import Foundation

extension DoryVirtioFeatures {
  public static let blockReadOnly = Self(rawValue: 1 << 5)
  public static let blockSize = Self(rawValue: 1 << 6)
  public static let blockFlush = Self(rawValue: 1 << 9)
  public static let blockDiscard = Self(rawValue: 1 << 13)
  public static let blockWriteZeroes = Self(rawValue: 1 << 14)
}

public protocol DoryVirtioBlockStorage: AnyObject, Sendable {
  var capacityBytes: UInt64 { get }
  var logicalBlockSize: UInt32 { get }
  var readOnly: Bool { get }
  func read(offset: UInt64, byteCount: Int) throws -> [UInt8]
  func write(offset: UInt64, bytes: [UInt8]) throws
  func flush() throws
  func discard(offset: UInt64, byteCount: UInt64) throws
  func writeZeroes(offset: UInt64, byteCount: UInt64, mayUnmap: Bool) throws
}

public enum DoryVirtioBlockError: Error, Sendable, Equatable {
  case invalidCapacity(UInt64)
  case malformedRequest
  case invalidDescriptorDirection
  case requestOutOfBounds(offset: UInt64, byteCount: UInt64)
  case invalidStorageResponse(expected: Int, actual: Int)
  case tooManyRangeSegments(Int)
}

public struct DoryVirtioBlockResult: Sendable, Hashable {
  public let bytesWritten: UInt32
  public let status: UInt8
}

public struct DoryVirtioBlockReadRange: Sendable, Hashable {
  public let offset: UInt64
  public let byteCount: UInt64

  public init(offset: UInt64, byteCount: UInt64) {
    self.offset = offset
    self.byteCount = byteCount
  }
}

/// Bounded, transport-neutral evidence for proving that firmware or a guest driver actually used a
/// block device. Recent read ranges deliberately retain offsets rather than payload bytes, so the
/// diagnostic cannot disclose guest data or grow with an installer image.
public struct DoryVirtioBlockDiagnostics: Sendable, Hashable {
  public let requestCount: UInt64
  public let successfulRequestCount: UInt64
  public let failedRequestCount: UInt64
  public let unsupportedRequestCount: UInt64
  public let readRequestCount: UInt64
  public let readByteCount: UInt64
  public let writeRequestCount: UInt64
  public let writeByteCount: UInt64
  public let flushRequestCount: UInt64
  public let discardRequestCount: UInt64
  public let discardedByteCount: UInt64
  public let writeZeroesRequestCount: UInt64
  public let writeZeroesByteCount: UInt64
  public let recentReadRanges: [DoryVirtioBlockReadRange]
}

/// Transport-neutral VirtIO block request engine with bounded scatter/gather and range commands.
public final class DoryVirtioBlockDevice: @unchecked Sendable {
  public static let sectorSize: UInt64 = 512
  public static let successStatus: UInt8 = 0
  public static let ioErrorStatus: UInt8 = 1
  public static let unsupportedStatus: UInt8 = 2

  public let storage: any DoryVirtioBlockStorage
  public let identifier: [UInt8]
  public let maximumRangeSegments: Int

  private static let maximumRecentReadRanges = 16
  private let diagnosticsLock = NSLock()
  private var requestCount: UInt64 = 0
  private var successfulRequestCount: UInt64 = 0
  private var failedRequestCount: UInt64 = 0
  private var unsupportedRequestCount: UInt64 = 0
  private var readRequestCount: UInt64 = 0
  private var readByteCount: UInt64 = 0
  private var writeRequestCount: UInt64 = 0
  private var writeByteCount: UInt64 = 0
  private var flushRequestCount: UInt64 = 0
  private var discardRequestCount: UInt64 = 0
  private var discardedByteCount: UInt64 = 0
  private var writeZeroesRequestCount: UInt64 = 0
  private var writeZeroesByteCount: UInt64 = 0
  private var recentReadRanges: [DoryVirtioBlockReadRange] = []

  public init(
    storage: any DoryVirtioBlockStorage,
    identifier: String,
    maximumRangeSegments: Int = 32
  ) throws {
    guard storage.capacityBytes % Self.sectorSize == 0,
      storage.logicalBlockSize >= 512,
      storage.logicalBlockSize.nonzeroBitCount == 1
    else { throw DoryVirtioBlockError.invalidCapacity(storage.capacityBytes) }
    self.storage = storage
    self.identifier = Array(identifier.utf8.prefix(20))
    self.maximumRangeSegments = min(Int(UInt32.max), max(1, maximumRangeSegments))
  }

  public var offeredFeatures: DoryVirtioFeatures {
    var features: DoryVirtioFeatures = [.blockSize, .blockFlush, .blockDiscard, .blockWriteZeroes]
    if storage.readOnly { features.insert(.blockReadOnly) }
    return features
  }

  public var configuration: [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 60)
    put(storage.capacityBytes / Self.sectorSize, at: 0, in: &bytes)
    put(UInt32(1 << 20), at: 8, in: &bytes)
    put(UInt32(126), at: 12, in: &bytes)
    put(storage.logicalBlockSize, at: 20, in: &bytes)
    put(UInt32.max, at: 36, in: &bytes)
    put(UInt32(maximumRangeSegments), at: 40, in: &bytes)
    put(UInt32(1), at: 44, in: &bytes)
    put(UInt32.max, at: 48, in: &bytes)
    put(UInt32(maximumRangeSegments), at: 52, in: &bytes)
    bytes[56] = 1
    return bytes
  }

  public var diagnostics: DoryVirtioBlockDiagnostics {
    diagnosticsLock.withLock {
      .init(
        requestCount: requestCount,
        successfulRequestCount: successfulRequestCount,
        failedRequestCount: failedRequestCount,
        unsupportedRequestCount: unsupportedRequestCount,
        readRequestCount: readRequestCount,
        readByteCount: readByteCount,
        writeRequestCount: writeRequestCount,
        writeByteCount: writeByteCount,
        flushRequestCount: flushRequestCount,
        discardRequestCount: discardRequestCount,
        discardedByteCount: discardedByteCount,
        writeZeroesRequestCount: writeZeroesRequestCount,
        writeZeroesByteCount: writeZeroesByteCount,
        recentReadRanges: recentReadRanges
      )
    }
  }

  public func process(
    _ chain: DoryVirtioDescriptorChain,
    memory: any DoryVirtioGuestMemory
  ) throws -> DoryVirtioBlockResult {
    guard chain.descriptors.count >= 2,
      let headerDescriptor = chain.descriptors.first,
      let statusDescriptor = chain.descriptors.last,
      headerDescriptor.length == 16,
      !headerDescriptor.deviceWillWrite,
      statusDescriptor.deviceWillWrite,
      statusDescriptor.length >= 1
    else { throw DoryVirtioBlockError.malformedRequest }

    let header = try exactRead(memory, descriptor: headerDescriptor)
    let requestType = uint32(header, at: 0)
    let sector = uint64(header, at: 8)
    let payload = Array(chain.descriptors.dropFirst().dropLast())
    recordRequest()
    let result: DoryVirtioBlockResult
    do {
      result = try execute(type: requestType, sector: sector, payload: payload, memory: memory)
    } catch DoryVirtioBlockError.invalidDescriptorDirection {
      result = .init(bytesWritten: 1, status: Self.ioErrorStatus)
    } catch {
      result = .init(bytesWritten: 1, status: Self.ioErrorStatus)
    }
    recordCompletion(status: result.status)
    try memory.write(at: statusDescriptor.address, bytes: [result.status])
    return result
  }

  private func execute(
    type: UInt32,
    sector: UInt64,
    payload: [DoryVirtioDescriptor],
    memory: any DoryVirtioGuestMemory
  ) throws -> DoryVirtioBlockResult {
    switch type {
    case 0:
      try requireDirection(payload, deviceWillWrite: true)
      let byteCount = try totalLength(payload)
      guard byteCount > 0, byteCount % Self.sectorSize == 0 else {
        throw DoryVirtioBlockError.malformedRequest
      }
      let offset = try checkedOffset(sector: sector, byteCount: byteCount)
      let bytes = try storage.read(offset: offset, byteCount: Int(byteCount))
      guard bytes.count == Int(byteCount) else {
        throw DoryVirtioBlockError.invalidStorageResponse(
          expected: Int(byteCount), actual: bytes.count)
      }
      try scatter(bytes, into: payload, memory: memory)
      recordRead(offset: offset, byteCount: byteCount)
      return .init(bytesWritten: UInt32(byteCount) + 1, status: Self.successStatus)
    case 1:
      guard !storage.readOnly else {
        return .init(bytesWritten: 1, status: Self.ioErrorStatus)
      }
      try requireDirection(payload, deviceWillWrite: false)
      let bytes = try gather(payload, memory: memory)
      guard !bytes.isEmpty, bytes.count % Int(Self.sectorSize) == 0 else {
        throw DoryVirtioBlockError.malformedRequest
      }
      let offset = try checkedOffset(sector: sector, byteCount: UInt64(bytes.count))
      try storage.write(offset: offset, bytes: bytes)
      recordWrite(byteCount: UInt64(bytes.count))
      return .init(bytesWritten: 1, status: Self.successStatus)
    case 4:
      guard payload.isEmpty else { throw DoryVirtioBlockError.malformedRequest }
      try storage.flush()
      diagnosticsLock.withLock { flushRequestCount = Self.saturatingAdd(flushRequestCount, 1) }
      return .init(bytesWritten: 1, status: Self.successStatus)
    case 8:
      try requireDirection(payload, deviceWillWrite: true)
      let writable = try totalLength(payload)
      var id = [UInt8](repeating: 0, count: min(20, Int(writable)))
      id.replaceSubrange(0..<min(id.count, identifier.count), with: identifier.prefix(id.count))
      try scatter(id, into: payload, memory: memory)
      return .init(bytesWritten: UInt32(id.count) + 1, status: Self.successStatus)
    case 11:
      guard !storage.readOnly else {
        return .init(bytesWritten: 1, status: Self.ioErrorStatus)
      }
      try requireDirection(payload, deviceWillWrite: false)
      try executeRanges(try gather(payload, memory: memory), zeroes: false)
      return .init(bytesWritten: 1, status: Self.successStatus)
    case 13:
      guard !storage.readOnly else {
        return .init(bytesWritten: 1, status: Self.ioErrorStatus)
      }
      try requireDirection(payload, deviceWillWrite: false)
      try executeRanges(try gather(payload, memory: memory), zeroes: true)
      return .init(bytesWritten: 1, status: Self.successStatus)
    default:
      diagnosticsLock.withLock {
        unsupportedRequestCount = Self.saturatingAdd(unsupportedRequestCount, 1)
      }
      return .init(bytesWritten: 1, status: Self.unsupportedStatus)
    }
  }

  private func executeRanges(_ bytes: [UInt8], zeroes: Bool) throws {
    guard !bytes.isEmpty, bytes.count % 16 == 0 else {
      throw DoryVirtioBlockError.malformedRequest
    }
    let count = bytes.count / 16
    guard count <= maximumRangeSegments else {
      throw DoryVirtioBlockError.tooManyRangeSegments(count)
    }
    diagnosticsLock.withLock {
      if zeroes {
        writeZeroesRequestCount = Self.saturatingAdd(writeZeroesRequestCount, 1)
      } else {
        discardRequestCount = Self.saturatingAdd(discardRequestCount, 1)
      }
    }
    for index in 0..<count {
      let base = index * 16
      let sector = uint64(bytes, at: base)
      let sectors = uint32(bytes, at: base + 8)
      let flags = uint32(bytes, at: base + 12)
      guard sectors > 0, zeroes ? flags & ~1 == 0 : flags == 0 else {
        throw DoryVirtioBlockError.malformedRequest
      }
      let byteCount = UInt64(sectors) * Self.sectorSize
      let offset = try checkedOffset(sector: sector, byteCount: byteCount)
      if zeroes {
        try storage.writeZeroes(offset: offset, byteCount: byteCount, mayUnmap: flags & 1 != 0)
        diagnosticsLock.withLock {
          writeZeroesByteCount = Self.saturatingAdd(writeZeroesByteCount, byteCount)
        }
      } else {
        try storage.discard(offset: offset, byteCount: byteCount)
        diagnosticsLock.withLock {
          discardedByteCount = Self.saturatingAdd(discardedByteCount, byteCount)
        }
      }
    }
  }

  private func checkedOffset(sector: UInt64, byteCount: UInt64) throws -> UInt64 {
    let (offset, multiplyOverflow) = sector.multipliedReportingOverflow(by: Self.sectorSize)
    let (end, addOverflow) = offset.addingReportingOverflow(byteCount)
    guard !multiplyOverflow, !addOverflow, end <= storage.capacityBytes else {
      throw DoryVirtioBlockError.requestOutOfBounds(offset: offset, byteCount: byteCount)
    }
    return offset
  }

  private func requireDirection(
    _ descriptors: [DoryVirtioDescriptor],
    deviceWillWrite: Bool
  ) throws {
    guard !descriptors.isEmpty, descriptors.allSatisfy({ $0.deviceWillWrite == deviceWillWrite })
    else { throw DoryVirtioBlockError.invalidDescriptorDirection }
  }

  private func totalLength(_ descriptors: [DoryVirtioDescriptor]) throws -> UInt64 {
    try descriptors.reduce(0) { total, descriptor in
      let (updated, overflow) = total.addingReportingOverflow(UInt64(descriptor.length))
      guard !overflow, updated <= UInt64(UInt32.max - 1) else {
        throw DoryVirtioBlockError.malformedRequest
      }
      return updated
    }
  }

  private func gather(
    _ descriptors: [DoryVirtioDescriptor],
    memory: any DoryVirtioGuestMemory
  ) throws -> [UInt8] {
    var result: [UInt8] = []
    result.reserveCapacity(Int(try totalLength(descriptors)))
    for descriptor in descriptors { result += try exactRead(memory, descriptor: descriptor) }
    return result
  }

  private func scatter(
    _ bytes: [UInt8],
    into descriptors: [DoryVirtioDescriptor],
    memory: any DoryVirtioGuestMemory
  ) throws {
    var sourceOffset = 0
    for descriptor in descriptors where sourceOffset < bytes.count {
      let count = min(Int(descriptor.length), bytes.count - sourceOffset)
      try memory.write(
        at: descriptor.address,
        bytes: Array(bytes[sourceOffset..<(sourceOffset + count)])
      )
      sourceOffset += count
    }
    guard sourceOffset == bytes.count else { throw DoryVirtioBlockError.malformedRequest }
  }

  private func exactRead(
    _ memory: any DoryVirtioGuestMemory,
    descriptor: DoryVirtioDescriptor
  ) throws -> [UInt8] {
    let bytes = try memory.read(at: descriptor.address, byteCount: Int(descriptor.length))
    guard bytes.count == Int(descriptor.length) else {
      throw DoryVirtioBlockError.invalidStorageResponse(
        expected: Int(descriptor.length), actual: bytes.count)
    }
    return bytes
  }

  private func recordRequest() {
    diagnosticsLock.withLock { requestCount = Self.saturatingAdd(requestCount, 1) }
  }

  private func recordCompletion(status: UInt8) {
    diagnosticsLock.withLock {
      if status == Self.successStatus {
        successfulRequestCount = Self.saturatingAdd(successfulRequestCount, 1)
      } else if status != Self.unsupportedStatus {
        failedRequestCount = Self.saturatingAdd(failedRequestCount, 1)
      }
    }
  }

  private func recordRead(offset: UInt64, byteCount: UInt64) {
    diagnosticsLock.withLock {
      readRequestCount = Self.saturatingAdd(readRequestCount, 1)
      readByteCount = Self.saturatingAdd(readByteCount, byteCount)
      recentReadRanges.append(.init(offset: offset, byteCount: byteCount))
      if recentReadRanges.count > Self.maximumRecentReadRanges {
        recentReadRanges.removeFirst(recentReadRanges.count - Self.maximumRecentReadRanges)
      }
    }
  }

  private func recordWrite(byteCount: UInt64) {
    diagnosticsLock.withLock {
      writeRequestCount = Self.saturatingAdd(writeRequestCount, 1)
      writeByteCount = Self.saturatingAdd(writeByteCount, byteCount)
    }
  }

  private static func saturatingAdd(_ value: UInt64, _ increment: UInt64) -> UInt64 {
    let (result, overflow) = value.addingReportingOverflow(increment)
    return overflow ? .max : result
  }
}

public final class DoryVirtioInMemoryBlockStorage: DoryVirtioBlockStorage, @unchecked Sendable {
  public let logicalBlockSize: UInt32
  public let readOnly: Bool

  private let lock = NSLock()
  private var bytes: [UInt8]
  private var flushes = 0

  public init(
    byteCount: Int,
    logicalBlockSize: UInt32 = 512,
    readOnly: Bool = false,
    initialBytes: [UInt8] = []
  ) {
    precondition(byteCount >= 0 && initialBytes.count <= byteCount)
    self.logicalBlockSize = logicalBlockSize
    self.readOnly = readOnly
    bytes = initialBytes + [UInt8](repeating: 0, count: byteCount - initialBytes.count)
  }

  public var capacityBytes: UInt64 { lock.withLock { UInt64(bytes.count) } }
  public var flushCount: Int { lock.withLock { flushes } }

  public func read(offset: UInt64, byteCount: Int) throws -> [UInt8] {
    try lock.withLock { Array(bytes[try range(offset: offset, byteCount: UInt64(byteCount))]) }
  }

  public func write(offset: UInt64, bytes: [UInt8]) throws {
    guard !readOnly else { throw DoryVirtioBlockError.malformedRequest }
    try lock.withLock {
      self.bytes.replaceSubrange(
        try range(offset: offset, byteCount: UInt64(bytes.count)), with: bytes)
    }
  }

  public func flush() throws { lock.withLock { flushes += 1 } }

  public func discard(offset: UInt64, byteCount: UInt64) throws {
    try writeZeroes(offset: offset, byteCount: byteCount, mayUnmap: true)
  }

  public func writeZeroes(offset: UInt64, byteCount: UInt64, mayUnmap: Bool) throws {
    guard !readOnly else { throw DoryVirtioBlockError.malformedRequest }
    try lock.withLock {
      let range = try range(offset: offset, byteCount: byteCount)
      bytes.replaceSubrange(range, with: repeatElement(0, count: range.count))
    }
  }

  private func range(offset: UInt64, byteCount: UInt64) throws -> Range<Int> {
    guard offset <= UInt64(bytes.count), byteCount <= UInt64(bytes.count) - offset else {
      throw DoryVirtioBlockError.requestOutOfBounds(offset: offset, byteCount: byteCount)
    }
    return Int(offset)..<Int(offset + byteCount)
  }
}

private func uint32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
  (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << UInt32($1 * 8) }
}

private func uint64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
  (0..<8).reduce(0) { $0 | UInt64(bytes[offset + $1]) << UInt64($1 * 8) }
}

private func put<T: FixedWidthInteger>(_ value: T, at offset: Int, in bytes: inout [UInt8]) {
  for index in 0..<MemoryLayout<T>.size {
    bytes[offset + index] = UInt8(truncatingIfNeeded: value >> T(index * 8))
  }
}
