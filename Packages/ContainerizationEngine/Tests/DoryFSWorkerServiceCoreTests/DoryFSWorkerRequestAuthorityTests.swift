import Darwin
import DoryFSWorkerContracts
import Foundation
import Testing
@testable import DoryFSWorkerServiceCore

@Suite(.serialized)
struct DoryFSWorkerRequestAuthorityTests {
    @Test(arguments: RevokedHostOperation.allCases)
    func invalidationPreventsAdmittedWorkFromAcquiringHostAuthority(
        operation: RevokedHostOperation
    ) async throws {
        let fixture = try RequestAuthorityFixture()
        let request = try fixture.prepare(operation)
        fixture.pause.arm()
        defer { fixture.pause.resume() }
        let task = Task.detached { try fixture.execute(request) }
        try #require(await fixture.pause.waitUntilPaused() == .success)

        try fixture.send(.invalidate(DoryFSWorkerInvalidation(
            generation: fixture.bootstrap.generation,
            shareCapabilityID: fixture.share.capabilityID
        )))
        // Invalidation does not prematurely close a handle borrowed by admitted work.
        #expect(try fixture.snapshot().fileHandles == (operation == .open || operation == .create ? 2 : 1))
        #expect(try fixture.snapshot().directoryHandles == 1)
        fixture.pause.resume()

        let outcome = try await task.value
        #expect(outcome == .rejected(.shuttingDown))
        try fixture.expectUnchangedHostTree()
        let resources = try fixture.snapshot()
        #expect(resources.fileHandles == 0)
        #expect(resources.directoryHandles == 0)
        #expect(resources.liveNonRootNodes == 0)
        #expect(resources.advisoryLockOwners == 0)
        #expect(resources.pendingBlockingLocks == 0)
        // Neither a late reply nor a duplicate control frame reactivates retired authority.
        #expect(try fixture.execute(request) == .rejected(.shuttingDown))
    }

    @Test func interruptCancelsLoadedWriteAndDoesNotPoisonReusedRequestIdentity() async throws {
        let fixture = try RequestAuthorityFixture()
        let request = try fixture.prepare(.write)
        fixture.pause.arm()
        defer { fixture.pause.resume() }
        let task = Task.detached { try fixture.execute(request) }
        try #require(await fixture.pause.waitUntilPaused() == .success)
        try fixture.send(.interrupt(DoryFSWorkerInterrupt(
            generation: request.generation,
            shareCapabilityID: request.shareCapabilityID,
            targetRequestID: request.requestID,
            targetCorrelationID: request.correlationID,
            deadlineUptimeNanoseconds: request.deadlineUptimeNanoseconds
        )))
        fixture.pause.resume()

        let outcome = try await task.value
        let response = try completedPayload(outcome)
        #expect(try FuseProtocol.decodeOutHeader(response).error == -EINTR)
        try fixture.expectUnchangedHostTree()
        try fixture.commit(request)

        // Both IDs can be reused only after the old publication has retired. Its cancellation
        // marker must not survive that lifetime and deny the successor's independent authority.
        let successor = try fixture.request(
            opcode: .write,
            nodeID: try FuseProtocol.decodeInHeader([UInt8](request.payload)).nodeID,
            payload: Array(request.payload.dropFirst(FuseInHeader.byteCount)),
            requestID: request.requestID,
            correlationID: request.correlationID
        )
        #expect(try FuseProtocol.decodeOutHeader(
            completedPayload(fixture.execute(successor))
        ).error == 0)
        try fixture.commit(successor)
        #expect(try String(contentsOf: fixture.fileURL, encoding: .utf8) == "replaced!")
    }

    @Test(arguments: StaleInterrupt.allCases)
    func interruptMustMatchTheExactActiveReservation(mismatch: StaleInterrupt) async throws {
        let fixture = try RequestAuthorityFixture()
        let request = try fixture.prepare(.write)
        fixture.pause.arm()
        defer { fixture.pause.resume() }
        let task = Task.detached { try fixture.execute(request) }
        try #require(await fixture.pause.waitUntilPaused() == .success)
        try fixture.send(.interrupt(DoryFSWorkerInterrupt(
            generation: mismatch == .generation
                ? DoryFSWorkerGeneration(rawValue: 18) : request.generation,
            shareCapabilityID: mismatch == .share
                ? DoryFSShareCapabilityID(rawValue: UUID()) : request.shareCapabilityID,
            targetRequestID: request.requestID + (mismatch == .requestID ? 1 : 0),
            targetCorrelationID: request.correlationID + (mismatch == .correlationID ? 1 : 0),
            deadlineUptimeNanoseconds: request.deadlineUptimeNanoseconds
        )))
        fixture.pause.resume()

        #expect(try FuseProtocol.decodeOutHeader(completedPayload(await task.value)).error == 0)
        try fixture.commit(request)
        #expect(try String(contentsOf: fixture.fileURL, encoding: .utf8) == "replaced!")
    }

    @Test func deadlineIsCheckedAgainAfterFileHandleAcquisition() async throws {
        let fixture = try RequestAuthorityFixture()
        let original = try fixture.prepare(.write)
        let deadline = DispatchTime.now().uptimeNanoseconds + 250_000_000
        let request = try fixture.request(
            opcode: .write,
            nodeID: try FuseProtocol.decodeInHeader([UInt8](original.payload)).nodeID,
            payload: Array(original.payload.dropFirst(FuseInHeader.byteCount)),
            requestID: original.requestID,
            correlationID: original.correlationID,
            deadline: deadline
        )
        fixture.pause.arm()
        defer { fixture.pause.resume() }
        let task = Task.detached { try fixture.execute(request) }
        try #require(await fixture.pause.waitUntilPaused() == .success)
        while DispatchTime.now().uptimeNanoseconds < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        fixture.pause.resume()

        #expect(try await task.value == .rejected(.deadlineExpired))
        try fixture.expectUnchangedHostTree()
        // Deadline expiry retires only this request, not the still-authorized share/handle.
        #expect(try fixture.snapshot().fileHandles == 1)
        let successor = try fixture.request(
            opcode: .write,
            nodeID: try FuseProtocol.decodeInHeader([UInt8](original.payload)).nodeID,
            payload: Array(original.payload.dropFirst(FuseInHeader.byteCount)),
            requestID: original.requestID,
            correlationID: original.correlationID
        )
        #expect(try FuseProtocol.decodeOutHeader(
            completedPayload(fixture.execute(successor))
        ).error == 0)
        try fixture.commit(successor)
    }

    @Test(arguments: [false, true])
    func delayedInterruptWakeCannotCancelSuccessorWithReusedCorrelationID(
        reuseRequestID: Bool
    ) async throws {
        let fixture = try RequestAuthorityFixture()
        let original = try fixture.prepare(.write)
        let fileDescriptor = Darwin.open(fixture.fileURL.path, O_RDWR | O_CLOEXEC)
        try #require(fileDescriptor >= 0)
        defer { Darwin.close(fileDescriptor) }
        var hostLock = flock()
        hostLock.l_type = Int16(F_WRLCK)
        hostLock.l_whence = Int16(SEEK_SET)
        try #require(fcntl(fileDescriptor, F_OFD_SETLK, &hostLock) == 0)

        fixture.pause.arm()
        defer { fixture.pause.resume(); fixture.interruptPause.resume() }
        let originalTask = Task.detached { try fixture.execute(original) }
        try #require(await fixture.pause.waitUntilPaused() == .success)
        fixture.interruptPause.arm()
        let delayedInterrupt = Task.detached {
            try fixture.send(.interrupt(DoryFSWorkerInterrupt(
                generation: original.generation,
                shareCapabilityID: original.shareCapabilityID,
                targetRequestID: original.requestID,
                targetCorrelationID: original.correlationID,
                deadlineUptimeNanoseconds: original.deadlineUptimeNanoseconds
            )))
        }
        try #require(await fixture.interruptPause.waitUntilPaused() == .success)
        // Request-local cancellation is already visible, even though its wake delivery is held.
        fixture.pause.resume()
        #expect(try FuseProtocol.decodeOutHeader(completedPayload(await originalTask.value)).error == -EINTR)
        try fixture.commit(original)

        let fileHandle = Array(original.payload.dropFirst(FuseInHeader.byteCount)).leUInt64(at: 0)
        let successor = try fixture.request(
            opcode: .setlkw,
            nodeID: try FuseProtocol.decodeInHeader([UInt8](original.payload)).nodeID,
            payload: littleEndianBytes(fileHandle) + littleEndianBytes(UInt64(99))
                + littleEndianBytes(UInt64(0)) + littleEndianBytes(UInt64.max)
                + littleEndianBytes(UInt32(1)) + littleEndianBytes(UInt32(42))
                + littleEndianBytes(UInt32(0)) + littleEndianBytes(UInt32(0)),
            requestID: original.requestID + (reuseRequestID ? 0 : 1),
            correlationID: original.correlationID
        )
        let successorTask = Task.detached { try fixture.execute(successor) }
        let admissionDeadline = ContinuousClock.now + .seconds(2)
        while try fixture.snapshot().pendingBlockingLocks != 1, ContinuousClock.now < admissionDeadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        try #require(fixture.snapshot().pendingBlockingLocks == 1)
        fixture.interruptPause.resume()
        try await delayedInterrupt.value
        // More than two lock-poll intervals prove the old delivery carried no cancellation state
        // into the successor. Its host conflict remains until its own exact interrupt arrives.
        try await Task.sleep(for: .milliseconds(60))
        #expect(try fixture.snapshot().pendingBlockingLocks == 1)
        try fixture.send(.interrupt(DoryFSWorkerInterrupt(
            generation: successor.generation,
            shareCapabilityID: successor.shareCapabilityID,
            targetRequestID: successor.requestID,
            targetCorrelationID: successor.correlationID,
            deadlineUptimeNanoseconds: successor.deadlineUptimeNanoseconds
        )))
        #expect(try FuseProtocol.decodeOutHeader(completedPayload(await successorTask.value)).error == -EINTR)
        try fixture.commit(successor)
        #expect(try fixture.snapshot().pendingBlockingLocks == 0)
        #expect(try fixture.snapshot().advisoryLockOwners == 0)
        try fixture.expectUnchangedHostTree()
    }

    @Test func committedDestroyRetiresHandlesWhenLastActiveRequestExpires() async throws {
        let fixture = try RequestAuthorityFixture()
        let original = try fixture.prepare(.write)
        let deadline = DispatchTime.now().uptimeNanoseconds + 250_000_000
        let request = try fixture.request(
            opcode: .write,
            nodeID: try FuseProtocol.decodeInHeader([UInt8](original.payload)).nodeID,
            payload: Array(original.payload.dropFirst(FuseInHeader.byteCount)),
            requestID: original.requestID, correlationID: original.correlationID,
            deadline: deadline
        )
        fixture.pause.arm()
        defer { fixture.pause.resume() }
        let task = Task.detached { try fixture.execute(request) }
        try #require(await fixture.pause.waitUntilPaused() == .success)
        let destroy = try fixture.request(opcode: .destroy, nodeID: 0, requestID: 20)
        #expect(try FuseProtocol.decodeOutHeader(completedPayload(fixture.execute(destroy))).error == 0)
        try fixture.commit(destroy)
        #expect(try fixture.snapshot().fileHandles == 1)
        while DispatchTime.now().uptimeNanoseconds < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        fixture.pause.resume()

        #expect(try await task.value == .rejected(.deadlineExpired))
        try fixture.expectUnchangedHostTree()
        let resources = try fixture.snapshot()
        #expect(resources.fileHandles == 0)
        #expect(resources.directoryHandles == 0)
        #expect(resources.liveNonRootNodes == 0)
        let successor = try fixture.request(
            opcode: .getattr, payload: FuseProtocol.encodeGetattrIn(FuseGetattrIn()), requestID: 21
        )
        #expect(try fixture.execute(successor) == .rejected(.connectionTeardown))
    }

    @Test func oversizedReplyRetiresOlderUnpublishedGrantsBeforeActiveWorkUnwinds() async throws {
        let fixture = try RequestAuthorityFixture()
        let write = try fixture.prepare(.write)
        let nodeID = try FuseProtocol.decodeInHeader([UInt8](write.payload)).nodeID
        fixture.pause.arm()
        defer { fixture.pause.resume() }
        let task = Task.detached { try fixture.execute(write) }
        try #require(await fixture.pause.waitUntilPaused() == .success)

        let unpublishedOpen = try fixture.request(
            opcode: .open, nodeID: nodeID,
            payload: littleEndianBytes(UInt32(2)) + littleEndianBytes(UInt32(0)), requestID: 20
        )
        _ = try completedPayload(fixture.execute(unpublishedOpen))
        #expect(try fixture.snapshot().fileHandles == 2)
        let oversized = try fixture.request(
            opcode: .getattr, payload: FuseProtocol.encodeGetattrIn(FuseGetattrIn()),
            requestID: 21, responseCapacity: UInt32(FuseOutHeader.byteCount)
        )
        #expect(try fixture.execute(oversized) == .rejected(.internalFailure))
        // The older uncommitted OPEN is rolled back now. The admitted write still keeps its own
        // handle alive, so a global connection reset must not run until that write returns.
        #expect(try fixture.snapshot().fileHandles == 1)
        #expect(try fixture.snapshot().directoryHandles == 1)
        fixture.pause.resume()

        #expect(try await task.value == .rejected(.shuttingDown))
        try fixture.expectUnchangedHostTree()
        #expect(try fixture.snapshot().fileHandles == 0)
        #expect(try fixture.snapshot().directoryHandles == 0)
        // A late publication acknowledgement cannot resurrect the rolled-back grant.
        try fixture.commit(unpublishedOpen)
        #expect(try fixture.snapshot().fileHandles == 0)
    }

    @Test func interruptedPartialDirectoryEnumerationBalancesUnpublishedLookups() throws {
        let fixture = try RequestAuthorityFixture()
        let server = try FuseServer(hostFS: HostFS(rootPath: fixture.root.path))
        let open = server.handle(request: fuseRequest(
            opcode: .opendir, unique: 1, nodeID: HostFS.rootNodeID, payload: []
        ))
        let directoryHandle = try responsePayload(open).leUInt64(at: 0)
        let authorization = AuthorizationBudget(successfulChecks: 9)
        let response = server.handle(request: fuseRequest(
            opcode: .readdirplus,
            unique: 2,
            nodeID: HostFS.rootNodeID,
            payload: readWritePayload(handle: directoryHandle, size: 16_384)
        ), authorization: { authorization.check() })

        #expect(try FuseProtocol.decodeOutHeader(response).error == -EINTR)
        #expect(server.resourceSnapshot.liveNonRootNodes == 0)
        #expect(server.resourceSnapshot.directoryCursorEntries > 0)
        server.resetConnection()
        #expect(server.resourceSnapshot.directoryHandles == 0)
        #expect(server.resourceSnapshot.directoryCursorEntries == 0)
        #expect(server.resourceSnapshot.directoryCursorNameBytes == 0)
    }

    @Test(arguments: [FuseOpcode.forget, .batchForget, .interrupt])
    func revokedOneWayOperationsStillNeverEmitFuseReplies(opcode: FuseOpcode) throws {
        let fixture = try RequestAuthorityFixture()
        let server = try FuseServer(hostFS: HostFS(rootPath: fixture.root.path))
        #expect(server.handle(request: fuseRequest(
            opcode: opcode, unique: 1, nodeID: HostFS.rootNodeID, payload: []
        ), authorization: { false }).isEmpty)
    }
}

enum RevokedHostOperation: CaseIterable, Sendable {
    case write, create, mkdir, symlink, link, setattr, unlink, rmdir, rename
    case open, opendir, read, readdirplus, fsync, getlk, setlk, setlkw
    case lookup, getattr, readlink, statfs
}

enum StaleInterrupt: CaseIterable, Sendable {
    case generation, share, requestID, correlationID
}

private final class RequestAuthorityFixture: @unchecked Sendable {
    let root: URL
    let fileURL: URL
    let pause = HostOperationPause()
    let interruptPause = HostOperationPause()
    let probe = ServerResourceProbe()
    let bootstrap: DoryFSWorkerBootstrap
    let share: DoryFSShareBootstrapAuthority
    let service: DoryFSWorkerService
    private let originalStatus: stat

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "dory-fs-request-authority-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        fileURL = root.appendingPathComponent("existing.txt")
        try "untouched".write(to: fileURL, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("existing-dir"), withIntermediateDirectories: false
        )
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("existing-link").path,
            withDestinationPath: "existing.txt"
        )
        originalStatus = try fileStatus(fileURL)
        let fd = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var status = stat()
        guard fstat(fd, &status) == 0 else { throw POSIXError(.EIO) }
        share = try DoryFSShareBootstrapAuthority(
            capabilityID: DoryFSShareCapabilityID(rawValue: UUID()),
            expectedRootIdentity: DoryFSPinnedRootIdentity(
                device: UInt64(truncatingIfNeeded: status.st_dev),
                inode: UInt64(truncatingIfNeeded: status.st_ino),
                generation: UInt64(truncatingIfNeeded: status.st_gen)
            ),
            readOnly: false,
            coherencePolicy: .disabled,
            guestIdentity: DoryFSGuestIdentityPolicy(uid: 1_000, gid: 1_000),
            resourceLimits: .production,
            rootDescriptorIndex: 0
        )
        bootstrap = try DoryFSWorkerBootstrap(
            workspaceID: DoryFSWorkerWorkspaceID(rawValue: UUID()),
            generation: DoryFSWorkerGeneration(rawValue: 17),
            workerLimits: .production,
            shares: [share]
        )
        let operationPause = pause
        let interruptWakePause = interruptPause
        let resourceProbe = probe
        service = DoryFSWorkerService(
            rootAuthority: DoryFSWorkerRootAuthority(
                bootstrapAdmission: DoryFSWorkerBootstrapAdmission()
            ),
            configureServer: { server in
                resourceProbe.install(server)
                server.fileOperationLoadedTestHook = { operationPause.pauseIfArmed() }
                server.beforeHostOperationTestHook = { operationPause.pauseIfArmed() }
            },
            beforeInterruptWakeTestHook: { interruptWakePause.pauseIfArmed() }
        )
        let result = try DoryFSWorkerRPCResultCodec.decode(service.bootstrap(
            exactBytes: DoryFSWorkerBootstrapCodec.encode(bootstrap), rootDescriptors: [handle]
        ))
        guard case .success = result else { throw RequestAuthorityError.unexpectedServiceReply }
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func prepare(_ operation: RevokedHostOperation) throws -> DoryFSWorkerRequest {
        let lookup = try request(opcode: .lookup, payload: Array("existing.txt\0".utf8), requestID: 1)
        let lookupResponse = try completedPayload(execute(lookup))
        let nodeID = try responsePayload(lookupResponse).leUInt64(at: 0)
        try commit(lookup)
        let open = try request(
            opcode: .open, nodeID: nodeID,
            payload: littleEndianBytes(UInt32(2)) + littleEndianBytes(UInt32(0)), requestID: 2
        )
        let fileHandle = try responsePayload(completedPayload(execute(open))).leUInt64(at: 0)
        try commit(open)
        let opendir = try request(opcode: .opendir, requestID: 3)
        let directoryHandle = try responsePayload(completedPayload(execute(opendir))).leUInt64(at: 0)
        try commit(opendir)
        let payload: [UInt8]
        let opcode: FuseOpcode
        var requestNodeID = HostFS.rootNodeID
        switch operation {
        case .write:
            opcode = .write; requestNodeID = nodeID
            payload = readWritePayload(handle: fileHandle, size: 9) + Array("replaced!".utf8)
        case .create:
            opcode = .create
            payload = littleEndianBytes(UInt32(0x40 | 2)) + littleEndianBytes(UInt32(0o644))
                + littleEndianBytes(UInt32(0)) + littleEndianBytes(UInt32(0)) + Array("created\0".utf8)
        case .mkdir:
            opcode = .mkdir
            payload = littleEndianBytes(UInt32(0o755)) + littleEndianBytes(UInt32(0)) + Array("created\0".utf8)
        case .symlink:
            opcode = .symlink; payload = Array("created\0existing.txt\0".utf8)
        case .link:
            opcode = .link; payload = littleEndianBytes(nodeID) + Array("created\0".utf8)
        case .setattr:
            opcode = .setattr; requestNodeID = nodeID
            payload = FuseProtocol.encodeSetattrIn(FuseSetattrIn(
                valid: [.size, .fileHandle], fileHandle: fileHandle, size: 0
            ))
        case .unlink:
            opcode = .unlink; payload = Array("existing.txt\0".utf8)
        case .rmdir:
            opcode = .rmdir; payload = Array("existing-dir\0".utf8)
        case .rename:
            opcode = .rename
            payload = littleEndianBytes(HostFS.rootNodeID) + Array("existing.txt\0renamed\0".utf8)
        case .open:
            opcode = .open; requestNodeID = nodeID
            payload = littleEndianBytes(UInt32(2)) + littleEndianBytes(UInt32(0))
        case .opendir:
            opcode = .opendir; payload = []
        case .read:
            opcode = .read; requestNodeID = nodeID
            payload = readWritePayload(handle: fileHandle, size: 9)
        case .readdirplus:
            opcode = .readdirplus; payload = readWritePayload(handle: directoryHandle, size: 16_384)
        case .fsync:
            opcode = .fsync; requestNodeID = nodeID
            payload = littleEndianBytes(fileHandle) + littleEndianBytes(UInt64(0))
        case .getlk, .setlk, .setlkw:
            opcode = operation == .getlk ? .getlk : (operation == .setlk ? .setlk : .setlkw)
            requestNodeID = nodeID
            payload = littleEndianBytes(fileHandle) + littleEndianBytes(UInt64(77))
                + littleEndianBytes(UInt64(0)) + littleEndianBytes(UInt64.max)
                + littleEndianBytes(UInt32(1)) + littleEndianBytes(UInt32(42))
                + littleEndianBytes(UInt32(0)) + littleEndianBytes(UInt32(0))
        case .lookup:
            opcode = .lookup; payload = Array("existing.txt\0".utf8)
        case .getattr:
            opcode = .getattr; requestNodeID = nodeID
            payload = FuseProtocol.encodeGetattrIn(FuseGetattrIn(flags: .fileHandle, fileHandle: fileHandle))
        case .readlink:
            let linkLookup = try request(
                opcode: .lookup, payload: Array("existing-link\0".utf8), requestID: 4
            )
            requestNodeID = try responsePayload(completedPayload(execute(linkLookup))).leUInt64(at: 0)
            try commit(linkLookup)
            opcode = .readlink; payload = []
        case .statfs:
            opcode = .statfs; payload = []
        }
        return try request(opcode: opcode, nodeID: requestNodeID, payload: payload, requestID: 10)
    }

    func request(
        opcode: FuseOpcode,
        nodeID: UInt64 = HostFS.rootNodeID,
        payload: [UInt8] = [],
        requestID: UInt64,
        correlationID: UInt64? = nil,
        deadline: UInt64? = nil,
        responseCapacity: UInt32 = 32_768
    ) throws -> DoryFSWorkerRequest {
        let unique = correlationID ?? requestID + 100
        return try DoryFSWorkerRequest(
            generation: bootstrap.generation,
            shareCapabilityID: share.capabilityID,
            requestID: requestID,
            correlationID: unique,
            opcodeClass: opcode.workerOpcodeClass,
            responseCapacity: responseCapacity,
            deadlineUptimeNanoseconds: deadline ?? DispatchTime.now().uptimeNanoseconds + 5_000_000_000,
            payload: Data(fuseRequest(opcode: opcode, unique: unique, nodeID: nodeID, payload: payload))
        )
    }

    func execute(_ request: DoryFSWorkerRequest) throws -> DoryFSWorkerReplyOutcome {
        let result = try DoryFSWorkerRPCResultCodec.decode(service.exchange(
            exactFrame: encode(.execute(request))
        ))
        guard case .success(let frame) = result,
              case .reply(let reply) = try DoryFSWorkerFrameCodec.decodeServiceFrame(
                frame, maximumFrameBytes: bootstrap.workerLimits.maximumFrameBytes
              ) else { throw RequestAuthorityError.unexpectedServiceReply }
        return reply.outcome
    }

    func send(_ frame: DoryFSWorkerClientFrame) throws { service.sendOneWay(exactFrame: try encode(frame)) }

    func commit(_ request: DoryFSWorkerRequest) throws {
        try send(.commitPublication(DoryFSWorkerPublication(
            generation: request.generation, shareCapabilityID: request.shareCapabilityID,
            requestID: request.requestID, correlationID: request.correlationID
        )))
    }

    func snapshot() throws -> FuseResourceSnapshot { try probe.snapshot() }

    func expectUnchangedHostTree() throws {
        #expect(try String(contentsOf: fileURL, encoding: .utf8) == "untouched")
        let status = try fileStatus(fileURL)
        #expect(status.st_ino == originalStatus.st_ino)
        #expect(status.st_mode == originalStatus.st_mode)
        #expect(status.st_nlink == originalStatus.st_nlink)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("existing-dir").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("created").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("renamed").path))
    }

    private func encode(_ frame: DoryFSWorkerClientFrame) throws -> Data {
        try DoryFSWorkerFrameCodec.encode(frame, maximumFrameBytes: bootstrap.workerLimits.maximumFrameBytes)
    }
}

private final class HostOperationPause: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    private let loaded = DispatchSemaphore(value: 0)
    private let proceed = DispatchSemaphore(value: 0)

    func arm() { lock.withLock { armed = true } }
    func resume() { proceed.signal() }
    func pauseIfArmed() {
        let shouldPause = lock.withLock {
            guard armed else { return false }
            armed = false
            return true
        }
        guard shouldPause else { return }
        loaded.signal()
        _ = proceed.wait(timeout: .now() + 5)
    }
    func waitUntilPaused() async -> DispatchTimeoutResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: self.loaded.wait(timeout: .now() + 2))
            }
        }
    }
}

private final class ServerResourceProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var server: FuseServer?
    func install(_ server: FuseServer) { lock.withLock { self.server = server } }
    func snapshot() throws -> FuseResourceSnapshot {
        try lock.withLock { try #require(server).resourceSnapshot }
    }
}

private final class AuthorizationBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    init(successfulChecks: Int) { remaining = successfulChecks }
    func check() -> Bool {
        lock.withLock {
            guard remaining > 0 else { return false }
            remaining -= 1
            return true
        }
    }
}

private enum RequestAuthorityError: Error { case unexpectedServiceReply }

private func completedPayload(_ outcome: DoryFSWorkerReplyOutcome) throws -> [UInt8] {
    guard case .completed(let payload) = outcome else { throw RequestAuthorityError.unexpectedServiceReply }
    return [UInt8](payload)
}

private func responsePayload(_ response: [UInt8]) throws -> [UInt8] {
    try #require(FuseProtocol.decodeOutHeader(response).error == 0)
    return Array(response.dropFirst(FuseOutHeader.byteCount))
}

private func fuseRequest(opcode: FuseOpcode, unique: UInt64, nodeID: UInt64, payload: [UInt8]) -> [UInt8] {
    FuseProtocol.encodeInHeader(FuseInHeader(
        length: UInt32(FuseInHeader.byteCount + payload.count), opcode: opcode.rawValue,
        unique: unique, nodeID: nodeID, uid: 1_000, gid: 1_000, pid: 42
    )) + payload
}

private func readWritePayload(handle: UInt64, size: UInt32) -> [UInt8] {
    littleEndianBytes(handle) + littleEndianBytes(UInt64(0)) + littleEndianBytes(size)
        + littleEndianBytes(UInt32(0)) + littleEndianBytes(UInt64(0))
        + littleEndianBytes(UInt32(0)) + littleEndianBytes(UInt32(0))
}

private func littleEndianBytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
    withUnsafeBytes(of: value.littleEndian) { Array($0) }
}

private func fileStatus(_ url: URL) throws -> stat {
    var status = stat()
    guard lstat(url.path, &status) == 0 else { throw POSIXError(.EIO) }
    return status
}

private extension Array where Element == UInt8 {
    func leUInt64(at offset: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 | UInt64(self[offset + $1]) << UInt64($1 * 8) }
    }
}
