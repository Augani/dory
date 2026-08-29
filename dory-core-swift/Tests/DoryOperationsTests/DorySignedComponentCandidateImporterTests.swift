@testable import DoryOperations
import CryptoKit
import Foundation
import Testing

@Suite("Signed component candidate importer")
struct DorySignedComponentCandidateImporterTests {
    @Test("signed local candidate installs exact dependencies and caches its authority")
    func installsSignedCandidate() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let candidate = try fixture.candidate()
        let operationID = UUID(uuidString: "01234567-89ab-4cde-8f01-23456789abcd")!
        let result = try candidate.importer.install(
            .desktopUbuntu,
            from: candidate.directory.path,
            operationID: operationID
        )

        #expect(result.operationID == operationID)
        #expect(result.installed.map(\.id) == [.linuxDesktop, .desktopUbuntu])
        #expect(result.installed.allSatisfy {
            $0.installationOperationID == operationID.uuidString.lowercased()
        })
        #expect(try fixture.store.verify(.linuxDesktop).installationName
            == result.installed[0].installationName)
        #expect(try fixture.store.verify(.desktopUbuntu).installationName
            == result.installed[1].installationName)
        #expect(try fixture.store.cachedCatalog(
            publicKey: candidate.publicKey,
            expectedArchitecture: "arm64",
            appVersion: Fixture.version
        )?.catalog == candidate.catalog)
    }

    @Test("zero operation identity is rejected before candidate bytes become active")
    func rejectsZeroOperationIdentity() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let candidate = try fixture.candidate()
        let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

        #expect(throws: DoryComponentError.invalidOperationID) {
            try candidate.importer.install(
                .desktopUbuntu,
                from: candidate.directory.path,
                operationID: zero
            )
        }
        #expect(try fixture.store.installedComponent(.linuxDesktop) == nil)
        #expect(try fixture.store.installedComponent(.desktopUbuntu) == nil)
    }

    @Test("asset mutation is rejected without activating the component")
    func rejectsMutatedAsset() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let candidate = try fixture.candidate()
        try Data("tampered".utf8).write(to: candidate.updateAsset)

        #expect(throws: DoryComponentError.self) {
            try candidate.importer.install(.desktopUbuntu, from: candidate.directory.path)
        }
        #expect(try fixture.store.installedComponent(.desktopUbuntu) == nil)
    }

    @Test("catalog mutation is rejected even when its checksum sidecar is rewritten")
    func rejectsCatalogMutation() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let candidate = try fixture.candidate()
        var bytes = try Data(contentsOf: candidate.directory.appendingPathComponent("catalog.json"))
        bytes.append(Data(" ".utf8))
        try bytes.write(to: candidate.directory.appendingPathComponent("catalog.json"))
        try Data((Fixture.digest(bytes) + "\n").utf8).write(
            to: candidate.directory.appendingPathComponent("catalog.json.sha256")
        )

        #expect(throws: DoryComponentError.self) {
            try candidate.importer.install(.desktopUbuntu, from: candidate.directory.path)
        }
        #expect(try fixture.store.installedComponent(.linuxDesktop) == nil)
    }

    @Test("candidate assets cannot be symlinks")
    func rejectsSymlinkAsset() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let candidate = try fixture.candidate()
        let replacement = fixture.root.appendingPathComponent("replacement")
        try Data("desktop update".utf8).write(to: replacement)
        try FileManager.default.removeItem(at: candidate.updateAsset)
        try FileManager.default.createSymbolicLink(
            at: candidate.updateAsset,
            withDestinationURL: replacement
        )

        #expect(throws: DoryComponentError.self) {
            try candidate.importer.install(.desktopUbuntu, from: candidate.directory.path)
        }
    }

    private final class Fixture {
        static let version = "9.8.7"

        let root: URL
        let store: DoryComponentStore

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "dory-signed-candidate-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let drive = try DoryDataDrive(home: root.appendingPathComponent("home").path)
            try drive.prepare()
            store = DoryComponentStore(drive: drive)
            try store.prepare()
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }

        struct Candidate {
            let directory: URL
            let updateAsset: URL
            let publicKey: String
            let catalog: DoryComponentCatalog
            let importer: DorySignedComponentCandidateImporter
        }

        func candidate() throws -> Candidate {
            let directory = root.appendingPathComponent("candidate", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
            let key = Curve25519.Signing.PrivateKey()
            let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
            let qualificationData = Data("qualification".utf8)
            let kernelData = Data("desktop kernel".utf8)
            let updateData = Data("desktop update".utf8)
            let qualificationName = assetName(.linuxDesktop, "virtual-machine-qualification.json")
            let kernelName = assetName(.linuxDesktop, "Image-desktop")
            let updateName = assetName(.desktopUbuntu, "dory-desktop-ubuntu-update-arm64.tar")
            let qualificationURL = try write(qualificationData, name: qualificationName, in: directory)
            _ = try write(kernelData, name: kernelName, in: directory)
            let updateURL = try write(updateData, name: updateName, in: directory)
            let provenance = DoryComponentProvenance(
                sourceCommit: String(repeating: "a", count: 40),
                builder: "dory.release.test",
                recipeDigest: String(repeating: "b", count: 64),
                sbomDigest: String(repeating: "c", count: 64),
                attestationDigest: Self.digest(qualificationData)
            )
            let host = DoryComponentHostRequirements(platform: "macos", minimumVersion: "14.0")
            let core = DoryComponentRelease(
                id: .dockerCore,
                version: Self.version,
                displayName: "Docker Core",
                summary: "Signed app",
                dependencies: [],
                downloadBytes: 1,
                installedBytes: 1,
                assets: [],
                architectures: ["arm64"],
                hostRequirements: host,
                provides: ["app.dory-core@9.8.7"],
                requires: [],
                provenance: provenance,
                qualification: []
            )
            let runtime = DoryComponentRelease(
                id: .linuxDesktop,
                version: Self.version,
                displayName: "Linux Desktop",
                summary: "Signed desktop runtime",
                dependencies: [.dockerCore],
                downloadBytes: UInt64(qualificationData.count + kernelData.count),
                installedBytes: UInt64(qualificationData.count + kernelData.count),
                assets: [
                    asset(
                        path: "virtual-machine-qualification.json",
                        name: qualificationName,
                        data: qualificationData,
                        role: .qualificationEvidence
                    ),
                    asset(
                        path: "Image-desktop",
                        name: kernelName,
                        data: kernelData,
                        role: .guestKernel
                    ),
                ],
                architectures: ["arm64"],
                hostRequirements: host,
                provides: ["device.virtio-gpu.venus@1"],
                requires: ["app.dory-core>=9.8.7"],
                provenance: provenance,
                qualification: ["qualification-1"]
            )
            let distribution = DoryComponentRelease(
                id: .desktopUbuntu,
                version: Self.version,
                displayName: "Ubuntu Desktop",
                summary: "Signed Ubuntu update",
                dependencies: [.dockerCore, .linuxDesktop],
                downloadBytes: UInt64(updateData.count),
                installedBytes: UInt64(updateData.count),
                assets: [asset(
                    path: "dory-desktop-ubuntu-update-arm64.tar",
                    name: updateName,
                    data: updateData,
                    role: .guestUpdate
                )],
                architectures: ["arm64"],
                hostRequirements: host,
                provides: ["guest.desktop.ubuntu@9.8.7"],
                requires: ["device.virtio-gpu.venus@1"],
                provenance: provenance,
                qualification: []
            )
            let catalog = DoryComponentCatalog(
                releaseVersion: Self.version,
                generatedAt: "2026-08-21T01:02:03Z",
                minimumAppVersion: Self.version,
                architecture: "arm64",
                components: [core, runtime, distribution],
                virtualMachineQualification: DoryComponentVirtualMachineQualificationAsset(
                    component: .linuxDesktop,
                    path: qualificationURL.lastPathComponent.replacingOccurrences(
                        of: "Dory-\(Self.version)-component-linux-desktop-arm64-",
                        with: ""
                    ),
                    manifestIdentity: "qualification-manifest-1",
                    manifestFormatVersion:
                        DoryVirtualMachineQualificationManifest.schemaVersion,
                    signingKeyID: Self.digest(key.publicKey.rawRepresentation)
                )
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let catalogData = try encoder.encode(catalog) + Data("\n".utf8)
            let signature = try key.signature(for: catalogData).base64EncodedString() + "\n"
            _ = try write(catalogData, name: "catalog.json", in: directory)
            _ = try write(Data((Self.digest(catalogData) + "\n").utf8), name: "catalog.json.sha256", in: directory)
            _ = try write(Data(signature.utf8), name: "catalog.json.sig", in: directory)
            return Candidate(
                directory: directory,
                updateAsset: updateURL,
                publicKey: publicKey,
                catalog: catalog,
                importer: DorySignedComponentCandidateImporter(
                    store: store,
                    publicKey: publicKey,
                    expectedArchitecture: "arm64",
                    appVersion: Self.version
                )
            )
        }

        private func asset(
            path: String,
            name: String,
            data: Data,
            role: DoryComponentArtifactRole
        ) -> DoryComponentAsset {
            DoryComponentAsset(
                path: path,
                url: "https://github.com/Augani/dory/releases/download/v\(Self.version)/\(name)",
                downloadBytes: UInt64(data.count),
                installedBytes: UInt64(data.count),
                sha256: Self.digest(data),
                installedSHA256: Self.digest(data),
                role: role
            )
        }

        private func assetName(_ id: DoryComponentID, _ path: String) -> String {
            "Dory-\(Self.version)-component-\(id.rawValue)-arm64-\(path)"
        }

        @discardableResult
        private func write(_ data: Data, name: String, in directory: URL) throws -> URL {
            let path = directory.appendingPathComponent(name)
            try data.write(to: path)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: path.path
            )
            return path
        }

        static func digest(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }
}
