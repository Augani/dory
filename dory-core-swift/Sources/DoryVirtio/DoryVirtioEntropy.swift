import Foundation

public protocol DoryVirtioEntropySource: Sendable {
  func randomBytes(byteCount: Int) throws -> [UInt8]
}

public enum DoryVirtioEntropyError: Error, Sendable, Equatable {
  case emptyRequest
  case invalidDescriptorDirection
  case requestTooLarge(requested: UInt64, maximum: UInt64)
  case invalidSourceResponse(expected: Int, actual: Int)
}

public struct DoryVirtioSystemEntropySource: DoryVirtioEntropySource, Sendable {
  public init() {}

  public func randomBytes(byteCount: Int) throws -> [UInt8] {
    var generator = SystemRandomNumberGenerator()
    return (0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
  }
}

/// Transport-neutral VirtIO entropy device. Each request is preflighted and bounded before the
/// source is consumed, so hostile guests cannot turn malformed chains into unbounded host work.
public final class DoryVirtioEntropyDevice: @unchecked Sendable {
  public let source: any DoryVirtioEntropySource
  public let maximumRequestBytes: UInt64

  public init(
    source: any DoryVirtioEntropySource = DoryVirtioSystemEntropySource(),
    maximumRequestBytes: UInt64 = 1024 * 1024
  ) {
    precondition(maximumRequestBytes > 0 && maximumRequestBytes <= UInt64(UInt32.max))
    self.source = source
    self.maximumRequestBytes = maximumRequestBytes
  }

  public var offeredFeatures: DoryVirtioFeatures { [] }
  public var configuration: [UInt8] { [] }

  public func process(
    _ chain: DoryVirtioDescriptorChain,
    memory: any DoryVirtioGuestMemory
  ) throws -> UInt32 {
    guard !chain.descriptors.isEmpty else {
      throw DoryVirtioEntropyError.emptyRequest
    }
    guard chain.readableByteCount == 0,
      chain.descriptors.allSatisfy(\.deviceWillWrite)
    else { throw DoryVirtioEntropyError.invalidDescriptorDirection }
    guard chain.writableByteCount > 0 else {
      throw DoryVirtioEntropyError.emptyRequest
    }
    guard chain.writableByteCount <= maximumRequestBytes else {
      throw DoryVirtioEntropyError.requestTooLarge(
        requested: chain.writableByteCount,
        maximum: maximumRequestBytes
      )
    }
    for descriptor in chain.descriptors {
      try memory.validate(
        at: descriptor.address,
        byteCount: Int(descriptor.length),
        deviceWillWrite: true
      )
    }
    let byteCount = Int(chain.writableByteCount)
    let bytes = try source.randomBytes(byteCount: byteCount)
    guard bytes.count == byteCount else {
      throw DoryVirtioEntropyError.invalidSourceResponse(
        expected: byteCount,
        actual: bytes.count
      )
    }
    var sourceOffset = 0
    for descriptor in chain.descriptors {
      let count = Int(descriptor.length)
      try memory.write(
        at: descriptor.address,
        bytes: Array(bytes[sourceOffset..<(sourceOffset + count)])
      )
      sourceOffset += count
    }
    return UInt32(byteCount)
  }
}
