import Darwin
import Testing
@testable import DoryFSWorkerServiceCore

struct DoryFSWorkerProcessResourcesTests {
    @Test func descriptorSoftLimitIsBoundedByHardLimitAndWorkerCeiling() {
        #expect(DoryFSWorkerProcessResources.desiredFileDescriptorSoftLimit(
            current: 256,
            hard: 1_048_576,
            ceiling: 262_144
        ) == 262_144)
        #expect(DoryFSWorkerProcessResources.desiredFileDescriptorSoftLimit(
            current: 256,
            hard: 32_768,
            ceiling: 262_144
        ) == 32_768)
    }

    @Test func descriptorSoftLimitNeverLowersAnExistingHigherLimit() {
        #expect(DoryFSWorkerProcessResources.desiredFileDescriptorSoftLimit(
            current: 1_048_576,
            hard: rlim_t.max,
            ceiling: 262_144
        ) == 1_048_576)
    }
}
