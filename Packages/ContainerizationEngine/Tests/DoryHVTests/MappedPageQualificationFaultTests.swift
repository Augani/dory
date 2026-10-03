import Foundation
import Testing
@testable import DoryHV
@testable import DoryOperations

#if arch(arm64)
@Suite struct MappedPageQualificationFaultTests {
    final class Protection: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [Bool] = []
        private var restoreWorks = true
        func setRestoreWorks(_ value: Bool) { lock.withLock { restoreWorks = value } }
        func apply(_ address: UInt64, _ count: Int, _ enabled: Bool) -> Bool {
            lock.withLock { calls.append(enabled); return enabled || restoreWorks }
        }
        var events: [Bool] { lock.withLock { calls } }
    }

    struct Fixture {
        let memory: GuestMemory
        let protection: Protection
        let controller: RuntimeQualificationFaultController
        let grant: DoryRuntimeQualificationFaultAuthority
        let challenge = UUID()
        var address: UInt64 { memory.guestBase + HostPage.size }
        func request(_ action: DoryRuntimeQualificationFaultRequest.Action,
                     kind: DoryRuntimeQualificationFaultKind? = nil) -> DoryRuntimeQualificationFaultRequest {
            .init(action: action, machineID: grant.machineID, operationID: grant.operationID,
                  resolvedPlanSHA256: grant.resolvedPlanSHA256, campaignManifestSHA256: grant.campaignManifestSHA256,
                  challenge: challenge, kind: action == .arm ? kind ?? .mappedPageRepeatedPermission : nil,
                  guestPhysicalAddress: action == .arm && kind != .blockFullFlushNoSpace ? address : nil)
        }
        func fill() throws {
            try memory.write(Array(DoryMappedPageQualificationChallenge.expectedPage(challenge: challenge)), at: address)
        }
    }

    func fixture(arms: UInt16 = 2, milliseconds: UInt32 = 1000) throws -> Fixture {
        let protection = Protection()
        let memory = try GuestMemory(
            guestBase: 0x4000_0000, size: 4 * HostPage.size,
            reclaimOperations: .init(unmap: { _, _ in true }, map: { _, _, _ in true },
                                     markReusable: { _, _ in true }, markInUse: { _, _ in true }),
            qualificationProtection: protection.apply
        )
        let grant = DoryRuntimeQualificationFaultAuthority(
            machineID: "campaign-arm-mapped", operationID: UUID(),
            resolvedPlanSHA256: String(repeating: "b", count: 64),
            campaignManifestSHA256: String(repeating: "c", count: 64),
            expiresAt: Date().addingTimeInterval(60),
            policy: .init(permittedFaults: [.blockFullFlushNoSpace, .mappedPageRepeatedPermission],
                          maximumArmingCount: arms, maximumArmedMilliseconds: milliseconds)
        )
        return Fixture(memory: memory, protection: protection,
                       controller: try RuntimeQualificationFaultController(authority: grant), grant: grant)
    }

    @Test func productionRetryBudgetAndSuccessfulExceptionAreBothRequiredForCompletion() throws {
        let f = try fixture()
        try f.fill()
        let armed = try f.controller.handle(f.request(.arm), memory: f.memory)
        #expect(armed.state == .armed && armed.isValidRuntimeObservation)
        #expect(f.memory.restorePage(guestAddress: f.address) == .alreadyMapped)
        #expect(f.memory.releaseRange(guestAddress: f.address, length: HostPage.size) == .rejected)
        var budget = MappedPageFaultRetryBudget()
        for count in 1...17 {
            let allowed = budget.retryAlreadyMapped(vcpuIndex: 0, physicalAddress: f.address, instructionAddress: 0x1000)
            let ticket = f.controller.mappedPageExit(address: f.address, vcpuIndex: 0,
                                                     instructionAddress: 0x1000, retryAllowed: allowed)
            #expect(allowed == (count <= 16))
            #expect(ticket == (count == 17 ? f.challenge : nil))
        }
        let beforeException = try f.controller.handle(f.request(.observe))
        #expect(beforeException.state == .faulting)
        #expect(beforeException.faultExitCount == 17 && beforeException.retryCount == 16)
        #expect(beforeException.isValidRuntimeObservation)
        try f.controller.mappedPageGuestExceptionInjected(challenge: f.challenge, exception: "synchronous-external-data-abort")
        let done = try f.controller.handle(f.request(.observe))
        #expect(done.state == .retryEscalated && done.isValidRuntimeObservation)
        #expect(done.memoryProtectionRestored == true)
        #expect(f.protection.events == [true, false])
        #expect(try f.memory.readBytes(at: f.address, count: Int(HostPage.size))
            == Array(DoryMappedPageQualificationChallenge.expectedPage(challenge: f.challenge)))
    }

    @Test func arbitraryOrReclaimedRamCannotBeProtected() throws {
        let empty = try fixture()
        #expect(throws: DoryRuntimeQualificationFaultError.unauthorized) {
            try empty.controller.handle(empty.request(.arm), memory: empty.memory)
        }
        #expect(empty.protection.events.isEmpty)
        let reclaimed = try fixture()
        try reclaimed.fill()
        #expect(reclaimed.memory.releaseRange(guestAddress: reclaimed.address, length: HostPage.size) == .reclaimed)
        #expect(throws: DoryRuntimeQualificationFaultError.unauthorized) {
            try reclaimed.controller.handle(reclaimed.request(.arm), memory: reclaimed.memory)
        }
        #expect(reclaimed.protection.events.isEmpty)
    }

    @Test func wrongInstructionOrCpuCancelsWithoutClaimingEscalation() throws {
        for changeCPU in [false, true] {
            let f = try fixture()
            try f.fill()
            _ = try f.controller.handle(f.request(.arm), memory: f.memory)
            _ = f.controller.mappedPageExit(address: f.address, vcpuIndex: 0, instructionAddress: 0x1000, retryAllowed: true)
            _ = f.controller.mappedPageExit(address: f.address, vcpuIndex: changeCPU ? 1 : 0,
                                           instructionAddress: changeCPU ? 0x1000 : 0x2000, retryAllowed: true)
            let cancelled = try f.controller.handle(f.request(.observe))
            #expect(cancelled.state == .cancelled && cancelled.isValidRuntimeObservation)
            #expect(cancelled.guestException == nil && cancelled.memoryProtectionRestored == true)
        }
    }

    @Test func prematureEscalationCannotFabricateTheRetryEpisode() throws {
        let f = try fixture()
        try f.fill()
        _ = try f.controller.handle(f.request(.arm), memory: f.memory)
        #expect(f.controller.mappedPageExit(address: f.address, vcpuIndex: 0,
                                          instructionAddress: 0x1000, retryAllowed: false) == nil)
        #expect(try f.controller.handle(f.request(.observe)).state == .cancelled)
        #expect(throws: DoryRuntimeQualificationFaultError.invalidIdentity) {
            try f.controller.mappedPageGuestExceptionInjected(challenge: f.challenge, exception: "serror")
        }
    }

    @Test func resetAndDeadlineRestorePermissionsEvenWhenNoGuestTouchesThePage() throws {
        let f = try fixture()
        try f.fill()
        _ = try f.controller.handle(f.request(.arm), memory: f.memory)
        f.controller.cancelPending()
        #expect(try f.controller.handle(f.request(.observe)).state == .cancelled)
        #expect(f.protection.events == [true, false])
        let expired = try fixture()
        try expired.fill()
        _ = try expired.controller.handle(expired.request(.arm), memory: expired.memory)
        let receipt = try #require(expired.controller.snapshot(monotonicNanoseconds: UInt64.max).first)
        #expect(receipt.state == .expired && receipt.isValidRuntimeObservation)
        #expect(expired.protection.events == [true, false])
    }

    @Test func rollbackFailureIsExplicitAndBlocksFurtherGuestExecutionAndArming() throws {
        let f = try fixture()
        try f.fill()
        _ = try f.controller.handle(f.request(.arm), memory: f.memory)
        f.protection.setRestoreWorks(false)
        f.controller.cancelPending()
        #expect(try f.controller.handle(f.request(.observe)).state == .restoreFailed)
        #expect(throws: DoryRuntimeQualificationFaultError.unauthorized) { try f.controller.checkProtectionRestoration() }
        #expect(throws: DoryRuntimeQualificationFaultError.alreadyArmed) {
            try f.controller.arm(.blockFullFlushNoSpace, challenge: UUID(), operationID: f.grant.operationID)
        }
        f.protection.setRestoreWorks(true)
        f.controller.cancelPending()
        #expect(try f.controller.handle(f.request(.observe)).state == .cancelled)
    }

    @Test func storageAndMemoryFaultsShareOneArmingBudget() throws {
        let f = try fixture(arms: 1)
        try f.fill()
        _ = try f.controller.handle(f.request(.arm), memory: f.memory)
        f.controller.cancelPending()
        #expect(throws: DoryRuntimeQualificationFaultError.armingBudgetExhausted) {
            try f.controller.arm(.blockFullFlushNoSpace, challenge: UUID(), operationID: f.grant.operationID)
        }
    }

    @Test func deadlineTimerRestoresAnUntouchedPageWithoutControlPolling() async throws {
        let f = try fixture(milliseconds: 20)
        try f.fill()
        _ = try f.controller.handle(f.request(.arm), memory: f.memory)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while f.protection.events.count < 2 && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        // Inspect the protection seam before snapshot: polling must not perform the rollback.
        #expect(f.protection.events == [true, false])
        let expired = try f.controller.handle(f.request(.observe))
        #expect(expired.state == .expired && expired.isValidRuntimeObservation)
    }

    @Test func recoveryAfterPostInjectionRollbackFailurePreservesTheExceptionFact() throws {
        let f = try fixture()
        try f.fill()
        _ = try f.controller.handle(f.request(.arm), memory: f.memory)
        var budget = MappedPageFaultRetryBudget()
        for _ in 1...17 {
            let allowed = budget.retryAlreadyMapped(vcpuIndex: 0, physicalAddress: f.address, instructionAddress: 0x1000)
            _ = f.controller.mappedPageExit(address: f.address, vcpuIndex: 0,
                                           instructionAddress: 0x1000, retryAllowed: allowed)
        }
        f.protection.setRestoreWorks(false)
        #expect(throws: DoryRuntimeQualificationFaultError.unauthorized) {
            try f.controller.mappedPageGuestExceptionInjected(challenge: f.challenge, exception: "synchronous-external-data-abort")
        }
        let failed = try f.controller.handle(f.request(.observe))
        #expect(failed.state == .restoreFailed && failed.isValidRuntimeObservation)
        #expect(failed.guestException == "synchronous-external-data-abort")
        f.protection.setRestoreWorks(true)
        f.controller.cancelPending()
        let recovered = try f.controller.handle(f.request(.observe))
        #expect(recovered.state == .cancelled && recovered.isValidRuntimeObservation)
        #expect(recovered.guestException == failed.guestException && recovered.memoryProtectionRestored == true)
    }
}
#endif
