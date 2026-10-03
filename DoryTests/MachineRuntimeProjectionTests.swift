import DoryOperations
import Foundation
import Testing
@testable import Dory

struct MachineRuntimeProjectionTests {
    @Test func nativeMacDisplayRepairIsDiagnosticNotStartOrSavedRAMDiscardAdmission() {
        var projected = machine(state: .failed)
        projected.guestFamily = "macos"
        projected.nativeMacDisplayRepair = .init(originalManifestSHA256: String(repeating: "a", count: 64),
            displays: [.init(widthPixels: 2560, heightPixels: 1600, pixelsPerInch: 220),
                       .init(widthPixels: 1920, heightPixels: 1080, pixelsPerInch: 144)],
            pendingSelectedDisplayIndex: nil, preservesSavedState: true, bundleRepairCompleted: false)
        projected.failure = .init(schemaVersion: 1, code: .savedStateInvalid, occurredAtUnixMilliseconds: 1_000,
            operationID: nil, causalChain: [.artifactAuthority], recoveryDisposition: .repair, evidenceReferences: [])
        #expect(projected.actionLabel == "Display Repair Required")
        #expect(!projected.requiresSavedStateRecovery)
        #expect(!projected.canDiscardSavedState)
        #expect(projected.runtimeEvidence.contains { $0.id == "display-repair" && $0.detail.contains("saved RAM are preserved") })
        projected.status = .suspended
        #expect(!projected.canDiscardSavedState)
    }
    @Test func invalidSavedStateOffersExplicitRecoveryNotStart() {
        var projected = machine(state: .failed)
        projected.failure = .init(
            schemaVersion: 1, code: .savedStateInvalid,
            occurredAtUnixMilliseconds: 1_000, operationID: nil,
            causalChain: [.artifactAuthority], recoveryDisposition: .repair, evidenceReferences: []
        )
        #expect(projected.requiresSavedStateRecovery)
        #expect(projected.canDiscardSavedState)
        #expect(projected.actionLabel == "Recover…")
        projected.processID = 123
        #expect(!projected.canDiscardSavedState)
        projected.processID = nil
        projected.activeOperation = .init(operationID: UUID().uuidString.lowercased(), kind: .stopping, phase: .publishing)
        #expect(!projected.canDiscardSavedState)
    }

    @Test func ordinaryFailuresAndLiveGuestsCannotDiscardSavedState() {
        for state in DoryVirtualMachineState.allCases {
            let projected = machine(state: state)
            #expect(!projected.requiresSavedStateRecovery)
            #expect(projected.canDiscardSavedState == (state == .suspended))
        }
    }

    @Test func pendingColdRecoveryOffersOnlyItsOriginalStopOperation() {
        let operationID = UUID()
        var projected = machine(state: .recovering)
        projected.failure = .init(
            schemaVersion: 1, code: .lifecycleRecoveryRequired,
            occurredAtUnixMilliseconds: 1_000, operationID: operationID.uuidString.lowercased(),
            causalChain: [.journal], recoveryDisposition: .repair, evidenceReferences: []
        )
        projected.activeOperation = .init(operationID: operationID.uuidString.lowercased(), kind: .stopping, phase: .publishing)
        #expect(projected.pendingSavedStateRecoveryOperationID == operationID)
        #expect(projected.canDiscardSavedState)
        #expect(projected.actionLabel == "Retry Recovery…")
        projected.activeOperation?.kind = .repairing
        #expect(!projected.canDiscardSavedState)
        projected.activeOperation?.kind = .stopping
        projected.processID = 42
        #expect(!projected.canDiscardSavedState)
    }

    private func machine(state: DoryVirtualMachineState = .running) -> Machine {
        Machine(
            name: "dev", distro: "Ubuntu", version: "24.04", status: state,
            cpuPercent: 0, memoryDisplay: "—", ip: "dev.dory.local",
            letter: "U", badgeHex: 0
        )
    }

    @Test func lifecycleLabelsAndActionsKeepTransitionalStatesDistinct() {
        let cases: [(DoryVirtualMachineState, String, String, Bool)] = [
            (.absent, "Absent", "Start", false),
            (.defined, "Created", "Start", false),
            (.created, "Created", "Start", true),
            (.installing, "Installing", "Stop", true),
            (.starting, "Starting", "Stop", true),
            (.running, "Running", "Stop", true),
            (.stopping, "Stopping", "Stopping", false),
            (.paused, "Paused", "Resume", true),
            (.suspended, "Suspended", "Restore", true),
            (.recovering, "Recovering", "Recovering", false),
            (.stopped, "Stopped", "Start", true),
            (.failed, "Failed", "Start", true),
            (.deleting, "Deleting", "Deleting", false),
        ]
        #expect(Set(cases.map(\.0)) == Set(DoryVirtualMachineState.allCases))
        for (state, label, action, acceptsAction) in cases {
            let projected = machine(state: state)
            #expect(projected.status.label == label)
            #expect(projected.actionLabel == action)
            #expect(projected.status.acceptsPrimaryAction == acceptsAction)
            #expect(projected.readinessObservations.allSatisfy { !$0.observed })
        }
    }

    @Test(arguments: 0..<6)
    func readinessObservationsDoNotPromoteOtherMilestones(selected: Int) {
        var projected = machine()
        projected.readiness = .init(
            processAlive: selected == 0, vmStarted: selected == 1,
            guestBooted: selected == 2, toolsConnected: selected == 3,
            desktopVisible: selected == 4, workloadReady: selected == 5
        )
        let expectedLabels = [
            "Process alive", "VM started", "Guest booted", "Guest tools connected",
            "Desktop visible", "Workload ready",
        ]
        #expect(projected.readinessObservations.map(\.label) == expectedLabels)
        #expect(projected.readinessObservations.filter(\.observed).map(\.label)
            == [expectedLabels[selected]])
        #expect(projected.readinessDetail.split(separator: "\n").map(String.init)
            == expectedLabels.enumerated().map {
                "\($0.element): \($0.offset == selected ? "observed" : "not observed")"
            })
    }

    @Test func retainedFailureDoesNotHideCurrentRecoveryProgress() throws {
        var projected = machine(state: .recovering)
        let previousOperationID = UUID().uuidString.lowercased()
        let currentOperationID = UUID().uuidString.lowercased()
        projected.failure = .init(
            schemaVersion: 1, code: .lifecycleRecoveryRequired,
            occurredAtUnixMilliseconds: 1_000, operationID: previousOperationID,
            causalChain: [], recoveryDisposition: .repair, evidenceReferences: []
        )
        projected.activeOperation = .init(
            operationID: currentOperationID, kind: .repairing, phase: .readyToPublish
        )
        let evidence = projected.runtimeEvidence
        #expect(evidence.contains { $0.id == "failure" })
        let operation = try #require(evidence.first { $0.id == "operation" })
        #expect(operation.label == "Repairing · Ready to publish")
        #expect(operation.detail == "Operation \(currentOperationID)")
        #expect(projected.operationProgressLabel == operation.label)
    }
}
