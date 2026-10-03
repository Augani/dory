import Darwin
import Foundation
import Testing
@testable import DoryHV
@testable import DoryOperations

@Suite struct RuntimeQualificationFaultControllerTests {
    @Test(arguments: [false, true])
    func rendererLifecycleGateRevokesQueuedPermitAndCannotResumeAfterStop(permanentStop: Bool) throws {
        let grant = DoryRuntimeQualificationFaultAuthority(
            machineID: "campaign-pc", operationID: UUID(), resolvedPlanSHA256: String(repeating: "b", count: 64),
            campaignManifestSHA256: String(repeating: "c", count: 64), expiresAt: Date().addingTimeInterval(60),
            policy: .init(permittedFaults: [.rendererWorkerCrash], maximumArmingCount: 2)
        )
        let faults = try RuntimeQualificationFaultController(authority: grant)
        let holder = RendererCrashAdmissionHolder()
        func request(generation: UInt64) -> DoryRuntimeQualificationFaultRequest {
            .init(action: .arm, machineID: grant.machineID, operationID: grant.operationID,
                resolvedPlanSHA256: grant.resolvedPlanSHA256, campaignManifestSHA256: grant.campaignManifestSHA256,
                challenge: UUID(), kind: .rendererWorkerCrash, rendererWorkerGeneration: generation)
        }
        _ = try faults.handle(request(generation: 7), rendererCrash: { holder.store($0) })
        let admission = try #require(holder.value)
        faults.suspendRendererCrashArming(permanently: permanentStop)
        #expect(!admission.claimDispatchPermission())
        #expect(faults.snapshot().first?.state == .cancelled)
        #expect(throws: DoryRuntimeQualificationFaultError.unauthorized) {
            try faults.handle(request(generation: 8), rendererCrash: { _ in Issue.record("suspended request dispatched") })
        }
        #expect(faults.snapshot().count == 1)
        faults.resumeRendererCrashArming()
        if permanentStop {
            #expect(throws: DoryRuntimeQualificationFaultError.unauthorized) {
                try faults.handle(request(generation: 8), rendererCrash: { _ in Issue.record("stopped request dispatched") })
            }
        } else {
            #expect(try faults.handle(request(generation: 8), rendererCrash: { _ in }).state == .crashRequested)
        }
        faults.cancelPending()
    }

    @Test func rendererCrashDispatchIsSingleUseSharedByCopiesAndPinnedToSignedExpiry() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let grant = DoryRuntimeQualificationFaultAuthority(
            machineID: "campaign-renderer", operationID: UUID(), resolvedPlanSHA256: String(repeating: "b", count: 64),
            campaignManifestSHA256: String(repeating: "c", count: 64), expiresAt: now.addingTimeInterval(0.25),
            policy: .init(permittedFaults: [.rendererWorkerCrash], maximumArmedMilliseconds: 10_000)
        )
        let admission = try grant.rendererCrashAdmission(challenge: UUID(), workerGeneration: 7,
            now: now, monotonicNanoseconds: 100)
        #expect(admission.dispatchDeadlineNanoseconds == 250_000_100)
        let copy = admission
        #expect(copy == admission)
        #expect(copy.claimDispatchPermission(now: now, monotonicNanoseconds: 101))
        #expect(!admission.claimDispatchPermission(now: now, monotonicNanoseconds: 102))
        let cancelled = try grant.rendererCrashAdmission(challenge: UUID(), workerGeneration: 7,
            now: now, monotonicNanoseconds: 100)
        let cancelledCopy = cancelled
        cancelled.cancelDispatch()
        #expect(!cancelledCopy.claimDispatchPermission(now: now, monotonicNanoseconds: 101))
        let expired = try grant.rendererCrashAdmission(challenge: UUID(), workerGeneration: 7,
            now: now, monotonicNanoseconds: 100)
        #expect(!expired.claimDispatchPermission(now: now, monotonicNanoseconds: 250_000_100))
        #expect(!expired.claimDispatchPermission(now: grant.expiresAt, monotonicNanoseconds: 101))
        #expect(throws: DoryRuntimeQualificationFaultError.invalidIdentity) {
            _ = try grant.rendererCrashAdmission(challenge: UUID(), workerGeneration: 7,
                now: now, monotonicNanoseconds: UInt64.max)
        }
    }

    @Test(arguments: ["rejected", "cancelled", "expired"])
    func rendererCrashCancellationRevokesQueuedDispatch(mode: String) throws {
        let grant = DoryRuntimeQualificationFaultAuthority(
            machineID: "campaign-renderer", operationID: UUID(), resolvedPlanSHA256: String(repeating: "b", count: 64),
            campaignManifestSHA256: String(repeating: "c", count: 64), expiresAt: Date().addingTimeInterval(60),
            policy: .init(permittedFaults: [.rendererWorkerCrash])
        )
        let controller = try RuntimeQualificationFaultController(authority: grant)
        let holder = RendererCrashAdmissionHolder()
        let challenge = UUID()
        _ = try controller.handle(.init(action: .arm, machineID: grant.machineID,
            operationID: grant.operationID, resolvedPlanSHA256: grant.resolvedPlanSHA256,
            campaignManifestSHA256: grant.campaignManifestSHA256, challenge: challenge,
            kind: .rendererWorkerCrash, rendererWorkerGeneration: 7), rendererCrash: { holder.store($0) })
        let admission = try #require(holder.value)
        if mode == "rejected" {
            controller.rendererCrashAcknowledged(challenge: challenge, workerGeneration: 7,
                accepted: false, inFlightCommands: 0)
        } else if mode == "cancelled" { controller.cancelPending() }
        else { _ = controller.snapshot(monotonicNanoseconds: admission.dispatchDeadlineNanoseconds) }
        #expect(!admission.claimDispatchPermission())
    }

    @Test(arguments: [true, false])
    func rendererCrashRequiresBothWorkerAcknowledgementAndInterruption(acknowledgementFirst: Bool) throws {
        let grant = DoryRuntimeQualificationFaultAuthority(
            machineID: "campaign-renderer", operationID: UUID(), resolvedPlanSHA256: String(repeating: "b", count: 64),
            campaignManifestSHA256: String(repeating: "c", count: 64), expiresAt: Date().addingTimeInterval(60),
            policy: .init(permittedFaults: [.rendererWorkerCrash])
        )
        let faults = try RuntimeQualificationFaultController(authority: grant)
        let challenge = UUID()
        let request = DoryRuntimeQualificationFaultRequest(action: .arm, machineID: grant.machineID,
            operationID: grant.operationID, resolvedPlanSHA256: grant.resolvedPlanSHA256,
            campaignManifestSHA256: grant.campaignManifestSHA256, challenge: challenge,
            kind: .rendererWorkerCrash, rendererWorkerGeneration: 7)
        #expect(throws: DoryRuntimeQualificationFaultError.unauthorized) { try faults.handle(request) }
        #expect(faults.snapshot().isEmpty)
        let armed = try faults.handle(request, rendererCrash: { admission in
            #expect(admission.permits(workspaceID: grant.operationID, workerGeneration: 7))
            #expect(!admission.permits(workspaceID: UUID(), workerGeneration: 7))
            #expect(!admission.permits(workspaceID: grant.operationID, workerGeneration: 8))
        })
        #expect(armed.state == .crashRequested)
        #expect(armed.isValidRuntimeObservation)
        faults.rendererCrashAcknowledged(challenge: challenge, workerGeneration: 8, accepted: true, inFlightCommands: 3)
        faults.rendererWorkerInterrupted(challenge: UUID(), workerGeneration: 7)
        #expect(faults.snapshot().first == armed)
        if acknowledgementFirst {
            faults.rendererCrashAcknowledged(challenge: challenge, workerGeneration: 7, accepted: true, inFlightCommands: 3)
        } else { faults.rendererWorkerInterrupted(challenge: challenge, workerGeneration: 7) }
        #expect(faults.snapshot().first?.state == .crashRequested)
        #expect(faults.snapshot().first?.isValidRuntimeObservation == true)
        if acknowledgementFirst { faults.rendererWorkerInterrupted(challenge: challenge, workerGeneration: 7) }
        else {
            faults.rendererCrashAcknowledged(challenge: challenge, workerGeneration: 7, accepted: true, inFlightCommands: 3)
        }
        let receipt = try #require(faults.snapshot().first)
        #expect(receipt.state == .workerLost)
        #expect(receipt.isValidRuntimeObservation)
        #expect(receipt.rendererWorkerGeneration == 7)
        #expect(receipt.rendererInFlightCommandCount == 3)
        #expect(receipt.matches(request))
        #expect(try JSONDecoder().decode(DoryRuntimeQualificationFaultObservation.self,
            from: JSONEncoder().encode(receipt)) == receipt)
        faults.rendererWorkerInterrupted(challenge: challenge, workerGeneration: 7)
        #expect(faults.snapshot().first == receipt)
    }

    @Test(arguments: ["rejected", "cancelled", "expired"])
    func rejectedCancelledOrExpiredCrashCannotBecomeWorkerLoss(mode: String) throws {
        let grant = DoryRuntimeQualificationFaultAuthority(
            machineID: "campaign-renderer", operationID: UUID(), resolvedPlanSHA256: String(repeating: "b", count: 64),
            campaignManifestSHA256: String(repeating: "c", count: 64), expiresAt: Date().addingTimeInterval(60),
            policy: .init(permittedFaults: [.rendererWorkerCrash])
        )
        let faults = try RuntimeQualificationFaultController(authority: grant)
        let challenge = UUID()
        let request = DoryRuntimeQualificationFaultRequest(action: .arm, machineID: grant.machineID,
            operationID: grant.operationID, resolvedPlanSHA256: grant.resolvedPlanSHA256,
            campaignManifestSHA256: grant.campaignManifestSHA256, challenge: challenge,
            kind: .rendererWorkerCrash, rendererWorkerGeneration: 7)
        _ = try faults.handle(request, rendererCrash: { _ in })
        if mode == "rejected" {
            faults.rendererCrashAcknowledged(challenge: challenge, workerGeneration: 7, accepted: false, inFlightCommands: 0)
        } else if mode == "cancelled" { faults.cancelPending() }
        else { _ = faults.snapshot(now: grant.expiresAt) }
        faults.rendererCrashAcknowledged(challenge: challenge, workerGeneration: 7, accepted: true, inFlightCommands: 1)
        faults.rendererWorkerInterrupted(challenge: challenge, workerGeneration: 7)
        let result = try #require(faults.snapshot().first)
        #expect(result.state == (mode == "rejected" ? .crashRejected : mode == "cancelled" ? .cancelled : .expired))
        #expect(result.isValidRuntimeObservation)
        #expect(result.rendererCrashAcknowledgedNanoseconds == nil)
        #expect(result.rendererWorkerInterruptedNanoseconds == nil)
        #expect(throws: DoryRuntimeQualificationFaultError.reusedChallenge) {
            _ = try faults.handle(request, rendererCrash: { _ in })
        }
    }

    @Test func rendererCrashCannotBeMintedByAnotherFaultPolicyOrSmuggledAsDiskWork() throws {
        let grant = DoryRuntimeQualificationFaultAuthority(
            machineID: "campaign-renderer", operationID: UUID(), resolvedPlanSHA256: String(repeating: "b", count: 64),
            campaignManifestSHA256: String(repeating: "c", count: 64), expiresAt: Date().addingTimeInterval(60),
            policy: .init(permittedFaults: [.blockFullFlushNoSpace])
        )
        #expect(throws: DoryRuntimeQualificationFaultError.unauthorized) {
            _ = try grant.rendererCrashAdmission(challenge: UUID(), workerGeneration: 7)
        }
        let malformed = DoryRuntimeQualificationFaultRequest(action: .arm, machineID: grant.machineID,
            operationID: grant.operationID, resolvedPlanSHA256: grant.resolvedPlanSHA256,
            campaignManifestSHA256: grant.campaignManifestSHA256, challenge: UUID(),
            kind: .blockFullFlushNoSpace, rendererWorkerGeneration: 7)
        #expect(!malformed.matches(grant))
    }

    @Test func controlRequiresExactGrantAndChallengeBeforeArmObserveOrCancel() throws {
        let grant = DoryRuntimeQualificationFaultAuthority(
            machineID: "campaign-arm-control", operationID: UUID(),
            resolvedPlanSHA256: String(repeating: "b", count: 64),
            campaignManifestSHA256: String(repeating: "c", count: 64),
            expiresAt: Date().addingTimeInterval(60),
            policy: .init(permittedFaults: [.blockFullFlushNoSpace], maximumArmingCount: 2)
        )
        let controller = try RuntimeQualificationFaultController(authority: grant)
        let challenge = UUID()
        func request(_ action: DoryRuntimeQualificationFaultRequest.Action, machine: String? = nil,
                     operation: UUID? = nil, plan: String? = nil, manifest: String? = nil,
                     nonce: UUID? = nil) -> DoryRuntimeQualificationFaultRequest {
            .init(action: action, machineID: machine ?? grant.machineID,
                  operationID: operation ?? grant.operationID, resolvedPlanSHA256: plan ?? grant.resolvedPlanSHA256,
                  campaignManifestSHA256: manifest ?? grant.campaignManifestSHA256,
                  challenge: nonce ?? challenge, kind: action == .arm ? .blockFullFlushNoSpace : nil)
        }
        for invalid in [request(.arm, machine: "other"), request(.arm, operation: UUID()),
                        request(.arm, plan: String(repeating: "d", count: 64)),
                        request(.arm, manifest: String(repeating: "e", count: 64))] {
            #expect(throws: DoryRuntimeQualificationFaultError.invalidIdentity) { try controller.handle(invalid) }
        }
        #expect(controller.snapshot().isEmpty)
        #expect(try controller.handle(request(.arm)).state == .armed)
        #expect(throws: DoryRuntimeQualificationFaultError.unknownChallenge) {
            try controller.handle(request(.cancel, nonce: UUID()))
        }
        #expect(try controller.handle(request(.observe)).state == .armed)
        #expect(try controller.handle(request(.cancel)).state == .cancelled)
        #expect(try controller.handle(request(.observe)).state == .cancelled)
        #expect(controller.consumeFullFlush(queueIndex: 0, queueGeneration: 1) == nil)
    }

    static let operationID = UUID(uuidString: "aaaa0000-0000-0000-0000-000000000001")!
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func controller(arms: UInt16 = 1, milliseconds: UInt32 = 1000) throws -> RuntimeQualificationFaultController {
        try RuntimeQualificationFaultController(authority: DoryRuntimeQualificationFaultAuthority(
            machineID: "campaign-arm-1", operationID: Self.operationID,
            resolvedPlanSHA256: String(repeating: "b", count: 64),
            campaignManifestSHA256: String(repeating: "c", count: 64), expiresAt: now.addingTimeInterval(60),
            policy: DoryCandidateCampaignFaultPolicy(permittedFaults: [.blockFullFlushNoSpace],
                                                   maximumArmingCount: arms, maximumArmedMilliseconds: milliseconds)
        ))
    }

    @Test func oneShotRecordsTheRealQueueErrorAndExactAuthority() throws {
        let faults = try controller()
        let challenge = UUID()
        try faults.arm(.blockFullFlushNoSpace, challenge: challenge, operationID: Self.operationID,
                       now: now, monotonicNanoseconds: 0)
        let consumed = faults.consumeFullFlush(queueIndex: 1, queueGeneration: 5, now: now, monotonicNanoseconds: 1)
        #expect(consumed == challenge)
        #expect(faults.consumeFullFlush(queueIndex: 1, queueGeneration: 5, now: now, monotonicNanoseconds: 2) == nil)
        faults.guestCompleted(challenge: challenge, status: 1, queueIndex: 1, queueGeneration: 5)
        let receipt = try #require(faults.snapshot(now: now, monotonicNanoseconds: 3).first)
        #expect(receipt.state == .guestCompleted)
        #expect(receipt.injectedErrno == ENOSPC)
        #expect(receipt.guestStatus == 1)
        #expect(receipt.queueIndex == 1)
        #expect(receipt.queueGeneration == 5)
        #expect(receipt.machineID == "campaign-arm-1")
        #expect(receipt.operationID == Self.operationID)
        #expect(receipt.resolvedPlanSHA256 == String(repeating: "b", count: 64))
    }

    @Test func differentQueueGenerationAndSuccessCannotAcknowledgeTheFault() throws {
        let faults = try controller()
        let challenge = UUID()
        try faults.arm(.blockFullFlushNoSpace, challenge: challenge, operationID: Self.operationID,
                       now: now, monotonicNanoseconds: 0)
        _ = faults.consumeFullFlush(queueIndex: 0, queueGeneration: 1, now: now, monotonicNanoseconds: 1)
        faults.guestCompleted(challenge: challenge, status: 1, queueIndex: 0, queueGeneration: 2)
        faults.guestCompleted(challenge: challenge, status: 0, queueIndex: 0, queueGeneration: 1)
        #expect(faults.snapshot(now: now, monotonicNanoseconds: 2).first?.state == .consumed)
    }

    @Test func unqueuedUnitCallIsNotProofOfGuestCompletion() throws {
        let faults = try controller()
        let challenge = UUID()
        try faults.arm(.blockFullFlushNoSpace, challenge: challenge, operationID: Self.operationID,
                       now: now, monotonicNanoseconds: 0)
        _ = faults.consumeFullFlush(queueIndex: nil, queueGeneration: nil, now: now, monotonicNanoseconds: 1)
        faults.guestCompleted(challenge: challenge, status: 1, queueIndex: 0, queueGeneration: 1)
        #expect(faults.snapshot(now: now, monotonicNanoseconds: 2).first?.state == .consumed)
    }

    @Test func resetCancelsArmedWorkAndAChallengeCannotBeReused() throws {
        let faults = try controller(arms: 2)
        let challenge = UUID()
        try faults.arm(.blockFullFlushNoSpace, challenge: challenge, operationID: Self.operationID,
                       now: now, monotonicNanoseconds: 0)
        faults.cancelPending()
        #expect(faults.consumeFullFlush(queueIndex: 0, queueGeneration: 1, now: now, monotonicNanoseconds: 1) == nil)
        #expect(faults.snapshot(now: now, monotonicNanoseconds: 2).first?.state == .cancelled)
        #expect(throws: DoryRuntimeQualificationFaultError.reusedChallenge) {
            try faults.arm(.blockFullFlushNoSpace, challenge: challenge, operationID: Self.operationID,
                           now: now, monotonicNanoseconds: 3)
        }
    }

    @Test func wallAndMonotonicExpiryBothDisarm() throws {
        let faults = try controller(milliseconds: 1)
        try faults.arm(.blockFullFlushNoSpace, challenge: UUID(), operationID: Self.operationID,
                       now: now, monotonicNanoseconds: 0)
        #expect(faults.consumeFullFlush(queueIndex: 0, queueGeneration: 1, now: now, monotonicNanoseconds: 1_000_000) == nil)
        #expect(faults.snapshot(now: now, monotonicNanoseconds: 1_000_001).first?.state == .expired)
        let expired = try controller()
        #expect(throws: DoryRuntimeQualificationFaultError.expired) {
            try expired.arm(.blockFullFlushNoSpace, challenge: UUID(), operationID: Self.operationID,
                            now: now.addingTimeInterval(60), monotonicNanoseconds: 0)
        }
    }

    @Test func armingBudgetIsBoundedAndOnlyOneFaultCanBePending() throws {
        let faults = try controller()
        try faults.arm(.blockFullFlushNoSpace, challenge: UUID(), operationID: Self.operationID,
                       now: now, monotonicNanoseconds: 0)
        #expect(throws: DoryRuntimeQualificationFaultError.alreadyArmed) {
            try faults.arm(.blockFullFlushNoSpace, challenge: UUID(), operationID: Self.operationID,
                           now: now, monotonicNanoseconds: 1)
        }
        faults.cancelPending()
        #expect(throws: DoryRuntimeQualificationFaultError.armingBudgetExhausted) {
            try faults.arm(.blockFullFlushNoSpace, challenge: UUID(), operationID: Self.operationID,
                           now: now, monotonicNanoseconds: 2)
        }
    }

    @Test func aDifferentRuntimeOperationCannotArmTheBackend() throws {
        let faults = try controller()
        #expect(throws: DoryRuntimeQualificationFaultError.invalidIdentity) {
            try faults.arm(.blockFullFlushNoSpace, challenge: UUID(), operationID: UUID(),
                           now: now, monotonicNanoseconds: 0)
        }
        #expect(faults.snapshot(now: now, monotonicNanoseconds: 0).isEmpty)
    }

    @Test func concurrentConsumersSpendOneFaultOnly() throws {
        let faults = try controller()
        try faults.arm(.blockFullFlushNoSpace, challenge: UUID(), operationID: Self.operationID,
                       now: now, monotonicNanoseconds: 0)
        final class Results: @unchecked Sendable {
            let lock = NSLock()
            var consumed = 0
        }
        let results = Results()
        let date = now
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            if faults.consumeFullFlush(queueIndex: 0, queueGeneration: 1, now: date, monotonicNanoseconds: 1) != nil {
                results.lock.withLock { results.consumed += 1 }
            }
        }
        #expect(results.lock.withLock { results.consumed } == 1)
    }
}

private final class RendererCrashAdmissionHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: DoryRendererCrashQualificationAdmission?
    var value: DoryRendererCrashQualificationAdmission? { lock.withLock { stored } }
    func store(_ admission: DoryRendererCrashQualificationAdmission) { lock.withLock { stored = admission } }
}
