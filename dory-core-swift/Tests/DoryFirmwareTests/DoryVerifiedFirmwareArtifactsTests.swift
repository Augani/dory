import CryptoKit
import DoryFirmware
import Foundation
import Testing

@Suite struct DoryVerifiedFirmwareArtifactsTests {
  @Test func admitsOnlyTheExactManifestArtifactSet() throws {
    let firmware = Data(repeating: 0xa5, count: 4_096)
    let variables = Data(#"{"generation":1,"variables":[]}"#.utf8)
    let sbom = Data(#"{"bomFormat":"CycloneDX","specVersion":"1.6"}"#.utf8)
    let manifest = try makeManifest(firmware: firmware, variables: variables, sbom: sbom)

    let verified = try DoryVerifiedFirmwareArtifacts(
      manifest: manifest,
      firmwareCode: firmware,
      variableStoreTemplate: variables,
      sbom: sbom
    )
    #expect(verified.manifest == manifest)
    #expect(verified.firmwareCode == firmware)
    #expect(verified.variableStoreTemplate == variables)
    #expect(verified.sbom == sbom)

    var substitutedSBOM = sbom
    substitutedSBOM[0] ^= 0xff
    #expect(throws: DoryFirmwareManifestError.self) {
      _ = try DoryVerifiedFirmwareArtifacts(
        manifest: manifest,
        firmwareCode: firmware,
        variableStoreTemplate: variables,
        sbom: substitutedSBOM
      )
    }
  }

  private func makeManifest(
    firmware: Data,
    variables: Data,
    sbom: Data
  ) throws -> DoryFirmwareArtifactManifest {
    try DoryFirmwareArtifactManifest(
      buildIdentifier: "dory-armvirt-fw-test.1",
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
      reproducible: true
    )
  }

  private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
