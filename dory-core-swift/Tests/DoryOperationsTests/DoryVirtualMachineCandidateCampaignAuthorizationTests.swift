import CryptoKit
import Foundation
import Testing
@testable import DoryOperations

@Suite("Candidate campaign authority")
struct DoryVirtualMachineCandidateCampaignAuthorizationTests {
    @Test("exact signed candidate is authorized without minting public qualification")
    func exactCandidate() throws {
        let fixture = try Fixture()
        let authority = try fixture.resolve()

        let resolved = try authority.resolve(
            request: fixture.cell.capability,
            backendImplementationIdentifier: fixture.cell.backendImplementationIdentifier,
            backendRuntimeBuildIdentifier: fixture.cell.backendRuntimeBuildIdentifier,
            hostHardwareModelIdentifier: "Mac14,10",
            hostOperatingSystemBuild: "26A5425a",
            installedComponents: fixture.cell.components,
            machineID: "campaign-pc-1",
            virtualCPUCount: 2,
            memoryBytes: 4 * 1_024 * 1_024 * 1_024,
            storageBytes: 32 * 1_024 * 1_024 * 1_024
        )

        #expect(resolved.cell.cellIdentifier == "linux-x86_64-pc")
        #expect(resolved.authorizationIdentity.hasPrefix("candidate-campaign-"))
        #expect(resolved.bootMediaInspectionEvidence?.catalogManifestEvidence == nil)
    }

    @Test("signature lifetime revocation host resource and artifact bindings fail closed")
    func negativeBindings() throws {
        let fixture = try Fixture()
        fixture.signatureURL.writeText(Data(repeating: 0, count: 64).base64EncodedString() + "\n")
        #expect(throws: DoryCandidateCampaignAuthorizationError.self) {
            try fixture.resolve()
        }

        try fixture.writeAuthority()
        #expect(throws: DoryCandidateCampaignAuthorizationError.self) {
            try fixture.resolve(minimumRevocationSequence: 2)
        }
        #expect(throws: DoryCandidateCampaignAuthorizationError.self) {
            try fixture.resolve(now: Date(timeIntervalSince1970: 2_000_000_000))
        }

        let authority = try fixture.resolve()
        #expect(throws: DoryCandidateCampaignAuthorizationError.self) {
            try authority.resolve(
                request: fixture.cell.capability,
                backendImplementationIdentifier: fixture.cell.backendImplementationIdentifier,
                backendRuntimeBuildIdentifier: fixture.cell.backendRuntimeBuildIdentifier,
                hostHardwareModelIdentifier: "Mac14,11",
                hostOperatingSystemBuild: "26A5425a",
                installedComponents: fixture.cell.components,
                machineID: "campaign-pc-1",
                virtualCPUCount: 2,
                memoryBytes: 4 * 1_024 * 1_024 * 1_024,
                storageBytes: 32 * 1_024 * 1_024 * 1_024
            )
        }
        #expect(throws: DoryCandidateCampaignAuthorizationError.self) {
            try authority.resolve(
                request: fixture.cell.capability,
                backendImplementationIdentifier: fixture.cell.backendImplementationIdentifier,
                backendRuntimeBuildIdentifier: fixture.cell.backendRuntimeBuildIdentifier,
                hostHardwareModelIdentifier: "Mac14,10",
                hostOperatingSystemBuild: "26A5425a",
                installedComponents: fixture.cell.components,
                machineID: "campaign-pc-1",
                virtualCPUCount: 9,
                memoryBytes: 4 * 1_024 * 1_024 * 1_024,
                storageBytes: 32 * 1_024 * 1_024 * 1_024
            )
        }

        fixture.applicationRoot.appending(path: "Contents/Helpers/doryd").writeText("replaced")
        #expect(throws: DoryCandidateCampaignAuthorizationError.self) {
            try fixture.resolve()
        }
        fixture.applicationRoot.appending(path: "Contents/Helpers/doryd")
            .writeText("Contents/Helpers/doryd\n")

        let helpers = fixture.applicationRoot.appending(path: "Contents/Helpers")
        let indirectHelpers = fixture.applicationRoot.appending(path: "Contents/Helpers.direct")
        try FileManager.default.moveItem(at: helpers, to: indirectHelpers)
        try FileManager.default.createSymbolicLink(
            at: helpers, withDestinationURL: indirectHelpers
        )
        #expect(throws: DoryCandidateCampaignAuthorizationError.self) {
            try fixture.resolve()
        }
    }

    @Test("unknown fields noncanonical JSON and a different state root are rejected")
    func structuralFailures() throws {
        let fixture = try Fixture()
        var object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixture.authorityURL))
                as? [String: Any]
        )
        object["forgedQualification"] = true
        let forged = try JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]
        )
        try forged.write(to: fixture.authorityURL)
        let signature = try fixture.key.signature(for: forged)
        fixture.signatureURL.writeText(signature.base64EncodedString() + "\n")
        #expect(throws: DoryCandidateCampaignAuthorizationError.self) {
            try fixture.resolve()
        }

        try fixture.writeAuthority()
        #expect(throws: DoryCandidateCampaignAuthorizationError.self) {
            try DoryVirtualMachineCandidateCampaignAuthorityResolver.resolve(
                authorityPath: fixture.authorityURL.path,
                signaturePath: fixture.signatureURL.path,
                publicKeyBase64: fixture.key.publicKey.rawRepresentation.base64EncodedString(),
                expectedStateRoot: fixture.root.appending(path: "other-state").path,
                expectedApplicationRoot: fixture.applicationRoot.path,
                now: fixture.now
            )
        }
    }

    @Test("campaign replay floor is idempotent and rejects conflicts and rollback")
    func replayFloor() throws {
        let fixture = try Fixture()
        let first = try fixture.resolve()
        try first.activateReplayFloor()
        try fixture.resolve().activateReplayFloor()

        try fixture.writeAuthority(nonce: "nonce-conflict")
        #expect(throws: DoryCandidateCampaignAuthorizationError.self) {
            try fixture.resolve()
        }

        try fixture.writeAuthority(
            campaignIdentifier: "wave0-next", nonce: "nonce-2", revocationSequence: 2
        )
        try fixture.resolve().activateReplayFloor()

        try fixture.writeAuthority(
            campaignIdentifier: "wave0-old", nonce: "nonce-3", revocationSequence: 1
        )
        #expect(throws: DoryCandidateCampaignAuthorizationError.self) {
            try fixture.resolve()
        }
    }

    private final class Fixture {
        let temporary: URL
        let root: URL
        let stateRoot: URL
        let candidateRoot: URL
        let sbomRoot: URL
        let applicationRoot: URL
        let authorityURL: URL
        let signatureURL: URL
        let key = Curve25519.Signing.PrivateKey()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cell: DoryCandidateCampaignCell

        init() throws {
            temporary = URL(fileURLWithPath: NSTemporaryDirectory())
                .appending(path: "dory-campaign-tests-\(UUID().uuidString.lowercased())")
            root = temporary
            stateRoot = root.appending(path: "state")
            candidateRoot = root.appending(path: "candidate")
            sbomRoot = root.appending(path: "sbom")
            applicationRoot = root.appending(path: "Dory.app")
            authorityURL = root.appending(path: "authority.json")
            signatureURL = root.appending(path: "authority.json.sig")
            try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: candidateRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: sbomRoot, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: applicationRoot, withIntermediateDirectories: true)
            candidateRoot.appending(path: "component-candidate-inventory.json")
                .writeText("candidate\n")
            sbomRoot.appending(path: "sbom.spdx.json").writeText("sbom\n")
            let paths = Self.artifactPaths
            for path in paths.values {
                let url = applicationRoot.appending(path: path)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                url.writeText(path + "\n")
            }
            let component = DoryVirtualMachineQualifiedComponent(
                componentIdentifier: "dory-hv",
                buildIdentifier: "sha256:" + Self.digest(
                    Data((paths["dory-hv"]! + "\n").utf8)
                ),
                artifactSHA256: Self.digest(Data((paths["dory-hv"]! + "\n").utf8))
            )
            cell = DoryCandidateCampaignCell(
                cellIdentifier: "linux-x86_64-pc",
                capability: DoryVirtualMachineCapabilityRequest(
                    guest: DoryGuestPlatform(family: .linux, architecture: .x86_64),
                    bootMedia: DoryBootMedia(
                        kind: .installerISO,
                        source: .userProvided,
                        artifactSHA256: String(repeating: "a", count: 64)
                    ),
                    backend: .doryHypervisor,
                    graphics: .hardwareAccelerated3D,
                    virtualHardwareABIVersion: 1
                ),
                backendImplementationIdentifier: "dory.rawhv",
                backendRuntimeBuildIdentifier: component.buildIdentifier,
                components: [component],
                resources: DoryCandidateCampaignResourceLimit(
                    maximumVirtualCPUCount: 8,
                    maximumMemoryBytes: 16 * 1_024 * 1_024 * 1_024,
                    maximumStorageBytes: 128 * 1_024 * 1_024 * 1_024
                )
            )
            try writeAuthority()
        }

        deinit { try? FileManager.default.removeItem(at: temporary) }

        func writeAuthority(
            campaignIdentifier: String = "wave0-local",
            nonce: String = "nonce-1",
            revocationSequence: UInt64 = 1
        ) throws {
            let artifacts = Self.artifactPaths.map { role, path in
                let data = Data((path + "\n").utf8)
                return DoryCandidateCampaignArtifact(
                    role: role, path: path, byteCount: UInt64(data.count),
                    sha256: Self.digest(data)
                )
            }
            let manifest = DoryVirtualMachineCandidateCampaignAuthorization(
                campaignIdentifier: campaignIdentifier,
                nonce: nonce,
                issuedAt: ISO8601DateFormatter().string(
                    from: now.addingTimeInterval(-60)
                ),
                expiresAt: ISO8601DateFormatter().string(
                    from: now.addingTimeInterval(3_600)
                ),
                revocationSequence: revocationSequence,
                signingKeyID: Self.digest(key.publicKey.rawRepresentation),
                stateRoot: stateRoot.path,
                candidateRoot: candidateRoot.path,
                applicationRoot: applicationRoot.path,
                candidateInventorySHA256: Self.digest(Data("candidate\n".utf8)),
                sbomRoot: sbomRoot.path,
                sbomSHA256: Self.digest(Data("sbom\n".utf8)),
                host: DoryCandidateCampaignHostConstraint(
                    qualificationHostClassID: "m2-pro-16g-macos-27.0-26a428",
                    hardwareModelIdentifier: "Mac14,10",
                    operatingSystemBuild: "26A5425a"
                ),
                machineIDPrefix: "campaign-",
                artifacts: artifacts,
                cells: [cell]
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(manifest)
            try data.write(to: authorityURL)
            let signature = try key.signature(for: data)
            signatureURL.writeText(signature.base64EncodedString() + "\n")
        }

        func resolve(
            minimumRevocationSequence: UInt64 = 1,
            now: Date? = nil
        ) throws -> DoryVerifiedVirtualMachineCandidateCampaignAuthority {
            try DoryVirtualMachineCandidateCampaignAuthorityResolver.resolve(
                authorityPath: authorityURL.path,
                signaturePath: signatureURL.path,
                publicKeyBase64: key.publicKey.rawRepresentation.base64EncodedString(),
                expectedStateRoot: stateRoot.path,
                expectedApplicationRoot: applicationRoot.path,
                minimumRevocationSequence: minimumRevocationSequence,
                now: now ?? self.now
            )
        }

        static let artifactPaths = [
            "app": "Contents/MacOS/Dory",
            "control": "Contents/Helpers/dorydctl",
            "daemon": "Contents/Helpers/doryd",
            "dory-hv": "Contents/Helpers/DoryHVRunner.app/Contents/MacOS/dory-hv",
            "dory-vmm": "Contents/Helpers/DoryVMM.app/Contents/MacOS/dory-vmm",
            "renderer-worker": "Contents/Helpers/DoryHVRunner.app/Contents/XPCServices/DoryRendererWorker.xpc/Contents/MacOS/DoryRendererWorker",
            "filesystem-worker": "Contents/Helpers/DoryHVRunner.app/Contents/XPCServices/DoryFSWorker.xpc/Contents/MacOS/DoryFSWorker",
        ]

        static func digest(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }
}

private extension URL {
    func writeText(_ value: String) {
        try! Data(value.utf8).write(to: self)
    }
}
