import Darwin
import Foundation
import Testing
@testable import dory_pc_linux_boot_runner

@Suite("PVH bounded stress IO")
struct PVHStressIOTests {
  private let runID = UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")!

  @Test("fresh disk records actual operations and verifies the owned inode after reopening")
  func diskFlushAndReopen() throws {
    let outer = try directory()
    defer { try? FileManager.default.removeItem(at: outer) }
    let storage = try PVHStressBlockStorage(newDirectory: outer.appendingPathComponent("disk"), runID: runID)
    let pattern = (0..<(128 << 10)).map { UInt8(truncatingIfNeeded: $0 * 37 + ($0 >> 8)) }
    #expect(try storage.read(offset: 1 << 20, byteCount: pattern.count) == [UInt8](repeating: 0, count: pattern.count))
    for _ in 0..<8 {
      try storage.write(offset: 1 << 20, bytes: pattern)
      try storage.flush()
      #expect(try storage.read(offset: 1 << 20, byteCount: pattern.count) == pattern)
    }
    let before = storage.snapshot
    let verified = try storage.verifyAfterPoweroff()
    #expect(verified.capacityBytes == 32 << 20)
    #expect(verified.runID == runID.uuidString.lowercased())
    #expect(verified.readRequests == 9 && verified.readBytes == 9 * UInt64(pattern.count))
    #expect(verified.writeRequests == 8 && verified.writeBytes == 8 * UInt64(pattern.count))
    #expect(verified.flushRequests == 8 && verified.failure == nil)
    #expect(verified.reopenedAndVerified)
    #expect(verified.verifiedRegionSHA256 == "dbb71d178d43f63f39dd9b0fb5fc30fb366ada39e3b8763e41338b892c098cd6")
    #expect(verified.readBytes == before.readBytes && verified.flushRequests == before.flushRequests)
    #expect(FileManager.default.fileExists(atPath: verified.filePath))
    #expect(throws: PVHStressIOError.self) { try storage.write(offset: 0, bytes: [1]) }
  }

  @Test("diagnostic construction never replaces an existing directory, file or symlink")
  func existingPathsArePreserved() throws {
    let outer = try directory()
    defer { try? FileManager.default.removeItem(at: outer) }
    let existing = outer.appendingPathComponent("existing")
    try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
    let marker = existing.appendingPathComponent("marker")
    try Data([4, 5, 6]).write(to: marker)
    let file = outer.appendingPathComponent("file")
    try Data([7, 8, 9]).write(to: file)
    let symlink = outer.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: existing)
    for path in [existing, file, symlink] {
      #expect(throws: PVHStressIOError.self) { _ = try PVHStressBlockStorage(newDirectory: path, runID: runID) }
    }
    #expect(try Data(contentsOf: marker) == Data([4, 5, 6]))
    #expect(try Data(contentsOf: file) == Data([7, 8, 9]))
    #expect(!FileManager.default.fileExists(atPath: existing.appendingPathComponent("virtio-block.raw").path))
  }

  @Test("invalid and overflowing ranges fail before any IO and remain failed")
  func invalidDiskRangesArePreflighted() throws {
    let outer = try directory()
    defer { try? FileManager.default.removeItem(at: outer) }
    let invalid: [(PVHStressBlockStorage) throws -> Void] = [
      { _ = try $0.read(offset: 0, byteCount: -1) },
      { _ = try $0.read(offset: 0, byteCount: (1 << 20) + 1) },
      { _ = try $0.read(offset: .max, byteCount: 1) },
      { try $0.write(offset: (32 << 20) - 1, bytes: [1, 2]) },
      { try $0.discard(offset: 0, byteCount: .max) },
      { try $0.writeZeroes(offset: .max, byteCount: 1, mayUnmap: true) },
    ]
    for (index, action) in invalid.enumerated() {
      let storage = try PVHStressBlockStorage(newDirectory: outer.appendingPathComponent("disk-\(index)"), runID: runID)
      #expect(throws: PVHStressIOError.self) { try action(storage) }
      let failed = storage.snapshot
      #expect(failed.readRequests == 0 && failed.writeRequests == 0)
      #expect(failed.discardRequests == 0 && failed.writeZeroesRequests == 0 && failed.zeroedBytes == 0)
      #expect(failed.failure != nil)
      #expect(throws: PVHStressIOError.self) { try storage.flush() }
      #expect(storage.snapshot.failure == failed.failure)
      let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: failed.filePath))
      defer { try? handle.close() }
      #expect(try handle.read(upToCount: 1) == Data([0]))
    }
  }

  @Test("advertised zero and discard operations are bounded and zero their whole ranges")
  func zeroAndDiscard() throws {
    let outer = try directory()
    defer { try? FileManager.default.removeItem(at: outer) }
    let storage = try PVHStressBlockStorage(newDirectory: outer.appendingPathComponent("disk"), runID: runID)
    let count = (64 << 10) + 1 // Cross the internal zeroing chunk boundary.
    try storage.write(offset: 512, bytes: [UInt8](repeating: 0xAD, count: count))
    try storage.writeZeroes(offset: 512, byteCount: UInt64(count), mayUnmap: false)
    #expect(try storage.read(offset: 512, byteCount: count) == [UInt8](repeating: 0, count: count))
    try storage.write(offset: 512, bytes: [UInt8](repeating: 0xBE, count: count))
    try storage.discard(offset: 512, byteCount: UInt64(count))
    #expect(try storage.read(offset: 512, byteCount: count) == [UInt8](repeating: 0, count: count))
    try storage.writeZeroes(offset: 32 << 20, byteCount: 0, mayUnmap: true)
    #expect(try storage.read(offset: 32 << 20, byteCount: 0).isEmpty)
    let snapshot = storage.snapshot
    #expect(snapshot.writeRequests == 2 && snapshot.discardRequests == 1 && snapshot.writeZeroesRequests == 2)
    #expect(snapshot.zeroedBytes == 2 * UInt64(count))
    #expect(snapshot.writeBytes == 2 * UInt64(count) && snapshot.flushRequests == 0)
  }

  @Test("even empty disk operations have a finite request budget")
  func emptyRequestBudget() throws {
    let outer = try directory()
    defer { try? FileManager.default.removeItem(at: outer) }
    let storage = try PVHStressBlockStorage(newDirectory: outer.appendingPathComponent("disk"), runID: runID)
    for _ in 0..<65_536 { try storage.write(offset: 0, bytes: []) }
    #expect(throws: PVHStressIOError.self) { try storage.write(offset: 0, bytes: []) }
    #expect(storage.snapshot.writeRequests == 65_536 && storage.snapshot.writeBytes == 0)
    #expect(storage.snapshot.failure != nil)
  }

  @Test("reopened verification rejects absent flush, changed content and replaced file identities")
  func verificationRejectsMissingFlushOrChangedArtifacts() throws {
    let outer = try directory()
    defer { try? FileManager.default.removeItem(at: outer) }
    for mode in ["no-flush", "contents", "inode", "symlink", "size", "hardlink"] {
      let directory = outer.appendingPathComponent(mode)
      let storage = try PVHStressBlockStorage(newDirectory: directory, runID: runID)
      try storage.write(offset: 1 << 20, bytes: PVHStressBlockStorage.expectedRegion())
      if mode != "no-flush" { try storage.flush() }
      let file = URL(fileURLWithPath: storage.snapshot.filePath)
      if mode == "contents" || mode == "size" {
        let handle = try FileHandle(forWritingTo: file)
        if mode == "contents" {
          try handle.seek(toOffset: (1 << 20) + 17)
          try handle.write(contentsOf: Data([0xFF]))
        } else { try handle.truncate(atOffset: 512) }
        try handle.close()
      } else if mode == "inode" || mode == "symlink" {
        let old = directory.appendingPathComponent("old.raw")
        try FileManager.default.moveItem(at: file, to: old)
        if mode == "symlink" { try FileManager.default.createSymbolicLink(at: file, withDestinationURL: old) }
        else {
          try Data().write(to: file)
          let handle = try FileHandle(forWritingTo: file)
          try handle.truncate(atOffset: 32 << 20)
          try handle.close()
        }
      } else if mode == "hardlink" {
        try FileManager.default.linkItem(at: file, to: directory.appendingPathComponent("alias.raw"))
      }
      #expect(throws: PVHStressIOError.self) { _ = try storage.verifyAfterPoweroff() }
      #expect(!storage.snapshot.reopenedAndVerified && storage.snapshot.verifiedRegionSHA256 == nil)
      #expect(storage.snapshot.failure != nil)
    }
  }

  @Test("transmit queues exact UUID-bound echoes and pump invokes sinks without its lock")
  func queuedEchoProtocol() throws {
    let peer = PVHStressNetworkPeer(runID: runID)
    let receiver = Receiver()
    peer.connectReceiveSink { frame in
      // This snapshot read would deadlock if pump held the backend lock.
      receiver.receive(frame, queued: peer.snapshot.queuedReplies)
    }
    let request = frame(sequence: 0)
    try peer.transmit(frame: request)
    #expect(receiver.count == 0 && peer.snapshot.queuedReplies == 1)
    #expect(peer.snapshot.acceptedBytes == 1024 && peer.snapshot.deliveredReplies == 0)
    #expect(try peer.pump() == 1)
    var echo = request
    echo.replaceSubrange(0..<6, with: request[6..<12])
    echo.replaceSubrange(6..<12, with: request[0..<6])
    #expect(receiver.lastFrame == echo && receiver.lastQueued == 0)
    #expect(peer.snapshot.deliveredReplies == 1 && peer.snapshot.queuedReplies == 0)
  }

  @Test("bounded successful IO reconciliation counts full Ethernet frames and preserves guest timing scope")
  func successfulNetworkReconciliation() throws {
    let peer = PVHStressNetworkPeer(runID: runID)
    let receiver = Receiver()
    peer.connectReceiveSink { receiver.receive($0, queued: 0) }
    for sequence in UInt32(0)..<4096 {
      try peer.transmit(frame: frame(sequence: sequence))
      #expect(try peer.pump() == 1)
    }
    let verified = try peer.verifyCompletion(guestFrames: 4096, guestBytes: 4096 * 1024, guestElapsedNanoseconds: 5_000_000_000)
    #expect(receiver.count == 4096 && verified.acceptedFrames == 4096 && verified.deliveredReplies == 4096)
    #expect(verified.acceptedBytes == 4096 * 1024 && verified.queuedReplies == 0 && verified.failure == nil)
    #expect(verified.verified && verified.guestReportedElapsedNanoseconds == 5_000_000_000)
    let decoded = try JSONDecoder().decode(PVHStressNetworkSnapshot.self, from: JSONEncoder().encode(verified))
    #expect(decoded.timingScope.contains("does not independently measure guest time"))
    #expect(decoded.guestReportedElapsedNanoseconds == verified.guestReportedElapsedNanoseconds)
    #expect(throws: PVHStressIOError.self) { try peer.transmit(frame: frame(sequence: 4096)) }
  }

  @Test("diagnostic identity, sequence and payload corruption are sticky failures")
  func malformedDiagnosticFrames() throws {
    let mutations: [(inout [UInt8]) -> Void] = [
      { $0[0] ^= 1 }, { $0[6] ^= 1 }, { $0[14] ^= 1 }, { $0[22] ^= 1 },
      { $0[41] = 1 }, { $0[43] ^= 1 }, { $0[44] ^= 1 }, { $0[1023] ^= 1 },
      { $0.removeLast() }, { $0.append(0) },
    ]
    for mutate in mutations {
      let peer = PVHStressNetworkPeer(runID: runID)
      var request = frame(sequence: 0)
      mutate(&request)
      #expect(throws: PVHStressIOError.self) { try peer.transmit(frame: request) }
      let failed = peer.snapshot
      #expect(failed.acceptedFrames == 0 && failed.queuedReplies == 0 && failed.failure != nil)
      #expect(throws: PVHStressIOError.self) { try peer.transmit(frame: frame(sequence: 0)) }
      #expect(peer.snapshot.failure == failed.failure)
    }
    let duplicate = PVHStressNetworkPeer(runID: runID)
    try duplicate.transmit(frame: frame(sequence: 0))
    #expect(throws: PVHStressIOError.self) { try duplicate.transmit(frame: frame(sequence: 0)) }
    #expect(duplicate.snapshot.acceptedFrames == 1)
  }

  @Test("reply and unrelated frame queues cannot exceed their declared limits")
  func queueAndIgnoredFrameBounds() throws {
    let peer = PVHStressNetworkPeer(runID: runID)
    for sequence in UInt32(0)..<64 { try peer.transmit(frame: frame(sequence: sequence)) }
    #expect(peer.snapshot.queuedReplies == 64)
    #expect(throws: PVHStressIOError.self) { try peer.transmit(frame: frame(sequence: 64)) }
    #expect(peer.snapshot.queuedReplies == 64 && peer.snapshot.acceptedFrames == 64)
    let unrelated = PVHStressNetworkPeer(runID: runID)
    var other = [UInt8](repeating: 0, count: 14)
    other[12] = 0x86; other[13] = 0xDD
    for _ in 0..<64 { try unrelated.transmit(frame: other) }
    #expect(unrelated.snapshot.ignoredFrames == 64 && unrelated.snapshot.acceptedFrames == 0)
    #expect(throws: PVHStressIOError.self) { try unrelated.transmit(frame: other) }
    #expect(unrelated.snapshot.failure != nil && unrelated.snapshot.queuedReplies == 0)
    let missingSink = PVHStressNetworkPeer(runID: runID)
    try missingSink.transmit(frame: frame(sequence: 0))
    #expect(throws: PVHStressIOError.self) { try missingSink.pump() }
    #expect(missingSink.snapshot.failure != nil && missingSink.snapshot.queuedReplies == 1)
  }

  @Test("overflowing, mismatching or premature guest completion cannot be accepted")
  func completionBoundsAndPendingReplies() throws {
    let cases: [(UInt64, UInt64, UInt64)] = [
      (UInt64.max, UInt64.max, UInt64.max),
      (4095, 4095 * 1024, 5_000_000_000),
      (4096, 4096 * 1024 - 1, 5_000_000_000),
      (4096, 4096 * 1024, 4_999_999_999),
      (4096, 4096 * 1024, 30_000_000_001),
      (4096, 4096 * 1024, 5_000_000_000),
    ]
    for (frames, bytes, elapsed) in cases {
      let peer = PVHStressNetworkPeer(runID: runID)
      try peer.transmit(frame: frame(sequence: 0))
      #expect(throws: PVHStressIOError.self) {
        _ = try peer.verifyCompletion(guestFrames: frames, guestBytes: bytes, guestElapsedNanoseconds: elapsed)
      }
      #expect(!peer.snapshot.verified && peer.snapshot.failure != nil)
      #expect(peer.snapshot.queuedReplies == 1 && peer.snapshot.guestReportedElapsedNanoseconds == nil)
    }
  }

  @Test("receive ownership cannot be replaced and recursive pumping cannot reorder replies")
  func receiveOwnershipAndPumpReentrancy() throws {
    let replaced = PVHStressNetworkPeer(runID: runID)
    replaced.connectReceiveSink { _ in }
    replaced.connectReceiveSink { _ in }
    #expect(throws: PVHStressIOError.self) { try replaced.transmit(frame: frame(sequence: 0)) }
    #expect(replaced.snapshot.failure == "receive sink replaced" && replaced.snapshot.acceptedFrames == 0)

    let recursive = PVHStressNetworkPeer(runID: runID)
    let receiver = Receiver()
    recursive.connectReceiveSink { frame in
      receiver.receive(frame, queued: recursive.snapshot.queuedReplies)
      _ = try? recursive.pump()
    }
    try recursive.transmit(frame: frame(sequence: 0))
    try recursive.transmit(frame: frame(sequence: 1))
    #expect(throws: PVHStressIOError.self) { try recursive.pump() }
    #expect(receiver.count == 1 && recursive.snapshot.deliveredReplies == 1)
    #expect(recursive.snapshot.failure != nil && !recursive.snapshot.verified)
  }

  private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("dory-stress-io-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
  }

  // Construct independently from literal protocol fields, including canonical UUID
  // text decoding rather than the production UUID tuple conversion.
  private func frame(sequence: UInt32) -> [UInt8] {
    var bytes: [UInt8] = [2, 0xD0, 0x52, 0, 0, 2, 2, 0xD0, 0x52, 0, 0, 1, 0x88, 0xB5]
    bytes += Array("DORYIO01".utf8)
    let hex = Array(runID.uuidString.replacingOccurrences(of: "-", with: ""))
    for index in stride(from: 0, to: hex.count, by: 2) {
      bytes.append(UInt8(String(hex[index...index + 1]), radix: 16)!)
    }
    for shift in [24, 16, 8, 0] { bytes.append(UInt8(truncatingIfNeeded: sequence >> shift)) }
    bytes += [3, 0xD4]
    bytes += (0..<980).map { UInt8(truncatingIfNeeded: UInt64(sequence) * 17 + UInt64($0 * 37 + ($0 >> 8))) }
    return bytes
  }

  private final class Receiver: @unchecked Sendable {
    private let lock = NSLock()
    private var received = 0
    private var frame: [UInt8] = []
    private var queued = 0
    func receive(_ frame: [UInt8], queued: Int) { lock.withLock { received += 1; self.frame = frame; self.queued = queued } }
    var count: Int { lock.withLock { received } }
    var lastFrame: [UInt8] { lock.withLock { frame } }
    var lastQueued: Int { lock.withLock { queued } }
  }
}
