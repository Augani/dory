#if arch(arm64)
import Darwin
import DoryExecutionContracts
import DoryNativeHVArm64
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

private struct ThroughputObservation: Codable {
    var round: Int
    var sample: Int
    var harness: String
    var position: String
    var durationMicroseconds: Double
}

private struct ThroughputRound: Codable {
    var round: Int
    var minimalHVDurationMicroseconds: Phase0AMetricSummary
    var doryContractDurationMicroseconds: Phase0AMetricSummary
    var doryOverheadPercent: Double
    var doryOfMinimalThroughputPercent: Double
    var orchestrationBudgetPass: Bool
}

private struct ThroughputAggregate: Codable {
    var minimalHVRoundMedianDurationMicroseconds: Phase0AMetricSummary
    var doryContractRoundMedianDurationMicroseconds: Phase0AMetricSummary
    var pairedRoundOverheadPercent: Phase0AMetricSummary
    var pairedRoundDoryOfMinimalThroughputPercent: Phase0AMetricSummary
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
}

private struct ThroughputReceipt: Codable {
    var schema: String
    var startedHost: Phase0AHostQualificationReceipt
    var finishedHost: Phase0AHostQualificationReceipt
    var policy: ThroughputPolicy
    var observations: [ThroughputObservation]
    var rounds: [ThroughputRound]
    var aggregate: ThroughputAggregate
    var minimalHVCorrectExecutions: Int
    var doryContractCorrectExecutions: Int
    var validityBlockers: [String]
    var orchestrationBudgetPass: Bool
    var hostNativeCPUThroughputQualified: Bool
    var referenceMatrixComplete: Bool
}

private enum ThroughputError: Error {
    case unexpectedDoryExit
}

private func elapsedMicroseconds(_ operation: () throws -> Void) rethrows -> Double {
    let start = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
    try operation()
    return Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - start) / 1_000
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
private func runCampaign() throws -> ThroughputReceipt {
    let startedHost = try Phase0AHostCollector.collect()
    var generation: UInt64 = 1
    var observations: [ThroughputObservation] = []
    observations.reserveCapacity(roundCount * sampleCount * 2)
    var rounds: [ThroughputRound] = []
    rounds.reserveCapacity(roundCount)

    for roundIndex in 0..<roundCount {
        for warmup in 0..<warmupCount {
            if (roundIndex + warmup).isMultiple(of: 2) {
                try runMinimalHVWorkload()
                try runDoryContractWorkload(generation: generation)
            } else {
                try runDoryContractWorkload(generation: generation)
                try runMinimalHVWorkload()
            }
            generation += 1
        }

        var minimalSamples: [Double] = []
        var dorySamples: [Double] = []
        for sampleIndex in 0..<sampleCount {
            let minimalFirst = (roundIndex + sampleIndex).isMultiple(of: 2)
            let minimal: Double
            let dory: Double
            if minimalFirst {
                minimal = try elapsedMicroseconds(runMinimalHVWorkload)
                dory = try elapsedMicroseconds {
                    try runDoryContractWorkload(generation: generation)
                }
            } else {
                dory = try elapsedMicroseconds {
                    try runDoryContractWorkload(generation: generation)
                }
                minimal = try elapsedMicroseconds(runMinimalHVWorkload)
            }
            minimalSamples.append(minimal)
            dorySamples.append(dory)
            observations.append(
                ThroughputObservation(
                    round: roundIndex + 1,
                    sample: sampleIndex + 1,
                    harness: "minimal-hv",
                    position: minimalFirst ? "first" : "second",
                    durationMicroseconds: minimal
                )
            )
            observations.append(
                ThroughputObservation(
                    round: roundIndex + 1,
                    sample: sampleIndex + 1,
                    harness: "dory-contract",
                    position: minimalFirst ? "second" : "first",
                    durationMicroseconds: dory
                )
            )
            generation += 1
        }

        let minimalSummary = try Phase0AMetricSummary(samples: minimalSamples)
        let dorySummary = try Phase0AMetricSummary(samples: dorySamples)
        let overhead = ((dorySummary.median / minimalSummary.median) - 1) * 100
        rounds.append(
            ThroughputRound(
                round: roundIndex + 1,
                minimalHVDurationMicroseconds: minimalSummary,
                doryContractDurationMicroseconds: dorySummary,
                doryOverheadPercent: overhead,
                doryOfMinimalThroughputPercent: (minimalSummary.median / dorySummary.median) * 100,
                orchestrationBudgetPass: overhead <= 3
            )
        )
    }

    let aggregate = ThroughputAggregate(
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
    let pass = blockers.isEmpty && aggregate.pairedRoundOverheadPercent.median <= 3
    return ThroughputReceipt(
        schema: "dory.phase0a.hv-throughput-calibration@1",
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
            orchestrationMedianOverheadBudgetPercent: 3
        ),
        observations: observations,
        rounds: rounds,
        aggregate: aggregate,
        minimalHVCorrectExecutions: roundCount * (warmupCount + sampleCount),
        doryContractCorrectExecutions: roundCount * (warmupCount + sampleCount),
        validityBlockers: blockers,
        orchestrationBudgetPass: pass,
        hostNativeCPUThroughputQualified: false,
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
        exit(receipt.orchestrationBudgetPass ? EXIT_SUCCESS : 3)
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
