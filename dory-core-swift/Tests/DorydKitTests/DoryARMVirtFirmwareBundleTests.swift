import CryptoKit
import Darwin
import DoryFirmware
import Foundation
@testable import DorydKit
import XCTest

final class DoryARMVirtFirmwareBundleTests: XCTestCase {
    func testLoadsOnlyTheCompleteVerifiedBundle() throws {
        let fixture = try makeBundle()
        defer { try? FileManager.default.removeItem(atPath: fixture.directory) }

        let admitted = try DoryARMVirtFirmwareBundle(directory: fixture.directory).loadVerified()
        XCTAssertEqual(admitted.manifest, fixture.manifest)
        XCTAssertEqual(admitted.firmwareCode, fixture.firmware)
        XCTAssertEqual(admitted.variableStoreTemplate, fixture.variables)
        XCTAssertEqual(admitted.sbom, fixture.sbom)

        try Data("substitution".utf8).write(
            to: URL(fileURLWithPath: fixture.directory)
                .appendingPathComponent(DoryARMVirtFirmwareBundleLayout.sbom)
        )
        XCTAssertThrowsError(
            try DoryARMVirtFirmwareBundle(directory: fixture.directory).loadVerified()
        )
    }

    func testRejectsWritableBundleDirectory() throws {
        let fixture = try makeBundle()
        defer { try? FileManager.default.removeItem(atPath: fixture.directory) }
        XCTAssertEqual(chmod(fixture.directory, 0o777), 0)
        XCTAssertThrowsError(
            try DoryARMVirtFirmwareBundle(directory: fixture.directory).loadVerified()
        )
    }

    private func makeBundle() throws -> (
        directory: String,
        manifest: DoryFirmwareArtifactManifest,
        firmware: Data,
        variables: Data,
        sbom: Data
    ) {
        let directory = "/tmp/dory-firmware-bundle-\(getpid())-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false)
        XCTAssertEqual(chmod(directory, 0o755), 0)
        let firmware = Data(repeating: 0xa5, count: 4_096)
        let variables = try DoryUEFIVariableStoreSnapshot().canonicalData()
        let sbom = Data(#"{"bomFormat":"CycloneDX","specVersion":"1.6"}"#.utf8)
        let manifest = try DoryFirmwareArtifactManifest(
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
        let files: [(String, Data)] = [
            (DoryARMVirtFirmwareBundleLayout.manifest, try JSONEncoder().encode(manifest)),
            (DoryARMVirtFirmwareBundleLayout.firmwareCode, firmware),
            (DoryARMVirtFirmwareBundleLayout.variableStoreTemplate, variables),
            (DoryARMVirtFirmwareBundleLayout.sbom, sbom),
        ]
        for (name, data) in files {
            let path = directory + "/" + name
            try data.write(to: URL(fileURLWithPath: path))
            XCTAssertEqual(chmod(path, 0o644), 0)
        }
        return (directory, manifest, firmware, variables, sbom)
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
