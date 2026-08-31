import DoryHV
import DoryMachinePC
import Foundation

/// Owns the one-shot filesystem worker generation attached to the current DoryPC machine. A full
/// PC reset creates a new signed worker bootstrap and new PCI frontends before execution resumes.
final class DoryPCFilesystemRuntime: @unchecked Sendable {
    private final class LifecycleGate: @unchecked Sendable {
        private let lock = NSLock()
        private var retired = false
        func retire() { lock.withLock { retired = true } }
        var isRetired: Bool { lock.withLock { retired } }
    }

    private struct Generation {
        let worker: DoryFilesystemWorkerLaunch
        let devices: [DoryPCVirtioFSPCIDevice]
        let lifecycleGate: LifecycleGate

        func retire() {
            lifecycleGate.retire()
            devices.forEach { $0.retireForMachineReplacement() }
            worker.client.invalidate()
        }
    }

    private let lock = NSLock()
    private let shares: [VirtioFSShareConfiguration]
    private let requestQueueCount: Int
    private let onWorkerLifecycle: @Sendable (VirtioFSWorkerLifecycleEvent) -> Void
    private var generation: Generation?

    init(
        shares: [VirtioFSShareConfiguration],
        virtualCPUCount: Int,
        onWorkerLifecycle: @escaping @Sendable (VirtioFSWorkerLifecycleEvent) -> Void
    ) throws {
        guard shares.count <= DoryPCV1ABI.maximumFileSystemShareCount else {
            throw VMError.invalidConfiguration(
                "DoryPC supports at most \(DoryPCV1ABI.maximumFileSystemShareCount) directory shares"
            )
        }
        try VirtioFSShareConfiguration.validateWritableTopology(shares)
        self.shares = shares
        requestQueueCount = min(8, max(1, virtualCPUCount))
        self.onWorkerLifecycle = onWorkerLifecycle
    }

    deinit { stop() }

    func start() throws -> [any DoryPCPCIFunction] {
        try lock.withLock {
            guard generation == nil else {
                throw VMError.invalidConfiguration("DoryPC filesystem generation is already active")
            }
            let replacement = try makeGeneration()
            generation = replacement
            return replacement.devices.map { $0 as any DoryPCPCIFunction }
        }
    }

    func replaceAfterMachineReset() throws -> [any DoryPCPCIFunction] {
        try lock.withLock {
            generation?.retire()
            generation = nil
            let replacement = try makeGeneration()
            generation = replacement
            return replacement.devices.map { $0 as any DoryPCPCIFunction }
        }
    }

    func stop() {
        lock.withLock {
            generation?.retire()
            generation = nil
        }
    }

    private func makeGeneration() throws -> Generation {
        guard !shares.isEmpty else {
            throw VMError.invalidConfiguration("cannot create an empty DoryPC filesystem generation")
        }
        let worker = try DoryFilesystemWorkerLauncher.startBlocking(shares: shares)
        let lifecycleGate = LifecycleGate()
        worker.installLifecycleHandler { [lifecycleGate, onWorkerLifecycle] event in
            guard !lifecycleGate.isRetired else { return }
            onWorkerLifecycle(.failure("filesystem worker channel \(event)"))
        }
        do {
            let devices = try shares.enumerated().map { index, share in
                try DoryPCVirtioFSPCIDevice(
                    address: DoryPCV1ABI.fileSystemPCIAddresses[index],
                    initialBARAddress: DoryPCV1ABI.fileSystemBARAddresses[index],
                    tag: share.tag,
                    broker: worker.broker(for: share),
                    requestQueueCount: requestQueueCount,
                    onWorkerLifecycle: onWorkerLifecycle
                )
            }
            return Generation(
                worker: worker,
                devices: devices,
                lifecycleGate: lifecycleGate
            )
        } catch {
            lifecycleGate.retire()
            worker.client.invalidate()
            throw error
        }
    }
}
