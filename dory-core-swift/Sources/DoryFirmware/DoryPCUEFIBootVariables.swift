import DoryMachinePC
import Foundation

public enum DoryPCUEFIBootVariableError: Error, Sendable, Equatable {
  case incompatiblePlatform(DoryFirmwarePlatform)
  case unsupportedPCIAddress(DoryPCPCIAddress)
  case noAvailableBootOption
}

/// Standard UEFI boot variables synthesized from a validated DoryPC-v1 launch plan.
///
/// Dory owns only load options carrying its private optional-data marker. Guest-created load
/// options are retained, and their existing relative order follows the Dory physical-device
/// fallbacks. This gives installation and recovery media deterministic priority without erasing
/// the operating system's more specific loader paths.
public enum DoryPCUEFIBootVariables {
  public static let globalVariableVendor = UUID(
    uuidString: "8BE4DF61-93CA-11D2-AA0D-00E098032B8C"
  )!
  public static let variableAttributes: DoryUEFIVariableAttributes = [
    .nonVolatile, .bootServiceAccess, .runtimeAccess,
  ]

  private static let firstOwnedOption: UInt16 = 0xd000
  private static let lastOwnedOption: UInt16 = 0xdfff
  private static let ownershipMagic = Data("DORYPC1\0".utf8)

  public static func applying(
    plan: DoryPCUEFILaunchPlan,
    to snapshot: DoryUEFIVariableStoreSnapshot
  ) throws -> DoryUEFIVariableStoreSnapshot {
    guard snapshot.platform == .pcV1 else {
      throw DoryPCUEFIBootVariableError.incompatiblePlatform(snapshot.platform)
    }

    let bootVariables = snapshot.variables.compactMap { variable -> (UInt16, DoryUEFIVariable)? in
      guard variable.key.vendor == globalVariableVendor,
        let number = bootOptionNumber(variable.key.name)
      else { return nil }
      return (number, variable)
    }
    let foreignNumbers = Set(
      bootVariables.compactMap { number, variable in
        ownedLogicalID(variable) == nil ? number : nil
      })

    var reusable: [String: [UInt16]] = [:]
    for (number, variable) in bootVariables {
      if let logicalID = ownedLogicalID(variable) {
        reusable[logicalID, default: []].append(number)
      }
    }
    for logicalID in reusable.keys {
      reusable[logicalID]?.sort()
    }

    var assigned: [String: UInt16] = [:]
    var assignedNumbers = Set<UInt16>()
    for device in plan.bootDevices {
      if let number = reusable[device.logicalID]?.first(where: {
        !foreignNumbers.contains($0) && !assignedNumbers.contains($0)
      }) {
        assigned[device.logicalID] = number
        assignedNumbers.insert(number)
        continue
      }
      guard
        let number = (firstOwnedOption...lastOwnedOption).first(where: {
          !foreignNumbers.contains($0) && !assignedNumbers.contains($0)
        })
      else {
        throw DoryPCUEFIBootVariableError.noAvailableBootOption
      }
      assigned[device.logicalID] = number
      assignedNumbers.insert(number)
    }

    let existingOrder = snapshot.variable(for: try key("BootOrder"))?.data ?? Data()
    var retainedForeignOrder: [UInt16] = []
    var seenForeign = Set<UInt16>()
    for number in decodeOrder(existingOrder)
    where foreignNumbers.contains(number) && seenForeign.insert(number).inserted {
      retainedForeignOrder.append(number)
    }

    var next = snapshot.variables.filter { variable in
      guard variable.key.vendor == globalVariableVendor else { return true }
      if variable.key.name == "BootOrder" { return false }
      guard bootOptionNumber(variable.key.name) != nil else { return true }
      return ownedLogicalID(variable) == nil
    }
    for device in plan.bootDevices {
      guard let number = assigned[device.logicalID] else {
        throw DoryPCUEFIBootVariableError.noAvailableBootOption
      }
      next.append(
        try DoryUEFIVariable(
          key: key(optionName(number)),
          attributes: variableAttributes,
          data: try loadOption(for: device)
        ))
    }
    let doryOrder = try plan.bootOrder.map { logicalID -> UInt16 in
      guard let number = assigned[logicalID] else {
        throw DoryPCUEFIBootVariableError.noAvailableBootOption
      }
      return number
    }
    next.append(
      try DoryUEFIVariable(
        key: key("BootOrder"),
        attributes: variableAttributes,
        data: encodeOrder(doryOrder + retainedForeignOrder)
      ))
    return try snapshot.replacingAllVariables(next)
  }

  private static func loadOption(for device: DoryPCUEFIBootDevice) throws -> Data {
    let path = try pciDevicePath(device.pciAddress)
    var bytes: [UInt8] = []
    append(UInt32(1), to: &bytes)  // LOAD_OPTION_ACTIVE
    append(UInt16(path.count), to: &bytes)
    for codeUnit in "Dory \(device.logicalID)".utf16 { append(codeUnit, to: &bytes) }
    append(UInt16(0), to: &bytes)
    bytes += path
    bytes += ownershipMagic
    bytes += device.logicalID.utf8
    return Data(bytes)
  }

  private static func pciDevicePath(_ address: DoryPCPCIAddress) throws -> [UInt8] {
    guard address.segment == 0, address.bus == 0 else {
      throw DoryPCUEFIBootVariableError.unsupportedPCIAddress(address)
    }
    return [
      0x02, 0x01, 0x0c, 0x00,  // ACPI(PNP0A03,0)
      0xd0, 0x41, 0x03, 0x0a,
      0x00, 0x00, 0x00, 0x00,
      0x01, 0x01, 0x06, 0x00,  // PCI(function,device)
      address.function, address.device,
      0x7f, 0xff, 0x04, 0x00,
    ]
  }

  private static func ownedLogicalID(_ variable: DoryUEFIVariable) -> String? {
    let bytes = [UInt8](variable.data)
    guard bytes.count >= 8 else { return nil }
    let pathLength = Int(bytes[4]) | Int(bytes[5]) << 8
    var cursor = 6
    var foundTerminator = false
    while cursor + 1 < bytes.count {
      if bytes[cursor] == 0, bytes[cursor + 1] == 0 {
        cursor += 2
        foundTerminator = true
        break
      }
      cursor += 2
    }
    guard foundTerminator, pathLength <= bytes.count - cursor else { return nil }
    cursor += pathLength
    let optionalData = Data(bytes[cursor...])
    guard optionalData.starts(with: ownershipMagic) else { return nil }
    return String(data: optionalData.dropFirst(ownershipMagic.count), encoding: .utf8)
  }

  private static func decodeOrder(_ data: Data) -> [UInt16] {
    let bytes = [UInt8](data)
    guard bytes.count.isMultiple(of: 2) else { return [] }
    return stride(from: 0, to: bytes.count, by: 2).map {
      UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8
    }
  }

  private static func encodeOrder(_ order: [UInt16]) -> Data {
    var bytes: [UInt8] = []
    for number in order { append(number, to: &bytes) }
    return Data(bytes)
  }

  private static func bootOptionNumber(_ name: String) -> UInt16? {
    guard name.count == 8, name.hasPrefix("Boot"),
      let number = UInt16(name.dropFirst(4), radix: 16),
      name == optionName(number)
    else { return nil }
    return number
  }

  private static func optionName(_ number: UInt16) -> String {
    String(format: "Boot%04X", number)
  }

  private static func key(_ name: String) throws -> DoryUEFIVariableKey {
    try .init(vendor: globalVariableVendor, name: name)
  }

  private static func append<T: FixedWidthInteger>(_ value: T, to bytes: inout [UInt8]) {
    for offset in 0..<MemoryLayout<T>.size {
      bytes.append(UInt8(truncatingIfNeeded: value >> T(offset * 8)))
    }
  }
}
