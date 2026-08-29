import DoryOperations
import Testing
@testable import DoryHV
@testable import dory_hv

@Suite struct DesktopShutdownPlanTests {
    @Test func legacyAndAuthorizedContractsUseGuestAssistedShutdown() {
        #expect(DesktopMode.ShutdownPlan(resolvedDevices: nil) == .guestAssisted)
        #expect(DesktopMode.ShutdownPlan(resolvedDevices: .init(
            gracefulShutdown: true
        )) == .guestAssisted)
    }

    @Test func resolvedOptOutUsesImmediateHostShutdown() {
        #expect(DesktopMode.ShutdownPlan(resolvedDevices: .init(
            gracefulShutdown: false
        )) == .immediate)
    }

    @Test func usbAuthorityTerminalBoundaryExcludesAnExecutingMachine() {
        #expect(DesktopMachineExecutionState.notStarted.isTerminalBoundary)
        #expect(!DesktopMachineExecutionState.running.isTerminalBoundary)
        #expect(DesktopMachineExecutionState.ended.isTerminalBoundary)
    }

    @Test func gpuBoundaryPublishesReleasesBeforeWaitingForRetirement() {
        let receipt = VirtioGPUQuiescence(epoch: 17, reason: .shutdown)
        var operations = [String]()

        let started = DesktopGPUShutdownBoundary.begin(
            quiesce: {
                operations.append("quiesce")
                return receipt
            },
            detachPresentations: {
                operations.append("detach-presentations")
            }
        )
        #expect(started === receipt)
        #expect(operations == ["quiesce", "detach-presentations"])

        receipt.complete(.completed)
        #expect(DesktopGPUShutdownBoundary.wait(
            for: receipt,
            timeout: 0.1
        ) == .completed(epoch: 17))
    }

    @Test func gpuBoundaryClassifiesTypedFailureAndFiniteTimeout() {
        let fault = VirtioGPURendererHealthFault.resetRequiresRecreation(
            "renderer instance is quarantined"
        )
        let failed = VirtioGPUQuiescence(epoch: 23, reason: .shutdown)
        failed.complete(.failed(fault))
        let failure = DesktopGPUShutdownBoundary.wait(for: failed, timeout: 0.1)
        #expect(failure == .failed(epoch: 23, fault: fault))
        #expect(failure.failure != nil)
        #expect(desktopGPUShutdownFailure(
            failure,
            rendererFailureLatch: nil
        ) is VMError)

        let rendererFailureLatch = DesktopRendererRuntimeFailureLatch()
        let rendererFailure = desktopGPUShutdownFailure(
            failure,
            rendererFailureLatch: rendererFailureLatch
        )
        #expect(rendererFailure as? DesktopRendererRuntimeFailure == .init(
            kind: .gpuQuiescence,
            reason: failure.logDescription
        ))

        let pending = VirtioGPUQuiescence(epoch: 24, reason: .shutdown)
        let timeout = DesktopGPUShutdownBoundary.wait(for: pending, timeout: 0)
        #expect(timeout == .timedOut(epoch: 24))
        #expect(timeout.failure != nil)
    }

    @Test func rendererFailureClassificationIsCandidateScopedAndFirstCauseWins() {
        let latch = DesktopRendererRuntimeFailureLatch()
        latch.record(kind: .worker, reason: "XPC interruption")
        latch.record(kind: .metalDevice, reason: "secondary teardown loss")

        let expected = DesktopRendererRuntimeFailure(
            kind: .worker,
            reason: "XPC interruption"
        )
        #expect(latch.failure == expected)
        #expect(desktopHelperExitStatus(for: expected) == .rendererCandidateFailure)
        #expect(desktopHelperExitStatus(for: VMError.bootFailure(
            "guest readiness timed out"
        )) == .generalFailure)
    }

    @Test func initializationRollbackRunsEveryAuthorityInReverseOrderExactlyOnce() {
        var operations = [String]()
        let rollback = DesktopInitializationRollback()
        rollback.register { operations.append("gpu") }
        rollback.register { operations.append("bridge-sockets") }
        rollback.register { operations.append("network-process") }

        rollback.performIfNeeded()
        rollback.performIfNeeded()

        #expect(operations == ["network-process", "bridge-sockets", "gpu"])
    }

    @Test func committedInitializationDisarmsRollback() {
        var rollbackCount = 0
        let rollback = DesktopInitializationRollback()
        rollback.register { rollbackCount += 1 }

        rollback.commit()
        rollback.performIfNeeded()

        #expect(rollbackCount == 0)
    }
}
