import Darwin
import DoryFSWorkerContracts
import DoryMachinePC
import DoryVirtio
import Foundation

/// Standard non-DAX virtio-fs over the DoryPC PCI transport. Every request is copied into
/// host-owned memory before worker admission; every response is published through the transport's
/// queue-generation fence so a reset can revoke late filesystem work without guest-memory access.
public final class DoryPCVirtioFSPCIDevice: DoryPCPCIFunction,
    DoryPCPCIMSIControllable, DoryPCPCIINTxControllable,
    DoryPCPCIBARMemoryDevice, DoryPCVirtioGuestMemoryConsumer, @unchecked Sendable
{
    private final class ResetRelay: @unchecked Sendable {
        weak var frontend: DoryPCVirtioFSPCIDevice?
        func reset() { frontend?.reset() }
    }

    public let pciFunction: DoryPCVirtioPCIFunction
    public let tag: String
    public let requestQueueCount: Int

    public var pciAddress: DoryPCPCIAddress { pciFunction.pciAddress }
    public var configurationFunction: DoryPCPCIConfigurationFunction {
        pciFunction.configurationFunction
    }
    public var barIndex: Int { pciFunction.barIndex }
    public var transport: DoryPCVirtioPCITransport { pciFunction.transport }

    private let broker: DoryFSWorkerBroker
    private let onWorkerLifecycle: @Sendable (VirtioFSWorkerLifecycleEvent) -> Void
    private let stateLock = NSLock()
    private var activeRequestCount = 0
    private var terminal = false
    private var connectionStarted = false
    private var fuseDestroyCommitted = false
    private let maximumInFlightRequests: Int

    public init(
        address: DoryPCPCIAddress,
        initialBARAddress: UInt64,
        tag: String,
        broker: DoryFSWorkerBroker,
        requestQueueCount: Int,
        maximumQueueSize: UInt16 = 256,
        onWorkerLifecycle: @escaping @Sendable (VirtioFSWorkerLifecycleEvent) -> Void = { _ in }
    ) throws {
        let tagBytes = Array(tag.utf8)
        guard !tagBytes.isEmpty, tagBytes.count < VirtioFS.tagByteCount else {
            throw VirtioFSError.invalidTag(tag)
        }
        guard (1...8).contains(requestQueueCount) else {
            throw DoryPCVirtioPCIError.invalidQueueCount(requestQueueCount)
        }
        self.tag = tag
        self.broker = broker
        self.requestQueueCount = requestQueueCount
        self.onWorkerLifecycle = onWorkerLifecycle
        maximumInFlightRequests = max(4, requestQueueCount * 4)
        var configuration = [UInt8](repeating: 0, count: VirtioFS.tagByteCount)
        configuration.replaceSubrange(0..<tagBytes.count, with: tagBytes)
        var queueCount = UInt32(requestQueueCount).littleEndian
        withUnsafeBytes(of: &queueCount) { configuration.append(contentsOf: $0) }
        let relay = ResetRelay()
        pciFunction = try .init(
            address: address,
            virtioDeviceID: 26,
            classCode: 0x018000,
            initialBARAddress: initialBARAddress,
            queueCount: requestQueueCount + 1,
            maximumQueueSize: maximumQueueSize,
            offeredFeatures: [.indirectDescriptors, .eventIndex],
            deviceConfiguration: configuration,
            onReset: { [relay] in relay.reset() }
        )
        relay.frontend = self
    }

    public func connectGuestMemory(_ memory: any DoryVirtioGuestMemory) {
        transport.connectDeferredQueueProcessor(
            memory: memory,
            canProcess: { [weak self] queue in
                self?.canProcess(queue: queue) ?? false
            },
            processor: { [weak self] queue, chain, memory, completion in
                guard let self else { return }
                try self.process(
                    queue: queue,
                    chain: chain,
                    memory: memory,
                    completion: completion
                )
            }
        )
    }

    public func shutdown() {
        reset()
    }

    /// Revokes this frontend because the complete DoryPC machine generation is being replaced.
    /// The runtime owns worker replacement, so this path does not classify an ordinary reboot as a
    /// filesystem failure or attempt to reuse the one-shot worker generation.
    public func retireForMachineReplacement() {
        stateLock.withLock { terminal = true }
    }

    public func readConfiguration(offset: Int, byteCount: Int) throws -> [UInt8] {
        try pciFunction.readConfiguration(offset: offset, byteCount: byteCount)
    }

    public func writeConfiguration(offset: Int, bytes: [UInt8]) throws {
        try pciFunction.writeConfiguration(offset: offset, bytes: bytes)
    }

    public func connectMSISink(
        _ sink: @escaping @Sendable (_ messageAddress: UInt64, _ messageData: UInt16) -> Bool
    ) {
        pciFunction.connectMSISink(sink)
    }

    public func readBAR(offset: UInt64, byteCount: Int) throws -> [UInt8] {
        try pciFunction.readBAR(offset: offset, byteCount: byteCount)
    }

    public func writeBAR(offset: UInt64, bytes: [UInt8]) throws {
        try pciFunction.writeBAR(offset: offset, bytes: bytes)
    }

    private func canProcess(queue: UInt16) -> Bool {
        guard Int(queue) <= requestQueueCount else { return false }
        return stateLock.withLock { !terminal && activeRequestCount < maximumInFlightRequests }
    }

    private func process(
        queue: UInt16,
        chain: DoryVirtioDescriptorChain,
        memory: any DoryVirtioGuestMemory,
        completion: DoryPCVirtioPCIDeferredCompletion
    ) throws {
        guard Int(queue) <= requestQueueCount else {
            throw DoryPCVirtioPCIError.invalidQueue(queue)
        }
        let requestLimit = broker.effectiveAdmissionLimits.maximumRequestBytes
        let readable = Int(min(chain.readableByteCount, UInt64(requestLimit)))
        let snapshotBytes = max(FuseInHeader.byteCount, readable)
        let request = try Self.readReadablePrefix(
            chain: chain,
            memory: memory,
            byteCount: min(snapshotBytes, Int(chain.readableByteCount))
        )
        let decision = VirtioFSRequestAdmission.inspect(
            chain: chain,
            request: request,
            queue: Int(queue),
            maximumRequestBytes: requestLimit,
            maximumResponseBytes: broker.effectiveAdmissionLimits.maximumResponseBytes
        )
        switch decision {
        case .reject(let rejected):
            _ = completion.publish(rejected.response)
        case .execute(let admitted):
            let accepted = stateLock.withLock { () -> Bool in
                guard !terminal, activeRequestCount < maximumInFlightRequests else { return false }
                activeRequestCount += 1
                connectionStarted = true
                return true
            }
            guard accepted else {
                _ = completion.publish(Self.errorResponse(unique: admitted.header.unique, errno: EAGAIN))
                return
            }
            Task { [weak self] in
                guard let self else { return }
                await self.execute(admitted, queue: queue, completion: completion)
            }
        }
    }

    private func execute(
        _ request: VirtioFSAdmittedRequest,
        queue: UInt16,
        completion: DoryPCVirtioPCIDeferredCompletion
    ) async {
        defer {
            stateLock.withLock { activeRequestCount -= 1 }
            transport.processQueue(queue)
        }
        let now = DispatchTime.now().uptimeNanoseconds
        let (deadline, overflow) = now.addingReportingOverflow(
            broker.limits.maximumOperationNanoseconds
        )
        guard !overflow else {
            fail("virtio-fs worker operation deadline overflow")
            _ = completion.publish(Self.errorResponse(unique: request.header.unique, errno: EIO))
            return
        }
        do {
            let execution = try await broker.execute(
                correlationID: request.header.unique,
                opcodeClass: request.opcode?.workerOpcodeClass ?? .control,
                request: Data(request.bytes),
                responseCapacity: request.maximumResponseBytes,
                deadlineUptimeNanoseconds: deadline
            )
            let normalized = Self.normalizedResponse(
                [UInt8](execution.response),
                for: request
            )
            let mayPublish = stateLock.withLock { !terminal }
            let published = mayPublish && completion.publish(normalized.bytes)
            if published && normalized.representsWorkerResponse {
                try await broker.commitPublication(execution.publication)
                if request.opcode == .destroy,
                   (try? FuseProtocol.decodeOutHeader(normalized.bytes).error) == 0 {
                    stateLock.withLock { fuseDestroyCommitted = true }
                }
            } else {
                try await broker.discardPublication(execution.publication)
            }
        } catch {
            _ = completion.publish(Self.errorResponse(unique: request.header.unique, errno: EIO))
            fail("filesystem worker request failed: \(error)")
        }
    }

    private func reset() {
        let state = stateLock.withLock { () -> (started: Bool, destroyed: Bool, first: Bool) in
            guard connectionStarted else { return (false, false, false) }
            let first = !terminal
            terminal = true
            return (connectionStarted, fuseDestroyCommitted, first)
        }
        guard state.first, state.started else { return }
        Task { [broker, onWorkerLifecycle] in
            if state.destroyed {
                do {
                    try await broker.completeConnectionTeardown()
                    onWorkerLifecycle(.connectionTeardown)
                } catch {
                    await broker.invalidate()
                    onWorkerLifecycle(.failure(
                        "filesystem worker connection teardown was not quiescent: \(error)"
                    ))
                }
            } else {
                await broker.invalidate()
                onWorkerLifecycle(.failure(
                    "filesystem worker generation invalidated by virtio-fs device reset"
                ))
            }
        }
    }

    private func fail(_ reason: String) {
        let shouldReport = stateLock.withLock { () -> Bool in
            guard !terminal else { return false }
            terminal = true
            return true
        }
        guard shouldReport else { return }
        Task { [broker, onWorkerLifecycle] in
            await broker.invalidate()
            onWorkerLifecycle(.failure(reason))
        }
    }

    private static func readReadablePrefix(
        chain: DoryVirtioDescriptorChain,
        memory: any DoryVirtioGuestMemory,
        byteCount: Int
    ) throws -> [UInt8] {
        guard byteCount >= 0 else { return [] }
        var result = [UInt8]()
        result.reserveCapacity(byteCount)
        for descriptor in chain.descriptors where !descriptor.deviceWillWrite
            && result.count < byteCount
        {
            let count = min(Int(descriptor.length), byteCount - result.count)
            result += try memory.read(at: descriptor.address, byteCount: count)
        }
        return result
    }

    private struct NormalizedResponse {
        let bytes: [UInt8]
        let representsWorkerResponse: Bool
    }

    private static func normalizedResponse(
        _ response: [UInt8],
        for request: VirtioFSAdmittedRequest
    ) -> NormalizedResponse {
        if !request.expectsReply {
            return .init(bytes: [], representsWorkerResponse: response.isEmpty)
        }
        if request.opcode == .interrupt, response.isEmpty {
            return .init(
                bytes: errorResponse(unique: request.header.unique, errno: 0),
                representsWorkerResponse: false
            )
        }
        guard response.count >= FuseOutHeader.byteCount,
              response.count <= request.maximumResponseBytes,
              let header = try? FuseProtocol.decodeOutHeader(response),
              Int(header.length) == response.count,
              header.unique == request.header.unique else {
            return .init(
                bytes: errorResponse(unique: request.header.unique, errno: EIO),
                representsWorkerResponse: false
            )
        }
        return .init(bytes: response, representsWorkerResponse: true)
    }

    private static func errorResponse(unique: UInt64, errno: Int32) -> [UInt8] {
        FuseProtocol.encodeOutHeader(FuseOutHeader(
            length: UInt32(FuseOutHeader.byteCount),
            error: errno == 0 ? 0 : -FuseProtocol.linuxErrno(errno),
            unique: unique
        ))
    }
}
