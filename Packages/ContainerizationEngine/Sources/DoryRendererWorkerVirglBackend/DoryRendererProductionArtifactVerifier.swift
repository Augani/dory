import CryptoKit
import Darwin
import DoryRendererWorkerContracts
import Foundation

public enum DoryRendererProductionArtifactError: Error, Equatable, Sendable {
    case invalidBundleLayout
    case artifactUnavailable(String)
    case executableDigestMismatch
}

/// Path-free proof that the running worker's exact executable bytes match the daemon-admitted
/// immutable bootstrap. The daemon and packager own canonical inventory verification; the
/// sandboxed worker owns only its signed XPC bundle and never reaches into the parent runner.
public struct DoryRendererArtifactAttestation: Equatable, Sendable {
    public let candidateInventory: DoryRendererArtifactDigest
    public let rendererWorkerExecutable: DoryRendererArtifactDigest

    public init(
        candidateInventory: DoryRendererArtifactDigest,
        rendererWorkerExecutable: DoryRendererArtifactDigest
    ) {
        self.candidateInventory = candidateInventory
        self.rendererWorkerExecutable = rendererWorkerExecutable
    }
}

public protocol DoryRendererProductionArtifactVerifying: Sendable {
    func verify(
        bootstrap: DoryRendererWorkerBootstrap
    ) throws -> DoryRendererArtifactAttestation
}

/// Verifies the exact final worker executable. No path is read from XPC or the environment. Every
/// directory component is opened with `O_NOFOLLOW`; the worker is a bounded regular file whose
/// bytes match bootstrap authority minted from the already-verified candidate inventory.
public struct DoryRendererProductionArtifactVerifier:
    DoryRendererProductionArtifactVerifying,
    Sendable
{
    public static let maximumArtifactBytes =
        DoryRendererProductionInventory.maximumArtifactBytes
    public static let workerBundleExecutableRelativePath = "MacOS/DoryRendererWorker"
    private let contentsRoot: URL
    private let executableRelativePath: String

    /// Production constructor. The XPC bundle must be nested exactly at
    /// `Runner.app/Contents/XPCServices/Worker.xpc`; a standalone SwiftPM executable has no
    /// production artifact authority and therefore fails closed here.
    public init(bundle: Bundle = .main) throws {
        guard bundle.bundleURL.pathExtension == "xpc",
              let executableURL = bundle.executableURL else {
            throw DoryRendererProductionArtifactError.invalidBundleLayout
        }
        let xpcServices = bundle.bundleURL.deletingLastPathComponent()
        guard xpcServices.lastPathComponent == "XPCServices" else {
            throw DoryRendererProductionArtifactError.invalidBundleLayout
        }
        let runnerContents = xpcServices.deletingLastPathComponent().standardizedFileURL
        let root = bundle.bundleURL.appendingPathComponent(
            "Contents",
            isDirectory: true
        ).standardizedFileURL
        guard runnerContents.lastPathComponent == "Contents",
              root.lastPathComponent == "Contents",
              let relative = Self.relativePath(of: executableURL, below: root) else {
            throw DoryRendererProductionArtifactError.invalidBundleLayout
        }
        contentsRoot = root
        executableRelativePath = relative
    }

    /// Test/packaging constructor. Paths remain fixed below one injected Contents root; callers
    /// cannot use this constructor through the XPC wire contract.
    public init(contentsRoot: URL, executableRelativePath: String) throws {
        guard Self.validRelativePath(executableRelativePath) else {
            throw DoryRendererProductionArtifactError.invalidBundleLayout
        }
        self.contentsRoot = contentsRoot.standardizedFileURL
        self.executableRelativePath = executableRelativePath
    }

    public func verify(
        bootstrap: DoryRendererWorkerBootstrap
    ) throws -> DoryRendererArtifactAttestation {
        let rootDescriptor = open(
            contentsRoot.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard rootDescriptor >= 0 else {
            throw DoryRendererProductionArtifactError.invalidBundleLayout
        }
        defer { close(rootDescriptor) }

        let expectedPath = Self.workerBundleExecutableRelativePath
        guard executableRelativePath == expectedPath else {
            throw DoryRendererProductionArtifactError.invalidBundleLayout
        }
        let executable = try Self.openSecureRegularFile(
            relativePath: expectedPath,
            rootDescriptor: rootDescriptor,
            maximumBytes: Self.maximumArtifactBytes,
            label: "renderer worker executable"
        )
        defer { close(executable.fileDescriptor) }
        let executableDigest = try Self.hashFileData(
            artifact: executable
        )
        guard executableDigest == bootstrap.artifacts.rendererWorkerExecutable.bytes else {
            throw DoryRendererProductionArtifactError.executableDigestMismatch
        }

        return DoryRendererArtifactAttestation(
            candidateInventory: bootstrap.artifacts.candidateInventory,
            rendererWorkerExecutable: bootstrap.artifacts.rendererWorkerExecutable
        )
    }

    private struct OpenedArtifact {
        let fileDescriptor: Int32
        let byteCount: UInt64
        let identity: FileIdentity
    }

    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let modificationSeconds: Int
        let modificationNanoseconds: Int
        let changeSeconds: Int
        let changeNanoseconds: Int

        init(_ status: stat) {
            device = status.st_dev
            inode = status.st_ino
            size = status.st_size
            modificationSeconds = status.st_mtimespec.tv_sec
            modificationNanoseconds = status.st_mtimespec.tv_nsec
            changeSeconds = status.st_ctimespec.tv_sec
            changeNanoseconds = status.st_ctimespec.tv_nsec
        }
    }

    private static func openSecureRegularFile(
        relativePath: String,
        rootDescriptor: Int32,
        maximumBytes: UInt64,
        label: String
    ) throws -> OpenedArtifact {
        guard validRelativePath(relativePath) else {
            throw DoryRendererProductionArtifactError.artifactUnavailable(label)
        }
        let parts = relativePath.split(separator: "/").map(String.init)
        var directory = fcntl(rootDescriptor, F_DUPFD_CLOEXEC, 0)
        guard directory >= 0 else {
            throw DoryRendererProductionArtifactError.artifactUnavailable(label)
        }
        for part in parts.dropLast() {
            let next = openat(
                directory,
                part,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
            close(directory)
            guard next >= 0 else {
                throw DoryRendererProductionArtifactError.artifactUnavailable(label)
            }
            directory = next
        }
        let descriptor = openat(
            directory,
            parts.last!,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        close(directory)
        guard descriptor >= 0 else {
            throw DoryRendererProductionArtifactError.artifactUnavailable(label)
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_nlink == 1,
              status.st_size > 0,
              UInt64(status.st_size) <= maximumBytes,
              status.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
            close(descriptor)
            throw DoryRendererProductionArtifactError.artifactUnavailable(label)
        }
        return OpenedArtifact(
            fileDescriptor: descriptor,
            byteCount: UInt64(status.st_size),
            identity: FileIdentity(status)
        )
    }

    private static func hashFileData(
        artifact: OpenedArtifact
    ) throws -> Data {
        let fileDescriptor = artifact.fileDescriptor
        let byteCount = artifact.byteCount
        guard lseek(fileDescriptor, 0, SEEK_SET) == 0 else {
            throw DoryRendererProductionArtifactError.artifactUnavailable(
                "renderer worker executable"
            )
        }
        var remaining = byteCount
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1_024 * 1_024)
        while remaining > 0 {
            let requested = min(buffer.count, Int(remaining))
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(fileDescriptor, $0.baseAddress, requested)
            }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw DoryRendererProductionArtifactError.artifactUnavailable(
                    "renderer worker executable"
                )
            }
            hasher.update(data: Data(buffer[0..<count]))
            remaining -= UInt64(count)
        }
        try revalidate(artifact)
        return Data(hasher.finalize())
    }

    private static func revalidate(_ artifact: OpenedArtifact) throws {
        var status = stat()
        guard fstat(artifact.fileDescriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_nlink == 1,
              status.st_size > 0,
              UInt64(status.st_size) == artifact.byteCount,
              status.st_mode & (S_IWGRP | S_IWOTH) == 0,
              FileIdentity(status) == artifact.identity else {
            throw DoryRendererProductionArtifactError.artifactUnavailable(
                "renderer worker executable"
            )
        }
    }

    private static func validRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasSuffix("/") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func relativePath(of url: URL, below root: URL) -> String? {
        let rootPath = root.standardizedFileURL.path
        let candidate = url.standardizedFileURL.path
        guard candidate.hasPrefix(rootPath + "/") else { return nil }
        let relative = String(candidate.dropFirst(rootPath.count + 1))
        return validRelativePath(relative) ? relative : nil
    }
}
