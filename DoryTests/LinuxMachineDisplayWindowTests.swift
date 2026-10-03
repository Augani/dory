import Testing
import DoryVMDisplayWireContracts
import Foundation
@testable import Dory

struct LinuxMachineDisplayWindowTests {
    @Test func heldInputReleasesEveryEndpointOnceAndKeepsItsOriginalOperation() {
        var state = LinuxMachineHeldInputState()
        #expect(state.takeReleases().isEmpty)
        let operation = UUID()
        state.record(operationID: operation, endpoint: .keyboard, events: [
            .init(type: 1, code: 42, value: 1), .init(type: 1, code: 30, value: 1),
            .init(type: 1, code: 30, value: 2), .init(type: 1, code: 31, value: 0)
        ])
        state.record(operationID: operation, endpoint: .absolutePointer, events: [
            .init(type: 3, code: 0, value: 100), .init(type: 1, code: 272, value: 1)
        ])
        state.record(operationID: operation, endpoint: .relativePointer, events: [
            .init(type: 2, code: 1, value: -10), .init(type: 1, code: 273, value: 1)
        ])
        let releases = state.takeReleases()
        #expect(releases == [
            .init(operationID: operation, endpoint: .keyboard, events: [
                .init(type: 1, code: 30, value: 0), .init(type: 1, code: 42, value: 0)
            ]),
            .init(operationID: operation, endpoint: .absolutePointer, events: [
                .init(type: 1, code: 272, value: 0)
            ]),
            .init(operationID: operation, endpoint: .relativePointer, events: [
                .init(type: 1, code: 273, value: 0)
            ])
        ])
        #expect(state.takeReleases().isEmpty)
        state.observeOperation(UUID())
        #expect(releases.allSatisfy { $0.operationID == operation })
    }

    @Test(arguments: [DoryVMDisplayInputEndpoint.keyboard, .absolutePointer, .relativePointer])
    func explicitInputReleaseDoesNotLeaveASecondFocusLossRelease(endpoint: DoryVMDisplayInputEndpoint) {
        var state = LinuxMachineHeldInputState()
        let operation = UUID()
        state.record(operationID: operation, endpoint: endpoint, events: [
            .init(type: 1, code: 30, value: 1), .init(type: 1, code: 30, value: 0)
        ])
        #expect(state.takeReleases().isEmpty)
        state.record(operationID: operation, endpoint: endpoint, events: [
            .init(type: 1, code: 42, value: 2), .init(type: 1, code: 99, value: -1)
        ])
        #expect(state.takeReleases() == [
            .init(operationID: operation, endpoint: endpoint,
                  events: [.init(type: 1, code: 42, value: 0)])
        ])
    }

    @Test func newRunnerOperationDropsOldHeldInputWithoutReleasingIntoItsSuccessor() {
        var state = LinuxMachineHeldInputState()
        let old = UUID()
        let fresh = UUID()
        state.record(operationID: old, endpoint: .keyboard,
                     events: [.init(type: 1, code: 30, value: 1)])
        let unchanged = state.observeOperation(old)
        #expect(!unchanged)
        #expect(state.takeReleases().first?.operationID == old)
        state.record(operationID: old, endpoint: .relativePointer,
                     events: [.init(type: 1, code: 272, value: 1)])
        let changed = state.observeOperation(fresh)
        #expect(changed)
        #expect(state.operationID == fresh)
        #expect(state.takeReleases().isEmpty)
        state.record(operationID: fresh, endpoint: .keyboard,
                     events: [.init(type: 1, code: 31, value: 1)])
        #expect(state.takeReleases() == [
            .init(operationID: fresh, endpoint: .keyboard,
                  events: [.init(type: 1, code: 31, value: 0)])
        ])
    }

    @Test func displayCommandSequenceSurvivesAppRelaunch() {
        var original = DoryDisplayCommandSequence()
        #expect(original.next(uptimeNanoseconds: 1_000) == 1_000)
        #expect(original.next(uptimeNanoseconds: 1_000) == 1_001)
        #expect(original.next(uptimeNanoseconds: 999) == 1_002)
        var reopened = DoryDisplayCommandSequence()
        #expect(reopened.next(uptimeNanoseconds: 2_000) == 2_000)
        #expect(reopened.lastSequence > original.lastSequence)
    }

    @Test func displayCommandSequenceRejectsZeroAndSaturation() {
        var sequence = DoryDisplayCommandSequence()
        #expect(sequence.next(uptimeNanoseconds: 0) == nil)
        #expect(sequence.next(uptimeNanoseconds: UInt64.max - 1) == UInt64.max - 1)
        #expect(sequence.next(uptimeNanoseconds: .max - 1) == nil)
        #expect(sequence.next(uptimeNanoseconds: .max) == nil)
    }

    @Test func captureTitleIsStableAndMachineScoped() {
        let primary = LinuxMachineDisplayWindow(machineID: "ubuntu-a4")
        let secondary = LinuxMachineDisplayWindow(machineID: "ubuntu-a4", scanoutID: 1)

        #expect(primary.id == "ubuntu-a4:0")
        #expect(primary.windowTitle == "Dory — ubuntu-a4 — Display 1")
        #expect(secondary.id == "ubuntu-a4:1")
        #expect(secondary.windowTitle == "Dory — ubuntu-a4 — Display 2")
    }

    @Test func scanoutCoordinatesKeepTopOriginFramesUpright() {
        let topOrigin = LinuxMachineScanoutTextureCoordinates.sourceUV(
            sourceRect: .init(x: 100, y: 50, width: 400, height: 200),
            backingWidth: 1_000,
            backingHeight: 500,
            yOriginTop: true
        )
        #expect(topOrigin == SIMD4<Float>(0.1, 0.1, 0.5, 0.5))

        let bottomOrigin = LinuxMachineScanoutTextureCoordinates.sourceUV(
            sourceRect: .init(x: 100, y: 50, width: 400, height: 200),
            backingWidth: 1_000,
            backingHeight: 500,
            yOriginTop: false
        )
        #expect(bottomOrigin == SIMD4<Float>(0.1, 0.5, 0.5, 0.1))
    }

    @Test func qualificationEvidenceRequiresBothMetalAndBrokerCompletion() {
        #expect(LinuxMachineDisplayEvidenceAdmission.accepts(
            presented: true,
            completionID: 19,
            brokerAccepted: true
        ))
        #expect(!LinuxMachineDisplayEvidenceAdmission.accepts(
            presented: true,
            completionID: 19,
            brokerAccepted: false
        ))
        #expect(!LinuxMachineDisplayEvidenceAdmission.accepts(
            presented: false,
            completionID: 19,
            brokerAccepted: true
        ))
        #expect(!LinuxMachineDisplayEvidenceAdmission.accepts(
            presented: true,
            completionID: nil,
            brokerAccepted: true
        ))
    }

    @Test func capturePollingGateHoldsExactlyOneFrameUntilReleased() {
        var gate = LinuxMachineFramePollingGate()
        #expect(!gate.isHeld)
        let firstHold = gate.hold()
        #expect(firstHold)
        #expect(gate.isHeld)
        let duplicateHold = gate.hold()
        #expect(!duplicateHold)
        let firstRelease = gate.release()
        #expect(firstRelease)
        #expect(!gate.isHeld)
        let duplicateRelease = gate.release()
        #expect(!duplicateRelease)
    }

    @Test func replacementRunnerResetsFrameAndCursorPollSequences() {
        var cursor = LinuxMachineDisplayOperationCursor()
        let firstOperation = UUID()
        let replacementOperation = UUID()
        let firstObservation = cursor.observeOperation(firstOperation)
        #expect(firstObservation)
        cursor.acknowledgeFrame(sequence: 100)
        cursor.observeCursor(sequence: 80)
        let duplicateObservation = cursor.observeOperation(firstOperation)
        #expect(!duplicateObservation)
        #expect(cursor.afterFrameSequence == 100)
        #expect(cursor.afterCursorSequence == 80)

        let replacementObservation = cursor.observeOperation(replacementOperation)
        #expect(replacementObservation)
        #expect(cursor.operationID == replacementOperation)
        #expect(cursor.afterFrameSequence == 0)
        #expect(cursor.afterCursorSequence == 0)
        cursor.acknowledgeFrame(sequence: 1)
        cursor.observeCursor(sequence: 1)
        #expect(cursor.afterFrameSequence == 1)
        #expect(cursor.afterCursorSequence == 1)
    }
}
