@testable import DoryOperations
import CryptoKit
import Foundation
import XCTest

final class DoryVirtualMachineQualificationManifestTests: XCTestCase {
    func testSignedCatalogInstalledManifestMintsOnlyExactTrustedQualification() throws {
        let fixture = try QualificationFixture()
        defer { fixture.cleanup() }
        let installed = try fixture.installAuthority()
        let authority = try fixture.resolveAuthority()

        XCTAssertEqual(authority.catalogDigest, installed.catalogDigest)
        XCTAssertEqual(authority.manifestIdentity, fixture.manifest.manifestIdentity)
        let resolved = try authority.resolve(
            request: fixture.request,
            backendImplementationIdentifier:
                RawBackendContract.implementationIdentifier,
            backendRuntimeBuildIdentifier: fixture.runtimeBuild,
            hostHardwareModelIdentifier: fixture.hostModel,
            hostOperatingSystemBuild: fixture.hostBuild,
            installedComponents: fixture.runtimeComponents
        )
        let descriptor = DoryAppleSiliconCapabilityEvaluator.evaluate(
            fixture.request,
            host: fixture.hostFacts,
            trustedGuestImageGraphicsQualification: resolved.graphics,
            trustedRuntimeQualification: resolved.runtime
        )
        XCTAssertEqual(descriptor.availability.supportTier, .supported)
        XCTAssertEqual(descriptor.availability.state, .available)
        XCTAssertEqual(
            descriptor.runtimeQualificationEvidence?.qualificationIdentity,
            fixture.record.qualificationIdentity
        )
    }

    func testCatalogV1CannotBecomeQualificationAuthority() throws {
        let fixture = try QualificationFixture(catalogSchemaVersion: 1, declaresAuthority: false)
        defer { fixture.cleanup() }
        try fixture.installAuthority()

        XCTAssertThrowsError(try fixture.resolveAuthority()) { error in
            XCTAssertEqual(
                error as? DoryVirtualMachineQualificationAuthorityError,
                .catalogSchemaUnsupported(1)
            )
        }
    }

    func testMissingDeclarationFailsClosed() throws {
        let fixture = try QualificationFixture(declaresAuthority: false)
        defer { fixture.cleanup() }
        try fixture.installAuthority()

        XCTAssertThrowsError(try fixture.resolveAuthority()) { error in
            XCTAssertEqual(
                error as? DoryVirtualMachineQualificationAuthorityError,
                .authorityUndeclared
            )
        }
    }

    func testTamperedCatalogSignatureAndManifestFailClosed() throws {
        do {
            let fixture = try QualificationFixture()
            defer { fixture.cleanup() }
            try fixture.installAuthority()
            let signaturePath = fixture.store.root + "/catalog.sig"
            try Data("not-a-signature".utf8).write(to: URL(fileURLWithPath: signaturePath))
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: signaturePath
            )
            XCTAssertThrowsError(try fixture.resolveAuthority()) { error in
                XCTAssertEqual(error as? DoryComponentError, .invalidSignature)
            }
        }

        do {
            let fixture = try QualificationFixture()
            defer { fixture.cleanup() }
            let installed = try fixture.installAuthority()
            let path = try XCTUnwrap(fixture.store.assetPath(
                component: .linuxMachines,
                path: fixture.manifestPath
            ))
            var data = try Data(contentsOf: URL(fileURLWithPath: path))
            data.append(0x20)
            try data.write(to: URL(fileURLWithPath: path))
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: path
            )
            XCTAssertFalse(installed.assets.isEmpty)
            XCTAssertThrowsError(try fixture.resolveAuthority()) { error in
                XCTAssertEqual(
                    error as? DoryVirtualMachineQualificationAuthorityError,
                    .installedComponentUnavailable
                )
            }
        }
    }

    func testStaleRuntimeBuildAndComponentDigestCannotMintTrust() throws {
        let fixture = try QualificationFixture()
        defer { fixture.cleanup() }
        try fixture.installAuthority()
        let authority = try fixture.resolveAuthority()

        XCTAssertThrowsError(try authority.resolve(
            request: fixture.request,
            backendImplementationIdentifier: RawBackendContract.implementationIdentifier,
            backendRuntimeBuildIdentifier: "sha256:stale",
            hostHardwareModelIdentifier: fixture.hostModel,
            hostOperatingSystemBuild: fixture.hostBuild,
            installedComponents: fixture.runtimeComponents
        )) { error in
            XCTAssertEqual(
                error as? DoryVirtualMachineQualificationAuthorityError,
                .qualificationUnavailable
            )
        }

        var components = fixture.runtimeComponents
        components[0].artifactSHA256 = String(repeating: "f", count: 64)
        XCTAssertThrowsError(try authority.resolve(
            request: fixture.request,
            backendImplementationIdentifier: RawBackendContract.implementationIdentifier,
            backendRuntimeBuildIdentifier: fixture.runtimeBuild,
            hostHardwareModelIdentifier: fixture.hostModel,
            hostOperatingSystemBuild: fixture.hostBuild,
            installedComponents: components
        ))
    }
}

private enum RawBackendContract {
    static let implementationIdentifier = "dory.raw-hv-linux.compatibility.v1"
}

private final class QualificationFixture {
    let root: URL
    let store: DoryComponentStore
    let privateKey = Curve25519.Signing.PrivateKey()
    let appVersion = "1.0.0"
    let manifestPath = "vm-qualifications.json"
    let hostModel = "Mac15,3"
    let hostBuild = "26A5406c"
    let mediaDigest = String(repeating: "a", count: 64)
    let helperDigest = String(repeating: "b", count: 64)
    let runtimeBuild: String
    let runtimeComponents: [DoryVirtualMachineQualifiedComponent]
    let request: DoryVirtualMachineCapabilityRequest
    let record: DoryVirtualMachineQualificationRecord
    let manifest: DoryVirtualMachineQualificationManifest
    let catalog: DoryComponentCatalog
    let catalogData: Data
    let catalogSignature: String
    let manifestData: Data

    var hostFacts: DoryAppleSiliconHostFacts {
        DoryAppleSiliconHostFacts(
            macOSMajorVersion: 26,
            virtualizationFrameworkAvailable: true,
            hypervisorFrameworkAvailable: true,
            doryHypervisorAvailable: true,
            qemuHypervisorFrameworkAvailable: false,
            windowsUEFIFirmwareAvailable: false,
            windowsSecureBootAvailable: false,
            windowsSBSADeviceModelAvailable: false,
            virtualTPM20Available: false,
            windowsGuestDrivers: DoryWindowsGuestDriverFacts(
                storageAvailable: false,
                networkAvailable: false,
                displayAvailable: false,
                inputAvailable: false
            ),
            macOSGuestVirtualizationSupported: false,
            macOSRestoreImageInstallationSupported: false,
            doryMacOSBackendAvailable: false,
            doryMacOSBackendQualified: false,
            metalAvailable: true,
            doryAcceleratedRendererAvailable: true,
            runtimeQualificationContext: DoryVirtualMachineRuntimeQualificationHostContext(
                virtualHardwareABIVersion: 1,
                doryHypervisorRuntimeBuildID: runtimeBuild,
                virtualizationFrameworkAdapterBuildID: "",
                qemuRuntimeBuildID: ""
            )
        )
    }

    init(catalogSchemaVersion: Int = 2, declaresAuthority: Bool = true) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "dory-vm-qualification-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let drive = try DoryDataDrive(home: root.path)
        try drive.prepare()
        store = DoryComponentStore(drive: drive)
        try store.prepare()

        runtimeBuild = "sha256:\(helperDigest)"
        runtimeComponents = [DoryVirtualMachineQualifiedComponent(
            componentIdentifier: "dory-hv",
            buildIdentifier: runtimeBuild,
            artifactSHA256: helperDigest
        )]
        let devices = DoryVirtualMachineDeviceCapabilityRequest.minimumBootable
        request = DoryVirtualMachineCapabilityRequest(
            guest: DoryGuestPlatform(family: .linux, architecture: .arm64),
            bootMedia: DoryBootMedia(
                kind: .installedLinuxBootBundle,
                source: .bundledByDory,
                artifactSHA256: mediaDigest
            ),
            backend: .doryHypervisor,
            graphics: .none,
            devices: devices
        )
        record = DoryVirtualMachineQualificationRecord(
            qualificationIdentity: "raw-linux-arm64-none-v1",
            guest: request.guest,
            bootMediaKind: request.bootMedia.kind,
            bootMediaSource: request.bootMedia.source,
            immutableArtifactSHA256: mediaDigest,
            backend: request.backend,
            backendImplementationIdentifier: RawBackendContract.implementationIdentifier,
            backendRuntimeBuildIdentifier: runtimeBuild,
            virtualHardwareABIVersion: request.virtualHardwareABIVersion,
            graphics: request.graphics,
            devices: devices,
            hostHardwareModelIdentifier: hostModel,
            hostOperatingSystemBuild: hostBuild,
            components: runtimeComponents
        )
        let signingKeyID = Self.digest(privateKey.publicKey.rawRepresentation)
        manifest = DoryVirtualMachineQualificationManifest(
            manifestIdentity: "dory-vm-qualifications-2026.8",
            catalogReleaseVersion: "1.0.0",
            architecture: "arm64",
            signingKeyID: signingKeyID,
            records: [record]
        )
        manifestData = try Self.encoded(manifest)
        let asset = DoryComponentAsset(
            path: manifestPath,
            url: "https://example.invalid/\(manifestPath)",
            downloadBytes: UInt64(manifestData.count),
            installedBytes: UInt64(manifestData.count),
            sha256: Self.digest(manifestData),
            installedSHA256: Self.digest(manifestData)
        )
        let core = DoryComponentRelease(
            id: .dockerCore,
            version: "1.0.0",
            displayName: "Docker Core",
            summary: "Core",
            dependencies: [],
            downloadBytes: 1,
            installedBytes: 1,
            assets: []
        )
        let machines = DoryComponentRelease(
            id: .linuxMachines,
            version: "1.0.0",
            displayName: "Linux Machines",
            summary: "Qualified Linux runtimes",
            dependencies: [.dockerCore],
            downloadBytes: UInt64(manifestData.count),
            installedBytes: UInt64(manifestData.count),
            assets: [asset]
        )
        catalog = DoryComponentCatalog(
            schemaVersion: catalogSchemaVersion,
            releaseVersion: "1.0.0",
            generatedAt: "2026-08-20T12:00:00.000Z",
            minimumAppVersion: appVersion,
            architecture: "arm64",
            components: [core, machines],
            virtualMachineQualification: declaresAuthority
                ? DoryComponentVirtualMachineQualificationAsset(
                    component: .linuxMachines,
                    path: manifestPath,
                    manifestIdentity: manifest.manifestIdentity,
                    manifestFormatVersion: manifest.schemaVersion,
                    signingKeyID: signingKeyID
                ) : nil
        )
        catalogData = try Self.encoded(catalog)
        catalogSignature = try privateKey.signature(for: catalogData).base64EncodedString()
    }

    @discardableResult
    func installAuthority() throws -> DoryInstalledComponent {
        _ = try store.cacheCatalog(
            data: catalogData,
            signature: catalogSignature,
            publicKey: privateKey.publicKey.rawRepresentation.base64EncodedString(),
            expectedArchitecture: "arm64",
            appVersion: appVersion
        )
        let source = root.appendingPathComponent("qualification-source.json")
        try manifestData.write(to: source)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: source.path
        )
        return try store.install(
            try XCTUnwrap(catalog.component(.linuxMachines)),
            catalogDigest: DoryComponentCatalogVerifier.digest(catalogData),
            downloadedAssets: [manifestPath: source.path]
        )
    }

    func resolveAuthority() throws -> DoryVerifiedVirtualMachineQualificationAuthority {
        try DoryVirtualMachineQualificationAuthorityResolver.resolve(
            store: store,
            publicKey: privateKey.publicKey.rawRepresentation.base64EncodedString(),
            expectedArchitecture: "arm64",
            appVersion: appVersion
        )
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    private static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value) + Data("\n".utf8)
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
