import DoryOperations
import Darwin
import Foundation

/// Exact runtime observations, not qualification verdicts. `consumed` means a backend operation
/// failed; only `guestCompleted` proves the error reached the current queue's used ring.
public typealias RuntimeQualificationFaultObservation = DoryRuntimeQualificationFaultObservation

/// All state is guarded by `lock`. The synchronous backend seam never waits for a control
/// callback and never invokes user code under a queue/device lock. An immutable opaque grant
/// is required; production defaults have no controller at all.
public final class RuntimeQualificationFaultController: @unchecked Sendable {
    private let lock = NSLock()
    private let authority: DoryRuntimeQualificationFaultAuthority
    private var observations: [RuntimeQualificationFaultObservation] = []
    private var pending: (index: Int, monotonicDeadline: UInt64)?
    private var protectedPage: (index: Int, memory: GuestMemory, address: UInt64)?
    private var expiryTimer: DispatchSourceTimer?
    private var rendererCrashHandler: (@Sendable (DoryRendererCrashQualificationAdmission) throws -> Void)?
    private var rendererCrashAdmission: (index: Int, admission: DoryRendererCrashQualificationAdmission)?
    private var rendererCrashArmingAllowed = true
    private var rendererCrashArmingClosed = false

    public init(authority: DoryRuntimeQualificationFaultAuthority) throws {
        guard authority.policy.isValid else { throw DoryRuntimeQualificationFaultError.unauthorized }
        self.authority = authority
    }

    deinit { cancelPending() }

    public func connectRendererCrashHandler(
        _ handler: @escaping @Sendable (DoryRendererCrashQualificationAdmission) throws -> Void
    ) {
        lock.withLock { rendererCrashHandler = handler }
    }

    public func handle(
        _ request: DoryRuntimeQualificationFaultRequest, memory: GuestMemory? = nil,
        rendererCrash: (@Sendable (DoryRendererCrashQualificationAdmission) throws -> Void)? = nil
    ) throws -> RuntimeQualificationFaultObservation {
        guard request.matches(authority) else { throw DoryRuntimeQualificationFaultError.invalidIdentity }
        if request.action == .arm, let kind = request.kind {
            if kind == .rendererWorkerCrash {
                guard let rendererCrash = rendererCrash ?? lock.withLock({ rendererCrashHandler }),
                      let generation = request.rendererWorkerGeneration else {
                    throw DoryRuntimeQualificationFaultError.unauthorized
                }
                let admission = try armRendererCrash(challenge: request.challenge,
                    operationID: request.operationID, workerGeneration: generation)
                do { try rendererCrash(admission) }
                catch {
                    rendererCrashAcknowledged(challenge: request.challenge, workerGeneration: generation,
                                              accepted: false, inFlightCommands: 0)
                    throw error
                }
            } else if kind == .mappedPageRepeatedPermission {
                guard let memory, let address = request.guestPhysicalAddress else {
                    throw DoryRuntimeQualificationFaultError.invalidIdentity
                }
                try armMappedPage(address: address, challenge: request.challenge,
                                  operationID: request.operationID, memory: memory)
            } else { try arm(kind, challenge: request.challenge, operationID: request.operationID) }
        } else if request.action == .cancel {
            try lock.withLock {
                guard let index = observations.firstIndex(where: { $0.challenge == request.challenge }) else {
                    throw DoryRuntimeQualificationFaultError.unknownChallenge
                }
                if pending?.index == index {
                    retirePendingLocked(state: .cancelled)
                }
            }
        }
        guard let observation = snapshot().first(where: { $0.challenge == request.challenge }) else {
            throw DoryRuntimeQualificationFaultError.unknownChallenge
        }
        return observation
    }

    private func armRendererCrash(challenge: UUID, operationID: UUID,
                                  workerGeneration: UInt64) throws -> DoryRendererCrashQualificationAdmission {
        let now = Date()
        let monotonic = DispatchTime.now().uptimeNanoseconds
        let admission = try authority.rendererCrashAdmission(challenge: challenge, workerGeneration: workerGeneration,
                                                           now: now, monotonicNanoseconds: monotonic)
        try lock.withLock {
            guard rendererCrashArmingAllowed else { throw DoryRuntimeQualificationFaultError.unauthorized }
            let index = try armLocked(.rendererWorkerCrash, challenge: challenge, operationID: operationID,
                                      now: now, monotonicNanoseconds: monotonic)
            observations[index].state = .crashRequested
            observations[index].rendererWorkerGeneration = workerGeneration
            observations[index].rendererCrashRequestNanoseconds = monotonic
            pending = (index, admission.dispatchDeadlineNanoseconds)
            rendererCrashAdmission = (index, admission)
        }
        return admission
    }

    /// A signed worker ACK establishes only fault acceptance, not that its process has died.
    public func rendererCrashAcknowledged(challenge: UUID, workerGeneration: UInt64,
                                          accepted: Bool, inFlightCommands: UInt32) {
        lock.withLock {
            expireLocked(now: Date(), monotonicNanoseconds: DispatchTime.now().uptimeNanoseconds)
            guard let active = pending, observations[active.index].kind == .rendererWorkerCrash,
                  observations[active.index].challenge == challenge,
                  observations[active.index].rendererWorkerGeneration == workerGeneration,
                  observations[active.index].rendererCrashAcknowledgedNanoseconds == nil else { return }
            let index = active.index
            guard accepted, inFlightCommands <= UInt32(UInt16.max) else {
                observations[index].state = .crashRejected
                rendererCrashAdmission?.admission.cancelDispatch()
                rendererCrashAdmission = nil
                pending = nil
                return
            }
            observations[index].rendererCrashAcknowledgedNanoseconds = DispatchTime.now().uptimeNanoseconds
            observations[index].rendererInFlightCommandCount = inFlightCommands
            if observations[index].rendererWorkerInterruptedNanoseconds != nil {
                observations[index].state = .workerLost
                rendererCrashAdmission = nil
                pending = nil
            }
        }
    }

    /// Only the authenticated channel's actual interruption calls this. Local reset/invalidation,
    /// a command timeout, or a qualification request cannot manufacture worker-loss evidence.
    public func rendererWorkerInterrupted(challenge: UUID, workerGeneration: UInt64) {
        lock.withLock {
            expireLocked(now: Date(), monotonicNanoseconds: DispatchTime.now().uptimeNanoseconds)
            guard let active = pending, observations[active.index].kind == .rendererWorkerCrash,
                  observations[active.index].challenge == challenge,
                  observations[active.index].rendererWorkerGeneration == workerGeneration,
                  observations[active.index].rendererWorkerInterruptedNanoseconds == nil else { return }
            let index = active.index
            observations[index].rendererWorkerInterruptedNanoseconds = DispatchTime.now().uptimeNanoseconds
            if observations[index].rendererCrashAcknowledgedNanoseconds != nil {
                observations[index].state = .workerLost
                rendererCrashAdmission = nil
                pending = nil
            }
        }
    }

    public func arm(
        _ kind: DoryRuntimeQualificationFaultKind,
        challenge: UUID,
        operationID: UUID,
        now: Date = Date(),
        monotonicNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) throws {
        guard kind == .blockFullFlushNoSpace else { throw DoryRuntimeQualificationFaultError.unauthorized }
        try lock.withLock {
            _ = try armLocked(kind, challenge: challenge, operationID: operationID,
                              now: now, monotonicNanoseconds: monotonicNanoseconds)
        }
    }

    private func armLocked(
        _ kind: DoryRuntimeQualificationFaultKind, challenge: UUID, operationID: UUID,
        now: Date, monotonicNanoseconds: UInt64
    ) throws -> Int {
        expireLocked(now: now, monotonicNanoseconds: monotonicNanoseconds)
        guard operationID == authority.operationID,
              challenge != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) else {
            throw DoryRuntimeQualificationFaultError.invalidIdentity
        }
        guard now < authority.expiresAt else { throw DoryRuntimeQualificationFaultError.expired }
        guard authority.policy.permittedFaults.contains(kind) else { throw DoryRuntimeQualificationFaultError.unauthorized }
        guard pending == nil else { throw DoryRuntimeQualificationFaultError.alreadyArmed }
        guard !observations.contains(where: { $0.challenge == challenge }) else {
            throw DoryRuntimeQualificationFaultError.reusedChallenge
        }
        guard observations.count < Int(authority.policy.maximumArmingCount) else {
            throw DoryRuntimeQualificationFaultError.armingBudgetExhausted
        }
        let duration = UInt64(authority.policy.maximumArmedMilliseconds) * 1_000_000
        let (deadline, overflow) = monotonicNanoseconds.addingReportingOverflow(duration)
        guard !overflow else { throw DoryRuntimeQualificationFaultError.invalidIdentity }
        observations.append(RuntimeQualificationFaultObservation(
            challenge: challenge, kind: kind, machineID: authority.machineID,
            operationID: authority.operationID, resolvedPlanSHA256: authority.resolvedPlanSHA256,
            campaignManifestSHA256: authority.campaignManifestSHA256, state: .armed
        ))
        let index = observations.count - 1
        pending = (index, deadline)
        return index
    }

    private func armMappedPage(address: UInt64, challenge: UUID, operationID: UUID, memory: GuestMemory) throws {
        try lock.withLock {
            let index = try armLocked(.mappedPageRepeatedPermission, challenge: challenge,
                                      operationID: operationID, now: Date(),
                                      monotonicNanoseconds: DispatchTime.now().uptimeNanoseconds)
            observations[index].guestPhysicalAddress = address
            observations[index].faultExitCount = 0
            observations[index].retryCount = 0
            observations[index].memoryProtectionRestored = true
            do { try memory.protectQualificationPage(address: address, challenge: challenge) }
            catch {
                pending = nil
                observations[index].state = .cancelled
                throw error
            }
            protectedPage = (index, memory, address)
            observations[index].memoryProtectionRestored = false
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
            let remainingLifetime = max(1, Int(ceil(authority.expiresAt.timeIntervalSinceNow * 1_000)))
            timer.schedule(deadline: .now() + .milliseconds(min(
                Int(authority.policy.maximumArmedMilliseconds), remainingLifetime
            )))
            timer.setEventHandler { [weak self] in _ = self?.snapshot() }
            expiryTimer = timer
            timer.resume()
        }
    }

    /// Only the owner vCPU calls this after an actual already-mapped Hypervisor exception and
    /// the production retry-budget decision. No control request can increment these counters.
    func mappedPageExit(address: UInt64, vcpuIndex: Int, instructionAddress: UInt64,
                        retryAllowed: Bool) -> UUID? {
        lock.withLock {
            expireLocked(now: Date(), monotonicNanoseconds: DispatchTime.now().uptimeNanoseconds)
            guard let active = pending, let page = protectedPage, page.index == active.index,
                  address & ~(GuestMemory.pageSize - 1) == page.address,
                  observations[active.index].state != .restoreFailed else { return nil }
            let index = active.index
            if observations[index].virtualCPUIndex == nil {
                observations[index].virtualCPUIndex = vcpuIndex
                observations[index].instructionAddress = instructionAddress
            }
            // Interference from another CPU/instruction cannot be combined into a fake episode.
            guard observations[index].virtualCPUIndex == vcpuIndex,
                  observations[index].instructionAddress == instructionAddress else {
                retirePendingLocked(state: .cancelled)
                return nil
            }
            let count = (observations[index].faultExitCount ?? 0) + 1
            guard count <= UInt16(MappedPageFaultRetryBudget.maximumRetries + 1),
                  retryAllowed == (count <= UInt16(MappedPageFaultRetryBudget.maximumRetries)) else {
                retirePendingLocked(state: .cancelled)
                return nil
            }
            observations[index].faultExitCount = count
            observations[index].retryCount = min(count, UInt16(MappedPageFaultRetryBudget.maximumRetries))
            observations[index].state = .faulting
            return retryAllowed ? nil : observations[index].challenge
        }
    }

    /// Called only after the owning vCPU's exception-register updates succeed. Restore failure
    /// remains explicit and throws, so the run loop stops instead of continuing with poisoned RAM.
    func mappedPageGuestExceptionInjected(challenge: UUID, exception: String) throws {
        try lock.withLock {
            guard let page = protectedPage, let active = pending, page.index == active.index,
                  observations[page.index].challenge == challenge,
                  observations[page.index].faultExitCount == UInt16(MappedPageFaultRetryBudget.maximumRetries + 1),
                  ["synchronous-external-data-abort", "serror"].contains(exception) else {
                throw DoryRuntimeQualificationFaultError.invalidIdentity
            }
            observations[page.index].guestException = exception
            guard restoreProtectionLocked() else {
                observations[page.index].state = .restoreFailed
                throw DoryRuntimeQualificationFaultError.unauthorized
            }
            observations[page.index].state = .retryEscalated
            pending = nil
            expiryTimer?.cancel()
            expiryTimer = nil
        }
    }

    /// Consumes at most once, at the real backend operation boundary. A queue epoch is optional
    /// only for deterministic host-side unit calls; those cannot be marked guest-completed.
    func consumeFullFlush(
        queueIndex: Int?, queueGeneration: UInt64?,
        now: Date = Date(), monotonicNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> UUID? {
        lock.withLock {
            expireLocked(now: now, monotonicNanoseconds: monotonicNanoseconds)
            guard let active = pending,
                  observations[active.index].kind == .blockFullFlushNoSpace else { return nil }
            pending = nil
            observations[active.index].state = .consumed
            observations[active.index].injectedErrno = ENOSPC
            observations[active.index].queueIndex = queueIndex
            observations[active.index].queueGeneration = queueGeneration
            return observations[active.index].challenge
        }
    }

    func guestCompleted(challenge: UUID, status: UInt8, queueIndex: Int, queueGeneration: UInt64) {
        lock.withLock {
            guard status == 1, let index = observations.firstIndex(where: { $0.challenge == challenge }),
                  observations[index].state == .consumed,
                  observations[index].queueIndex == queueIndex,
                  observations[index].queueGeneration == queueGeneration else { return }
            observations[index].state = .guestCompleted
            observations[index].guestStatus = status
        }
    }

    /// Lifecycle rejection and pending-permit cancellation share the arming lock. A request
    /// that observed "running" immediately before pause/stop cannot arm after this boundary.
    public func suspendRendererCrashArming(permanently: Bool = false) {
        lock.withLock {
            rendererCrashArmingAllowed = false
            if permanently { rendererCrashArmingClosed = true }
            if let pending, observations[pending.index].kind == .rendererWorkerCrash {
                retirePendingLocked(state: .cancelled)
            }
        }
    }

    public func resumeRendererCrashArming() {
        lock.withLock { rendererCrashArmingAllowed = !rendererCrashArmingClosed }
    }

    /// Reset/stop cannot leave an armed fault waiting for a later disk/queue generation.
    public func cancelPending() {
        lock.withLock {
            retirePendingLocked(state: .cancelled)
        }
    }

    /// Checked by the owner run loop; a failed rollback cannot silently continue guest execution.
    func checkProtectionRestoration() throws {
        try lock.withLock {
            expireLocked(now: Date(), monotonicNanoseconds: DispatchTime.now().uptimeNanoseconds)
            if let page = protectedPage, observations[page.index].state == .restoreFailed {
                throw DoryRuntimeQualificationFaultError.unauthorized
            }
        }
    }

    public func snapshot(
        now: Date = Date(), monotonicNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> [RuntimeQualificationFaultObservation] {
        lock.withLock {
            expireLocked(now: now, monotonicNanoseconds: monotonicNanoseconds)
            return observations
        }
    }

    private func expireLocked(now: Date, monotonicNanoseconds: UInt64) {
        if let active = pending,
           now >= authority.expiresAt || monotonicNanoseconds >= active.monotonicDeadline {
            retirePendingLocked(state: .expired)
        }
    }

    private func restoreProtectionLocked() -> Bool {
        guard let page = protectedPage else { return true }
        guard page.memory.restoreQualificationPage(address: page.address,
            challenge: observations[page.index].challenge) else { return false }
        observations[page.index].memoryProtectionRestored = true
        protectedPage = nil
        return true
    }

    private func retirePendingLocked(state: RuntimeQualificationFaultObservation.State) {
        guard let active = pending else { return }
        if rendererCrashAdmission?.index == active.index {
            rendererCrashAdmission?.admission.cancelDispatch()
            rendererCrashAdmission = nil
        }
        if restoreProtectionLocked() {
            observations[active.index].state = state
            pending = nil
        } else { observations[active.index].state = .restoreFailed }
        expiryTimer?.cancel()
        expiryTimer = nil
    }
}
