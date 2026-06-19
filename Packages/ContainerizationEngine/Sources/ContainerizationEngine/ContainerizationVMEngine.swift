import Foundation
import Containerization

/// Dory's in-process VM engine, built on Apple's `containerization` framework. Unlike the shipping
/// dind-on-`container`-CLI engine, this drives the Linux VM directly via Virtualization.framework,
/// which exposes the capabilities the CLI hides — and therefore the OrbStack features that were
/// blocked: Rosetta-accelerated x86, host↔guest (bidirectional) file mounts, and the device/memory
/// controls behind USB/audio passthrough and dynamic ballooning.
public struct ContainerizationVMEngine: Sendable {
    public struct RunSpec: Sendable {
        public var id: String
        public var image: String
        public var arguments: [String]
        public var cpus: Int
        public var memoryInBytes: UInt64
        /// Rosetta-accelerated x86 emulation — a first-class `ContainerManager` parameter, far
        /// faster than the qemu binfmt fallback the dind engine uses.
        public var rosetta: Bool
        /// Bidirectional host↔guest file shares (`host:guest`). The framework mounts these via
        /// virtiofs in either direction, covering both `docker -v` and the reverse OrbStack mount.
        public var mounts: [(host: String, guest: String)]

        public init(
            id: String,
            image: String,
            arguments: [String] = ["/bin/sh"],
            cpus: Int = 4,
            memoryInBytes: UInt64 = 1024 * 1024 * 1024,
            rosetta: Bool = false,
            mounts: [(host: String, guest: String)] = []
        ) {
            self.id = id
            self.image = image
            self.arguments = arguments
            self.cpus = cpus
            self.memoryInBytes = memoryInBytes
            self.rosetta = rosetta
            self.mounts = mounts
        }
    }

    public let kernelPath: URL
    public let rootfsSizeInBytes: UInt64

    public init(kernelPath: URL, rootfsSizeInBytes: UInt64 = 8 * 1024 * 1024 * 1024) {
        self.kernelPath = kernelPath
        self.rootfsSizeInBytes = rootfsSizeInBytes
    }

    /// Boot a Linux VM and run the container in it, in-process. Returns the started container so the
    /// caller can wait on it, exec into it, and tear it down.
    @discardableResult
    public func run(_ spec: RunSpec) async throws -> LinuxContainer {
        let kernel = Kernel(path: kernelPath, platform: .linuxArm)

        var network: Network?
        if #available(macOS 26, *) {
            network = try VmnetNetwork()
        }

        var manager = try await ContainerManager(
            kernel: kernel,
            initfsReference: "vminit:latest",
            network: network,
            rosetta: spec.rosetta
        )

        let rootfsSize = rootfsSizeInBytes
        let container = try await manager.create(
            spec.id,
            reference: spec.image,
            rootfsSizeInBytes: rootfsSize,
            readOnly: false,
            networking: network != nil
        ) { config in
            config.cpus = spec.cpus
            config.memoryInBytes = spec.memoryInBytes
            config.process.arguments = spec.arguments
            config.process.capabilities = .allCapabilities
            for mount in spec.mounts {
                config.mounts.append(Containerization.Mount.share(source: mount.host, destination: mount.guest))
            }
        }

        try await container.create()
        try await container.start()
        return container
    }

    /// Run a command in a running container — the in-process equivalent of `docker exec`.
    @discardableResult
    public func exec(_ container: LinuxContainer, id: String, arguments: [String]) async throws -> LinuxProcess {
        try await container.exec(id) { config in
            config.arguments = arguments
            config.capabilities = .allCapabilities
        }
    }

    /// Live CPU/memory statistics — the signal a dynamic-memory balloon policy reads to decide how
    /// much guest RAM to return to macOS.
    public func statistics(_ container: LinuxContainer) async throws -> ContainerStatistics {
        try await container.statistics()
    }

    public func stop(_ container: LinuxContainer) async throws {
        try await container.stop()
    }

    public func wait(_ container: LinuxContainer) async throws -> ExitStatus {
        try await container.wait()
    }
}
