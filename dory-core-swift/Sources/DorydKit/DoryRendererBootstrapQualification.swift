import CryptoKit
import Darwin
import DoryOperations
import DoryRendererWorkerWireContracts
import Foundation
import Security

public enum DoryRendererBootstrapQualificationError: Error, Equatable, Sendable {
    case resourceUnavailable
    case resourceInvalid
    case nonCanonicalSignature
    case signatureInvalid
    case nonCanonicalJSON
    case schemaInvalid
    case productionKeyMismatch
    case tupleMismatch
    case workerIdentityMismatch
    case developerIDSealInvalid
    case capabilityMismatch
    case validityInvalid
    case revoked
}

/// A compact attestation copied from the real capability receipt returned by the packaged worker.
/// The complete capset bytes stay in the bootstrap transcript; their exact sizes and SHA-256
/// values are sufficient for the runtime runner to compare a fresh live bootstrap without making
/// this release authority unbounded.
public struct DoryRendererQualifiedCapset: Equatable, Sendable {
    public let id: UInt32
    public let maximumVersion: UInt32
    public let byteCount: UInt32
    public let sha256: DoryRendererArtifactDigest
}

/// Candidate-bound evidence minted only after the already-signed nested XPC service returns a real
/// production capability receipt. The enclosing runner's code signature seals the receipt as a
/// resource. A detached Ed25519 signature additionally upgrades the evidence from Developer-ID
/// preview authority to public release/support authority.
public struct DoryVerifiedRendererBootstrapQualification: Equatable, Sendable {
    public static let kind = "dev.dory.renderer-bootstrap-qualification"
    public static let schemaVersion = 1
    public static let bootstrapProtocolVersion = 3
    public static let capabilityReceiptProtocolVersion = 4
    public static let maximumEncodedBytes = 64 * 1_024
    public static let maximumValidity: TimeInterval = 548 * 24 * 60 * 60
    public static let maximumClockSkew: TimeInterval = 5 * 60
    public static let minimumRevocationSequence: UInt64 = 1
    public static let receiptFilename = "renderer-bootstrap-qualification.json"
    public static let signatureFilename =
        "renderer-bootstrap-qualification.json.sig"

    /// Emergency revocation remains available even while the production signing key is valid.
    /// Values are transcript digests, which uniquely bind the request and worker reply.
    private static let revokedBootstrapTranscriptSHA256s: Set<String> = []

    public let receiptSHA256: DoryRendererArtifactDigest
    public let qualificationIdentity: String
    public let sourceTuple: DoryRendererSourceTuple
    public let tupleDefinitionSHA256: DoryRendererArtifactDigest
    public let candidateInventorySHA256: DoryRendererArtifactDigest
    public let managedGuestKernelSHA256: DoryRendererArtifactDigest
    public let workerExecutableSHA256: DoryRendererArtifactDigest
    public let workerCodeDirectoryHash: DoryCodeDirectoryHash
    public let guestMesaSHA256: DoryRendererArtifactDigest
    public let bootstrapTranscriptSHA256: DoryRendererArtifactDigest
    public let capabilityReceiptSHA256: DoryRendererArtifactDigest
    public let featureBits: UInt64
    public let capsets: [DoryRendererQualifiedCapset]
    public let issuedAt: Date
    public let expiresAt: Date
    public let signingKeyID: DoryRendererArtifactDigest
    public let revocationKeyID: DoryRendererArtifactDigest
    public let revocationSequence: UInt64
    public let releaseSignatureVerified: Bool

    public var productionAccelerationIsQualified: Bool {
        sourceTuple == .productionCandidate
            && tupleDefinitionSHA256.lowercaseSHA256
                == DoryRendererSourceTuple.productionDefinitionSHA256
            && guestMesaSHA256.lowercaseSHA256
                == DoryRendererSourceTuple.guestMesaRuntimeSHA256
            && featureBits == DoryRendererWorkerFeatures.productionAcceleration.rawValue
            && capsets.map(\.id) == [2, 4]
    }

    public func authorizes(
        candidateInventory: DoryRendererArtifactDigest,
        workerExecutable: DoryRendererArtifactDigest,
        workerCodeDirectoryHash: DoryCodeDirectoryHash
    ) -> Bool {
        productionAccelerationIsQualified
            && candidateInventorySHA256 == candidateInventory
            && workerExecutableSHA256 == workerExecutable
            && self.workerCodeDirectoryHash == workerCodeDirectoryHash
    }

    /// Compares the stable facts from a fresh, generation-bound worker bootstrap. The receipt
    /// codec has already bound workspace, generation, producer-fence contract, inventory, and
    /// executable to `bootstrap`; this comparison additionally proves that the capset bytes and
    /// complete feature set equal the packaged qualification. Public release status separately
    /// requires `releaseSignatureVerified`.
    public func authorizes(
        bootstrap: DoryRendererWorkerBootstrap,
        liveReceipt: DoryRendererCapabilityReceipt
    ) -> Bool {
        guard authorizes(
            candidateInventory: bootstrap.artifacts.candidateInventory,
            workerExecutable: bootstrap.artifacts.rendererWorkerExecutable,
            workerCodeDirectoryHash:
                bootstrap.artifacts.rendererWorkerCodeDirectoryHash
        ),
        guestMesaSHA256 == bootstrap.artifacts.guestMesa,
        managedGuestKernelSHA256 == bootstrap.artifacts.managedGuestKernel,
        liveReceipt.workspaceID == bootstrap.workspaceID,
        liveReceipt.generation == bootstrap.generation,
        liveReceipt.sourceTuple == sourceTuple,
        liveReceipt.producerFenceContract == bootstrap.producerFenceContract,
        liveReceipt.candidateInventory == candidateInventorySHA256,
        liveReceipt.rendererWorkerExecutable == workerExecutableSHA256,
        liveReceipt.features.rawValue == featureBits,
        liveReceipt.capsets.count == capsets.count else {
            return false
        }
        return zip(liveReceipt.capsets, capsets).allSatisfy { live, qualified in
            live.id == qualified.id
                && live.maximumVersion == qualified.maximumVersion
                && live.byteCount == Int(qualified.byteCount)
                && live.digest == qualified.sha256
        }
    }

    /// Creates canonical candidate evidence from the exact request sent to, and canonical reply
    /// returned by, an already-signed worker. This method does not sign the result: preview trust
    /// comes only from the enclosing expected-team Developer ID resource seal, while public
    /// release trust comes from a detached signature made outside the runner process.
    public static func makeCandidateReceipt(
        bootstrap: DoryRendererWorkerBootstrap,
        liveReceipt: DoryRendererCapabilityReceipt,
        issuedAt: Date,
        expiresAt: Date,
        revocationSequence: UInt64 = minimumRevocationSequence
    ) throws -> Data {
        guard liveReceipt.productionAccelerationIsAdmissible,
              liveReceipt.workspaceID == bootstrap.workspaceID,
              liveReceipt.generation == bootstrap.generation,
              liveReceipt.sourceTuple == bootstrap.sourceTuple,
              liveReceipt.producerFenceContract == bootstrap.producerFenceContract,
              liveReceipt.candidateInventory == bootstrap.artifacts.candidateInventory,
              liveReceipt.rendererWorkerExecutable
                == bootstrap.artifacts.rendererWorkerExecutable,
              bootstrap.sourceTuple == .productionCandidate,
              bootstrap.artifacts.guestMesa.lowercaseSHA256
                == DoryRendererSourceTuple.guestMesaRuntimeSHA256,
              expiresAt > issuedAt,
              expiresAt.timeIntervalSince(issuedAt) <= maximumValidity,
              revocationSequence >= minimumRevocationSequence,
              revocationSequence <= UInt64(Int64.max) else {
            throw DoryRendererBootstrapQualificationError.capabilityMismatch
        }
        guard let rawPublicKey = Data(base64Encoded: DoryComponentDefaults.publicKey),
              rawPublicKey.count == 32 else {
            throw DoryRendererBootstrapQualificationError.productionKeyMismatch
        }

        let bootstrapBytes = DoryRendererWorkerBootstrapCodec.encode(bootstrap)
        let capabilityReceiptBytes = DoryRendererCapabilityReceiptCodec.encode(liveReceipt)
        let transcript = transcriptSHA256(
            bootstrapBytes: bootstrapBytes,
            capabilityReceiptBytes: capabilityReceiptBytes
        )
        let keyID = lowercaseHexadecimal(Data(SHA256.hash(data: rawPublicKey)))
        let transcriptHex = lowercaseHexadecimal(transcript)
        let root: [String: Any] = [
            "bootstrapProtocolVersion": bootstrapProtocolVersion,
            "bootstrapTranscriptSHA256": transcriptHex,
            "capabilityReceiptProtocolVersion": capabilityReceiptProtocolVersion,
            "capabilityReceiptSHA256": lowercaseHexadecimal(
                Data(SHA256.hash(data: capabilityReceiptBytes))
            ),
            "candidateInventorySHA256": bootstrap.artifacts.candidateInventory.lowercaseSHA256,
            "capsets": liveReceipt.capsets.map { capset in
                [
                    "byteCount": capset.byteCount,
                    "id": Int(capset.id),
                    "maximumVersion": Int(capset.maximumVersion),
                    "sha256": capset.digest.lowercaseSHA256,
                ] as [String: Any]
            },
            "expiresAt": canonicalTimestamp(expiresAt),
            "featureBits": NSNumber(value: liveReceipt.features.rawValue),
            "guestMesaSHA256": bootstrap.artifacts.guestMesa.lowercaseSHA256,
            "issuedAt": canonicalTimestamp(issuedAt),
            "kind": kind,
            "managedGuestKernelSHA256":
                bootstrap.artifacts.managedGuestKernel.lowercaseSHA256,
            "producerFenceContract": Int(bootstrap.producerFenceContract.rawValue),
            "qualificationIdentity": "dory-renderer-bootstrap:\(transcriptHex)",
            "revocationKeyID": keyID,
            "revocationSequence": NSNumber(value: revocationSequence),
            "schemaVersion": schemaVersion,
            "signingKeyID": keyID,
            "sourceTuple": Int(bootstrap.sourceTuple.rawValue),
            "tupleDefinitionSHA256": DoryRendererSourceTuple.productionDefinitionSHA256,
            "workerCodeDirectoryHash": bootstrap.artifacts
                .rendererWorkerCodeDirectoryHash.lowercaseHexadecimal,
            "workerExecutableSHA256":
                bootstrap.artifacts.rendererWorkerExecutable.lowercaseSHA256,
        ]
        let receiptData = try DoryRendererProductionInventory.canonicalJSONData(root)
            + Data("\n".utf8)
        guard receiptData.count <= maximumEncodedBytes else {
            throw DoryRendererBootstrapQualificationError.schemaInvalid
        }
        // Decode through the same strict preview path used at runtime so the producer cannot emit
        // a byte shape that the packaged consumer interprets differently.
        _ = try decodeDeveloperIDSignedCandidate(
            receiptData: receiptData,
            now: issuedAt
        )
        return receiptData
    }

    public static func verifyProduction(
        receiptData: Data,
        signatureData: Data,
        now: Date = Date()
    ) throws -> Self {
        try verify(
            receiptData: receiptData,
            signatureData: signatureData,
            publicKeyBase64: DoryComponentDefaults.publicKey,
            now: now,
            minimumRevocationSequence: minimumRevocationSequence
        )
    }

    /// Decodes capability evidence whose byte integrity is supplied by the enclosing expected
    /// Developer ID runner signature. This is sufficient for local/preview runtime activation
    /// only; `releaseSignatureVerified` remains false and release gates must reject it.
    static func decodeDeveloperIDSignedCandidate(
        receiptData: Data,
        now: Date = Date()
    ) throws -> Self {
        guard let rawPublicKey = Data(
            base64Encoded: DoryComponentDefaults.publicKey
        ), rawPublicKey.count == 32 else {
            throw DoryRendererBootstrapQualificationError.productionKeyMismatch
        }
        return try decode(
            receiptData: receiptData,
            rawPublicKey: rawPublicKey,
            now: now,
            minimumRevocationSequence: minimumRevocationSequence,
            releaseSignatureVerified: false
        )
    }

    /// Loads the fixed candidate receipt and detached public-release signature sealed into the
    /// running bundle. Both objects are opened without following links and read from stable
    /// descriptors before the detached signature is evaluated.
    public static func loadProduction(
        from bundle: Bundle = .main,
        now: Date = Date()
    ) throws -> Self {
        guard let resources = bundle.resourceURL else {
            throw DoryRendererBootstrapQualificationError.resourceUnavailable
        }
        let receipt = try stableResource(
            resources.appendingPathComponent(receiptFilename),
            maximumBytes: maximumEncodedBytes
        )
        let signature = try stableResource(
            resources.appendingPathComponent(signatureFilename),
            maximumBytes: 128
        )
        return try verifyProduction(
            receiptData: receipt,
            signatureData: signature,
            now: now
        )
    }

#if DEBUG
    /// Debug-only fixture decoder for packages that cannot use `@testable import DorydKit`.
    /// Shipping Release builds do not export an unsigned-candidate decoder.
    public static func decodeDeveloperIDSignedCandidateForTesting(
        receiptData: Data,
        now: Date = Date()
    ) throws -> Self {
        try decodeDeveloperIDSignedCandidate(receiptData: receiptData, now: now)
    }
#endif

    /// Preferred runtime acquisition: validate the detached production signature when it exists,
    /// otherwise retain the explicitly weaker Developer-ID-sealed preview authority. A present
    /// but malformed or invalid signature is never treated as absence and cannot downgrade.
    public static func loadRuntimeCandidate(
        from bundle: Bundle = .main,
        now: Date = Date()
    ) throws -> Self {
        try loadRuntimeCandidate(
            from: bundle,
            now: now,
            expectedDeveloperIDSeal: requireExpectedDeveloperIDRunnerSeal
        )
    }

    /// Internal seam for proving the preview trust transition without making a bypass callable by
    /// another package. Shipping callers always enter the public overload above.
    static func loadRuntimeCandidateForTesting(
        from bundle: Bundle,
        now: Date,
        expectedDeveloperIDSeal: (Bundle) throws -> Void
    ) throws -> Self {
        try loadRuntimeCandidate(
            from: bundle,
            now: now,
            expectedDeveloperIDSeal: expectedDeveloperIDSeal
        )
    }

    private static func loadRuntimeCandidate(
        from bundle: Bundle,
        now: Date,
        expectedDeveloperIDSeal: (Bundle) throws -> Void
    ) throws -> Self {
        guard let resources = bundle.resourceURL else {
            throw DoryRendererBootstrapQualificationError.resourceUnavailable
        }
        let receipt = try stableResource(
            resources.appendingPathComponent(receiptFilename),
            maximumBytes: maximumEncodedBytes
        )
        let signatureURL = resources.appendingPathComponent(signatureFilename)
        var signatureInfo = stat()
        if lstat(signatureURL.path, &signatureInfo) == 0 {
            return try verifyProduction(
                receiptData: receipt,
                signatureData: stableResource(signatureURL, maximumBytes: 128),
                now: now
            )
        }
        guard errno == ENOENT else {
            throw DoryRendererBootstrapQualificationError.resourceInvalid
        }
        try expectedDeveloperIDSeal(bundle)
        return try decodeDeveloperIDSignedCandidate(
            receiptData: receipt,
            now: now
        )
    }

    /// Test-only injection seam. Shipping loaders always pin the compiled production key and
    /// revocation floor; no production caller can select a local trust root.
    static func verifyForTesting(
        receiptData: Data,
        signatureData: Data,
        publicKeyBase64: String,
        now: Date,
        minimumRevocationSequence: UInt64 = minimumRevocationSequence
    ) throws -> Self {
        try verify(
            receiptData: receiptData,
            signatureData: signatureData,
            publicKeyBase64: publicKeyBase64,
            now: now,
            minimumRevocationSequence: minimumRevocationSequence
        )
    }

    private static func verify(
        receiptData: Data,
        signatureData: Data,
        publicKeyBase64: String,
        now: Date,
        minimumRevocationSequence: UInt64
    ) throws -> Self {
        guard !receiptData.isEmpty,
              receiptData.count <= maximumEncodedBytes,
              let rawPublicKey = Data(base64Encoded: publicKeyBase64),
              rawPublicKey.count == 32,
              let publicKey = try? Curve25519.Signing.PublicKey(
                rawRepresentation: rawPublicKey
              ) else {
            throw DoryRendererBootstrapQualificationError.signatureInvalid
        }
        let signature = try canonicalSignature(signatureData)
        guard publicKey.isValidSignature(signature, for: receiptData) else {
            throw DoryRendererBootstrapQualificationError.signatureInvalid
        }
        return try decode(
            receiptData: receiptData,
            rawPublicKey: rawPublicKey,
            now: now,
            minimumRevocationSequence: minimumRevocationSequence,
            releaseSignatureVerified: true
        )
    }

    private static func decode(
        receiptData: Data,
        rawPublicKey: Data,
        now: Date,
        minimumRevocationSequence: UInt64,
        releaseSignatureVerified: Bool
    ) throws -> Self {
        guard !receiptData.isEmpty,
              receiptData.count <= maximumEncodedBytes,
              rawPublicKey.count == 32,
              let object = try? JSONSerialization.jsonObject(with: receiptData),
              let root = object as? [String: Any],
              let canonical = try? DoryRendererProductionInventory.canonicalJSONData(root),
              receiptData == canonical + Data("\n".utf8) else {
            throw DoryRendererBootstrapQualificationError.nonCanonicalJSON
        }

        let keys: Set<String> = [
            "bootstrapProtocolVersion", "bootstrapTranscriptSHA256", "capabilityReceiptProtocolVersion",
            "capabilityReceiptSHA256", "candidateInventorySHA256", "capsets", "expiresAt",
            "featureBits", "guestMesaSHA256", "issuedAt", "kind", "producerFenceContract",
            "managedGuestKernelSHA256", "qualificationIdentity", "revocationKeyID",
            "revocationSequence", "schemaVersion", "signingKeyID", "sourceTuple",
            "tupleDefinitionSHA256", "workerCodeDirectoryHash", "workerExecutableSHA256",
        ]
        guard Set(root.keys) == keys,
              root["kind"] as? String == kind,
              exactUnsigned(root["schemaVersion"]) == UInt64(schemaVersion),
              exactUnsigned(root["bootstrapProtocolVersion"])
                == UInt64(bootstrapProtocolVersion),
              exactUnsigned(root["capabilityReceiptProtocolVersion"])
                == UInt64(capabilityReceiptProtocolVersion),
              exactUnsigned(root["producerFenceContract"])
                == UInt64(DoryRendererProducerFenceContract
                    .managedLinux61230PrepareFBV1.rawValue),
              let rawSourceTuple = exactUnsigned(root["sourceTuple"]),
              let sourceTupleValue = UInt16(exactly: rawSourceTuple),
              let sourceTuple = DoryRendererSourceTuple(rawValue: sourceTupleValue),
              let qualificationIdentity = root["qualificationIdentity"] as? String,
              let tupleDefinitionHex = root["tupleDefinitionSHA256"] as? String,
              let candidateInventoryHex = root["candidateInventorySHA256"] as? String,
              let workerExecutableHex = root["workerExecutableSHA256"] as? String,
              let workerCDHashHex = root["workerCodeDirectoryHash"] as? String,
              let managedGuestKernelHex = root["managedGuestKernelSHA256"] as? String,
              let guestMesaHex = root["guestMesaSHA256"] as? String,
              let transcriptHex = root["bootstrapTranscriptSHA256"] as? String,
              let capabilityReceiptHex = root["capabilityReceiptSHA256"] as? String,
              let featureBits = exactUnsigned(root["featureBits"]),
              let issuedAtString = root["issuedAt"] as? String,
              let expiresAtString = root["expiresAt"] as? String,
              let signingKeyHex = root["signingKeyID"] as? String,
              let revocationKeyHex = root["revocationKeyID"] as? String,
              let revocationSequence = exactUnsigned(root["revocationSequence"]),
              let rawCapsets = root["capsets"] as? [[String: Any]] else {
            throw DoryRendererBootstrapQualificationError.schemaInvalid
        }

        let tupleDefinition = try digest(tupleDefinitionHex, field: "tupleDefinitionSHA256")
        let candidateInventory = try digest(candidateInventoryHex, field: "candidateInventorySHA256")
        let workerExecutable = try digest(workerExecutableHex, field: "workerExecutableSHA256")
        let managedGuestKernel = try digest(
            managedGuestKernelHex,
            field: "managedGuestKernelSHA256"
        )
        let workerCDHash: DoryCodeDirectoryHash
        do {
            workerCDHash = try DoryCodeDirectoryHash(
                lowercaseHexadecimal: workerCDHashHex,
                field: "workerCodeDirectoryHash"
            )
        } catch {
            throw DoryRendererBootstrapQualificationError.schemaInvalid
        }
        let guestMesa = try digest(guestMesaHex, field: "guestMesaSHA256")
        let transcript = try digest(transcriptHex, field: "bootstrapTranscriptSHA256")
        let capabilityReceipt = try digest(
            capabilityReceiptHex,
            field: "capabilityReceiptSHA256"
        )
        let signingKey = try digest(signingKeyHex, field: "signingKeyID")
        let revocationKey = try digest(revocationKeyHex, field: "revocationKeyID")
        let expectedKeyID = try DoryRendererArtifactDigest(
            bytes: Data(SHA256.hash(data: rawPublicKey)),
            field: "productionSigningKeyID"
        )
        guard signingKey == expectedKeyID, revocationKey == expectedKeyID else {
            throw DoryRendererBootstrapQualificationError.productionKeyMismatch
        }
        guard sourceTuple == .productionCandidate,
              tupleDefinition.lowercaseSHA256
                == DoryRendererSourceTuple.productionDefinitionSHA256,
              guestMesa.lowercaseSHA256
                == DoryRendererSourceTuple.guestMesaRuntimeSHA256 else {
            throw DoryRendererBootstrapQualificationError.tupleMismatch
        }
        guard qualificationIdentity == "dory-renderer-bootstrap:\(transcriptHex)" else {
            throw DoryRendererBootstrapQualificationError.schemaInvalid
        }

        let capsets = try decodeCapsets(rawCapsets)
        guard featureBits == DoryRendererWorkerFeatures.productionAcceleration.rawValue,
              capsets.map(\.id) == [2, 4] else {
            throw DoryRendererBootstrapQualificationError.capabilityMismatch
        }
        let issuedAt = try timestamp(issuedAtString)
        let expiresAt = try timestamp(expiresAtString)
        guard issuedAt <= now.addingTimeInterval(maximumClockSkew),
              expiresAt > now,
              expiresAt > issuedAt,
              expiresAt.timeIntervalSince(issuedAt) <= maximumValidity else {
            throw DoryRendererBootstrapQualificationError.validityInvalid
        }
        guard revocationSequence >= minimumRevocationSequence,
              !revokedBootstrapTranscriptSHA256s.contains(transcriptHex) else {
            throw DoryRendererBootstrapQualificationError.revoked
        }

        return Self(
            receiptSHA256: try DoryRendererArtifactDigest(
                bytes: Data(SHA256.hash(data: receiptData)),
                field: "rendererBootstrapQualification"
            ),
            qualificationIdentity: qualificationIdentity,
            sourceTuple: sourceTuple,
            tupleDefinitionSHA256: tupleDefinition,
            candidateInventorySHA256: candidateInventory,
            managedGuestKernelSHA256: managedGuestKernel,
            workerExecutableSHA256: workerExecutable,
            workerCodeDirectoryHash: workerCDHash,
            guestMesaSHA256: guestMesa,
            bootstrapTranscriptSHA256: transcript,
            capabilityReceiptSHA256: capabilityReceipt,
            featureBits: featureBits,
            capsets: capsets,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            signingKeyID: signingKey,
            revocationKeyID: revocationKey,
            revocationSequence: revocationSequence,
            releaseSignatureVerified: releaseSignatureVerified
        )
    }

    private static func decodeCapsets(
        _ rawCapsets: [[String: Any]]
    ) throws -> [DoryRendererQualifiedCapset] {
        guard rawCapsets.count == 2 else {
            throw DoryRendererBootstrapQualificationError.capabilityMismatch
        }
        var capsets = [DoryRendererQualifiedCapset]()
        capsets.reserveCapacity(2)
        for raw in rawCapsets {
            guard Set(raw.keys) == Set(["byteCount", "id", "maximumVersion", "sha256"]),
                  let idValue = exactUnsigned(raw["id"]),
                  let id = UInt32(exactly: idValue),
                  let maximumVersionValue = exactUnsigned(raw["maximumVersion"]),
                  let maximumVersion = UInt32(exactly: maximumVersionValue),
                  let byteCountValue = exactUnsigned(raw["byteCount"]),
                  let byteCount = UInt32(exactly: byteCountValue),
                  byteCount > 0,
                  byteCount <= UInt32(DoryRendererCapsetAttestation.maximumCapsetBytes),
                  let sha256 = raw["sha256"] as? String,
                  (id == 2 && maximumVersion > 0) || (id == 4 && maximumVersion == 0) else {
                throw DoryRendererBootstrapQualificationError.capabilityMismatch
            }
            capsets.append(DoryRendererQualifiedCapset(
                id: id,
                maximumVersion: maximumVersion,
                byteCount: byteCount,
                sha256: try digest(sha256, field: "capset-\(id)")
            ))
        }
        guard capsets.map(\.id) == [2, 4] else {
            // Ordering is part of both receipt codecs. Sorting here would allow a non-canonical
            // transcript summary to differ from the real worker wire result.
            throw DoryRendererBootstrapQualificationError.capabilityMismatch
        }
        return capsets
    }

    private static func digest(
        _ value: String,
        field: String
    ) throws -> DoryRendererArtifactDigest {
        do {
            return try DoryRendererArtifactDigest(
                lowercaseSHA256: value,
                field: field
            )
        } catch {
            throw DoryRendererBootstrapQualificationError.schemaInvalid
        }
    }

    private static func canonicalSignature(_ data: Data) throws -> Data {
        guard data.count <= 128,
              let line = String(data: data, encoding: .ascii),
              line.hasSuffix("\n"),
              !line.dropLast().contains(where: { $0.isWhitespace }),
              let signature = Data(base64Encoded: String(line.dropLast())),
              signature.count == 64,
              signature.base64EncodedString() == String(line.dropLast()) else {
            throw DoryRendererBootstrapQualificationError.nonCanonicalSignature
        }
        return signature
    }

    private static func timestamp(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let parsed = formatter.date(from: value),
              formatter.string(from: parsed) == value else {
            throw DoryRendererBootstrapQualificationError.validityInvalid
        }
        return parsed
    }

    private static func exactUnsigned(_ value: Any?) -> UInt64? {
        guard let value else { return nil }
        let cfValue = value as CFTypeRef
        guard CFGetTypeID(cfValue) == CFNumberGetTypeID(),
              let number = value as? NSNumber else {
            return nil
        }
        let objectiveCType = String(cString: number.objCType)
        guard objectiveCType != "f", objectiveCType != "d" else { return nil }
        let signedValue = number.int64Value
        guard signedValue >= 0,
              number.compare(NSNumber(value: signedValue)) == .orderedSame else {
            return nil
        }
        return UInt64(signedValue)
    }

    private static func requireExpectedDeveloperIDRunnerSeal(
        _ bundle: Bundle
    ) throws {
        guard bundle.bundleURL.pathExtension == "app" else {
            throw DoryRendererBootstrapQualificationError.developerIDSealInvalid
        }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            bundle.bundleURL as CFURL,
            SecCSFlags(),
            &staticCode
        ) == errSecSuccess,
        let staticCode else {
            throw DoryRendererBootstrapQualificationError.developerIDSealInvalid
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            DoryRendererWorkerIdentity.runnerCodeSigningRequirement as CFString,
            SecCSFlags(),
            &requirement
        ) == errSecSuccess,
        let requirement else {
            throw DoryRendererBootstrapQualificationError.developerIDSealInvalid
        }
        let flags = SecCSFlags(
            rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode
        )
        guard SecStaticCodeCheckValidity(staticCode, flags, requirement) == errSecSuccess else {
            throw DoryRendererBootstrapQualificationError.developerIDSealInvalid
        }
    }

    private static func transcriptSHA256(
        bootstrapBytes: Data,
        capabilityReceiptBytes: Data
    ) -> Data {
        var transcript = Data("dev.dory.renderer-bootstrap-transcript.v1\0".utf8)
        appendLittleEndian(UInt64(bootstrapBytes.count), to: &transcript)
        transcript.append(bootstrapBytes)
        appendLittleEndian(UInt64(capabilityReceiptBytes.count), to: &transcript)
        transcript.append(capabilityReceiptBytes)
        return Data(SHA256.hash(data: transcript))
    }

    private static func appendLittleEndian(_ value: UInt64, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private static func lowercaseHexadecimal(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func canonicalTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func stableResource(
        _ url: URL,
        maximumBytes: Int
    ) throws -> Data {
        let descriptor = open(
            url.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard descriptor >= 0 else {
            throw DoryRendererBootstrapQualificationError.resourceUnavailable
        }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_nlink == 1,
              before.st_size > 0,
              before.st_size <= off_t(maximumBytes),
              before.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
            throw DoryRendererBootstrapQualificationError.resourceInvalid
        }
        var bytes = Data(count: Int(before.st_size))
        try bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else {
                throw DoryRendererBootstrapQualificationError.resourceInvalid
            }
            var offset = 0
            while offset < raw.count {
                let count = pread(
                    descriptor,
                    base.advanced(by: offset),
                    raw.count - offset,
                    off_t(offset)
                )
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    throw DoryRendererBootstrapQualificationError.resourceInvalid
                }
            }
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw DoryRendererBootstrapQualificationError.resourceInvalid
        }
        return bytes
    }
}
