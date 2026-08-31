import Foundation

public enum DoryX86MemoryAccessKind: String, Codable, Sendable, Hashable {
  case instructionFetch
  case read
  case write

  public func hash(into hasher: inout Hasher) {
    let discriminator: UInt8 =
      switch self {
      case .instructionFetch: 0
      case .read: 1
      case .write: 2
      }
    hasher.combine(discriminator)
  }
}

public enum DoryX86MemoryError: Error, Codable, Sendable, Hashable, CustomStringConvertible {
  case unmapped(address: UInt64, byteCount: Int, access: DoryX86MemoryAccessKind)
  case addressOverflow(address: UInt64, byteCount: Int)
  case pageFault(address: UInt64, errorCode: UInt32)

  public var description: String {
    switch self {
    case .unmapped(let address, let byteCount, let access):
      "x86 \(access.rawValue) touches unmapped memory at 0x\(String(address, radix: 16)) for \(byteCount) bytes"
    case .addressOverflow(let address, let byteCount):
      "x86 memory access overflows at 0x\(String(address, radix: 16)) for \(byteCount) bytes"
    case .pageFault(let address, let errorCode):
      "x86 page fault at 0x\(String(address, radix: 16)) with error code 0x\(String(errorCode, radix: 16))"
    }
  }
}

public protocol DoryX86Memory: AnyObject, Sendable {
  /// Returns up to `maximumCount` bytes without faulting merely because a shorter instruction ends
  /// at the mapping boundary. The decoder decides whether the returned instruction is truncated.
  func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8]
  func read(at address: UInt64, byteCount: Int) throws -> [UInt8]
  func write(at address: UInt64, bytes: [UInt8]) throws
  /// Proves that a complete write can commit before an instruction exposes any memory changes.
  func validateWrite(at address: UInt64, byteCount: Int) throws
  /// Joins prior and subsequent accesses at the memory implementation's ordering boundary.
  func synchronize()
}

/// Optional exact fast path for forward, non-overlapping string copies. Implementations return
/// `nil` before mutation when either starting address is not proven ordinary RAM or when the
/// resolved backing ranges overlap. A positive result is a fully committed prefix, allowing the
/// interpreter to expose precise REP progress before retrying the next page or mapping boundary
/// through the architectural scalar path.
public protocol DoryX86BulkMemory: DoryX86Memory {
  /// Returns a positive prefix that is proven ordinary RAM without performing I/O or mutation.
  func bulkCopyRAMSpan(at address: UInt64, maximumByteCount: Int) -> Int?

  func copyForwardNonoverlapping(
    from sourceAddress: UInt64,
    to destinationAddress: UInt64,
    maximumByteCount: Int
  ) throws -> Int?
}

extension DoryX86Memory {
  public func validateWrite(at address: UInt64, byteCount: Int) throws {
    _ = try read(at: address, byteCount: byteCount)
  }

  public func synchronize() {}
}

/// Deterministic flat address space for interpreter conformance, firmware bring-up, and replay.
/// Product paging composes a translator in front of the same protocol rather than weakening this
/// exact bounds behavior.
public final class DoryX86ByteArrayMemory: DoryX86Memory, @unchecked Sendable {
  public let baseAddress: UInt64
  private let lock = NSLock()
  private var storage: [UInt8]

  public init(baseAddress: UInt64 = 0, bytes: [UInt8]) {
    self.baseAddress = baseAddress
    storage = bytes
  }

  public convenience init(baseAddress: UInt64 = 0, byteCount: Int) {
    self.init(baseAddress: baseAddress, bytes: .init(repeating: 0, count: byteCount))
  }

  public func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8] {
    guard maximumCount > 0 else { return [] }
    lock.lock()
    defer { lock.unlock() }
    let offset = try checkedOffset(address: address, byteCount: 1, access: .instructionFetch)
    return Array(storage[offset..<min(storage.count, offset + maximumCount)])
  }

  public func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    guard byteCount > 0 else { return [] }
    lock.lock()
    defer { lock.unlock() }
    let offset = try checkedOffset(address: address, byteCount: byteCount, access: .read)
    return Array(storage[offset..<(offset + byteCount)])
  }

  public func write(at address: UInt64, bytes: [UInt8]) throws {
    guard !bytes.isEmpty else { return }
    lock.lock()
    defer { lock.unlock() }
    let offset = try checkedOffset(address: address, byteCount: bytes.count, access: .write)
    storage.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
  }

  public func validateWrite(at address: UInt64, byteCount: Int) throws {
    guard byteCount > 0 else { return }
    lock.lock()
    defer { lock.unlock() }
    _ = try checkedOffset(address: address, byteCount: byteCount, access: .write)
  }

  public func synchronize() {
    lock.lock()
    lock.unlock()
  }

  public func snapshot() -> [UInt8] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }

  private func checkedOffset(
    address: UInt64,
    byteCount: Int,
    access: DoryX86MemoryAccessKind
  ) throws -> Int {
    guard byteCount >= 0,
      !address.addingReportingOverflow(UInt64(byteCount)).overflow
    else {
      throw DoryX86MemoryError.addressOverflow(address: address, byteCount: byteCount)
    }
    guard address >= baseAddress else {
      throw DoryX86MemoryError.unmapped(address: address, byteCount: byteCount, access: access)
    }
    let distance = address - baseAddress
    guard distance <= UInt64(Int.max) else {
      throw DoryX86MemoryError.unmapped(address: address, byteCount: byteCount, access: access)
    }
    let offset = Int(distance)
    guard offset <= storage.count, byteCount <= storage.count - offset else {
      throw DoryX86MemoryError.unmapped(address: address, byteCount: byteCount, access: access)
    }
    return offset
  }
}

extension DoryX86ByteArrayMemory: DoryX86BulkMemory {
  public func bulkCopyRAMSpan(at address: UInt64, maximumByteCount: Int) -> Int? {
    guard maximumByteCount > 0 else { return 0 }
    return lock.withLock {
      guard address >= baseAddress else { return nil }
      let distance = address - baseAddress
      guard distance < UInt64(storage.count), distance <= UInt64(Int.max) else { return nil }
      return min(maximumByteCount, storage.count - Int(distance))
    }
  }

  public func copyForwardNonoverlapping(
    from sourceAddress: UInt64,
    to destinationAddress: UInt64,
    maximumByteCount: Int
  ) throws -> Int? {
    guard maximumByteCount > 0 else { return 0 }
    return lock.withLock {
      guard sourceAddress >= baseAddress, destinationAddress >= baseAddress else { return nil }
      let sourceDistance = sourceAddress - baseAddress
      let destinationDistance = destinationAddress - baseAddress
      guard sourceDistance < UInt64(storage.count), destinationDistance < UInt64(storage.count),
        sourceDistance <= UInt64(Int.max), destinationDistance <= UInt64(Int.max)
      else { return nil }
      let sourceOffset = Int(sourceDistance)
      let destinationOffset = Int(destinationDistance)
      let count = min(
        maximumByteCount,
        storage.count - sourceOffset,
        storage.count - destinationOffset
      )
      guard count > 0 else { return nil }
      guard sourceOffset + count <= destinationOffset || destinationOffset + count <= sourceOffset
      else { return nil }
      let bytes = Array(storage[sourceOffset..<(sourceOffset + count)])
      storage.replaceSubrange(destinationOffset..<(destinationOffset + count), with: bytes)
      return count
    }
  }
}
