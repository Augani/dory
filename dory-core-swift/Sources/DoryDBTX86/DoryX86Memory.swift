import Foundation

public enum DoryX86MemoryAccessKind: String, Codable, Sendable, Hashable {
  case instructionFetch
  case read
  case write
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
