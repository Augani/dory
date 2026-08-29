import Darwin
import DoryFSWorkerContracts
import Dispatch
import Foundation
import Testing
@testable import DoryFSWorkerServiceCore

struct FuseResourceQuotaTests {
    @Test func atomicAdmissionNeverOvershootsAndTokensRecover() throws {
        let limits = quotaLimits(nodes: 4)
        let quota = FuseResourceQuota(limits: limits)
        let results = QuotaAdmissionResults()

        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            do {
                results.record(token: try quota.acquire(.liveNonRootNodes))
            } catch let error as FuseResourceQuotaError {
                results.record(error: error)
            } catch {
                results.recordUnexpected(error)
            }
        }

        #expect(results.successCount == limits.maximumLiveNonRootNodes)
        #expect(results.errors == Array(
            repeating: FuseResourceQuotaError(
                resource: .liveNonRootNodes,
                limit: limits.maximumLiveNonRootNodes
            ),
            count: 64 - limits.maximumLiveNonRootNodes
        ))
        #expect(results.unexpectedErrors.isEmpty)
        #expect(quota.snapshot().liveNonRootNodes == limits.maximumLiveNonRootNodes)

        results.releaseAll()
        #expect(quota.snapshot().liveNonRootNodes == 0)
    }

    @Test func nodeQuotaRejectsBeforeCreateAndRecoversOnForgetAndReset() throws {
        let root = try QuotaTestRoot()
        try root.write("first", to: "first.txt")
        try root.write("second", to: "second.txt")
        let limits = quotaLimits(nodes: 1)
        let hostFS = try HostFS(rootPath: root.url.path, resourceLimits: limits)

        hostFS.identityPinOpenTestErrno = EMFILE
        #expect(throws: HostFSError.systemCall("pin identity first.txt", EMFILE)) {
            _ = try hostFS.lookup(parent: HostFS.rootNodeID, name: "first.txt")
        }
        #expect(hostFS.resourceSnapshot.liveNonRootNodes == 0)
        hostFS.identityPinOpenTestErrno = nil

        let first = try hostFS.lookup(parent: HostFS.rootNodeID, name: "first.txt")
        hostFS.retainLookup(nodeID: first.nodeID)
        #expect(hostFS.resourceSnapshot.liveNonRootNodes == 1)

        #expect(throws: FuseResourceQuotaError(resource: .liveNonRootNodes, limit: 1)) {
            _ = try hostFS.lookup(parent: HostFS.rootNodeID, name: "second.txt")
        }
        #expect(throws: FuseResourceQuotaError(resource: .liveNonRootNodes, limit: 1)) {
            _ = try hostFS.createFile(parent: HostFS.rootNodeID, name: "not-created.txt")
        }
        #expect(!FileManager.default.fileExists(atPath: root.url.appendingPathComponent("not-created.txt").path))
        #expect(hostFS.resourceSnapshot.liveNonRootNodes == 1)

        hostFS.forgetLookup(nodeID: first.nodeID, count: 1)
        #expect(hostFS.resourceSnapshot.liveNonRootNodes == 0)

        let second = try hostFS.lookup(parent: HostFS.rootNodeID, name: "second.txt")
        hostFS.retainLookup(nodeID: second.nodeID)
        #expect(hostFS.resourceSnapshot.liveNonRootNodes == 1)

        hostFS.resetFuseReferences()
        #expect(hostFS.resourceSnapshot.liveNonRootNodes == 0)
    }

    @Test func concurrentHostLookupsRespectTheNodeBoundaryAndReset() throws {
        let root = try QuotaTestRoot()
        let names = (0..<32).map { "entry-\($0).txt" }
        for name in names {
            try root.write(name, to: name)
        }
        let limit = 4
        let hostFS = try HostFS(
            rootPath: root.url.path,
            resourceLimits: quotaLimits(nodes: limit)
        )
        let results = ConcurrentLookupResults()

        DispatchQueue.concurrentPerform(iterations: names.count) { index in
            do {
                let entry = try hostFS.lookup(parent: HostFS.rootNodeID, name: names[index])
                hostFS.retainLookup(nodeID: entry.nodeID)
                results.recordSuccess()
            } catch let error as FuseResourceQuotaError {
                results.record(error: error)
            } catch {
                results.recordUnexpected(error)
            }
        }

        #expect(results.successCount == limit)
        #expect(results.errors.count == names.count - limit)
        #expect(results.errors.allSatisfy {
            $0 == FuseResourceQuotaError(resource: .liveNonRootNodes, limit: limit)
        })
        #expect(results.unexpectedErrors.isEmpty)
        #expect(hostFS.resourceSnapshot.liveNonRootNodes == limit)

        hostFS.resetFuseReferences()
        #expect(hostFS.resourceSnapshot.liveNonRootNodes == 0)
    }

    @Test func handleQuotasMapToEMFILEAndRecoverOnReleaseAndReset() throws {
        let root = try QuotaTestRoot()
        try root.write("payload", to: "file.txt")
        let hostFS = try HostFS(
            rootPath: root.url.path,
            resourceLimits: quotaLimits(nodes: 1, files: 1, directories: 1)
        )
        let server = FuseServer(hostFS: hostFS)
        let lookup = server.handle(request: quotaRequest(
            unique: 1,
            opcode: .lookup,
            nodeID: HostFS.rootNodeID,
            payload: Array("file.txt\0".utf8)
        ))
        #expect(try FuseProtocol.decodeOutHeader(lookup).error == 0)
        let nodeID = quotaPayload(from: lookup).leUInt64(at: 0)

        let rejectedCreate = server.handle(request: quotaRequest(
            unique: 10,
            opcode: .create,
            nodeID: HostFS.rootNodeID,
            payload: quotaBytes(UInt32(O_RDWR)) + quotaBytes(UInt32(0o644))
                + quotaBytes(UInt32(0)) + quotaBytes(UInt32(0)) + Array("not-created.txt\0".utf8)
        ))
        #expect(try FuseProtocol.decodeOutHeader(rejectedCreate).error == -FuseProtocol.linuxErrno(EMFILE))
        #expect(server.resourceSnapshot.fileHandles == 0)
        #expect(!FileManager.default.fileExists(atPath: root.url.appendingPathComponent("not-created.txt").path))

        let firstOpen = server.handle(request: quotaRequest(
            unique: 2,
            opcode: .open,
            nodeID: nodeID,
            payload: quotaBytes(UInt32(O_RDONLY)) + quotaBytes(UInt32(0))
        ))
        #expect(try FuseProtocol.decodeOutHeader(firstOpen).error == 0)
        let fileHandle = quotaPayload(from: firstOpen).leUInt64(at: 0)
        let rejectedOpen = server.handle(request: quotaRequest(
            unique: 3,
            opcode: .open,
            nodeID: nodeID,
            payload: quotaBytes(UInt32(O_RDONLY)) + quotaBytes(UInt32(0))
        ))
        #expect(try FuseProtocol.decodeOutHeader(rejectedOpen).error == -FuseProtocol.linuxErrno(EMFILE))

        let firstOpenDir = server.handle(request: quotaRequest(
            unique: 4,
            opcode: .opendir,
            nodeID: HostFS.rootNodeID
        ))
        #expect(try FuseProtocol.decodeOutHeader(firstOpenDir).error == 0)
        let directoryHandle = quotaPayload(from: firstOpenDir).leUInt64(at: 0)
        let rejectedOpenDir = server.handle(request: quotaRequest(
            unique: 5,
            opcode: .opendir,
            nodeID: HostFS.rootNodeID
        ))
        #expect(try FuseProtocol.decodeOutHeader(rejectedOpenDir).error == -FuseProtocol.linuxErrno(EMFILE))
        #expect(server.resourceSnapshot.fileHandles == 1)
        #expect(server.resourceSnapshot.directoryHandles == 1)

        let release = server.handle(request: quotaRequest(
            unique: 6,
            opcode: .release,
            nodeID: nodeID,
            payload: quotaReleasePayload(handle: fileHandle, owner: 0)
        ))
        let releaseDir = server.handle(request: quotaRequest(
            unique: 7,
            opcode: .releasedir,
            nodeID: HostFS.rootNodeID,
            payload: quotaBytes(directoryHandle)
        ))
        #expect(try FuseProtocol.decodeOutHeader(release).error == 0)
        #expect(try FuseProtocol.decodeOutHeader(releaseDir).error == 0)
        #expect(server.resourceSnapshot.fileHandles == 0)
        #expect(server.resourceSnapshot.directoryHandles == 0)

        let reopenedFile = server.handle(request: quotaRequest(
            unique: 8,
            opcode: .open,
            nodeID: nodeID,
            payload: quotaBytes(UInt32(O_RDONLY)) + quotaBytes(UInt32(0))
        ))
        let reopenedDirectory = server.handle(request: quotaRequest(
            unique: 9,
            opcode: .opendir,
            nodeID: HostFS.rootNodeID
        ))
        #expect(try FuseProtocol.decodeOutHeader(reopenedFile).error == 0)
        #expect(try FuseProtocol.decodeOutHeader(reopenedDirectory).error == 0)
        #expect(server.resourceSnapshot.fileHandles == 1)
        #expect(server.resourceSnapshot.directoryHandles == 1)

        server.resetConnection()
        let reset = server.resourceSnapshot
        #expect(reset.liveNonRootNodes == 0)
        #expect(reset.fileHandles == 0)
        #expect(reset.directoryHandles == 0)
        #expect(reset.advisoryLockOwners == 0)
        #expect(reset.pendingBlockingLocks == 0)
    }

    @Test func directoryCursorRetainsOnlyNamesConsideredForBoundedResponses() throws {
        let root = try QuotaTestRoot()
        for index in 0..<32 {
            try root.write("payload", to: String(format: "entry-%04d", index))
        }
        let nameLength = "entry-0000".utf8.count
        let recordLength = quotaDirentPlusLength(nameByteCount: nameLength)
        let server = FuseServer(hostFS: try HostFS(
            rootPath: root.url.path,
            resourceLimits: quotaLimits(cursorEntries: 64, cursorNameBytes: 1_024)
        ))
        let opened = server.handle(request: quotaRequest(
            unique: 100,
            opcode: .opendir,
            nodeID: HostFS.rootNodeID
        ))
        let handle = quotaPayload(from: opened).leUInt64(at: 0)

        let first = server.handle(request: quotaRequest(
            unique: 101,
            opcode: .readdirplus,
            nodeID: HostFS.rootNodeID,
            payload: quotaReadDirPayload(
                handle: handle,
                offset: 0,
                maximumBytes: UInt32(recordLength)
            )
        ))

        #expect(try FuseProtocol.decodeOutHeader(first).error == 0)
        #expect(quotaPayload(from: first).count == recordLength)
        #expect(server.resourceSnapshot.liveNonRootNodes == 1)
        #expect(server.resourceSnapshot.directoryCursorEntries == 1)
        #expect(server.resourceSnapshot.directoryCursorNameBytes == nameLength)

        let released = server.handle(request: quotaRequest(
            unique: 102,
            opcode: .releasedir,
            nodeID: HostFS.rootNodeID,
            payload: quotaBytes(handle)
        ))
        #expect(try FuseProtocol.decodeOutHeader(released).error == 0)
        #expect(server.resourceSnapshot.directoryCursorEntries == 0)
        #expect(server.resourceSnapshot.directoryCursorNameBytes == 0)
    }

    @Test func directoryCursorQuotaFailsWithEOVERFLOWAndRecoversOnRelease() throws {
        let root = try QuotaTestRoot()
        for index in 0..<3 {
            try root.write("payload", to: String(format: "entry-%04d", index))
        }
        let nameLength = "entry-0000".utf8.count
        let recordLength = quotaDirentPlusLength(nameByteCount: nameLength)
        let server = FuseServer(hostFS: try HostFS(
            rootPath: root.url.path,
            resourceLimits: quotaLimits(cursorEntries: 1, cursorNameBytes: nameLength)
        ))
        let opened = server.handle(request: quotaRequest(
            unique: 110,
            opcode: .opendir,
            nodeID: HostFS.rootNodeID
        ))
        let handle = quotaPayload(from: opened).leUInt64(at: 0)
        let first = server.handle(request: quotaRequest(
            unique: 111,
            opcode: .readdirplus,
            nodeID: HostFS.rootNodeID,
            payload: quotaReadDirPayload(
                handle: handle,
                offset: 0,
                maximumBytes: UInt32(recordLength * 2)
            )
        ))
        let firstPayload = quotaPayload(from: first)

        #expect(try FuseProtocol.decodeOutHeader(first).error == 0)
        #expect(firstPayload.count == recordLength)
        #expect(server.resourceSnapshot.directoryCursorEntries == 1)
        #expect(server.resourceSnapshot.directoryCursorNameBytes == nameLength)
        let nextOffset = firstPayload.leUInt64(at: 128 + 8)
        let overflow = server.handle(request: quotaRequest(
            unique: 112,
            opcode: .readdirplus,
            nodeID: HostFS.rootNodeID,
            payload: quotaReadDirPayload(
                handle: handle,
                offset: nextOffset,
                maximumBytes: UInt32(recordLength)
            )
        ))
        #expect(
            try FuseProtocol.decodeOutHeader(overflow).error
                == -FuseProtocol.linuxErrno(EOVERFLOW)
        )

        _ = server.handle(request: quotaRequest(
            unique: 113,
            opcode: .releasedir,
            nodeID: HostFS.rootNodeID,
            payload: quotaBytes(handle)
        ))
        #expect(server.resourceSnapshot.directoryCursorEntries == 0)
        #expect(server.resourceSnapshot.directoryCursorNameBytes == 0)
    }

    @Test func unpublishedCreateRollbackRecoversNodeAndHandleTokens() throws {
        let root = try QuotaTestRoot()
        let hostFS = try HostFS(
            rootPath: root.url.path,
            resourceLimits: quotaLimits(nodes: 1, files: 1)
        )
        let server = FuseServer(hostFS: hostFS)
        let response = server.handle(request: quotaRequest(
            unique: 15,
            opcode: .create,
            nodeID: HostFS.rootNodeID,
            payload: quotaBytes(UInt32(O_RDWR)) + quotaBytes(UInt32(0o644))
                + quotaBytes(UInt32(0)) + quotaBytes(UInt32(0)) + Array("created.txt\0".utf8)
        ))
        #expect(try FuseProtocol.decodeOutHeader(response).error == 0)
        #expect(server.resourceSnapshot.liveNonRootNodes == 1)
        #expect(server.resourceSnapshot.fileHandles == 1)

        server.rollbackUnpublishedResponse(opcode: .create, response: response)
        #expect(server.resourceSnapshot.liveNonRootNodes == 0)
        #expect(server.resourceSnapshot.fileHandles == 0)
        #expect(FileManager.default.fileExists(atPath: root.url.appendingPathComponent("created.txt").path))
    }

    @Test func serverShutdownRecoversEveryRegisteredResource() throws {
        let root = try QuotaTestRoot()
        try root.write("shutdown", to: "shutdown.txt")
        let hostFS = try HostFS(rootPath: root.url.path, resourceLimits: quotaLimits())

        try exerciseQuotaShutdown(hostFS: hostFS)

        let snapshot = hostFS.resourceSnapshot
        #expect(snapshot.liveNonRootNodes == 0)
        #expect(snapshot.fileHandles == 0)
        #expect(snapshot.directoryHandles == 0)
        #expect(snapshot.advisoryLockOwners == 0)
        #expect(snapshot.pendingBlockingLocks == 0)
    }

    @Test func advisoryOwnerQuotaRecoversAfterFlushAndRelease() throws {
        let fixture = try QuotaLockFixture(limits: quotaLimits(nodes: 2, files: 1, owners: 1))

        let firstLock = fixture.server.handle(request: fixture.lockRequest(
            unique: 20,
            owner: 101,
            type: 1,
            blocking: false
        ))
        #expect(try FuseProtocol.decodeOutHeader(firstLock).error == 0)
        #expect(fixture.server.resourceSnapshot.advisoryLockOwners == 1)

        let rejectedOwner = fixture.server.handle(request: fixture.lockRequest(
            unique: 21,
            owner: 202,
            type: 1,
            blocking: false
        ))
        #expect(try FuseProtocol.decodeOutHeader(rejectedOwner).error == -FuseProtocol.linuxErrno(EMFILE))
        #expect(fixture.server.resourceSnapshot.advisoryLockOwners == 1)

        let flush = fixture.server.handle(request: quotaRequest(
            unique: 22,
            opcode: .flush,
            nodeID: fixture.nodeID,
            payload: quotaFlushPayload(handle: fixture.fileHandle, owner: 101)
        ))
        #expect(try FuseProtocol.decodeOutHeader(flush).error == 0)
        #expect(fixture.server.resourceSnapshot.advisoryLockOwners == 0)

        let replacementOwner = fixture.server.handle(request: fixture.lockRequest(
            unique: 23,
            owner: 202,
            type: 1,
            blocking: false
        ))
        #expect(try FuseProtocol.decodeOutHeader(replacementOwner).error == 0)
        #expect(fixture.server.resourceSnapshot.advisoryLockOwners == 1)

        let release = fixture.server.handle(request: quotaRequest(
            unique: 24,
            opcode: .release,
            nodeID: fixture.nodeID,
            payload: quotaReleasePayload(handle: fixture.fileHandle, owner: 202)
        ))
        #expect(try FuseProtocol.decodeOutHeader(release).error == 0)
        #expect(fixture.server.resourceSnapshot.fileHandles == 0)
        #expect(fixture.server.resourceSnapshot.advisoryLockOwners == 0)
    }

    @Test func pendingLockQuotaMapsToEAGAINAndRecoversImmediatelyOnInterrupt() throws {
        let fixture = try QuotaLockFixture(limits: quotaLimits(
            nodes: 2,
            files: 1,
            owners: 3,
            pending: 1
        ))
        let ownerLock = fixture.server.handle(request: fixture.lockRequest(
            unique: 30,
            owner: 301,
            type: 1,
            blocking: false
        ))
        #expect(try FuseProtocol.decodeOutHeader(ownerLock).error == 0)

        let waiterResult = QuotaLockedResponse()
        let waiterFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            waiterResult.store(fixture.server.handle(request: fixture.lockRequest(
                unique: 31,
                owner: 302,
                type: 1,
                blocking: true
            )))
            waiterFinished.signal()
        }
        #expect(quotaWaitUntil { fixture.server.resourceSnapshot.pendingBlockingLocks == 1 })
        #expect(fixture.server.resourceSnapshot.advisoryLockOwners == 2)

        let rejectedWaiter = fixture.server.handle(request: fixture.lockRequest(
            unique: 32,
            owner: 303,
            type: 1,
            blocking: true
        ))
        #expect(try FuseProtocol.decodeOutHeader(rejectedWaiter).error == -FuseProtocol.linuxErrno(EAGAIN))
        #expect(fixture.server.resourceSnapshot.pendingBlockingLocks == 1)
        #expect(fixture.server.resourceSnapshot.advisoryLockOwners == 2)

        let interrupt = fixture.server.handle(request: quotaRequest(
            unique: 33,
            opcode: .interrupt,
            nodeID: HostFS.rootNodeID,
            payload: quotaBytes(UInt64(31))
        ))
        #expect(interrupt.isEmpty)
        #expect(fixture.server.resourceSnapshot.pendingBlockingLocks == 0)
        #expect(waiterFinished.wait(timeout: .now() + 2) == .success)
        #expect(try FuseProtocol.decodeOutHeader(waiterResult.load()).error == -FuseProtocol.linuxErrno(EINTR))
        #expect(fixture.server.resourceSnapshot.advisoryLockOwners == 1)

        let releaseOwner = fixture.server.handle(request: quotaRequest(
            unique: 34,
            opcode: .flush,
            nodeID: fixture.nodeID,
            payload: quotaFlushPayload(handle: fixture.fileHandle, owner: 301)
        ))
        #expect(try FuseProtocol.decodeOutHeader(releaseOwner).error == 0)

        let recoveredWaiter = fixture.server.handle(request: fixture.lockRequest(
            unique: 35,
            owner: 303,
            type: 1,
            blocking: true
        ))
        #expect(try FuseProtocol.decodeOutHeader(recoveredWaiter).error == 0)
        #expect(fixture.server.resourceSnapshot.pendingBlockingLocks == 0)
        #expect(fixture.server.resourceSnapshot.advisoryLockOwners == 1)

        let release = fixture.server.handle(request: quotaRequest(
            unique: 36,
            opcode: .release,
            nodeID: fixture.nodeID,
            payload: quotaReleasePayload(handle: fixture.fileHandle, owner: 303)
        ))
        #expect(try FuseProtocol.decodeOutHeader(release).error == 0)
        #expect(fixture.server.resourceSnapshot.fileHandles == 0)
        #expect(fixture.server.resourceSnapshot.advisoryLockOwners == 0)
    }
}

private func quotaLimits(
    nodes: Int = 8,
    files: Int = 8,
    directories: Int = 8,
    cursorEntries: Int = 64,
    cursorNameBytes: Int = 4_096,
    owners: Int = 8,
    pending: Int = 8
) -> FuseResourceLimits {
    FuseResourceLimits(
        maximumLiveNonRootNodes: nodes,
        maximumFileHandles: files,
        maximumDirectoryHandles: directories,
        maximumDirectoryCursorEntries: cursorEntries,
        maximumDirectoryCursorNameBytes: cursorNameBytes,
        maximumAdvisoryLockOwners: owners,
        maximumPendingBlockingLocks: pending
    )
}

private func quotaReadDirPayload(
    handle: UInt64,
    offset: UInt64,
    maximumBytes: UInt32
) -> [UInt8] {
    quotaBytes(handle) + quotaBytes(offset) + quotaBytes(maximumBytes) + quotaBytes(UInt32(0))
        + quotaBytes(UInt64(0)) + quotaBytes(UInt32(0)) + quotaBytes(UInt32(0))
}

private func quotaDirentPlusLength(nameByteCount: Int) -> Int {
    (128 + 24 + nameByteCount + 7) & ~7
}

private func quotaRequest(
    unique: UInt64,
    opcode: FuseOpcode,
    nodeID: UInt64,
    payload: [UInt8] = []
) -> [UInt8] {
    FuseProtocol.encodeInHeader(FuseInHeader(
        length: UInt32(FuseInHeader.byteCount + payload.count),
        opcode: opcode.rawValue,
        unique: unique,
        nodeID: nodeID,
        uid: 1000,
        gid: 1000,
        pid: 42
    )) + payload
}

private func quotaPayload(from response: [UInt8]) -> [UInt8] {
    Array(response.dropFirst(FuseOutHeader.byteCount))
}

private func quotaBytes(_ value: UInt32) -> [UInt8] {
    var value = value.littleEndian
    return withUnsafeBytes(of: &value) { Array($0) }
}

private func quotaBytes(_ value: UInt64) -> [UInt8] {
    var value = value.littleEndian
    return withUnsafeBytes(of: &value) { Array($0) }
}

private func quotaLockPayload(
    handle: UInt64,
    owner: UInt64,
    type: UInt32
) -> [UInt8] {
    quotaBytes(handle) + quotaBytes(owner) + quotaBytes(UInt64(0)) + quotaBytes(UInt64(7))
        + quotaBytes(type) + quotaBytes(UInt32(42)) + quotaBytes(UInt32(0)) + quotaBytes(UInt32(0))
}

private func quotaFlushPayload(handle: UInt64, owner: UInt64) -> [UInt8] {
    quotaBytes(handle) + quotaBytes(UInt32(0)) + quotaBytes(UInt32(0)) + quotaBytes(owner)
}

private func quotaReleasePayload(handle: UInt64, owner: UInt64) -> [UInt8] {
    quotaFlushPayload(handle: handle, owner: owner)
}

private func quotaWaitUntil(
    timeout: TimeInterval = 2,
    condition: () -> Bool
) -> Bool {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while ProcessInfo.processInfo.systemUptime < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.005)
    }
    return condition()
}

private func exerciseQuotaShutdown(hostFS: HostFS) throws {
    let server = FuseServer(hostFS: hostFS)
    let lookup = server.handle(request: quotaRequest(
        unique: 200,
        opcode: .lookup,
        nodeID: HostFS.rootNodeID,
        payload: Array("shutdown.txt\0".utf8)
    ))
    guard try FuseProtocol.decodeOutHeader(lookup).error == 0 else {
        throw QuotaTestFixtureError.lookupFailed
    }
    let nodeID = quotaPayload(from: lookup).leUInt64(at: 0)
    let open = server.handle(request: quotaRequest(
        unique: 201,
        opcode: .open,
        nodeID: nodeID,
        payload: quotaBytes(UInt32(O_RDWR)) + quotaBytes(UInt32(0))
    ))
    guard try FuseProtocol.decodeOutHeader(open).error == 0 else {
        throw QuotaTestFixtureError.openFailed
    }
    let fileHandle = quotaPayload(from: open).leUInt64(at: 0)
    let openDirectory = server.handle(request: quotaRequest(
        unique: 202,
        opcode: .opendir,
        nodeID: HostFS.rootNodeID
    ))
    guard try FuseProtocol.decodeOutHeader(openDirectory).error == 0 else {
        throw QuotaTestFixtureError.openDirectoryFailed
    }
    let lock = server.handle(request: quotaRequest(
        unique: 203,
        opcode: .setlk,
        nodeID: nodeID,
        payload: quotaLockPayload(handle: fileHandle, owner: 901, type: 1)
    ))
    guard try FuseProtocol.decodeOutHeader(lock).error == 0 else {
        throw QuotaTestFixtureError.lockFailed
    }
    let snapshot = server.resourceSnapshot
    guard snapshot.liveNonRootNodes == 1,
          snapshot.fileHandles == 1,
          snapshot.directoryHandles == 1,
          snapshot.advisoryLockOwners == 1 else {
        throw QuotaTestFixtureError.unexpectedSnapshot
    }
}

private extension Array where Element == UInt8 {
    func leUInt32(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }

    func leUInt64(at offset: Int) -> UInt64 {
        UInt64(leUInt32(at: offset)) | UInt64(leUInt32(at: offset + 4)) << 32
    }
}

private final class QuotaTestRoot {
    let url: URL

    init() throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dory-fuse-quota-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func write(_ text: String, to relativePath: String) throws {
        try text.write(to: url.appendingPathComponent(relativePath), atomically: true, encoding: .utf8)
    }
}

private final class QuotaAdmissionResults: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [FuseResourceToken] = []
    private var recordedErrors: [FuseResourceQuotaError] = []
    private var recordedUnexpectedErrors: [String] = []

    var successCount: Int { lock.withLock { tokens.count } }
    var errors: [FuseResourceQuotaError] { lock.withLock { recordedErrors } }
    var unexpectedErrors: [String] { lock.withLock { recordedUnexpectedErrors } }

    func record(token: FuseResourceToken) {
        lock.withLock { tokens.append(token) }
    }

    func record(error: FuseResourceQuotaError) {
        lock.withLock { recordedErrors.append(error) }
    }

    func recordUnexpected(_ error: Error) {
        lock.withLock { recordedUnexpectedErrors.append(String(describing: error)) }
    }

    func releaseAll() {
        let admitted = lock.withLock { () -> [FuseResourceToken] in
            let admitted = tokens
            tokens.removeAll(keepingCapacity: false)
            return admitted
        }
        admitted.forEach { $0.release() }
    }
}

private final class ConcurrentLookupResults: @unchecked Sendable {
    private let lock = NSLock()
    private var successes = 0
    private var recordedErrors: [FuseResourceQuotaError] = []
    private var recordedUnexpectedErrors: [String] = []

    var successCount: Int { lock.withLock { successes } }
    var errors: [FuseResourceQuotaError] { lock.withLock { recordedErrors } }
    var unexpectedErrors: [String] { lock.withLock { recordedUnexpectedErrors } }

    func recordSuccess() {
        lock.withLock { successes += 1 }
    }

    func record(error: FuseResourceQuotaError) {
        lock.withLock { recordedErrors.append(error) }
    }

    func recordUnexpected(_ error: Error) {
        lock.withLock { recordedUnexpectedErrors.append(String(describing: error)) }
    }
}

private final class QuotaLockedResponse: @unchecked Sendable {
    private let lock = NSLock()
    private var response: [UInt8] = []

    func store(_ response: [UInt8]) {
        lock.withLock { self.response = response }
    }

    func load() -> [UInt8] {
        lock.withLock { response }
    }
}

private final class QuotaLockFixture: @unchecked Sendable {
    let root: QuotaTestRoot
    let server: FuseServer
    let nodeID: UInt64
    let fileHandle: UInt64

    init(limits: FuseResourceLimits) throws {
        root = try QuotaTestRoot()
        try root.write("lock", to: "lock.txt")
        server = FuseServer(hostFS: try HostFS(rootPath: root.url.path, resourceLimits: limits))
        let lookup = server.handle(request: quotaRequest(
            unique: 100,
            opcode: .lookup,
            nodeID: HostFS.rootNodeID,
            payload: Array("lock.txt\0".utf8)
        ))
        guard try FuseProtocol.decodeOutHeader(lookup).error == 0 else {
            throw QuotaTestFixtureError.lookupFailed
        }
        nodeID = quotaPayload(from: lookup).leUInt64(at: 0)
        let open = server.handle(request: quotaRequest(
            unique: 101,
            opcode: .open,
            nodeID: nodeID,
            payload: quotaBytes(UInt32(O_RDWR)) + quotaBytes(UInt32(0))
        ))
        guard try FuseProtocol.decodeOutHeader(open).error == 0 else {
            throw QuotaTestFixtureError.openFailed
        }
        fileHandle = quotaPayload(from: open).leUInt64(at: 0)
    }

    func lockRequest(unique: UInt64, owner: UInt64, type: UInt32, blocking: Bool) -> [UInt8] {
        quotaRequest(
            unique: unique,
            opcode: blocking ? .setlkw : .setlk,
            nodeID: nodeID,
            payload: quotaLockPayload(handle: fileHandle, owner: owner, type: type)
        )
    }
}

private enum QuotaTestFixtureError: Error {
    case lookupFailed
    case openFailed
    case openDirectoryFailed
    case lockFailed
    case unexpectedSnapshot
}
