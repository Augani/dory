import AppKit
import Darwin
import DoryFirmware
import DoryHV
import DoryMachinePC
import DoryOperations
import DoryRendererWorkerContracts
import DoryVMMKit
import DoryVirtio
import DorydKit
import Foundation

protocol DoryPCRendererGenerationLaunch: AnyObject, Sendable {
  var doryPCWorkerGeneration: UInt64 { get }
  func teardown(reason: String)
  func waitForRetirement(reason: String) async throws
}

final class DoryPCRendererLaunchStore<Launch: DoryPCRendererGenerationLaunch>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Launch?
  private var retiredForReplacement: Launch?
  private var terminal = false
  private let terminalRetirement = DesktopRendererWorkerRetirement<Void>()

  init(_ launch: Launch?) {
    stored = launch
  }

  func current() -> Launch? { lock.withLock { terminal ? nil : stored } }

  /// A whole-machine reboot may overtake GPU-only recovery. Its reset must join the already
  /// requested one-shot worker handoff, while presentation callbacks still see no live launch.
  func replacementSource() -> Launch? {
    lock.withLock { terminal ? nil : stored ?? retiredForReplacement }
  }

  func current(matchingWorkerGeneration workerGeneration: UInt64) -> Launch? {
    lock.withLock {
      guard !terminal, stored?.doryPCWorkerGeneration == workerGeneration else { return nil }
      return stored
    }
  }

  @discardableResult
  func replace(_ launch: Launch, replacing previous: Launch? = nil) -> Bool {
    lock.withLock {
      guard !terminal else { return false }
      let current = stored ?? retiredForReplacement
      if let previous, current !== previous { return false }
      if let current, launch.doryPCWorkerGeneration <= current.doryPCWorkerGeneration { return false }
      stored = launch
      retiredForReplacement = nil
      return true
    }
  }

  func retire(matchingWorkerGeneration workerGeneration: UInt64) -> Launch? {
    lock.withLock {
      guard !terminal, stored?.doryPCWorkerGeneration == workerGeneration else { return nil }
      let launch = stored
      stored = nil
      retiredForReplacement = launch
      return launch
    }
  }

  func teardown(reason: String) {
    _ = startTerminalRetirement(reason: reason)
  }

  func teardownAndWait(reason: String) async throws {
    guard let retirement = startTerminalRetirement(reason: reason) else { return }
    try await retirement.value
  }

  private func startTerminalRetirement(reason: String) -> Task<Void, any Error>? {
    let launch = lock.withLock {
      terminal = true
      return stored ?? retiredForReplacement
    }
    guard let launch else { return nil }
    launch.teardown(reason: reason)
    // Hold the exact retired launch until its bounded proof wait completes. Neither AppKit nor a
    // guest register callback joins here; an explicit asynchronous caller can join the same task.
    return terminalRetirement.start {
      try await launch.waitForRetirement(reason: reason)
    }
  }
}

struct DoryPCRendererReplacementResetTicket: Sendable {
  let epoch: UInt64
}

/// The execution thread records reboot intent before hopping onto the app run loop. Whichever
/// replacement completion gets there first consumes it exactly once, so callback order is inert.
final class DoryPCRendererMachineResetHandoff<Payload: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var pending: Payload?
  private var requested = false

  var isPending: Bool { lock.withLock { requested } }
  func begin() { lock.withLock { requested = true } }
  func store(_ payload: Payload) { lock.withLock { pending = payload; requested = true } }
  func take() -> Payload? {
    lock.withLock {
      guard let payload = pending else { return nil }
      pending = nil
      requested = false
      return payload
    }
  }
  func clear() { lock.withLock { pending = nil; requested = false } }
}

/// Worker callbacks can arrive while the PC machine is being constructed. Retain only the newest
/// monotonic generation and deliver on the controller's actor, without VM-stop authority.
final class DoryPCRendererWorkerLossRelay: @unchecked Sendable {
  private let lock = NSLock()
  private var latestGeneration: UInt64 = 0
  private var pending: UInt64?
  private var closed = false
  private var handler: (@MainActor @Sendable (UInt64) -> Void)?

  func install(_ handler: @escaping @MainActor @Sendable (UInt64) -> Void) {
    let generation = lock.withLock { () -> UInt64? in
      guard !closed else { return nil }
      self.handler = handler
      let generation = pending
      pending = nil
      return generation
    }
    if let generation { DesktopAppRunLoop.perform { handler(generation) } }
  }

  func report(_ generation: UInt64) {
    let delivery = lock.withLock { () -> (@MainActor @Sendable (UInt64) -> Void)? in
      guard !closed, generation > latestGeneration else { return nil }
      latestGeneration = generation
      guard let handler else { pending = generation; return nil }
      return handler
    }
    if let delivery { DesktopAppRunLoop.perform { delivery(generation) } }
  }

  func close() { lock.withLock { closed = true; pending = nil; handler = nil } }
}

@MainActor
final class DoryPCRendererReplacementResetCoordinator<Launch: DoryPCRendererGenerationLaunch> {
  private var resetGeneration: UInt64 = 0

  func beginReset(
    previousLaunch: Launch,
    launchStore: DoryPCRendererLaunchStore<Launch>
  ) -> DoryPCRendererReplacementResetTicket? {
    guard
      launchStore.retire(
        matchingWorkerGeneration: previousLaunch.doryPCWorkerGeneration
      ) != nil
    else {
      return nil
    }
    precondition(resetGeneration < .max)
    resetGeneration += 1
    return DoryPCRendererReplacementResetTicket(epoch: resetGeneration)
  }

  func acceptsCompletion(_ ticket: DoryPCRendererReplacementResetTicket) -> Bool {
    resetGeneration == ticket.epoch
  }

  func invalidate() {
    precondition(resetGeneration < .max)
    resetGeneration += 1
  }
}

final class DoryPCRendererReadyPublisher: @unchecked Sendable {
  private let lock = NSLock()
  private var published = false
  private var presentationReady = false
  private var rendererPresentationReady: Bool
  private var rendererPresentationSuspended = false
  private var rendererPresentationGeneration: UInt64?
  private var guestMachineEpoch: UInt64 = 1
  private var guestServicesReady: Bool
  private let requiresGuestServices: Bool
  private let requiresRendererPresentation: Bool
  private let publishOperation: @Sendable (UInt64?, UInt64) throws -> Void

  init(
    requiresGuestServices: Bool,
    requiresRendererPresentation: Bool = false,
    _ publishOperation: @escaping @Sendable (UInt64?, UInt64) throws -> Void
  ) {
    self.requiresGuestServices = requiresGuestServices
    self.requiresRendererPresentation = requiresRendererPresentation
    rendererPresentationReady = !requiresRendererPresentation
    rendererPresentationGeneration = nil
    guestServicesReady = !requiresGuestServices
    self.publishOperation = publishOperation
  }

  func markPresentationReady() throws {
    try markReady { presentationReady = true }
  }

  /// A VM reset starts another guest boot even when the same host renderer survives. Neither
  /// the previous execution slice nor its service/presentation observations can publish the
  /// replacement machine's readiness.
  func prepareGuestMachineReset() {
    lock.withLock {
      guestMachineEpoch = guestMachineEpoch == .max ? 1 : guestMachineEpoch + 1
      published = false
      presentationReady = false
      rendererPresentationReady = !requiresRendererPresentation
      rendererPresentationSuspended = requiresRendererPresentation
      rendererPresentationGeneration = nil
      guestServicesReady = !requiresGuestServices
    }
  }

  func prepareRendererPresentation(workerGeneration: UInt64) {
    lock.withLock {
      published = false
      rendererPresentationReady = false
      rendererPresentationSuspended = false
      rendererPresentationGeneration = workerGeneration
    }
  }

  func suspendRendererPresentation(workerGeneration: UInt64) {
    lock.withLock {
      guard rendererPresentationGeneration == nil || rendererPresentationGeneration == workerGeneration else { return }
      published = false
      rendererPresentationReady = false
      rendererPresentationSuspended = true
    }
  }

  func markRendererPresentationReady(workerGeneration: UInt64) throws {
    try markReady {
      guard !rendererPresentationSuspended else { return }
      if rendererPresentationGeneration == nil {
        rendererPresentationGeneration = workerGeneration
      }
      guard rendererPresentationGeneration == workerGeneration else { return }
      rendererPresentationReady = true
    }
  }

  func markGuestServicesReady() throws {
    try markReady { guestServicesReady = true }
  }

  private func markReady(_ mutation: () -> Void) throws {
    let publication = lock.withLock { () -> (generation: UInt64?, epoch: UInt64)? in
      mutation()
      guard !published else { return nil }
      guard presentationReady, rendererPresentationReady, guestServicesReady else {
        return nil
      }
      published = true
      return (rendererPresentationGeneration, guestMachineEpoch)
    }
    guard let publication else { return }
    do {
      try publishOperation(publication.generation, publication.epoch)
    } catch {
      lock.withLock {
        guard rendererPresentationGeneration == publication.generation,
          guestMachineEpoch == publication.epoch else { return }
        published = false
      }
      throw error
    }
  }
}

extension DesktopRendererWorkerLaunch: DoryPCRendererGenerationLaunch {
  var doryPCWorkerGeneration: UInt64 { workerGeneration.rawValue }
}

enum DoryPCMode {
  static func requestRendererRestart(
    transport: DoryPCVirtioPCITransport, authority: DoryPCVirGLRendererAuthority?,
    replacementAvailable: Bool, stopping: Bool
  ) -> Bool {
    guard !stopping, replacementAvailable, authority?.acceptsGuestCommands == true else { return false }
    let baseline = transport.deviceState.snapshot()
    guard baseline.status.contains(.driverOK) else { return false }
    let epoch = baseline.lifecycleEpoch
    _ = transport.requestDeviceReset(expectedLifecycleEpoch: epoch)
    let current = transport.deviceState.snapshot()
    return current.lifecycleEpoch == epoch && current.status.contains(.deviceNeedsReset)
  }

  static func runtimeGraphicsBackend(
    for producerFenceContract: DoryRendererProducerFenceContract?
  ) throws -> DoryRuntimeGraphicsBackend {
    switch producerFenceContract {
    case .doryPCX8664LinuxVirGL2PrepareFBV1:
      return .virgl
    case .doryPCX8664LinuxVenusPrepareFBV1:
      return .virglVenus
    case .none, .some:
      throw VMError.invalidConfiguration(
        "DoryPC accelerated readiness has no admitted PC renderer contract"
      )
    }
  }

  static func acceleratedRuntimeGraphicsSelection(
    operationID: UUID,
    resolvedPlanSHA256: String,
    planRevision: UInt64,
    producerFenceContract: DoryRendererProducerFenceContract?,
    workerGeneration: UInt64,
    rendererWorkerReceiptSHA256: String
  ) throws -> DoryRuntimeGraphicsSelection {
    let backend = try runtimeGraphicsBackend(for: producerFenceContract)
    // A signed worker profile and a host presentation establish renderer admission, not a
    // guest-observed shader/fence proof. Keep the receipt provisional until that independent
    // observation can be bound to this exact runtime generation.
    let selection = DoryRuntimeGraphicsSelection(
      operationID: DoryOperationIdentity.canonical(operationID),
      resolvedPlanSHA256: resolvedPlanSHA256,
      planRevision: planRevision,
      accelerationLevel: .hardwareAccelerated3D,
      backend: backend,
      rendererGeneration: workerGeneration,
      rendererWorkerReceiptSHA256: rendererWorkerReceiptSHA256,
      requestedGraphics: .hardwareAccelerated3D,
      admittedGraphics: .hardwareAccelerated3D,
      verificationState: .provisional
    )
    guard selection.isValid else {
      throw VMError.invalidConfiguration(
        "DoryPC accelerated readiness has an invalid renderer identity"
      )
    }
    return selection
  }

  /// A resolved device contract is launch authority, not a best-effort preference. Once a host
  /// device is requested, construction or attachment failure must abort the launch instead of
  /// publishing a VM whose actual device graph no longer matches its immutable envelope.
  static func admitRequiredHostDevice<Device>(
    requested: Bool,
    make: () throws -> Device
  ) throws -> Device? {
    guard requested else { return nil }
    return try make()
  }

  /// DoryPC accelerated graphics is a signed renderer-worker contract, not a fallback hint. The
  /// runner may build a VirGL authority only for hardware-3D launches that also have a display;
  /// software/no-graphics launches must leave the renderer path unobserved so stale descriptors
  /// cannot widen authority after admission.
  static func admitRequiredGPUAcceleration<Authority>(
    graphics: DoryGraphicsAccelerationLevel,
    hasDisplay: Bool,
    make: () throws -> Authority
  ) throws -> Authority? {
    switch graphics {
    case .none, .software:
      return nil
    case .hostAcceleratedDisplay:
      throw VMError.invalidConfiguration(
        "DoryPC host-accelerated display requires a separate admitted graphics contract"
      )
    case .hardwareAccelerated3D:
      guard hasDisplay else {
        throw VMError.invalidConfiguration(
          "DoryPC accelerated graphics requires an admitted display"
        )
      }
      return try make()
    }
  }

  /// DoryPC's gvproxy sockets are ephemeral runtime endpoints. Derive their directory from the
  /// already-admitted lifecycle socket rather than the persistent machine bundle, whose path can
  /// legitimately exceed Darwin's `sockaddr_un.sun_path` limit.
  static func ephemeralRuntimeDirectory(controlSocketPath: String) -> String? {
    guard controlSocketPath.hasPrefix("/"),
      !controlSocketPath.utf8.contains(0)
    else { return nil }
    let directory = URL(fileURLWithPath: controlSocketPath)
      .deletingLastPathComponent().standardizedFileURL.path
    guard directory != "/", !directory.isEmpty else { return nil }
    return directory
  }

  struct Configuration {
    let envelope: DoryPCRuntimeLaunchEnvelope
    let authority: DoryPCUEFIRuntimeAuthority
    let stateDirectory: String
    let handoffSocketPath: String
    let agentSocketPath: String
    let shellSocketPath: String
    let consoleSocketPath: String
    let controlSocketPath: String
    let usbControlSocketPath: String?
    let sshAgentSocketPath: String?
    let gvproxyPath: String
    let shares: [DoryMachineShareConfiguration]
    let environment: [String: String]
    let displayPresentation: DoryMachineDisplayPresentation
    var displayRelayServiceName: String? = nil
    let reconnectIdentity: DoryRuntimeReconnectLaunchIdentity
    var rendererWorkerLaunch: DesktopRendererWorkerLaunch? = nil
    var rendererReplacementProvider: DesktopRendererWorkerReplacementProvider? = nil
    var qualificationFaultAuthority: DoryRuntimeQualificationFaultAuthority? = nil
  }

  @MainActor
  static func run(_ configuration: Configuration) throws {
    let controller = try Controller(configuration: configuration)
    try controller.run()
  }

  @MainActor
  private final class Controller: NSObject, NSApplicationDelegate, NSWindowDelegate {

    private final class FirstFrameRelay: @unchecked Sendable {
      private let lock = NSLock()
      private var delivered = false
      private var operation: (@Sendable () -> Void)?

      func install(_ operation: @escaping @Sendable () -> Void) {
        let deliverNow = lock.withLock { () -> Bool in
          self.operation = operation
          return delivered
        }
        if deliverNow { operation() }
      }

      func deliver() {
        let operation = lock.withLock { () -> (@Sendable () -> Void)? in
          guard !delivered else { return nil }
          delivered = true
          return self.operation
        }
        operation?()
      }
    }

    private class FailureRelay: @unchecked Sendable {
      private let lock = NSLock()
      private var failureStorage: String?
      private var stop: (@Sendable () -> Void)?

      var failure: String? { lock.withLock { failureStorage } }

      func installStop(_ operation: @escaping @Sendable () -> Void) {
        let shouldStop = lock.withLock { () -> Bool in
          stop = operation
          return failureStorage != nil
        }
        if shouldStop { operation() }
      }

      func report(_ reason: String) {
        let operation = lock.withLock { () -> (@Sendable () -> Void)? in
          guard failureStorage == nil else { return nil }
          failureStorage = reason
          return stop
        }
        operation?()
      }
    }

    private final class FilesystemFailureRelay: FailureRelay, @unchecked Sendable {
      func report(_ event: VirtioFSWorkerLifecycleEvent) {
        guard case .failure(let reason) = event else { return }
        report(reason)
      }
    }

    private final class MachineState: @unchecked Sendable {
      private let lock = NSLock()
      let executionPause = GuestExecutionPauseCoordinator()
      private var machine: DoryPCUEFIMachine
      private var dynamicDisplayModes: [DoryVirtioGPUDisplayMode]?
      private var stopping = false

      init(
        machine: DoryPCUEFIMachine,
        dynamicDisplayModes: [DoryVirtioGPUDisplayMode]?
      ) {
        self.machine = machine
        self.dynamicDisplayModes = dynamicDisplayModes
      }

      func current() -> DoryPCUEFIMachine { lock.withLock { machine } }

      func replace(_ replacement: DoryPCUEFIMachine) -> Bool {
        lock.withLock {
          guard !stopping else { return false }
          if let dynamicDisplayModes {
            guard replacement.displayDevice.gpuDevice.scanouts.count >= dynamicDisplayModes.count
            else { return false }
            guard replacement.displayDevice.updateScanoutTopology(dynamicDisplayModes) else {
              return false
            }
          }
          machine = replacement
          return true
        }
      }

      @discardableResult
      func updateDisplaySize(
        scanoutID: UInt32,
        width: UInt32,
        height: UInt32,
        physicalWidthMillimeters: UInt16,
        physicalHeightMillimeters: UInt16
      ) -> Bool {
        lock.withLock {
          guard !stopping, var modes = dynamicDisplayModes,
            Int(scanoutID) < modes.count,
            (1...DoryVirtualMachineDisplayCapabilityRequest.maximumDimensionPixels).contains(width),
            (1...DoryVirtualMachineDisplayCapabilityRequest.maximumDimensionPixels).contains(height),
            physicalWidthMillimeters > 0,
            physicalHeightMillimeters > 0
          else { return false }
          let index = Int(scanoutID)
          let physicalWidth = min(4_095, physicalWidthMillimeters)
          let physicalHeight = min(4_095, physicalHeightMillimeters)
          let requested = DoryVirtioGPUDisplayMode(
            width: width,
            height: height,
            physicalWidthMillimeters: physicalWidth,
            physicalHeightMillimeters: physicalHeight
          )
          if modes[index] == requested { return true }
          guard machine.displayDevice.updateScanoutSize(
            scanoutID: scanoutID,
            width: width,
            height: height,
            physicalWidthMillimeters: physicalWidth,
            physicalHeightMillimeters: physicalHeight
          ) else { return false }
          modes[index] = requested
          dynamicDisplayModes = modes
          return true
        }
      }

      func updateDisplayTopology(_ displays: [DoryVirtioGPUDisplayMode]) -> Bool {
        lock.withLock {
          guard !stopping, let modes = dynamicDisplayModes,
            !displays.isEmpty,
            displays.count <= machine.displayDevice.gpuDevice.scanouts.count,
            displays.allSatisfy({
              (1...DoryVirtualMachineDisplayCapabilityRequest.maximumDimensionPixels)
                .contains($0.width)
                && (1...DoryVirtualMachineDisplayCapabilityRequest.maximumDimensionPixels)
                  .contains($0.height)
                && $0.physicalWidthMillimeters > 0
                && $0.physicalHeightMillimeters > 0
            })
          else { return false }
          let normalized = displays.map {
            DoryVirtioGPUDisplayMode(
              width: $0.width,
              height: $0.height,
              physicalWidthMillimeters: min(4_095, $0.physicalWidthMillimeters),
              physicalHeightMillimeters: min(4_095, $0.physicalHeightMillimeters)
            )
          }
          if modes == normalized { return true }
          guard machine.displayDevice.updateScanoutTopology(normalized) else { return false }
          dynamicDisplayModes = normalized
          return true
        }
      }

      func requestStop() {
        executionPause.stop()
        let current = lock.withLock { () -> DoryPCUEFIMachine? in
          guard !stopping else { return nil }
          stopping = true
          return machine
        }
        current?.machine.powerController.request(.powerOff)
      }

      func requestGuestShutdown(
        graceful: Bool,
        agentSocketPath: String,
        keyboardInput: DoryPCDesktopInputSink,
        log: @escaping @Sendable (String) -> Void
      ) {
        let current = lock.withLock { () -> DoryPCUEFIMachine? in
          guard !stopping else { return nil }
          stopping = true
          return machine
        }
        guard let current else { return }
        // Graceful shutdown must be able to execute the guest's shutdown request.
        try? executionPause.resume()
        guard graceful else {
          current.machine.powerController.request(.powerOff)
          return
        }
        DispatchQueue.global(qos: .userInitiated).async {
          do {
            let control = DorydKit.AgentControl(
              configuration: .init(
                directSocketPath: agentSocketPath
              ))
            defer { control.disconnect() }
            let result = try control.exec(
              argv: [
                "/bin/sh", "-c",
                GuestShutdownCommand.detachedDesktopRequest(),
              ],
              timeoutMs: 5_000,
              outputLimitBytes: 64 * 1_024
            )
            guard result.exitCode == 0, !result.timedOut else {
              throw VMError.bootFailure(
                "guest shutdown request exited \(result.exitCode)"
              )
            }
          } catch {
            log("graceful shutdown RPC failed; sending ACPI power key: \(error)")
            keyboardInput.send(frame: [
              .init(type: 1, code: 116, value: 1),
              .init(type: 1, code: 116, value: 0),
            ])
          }
          DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + DoryEngineShutdownTiming.helperWatchdogSeconds
          ) {
            log("graceful guest shutdown timed out; forcing power off")
            current.machine.powerController.request(.powerOff)
          }
        }
      }

      var isStopping: Bool { lock.withLock { stopping } }
    }

    private let configuration: Configuration
    private let application = NSApplication.shared
    private let stateLock: EngineStateDirectoryLock
    private let serialLog: FileHandle
    private let serialOutput: BoundedSerialConsolePublisher
    private let serialInput: RawHVSerialConsoleInput
    private let lifecycleServer: VmmLifecycleReceiptServer
    private let networkBackend: any DoryVirtioNetworkBackend
    private let networkRuntime: DoryPCGVProxyNetworkBackend?
    private let vsock: VirtioVsock
    private let agentBridge: GuestVsockSocketBridge
    private let shellBridge: GuestVsockSocketBridge
    private let sshAgentBridge: HostSSHAgentBridge?
    private let filesystemRuntime: DoryPCFilesystemRuntime?
    private let filesystemFailureRelay: FilesystemFailureRelay
    private let rendererFailureRelay: FailureRelay
    private let rendererWorkerLossRelay: DoryPCRendererWorkerLossRelay
    private let clipboard: DoryDesktopClipboardCoordinator?
    private let clipboardFocus = DoryDesktopClipboardFocusLease()
    private let machineState: MachineState
    private let keyboardInput: DoryPCDesktopInputSink
    private let pointerInput: DoryPCDesktopInputSink
    private let relativePointerInput: DoryPCDesktopInputSink
    private let displaySink: DoryPCSoftwareDisplaySink?
    private let gpuAccelerationAuthority: DoryPCVirGLRendererAuthority?
    private let qualificationFaultController: RuntimeQualificationFaultController?
    private let gpuHostVisibleAperture: DoryPCHostVisibleGPUAperture?
    private let executionProfilingEnabled: Bool
    private let executionProfileWriter: DoryPCExecutionProfileWriter?
    private let rendererWorkerLaunchStore: DoryPCRendererLaunchStore<DesktopRendererWorkerLaunch>
    private let rendererReplacementProvider: DesktopRendererWorkerReplacementProvider?
    private let cameraBridge: DoryPCCameraBridge?
    private let audioBackend: DoryPCMacAudioBackend?
    private let usbControlHandler: DoryPCUSBControlHandler?
    private let usbControlServer: UsbControlServer?
    private let displayRelaySlot: DoryVMDisplayRunnerRelaySlot
    private let mailbox: DesktopFrameMailbox?
    private let cursorMailbox: DesktopCursorMailbox?
    private let window: NSWindow?
    private let readyPublisher: DoryPCRendererReadyPublisher
    private let graphicsReadinessState: DesktopRuntimeGraphicsReadinessState
    private var executionThread: Thread?
    private var gpuRendererReplacementTask: Task<Void, Never>?
    private struct RendererMachineResetDevices: Sendable {
      let previousDisplayDevice: DoryPCVirtioGPUPCIDevice
      let vsock: DoryPCVirtioVsockPCIDevice
      let filesystem: [any DoryPCPCIFunction]
    }
    private let rendererMachineResetHandoff = DoryPCRendererMachineResetHandoff<RendererMachineResetDevices>()
    private let rendererResetCoordinator = DoryPCRendererReplacementResetCoordinator<
      DesktopRendererWorkerLaunch
    >()
    private let signalQueue = DispatchQueue(
      label: "dev.dory.dory-hv.dorypc.signals",
      qos: .userInitiated
    )
    private let guestServiceQueue = DispatchQueue(
      label: "dev.dory.dory-hv.dorypc.guest-services",
      qos: .userInitiated
    )
    private var signalSources = [DispatchSourceSignal]()
    private var stopError: Error?

    init(configuration: Configuration) throws {
      let envelope = configuration.envelope
      let rendererWorkerLaunch = configuration.rendererWorkerLaunch
      switch (envelope.graphics, rendererWorkerLaunch) {
      case (.none, nil), (.software, nil), (.hardwareAccelerated3D, .some):
        break
      case (.hostAcceleratedDisplay, _):
        throw VMError.invalidConfiguration(
          "DoryPC host-accelerated display requires a separate admitted graphics contract"
        )
      case (.hardwareAccelerated3D, nil):
        throw VMError.invalidConfiguration(
          "DoryPC accelerated graphics requires the signed renderer authority"
        )
      case (.none, .some), (.software, .some):
        throw VMError.invalidConfiguration(
          "DoryPC software graphics must not receive renderer authority"
        )
      }
      let faultController = try configuration.qualificationFaultAuthority.map { authority in
        guard authority.machineID == envelope.machineID,
          authority.operationID == envelope.operationID,
          authority.resolvedPlanSHA256 == envelope.resolvedPlanSHA256,
          authority.expiresAt > Date(), authority.policy.isRendererCrashOnly,
          envelope.graphics == .hardwareAccelerated3D, rendererWorkerLaunch != nil
        else { throw DoryRuntimeQualificationFaultError.unauthorized }
        return try RuntimeQualificationFaultController(authority: authority)
      }
      qualificationFaultController = faultController
      rendererWorkerLaunchStore = DoryPCRendererLaunchStore(rendererWorkerLaunch)
      rendererReplacementProvider = configuration.rendererReplacementProvider
      let devices = envelope.devices
      guard devices.displays.count <= 1 || configuration.displayRelayServiceName != nil else {
        throw VMError.invalidConfiguration(
          "DoryPC multiple displays require the app-owned display relay"
        )
      }
      guard devices.networkAttachment != .bridged else {
        throw VMError.invalidConfiguration(
          "DoryPC launch requested a host device backend that is not admitted by this runner"
        )
      }
      let clipboardPolicy: DoryVMClipboardPolicy?
      if devices.clipboard {
        guard let policy = devices.clipboardPolicy, policy.isEnabled else {
          throw VMError.invalidConfiguration(
            "DoryPC clipboard requires an explicit enabled transfer policy"
          )
        }
        clipboardPolicy = policy
      } else {
        clipboardPolicy = nil
      }
      self.configuration = configuration
      guard devices.directorySharing == !configuration.shares.isEmpty else {
        throw VMError.invalidConfiguration(
          "DoryPC directory-sharing contract does not match launch shares"
        )
      }
      let rawShares = try configuration.shares.map { share in
        try VirtioFSShareConfiguration(
          tag: share.tag,
          path: share.hostPath,
          readOnly: share.readOnly,
          guestMountPoint: share.guestPath
        )
      }
      let filesystemFailureRelay = FilesystemFailureRelay()
      self.filesystemFailureRelay = filesystemFailureRelay
      let rendererFailureRelay = FailureRelay()
      self.rendererFailureRelay = rendererFailureRelay
      let rendererWorkerLossRelay = DoryPCRendererWorkerLossRelay()
      self.rendererWorkerLossRelay = rendererWorkerLossRelay
      let filesystemRuntime =
        rawShares.isEmpty
        ? nil
        : try DoryPCFilesystemRuntime(
          shares: rawShares,
          virtualCPUCount: Int(envelope.executionResources.virtualCPUCount),
          onWorkerLifecycle: { [filesystemFailureRelay] event in
            filesystemFailureRelay.report(event)
          }
        )
      self.filesystemRuntime = filesystemRuntime
      try FileManager.default.createDirectory(
        atPath: configuration.stateDirectory,
        withIntermediateDirectories: true
      )
      stateLock = try EngineStateDirectoryLock(stateDirectory: configuration.stateDirectory)
      serialLog = try Self.openSerialLog(configuration.stateDirectory + "/serial.log")
      executionProfilingEnabled = configuration.environment["DORY_PC_PROFILE_EXECUTION"] == "1"
      executionProfileWriter = try executionProfilingEnabled
        ? DoryPCExecutionProfileWriter(
            stateDirectory: configuration.stateDirectory,
            admittedEnvelope: envelope
          )
        : nil
      serialOutput = try BoundedSerialConsolePublisher(destinations: [
        .init(fileHandle: FileHandle.standardError),
        .init(fileHandle: serialLog, synchronizeOnStop: true),
      ])

      let networkRuntime: DoryPCGVProxyNetworkBackend?
      let networkBackend: any DoryVirtioNetworkBackend
      switch devices.networkAttachment {
      case .disconnected:
        networkRuntime = nil
        networkBackend = DoryVirtioInMemoryNetworkBackend()
      case .sharedNAT, .isolated:
        guard let interface = devices.networkInterface else {
          throw VMError.invalidConfiguration("DoryPC network identity is missing")
        }
        guard
          let runtimeDirectory = DoryPCMode.ephemeralRuntimeDirectory(
            controlSocketPath: configuration.controlSocketPath
          )
        else {
          throw VMError.invalidConfiguration(
            "DoryPC lifecycle socket does not identify a runtime directory"
          )
        }
        let connected = try DoryPCGVProxyNetworkBackend(
          gvproxyPath: configuration.gvproxyPath,
          stateDirectory: runtimeDirectory,
          attachment: devices.networkAttachment,
          interface: interface,
          portForwards: envelope.portForwards
        )
        networkRuntime = connected
        networkBackend = connected
      case .bridged:
        throw VMError.invalidConfiguration("DoryPC bridged networking is not admitted")
      }
      self.networkRuntime = networkRuntime
      self.networkBackend = networkBackend

      let displayRelaySlot = DoryVMDisplayRunnerRelaySlot()
      self.displayRelaySlot = displayRelaySlot
      let hasDisplay = !devices.displays.isEmpty
      let displayCount = devices.dynamicDisplay ? 16 : devices.displays.count
      let usesDisplayRelay = configuration.displayRelayServiceName != nil
      let mailbox = hasDisplay && !usesDisplayRelay
        ? DesktopFrameMailbox(scanoutID: 0) : nil
      self.mailbox = mailbox
      let cursorMailbox = hasDisplay && !usesDisplayRelay ? DesktopCursorMailbox() : nil
      self.cursorMailbox = cursorMailbox
      let readyRendererWorkerLaunchStore = rendererWorkerLaunchStore
      let initialGraphicsSelection: DoryRuntimeGraphicsSelection?
      switch envelope.graphics {
      case .software:
        initialGraphicsSelection = DoryRuntimeGraphicsSelection.resolvedSoftware(
          operationID: envelope.operationID,
          resolvedPlanSHA256: envelope.resolvedPlanSHA256,
          planRevision: envelope.planRevision
        )
      case .hardwareAccelerated3D:
        guard let rendererWorkerLaunch else {
          throw VMError.invalidConfiguration(
            "DoryPC accelerated readiness is missing renderer authority"
          )
        }
        initialGraphicsSelection = try DoryPCMode.acceleratedRuntimeGraphicsSelection(
          operationID: envelope.operationID,
          resolvedPlanSHA256: envelope.resolvedPlanSHA256,
          planRevision: envelope.planRevision,
          producerFenceContract: envelope.rendererProducerFenceContract,
          workerGeneration: rendererWorkerLaunch.workerGeneration.rawValue,
          rendererWorkerReceiptSHA256: rendererWorkerLaunch.rendererWorkerReceiptSHA256
        )
      case .none:
        initialGraphicsSelection = nil
      case .hostAcceleratedDisplay:
        throw VMError.invalidConfiguration(
          "DoryPC host-accelerated display is not admitted"
        )
      }
      let handoffSocketPath = configuration.handoffSocketPath
      let graphicsReadinessState = DesktopRuntimeGraphicsReadinessState(
        selection: initialGraphicsSelection,
        sender: { ready in
          try VmmHandoffClient.send(
            path: handoffSocketPath,
            ready: ready
          )
        },
        renewalFailureHandler: { error in
          Self.log("DoryPC graphics readiness renewal failed: \(error)")
        }
      )
      self.graphicsReadinessState = graphicsReadinessState
      let readyPublisher = DoryPCRendererReadyPublisher(
        // DoryPC-v1 boots user-supplied Linux media. The VirtIO display is part of the
        // machine contract, but a Dory guest agent is not. Agent-backed conveniences may
        // come online after boot; they cannot prevent a valid generic installation from
        // publishing readiness or completing its first disk-boot proof.
        requiresGuestServices: false,
        requiresRendererPresentation: rendererWorkerLaunch != nil
      ) { admittedRendererGeneration, guestMachineEpoch in
        if envelope.graphics == .hardwareAccelerated3D {
          guard let rendererGeneration = admittedRendererGeneration,
            readyRendererWorkerLaunchStore.current(
              matchingWorkerGeneration: rendererGeneration
            ) != nil,
            graphicsReadinessState.snapshot?.rendererGeneration == rendererGeneration
          else {
            throw VMError.invalidConfiguration(
              "DoryPC accelerated readiness is missing renderer authority"
            )
          }
        }
        try graphicsReadinessState.publish(
          VmmReadyMessage(
            machineID: envelope.machineID,
            operationID: DoryOperationIdentity.canonical(envelope.operationID),
            controlSocketPath: configuration.controlSocketPath,
            detail: "DoryPC-v1 x86_64 Linux firmware has begun executing through DoryDBT"
          ),
          expectedGuestMachineEpoch: guestMachineEpoch
        )
      }
      self.readyPublisher = readyPublisher
      let firstFrameRelay = FirstFrameRelay()
      let displaySink: DoryPCSoftwareDisplaySink?
      if usesDisplayRelay {
        displaySink = hasDisplay
          ? DoryPCSoftwareDisplaySink(
              publishFrame: { [displayRelaySlot] in displayRelaySlot.publish($0) },
              releaseFrame: { [displayRelaySlot, rendererFailureRelay] resourceID, generation in
                guard displayRelaySlot.retireCPUResource(
                  resourceID: resourceID,
                  throughGeneration: generation
                ) else {
                  rendererFailureRelay.report("DoryPC CPU framebuffer retirement failed")
                  return
                }
              },
              publishCursor: { [displayRelaySlot, displayCount] in
                displayRelaySlot.publishCursor($0, scanoutCount: displayCount)
              },
              hideCursor: { [displayRelaySlot] in
                displayRelaySlot.publishHiddenCursor(scanoutID: $0)
              },
              onFirstFrame: { firstFrameRelay.deliver() }
            ) : nil
      } else {
        displaySink = mailbox.map { mailbox in
          DoryPCSoftwareDisplaySink(
            mailbox: mailbox,
            publishCursor: { [cursorMailbox] in cursorMailbox?.submit($0) },
            onFirstFrame: { firstFrameRelay.deliver() }
          )
        }
      }
      self.displaySink = displaySink
      if let mailbox, let displaySink {
        mailbox.installCPUFramePresentationObserver { [weak displaySink] frame in
          displaySink?.hostDidPresent(frame)
        }
      }
      let graphicsTraceWriter: DesktopGraphicsTraceWriter?
      if configuration.environment["DORY_GPU_TRACE_GRAPHICS"] == "1",
        rendererWorkerLaunch != nil
      {
        graphicsTraceWriter = try DesktopGraphicsTraceWriter(
          stateDirectory: configuration.stateDirectory
        )
        Self.log(
          "DoryPC graphics trace enabled at \(configuration.stateDirectory)/graphics-trace.ndjson"
        )
      } else {
        graphicsTraceWriter = nil
        if configuration.environment["DORY_GPU_TRACE_GRAPHICS"] == "1" {
          Self.log("DoryPC graphics trace requested without an admitted renderer worker")
        }
      }
      let graphicsTraceContext: VirtioGPUGraphicsTraceContext?
      let onGraphicsTrace: (@Sendable (VirtioGPUGraphicsTraceEvent) -> Void)?
      if let graphicsTraceWriter, let rendererWorkerLaunch {
        graphicsTraceContext = VirtioGPUGraphicsTraceContext(
          machineID: envelope.machineID,
          operationID: DoryOperationIdentity.canonical(envelope.operationID),
          workerGeneration: rendererWorkerLaunch.workerGeneration.rawValue
        )
        onGraphicsTrace = { event in graphicsTraceWriter.record(event) }
      } else {
        graphicsTraceContext = nil
        onGraphicsTrace = nil
      }
      let gpuAccelerationAuthority = try DoryPCMode.admitRequiredGPUAcceleration(
        graphics: envelope.graphics,
        hasDisplay: hasDisplay
      ) { () -> DoryPCVirGLRendererAuthority in
        guard let rendererWorkerLaunch, hasDisplay else {
          throw VMError.invalidConfiguration(
            "DoryPC accelerated graphics requires the signed renderer authority"
          )
        }
        return try DoryPCVirGLRendererAuthority(
          lane: rendererWorkerLaunch.commandLane,
          deviceGeneration: DesktopRendererWorkerLaunch.initialDeviceGeneration,
          scanoutSink: { [mailbox, displayRelaySlot, firstFrameRelay] update in
            if usesDisplayRelay {
              guard displayRelaySlot.publish(update) else { return false }
            } else {
              guard mailbox?.submit(update) == true else { return false }
            }
            firstFrameRelay.deliver()
            return true
          },
          onWorkerUnavailable: { [rendererWorkerLossRelay] workerGeneration in
            rendererWorkerLossRelay.report(workerGeneration)
          },
          onVenusFenceVerification: { [graphicsReadinessState] workerGeneration, outcome in
            switch outcome {
            case .verified:
              graphicsReadinessState.apply(outcome, workerGeneration: workerGeneration)
            case .violated:
              graphicsReadinessState.publishRuntimeDetail(
                "DoryPC guest producer fence arrived after scanout; renderer revoked."
              )
            }
          },
          graphicsTraceContext: graphicsTraceContext,
          onGraphicsTrace: onGraphicsTrace
        )
      }
      self.gpuAccelerationAuthority = gpuAccelerationAuthority
      faultController?.connectRendererCrashHandler { [weak gpuAccelerationAuthority, weak faultController] admission in
        guard let gpuAccelerationAuthority else {
          throw DoryRuntimeQualificationFaultError.unauthorized
        }
        try gpuAccelerationAuthority.requestQualificationRendererCrash(
          admission,
          acknowledgement: { [weak faultController] accepted, count in
            faultController?.rendererCrashAcknowledged(
              challenge: admission.challenge, workerGeneration: admission.workerGeneration,
              accepted: accepted, inFlightCommands: count
            )
          },
          interrupted: { [weak faultController] in
            faultController?.rendererWorkerInterrupted(
              challenge: admission.challenge, workerGeneration: admission.workerGeneration
            )
          }
        )
      }
      let gpuHostVisibleAperture = try gpuAccelerationAuthority?
        .makeHostVisibleAperture()
      self.gpuHostVisibleAperture = gpuHostVisibleAperture
      let audioBackend =
        devices.audioInput || devices.audioOutput
        ? DoryPCMacAudioBackend { message in
          FileHandle.standardError.write(
            Data("dory-hv DoryPC audio: \(message)\n".utf8)
          )
        } : nil
      self.audioBackend = audioBackend
      let vsock = VirtioVsock(guestCID: 3)
      self.vsock = vsock
      let vsockPCI = try DoryPCVirtioVsockPCIDevice(
        address: DoryPCV1ABI.vsockPCIAddress,
        initialBARAddress: DoryPCV1ABI.vsockBARAddress,
        vsock: vsock
      )
      let filesystemFunctions = try filesystemRuntime?.start() ?? []
      let machine = try configuration.authority.makeMachine(
        displaySink: displaySink,
        gpuAccelerationAuthority: gpuAccelerationAuthority,
        gpuHostVisibleAperture: gpuHostVisibleAperture,
        soundBackend: audioBackend ?? DoryVirtioInMemorySoundBackend(),
        networkBackend: networkBackend,
        additionalPCIFunctions: [vsockPCI] + filesystemFunctions,
        instrumentationEnabled: executionProfilingEnabled
      )
      if devices.networkAttachment == .disconnected {
        _ = machine.networkDevice.setLinkUp(false)
      }
      let dynamicDisplayModes =
        devices.dynamicDisplay
        ? Array(machine.displayDevice.gpuDevice.scanouts.prefix(devices.displays.count))
          .map(\.displayMode)
        : nil
      machineState = MachineState(
        machine: machine,
        dynamicDisplayModes: dynamicDisplayModes
      )
      filesystemFailureRelay.installStop { [machineState] in
        machineState.current().machine.powerController.request(.powerOff)
      }
      rendererFailureRelay.installStop { [machineState] in
        let current = machineState.current()
        current.displayDevice.gpuDevice.reset()
        current.machine.powerController.request(.powerOff)
      }
      let keyboardInput = DoryPCDesktopInputSink(device: machine.keyboardDevice)
      self.keyboardInput = keyboardInput
      pointerInput = DoryPCDesktopInputSink(device: machine.tabletDevice)
      relativePointerInput = DoryPCDesktopInputSink(device: machine.pointerDevice)
      let agentBridge = GuestVsockSocketBridge(
        socketPath: configuration.agentSocketPath,
        guestPort: VsockPorts.agent,
        service: .agentSocket,
        log: Self.log
      )
      let shellBridge = GuestVsockSocketBridge(
        socketPath: configuration.shellSocketPath,
        guestPort: 1_027,
        service: .shell,
        log: Self.log
      )
      try agentBridge.attach(to: vsock)
      do {
        try shellBridge.attach(to: vsock)
      } catch {
        agentBridge.stop()
        throw error
      }
      self.agentBridge = agentBridge
      self.shellBridge = shellBridge
      if let socketPath = configuration.sshAgentSocketPath {
        do {
          let bridge = try HostSSHAgentBridge(socketPath: socketPath, log: Self.log)
          try bridge.attach(to: vsock)
          sshAgentBridge = bridge
        } catch {
          agentBridge.stop()
          shellBridge.stop()
          throw error
        }
      } else {
        sshAgentBridge = nil
      }
      let clipboardFocus = self.clipboardFocus
      clipboard = clipboardPolicy.map { policy in
        let control = DorydKit.AgentControl(
          configuration: .init(
            directSocketPath: configuration.agentSocketPath
          ))
        return DoryDesktopClipboardCoordinator(
          policy: policy,
          transport: DoryDesktopClipboardTransport(
            availability: { try control.clipboardAvailable() },
            get: { try control.clipboardGet(mimeType: $0) },
            set: { try control.clipboardSet(mimeType: $0, data: $1) }
          ),
          focusLease: clipboardFocus,
          sendShortcut: { keyCode in
            keyboardInput.send(frame: [
              .init(type: 1, code: 125, value: 0),
              .init(type: 1, code: 126, value: 0),
              .init(type: 1, code: 29, value: 1),
              .init(type: 1, code: keyCode, value: 1),
              .init(type: 1, code: keyCode, value: 0),
              .init(type: 1, code: 29, value: 0),
            ])
          },
          log: Self.log
        )
      }
      if devices.removableUSBHotplug {
        guard let socketPath = configuration.usbControlSocketPath else {
          throw VMError.invalidConfiguration(
            "DoryPC removable USB hotplug requires an admitted control socket"
          )
        }
        let handler = DoryPCUSBControlHandler(
          controller: machine.xhciController,
          machineID: envelope.machineID
        )
        usbControlHandler = handler
        usbControlServer = UsbControlServer(path: socketPath, handler: handler)
      } else {
        guard configuration.usbControlSocketPath == nil else {
          throw VMError.invalidConfiguration(
            "DoryPC USB control socket is not authorized by the device contract"
          )
        }
        usbControlHandler = nil
        usbControlServer = nil
      }
      cameraBridge = try DoryPCMode.admitRequiredHostDevice(
        requested: devices.cameraInput
      ) {
        let bridge = try DoryPCCameraBridge { message in
          FileHandle.standardError.write(
            Data("dory-hv DoryPC camera: \(message)\n".utf8)
          )
        }
        try bridge.attach(to: machine.xhciController)
        return bridge
      }
      serialInput = try RawHVSerialConsoleInput(
        socketPath: configuration.consoleSocketPath,
        receive: { [machineState] bytes in
          machineState.current().machine.serial.enqueueReceivedBytes(bytes)
          return true
        }
      )
      let telemetrySampler = DoryPCDeviceTelemetrySampler(
        machineID: envelope.machineID,
        operationID: envelope.operationID
      ) { [machineState, displaySink] in
        let current = machineState.current()
        return .init(
          execution: current.machine.executionStatistics,
          graphics: current.displayDevice.gpuDevice.commandDiagnostics,
          display: displaySink?.metrics
        )
      }
      let faultHandler: (@Sendable (DoryRuntimeQualificationFaultRequest) throws
        -> DoryRuntimeQualificationFaultObservation)?
      if let faultController {
        faultHandler = { [machineState] request in
          if request.action == .arm {
            guard !machineState.isStopping, machineState.executionPause.state == .running,
              request.kind == .rendererWorkerCrash
            else { throw DoryRuntimeQualificationFaultError.unauthorized }
          }
          return try faultController.handle(request)
        }
      } else { faultHandler = nil }
      lifecycleServer = VmmLifecycleReceiptServer(
        socketPath: configuration.controlSocketPath,
        deviceTelemetryProvider: { telemetrySampler.snapshot() },
        lifecycleHandler: { [networkRuntime, faultController] action in
          if action == .prepareStop {
            faultController?.suspendRendererCrashArming(permanently: true)
            networkRuntime?.stop()
          }
        },
        reconnectIdentity: configuration.reconnectIdentity,
        executionStateProvider: { [machineState] in machineState.executionPause.state },
        executionLifecycleHandler: { [machineState, faultController] action in
          if action == .preparePause {
            faultController?.suspendRendererCrashArming()
            try machineState.executionPause.pause()
          } else {
            try machineState.executionPause.resume()
            faultController?.resumeRendererCrashArming()
          }
        },
        qualificationFaultHandler: faultHandler
      )

      if let serviceName = configuration.displayRelayServiceName {
        guard hasDisplay else {
          throw VMError.invalidConfiguration(
            "DoryPC display relay requires an admitted display"
          )
        }
        let relay = DoryVMDisplayRunnerRelay.connect(
          machineID: envelope.machineID,
          operationID: envelope.operationID,
          serviceName: serviceName,
          commandHandler: DoryVMDisplayRunnerCommandHandler(
            input: { [keyboardInput, pointerInput, relativePointerInput] endpoint, events in
              switch endpoint {
              case .keyboard: keyboardInput.submit(frame: events)
              case .absolutePointer: pointerInput.submit(frame: events)
              case .relativePointer: relativePointerInput.submit(frame: events)
              }
            },
            resize: { [machineState] scanoutID, width, height, physicalWidth, physicalHeight in
              machineState.updateDisplaySize(
                scanoutID: scanoutID,
                width: width,
                height: height,
                physicalWidthMillimeters: physicalWidth,
                physicalHeightMillimeters: physicalHeight
              )
            },
            topology: { [machineState] displays in
              machineState.updateDisplayTopology(
                displays.map {
                  DoryVirtioGPUDisplayMode(
                    width: $0.width,
                    height: $0.height,
                    physicalWidthMillimeters: $0.physicalWidthMillimeters,
                    physicalHeightMillimeters: $0.physicalHeightMillimeters
                  )
                }
              )
            },
            restartGraphics: { [machineState, gpuAccelerationAuthority, rendererReplacementProvider = configuration.rendererReplacementProvider] in
              DoryPCMode.requestRendererRestart(
                transport: machineState.current().displayDevice.transport,
                authority: gpuAccelerationAuthority,
                replacementAvailable: rendererReplacementProvider != nil,
                stopping: machineState.isStopping
              )
            },
            focus: { [clipboardFocus] in
              clipboardFocus.update(leaseID: $0, active: $1, expiresAtUptimeNanoseconds: $2)
            },
            revokeFocus: { [clipboardFocus] in clipboardFocus.invalidate() },
            releaseInput: { [keyboardInput, pointerInput, relativePointerInput] in
              keyboardInput.releaseAllPressedKeys()
              pointerInput.releaseAllPressedKeys()
              relativePointerInput.releaseAllPressedKeys()
            }
          ),
          onPresentationCompleted: {
            [readyPublisher, graphicsReadinessState, rendererWorkerLaunchStore,
             gpuAccelerationAuthority, machineState]
            workerGeneration, _ in
            do {
              guard let launch = rendererWorkerLaunchStore.current(
                matchingWorkerGeneration: workerGeneration
              ) else { return }
              launch.recordSynchronizedPresentation(
                workerGeneration: workerGeneration
              )
              try launch.claimSynchronizedPresentationForPublication()
              graphicsReadinessState.recordFirstPresentationCompletion(
                workerGeneration: workerGeneration
              )
              try readyPublisher.markRendererPresentationReady(
                workerGeneration: workerGeneration
              )
            } catch {
              DesktopAppRunLoop.perform {
                Self.handleWorkerPresentationFailure(
                  workerGeneration: workerGeneration,
                  reason: "app-owned display failed closed: \(error)",
                  rendererWorkerLaunchStore: rendererWorkerLaunchStore,
                  gpuAccelerationAuthority: gpuAccelerationAuthority,
                  machineState: machineState
                )
              }
            }
          },
          onPresentationFailed: {
            [rendererWorkerLaunchStore, gpuAccelerationAuthority, machineState]
            workerGeneration, reason in
            DesktopAppRunLoop.perform {
              Self.handleWorkerPresentationFailure(
                workerGeneration: workerGeneration,
                reason: "app-owned display rejected frame: \(reason)",
                rendererWorkerLaunchStore: rendererWorkerLaunchStore,
                gpuAccelerationAuthority: gpuAccelerationAuthority,
                machineState: machineState
              )
            }
          },
          onCPUPresentationCompleted: { [weak displaySink] completion in
            displaySink?.hostDidPresent(
              resourceID: completion.resourceID,
              resourceGeneration: completion.resourceGeneration,
              visibleContent: completion.visibleContent
            )
          },
          log: Self.log
        )
        displayRelaySlot.install(relay)
      }

      if let display = devices.displays.first, let mailbox {
        let scale = max(1, CGFloat(display.backingScaleFactor))
        let size = NSSize(
          width: CGFloat(display.widthPixels) / scale,
          height: CGFloat(display.heightPixels) / scale
        )
        let view = try DesktopMetalView(
          frame: NSRect(origin: .zero, size: size),
          keyboardInput: keyboardInput,
          pointerInput: pointerInput,
          relativePointerInput: relativePointerInput,
          guestBackingScaleFactor: scale,
          scanoutID: 0
        )
        if devices.dynamicDisplay {
          view.onDrawableSizeChange = {
            [machineState] width, height, physicalWidth, physicalHeight in
            _ = machineState.updateDisplaySize(
              scanoutID: 0,
              width: width,
              height: height,
              physicalWidthMillimeters: physicalWidth,
              physicalHeightMillimeters: physicalHeight
            )
          }
        }
        view.onMacShortcut = { [weak clipboard] event in
          clipboard?.handleMacShortcut(event) ?? false
        }
        if rendererWorkerLaunch != nil {
          view.onDeviceFailure = {
            [
              rendererFailureRelay,
              weak machineState,
              rendererWorkerLaunchStore,
            ] reason in
            let rendererWorkerLaunch = rendererWorkerLaunchStore.current()
            rendererWorkerLaunch?.failSynchronizedPresentation(reason)
            rendererFailureRelay.report("Metal display failed closed: \(reason)")
            rendererWorkerLaunch?.teardown(reason: reason)
            machineState?.current().machine.powerController.request(.powerOff)
          }
          view.onWorkerPresentationFailed = {
            [
              gpuAccelerationAuthority,
              machineState,
              rendererWorkerLaunchStore,
            ] workerGeneration, reason in
            DesktopAppRunLoop.perform {
              Self.handleWorkerPresentationFailure(
                workerGeneration: workerGeneration,
                reason: "Metal display failed closed: \(reason)",
                rendererWorkerLaunchStore: rendererWorkerLaunchStore,
                gpuAccelerationAuthority: gpuAccelerationAuthority,
                machineState: machineState
              )
            }
          }
          view.onWorkerPresentationCompleted = {
            [
              gpuAccelerationAuthority,
              readyPublisher,
              graphicsReadinessState,
              rendererWorkerLaunchStore,
              machineState,
            ] workerGeneration in
            do {
              guard
                let rendererWorkerLaunch =
                  rendererWorkerLaunchStore
                  .current(matchingWorkerGeneration: workerGeneration)
              else {
                return
              }
              rendererWorkerLaunch.recordSynchronizedPresentation(
                workerGeneration: workerGeneration
              )
              try rendererWorkerLaunch
                .claimSynchronizedPresentationForPublication()
              graphicsReadinessState.recordFirstPresentationCompletion(
                workerGeneration: workerGeneration
              )
              try readyPublisher.markRendererPresentationReady(
                workerGeneration: workerGeneration
              )
            } catch {
              DesktopAppRunLoop.perform {
                Self.handleWorkerPresentationFailure(
                  workerGeneration: workerGeneration,
                  reason: "renderer presentation failed closed: \(error)",
                  rendererWorkerLaunchStore: rendererWorkerLaunchStore,
                  gpuAccelerationAuthority: gpuAccelerationAuthority,
                  machineState: machineState
                )
              }
            }
          }
        }
        mailbox.view = view
        cursorMailbox?.view = view
        let window = NSWindow(
          contentRect: NSRect(origin: .zero, size: size),
          styleMask: [.titled, .closable, .miniaturizable, .resizable],
          backing: .buffered,
          defer: false
        )
        window.title = "\(envelope.machineID) — Dory Desktop"
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.autoresizesSubviews = true
        view.frame = content.bounds
        view.autoresizingMask = [.width, .height]
        content.addSubview(view)

        let startup = Self.makeStartupOverlay(frame: content.bounds)
        content.addSubview(startup)
        firstFrameRelay.install { [weak startup, weak window] in
          DesktopAppRunLoop.perform {
            startup?.removeFromSuperview()
            window?.title = "\(envelope.machineID) — Dory Desktop"
          }
        }
        window.title = "\(envelope.machineID) — Starting x86_64 Linux"
        window.contentView = content
        window.minSize = NSSize(width: 640, height: 400)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.tabbingMode = .disallowed
        window.center()
        self.window = window
      } else {
        window = nil
      }
      super.init()
      if configuration.displayRelayServiceName == nil {
        clipboard?.observeLocalDisplayFocus { [weak self] in
          guard let self, NSApp.isActive, let window = self.window,
                window.isKeyWindow, let view = self.mailbox?.view else { return false }
          return window.firstResponder === view
        }
      }
      rendererWorkerLossRelay.install { [weak self] in self?.handleWorkerUnavailable($0) }
      installGPUResetObserver(machine.displayDevice)
      window?.delegate = self
      clipboard?.start()
    }

    func run() throws {
      defer { cleanup() }
      try usbControlServer?.start()
      try lifecycleServer.start()
      displayRelaySlot.start()
      DoryDesktopApplicationIdentity.install(on: application)
      application.setActivationPolicy(window == nil ? .accessory : .regular)
      application.delegate = self
      try installSignals()
      window?.makeKeyAndOrderFront(nil)
      if window != nil { application.activate() }
      startExecution()
      startGuestServicePreparation()
      application.run()
      if let stopError { throw stopError }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
      requestGuestShutdown()
      return false
    }

    func windowDidResignKey(_ notification: Notification) {
      mailbox?.view?.releasePressedInput()
    }

    func applicationDidResignActive(_ notification: Notification) {
      mailbox?.view?.releasePressedInput()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
      // On hosts where audit-token Unix signalling is unavailable, daemon termination
      // reaches an admitted desktop runner through NSRunningApplication.terminate(). AppKit
      // invokes this delegate instead of the DispatchSource SIGTERM path, then the daemon's
      // bounded stop eventually force-terminates the app. Retire the runner-owned child now
      // so that cancellation of the AppKit quit cannot strand gvproxy under launchd.
      networkRuntime?.stop()
      requestGuestShutdown()
      return .terminateCancel
    }

    private func startExecution() {
      let thread = Thread { [weak self] in self?.execute() }
      thread.name = "dev.dory.dory-hv.dorypc.execution"
      thread.qualityOfService = RawHVSchedulingPolicy.machineOwnerThreadQualityOfService
      thread.stackSize = RawHVSchedulingPolicy.machineOwnerThreadStackSize
      executionThread = thread
      thread.start()
    }

    private func startGuestServicePreparation() {
      let devices = configuration.envelope.devices
      guard devices.clipboard || devices.clockSynchronization || devices.directorySharing
      else { return }
      let installerIsFirst =
        configuration.envelope.launchPlan.bootOrder.first.flatMap {
          firstID in
          configuration.envelope.launchPlan.bootDevices.first {
            $0.logicalID == firstID
          }?.kind
        } == .removableMedia
      guard !installerIsFirst else {
        Self.log("installer guest services are deferred until the installed guest boots")
        return
      }
      let agentSocketPath = configuration.agentSocketPath
      let readyPublisher = self.readyPublisher
      let clipboard = self.clipboard
      let machineState = self.machineState
      let directoryShares = configuration.shares
      guestServiceQueue.async {
        let clock = ContinuousClock()
        let startedAt = clock.now
        var reportedUnavailable = false
        while !machineState.isStopping {
          do {
            let control = DorydKit.AgentControl(
              configuration: .init(
                directSocketPath: agentSocketPath
              ))
            defer { control.disconnect() }
            let info = try control.info()
            guard info.protocolVersion == DoryCore.protocolVersion(),
              info.capabilitiesAreCanonical
            else {
              throw VMError.bootFailure(
                "DoryPC guest agent protocol identity is incompatible"
              )
            }
            if devices.clockSynchronization {
              guard info.supports("clock-sync", minimumVersion: 1),
                try control.clockSync()
              else {
                throw VMError.bootFailure(
                  "DoryPC guest declined clock synchronization"
                )
              }
            }
            if devices.clipboard {
              guard info.supports("clipboard", minimumVersion: 1),
                try control.clipboardAvailable()
              else {
                throw VMError.bootFailure(
                  "DoryPC guest lacks clipboard RPC capabilities"
                )
              }
            }
            if devices.directorySharing {
              guard info.supports("virtiofs-mount", minimumVersion: 1) else {
                throw VMError.bootFailure(
                  "DoryPC guest lacks virtio-fs mount capability"
                )
              }
              for share in directoryShares {
                _ = try control.virtioFSMount(
                  tag: share.tag,
                  mountPath: share.guestPath,
                  readOnly: share.readOnly
                )
              }
            }
            if let clipboard {
              DesktopAppRunLoop.perform { clipboard.markGuestReady() }
            }
            try readyPublisher.markGuestServicesReady()
            Self.log("requested guest services are ready")
            return
          } catch {
            guard !machineState.isStopping else { return }
            if !reportedUnavailable, clock.now - startedAt >= .seconds(90) {
              reportedUnavailable = true
              Self.log(
                "optional guest services are unavailable; retrying while the VM runs: \(error)"
              )
            }
            // Translated kernels and freshly installed tools can become ready well
            // after the initial boot window. Back off without abandoning integration,
            // and let shutdown interrupt the wait between RPC attempts.
            let retryAt = clock.now.advanced(
              by: reportedUnavailable ? .seconds(5) : .milliseconds(250)
            )
            while !machineState.isStopping, clock.now < retryAt {
              Thread.sleep(forTimeInterval: 0.25)
            }
          }
        }
      }
    }

    private nonisolated func execute() {
      var observedMachine: DoryPCDirectKernelMachine?
      var bootTimeline: DoryPCBootTimeline?
      var publishedTimelineEvents = 0
      var machineSequence: UInt64 = 0
      func publishTimeline() {
        guard let bootTimeline,
          let bytes = try? JSONEncoder().encode(bootTimeline.snapshot()),
          let text = String(data: bytes, encoding: .utf8)
        else { return }
        Self.log("boot timeline \(text)")
      }
      defer {
        bootTimeline?.finish(reason: "execution-loop-ended")
        publishTimeline()
        if let observedMachine, let executionProfileWriter {
          do {
            try executionProfileWriter.record(
              reason: .executionEnded,
              machineSequence: machineSequence,
              machine: observedMachine,
              bootTimeline: bootTimeline?.snapshot()
            )
          } catch {
            Self.log("DoryPC execution profile final sample failed: \(error)")
          }
        }
        observedMachine?.serial.observeBoot(with: nil)
      }
      let progressLogIntervalNanoseconds: UInt64 = 30_000_000_000
      var nextProgressLogNanoseconds =
        DispatchTime.now().uptimeNanoseconds
        &+ progressLogIntervalNanoseconds
      var publishedExecutionReadiness = false
      do {
        while try machineState.executionPause.enter(participant: 0) {
          defer { machineState.executionPause.leave(participant: 0) }
          let composed = machineState.current()
          if observedMachine !== composed.machine {
            bootTimeline?.finish(reason: "machine-replaced")
            publishTimeline()
            if let observedMachine {
              try executionProfileWriter?.record(
                reason: .machineReplaced,
                machineSequence: machineSequence,
                machine: observedMachine,
                bootTimeline: bootTimeline?.snapshot()
              )
            }
            observedMachine?.serial.observeBoot(with: nil)
            guard machineSequence < .max else {
              throw VMError.bootFailure("DoryPC execution profile machine sequence exhausted")
            }
            machineSequence += 1
            observedMachine = composed.machine
            bootTimeline = DoryPCBootTimeline()
            composed.machine.serial.observeBoot(with: bootTimeline)
            publishedTimelineEvents = 1
            publishTimeline()
            try executionProfileWriter?.record(
              reason: .machineStarted,
              machineSequence: machineSequence,
              machine: composed.machine,
              bootTimeline: bootTimeline?.snapshot()
            )
          }
          let stop = try composed.machine.run(
            maximumInstructions: 250_000,
            exceptionPolicy: .deliver
          )
          if !publishedExecutionReadiness {
            // Runner admission alone is not guest readiness. Publish only after the
            // machine has completed an execution slice, proving that reset-state,
            // firmware fetch, translation, and lifecycle supervision are live. Pixel
            // readiness remains a separate host-presentation boundary.
            try readyPublisher.markPresentationReady()
            publishedExecutionReadiness = true
          }
          for byte in composed.machine.serial.drainTransmittedBytes() {
            serialOutput.enqueue(byte)
          }
          if let count = bootTimeline?.snapshot().events.count, count > publishedTimelineEvents {
            publishedTimelineEvents = count
            publishTimeline()
            try executionProfileWriter?.record(
              reason: .bootMilestone,
              machineSequence: machineSequence,
              machine: composed.machine,
              bootTimeline: bootTimeline?.snapshot()
            )
          }
          let now = DispatchTime.now().uptimeNanoseconds
          if now >= nextProgressLogNanoseconds {
            let statistics = composed.machine.executionStatistics
            Self.log(
              "execution progress interpreter=\(statistics.interpreterInstructions) "
                + "baseline=\(statistics.baselineJITInstructions) "
                + "optimizing=\(statistics.optimizingJITInstructions) "
                + "maskable-interrupts=\(statistics.deliveredMaskableInterrupts) "
                + "nmi-interrupts=\(statistics.deliveredNonMaskableInterrupts) "
                + "iret=\(statistics.retiredInterruptReturns) "
                + "interrupt-vectors=[\(Self.interruptVectorProgress(statistics.deliveredInterruptVectors))]"
            )
            if let diagnostics = composed.machine.baselineJITDiagnostics {
              Self.log(Self.jitProgress("baseline", diagnostics))
            }
            if let diagnostics = composed.machine.optimizingJITDiagnostics {
              Self.log(Self.jitProgress("optimizing", diagnostics))
            }
            Self.log(Self.machineExecutionProgress(composed))
            Self.log(Self.blockDeviceProgress(composed))
            try executionProfileWriter?.record(
              reason: .periodic,
              machineSequence: machineSequence,
              machine: composed.machine,
              bootTimeline: bootTimeline?.snapshot()
            )
            nextProgressLogNanoseconds = now &+ progressLogIntervalNanoseconds
          }
          switch stop {
          case .instructionBudget:
            continue
          case .reset:
            guard !machineState.isStopping else {
              finish(nil)
              return
            }
            qualificationFaultController?.cancelPending()
            rendererMachineResetHandoff.begin()
            guard displayRelaySlot.resetCPUFrames() else {
              throw VMError.bootFailure(
                "DoryPC guest reset could not retire the previous boot's display frames"
              )
            }
            mailbox?.disable()
            for scanout in composed.displayDevice.gpuDevice.scanouts {
              displaySink?.presentCursor(.hidden(scanoutID: scanout.id))
            }
            // An ACPI reset may arrive without guest status-zero writes. Retire both GPU and
            // PCI queues so a pending renderer replacement cannot replay the old boot's chains.
            readyPublisher.prepareGuestMachineReset()
            publishedExecutionReadiness = false
            graphicsReadinessState.prepareGuestMachineReset()
            try composed.displayDevice.transport.writeBAR(offset: 0x14, bytes: [0])
            displaySink?.resetResources()
            audioBackend?.reset()
            vsock.resetTransportNeutralDevice()
            let vsockPCI = try DoryPCVirtioVsockPCIDevice(
              address: DoryPCV1ABI.vsockPCIAddress,
              initialBARAddress: DoryPCV1ABI.vsockBARAddress,
              vsock: vsock
            )
            let filesystemFunctions =
              try filesystemRuntime?
              .replaceAfterMachineReset() ?? []
            if let gpuAccelerationAuthority,
              !gpuAccelerationAuthority.canBackReplacementMachineAfterReset
            {
              guard let rendererReplacementProvider,
                let previousRendererWorkerLaunch = rendererWorkerLaunchStore.replacementSource()
              else {
                throw VMError.bootFailure(
                  "DoryPC accelerated graphics reset revoked the renderer worker; a fresh signed renderer generation is required"
                )
              }
              scheduleRendererReplacementReset(
                provider: rendererReplacementProvider,
                previousLaunch: previousRendererWorkerLaunch,
                gpuAccelerationAuthority: gpuAccelerationAuthority,
                previousDisplayDevice: composed.displayDevice,
                vsockPCI: vsockPCI,
                filesystemFunctions: filesystemFunctions
              )
              return
            }
            rendererMachineResetHandoff.clear()
            let replacement = try configuration.authority.makeMachine(
              displaySink: displaySink,
              gpuAccelerationAuthority: gpuAccelerationAuthority,
              gpuHostVisibleAperture: gpuHostVisibleAperture,
              soundBackend: audioBackend
                ?? DoryVirtioInMemorySoundBackend(),
              networkBackend: networkBackend,
              additionalPCIFunctions: [vsockPCI] + filesystemFunctions,
              instrumentationEnabled: executionProfilingEnabled
            )
            guard try installReplacementMachine(replacement) else { return }
          case .poweredOff:
            if let failure = filesystemFailureRelay.failure
              ?? rendererFailureRelay.failure
            {
              throw VMError.bootFailure(failure)
            }
            finish(nil)
            return
          case .halted(let count):
            throw VMError.bootFailure(
              "DoryPC halted without a pending wake source after \(count) instructions"
            )
          case .exception(let exception, let count):
            throw VMError.bootFailure(
              "DoryPC stopped on unhandled \(exception) after \(count) instructions"
            )
          case .tripleFault(let source, let count):
            let sourceDetail: String
            switch source {
            case .exception(let evidence):
              let state = evidence.state
              let faultLinearRIP =
                evidence.executionMode == .long64
                ? evidence.exception.instructionPointer
                : state.cs.base &+ evidence.exception.instructionPointer
              let faultRIP = String(faultLinearRIP, radix: 16)
              let codeSegment = String(state.cs.selector, radix: 16)
              let bytes = evidence.instructionBytes.map {
                String(format: "%02x", $0)
              }.joined(separator: " ")
              sourceDetail =
                "exception=\(evidence.exception.kind) "
                + "vector=\(evidence.exception.vector) "
                + "processor=\(evidence.processor) "
                + "mode=\(evidence.executionMode.rawValue) "
                + "fault-rip=0x\(faultRIP) cs=0x\(codeSegment) "
                + "bytes=[\(bytes)]"
            case .interrupt(let vector, let interruptSource, let processor):
              sourceDetail =
                "interrupt=\(vector) source=\(interruptSource) "
                + "processor=\(processor)"
            }
            let state = composed.machine.state
            let statistics = composed.machine.executionStatistics
            let detail =
              state.map {
                let rip = String($0.cs.base &+ $0.rip, radix: 16)
                let cr0 = String($0.control.cr0, radix: 16)
                let cr3 = String($0.control.cr3, radix: 16)
                let cr4 = String($0.control.cr4, radix: 16)
                let efer = String($0.control.efer, radix: 16)
                return "rip=0x\(rip) cr0=0x\(cr0) cr3=0x\(cr3) "
                  + "cr4=0x\(cr4) efer=0x\(efer)"
              } ?? "architectural-state=unavailable"
            throw VMError.bootFailure(
              "DoryPC triple-faulted from \(sourceDetail) "
                + "after \(count) instructions; "
                + "\(detail); interpreter=\(statistics.interpreterInstructions) "
                + "baseline=\(statistics.baselineJITInstructions) "
                + "optimizing=\(statistics.optimizingJITInstructions)"
            )
          }
        }
        finish(nil)
      } catch {
        finish(error)
      }
    }

    private nonisolated func scheduleRendererReplacementReset(
      provider: DesktopRendererWorkerReplacementProvider,
      previousLaunch: DesktopRendererWorkerLaunch,
      gpuAccelerationAuthority: DoryPCVirGLRendererAuthority,
      previousDisplayDevice: DoryPCVirtioGPUPCIDevice,
      vsockPCI: DoryPCVirtioVsockPCIDevice,
      filesystemFunctions: [any DoryPCPCIFunction]
    ) {
      rendererMachineResetHandoff.store(.init(
        previousDisplayDevice: previousDisplayDevice, vsock: vsockPCI, filesystem: filesystemFunctions
      ))
      DesktopAppRunLoop.perform { [weak self] in
        guard let self, !machineState.isStopping,
          machineState.current().displayDevice === previousDisplayDevice else { return }
        if gpuRendererReplacementTask != nil,
          rendererWorkerLaunchStore.replacementSource() === previousLaunch {
          // The daemon handoff is one-shot: do not request the same successor twice. The
          // pending completion now resumes a full guest reboot instead of replaying GPU queues.
          return
        }
        if gpuAccelerationAuthority.canBackReplacementMachineAfterReset {
          // GPU completion may precede this run-loop callback. That fresh worker has already
          // crossed the guest reset, so reuse it for the reboot without another daemon handoff.
          guard let reset = rendererMachineResetHandoff.take() else { return }
          do {
            try resumeMachineAfterRendererReset(reset, authority: gpuAccelerationAuthority)
          } catch { finish(error) }
          return
        }
        guard
          let ticket = rendererResetCoordinator.beginReset(
            previousLaunch: previousLaunch,
            launchStore: rendererWorkerLaunchStore
          )
        else {
          return
        }
        let complete: @MainActor @Sendable (Result<DesktopRendererWorkerLaunch, any Error>) -> Void = { [weak self] result in
          guard let self else {
            if case .success(let replacement) = result { replacement.teardown(reason: "PC owner released during machine reset") }
            return
          }
          guard rendererResetCoordinator.acceptsCompletion(ticket), !machineState.isStopping else {
            if case .success(let replacement) = result { replacement.teardown(reason: "stale renderer reset generation") }
            return
          }
          _ = rendererMachineResetHandoff.take()
          var prepared: DesktopRendererWorkerLaunch?
          do {
            let replacementLaunch = try result.get()
            prepared = replacementLaunch
            try gpuAccelerationAuthority.installReplacementAfterReset(
              lane: replacementLaunch.commandLane
            )
            previousLaunch.teardown(reason: "renderer generation replaced after guest reset")
            guard rendererWorkerLaunchStore.replace(replacementLaunch, replacing: previousLaunch) else {
              throw CancellationError()
            }
            graphicsReadinessState.prepareRendererReplacement(replacementLaunch)
            let replacement = try configuration.authority.makeMachine(
              displaySink: displaySink,
              gpuAccelerationAuthority: gpuAccelerationAuthority,
              gpuHostVisibleAperture: gpuHostVisibleAperture,
              soundBackend: audioBackend ?? DoryVirtioInMemorySoundBackend(),
              networkBackend: networkBackend,
              additionalPCIFunctions: [vsockPCI] + filesystemFunctions,
              instrumentationEnabled: executionProfilingEnabled
            )
            guard try installReplacementMachine(replacement) else { return }
            prepared = nil
            startExecution()
          } catch {
            prepared?.teardown(reason: "renderer replacement failed: \(error)")
            previousLaunch.teardown(reason: "renderer replacement failed: \(error)")
            if !machineState.isStopping { finish(error) }
          }
        }
        Task.detached(priority: .userInitiated) {
          do {
            let launch = try await provider.prepareReplacement(after: previousLaunch)
            DesktopAppRunLoop.perform { complete(.success(launch)) }
          } catch {
            DesktopAppRunLoop.perform { complete(.failure(error)) }
          }
        }
      }
    }

    private func handleWorkerUnavailable(_ workerGeneration: UInt64) {
      guard !machineState.isStopping,
        let launch = rendererWorkerLaunchStore.current(matchingWorkerGeneration: workerGeneration) else { return }
      readyPublisher.suspendRendererPresentation(workerGeneration: workerGeneration)
      graphicsReadinessState.rendererBecameUnavailable(
        workerGeneration: workerGeneration,
        detail: "Graphics renderer stopped; the x86 VM is still running."
      )
      launch.teardown(reason: "isolated DoryPC renderer loss")
      let transport = machineState.current().displayDevice.transport
      _ = transport.requestDeviceReset(expectedLifecycleEpoch: transport.deviceState.snapshot().lifecycleEpoch)
    }

    private nonisolated func installGPUResetObserver(_ device: DoryPCVirtioGPUPCIDevice) {
      device.transport.connectResetCompletedSink { [weak self, weak device] _ in
        guard let device else { return }
        DesktopAppRunLoop.perform { [weak self] in self?.replaceRendererAfterGPUReset(device) }
      }
    }

    /// This path never creates a replacement PC machine: RAM, CPU state, disks, networking and
    /// unsaved guest work keep their original owner. Only a completed GPU reset can admit a worker.
    private func replaceRendererAfterGPUReset(_ device: DoryPCVirtioGPUPCIDevice) {
      guard !machineState.isStopping, machineState.current().displayDevice === device,
        !rendererMachineResetHandoff.isPending,
        let authority = gpuAccelerationAuthority, !authority.canBackReplacementMachineAfterReset,
        let provider = rendererReplacementProvider, let previous = rendererWorkerLaunchStore.current(),
        let ticket = rendererResetCoordinator.beginReset(previousLaunch: previous, launchStore: rendererWorkerLaunchStore)
      else { return }
      readyPublisher.suspendRendererPresentation(workerGeneration: previous.workerGeneration.rawValue)
      graphicsReadinessState.rendererBecameUnavailable(
        workerGeneration: previous.workerGeneration.rawValue,
        detail: "Preparing a fresh isolated x86 graphics renderer; the VM remains running."
      )
      let complete: @MainActor @Sendable (Result<DesktopRendererWorkerLaunch, any Error>) -> Void = { [weak self, device] result in
        guard let self else {
          if case .success(let replacement) = result { replacement.teardown(reason: "PC owner released during GPU recovery") }
          return
        }
        guard rendererResetCoordinator.acceptsCompletion(ticket) else {
          if case .success(let replacement) = result { replacement.teardown(reason: "stale GPU replacement ticket") }
          return
        }
        gpuRendererReplacementTask = nil
        let machineReset = rendererMachineResetHandoff.take()
        var prepared: DesktopRendererWorkerLaunch?
        do {
          let replacement = try result.get()
          prepared = replacement
          guard !machineState.isStopping,
            machineState.current().displayDevice === device else { throw CancellationError() }
          // Repeated guest resets while bootstrap awaited coalesce into the latest completed
          // epoch. The pristine replacement has never executed a command in any prior epoch.
          let epoch = device.transport.deviceState.snapshot().lifecycleEpoch
          let installed: Void? = try device.transport.withCompletedReset(expectedEpoch: epoch) {
            try authority.installReplacementAfterReset(
              lane: replacement.commandLane, expectedResetGeneration: authority.currentResetGeneration
            )
            guard rendererWorkerLaunchStore.replace(replacement, replacing: previous) else {
              throw CancellationError()
            }
            graphicsReadinessState.prepareRendererReplacement(replacement)
            readyPublisher.prepareRendererPresentation(workerGeneration: replacement.workerGeneration.rawValue)
          }
          guard installed != nil else { throw DoryPCVirGLRendererAuthorityError.rendererUnavailable }
          previous.teardown(reason: "renderer replaced after GPU-only reset")
          if let machineReset {
            try resumeMachineAfterRendererReset(machineReset, authority: authority)
            prepared = nil
            return
          }
          prepared = nil
          // The execution thread may still be preparing new vsock/filesystem functions for an
          // intentional reboot. It will resume with this worker; never replay the retired boot.
          if rendererMachineResetHandoff.isPending { return }
          graphicsReadinessState.publishRuntimeDetail(
            "Graphics renderer replaced; waiting for new guest output. The x86 VM stayed running."
          )
          DispatchQueue.global(qos: .userInitiated).async { [weak replayDevice = device] in
            guard let device = replayDevice else { return }
            for queue in 0..<device.transport.queueCount { device.transport.processQueue(UInt16(queue)) }
          }
        } catch {
          prepared?.teardown(reason: "DoryPC GPU replacement cancelled or failed: \(error)")
          previous.teardown(reason: "DoryPC GPU replacement failed")
          if !machineState.isStopping {
            if machineReset != nil || rendererMachineResetHandoff.isPending { finish(error) }
            else {
              graphicsReadinessState.publishRuntimeDetail(
                "Graphics recovery failed; the x86 VM is still running. \(error)"
              )
            }
          }
        }
      }
      // AppKit owns the main run loop inside a long-lived main-actor task. A new Task on that
      // actor would queue behind NSApplication.run(); use the actual CFRunLoop completion lane.
      gpuRendererReplacementTask = Task.detached(priority: .userInitiated) {
        do {
          let replacement = try await provider.prepareReplacement(after: previous)
          if Task.isCancelled {
            replacement.teardown(reason: "GPU replacement preparation cancelled")
            throw CancellationError()
          }
          DesktopAppRunLoop.perform { complete(.success(replacement)) }
        } catch {
          DesktopAppRunLoop.perform { complete(.failure(error)) }
        }
      }
    }

    private func resumeMachineAfterRendererReset(
      _ reset: RendererMachineResetDevices, authority: DoryPCVirGLRendererAuthority
    ) throws {
      guard !machineState.isStopping,
        machineState.current().displayDevice === reset.previousDisplayDevice else { return }
      let replacement = try configuration.authority.makeMachine(
        displaySink: displaySink,
        gpuAccelerationAuthority: authority,
        gpuHostVisibleAperture: gpuHostVisibleAperture,
        soundBackend: audioBackend ?? DoryVirtioInMemorySoundBackend(),
        networkBackend: networkBackend,
        additionalPCIFunctions: [reset.vsock] + reset.filesystem,
        instrumentationEnabled: executionProfilingEnabled
      )
      guard try installReplacementMachine(replacement) else { return }
      startExecution()
    }

    @MainActor
    private static func handleWorkerPresentationFailure(
      workerGeneration: UInt64,
      reason: String,
      rendererWorkerLaunchStore: DoryPCRendererLaunchStore<DesktopRendererWorkerLaunch>,
      gpuAccelerationAuthority: DoryPCVirGLRendererAuthority?,
      machineState: MachineState
    ) {
      guard
        let rendererWorkerLaunch =
          rendererWorkerLaunchStore
          .current(matchingWorkerGeneration: workerGeneration)
      else {
        return
      }
      guard !machineState.isStopping else { return }
      rendererWorkerLaunch.failSynchronizedPresentation(reason)
      gpuAccelerationAuthority?.reportWorkerPresentationFailure(workerGeneration: workerGeneration)
    }

    private nonisolated func installReplacementMachine(_ replacement: DoryPCUEFIMachine) throws
      -> Bool
    {
      try usbControlHandler?.replaceController(replacement.xhciController)
      try cameraBridge?.attach(to: replacement.xhciController)
      if configuration.envelope.devices.networkAttachment == .disconnected {
        _ = replacement.networkDevice.setLinkUp(false)
      }
      keyboardInput.replaceDevice(replacement.keyboardDevice)
      pointerInput.replaceDevice(replacement.tabletDevice)
      relativePointerInput.replaceDevice(replacement.pointerDevice)
      guard machineState.replace(replacement) else {
        finish(nil)
        return false
      }
      installGPUResetObserver(replacement.displayDevice)
      if let generation = graphicsReadinessState.snapshot?.rendererGeneration {
        readyPublisher.prepareRendererPresentation(workerGeneration: generation)
      }
      graphicsReadinessState.resumeGuestMachinePresentation()
      return true
    }

    private nonisolated func finish(_ error: Error?) {
      DesktopAppRunLoop.perform { [weak self] in
        guard let self else { return }
        if self.stopError == nil { self.stopError = error }
        self.application.stop(nil)
        if let event = NSEvent.otherEvent(
          with: .applicationDefined,
          location: .zero,
          modifierFlags: [],
          timestamp: 0,
          windowNumber: 0,
          context: nil,
          subtype: 0,
          data1: 0,
          data2: 0
        ) {
          self.application.postEvent(event, atStart: false)
        }
      }
    }

    private func installSignals() throws {
      guard DoryPCClockSource.installProcessResumeTracking() else {
        throw VMError.invalidConfiguration(
          "could not install DoryPC resume clock tracking: errno \(errno)"
        )
      }
      let graceful = configuration.envelope.devices.gracefulShutdown
      let agentSocketPath = configuration.agentSocketPath
      let keyboardInput = self.keyboardInput
      let machineState = self.machineState
      let networkRuntime = self.networkRuntime
      let faultController = qualificationFaultController
      for number in [SIGTERM, SIGINT] {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: signalQueue)
        source.setEventHandler { @Sendable in
          // The daemon's bounded stop may ultimately SIGKILL this runner if an
          // installer has no guest agent and ignores the ACPI power key. Retire the
          // runner-owned sidecar at the first host termination signal so that forced
          // runner exit cannot orphan gvproxy under launchd or leak its stale sockets
          // into the next start. Guest shutdown control uses the independent vsock
          // bridge, so network teardown does not prevent the graceful request.
          faultController?.suspendRendererCrashArming(permanently: true)
          networkRuntime?.stop()
          machineState.requestGuestShutdown(
            graceful: graceful,
            agentSocketPath: agentSocketPath,
            keyboardInput: keyboardInput,
            log: Self.log
          )
        }
        source.resume()
        signalSources.append(source)
      }
    }

    private func cleanup() {
      qualificationFaultController?.suspendRendererCrashArming(permanently: true)
      rendererWorkerLossRelay.close()
      rendererResetCoordinator.invalidate()
      gpuRendererReplacementTask?.cancel()
      gpuRendererReplacementTask = nil
      rendererMachineResetHandoff.clear()
      mailbox?.view?.releasePressedInput()
      displayRelaySlot.stop()
      machineState.requestStop()
      signalSources.forEach { $0.cancel() }
      signalSources.removeAll()
      lifecycleServer.stop()
      clipboard?.stop()
      agentBridge.stop()
      shellBridge.stop()
      sshAgentBridge?.stop()
      filesystemRuntime?.stop()
      _ = vsock.quiesce()
      _ = usbControlServer?.stop()
      usbControlHandler?.stop()
      networkRuntime?.stop()
      cameraBridge?.stop()
      audioBackend?.reset()
      // A graceful stop has the same blob lifetime ordering as worker loss: retire every guest
      // CPU/DMA alias while the renderer arena still exists, then invalidate the worker lane.
      machineState.current().displayDevice.gpuDevice.reset()
      rendererWorkerLaunchStore.teardown(reason: "DoryPC renderer launch teardown")
      serialInput.stop()
      _ = serialOutput.stop()
      try? serialLog.close()
      mailbox?.disable()
    }

    private static func openSerialLog(_ path: String) throws -> FileHandle {
      let descriptor = Darwin.open(
        path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
      guard descriptor >= 0 else {
        throw VMError.invalidConfiguration(
          "could not open DoryPC serial log: errno \(errno)"
        )
      }
      var status = stat()
      guard fstat(descriptor, &status) == 0,
        status.st_mode & S_IFMT == S_IFREG,
        status.st_uid == geteuid(),
        status.st_mode & 0o077 == 0
      else {
        let code = errno
        Darwin.close(descriptor)
        throw VMError.invalidConfiguration(
          "DoryPC serial log is not an owner-private regular file: errno \(code)"
        )
      }
      return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private static func makeStartupOverlay(frame: NSRect) -> NSView {
      let overlay = NSVisualEffectView(frame: frame)
      overlay.autoresizingMask = [.width, .height]
      overlay.blendingMode = .withinWindow
      overlay.material = .underWindowBackground
      overlay.state = .active

      let progress = NSProgressIndicator()
      progress.style = .spinning
      progress.controlSize = .regular
      progress.startAnimation(nil)

      let title = NSTextField(labelWithString: "Starting x86_64 Linux")
      title.font = .systemFont(ofSize: 17, weight: .semibold)
      title.textColor = .labelColor
      title.alignment = .center

      let detail = NSTextField(
        wrappingLabelWithString:
          "Translating UEFI firmware. The installer will appear automatically."
      )
      detail.font = .systemFont(ofSize: 13)
      detail.textColor = .secondaryLabelColor
      detail.alignment = .center
      detail.maximumNumberOfLines = 2
      detail.preferredMaxLayoutWidth = 420

      let stack = NSStackView(views: [progress, title, detail])
      stack.orientation = .vertical
      stack.alignment = .centerX
      stack.spacing = 10
      stack.translatesAutoresizingMaskIntoConstraints = false
      overlay.addSubview(stack)
      NSLayoutConstraint.activate([
        stack.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
        stack.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
        stack.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.leadingAnchor, constant: 32),
        stack.trailingAnchor.constraint(lessThanOrEqualTo: overlay.trailingAnchor, constant: -32),
      ])
      return overlay
    }

    private nonisolated static func log(_ message: String) {
      FileHandle.standardError.write(Data("dory-hv DoryPC: \(message)\n".utf8))
    }

    private nonisolated static func machineExecutionProgress(
      _ composed: DoryPCUEFIMachine
    ) -> String {
      let machine = composed.machine
      let processors = machine.processorExecutionSnapshots.map { snapshot in
        guard let state = snapshot.state else {
          return
            "cpu\(snapshot.index){lifecycle=\(snapshot.lifecycle.rawValue),halted=\(snapshot.isHalted),state=nil}"
        }
        let mode = snapshot.executionMode?.rawValue ?? "unknown"
        let cpl = snapshot.privilegeLevel.map(String.init) ?? "unknown"
        return
          "cpu\(snapshot.index){lifecycle=\(snapshot.lifecycle.rawValue),halted=\(snapshot.isHalted),"
          + "mode=\(mode),cpl=\(cpl),rip=0x\(hex(state.rip)),cs=0x\(hex(UInt64(state.cs.selector))),"
          + "rflags=0x\(hex(state.rflags.rawValue)),cr0=0x\(hex(state.control.cr0)),"
          + "cr3=0x\(hex(state.control.cr3)),cr4=0x\(hex(state.control.cr4)),"
          + "efer=0x\(hex(state.control.efer)),cr8=0x\(hex(state.control.cr8))}"
      }.joined(separator: " ")
      let localAPICs = machine.localAPICs.map { apic in
        let snapshot = apic.snapshot()
        let timer = snapshot.timer
        return "lapic\(snapshot.apicID){enabled=\(snapshot.softwareEnabled),"
          + "tpr=0x\(hex(UInt64(snapshot.taskPriority))),irr=[\(hexSet(snapshot.interruptRequest))],"
          + "isr=[\(hexSet(snapshot.inService))],level=[\(hexSet(snapshot.levelTriggered))],"
          + "timer={masked=\(timer.masked),mode=\(timer.mode.rawValue),vector=0x\(hex(UInt64(timer.vector))),"
          + "initial=\(timer.initialCount),current=\(timer.currentCount)}}"
      }.joined(separator: " ")
      let pic = machine.legacyPIC.snapshot()
      let pit = machine.legacyPIT.snapshot()
      let hpet = machine.hpet.snapshot()
      let hpetTimers = hpet.timers.enumerated().prefix(3).map { index, timer in
        "t\(index){cfg=0x\(hex(timer.configuration)),cmp=\(timer.comparator),period=\(timer.period),armed=\(timer.armed)}"
      }.joined(separator: ",")
      let ioAPIC = machine.ioAPIC.snapshot()
      let activeIOPins = ioAPIC.filter { pin in
        !pin.route.masked || pin.asserted || pin.remoteIRR
      }.prefix(8).map { pin in
        "pin\(pin.pin){vec=0x\(hex(UInt64(pin.route.vector))),dest=\(pin.route.destinationAPICID),"
          + "masked=\(pin.route.masked),level=\(pin.route.levelTriggered),"
          + "asserted=\(pin.asserted),remoteIRR=\(pin.remoteIRR)}"
      }.joined(separator: ",")
      return "machine progress \(processors) \(localAPICs) "
        + "pic{mvec=0x\(hex(UInt64(pic.masterVectorOffset))),svec=0x\(hex(UInt64(pic.slaveVectorOffset))),"
        + "mmask=0x\(hex(UInt64(pic.masterMask))),smask=0x\(hex(UInt64(pic.slaveMask))),"
        + "mirr=0x\(hex(UInt64(pic.masterRequest))),sirr=0x\(hex(UInt64(pic.slaveRequest))),"
        + "misr=0x\(hex(UInt64(pic.masterInService))),sisr=0x\(hex(UInt64(pic.slaveInService))),"
        + "mlvl=0x\(hex(UInt64(pic.masterLevelTriggered))),slvl=0x\(hex(UInt64(pic.slaveLevelTriggered))),"
        + "massert=0x\(hex(UInt64(pic.masterAssertedLines))),sassert=0x\(hex(UInt64(pic.slaveAssertedLines)))} "
        + "pit{armed=\(pit.armed),mode=\(pit.mode.rawValue),reload=\(pit.reload),current=\(pit.current)} "
        + "hpet{enabled=\(hpet.enabled),legacy=\(hpet.legacyReplacement),main=\(hpet.mainCounter),"
        + "status=0x\(hex(hpet.interruptStatus)),timers=[\(hpetTimers)]} "
        + "ioapic{active=[\(activeIOPins)]}"
    }

    private nonisolated static func hex(_ value: UInt64) -> String {
      String(value, radix: 16)
    }

    private nonisolated static func hexSet(_ values: Set<UInt8>) -> String {
      values.sorted().map { hex(UInt64($0)) }.joined(separator: ",")
    }

    private nonisolated static func interruptVectorProgress(
      _ vectors: [DoryPCExecutionStatistics.InterruptVectorCount]
    ) -> String {
      vectors.prefix(5).map {
        "0x\(hex(UInt64($0.vector))):\($0.deliveries)"
      }.joined(separator: ",")
    }

    private nonisolated static func blockDeviceProgress(
      _ composed: DoryPCUEFIMachine
    ) -> String {
      let devices = zip(composed.plan.bootDevices, composed.blockDevices).map {
        planned, attached in
        let state = attached.transport.deviceState.snapshot()
        let queue = try? attached.transport.queueSnapshot(at: 0)
        let registers = attached.transport.registerDiagnostics
        let requests = attached.blockDevice.diagnostics
        let ranges = requests.recentReadRanges.suffix(4).map {
          "\($0.offset)+\($0.byteCount)"
        }.joined(separator: ",")
        return "\(planned.logicalID){kind=\(planned.kind),status=\(state.status.rawValue),"
          + "queue-enabled=\(queue?.enabled == true),register-reads=\(registers.readCount),"
          + "register-writes=\(registers.writeCount),requests=\(requests.requestCount),"
          + "reads=\(requests.readRequestCount),read-bytes=\(requests.readByteCount),"
          + "writes=\(requests.writeRequestCount),write-bytes=\(requests.writeByteCount),"
          + "flushes=\(requests.flushRequestCount),failures=\(requests.failedRequestCount),"
          + "unsupported=\(requests.unsupportedRequestCount),recent-reads=[\(ranges)]}"
      }
      return "block progress " + devices.joined(separator: " ")
    }

    private nonisolated static func jitProgress(
      _ tier: String,
      _ diagnostics: DoryPCJITCacheStatistics
    ) -> String {
      let hotSites = diagnostics.negativeCacheHotSites.prefix(5).map { site in
        let bytes = site.instructionBytes.prefix(15).map {
          String(format: "%02x", $0)
        }.joined()
        return "{rip=\(String(site.guestRIP, radix: 16)),cpl=\(site.privilegeLevel),"
          + "bytes=\(bytes),reason=\(site.declineReason.rawValue),hits=\(site.hitCount)}"
      }.joined(separator: ",")
      return "jit progress tier=\(tier) "
        + "recent-hits=\(diagnostics.recentLookupHits) "
        + "block-cache-hits=\(diagnostics.blockCacheLookupHits) "
        + "dictionary-hits=\(diagnostics.dictionaryLookupHits) "
        + "misses=\(diagnostics.lookupMisses) "
        + "generation-hits=\(diagnostics.memoryGenerationHits) "
        + "byte-hits=\(diagnostics.byteValidationHits) "
        + "shared-hits=\(diagnostics.sharedCodeHits) "
        + "compiled=\(diagnostics.compiledBlocks) "
        + "declined=\(diagnostics.declinedCompilations) "
        + "negative-hits=\(diagnostics.negativeCacheHits) "
        + "negative-misses=\(diagnostics.negativeCacheMisses) "
        + "negative-generation-mismatches="
        + "\(diagnostics.negativeGenerationMismatches) "
        + "negative-entries=\(diagnostics.negativeEntryCount) "
        + "wraps=\(diagnostics.codeCacheWraps) "
        + "trace-attempts=\(diagnostics.nativeTraceAttempts) "
        + "trace-replays=\(diagnostics.nativeTraceReplays) "
        + "generation-checks=\(diagnostics.codeGenerationChecks) "
        + "generation-mismatches=\(diagnostics.codeGenerationMismatches) "
        + "chain-calls=\(diagnostics.chainedExecutionCalls) "
        + "chain-requested=\(diagnostics.chainedRequestedInstructions) "
        + "chain-retired=\(diagnostics.chainedRetiredInstructions) "
        + "negative-top=[\(hotSites)]"
    }

    private func requestGuestShutdown() {
      qualificationFaultController?.suspendRendererCrashArming(permanently: true)
      window?.orderOut(nil)
      machineState.requestGuestShutdown(
        graceful: configuration.envelope.devices.gracefulShutdown,
        agentSocketPath: configuration.agentSocketPath,
        keyboardInput: keyboardInput,
        log: Self.log
      )
    }
  }
}
