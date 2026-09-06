import CryptoKit
import Darwin
import DoryHV
import DoryRendererWorkerWireContracts
import DorydKit
import Foundation
import Security

enum RendererBootstrapQualificationCommandError: Error, Equatable {
    case usage(String)
    case invalidRunnerBundle
    case invalidRunnerSignature
    case invalidInventoryPath
    case invalidInventory
    case artifactMismatch(String)
    case invalidKernelDigest
    case invalidMesaDigest
    case invalidTimestamp(String)
    case invalidValidityWindow
    case invalidOutputPath
    case outputExists
    case outputWriteFailed
}

/// Build-time admission harness for the exact already-signed nested renderer XPC.
///
/// This command intentionally lives in `dory-hv`: the worker's audit-token policy admits only the
/// expected-team runner, so an unsigned helper executable cannot manufacture bootstrap evidence.
/// The receipt is written outside the intermediate-signed app. Packaging later copies it into
/// Resources and applies the final outer signature.
enum RendererBootstrapQualificationCommand {
    enum Profile: String {
        case managedLinux612106 = "managed-linux-6.12.106"
        case doryPCX8664VirGL2 = "dory-pc-x86_64-virgl2"

        var producerFenceContract: DoryRendererProducerFenceContract {
            switch self {
            case .managedLinux612106:
                return .managedLinux612106PrepareFBV1
            case .doryPCX8664VirGL2:
                return .doryPCX8664LinuxVirGL2PrepareFBV1
            }
        }

        var requestedCapabilities: DoryRendererRequestedCapabilities {
            switch self {
            case .managedLinux612106:
                return .productionAcceleration
            case .doryPCX8664VirGL2:
                return .pcVirGL2Acceleration
            }
        }

        var receiptFilename: String {
            switch self {
            case .managedLinux612106:
                return DoryVerifiedRendererBootstrapQualification.receiptFilename
            case .doryPCX8664VirGL2:
                return DoryVerifiedRendererBootstrapQualification.pcVirGL2ReceiptFilename
            }
        }

        func guestMesaDigest(_ supplied: String?) throws -> DoryRendererArtifactDigest {
            switch self {
            case .managedLinux612106:
                if let supplied, supplied != DoryRendererSourceTuple.guestMesaRuntimeSHA256 {
                    throw RendererBootstrapQualificationCommandError.invalidMesaDigest
                }
                return try DoryRendererArtifactDigest(
                    lowercaseSHA256: DoryRendererSourceTuple.guestMesaRuntimeSHA256,
                    field: "guestMesa"
                )
            case .doryPCX8664VirGL2:
                guard let supplied else {
                    throw RendererBootstrapQualificationCommandError.invalidMesaDigest
                }
                let digest = try DoryRendererArtifactDigest(
                    lowercaseSHA256: supplied,
                    field: "guestMesa"
                )
                guard digest.lowercaseSHA256 != DoryRendererSourceTuple.guestMesaRuntimeSHA256 else {
                    throw RendererBootstrapQualificationCommandError.invalidMesaDigest
                }
                return digest
            }
        }
    }

    struct Options {
        let profile: Profile
        let inventoryPath: String
        let managedKernelSHA256: String
        let guestMesaSHA256: String?
        let issuedAt: Date
        let expiresAt: Date
        let outputPath: String
    }

    private final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<Void, any Error>?

        func publish(_ result: Result<Void, any Error>) {
            lock.lock()
            value = result
            lock.unlock()
        }

        func read() -> Result<Void, any Error>? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    static func run(_ arguments: ArraySlice<String>) throws {
        let options = try parse(arguments)
        let semaphore = DispatchSemaphore(value: 0)
        let outcome = Outcome()
        Task.detached {
            do {
                try await qualify(options)
                outcome.publish(.success(()))
            } catch {
                outcome.publish(.failure(error))
            }
            semaphore.signal()
        }
        semaphore.wait()
        guard let result = outcome.read() else {
            throw RendererBootstrapQualificationCommandError.outputWriteFailed
        }
        try result.get()
    }

    private static func qualify(_ options: Options) async throws {
        let bundle = Bundle.main
        guard bundle.bundleURL.pathExtension == "app",
              bundle.bundleIdentifier == DoryRendererWorkerIdentity.runnerBundleIdentifier else {
            throw RendererBootstrapQualificationCommandError.invalidRunnerBundle
        }
        _ = try verifiedCodeDirectoryHash(
            at: bundle.bundleURL,
            requirement: DoryRendererWorkerIdentity.runnerCodeSigningRequirement,
            checkNestedCode: true
        )

        let contents = bundle.bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let requiredInventoryURL = contents.appendingPathComponent(
            DoryRendererProductionInventory.relativePath
        ).standardizedFileURL
        let suppliedInventoryURL = URL(
            fileURLWithPath: options.inventoryPath
        ).standardizedFileURL
        guard suppliedInventoryURL == requiredInventoryURL else {
            throw RendererBootstrapQualificationCommandError.invalidInventoryPath
        }
        let inventoryData = try stableRegularFile(
            suppliedInventoryURL,
            maximumBytes: UInt64(DoryRendererProductionInventory.maximumEncodedBytes)
        )
        let inventory: DoryRendererProductionInventory
        do {
            inventory = try DoryRendererProductionInventory.decodeCanonical(inventoryData)
        } catch {
            throw RendererBootstrapQualificationCommandError.invalidInventory
        }

        for component in inventory.components.values {
            for record in component.files {
                let artifactURL = contents.appendingPathComponent(record.path)
                let actual = try stableRegularFile(
                    artifactURL,
                    maximumBytes: DoryRendererProductionInventory.maximumArtifactBytes
                )
                guard UInt64(actual.count) == record.byteCount,
                      Data(SHA256.hash(data: actual)) == record.sha256.bytes else {
                    throw RendererBootstrapQualificationCommandError.artifactMismatch(
                        record.path
                    )
                }
            }
        }

        guard let worker = inventory.components["rendererWorker"]?.files.first else {
            throw RendererBootstrapQualificationCommandError.invalidInventory
        }
        let workerBundle = contents.appendingPathComponent(
            "XPCServices/DoryRendererWorker.xpc",
            isDirectory: true
        )
        let workerCodeDirectoryHash = try verifiedCodeDirectoryHash(
            at: workerBundle,
            requirement: DoryRendererWorkerIdentity.workerCodeSigningRequirement,
            checkNestedCode: false
        )
        let managedKernel: DoryRendererArtifactDigest
        do {
            managedKernel = try DoryRendererArtifactDigest(
                lowercaseSHA256: options.managedKernelSHA256,
                field: "managedGuestKernel"
            )
        } catch {
            throw RendererBootstrapQualificationCommandError.invalidKernelDigest
        }
        let guestMesa = try options.profile.guestMesaDigest(options.guestMesaSHA256)
        let bootstrap = try makeBootstrap(
            profile: options.profile,
            candidateInventory: inventory.candidateInventory,
            managedKernel: managedKernel,
            guestMesa: guestMesa,
            rendererWorkerExecutable: worker.sha256,
            rendererWorkerCodeDirectoryHash: workerCodeDirectoryHash
        )
        let exactBootstrapBytes = DoryRendererWorkerBootstrapCodec.encode(bootstrap)
        let broker = try await DoryRendererWorkerBroker.connect(
            exactBootstrapBytes: exactBootstrapBytes
        )
        do {
            let receipt = try DoryVerifiedRendererBootstrapQualification
                .makeCandidateReceipt(
                    bootstrap: bootstrap,
                    liveReceipt: broker.capabilityReceipt,
                    issuedAt: options.issuedAt,
                    expiresAt: options.expiresAt
                )
            try writeExclusive(receipt, to: options.outputPath)
            await broker.invalidate()
        } catch {
            await broker.invalidate()
            throw error
        }
    }

    static func makeBootstrap(
        profile: Profile,
        candidateInventory: DoryRendererArtifactDigest,
        managedKernel: DoryRendererArtifactDigest,
        guestMesa: DoryRendererArtifactDigest,
        rendererWorkerExecutable: DoryRendererArtifactDigest,
        rendererWorkerCodeDirectoryHash: DoryCodeDirectoryHash
    ) throws -> DoryRendererWorkerBootstrap {
        try DoryRendererWorkerBootstrap(
            workspaceID: DoryRendererWorkspaceID(
                rawValue: UUID(uuidString: "d0470000-0000-4000-8000-000000000001")!
            ),
            generation: DoryRendererWorkerGeneration(rawValue: 1),
            sourceTuple: .productionCandidate,
            producerFenceContract: profile.producerFenceContract,
            requestedCapabilities: profile.requestedCapabilities,
            artifacts: DoryRendererArtifactManifest(
                candidateInventory: candidateInventory,
                managedGuestKernel: managedKernel,
                guestMesa: guestMesa,
                rendererWorkerExecutable: rendererWorkerExecutable,
                rendererWorkerCodeDirectoryHash: rendererWorkerCodeDirectoryHash
            )
        )
    }

    static func parse(_ arguments: ArraySlice<String>) throws -> Options {
        var values = [String: String]()
        let allowed: Set<String> = [
            "--inventory", "--managed-kernel-sha256", "--guest-mesa-sha256",
            "--producer-fence-contract", "--issued-at", "--expires-at", "--output",
        ]
        let required: Set<String> = [
            "--inventory", "--managed-kernel-sha256", "--issued-at", "--expires-at", "--output",
        ]
        var iterator = arguments.makeIterator()
        while let option = iterator.next() {
            guard allowed.contains(option), values[option] == nil,
                  let value = iterator.next(), !value.isEmpty else {
                throw RendererBootstrapQualificationCommandError.usage(option)
            }
            values[option] = value
        }
        guard required.isSubset(of: Set(values.keys)),
              Set(values.keys).isSubset(of: allowed),
              let inventory = values["--inventory"],
              let kernel = values["--managed-kernel-sha256"],
              let issuedString = values["--issued-at"],
              let expiresString = values["--expires-at"],
              let output = values["--output"] else {
            throw RendererBootstrapQualificationCommandError.usage(
                "renderer-qualify requires inventory, kernel digest, issuance, expiry, and output"
            )
        }
        let profile: Profile
        if let rawProfile = values["--producer-fence-contract"] {
            guard let parsed = Profile(rawValue: rawProfile) else {
                throw RendererBootstrapQualificationCommandError.usage(rawProfile)
            }
            profile = parsed
        } else {
            profile = .managedLinux612106
        }
        _ = try profile.guestMesaDigest(values["--guest-mesa-sha256"])
        let issued = try timestamp(issuedString)
        let expires = try timestamp(expiresString)
        guard expires > issued,
              expires.timeIntervalSince(issued)
                <= DoryVerifiedRendererBootstrapQualification.maximumValidity else {
            throw RendererBootstrapQualificationCommandError.invalidValidityWindow
        }
        let outputURL = URL(fileURLWithPath: output)
        guard outputURL.path == output,
              outputURL.lastPathComponent == profile.receiptFilename else {
            throw RendererBootstrapQualificationCommandError.invalidOutputPath
        }
        return Options(
            profile: profile,
            inventoryPath: inventory,
            managedKernelSHA256: kernel,
            guestMesaSHA256: values["--guest-mesa-sha256"],
            issuedAt: issued,
            expiresAt: expires,
            outputPath: output
        )
    }

    private static func timestamp(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = formatter.date(from: value),
              formatter.string(from: date) == value else {
            throw RendererBootstrapQualificationCommandError.invalidTimestamp(value)
        }
        return date
    }

    private static func stableRegularFile(
        _ url: URL,
        maximumBytes: UInt64
    ) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw RendererBootstrapQualificationCommandError.artifactMismatch(url.path)
        }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_nlink == 1,
              before.st_size > 0,
              UInt64(before.st_size) <= maximumBytes,
              before.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
            throw RendererBootstrapQualificationCommandError.artifactMismatch(url.path)
        }
        var bytes = Data(count: Int(before.st_size))
        try bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else {
                throw RendererBootstrapQualificationCommandError.artifactMismatch(url.path)
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
                    throw RendererBootstrapQualificationCommandError.artifactMismatch(url.path)
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
            throw RendererBootstrapQualificationCommandError.artifactMismatch(url.path)
        }
        return bytes
    }

    private static func verifiedCodeDirectoryHash(
        at url: URL,
        requirement requirementString: String,
        checkNestedCode: Bool
    ) throws -> DoryCodeDirectoryHash {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &code) == errSecSuccess,
              let code,
              SecRequirementCreateWithString(
                requirementString as CFString,
                SecCSFlags(),
                &requirement
              ) == errSecSuccess,
              let requirement else {
            throw RendererBootstrapQualificationCommandError.invalidRunnerSignature
        }
        var rawFlags = kSecCSCheckAllArchitectures
        if checkNestedCode { rawFlags |= kSecCSCheckNestedCode }
        guard SecStaticCodeCheckValidity(
            code,
            SecCSFlags(rawValue: rawFlags),
            requirement
        ) == errSecSuccess else {
            throw RendererBootstrapQualificationCommandError.invalidRunnerSignature
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            code,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
        let values = information as? [CFString: Any],
        let unique = values[kSecCodeInfoUnique] as? Data else {
            throw RendererBootstrapQualificationCommandError.invalidRunnerSignature
        }
        do {
            return try DoryCodeDirectoryHash(bytes: unique)
        } catch {
            throw RendererBootstrapQualificationCommandError.invalidRunnerSignature
        }
    }

    private static func writeExclusive(_ data: Data, to path: String) throws {
        let descriptor = open(
            path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o644)
        )
        guard descriptor >= 0 else {
            if errno == EEXIST {
                throw RendererBootstrapQualificationCommandError.outputExists
            }
            throw RendererBootstrapQualificationCommandError.outputWriteFailed
        }
        defer { close(descriptor) }
        var offset = 0
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else {
                throw RendererBootstrapQualificationCommandError.outputWriteFailed
            }
            while offset < raw.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    raw.count - offset
                )
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    throw RendererBootstrapQualificationCommandError.outputWriteFailed
                }
            }
        }
        guard fsync(descriptor) == 0 else {
            throw RendererBootstrapQualificationCommandError.outputWriteFailed
        }
    }
}
