import AppKit
import Darwin
import DoryRendererWorkerWireContracts
import Foundation

enum DoryApplicationProcessLaunchError: Error, CustomStringConvertible {
  case invalidDesktopHelperBundle(String)
  case launchFailed(String)
  case launchTimedOut
  case launchCancelled
  case invalidProcessIdentifier
  case processIdentityMismatch(expected: pid_t, actual: pid_t)
  case monitorFailed(Int32)

  var description: String {
    switch self {
    case .invalidDesktopHelperBundle(let detail):
      return "invalid Dory desktop helper application bundle: \(detail)"
    case .launchFailed(let detail):
      return "LaunchServices could not start DoryHVRunner: \(detail)"
    case .launchTimedOut:
      return "LaunchServices timed out while starting DoryHVRunner"
    case .launchCancelled:
      return "Dory desktop helper launch was cancelled before its handoff completed"
    case .invalidProcessIdentifier:
      return "LaunchServices returned an invalid DoryHVRunner process identifier"
    case .processIdentityMismatch(let expected, let actual):
      return
        "LaunchServices reported DoryHVRunner PID \(actual), expected authenticated peer PID \(expected)"
    case .monitorFailed(let code):
      return "could not monitor DoryHVRunner: \(String(cString: strerror(code)))"
    }
  }
}

enum DoryDesktopHelperApplicationKind: Equatable, Sendable {
  case rawHVRunner
  case virtualizationVMM

  var signedIdentity: DoryLiveRunnerCodeIdentity {
    switch self {
    case .rawHVRunner: .signedApplication
    case .virtualizationVMM: .signedVirtualizationApplication
    }
  }
}

struct DoryRunnerApplicationBundle: Equatable, Sendable {
  let applicationURL: URL
  let executableURL: URL
  let kind: DoryDesktopHelperApplicationKind

  init(executablePath: String) throws {
    let executable = URL(fileURLWithPath: executablePath).standardizedFileURL
    let macOSDirectory = executable.deletingLastPathComponent()
    let contentsDirectory = macOSDirectory.deletingLastPathComponent()
    let application = contentsDirectory.deletingLastPathComponent()
    guard macOSDirectory.lastPathComponent == "MacOS",
      contentsDirectory.lastPathComponent == "Contents",
      application.pathExtension == "app",
      let bundle = Bundle(url: application),
      bundle.executableURL?.standardizedFileURL == executable
    else {
      throw DoryApplicationProcessLaunchError.invalidDesktopHelperBundle(executablePath)
    }
    switch bundle.bundleIdentifier {
    case DoryRendererWorkerIdentity.runnerBundleIdentifier:
      kind = .rawHVRunner
    case DoryDesktopApplicationCodeIdentity.vmmBundleIdentifier:
      kind = .virtualizationVMM
    default:
      throw DoryApplicationProcessLaunchError.invalidDesktopHelperBundle(executablePath)
    }
    applicationURL = application
    executableURL = executable
  }
}

protocol DoryApplicationTerminationControlling: Sendable {
  var isTerminated: Bool { get }
  @discardableResult func forceTerminate() -> Bool
}

struct DoryWorkspaceApplicationLaunch: DoryApplicationTerminationControlling, @unchecked Sendable {
  let application: NSRunningApplication

  var processIdentifier: pid_t { application.processIdentifier }
  var isTerminated: Bool {
    application.isTerminated
      || NSRunningApplication(processIdentifier: processIdentifier) == nil
  }

  @discardableResult
  func forceTerminate() -> Bool {
    application.forceTerminate()
  }

  @discardableResult
  func terminate() -> Bool {
    application.terminate()
  }
}

/// Retains an exact LaunchServices application after a bounded daemon-side cleanup attempt could
/// not prove termination. Retries run on a private queue, so a stuck AppKit termination request can
/// neither block doryd's machine lock nor release the only exact-process handle prematurely.
final class DoryApplicationTerminalRetirement: @unchecked Sendable {
  private let application: any DoryApplicationTerminationControlling
  private let retryDelay: TimeInterval
  private let queue: DispatchQueue
  private let onRetired: @Sendable () -> Void
  private let completion = DispatchGroup()

  private init(
    application: any DoryApplicationTerminationControlling,
    retryDelay: TimeInterval,
    onRetired: @escaping @Sendable () -> Void
  ) {
    self.application = application
    self.retryDelay = max(0.001, retryDelay)
    queue = DispatchQueue(label: "dev.dory.application-terminal-retirement", qos: .utility)
    self.onRetired = onRetired
    completion.enter()
  }

  @discardableResult
  static func begin(
    application: any DoryApplicationTerminationControlling,
    retryDelay: TimeInterval = 1,
    onRetired: @escaping @Sendable () -> Void = {}
  ) -> DoryApplicationTerminalRetirement {
    let retirement = DoryApplicationTerminalRetirement(
      application: application,
      retryDelay: retryDelay,
      onRetired: onRetired
    )
    retirement.queue.async { retirement.attempt() }
    return retirement
  }

  func waitForTermination(timeout: TimeInterval) -> Bool {
    completion.wait(timeout: .now() + max(0, timeout)) == .success
  }

  func waitForTermination() {
    completion.wait()
  }

  private func attempt() {
    guard !application.isTerminated else {
      onRetired()
      completion.leave()
      return
    }
    _ = application.forceTerminate()
    queue.asyncAfter(deadline: .now() + retryDelay) { [self] in
      attempt()
    }
  }
}

/// Uses LaunchServices rather than making a desktop helper a daemon child. That gives TCC the
/// signed DoryHVRunner or DoryVMM bundle as the responsible Camera/Microphone identity. The helper
/// still receives no runtime object authority until the authenticated descriptor gate completes.
final class DoryWorkspaceApplicationLauncher: @unchecked Sendable {
  final class Request: @unchecked Sendable {
    fileprivate let completion: Completion
    fileprivate let completed = DispatchSemaphore(value: 0)

    init(
      retire: @escaping @Sendable (DoryWorkspaceApplicationLaunch) -> Void = {
        DoryApplicationTerminalRetirement.begin(application: $0)
      }
    ) {
      completion = Completion(retire: retire)
    }

    /// Claims the queued MainActor invocation once, provided the handoff has not already failed.
    /// Cancelling a request before the actor gets to it must not start another application.
    func claimInvocation() -> Bool { completion.claimInvocation() }

    func receive(application: DoryWorkspaceApplicationLaunch?, error: Error?) {
      if completion.finish(application: application, error: error) {
        completed.signal()
      }
    }

    /// Cancels a pending request without waiting for LaunchServices. If it has already returned
    /// an application, ownership of that exact handle remains with the failed-handoff caller.
    /// A later callback instead retires its handle asynchronously, outside the completion lock.
    func cancel() -> DoryWorkspaceApplicationLaunch? {
      let outcome = completion.cancel()
      if outcome.completedPendingRequest { completed.signal() }
      return outcome.application
    }

    func finish(timeout: TimeInterval = 30) throws -> DoryWorkspaceApplicationLaunch {
      let duration = timeout.isFinite ? max(0, timeout) : 30
      let deadline = ProcessInfo.processInfo.systemUptime + duration
      if Thread.isMainThread {
        while completion.takeResult() == nil, ProcessInfo.processInfo.systemUptime < deadline {
          _ = RunLoop.current.run(
            mode: .default,
            before: Date().addingTimeInterval(min(
              0.01, max(0, deadline - ProcessInfo.processInfo.systemUptime)
            ))
          )
        }
      } else if completion.takeResult() == nil {
        _ = completed.wait(timeout: .now() + duration)
      }
      if completion.abandon(error: DoryApplicationProcessLaunchError.launchTimedOut) {
        completed.signal()
      }
      return try completion.takeResult()!.get()
    }
  }

  fileprivate final class Completion: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<DoryWorkspaceApplicationLaunch, Error>?
    private var abandoned = false
    private var invocationClaimed = false
    private var applicationClaimedForCancellation = false
    // AppKit's equality/hash represent application identity across wrappers and PID changes.
    // Retain the objects so a late callback cannot be confused with a recycled object address.
    private var retiredApplications: Set<NSRunningApplication> = []
    private let retire: @Sendable (DoryWorkspaceApplicationLaunch) -> Void

    init(retire: @escaping @Sendable (DoryWorkspaceApplicationLaunch) -> Void) {
      self.retire = retire
    }

    func claimInvocation() -> Bool {
      lock.lock()
      defer { lock.unlock() }
      guard result == nil, !invocationClaimed else { return false }
      invocationClaimed = true
      return true
    }

    func finish(application: DoryWorkspaceApplicationLaunch?, error: Error?) -> Bool {
      var accepted = false
      var applicationToRetire: DoryWorkspaceApplicationLaunch?
      lock.lock()
      if abandoned || result != nil {
        // A duplicate callback cannot overwrite the application already owned by the caller.
        // A distinct unexpected/late application must still be retired exactly once.
        if let application,
          !(result.map {
            if case .success(let owned) = $0 {
              // AppKit may vend more than one wrapper for a live application. A duplicate
              // callback must not terminate that accepted process merely because wrappers differ.
              return owned.application.isEqual(application.application)
            }
            return false
          } ?? false),
          claimRetirement(application)
        {
          applicationToRetire = application
        }
      } else if let error {
        result = .failure(error)
        accepted = true
        if let application,
          claimRetirement(application)
        {
          applicationToRetire = application
        }
      } else if let application {
        result = .success(application)
        accepted = true
      } else {
        result = .failure(
          DoryApplicationProcessLaunchError.launchFailed(
            "completion returned neither an application nor an error"
          ))
        accepted = true
      }
      lock.unlock()
      if let applicationToRetire { retire(applicationToRetire) }
      return accepted
    }

    /// The completion lock must be held. Actual retirement always happens after unlocking.
    private func claimRetirement(_ application: DoryWorkspaceApplicationLaunch) -> Bool {
      retiredApplications.insert(application.application).inserted
    }

    func takeResult() -> Result<DoryWorkspaceApplicationLaunch, Error>? {
      lock.lock()
      defer { lock.unlock() }
      return result
    }

    func abandon(error: Error) -> Bool {
      lock.lock()
      defer { lock.unlock() }
      guard result == nil else { return false }
      abandoned = true
      result = .failure(error)
      return true
    }

    func cancel() -> (
      completedPendingRequest: Bool, application: DoryWorkspaceApplicationLaunch?
    ) {
      lock.lock()
      defer { lock.unlock() }
      if result == nil {
        abandoned = true
        result = .failure(DoryApplicationProcessLaunchError.launchCancelled)
        return (true, nil)
      }
      guard !applicationClaimedForCancellation, case .success(let application) = result else {
        return (false, nil)
      }
      applicationClaimedForCancellation = true
      return (false, application)
    }
  }

  func launch(
    bundle: DoryRunnerApplicationBundle,
    arguments: [String],
    environment: [String: String],
    timeout: TimeInterval = 30
  ) throws -> DoryWorkspaceApplicationLaunch {
    try beginLaunch(
      bundle: bundle,
      arguments: arguments,
      environment: environment
    ).finish(timeout: timeout)
  }

  /// Begins the LaunchServices request without waiting for its completion callback. The caller
  /// can therefore complete Dory's authenticated descriptor handoff while the new app is still
  /// establishing its AppKit identity; this avoids a launch-completion/handoff dependency cycle.
  func beginLaunch(
    bundle: DoryRunnerApplicationBundle,
    arguments: [String],
    environment: [String: String]
  ) -> Request {
    let request = Request()
    let invoke: @MainActor @Sendable () -> Void = {
      guard request.claimInvocation() else { return }
      let configuration = NSWorkspace.OpenConfiguration()
      configuration.arguments = arguments
      configuration.environment = environment
      configuration.activates = false
      configuration.addsToRecentItems = false
      configuration.createsNewApplicationInstance = true
      configuration.allowsRunningApplicationSubstitution = false
      configuration.promptsUserIfNeeded = false
      NSWorkspace.shared.openApplication(
        at: bundle.applicationURL,
        configuration: configuration
      ) { application, error in
        request.receive(
          application: application.map { DoryWorkspaceApplicationLaunch(application: $0) },
          error: error
        )
      }
    }

    // A main-thread check is not an actor-isolation proof under Swift's concurrency runtime.
    // Enter the actor asynchronously in every case so LaunchServices remains nonblocking and
    // the authenticated descriptor handoff can complete while AppKit establishes identity.
    Task { @MainActor in invoke() }
    return request
  }
}

/// EVFILT_PROC observes the exact non-child process object selected by LaunchServices. Darwin's
/// NOTE_EXITSTATUS is available when the observer may signal the target (doryd and the runner are
/// the same user), preserving the existing restart/error-status behavior without pretending the
/// runner is a waitpid-owned child.
final class DoryApplicationProcessMonitor: @unchecked Sendable {
  enum Observation: Sendable {
    case event(identifier: UInt, filter: Int16, flags: UInt16, filterFlags: UInt32, data: Int)
    case timedOut
    case interrupted
    case failed
  }
  typealias EventWaiter = @Sendable (Int32, TimeInterval?) -> Observation

  private enum WaitAdmission {
    case completed(HvProcessTermination)
    case observe(DispatchGroup)
    case join(DispatchGroup)
  }

  let pid: pid_t
  private let queueDescriptor: Int32
  private let terminationObserved: @Sendable () -> Bool
  private let eventWaiter: EventWaiter
  private let observationLock = NSLock()
  private var cachedTermination: HvProcessTermination?
  private var activeObservation: DispatchGroup?
  private var kernelObservationFailed = false
  private static let maximumBoundedWait = TimeInterval(Int64.max / 1_000_000_000) / 2

  init(
    pid: pid_t,
    terminationObservedAfterRegistration: @escaping @Sendable () -> Bool = { false },
    eventWaiter: EventWaiter? = nil
  ) throws {
    guard pid > 1 else { throw DoryApplicationProcessLaunchError.invalidProcessIdentifier }
    self.pid = pid
    terminationObserved = terminationObservedAfterRegistration
    self.eventWaiter = eventWaiter ?? Self.readEvent
    queueDescriptor = kqueue()
    guard queueDescriptor >= 0 else {
      throw DoryApplicationProcessLaunchError.monitorFailed(errno)
    }
    var registration = kevent(
      ident: UInt(pid),
      filter: Int16(EVFILT_PROC),
      flags: UInt16(EV_ADD | EV_ENABLE | EV_ONESHOT),
      fflags: NOTE_EXIT | UInt32(bitPattern: NOTE_EXITSTATUS),
      data: 0,
      udata: nil
    )
    let result = kevent(
      queueDescriptor,
      &registration,
      1,
      nil,
      0,
      nil
    )
    guard result == 0 else {
      let code = errno
      Darwin.close(queueDescriptor)
      throw DoryApplicationProcessLaunchError.monitorFailed(code)
    }
    // EVFILT_PROC observes exits after attachment. LaunchServices can report a very short-lived
    // application just before it exits, so close the completion-to-registration race by
    // checking the retained NSRunningApplication immediately after the knote is installed.
    // A queued exact exit can still carry a truthful status if it happened after attachment.
    // Otherwise independent termination proves lifetime retirement, but not a wait status.
    if terminationObservedAfterRegistration() {
      switch self.eventWaiter(queueDescriptor, 0) {
      case let .event(identifier, filter, flags, filterFlags, data)
        where identifier == UInt(pid) && filter == Int16(EVFILT_PROC)
          && flags & UInt16(EV_ERROR) == 0 && filterFlags & NOTE_EXIT != 0
          && filterFlags & UInt32(bitPattern: NOTE_EXITSTATUS) != 0:
        cachedTermination = Self.decode(rawStatus: Int32(truncatingIfNeeded: data))
      default:
        cachedTermination = Self.unknownTermination
      }
    }
  }

  func waitForTermination() -> HvProcessTermination {
    waitForTermination(timeout: nil)!
  }

  /// A bounded wait is used only by launch-failure cleanup. Normal supervision keeps its
  /// indefinite wait on a utility queue. A timeout consumes no knote, so the same exact-process
  /// monitor remains valid for the terminal retirement path or a later supervised wait.
  func waitForTermination(timeout: TimeInterval) -> HvProcessTermination? {
    if let cached = observationLock.withLock({ cachedTermination }) { return cached }
    guard timeout.isFinite, timeout >= 0, timeout <= Self.maximumBoundedWait else { return nil }
    return waitForTermination(timeout: Optional(timeout))
  }

  private func waitForTermination(timeout: TimeInterval?) -> HvProcessTermination? {
    let deadline = timeout.map { ProcessInfo.processInfo.systemUptime + $0 }
    while true {
      let admission: WaitAdmission = observationLock.withLock {
        if let cachedTermination { return .completed(cachedTermination) }
        if let activeObservation { return .join(activeObservation) }
        let observation = DispatchGroup()
        observation.enter()
        activeObservation = observation
        return .observe(observation)
      }
      switch admission {
      case .completed(let termination):
        return termination
      case .join(let observation):
        if let deadline {
          let remaining = max(0, deadline - ProcessInfo.processInfo.systemUptime)
          guard observation.wait(timeout: .now() + remaining) == .success else {
            return observationLock.withLock { cachedTermination }
          }
        } else {
          observation.wait()
        }
      case .observe(let observation):
        let result = observeTermination(until: deadline)
        let published = observationLock.withLock { () -> HvProcessTermination? in
          if cachedTermination == nil { cachedTermination = result }
          activeObservation = nil
          return cachedTermination
        }
        observation.leave()
        return published
      }
    }
  }

  /// Only one caller consumes the one-shot knote. All other waiters join that observation with
  /// their own monotonic deadline, and a positive result is replayed rather than waiting again.
  private func observeTermination(until deadline: TimeInterval?) -> HvProcessTermination? {
    if observationLock.withLock({ kernelObservationFailed }) {
      return observeTerminationAfterMonitorFailure(until: deadline)
    }
    while true {
      let remaining = deadline.map { $0 - ProcessInfo.processInfo.systemUptime }
      if let remaining, remaining <= 0 {
        return terminationObserved() ? Self.unknownTermination : nil
      }
      switch eventWaiter(queueDescriptor, remaining) {
      case let .event(identifier, filter, flags, filterFlags, data)
        where identifier == UInt(pid) && filter == Int16(EVFILT_PROC)
          && flags & UInt16(EV_ERROR) == 0 && filterFlags & NOTE_EXIT != 0:
        guard filterFlags & UInt32(bitPattern: NOTE_EXITSTATUS) != 0 else {
          return Self.unknownTermination
        }
        return Self.decode(rawStatus: Int32(truncatingIfNeeded: data))
      case .interrupted:
        continue
      case .timedOut:
        return terminationObserved() ? Self.unknownTermination : nil
      case .event, .failed:
        // EV_ERROR data is errno, not a wait status. Wrong-identity/filter events and monitor
        // errors cannot authorize releasing VM authority. Use only the retained exact app's
        // independent termination observation, preserving each caller's original deadline.
        // A malformed event may already have consumed the one-shot knote. Retain this
        // failure across bounded waits; a later observer must not block on that knote
        // before checking the exact application's independent termination proof.
        observationLock.withLock { kernelObservationFailed = true }
        return observeTerminationAfterMonitorFailure(until: deadline)
      }
    }
  }

  private func observeTerminationAfterMonitorFailure(until deadline: TimeInterval?)
    -> HvProcessTermination?
  {
    while !terminationObserved() {
      if let deadline, ProcessInfo.processInfo.systemUptime >= deadline { return nil }
      let delay = deadline.map { min(0.01, max(0, $0 - ProcessInfo.processInfo.systemUptime)) }
        ?? 0.01
      Thread.sleep(forTimeInterval: delay)
    }
    return Self.unknownTermination
  }

  private static let unknownTermination = HvProcessTermination(
    status: 0, wasUncaughtSignal: false, statusIsKnown: false)

  private static func readEvent(descriptor: Int32, timeout: TimeInterval?) -> Observation {
    var event = kevent()
    let result: Int32
    if let timeout {
      let wholeSeconds = floor(timeout)
      var timeoutValue = timespec(tv_sec: Int(wholeSeconds),
        tv_nsec: Int((timeout - wholeSeconds) * 1_000_000_000))
      result = withUnsafePointer(to: &timeoutValue) {
        kevent(descriptor, nil, 0, &event, 1, $0)
      }
    } else {
      result = kevent(descriptor, nil, 0, &event, 1, nil)
    }
    if result > 0 {
      return .event(identifier: event.ident, filter: event.filter, flags: event.flags,
        filterFlags: event.fflags, data: event.data)
    }
    if result == 0 { return .timedOut }
    return errno == EINTR ? .interrupted : .failed
  }

  private static func decode(rawStatus: Int32) -> HvProcessTermination {
    let signal = rawStatus & 0x7f
    if signal == 0 {
      return HvProcessTermination(
        status: (rawStatus >> 8) & 0xff,
        wasUncaughtSignal: false
      )
    }
    return HvProcessTermination(status: signal, wasUncaughtSignal: true)
  }

  deinit { Darwin.close(queueDescriptor) }
}
