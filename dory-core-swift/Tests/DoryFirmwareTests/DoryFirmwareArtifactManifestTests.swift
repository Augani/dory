import CryptoKit
import DoryFirmware
import DoryMachineARMVirt
import DoryMachinePC
import Foundation
import Testing

@Suite struct DoryFirmwareArtifactManifestTests {
  @Test func manifestPinsEveryFirmwareAuthorityAndRoundTripsCanonically() throws {
    let fixture = Fixture()
    let manifest = try fixture.manifest()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(manifest)
    let decoded = try JSONDecoder().decode(DoryFirmwareArtifactManifest.self, from: data)

    #expect(decoded == manifest)
    #expect(decoded.firmwareABIIdentity == DoryARMVirtV1ABI.firmwareABIIdentity)
    #expect(decoded.machineABIIdentity == DoryARMVirtV1ABI.identity)
    #expect(decoded.variableStoreFormatIdentity == DoryARMVirtV1ABI.variableStoreFormatIdentity)
    #expect(decoded.variableBridgeIdentity == DoryFirmwareArtifactManifest.variableBridgeIdentity)
    #expect(decoded.reproducible)
    #expect(try encoder.encode(decoded) == data)
  }

  @Test func exactArtifactsVerifyAndAnySubstitutionFails() throws {
    let fixture = Fixture()
    let manifest = try fixture.manifest()
    try manifest.verify(
      firmwareCode: fixture.firmware,
      variableStoreTemplate: fixture.variables,
      sbom: fixture.sbom
    )

    var changedFirmware = fixture.firmware
    changedFirmware[0] ^= 0xff
    #expect(throws: DoryFirmwareManifestError.self) {
      try manifest.verify(
        firmwareCode: changedFirmware,
        variableStoreTemplate: fixture.variables,
        sbom: fixture.sbom
      )
    }
    #expect(throws: DoryFirmwareManifestError.self) {
      try manifest.verify(
        firmwareCode: fixture.firmware.dropLast(),
        variableStoreTemplate: fixture.variables,
        sbom: fixture.sbom
      )
    }
  }

  @Test func pcManifestPinsTheCompletePCFirmwareComposition() throws {
    let fixture = Fixture()
    let manifest = try fixture.manifest(platform: .pcV1)
    let data = try JSONEncoder().encode(manifest)
    let decoded = try JSONDecoder().decode(DoryFirmwareArtifactManifest.self, from: data)

    #expect(decoded.platform == .pcV1)
    #expect(decoded.firmwareABIIdentity == DoryPCV1ABI.firmwareABIIdentity)
    #expect(decoded.machineABIIdentity == DoryPCV1ABI.identity)
    #expect(decoded.variableStoreFormatIdentity == DoryPCV1ABI.variableStoreFormatIdentity)
    #expect(decoded.variableBridgeIdentity == DoryPCV1ABI.variableBridgeIdentity)
  }

  @Test func nonReproducibleOrUnpinnedBuildsAreRejected() throws {
    let fixture = Fixture()
    #expect(throws: DoryFirmwareManifestError.invalidSourceRevision("main")) {
      _ = try DoryFirmwareSourcePin(
        repository: "https://github.com/tianocore/edk2.git",
        revision: "main"
      )
    }
    #expect(throws: DoryFirmwareManifestError.invalidSourceRepository("file:///tmp/edk2")) {
      _ = try DoryFirmwareSourcePin(
        repository: "file:///tmp/edk2",
        revision: String(repeating: "a", count: 40)
      )
    }
    #expect(throws: DoryFirmwareManifestError.nonReproducibleBuild) {
      _ = try fixture.manifest(reproducible: false)
    }
  }

  @Test func decoderRejectsIdentitySubstitutionAndUnknownFields() throws {
    let fixture = Fixture()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let manifest = try fixture.manifest()
    let canonical = try encoder.encode(manifest)
    let text = String(decoding: canonical, as: UTF8.self)
    let wrongMachine = Data(
      text.replacingOccurrences(of: "dory.armvirt@1", with: "dory.pc@1").utf8
    )
    #expect(throws: DoryFirmwareManifestError.incompatibleMachineABI("dory.pc@1")) {
      _ = try JSONDecoder().decode(DoryFirmwareArtifactManifest.self, from: wrongMachine)
    }

    var object = try #require(JSONSerialization.jsonObject(with: canonical) as? [String: Any])
    object["future"] = true
    let unknown = try JSONSerialization.data(withJSONObject: object)
    #expect(
      throws: DoryFirmwareError.unknownFields(
        type: "DoryFirmwareArtifactManifest",
        fields: ["future"]
      )
    ) {
      _ = try JSONDecoder().decode(DoryFirmwareArtifactManifest.self, from: unknown)
    }
  }
}

private struct Fixture {
  let firmware = Data(repeating: 0xa5, count: 4_096)
  let variables = Data(#"{"generation":1,"variables":[]}"#.utf8)
  let sbom = Data(#"{"bomFormat":"CycloneDX","specVersion":"1.6"}"#.utf8)

  func manifest(
    platform: DoryFirmwarePlatform = .armVirtV1,
    reproducible: Bool = true
  ) throws -> DoryFirmwareArtifactManifest {
    try DoryFirmwareArtifactManifest(
      platform: platform,
      buildIdentifier: "dory-fw-test.1",
      source: DoryFirmwareSourcePin(
        repository: "https://github.com/tianocore/edk2.git",
        revision: String(repeating: "a", count: 40)
      ),
      sourceDateEpoch: 1_788_048_000,
      platformConfigurationSHA256: digest(Data("DoryARMVirt.dsc".utf8)),
      toolchainSHA256: digest(Data("clang-17F109".utf8)),
      firmwareCodeSHA256: digest(firmware),
      firmwareCodeByteCount: UInt64(firmware.count),
      variableStoreTemplateSHA256: digest(variables),
      variableStoreTemplateByteCount: UInt64(variables.count),
      sbomSHA256: digest(sbom),
      secureBootPolicy: .userManagedKeys,
      reproducible: reproducible
    )
  }

  private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
