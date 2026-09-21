import DoryVMDisplayWireContracts
import Foundation
import Metal

public final class DoryVMDisplayBroker: @unchecked Sendable {
    public typealias RunnerValidator = @Sendable (
        _ machineID: String,
        _ operationID: String,
        _ processIdentifier: pid_t
    ) -> Bool

    struct FrameDelivery {
        let frame: Data
        let descriptors: [FileHandle]
        let sharedTextureHandle: MTLSharedTextureHandle?
    }

    private struct RunnerOwner: Equatable {
        let operationID: String
        let sessionID: UUID
        let processIdentifier: pid_t
    }

    private final class FrameAuthority {
        let descriptors: [FileHandle]
        let sharedTextureHandle: MTLSharedTextureHandle?

        private let lock = NSLock()
        private let reply: (Bool, String) -> Void
        private var completed = false
        private var consumerSessionID: UUID?

        init(
            descriptors: [FileHandle],
            sharedTextureHandle: MTLSharedTextureHandle?,
            reply: @escaping (Bool, String) -> Void
        ) {
            self.descriptors = descriptors
            self.sharedTextureHandle = sharedTextureHandle
            self.reply = reply
        }

        func deliver(to sessionID: UUID) {
            lock.withLock { consumerSessionID = sessionID }
        }

        func wasDelivered(to sessionID: UUID) -> Bool {
            lock.withLock { consumerSessionID == sessionID }
        }

        func complete(_ presented: Bool, detail: String) {
            let shouldReply = lock.withLock { () -> Bool in
                guard !completed else { return false }
                completed = true
                return true
            }
            if shouldReply { reply(presented, detail) }
        }
    }

    private let lock = NSLock()
    private let runnerValidator: RunnerValidator
    private var state = DoryVMDisplayRelayState<FrameAuthority>()
    private var runnerOwners: [String: RunnerOwner] = [:]
    private var cursors: [String: [UInt32: DoryVMDisplayCursor]] = [:]

    public init(runnerValidator: @escaping RunnerValidator) {
        self.runnerValidator = runnerValidator
    }

    func publish(
        frameData: Data,
        descriptors: [FileHandle],
        sharedTextureHandle: MTLSharedTextureHandle?,
        runnerSessionID: UUID,
        processIdentifier: pid_t,
        reply: @escaping (Bool, String) -> Void
    ) {
        let authority = FrameAuthority(
            descriptors: descriptors,
            sharedTextureHandle: sharedTextureHandle,
            reply: reply
        )
        do {
            let frame = try DoryVMDisplayFrameCodec.decode(frameData)
            try frame.validate(
                descriptorCount: descriptors.count,
                hasSharedTextureHandle: sharedTextureHandle != nil
            )
            guard runnerValidator(frame.machineID, frame.operationID, processIdentifier) else {
                throw DoryVMDisplayRelayError.staleRunner
            }
            let evicted = try lock.withLock { () throws -> [FrameAuthority] in
                let proposedOwner = RunnerOwner(
                    operationID: frame.operationID,
                    sessionID: runnerSessionID,
                    processIdentifier: processIdentifier
                )
                if let owner = runnerOwners[frame.machineID], owner != proposedOwner {
                    throw DoryVMDisplayRelayError.staleRunner
                }
                let result = try state.publish(frame: frame, authority: authority)
                runnerOwners[frame.machineID] = proposedOwner
                return result.evicted.map(\.authority)
            }
            for authority in evicted {
                authority.complete(false, detail: "frame-evicted")
            }
            // The successful reply remains open until the app acknowledges or the lease retires.
        } catch {
            authority.complete(false, detail: Self.detail(for: error))
        }
    }

    func nextFrame(
        machineID: String,
        scanoutID: UInt32,
        afterSequence: UInt64,
        applicationSessionID: UUID
    ) throws -> FrameDelivery? {
        let record = try lock.withLock {
            try state.nextFrame(
                machineID: machineID,
                scanoutID: scanoutID,
                afterSequence: afterSequence
            )
        }
        guard let record else { return nil }
        record.authority.deliver(to: applicationSessionID)
        do {
            return FrameDelivery(
                frame: try DoryVMDisplayFrameCodec.encode(record.frame),
                descriptors: record.authority.descriptors,
                sharedTextureHandle: record.authority.sharedTextureHandle
            )
        } catch {
            let retired = try? lock.withLock {
                try state.acknowledgeFrame(
                    machineID: machineID,
                    leaseID: record.frame.leaseID.rawValue
                )
            }
            retired?.authority.complete(false, detail: "frame-encoding-failed")
            throw error
        }
    }

    func acknowledgeFrame(
        machineID: String,
        leaseID: UUID,
        presented: Bool,
        applicationSessionID: UUID
    ) throws {
        let record = try lock.withLock {
            try state.acknowledgeFrame(
                machineID: machineID,
                leaseID: leaseID,
                authorizedBy: { $0.wasDelivered(to: applicationSessionID) }
            )
        }
        record.authority.complete(
            presented,
            detail: presented ? "" : "presentation-rejected"
        )
    }

    func publishCursor(
        cursorData: Data,
        runnerSessionID: UUID,
        processIdentifier: pid_t
    ) throws {
        let cursor = try DoryVMDisplayCursorCodec.decode(cursorData)
        guard runnerValidator(cursor.machineID, cursor.operationID, processIdentifier) else {
            throw DoryVMDisplayRelayError.staleRunner
        }
        try lock.withLock {
            let proposedOwner = RunnerOwner(
                operationID: cursor.operationID,
                sessionID: runnerSessionID,
                processIdentifier: processIdentifier
            )
            if let owner = runnerOwners[cursor.machineID], owner != proposedOwner {
                throw DoryVMDisplayRelayError.staleRunner
            }
            try state.registerRunner(
                machineID: cursor.machineID,
                operationID: cursor.operationID
            )
            if let current = cursors[cursor.machineID]?[cursor.scanoutID],
               cursor.sequence <= current.sequence {
                throw DoryVMDisplayRelayError.nonMonotonicSequence
            }
            runnerOwners[cursor.machineID] = proposedOwner
            cursors[cursor.machineID, default: [:]][cursor.scanoutID] = cursor
        }
    }

    func nextCursor(
        machineID: String,
        scanoutID: UInt32,
        afterSequence: UInt64
    ) throws -> Data? {
        let cursor = try lock.withLock { () throws -> DoryVMDisplayCursor? in
            guard runnerOwners[machineID] != nil else {
                throw DoryVMDisplayRelayError.unknownMachine
            }
            guard let cursor = cursors[machineID]?[scanoutID],
                  cursor.sequence > afterSequence else { return nil }
            return cursor
        }
        return try cursor.map(DoryVMDisplayCursorCodec.encode)
    }

    func send(commandData: Data) throws {
        let command = try DoryVMDisplayCommandCodec.decode(commandData)
        try lock.withLock { try state.send(command: command) }
    }

    func nextCommand(
        machineID: String,
        operationID: String,
        afterSequence: UInt64,
        runnerSessionID: UUID,
        processIdentifier: pid_t
    ) throws -> Data? {
        guard runnerValidator(machineID, operationID, processIdentifier) else {
            throw DoryVMDisplayRelayError.staleRunner
        }
        return try lock.withLock {
            guard runnerOwners[machineID] == RunnerOwner(
                operationID: operationID,
                sessionID: runnerSessionID,
                processIdentifier: processIdentifier
            ) else {
                throw DoryVMDisplayRelayError.staleRunner
            }
            return try state.nextCommand(
                machineID: machineID,
                operationID: operationID,
                afterSequence: afterSequence
            ).map(DoryVMDisplayCommandCodec.encode)
        }
    }

    func retireRunner(
        machineID: String,
        operationID: String,
        runnerSessionID: UUID,
        processIdentifier: pid_t
    ) throws {
        let retired = try lock.withLock { () throws -> [FrameAuthority] in
            guard runnerOwners[machineID] == RunnerOwner(
                operationID: operationID,
                sessionID: runnerSessionID,
                processIdentifier: processIdentifier
            ) else {
                throw DoryVMDisplayRelayError.staleRunner
            }
            let retired = try state.retireRunner(
                machineID: machineID,
                operationID: operationID
            )
            runnerOwners.removeValue(forKey: machineID)
            cursors.removeValue(forKey: machineID)
            return retired.frames.map(\.authority)
        }
        for authority in retired {
            authority.complete(false, detail: "runner-retired")
        }
    }

    func invalidateApplication(sessionID: UUID) {
        let reclaimed = lock.withLock {
            state.reclaimDelivered { $0.wasDelivered(to: sessionID) }.map(\.authority)
        }
        for authority in reclaimed {
            authority.complete(false, detail: "application-disconnected")
        }
    }

    func invalidateRunner(sessionID: UUID) {
        let retired = lock.withLock { () -> [FrameAuthority] in
            let machineIDs = runnerOwners.compactMap { machineID, owner in
                owner.sessionID == sessionID ? machineID : nil
            }.sorted()
            var authorities: [FrameAuthority] = []
            for machineID in machineIDs {
                guard let owner = runnerOwners.removeValue(forKey: machineID),
                      let result = try? state.retireRunner(
                          machineID: machineID,
                          operationID: owner.operationID
                      ) else {
                    continue
                }
                cursors.removeValue(forKey: machineID)
                authorities.append(contentsOf: result.frames.map(\.authority))
            }
            return authorities
        }
        for authority in retired {
            authority.complete(false, detail: "runner-disconnected")
        }
    }

    fileprivate static func detail(for error: Error) -> String {
        switch error {
        case DoryVMDisplayWireError.invalidMachineID: "invalid-machine"
        case DoryVMDisplayWireError.invalidOperationID: "invalid-operation"
        case DoryVMDisplayWireError.invalidFrameIdentity: "invalid-frame"
        case DoryVMDisplayWireError.invalidRectangle: "invalid-rectangle"
        case DoryVMDisplayWireError.invalidTransportAuthority: "invalid-authority"
        case DoryVMDisplayWireError.invalidCommand: "invalid-command"
        case DoryVMDisplayWireError.frameTooLarge: "frame-too-large"
        case DoryVMDisplayWireError.commandTooLarge: "command-too-large"
        case DoryVMDisplayWireError.cursorTooLarge: "cursor-too-large"
        case DoryVMDisplayWireError.invalidCursor: "invalid-cursor"
        case DoryVMDisplayWireError.nonCanonicalEncoding: "non-canonical"
        case DoryVMDisplayRelayError.staleRunner: "stale-runner"
        case DoryVMDisplayRelayError.nonMonotonicSequence: "non-monotonic"
        case DoryVMDisplayRelayError.duplicateLease: "duplicate-lease"
        case DoryVMDisplayRelayError.saturated: "relay-saturated"
        case DoryVMDisplayRelayError.unknownMachine: "unknown-machine"
        case DoryVMDisplayRelayError.unknownLease: "unknown-lease"
        default: "relay-failed"
        }
    }
}

public final class DoryVMDisplayListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let broker: DoryVMDisplayBroker

    public init(broker: DoryVMDisplayBroker) {
        self.broker = broker
    }

    public func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        guard let role = DorydXPCSecurity.configureDisplayConnection(connection) else {
            return false
        }
        let service = DoryVMDisplayConnectionService(
            broker: broker,
            role: role,
            processIdentifier: connection.processIdentifier
        )
        connection.exportedInterface = DoryVMDisplayBrokerXPCInterface.make()
        connection.exportedObject = service
        connection.invalidationHandler = { [weak service] in service?.invalidate() }
        connection.interruptionHandler = { [weak service] in service?.invalidate() }
        connection.resume()
        return true
    }
}

private final class DoryVMDisplayConnectionService:
    NSObject,
    DoryVMDisplayBrokerXPCProtocol
{
    private let broker: DoryVMDisplayBroker
    private let role: DoryVMDisplayPeerRole
    private let processIdentifier: pid_t
    private let sessionID = UUID()
    private let invalidationLock = NSLock()
    private var invalidated = false

    init(
        broker: DoryVMDisplayBroker,
        role: DoryVMDisplayPeerRole,
        processIdentifier: pid_t
    ) {
        self.broker = broker
        self.role = role
        self.processIdentifier = processIdentifier
    }

    func publishFrame(
        _ frame: Data,
        descriptors: [FileHandle],
        sharedTextureHandle: MTLSharedTextureHandle?,
        withReply reply: @escaping (Bool, String) -> Void
    ) {
        guard role == .runner || role == .development else {
            reply(false, "unauthorized-role")
            return
        }
        broker.publish(
            frameData: frame,
            descriptors: descriptors,
            sharedTextureHandle: sharedTextureHandle,
            runnerSessionID: sessionID,
            processIdentifier: processIdentifier,
            reply: reply
        )
    }

    func nextFrame(
        _ machineID: String,
        scanoutID: UInt32,
        afterSequence: UInt64,
        withReply reply: @escaping (Bool, Data, [FileHandle], MTLSharedTextureHandle?, String) -> Void
    ) {
        guard role == .application || role == .development else {
            reply(false, Data(), [], nil, "unauthorized-role")
            return
        }
        do {
            guard let delivery = try broker.nextFrame(
                machineID: machineID,
                scanoutID: scanoutID,
                afterSequence: afterSequence,
                applicationSessionID: sessionID
            ) else {
                reply(false, Data(), [], nil, "")
                return
            }
            reply(
                true,
                delivery.frame,
                delivery.descriptors,
                delivery.sharedTextureHandle,
                ""
            )
        } catch {
            reply(false, Data(), [], nil, DoryVMDisplayBroker.detail(for: error))
        }
    }

    func acknowledgeFrame(
        _ machineID: String,
        leaseID: String,
        presented: Bool,
        withReply reply: @escaping (Bool, String) -> Void
    ) {
        guard role == .application || role == .development,
              let parsedLeaseID = UUID(uuidString: leaseID),
              parsedLeaseID.uuidString.lowercased() == leaseID else {
            reply(false, "unauthorized-or-invalid-lease")
            return
        }
        do {
            try broker.acknowledgeFrame(
                machineID: machineID,
                leaseID: parsedLeaseID,
                presented: presented,
                applicationSessionID: sessionID
            )
            reply(true, "")
        } catch {
            reply(false, DoryVMDisplayBroker.detail(for: error))
        }
    }

    func publishCursor(
        _ cursor: Data,
        withReply reply: @escaping (Bool, String) -> Void
    ) {
        guard role == .runner || role == .development else {
            reply(false, "unauthorized-role")
            return
        }
        do {
            try broker.publishCursor(
                cursorData: cursor,
                runnerSessionID: sessionID,
                processIdentifier: processIdentifier
            )
            reply(true, "")
        } catch {
            reply(false, DoryVMDisplayBroker.detail(for: error))
        }
    }

    func nextCursor(
        _ machineID: String,
        scanoutID: UInt32,
        afterSequence: UInt64,
        withReply reply: @escaping (Bool, Data, String) -> Void
    ) {
        guard role == .application || role == .development else {
            reply(false, Data(), "unauthorized-role")
            return
        }
        do {
            guard let cursor = try broker.nextCursor(
                machineID: machineID,
                scanoutID: scanoutID,
                afterSequence: afterSequence
            ) else {
                reply(false, Data(), "")
                return
            }
            reply(true, cursor, "")
        } catch {
            reply(false, Data(), DoryVMDisplayBroker.detail(for: error))
        }
    }

    func sendCommand(
        _ command: Data,
        withReply reply: @escaping (Bool, String) -> Void
    ) {
        guard role == .application || role == .development else {
            reply(false, "unauthorized-role")
            return
        }
        do {
            try broker.send(commandData: command)
            reply(true, "")
        } catch {
            reply(false, DoryVMDisplayBroker.detail(for: error))
        }
    }

    func nextCommand(
        _ machineID: String,
        operationID: String,
        afterSequence: UInt64,
        withReply reply: @escaping (Bool, Data, String) -> Void
    ) {
        guard role == .runner || role == .development else {
            reply(false, Data(), "unauthorized-role")
            return
        }
        do {
            guard let command = try broker.nextCommand(
                machineID: machineID,
                operationID: operationID,
                afterSequence: afterSequence,
                runnerSessionID: sessionID,
                processIdentifier: processIdentifier
            ) else {
                reply(false, Data(), "")
                return
            }
            reply(true, command, "")
        } catch {
            reply(false, Data(), DoryVMDisplayBroker.detail(for: error))
        }
    }

    func retireRunner(
        _ machineID: String,
        operationID: String,
        withReply reply: @escaping (Bool, String) -> Void
    ) {
        guard role == .runner || role == .development else {
            reply(false, "unauthorized-role")
            return
        }
        do {
            try broker.retireRunner(
                machineID: machineID,
                operationID: operationID,
                runnerSessionID: sessionID,
                processIdentifier: processIdentifier
            )
            reply(true, "")
        } catch {
            reply(false, DoryVMDisplayBroker.detail(for: error))
        }
    }

    func invalidate() {
        let shouldInvalidate = invalidationLock.withLock { () -> Bool in
            guard !invalidated else { return false }
            invalidated = true
            return true
        }
        guard shouldInvalidate else { return }
        if role == .application || role == .development {
            broker.invalidateApplication(sessionID: sessionID)
        }
        if role == .runner || role == .development {
            broker.invalidateRunner(sessionID: sessionID)
        }
    }
}
