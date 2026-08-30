#if arch(arm64)
import Darwin
import DoryExecutionContracts
import DoryNativeHVArm64
import DoryPhase0AQualification
import Foundation

private let warmupCount = 5
private let sampleCount = 30
private let guestBase: UInt64 = 0x8000_0000

private struct CampaignPolicy: Codable {
    var warmupCount: Int
    var sampleCountPerHarness: Int
    var order: String
    var clock: String
    var percentileMethod: String
    var orchestrationMedianOverheadBudgetPercent: Double
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
    var minimalHVLifecycleMicroseconds: Phase0AMetricSummary
    var doryContractLifecycleMicroseconds: Phase0AMetricSummary
    var medianOverheadPercent: Double
    var correctness: CorrectnessReceipt
    var contaminationBlockers: [String]
    var releaseBudgetPass: Bool
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
    for iteration in 0..<warmupCount {
        if iteration.isMultiple(of: 2) {
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
    for iteration in 0..<sampleCount {
        if iteration.isMultiple(of: 2) {
            minimalSamples.append(try elapsedMicroseconds(runMinimalHVWorkload))
            dorySamples.append(try elapsedMicroseconds {
                try runDoryContractWorkload(generation: generation)
            })
        } else {
            dorySamples.append(try elapsedMicroseconds {
                try runDoryContractWorkload(generation: generation)
            })
            minimalSamples.append(try elapsedMicroseconds(runMinimalHVWorkload))
        }
        generation += 1
    }

    let minimalSummary = try Phase0AMetricSummary(samples: minimalSamples)
    let dorySummary = try Phase0AMetricSummary(samples: dorySamples)
    let overhead = ((dorySummary.median / minimalSummary.median) - 1) * 100
    let finishedHost = try Phase0AHostCollector.collect()
    var contamination: [String] = []
    if startedHost.host.bootSessionIdentifier != finishedHost.host.bootSessionIdentifier {
        contamination.append("boot session changed during campaign")
    }
    if startedHost.host.powerSource != finishedHost.host.powerSource {
        contamination.append("power source changed during campaign")
    }
    if startedHost.host.lowPowerModeEnabled || finishedHost.host.lowPowerModeEnabled {
        contamination.append("low-power mode was enabled")
    }
    if startedHost.host.thermalState != "nominal" || finishedHost.host.thermalState != "nominal" {
        contamination.append("thermal state was not nominal")
    }
    let pass = contamination.isEmpty && overhead <= 3
    return CalibrationReceipt(
        schema: "dory.phase0a.hv-lifecycle-calibration@1",
        startedHost: startedHost,
        finishedHost: finishedHost,
        policy: CampaignPolicy(
            warmupCount: warmupCount,
            sampleCountPerHarness: sampleCount,
            order: "alternating AB/BA",
            clock: "CLOCK_MONOTONIC_RAW",
            percentileMethod: "R-7 linear interpolation",
            orchestrationMedianOverheadBudgetPercent: 3
        ),
        minimalHVLifecycleMicroseconds: minimalSummary,
        doryContractLifecycleMicroseconds: dorySummary,
        medianOverheadPercent: overhead,
        correctness: CorrectnessReceipt(
            minimalHVIterations: warmupCount + sampleCount,
            doryContractIterations: warmupCount + sampleCount,
            expectedRegisterValue: 42
        ),
        contaminationBlockers: contamination,
        releaseBudgetPass: pass,
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
        exit(receipt.releaseBudgetPass ? EXIT_SUCCESS : 3)
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
