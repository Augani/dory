import DoryDBTX86
import Foundation
import Testing

@testable import DoryMachinePC

@Suite struct DoryPCExecutionConfigurationTests {
  @Test func interpreterSnapshotDoesNotClaimUnusedJITOptions() throws {
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 * 1_024 * 1_024,
      interpreter: .init(profile: .intelCompatibleV1),
      baselineJITTier1Enabled: true, baselineJITRawTargetPredictionOptions: .all,
      clockSource: .hostMonotonic, instrumentationEnabled: true)
    let configuration = machine.executionConfiguration
    #expect(configuration.cpuProfile == .intelCompatibleV1)
    #expect(configuration.memoryBytes == machine.memoryByteCount)
    #expect(configuration.processorCount == machine.processorCount)
    #expect(configuration.tier == .interpreter)
    #expect(configuration.baselineJITTier1Enabled == nil)
    #expect(configuration.optimizingJITTier1Enabled == nil)
    #expect(configuration.rawTargetPredictionOptionBits == nil)
    #expect(configuration.baselineCodeByteLimitsByProcessor.isEmpty)
    #expect(configuration.optimizingCodeByteLimitsByProcessor.isEmpty)
    #expect(configuration.optimizingWarmupDispatches == nil)
    #expect(configuration.clockKind == .hostMonotonic)
    #expect(configuration.instrumentationEnabled)
    #expect(try JSONDecoder().decode(DoryPCExecutionConfiguration.self,
      from: JSONEncoder().encode(configuration)) == configuration)
  }

  @Test func baselineSnapshotUsesExecutorLimitsAfterPerOwnerClamping() throws {
    // Construct only: no guest instructions or raw predictors execute in this fixture.
    let predictors: DoryARM64RawTargetPredictionOptions = [.legacyDirectChain, .shadowReturnStack]
    let machine = try DoryPCDirectKernelMachine(memoryBytes: 2 * 1_024 * 1_024,
      processorCount: 3, executionTier: .baselineJIT,
      baselineJITMaximumCodeBytes: 10_000, baselineJITTier1Enabled: false,
      baselineJITRawTargetPredictionOptions: predictors, jitWriteCoherencePolicy: .checkedCallbacks)
    let configuration = machine.executionConfiguration
    #expect(configuration.tier == machine.executionTier)
    #expect(configuration.processorCount == 3)
    #expect(configuration.baselineJITTier1Enabled == false)
    #expect(configuration.optimizingJITTier1Enabled == nil)
    #expect(configuration.rawTargetPredictionOptionBits == predictors.rawValue)
    #expect(configuration.baselineCodeByteLimitsByProcessor == [4_096, 4_096, 4_096])
    #expect(configuration.optimizingCodeByteLimitsByProcessor.isEmpty)
    #expect(configuration.jitWriteCoherencePolicy == .checkedCallbacks)
    #expect(configuration.clockKind == .deterministic)
    #expect(!configuration.instrumentationEnabled)
  }

  @Test func optimizingSnapshotRecordsBothActualCachePartitionsAndTier1Selections() throws {
    let machine = try DoryPCDirectKernelMachine(memoryBytes: 2 * 1_024 * 1_024,
      processorCount: 2, executionTier: .optimizingJIT,
      baselineJITMaximumCodeBytes: 131_072, baselineJITTier1Enabled: true,
      optimizingJITWarmupDispatches: 3)
    let configuration = machine.executionConfiguration
    #expect(configuration.tier == .optimizingJIT)
    #expect(configuration.baselineCodeByteLimitsByProcessor == [16_384, 16_384])
    #expect(configuration.optimizingCodeByteLimitsByProcessor == [49_152, 49_152])
    #expect(configuration.baselineJITTier1Enabled == true)
    #expect(configuration.optimizingJITTier1Enabled == false)
    #expect(configuration.optimizingWarmupDispatches == 3)
    #expect(configuration.rawTargetPredictionOptionBits == 0)
    #expect(try JSONDecoder().decode(DoryPCExecutionConfiguration.self,
      from: JSONEncoder().encode(configuration)) == configuration)
  }
}
