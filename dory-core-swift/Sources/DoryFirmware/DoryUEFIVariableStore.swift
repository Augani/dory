import DoryMachineARMVirt
import Foundation

struct DoryFirmwareAnyCodingKey: CodingKey {
  let stringValue: String
  let intValue: Int? = nil

  init?(stringValue: String) { self.stringValue = stringValue }
  init?(intValue: Int) { return nil }
}

func rejectUnknownFirmwareFields(
  from decoder: Decoder,
  allowed: Set<String>,
  type: String
) throws {
  let container = try decoder.container(keyedBy: DoryFirmwareAnyCodingKey.self)
  let unknown = container.allKeys.map(\.stringValue).filter { !allowed.contains($0) }.sorted()
  guard unknown.isEmpty else { throw DoryFirmwareError.unknownFields(type: type, fields: unknown) }
}

public struct DoryUEFIVariableAttributes: OptionSet, Codable, Sendable, Hashable {
  public let rawValue: UInt32

  public init(rawValue: UInt32) {
    self.rawValue = rawValue
  }

  public static let nonVolatile = Self(rawValue: 1 << 0)
  public static let bootServiceAccess = Self(rawValue: 1 << 1)
  public static let runtimeAccess = Self(rawValue: 1 << 2)
  public static let authenticatedWrite = Self(rawValue: 1 << 4)
  public static let timeBasedAuthenticatedWrite = Self(rawValue: 1 << 5)
  public static let appendWrite = Self(rawValue: 1 << 6)

  public static let supported: Self = [
    .nonVolatile,
    .bootServiceAccess,
    .runtimeAccess,
    .authenticatedWrite,
    .timeBasedAuthenticatedWrite,
    .appendWrite,
  ]

  public var isValid: Bool {
    !isEmpty && rawValue & ~Self.supported.rawValue == 0
  }
}

public struct DoryUEFIVariableKey: Codable, Sendable, Hashable, Comparable {
  public static let maximumNameUTF8Bytes = 1_024

  public let vendor: UUID
  public let name: String

  public init(vendor: UUID, name: String) throws {
    let bytes = Array(name.utf8)
    guard !bytes.isEmpty,
      bytes.count <= Self.maximumNameUTF8Bytes,
      !bytes.contains(0)
    else {
      throw DoryFirmwareError.invalidVariableName
    }
    self.vendor = vendor
    self.name = name
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    let leftVendor = lhs.vendor.uuidString.lowercased()
    let rightVendor = rhs.vendor.uuidString.lowercased()
    if leftVendor != rightVendor { return leftVendor < rightVendor }
    return lhs.name < rhs.name
  }

  private enum CodingKeys: String, CodingKey { case vendor, name }

  public init(from decoder: Decoder) throws {
    try rejectUnknownFirmwareFields(
      from: decoder,
      allowed: ["vendor", "name"],
      type: "DoryUEFIVariableKey"
    )
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      vendor: container.decode(UUID.self, forKey: .vendor),
      name: container.decode(String.self, forKey: .name)
    )
  }
}

public struct DoryUEFIVariable: Codable, Sendable, Hashable, Comparable {
  public static let maximumDataBytes = 1 << 20

  public let key: DoryUEFIVariableKey
  public let attributes: DoryUEFIVariableAttributes
  public let data: Data

  public init(
    key: DoryUEFIVariableKey,
    attributes: DoryUEFIVariableAttributes,
    data: Data
  ) throws {
    guard attributes.isValid else { throw DoryFirmwareError.invalidVariableAttributes }
    guard data.count <= Self.maximumDataBytes else {
      throw DoryFirmwareError.variableDataTooLarge(actual: data.count)
    }
    self.key = key
    self.attributes = attributes
    self.data = data
  }

  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.key < rhs.key }

  private enum CodingKeys: String, CodingKey { case key, attributes, data }

  public init(from decoder: Decoder) throws {
    try rejectUnknownFirmwareFields(
      from: decoder,
      allowed: ["key", "attributes", "data"],
      type: "DoryUEFIVariable"
    )
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      key: container.decode(DoryUEFIVariableKey.self, forKey: .key),
      attributes: container.decode(DoryUEFIVariableAttributes.self, forKey: .attributes),
      data: container.decode(Data.self, forKey: .data)
    )
  }
}

public struct DoryUEFIVariableStoreSnapshot: Codable, Sendable, Hashable {
  public static let schemaVersion: UInt32 = 1
  public static let maximumVariables = 4_096
  public static let maximumTotalDataBytes = 16 << 20

  public let schemaVersion: UInt32
  public let formatIdentity: String
  public let machineABIIdentity: String
  public let generation: UInt64
  public let variables: [DoryUEFIVariable]

  public init(generation: UInt64 = 1, variables: [DoryUEFIVariable] = []) throws {
    try self.init(
      schemaVersion: Self.schemaVersion,
      formatIdentity: DoryARMVirtV1ABI.variableStoreFormatIdentity,
      machineABIIdentity: DoryARMVirtV1ABI.identity,
      generation: generation,
      variables: variables
    )
  }

  private init(
    schemaVersion: UInt32,
    formatIdentity: String,
    machineABIIdentity: String,
    generation: UInt64,
    variables: [DoryUEFIVariable]
  ) throws {
    guard schemaVersion == Self.schemaVersion else {
      throw DoryFirmwareError.unsupportedSchemaVersion(schemaVersion)
    }
    guard formatIdentity == DoryARMVirtV1ABI.variableStoreFormatIdentity else {
      throw DoryFirmwareError.incompatibleFormatIdentity(formatIdentity)
    }
    guard machineABIIdentity == DoryARMVirtV1ABI.identity else {
      throw DoryFirmwareError.incompatibleMachineABI(machineABIIdentity)
    }
    guard generation > 0 else { throw DoryFirmwareError.invalidGeneration(generation) }
    guard variables.count <= Self.maximumVariables else {
      throw DoryFirmwareError.tooManyVariables(actual: variables.count)
    }
    let keys = variables.map(\.key)
    guard keys == keys.sorted(), Set(keys).count == keys.count else {
      throw DoryFirmwareError.nonCanonicalVariables
    }
    let total = variables.reduce(into: 0) { $0 += $1.data.count }
    guard total <= Self.maximumTotalDataBytes else {
      throw DoryFirmwareError.storeDataTooLarge(actual: total)
    }
    self.schemaVersion = schemaVersion
    self.formatIdentity = formatIdentity
    self.machineABIIdentity = machineABIIdentity
    self.generation = generation
    self.variables = variables
  }

  public func variable(for key: DoryUEFIVariableKey) -> DoryUEFIVariable? {
    variables.first { $0.key == key }
  }

  public func setting(_ variable: DoryUEFIVariable) throws -> Self {
    guard generation < UInt64.max else { throw DoryFirmwareError.generationExhausted }
    var next = variables.filter { $0.key != variable.key }
    next.append(variable)
    next.sort()
    return try Self(generation: generation + 1, variables: next)
  }

  public func deleting(_ key: DoryUEFIVariableKey) throws -> Self {
    guard generation < UInt64.max else { throw DoryFirmwareError.generationExhausted }
    return try Self(
      generation: generation + 1,
      variables: variables.filter { $0.key != key }
    )
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion, formatIdentity, machineABIIdentity, generation, variables
  }

  public init(from decoder: Decoder) throws {
    try rejectUnknownFirmwareFields(
      from: decoder,
      allowed: [
        "schemaVersion", "formatIdentity", "machineABIIdentity", "generation", "variables",
      ],
      type: "DoryUEFIVariableStoreSnapshot"
    )
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      schemaVersion: container.decode(UInt32.self, forKey: .schemaVersion),
      formatIdentity: container.decode(String.self, forKey: .formatIdentity),
      machineABIIdentity: container.decode(String.self, forKey: .machineABIIdentity),
      generation: container.decode(UInt64.self, forKey: .generation),
      variables: container.decode([DoryUEFIVariable].self, forKey: .variables)
    )
  }
}

public enum DoryFirmwareError: Error, Equatable, Sendable {
  case unsupportedSchemaVersion(UInt32)
  case incompatibleFormatIdentity(String)
  case incompatibleMachineABI(String)
  case invalidGeneration(UInt64)
  case generationExhausted
  case invalidVariableName
  case invalidVariableAttributes
  case variableDataTooLarge(actual: Int)
  case tooManyVariables(actual: Int)
  case storeDataTooLarge(actual: Int)
  case nonCanonicalVariables
  case invalidVariableBridgeLayout
  case unknownFields(type: String, fields: [String])
}
