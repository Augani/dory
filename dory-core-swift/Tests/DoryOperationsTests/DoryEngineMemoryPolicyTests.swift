import DoryOperations
import Testing

@Suite struct DoryEngineMemoryPolicyTests {
    private let gibibyte: UInt64 = 1_024 * 1_024 * 1_024

    @Test func rawHVMemoryEndsAtTheGuestPhysicalAddressLimit() {
        let maximumBytes = UInt64(DoryEngineMemoryPolicy.maximumMemoryMB) * 1_024 * 1_024

        #expect(DoryEngineMemoryPolicy.maximumMemoryMB == 62 * 1_024)
        #expect(
            DoryEngineMemoryPolicy.guestRAMBaseBytes + maximumBytes
                == DoryEngineMemoryPolicy.guestPhysicalAddressLimitBytes
        )
    }

    @Test func highMemoryHostsNeverReceiveAnUnrepresentableDefaultOrMaximum() {
        #expect(DoryEngineMemoryPolicy.hostScaledMemoryMB(
            physicalMemory: 128 * gibibyte
        ) == 62 * 1_024)
        #expect(DoryEngineMemoryPolicy.maximumConfigurableMemoryMB(
            physicalMemory: 128 * gibibyte
        ) == 62 * 1_024)
        #expect(DoryEngineMemoryPolicy.clampedMemoryMB(64 * 1_024) == 62 * 1_024)
    }

    @Test func ordinaryHostsRetainTheExistingElasticSizingPolicy() {
        #expect(DoryEngineMemoryPolicy.hostScaledMemoryMB(
            physicalMemory: 16 * gibibyte
        ) == 8 * 1_024)
        #expect(DoryEngineMemoryPolicy.hostScaledMemoryMB(
            physicalMemory: 8 * gibibyte
        ) == 4 * 1_024)
        #expect(DoryEngineMemoryPolicy.maximumConfigurableMemoryMB(
            physicalMemory: 16 * gibibyte
        ) == 12 * 1_024)
    }
}
