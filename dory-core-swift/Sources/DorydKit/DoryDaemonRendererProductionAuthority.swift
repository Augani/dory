import CryptoKit
import Darwin
import DoryOperations
import DoryRendererWorkerWireContracts
import Foundation
import Security

/// Daemon-owned identity for the renderer artifacts sealed into one RawHV runner. Guest
/// qualification remains a separate signed capability gate; this value proves that the exact
/// inventory, guest-Mesa archive, worker executable, and trusted bootstrap qualification agree.
struct DoryDaemonRendererAccelerationAdmission: Sendable, Equatable {
    static let currentSchemaVersion: UInt16 = 3
    static let bootstrapQualificationComponentIdentity =
        "dory-renderer-bootstrap-qualification"
    static let bootstrapQualificationSignatureComponentIdentity =
        "dory-renderer-bootstrap-qualification-signature"

    /// The protocol contract requires both VirGL2 and Venus. This flag no longer asserts that a
    /// build supplies them: only a verified, candidate-bound bootstrap qualification may do that.
    static var productionTupleProvidesRequiredCapsets: Bool {
        DoryRendererRequestedCapabilities.productionAcceleration.contains(.virgl2)
            && DoryRendererRequestedCapabilities.productionAcceleration.contains(.venus)
    }

    let schemaVersion: UInt16
    let runtimeBuildIdentifier: String
    let candidateInventory: DoryRendererArtifactDigest
    let guestMesa: DoryRendererArtifactDigest
    let rendererWorkerExecutable: DoryRendererArtifactDigest
    let bootstrapQualification: DoryRendererArtifactDigest?
    let bootstrapQualificationSignature: DoryRendererArtifactDigest?

    init(
        schemaVersion: UInt16 = Self.currentSchemaVersion,
        runtimeBuildIdentifier: String,
        candidateInventory: DoryRendererArtifactDigest,
        guestMesa: DoryRendererArtifactDigest,
        rendererWorkerExecutable: DoryRendererArtifactDigest,
        bootstrapQualification: DoryRendererArtifactDigest? = nil,
        bootstrapQualificationSignature: DoryRendererArtifactDigest? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.runtimeBuildIdentifier = runtimeBuildIdentifier
        self.candidateInventory = candidateInventory
        self.guestMesa = guestMesa
        self.rendererWorkerExecutable = rendererWorkerExecutable
        self.bootstrapQualification = bootstrapQualification
        self.bootstrapQualificationSignature = bootstrapQualificationSignature
    }

    var releaseQualificationIsAuthenticated: Bool {
        bootstrapQualification != nil
            && bootstrapQualificationSignature != nil
    }

    func authorizes(runtimeBuildIdentifier expectedRuntime: String) -> Bool {
        Self.productionTupleProvidesRequiredCapsets
            && schemaVersion == Self.currentSchemaVersion
            && runtimeBuildIdentifier == expectedRuntime
            && !runtimeBuildIdentifier.isEmpty
            && Self.runtimeDigest(runtimeBuildIdentifier) != nil
            && guestMesa.lowercaseSHA256
                == DoryRendererSourceTuple.guestMesaRuntimeSHA256
            && bootstrapQualification != nil
    }

    func artifactManifest(
        managedGuestKernel: DoryRendererArtifactDigest,
        rendererWorkerCodeDirectoryHash: DoryCodeDirectoryHash
    ) -> DoryRendererArtifactManifest {
        DoryRendererArtifactManifest(
            candidateInventory: candidateInventory,
            managedGuestKernel: managedGuestKernel,
            guestMesa: guestMesa,
            rendererWorkerExecutable: rendererWorkerExecutable,
            rendererWorkerCodeDirectoryHash: rendererWorkerCodeDirectoryHash
        )
    }

    var qualifiedComponents: [DoryVirtualMachineQualifiedComponent] {
        let definition = DoryRendererSourceTuple.productionDefinitionSHA256
        var records: [(String, String, DoryRendererArtifactDigest)] = [
            (
                DoryRendererProductionInventory.ComponentIdentity.candidateInventory,
                "definition:\(definition)",
                candidateInventory
            ),
            (
                DoryRendererProductionInventory.ComponentIdentity.guestMesa,
                "mesa:\(DoryRendererSourceTuple.guestMesaRevision)",
                guestMesa
            ),
            (
                DoryRendererProductionInventory.ComponentIdentity.worker,
                "sha256:\(rendererWorkerExecutable.lowercaseSHA256)",
                rendererWorkerExecutable
            ),
        ]
        if let bootstrapQualification {
            records.append((
                Self.bootstrapQualificationComponentIdentity,
                "receipt:\(bootstrapQualification.lowercaseSHA256)",
                bootstrapQualification
            ))
        }
        if let bootstrapQualificationSignature {
            records.append((
                Self.bootstrapQualificationSignatureComponentIdentity,
                "signature:\(bootstrapQualificationSignature.lowercaseSHA256)",
                bootstrapQualificationSignature
            ))
        }
        return records.map { identity, build, digest in
            DoryVirtualMachineQualifiedComponent(
                componentIdentifier: identity,
                buildIdentifier: build,
                artifactSHA256: digest.lowercaseSHA256
            )
        }.sorted { $0.componentIdentifier < $1.componentIdentifier }
    }

    /// Reconstructs the typed renderer authority from the exact component evidence already sealed
    /// into a validated resolved plan. Production start revalidation must first prove that these
    /// records still equal the freshly verified signed runtime component graph.
    static func recovering(
        runtimeBuildIdentifier: String,
        components: [DoryResolvedBackendComponentEvidence]
    ) throws -> Self {
        let requiredRendererIdentities: Set<String> = [
            DoryRendererProductionInventory.ComponentIdentity.candidateInventory,
            DoryRendererProductionInventory.ComponentIdentity.guestMesa,
            DoryRendererProductionInventory.ComponentIdentity.worker,
            Self.bootstrapQualificationComponentIdentity,
        ]
        let byIdentity = Dictionary(grouping: components, by: \.componentIdentifier)
        let receivedIdentities = Set(byIdentity.keys)
        let requiredIdentities = requiredRendererIdentities.union(["dory-hv"])
        let optionalSignature = Self.bootstrapQualificationSignatureComponentIdentity
        guard receivedIdentities == requiredIdentities
                || receivedIdentities == requiredIdentities.union([optionalSignature]),
              byIdentity.values.allSatisfy({ $0.count == 1 }),
              let runtimeDigest = runtimeDigest(runtimeBuildIdentifier),
              let runtime = byIdentity["dory-hv"]?.first,
              runtime.buildIdentifier == runtimeBuildIdentifier,
              runtime.artifactSHA256 == runtimeDigest else {
            throw DoryDaemonRendererProductionAuthorityError.inventoryInvalid
        }

        func record(_ identity: String) throws -> DoryResolvedBackendComponentEvidence {
            guard let value = byIdentity[identity]?.first else {
                throw DoryDaemonRendererProductionAuthorityError.inventoryInvalid
            }
            return value
        }
        func digest(
            _ identity: String,
            expectedBuildIdentifier: (String) -> String
        ) throws -> DoryRendererArtifactDigest {
            let value = try record(identity)
            let artifact = try DoryRendererArtifactDigest(
                lowercaseSHA256: value.artifactSHA256,
                field: identity
            )
            guard value.buildIdentifier == expectedBuildIdentifier(artifact.lowercaseSHA256) else {
                throw DoryDaemonRendererProductionAuthorityError.inventoryInvalid
            }
            return artifact
        }

        let candidateInventory = try digest(
            DoryRendererProductionInventory.ComponentIdentity.candidateInventory
        ) { _ in
            "definition:\(DoryRendererSourceTuple.productionDefinitionSHA256)"
        }
        let guestMesa = try digest(
            DoryRendererProductionInventory.ComponentIdentity.guestMesa
        ) { _ in
            "mesa:\(DoryRendererSourceTuple.guestMesaRevision)"
        }
        guard guestMesa.lowercaseSHA256 == DoryRendererSourceTuple.guestMesaRuntimeSHA256 else {
            throw DoryDaemonRendererProductionAuthorityError.inventoryInvalid
        }
        let admission = Self(
            runtimeBuildIdentifier: runtimeBuildIdentifier,
            candidateInventory: candidateInventory,
            guestMesa: guestMesa,
            rendererWorkerExecutable: try digest(
                DoryRendererProductionInventory.ComponentIdentity.worker
            ) { "sha256:\($0)" },
            bootstrapQualification: try digest(
                Self.bootstrapQualificationComponentIdentity
            ) { "receipt:\($0)" },
            bootstrapQualificationSignature: byIdentity[optionalSignature] == nil
                ? nil
                : try digest(optionalSignature) { "signature:\($0)" }
        )
        guard admission.authorizes(runtimeBuildIdentifier: runtimeBuildIdentifier) else {
            throw DoryDaemonRendererProductionAuthorityError.inventoryInvalid
        }
        return admission
    }

    private static func runtimeDigest(_ buildIdentifier: String) -> String? {
        guard buildIdentifier.hasPrefix("sha256:") else { return nil }
        let digest = String(buildIdentifier.dropFirst("sha256:".count))
        guard digest.utf8.count == 64,
              digest.utf8.allSatisfy({
                  (48...57).contains($0) || (97...102).contains($0)
              }),
              digest.contains(where: { $0 != "0" }) else {
            return nil
        }
        return digest
    }
}

enum DoryDaemonRendererProductionAuthorityError: Error, Sendable, Equatable {
    case inventoryAbsent
    case bootstrapQualificationAbsent
    case bootstrapQualificationSignatureAbsent
    case invalidBundleLayout
    case invalidBundleSignature
    case inventoryInvalid
    case artifactInvalid(String)
    case workerSignatureInvalid
}

/// Verifies the signed runner's fixed renderer bundle graph before acceleration becomes a host
/// capability fact. Absence is a valid software-only runner; a present but invalid graph fails the
/// complete runtime verification rather than silently disappearing into software fallback.
enum DoryDaemonRendererProductionAuthority {
    private static let workerExecutableRelativePath =
        DoryRendererProductionInventory.rendererWorkerRelativePath
    private static let workerBundleRelativePath =
        "XPCServices/DoryRendererWorker.xpc"
    private static let bootstrapQualificationRelativePath =
        "Resources/renderer-bootstrap-qualification.json"
    private static let bootstrapQualificationSignatureRelativePath =
        "Resources/renderer-bootstrap-qualification.json.sig"

    static func verifyIfPresent(
        runnerExecutablePath: String,
        runtimeBuildIdentifier: String
    ) throws -> DoryDaemonRendererAccelerationAdmission? {
        let executable = URL(fileURLWithPath: runnerExecutablePath).standardizedFileURL
        let macOSDirectory = executable.deletingLastPathComponent()
        let contents = macOSDirectory.deletingLastPathComponent()
        let runnerBundle = contents.deletingLastPathComponent()
        guard executable.lastPathComponent == "dory-hv",
              macOSDirectory.lastPathComponent == "MacOS",
              contents.lastPathComponent == "Contents",
              runnerBundle.pathExtension == "app" else {
            throw DoryDaemonRendererProductionAuthorityError.invalidBundleLayout
        }
        let root = open(
            contents.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard root >= 0 else {
            throw DoryDaemonRendererProductionAuthorityError.invalidBundleLayout
        }
        defer { close(root) }

        // The outer application seal is launch authority even for a software-only RawHV runner.
        // A missing renderer inventory may suppress acceleration; it may not bypass bundle or
        // nested-code signature validation.
        _ = try verifyCode(
            at: runnerBundle,
            expectedIdentifier: DoryRendererWorkerIdentity.runnerBundleIdentifier,
            checkNestedCode: true
        )

        let inventoryDescriptor: Int32
        do {
            inventoryDescriptor = try openSecureRegularFile(
                DoryRendererProductionInventory.relativePath,
                below: root,
                maximumBytes: UInt64(
                    DoryRendererProductionInventory.maximumEncodedBytes
                )
            )
        } catch let error as DoryDaemonRendererProductionAuthorityError
            where error == .inventoryAbsent {
            return nil
        }
        defer { close(inventoryDescriptor) }
        let inventoryBytes: Data
        do {
            inventoryBytes = try readInventory(
                inventoryDescriptor,
                maximumBytes: UInt64(
                    DoryRendererProductionInventory.maximumEncodedBytes
                )
            )
        } catch {
            throw DoryDaemonRendererProductionAuthorityError.artifactInvalid(
                "renderer inventory read failed: \(error)"
            )
        }
        let inventory: DoryRendererProductionInventory
        do {
            inventory = try DoryRendererProductionInventory.decodeCanonical(inventoryBytes)
        } catch {
            throw DoryDaemonRendererProductionAuthorityError.artifactInvalid(
                "renderer inventory decode failed: \(error)"
            )
        }

        guard inventory.components.count == 2,
              let angleComponent = inventory.components["angleMetal"],
              angleComponent.files.map(\.path) == [
                DoryRendererProductionInventory.angleEGLRelativePath,
                DoryRendererProductionInventory.angleGLESv2RelativePath,
              ],
              let workerComponent = inventory.components["rendererWorker"],
              workerComponent.files.count == 1,
              let workerRecord = workerComponent.files.first,
              workerRecord.path == workerExecutableRelativePath else {
            throw DoryDaemonRendererProductionAuthorityError.artifactInvalid(
                "renderer inventory component layout is invalid"
            )
        }

        // The candidate-inventory digest is only meaningful after every claimed packaged byte
        // has been compared with the signed bundle. Nested-code validation authenticates these
        // dylibs; descriptor hashing additionally proves they are the exact ANGLE Metal pair that
        // the inventory and bootstrap qualification name.
        for record in angleComponent.files {
            let descriptor = try openSecureRegularFile(
                record.path,
                below: root,
                maximumBytes: DoryRendererProductionInventory.maximumArtifactBytes
            )
            defer { close(descriptor) }
            let artifact: (byteCount: UInt64, digest: DoryRendererArtifactDigest)
            do {
                artifact = try hashFile(
                    descriptor,
                    maximumBytes: DoryRendererProductionInventory.maximumArtifactBytes
                )
            } catch {
                throw DoryDaemonRendererProductionAuthorityError.artifactInvalid(
                    "renderer ANGLE artifact read failed: \(record.path): \(error)"
                )
            }
            guard artifact.byteCount == record.byteCount,
                  artifact.digest == record.sha256 else {
                throw DoryDaemonRendererProductionAuthorityError.artifactInvalid(record.path)
            }
        }

        let workerBundle = contents.appendingPathComponent(workerBundleRelativePath)
        let workerCodeDirectoryHash = try verifyCode(
            at: workerBundle,
            expectedIdentifier: DoryRendererWorkerIdentity.workerBundleIdentifier,
            checkNestedCode: false
        )
        let workerDescriptor = try openSecureRegularFile(
            workerExecutableRelativePath,
            below: root,
            maximumBytes: DoryRendererProductionInventory.maximumArtifactBytes
        )
        defer { close(workerDescriptor) }
        let worker: (byteCount: UInt64, digest: DoryRendererArtifactDigest)
        do {
            worker = try hashFile(
                workerDescriptor,
                maximumBytes: DoryRendererProductionInventory.maximumArtifactBytes
            )
        } catch {
            throw DoryDaemonRendererProductionAuthorityError.artifactInvalid(
                "renderer worker read failed: \(error)"
            )
        }
        guard worker.byteCount == workerRecord.byteCount,
              worker.digest == workerRecord.sha256 else {
            throw DoryDaemonRendererProductionAuthorityError.artifactInvalid(
                workerExecutableRelativePath
            )
        }

        let qualificationDescriptor: Int32
        do {
            qualificationDescriptor = try openSecureRegularFile(
                bootstrapQualificationRelativePath,
                below: root,
                maximumBytes: UInt64(
                    DoryVerifiedRendererBootstrapQualification.maximumEncodedBytes
                )
            )
        } catch let error as DoryDaemonRendererProductionAuthorityError
            where error == .bootstrapQualificationAbsent {
            // A signed worker without externally trusted bootstrap evidence is a valid
            // software-only runner. It cannot advertise hardware acceleration.
            return nil
        }
        defer { close(qualificationDescriptor) }
        let qualificationBytes: Data
        do {
            qualificationBytes = try readInventory(
                qualificationDescriptor,
                maximumBytes: UInt64(
                    DoryVerifiedRendererBootstrapQualification.maximumEncodedBytes
                )
            )
        } catch {
            throw DoryDaemonRendererProductionAuthorityError.artifactInvalid(
                "renderer bootstrap qualification read failed: \(error)"
            )
        }
        let qualificationEvidence: (
            qualification: DoryVerifiedRendererBootstrapQualification,
            signatureDigest: DoryRendererArtifactDigest?
        )
        do {
            let signatureDescriptor = try openSecureRegularFile(
                bootstrapQualificationSignatureRelativePath,
                below: root,
                maximumBytes: 128
            )
            defer { close(signatureDescriptor) }
            let signatureBytes = try readInventory(
                signatureDescriptor,
                maximumBytes: 128
            )
            let qualification = try DoryVerifiedRendererBootstrapQualification
                .verifyProduction(
                    receiptData: qualificationBytes,
                    signatureData: signatureBytes
                )
            let signatureDigest = try DoryRendererArtifactDigest(
                bytes: Data(SHA256.hash(data: signatureBytes)),
                field: "rendererBootstrapQualificationSignature"
            )
            qualificationEvidence = (qualification, signatureDigest)
        } catch let error as DoryDaemonRendererProductionAuthorityError
            where error == .bootstrapQualificationSignatureAbsent {
            // Expected Developer ID seals plus exact worker/live-capset matching authorize
            // preview runtime use. Only the detached production signature upgrades this to
            // release-support evidence.
            do {
                let qualification = try DoryVerifiedRendererBootstrapQualification
                    .decodeDeveloperIDSignedCandidate(
                        receiptData: qualificationBytes
                    )
                qualificationEvidence = (qualification, nil)
            } catch {
                throw DoryDaemonRendererProductionAuthorityError.artifactInvalid(
                    "renderer bootstrap qualification is invalid: \(error)"
                )
            }
        } catch {
            throw DoryDaemonRendererProductionAuthorityError.artifactInvalid(
                "renderer bootstrap qualification is invalid: \(error)"
            )
        }
        let qualification = qualificationEvidence.qualification
        let qualificationSignatureDigest = qualificationEvidence.signatureDigest
        guard qualification.authorizes(
            candidateInventory: inventory.candidateInventory,
            workerExecutable: worker.digest,
            workerCodeDirectoryHash: workerCodeDirectoryHash
        ) else {
            throw DoryDaemonRendererProductionAuthorityError.artifactInvalid(
                "renderer bootstrap qualification does not bind the packaged worker"
            )
        }

        let admission = DoryDaemonRendererAccelerationAdmission(
            runtimeBuildIdentifier: runtimeBuildIdentifier,
            candidateInventory: inventory.candidateInventory,
            guestMesa: try DoryRendererArtifactDigest(
                lowercaseSHA256: DoryRendererSourceTuple.guestMesaRuntimeSHA256,
                field: "guestMesa"
            ),
            rendererWorkerExecutable: worker.digest,
            bootstrapQualification: qualification.receiptSHA256,
            bootstrapQualificationSignature: qualificationSignatureDigest
        )
        guard admission.authorizes(runtimeBuildIdentifier: runtimeBuildIdentifier) else {
            throw DoryDaemonRendererProductionAuthorityError.artifactInvalid(
                "renderer acceleration admission does not match the compiled tuple"
            )
        }
        return admission
    }

    private static func openSecureRegularFile(
        _ relativePath: String,
        below root: Int32,
        maximumBytes: UInt64
    ) throws -> Int32 {
        let parts = relativePath.split(separator: "/").map(String.init)
        guard !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw DoryDaemonRendererProductionAuthorityError.artifactInvalid(relativePath)
        }
        var directory = fcntl(root, F_DUPFD_CLOEXEC, 0)
        guard directory >= 0 else {
            throw DoryDaemonRendererProductionAuthorityError.artifactInvalid(relativePath)
        }
        defer { close(directory) }
        for component in parts.dropLast() {
            let next = openat(
                directory,
                component,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
            guard next >= 0 else {
                if errno == ENOENT,
                   relativePath == DoryRendererProductionInventory.relativePath {
                    throw DoryDaemonRendererProductionAuthorityError.inventoryAbsent
                }
                if errno == ENOENT,
                   relativePath == bootstrapQualificationRelativePath {
                    throw DoryDaemonRendererProductionAuthorityError
                        .bootstrapQualificationAbsent
                }
                if errno == ENOENT,
                   relativePath == bootstrapQualificationSignatureRelativePath {
                    throw DoryDaemonRendererProductionAuthorityError
                        .bootstrapQualificationSignatureAbsent
                }
                throw DoryDaemonRendererProductionAuthorityError.artifactInvalid(relativePath)
            }
            close(directory)
            directory = next
        }
        let descriptor = openat(
            directory,
            parts.last!,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard descriptor >= 0 else {
            if errno == ENOENT,
               relativePath == DoryRendererProductionInventory.relativePath {
                throw DoryDaemonRendererProductionAuthorityError.inventoryAbsent
            }
            if errno == ENOENT,
               relativePath == bootstrapQualificationRelativePath {
                throw DoryDaemonRendererProductionAuthorityError
                    .bootstrapQualificationAbsent
            }
            if errno == ENOENT,
               relativePath == bootstrapQualificationSignatureRelativePath {
                throw DoryDaemonRendererProductionAuthorityError
                    .bootstrapQualificationSignatureAbsent
            }
            throw DoryDaemonRendererProductionAuthorityError.artifactInvalid(relativePath)
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1,
              info.st_size > 0,
              UInt64(info.st_size) <= maximumBytes,
              info.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
            close(descriptor)
            throw DoryDaemonRendererProductionAuthorityError.artifactInvalid(relativePath)
        }
        return descriptor
    }

    private static func readInventory(
        _ descriptor: Int32,
        maximumBytes: UInt64
    ) throws -> Data {
        var bytes = Data()
        let result = try consumeStableFile(
            descriptor,
            maximumBytes: maximumBytes
        ) { chunk in
            bytes.append(chunk)
        }
        guard result.byteCount == UInt64(bytes.count) else {
            throw DoryDaemonRendererProductionAuthorityError.inventoryInvalid
        }
        return bytes
    }

    private static func hashFile(
        _ descriptor: Int32,
        maximumBytes: UInt64
    ) throws -> (byteCount: UInt64, digest: DoryRendererArtifactDigest) {
        try consumeStableFile(descriptor, maximumBytes: maximumBytes) { _ in }
    }

    /// Hashes through a bounded chunk and never retains artifact payloads. Only the inventory's
    /// separately bounded 1 MiB reader accumulates bytes for canonical JSON parsing.
    private static func consumeStableFile(
        _ descriptor: Int32,
        maximumBytes: UInt64,
        consume: (Data) throws -> Void
    ) throws -> (byteCount: UInt64, digest: DoryRendererArtifactDigest) {
        var before = stat()
        guard fstat(descriptor, &before) == 0 else {
            throw DoryDaemonRendererProductionAuthorityError.inventoryInvalid
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var byteCount: UInt64 = 0
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty { break }
            let (nextCount, overflow) = byteCount.addingReportingOverflow(
                UInt64(chunk.count)
            )
            guard !overflow, nextCount <= maximumBytes else {
                throw DoryDaemonRendererProductionAuthorityError.inventoryInvalid
            }
            byteCount = nextCount
            hasher.update(data: chunk)
            try consume(chunk)
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              byteCount == UInt64(after.st_size) else {
            throw DoryDaemonRendererProductionAuthorityError.inventoryInvalid
        }
        return (
            byteCount,
            try DoryRendererArtifactDigest(bytes: Data(hasher.finalize()))
        )
    }

    private static func verifyCode(
        at url: URL,
        expectedIdentifier: String,
        checkNestedCode: Bool
    ) throws -> DoryCodeDirectoryHash {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &code)
                == errSecSuccess,
              let code else {
            throw DoryDaemonRendererProductionAuthorityError.invalidBundleSignature
        }
        var rawFlags = kSecCSCheckAllArchitectures
        if checkNestedCode { rawFlags |= kSecCSCheckNestedCode }
        guard SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: rawFlags), nil)
                == errSecSuccess else {
            throw DoryDaemonRendererProductionAuthorityError.invalidBundleSignature
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
        let values = information as? [CFString: Any],
        values[kSecCodeInfoIdentifier] as? String == expectedIdentifier,
        values[kSecCodeInfoTeamIdentifier] as? String
            == DoryRendererWorkerIdentity.developmentTeamIdentifier,
        let unique = values[kSecCodeInfoUnique] as? Data else {
            throw DoryDaemonRendererProductionAuthorityError.workerSignatureInvalid
        }
        do {
            return try DoryCodeDirectoryHash(
                bytes: unique,
                field: expectedIdentifier
            )
        } catch {
            throw DoryDaemonRendererProductionAuthorityError.workerSignatureInvalid
        }
    }
}
