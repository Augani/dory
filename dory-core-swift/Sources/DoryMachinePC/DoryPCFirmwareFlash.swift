import Foundation

public enum DoryPCFirmwareFlashError: Error, Sendable, Equatable {
  case emptyImage
  case imageTooLarge(maximum: UInt64, actual: Int)
  case unalignedImage(Int)
}

/// Immutable, erased-byte-padded firmware flash mapped at the top of the 32-bit address space.
/// Images smaller than the reserved DoryPC-v1 region are right-aligned so their architectural
/// reset vector remains at `0xfffffff0`.
public final class DoryPCFirmwareFlash: DoryPCMMIODevice, @unchecked Sendable {
  public let baseAddress = DoryPCV1ABI.firmwareCodeBase
  public let byteCount = DoryPCV1ABI.firmwareCodeBytes
  public let allowsInstructionFetch = true
  public let image: Data
  public let imageOffset: UInt64

  public init(image: Data) throws {
    guard !image.isEmpty else { throw DoryPCFirmwareFlashError.emptyImage }
    guard UInt64(image.count) <= byteCount else {
      throw DoryPCFirmwareFlashError.imageTooLarge(maximum: byteCount, actual: image.count)
    }
    guard image.count % 4_096 == 0 else {
      throw DoryPCFirmwareFlashError.unalignedImage(image.count)
    }
    self.image = image
    imageOffset = byteCount - UInt64(image.count)
  }

  public func read(offset: UInt64, byteCount: Int) throws -> [UInt8] {
    guard byteCount > 0, offset <= self.byteCount,
      UInt64(byteCount) <= self.byteCount - offset
    else {
      throw DoryPCPhysicalMemoryError.unsupportedAccess(
        offset: offset,
        byteCount: byteCount,
        write: false
      )
    }
    var result = [UInt8](repeating: 0xff, count: byteCount)
    let readStart = offset
    let readEnd = offset + UInt64(byteCount)
    let imageEnd = imageOffset + UInt64(image.count)
    let overlapStart = max(readStart, imageOffset)
    let overlapEnd = min(readEnd, imageEnd)
    if overlapStart < overlapEnd {
      let sourceStart = Int(overlapStart - imageOffset)
      let destinationStart = Int(overlapStart - readStart)
      let count = Int(overlapEnd - overlapStart)
      result.replaceSubrange(
        destinationStart..<(destinationStart + count),
        with: image[sourceStart..<(sourceStart + count)]
      )
    }
    return result
  }

  public func write(offset: UInt64, bytes: [UInt8]) throws {
    throw DoryPCPhysicalMemoryError.unsupportedAccess(
      offset: offset,
      byteCount: bytes.count,
      write: true
    )
  }

  public func validateWrite(offset: UInt64, byteCount: Int) throws {
    throw DoryPCPhysicalMemoryError.unsupportedAccess(
      offset: offset,
      byteCount: byteCount,
      write: true
    )
  }
}
