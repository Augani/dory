import DoryFirmware
import DoryMachineARMVirt
import Foundation
import Testing

@Suite struct DoryUEFIVariableStoreTests {
  @Test func publicTemplateCodecAcceptsOnlyCanonicalBytes() throws {
    let snapshot = try DoryUEFIVariableStoreSnapshot()
    let canonical = try snapshot.canonicalData()
    #expect(try DoryUEFIVariableStoreSnapshot.decodeCanonicalTemplate(canonical) == snapshot)

    var noncanonical = canonical
    noncanonical.insert(contentsOf: Data(" ".utf8), at: noncanonical.startIndex)
    #expect(throws: DoryUEFIVariableStoreFileError.self) {
      _ = try DoryUEFIVariableStoreSnapshot.decodeCanonicalTemplate(noncanonical)
    }
  }

  private let globalVendor = UUID(uuidString: "8be4df61-93ca-11d2-aa0d-00e098032b8c")!

  @Test func canonicalStoreRoundTripsAndPinsARMVirtIdentity() throws {
    let bootOrder = try variable(name: "BootOrder", bytes: [0, 0])
    let secureBoot = try variable(name: "SecureBoot", bytes: [1])
    let snapshot = try DoryUEFIVariableStoreSnapshot(
      variables: [bootOrder, secureBoot].sorted()
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let encoded = try encoder.encode(snapshot)
    let decoded = try JSONDecoder().decode(DoryUEFIVariableStoreSnapshot.self, from: encoded)

    #expect(decoded == snapshot)
    #expect(decoded.formatIdentity == DoryARMVirtV1ABI.variableStoreFormatIdentity)
    #expect(decoded.machineABIIdentity == DoryARMVirtV1ABI.identity)
    #expect(try encoder.encode(decoded) == encoded)
  }

  @Test func mutationsAreCanonicalAndGenerationBound() throws {
    let bootOrder = try variable(name: "BootOrder", bytes: [0, 0])
    let secureBoot = try variable(name: "SecureBoot", bytes: [1])
    let empty = try DoryUEFIVariableStoreSnapshot()
    let first = try empty.setting(secureBoot)
    let second = try first.setting(bootOrder)

    #expect(second.generation == 3)
    #expect(second.variables.map(\.key.name) == ["BootOrder", "SecureBoot"])
    #expect(try second.deleting(secureBoot.key).variables == [bootOrder])
  }

  @Test func invalidAndNoncanonicalStoresFailClosed() throws {
    #expect(throws: DoryFirmwareError.invalidVariableName) {
      _ = try DoryUEFIVariableKey(vendor: globalVendor, name: "")
    }
    #expect(throws: DoryFirmwareError.invalidVariableAttributes) {
      _ = try DoryUEFIVariable(
        key: DoryUEFIVariableKey(vendor: globalVendor, name: "BootOrder"),
        attributes: [],
        data: Data()
      )
    }
    let bootOrder = try variable(name: "BootOrder", bytes: [0, 0])
    let secureBoot = try variable(name: "SecureBoot", bytes: [1])
    #expect(throws: DoryFirmwareError.nonCanonicalVariables) {
      _ = try DoryUEFIVariableStoreSnapshot(variables: [secureBoot, bootOrder])
    }
    #expect(throws: DoryFirmwareError.nonCanonicalVariables) {
      _ = try DoryUEFIVariableStoreSnapshot(variables: [bootOrder, bootOrder])
    }
  }

  @Test func decodedIdentitySubstitutionIsRejected() throws {
    let json = Data(#"""
      {
        "schemaVersion":1,
        "formatIdentity":"dory.uefi.variables.armvirt@1",
        "machineABIIdentity":"dory.pc@1",
        "generation":1,
        "variables":[]
      }
      """#.utf8)
    #expect(throws: DoryFirmwareError.incompatibleMachineABI("dory.pc@1")) {
      _ = try JSONDecoder().decode(DoryUEFIVariableStoreSnapshot.self, from: json)
    }
  }

  @Test func unknownFieldsAreRejectedAtEveryContractBoundary() throws {
    let topLevel = Data(#"""
      {
        "schemaVersion":1,
        "formatIdentity":"dory.uefi.variables.armvirt@1",
        "machineABIIdentity":"dory.armvirt@1",
        "generation":1,
        "variables":[],
        "future":true
      }
      """#.utf8)
    #expect(throws: DoryFirmwareError.unknownFields(
      type: "DoryUEFIVariableStoreSnapshot",
      fields: ["future"]
    )) {
      _ = try JSONDecoder().decode(DoryUEFIVariableStoreSnapshot.self, from: topLevel)
    }

    let variable = Data(#"""
      {
        "key":{"vendor":"8BE4DF61-93CA-11D2-AA0D-00E098032B8C","name":"BootOrder"},
        "attributes":7,
        "data":"AAA=",
        "future":true
      }
      """#.utf8)
    #expect(throws: DoryFirmwareError.unknownFields(
      type: "DoryUEFIVariable",
      fields: ["future"]
    )) {
      _ = try JSONDecoder().decode(DoryUEFIVariable.self, from: variable)
    }

    let key = Data(#"""
      {
        "vendor":"8BE4DF61-93CA-11D2-AA0D-00E098032B8C",
        "name":"BootOrder",
        "future":true
      }
      """#.utf8)
    #expect(throws: DoryFirmwareError.unknownFields(
      type: "DoryUEFIVariableKey",
      fields: ["future"]
    )) {
      _ = try JSONDecoder().decode(DoryUEFIVariableKey.self, from: key)
    }
  }

  private func variable(name: String, bytes: [UInt8]) throws -> DoryUEFIVariable {
    try DoryUEFIVariable(
      key: DoryUEFIVariableKey(vendor: globalVendor, name: name),
      attributes: [.nonVolatile, .bootServiceAccess, .runtimeAccess],
      data: Data(bytes)
    )
  }
}
