#if arch(arm64)
import Darwin
import DoryExecutionContracts
import DoryNativeHVArm64
import DoryPhase0AHostNativeWorkload
import DoryPhase0AQualification
import Foundation

private let roundCount = 5
private let warmupCount = 2
private let sampleCount = 20
private let guestBase: UInt64 = 0x8000_0000
private let counterProgram: [UInt32] = [
    0xd292_d000, 0xf2a0_1300, 0xd280_0001, 0x9100_0421,
    0xf100_0400, 0x54ff_ffc1, 0xaa01_03e0, 0xd400_0002,
]

private enum MeasuredHarness: String, CaseIterable {
    case hostNative = "host-native"
    case minimalHV = "minimal-hv"
    case doryContract = "dory-contract"
}

private struct ThroughputObservation: Codable {
    var round: Int
    var sample: Int
    var harness: String
    var position: String
    var durationMicroseconds: Double
}

private struct ThroughputRound: Codable {
    var round: Int
    var hostNativeDurationMicroseconds: Phase0AMetricSummary
    var minimalHVDurationMicroseconds: Phase0AMetricSummary
    var doryContractDurationMicroseconds: Phase0AMetricSummary
    var doryOverheadPercent: Double
    var doryOfMinimalThroughputPercent: Double
    var minimalHVOfHostNativeThroughputPercent: Double
    var doryOfHostNativeThroughputPercent: Double
    var orchestrationBudgetPass: Bool
    var cpuThroughputBudgetPass: Bool
}

private struct ThroughputAggregate: Codable {
    var hostNativeRoundMedianDurationMicroseconds: Phase0AMetricSummary
    var minimalHVRoundMedianDurationMicroseconds: Phase0AMetricSummary
    var doryContractRoundMedianDurationMicroseconds: Phase0AMetricSummary
    var pairedRoundOverheadPercent: Phase0AMetricSummary
    var pairedRoundDoryOfMinimalThroughputPercent: Phase0AMetricSummary
    var pairedRoundMinimalHVOfHostNativeThroughputPercent: Phase0AMetricSummary
    var pairedRoundDoryOfHostNativeThroughputPercent: Phase0AMetricSummary
}

private struct ThroughputPolicy: Codable {
    var workload: String
    var guestLoopIterationsPerExecution: UInt64
    var roundCount: Int
    var warmupCountPerHarnessPerRound: Int
    var sampleCountPerHarnessPerRound: Int
    var clock: String
    var order: String
    var percentileMethod: String
    var inferenceUnit: String
    var orchestrationMedianOverheadBudgetPercent: Double
    var cpuThroughputOfHostNativeMedianBudgetPercent: Double
}

private struct ThroughputReceipt: Codable {
    var schema: String
    var startedHost: Phase0AHostQualificationReceipt
    var finishedHost: Phase0AHostQualificationReceipt
    var policy: ThroughputPolicy
    var observations: [ThroughputObservation]
    var rounds: [ThroughputRound]
    var aggregate: ThroughputAggregate
    var hostNativeCorrectExecutions: Int
    var minimalHVCorrectExecutions: Int
    var doryContractCorrectExecutions: Int
    var validityBlockers: [String]
    var orchestrationBudgetPass: Bool
    var cpuThroughputBudgetPass: Bool
    var referenceMatrixComplete: Bool
}

private enum ThroughputError: Error {
    case unexpectedHostCounter(UInt64)
    case unexpectedDoryExit
}

private func elapsedMicroseconds(_ operation: () throws -> Void) rethrows -> Double {
    let start = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
    try operation()
    return Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - start) / 1_000
}

@available(macOS 15.0, *)
private func runHostNativeWorkload() throws {
    let count = dory_phase0a_native_counter_loop(
        DoryNativeHVArm64MinimalHarness.counterLoopIterations
    )
    guard count == DoryNativeHVArm64MinimalHarness.counterLoopIterations else {
        throw ThroughputError.unexpectedHostCounter(count)
    }
}

private func rotatedHarnesses(offset: Int) -> [MeasuredHarness] {
    let harnesses = MeasuredHarness.allCases
    return (0..<harnesses.count).map { harnesses[(offset + $0) % harnesses.count] }
}

@available(macOS 15.0, *)
private func runMinimalHVWorkload() throws {
    _ = try DoryNativeHVArm64MinimalHarness.runCounterLoop()
}

@available(macOS 15.0, *)
private func runDoryContractWorkload(generation: UInt64) throws {
    let engine = try DoryNativeHVArm64Engine(executionGeneration: generation)
    var createdVCPU: DoryVCPU?
    let pageSize = UInt64(getpagesize())
    let memory = UnsafeMutableRawPointer.allocate(
        byteCount: Int(pageSize),
        alignment: Int(pageSize)
    )
    memory.initializeMemory(as: UInt8.self, repeating: 0, count: Int(pageSize))
    for (index, instruction) in counterProgram.enumerated() {
        memory.advanced(by: index * MemoryLayout<UInt32>.size).storeBytes(
            of: instruction.littleEndian,
            as: UInt32.self
        )
    }
    defer {
        if let createdVCPU { try? engine.destroyVCPU(createdVCPU) }
        try? engine.close()
        memory.deallocate()
    }

    let region = try DoryGuestMemoryRegion(
        id: 1,
        range: DoryGuestAddressRange(base: guestBase, byteCount: pageSize),
        pageSize: pageSize,
        permissions: [.read, .write, .execute],
        ownership: .executionEngine,
        mappingGeneration: 1,
        dirtyTracking: .disabled
    )
    try engine.mapMemory(
        try DoryGuestMemoryMapping(
            region: region,
            hostAddress: memory,
            hostByteCount: pageSize
        )
    )
    let vcpu = try engine.createVCPU(
        id: DoryVCPUIdentifier(0),
        initialState: DoryARM64ArchitecturalState.reset(programCounter: guestBase)
    )
    createdVCPU = vcpu
    let exit = try engine.run(vcpu, until: nil)
    guard
        case .hypercall(let number, let arguments, let token) = exit.reason,
        number == DoryNativeHVArm64MinimalHarness.counterLoopIterations,
        arguments.count == 7,
        arguments[0] == DoryNativeHVArm64MinimalHarness.counterLoopIterations,
        arguments.dropFirst().allSatisfy({ $0 == 0 })
    else {
        throw ThroughputError.unexpectedDoryExit
    }
    try engine.complete(token, with: .hypercallResult([UInt64.max]))
    try engine.destroyVCPU(vcpu)
    createdVCPU = nil
    try engine.unmapMemory(region.range, mappingGeneration: 1)
    try engine.close()
}

@available(macOS 15.0, *)
private func measure(_ harness: MeasuredHarness, generation: UInt64) throws -> Double {
    switch harness {
    case .hostNative:
        try elapsedMicroseconds(runHostNativeWorkload)
    case .minimalHV:
        try elapsedMicroseconds(runMinimalHVWorkload)
    case .doryContract:
        try elapsedMicroseconds {
            try runDoryContractWorkload(generation: generation)
        }
    }
}

@available(macOS 15.0, *)
private func runCampaign() throws -> ThroughputReceipt {
    let startedHost = try Phase0AHostCollector.collect()
    var generation: UInt64 = 1
    var observations: [ThroughputObservation] = []
    observations.reserveCapacity(roundCount * sampleCount * MeasuredHarness.allCases.count)
    var rounds: [ThroughputRound] = []
    rounds.reserveCapacity(roundCount)

    for roundIndex in 0..<roundCount {
        for warmup in 0..<warmupCount {
            for harness in rotatedHarnesses(offset: roundIndex + warmup) {
                switch harness {
                case .hostNative: try runHostNativeWorkload()
                case .minimalHV: try runMinimalHVWorkload()
                case .doryContract: try runDoryContractWorkload(generation: generation)
                }
            }
            generation += 1
        }

        var hostNativeSamples: [Double] = []
        var minimalSamples: [Double] = []
        var dorySamples: [Double] = []
        for sampleIndex in 0..<sampleCount {
            let order = rotatedHarnesses(offset: roundIndex + sampleIndex)
            var durations: [MeasuredHarness: Double] = [:]
            for (position, harness) in order.enumerated() {
                let duration = try measure(harness, generation: generation)
                durations[harness] = duration
                observations.append(
                    ThroughputObservation(
                        round: roundIndex + 1,
                        sample: sampleIndex + 1,
                        harness: harness.rawValue,
                        position: ["first", "second", "third"][position],
                        durationMicroseconds: duration
                    )
                )
            }
            hostNativeSamples.append(durations[.hostNative]!)
            minimalSamples.append(durations[.minimalHV]!)
            dorySamples.append(durations[.doryContract]!)
            generation += 1
        }

        let hostNativeSummary = try Phase0AMetricSummary(samples: hostNativeSamples)
        let minimalSummary = try Phase0AMetricSummary(samples: minimalSamples)
        let dorySummary = try Phase0AMetricSummary(samples: dorySamples)
        let overhead = ((dorySummary.median / minimalSummary.median) - 1) * 100
        let doryOfHost = (hostNativeSummary.median / dorySummary.median) * 100
        rounds.append(
            ThroughputRound(
                round: roundIndex + 1,
                hostNativeDurationMicroseconds: hostNativeSummary,
                minimalHVDurationMicroseconds: minimalSummary,
                doryContractDurationMicroseconds: dorySummary,
                doryOverheadPercent: overhead,
                doryOfMinimalThroughputPercent: (minimalSummary.median / dorySummary.median) * 100,
                minimalHVOfHostNativeThroughputPercent: (
                    hostNativeSummary.median / minimalSummary.median
                ) * 100,
                doryOfHostNativeThroughputPercent: doryOfHost,
                orchestrationBudgetPass: overhead <= 3,
                cpuThroughputBudgetPass: doryOfHost >= 95
            )
        )
    }

    let aggregate = ThroughputAggregate(
        hostNativeRoundMedianDurationMicroseconds: try Phase0AMetricSummary(
            samples: rounds.map(\.hostNativeDurationMicroseconds.median)
        ),
        minimalHVRoundMedianDurationMicroseconds: try Phase0AMetricSummary(
            samples: rounds.map(\.minimalHVDurationMicroseconds.median)
        ),
        doryContractRoundMedianDurationMicroseconds: try Phase0AMetricSummary(
            samples: rounds.map(\.doryContractDurationMicroseconds.median)
        ),
        pairedRoundOverheadPercent: try Phase0AMetricSummary(
            samples: rounds.map(\.doryOverheadPercent),
            allowsNegativeValues: true
        ),
        pairedRoundDoryOfMinimalThroughputPercent: try Phase0AMetricSummary(
            samples: rounds.map(\.doryOfMinimalThroughputPercent)
        ),
        pairedRoundMinimalHVOfHostNativeThroughputPercent: try Phase0AMetricSummary(
            samples: rounds.map(\.minimalHVOfHostNativeThroughputPercent)
        ),
        pairedRoundDoryOfHostNativeThroughputPercent: try Phase0AMetricSummary(
            samples: rounds.map(\.doryOfHostNativeThroughputPercent)
        )
    )
    let finishedHost = try Phase0AHostCollector.collect()
    var blockers: [String] = []
    if startedHost.host.bootSessionIdentifier != finishedHost.host.bootSessionIdentifier {
        blockers.append("boot session changed during campaign")
    }
    if startedHost.host.powerSource != finishedHost.host.powerSource {
        blockers.append("power source changed during campaign")
    }
    if startedHost.host.lowPowerModeEnabled || finishedHost.host.lowPowerModeEnabled {
        blockers.append("low-power mode was enabled")
    }
    if startedHost.host.thermalState != "nominal" || finishedHost.host.thermalState != "nominal" {
        blockers.append("thermal state was not nominal")
    }
    let orchestrationPass = blockers.isEmpty && aggregate.pairedRoundOverheadPercent.median <= 3
    let cpuThroughputPass = blockers.isEmpty
        && aggregate.pairedRoundDoryOfHostNativeThroughputPercent.median >= 95
    return ThroughputReceipt(
        schema: "dory.phase0a.hv-throughput-calibration@2",
        startedHost: startedHost,
        finishedHost: finishedHost,
        policy: ThroughputPolicy(
            workload: "ARM64 10,000,000-iteration add/subs/branch loop followed by HVC",
            guestLoopIterationsPerExecution: DoryNativeHVArm64MinimalHarness.counterLoopIterations,
            roundCount: roundCount,
            warmupCountPerHarnessPerRound: warmupCount,
            sampleCountPerHarnessPerRound: sampleCount,
            clock: "CLOCK_MONOTONIC_RAW",
            order: "position-balanced by round and sample parity",
            percentileMethod: "R-7 linear interpolation",
            inferenceUnit: "round median",
            orchestrationMedianOverheadBudgetPercent: 3,
            cpuThroughputOfHostNativeMedianBudgetPercent: 95
        ),
        observations: observations,
        rounds: rounds,
        aggregate: aggregate,
        hostNativeCorrectExecutions: roundCount * (warmupCount + sampleCount),
        minimalHVCorrectExecutions: roundCount * (warmupCount + sampleCount),
        doryContractCorrectExecutions: roundCount * (warmupCount + sampleCount),
        validityBlockers: blockers,
        orchestrationBudgetPass: orchestrationPass,
        cpuThroughputBudgetPass: cpuThroughputPass,
        referenceMatrixComplete: false
    )
}

if #available(macOS 15.0, *) {
    do {
        let receipt = try runCampaign()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        FileHandle.standardOutput.write(try encoder.encode(receipt))
        FileHandle.standardOutput.write(Data([0x0a]))
        exit(
            receipt.orchestrationBudgetPass && receipt.cpuThroughputBudgetPass
                ? EXIT_SUCCESS
                : 3
        )
    } catch {
        FileHandle.standardError.write(Data("dory Phase 0A HV throughput failed: \(error)\n".utf8))
        exit(EXIT_FAILURE)
    }
} else {
    FileHandle.standardError.write(Data("dory Phase 0A HV throughput requires macOS 15 or newer\n".utf8))
    exit(2)
}
#else
import Foundation

FileHandle.standardError.write(Data("dory Phase 0A HV throughput requires Apple silicon\n".utf8))
exit(2)
#endif
