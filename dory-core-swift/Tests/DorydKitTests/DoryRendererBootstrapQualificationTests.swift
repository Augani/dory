import CryptoKit
@testable import DorydKit
import DoryRendererWorkerWireContracts
import Foundation
import Testing

@Suite("Renderer bootstrap qualification")
struct DoryRendererBootstrapQualificationTests {
    @Test("signed real dual-capset evidence binds the exact worker")
    func signedDualCapsetEvidenceBindsExactWorker() throws {
        let fixture = try RendererBootstrapQualificationFixture()
        let qualification = try DoryVerifiedRendererBootstrapQualification
            .verifyForTesting(
                receiptData: fixture.receipt,
                signatureData: fixture.signature,
                publicKeyBase64: fixture.publicKey,
                now: fixture.now
            )

        #expect(qualification.productionAccelerationIsQualified)
        #expect(qualification.releaseSignatureVerified)
        #expect(qualification.capsets.map(\.id) == [2, 4])
        #expect(qualification.authorizes(
            candidateInventory: try fixture.digest("1"),
            workerExecutable: try fixture.digest("2"),
            workerCodeDirectoryHash: try DoryCodeDirectoryHash(
                lowercaseHexadecimal: String(repeating: "ab", count: 20)
            )
        ))
        #expect(!qualification.authorizes(
            candidateInventory: try fixture.digest("1"),
            workerExecutable: try fixture.digest("9"),
            workerCodeDirectoryHash: try DoryCodeDirectoryHash(
                lowercaseHexadecimal: String(repeating: "ab", count: 20)
            )
        ))

        let bootstrap = try fixture.bootstrap()
        let liveReceipt = try DoryRendererCapabilityReceipt(
            accepting: bootstrap,
            features: .productionAcceleration,
            capsets: [
                try DoryRendererCapsetAttestation(
                    id: 2,
                    maximumVersion: 2,
                    data: fixture.virgl2Capset
                ),
                try DoryRendererCapsetAttestation(
                    id: 4,
                    maximumVersion: 0,
                    data: fixture.venusCapset
                ),
            ]
        )
        #expect(qualification.authorizes(
            bootstrap: bootstrap,
            liveReceipt: liveReceipt
        ))
        let driftedReceipt = try DoryRendererCapabilityReceipt(
            accepting: bootstrap,
            features: .productionAcceleration,
            capsets: [
                try DoryRendererCapsetAttestation(
                    id: 2,
                    maximumVersion: 2,
                    data: fixture.virgl2Capset + Data([0])
                ),
                try DoryRendererCapsetAttestation(
                    id: 4,
                    maximumVersion: 0,
                    data: fixture.venusCapset
                ),
            ]
        )
        #expect(!qualification.authorizes(
            bootstrap: bootstrap,
            liveReceipt: driftedReceipt
        ))
    }

    @Test("candidate producer canonically binds exact bootstrap and real receipt")
    func candidateProducerBindsExactTranscript() throws {
        let fixture = try RendererBootstrapQualificationFixture()
        let bootstrap = try fixture.bootstrap()
        let liveReceipt = try fixture.liveReceipt(accepting: bootstrap)
        let bytes = try DoryVerifiedRendererBootstrapQualification.makeCandidateReceipt(
            bootstrap: bootstrap,
            liveReceipt: liveReceipt,
            issuedAt: fixture.now.addingTimeInterval(-60),
            expiresAt: fixture.now.addingTimeInterval(24 * 60 * 60)
        )
        let qualification = try DoryVerifiedRendererBootstrapQualification
            .decodeDeveloperIDSignedCandidate(receiptData: bytes, now: fixture.now)

        #expect(!qualification.releaseSignatureVerified)
        #expect(qualification.managedGuestKernelSHA256 == bootstrap.artifacts.managedGuestKernel)
        #expect(qualification.authorizes(bootstrap: bootstrap, liveReceipt: liveReceipt))

        let driftedBootstrap = try DoryRendererWorkerBootstrap(
            workspaceID: bootstrap.workspaceID,
            generation: bootstrap.generation,
            sourceTuple: bootstrap.sourceTuple,
            producerFenceContract: bootstrap.producerFenceContract,
            requestedCapabilities: bootstrap.requestedCapabilities,
            artifacts: DoryRendererArtifactManifest(
                candidateInventory: bootstrap.artifacts.candidateInventory,
                managedGuestKernel: try fixture.digest("8"),
                guestMesa: bootstrap.artifacts.guestMesa,
                rendererWorkerExecutable: bootstrap.artifacts.rendererWorkerExecutable,
                rendererWorkerCodeDirectoryHash:
                    bootstrap.artifacts.rendererWorkerCodeDirectoryHash
            )
        )
        #expect(!qualification.authorizes(
            bootstrap: driftedBootstrap,
            liveReceipt: try fixture.liveReceipt(accepting: driftedBootstrap)
        ))
    }

    @Test("unsigned preview requires outer seal and invalid signature never downgrades")
    func runtimeCandidateTrustTransition() throws {
        let fixture = try RendererBootstrapQualificationFixture()
        let bootstrap = try fixture.bootstrap()
        let liveReceipt = try fixture.liveReceipt(accepting: bootstrap)
        let receipt = try DoryVerifiedRendererBootstrapQualification.makeCandidateReceipt(
            bootstrap: bootstrap,
            liveReceipt: liveReceipt,
            issuedAt: fixture.now.addingTimeInterval(-60),
            expiresAt: fixture.now.addingTimeInterval(24 * 60 * 60)
        )
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathExtension("app")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let contents = temporary.appendingPathComponent("Contents", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(
            at: resources,
            withIntermediateDirectories: true
        )
        let info: [String: Any] = [
            "CFBundleIdentifier": "dev.dory.qualification-test",
            "CFBundleName": "QualificationTest",
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1",
        ]
        try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        ).write(to: contents.appendingPathComponent("Info.plist"))
        try receipt.write(
            to: resources.appendingPathComponent(
                DoryVerifiedRendererBootstrapQualification.receiptFilename
            )
        )
        let bundle = try #require(Bundle(url: temporary))

        #expect(throws: DoryRendererBootstrapQualificationError.developerIDSealInvalid) {
            _ = try DoryVerifiedRendererBootstrapQualification.loadRuntimeCandidate(
                from: bundle,
                now: fixture.now
            )
        }
        var sealChecks = 0
        let preview = try DoryVerifiedRendererBootstrapQualification
            .loadRuntimeCandidateForTesting(
                from: bundle,
                now: fixture.now
            ) { _ in
                sealChecks += 1
            }
        #expect(sealChecks == 1)
        #expect(!preview.releaseSignatureVerified)

        try Data("not-a-signature\n".utf8).write(
            to: resources.appendingPathComponent(
                DoryVerifiedRendererBootstrapQualification.signatureFilename
            )
        )
        sealChecks = 0
        #expect(throws: DoryRendererBootstrapQualificationError.nonCanonicalSignature) {
            _ = try DoryVerifiedRendererBootstrapQualification
                .loadRuntimeCandidateForTesting(
                    from: bundle,
                    now: fixture.now
                ) { _ in
                    sealChecks += 1
                }
        }
        #expect(sealChecks == 0)
    }

    @Test("single-capset and fabricated feature evidence fail even when signed")
    func incompleteCapabilitiesFailClosed() throws {
        let fixture = try RendererBootstrapQualificationFixture()
        var singleCapset = fixture.object
        singleCapset["capsets"] = [fixture.capsets[1]]
        let singleBytes = try fixture.canonical(singleCapset)
        #expect(throws: DoryRendererBootstrapQualificationError.capabilityMismatch) {
            _ = try DoryVerifiedRendererBootstrapQualification.verifyForTesting(
                receiptData: singleBytes,
                signatureData: fixture.sign(singleBytes),
                publicKeyBase64: fixture.publicKey,
                now: fixture.now
            )
        }

        var fabricatedFeatures = fixture.object
        fabricatedFeatures["featureBits"] = Int(
            DoryRendererWorkerFeatures.venus.rawValue
        )
        let fabricatedBytes = try fixture.canonical(fabricatedFeatures)
        #expect(throws: DoryRendererBootstrapQualificationError.capabilityMismatch) {
            _ = try DoryVerifiedRendererBootstrapQualification.verifyForTesting(
                receiptData: fabricatedBytes,
                signatureData: fixture.sign(fabricatedBytes),
                publicKeyBase64: fixture.publicKey,
                now: fixture.now
            )
        }
    }

    @Test("tamper expiry and stale revocation evidence fail closed")
    func trustAndFreshnessFailClosed() throws {
        let fixture = try RendererBootstrapQualificationFixture()
        var tampered = fixture.receipt
        tampered[tampered.index(tampered.startIndex, offsetBy: 20)] ^= 1
        #expect(throws: DoryRendererBootstrapQualificationError.signatureInvalid) {
            _ = try DoryVerifiedRendererBootstrapQualification.verifyForTesting(
                receiptData: tampered,
                signatureData: fixture.signature,
                publicKeyBase64: fixture.publicKey,
                now: fixture.now
            )
        }

        var expired = fixture.object
        expired["expiresAt"] = "2026-08-25T12:00:00Z"
        let expiredBytes = try fixture.canonical(expired)
        #expect(throws: DoryRendererBootstrapQualificationError.validityInvalid) {
            _ = try DoryVerifiedRendererBootstrapQualification.verifyForTesting(
                receiptData: expiredBytes,
                signatureData: fixture.sign(expiredBytes),
                publicKeyBase64: fixture.publicKey,
                now: fixture.now
            )
        }

        #expect(throws: DoryRendererBootstrapQualificationError.revoked) {
            _ = try DoryVerifiedRendererBootstrapQualification.verifyForTesting(
                receiptData: fixture.receipt,
                signatureData: fixture.signature,
                publicKeyBase64: fixture.publicKey,
                now: fixture.now,
                minimumRevocationSequence: 2
            )
        }
    }
}

private struct RendererBootstrapQualificationFixture {
    let privateKey = Curve25519.Signing.PrivateKey()
    let now: Date
    let virgl2Capset = Data("real-virgl2-capset".utf8)
    let venusCapset = Data("real-venus-capset".utf8)
    let object: [String: Any]
    let capsets: [[String: Any]]
    let receipt: Data
    let signature: Data

    var publicKey: String {
        privateKey.publicKey.rawRepresentation.base64EncodedString()
    }

    init() throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        now = try #require(formatter.date(from: "2026-08-26T12:00:00Z"))
        let transcript = String(repeating: "6", count: 64)
        let virgl2SHA256 = SHA256.hash(data: virgl2Capset).map {
            String(format: "%02x", $0)
        }.joined()
        let venusSHA256 = SHA256.hash(data: venusCapset).map {
            String(format: "%02x", $0)
        }.joined()
        capsets = [
            [
                "byteCount": virgl2Capset.count,
                "id": 2,
                "maximumVersion": 2,
                "sha256": virgl2SHA256,
            ],
            [
                "byteCount": venusCapset.count,
                "id": 4,
                "maximumVersion": 0,
                "sha256": venusSHA256,
            ],
        ]
        let keyID = SHA256.hash(data: privateKey.publicKey.rawRepresentation).map {
            String(format: "%02x", $0)
        }.joined()
        object = [
            "bootstrapProtocolVersion": 3,
            "bootstrapTranscriptSHA256": transcript,
            "capabilityReceiptProtocolVersion": 4,
            "capabilityReceiptSHA256": String(repeating: "5", count: 64),
            "candidateInventorySHA256": String(repeating: "1", count: 64),
            "capsets": capsets,
            "expiresAt": "2026-09-26T12:00:00Z",
            "featureBits": Int(
                DoryRendererWorkerFeatures.productionAcceleration.rawValue
            ),
            "guestMesaSHA256": DoryRendererSourceTuple.guestMesaRuntimeSHA256,
            "issuedAt": "2026-08-25T12:00:00Z",
            "kind": DoryVerifiedRendererBootstrapQualification.kind,
            "managedGuestKernelSHA256": String(repeating: "7", count: 64),
            "producerFenceContract": Int(
                DoryRendererProducerFenceContract
                    .managedLinux612106PrepareFBV1.rawValue
            ),
            "qualificationIdentity": "dory-renderer-bootstrap:\(transcript)",
            "revocationKeyID": keyID,
            "revocationSequence": 1,
            "schemaVersion": 1,
            "signingKeyID": keyID,
            "sourceTuple": Int(DoryRendererSourceTuple.productionCandidate.rawValue),
            "tupleDefinitionSHA256":
                DoryRendererSourceTuple.productionDefinitionSHA256,
            "workerCodeDirectoryHash": String(repeating: "ab", count: 20),
            "workerExecutableSHA256": String(repeating: "2", count: 64),
        ]
        receipt = try Self.canonical(object)
        signature = try Self.signature(receipt, key: privateKey)
    }

    func digest(_ nibble: Character) throws -> DoryRendererArtifactDigest {
        try DoryRendererArtifactDigest(
            lowercaseSHA256: String(repeating: nibble, count: 64)
        )
    }

    func bootstrap() throws -> DoryRendererWorkerBootstrap {
        try DoryRendererWorkerBootstrap(
            workspaceID: DoryRendererWorkspaceID(
                rawValue: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
            ),
            generation: DoryRendererWorkerGeneration(rawValue: 7),
            sourceTuple: .productionCandidate,
            producerFenceContract: .managedLinux612106PrepareFBV1,
            requestedCapabilities: .productionAcceleration,
            artifacts: DoryRendererArtifactManifest(
                candidateInventory: try digest("1"),
                managedGuestKernel: try digest("7"),
                guestMesa: try DoryRendererArtifactDigest(
                    lowercaseSHA256: DoryRendererSourceTuple.guestMesaRuntimeSHA256
                ),
                rendererWorkerExecutable: try digest("2"),
                rendererWorkerCodeDirectoryHash: try DoryCodeDirectoryHash(
                    lowercaseHexadecimal: String(repeating: "ab", count: 20)
                )
            )
        )
    }

    func liveReceipt(
        accepting bootstrap: DoryRendererWorkerBootstrap
    ) throws -> DoryRendererCapabilityReceipt {
        try DoryRendererCapabilityReceipt(
            accepting: bootstrap,
            features: .productionAcceleration,
            capsets: [
                try DoryRendererCapsetAttestation(
                    id: 2,
                    maximumVersion: 2,
                    data: virgl2Capset
                ),
                try DoryRendererCapsetAttestation(
                    id: 4,
                    maximumVersion: 0,
                    data: venusCapset
                ),
            ]
        )
    }

    func canonical(_ value: [String: Any]) throws -> Data {
        try Self.canonical(value)
    }

    func sign(_ value: Data) -> Data {
        try! Self.signature(value, key: privateKey)
    }

    private static func canonical(_ value: [String: Any]) throws -> Data {
        try DoryRendererProductionInventory.canonicalJSONData(value)
            + Data("\n".utf8)
    }

    private static func signature(
        _ value: Data,
        key: Curve25519.Signing.PrivateKey
    ) throws -> Data {
        Data(try key.signature(for: value).base64EncodedString().utf8)
            + Data("\n".utf8)
    }
}
