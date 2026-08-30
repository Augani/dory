import DoryMachineARMVirt
import Foundation

/// Frozen MMIO contract implemented by Dory's EDK II variable-runtime driver.
///
/// All scalar registers are little-endian. The vendor field contains the 16 RFC 4122 UUID bytes,
/// names are UTF-8, and command publication is the final guest write for a request. The Dory EDK
/// II port owns UTF-16 conversion at the UEFI protocol boundary.
public enum DoryUEFIVariableBridgeV1ABI {
  public static let identity = DoryFirmwareArtifactManifest.variableBridgeIdentity
  public static let version: UInt32 = 1
  public static let magic: UInt64 = 0x3152_4156_5952_4f44  // "DORYVAR1"
  public static let baseAddress = DoryARMVirtV1ABI.firmwareVariableBase
  public static let byteCount = DoryARMVirtV1ABI.firmwareVariableBytes

  public static let magicOffset: UInt64 = 0x0000
  public static let versionOffset: UInt64 = 0x0008
  public static let statusOffset: UInt64 = 0x000c
  public static let commandOffset: UInt64 = 0x0010
  public static let attributesOffset: UInt64 = 0x0014
  public static let generationOffset: UInt64 = 0x0018
  public static let vendorOffset: UInt64 = 0x0020
  public static let vendorByteCount = 16
  public static let nameLengthOffset: UInt64 = 0x0030
  public static let dataLengthOffset: UInt64 = 0x0034
  public static let nameOffset: UInt64 = 0x1000
  public static let nameByteCount = DoryUEFIVariableKey.maximumNameUTF8Bytes
  public static let dataOffset: UInt64 = 0x2000
  public static let dataByteCount = DoryUEFIVariable.maximumDataBytes

  public static func validateLayout() throws {
    guard identity == "dory.uefi.variable-bridge.armvirt@1",
      baseAddress == DoryARMVirtV1ABI.firmwareVariableBase,
      byteCount == DoryARMVirtV1ABI.firmwareVariableBytes,
      nameOffset + UInt64(nameByteCount) <= dataOffset,
      dataOffset + UInt64(dataByteCount) <= byteCount
    else {
      throw DoryFirmwareError.invalidVariableBridgeLayout
    }
  }
}

public enum DoryUEFIVariableBridgeCommand: UInt32, CaseIterable, Sendable {
  case reset = 0
  case get = 1
  case set = 2
  case delete = 3
  case first = 4
  case next = 5
}

public enum DoryUEFIVariableBridgeStatus: UInt32, CaseIterable, Sendable, Equatable {
  case idle = 0
  case success = 1
  case notFound = 2
  case invalidRequest = 3
  case recoveryRequired = 4
  case generationConflict = 5
  case storageFailure = 6
}

public struct DoryUEFIVariableBridgeRequest: Sendable, Equatable {
  public let command: DoryUEFIVariableBridgeCommand
  public let vendor: UUID?
  public let name: String?
  public let attributes: DoryUEFIVariableAttributes
  public let data: Data

  public init(
    command: DoryUEFIVariableBridgeCommand,
    vendor: UUID? = nil,
    name: String? = nil,
    attributes: DoryUEFIVariableAttributes = [],
    data: Data = Data()
  ) {
    self.command = command
    self.vendor = vendor
    self.name = name
    self.attributes = attributes
    self.data = data
  }
}

public struct DoryUEFIVariableBridgeResponse: Sendable, Equatable {
  public let status: DoryUEFIVariableBridgeStatus
  public let generation: UInt64
  public let variable: DoryUEFIVariable?

  public init(
    status: DoryUEFIVariableBridgeStatus,
    generation: UInt64,
    variable: DoryUEFIVariable? = nil
  ) {
    self.status = status
    self.generation = generation
    self.variable = variable
  }
}

/// Transport-independent execution of bridge requests against the crash-safe per-VM store.
public struct DoryUEFIVariableBridgeService: Sendable {
  public let store: DoryUEFIVariableStoreFile

  public init(store: DoryUEFIVariableStoreFile) {
    self.store = store
  }

  public func execute(_ request: DoryUEFIVariableBridgeRequest) -> DoryUEFIVariableBridgeResponse {
    do {
      let load = try store.load()
      guard load.source == .primary else {
        return response(.recoveryRequired, generation: load.snapshot.generation)
      }
      let snapshot = load.snapshot
      switch request.command {
      case .reset:
        return response(.idle, generation: snapshot.generation)
      case .get:
        let key = try requestKey(request)
        guard let variable = snapshot.variable(for: key) else {
          return response(.notFound, generation: snapshot.generation)
        }
        return response(.success, generation: snapshot.generation, variable: variable)
      case .set:
        let variable = try DoryUEFIVariable(
          key: requestKey(request),
          attributes: request.attributes,
          data: request.data
        )
        let successor = try snapshot.setting(variable)
        try store.commit(successor, expectedGeneration: snapshot.generation)
        return response(.success, generation: successor.generation, variable: variable)
      case .delete:
        let key = try requestKey(request)
        guard snapshot.variable(for: key) != nil else {
          return response(.notFound, generation: snapshot.generation)
        }
        let successor = try snapshot.deleting(key)
        try store.commit(successor, expectedGeneration: snapshot.generation)
        return response(.success, generation: successor.generation)
      case .first:
        guard let variable = snapshot.variables.first else {
          return response(.notFound, generation: snapshot.generation)
        }
        return response(.success, generation: snapshot.generation, variable: variable)
      case .next:
        let key = try requestKey(request)
        guard let variable = snapshot.variables.first(where: { $0.key > key }) else {
          return response(.notFound, generation: snapshot.generation)
        }
        return response(.success, generation: snapshot.generation, variable: variable)
      }
    } catch let error as DoryUEFIVariableStoreFileError {
      switch error {
      case .recoveryRequired, .noRecoverableBackup:
        return response(.recoveryRequired)
      case .generationConflict:
        return response(.generationConflict)
      default:
        return response(.storageFailure)
      }
    } catch is DoryFirmwareError {
      return response(.invalidRequest)
    } catch {
      return response(.storageFailure)
    }
  }

  private func requestKey(
    _ request: DoryUEFIVariableBridgeRequest
  ) throws -> DoryUEFIVariableKey {
    guard let vendor = request.vendor, let name = request.name else {
      throw DoryFirmwareError.invalidVariableName
    }
    return try DoryUEFIVariableKey(vendor: vendor, name: name)
  }

  private func response(
    _ status: DoryUEFIVariableBridgeStatus,
    generation: UInt64 = 0,
    variable: DoryUEFIVariable? = nil
  ) -> DoryUEFIVariableBridgeResponse {
    DoryUEFIVariableBridgeResponse(
      status: status,
      generation: generation,
      variable: variable
    )
  }
}
