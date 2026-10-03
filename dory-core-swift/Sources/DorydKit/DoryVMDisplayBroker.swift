import DoryVMDisplayWireContracts
import Foundation
import Metal

/// Revocation is immediate; broker mutation checks this token while holding its own state lock.
/// Invalidation then drains that lock before retiring authorities, so a late XPC callback cannot
/// re-register a retired runner or deliver a new frame to a disconnected application.
final class DoryVMDisplayConnectionLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    var isActive: Bool { lock.withLock { active } }
    func revoke() { lock.withLock { active = false } }
}

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

    private struct ApplicationFrameCursor: Hashable {
        let machineID: String
        let scanoutID: UInt32
        let sessionID: UUID
    }

    enum CommandApplicationStatus: Equatable {
        case pending
        case applied
        case rejected(String)
    }

    private struct CommandApplicationRecord {
        let operationID: String
        let topologyScanoutCount: UInt32?
        let applicationSessionID: UUID?
        let applicationSequence: UInt64?
        var status: CommandApplicationStatus
        var delivered = false
        var releasedInputKeys: Set<InputKey> = []
        var cleanupInputKeys: Set<InputKey> = []
        var cleanupFocusLeaseID: String?
        var focusLeaseID: String?
        var focusActive: Bool?
    }

    private struct InputKey: Hashable {
        let endpoint: DoryVMDisplayInputEndpoint
        let code: UInt16
    }

    private struct MachineInputState {
        static let maximumApplicationCount = 16
        var lastApplicationSequences: [UUID: UInt64] = [:]
        var owners: [InputKey: Set<UUID>] = [:]
        // A delivered press may have taken effect even if its acknowledgement never arrives.
        // Only an acknowledged physical release (or runner retirement) discharges this debt.
        var possiblyHeld: [InputKey: UInt64] = [:]
        var pendingCleanup: [InputKey: UInt64] = [:]
        var cleanupRetryAfter: [InputKey: UInt64] = [:]
        var focusOwner: (sessionID: UUID, leaseID: String, sequence: UInt64)?
        var pendingFocusRevocations: Set<String> = []
        var lastConfirmedTopologySequence: UInt64 = 0
    }

    private final class FrameAuthority {
        let descriptors: [FileHandle]
        let sharedTextureHandle: MTLSharedTextureHandle?

        private let lock = NSLock()
        private let reply: (Bool, UInt64, String) -> Void
        private var completed = false
        private var consumerSessionID: UUID?

        init(
            descriptors: [FileHandle],
            sharedTextureHandle: MTLSharedTextureHandle?,
            reply: @escaping (Bool, UInt64, String) -> Void
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

        var deliveredSessionID: UUID? {
            lock.withLock { consumerSessionID }
        }

        func complete(
            _ presented: Bool,
            metalCommandBufferCompletionID: UInt64 = 0,
            detail: String
        ) {
            let shouldReply = lock.withLock { () -> Bool in
                guard !completed else { return false }
                completed = true
                return true
            }
            if shouldReply {
                reply(presented, metalCommandBufferCompletionID, detail)
            }
        }
    }

    private let lock = NSLock()
    private let runnerValidator: RunnerValidator
    private var state = DoryVMDisplayRelayState<FrameAuthority>()
    private var runnerOwners: [String: RunnerOwner] = [:]
    private var deliveredFrameOperations: [ApplicationFrameCursor: String] = [:]
    private var cursors: [String: [UInt32: DoryVMDisplayCursor]] = [:]
    private var commandApplications: [String: [UInt64: CommandApplicationRecord]] = [:]
    private var activeApplicationSessions: Set<UUID> = []
    private var inputStates: [String: MachineInputState] = [:]
    private var retiredFrameAcks: [String: [UUID: UUID]] = [:]
    private var retiredFrameOrder: [String: [UUID]] = [:]
    private var revokedTopologyLeases: [String: Set<UUID>] = [:]

    public init(runnerValidator: @escaping RunnerValidator) {
        self.runnerValidator = runnerValidator
    }

    func registerApplication(sessionID: UUID) throws {
        try lock.withLock {
            guard activeApplicationSessions.contains(sessionID)
                || activeApplicationSessions.count < 256 else {
                throw DoryVMDisplayRelayError.saturated
            }
            activeApplicationSessions.insert(sessionID)
        }
    }

    func publish(
        frameData: Data,
        descriptors: [FileHandle],
        sharedTextureHandle: MTLSharedTextureHandle?,
        runnerSessionID: UUID,
        processIdentifier: pid_t,
        connectionLifetime: DoryVMDisplayConnectionLifetime? = nil,
        reply: @escaping (Bool, UInt64, String) -> Void
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
                try requireActiveConnection(connectionLifetime)
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
        applicationSessionID: UUID,
        connectionLifetime: DoryVMDisplayConnectionLifetime? = nil
    ) throws -> FrameDelivery? {
        let cursor = ApplicationFrameCursor(
            machineID: machineID,
            scanoutID: scanoutID,
            sessionID: applicationSessionID
        )
        let record = try lock.withLock {
            try requireActiveConnection(connectionLifetime)
            let currentOperation = runnerOwners[machineID]?.operationID
            let effectiveAfterSequence = currentOperation != nil
                && deliveredFrameOperations[cursor] == currentOperation
                ? afterSequence : 0
            let record = try state.nextFrame(
                machineID: machineID,
                scanoutID: scanoutID,
                afterSequence: effectiveAfterSequence
            )
            if let record {
                record.authority.deliver(to: applicationSessionID)
                deliveredFrameOperations[cursor] = record.frame.operationID
            }
            return record
        }
        guard let record else { return nil }
        do {
            return FrameDelivery(
                frame: try DoryVMDisplayFrameCodec.encode(record.frame),
                descriptors: record.authority.descriptors,
                sharedTextureHandle: record.authority.sharedTextureHandle
            )
        } catch {
            let retired = try? lock.withLock {
                if deliveredFrameOperations[cursor] == record.frame.operationID {
                    deliveredFrameOperations.removeValue(forKey: cursor)
                }
                return try state.acknowledgeFrame(
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
        metalCommandBufferCompletionID: UInt64,
        applicationSessionID: UUID,
        connectionLifetime: DoryVMDisplayConnectionLifetime? = nil
    ) throws {
        guard presented == (metalCommandBufferCompletionID > 0) else {
            throw DoryVMDisplayRelayError.invalidAcknowledgement
        }
        let (record, topologyRevoked) = try lock.withLock { () throws -> (
            DoryVMDisplayRelayState<FrameAuthority>.FrameRecord, Bool
        ) in
            try requireActiveConnection(connectionLifetime)
            do {
                let record = try state.acknowledgeFrame(
                    machineID: machineID,
                    leaseID: leaseID,
                    authorizedBy: { $0.wasDelivered(to: applicationSessionID) }
                )
                let revoked = revokedTopologyLeases[machineID]?.remove(leaseID) != nil
                return (record, revoked)
            } catch DoryVMDisplayRelayError.unknownLease {
                guard retiredFrameAcks[machineID]?[leaseID] == applicationSessionID else {
                    throw DoryVMDisplayRelayError.unknownLease
                }
                retiredFrameAcks[machineID]?.removeValue(forKey: leaseID)
                retiredFrameOrder[machineID]?.removeAll { $0 == leaseID }
                throw DoryVMDisplayRelayError.retiredFrame
            }
        }
        if topologyRevoked {
            record.authority.complete(false, detail: "scanout-removed")
            throw DoryVMDisplayRelayError.retiredFrame
        }
        record.authority.complete(
            presented,
            metalCommandBufferCompletionID: metalCommandBufferCompletionID,
            detail: presented ? "" : "presentation-rejected"
        )
    }

    func publishCursor(
        cursorData: Data,
        runnerSessionID: UUID,
        processIdentifier: pid_t,
        connectionLifetime: DoryVMDisplayConnectionLifetime? = nil
    ) throws {
        let cursor = try DoryVMDisplayCursorCodec.decode(cursorData)
        guard runnerValidator(cursor.machineID, cursor.operationID, processIdentifier) else {
            throw DoryVMDisplayRelayError.staleRunner
        }
        try lock.withLock {
            try requireActiveConnection(connectionLifetime)
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
            if cursor.visible,
               !state.acceptsVisibleCursor(
                   machineID: cursor.machineID,
                   scanoutID: cursor.scanoutID
               ) {
                throw DoryVMDisplayRelayError.inactiveScanout
            }
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

    func send(
        commandData: Data, applicationSessionID: UUID,
        connectionLifetime: DoryVMDisplayConnectionLifetime? = nil
    ) throws {
        let command = try DoryVMDisplayCommandCodec.decode(commandData)
        try lock.withLock {
            try requireActiveConnection(connectionLifetime)
            guard activeApplicationSessions.contains(applicationSessionID) else {
                throw DoryVMDisplayRelayError.inactiveApplication
            }
            guard let owner = runnerOwners[command.machineID] else {
                throw DoryVMDisplayRelayError.unknownMachine
            }
            guard owner.operationID == command.operationID else {
                throw DoryVMDisplayRelayError.staleRunner
            }
            var input = inputStates[command.machineID] ?? MachineInputState()
            guard command.sequence > (input.lastApplicationSequences[applicationSessionID] ?? 0)
            else { throw DoryVMDisplayRelayError.nonMonotonicSequence }
            guard input.lastApplicationSequences[applicationSessionID] != nil
                || input.lastApplicationSequences.count < MachineInputState.maximumApplicationCount,
                (commandApplications[command.machineID]?.values.filter {
                    $0.applicationSessionID != nil && $0.status == .pending
                }.count ?? 0) < DoryVMDisplayRelayState<FrameAuthority>.maximumPendingCommands else {
                throw DoryVMDisplayRelayError.saturated
            }
            if command.kind == .focus, command.focused == true,
               input.pendingFocusRevocations.count >= MachineInputState.maximumApplicationCount {
                throw DoryVMDisplayRelayError.saturated
            }
            if command.kind == .focus, command.focused == true,
               !validFocusDeadline(command) {
                throw DoryVMDisplayWireError.invalidCommand
            }
            if command.kind == .focus, let leaseID = command.focusLeaseID {
                guard !input.pendingFocusRevocations.contains(leaseID),
                    !(input.focusOwner?.leaseID == leaseID
                    && input.focusOwner?.sessionID != applicationSessionID),
                    !(commandApplications[command.machineID]?.values.contains {
                        $0.focusLeaseID == leaseID && $0.applicationSessionID != nil
                            && $0.applicationSessionID != applicationSessionID
                    } ?? false) else {
                    throw DoryVMDisplayRelayError.inactiveApplication
                }
            }
            let queued = try state.enqueue(command: command)
            input.lastApplicationSequences[applicationSessionID] = command.sequence
            inputStates[command.machineID] = input
            commandApplications[command.machineID, default: [:]][queued.sequence] =
                CommandApplicationRecord(
                    operationID: command.operationID,
                    topologyScanoutCount: command.kind == .topology
                        ? command.topology.map { UInt32($0.count) } : nil,
                    applicationSessionID: applicationSessionID,
                    applicationSequence: command.sequence,
                    status: .pending,
                    focusLeaseID: command.focusLeaseID,
                    focusActive: command.focused
                )
            pruneCommandApplications(machineID: command.machineID)
        }
    }

    func acknowledgeCommand(
        machineID: String,
        operationID: String,
        sequence: UInt64,
        applied: Bool,
        detail: String,
        runnerSessionID: UUID,
        processIdentifier: pid_t,
        connectionLifetime: DoryVMDisplayConnectionLifetime? = nil
    ) throws {
        guard detail.utf8.count <= 256,
              !detail.contains("\0") else {
            throw DoryVMDisplayRelayError.invalidAcknowledgement
        }
        guard runnerValidator(machineID, operationID, processIdentifier) else {
            throw DoryVMDisplayRelayError.staleRunner
        }
        let retired = try lock.withLock { () throws -> [FrameAuthority] in
            try requireActiveConnection(connectionLifetime)
            guard runnerOwners[machineID] == RunnerOwner(
                operationID: operationID,
                sessionID: runnerSessionID,
                processIdentifier: processIdentifier
            ),
            var record = commandApplications[machineID]?[sequence],
            record.operationID == operationID,
            record.delivered else {
                throw DoryVMDisplayRelayError.unknownCommand
            }
            if record.status == .rejected("superseded-input-cleanup") { return [] }
            guard record.status == .pending else { throw DoryVMDisplayRelayError.unknownCommand }
            var retired: [FrameAuthority] = []
            if applied, let topologyScanoutCount = record.topologyScanoutCount,
               sequence > (inputStates[machineID]?.lastConfirmedTopologySequence ?? 0) {
                let frames = try state.applyTopology(
                    machineID: machineID,
                    operationID: operationID,
                    activeScanoutCount: topologyScanoutCount
                )
                for frame in frames.deliveredToRevoke {
                    revokedTopologyLeases[machineID, default: []].insert(
                        try frame.frame.leaseID.rawValue
                    )
                }
                for scanoutID in cursors[machineID]?.keys.filter({
                    $0 >= topologyScanoutCount
                }) ?? [] {
                    cursors[machineID]?.removeValue(forKey: scanoutID)
                }
                retired = frames.queuedRetired.map(\.authority)
                inputStates[machineID]?.lastConfirmedTopologySequence = sequence
            }
            record.status = applied ? .applied : .rejected(
                detail.isEmpty ? "runner-rejected-command" : detail
            )
            commandApplications[machineID]?[sequence] = record
            if var input = inputStates[machineID] {
                for key in record.cleanupInputKeys where input.pendingCleanup[key] == sequence {
                    input.pendingCleanup.removeValue(forKey: key)
                }
                if let leaseID = record.cleanupFocusLeaseID {
                    input.pendingFocusRevocations.remove(leaseID)
                }
                if applied, record.focusActive == false,
                   input.focusOwner?.leaseID == record.focusLeaseID,
                   input.focusOwner?.sessionID == record.applicationSessionID,
                   (input.focusOwner?.sequence ?? .max) < sequence {
                    input.focusOwner = nil
                }
                if applied {
                    for key in record.releasedInputKeys
                    where (input.possiblyHeld[key] ?? .max) <= sequence {
                        input.possiblyHeld.removeValue(forKey: key)
                        input.cleanupRetryAfter.removeValue(forKey: key)
                    }
                } else {
                    let now = DispatchTime.now().uptimeNanoseconds
                    let retry = now.addingReportingOverflow(100_000_000)
                    for key in record.releasedInputKeys {
                        input.cleanupRetryAfter[key] = retry.overflow ? .max : retry.partialValue
                    }
                }
                inputStates[machineID] = input
            }
            pruneCommandApplications(machineID: machineID)
            return retired
        }
        for authority in retired {
            authority.complete(false, detail: "scanout-removed")
        }
    }

    func commandStatus(
        machineID: String,
        operationID: String,
        sequence: UInt64,
        applicationSessionID: UUID? = nil
    ) -> (known: Bool, applied: Bool, detail: String) {
        lock.withLock {
            guard let record = commandApplications[machineID]?.values.first(where: {
                $0.operationID == operationID && $0.applicationSequence == sequence
                    && (applicationSessionID == nil || $0.applicationSessionID == applicationSessionID)
            }) else {
                return (false, false, "unknown-command")
            }
            switch record.status {
            case .pending:
                return (true, false, "pending")
            case .applied:
                return (true, true, "")
            case .rejected(let detail):
                return (true, false, detail)
            }
        }
    }

    func nextCommand(
        machineID: String,
        operationID: String,
        afterSequence: UInt64,
        runnerSessionID: UUID,
        processIdentifier: pid_t,
        connectionLifetime: DoryVMDisplayConnectionLifetime? = nil
    ) throws -> Data? {
        guard runnerValidator(machineID, operationID, processIdentifier) else {
            throw DoryVMDisplayRelayError.staleRunner
        }
        return try lock.withLock {
            try requireActiveConnection(connectionLifetime)
            guard runnerOwners[machineID] == RunnerOwner(
                operationID: operationID,
                sessionID: runnerSessionID,
                processIdentifier: processIdentifier
            ) else {
                throw DoryVMDisplayRelayError.staleRunner
            }
            scheduleInputCleanup(machineID: machineID, operationID: operationID)
            while var command = try state.nextCommand(
                machineID: machineID, operationID: operationID, afterSequence: afterSequence
            ) {
                guard var record = commandApplications[machineID]?[command.sequence] else {
                    throw DoryVMDisplayRelayError.unknownCommand
                }
                record.delivered = true
                if command.kind == .input {
                    prepareInputDelivery(command: &command, record: &record)
                    if command.inputEvents.isEmpty {
                        record.status = .applied
                        commandApplications[machineID]?[command.sequence] = record
                        pruneCommandApplications(machineID: machineID)
                        continue
                    }
                } else if command.kind == .focus,
                          let leaseID = command.focusLeaseID, var input = inputStates[machineID] {
                    if command.focused == true, let sessionID = record.applicationSessionID {
                        guard validFocusDeadline(command) else {
                            record.status = .rejected("expired-focus-lease")
                            commandApplications[machineID]?[command.sequence] = record
                            pruneCommandApplications(machineID: machineID)
                            continue
                        }
                        input.focusOwner = (sessionID, leaseID, command.sequence)
                    } else if let sessionID = record.applicationSessionID {
                        guard input.focusOwner?.leaseID == leaseID,
                              input.focusOwner?.sessionID == sessionID else {
                            record.status = .rejected("stale-focus-lease")
                            commandApplications[machineID]?[command.sequence] = record
                            pruneCommandApplications(machineID: machineID)
                            continue
                        }
                        // Retain the lease until revoke ACK: disconnect must still replace a
                        // delivered revoke whose runner callback never arrives.
                    }
                    inputStates[machineID] = input
                }
                commandApplications[machineID]?[command.sequence] = record
                return try DoryVMDisplayCommandCodec.encode(command)
            }
            return nil
        }
    }

    func retireRunner(
        machineID: String,
        operationID: String,
        runnerSessionID: UUID,
        processIdentifier: pid_t,
        connectionLifetime: DoryVMDisplayConnectionLifetime? = nil
    ) throws {
        let retired = try lock.withLock { () throws -> [FrameAuthority] in
            try requireActiveConnection(connectionLifetime)
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
            inputStates.removeValue(forKey: machineID)
            cursors.removeValue(forKey: machineID)
            retiredFrameAcks.removeValue(forKey: machineID)
            retiredFrameOrder.removeValue(forKey: machineID)
            revokedTopologyLeases.removeValue(forKey: machineID)
            rejectPendingCommands(
                machineID: machineID,
                operationID: operationID,
                detail: "runner-retired"
            )
            return retired.frames.map(\.authority)
        }
        for authority in retired {
            authority.complete(false, detail: "runner-retired")
        }
    }

    func retireCPUFrames(
        machineID: String,
        operationID: String,
        runnerSessionID: UUID,
        processIdentifier: pid_t,
        connectionLifetime: DoryVMDisplayConnectionLifetime? = nil
    ) throws {
        guard runnerValidator(machineID, operationID, processIdentifier) else {
            throw DoryVMDisplayRelayError.staleRunner
        }
        let retired = try lock.withLock { () throws -> [FrameAuthority] in
            try requireActiveConnection(connectionLifetime)
            let proposedOwner = RunnerOwner(
                operationID: operationID,
                sessionID: runnerSessionID,
                processIdentifier: processIdentifier
            )
            if let owner = runnerOwners[machineID], owner != proposedOwner {
                throw DoryVMDisplayRelayError.staleRunner
            }
            try state.registerRunner(machineID: machineID, operationID: operationID)
            let result = try state.retireCPUFrames(
                machineID: machineID,
                operationID: operationID
            )
            runnerOwners[machineID] = proposedOwner
            for frame in result.delivered {
                if let leaseID = try? frame.frame.leaseID.rawValue {
                    revokedTopologyLeases[machineID]?.remove(leaseID)
                }
            }
            rememberRetiredDeliveredFrames(machineID: machineID, frames: result.delivered)
            return (result.queued + result.delivered).map(\.authority)
        }
        for authority in retired {
            authority.complete(false, detail: "guest-reset")
        }
    }

    func retireCPUResource(
        machineID: String,
        operationID: String,
        resourceID: UInt32,
        throughGeneration: UInt64,
        runnerSessionID: UUID,
        processIdentifier: pid_t,
        connectionLifetime: DoryVMDisplayConnectionLifetime? = nil
    ) throws {
        guard resourceID != 0, throughGeneration != 0 else {
            throw DoryVMDisplayWireError.invalidFrameIdentity
        }
        guard runnerValidator(machineID, operationID, processIdentifier) else {
            throw DoryVMDisplayRelayError.staleRunner
        }
        let retired = try lock.withLock { () throws -> [FrameAuthority] in
            try requireActiveConnection(connectionLifetime)
            let proposedOwner = RunnerOwner(
                operationID: operationID,
                sessionID: runnerSessionID,
                processIdentifier: processIdentifier
            )
            if let owner = runnerOwners[machineID], owner != proposedOwner {
                throw DoryVMDisplayRelayError.staleRunner
            }
            try state.registerRunner(machineID: machineID, operationID: operationID)
            let result = try state.retireCPUResource(
                machineID: machineID,
                operationID: operationID,
                resourceID: resourceID,
                throughGeneration: throughGeneration
            )
            runnerOwners[machineID] = proposedOwner
            for frame in result.delivered {
                if let leaseID = try? frame.frame.leaseID.rawValue {
                    revokedTopologyLeases[machineID]?.remove(leaseID)
                }
            }
            rememberRetiredDeliveredFrames(machineID: machineID, frames: result.delivered)
            return (result.queued + result.delivered).map(\.authority)
        }
        for authority in retired {
            authority.complete(false, detail: "resource-retired")
        }
    }

    /// Must be called under the broker lock so revocation and retirement cannot be overtaken.
    private func requireActiveConnection(_ lifetime: DoryVMDisplayConnectionLifetime?) throws {
        guard lifetime?.isActive != false else {
            throw DoryVMDisplayRelayError.inactiveApplication
        }
    }

    private func validFocusDeadline(_ command: DoryVMDisplayCommand) -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        guard let deadline = command.focusExpiresAtUptimeNanoseconds, deadline > now else { return false }
        return deadline - now <= DoryVMDisplayCommand.maximumFocusLeaseLifetimeNanoseconds
    }

    private func rememberRetiredDeliveredFrames(
        machineID: String,
        frames: [DoryVMDisplayRelayState<FrameAuthority>.FrameRecord]
    ) {
        for frame in frames {
            guard let sessionID = frame.authority.deliveredSessionID,
                  let leaseID = try? frame.frame.leaseID.rawValue else { continue }
            retiredFrameAcks[machineID, default: [:]][leaseID] = sessionID
            retiredFrameOrder[machineID, default: []].append(leaseID)
        }
        let maximumRetiredAcks = 64
        while (retiredFrameOrder[machineID]?.count ?? 0) > maximumRetiredAcks {
            let oldest = retiredFrameOrder[machineID]!.removeFirst()
            retiredFrameAcks[machineID]?.removeValue(forKey: oldest)
        }
    }

    /// Update logical ownership at delivery, but keep physical-release debt until a runner ACK.
    /// This covers both a queued key-up cancelled on disconnect and a delivered key-up whose
    /// callback is lost. Keys held by another live display session must not be released.
    private func prepareInputDelivery(
        command: inout DoryVMDisplayCommand,
        record: inout CommandApplicationRecord
    ) {
        guard let endpoint = command.inputEndpoint else { return }
        var input = inputStates[command.machineID] ?? MachineInputState()
        var forwarded: [DoryVMDisplayInputEvent] = []
        for event in command.inputEvents {
            guard event.type == 1 else {
                forwarded.append(event)
                continue
            }
            let key = InputKey(endpoint: endpoint, code: event.code)
            if let sessionID = record.applicationSessionID {
                if event.value != 0 {
                    if let oldCleanup = input.pendingCleanup[key], oldCleanup < command.sequence {
                        // A cleanup delivered before this new press cannot discharge the new
                        // press. Retire only that version so lost old ACKs cannot block cleanup.
                        input.pendingCleanup.removeValue(forKey: key)
                        commandApplications[command.machineID]?[oldCleanup]?.cleanupInputKeys.remove(key)
                        if commandApplications[command.machineID]?[oldCleanup]?.cleanupInputKeys.isEmpty == true {
                            commandApplications[command.machineID]?[oldCleanup]?.status =
                                .rejected("superseded-input-cleanup")
                        }
                    }
                    input.owners[key, default: []].insert(sessionID)
                    input.possiblyHeld[key] = command.sequence
                    record.releasedInputKeys.remove(key)
                    forwarded.append(event)
                } else if input.owners[key]?.remove(sessionID) != nil {
                    if input.owners[key]?.isEmpty == true {
                        input.owners.removeValue(forKey: key)
                        forwarded.append(event)
                        record.releasedInputKeys.insert(key)
                    }
                }
            } else if input.owners[key]?.isEmpty ?? true {
                forwarded.append(event)
                record.releasedInputKeys.insert(key)
            } else {
                // A new owner pressed this key before the queued cleanup reached the runner.
                if input.pendingCleanup[key] == command.sequence {
                    input.pendingCleanup.removeValue(forKey: key)
                }
                record.cleanupInputKeys.remove(key)
            }
        }
        command.inputEvents = forwarded
        inputStates[command.machineID] = input
    }

    private func scheduleInputCleanup(machineID: String, operationID: String) {
        guard var input = inputStates[machineID],
              let operation = UUID(uuidString: operationID) else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let keys = input.possiblyHeld.keys.filter {
            (input.owners[$0]?.isEmpty ?? true) && input.pendingCleanup[$0] == nil
                && (input.cleanupRetryAfter[$0] ?? 0) <= now
        }
        for endpoint in [DoryVMDisplayInputEndpoint.keyboard, .absolutePointer, .relativePointer] {
            let endpointKeys = keys.filter { $0.endpoint == endpoint }.sorted { $0.code < $1.code }
            // Raw VirtIO input's 64-event production frame also includes the runner's SYN_REPORT.
            let maximumCleanupEvents = DoryVMDisplayCommand.maximumInputEventCount - 1
            for start in stride(from: 0, to: endpointKeys.count,
                                by: maximumCleanupEvents) {
                let chunk = Array(endpointKeys[start..<min(
                    start + maximumCleanupEvents, endpointKeys.count
                )])
                guard let command = try? DoryVMDisplayCommand.input(
                    machineID: machineID, operationID: operation, sequence: 1,
                    endpoint: endpoint,
                    events: chunk.map { .init(type: 1, code: $0.code, value: 0) }
                ), let queued = try? state.enqueue(command: command, isCleanup: true) else {
                    // Preserve the debt. Reserved capacity normally guarantees admission; a
                    // poll retries after backpressure without inventing a successful release.
                    inputStates[machineID] = input
                    return
                }
                let chunkKeys = Set(chunk)
                for key in chunkKeys { input.pendingCleanup[key] = queued.sequence }
                commandApplications[machineID, default: [:]][queued.sequence] =
                    CommandApplicationRecord(
                        operationID: operationID, topologyScanoutCount: nil,
                        applicationSessionID: nil, applicationSequence: nil,
                        status: .pending, cleanupInputKeys: chunkKeys
                    )
            }
        }
        inputStates[machineID] = input
        pruneCommandApplications(machineID: machineID)
    }

    private func revokeApplicationFocus(
        machineID: String, operationID: String, sessionID: UUID
    ) {
        guard var input = inputStates[machineID], let owner = input.focusOwner,
              owner.sessionID == sessionID,
              !input.pendingFocusRevocations.contains(owner.leaseID),
              let operation = UUID(uuidString: operationID),
              let leaseID = UUID(uuidString: owner.leaseID),
              let command = try? DoryVMDisplayCommand.focus(
                machineID: machineID, operationID: operation, sequence: 1,
                leaseID: leaseID, active: false
              ), let queued = try? state.enqueue(command: command, isCleanup: true) else { return }
        input.pendingFocusRevocations.insert(owner.leaseID)
        input.focusOwner = nil
        inputStates[machineID] = input
        commandApplications[machineID, default: [:]][queued.sequence] = CommandApplicationRecord(
            operationID: operationID, topologyScanoutCount: nil,
            applicationSessionID: nil, applicationSequence: nil, status: .pending,
            cleanupFocusLeaseID: owner.leaseID
        )
        // A matching runner-side lease also expires independently if this revoke cannot apply.
        pruneCommandApplications(machineID: machineID)
    }

    func invalidateApplication(sessionID: UUID) {
        let reclaimed = lock.withLock {
            activeApplicationSessions.remove(sessionID)
            for machineID in Array(inputStates.keys) {
                guard var input = inputStates[machineID],
                      let operationID = runnerOwners[machineID]?.operationID else { continue }
                input.lastApplicationSequences.removeValue(forKey: sessionID)
                for key in Array(input.owners.keys) {
                    input.owners[key]?.remove(sessionID)
                    if input.owners[key]?.isEmpty == true { input.owners.removeValue(forKey: key) }
                }
                inputStates[machineID] = input
                let queued = Set(commandApplications[machineID]?.compactMap { sequence, record in
                    record.applicationSessionID == sessionID && record.status == .pending
                        && !record.delivered ? sequence : nil
                } ?? [])
                for command in state.removeCommands(
                    machineID: machineID, operationID: operationID, sequences: queued
                ) {
                    commandApplications[machineID]?[command.sequence]?.status =
                        .rejected("application-disconnected")
                }
                scheduleInputCleanup(machineID: machineID, operationID: operationID)
                revokeApplicationFocus(
                    machineID: machineID, operationID: operationID, sessionID: sessionID
                )
            }
            deliveredFrameOperations = deliveredFrameOperations.filter {
                $0.key.sessionID != sessionID
            }
            for machineID in Array(retiredFrameAcks.keys) {
                let revoked = retiredFrameAcks[machineID]?.compactMap { leaseID, owner in
                    owner == sessionID ? leaseID : nil
                } ?? []
                for leaseID in revoked {
                    retiredFrameAcks[machineID]?.removeValue(forKey: leaseID)
                }
                retiredFrameOrder[machineID]?.removeAll { revoked.contains($0) }
            }
            let reclaimed = state.reclaimDelivered { $0.wasDelivered(to: sessionID) }
            for frame in reclaimed {
                if let leaseID = try? frame.frame.leaseID.rawValue {
                    revokedTopologyLeases[frame.frame.machineID]?.remove(leaseID)
                }
            }
            return reclaimed.map(\.authority)
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
                inputStates.removeValue(forKey: machineID)
                deliveredFrameOperations = deliveredFrameOperations.filter {
                    $0.key.machineID != machineID
                }
                retiredFrameAcks.removeValue(forKey: machineID)
                retiredFrameOrder.removeValue(forKey: machineID)
                revokedTopologyLeases.removeValue(forKey: machineID)
                rejectPendingCommands(
                    machineID: machineID,
                    operationID: owner.operationID,
                    detail: "runner-disconnected"
                )
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
        case DoryVMDisplayRelayError.inactiveScanout: "inactive-scanout"
        case DoryVMDisplayRelayError.saturated: "relay-saturated"
        case DoryVMDisplayRelayError.unknownMachine: "unknown-machine"
        case DoryVMDisplayRelayError.unknownLease: "unknown-lease"
        case DoryVMDisplayRelayError.retiredFrame: "retired-frame"
        case DoryVMDisplayRelayError.unknownCommand: "unknown-command"
        case DoryVMDisplayRelayError.invalidAcknowledgement: "invalid-acknowledgement"
        case DoryVMDisplayRelayError.inactiveApplication: "application-disconnected"
        default: "relay-failed"
        }
    }

    private func rejectPendingCommands(
        machineID: String,
        operationID: String,
        detail: String
    ) {
        guard var records = commandApplications[machineID] else { return }
        for sequence in records.keys {
            guard var record = records[sequence],
                  record.operationID == operationID,
                  record.status == .pending else { continue }
            record.status = .rejected(detail)
            records[sequence] = record
        }
        commandApplications[machineID] = records
    }

    private func pruneCommandApplications(machineID: String) {
        let maximumRecordCount = 768
        guard var records = commandApplications[machineID],
              records.count > maximumRecordCount else { return }
        let currentOperationID = runnerOwners[machineID]?.operationID
        let oldestFirst = records.keys.sorted {
            let leftRetired = records[$0]?.operationID != currentOperationID
            let rightRetired = records[$1]?.operationID != currentOperationID
            if leftRetired != rightRetired { return leftRetired }
            return $0 < $1
        }
        for sequence in oldestFirst where records.count > maximumRecordCount {
            guard records[sequence]?.status != .pending else { continue }
            records.removeValue(forKey: sequence)
        }
        commandApplications[machineID] = records
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
        guard let service = try? DoryVMDisplayConnectionService(
            broker: broker,
            role: role,
            processIdentifier: connection.processIdentifier
        ) else { return false }
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
    private let connectionLifetime = DoryVMDisplayConnectionLifetime()
    private let invalidationLock = NSLock()
    private var invalidated = false

    init(
        broker: DoryVMDisplayBroker,
        role: DoryVMDisplayPeerRole,
        processIdentifier: pid_t
    ) throws {
        self.broker = broker
        self.role = role
        self.processIdentifier = processIdentifier
        super.init()
        if role == .application || role == .development {
            try broker.registerApplication(sessionID: sessionID)
        }
    }

    deinit { invalidate() }

    func publishFrame(
        _ frame: Data,
        descriptors: [FileHandle],
        sharedTextureHandle: MTLSharedTextureHandle?,
        withReply reply: @escaping (Bool, UInt64, String) -> Void
    ) {
        guard role == .runner || role == .development else {
            reply(false, 0, "unauthorized-role")
            return
        }
        broker.publish(
            frameData: frame,
            descriptors: descriptors,
            sharedTextureHandle: sharedTextureHandle,
            runnerSessionID: sessionID,
            processIdentifier: processIdentifier,
            connectionLifetime: connectionLifetime,
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
                applicationSessionID: sessionID,
                connectionLifetime: connectionLifetime
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
        metalCommandBufferCompletionID: UInt64,
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
                metalCommandBufferCompletionID: metalCommandBufferCompletionID,
                applicationSessionID: sessionID,
                connectionLifetime: connectionLifetime
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
                processIdentifier: processIdentifier,
                connectionLifetime: connectionLifetime
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
            try broker.send(
                commandData: command, applicationSessionID: sessionID,
                connectionLifetime: connectionLifetime
            )
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
                processIdentifier: processIdentifier,
                connectionLifetime: connectionLifetime
            ) else {
                reply(false, Data(), "")
                return
            }
            reply(true, command, "")
        } catch {
            reply(false, Data(), DoryVMDisplayBroker.detail(for: error))
        }
    }

    func acknowledgeCommand(
        _ machineID: String,
        operationID: String,
        sequence: UInt64,
        applied: Bool,
        detail: String,
        withReply reply: @escaping (Bool, String) -> Void
    ) {
        guard role == .runner || role == .development else {
            reply(false, "unauthorized-role")
            return
        }
        do {
            try broker.acknowledgeCommand(
                machineID: machineID,
                operationID: operationID,
                sequence: sequence,
                applied: applied,
                detail: detail,
                runnerSessionID: sessionID,
                processIdentifier: processIdentifier,
                connectionLifetime: connectionLifetime
            )
            reply(true, "")
        } catch {
            reply(false, DoryVMDisplayBroker.detail(for: error))
        }
    }

    func commandStatus(
        _ machineID: String,
        operationID: String,
        sequence: UInt64,
        withReply reply: @escaping (Bool, Bool, String) -> Void
    ) {
        guard role == .application || role == .development else {
            reply(false, false, "unauthorized-role")
            return
        }
        let status = broker.commandStatus(
            machineID: machineID,
            operationID: operationID,
            sequence: sequence,
            applicationSessionID: sessionID
        )
        reply(status.known, status.applied, status.detail)
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
                processIdentifier: processIdentifier,
                connectionLifetime: connectionLifetime
            )
            reply(true, "")
        } catch {
            reply(false, DoryVMDisplayBroker.detail(for: error))
        }
    }

    func retireCPUFrames(
        _ machineID: String,
        operationID: String,
        withReply reply: @escaping (Bool, String) -> Void
    ) {
        guard role == .runner || role == .development else {
            reply(false, "unauthorized-role")
            return
        }
        do {
            try broker.retireCPUFrames(
                machineID: machineID,
                operationID: operationID,
                runnerSessionID: sessionID,
                processIdentifier: processIdentifier,
                connectionLifetime: connectionLifetime
            )
            reply(true, "")
        } catch {
            reply(false, DoryVMDisplayBroker.detail(for: error))
        }
    }

    func retireCPUResource(
        _ machineID: String,
        operationID: String,
        resourceID: UInt32,
        throughGeneration: UInt64,
        withReply reply: @escaping (Bool, String) -> Void
    ) {
        guard role == .runner || role == .development else {
            reply(false, "unauthorized-role")
            return
        }
        do {
            try broker.retireCPUResource(
                machineID: machineID,
                operationID: operationID,
                resourceID: resourceID,
                throughGeneration: throughGeneration,
                runnerSessionID: sessionID,
                processIdentifier: processIdentifier,
                connectionLifetime: connectionLifetime
            )
            reply(true, "")
        } catch {
            reply(false, DoryVMDisplayBroker.detail(for: error))
        }
    }

    func invalidate() {
        connectionLifetime.revoke()
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
