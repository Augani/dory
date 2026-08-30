#if arch(arm64)
import Darwin
import DoryExecutionContracts
import DoryNativeHVArm64
import DoryPhase0AQualification
import Foundation

private let warmupCount = 20
private let sampleCount = 300
private let roundCount = 5
private let guestBase: UInt64 = 0x8000_0000

private struct CampaignPolicy: Codable {
    var roundCount: Int
    var warmupCountPerHarnessPerRound: Int
    var sampleCountPerHarnessPerRound: Int
    var order: String
    var clock: String
    var percentileMethod: String
    var inferenceUnit: String
    var orchestrationMedianOverheadBudgetPercent: Double
}

private struct LifecycleObservation: Codable {
    var round: Int
    var sample: Int
    var harness: String
    var position: String
    var durationMicroseconds: Double
}

private struct RoundReceipt: Codable {
    var round: Int
    var minimalHVLifecycleMicroseconds: Phase0AMetricSummary
    var doryContractLifecycleMicroseconds: Phase0AMetricSummary
    var medianOverheadPercent: Double
    var budgetPass: Bool
}

private struct AggregateReceipt: Codable {
    var minimalHVRoundMediansMicroseconds: Phase0AMetricSummary
    var doryContractRoundMediansMicroseconds: Phase0AMetricSummary
    var pairedRoundOverheadPercent: Phase0AMetricSummary
}

private struct CorrectnessReceipt: Codable {
    var minimalHVIterations: Int
    var doryContractIterations: Int
    var expectedRegisterValue: UInt64
}

private struct CalibrationReceipt: Codable {
    var schema: String
    var startedHost: Phase0AHostQualificationReceipt
    var finishedHost: Phase0AHostQualificationReceipt
    var policy: CampaignPolicy
    var observations: [LifecycleObservation]
    var rounds: [RoundReceipt]
    var aggregate: AggregateReceipt
    var correctness: CorrectnessReceipt
    var validityBlockers: [String]
    var orchestrationBudgetPass: Bool
    var referenceMatrixComplete: Bool
}

private enum CalibrationError: Error {
    case unexpectedDoryExit
}

private func elapsedMicroseconds(_ operation: () throws -> Void) rethrows -> Double {
    let start = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
    try operation()
    let finish = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
    return Double(finish - start) / 1_000
}

@available(macOS 15.0, *)
private func runMinimalHVWorkload() throws {
    _ = try DoryNativeHVArm64MinimalHarness.run()
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
    memory.storeBytes(of: UInt32(0xd280_0540).littleEndian, as: UInt32.self)
    memory.advanced(by: 4).storeBytes(of: UInt32(0xd400_0002).littleEndian, as: UInt32.self)
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
    guard case .hypercall(let number, _, let token) = exit.reason, number == 42 else {
        throw CalibrationError.unexpectedDoryExit
    }
    try engine.complete(token, with: .hypercallResult([UInt64.max]))
    try engine.destroyVCPU(vcpu)
    createdVCPU = nil
    try engine.unmapMemory(region.range, mappingGeneration: 1)
    try engine.close()
}

@available(macOS 15.0, *)
private func runCampaign() throws -> CalibrationReceipt {
    let startedHost = try Phase0AHostCollector.collect()
    var generation: UInt64 = 1
    var observations: [LifecycleObservation] = []
    observations.reserveCapacity(roundCount * sampleCount * 2)
    var rounds: [RoundReceipt] = []
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
        minimalSamples.reserveCapacity(sampleCount)
        dorySamples.reserveCapacity(sampleCount)
        for sampleIndex in 0..<sampleCount {
            let minimalFirst = (roundIndex + sampleIndex).isMultiple(of: 2)
            if minimalFirst {
                let minimal = try elapsedMicroseconds(runMinimalHVWorkload)
                let dory = try elapsedMicroseconds {
                    try runDoryContractWorkload(generation: generation)
                }
                minimalSamples.append(minimal)
                dorySamples.append(dory)
                observations.append(
                    LifecycleObservation(
                        round: roundIndex + 1,
                        sample: sampleIndex + 1,
                        harness: "minimal-hv",
                        position: "first",
                        durationMicroseconds: minimal
                    )
                )
                observations.append(
                    LifecycleObservation(
                        round: roundIndex + 1,
                        sample: sampleIndex + 1,
                        harness: "dory-contract",
                        position: "second",
                        durationMicroseconds: dory
                    )
                )
            } else {
                let dory = try elapsedMicroseconds {
                    try runDoryContractWorkload(generation: generation)
                }
                let minimal = try elapsedMicroseconds(runMinimalHVWorkload)
                dorySamples.append(dory)
                minimalSamples.append(minimal)
                observations.append(
                    LifecycleObservation(
                        round: roundIndex + 1,
                        sample: sampleIndex + 1,
                        harness: "dory-contract",
                        position: "first",
                        durationMicroseconds: dory
                    )
                )
                observations.append(
                    LifecycleObservation(
                        round: roundIndex + 1,
                        sample: sampleIndex + 1,
                        harness: "minimal-hv",
                        position: "second",
                        durationMicroseconds: minimal
                    )
                )
            }
            generation += 1
        }

        let minimalSummary = try Phase0AMetricSummary(samples: minimalSamples)
        let dorySummary = try Phase0AMetricSummary(samples: dorySamples)
        let overhead = ((dorySummary.median / minimalSummary.median) - 1) * 100
        rounds.append(
            RoundReceipt(
                round: roundIndex + 1,
                minimalHVLifecycleMicroseconds: minimalSummary,
                doryContractLifecycleMicroseconds: dorySummary,
                medianOverheadPercent: overhead,
                budgetPass: overhead <= 3
            )
        )
    }

    let aggregate = AggregateReceipt(
        minimalHVRoundMediansMicroseconds: try Phase0AMetricSummary(
            samples: rounds.map(\.minimalHVLifecycleMicroseconds.median)
        ),
        doryContractRoundMediansMicroseconds: try Phase0AMetricSummary(
            samples: rounds.map(\.doryContractLifecycleMicroseconds.median)
        ),
        pairedRoundOverheadPercent: try Phase0AMetricSummary(
            samples: rounds.map(\.medianOverheadPercent),
            allowsNegativeValues: true
        )
    )
    let finishedHost = try Phase0AHostCollector.collect()
    var validityBlockers: [String] = []
    if startedHost.host.bootSessionIdentifier != finishedHost.host.bootSessionIdentifier {
        validityBlockers.append("boot session changed during campaign")
    }
    if startedHost.host.powerSource != finishedHost.host.powerSource {
        validityBlockers.append("power source changed during campaign")
    }
    if startedHost.host.lowPowerModeEnabled || finishedHost.host.lowPowerModeEnabled {
        validityBlockers.append("low-power mode was enabled")
    }
    if startedHost.host.thermalState != "nominal" || finishedHost.host.thermalState != "nominal" {
        validityBlockers.append("thermal state was not nominal")
    }
    let pass = validityBlockers.isEmpty && aggregate.pairedRoundOverheadPercent.median <= 3
    return CalibrationReceipt(
        schema: "dory.phase0a.hv-lifecycle-calibration@2",
        startedHost: startedHost,
        finishedHost: finishedHost,
        policy: CampaignPolicy(
            roundCount: roundCount,
            warmupCountPerHarnessPerRound: warmupCount,
            sampleCountPerHarnessPerRound: sampleCount,
            order: "position-balanced by round and sample parity",
            clock: "CLOCK_MONOTONIC_RAW",
            percentileMethod: "R-7 linear interpolation",
            inferenceUnit: "round median",
            orchestrationMedianOverheadBudgetPercent: 3
        ),
        observations: observations,
        rounds: rounds,
        aggregate: aggregate,
        correctness: CorrectnessReceipt(
            minimalHVIterations: roundCount * (warmupCount + sampleCount),
            doryContractIterations: roundCount * (warmupCount + sampleCount),
            expectedRegisterValue: 42
        ),
        validityBlockers: validityBlockers,
        orchestrationBudgetPass: pass,
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
        FileHandle.standardError.write(Data("dory Phase 0A HV calibration failed: \(error)\n".utf8))
        exit(EXIT_FAILURE)
    }
} else {
    FileHandle.standardError.write(Data("dory Phase 0A HV calibration requires macOS 15 or newer\n".utf8))
    exit(2)
}
#else
import Foundation

FileHandle.standardError.write(Data("dory Phase 0A HV calibration requires Apple silicon\n".utf8))
exit(2)
#endif
