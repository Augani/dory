import DoryHV
import DoryMachinePC
import DoryVirtio
import Foundation
import Testing
@testable import dory_hv

@Suite struct DoryPCGraphicsRecoveryTests {
  @Test func completedResetCallbackObservesClearedQueuesAndCannotReuseEarlierEpoch() throws {
    let transport = try DoryPCVirtioPCITransport(queueCount: 2, offeredFeatures: [.gpuVirgl])
    let recorder = PCGPUResetRecorder()
    transport.connectResetCompletedSink { epoch in
      recorder.record(epoch)
      #expect((try? transport.queueSnapshot(at: 0).enabled) == false)
      #expect((try? transport.queueSnapshot(at: 1).enabled) == false)
      #expect(transport.deviceState.snapshot().status.isEmpty)
    }
    for queue in 0..<2 {
      try transport.writeBAR(offset: 0x16, bytes: [UInt8(queue), 0])
      try transport.writeBAR(offset: 0x1C, bytes: [1, 0])
    }
    #expect(try transport.queueSnapshot(at: 0).enabled)
    let originalFeatures = transport.deviceState.offeredFeatures
    let originalEpoch = transport.deviceState.snapshot().lifecycleEpoch
    #expect(transport.withCompletedReset(expectedEpoch: originalEpoch) { true } == nil)
    #expect(transport.requestDeviceReset(expectedLifecycleEpoch: originalEpoch))
    #expect(!transport.requestDeviceReset(expectedLifecycleEpoch: originalEpoch))
    #expect(recorder.values.isEmpty)
    #expect(try transport.queueSnapshot(at: 0).enabled)
    try transport.writeBAR(offset: 0x14, bytes: [0])
    let resetEpoch = transport.deviceState.snapshot().lifecycleEpoch
    #expect(recorder.values == [resetEpoch])
    #expect(resetEpoch > originalEpoch)
    #expect(transport.deviceState.offeredFeatures == originalFeatures)
    #expect(transport.withCompletedReset(expectedEpoch: resetEpoch) { true } == true)
    #expect(!transport.requestDeviceReset(expectedLifecycleEpoch: originalEpoch))
    try transport.writeBAR(offset: 0x14, bytes: [0])
    #expect(transport.withCompletedReset(expectedEpoch: resetEpoch) { true } == nil)
  }

  @Test func softwareOrStoppingPCRejectsRendererRestartWithoutMutatingTransport() throws {
    let transport = try DoryPCVirtioPCITransport(queueCount: 2, offeredFeatures: [])
    let baseline = transport.deviceState.snapshot()
    #expect(!DoryPCMode.requestRendererRestart(
      transport: transport, authority: nil, replacementAvailable: true, stopping: false
    ))
    #expect(transport.deviceState.snapshot().status == baseline.status)
    #expect(transport.deviceState.snapshot().lifecycleEpoch == baseline.lifecycleEpoch)
    #expect(!transport.deviceState.snapshot().status.contains(.deviceNeedsReset))
  }
}

private final class PCGPUResetRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded = [UInt64]()
  var values: [UInt64] { lock.withLock { recorded } }
  func record(_ epoch: UInt64) { lock.withLock { recorded.append(epoch) } }
}
