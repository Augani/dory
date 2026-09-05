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

    static func prepare(
        runnerPath: String,
        kernelPath: String,
        stateDirectory: String
    ) throws -> Self {
        let (runtime, runnerIdentity, workerIdentity) = try Self.verifiedRuntime(at: runnerPath)
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
            releaseIdentity: DoryRendererReleaseIdentityV1(
                runnerCodeDirectoryHash: runnerIdentity,
                rendererWorkerCodeDirectoryHash: workerIdentity,
                tupleDefinitionSHA256: try DoryRendererArtifactDigest(
                    lowercaseSHA256: DoryRendererSourceTuple.productionDefinitionSHA256,
                    field: "rendererTupleDefinition"
                )
            )
        )
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
