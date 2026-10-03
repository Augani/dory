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

        var runtimeRequest = fixture.cell.capability
        runtimeRequest.devices.networkInterface = .stable(machineID: "campaign-pc-1")

        let resolved = try authority.resolve(
            request: runtimeRequest,
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

        var changedMTU = runtimeRequest
        changedMTU.devices.networkInterface?.maximumTransmissionUnit = 1_280
        #expect(throws: DoryCandidateCampaignAuthorizationError.self) {
            _ = try authority.resolve(
                request: changedMTU,
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
        }
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

    @Test("existing signed authorities grant no fault injection")
    func noImplicitFaultAuthority() throws {
        let fixture = try Fixture(guestArchitecture: .arm64)
        let authority = try fixture.resolve()
        let cell = DoryResolvedCandidateCampaignCell(
            campaignIdentifier: authority.campaignIdentifier, manifestSHA256: authority.manifestSHA256,
            signingKeyID: authority.signingKeyID, cell: fixture.cell
        )
        #expect(throws: DoryRuntimeQualificationFaultError.unauthorized) {
            try authority.authorizeRuntimeFaults(cell: cell, machineID: "campaign-arm-1", operationID: UUID(),
                                                resolvedPlanSHA256: String(repeating: "b", count: 64), now: fixture.now)
        }
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.authorityURL)) as? [String: Any])
        let cells = try #require(object["cells"] as? [[String: Any]])
        #expect(cells[0]["faultPolicy"] == nil)
    }

    @Test("faults require an exact signed ARM cell, identity and unexpired authority")
    func signedFaultPolicy() throws {
        let policy = DoryCandidateCampaignFaultPolicy(permittedFaults: [.blockFullFlushNoSpace])
        let fixture = try Fixture(guestArchitecture: .arm64, faultPolicy: policy)
        let authority = try fixture.resolve()
        let cell = DoryResolvedCandidateCampaignCell(
            campaignIdentifier: authority.campaignIdentifier, manifestSHA256: authority.manifestSHA256,
            signingKeyID: authority.signingKeyID, cell: fixture.cell
        )
        let operationID = UUID()
        let grant = try authority.authorizeRuntimeFaults(
            cell: cell, machineID: "campaign-arm-1", operationID: operationID,
            resolvedPlanSHA256: String(repeating: "b", count: 64), now: fixture.now
        )
        #expect(grant.operationID == operationID)
        #expect(grant.machineID == "campaign-arm-1")
        #expect(grant.policy == policy)
        #expect(grant.campaignManifestSHA256 == authority.manifestSHA256)
        #expect(throws: DoryRuntimeQualificationFaultError.invalidIdentity) {
            try authority.authorizeRuntimeFaults(cell: cell, machineID: "personal-vm", operationID: operationID,
                                                resolvedPlanSHA256: String(repeating: "b", count: 64), now: fixture.now)
        }
        #expect(throws: DoryRuntimeQualificationFaultError.invalidIdentity) {
            try authority.authorizeRuntimeFaults(cell: cell, machineID: "campaign-arm-1", operationID: operationID,
                                                resolvedPlanSHA256: "bad-plan", now: fixture.now)
        }
        #expect(throws: DoryRuntimeQualificationFaultError.expired) {
            try authority.authorizeRuntimeFaults(cell: cell, machineID: "campaign-arm-1", operationID: operationID,
                                                resolvedPlanSHA256: String(repeating: "b", count: 64),
                                                now: fixture.now.addingTimeInterval(3600))
        }
        #expect(throws: DoryRuntimeQualificationFaultError.unauthorized) {
            try authority.authorizeRuntimeFaults(cell: cell, machineID: "campaign-arm-1", operationID: operationID,
                                                resolvedPlanSHA256: String(repeating: "b", count: 64),
                                                now: fixture.now.addingTimeInterval(-120))
        }
        var altered = cell.cell
        altered.faultPolicy?.maximumArmingCount = 8
        let forgedCell = DoryResolvedCandidateCampaignCell(
            campaignIdentifier: cell.campaignIdentifier, manifestSHA256: cell.manifestSHA256,
            signingKeyID: cell.signingKeyID, cell: altered
        )
        #expect(throws: DoryRuntimeQualificationFaultError.unauthorized) {
            try authority.authorizeRuntimeFaults(cell: forgedCell, machineID: "campaign-arm-1", operationID: operationID,
                                                resolvedPlanSHA256: String(repeating: "b", count: 64), now: fixture.now)
        }
    }

    @Test("renderer crash requires exact signed permission and does not grant other faults",
          arguments: [DoryGuestArchitecture.arm64, .x86_64])
    func signedRendererCrashPolicy(architecture: DoryGuestArchitecture) throws {
        let policy = DoryCandidateCampaignFaultPolicy(permittedFaults: [.rendererWorkerCrash])
        let fixture = try Fixture(guestArchitecture: architecture, faultPolicy: policy)
        let authority = try fixture.resolve()
        let cell = DoryResolvedCandidateCampaignCell(
            campaignIdentifier: authority.campaignIdentifier, manifestSHA256: authority.manifestSHA256,
            signingKeyID: authority.signingKeyID, cell: fixture.cell
        )
        let operation = UUID()
        let grant = try authority.authorizeRuntimeFaults(cell: cell, machineID: "campaign-renderer-1",
            operationID: operation, resolvedPlanSHA256: String(repeating: "b", count: 64), now: fixture.now)
        #expect(grant.policy.permittedFaults == [.rendererWorkerCrash])
        #expect(!grant.policy.permittedFaults.contains(.blockFullFlushNoSpace))
        let admission = try grant.rendererCrashAdmission(challenge: UUID(), workerGeneration: 7,
            now: fixture.now, monotonicNanoseconds: 100)
        #expect(admission.permits(workspaceID: operation, workerGeneration: 7, now: fixture.now))
        #expect(!admission.permits(workspaceID: operation, workerGeneration: 8, now: fixture.now))
        #expect(admission.claimDispatchPermission(now: fixture.now, monotonicNanoseconds: 101))
        #expect(!admission.claimDispatchPermission(now: fixture.now, monotonicNanoseconds: 102))
    }

    @Test("PC renderer permission never enables ARM storage/memory faults or software graphics")
    func pcRendererFaultScope() throws {
        for faults: [DoryRuntimeQualificationFaultKind] in [
            [.blockFullFlushNoSpace, .rendererWorkerCrash],
            [.mappedPageRepeatedPermission, .rendererWorkerCrash]
        ] {
            let fixture = try Fixture(faultPolicy: .init(permittedFaults: faults))
            #expect(throws: DoryCandidateCampaignAuthorizationError.self) { try fixture.resolve() }
        }
        for graphics in [DoryGraphicsAccelerationLevel.none, .software, .hostAcceleratedDisplay] {
            let fixture = try Fixture(graphics: graphics,
                faultPolicy: .init(permittedFaults: [.rendererWorkerCrash]))
            #expect(throws: DoryCandidateCampaignAuthorizationError.self) { try fixture.resolve() }
        }
    }

    @Test("invalid policies and PC storage faults cannot carry fault authority")
    func invalidFaultPolicies() throws {
        let policy = DoryCandidateCampaignFaultPolicy(permittedFaults: [.blockFullFlushNoSpace])
        let unsupported = try Fixture(guestArchitecture: .x86_64, faultPolicy: policy)
        #expect(throws: DoryCandidateCampaignAuthorizationError.self) { try unsupported.resolve() }
        var malformed = policy
        malformed.maximumArmingCount = 0
        let invalid = try Fixture(guestArchitecture: .arm64, faultPolicy: malformed)
        #expect(throws: DoryCandidateCampaignAuthorizationError.self) { try invalid.resolve() }
        #expect(!DoryCandidateCampaignFaultPolicy(permittedFaults: [.blockFullFlushNoSpace, .blockFullFlushNoSpace]).isValid)
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

        init(guestArchitecture: DoryGuestArchitecture = .x86_64,
             graphics: DoryGraphicsAccelerationLevel = .hardwareAccelerated3D,
             faultPolicy: DoryCandidateCampaignFaultPolicy? = nil) throws {
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
                    guest: DoryGuestPlatform(family: .linux, architecture: guestArchitecture),
                    bootMedia: DoryBootMedia(
                        kind: .installerISO,
                        source: .userProvided,
                        artifactSHA256: String(repeating: "a", count: 64)
                    ),
                    backend: .doryHypervisor,
                    graphics: graphics,
                    devices: DoryVirtualMachineDeviceCapabilityRequest(
                        networkInterface: .stable(machineID: "campaign-template"),
                        display: DoryVirtualMachineDisplayCapabilityRequest(
                            widthPixels: 1_920,
                            heightPixels: 1_080
                        ),
                        keyboard: true,
                        pointer: true
                    ),
                    virtualHardwareABIVersion: 1
                ),
                backendImplementationIdentifier: "dory.rawhv",
                backendRuntimeBuildIdentifier: component.buildIdentifier,
                components: [component],
                resources: DoryCandidateCampaignResourceLimit(
                    maximumVirtualCPUCount: 8,
                    maximumMemoryBytes: 16 * 1_024 * 1_024 * 1_024,
                    maximumStorageBytes: 128 * 1_024 * 1_024 * 1_024
                ),
                faultPolicy: faultPolicy
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
