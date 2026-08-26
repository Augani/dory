import DoryFSWorkerContracts
import Foundation
@testable import DoryFSWorkerServiceCore
@testable import DoryHV

/// Data-only test double for the signed worker channel. It deliberately lives in the test target:
/// production DoryHV has no ServiceCore dependency or in-process filesystem fallback.
final class DoryFSWorkerTestChannel: DoryFSWorkerChannel, @unchecked Sendable {
    static let generation = try! DoryFSWorkerGeneration(rawValue: 1)
    static let capabilityID = try! DoryFSShareCapabilityID(
        rawValue: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    )

    let generation: DoryFSWorkerGeneration
    let capabilityID: DoryFSShareCapabilityID

    private struct PendingPublication {
        let correlationID: UInt64
        let opcode: FuseOpcode
        let response: [UInt8]
    }

    let server: FuseServer
    private let executeInline: Bool
    private let executionQueue = DispatchQueue(
        label: "dory-hv.tests.fs-worker",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let lock = NSLock()
    private var active = true
    private var pending = [UInt64: PendingPublication]()
    private var lifecycleHandlers = [@Sendable (DoryFSWorkerChannelEvent) -> Void]()
    private var _beforeRequestExecutionTestHook: (@Sendable () -> Void)?
    private var _requestExecutionCorrelationTestHook: (@Sendable (UInt64) -> Void)?

    var beforeRequestExecutionTestHook: (@Sendable () -> Void)? {
        get { lock.withLock { _beforeRequestExecutionTestHook } }
        set { lock.withLock { _beforeRequestExecutionTestHook = newValue } }
    }

    var requestExecutionCorrelationTestHook: (@Sendable (UInt64) -> Void)? {
        get { lock.withLock { _requestExecutionCorrelationTestHook } }
        set { lock.withLock { _requestExecutionCorrelationTestHook = newValue } }
    }

    init(
        hostFS: HostFS,
        executeInline: Bool = false,
        generation: DoryFSWorkerGeneration = DoryFSWorkerTestChannel.generation,
        capabilityID: DoryFSShareCapabilityID = DoryFSWorkerTestChannel.capabilityID
    ) {
        server = FuseServer(hostFS: hostFS)
        self.executeInline = executeInline
        self.generation = generation
        self.capabilityID = capabilityID
    }

    func installLifecycleHandler(
        _ handler: @escaping @Sendable (DoryFSWorkerChannelEvent) -> Void
    ) {
        let deliverImmediately = lock.withLock {
            guard active else { return true }
            lifecycleHandlers.append(handler)
            return false
        }
        if deliverImmediately { handler(.invalidated) }
    }

    func send(
        frame: Data,
        completion: @escaping @Sendable (Result<Data, DoryFSWorkerChannelFailure>) -> Void
    ) {
        let work: @Sendable () -> Void = { [self] in
            completion(handle(frame: frame))
        }
        if executeInline {
            work()
        } else {
            executionQueue.async(execute: work)
        }
    }

    func sendOneWay(frame: Data) {
        guard let decoded = try? DoryFSWorkerFrameCodec.decodeClientFrame(
            frame,
            maximumFrameBytes: DoryFSWorkerLimits.production.maximumFrameBytes
        ) else { return }

        switch decoded {
        case .interrupt(let interrupt):
            server.interrupt(requestUnique: interrupt.targetCorrelationID)
        case .commitPublication(let publication):
            acknowledge(publication, committed: true)
        case .discardPublication(let publication):
            acknowledge(publication, committed: false)
        case .invalidate:
            invalidate()
        case .execute, .drain:
            break
        }
    }

    func invalidate() {
        let transition = lock.withLock { () -> (
            [PendingPublication],
            [@Sendable (DoryFSWorkerChannelEvent) -> Void]
        )? in
            guard active else { return nil }
            active = false
            let publications = Array(pending.values)
            pending.removeAll(keepingCapacity: false)
            let handlers = lifecycleHandlers
            lifecycleHandlers.removeAll(keepingCapacity: false)
            return (publications, handlers)
        }
        guard let transition else { return }
        server.cancelAllRequests()
        for publication in transition.0 {
            server.rollbackUnpublishedResponse(
                opcode: publication.opcode,
                response: publication.response
            )
        }
        server.resetConnection()
        for handler in transition.1 { handler(.invalidated) }
    }

    private func handle(
        frame: Data
    ) -> Result<Data, DoryFSWorkerChannelFailure> {
        guard lock.withLock({ active }) else { return .failure(.invalidated) }
        let decoded: DoryFSWorkerClientFrame
        do {
            decoded = try DoryFSWorkerFrameCodec.decodeClientFrame(
                frame,
                maximumFrameBytes: DoryFSWorkerLimits.production.maximumFrameBytes
            )
        } catch {
            return .failure(.unavailable)
        }

        switch decoded {
        case .execute(let request):
            return execute(request)
        case .drain(let drain):
            guard lock.withLock({ active && pending.isEmpty }) else {
                return .failure(.unavailable)
            }
            return encode(.drained(DoryFSWorkerDrained(
                generation: drain.generation,
                shareCapabilityID: drain.shareCapabilityID
            )))
        case .interrupt, .invalidate, .commitPublication, .discardPublication:
            return .failure(.unavailable)
        }
    }

    private func execute(
        _ request: DoryFSWorkerRequest
    ) -> Result<Data, DoryFSWorkerChannelFailure> {
        let requestBytes = [UInt8](request.payload)
        guard request.generation == generation,
              request.shareCapabilityID == capabilityID,
              let header = try? FuseProtocol.decodeInHeader(requestBytes),
              header.unique == request.correlationID,
              let opcode = FuseOpcode(rawValue: header.opcode),
              opcode.workerOpcodeClass == request.opcodeClass else {
            return encodeReply(request, outcome: .rejected(.invalidRequest))
        }

        beforeRequestExecutionTestHook?()
        requestExecutionCorrelationTestHook?(request.correlationID)
        let response = server.handle(request: requestBytes)
        guard response.count <= Int(request.responseCapacity) else {
            server.rollbackUnpublishedResponse(opcode: opcode, response: response)
            return encodeReply(request, outcome: .rejected(.internalFailure))
        }

        let retained = lock.withLock {
            guard active, pending[request.requestID] == nil else { return false }
            pending[request.requestID] = PendingPublication(
                correlationID: request.correlationID,
                opcode: opcode,
                response: response
            )
            return true
        }
        guard retained else {
            server.rollbackUnpublishedResponse(opcode: opcode, response: response)
            return .failure(.invalidated)
        }
        return encodeReply(request, outcome: .completed(Data(response)))
    }

    private func acknowledge(
        _ publication: DoryFSWorkerPublication,
        committed: Bool
    ) {
        let retained = lock.withLock { () -> PendingPublication? in
            guard active,
                  publication.generation == generation,
                  publication.shareCapabilityID == capabilityID,
                  let value = pending[publication.requestID],
                  value.correlationID == publication.correlationID else { return nil }
            pending.removeValue(forKey: publication.requestID)
            return value
        }
        guard let retained else { return }
        if committed {
            if retained.opcode == FuseOpcode.initOp,
               let header = try? FuseProtocol.decodeOutHeader(retained.response),
               header.error == 0 {
                server.markFuseInitCompleted()
            }
        } else {
            server.rollbackUnpublishedResponse(
                opcode: retained.opcode,
                response: retained.response
            )
        }
    }

    private func encodeReply(
        _ request: DoryFSWorkerRequest,
        outcome: DoryFSWorkerReplyOutcome
    ) -> Result<Data, DoryFSWorkerChannelFailure> {
        do {
            return encode(.reply(try DoryFSWorkerReply(
                generation: request.generation,
                shareCapabilityID: request.shareCapabilityID,
                requestID: request.requestID,
                correlationID: request.correlationID,
                outcome: outcome
            )))
        } catch {
            return .failure(.unavailable)
        }
    }

    private func encode(
        _ frame: DoryFSWorkerServiceFrame
    ) -> Result<Data, DoryFSWorkerChannelFailure> {
        do {
            return .success(try DoryFSWorkerFrameCodec.encode(
                frame,
                maximumFrameBytes: DoryFSWorkerLimits.production.maximumFrameBytes
            ))
        } catch {
            return .failure(.unavailable)
        }
    }
}

extension VirtioFS {
    convenience init(
        tag: String,
        hostFS: HostFS,
        requestQueueCount: Int? = nil,
        notificationBacklogLimit: Int = 256,
        inlineRequests: Bool? = nil
    ) throws {
        let channel = DoryFSWorkerTestChannel(
            hostFS: hostFS,
            executeInline: inlineRequests ?? false
        )
        let broker = DoryFSWorkerBroker(
            shareCapabilityID: DoryFSWorkerTestChannel.capabilityID,
            generation: DoryFSWorkerTestChannel.generation,
            channel: channel
        )
        try self.init(
            tag: tag,
            broker: broker,
            requestQueueCount: requestQueueCount,
            notificationBacklogLimit: notificationBacklogLimit
        )
    }
}
