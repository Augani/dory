import Darwin
import DoryMacGuestIntegrationWire
import Foundation

/// Compile with the actual DoryGuestFileOfferReader.swift and integration-wire module.
/// All descriptors and files belong to this temporary fixture; no app or guest is launched.
@main
struct DoryGuestFileOfferReaderContract {
  static func main() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "dory-file-offer-reader-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("selected.txt")
    try Data("abcdef".utf8).write(to: url)
    try retirementJoinsPausedRead(url)
    try readsRemainSequential(url)
    try retirementBetweenReadAndCommit(url)
    try originalDeadlineDoesNotRenewAfterRead(url)
    try failedReadAndForeignCloseAreDetached(url)
    print("Dory guest file offer reader contract passed (5 cases)")
  }

  private static func retirementJoinsPausedRead(_ url: URL) throws {
    let handle = try FileHandle(forReadingFrom: url)
    let descriptor = handle.fileDescriptor
    let events = Events()
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0), closed = DispatchSemaphore(value: 0)
    let reader = DoryGuestFileOfferReader(handle: handle) {
      events.incrementCloses()
      closed.signal()
    }
    DispatchQueue.global().async {
      defer { finished.signal() }
      do {
        _ = try reader.read({ file in
          entered.signal()
          requireSignal(release)
          return try file.read(upToCount: 3) ?? Data()
        }, authorizeResult: { bytes in
          events.recordCommit(bytes)
        })
        events.recordFailure("retired read unexpectedly committed")
      } catch DoryMacGuestIntegrationWire.WireError.connectionClosed {
        events.incrementDenials()
      } catch { events.recordFailure(String(describing: error)) }
    }
    requireSignal(entered)
    let revoked = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      reader.retire()
      reader.retire()
      revoked.signal()
    }
    // Retirement must complete while the actual reader is still held, not join its I/O.
    requireSignal(revoked)
    precondition(events.closes == 0)
    precondition(fcntl(descriptor, F_GETFD) >= 0, "descriptor closed under active read")
    do {
      _ = try reader.read({ _ in preconditionFailure("retired reader admitted another read") },
        authorizeResult: { _ in preconditionFailure("retired reader admitted commit") })
      preconditionFailure("retired reader admitted work")
    } catch DoryMacGuestIntegrationWire.WireError.connectionClosed {}
    release.signal()
    requireSignal(finished)
    requireSignal(closed)
    reader.retire()
    precondition(events.closes == 1 && events.denials == 1 && events.commits.isEmpty)
    precondition(events.failures.isEmpty)
  }

  private static func readsRemainSequential(_ url: URL) throws {
    let events = Events(), entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
    let closed = DispatchSemaphore(value: 0)
    let reader = DoryGuestFileOfferReader(handle: try FileHandle(forReadingFrom: url)) {
      events.incrementCloses()
      closed.signal()
    }
    DispatchQueue.global().async {
      defer { finished.signal() }
      do {
        try reader.read({ file in
          entered.signal()
          requireSignal(release)
          return try file.read(upToCount: 3) ?? Data()
        }, authorizeResult: { events.recordCommit($0) })
      } catch { events.recordFailure(String(describing: error)) }
    }
    requireSignal(entered)
    do {
      _ = try reader.read({ _ in preconditionFailure("overlapping sequential read entered") },
        authorizeResult: { _ in preconditionFailure("overlapping read committed") })
      preconditionFailure("overlapping read was admitted")
    } catch DoryMacGuestIntegrationWire.WireError.connectionClosed {}
    release.signal()
    requireSignal(finished)
    try reader.read({ try $0.read(upToCount: 3) ?? Data() },
      authorizeResult: { events.recordCommit($0) })
    let eof = try reader.read({ try $0.read(upToCount: 1) ?? Data() }, authorizeResult: { $0 })
    precondition(eof.isEmpty)
    precondition(events.commits == [Data("abc".utf8), Data("def".utf8)])
    precondition(events.failures.isEmpty)
    reader.retire()
    requireSignal(closed)
    precondition(events.closes == 1)
  }

  private static func retirementBetweenReadAndCommit(_ url: URL) throws {
    let events = Events(), owner = Owner()
    let original = owner.identity
    let enteredCommit = DispatchSemaphore(value: 0), releaseCommit = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0), closed = DispatchSemaphore(value: 0)
    let reader = DoryGuestFileOfferReader(handle: try FileHandle(forReadingFrom: url)) {
      events.incrementCloses()
      closed.signal()
    }
    DispatchQueue.global().async {
      defer { finished.signal() }
      do {
        try reader.read({ try $0.read(upToCount: 3) ?? Data() }, authorizeResult: { bytes in
          // Admission passed the leaf gate, but the owner can still change before commit.
          enteredCommit.signal()
          requireSignal(releaseCommit)
          try owner.commit(bytes, expectedIdentity: original)
        })
        events.recordFailure("old result changed successor offset")
      } catch DoryMacGuestIntegrationWire.WireError.connectionClosed {
        events.incrementDenials()
      } catch { events.recordFailure(String(describing: error)) }
    }
    requireSignal(enteredCommit)
    owner.replace()
    reader.retire()
    precondition(events.closes == 0, "reader lease ended before result authorization")
    releaseCommit.signal()
    requireSignal(finished)
    requireSignal(closed)
    precondition(owner.offset == 0 && events.denials == 1 && events.closes == 1)
    precondition(events.failures.isEmpty)
  }

  private static func originalDeadlineDoesNotRenewAfterRead(_ url: URL) throws {
    let events = Events(), closed = DispatchSemaphore(value: 0)
    let reader = DoryGuestFileOfferReader(handle: try FileHandle(forReadingFrom: url)) {
      events.incrementCloses()
      closed.signal()
    }
    let request = try DoryMacGuestIntegrationWire.Envelope(
      kind: .request, sessionID: UUID(), machineID: String(repeating: "a", count: 64),
      runtimeGeneration: 7, requestID: 1, capability: .filePull, timeoutMilliseconds: 10)
    var admission = try DoryMacGuestIntegrationWire.UserActionAdmission(
      request: request, receivedAtUptimeNanoseconds: 1_000_000_000)
    precondition(admission.begin(nowUptimeNanoseconds: 1_000_000_001))
    do {
      try reader.read({ try $0.read(upToCount: 3) ?? Data() }, authorizeResult: { bytes in
        // At the exact original boundary, no replacement timeout may authorize consumed bytes.
        let now: UInt64 = 1_010_000_000
        guard admission.state == .begun, now < admission.deadlineUptimeNanoseconds else {
          admission.expire()
          throw ExpiredRead()
        }
        events.recordCommit(bytes)
      })
      preconditionFailure("post-read deadline was renewed")
    } catch is ExpiredRead {}
    precondition(admission.state == .expired && events.commits.isEmpty)
    reader.retire()
    requireSignal(closed)
    precondition(events.closes == 1)
  }

  private static func failedReadAndForeignCloseAreDetached(_ url: URL) throws {
    let events = Events(), enteredClose = DispatchSemaphore(value: 0)
    let releaseClose = DispatchSemaphore(value: 0), finishedClose = DispatchSemaphore(value: 0)
    let reader = DoryGuestFileOfferReader(handle: try FileHandle(forReadingFrom: url)) {
      enteredClose.signal()
      requireSignal(releaseClose)
      events.incrementCloses()
      finishedClose.signal()
    }
    do {
      _ = try reader.read({ _ in throw DoryMacGuestIntegrationWire.WireError.ioFailure(EIO) },
        authorizeResult: { _ in preconditionFailure("failed read committed") })
      preconditionFailure("failed read was accepted")
    } catch DoryMacGuestIntegrationWire.WireError.ioFailure(EIO) {}
    reader.retire()
    requireSignal(enteredClose)
    // Even a blocked foreign cleanup cannot make a repeated owner revocation block.
    reader.retire()
    precondition(events.closes == 0)
    releaseClose.signal()
    requireSignal(finishedClose)
    precondition(events.closes == 1)
  }

  private struct ExpiredRead: Error {}

  private static func requireSignal(_ semaphore: DispatchSemaphore) {
    precondition(semaphore.wait(timeout: .now() + 2) == .success, "fixture gate exceeded deadline")
  }

  private final class Owner: @unchecked Sendable {
    private let lock = NSLock()
    private var current = UUID()
    private var committedOffset: UInt64 = 0
    var identity: UUID { lock.withLock { current } }
    var offset: UInt64 { lock.withLock { committedOffset } }
    func replace() { lock.withLock { current = UUID(); committedOffset = 0 } }
    func commit(_ bytes: Data, expectedIdentity: UUID) throws {
      try lock.withLock {
        guard current == expectedIdentity else {
          throw DoryMacGuestIntegrationWire.WireError.connectionClosed
        }
        committedOffset += UInt64(bytes.count)
      }
    }
  }

  private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var closeCount = 0, denialCount = 0
    private var committedBytes: [Data] = [], errors: [String] = []
    var closes: Int { lock.withLock { closeCount } }
    var denials: Int { lock.withLock { denialCount } }
    var commits: [Data] { lock.withLock { committedBytes } }
    var failures: [String] { lock.withLock { errors } }
    func incrementCloses() { lock.withLock { closeCount += 1 } }
    func incrementDenials() { lock.withLock { denialCount += 1 } }
    func recordCommit(_ bytes: Data) { lock.withLock { committedBytes.append(bytes) } }
    func recordFailure(_ value: String) { lock.withLock { errors.append(value) } }
  }
}
