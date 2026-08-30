private struct DoryARMVirtBootStateCodingKey: CodingKey {
  let stringValue: String
  let intValue: Int? = nil

  init?(stringValue: String) { self.stringValue = stringValue }
  init?(intValue: Int) { return nil }
}

public struct DoryARMVirtV1InitialCPUState: Codable, Sendable, Hashable {
  public static let resetPSTATE: UInt64 = 0x3c5

  public let bootProtocol: DoryARMVirtV1BootProtocol
  public let programCounter: UInt64
  public let pstate: UInt64
  public let x0: UInt64
  public let x1: UInt64
  public let x2: UInt64
  public let x3: UInt64

  public static func directLinux(
    entryPoint: UInt64,
    deviceTreeAddress: UInt64
  ) throws -> Self {
    guard entryPoint >= DoryARMVirtV1ABI.ramBase,
      deviceTreeAddress >= DoryARMVirtV1ABI.ramBase,
      entryPoint != deviceTreeAddress
    else {
      throw DoryARMVirtV1BootStateError.invalidDirectLinuxState
    }
    return Self(
      bootProtocol: .directLinux,
      programCounter: entryPoint,
      pstate: resetPSTATE,
      x0: deviceTreeAddress,
      x1: 0,
      x2: 0,
      x3: 0
    )
  }

  public static func uefi(deviceTreeAddress: UInt64) throws -> Self {
    guard deviceTreeAddress == DoryARMVirtV1ABI.ramBase + DoryARMVirtV1ABI.dtbOffset else {
      throw DoryARMVirtV1BootStateError.invalidUEFIState
    }
    return Self(
      bootProtocol: .uefi,
      programCounter: DoryARMVirtV1ABI.uefiResetAddress,
      pstate: resetPSTATE,
      x0: deviceTreeAddress,
      x1: 0,
      x2: 0,
      x3: 0
    )
  }

  private init(
    bootProtocol: DoryARMVirtV1BootProtocol,
    programCounter: UInt64,
    pstate: UInt64,
    x0: UInt64,
    x1: UInt64,
    x2: UInt64,
    x3: UInt64
  ) {
    self.bootProtocol = bootProtocol
    self.programCounter = programCounter
    self.pstate = pstate
    self.x0 = x0
    self.x1 = x1
    self.x2 = x2
    self.x3 = x3
  }

  private enum CodingKeys: String, CodingKey {
    case bootProtocol, programCounter, pstate, x0, x1, x2, x3
  }

  public init(from decoder: Decoder) throws {
    let allFields = try decoder.container(keyedBy: DoryARMVirtBootStateCodingKey.self)
    let allowed = Set(["bootProtocol", "programCounter", "pstate", "x0", "x1", "x2", "x3"])
    guard allFields.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
      throw DoryARMVirtV1BootStateError.unknownFields(
        allFields.allKeys.map(\.stringValue).filter { !allowed.contains($0) }.sorted()
      )
    }
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let bootProtocol = try container.decode(DoryARMVirtV1BootProtocol.self, forKey: .bootProtocol)
    let programCounter = try container.decode(UInt64.self, forKey: .programCounter)
    let pstate = try container.decode(UInt64.self, forKey: .pstate)
    let x0 = try container.decode(UInt64.self, forKey: .x0)
    let x1 = try container.decode(UInt64.self, forKey: .x1)
    let x2 = try container.decode(UInt64.self, forKey: .x2)
    let x3 = try container.decode(UInt64.self, forKey: .x3)
    switch bootProtocol {
    case .directLinux:
      let expected = try Self.directLinux(entryPoint: programCounter, deviceTreeAddress: x0)
      guard pstate == expected.pstate, x1 == 0, x2 == 0, x3 == 0 else {
        throw DoryARMVirtV1BootStateError.invalidDirectLinuxState
      }
      self = expected
    case .uefi:
      let expected = try Self.uefi(deviceTreeAddress: x0)
      guard programCounter == expected.programCounter,
        pstate == expected.pstate,
        x1 == 0,
        x2 == 0,
        x3 == 0
      else {
        throw DoryARMVirtV1BootStateError.invalidUEFIState
      }
      self = expected
    }
  }
}

public enum DoryARMVirtV1BootStateError: Error, Sendable, Equatable {
  case invalidDirectLinuxState
  case invalidUEFIState
  case unknownFields([String])
}
