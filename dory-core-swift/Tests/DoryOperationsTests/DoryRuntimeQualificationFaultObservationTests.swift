import Foundation
import Testing
@testable import DoryOperations

@Suite struct DoryRuntimeQualificationFaultObservationTests {
    @Test func rendererDeathRequiresBothBoundedFactsAndCannotMixInAnotherFaultClass() {
        var receipt = DoryRuntimeQualificationFaultObservation(challenge: UUID(), kind: .rendererWorkerCrash,
            machineID: "campaign-renderer", operationID: UUID(), resolvedPlanSHA256: String(repeating: "b", count: 64),
            campaignManifestSHA256: String(repeating: "c", count: 64), state: .workerLost)
        receipt.rendererWorkerGeneration = 7
        receipt.rendererCrashRequestNanoseconds = 100
        receipt.rendererCrashAcknowledgedNanoseconds = 101
        receipt.rendererWorkerInterruptedNanoseconds = 102
        receipt.rendererInFlightCommandCount = 0
        #expect(receipt.isValidRuntimeObservation)
        var invalid = receipt; invalid.rendererCrashRequestNanoseconds = 0
        #expect(!invalid.isValidRuntimeObservation)
        invalid = receipt; invalid.rendererWorkerInterruptedNanoseconds = nil
        #expect(!invalid.isValidRuntimeObservation)
        invalid = receipt; invalid.rendererCrashAcknowledgedNanoseconds = nil
        #expect(!invalid.isValidRuntimeObservation)
        invalid = receipt; invalid.rendererInFlightCommandCount = nil
        #expect(!invalid.isValidRuntimeObservation)
        invalid = receipt; invalid.state = .crashRequested
        #expect(!invalid.isValidRuntimeObservation)
        invalid = receipt; invalid.queueGeneration = 1
        #expect(!invalid.isValidRuntimeObservation)
        invalid = receipt; invalid.rendererWorkerGeneration = 0
        #expect(!invalid.isValidRuntimeObservation)
        invalid = receipt; invalid.rendererCrashAcknowledgedNanoseconds = 99
        #expect(!invalid.isValidRuntimeObservation)
        invalid = receipt; invalid.rendererWorkerInterruptedNanoseconds = 99
        #expect(!invalid.isValidRuntimeObservation)
        invalid = receipt; invalid.rendererInFlightCommandCount = UInt32(UInt16.max) + 1
        #expect(!invalid.isValidRuntimeObservation)
        invalid = receipt; invalid.state = .armed
        #expect(!invalid.isValidRuntimeObservation)
    }
}
