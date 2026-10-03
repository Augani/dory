import DoryVMDisplayWireContracts
import Foundation

enum DoryVMDisplayRelayError: Error, Equatable {
    case staleRunner
    case nonMonotonicSequence
    case duplicateLease
    case inactiveScanout
    case saturated
    case unknownMachine
    case unknownLease
    case retiredFrame
    case unknownCommand
    case invalidAcknowledgement
    case inactiveApplication
}

/// Synchronous state authority for the display XPC broker. File descriptors and Metal handles are
/// represented by the generic `Authority` value so queue, ordering, and lifetime behavior can be
/// tested without constructing platform graphics objects.
struct DoryVMDisplayRelayState<Authority> {
    static var maximumFramesPerScanout: Int { 2 }
    static var maximumPendingCommands: Int { 256 }
    // One cleanup packet per possible evdev key/button plus one focus revocation per input
    // session. This remains bounded even when many single-key disconnects precede a poll.
    static var maximumCleanupCommands: Int { 281 }
    static var maximumRetiredCPUResourceIDs: Int { 1_048_576 }

    struct FrameRecord {
        let frame: DoryVMDisplayFrame
        let authority: Authority
    }

    struct PublishResult {
        let evicted: [FrameRecord]
    }

    struct RetiredRunner {
        let frames: [FrameRecord]
        let commands: [DoryVMDisplayCommand]
    }

    struct RetiredCPUFrames {
        let queued: [FrameRecord]
        let delivered: [FrameRecord]
    }

    struct AppliedTopology {
        let queuedRetired: [FrameRecord]
        /// App-delivered frames stay live until their Metal completion acknowledges the lease.
        let deliveredToRevoke: [FrameRecord]
    }

    private struct ScanoutState {
        var lastPublishedSequence: UInt64 = 0
        var queued: [FrameRecord] = []
        var delivered: [UUID: FrameRecord] = [:]
    }

    private struct MachineState {
        let operationID: String
        var scanouts: [UInt32: ScanoutState] = [:]
        var minimumCPUEpoch: UInt64 = 1
        var retiredCPUResourceGenerations: [UInt32: UInt64] = [:]
        /// Set only after the runner confirms an app-requested topology change.
        var activeScanoutCount: UInt32?
        var lastCommandSequence: UInt64 = 0
        var commands: [DoryVMDisplayCommand] = []
        var cleanupCommandSequences: Set<UInt64> = []
    }

    private var machines: [String: MachineState] = [:]

    func acceptsVisibleCursor(machineID: String, scanoutID: UInt32) -> Bool {
        guard let machine = machines[machineID] else { return false }
        return machine.activeScanoutCount.map { scanoutID < $0 } ?? true
    }

    mutating func registerRunner(machineID: String, operationID: String) throws {
        guard !machineID.isEmpty,
              let parsedOperationID = UUID(uuidString: operationID),
              parsedOperationID.uuidString.lowercased() == operationID else {
            throw DoryVMDisplayRelayError.staleRunner
        }
        if let machine = machines[machineID] {
            guard machine.operationID == operationID else {
                throw DoryVMDisplayRelayError.staleRunner
            }
            return
        }
        machines[machineID] = MachineState(operationID: operationID)
    }

    mutating func publish(
        frame: DoryVMDisplayFrame,
        authority: Authority
    ) throws -> PublishResult {
        try frame.validate()
        var machine = machines[frame.machineID]
            ?? MachineState(operationID: frame.operationID)
        guard machine.operationID == frame.operationID else {
            throw DoryVMDisplayRelayError.staleRunner
        }
        if frame.transport == .cpuCopy {
            let lease = try DoryVMDisplayCPUFrameLeaseCodec.decode(frame.leasePayload)
            guard lease.cpuEpoch == machine.minimumCPUEpoch,
                  lease.resourceGeneration > (machine.retiredCPUResourceGenerations[
                    lease.resourceID] ?? 0) else {
                throw DoryVMDisplayRelayError.retiredFrame
            }
        }
        if let activeScanoutCount = machine.activeScanoutCount,
           frame.scanoutID >= activeScanoutCount {
            throw DoryVMDisplayRelayError.inactiveScanout
        }
        var scanout = machine.scanouts[frame.scanoutID] ?? ScanoutState()
        guard frame.sequence > scanout.lastPublishedSequence else {
            throw DoryVMDisplayRelayError.nonMonotonicSequence
        }
        let leaseID = try frame.leaseID.rawValue
        guard !machine.scanouts.values.contains(where: { state in
            state.queued.contains { (try? $0.frame.leaseID.rawValue) == leaseID }
                || state.delivered[leaseID] != nil
        }) else {
            throw DoryVMDisplayRelayError.duplicateLease
        }

        var evicted: [FrameRecord] = []
        let inFlightCount = scanout.queued.count + scanout.delivered.count
        if inFlightCount >= Self.maximumFramesPerScanout {
            guard !scanout.queued.isEmpty else {
                throw DoryVMDisplayRelayError.saturated
            }
            evicted.append(scanout.queued.removeFirst())
        }
        scanout.lastPublishedSequence = frame.sequence
        scanout.queued.append(FrameRecord(frame: frame, authority: authority))
        machine.scanouts[frame.scanoutID] = scanout
        machines[frame.machineID] = machine
        return PublishResult(evicted: evicted)
    }

    mutating func nextFrame(
        machineID: String,
        scanoutID: UInt32,
        afterSequence: UInt64
    ) throws -> FrameRecord? {
        guard var machine = machines[machineID] else {
            throw DoryVMDisplayRelayError.unknownMachine
        }
        guard var scanout = machine.scanouts[scanoutID],
              let index = scanout.queued.firstIndex(where: {
                  $0.frame.sequence > afterSequence
              }) else {
            return nil
        }
        let record = scanout.queued.remove(at: index)
        scanout.delivered[try record.frame.leaseID.rawValue] = record
        machine.scanouts[scanoutID] = scanout
        machines[machineID] = machine
        return record
    }

    mutating func acknowledgeFrame(
        machineID: String,
        leaseID: UUID,
        authorizedBy isAuthorized: (Authority) -> Bool = { _ in true }
    ) throws -> FrameRecord {
        guard var machine = machines[machineID] else {
            throw DoryVMDisplayRelayError.unknownMachine
        }
        for scanoutID in machine.scanouts.keys.sorted() {
            guard var scanout = machine.scanouts[scanoutID],
                  let record = scanout.delivered[leaseID] else {
                continue
            }
            guard isAuthorized(record.authority) else {
                throw DoryVMDisplayRelayError.unknownLease
            }
            scanout.delivered.removeValue(forKey: leaseID)
            machine.scanouts[scanoutID] = scanout
            machines[machineID] = machine
            return record
        }
        throw DoryVMDisplayRelayError.unknownLease
    }

    /// Guest reset invalidates the software framebuffer without retiring renderer-backed
    /// scanouts or the runner's operation identity. Preserve the sequence high-water mark so
    /// delayed old publications cannot be admitted after a replacement frame.
    mutating func retireCPUFrames(
        machineID: String,
        operationID: String
    ) throws -> RetiredCPUFrames {
        guard var machine = machines[machineID] else {
            throw DoryVMDisplayRelayError.unknownMachine
        }
        guard machine.operationID == operationID else {
            throw DoryVMDisplayRelayError.staleRunner
        }
        guard machine.minimumCPUEpoch < .max else {
            throw DoryVMDisplayRelayError.saturated
        }
        machine.minimumCPUEpoch += 1
        var queued = [FrameRecord]()
        var delivered = [FrameRecord]()
        for scanoutID in machine.scanouts.keys.sorted() {
            guard var scanout = machine.scanouts[scanoutID] else { continue }
            queued.append(contentsOf: scanout.queued.filter {
                $0.frame.transport == .cpuCopy
            })
            scanout.queued.removeAll { $0.frame.transport == .cpuCopy }
            for leaseID in scanout.delivered.keys.sorted(by: {
                $0.uuidString < $1.uuidString
            }) {
                guard let frame = scanout.delivered[leaseID],
                      frame.frame.transport == .cpuCopy else { continue }
                scanout.delivered.removeValue(forKey: leaseID)
                delivered.append(frame)
            }
            machine.scanouts[scanoutID] = scanout
        }
        machines[machineID] = machine
        return RetiredCPUFrames(queued: queued, delivered: delivered)
    }

    /// Unref of a copied framebuffer retires only that resource incarnation. Keep a bounded
    /// tombstone so a publication already in flight cannot resurrect it with a newer sequence.
    mutating func retireCPUResource(
        machineID: String,
        operationID: String,
        resourceID: UInt32,
        throughGeneration: UInt64
    ) throws -> RetiredCPUFrames {
        guard resourceID != 0, throughGeneration != 0 else {
            throw DoryVMDisplayWireError.invalidFrameIdentity
        }
        guard var machine = machines[machineID] else {
            throw DoryVMDisplayRelayError.unknownMachine
        }
        guard machine.operationID == operationID else {
            throw DoryVMDisplayRelayError.staleRunner
        }
        if machine.retiredCPUResourceGenerations[resourceID] == nil,
           machine.retiredCPUResourceGenerations.count >= Self.maximumRetiredCPUResourceIDs {
            throw DoryVMDisplayRelayError.saturated
        }
        machine.retiredCPUResourceGenerations[resourceID] = max(
            machine.retiredCPUResourceGenerations[resourceID] ?? 0,
            throughGeneration
        )
        var queued = [FrameRecord]()
        var delivered = [FrameRecord]()
        for scanoutID in machine.scanouts.keys.sorted() {
            guard var scanout = machine.scanouts[scanoutID] else { continue }
            queued.append(contentsOf: scanout.queued.filter {
                Self.isCPUResourceFrame($0.frame, resourceID: resourceID,
                    throughGeneration: throughGeneration)
            })
            scanout.queued.removeAll {
                Self.isCPUResourceFrame($0.frame, resourceID: resourceID,
                    throughGeneration: throughGeneration)
            }
            for leaseID in scanout.delivered.keys.sorted(by: {
                $0.uuidString < $1.uuidString
            }) {
                guard let frame = scanout.delivered[leaseID],
                      Self.isCPUResourceFrame(frame.frame, resourceID: resourceID,
                        throughGeneration: throughGeneration) else { continue }
                scanout.delivered.removeValue(forKey: leaseID)
                delivered.append(frame)
            }
            machine.scanouts[scanoutID] = scanout
        }
        machines[machineID] = machine
        return RetiredCPUFrames(queued: queued, delivered: delivered)
    }

    private static func isCPUResourceFrame(
        _ frame: DoryVMDisplayFrame,
        resourceID: UInt32,
        throughGeneration: UInt64
    ) -> Bool {
        guard frame.transport == .cpuCopy,
              let lease = try? DoryVMDisplayCPUFrameLeaseCodec.decode(frame.leasePayload)
        else { return false }
        return lease.resourceID == resourceID
            && lease.resourceGeneration <= throughGeneration
    }

    /// A confirmed hot-unplug retires queued leases and marks delivered leases for retirement
    /// after the app's Metal completion. Keep the sequence high-water mark across hot-add.
    mutating func applyTopology(
        machineID: String,
        operationID: String,
        activeScanoutCount: UInt32
    ) throws -> AppliedTopology {
        guard (1...DoryVMDisplayFrame.maximumScanoutCount).contains(activeScanoutCount),
              var machine = machines[machineID] else {
            throw DoryVMDisplayRelayError.unknownMachine
        }
        guard machine.operationID == operationID else {
            throw DoryVMDisplayRelayError.staleRunner
        }
        var queued = [FrameRecord]()
        var delivered = [FrameRecord]()
        for scanoutID in machine.scanouts.keys.sorted() where scanoutID >= activeScanoutCount {
            guard var scanout = machine.scanouts[scanoutID] else { continue }
            queued.append(contentsOf: scanout.queued)
            scanout.queued.removeAll()
            for leaseID in scanout.delivered.keys.sorted(by: {
                $0.uuidString < $1.uuidString
            }) {
                if let frame = scanout.delivered[leaseID] {
                    delivered.append(frame)
                }
            }
            machine.scanouts[scanoutID] = scanout
        }
        machine.activeScanoutCount = activeScanoutCount
        machines[machineID] = machine
        return AppliedTopology(queuedRetired: queued, deliveredToRevoke: delivered)
    }

    mutating func send(command: DoryVMDisplayCommand) throws {
        try command.validate()
        guard var machine = machines[command.machineID] else {
            throw DoryVMDisplayRelayError.unknownMachine
        }
        guard machine.operationID == command.operationID else {
            throw DoryVMDisplayRelayError.staleRunner
        }
        guard command.sequence > machine.lastCommandSequence else {
            throw DoryVMDisplayRelayError.nonMonotonicSequence
        }
        guard machine.commands.count < Self.maximumPendingCommands else {
            throw DoryVMDisplayRelayError.saturated
        }
        machine.lastCommandSequence = command.sequence
        machine.commands.append(command)
        machines[command.machineID] = machine
    }

    mutating func nextCommand(
        machineID: String,
        operationID: String,
        afterSequence: UInt64
    ) throws -> DoryVMDisplayCommand? {
        guard var machine = machines[machineID] else {
            throw DoryVMDisplayRelayError.unknownMachine
        }
        guard machine.operationID == operationID else {
            throw DoryVMDisplayRelayError.staleRunner
        }
        guard let index = machine.commands.firstIndex(where: {
            $0.sequence > afterSequence
        }) else {
            return nil
        }
        let command = machine.commands.remove(at: index)
        machine.cleanupCommandSequences.remove(command.sequence)
        machines[machineID] = machine
        return command
    }

    /// Application sequence numbers are replay identities, not runner queue positions. A broker
    /// sequence prevents another window (or broker-generated releases) from colliding with them.
    mutating func enqueue(
        command: DoryVMDisplayCommand,
        isCleanup: Bool = false
    ) throws -> DoryVMDisplayCommand {
        try command.validate()
        guard var machine = machines[command.machineID] else {
            throw DoryVMDisplayRelayError.unknownMachine
        }
        guard machine.operationID == command.operationID else {
            throw DoryVMDisplayRelayError.staleRunner
        }
        let cleanupCount = machine.cleanupCommandSequences.count
        guard isCleanup
            ? cleanupCount < Self.maximumCleanupCommands
            : machine.commands.count - cleanupCount < Self.maximumPendingCommands else {
            throw DoryVMDisplayRelayError.saturated
        }
        let reserved = isCleanup ? UInt64(0) : UInt64(Self.maximumCleanupCommands)
        guard machine.lastCommandSequence < UInt64.max - reserved else {
            throw DoryVMDisplayRelayError.saturated
        }
        var queued = command
        queued.sequence = machine.lastCommandSequence + 1
        machine.lastCommandSequence = queued.sequence
        machine.commands.append(queued)
        if isCleanup { machine.cleanupCommandSequences.insert(queued.sequence) }
        machines[command.machineID] = machine
        return queued
    }

    mutating func removeCommands(
        machineID: String,
        operationID: String,
        sequences: Set<UInt64>
    ) -> [DoryVMDisplayCommand] {
        guard var machine = machines[machineID], machine.operationID == operationID else {
            return []
        }
        let removed = machine.commands.filter { sequences.contains($0.sequence) }
        machine.commands.removeAll { sequences.contains($0.sequence) }
        machine.cleanupCommandSequences.subtract(sequences)
        machines[machineID] = machine
        return removed
    }

    mutating func retireRunner(
        machineID: String,
        operationID: String
    ) throws -> RetiredRunner {
        guard let machine = machines[machineID] else {
            throw DoryVMDisplayRelayError.unknownMachine
        }
        guard machine.operationID == operationID else {
            throw DoryVMDisplayRelayError.staleRunner
        }
        machines.removeValue(forKey: machineID)
        let frames = machine.scanouts.keys.sorted().flatMap { scanoutID -> [FrameRecord] in
            guard let scanout = machine.scanouts[scanoutID] else { return [] }
            return scanout.queued + scanout.delivered.keys.sorted {
                $0.uuidString < $1.uuidString
            }.compactMap { scanout.delivered[$0] }
        }
        return RetiredRunner(frames: frames, commands: machine.commands)
    }

    mutating func reclaimDelivered(
        where shouldReclaim: (Authority) -> Bool
    ) -> [FrameRecord] {
        var reclaimed: [FrameRecord] = []
        for machineID in machines.keys.sorted() {
            guard var machine = machines[machineID] else { continue }
            for scanoutID in machine.scanouts.keys.sorted() {
                guard var scanout = machine.scanouts[scanoutID] else { continue }
                for leaseID in scanout.delivered.keys.sorted(by: {
                    $0.uuidString < $1.uuidString
                }) {
                    guard let record = scanout.delivered[leaseID],
                          shouldReclaim(record.authority) else {
                        continue
                    }
                    scanout.delivered.removeValue(forKey: leaseID)
                    reclaimed.append(record)
                }
                machine.scanouts[scanoutID] = scanout
            }
            machines[machineID] = machine
        }
        return reclaimed
    }
}
