import Darwin
import DoryRendererWorkerContracts
import DoryRendererWorkerServiceCore
import Foundation
import Testing

@Suite(.serialized)
struct DoryRendererWorkerServiceLifetimeTests {
    @Test func invalidationDuringActivationNeverPublishesLateReceiptOrReopensAdmission() throws {
        let bootstrap = try lifecycleBootstrap()
        let backend = try LifecycleBackend(heldCall: .activation)
        let service = DoryRendererWorkerService(backend: backend)
        let replies = LifecycleBootstrapReply()
        let bootstrapFinished = DispatchSemaphore(value: 0)
        let invalidationFinished = DispatchSemaphore(value: 0)
        let bytes = DoryRendererWorkerBootstrapCodec.encode(bootstrap)
        defer { backend.releaseCall.signal() }
        Thread {
            replies.store(service.bootstrapWithDescriptors(exactBytes: bytes))
            bootstrapFinished.signal()
        }.start()
        try #require(backend.callEntered.wait(timeout: .now() + 2) == .success)
        Thread { service.invalidate(); invalidationFinished.signal() }.start()
        try #require(lifecycleEventually { rejectedAdmission(service) == .failure(.capabilityUnavailable) })
        #expect(invalidationFinished.wait(timeout: .now() + 0.02) == .timedOut)
        #expect(backend.invalidationCount == 0)
        backend.releaseCall.signal()
        try #require(bootstrapFinished.wait(timeout: .now() + 2) == .success)
        try #require(invalidationFinished.wait(timeout: .now() + 2) == .success)
        let response = try #require(replies.value)
        #expect(try DoryRendererWorkerRPCResultCodec.decode(response.result) == .failure(.capabilityUnavailable))
        #expect(response.descriptors.isEmpty)
        #expect(backend.invalidationCount == 1)
        #expect(!backend.invalidatedDuringForeignCall)
        #expect(backend.executionCount == 0)
        #expect(rejectedAdmission(service) == .failure(.capabilityUnavailable))
        #expect(try DoryRendererWorkerRPCResultCodec.decode(service.bootstrap(exactBytes: bytes))
            == .failure(.bootstrapAlreadyAttempted))
    }

    @Test func invalidationDuringArenaExportClosesLateDescriptorAndRetiresActivatedBackend() throws {
        let arenaBytes = DoryRendererWorkerBootstrap.minimumHostVisibleArenaByteCount
        let bootstrap = try lifecycleBootstrap(arenaBytes: arenaBytes)
        let backend = try LifecycleBackend(heldCall: .arenaExport, arenaBytes: arenaBytes)
        let service = DoryRendererWorkerService(backend: backend)
        let replies = LifecycleBootstrapReply()
        let bootstrapFinished = DispatchSemaphore(value: 0)
        let invalidationFinished = DispatchSemaphore(value: 0)
        let bytes = DoryRendererWorkerBootstrapCodec.encode(bootstrap)
        defer { backend.releaseCall.signal() }
        Thread {
            replies.store(service.bootstrapWithDescriptors(exactBytes: bytes))
            bootstrapFinished.signal()
        }.start()
        try #require(backend.callEntered.wait(timeout: .now() + 2) == .success)
        Thread { service.invalidate(); invalidationFinished.signal() }.start()
        try #require(lifecycleEventually { rejectedAdmission(service) == .failure(.capabilityUnavailable) })
        #expect(invalidationFinished.wait(timeout: .now() + 0.02) == .timedOut)
        backend.releaseCall.signal()
        try #require(bootstrapFinished.wait(timeout: .now() + 2) == .success)
        try #require(invalidationFinished.wait(timeout: .now() + 2) == .success)
        let response = try #require(replies.value)
        #expect(try DoryRendererWorkerRPCResultCodec.decode(response.result) == .failure(.capabilityUnavailable))
        #expect(response.descriptors.isEmpty)
        let exported = try #require(backend.lastExportedDescriptor)
        #expect(fcntl(exported, F_GETFD) == -1)
        #expect(errno == EBADF)
        #expect(backend.invalidationCount == 1)
        #expect(!backend.invalidatedDuringForeignCall)
    }

    @Test func reentrantActivationInvalidationDefersCleanupUntilForeignCallUnwinds() throws {
        let holder = LifecycleServiceHolder()
        let backend = try LifecycleBackend(onActivate: { holder.value?.invalidate() })
        let service = DoryRendererWorkerService(backend: backend)
        holder.store(service)
        let bootstrap = try lifecycleBootstrap()
        let finished = DispatchSemaphore(value: 0)
        let replies = LifecycleBootstrapReply()
        let bytes = DoryRendererWorkerBootstrapCodec.encode(bootstrap)
        Thread {
            replies.store(service.bootstrapWithDescriptors(exactBytes: bytes))
            finished.signal()
        }.start()
        try #require(finished.wait(timeout: .now() + 2) == .success)
        service.invalidate() // Join any reentrant cleanup queued after the bootstrap owner.
        let response = try #require(replies.value)
        #expect(try DoryRendererWorkerRPCResultCodec.decode(response.result) == .failure(.capabilityUnavailable))
        #expect(response.descriptors.isEmpty)
        #expect(backend.invalidationCount == 1)
        #expect(!backend.invalidatedDuringForeignCall)
    }

    @Test func invalidationRejectsHeldExchangeAndQueuedSuccessorWithoutMoreForeignExecution() throws {
        let bootstrap = try lifecycleBootstrap()
        let backend = try LifecycleBackend(heldCall: .execution)
        let service = DoryRendererWorkerService(backend: backend)
        _ = service.bootstrap(exactBytes: DoryRendererWorkerBootstrapCodec.encode(bootstrap))
        let replies = LifecycleExchangeReplies()
        let replyFinished = DispatchSemaphore(value: 0)
        let invalidationFinished = DispatchSemaphore(value: 0)
        defer { backend.releaseCall.signal() }
        for requestID in UInt64(1)...2 {
            service.exchangeAsynchronously(exactFrame: try lifecycleResetFrame(bootstrap, requestID: requestID),
                descriptors: []) { bytes, descriptors, _ in
                for descriptor in descriptors { try? descriptor.close() }
                replies.store(bytes)
                replyFinished.signal()
            }
        }
        try #require(backend.callEntered.wait(timeout: .now() + 2) == .success)
        Thread { service.invalidate(); invalidationFinished.signal() }.start()
        try #require(lifecycleEventually { rejectedAdmission(service) == .failure(.capabilityUnavailable) })
        #expect(invalidationFinished.wait(timeout: .now() + 0.02) == .timedOut)
        backend.releaseCall.signal()
        try #require(replyFinished.wait(timeout: .now() + 2) == .success)
        try #require(replyFinished.wait(timeout: .now() + 2) == .success)
        try #require(invalidationFinished.wait(timeout: .now() + 2) == .success)
        #expect(replies.values.count == 2)
        for reply in replies.values {
            #expect(try DoryRendererWorkerRPCResultCodec.decode(reply) == .failure(.capabilityUnavailable))
        }
        #expect(backend.executionCount == 1)
        #expect(backend.invalidationCount == 1)
        #expect(!backend.invalidatedDuringForeignCall)
        #expect(service.metricsSnapshot().currentQueueDepth == 0)
    }

    @Test func reentrantExchangeCompletionInvalidationDoesNotDeadlockOrRepeatCleanup() throws {
        let bootstrap = try lifecycleBootstrap()
        let backend = try LifecycleBackend()
        let service = DoryRendererWorkerService(backend: backend)
        _ = service.bootstrap(exactBytes: DoryRendererWorkerBootstrapCodec.encode(bootstrap))
        let finished = DispatchSemaphore(value: 0)
        service.exchangeAsynchronously(exactFrame: try lifecycleResetFrame(bootstrap, requestID: 1),
            descriptors: []) { _, descriptors, _ in
            for descriptor in descriptors { try? descriptor.close() }
            service.invalidate()
            finished.signal()
        }
        try #require(finished.wait(timeout: .now() + 2) == .success)
        service.invalidate()
        #expect(backend.invalidationCount == 1)
        #expect(rejectedAdmission(service) == .failure(.capabilityUnavailable))
    }

    @Test func malformedOversizedBackendReplyClosesExplicitlyOwnedDescriptors() throws {
        let bootstrap = try lifecycleBootstrap()
        let backend = try LifecycleBackend(oversizedReplyPayloadByteCount: bootstrap.limits.maximumCommandBytes + 1)
        let service = DoryRendererWorkerService(backend: backend)
        _ = service.bootstrap(exactBytes: DoryRendererWorkerBootstrapCodec.encode(bootstrap))
        let response = service.exchange(exactFrame: try lifecycleResetFrame(bootstrap, requestID: 1), descriptors: [])
        #expect(try DoryRendererWorkerRPCResultCodec.decode(response.result) == .failure(.protocolViolation))
        #expect(response.descriptors.isEmpty)
        let rejectedDescriptor = try #require(backend.lastReplyDescriptor)
        #expect(fcntl(rejectedDescriptor, F_GETFD) == -1)
        #expect(errno == EBADF)
        #expect(backend.invalidationCount == 1)
    }
}

private func lifecycleBootstrap(arenaBytes: UInt64 = 0) throws -> DoryRendererWorkerBootstrap {
    func digest(_ seed: UInt8) throws -> DoryRendererArtifactDigest {
        try DoryRendererArtifactDigest(bytes: Data(repeating: seed, count: 32))
    }
    return try DoryRendererWorkerBootstrap(workspaceID: DoryRendererWorkspaceID(rawValue: UUID()),
        generation: DoryRendererWorkerGeneration(rawValue: 1), sourceTuple: .productionCandidate,
        producerFenceContract: .managedLinux612106PrepareFBV1,
        requestedCapabilities: .productionAcceleration,
        artifacts: DoryRendererArtifactManifest(candidateInventory: digest(1),
            managedGuestKernel: digest(2), guestMesa: digest(3), rendererWorkerExecutable: digest(4),
            rendererWorkerCodeDirectoryHash: DoryCodeDirectoryHash(
                bytes: Data(repeating: 5, count: DoryCodeDirectoryHash.byteCount))),
        hostVisibleArenaByteCount: arenaBytes)
}

private func lifecycleResetFrame(_ bootstrap: DoryRendererWorkerBootstrap, requestID: UInt64) throws -> Data {
    let payload = withUnsafeBytes(of: UInt64(2).littleEndian) { Data($0) }
    return try DoryRendererWorkerCommandCodec.encode(DoryRendererWorkerCommand(
        generation: bootstrap.generation, requestID: requestID, operation: .resetAfterDeviceQuiesce,
        deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 5_000_000_000,
        payload: payload, limits: bootstrap.limits), limits: bootstrap.limits)
}

private func rejectedAdmission(_ service: DoryRendererWorkerService) -> DoryRendererWorkerRPCResult? {
    let replies = LifecycleExchangeReplies()
    service.exchangeAsynchronously(exactFrame: Data(), descriptors: []) { bytes, descriptors, _ in
        for descriptor in descriptors { try? descriptor.close() }
        replies.store(bytes)
    }
    guard let bytes = replies.values.first else { return nil }
    return try? DoryRendererWorkerRPCResultCodec.decode(bytes)
}

private func lifecycleEventually(_ predicate: () -> Bool) -> Bool {
    let deadline = Date(timeIntervalSinceNow: 2)
    while Date() < deadline {
        if predicate() { return true }
        Thread.sleep(forTimeInterval: 0.002)
    }
    return predicate()
}

private final class LifecycleBootstrapReply: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (result: Data, descriptors: [FileHandle])?
    var value: (result: Data, descriptors: [FileHandle])? { lock.withLock { stored } }
    func store(_ value: (result: Data, descriptors: [FileHandle])) { lock.withLock { stored = value } }
}

private final class LifecycleExchangeReplies: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Data] = []
    var values: [Data] { lock.withLock { stored } }
    func store(_ bytes: Data) { lock.withLock { stored.append(bytes) } }
}

private final class LifecycleServiceHolder: @unchecked Sendable {
    private let lock = NSLock()
    private weak var service: DoryRendererWorkerService?
    var value: DoryRendererWorkerService? { lock.withLock { service } }
    func store(_ service: DoryRendererWorkerService) { lock.withLock { self.service = service } }
}

private final class LifecycleBackend: DoryRendererWorkerBackend, @unchecked Sendable {
    enum HeldCall { case activation, arenaExport, execution }
    let callEntered = DispatchSemaphore(value: 0)
    let releaseCall = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let heldCall: HeldCall?
    private let onActivate: (@Sendable () -> Void)?
    private let arenaDescriptor: Int32
    private let replyDescriptor: Int32
    private let oversizedReplyPayloadByteCount: Int
    private var storedInvalidationCount = 0
    private var storedExecutionCount = 0
    private var storedExportedDescriptor: Int32?
    private var storedReplyDescriptor: Int32?
    private var foreignCallActive = false
    private var storedInvalidatedDuringForeignCall = false

    var invalidationCount: Int { lock.withLock { storedInvalidationCount } }
    var executionCount: Int { lock.withLock { storedExecutionCount } }
    var lastExportedDescriptor: Int32? { lock.withLock { storedExportedDescriptor } }
    var lastReplyDescriptor: Int32? { lock.withLock { storedReplyDescriptor } }
    var invalidatedDuringForeignCall: Bool { lock.withLock { storedInvalidatedDuringForeignCall } }

    init(heldCall: HeldCall? = nil, arenaBytes: UInt64 = 0, oversizedReplyPayloadByteCount: Int = 0,
         onActivate: (@Sendable () -> Void)? = nil) throws {
        self.heldCall = heldCall
        self.onActivate = onActivate
        self.oversizedReplyPayloadByteCount = oversizedReplyPayloadByteCount
        let arena = try Self.fixtureDescriptor(byteCount: arenaBytes)
        do {
            replyDescriptor = try Self.fixtureDescriptor(byteCount: oversizedReplyPayloadByteCount == 0 ? 0 : 16)
            arenaDescriptor = arena
        } catch {
            if arena >= 0 { close(arena) }
            throw error
        }
    }

    deinit {
        if arenaDescriptor >= 0 { close(arenaDescriptor) }
        if replyDescriptor >= 0 { close(replyDescriptor) }
    }

    func activate(bootstrap: DoryRendererWorkerBootstrap) throws -> DoryRendererCapabilityReceipt {
        lock.withLock { foreignCallActive = true }
        defer { lock.withLock { foreignCallActive = false } }
        onActivate?()
        try holdIfNeeded(.activation)
        return try DoryRendererCapabilityReceipt(accepting: bootstrap, features: .productionAcceleration,
            capsets: [DoryRendererCapsetAttestation(id: 2, maximumVersion: 1, data: Data([2])),
                      DoryRendererCapsetAttestation(id: 4, maximumVersion: 0, data: Data([4]))])
    }

    func execute(command _: DoryRendererWorkerCommand, descriptors _: [FileHandle]) throws
        -> DoryRendererWorkerBackendExecution {
        lock.withLock { foreignCallActive = true; storedExecutionCount += 1 }
        defer { lock.withLock { foreignCallActive = false } }
        try holdIfNeeded(.execution)
        if oversizedReplyPayloadByteCount > 0 {
            let descriptor = fcntl(replyDescriptor, F_DUPFD_CLOEXEC, 0)
            guard descriptor >= 0 else { throw POSIXError(.EIO) }
            lock.withLock { storedReplyDescriptor = descriptor }
            // Explicit ownership: ARC does not close this descriptor on a rejected output.
            return .success(payload: Data(repeating: 0, count: oversizedReplyPayloadByteCount),
                descriptors: [FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)])
        }
        return .success(payload: Data(), descriptors: [])
    }

    func hostVisibleArenaDescriptor() throws -> FileHandle? {
        guard arenaDescriptor >= 0 else { return nil }
        lock.withLock { foreignCallActive = true }
        defer { lock.withLock { foreignCallActive = false } }
        try holdIfNeeded(.arenaExport)
        let exported = fcntl(arenaDescriptor, F_DUPFD_CLOEXEC, 0)
        guard exported >= 0 else { throw POSIXError(.EIO) }
        lock.withLock { storedExportedDescriptor = exported }
        return FileHandle(fileDescriptor: exported, closeOnDealloc: true)
    }

    func invalidate() {
        lock.withLock {
            storedInvalidationCount += 1
            storedInvalidatedDuringForeignCall = storedInvalidatedDuringForeignCall || foreignCallActive
        }
    }

    private func holdIfNeeded(_ call: HeldCall) throws {
        guard heldCall == call else { return }
        callEntered.signal()
        guard releaseCall.wait(timeout: .now() + 5) == .success else { throw POSIXError(.ETIMEDOUT) }
    }

    private static func fixtureDescriptor(byteCount: UInt64) throws -> Int32 {
        guard byteCount > 0 else { return -1 }
        var template = Array("/tmp/dory-service-lifetime.XXXXXX".utf8CString)
        let fd = template.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
        guard fd >= 0 else { throw POSIXError(.EIO) }
        guard fchmod(fd, S_IRUSR | S_IWUSR) == 0, ftruncate(fd, off_t(byteCount)) == 0,
              template.withUnsafeBufferPointer({ unlink($0.baseAddress!) }) == 0 else {
            close(fd)
            template.withUnsafeBufferPointer { _ = unlink($0.baseAddress!) }
            throw POSIXError(.EIO)
        }
        return fd
    }
}
