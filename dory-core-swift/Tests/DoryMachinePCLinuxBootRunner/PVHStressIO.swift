import CryptoKit
import Darwin
import DoryVirtio
import Foundation

enum PVHStressIOError: Error, Equatable {
  case invalid(String)
  case systemCall(String, Int32)
}

struct PVHStressIOSnapshot: Codable, Sendable {
  let block: PVHStressBlockSnapshot
  let network: PVHStressNetworkSnapshot
}

struct PVHStressBlockSnapshot: Codable, Sendable {
  let runID: String
  let filePath: String
  let capacityBytes: UInt64
  let readRequests: UInt64
  let readBytes: UInt64
  let writeRequests: UInt64
  let writeBytes: UInt64
  let flushRequests: UInt64
  let discardRequests: UInt64
  let writeZeroesRequests: UInt64
  let zeroedBytes: UInt64
  let failure: String?
  let reopenedAndVerified: Bool
  let verifiedRegionSHA256: String?
}

/// A newly created diagnostic disk, retained after close for review. This is never
/// an adapter for an existing workload disk. All operation sizes are checked before IO.
final class PVHStressBlockStorage: DoryVirtioBlockStorage, @unchecked Sendable {
  static let diskByteCount: UInt64 = 32 << 20
  static let regionOffset: UInt64 = 1 << 20
  static let regionByteCount = 128 << 10
  static let maximumTransferBytes = 1 << 20
  static let maximumTransferredBytes: UInt64 = 256 << 20
  static let maximumRequests: UInt64 = 65_536
  let capacityBytes = diskByteCount
  let logicalBlockSize: UInt32 = 512
  let readOnly = false

  private let lock = NSLock()
  private let directoryFD: Int32
  private var fileFD: Int32
  private let device: dev_t
  private let inode: ino_t
  private let runID: String
  private let filePath: String
  private var readRequests: UInt64 = 0
  private var readBytes: UInt64 = 0
  private var writeRequests: UInt64 = 0
  private var writeBytes: UInt64 = 0
  private var flushRequests: UInt64 = 0
  private var discardRequests: UInt64 = 0
  private var writeZeroesRequests: UInt64 = 0
  private var zeroedBytes: UInt64 = 0
  private var failure: String?
  private var verified = false
  private var regionSHA256: String?

  init(newDirectory: URL, runID: UUID) throws {
    let path = newDirectory.path
    guard newDirectory.isFileURL, path.hasPrefix("/"), !path.utf8.contains(0),
      path.utf8.count < Int(PATH_MAX) - 32,
      Self.regionOffset + UInt64(Self.regionByteCount) <= Self.diskByteCount
    else { throw PVHStressIOError.invalid("fresh diagnostic directory") }
    // mkdir fails for an existing directory, file or symlink. Never remove or replace it.
    guard mkdir(path, 0o700) == 0 else { throw PVHStressIOError.systemCall("mkdir", errno) }
    let directoryFD = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard directoryFD >= 0 else { throw PVHStressIOError.systemCall("open directory", errno) }
    let fileFD = openat(directoryFD, "virtio-block.raw", O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard fileFD >= 0 else {
      let saved = errno; close(directoryFD)
      throw PVHStressIOError.systemCall("create disk", saved)
    }
    do {
      guard ftruncate(fileFD, off_t(Self.diskByteCount)) == 0 else {
        throw PVHStressIOError.systemCall("size disk", errno)
      }
      var identity = stat()
      guard fstat(fileFD, &identity) == 0 else { throw PVHStressIOError.systemCall("stat disk", errno) }
      guard identity.st_mode & S_IFMT == S_IFREG, identity.st_nlink == 1,
        identity.st_size == off_t(Self.diskByteCount)
      else { throw PVHStressIOError.invalid("created disk identity") }
      self.directoryFD = directoryFD
      self.fileFD = fileFD
      device = identity.st_dev
      inode = identity.st_ino
      self.runID = runID.uuidString.lowercased()
      filePath = newDirectory.appendingPathComponent("virtio-block.raw").path
    } catch {
      close(fileFD); close(directoryFD)
      throw error
    }
  }

  deinit {
    if fileFD >= 0 { close(fileFD) }
    close(directoryFD)
  }

  var snapshot: PVHStressBlockSnapshot {
    lock.withLock { makeSnapshot() }
  }

  static func expectedRegion() -> [UInt8] {
    (0..<regionByteCount).map { UInt8(truncatingIfNeeded: $0 * 37 + ($0 >> 8)) }
  }

  func read(offset: UInt64, byteCount: Int) throws -> [UInt8] {
    try operation {
      try validate(offset: offset, byteCount: byteCount)
      readRequests += 1
      var bytes = [UInt8](repeating: 0, count: byteCount)
      try bytes.withUnsafeMutableBytes { buffer in
        var completed = 0
        while completed < byteCount {
          let count = pread(fileFD, buffer.baseAddress!.advanced(by: completed), byteCount - completed, off_t(offset) + off_t(completed))
          if count < 0, errno == EINTR { continue }
          guard count > 0 else { throw PVHStressIOError.systemCall("pread", count < 0 ? errno : EIO) }
          completed += count; readBytes += UInt64(count)
        }
      }
      return bytes
    }
  }

  func write(offset: UInt64, bytes: [UInt8]) throws {
    try operation {
      try validate(offset: offset, byteCount: bytes.count)
      writeRequests += 1
      try bytes.withUnsafeBytes { buffer in
        var completed = 0
        while completed < bytes.count {
          let count = pwrite(fileFD, buffer.baseAddress!.advanced(by: completed), bytes.count - completed, off_t(offset) + off_t(completed))
          if count < 0, errno == EINTR { continue }
          guard count > 0 else { throw PVHStressIOError.systemCall("pwrite", count < 0 ? errno : EIO) }
          completed += count; writeBytes += UInt64(count)
        }
      }
    }
  }

  func flush() throws {
    try operation {
      try validateRequestBudget()
      guard fsync(fileFD) == 0 else { throw PVHStressIOError.systemCall("fsync", errno) }
      flushRequests += 1
    }
  }

  func discard(offset: UInt64, byteCount: UInt64) throws {
    try zeroRange(offset: offset, byteCount: byteCount, discard: true)
  }

  func writeZeroes(offset: UInt64, byteCount: UInt64, mayUnmap: Bool) throws {
    // Zeroing is valid whether or not the guest permits deallocation.
    try zeroRange(offset: offset, byteCount: byteCount, discard: false)
  }

  /// The root calls only after the guest's independently observed poweroff. A fresh
  /// descriptor must see the same owned inode and exact pattern; closing is not counted
  /// as a guest flush, and verification performs no compensating write or fsync.
  func verifyAfterPoweroff() throws -> PVHStressBlockSnapshot {
    try operation {
      guard flushRequests >= 1, writeBytes >= UInt64(Self.regionByteCount) else {
        throw PVHStressIOError.invalid("missing guest disk write/flush")
      }
      let oldFD = fileFD; fileFD = -1
      guard close(oldFD) == 0 else { throw PVHStressIOError.systemCall("close disk", errno) }
      let reopened = openat(directoryFD, "virtio-block.raw", O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
      guard reopened >= 0 else { throw PVHStressIOError.systemCall("reopen disk", errno) }
      defer { close(reopened) }
      var identity = stat()
      guard fstat(reopened, &identity) == 0 else { throw PVHStressIOError.systemCall("stat reopened disk", errno) }
      guard identity.st_dev == device, identity.st_ino == inode,
        identity.st_mode & S_IFMT == S_IFREG, identity.st_nlink == 1,
        identity.st_size == off_t(Self.diskByteCount)
      else { throw PVHStressIOError.invalid("reopened disk identity changed") }
      var bytes = [UInt8](repeating: 0, count: Self.regionByteCount)
      try bytes.withUnsafeMutableBytes { buffer in
        var completed = 0
        while completed < buffer.count {
          let count = pread(reopened, buffer.baseAddress!.advanced(by: completed), buffer.count - completed, off_t(Self.regionOffset) + off_t(completed))
          if count < 0, errno == EINTR { continue }
          guard count > 0 else { throw PVHStressIOError.systemCall("verify pread", count < 0 ? errno : EIO) }
          completed += count
        }
      }
      guard bytes == Self.expectedRegion() else { throw PVHStressIOError.invalid("reopened disk pattern mismatch") }
      verified = true
      regionSHA256 = SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
      return makeSnapshot()
    }
  }

  private func operation<T>(_ body: () throws -> T) throws -> T {
    try lock.withLock {
      guard failure == nil, fileFD >= 0 else { throw PVHStressIOError.invalid("disk closed or failed") }
      do { return try body() }
      catch { failure = String(String(describing: error).prefix(160)); throw error }
    }
  }

  private func validateRequestBudget() throws {
    guard readRequests + writeRequests + flushRequests + discardRequests + writeZeroesRequests < Self.maximumRequests else {
      throw PVHStressIOError.invalid("disk request budget")
    }
  }

  private func validate(offset: UInt64, byteCount: Int) throws {
    guard byteCount >= 0, byteCount <= Self.maximumTransferBytes else {
      throw PVHStressIOError.invalid("disk transfer size")
    }
    try validateRange(offset: offset, byteCount: UInt64(byteCount))
  }

  private func validateRange(offset: UInt64, byteCount: UInt64) throws {
    try validateRequestBudget()
    guard offset <= capacityBytes, byteCount <= capacityBytes - offset,
      byteCount <= Self.maximumTransferredBytes - readBytes - writeBytes - zeroedBytes
    else { throw PVHStressIOError.invalid("disk range/transfer budget") }
  }

  private func zeroRange(offset: UInt64, byteCount: UInt64, discard: Bool) throws {
    try operation {
      // The whole range and remaining transfer budget are checked before the first
      // write. Discard may legally return zeros; no host hole-punch API is required.
      try validateRange(offset: offset, byteCount: byteCount)
      if discard { discardRequests += 1 } else { writeZeroesRequests += 1 }
      let zeros = [UInt8](repeating: 0, count: 64 << 10)
      try zeros.withUnsafeBytes { buffer in
        var completed: UInt64 = 0
        while completed < byteCount {
          let requested = Int(min(byteCount - completed, UInt64(buffer.count)))
          let count = pwrite(fileFD, buffer.baseAddress!, requested, off_t(offset + completed))
          if count < 0, errno == EINTR { continue }
          guard count > 0 else { throw PVHStressIOError.systemCall("zero pwrite", count < 0 ? errno : EIO) }
          completed += UInt64(count); zeroedBytes += UInt64(count)
        }
      }
    }
  }

  private func makeSnapshot() -> PVHStressBlockSnapshot {
    .init(runID: runID, filePath: filePath, capacityBytes: capacityBytes,
      readRequests: readRequests, readBytes: readBytes, writeRequests: writeRequests,
      writeBytes: writeBytes, flushRequests: flushRequests,
      discardRequests: discardRequests, writeZeroesRequests: writeZeroesRequests,
      zeroedBytes: zeroedBytes, failure: failure,
      reopenedAndVerified: verified, verifiedRegionSHA256: regionSHA256)
  }
}

struct PVHStressNetworkSnapshot: Codable, Sendable {
  let runID: String
  let acceptedFrames: UInt64
  let acceptedBytes: UInt64
  let deliveredReplies: UInt64
  let queuedReplies: Int
  let ignoredFrames: UInt64
  let failure: String?
  let guestReportedElapsedNanoseconds: UInt64?
  let verified: Bool
  let timingScope: String
}

/// An isolated Ethernet echo peer. It never opens host network sockets, and transmit
/// never calls the receive sink. The root pumps replies between machine quanta.
final class PVHStressNetworkPeer: DoryVirtioNetworkBackend, @unchecked Sendable {
  static let guestMAC: [UInt8] = [0x02, 0xD0, 0x52, 0, 0, 1]
  static let peerMAC: [UInt8] = [0x02, 0xD0, 0x52, 0, 0, 2]
  static let frameByteCount = 1024
  static let minimumFrames: UInt64 = 4096
  static let maximumFrames: UInt64 = 16384
  static let maximumQueuedReplies = 64
  private let lock = NSLock()
  private let runID: UUID
  private let uuidBytes: [UInt8]
  private var sink: (@Sendable ([UInt8]) -> Void)?
  private var replies: [[UInt8]] = []
  private var accepted: UInt64 = 0
  private var delivered: UInt64 = 0
  private var ignored: UInt64 = 0
  private var failure: String?
  private var guestElapsed: UInt64?
  private var verified = false
  private var pumping = false

  init(runID: UUID) {
    self.runID = runID
    var bytes = runID.uuid
    uuidBytes = withUnsafeBytes(of: &bytes) { Array($0) }
  }

  var snapshot: PVHStressNetworkSnapshot { lock.withLock { makeSnapshot() } }

  func connectReceiveSink(_ sink: @escaping @Sendable ([UInt8]) -> Void) {
    lock.withLock {
      if self.sink != nil { failure = failure ?? "receive sink replaced" }
      else { self.sink = sink }
    }
  }

  func transmit(frame: [UInt8]) throws {
    try lock.withLock {
      guard failure == nil, !verified else { throw PVHStressIOError.invalid("network completed or failed") }
      do {
        guard (14...1518).contains(frame.count) else { throw PVHStressIOError.invalid("Ethernet frame length") }
        if frame[12] != 0x88 || frame[13] != 0xB5 {
          guard ignored < 64 else { throw PVHStressIOError.invalid("unrelated frame budget") }
          ignored += 1
          return
        }
        guard accepted < Self.maximumFrames, replies.count < Self.maximumQueuedReplies,
          frame.count == Self.frameByteCount,
          Array(frame[0..<6]) == Self.peerMAC, Array(frame[6..<12]) == Self.guestMAC,
          Array(frame[14..<22]) == Array("DORYIO01".utf8), Array(frame[22..<38]) == uuidBytes,
          frame[42] == 3, frame[43] == 0xD4
        else { throw PVHStressIOError.invalid("diagnostic frame identity/queue budget") }
        let sequence = frame[38..<42].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard UInt64(sequence) == accepted else { throw PVHStressIOError.invalid("diagnostic sequence") }
        for index in 0..<980 {
          guard frame[44 + index] == UInt8(truncatingIfNeeded: UInt64(sequence) * 17 + UInt64(index * 37 + (index >> 8)))
          else { throw PVHStressIOError.invalid("diagnostic payload") }
        }
        var reply = frame
        reply.replaceSubrange(0..<6, with: Self.guestMAC)
        reply.replaceSubrange(6..<12, with: Self.peerMAC)
        replies.append(reply)
        accepted += 1
      } catch { failure = String(String(describing: error).prefix(160)); throw error }
    }
  }

  @discardableResult
  func pump(maximumFrames: Int = maximumQueuedReplies) throws -> Int {
    let delivery: ((@Sendable ([UInt8]) -> Void), [[UInt8]])? = try lock.withLock {
      guard failure == nil else { throw PVHStressIOError.invalid("network failed") }
      do {
        guard (1...Self.maximumQueuedReplies).contains(maximumFrames), !pumping else {
          throw PVHStressIOError.invalid("reply pump budget/reentrancy")
        }
        guard !replies.isEmpty else { return nil }
        guard let sink else { throw PVHStressIOError.invalid("receive sink absent") }
        let frames = Array(replies.prefix(maximumFrames))
        replies.removeFirst(frames.count)
        pumping = true
        return (sink, frames)
      } catch { failure = String(String(describing: error).prefix(160)); throw error }
    }
    guard let delivery else { return 0 }
    defer { lock.withLock { pumping = false } }
    for frame in delivery.1 {
      delivery.0(frame) // No backend lock or VM transport lock is held here.
      try lock.withLock {
        delivered += 1
        guard failure == nil else { throw PVHStressIOError.invalid("network failed during delivery") }
      }
    }
    return delivery.1.count
  }

  func verifyCompletion(
    guestFrames: UInt64, guestBytes: UInt64, guestElapsedNanoseconds: UInt64
  ) throws -> PVHStressNetworkSnapshot {
    try lock.withLock {
      guard failure == nil else { throw PVHStressIOError.invalid("network failed") }
      do {
        guard !verified, !pumping,
          (Self.minimumFrames...Self.maximumFrames).contains(guestFrames),
          guestBytes == guestFrames * UInt64(Self.frameByteCount),
          (5_000_000_000...30_000_000_000).contains(guestElapsedNanoseconds),
          accepted == guestFrames, delivered == guestFrames, replies.isEmpty
        else { throw PVHStressIOError.invalid("network completion counts/duration") }
        guestElapsed = guestElapsedNanoseconds
        verified = true
        return makeSnapshot()
      } catch { failure = String(String(describing: error).prefix(160)); throw error }
    }
  }

  private func makeSnapshot() -> PVHStressNetworkSnapshot {
    .init(runID: runID.uuidString.lowercased(), acceptedFrames: accepted,
      acceptedBytes: accepted * UInt64(Self.frameByteCount), deliveredReplies: delivered,
      queuedReplies: replies.count, ignoredFrames: ignored, failure: failure,
      guestReportedElapsedNanoseconds: guestElapsed, verified: verified,
      timingScope: "Duration comes from the guest workload result; this backend does not independently measure guest time.")
  }
}
