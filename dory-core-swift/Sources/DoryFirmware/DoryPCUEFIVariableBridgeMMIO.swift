import DoryMachinePC
import Foundation

public enum DoryPCUEFIVariableBridgeMMIOError: Error, Sendable, Equatable {
  case incompatibleVariableStorePlatform(DoryFirmwarePlatform)
}

/// DoryPC-v1 MMIO transport for the persistent UEFI variable service.
///
/// Guest software fills the request registers and buffers, then publishes a command with one
/// aligned 32-bit write. Command execution is synchronous, so the status and response buffers are
/// complete when that write returns to the guest.
public final class DoryPCUEFIVariableBridgeMMIO: DoryPCMMIODevice, @unchecked Sendable {
  public let baseAddress: UInt64
  public let byteCount: UInt64
  public let service: DoryUEFIVariableBridgeService

  private let lock = NSLock()
  private var storage: [UInt8]

  public init(service: DoryUEFIVariableBridgeService) throws {
    let binding = try DoryUEFIVariableBridgeV1Binding(platform: .pcV1)
    let load = try service.store.load()
    guard load.snapshot.platform == .pcV1 else {
      throw DoryPCUEFIVariableBridgeMMIOError.incompatibleVariableStorePlatform(
        load.snapshot.platform
      )
    }
    self.service = service
    baseAddress = binding.baseAddress
    byteCount = binding.byteCount
    storage = [UInt8](repeating: 0, count: Int(binding.byteCount))
    storeUInt64(DoryUEFIVariableBridgeV1ABI.magic, at: DoryUEFIVariableBridgeV1ABI.magicOffset)
    storeUInt32(DoryUEFIVariableBridgeV1ABI.version, at: DoryUEFIVariableBridgeV1ABI.versionOffset)
    publish(
      .init(
        status: load.source == .primary ? .idle : .recoveryRequired,
        generation: load.snapshot.generation
      )
    )
  }

  public func read(offset: UInt64, byteCount: Int) throws -> [UInt8] {
    let range = try checkedRange(offset: offset, byteCount: byteCount, write: false)
    return lock.withLock { Array(storage[range]) }
  }

  public func write(offset: UInt64, bytes: [UInt8]) throws {
    try validateWrite(offset: offset, byteCount: bytes.count)
    lock.withLock {
      let range = Int(offset)..<(Int(offset) + bytes.count)
      storage.replaceSubrange(range, with: bytes)
      guard offset == DoryUEFIVariableBridgeV1ABI.commandOffset else { return }
      let response: DoryUEFIVariableBridgeResponse
      if let request = requestFromRegisters() {
        response = service.execute(request)
      } else {
        response = .init(
          status: .invalidRequest,
          generation: loadUInt64(at: DoryUEFIVariableBridgeV1ABI.generationOffset)
        )
      }
      publish(response)
    }
  }

  public func validateWrite(offset: UInt64, byteCount: Int) throws {
    let access = try checkedRange(offset: offset, byteCount: byteCount, write: true)
    let command = registerRange(DoryUEFIVariableBridgeV1ABI.commandOffset, byteCount: 4)
    if access == command { return }
    let writable = [
      registerRange(DoryUEFIVariableBridgeV1ABI.attributesOffset, byteCount: 4),
      registerRange(
        DoryUEFIVariableBridgeV1ABI.vendorOffset,
        byteCount: DoryUEFIVariableBridgeV1ABI.vendorByteCount
      ),
      registerRange(DoryUEFIVariableBridgeV1ABI.nameLengthOffset, byteCount: 4),
      registerRange(DoryUEFIVariableBridgeV1ABI.dataLengthOffset, byteCount: 4),
      registerRange(
        DoryUEFIVariableBridgeV1ABI.nameOffset,
        byteCount: DoryUEFIVariableBridgeV1ABI.nameByteCount
      ),
      registerRange(
        DoryUEFIVariableBridgeV1ABI.dataOffset,
        byteCount: DoryUEFIVariableBridgeV1ABI.dataByteCount
      ),
    ]
    guard
      writable.contains(where: {
        access.lowerBound >= $0.lowerBound && access.upperBound <= $0.upperBound
      })
    else {
      throw DoryPCPhysicalMemoryError.unsupportedAccess(
        offset: offset,
        byteCount: byteCount,
        write: true
      )
    }
  }

  private func requestFromRegisters() -> DoryUEFIVariableBridgeRequest? {
    guard
      let command = DoryUEFIVariableBridgeCommand(
        rawValue: loadUInt32(at: DoryUEFIVariableBridgeV1ABI.commandOffset)
      )
    else { return nil }
    if command == .reset || command == .first {
      return .init(command: command)
    }
    let nameLength = Int(loadUInt32(at: DoryUEFIVariableBridgeV1ABI.nameLengthOffset))
    let dataLength = Int(loadUInt32(at: DoryUEFIVariableBridgeV1ABI.dataLengthOffset))
    guard nameLength <= DoryUEFIVariableBridgeV1ABI.nameByteCount,
      dataLength <= DoryUEFIVariableBridgeV1ABI.dataByteCount,
      let name = String(
        bytes: bytes(at: DoryUEFIVariableBridgeV1ABI.nameOffset, count: nameLength),
        encoding: .utf8
      )
    else { return nil }
    let vendorBytes = bytes(
      at: DoryUEFIVariableBridgeV1ABI.vendorOffset,
      count: DoryUEFIVariableBridgeV1ABI.vendorByteCount
    )
    guard let vendor = uuid(bytes: vendorBytes) else { return nil }
    return .init(
      command: command,
      vendor: vendor,
      name: name,
      attributes: .init(
        rawValue: loadUInt32(at: DoryUEFIVariableBridgeV1ABI.attributesOffset)
      ),
      data: Data(bytes(at: DoryUEFIVariableBridgeV1ABI.dataOffset, count: dataLength))
    )
  }

  private func publish(_ response: DoryUEFIVariableBridgeResponse) {
    storeUInt32(response.status.rawValue, at: DoryUEFIVariableBridgeV1ABI.statusOffset)
    storeUInt64(response.generation, at: DoryUEFIVariableBridgeV1ABI.generationOffset)
    guard let variable = response.variable else {
      storeUInt32(0, at: DoryUEFIVariableBridgeV1ABI.attributesOffset)
      storeUInt32(0, at: DoryUEFIVariableBridgeV1ABI.nameLengthOffset)
      storeUInt32(0, at: DoryUEFIVariableBridgeV1ABI.dataLengthOffset)
      return
    }
    storeUInt32(variable.attributes.rawValue, at: DoryUEFIVariableBridgeV1ABI.attributesOffset)
    storeBytes(uuidBytes(variable.key.vendor), at: DoryUEFIVariableBridgeV1ABI.vendorOffset)
    let name = Array(variable.key.name.utf8)
    storeUInt32(UInt32(name.count), at: DoryUEFIVariableBridgeV1ABI.nameLengthOffset)
    storeUInt32(UInt32(variable.data.count), at: DoryUEFIVariableBridgeV1ABI.dataLengthOffset)
    storeBytes(name, at: DoryUEFIVariableBridgeV1ABI.nameOffset)
    storeBytes(Array(variable.data), at: DoryUEFIVariableBridgeV1ABI.dataOffset)
  }

  private func checkedRange(
    offset: UInt64,
    byteCount: Int,
    write: Bool
  ) throws -> Range<Int> {
    guard byteCount > 0, offset <= self.byteCount,
      UInt64(byteCount) <= self.byteCount - offset
    else {
      throw DoryPCPhysicalMemoryError.unsupportedAccess(
        offset: offset,
        byteCount: byteCount,
        write: write
      )
    }
    return Int(offset)..<(Int(offset) + byteCount)
  }

  private func registerRange(_ offset: UInt64, byteCount: Int) -> Range<Int> {
    Int(offset)..<(Int(offset) + byteCount)
  }

  private func bytes(at offset: UInt64, count: Int) -> [UInt8] {
    Array(storage[registerRange(offset, byteCount: count)])
  }

  private func loadUInt32(at offset: UInt64) -> UInt32 {
    bytes(at: offset, count: 4).enumerated().reduce(into: 0) {
      $0 |= UInt32($1.element) << UInt32($1.offset * 8)
    }
  }

  private func loadUInt64(at offset: UInt64) -> UInt64 {
    bytes(at: offset, count: 8).enumerated().reduce(into: 0) {
      $0 |= UInt64($1.element) << UInt64($1.offset * 8)
    }
  }

  private func storeUInt32(_ value: UInt32, at offset: UInt64) {
    storeBytes((0..<4).map { UInt8(truncatingIfNeeded: value >> UInt32($0 * 8)) }, at: offset)
  }

  private func storeUInt64(_ value: UInt64, at offset: UInt64) {
    storeBytes((0..<8).map { UInt8(truncatingIfNeeded: value >> UInt64($0 * 8)) }, at: offset)
  }

  private func storeBytes(_ bytes: [UInt8], at offset: UInt64) {
    storage.replaceSubrange(registerRange(offset, byteCount: bytes.count), with: bytes)
  }

  private func uuid(bytes: [UInt8]) -> UUID? {
    guard bytes.count == 16 else { return nil }
    return UUID(
      uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3],
        bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11],
        bytes[12], bytes[13], bytes[14], bytes[15]
      ))
  }

  private func uuidBytes(_ uuid: UUID) -> [UInt8] {
    withUnsafeBytes(of: uuid.uuid) { Array($0) }
  }
}
