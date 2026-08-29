import Darwin
import Foundation
import Synchronization
import Testing
@testable import DoryHV

@Suite struct MachineHotPathTests {
    private final class PublishedPayload: @unchecked Sendable {
        var value = 0
    }

    @Test func vCPUStopSignalPublishesBeforeContendingReadersExit() {
        let signal = VCPUStopSignal()
        let payload = PublishedPayload()
        let observations = Mutex<[Int]>([])
        let readersReady = Atomic<Int>(0)
        let completion = DispatchGroup()
        let readerCount = 16

        for _ in 0..<readerCount {
            completion.enter()
            Thread.detachNewThread {
                readersReady.wrappingAdd(1, ordering: .releasing)
                while !signal.isRequested {
                    sched_yield()
                }
                let observed = payload.value
                observations.withLock { $0.append(observed) }
                completion.leave()
            }
        }

        while readersReady.load(ordering: .acquiring) != readerCount {
            sched_yield()
        }
        payload.value = 0xD0_12
        signal.request()

        #expect(completion.wait(timeout: .now() + 2) == .success)
        let snapshot = observations.withLock { $0 }
        #expect(snapshot.count == readerCount)
        #expect(snapshot.allSatisfy { $0 == 0xD0_12 })
    }

    @Test func vCPUStopSignalIsOneWayForMachineLifetime() {
        let signal = VCPUStopSignal()

        #expect(!signal.isRequested)
        signal.request()
        #expect(signal.isRequested)
        signal.request()
        #expect(signal.isRequested)
    }

    @Test func guestStopReasonsRetainExactTerminalEvidence() {
        #expect(GuestStopReason.powerOff.description == "guest requested power off")
        #expect(GuestStopReason.reset.description == "guest requested reset")
        #expect(
            GuestStopReason.crash("cpu3 failed: EIO").description
                == "guest crash: cpu3 failed: EIO"
        )
    }

    @Test func sustainedGuestWorkDoesNotClaimTheAppKitSchedulingClass() {
        #expect(RawHVSchedulingPolicy.revision == 1)
        #expect(RawHVSchedulingPolicy.vCPUThreadQualityOfService == .userInitiated)
        #expect(RawHVSchedulingPolicy.machineOwnerThreadQualityOfService == .userInitiated)
        #expect(RawHVSchedulingPolicy.machineOwnerThreadStackSize == 1 << 21)
        #expect(RawHVSchedulingPolicy.blockIOWorkerDispatchQoS.qosClass == .userInitiated)
        #expect(RawHVSchedulingPolicy.networkIOWorkerDispatchQoS.qosClass == .userInitiated)
        #expect(RawHVSchedulingPolicy.fileSystemWorkerDispatchQoS.qosClass == .userInitiated)
    }
}
