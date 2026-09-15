import Foundation

/// Bounded observations of boot text at UART transmission, before host console buffering.
/// These markers are diagnostics, not authenticated guest readiness or capability evidence.
public final class DoryPCBootTimeline: @unchecked Sendable {
  public enum Milestone: String, Codable, CaseIterable, Sendable {
    case executionStarted, grub, grubMenu, kernel, rootMounted, initStarted
  }

  public struct Event: Codable, Sendable, Equatable {
    public let milestone: Milestone
    public let elapsedNanoseconds: UInt64
  }

  public struct Snapshot: Codable, Sendable {
    public let observationID: UUID
    public let clock: String
    public let originNanoseconds: UInt64
    public let elapsedNanoseconds: UInt64
    public let observedSerialBytes: UInt64
    public let events: [Event]
    public let unobservedMilestones: [Milestone]
    public let unobservedStatus: String
    public let terminationReason: String?
  }

  private struct Matcher {
    let milestone: Milestone
    let bytes: [UInt8]
    let fallback: [Int]
    var matched = 0

    init(_ milestone: Milestone, _ text: String) {
      self.milestone = milestone
      bytes = Array(text.utf8)
      var table = [Int](repeating: 0, count: bytes.count)
      var prefix = 0
      for index in 1..<bytes.count {
        while prefix > 0, bytes[index] != bytes[prefix] { prefix = table[prefix - 1] }
        if bytes[index] == bytes[prefix] { prefix += 1 }
        table[index] = prefix
      }
      fallback = table
    }

    mutating func consume(_ byte: UInt8) -> Bool {
      while matched > 0, byte != bytes[matched] { matched = fallback[matched - 1] }
      if byte == bytes[matched] { matched += 1 }
      guard matched == bytes.count else { return false }
      matched = fallback[matched - 1]
      return true
    }
  }

  private let lock = NSLock()
  private let observationID = UUID()
  private let now: @Sendable () -> UInt64
  private let origin: UInt64
  private var events: [Event] = [.init(milestone: .executionStarted, elapsedNanoseconds: 0)]
  private var seen: Set<Milestone> = [.executionStarted]
  private var serialBytes: UInt64 = 0
  private var endedAt: UInt64?
  private var terminationReason: String?
  private var matchers: [Matcher] = [
    .init(.grub, "GNU GRUB"),
    .init(.grub, "Welcome to GRUB"),
    .init(.grub, "  Booting `"),
    // Arch's current UEFI installer menu is GRUB-driven, but its serial output contains
    // the selected menu entry rather than GRUB's interactive banner. Keep the established
    // `grub` receipt value for schema compatibility while recognizing this bounded marker.
    .init(.grub, "Arch Linux install medium (x86_64, "),
    // The interactive prompt is a later and distinct bootloader phase from the banner. It is
    // suitable for synchronized keyboard injection; a banner alone is not an input-ready proof.
    .init(.grubMenu, "Press enter to boot the selected OS"),
    .init(.kernel, "Linux version "),
    .init(.rootMounted, "VFS: Mounted root"),
    .init(.initStarted, "Run /init as init process"),
    .init(.initStarted, "Run /sbin/init as init process"),
    .init(.initStarted, "Run /bin/sh as init process"),
  ]

  public init() {
    now = { DispatchTime.now().uptimeNanoseconds }
    origin = DispatchTime.now().uptimeNanoseconds
  }

  init(now: @escaping @Sendable () -> UInt64) {
    self.now = now
    origin = now()
  }

  // Called under the UART lock, preserving guest transmit order even when callers race.
  // No guest text is retained and no callback, file write, or clock read occurs unless a
  // previously unseen marker completes. Snapshot callers never acquire the UART lock.
  func observeTransmittedByte(_ byte: UInt8) {
    lock.withLock {
      guard endedAt == nil else { return }
      if serialBytes < .max { serialBytes += 1 }
      for index in matchers.indices where !seen.contains(matchers[index].milestone) {
        if matchers[index].consume(byte) {
          let milestone = matchers[index].milestone
          seen.insert(milestone)
          events.append(.init(milestone: milestone, elapsedNanoseconds: elapsed(now())))
        }
      }
    }
  }

  public func finish(reason: String) {
    lock.withLock {
      guard endedAt == nil else { return }
      endedAt = now()
      terminationReason = String(reason.prefix(128))
    }
  }

  public func snapshot() -> Snapshot {
    lock.withLock {
      Snapshot(
        observationID: observationID,
        clock: "host-dispatch-uptime-nanoseconds",
        originNanoseconds: origin,
        elapsedNanoseconds: elapsed(endedAt ?? now()),
        observedSerialBytes: serialBytes,
        events: events,
        unobservedMilestones: Milestone.allCases.filter { !seen.contains($0) },
        unobservedStatus: endedAt == nil ? "pending" : "censored",
        terminationReason: terminationReason
      )
    }
  }

  private func elapsed(_ timestamp: UInt64) -> UInt64 {
    timestamp >= origin ? timestamp - origin : 0
  }
}
