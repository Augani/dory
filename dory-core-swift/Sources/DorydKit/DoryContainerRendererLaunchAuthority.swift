import CryptoKit
import Darwin
import DoryOperations
import DoryRendererWorkerWireContracts
import Foundation

/// Read-only package preflight shared by Settings and container launch. This verifies the
/// signed runner/worker qualification; observed guest GPU readiness still comes from launch.
public enum DoryContainerGPUPreflight {
    public static func verifyRunner(at path: String) throws {
        _ = try DoryContainerRendererLaunchAuthority.verifiedRuntime(at: path)
    }
}

/// The Docker engine uses the same signed worker and immutable bootstrap as an ARM desktop.
/// CLI metadata describes the inherited object; it does not replace that object's authority.
final class DoryContainerRendererLaunchAuthority: Sendable {
    let bootstrap: RawHVAdmittedRendererBootstrap
    let kernelSHA256: String
    let releaseIdentity: DoryRendererReleaseIdentityV1

    init(bootstrap: RawHVAdmittedRendererBootstrap, kernelSHA256: String,
         releaseIdentity: DoryRendererReleaseIdentityV1) {
        self.bootstrap = bootstrap
        self.kernelSHA256 = kernelSHA256
        self.releaseIdentity = releaseIdentity
    }

    var arguments: [String] {
        ["--renderer-bootstrap-byte-count", String(bootstrap.byteCount),
         "--renderer-bootstrap-sha256", bootstrap.sha256,
         "--gpu-kernel-sha256", kernelSHA256]
    }

    static func refreshManagedHVConfiguration(
        _ configuration: inout HvProcessConfiguration,
        prepareAuthority: (
            _ runnerPath: String,
            _ kernelPath: String,
            _ stateDirectory: String
        ) throws -> DoryContainerRendererLaunchAuthority = {
            try DoryContainerRendererLaunchAuthority.prepare(
                runnerPath: $0,
                kernelPath: $1,
                stateDirectory: $2
            )
        }
    ) throws {
        guard configuration.containerRendererAuthority != nil else { return }
        let kernelPath = try requiredArgumentValue("--kernel", in: configuration.arguments)
        let stateDirectory = try requiredArgumentValue("--state-dir", in: configuration.arguments)
        configuration.arguments = try removingRendererBootstrapArguments(from: configuration.arguments)
        for descriptor in configuration.inheritedFileDescriptors
        where descriptor.name == RuntimeLaunchEnvelope.rendererBootstrapSlotName
            || descriptor.childDescriptor == RuntimeLaunchEnvelope.rendererBootstrapDescriptor {
            descriptor.close()
        }
        configuration.inheritedFileDescriptors.removeAll {
            $0.name == RuntimeLaunchEnvelope.rendererBootstrapSlotName
                || $0.childDescriptor == RuntimeLaunchEnvelope.rendererBootstrapDescriptor
        }
        let refreshed = try prepareAuthority(configuration.executablePath, kernelPath, stateDirectory)
        configuration.arguments += refreshed.arguments
        configuration.inheritedFileDescriptors.append(refreshed.bootstrap.authority)
        configuration.containerRendererAuthority = refreshed
        configuration.rendererReleaseIdentity = refreshed.releaseIdentity
    }

    private static func requiredArgumentValue(
        _ flag: String,
        in arguments: [String]
    ) throws -> String {
        guard !arguments.contains(where: { $0.hasPrefix(flag + "=") }) else {
            throw MachineManagerError.persistence("container GPU launch argument \(flag) must not use inline form")
        }
        let indices = arguments.indices.filter { arguments[$0] == flag }
        guard indices.count == 1, let index = indices.first,
              arguments.indices.contains(index + 1) else {
            throw MachineManagerError.persistence("container GPU launch argument \(flag) is missing")
        }
        return arguments[index + 1]
    }

    private static func removingRendererBootstrapArguments(
        from arguments: [String]
    ) throws -> [String] {
        let flags = Set(["--renderer-bootstrap-byte-count",
                         "--renderer-bootstrap-sha256",
                         "--gpu-kernel-sha256"])
        var result: [String] = []
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            guard !flags.contains(where: { argument.hasPrefix($0 + "=") }) else {
                throw MachineManagerError.persistence("container GPU renderer bootstrap arguments must not use inline form")
            }
            if flags.contains(argument) {
                guard arguments.indices.contains(index + 1) else {
                    throw MachineManagerError.persistence("container GPU renderer bootstrap argument \(argument) is missing its value")
                }
                index += 2
                continue
            }
            result.append(argument)
            index += 1
        }
        return result
    }

    static func prepare(
        runnerPath: String,
        kernelPath: String,
        stateDirectory: String,
        releaseIdentityProvider: any DoryRendererReleaseIdentityProviding =
            DoryCurrentTaskRendererReleaseIdentityProvider()
    ) throws -> Self {
        let (runtime, runnerIdentity, workerIdentity) = try Self.verifiedRuntime(at: runnerPath)
        let releaseIdentity = try validatedDaemonReleaseIdentity(
            provider: releaseIdentityProvider,
            runnerIdentity: runnerIdentity,
            workerIdentity: workerIdentity
        )
        let kernelDigest = try digestKernel(at: kernelPath)
        // Do not repair permissions on an existing directory: the trusted-root acquisition must
        // reject an unsafe or replaced state root instead of granting it launch authority.
        let stagingDirectory = stateDirectory + "/renderer"
        try FileManager.default.createDirectory(
            atPath: stagingDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let root = try DoryTrustedDirectoryRoot(canonicalAbsolutePath: stagingDirectory)
        let request = RawHVRendererBootstrapRequest(
            workspaceID: UUID(), generation: 1,
            runtimeBuildIdentifier: runtime.runtimeBuildIdentifier,
            components: runtime.components.map {
                DoryResolvedBackendComponentEvidence(
                    componentIdentifier: $0.componentIdentifier,
                    buildIdentifier: $0.buildIdentifier,
                    artifactSHA256: $0.artifactSHA256
                )
            },
            rendererWorkerCodeDirectoryHash: workerIdentity
        )
        let bootstrap = try root.withBorrowedDescriptor {
            try MachineManager.stageResolvedRawHVRendererBootstrap(
                machineDirectoryDescriptor: $0,
                machineDirectoryGeneration: root.identity,
                exactKernelSHA256: kernelDigest, request: request
            )
        }
        return Self(
            bootstrap: bootstrap, kernelSHA256: kernelDigest,
            releaseIdentity: releaseIdentity
        )
    }

    static func validatedDaemonReleaseIdentity(
        provider: any DoryRendererReleaseIdentityProviding,
        runnerIdentity: DoryCodeDirectoryHash,
        workerIdentity: DoryCodeDirectoryHash
    ) throws -> DoryRendererReleaseIdentityV1 {
        let identity = try provider.loadReleaseIdentity()
        guard identity.tupleDefinitionSHA256.lowercaseSHA256
                == DoryRendererSourceTuple.productionDefinitionSHA256 else {
            throw DoryRendererReleaseIdentityError.tupleDefinitionMismatch
        }
        guard identity.runnerCodeDirectoryHash == runnerIdentity,
              identity.rendererWorkerCodeDirectoryHash == workerIdentity else {
            throw DoryRendererReleaseIdentityError.releaseIdentityMismatch
        }
        return identity
    }

    static func verifiedRuntime(at path: String) throws -> (
        DoryDaemonVerifiedBackendRuntime, DoryCodeDirectoryHash, DoryCodeDirectoryHash
    ) {
        let runtime = try DoryDaemonVirtualMachineProductionTrustFactory.verifyProductionRuntime(
            path: path,
            descriptor: RawHVLinuxMachineBackend.backendDescriptor,
            componentIdentifier: "dory-hv"
        )
        guard let admission = runtime.rendererAccelerationAdmission,
              admission.authorizes(runtimeBuildIdentifier: runtime.runtimeBuildIdentifier),
              let runnerIdentity = admission.runnerCodeDirectoryHash,
              let workerIdentity = admission.rendererWorkerCodeDirectoryHash else {
            throw MachineManagerError.persistence("container GPU requires a signed, qualified renderer bundle")
        }
        return (runtime, runnerIdentity, workerIdentity)
    }

    private static func digestKernel(at path: String) throws -> String {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw MachineManagerError.persistence("container GPU kernel cannot be opened")
        }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size > 0, before.st_size <= 512 * 1024 * 1024,
              before.st_uid == 0 || before.st_uid == geteuid(),
              before.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
            throw MachineManagerError.persistence("container GPU kernel is not a trusted regular file")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var digest = SHA256()
        var count: Int64 = 0
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            count += Int64(chunk.count)
            guard count <= before.st_size else {
                throw MachineManagerError.persistence("container GPU kernel grew during admission")
            }
            digest.update(data: chunk)
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, count == before.st_size,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw MachineManagerError.persistence("container GPU kernel changed during admission")
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
