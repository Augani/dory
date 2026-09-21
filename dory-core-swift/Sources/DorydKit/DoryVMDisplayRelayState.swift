import DoryVMDisplayWireContracts
import Foundation

enum DoryVMDisplayRelayError: Error, Equatable {
    case staleRunner
    case nonMonotonicSequence
    case duplicateLease
    case saturated
    case unknownMachine
    case unknownLease
}

/// Synchronous state authority for the display XPC broker. File descriptors and Metal handles are
/// represented by the generic `Authority` value so queue, ordering, and lifetime behavior can be
/// tested without constructing platform graphics objects.
struct DoryVMDisplayRelayState<Authority> {
    static var maximumFramesPerScanout: Int { 2 }
    static var maximumPendingCommands: Int { 256 }

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

    private struct ScanoutState {
        var lastPublishedSequence: UInt64 = 0
        var queued: [FrameRecord] = []
        var delivered: [UUID: FrameRecord] = [:]
    }

    private struct MachineState {
        let operationID: String
        var scanouts: [UInt32: ScanoutState] = [:]
        var lastCommandSequence: UInt64 = 0
        var commands: [DoryVMDisplayCommand] = []
    }

    private var machines: [String: MachineState] = [:]

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
        leaseID: UUID
    ) throws -> FrameRecord {
        guard var machine = machines[machineID] else {
            throw DoryVMDisplayRelayError.unknownMachine
        }
        for scanoutID in machine.scanouts.keys.sorted() {
            guard var scanout = machine.scanouts[scanoutID],
                  let record = scanout.delivered.removeValue(forKey: leaseID) else {
                continue
            }
            machine.scanouts[scanoutID] = scanout
            machines[machineID] = machine
            return record
        }
        throw DoryVMDisplayRelayError.unknownLease
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
        machines[machineID] = machine
        return command
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
}
