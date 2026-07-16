@testable import DoryOperations
import CryptoKit
import Foundation
import XCTest

final class DoryComponentsTests: XCTestCase {
    func testSignedCatalogRejectsTamperingWrongArchitectureAndOldApp() throws {
        let key = Curve25519.Signing.PrivateKey()
        let catalog = catalog(components: [core()])
        let data = try encoded(catalog)
        let signature = try key.signature(for: data).base64EncodedString()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()

        XCTAssertEqual(
            try DoryComponentCatalogVerifier.verify(
                catalogData: data,
                signatureBase64: signature,
                publicKeyBase64: publicKey,
                expectedArchitecture: "arm64",
                appVersion: "0.4.0"
            ),
            catalog
        )

        var tampered = data
        tampered.append(0x20)
        XCTAssertThrowsError(try DoryComponentCatalogVerifier.verify(
            catalogData: tampered,
            signatureBase64: signature,
            publicKeyBase64: publicKey,
            expectedArchitecture: "arm64",
            appVersion: "0.4.0"
        )) { error in
            XCTAssertEqual(error as? DoryComponentError, .invalidSignature)
        }
        XCTAssertThrowsError(try DoryComponentCatalogVerifier.verify(
            catalogData: data,
            signatureBase64: signature,
            publicKeyBase64: publicKey,
            expectedArchitecture: "amd64",
            appVersion: "0.4.0"
        )) { error in
            XCTAssertEqual(
                error as? DoryComponentError,
                .incompatibleArchitecture(expected: "amd64", actual: "arm64")
            )
        }
        XCTAssertThrowsError(try DoryComponentCatalogVerifier.verify(
            catalogData: data,
            signatureBase64: signature,
            publicKeyBase64: publicKey,
            expectedArchitecture: "arm64",
            appVersion: "0.3.1"
        )) { error in
            XCTAssertEqual(
                error as? DoryComponentError,
                .incompatibleAppVersion(required: "0.4.0", actual: "0.3.1")
            )
        }
    }

    func testCatalogRejectsDuplicatePathsCyclesAndDisagreeingSizes() throws {
        let payload = Data("kubectl".utf8)
        let asset = try plainAsset(path: "kubectl", data: payload)
        let duplicate = DoryComponentRelease(
            id: .kubernetes,
            version: "1.0.0",
            displayName: "Kubernetes",
            summary: "Local Kubernetes",
            downloadBytes: UInt64(payload.count * 2),
            installedBytes: UInt64(payload.count * 2),
            assets: [asset, asset]
        )
        XCTAssertThrowsError(try DoryComponentCatalogVerifier.validate(
            catalog(components: [core(), duplicate]),
            expectedArchitecture: "arm64",
            appVersion: "0.4.0"
        ))

        let desktop = release(
            id: .linuxDesktop,
            data: Data("desktop".utf8),
            dependencies: [.dockerCore, .desktopUbuntu]
        )
        let ubuntu = release(
            id: .desktopUbuntu,
            data: Data("ubuntu".utf8),
            dependencies: [.dockerCore, .linuxDesktop]
        )
        XCTAssertThrowsError(try DoryComponentCatalogVerifier.validate(
            catalog(components: [core(), desktop, ubuntu]),
            expectedArchitecture: "arm64",
            appVersion: "0.4.0"
        )) { error in
            XCTAssertEqual(error as? DoryComponentError, .invalidCatalog("component dependency cycle"))
        }
    }

    func testInstallVerifyAndRemovePreserveEveryWorkloadDirectory() throws {
        let fixture = try Fixture(name: "preserve")
        defer { fixture.cleanup() }
        let payload = Data("verified kubectl payload".utf8)
        let source = try fixture.write(payload, name: "kubectl-source")
        let kubernetes = release(id: .kubernetes, data: payload, assetPath: "kubectl")
        let catalog = catalog(components: [core(), kubernetes])
        let catalogData = try encoded(catalog)
        let workloadPaths = [
            fixture.drive.engineDirectory + "/container-state",
            fixture.drive.kubernetesDirectory + "/cluster-state",
            fixture.drive.machinesDirectory + "/machine-disk",
            fixture.drive.snapshotsDirectory + "/snapshot",
            fixture.drive.exportsDirectory + "/backup",
        ]
        for path in workloadPaths { try Data("user data".utf8).write(to: URL(fileURLWithPath: path)) }

        let installed = try fixture.store.install(
            kubernetes,
            catalogDigest: DoryComponentCatalogVerifier.digest(catalogData),
            downloadedAssets: ["kubectl": source.path]
        )

        XCTAssertEqual(installed.id, .kubernetes)
        XCTAssertEqual(try fixture.store.verify(.kubernetes), installed)
        XCTAssertEqual(
            fixture.store.assetPath(component: .kubernetes, path: "kubectl").flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) },
            payload
        )
        XCTAssertEqual(
            fixture.store.list(
                catalog: catalog,
                catalogDigest: DoryComponentCatalogVerifier.digest(catalogData)
            ).first(where: { $0.id == .kubernetes })?.state,
            .installed
        )

        try fixture.store.remove(.kubernetes, catalog: catalog)
        XCTAssertNil(try fixture.store.installedComponent(.kubernetes))
        XCTAssertNil(fixture.store.assetPath(component: .kubernetes, path: "kubectl"))
        for path in workloadPaths {
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data("user data".utf8))
        }
    }

    func testDependenciesBlockInstallAndRemovalInTheWrongOrder() throws {
        let fixture = try Fixture(name: "dependencies")
        defer { fixture.cleanup() }
        let desktopData = Data("desktop kernel".utf8)
        let ubuntuData = Data("ubuntu rootfs".utf8)
        let desktop = release(id: .linuxDesktop, data: desktopData)
        let ubuntu = release(
            id: .desktopUbuntu,
            data: ubuntuData,
            dependencies: [.dockerCore, .linuxDesktop]
        )
        let catalog = catalog(components: [core(), desktop, ubuntu])
        let digest = DoryComponentCatalogVerifier.digest(try encoded(catalog))
        let desktopSource = try fixture.write(desktopData, name: "desktop")
        let ubuntuSource = try fixture.write(ubuntuData, name: "ubuntu")

        XCTAssertThrowsError(try fixture.store.install(
            ubuntu,
            catalogDigest: digest,
            downloadedAssets: [ubuntu.assets[0].path: ubuntuSource.path]
        )) { error in
            XCTAssertEqual(error as? DoryComponentError, .missingDependency(.linuxDesktop))
        }

        try fixture.store.install(
            desktop,
            catalogDigest: digest,
            downloadedAssets: [desktop.assets[0].path: desktopSource.path]
        )
        try fixture.store.install(
            ubuntu,
            catalogDigest: digest,
            downloadedAssets: [ubuntu.assets[0].path: ubuntuSource.path]
        )
        XCTAssertThrowsError(try fixture.store.remove(.linuxDesktop, catalog: catalog)) { error in
            XCTAssertEqual(error as? DoryComponentError, .componentInUse(.desktopUbuntu))
        }
        try fixture.store.remove(.desktopUbuntu, catalog: catalog)
        try fixture.store.remove(.linuxDesktop, catalog: catalog)
        XCTAssertNil(try fixture.store.installedComponent(.linuxDesktop))
    }

    func testFailedUpdateLeavesPreviousVersionActive() throws {
        let fixture = try Fixture(name: "failed-update")
        defer { fixture.cleanup() }
        let firstData = Data("version one".utf8)
        let secondData = Data("version two".utf8)
        let first = release(id: .linuxMachines, version: "1.0.0", data: firstData)
        let second = release(id: .linuxMachines, version: "2.0.0", data: secondData)
        let firstSource = try fixture.write(firstData, name: "first")
        let corruptSource = try fixture.write(Data("corrupt".utf8), name: "corrupt")

        try fixture.store.install(
            first,
            catalogDigest: String(repeating: "1", count: 64),
            downloadedAssets: [first.assets[0].path: firstSource.path]
        )
        XCTAssertThrowsError(try fixture.store.install(
            second,
            catalogDigest: String(repeating: "2", count: 64),
            downloadedAssets: [second.assets[0].path: corruptSource.path]
        ))

        let active = try XCTUnwrap(fixture.store.installedComponent(.linuxMachines))
        XCTAssertEqual(active.version, "1.0.0")
        XCTAssertEqual(try fixture.store.verify(.linuxMachines), active)
    }

    func testCorruptionFailsClosedAndIsReportedInvalid() throws {
        let fixture = try Fixture(name: "corruption")
        defer { fixture.cleanup() }
        let payload = Data("machine image".utf8)
        let component = release(id: .linuxMachines, data: payload)
        let catalog = catalog(components: [core(), component])
        let catalogData = try encoded(catalog)
        let source = try fixture.write(payload, name: "machine")
        try fixture.store.install(
            component,
            catalogDigest: DoryComponentCatalogVerifier.digest(catalogData),
            downloadedAssets: [component.assets[0].path: source.path]
        )
        let path = try XCTUnwrap(fixture.store.assetPath(
            component: .linuxMachines,
            path: component.assets[0].path
        ))
        try Data("tampered data".utf8).write(to: URL(fileURLWithPath: path))

        XCTAssertThrowsError(try fixture.store.verify(.linuxMachines))
        XCTAssertEqual(
            fixture.store.list(
                catalog: catalog,
                catalogDigest: DoryComponentCatalogVerifier.digest(catalogData)
            ).first(where: { $0.id == .linuxMachines })?.state,
            .invalid
        )
    }

    func testLZFSEAssetIsBoundedVerifiedAndMadeExecutable() throws {
        let fixture = try Fixture(name: "lzfse")
        defer { fixture.cleanup() }
        let payload = Data(repeating: 0x41, count: 128 * 1_024)
        let compressed = try compressLZFSE(payload)
        let source = try fixture.write(compressed, name: "tool.lzfse")
        let asset = DoryComponentAsset(
            path: "machine-tool",
            url: source.absoluteString,
            compression: .lzfse,
            downloadBytes: UInt64(compressed.count),
            installedBytes: UInt64(payload.count),
            sha256: digest(compressed),
            installedSHA256: digest(payload),
            executable: true
        )
        let component = DoryComponentRelease(
            id: .linuxMachines,
            version: "1.0.0",
            displayName: "Linux Machines",
            summary: "Headless Linux machines",
            downloadBytes: asset.downloadBytes,
            installedBytes: asset.installedBytes,
            assets: [asset]
        )

        try fixture.store.install(
            component,
            catalogDigest: String(repeating: "a", count: 64),
            downloadedAssets: [asset.path: source.path]
        )
        let output = try XCTUnwrap(fixture.store.assetPath(component: .linuxMachines, path: asset.path))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: output)), payload)
        let attributes = try FileManager.default.attributesOfItem(atPath: output)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testCachedCatalogIsReverifiedEveryTime() throws {
        let fixture = try Fixture(name: "catalog-cache")
        defer { fixture.cleanup() }
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        let catalog = catalog(components: [core()])
        let data = try encoded(catalog)
        let signature = try key.signature(for: data).base64EncodedString()

        _ = try fixture.store.cacheCatalog(
            data: data,
            signature: signature,
            publicKey: publicKey,
            expectedArchitecture: "arm64",
            appVersion: "0.4.0"
        )
        XCTAssertEqual(
            try fixture.store.cachedCatalog(
                publicKey: publicKey,
                expectedArchitecture: "arm64",
                appVersion: "0.4.0"
            )?.catalog,
            catalog
        )

        let path = fixture.drive.componentsDirectory + "/catalog.json"
        var tampered = try Data(contentsOf: URL(fileURLWithPath: path))
        tampered.append(0x20)
        try tampered.write(to: URL(fileURLWithPath: path), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        XCTAssertThrowsError(try fixture.store.cachedCatalog(
            publicKey: publicKey,
            expectedArchitecture: "arm64",
            appVersion: "0.4.0"
        )) { error in
            XCTAssertEqual(error as? DoryComponentError, .invalidSignature)
        }
    }

    func testSymlinkSourceIsRejectedWithoutReadingItsTarget() throws {
        let fixture = try Fixture(name: "symlink")
        defer { fixture.cleanup() }
        let payload = Data("outside".utf8)
        let target = try fixture.write(payload, name: "outside")
        let link = fixture.root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target.path)
        let component = release(id: .kubernetes, data: payload, assetPath: "kubectl")

        XCTAssertThrowsError(try fixture.store.install(
            component,
            catalogDigest: String(repeating: "f", count: 64),
            downloadedAssets: ["kubectl": link.path]
        ))
        XCTAssertEqual(try Data(contentsOf: target), payload)
        XCTAssertNil(try fixture.store.installedComponent(.kubernetes))
    }

    private func core() -> DoryComponentRelease {
        DoryComponentRelease(
            id: .dockerCore,
            version: "0.4.0",
            displayName: "Docker Core",
            summary: "Docker, Compose, Buildx, networking, and storage",
            dependencies: [],
            downloadBytes: 100,
            installedBytes: 200,
            assets: []
        )
    }

    private func release(
        id: DoryComponentID,
        version: String = "1.0.0",
        data: Data,
        assetPath: String? = nil,
        dependencies: [DoryComponentID] = [.dockerCore]
    ) -> DoryComponentRelease {
        let path = assetPath ?? "\(id.rawValue)-payload"
        let asset = try! plainAsset(path: path, data: data)
        return DoryComponentRelease(
            id: id,
            version: version,
            displayName: id.rawValue,
            summary: "Optional \(id.rawValue)",
            dependencies: dependencies,
            downloadBytes: UInt64(data.count),
            installedBytes: UInt64(data.count),
            assets: [asset]
        )
    }

    private func catalog(components: [DoryComponentRelease]) -> DoryComponentCatalog {
        DoryComponentCatalog(
            releaseVersion: "0.4.0",
            generatedAt: "2026-07-16T12:00:00Z",
            minimumAppVersion: "0.4.0",
            architecture: "arm64",
            components: components
        )
    }

    private func plainAsset(path: String, data: Data) throws -> DoryComponentAsset {
        DoryComponentAsset(
            path: path,
            url: "file:///tmp/\(path)",
            downloadBytes: UInt64(data.count),
            installedBytes: UInt64(data.count),
            sha256: digest(data),
            installedSHA256: digest(data)
        )
    }

    private func encoded(_ catalog: DoryComponentCatalog) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(catalog) + Data("\n".utf8)
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func compressLZFSE(_ data: Data) throws -> Data {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-component-compression-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("input")
        let output = directory.appendingPathComponent("output.lzfse")
        try data.write(to: input)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/compression_tool")
        process.arguments = ["-encode", "-a", "lzfse", "-i", input.path, "-o", output.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw DoryComponentError.invalidAsset("test compression")
        }
        return try Data(contentsOf: output)
    }

    private final class Fixture {
        let root: URL
        let drive: DoryDataDrive
        let store: DoryComponentStore

        init(name: String) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("dory-components-\(name)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            drive = try DoryDataDrive(home: root.path)
            try drive.prepare()
            store = DoryComponentStore(drive: drive)
            try store.prepare()
        }

        func write(_ data: Data, name: String) throws -> URL {
            let url = root.appendingPathComponent(name)
            try data.write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return url
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
