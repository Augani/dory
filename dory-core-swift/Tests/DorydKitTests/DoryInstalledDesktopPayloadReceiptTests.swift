@testable import DorydKit
import CryptoKit
import DoryOperations
import Foundation
import Testing

@Suite("Installed desktop payload receipt")
struct DoryInstalledDesktopPayloadReceiptTests {
    private let digest = String(repeating: "a", count: 64)

    @Test("verified receipts round trip with exact bundle evidence")
    func verifiedRoundTrip() throws {
        let receipt = DoryInstalledDesktopPayloadReceipt.verifiedUpdate(
            distributionIdentifier: "ubuntu",
            releaseVersion: "24.04.3+runtime.4.5.6",
            inputSHA256: digest,
            bundleSHA256: String(repeating: "b", count: 64),
            distributionComponentIdentifier: "desktop-ubuntu",
            distributionInstallationName: "ubuntu-installation",
            distributionCatalogSHA256: String(repeating: "c", count: 64),
            bundleAssetIdentifier: "dory-desktop-ubuntu-update-arm64.tar",
            runtimeComponentIdentifier: "linux-desktop",
            runtimeInstallationName: "runtime-installation",
            runtimeCatalogSHA256: String(repeating: "d", count: 64),
            kernelAssetIdentifier: "dory-desktop-kernel-arm64.lzfse",
            kernelSHA256: String(repeating: "e", count: 64)
        )
        #expect(receipt.isValid)
        #expect(
            try JSONDecoder().decode(
                DoryInstalledDesktopPayloadReceipt.self,
                from: JSONEncoder().encode(receipt)
            ) == receipt
        )
    }

    @Test("legacy projection requires a complete valid receipt and never invents bundle evidence")
    func legacyProjection() {
        let receipt = DoryInstalledDesktopPayloadReceipt.legacyEnvironment([
            "DORY_DESKTOP_DISTRO": "debian",
            "DORY_DESKTOP_RELEASE_VERSION": "13+runtime.7",
            "DORY_DESKTOP_INPUT_SHA256": digest,
            "OPAQUE": "preserve",
        ])
        #expect(receipt?.provenance == .legacyEnvironment)
        #expect(receipt?.bundleSHA256 == nil)
        #expect(receipt?.matchesLegacyEnvironment([
            "DORY_DESKTOP_DISTRO": "debian",
            "DORY_DESKTOP_RELEASE_VERSION": "13+runtime.7",
            "DORY_DESKTOP_INPUT_SHA256": digest,
        ]) == true)
        #expect(DoryInstalledDesktopPayloadReceipt.legacyEnvironment([
            "DORY_DESKTOP_DISTRO": "debian",
            "DORY_DESKTOP_RELEASE_VERSION": "13+runtime.7",
        ]) == nil)
        #expect(DoryInstalledDesktopPayloadReceipt.legacyEnvironment([
            "DORY_DESKTOP_DISTRO": "debian",
            "DORY_DESKTOP_RELEASE_VERSION": "13+runtime.7",
            "DORY_DESKTOP_INPUT_SHA256": String(repeating: "A", count: 64),
        ]) == nil)
    }

    @Test("receipt shapes fail closed")
    func invalidShapes() {
        let valid = DoryInstalledDesktopPayloadReceipt.verifiedUpdate(
            distributionIdentifier: "kali",
            releaseVersion: "rolling+runtime.1",
            inputSHA256: digest,
            bundleSHA256: String(repeating: "b", count: 64),
            distributionComponentIdentifier: "desktop-kali",
            distributionInstallationName: "kali-installation",
            distributionCatalogSHA256: String(repeating: "c", count: 64),
            bundleAssetIdentifier: "dory-desktop-kali-update-arm64.tar",
            runtimeComponentIdentifier: "linux-desktop",
            runtimeInstallationName: "runtime-installation",
            runtimeCatalogSHA256: String(repeating: "d", count: 64),
            kernelAssetIdentifier: "dory-desktop-kernel-arm64.lzfse",
            kernelSHA256: String(repeating: "e", count: 64)
        )
        var mutations: [DoryInstalledDesktopPayloadReceipt] = []
        var value = valid
        value.schemaVersion = 2
        mutations.append(value)
        value = valid
        value.distributionIdentifier = "windows"
        mutations.append(value)
        value = valid
        value.releaseVersion = "../unsafe"
        mutations.append(value)
        value = valid
        value.inputSHA256 = String(repeating: "A", count: 64)
        mutations.append(value)
        value = valid
        value.bundleSHA256 = nil
        mutations.append(value)
        value = valid
        value.provenance = .legacyEnvironment
        mutations.append(value)
        value = valid
        value.distributionInstallationName = ".."
        mutations.append(value)
        for mutation in mutations {
            #expect(!mutation.isValid)
        }
    }

    @Test("typed and legacy authorities cannot conflict")
    func authorityCoherence() {
        let verified = DoryInstalledDesktopPayloadReceipt.verifiedUpdate(
            distributionIdentifier: "ubuntu",
            releaseVersion: "24.04+runtime.7",
            inputSHA256: digest,
            bundleSHA256: String(repeating: "b", count: 64),
            distributionComponentIdentifier: "desktop-ubuntu",
            distributionInstallationName: "ubuntu-installation",
            distributionCatalogSHA256: String(repeating: "c", count: 64),
            bundleAssetIdentifier: "dory-desktop-ubuntu-update-arm64.tar",
            runtimeComponentIdentifier: "linux-desktop",
            runtimeInstallationName: "runtime-installation",
            runtimeCatalogSHA256: String(repeating: "d", count: 64),
            kernelAssetIdentifier: "dory-desktop-kernel-arm64.lzfse",
            kernelSHA256: String(repeating: "e", count: 64)
        )
        #expect(verified.hasCoherentAuthority(environment: [:]))
        #expect(verified.hasCoherentAuthority(environment: ["DORY_DESKTOP_DISTRO": "ubuntu"]))
        #expect(!verified.hasCoherentAuthority(environment: ["DORY_DESKTOP_DISTRO": "kali"]))
        #expect(!verified.hasCoherentAuthority(environment: [
            "DORY_DESKTOP_DISTRO": "ubuntu",
            "DORY_DESKTOP_RELEASE_VERSION": "24.04+runtime.7",
        ]))

        let legacyEnvironment = [
            "DORY_DESKTOP_DISTRO": "ubuntu",
            "DORY_DESKTOP_RELEASE_VERSION": "24.04+runtime.6",
            "DORY_DESKTOP_INPUT_SHA256": digest,
        ]
        let legacy = DoryInstalledDesktopPayloadReceipt.legacyEnvironment(legacyEnvironment)
        #expect(legacy?.hasCoherentAuthority(environment: legacyEnvironment) == true)
        #expect(legacy?.hasCoherentAuthority(environment: [:]) == false)
        #expect(legacy?.archivedLegacySnapshotReceipt?.hasCoherentAuthority(environment: [:]) == true)
    }

    @Test("production resolver binds active signed component generations and rejects stale IDs")
    func productionResolver() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-desktop-update-resolver-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let drive = try DoryDataDrive(home: root.path)
        try drive.prepare()
        let store = DoryComponentStore(drive: drive)
        try store.prepare()
        let bundleData = Data("signed ubuntu update".utf8)
        let kernelData = Data("signed desktop kernel".utf8)
        let digest: (Data) -> String = { data in
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        let asset: (String, Data) -> DoryComponentAsset = { path, data in
            DoryComponentAsset(
                path: path,
                url: "https://components.invalid/" + path,
                downloadBytes: UInt64(data.count),
                installedBytes: UInt64(data.count),
                sha256: digest(data),
                installedSHA256: digest(data)
            )
        }
        let runtime = DoryComponentRelease(
            id: .linuxDesktop,
            version: "4.5.6",
            displayName: "Linux Desktop",
            summary: "runtime",
            downloadBytes: UInt64(kernelData.count),
            installedBytes: UInt64(kernelData.count),
            assets: [asset(DoryInstalledDesktopPayloadReceipt.kernelAssetIdentifier, kernelData)]
        )
        let bundleID = DoryInstalledDesktopPayloadReceipt.bundleAssetIdentifier(
            for: "ubuntu"
        )
        let ubuntu = DoryComponentRelease(
            id: .desktopUbuntu,
            version: "1.2.3",
            displayName: "Ubuntu",
            summary: "desktop",
            dependencies: [.dockerCore, .linuxDesktop],
            downloadBytes: UInt64(bundleData.count),
            installedBytes: UInt64(bundleData.count),
            assets: [asset(bundleID, bundleData)]
        )
        let core = DoryComponentRelease(
            id: .dockerCore,
            version: "0.4.0",
            displayName: "Docker Core",
            summary: "Docker, Compose, Buildx, networking, and storage",
            dependencies: [],
            downloadBytes: 100,
            installedBytes: 200,
            assets: []
        )
        let catalog = DoryComponentCatalog(
            schemaVersion: 1,
            releaseVersion: "0.4.0",
            generatedAt: "2026-08-20T00:00:00Z",
            minimumAppVersion: "0.4.5",
            architecture: "arm64",
            components: [core, runtime, ubuntu]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let catalogData = try encoder.encode(catalog) + Data("\n".utf8)
        let signingKey = Curve25519.Signing.PrivateKey()
        let publicKey = signingKey.publicKey.rawRepresentation.base64EncodedString()
        _ = try store.cacheCatalog(
            data: catalogData,
            signature: try signingKey.signature(for: catalogData).base64EncodedString(),
            publicKey: publicKey,
            expectedArchitecture: "arm64",
            appVersion: "0.4.5"
        )
        let sourceDirectory = root.appendingPathComponent("sources")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        let kernelSource = sourceDirectory.appendingPathComponent("kernel")
        let bundleSource = sourceDirectory.appendingPathComponent("bundle")
        try kernelData.write(to: kernelSource)
        try bundleData.write(to: bundleSource)
        let catalogSHA256 = DoryComponentCatalogVerifier.digest(catalogData)
        let runtimeInstalled = try store.install(
            runtime,
            catalogDigest: catalogSHA256,
            downloadedAssets: [runtime.assets[0].path: kernelSource.path]
        )
        let ubuntuInstalled = try store.install(
            ubuntu,
            catalogDigest: catalogSHA256,
            downloadedAssets: [ubuntu.assets[0].path: bundleSource.path]
        )
        let resolver = DoryComponentStoreDesktopUpdateArtifactResolver(
            store: store,
            publicKey: publicKey,
            expectedArchitecture: "arm64",
            appVersion: "0.4.5"
        )
        let productionResolver = DoryComponentStoreDesktopUpdateArtifactResolver(store: store)
        #expect(
            productionResolver.appVersion
                == DoryDaemonVirtualMachineProductionTrustFactory.compiledDaemonVersion
        )
        try DoryComponentCatalogVerifier.validate(
            catalog,
            expectedArchitecture: productionResolver.expectedArchitecture,
            appVersion: productionResolver.appVersion
        )
        let request = DoryDesktopUpdateRequest(
            distro: "ubuntu",
            version: "1.2.3+runtime.4.5.6",
            distributionInstallationName: ubuntuInstalled.installationName,
            runtimeInstallationName: runtimeInstalled.installationName
        )
        let authority = try resolver.resolve(request, guestArchitecture: "arm64")
        #expect(authority.receipt.distributionCatalogSHA256 == catalogSHA256)
        #expect(authority.receipt.bundleSHA256 == digest(bundleData))
        #expect(authority.receipt.kernelSHA256 == digest(kernelData))

        var stale = request
        stale.runtimeInstallationName = "4.5.6-stale"
        #expect(throws: (any Error).self) {
            _ = try resolver.resolve(stale, guestArchitecture: "arm64")
        }
        try Data("tampered".utf8).write(to: URL(fileURLWithPath: authority.bundlePath))
        #expect(throws: (any Error).self) {
            _ = try resolver.resolve(request, guestArchitecture: "arm64")
        }
    }
}
