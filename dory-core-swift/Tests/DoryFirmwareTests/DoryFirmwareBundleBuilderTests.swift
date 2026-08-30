import CryptoKit
import DoryFirmware
import DoryMachinePC
import Foundation
import Testing

@Suite struct DoryFirmwareBundleBuilderTests {
  @Test func buildsDeterministicVerifiedBundle() throws {
    let input = try makeInput()
    let first = try DoryFirmwareBundleBuilder.build(input)
    let second = try DoryFirmwareBundleBuilder.build(input)

    #expect(first.manifestData == second.manifestData)
    #expect(first.variableStoreTemplate == second.variableStoreTemplate)
    #expect(first.sbom == second.sbom)
    try first.manifest.verify(
      firmwareCode: first.firmwareCode,
      variableStoreTemplate: first.variableStoreTemplate,
      sbom: first.sbom
    )
    _ = try DoryUEFIVariableStoreSnapshot.decodeCanonicalTemplate(
      first.variableStoreTemplate
    )

    let sbom = try #require(
      JSONSerialization.jsonObject(with: first.sbom) as? [String: Any]
    )
    #expect(sbom["bomFormat"] as? String == "CycloneDX")
    #expect(sbom["specVersion"] as? String == "1.6")
    let metadata = try #require(sbom["metadata"] as? [String: Any])
    #expect(metadata["timestamp"] as? String == "2026-08-12T08:13:56Z")
  }

  @Test func publishesExactFourFileLayout() throws {
    let bundle = try DoryFirmwareBundleBuilder.build(makeInput())
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString,
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    try bundle.write(to: directory)

    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    #expect(
      names
        == [
          DoryFirmwareBundleLayout.firmwareCodeFileName,
          DoryFirmwareBundleLayout.manifestFileName,
          DoryFirmwareBundleLayout.sbomFileName,
          DoryFirmwareBundleLayout.variableStoreTemplateFileName,
        ].sorted())
    #expect(
      try Data(
        contentsOf: directory.appendingPathComponent(
          DoryFirmwareBundleLayout.manifestFileName
        )) == bundle.manifestData
    )
  }

  @Test func buildsPCFirmwareBundleWithPCSBOMAuthority() throws {
    let bundle = try DoryFirmwareBundleBuilder.build(makeInput(platform: .pcV1))

    #expect(bundle.manifest.platform == .pcV1)
    #expect(bundle.manifest.machineABIIdentity == DoryPCV1ABI.identity)
    #expect(bundle.manifest.firmwareABIIdentity == DoryPCV1ABI.firmwareABIIdentity)
    let variables = try DoryUEFIVariableStoreSnapshot.decodeCanonicalTemplate(
      bundle.variableStoreTemplate
    )
    #expect(variables.platform == .pcV1)
    #expect(variables.machineABIIdentity == DoryPCV1ABI.identity)
    #expect(variables.formatIdentity == DoryPCV1ABI.variableStoreFormatIdentity)

    let sbom = try #require(JSONSerialization.jsonObject(with: bundle.sbom) as? [String: Any])
    let metadata = try #require(sbom["metadata"] as? [String: Any])
    let component = try #require(metadata["component"] as? [String: Any])
    #expect(component["name"] as? String == "DoryPC")
    let properties = try #require(component["properties"] as? [[String: String]])
    #expect(
      properties.contains([
        "name": "dory:machine-abi",
        "value": DoryPCV1ABI.identity,
      ]))
  }

  private func makeInput(
    platform: DoryFirmwarePlatform = .armVirtV1
  ) throws -> DoryFirmwareBundleBuildInput {
    DoryFirmwareBundleBuildInput(
      platform: platform,
      buildIdentifier: "dory-firmware-202608",
      source: try DoryFirmwareSourcePin(
        repository: "https://github.com/tianocore/edk2.git",
        revision: "2970e5699ba6267f3384ffab20f96647578aebc8"
      ),
      sourceDateEpoch: 1_786_522_436,
      platformConfiguration: Data("dory-platform-v1\n".utf8),
      toolchainDescriptor: Data("dory-toolchain-v1\n".utf8),
      firmwareCode: Data(repeating: 0xff, count: 4_096),
      secureBootPolicy: .userManagedKeys
    )
  }
}
