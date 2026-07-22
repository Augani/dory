import Darwin
import Foundation
import Testing
@testable import DoryHV

struct FuseServerTests {
    @Test func lookupGetattrOpenReadAndReleaseFlow() throws {
        let root = try TestFuseServerRoot()
        try root.write("hello dory", to: "hello.txt")
        let server = try FuseServer(hostFS: HostFS(rootPath: root.url.path))

        let lookup = server.handle(request: request(unique: 10, opcode: .lookup, nodeID: HostFS.rootNodeID, payload: Array("hello.txt\0".utf8)))
        let lookupHeader = try FuseProtocol.decodeOutHeader(lookup)
        let lookupPayload = payload(from: lookup)
        let nodeID = lookupPayload.leUInt64(at: 0)

        #expect(lookupHeader.error == 0)
        #expect(lookupHeader.unique == 10)
        #expect(lookupHeader.length == UInt32(FuseOutHeader.byteCount + 128))
        #expect(nodeID != HostFS.rootNodeID)
        #expect(lookupPayload.leUInt64(at: 40) == nodeID)
        #expect(lookupPayload.leUInt64(at: 48) == 10)
        #expect(lookupPayload.leUInt32(at: 100) & UInt32(S_IFMT) == UInt32(S_IFREG))

        let getattr = server.handle(request: request(
            unique: 11,
            opcode: .getattr,
            nodeID: nodeID,
            payload: FuseProtocol.encodeGetattrIn(FuseGetattrIn())
        ))
        let getattrHeader = try FuseProtocol.decodeOutHeader(getattr)
        let getattrPayload = payload(from: getattr)

        #expect(getattrHeader.error == 0)
        #expect(getattrPayload.count == 104)
        #expect(getattrPayload.leUInt64(at: 16) == nodeID)
        #expect(getattrPayload.leUInt64(at: 24) == 10)

        let open = server.handle(request: request(unique: 12, opcode: .open, nodeID: nodeID, payload: bytes(UInt32(O_RDONLY)) + bytes(UInt32(0))))
        let openHeader = try FuseProtocol.decodeOutHeader(open)
        let openPayload = payload(from: open)
        let handle = openPayload.leUInt64(at: 0)

        #expect(openHeader.error == 0)
        #expect(handle > 0)
        #expect(openPayload.leUInt32(at: 8) == (1 << 5))

        let readIn = bytes(handle) + bytes(UInt64(6)) + bytes(UInt32(4)) + bytes(UInt32(0)) + bytes(UInt64(0)) + bytes(UInt32(0)) + bytes(UInt32(0))
        let read = server.handle(request: request(unique: 13, opcode: .read, nodeID: nodeID, payload: readIn))

        #expect(try FuseProtocol.decodeOutHeader(read).error == 0)
        #expect(String(decoding: payload(from: read), as: UTF8.self) == "dory")

        let release = server.handle(request: request(unique: 14, opcode: .release, nodeID: nodeID, payload: bytes(handle) + bytes(UInt32(0)) + bytes(UInt32(0)) + bytes(UInt64(0))))

        #expect(try FuseProtocol.decodeOutHeader(release).error == 0)

        let readAfterRelease = server.handle(request: request(unique: 15, opcode: .read, nodeID: nodeID, payload: readIn))

        #expect(try FuseProtocol.decodeOutHeader(readAfterRelease).error == -EBADF)
    }

    @Test func getattrFileHandleSurvivesHostAtomicReplacement() throws {
        let root = try TestFuseServerRoot()
        try root.write("old", to: "watched.txt")
        let server = try FuseServer(hostFS: HostFS(rootPath: root.url.path))

        let oldLookup = server.handle(request: request(
            unique: 300,
            opcode: .lookup,
            nodeID: HostFS.rootNodeID,
            payload: Array("watched.txt\0".utf8)
        ))
        let oldNodeID = payload(from: oldLookup).leUInt64(at: 0)
        let oldOpen = server.handle(request: request(
            unique: 301,
            opcode: .open,
            nodeID: oldNodeID,
            payload: bytes(UInt32(O_RDONLY)) + bytes(UInt32(0))
        ))
        let oldHandle = payload(from: oldOpen).leUInt64(at: 0)

        let preReplacementHandleGetattr = server.handle(request: request(
            unique: 299,
            opcode: .getattr,
            nodeID: oldNodeID,
            payload: FuseProtocol.encodeGetattrIn(FuseGetattrIn(
                flags: .fileHandle,
                fileHandle: oldHandle
            ))
        ))
        #expect(try FuseProtocol.decodeOutHeader(preReplacementHandleGetattr).error == 0)
        #expect(payload(from: preReplacementHandleGetattr).leUInt32(at: 80) == 1)

        // Foundation's atomic write replaces the directory entry with a distinct host inode.
        try root.write("replacement", to: "watched.txt")

        let pathGetattrRequest = request(
            unique: 302,
            opcode: .getattr,
            nodeID: oldNodeID,
            payload: FuseProtocol.encodeGetattrIn(FuseGetattrIn())
        )
        // The old node ID remains a valid inode while LOOKUP/FH refs exist. Atomic replacement
        // detaches its pathname, but GETATTR returns the pinned old inode instead of leaking ESTALE
        // to an ordinary path open. VirtioFS uses this direct response path in production.
        let firstPathGetattr = try directGetattrResponse(
            server: server,
            request: pathGetattrRequest
        )
        #expect(try FuseProtocol.decodeOutHeader(firstPathGetattr).error == 0)
        #expect(payload(from: firstPathGetattr).leUInt64(at: 24) == 3)
        #expect(payload(from: firstPathGetattr).leUInt32(at: 80) == 0)

        // Linux fstat(2) can omit FUSE_GETATTR_FH. Once detached, the same pinned attributes remain
        // available for the still-referenced old inode.
        let detachedPathGetattr = server.handle(request: pathGetattrRequest)
        #expect(try FuseProtocol.decodeOutHeader(detachedPathGetattr).error == 0)
        #expect(payload(from: detachedPathGetattr).leUInt64(at: 16) == oldNodeID)
        #expect(payload(from: detachedPathGetattr).leUInt64(at: 24) == 3)
        #expect(payload(from: detachedPathGetattr).leUInt32(at: 80) == 0)

        // These OPEN requests were authorized by the earlier LOOKUP but reached userspace after
        // reverse invalidation detached the old dentry. They must open the pinned old inode rather
        // than leak ESTALE or retarget oldNodeID to the replacement.
        let pendingOpen = server.handle(request: request(
            unique: 303,
            opcode: .open,
            nodeID: oldNodeID,
            payload: bytes(UInt32(0)) + bytes(UInt32(0)) // Linux O_RDONLY
        ))
        #expect(try FuseProtocol.decodeOutHeader(pendingOpen).error == 0)
        let pendingHandle = payload(from: pendingOpen).leUInt64(at: 0)

        let parallelPendingOpen = server.handle(request: request(
            unique: 304,
            opcode: .open,
            nodeID: oldNodeID,
            payload: bytes(UInt32(0)) + bytes(UInt32(0))
        ))
        #expect(try FuseProtocol.decodeOutHeader(parallelPendingOpen).error == 0)
        let parallelPendingHandle = payload(from: parallelPendingOpen).leUInt64(at: 0)
        for (unique, handle) in [(UInt64(3030), pendingHandle), (UInt64(3040), parallelPendingHandle)] {
            let readIn = bytes(handle) + bytes(UInt64(0)) + bytes(UInt32(32))
                + bytes(UInt32(0)) + bytes(UInt64(0)) + bytes(UInt32(0)) + bytes(UInt32(0))
            let read = server.handle(request: request(
                unique: unique,
                opcode: .read,
                nodeID: oldNodeID,
                payload: readIn
            ))
            #expect(try FuseProtocol.decodeOutHeader(read).error == 0)
            #expect(String(decoding: payload(from: read), as: UTF8.self) == "old")
        }

        let replacementLookup = server.handle(request: request(
            unique: 305,
            opcode: .lookup,
            nodeID: HostFS.rootNodeID,
            payload: Array("watched.txt\0".utf8)
        ))
        let replacementNodeID = payload(from: replacementLookup).leUInt64(at: 0)
        #expect(replacementNodeID != oldNodeID)

        let handleGetattrRequest = request(
            unique: 306,
            opcode: .getattr,
            nodeID: oldNodeID,
            payload: FuseProtocol.encodeGetattrIn(FuseGetattrIn(
                flags: .fileHandle,
                fileHandle: oldHandle
            ))
        )
        let handleGetattr = server.handle(request: handleGetattrRequest)
        let directHandleGetattr = try directGetattrResponse(
            server: server,
            request: handleGetattrRequest
        )
        let handleAttributes = payload(from: handleGetattr)

        #expect(try FuseProtocol.decodeOutHeader(handleGetattr).error == 0)
        #expect(directHandleGetattr == handleGetattr)
        #expect(handleAttributes.leUInt64(at: 16) == oldNodeID)
        #expect(handleAttributes.leUInt64(at: 24) == 3)
        #expect(handleAttributes.leUInt32(at: 80) == 0)

        let oldReadIn = bytes(oldHandle) + bytes(UInt64(0)) + bytes(UInt32(32))
            + bytes(UInt32(0)) + bytes(UInt64(0)) + bytes(UInt32(0)) + bytes(UInt32(0))
        let oldRead = server.handle(request: request(
            unique: 307,
            opcode: .read,
            nodeID: oldNodeID,
            payload: oldReadIn
        ))
        #expect(try FuseProtocol.decodeOutHeader(oldRead).error == 0)
        #expect(String(decoding: payload(from: oldRead), as: UTF8.self) == "old")

        let replacementOpen = server.handle(request: request(
            unique: 308,
            opcode: .open,
            nodeID: replacementNodeID,
            payload: bytes(UInt32(O_RDONLY)) + bytes(UInt32(0))
        ))
        let replacementHandle = payload(from: replacementOpen).leUInt64(at: 0)
        let replacementReadIn = bytes(replacementHandle) + bytes(UInt64(0)) + bytes(UInt32(32))
            + bytes(UInt32(0)) + bytes(UInt64(0)) + bytes(UInt32(0)) + bytes(UInt32(0))
        let replacementRead = server.handle(request: request(
            unique: 309,
            opcode: .read,
            nodeID: replacementNodeID,
            payload: replacementReadIn
        ))
        #expect(try FuseProtocol.decodeOutHeader(replacementRead).error == 0)
        #expect(String(decoding: payload(from: replacementRead), as: UTF8.self) == "replacement")

        let releaseIn = { (handle: UInt64) in
            bytes(handle) + bytes(UInt32(0)) + bytes(UInt32(0)) + bytes(UInt64(0))
        }
        _ = server.handle(request: request(
            unique: 310,
            opcode: .forget,
            nodeID: oldNodeID,
            payload: FuseProtocol.encodeForgetIn(FuseForgetIn(lookupCount: 1))
        ))
        _ = server.handle(request: request(
            unique: 311,
            opcode: .release,
            nodeID: oldNodeID,
            payload: releaseIn(oldHandle)
        ))
        for (unique, handle) in [(UInt64(314), pendingHandle), (UInt64(315), parallelPendingHandle)] {
            _ = server.handle(request: request(
                unique: unique,
                opcode: .release,
                nodeID: oldNodeID,
                payload: releaseIn(handle)
            ))
        }
        let retiredGetattr = server.handle(request: request(
            unique: 312,
            opcode: .getattr,
            nodeID: oldNodeID,
            payload: FuseProtocol.encodeGetattrIn(FuseGetattrIn())
        ))
        #expect(try FuseProtocol.decodeOutHeader(retiredGetattr).error == -ENOENT)
        _ = server.handle(request: request(
            unique: 313,
            opcode: .release,
            nodeID: replacementNodeID,
            payload: releaseIn(replacementHandle)
        ))
    }

    @Test func getattrFileHandleRejectsMismatchedAndUnknownHandlesOnBothPaths() throws {
        let root = try TestFuseServerRoot()
        try root.write("first", to: "first.txt")
        try root.write("second", to: "second.txt")
        let server = try FuseServer(hostFS: HostFS(rootPath: root.url.path))

        func lookupAndOpen(_ name: String, unique: UInt64) throws -> (nodeID: UInt64, handle: UInt64) {
            let lookup = server.handle(request: request(
                unique: unique,
                opcode: .lookup,
                nodeID: HostFS.rootNodeID,
                payload: Array("\(name)\0".utf8)
            ))
            let nodeID = payload(from: lookup).leUInt64(at: 0)
            let opened = server.handle(request: request(
                unique: unique + 1,
                opcode: .open,
                nodeID: nodeID,
                payload: bytes(UInt32(O_RDONLY)) + bytes(UInt32(0))
            ))
            #expect(try FuseProtocol.decodeOutHeader(opened).error == 0)
            return (nodeID, payload(from: opened).leUInt64(at: 0))
        }

        let first = try lookupAndOpen("first.txt", unique: 320)
        let second = try lookupAndOpen("second.txt", unique: 322)
        let invalidRequests = [
            request(
                unique: 324,
                opcode: .getattr,
                nodeID: first.nodeID,
                payload: FuseProtocol.encodeGetattrIn(FuseGetattrIn(
                    flags: .fileHandle,
                    fileHandle: second.handle
                ))
            ),
            request(
                unique: 325,
                opcode: .getattr,
                nodeID: first.nodeID,
                payload: FuseProtocol.encodeGetattrIn(FuseGetattrIn(
                    flags: .fileHandle,
                    fileHandle: UInt64.max
                ))
            ),
        ]

        for invalidRequest in invalidRequests {
            let arrayResponse = server.handle(request: invalidRequest)
            let directResponse = try directGetattrResponse(server: server, request: invalidRequest)
            #expect(try FuseProtocol.decodeOutHeader(arrayResponse).error == -EBADF)
            #expect(directResponse == arrayResponse)
        }
    }

    @Test func pinnedFallbackEnforcesLogicalAccessAndNodeIdentityOnEveryIOPath() throws {
        let root = try TestFuseServerRoot()
        try root.write("old", to: "watched.txt")
        try root.write("other", to: "other.txt")
        let path = root.url.appendingPathComponent("watched.txt")
        let server = try FuseServer(hostFS: HostFS(rootPath: root.url.path))

        func lookup(_ name: String, unique: UInt64) throws -> UInt64 {
            let response = server.handle(request: request(
                unique: unique,
                opcode: .lookup,
                nodeID: HostFS.rootNodeID,
                payload: Array("\(name)\0".utf8)
            ))
            #expect(try FuseProtocol.decodeOutHeader(response).error == 0)
            return payload(from: response).leUInt64(at: 0)
        }
        let oldNodeID = try lookup("watched.txt", unique: 330)
        let otherNodeID = try lookup("other.txt", unique: 331)
        try root.write("replacement", to: "watched.txt")

        let readOpen = server.handle(request: request(
            unique: 332,
            opcode: .open,
            nodeID: oldNodeID,
            payload: bytes(UInt32(0)) + bytes(UInt32(0)) // Linux O_RDONLY
        ))
        #expect(try FuseProtocol.decodeOutHeader(readOpen).error == 0)
        let readHandle = payload(from: readOpen).leUInt64(at: 0)
        let writePayload = bytes(readHandle) + bytes(UInt64(0)) + bytes(UInt32(1))
            + bytes(UInt32(0)) + bytes(UInt64(0)) + bytes(UInt32(0)) + bytes(UInt32(0))
            + Array("X".utf8)
        let arrayWrite = server.handle(request: request(
            unique: 333,
            opcode: .write,
            nodeID: oldNodeID,
            payload: writePayload
        ))
        #expect(try FuseProtocol.decodeOutHeader(arrayWrite).error == -EBADF)
        let directWrite = try directWriteResponse(server: server, request: request(
            unique: 334,
            opcode: .write,
            nodeID: oldNodeID,
            payload: writePayload
        ))
        #expect(try FuseProtocol.decodeOutHeader(directWrite).error == -EBADF)

        let truncate = server.handle(request: request(
            unique: 335,
            opcode: .setattr,
            nodeID: oldNodeID,
            payload: FuseProtocol.encodeSetattrIn(FuseSetattrIn(
                valid: [.size, .fileHandle],
                fileHandle: readHandle,
                size: 0
            ))
        ))
        #expect(try FuseProtocol.decodeOutHeader(truncate).error == -EBADF)

        let writeOpen = server.handle(request: request(
            unique: 336,
            opcode: .open,
            nodeID: oldNodeID,
            payload: bytes(UInt32(1)) + bytes(UInt32(0)) // Linux O_WRONLY
        ))
        #expect(try FuseProtocol.decodeOutHeader(writeOpen).error == 0)
        let writeHandle = payload(from: writeOpen).leUInt64(at: 0)
        let readPayload = bytes(writeHandle) + bytes(UInt64(0)) + bytes(UInt32(32))
            + bytes(UInt32(0)) + bytes(UInt64(0)) + bytes(UInt32(0)) + bytes(UInt32(0))
        let arrayRead = server.handle(request: request(
            unique: 337,
            opcode: .read,
            nodeID: oldNodeID,
            payload: readPayload
        ))
        #expect(try FuseProtocol.decodeOutHeader(arrayRead).error == -EBADF)
        let directRead = try directReadResponse(server: server, request: request(
            unique: 338,
            opcode: .read,
            nodeID: oldNodeID,
            payload: readPayload
        ))
        #expect(try FuseProtocol.decodeOutHeader(directRead).error == -EBADF)

        let wrongNodeRead = server.handle(request: request(
            unique: 339,
            opcode: .read,
            nodeID: otherNodeID,
            payload: bytes(readHandle) + bytes(UInt64(0)) + bytes(UInt32(32))
                + bytes(UInt32(0)) + bytes(UInt64(0)) + bytes(UInt32(0)) + bytes(UInt32(0))
        ))
        #expect(try FuseProtocol.decodeOutHeader(wrongNodeRead).error == -EBADF)

        #expect(try String(contentsOf: path, encoding: .utf8) == "replacement")
        let releasePayload = { (handle: UInt64) in
            bytes(handle) + bytes(UInt32(0)) + bytes(UInt32(0)) + bytes(UInt64(0))
        }
        for (unique, handle) in [(UInt64(3390), readHandle), (UInt64(3391), writeHandle)] {
            _ = server.handle(request: request(
                unique: unique,
                opcode: .release,
                nodeID: oldNodeID,
                payload: releasePayload(handle)
            ))
        }
    }

    @Test func concurrentForgetCannotRetireNodeBetweenOpenPinAndHandleReservation() throws {
        let root = try TestFuseServerRoot()
        try root.write("pinned", to: "forget-race.txt")
        let hostFS = try HostFS(rootPath: root.url.path)
        let server = FuseServer(hostFS: hostFS)

        let lookup = server.handle(request: request(
            unique: 346,
            opcode: .lookup,
            nodeID: HostFS.rootNodeID,
            payload: Array("forget-race.txt\0".utf8)
        ))
        let nodeID = payload(from: lookup).leUInt64(at: 0)

        // Force the final lookup reference away after OPEN has duplicated the identity but before
        // it reopens the file. The atomically reserved handle reference must keep the node alive.
        hostFS.openIdentityPinnedTestHook = { pinnedNodeID in
            hostFS.forgetLookup(nodeID: pinnedNodeID, count: 1)
        }
        let open = server.handle(request: request(
            unique: 347,
            opcode: .open,
            nodeID: nodeID,
            payload: bytes(UInt32(0)) + bytes(UInt32(0))
        ))
        hostFS.openIdentityPinnedTestHook = nil
        #expect(try FuseProtocol.decodeOutHeader(open).error == 0)
        let handle = payload(from: open).leUInt64(at: 0)

        let read = server.handle(request: request(
            unique: 348,
            opcode: .read,
            nodeID: nodeID,
            payload: bytes(handle) + bytes(UInt64(0)) + bytes(UInt32(32))
                + bytes(UInt32(0)) + bytes(UInt64(0)) + bytes(UInt32(0)) + bytes(UInt32(0))
        ))
        #expect(try FuseProtocol.decodeOutHeader(read).error == 0)
        #expect(String(decoding: payload(from: read), as: UTF8.self) == "pinned")

        _ = server.handle(request: request(
            unique: 349,
            opcode: .release,
            nodeID: nodeID,
            payload: bytes(handle) + bytes(UInt32(0)) + bytes(UInt32(0)) + bytes(UInt64(0))
        ))
        let retired = server.handle(request: request(
            unique: 350,
            opcode: .getattr,
            nodeID: nodeID,
            payload: FuseProtocol.encodeGetattrIn(FuseGetattrIn())
        ))
        #expect(try FuseProtocol.decodeOutHeader(retired).error == -ENOENT)
    }

    @Test func writebackModeAllowsKernelReadOnLogicalWriteOnlyHandle() throws {
        let root = try TestFuseServerRoot()
        try root.write("writeback", to: "write-only.txt")
        let server = try FuseServer(
            hostFS: HostFS(rootPath: root.url.path),
            writebackCache: true
        )
        let lookup = server.handle(request: request(
            unique: 351,
            opcode: .lookup,
            nodeID: HostFS.rootNodeID,
            payload: Array("write-only.txt\0".utf8)
        ))
        let nodeID = payload(from: lookup).leUInt64(at: 0)
        let open = server.handle(request: request(
            unique: 352,
            opcode: .open,
            nodeID: nodeID,
            payload: bytes(UInt32(1)) + bytes(UInt32(0)) // Linux O_WRONLY
        ))
        #expect(try FuseProtocol.decodeOutHeader(open).error == 0)
        let handle = payload(from: open).leUInt64(at: 0)
        let readPayload = bytes(handle) + bytes(UInt64(0)) + bytes(UInt32(32))
            + bytes(UInt32(0)) + bytes(UInt64(0)) + bytes(UInt32(0)) + bytes(UInt32(0))

        let arrayRead = server.handle(request: request(
            unique: 353,
            opcode: .read,
            nodeID: nodeID,
            payload: readPayload
        ))
        #expect(try FuseProtocol.decodeOutHeader(arrayRead).error == 0)
        #expect(String(decoding: payload(from: arrayRead), as: UTF8.self) == "writeback")
        let directRead = try directReadResponse(server: server, request: request(
            unique: 354,
            opcode: .read,
            nodeID: nodeID,
            payload: readPayload
        ))
        #expect(try FuseProtocol.decodeOutHeader(directRead).error == 0)
        #expect(String(decoding: payload(from: directRead), as: UTF8.self) == "writeback")
        _ = server.handle(request: request(
            unique: 355,
            opcode: .release,
            nodeID: nodeID,
            payload: bytes(handle) + bytes(UInt32(0)) + bytes(UInt32(0)) + bytes(UInt64(0))
        ))
    }

    @Test func writebackCreateMakesLogicalWriteOnlyHandleReadableToKernel() throws {
        let root = try TestFuseServerRoot()
        let server = try FuseServer(
            hostFS: HostFS(rootPath: root.url.path),
            writebackCache: true
        )
        let create = server.handle(request: request(
            unique: 356,
            opcode: .create,
            nodeID: HostFS.rootNodeID,
            payload: bytes(UInt32(0x40 | 0x1)) + bytes(UInt32(0o644))
                + bytes(UInt32(0)) + bytes(UInt32(0)) + Array("writeback-created.txt\0".utf8)
        ))
        #expect(try FuseProtocol.decodeOutHeader(create).error == 0)
        let createPayload = payload(from: create)
        let nodeID = createPayload.leUInt64(at: 0)
        let handle = createPayload.leUInt64(at: 128)
        let writeData = Array("created".utf8)
        let write = server.handle(request: request(
            unique: 357,
            opcode: .write,
            nodeID: nodeID,
            payload: bytes(handle) + bytes(UInt64(0)) + bytes(UInt32(writeData.count))
                + bytes(UInt32(0)) + bytes(UInt64(0)) + bytes(UInt32(0)) + bytes(UInt32(0))
                + writeData
        ))
        #expect(try FuseProtocol.decodeOutHeader(write).error == 0)

        let read = server.handle(request: request(
            unique: 358,
            opcode: .read,
            nodeID: nodeID,
            payload: bytes(handle) + bytes(UInt64(0)) + bytes(UInt32(32))
                + bytes(UInt32(0)) + bytes(UInt64(0)) + bytes(UInt32(0)) + bytes(UInt32(0))
        ))
        #expect(try FuseProtocol.decodeOutHeader(read).error == 0)
        #expect(String(decoding: payload(from: read), as: UTF8.self) == "created")
    }

    @Test func linuxAppendAndTruncateFlagsAreMappedWithoutDarwinBitCollisions() throws {
        let root = try TestFuseServerRoot()
        try root.write("seed", to: "value.txt")
        let path = root.url.appendingPathComponent("value.txt")
        let hostFS = try HostFS(rootPath: root.url.path)
        let server = FuseServer(hostFS: hostFS)
        let lookup = server.handle(request: request(
            unique: 340,
            opcode: .lookup,
            nodeID: HostFS.rootNodeID,
            payload: Array("value.txt\0".utf8)
        ))
        let nodeID = payload(from: lookup).leUInt64(at: 0)

        // Linux O_TRUNC is 0x200, which is Darwin O_CREAT. OPEN must not pass it through or truncate
        // here; FUSE_ATOMIC_O_TRUNC is not advertised, so Linux sends a separate SETATTR.
        let truncOpen = server.handle(request: request(
            unique: 341,
            opcode: .open,
            nodeID: nodeID,
            payload: bytes(UInt32(0x2 | 0x200)) + bytes(UInt32(0))
        ))
        #expect(try FuseProtocol.decodeOutHeader(truncOpen).error == 0)
        let truncHandle = payload(from: truncOpen).leUInt64(at: 0)
        #expect(try String(contentsOf: path, encoding: .utf8) == "seed")

        // Linux O_APPEND is 0x400, which is Darwin O_TRUNC. Decode it logically and use write(2)
        // so the supplied FUSE offsets cannot overwrite existing bytes.
        let appendOpen = server.handle(request: request(
            unique: 342,
            opcode: .open,
            nodeID: nodeID,
            payload: bytes(UInt32(0x2 | 0x400)) + bytes(UInt32(0))
        ))
        #expect(try FuseProtocol.decodeOutHeader(appendOpen).error == 0)
        let appendHandle = payload(from: appendOpen).leUInt64(at: 0)
        for (unique, byte, offset) in [(UInt64(343), "A", UInt64(0)), (UInt64(344), "B", UInt64(999))] {
            let data = Array(byte.utf8)
            let write = server.handle(request: request(
                unique: unique,
                opcode: .write,
                nodeID: nodeID,
                payload: bytes(appendHandle) + bytes(offset) + bytes(UInt32(data.count))
                    + bytes(UInt32(0)) + bytes(UInt64(0)) + bytes(UInt32(0)) + bytes(UInt32(0))
                    + data
            ))
            #expect(try FuseProtocol.decodeOutHeader(write).error == 0)
        }
        #expect(try String(contentsOf: path, encoding: .utf8) == "seedAB")
        #expect(try hostFS.cachedAttributes(nodeID: nodeID).size == 6)

        try root.write("replacement", to: "value.txt")
        let staleGetattr = server.handle(request: request(
            unique: 3440,
            opcode: .getattr,
            nodeID: nodeID,
            payload: FuseProtocol.encodeGetattrIn(FuseGetattrIn())
        ))
        #expect(try FuseProtocol.decodeOutHeader(staleGetattr).error == 0)
        #expect(payload(from: staleGetattr).leUInt64(at: 24) == 6)
        let detachedGetattr = server.handle(request: request(
            unique: 3441,
            opcode: .getattr,
            nodeID: nodeID,
            payload: FuseProtocol.encodeGetattrIn(FuseGetattrIn())
        ))
        #expect(try FuseProtocol.decodeOutHeader(detachedGetattr).error == 0)
        #expect(payload(from: detachedGetattr).leUInt64(at: 24) == 6)

        // A literal Linux CREATE|RDWR|APPEND must create, not inherit Darwin's 0x400 truncation bit.
        let create = server.handle(request: request(
            unique: 345,
            opcode: .create,
            nodeID: HostFS.rootNodeID,
            payload: bytes(UInt32(0x40 | 0x2 | 0x400)) + bytes(UInt32(0o644))
                + bytes(UInt32(0)) + bytes(UInt32(0)) + Array("append-created.txt\0".utf8)
        ))
        #expect(try FuseProtocol.decodeOutHeader(create).error == 0)
        let createHandle = payload(from: create).leUInt64(at: 128)
        let releasePayload = { (handle: UInt64) in
            bytes(handle) + bytes(UInt32(0)) + bytes(UInt32(0)) + bytes(UInt64(0))
        }
        for (unique, releasedNodeID, handle) in [
            (UInt64(3450), nodeID, truncHandle),
            (UInt64(3451), nodeID, appendHandle),
            (UInt64(3452), payload(from: create).leUInt64(at: 0), createHandle),
        ] {
            _ = server.handle(request: request(
                unique: unique,
                opcode: .release,
                nodeID: releasedNodeID,
                payload: releasePayload(handle)
            ))
        }
    }

    @Test func forgetAndBatchForgetReleaseLookupRefsWithoutReplies() throws {
        let root = try TestFuseServerRoot()
        try root.write("payload", to: "forgotten.txt")
        let hostFS = try HostFS(rootPath: root.url.path)
        let server = FuseServer(hostFS: hostFS)

        let firstLookup = server.handle(request: request(
            unique: 20,
            opcode: .lookup,
            nodeID: HostFS.rootNodeID,
            payload: Array("forgotten.txt\0".utf8)
        ))
        let nodeID = payload(from: firstLookup).leUInt64(at: 0)
        _ = server.handle(request: request(
            unique: 21,
            opcode: .lookup,
            nodeID: HostFS.rootNodeID,
            payload: Array("forgotten.txt\0".utf8)
        ))
        try hostFS.unlink(parent: HostFS.rootNodeID, name: "forgotten.txt")

        let forget = server.handle(request: request(
            unique: 22,
            opcode: .forget,
            nodeID: nodeID,
            payload: FuseProtocol.encodeForgetIn(FuseForgetIn(lookupCount: 1))
        ))
        #expect(forget.isEmpty)
        #expect(try hostFS.cachedAttributes(nodeID: nodeID).size == 7)

        let batch = server.handle(request: request(
            unique: 23,
            opcode: .batchForget,
            nodeID: 0,
            payload: FuseProtocol.encodeBatchForgetIn(FuseBatchForgetIn(entries: [
                FuseForgetOne(nodeID: nodeID, lookupCount: 1),
                FuseForgetOne(nodeID: 99_999, lookupCount: 5),
            ]))
        ))
        #expect(batch.isEmpty)
        #expect(throws: HostFSError.notFound("node \(nodeID)")) {
            _ = try hostFS.cachedAttributes(nodeID: nodeID)
        }
    }

    @Test func unpublishedResponsesRollbackLookupFileDirectoryCreateAndReaddirplusGrants() throws {
        let root = try TestFuseServerRoot()
        try root.write("source", to: "source.txt")
        let hostFS = try HostFS(rootPath: root.url.path)
        let server = FuseServer(hostFS: hostFS)
        func rollback(_ response: [UInt8], opcode: FuseOpcode) {
            var storage = response
            storage.withUnsafeMutableBytes { raw in
                server.rollbackUnpublishedResponse(
                    opcode: opcode,
                    writable: [VirtqueueSegment(
                        pointer: raw.baseAddress!,
                        length: raw.count,
                        isDeviceWritable: true
                    )],
                    written: raw.count
                )
            }
        }

        let droppedLookup = server.handle(request: request(
            unique: 2000,
            opcode: .lookup,
            nodeID: HostFS.rootNodeID,
            payload: Array("source.txt\0".utf8)
        ))
        let droppedLookupNode = payload(from: droppedLookup).leUInt64(at: 0)
        rollback(droppedLookup, opcode: .lookup)
        #expect(throws: HostFSError.notFound("node \(droppedLookupNode)")) {
            _ = try hostFS.cachedAttributes(nodeID: droppedLookupNode)
        }

        let lookup = server.handle(request: request(
            unique: 2001,
            opcode: .lookup,
            nodeID: HostFS.rootNodeID,
            payload: Array("source.txt\0".utf8)
        ))
        let nodeID = payload(from: lookup).leUInt64(at: 0)
        let droppedOpen = server.handle(request: request(
            unique: 2002,
            opcode: .open,
            nodeID: nodeID,
            payload: bytes(UInt32(0)) + bytes(UInt32(0))
        ))
        let droppedFileHandle = payload(from: droppedOpen).leUInt64(at: 0)
        rollback(droppedOpen, opcode: .open)
        let staleRead = server.handle(request: request(
            unique: 2003,
            opcode: .read,
            nodeID: nodeID,
            payload: bytes(droppedFileHandle) + bytes(UInt64(0)) + bytes(UInt32(16))
                + bytes(UInt32(0)) + bytes(UInt64(0)) + bytes(UInt32(0)) + bytes(UInt32(0))
        ))
        #expect(try FuseProtocol.decodeOutHeader(staleRead).error == -EBADF)
        _ = server.handle(request: request(
            unique: 2004,
            opcode: .forget,
            nodeID: nodeID,
            payload: FuseProtocol.encodeForgetIn(FuseForgetIn(lookupCount: 1))
        ))

        let droppedCreate = server.handle(request: request(
            unique: 2005,
            opcode: .create,
            nodeID: HostFS.rootNodeID,
            payload: bytes(UInt32(0x40 | 0x2)) + bytes(UInt32(0o644))
                + bytes(UInt32(0)) + bytes(UInt32(0)) + Array("created.txt\0".utf8)
        ))
        let createdPayload = payload(from: droppedCreate)
        let createdNodeID = createdPayload.leUInt64(at: 0)
        let createdHandle = createdPayload.leUInt64(at: 128)
        rollback(droppedCreate, opcode: .create)
        #expect(FileManager.default.fileExists(atPath: root.url.appendingPathComponent("created.txt").path))
        #expect(throws: HostFSError.notFound("node \(createdNodeID)")) {
            _ = try hostFS.cachedAttributes(nodeID: createdNodeID)
        }
        let staleCreateRead = server.handle(request: request(
            unique: 2006,
            opcode: .read,
            nodeID: createdNodeID,
            payload: bytes(createdHandle) + bytes(UInt64(0)) + bytes(UInt32(1))
                + bytes(UInt32(0)) + bytes(UInt64(0)) + bytes(UInt32(0)) + bytes(UInt32(0))
        ))
        #expect(try FuseProtocol.decodeOutHeader(staleCreateRead).error == -EBADF)

        let droppedOpenDir = server.handle(request: request(
            unique: 2007,
            opcode: .opendir,
            nodeID: HostFS.rootNodeID
        ))
        let droppedDirectoryHandle = payload(from: droppedOpenDir).leUInt64(at: 0)
        rollback(droppedOpenDir, opcode: .opendir)
        let staleReadDir = server.handle(request: request(
            unique: 2008,
            opcode: .readdirplus,
            nodeID: HostFS.rootNodeID,
            payload: bytes(droppedDirectoryHandle) + bytes(UInt64(0)) + bytes(UInt32(4096))
                + bytes(UInt32(0)) + bytes(UInt64(0)) + bytes(UInt32(0)) + bytes(UInt32(0))
        ))
        #expect(try FuseProtocol.decodeOutHeader(staleReadDir).error == -EBADF)

        try FileManager.default.removeItem(at: root.url.appendingPathComponent("source.txt"))
        try FileManager.default.removeItem(at: root.url.appendingPathComponent("created.txt"))
        try root.write("child", to: "child.txt")
        let openedDirectory = server.handle(request: request(
            unique: 2009,
            opcode: .opendir,
            nodeID: HostFS.rootNodeID
        ))
        let directoryHandle = payload(from: openedDirectory).leUInt64(at: 0)
        let droppedListing = server.handle(request: request(
            unique: 2010,
            opcode: .readdirplus,
            nodeID: HostFS.rootNodeID,
            payload: bytes(directoryHandle) + bytes(UInt64(0)) + bytes(UInt32(4096))
                + bytes(UInt32(0)) + bytes(UInt64(0)) + bytes(UInt32(0)) + bytes(UInt32(0))
        ))
        let childNodeID = payload(from: droppedListing).leUInt64(at: 0)
        rollback(droppedListing, opcode: .readdirplus)
        #expect(throws: HostFSError.notFound("node \(childNodeID)")) {
            _ = try hostFS.cachedAttributes(nodeID: childNodeID)
        }
        _ = server.handle(request: request(
            unique: 2011,
            opcode: .releasedir,
            nodeID: HostFS.rootNodeID,
            payload: bytes(directoryHandle) + bytes(UInt32(0)) + bytes(UInt32(0)) + bytes(UInt64(0))
        ))
    }

    @Test func connectionResetClosesOldHandlesRetiresNodesAndNeverImmediatelyReusesHandleIDs() throws {
        let root = try TestFuseServerRoot()
        try root.write("payload", to: "reset.txt")
        let hostFS = try HostFS(rootPath: root.url.path)
        let server = FuseServer(hostFS: hostFS)
        let oldLookup = server.handle(request: request(
            unique: 2020,
            opcode: .lookup,
            nodeID: HostFS.rootNodeID,
            payload: Array("reset.txt\0".utf8)
        ))
        let oldNodeID = payload(from: oldLookup).leUInt64(at: 0)
        let oldOpen = server.handle(request: request(
            unique: 2021,
            opcode: .open,
            nodeID: oldNodeID,
            payload: bytes(UInt32(0)) + bytes(UInt32(0))
        ))
        let oldFileHandle = payload(from: oldOpen).leUInt64(at: 0)
        let oldOpenDir = server.handle(request: request(
            unique: 2022,
            opcode: .opendir,
            nodeID: HostFS.rootNodeID
        ))
        let oldDirectoryHandle = payload(from: oldOpenDir).leUInt64(at: 0)

        server.resetConnection()

        #expect(throws: HostFSError.notFound("node \(oldNodeID)")) {
            _ = try hostFS.cachedAttributes(nodeID: oldNodeID)
        }
        let staleRead = server.handle(request: request(
            unique: 2023,
            opcode: .read,
            nodeID: oldNodeID,
            payload: bytes(oldFileHandle) + bytes(UInt64(0)) + bytes(UInt32(16))
                + bytes(UInt32(0)) + bytes(UInt64(0)) + bytes(UInt32(0)) + bytes(UInt32(0))
        ))
        #expect(try FuseProtocol.decodeOutHeader(staleRead).error == -EBADF)
        let staleReadDir = server.handle(request: request(
            unique: 2024,
            opcode: .readdirplus,
            nodeID: HostFS.rootNodeID,
            payload: bytes(oldDirectoryHandle) + bytes(UInt64(0)) + bytes(UInt32(4096))
                + bytes(UInt32(0)) + bytes(UInt64(0)) + bytes(UInt32(0)) + bytes(UInt32(0))
        ))
        #expect(try FuseProtocol.decodeOutHeader(staleReadDir).error == -EBADF)

        let freshLookup = server.handle(request: request(
            unique: 2025,
            opcode: .lookup,
            nodeID: HostFS.rootNodeID,
            payload: Array("reset.txt\0".utf8)
        ))
        let freshNodeID = payload(from: freshLookup).leUInt64(at: 0)
        let freshOpen = server.handle(request: request(
            unique: 2026,
            opcode: .open,
            nodeID: freshNodeID,
            payload: bytes(UInt32(0)) + bytes(UInt32(0))
        ))
        let freshFileHandle = payload(from: freshOpen).leUInt64(at: 0)
        let freshOpenDir = server.handle(request: request(
            unique: 2027,
            opcode: .opendir,
            nodeID: HostFS.rootNodeID
        ))
        let freshDirectoryHandle = payload(from: freshOpenDir).leUInt64(at: 0)

        #expect(freshNodeID > oldNodeID)
        #expect(freshFileHandle != oldFileHandle)
        #expect(freshDirectoryHandle != oldDirectoryHandle)
        _ = server.handle(request: request(
            unique: 2028,
            opcode: .release,
            nodeID: oldNodeID,
            payload: bytes(oldFileHandle) + bytes(UInt32(0)) + bytes(UInt32(0)) + bytes(UInt64(0))
        ))
        let freshRead = server.handle(request: request(
            unique: 2029,
            opcode: .read,
            nodeID: freshNodeID,
            payload: bytes(freshFileHandle) + bytes(UInt64(0)) + bytes(UInt32(16))
                + bytes(UInt32(0)) + bytes(UInt64(0)) + bytes(UInt32(0)) + bytes(UInt32(0))
        ))
        #expect(String(decoding: payload(from: freshRead), as: UTF8.self) == "payload")
    }

    @Test func forgetBeforeFileReleaseKeepsNodeAndOpenHandleAlive() throws {
        let root = try TestFuseServerRoot()
        try root.write("payload", to: "open.txt")
        let hostFS = try HostFS(rootPath: root.url.path)
        let server = FuseServer(hostFS: hostFS)
        let lookup = server.handle(request: request(
            unique: 26,
            opcode: .lookup,
            nodeID: HostFS.rootNodeID,
            payload: Array("open.txt\0".utf8)
        ))
        let nodeID = payload(from: lookup).leUInt64(at: 0)
        let opened = server.handle(request: request(
            unique: 27,
            opcode: .open,
            nodeID: nodeID,
            payload: bytes(UInt32(O_RDONLY)) + bytes(UInt32(0))
        ))
        let handle = payload(from: opened).leUInt64(at: 0)

        #expect(server.handle(request: request(
            unique: 28,
            opcode: .forget,
            nodeID: nodeID,
            payload: FuseProtocol.encodeForgetIn(FuseForgetIn(lookupCount: 1))
        )).isEmpty)
        #expect(try hostFS.cachedAttributes(nodeID: nodeID).size == 7)

        let readIn = bytes(handle) + bytes(UInt64(0)) + bytes(UInt32(7)) + bytes(UInt32(0))
            + bytes(UInt64(0)) + bytes(UInt32(0)) + bytes(UInt32(0))
        let read = server.handle(request: request(unique: 29, opcode: .read, nodeID: nodeID, payload: readIn))
        #expect(try FuseProtocol.decodeOutHeader(read).error == 0)
        #expect(String(decoding: payload(from: read), as: UTF8.self) == "payload")

        let releaseIn = bytes(handle) + bytes(UInt32(0)) + bytes(UInt32(0)) + bytes(UInt64(0))
        let released = server.handle(request: request(unique: 30, opcode: .release, nodeID: nodeID, payload: releaseIn))
        #expect(try FuseProtocol.decodeOutHeader(released).error == 0)
        #expect(throws: HostFSError.notFound("node \(nodeID)")) {
            _ = try hostFS.cachedAttributes(nodeID: nodeID)
        }
    }

    @Test func forgetBeforeDirectoryReleaseKeepsNodeAndDirectoryHandleAlive() throws {
        let root = try TestFuseServerRoot()
        try FileManager.default.createDirectory(at: root.url.appendingPathComponent("nested"), withIntermediateDirectories: false)
        try root.write("child", to: "nested/child.txt")
        let hostFS = try HostFS(rootPath: root.url.path)
        let server = FuseServer(hostFS: hostFS)
        let lookup = server.handle(request: request(
            unique: 31,
            opcode: .lookup,
            nodeID: HostFS.rootNodeID,
            payload: Array("nested\0".utf8)
        ))
        let nodeID = payload(from: lookup).leUInt64(at: 0)
        let opened = server.handle(request: request(unique: 32, opcode: .opendir, nodeID: nodeID))
        let handle = payload(from: opened).leUInt64(at: 0)

        #expect(server.handle(request: request(
            unique: 33,
            opcode: .forget,
            nodeID: nodeID,
            payload: FuseProtocol.encodeForgetIn(FuseForgetIn(lookupCount: 1))
        )).isEmpty)
        #expect(try hostFS.cachedAttributes(nodeID: nodeID).isDirectory)

        let readIn = bytes(handle) + bytes(UInt64(0)) + bytes(UInt32(4096)) + bytes(UInt32(0))
            + bytes(UInt64(0)) + bytes(UInt32(0)) + bytes(UInt32(0))
        let listing = server.handle(request: request(unique: 34, opcode: .readdirplus, nodeID: nodeID, payload: readIn))
        #expect(try FuseProtocol.decodeOutHeader(listing).error == 0)
        #expect(String(decoding: payload(from: listing)[(128 + 24)..<(128 + 33)], as: UTF8.self) == "child.txt")

        let releaseIn = bytes(handle) + bytes(UInt32(0)) + bytes(UInt32(0)) + bytes(UInt64(0))
        let released = server.handle(request: request(unique: 35, opcode: .releasedir, nodeID: nodeID, payload: releaseIn))
        #expect(try FuseProtocol.decodeOutHeader(released).error == 0)
        #expect(throws: HostFSError.notFound("node \(nodeID)")) {
            _ = try hostFS.cachedAttributes(nodeID: nodeID)
        }
    }

    @Test func releasedirCannotConsumeAFileHandleFromTheOtherNamespace() throws {
        let root = try TestFuseServerRoot()
        try root.write("payload", to: "file.txt")
        let server = try FuseServer(hostFS: HostFS(rootPath: root.url.path))
        let lookup = server.handle(request: request(
            unique: 36,
            opcode: .lookup,
            nodeID: HostFS.rootNodeID,
            payload: Array("file.txt\0".utf8)
        ))
        let nodeID = payload(from: lookup).leUInt64(at: 0)
        let openedFile = server.handle(request: request(
            unique: 37,
            opcode: .open,
            nodeID: nodeID,
            payload: bytes(UInt32(O_RDONLY)) + bytes(UInt32(0))
        ))
        let fileHandle = payload(from: openedFile).leUInt64(at: 0)
        let openedDirectory = server.handle(request: request(unique: 38, opcode: .opendir, nodeID: HostFS.rootNodeID))
        let directoryHandle = payload(from: openedDirectory).leUInt64(at: 0)
        #expect(fileHandle != directoryHandle)

        let releaseDirectoryIn = bytes(directoryHandle) + bytes(UInt32(0)) + bytes(UInt32(0)) + bytes(UInt64(0))
        let releaseDirectoryRequest = request(
            unique: 39,
            opcode: .releasedir,
            nodeID: HostFS.rootNodeID,
            payload: releaseDirectoryIn
        )
        let releaseDirectoryHeader = try FuseProtocol.decodeInHeader(releaseDirectoryRequest)
        let releaseDirectoryPayload = releaseDirectoryRequest[FuseInHeader.byteCount..<Int(releaseDirectoryHeader.length)]
        var releaseDestination = [UInt8](repeating: 0, count: FuseOutHeader.byteCount)
        let releaseCount = releaseDestination.withUnsafeMutableBytes { buffer -> Int in
            let segment = VirtqueueSegment(pointer: buffer.baseAddress!, length: buffer.count, isDeviceWritable: true)
            return server.writeReleaseResponse(
                header: releaseDirectoryHeader,
                payload: releaseDirectoryPayload,
                writable: [segment]
            )
        }
        #expect(releaseCount == FuseOutHeader.byteCount)
        #expect(try FuseProtocol.decodeOutHeader(releaseDestination).error == 0)

        let readIn = bytes(fileHandle) + bytes(UInt64(0)) + bytes(UInt32(7)) + bytes(UInt32(0))
            + bytes(UInt64(0)) + bytes(UInt32(0)) + bytes(UInt32(0))
        let read = server.handle(request: request(unique: 40, opcode: .read, nodeID: nodeID, payload: readIn))
        #expect(try FuseProtocol.decodeOutHeader(read).error == 0)
        #expect(String(decoding: payload(from: read), as: UTF8.self) == "payload")

        let releaseFileIn = bytes(fileHandle) + bytes(UInt32(0)) + bytes(UInt32(0)) + bytes(UInt64(0))
        let releasedFile = server.handle(request: request(unique: 41, opcode: .release, nodeID: nodeID, payload: releaseFileIn))
        #expect(try FuseProtocol.decodeOutHeader(releasedFile).error == 0)
    }

    @Test func malformedForgetRequestsStillHonorNoReplyContract() throws {
        let root = try TestFuseServerRoot()
        let server = try FuseServer(hostFS: HostFS(rootPath: root.url.path))

        #expect(server.handle(request: request(
            unique: 24,
            opcode: .forget,
            nodeID: 2,
            payload: [1, 2, 3]
        )).isEmpty)
        #expect(server.handle(request: request(
            unique: 25,
            opcode: .batchForget,
            nodeID: 0,
            payload: [2, 0, 0, 0, 0, 0, 0, 0]
        )).isEmpty)
    }

    @Test func zeroCopyReadMatchesArrayPath() throws {
        let root = try TestFuseServerRoot()
        try root.write("hello dory world", to: "z.txt")
        let server = try FuseServer(hostFS: HostFS(rootPath: root.url.path))
        let nodeID = payload(from: server.handle(request: request(unique: 1, opcode: .lookup, nodeID: HostFS.rootNodeID, payload: Array("z.txt\0".utf8)))).leUInt64(at: 0)
        let handle = payload(from: server.handle(request: request(unique: 2, opcode: .open, nodeID: nodeID, payload: bytes(UInt32(O_RDONLY)) + bytes(UInt32(0))))).leUInt64(at: 0)

        let readIn = bytes(handle) + bytes(UInt64(6)) + bytes(UInt32(4)) + bytes(UInt32(0)) + bytes(UInt64(0)) + bytes(UInt32(0)) + bytes(UInt32(0))
        let req = request(unique: 3, opcode: .read, nodeID: nodeID, payload: readIn)

        let arrayPath = server.handle(request: req)

        let header = try FuseProtocol.decodeInHeader(req)
        let readPayload = Array(req[FuseInHeader.byteCount..<Int(header.length)])
        var dest = [UInt8](repeating: 0, count: FuseOutHeader.byteCount + 4096)
        let written = dest.withUnsafeMutableBytes { buffer -> Int in
            let segment = VirtqueueSegment(pointer: buffer.baseAddress!, length: buffer.count, isDeviceWritable: true)
            return server.writeReadResponse(header: header, payload: readPayload, writable: [segment])
        }

        #expect(Array(dest[0..<written]) == arrayPath)
        #expect(String(decoding: dest[FuseOutHeader.byteCount..<written], as: UTF8.self) == "dory")
    }

    @Test func directWriteAndReleaseMatchArrayPath() throws {
        let root = try TestFuseServerRoot()
        let server = try FuseServer(hostFS: HostFS(rootPath: root.url.path))
        let createIn = bytes(UInt32(0x40 | 0x2)) + bytes(UInt32(0o644))
            + bytes(UInt32(0)) + bytes(UInt32(0)) + Array("direct.txt\0".utf8)
        let create = server.handle(request: request(unique: 101, opcode: .create, nodeID: HostFS.rootNodeID, payload: createIn))
        let createPayload = payload(from: create)
        let nodeID = createPayload.leUInt64(at: 0)
        let handle = createPayload.leUInt64(at: 128)
        let writeData = Array("hello direct".utf8)
        let writeIn = bytes(handle) + bytes(UInt64(0)) + bytes(UInt32(writeData.count)) + bytes(UInt32(0)) + bytes(UInt64(0)) + bytes(UInt32(0)) + bytes(UInt32(0)) + writeData
        let writeRequest = request(unique: 102, opcode: .write, nodeID: nodeID, payload: writeIn)
        let writeHeader = try FuseProtocol.decodeInHeader(writeRequest)
        let writePayload = writeRequest[FuseInHeader.byteCount..<Int(writeHeader.length)]
        var writeDest = [UInt8](repeating: 0, count: FuseOutHeader.byteCount + 8)
        let writeCount = writeDest.withUnsafeMutableBytes { buffer -> Int in
            let segment = VirtqueueSegment(pointer: buffer.baseAddress!, length: buffer.count, isDeviceWritable: true)
            return server.writeWriteResponse(header: writeHeader, payload: writePayload, writable: [segment])
        }

        #expect(writeCount == FuseOutHeader.byteCount + 8)
        #expect(try FuseProtocol.decodeOutHeader(Array(writeDest)).error == 0)
        #expect(payload(from: Array(writeDest)).leUInt32(at: 0) == UInt32(writeData.count))

        let releaseIn = bytes(handle) + bytes(UInt32(0)) + bytes(UInt32(0)) + bytes(UInt64(0))
        let releaseRequest = request(unique: 103, opcode: .release, nodeID: nodeID, payload: releaseIn)
        let releaseHeader = try FuseProtocol.decodeInHeader(releaseRequest)
        let releasePayload = releaseRequest[FuseInHeader.byteCount..<Int(releaseHeader.length)]
        var releaseDest = [UInt8](repeating: 0, count: FuseOutHeader.byteCount)
        let releaseCount = releaseDest.withUnsafeMutableBytes { buffer -> Int in
            let segment = VirtqueueSegment(pointer: buffer.baseAddress!, length: buffer.count, isDeviceWritable: true)
            return server.writeReleaseResponse(header: releaseHeader, payload: releasePayload, writable: [segment])
        }

        #expect(releaseCount == FuseOutHeader.byteCount)
        #expect(try FuseProtocol.decodeOutHeader(Array(releaseDest)).error == 0)
        #expect(try String(contentsOf: root.url.appendingPathComponent("direct.txt"), encoding: .utf8) == "hello direct")
    }

    @Test func releaseCannotCloseDescriptorBorrowedByConcurrentWrite() async throws {
        let root = try TestFuseServerRoot()
        let server = try FuseServer(hostFS: HostFS(rootPath: root.url.path))
        let create = server.handle(request: request(
            unique: 120,
            opcode: .create,
            nodeID: HostFS.rootNodeID,
            payload: bytes(UInt32(0x40 | 0x2)) + bytes(UInt32(0o644))
                + bytes(UInt32(0)) + bytes(UInt32(0)) + Array("leased.txt\0".utf8)
        ))
        let created = payload(from: create)
        let nodeID = created.leUInt64(at: 0)
        let handle = created.leUInt64(at: 128)
        let data = Array("survives release".utf8)
        let write = request(
            unique: 121,
            opcode: .write,
            nodeID: nodeID,
            payload: bytes(handle) + bytes(UInt64(0)) + bytes(UInt32(data.count))
                + bytes(UInt32(0)) + bytes(UInt64(0)) + bytes(UInt32(0))
                + bytes(UInt32(0)) + data
        )
        let loaded = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        server.fileOperationLoadedTestHook = {
            loaded.signal()
            resume.wait()
        }

        let writeTask = Task.detached { server.handle(request: write) }
        let waitResult = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: loaded.wait(timeout: .now() + 2))
            }
        }
        #expect(waitResult == .success)
        let release = server.handle(request: request(
            unique: 122,
            opcode: .release,
            nodeID: nodeID,
            payload: bytes(handle) + bytes(UInt32(0)) + bytes(UInt32(0)) + bytes(UInt64(0))
        ))
        #expect(try FuseProtocol.decodeOutHeader(release).error == 0)
        server.fileOperationLoadedTestHook = nil
        resume.signal()

        let response = await writeTask.value
        #expect(try FuseProtocol.decodeOutHeader(response).error == 0)
        #expect(payload(from: response).leUInt32(at: 0) == UInt32(data.count))
        #expect(
            try String(contentsOf: root.url.appendingPathComponent("leased.txt"), encoding: .utf8)
                == "survives release"
        )

        let stale = server.handle(request: write)
        #expect(try FuseProtocol.decodeOutHeader(stale).error == -EBADF)
    }

    @Test func directMetadataMissResponsesMatchArrayPath() throws {
        let root = try TestFuseServerRoot()
        try root.write("exists", to: "exists.txt")
        let arrayServer = try FuseServer(hostFS: HostFS(rootPath: root.url.path))
        let directHostFS = try HostFS(rootPath: root.url.path)
        let directServer = FuseServer(hostFS: directHostFS)

        let missingRequest = request(unique: 201, opcode: .lookup, nodeID: HostFS.rootNodeID, payload: Array("missing.txt\0".utf8))
        let missingHeader = try FuseProtocol.decodeInHeader(missingRequest)
        let missingPayload = missingRequest[FuseInHeader.byteCount..<Int(missingHeader.length)]
        let missingArrayPath = arrayServer.handle(request: missingRequest)
        var missingDest = [UInt8](repeating: 0, count: FuseOutHeader.byteCount + 128)
        let missingCount = missingDest.withUnsafeMutableBytes { buffer -> Int in
            let segment = VirtqueueSegment(pointer: buffer.baseAddress!, length: buffer.count, isDeviceWritable: true)
            return directServer.writeLookupResponse(header: missingHeader, payload: missingPayload, writable: [segment])
        }

        // Misses are always plain ENOENT. A negative dentry could hide a concurrently created path.
        #expect(missingCount == FuseOutHeader.byteCount)
        #expect(Array(missingDest[0..<missingCount]) == missingArrayPath)
        #expect(try FuseProtocol.decodeOutHeader(Array(missingDest)).error == -ENOENT)

        let hitRequest = request(unique: 202, opcode: .lookup, nodeID: HostFS.rootNodeID, payload: Array("exists.txt\0".utf8))
        let hitHeader = try FuseProtocol.decodeInHeader(hitRequest)
        let hitPayload = hitRequest[FuseInHeader.byteCount..<Int(hitHeader.length)]
        let hitArrayPath = arrayServer.handle(request: hitRequest)
        var hitDest = [UInt8](repeating: 0, count: FuseOutHeader.byteCount + 128)
        let hitCount = hitDest.withUnsafeMutableBytes { buffer -> Int in
            let segment = VirtqueueSegment(pointer: buffer.baseAddress!, length: buffer.count, isDeviceWritable: true)
            return directServer.writeLookupResponse(header: hitHeader, payload: hitPayload, writable: [segment])
        }

        #expect(hitCount == FuseOutHeader.byteCount + 128)
        #expect(Array(hitDest[0..<hitCount]) == hitArrayPath)

        // A direct hit owns exactly one lookup reference. Once the entry is detached, one matching
        // FORGET must retire the tombstone rather than leaving a reference acquired by a hidden
        // fallback lookup.
        let hitNodeID = payload(from: Array(hitDest)).leUInt64(at: 0)
        try directHostFS.unlink(parent: HostFS.rootNodeID, name: "exists.txt")
        #expect(try directHostFS.cachedAttributes(nodeID: hitNodeID).size == 6)
        directHostFS.forgetLookup(nodeID: hitNodeID, count: 1)
        #expect(throws: HostFSError.notFound("node \(hitNodeID)")) {
            _ = try directHostFS.cachedAttributes(nodeID: hitNodeID)
        }

        let getxattrRequest = request(unique: 203, opcode: .getxattr, nodeID: HostFS.rootNodeID)
        let getxattrHeader = try FuseProtocol.decodeInHeader(getxattrRequest)
        let getxattrArrayPath = arrayServer.handle(request: getxattrRequest)
        var getxattrDest = [UInt8](repeating: 0, count: FuseOutHeader.byteCount)
        let getxattrCount = getxattrDest.withUnsafeMutableBytes { buffer -> Int in
            let segment = VirtqueueSegment(pointer: buffer.baseAddress!, length: buffer.count, isDeviceWritable: true)
            return directServer.writeGetXattrNoDataResponse(header: getxattrHeader, writable: [segment])
        }

        #expect(getxattrCount == FuseOutHeader.byteCount)
        #expect(Array(getxattrDest) == getxattrArrayPath)
    }

    @Test func directCreateAndGetattrResponsesAreValid() throws {
        let root = try TestFuseServerRoot()
        let server = try FuseServer(hostFS: HostFS(rootPath: root.url.path))
        let createIn = bytes(UInt32(0x40 | 0x2)) + bytes(UInt32(0o644))
            + bytes(UInt32(0)) + bytes(UInt32(0)) + Array("created-direct.txt\0".utf8)
        let createRequest = request(unique: 210, opcode: .create, nodeID: HostFS.rootNodeID, payload: createIn)
        let createHeader = try FuseProtocol.decodeInHeader(createRequest)
        let createPayload = createRequest[FuseInHeader.byteCount..<Int(createHeader.length)]
        var createDest = [UInt8](repeating: 0, count: FuseOutHeader.byteCount + 144)
        let createCount = createDest.withUnsafeMutableBytes { buffer -> Int in
            let segment = VirtqueueSegment(pointer: buffer.baseAddress!, length: buffer.count, isDeviceWritable: true)
            return server.writeCreateResponse(header: createHeader, payload: createPayload, writable: [segment])
        }

        #expect(createCount == FuseOutHeader.byteCount + 144)
        #expect(try FuseProtocol.decodeOutHeader(Array(createDest)).error == 0)
        let createdPayload = payload(from: Array(createDest))
        let nodeID = createdPayload.leUInt64(at: 0)
        let handle = createdPayload.leUInt64(at: 128)
        #expect(nodeID != HostFS.rootNodeID)
        #expect(handle > 0)
        #expect(createdPayload.leUInt32(at: 108) == 1_000)
        #expect(createdPayload.leUInt32(at: 112) == 1_000)
        #expect(FileManager.default.fileExists(atPath: root.url.appendingPathComponent("created-direct.txt").path))

        let getattrRequest = request(
            unique: 211,
            opcode: .getattr,
            nodeID: nodeID,
            payload: FuseProtocol.encodeGetattrIn(FuseGetattrIn())
        )
        let getattrHeader = try FuseProtocol.decodeInHeader(getattrRequest)
        let getattrInput = getattrRequest[FuseInHeader.byteCount..<Int(getattrHeader.length)]
        let getattrArrayPath = server.handle(request: getattrRequest)
        var getattrDest = [UInt8](repeating: 0, count: FuseOutHeader.byteCount + 104)
        let getattrCount = getattrDest.withUnsafeMutableBytes { buffer -> Int in
            let segment = VirtqueueSegment(pointer: buffer.baseAddress!, length: buffer.count, isDeviceWritable: true)
            return server.writeGetattrResponse(
                header: getattrHeader,
                payload: getattrInput,
                writable: [segment]
            )
        }

        #expect(getattrCount == FuseOutHeader.byteCount + 104)
        #expect(Array(getattrDest) == getattrArrayPath)

        let releaseIn = bytes(handle) + bytes(UInt32(0)) + bytes(UInt32(0)) + bytes(UInt64(0))
        #expect(try FuseProtocol.decodeOutHeader(server.handle(request: request(unique: 212, opcode: .release, nodeID: nodeID, payload: releaseIn))).error == 0)
    }

    @Test func directMkdirUnlinkAndRmdirResponsesAreValid() throws {
        let root = try TestFuseServerRoot()
        try root.write("remove me", to: "gone.txt")
        let server = try FuseServer(hostFS: HostFS(rootPath: root.url.path))
        let mkdirIn = bytes(UInt32(0o755)) + bytes(UInt32(0)) + Array("nested-direct\0".utf8)
        let mkdirRequest = request(unique: 220, opcode: .mkdir, nodeID: HostFS.rootNodeID, payload: mkdirIn)
        let mkdirHeader = try FuseProtocol.decodeInHeader(mkdirRequest)
        let mkdirPayload = mkdirRequest[FuseInHeader.byteCount..<Int(mkdirHeader.length)]
        var mkdirDest = [UInt8](repeating: 0, count: FuseOutHeader.byteCount + 128)
        let mkdirCount = mkdirDest.withUnsafeMutableBytes { buffer -> Int in
            let segment = VirtqueueSegment(pointer: buffer.baseAddress!, length: buffer.count, isDeviceWritable: true)
            return server.writeMkdirResponse(header: mkdirHeader, payload: mkdirPayload, writable: [segment])
        }

        #expect(mkdirCount == FuseOutHeader.byteCount + 128)
        #expect(try FuseProtocol.decodeOutHeader(Array(mkdirDest)).error == 0)
        let mkdirResponse = payload(from: Array(mkdirDest))
        #expect(mkdirResponse.leUInt32(at: 108) == 1_000)
        #expect(mkdirResponse.leUInt32(at: 112) == 1_000)
        #expect(FileManager.default.fileExists(atPath: root.url.appendingPathComponent("nested-direct").path))

        let unlinkRequest = request(unique: 221, opcode: .unlink, nodeID: HostFS.rootNodeID, payload: Array("gone.txt\0".utf8))
        let unlinkHeader = try FuseProtocol.decodeInHeader(unlinkRequest)
        let unlinkPayload = unlinkRequest[FuseInHeader.byteCount..<Int(unlinkHeader.length)]
        var unlinkDest = [UInt8](repeating: 0, count: FuseOutHeader.byteCount)
        let unlinkCount = unlinkDest.withUnsafeMutableBytes { buffer -> Int in
            let segment = VirtqueueSegment(pointer: buffer.baseAddress!, length: buffer.count, isDeviceWritable: true)
            return server.writeRemoveResponse(header: unlinkHeader, opcode: .unlink, payload: unlinkPayload, writable: [segment])
        }

        #expect(unlinkCount == FuseOutHeader.byteCount)
        #expect(try FuseProtocol.decodeOutHeader(Array(unlinkDest)).error == 0)
        #expect(!FileManager.default.fileExists(atPath: root.url.appendingPathComponent("gone.txt").path))

        let rmdirRequest = request(unique: 222, opcode: .rmdir, nodeID: HostFS.rootNodeID, payload: Array("nested-direct\0".utf8))
        let rmdirHeader = try FuseProtocol.decodeInHeader(rmdirRequest)
        let rmdirPayload = rmdirRequest[FuseInHeader.byteCount..<Int(rmdirHeader.length)]
        var rmdirDest = [UInt8](repeating: 0, count: FuseOutHeader.byteCount)
        let rmdirCount = rmdirDest.withUnsafeMutableBytes { buffer -> Int in
            let segment = VirtqueueSegment(pointer: buffer.baseAddress!, length: buffer.count, isDeviceWritable: true)
            return server.writeRemoveResponse(header: rmdirHeader, opcode: .rmdir, payload: rmdirPayload, writable: [segment])
        }

        #expect(rmdirCount == FuseOutHeader.byteCount)
        #expect(try FuseProtocol.decodeOutHeader(Array(rmdirDest)).error == 0)
        #expect(!FileManager.default.fileExists(atPath: root.url.appendingPathComponent("nested-direct").path))
    }

    @Test func readdirplusReturnsPackedDirectoryEntries() throws {
        let root = try TestFuseServerRoot()
        try root.write("a", to: "a.txt")
        try root.write("b", to: "b.txt")
        let server = try FuseServer(hostFS: HostFS(rootPath: root.url.path))

        let opened = server.handle(request: request(unique: 19, opcode: .opendir, nodeID: HostFS.rootNodeID))
        let directoryHandle = payload(from: opened).leUInt64(at: 0)
        let readIn = bytes(directoryHandle) + bytes(UInt64(0)) + bytes(UInt32(4096)) + bytes(UInt32(0)) + bytes(UInt64(0)) + bytes(UInt32(0)) + bytes(UInt32(0))
        let response = server.handle(request: request(unique: 20, opcode: .readdirplus, nodeID: HostFS.rootNodeID, payload: readIn))
        let header = try FuseProtocol.decodeOutHeader(response)
        let data = payload(from: response)

        #expect(header.error == 0)
        #expect(data.count > 128 + 24)
        #expect(data.leUInt32(at: 128 + 16) == 5)
        #expect(String(decoding: data[(128 + 24)..<(128 + 29)], as: UTF8.self) == "a.txt")
        let firstLength = alignedDirentPlusLength(nameLength: 5)
        #expect(data.leUInt32(at: firstLength + 128 + 16) == 5)
        #expect(String(decoding: data[(firstLength + 128 + 24)..<(firstLength + 128 + 29)], as: UTF8.self) == "b.txt")
    }

    @Test func releasedirCannotRetireHandleBorrowedByConcurrentReaddirplus() async throws {
        let root = try TestFuseServerRoot()
        try root.write("payload", to: "kept.txt")
        let server = try FuseServer(hostFS: HostFS(rootPath: root.url.path))
        let opened = server.handle(request: request(
            unique: 130,
            opcode: .opendir,
            nodeID: HostFS.rootNodeID
        ))
        let handle = payload(from: opened).leUInt64(at: 0)
        let readPayload = bytes(handle) + bytes(UInt64(0)) + bytes(UInt32(4096))
            + bytes(UInt32(0)) + bytes(UInt64(0)) + bytes(UInt32(0)) + bytes(UInt32(0))
        let read = request(
            unique: 131,
            opcode: .readdirplus,
            nodeID: HostFS.rootNodeID,
            payload: readPayload
        )
        let loaded = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        server.directoryOperationLoadedTestHook = {
            loaded.signal()
            resume.wait()
        }

        let readTask = Task.detached { server.handle(request: read) }
        let waitResult = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: loaded.wait(timeout: .now() + 2))
            }
        }
        #expect(waitResult == .success)
        let release = server.handle(request: request(
            unique: 132,
            opcode: .releasedir,
            nodeID: HostFS.rootNodeID,
            payload: bytes(handle) + bytes(UInt32(0)) + bytes(UInt32(0)) + bytes(UInt64(0))
        ))
        #expect(try FuseProtocol.decodeOutHeader(release).error == 0)
        server.directoryOperationLoadedTestHook = nil
        resume.signal()

        let response = await readTask.value
        #expect(try FuseProtocol.decodeOutHeader(response).error == 0)
        #expect(String(decoding: payload(from: response), as: UTF8.self).contains("kept.txt"))
        let stale = server.handle(request: read)
        #expect(try FuseProtocol.decodeOutHeader(stale).error == -EBADF)
    }

    @Test func readdirplusOffsetRemainsStableWhenEarlierPageIsDeleted() throws {
        let root = try TestFuseServerRoot()
        for name in ["a.txt", "b.txt", "c.txt"] {
            try root.write(name, to: name)
        }
        let server = try FuseServer(hostFS: HostFS(rootPath: root.url.path))

        let opened = server.handle(request: request(
            unique: 2020,
            opcode: .opendir,
            nodeID: HostFS.rootNodeID
        ))
        let directoryHandle = payload(from: opened).leUInt64(at: 0)
        let oneRecordSize = UInt32(alignedDirentPlusLength(nameLength: 5))
        let firstRead = bytes(directoryHandle) + bytes(UInt64(0)) + bytes(oneRecordSize)
            + bytes(UInt32(0)) + bytes(UInt64(0)) + bytes(UInt32(0)) + bytes(UInt32(0))
        let first = payload(from: server.handle(request: request(
            unique: 2021,
            opcode: .readdirplus,
            nodeID: HostFS.rootNodeID,
            payload: firstRead
        )))
        #expect(String(decoding: first[(128 + 24)..<(128 + 29)], as: UTF8.self) == "a.txt")
        #expect(first.leUInt64(at: 128 + 8) == 1)

        let removed = server.handle(request: request(
            unique: 2022,
            opcode: .unlink,
            nodeID: HostFS.rootNodeID,
            payload: Array("a.txt\0".utf8)
        ))
        #expect(try FuseProtocol.decodeOutHeader(removed).error == 0)

        let secondRead = bytes(directoryHandle) + bytes(UInt64(1)) + bytes(oneRecordSize)
            + bytes(UInt32(0)) + bytes(UInt64(0)) + bytes(UInt32(0)) + bytes(UInt32(0))
        let second = payload(from: server.handle(request: request(
            unique: 2023,
            opcode: .readdirplus,
            nodeID: HostFS.rootNodeID,
            payload: secondRead
        )))
        #expect(String(decoding: second[(128 + 24)..<(128 + 29)], as: UTF8.self) == "b.txt")
        #expect(second.leUInt64(at: 128 + 8) == 2)
    }

    @Test func readdirplusOffsetZeroRefreshesARewoundDirectoryHandle() throws {
        let root = try TestFuseServerRoot()
        try root.write("a", to: "a.txt")
        let server = try FuseServer(hostFS: HostFS(rootPath: root.url.path))
        let opened = server.handle(request: request(
            unique: 2024,
            opcode: .opendir,
            nodeID: HostFS.rootNodeID
        ))
        let directoryHandle = payload(from: opened).leUInt64(at: 0)
        func readFromStart(unique: UInt64) -> [UInt8] {
            let read = bytes(directoryHandle) + bytes(UInt64(0)) + bytes(UInt32(4096))
                + bytes(UInt32(0)) + bytes(UInt64(0)) + bytes(UInt32(0)) + bytes(UInt32(0))
            return payload(from: server.handle(request: request(
                unique: unique,
                opcode: .readdirplus,
                nodeID: HostFS.rootNodeID,
                payload: read
            )))
        }

        let first = readFromStart(unique: 2025)
        #expect(String(decoding: first[(128 + 24)..<(128 + 29)], as: UTF8.self) == "a.txt")
        try root.write("b", to: "b.txt")
        let refreshed = readFromStart(unique: 2026)
        let firstLength = alignedDirentPlusLength(nameLength: 5)
        #expect(String(decoding: refreshed[(firstLength + 128 + 24)..<(firstLength + 128 + 29)], as: UTF8.self) == "b.txt")
    }

    @Test func repeatedOffsetZeroDuringDeletionKeepsOriginalCookieSpace() throws {
        let root = try TestFuseServerRoot()
        for name in ["a.txt", "b.txt", "c.txt"] { try root.write(name, to: name) }
        let server = try FuseServer(hostFS: HostFS(rootPath: root.url.path))
        let opened = server.handle(request: request(
            unique: 2027,
            opcode: .opendir,
            nodeID: HostFS.rootNodeID
        ))
        let directoryHandle = payload(from: opened).leUInt64(at: 0)
        func readFromStart(unique: UInt64) -> [UInt8] {
            let read = bytes(directoryHandle) + bytes(UInt64(0)) + bytes(UInt32(4096))
                + bytes(UInt32(0)) + bytes(UInt64(0)) + bytes(UInt32(0)) + bytes(UInt32(0))
            return payload(from: server.handle(request: request(
                unique: unique,
                opcode: .readdirplus,
                nodeID: HostFS.rootNodeID,
                payload: read
            )))
        }
        _ = readFromStart(unique: 2028)
        try FileManager.default.removeItem(at: root.url.appendingPathComponent("a.txt"))
        let repeated = readFromStart(unique: 2029)
        // The removed name keeps an empty cookie slot but must not be returned again: returning a
        // stale `a.txt` makes recursive deletion hit ENOENT and abandon the remaining page.
        #expect(String(decoding: repeated[(128 + 24)..<(128 + 29)], as: UTF8.self) == "b.txt")
        #expect(repeated.leUInt64(at: 128 + 8) == 2)
        let recordLength = alignedDirentPlusLength(nameLength: 5)
        #expect(String(decoding: repeated[(recordLength + 128 + 24)..<(recordLength + 128 + 29)], as: UTF8.self) == "c.txt")
        #expect(repeated.leUInt64(at: recordLength + 128 + 8) == 3)
    }

    @Test func createWriteFsyncRenameAndUnlinkMutateHostFilesystem() throws {
        let root = try TestFuseServerRoot()
        let server = try FuseServer(hostFS: HostFS(rootPath: root.url.path))
        let createIn = bytes(UInt32(0x40 | 0x2)) + bytes(UInt32(0o644))
            + bytes(UInt32(0)) + bytes(UInt32(0)) + Array("draft.txt\0".utf8)

        let create = server.handle(request: request(unique: 40, opcode: .create, nodeID: HostFS.rootNodeID, payload: createIn))
        let createPayload = payload(from: create)
        let nodeID = createPayload.leUInt64(at: 0)
        let handle = createPayload.leUInt64(at: 128)

        #expect(try FuseProtocol.decodeOutHeader(create).error == 0)
        #expect(nodeID != 0)
        #expect(handle != 0)
        #expect(createPayload.leUInt32(at: 136) == (1 << 5))

        let writeIn = bytes(handle) + bytes(UInt64(0)) + bytes(UInt32(11)) + bytes(UInt32(0)) + bytes(UInt64(0)) + bytes(UInt32(0)) + bytes(UInt32(0)) + Array("hello world".utf8)
        let write = server.handle(request: request(unique: 41, opcode: .write, nodeID: nodeID, payload: writeIn))

        #expect(try FuseProtocol.decodeOutHeader(write).error == 0)
        #expect(payload(from: write).leUInt32(at: 0) == 11)

        let fsync = server.handle(request: request(unique: 42, opcode: .fsync, nodeID: nodeID, payload: bytes(handle) + bytes(UInt32(0)) + bytes(UInt32(0))))
        #expect(try FuseProtocol.decodeOutHeader(fsync).error == 0)

        let flush = server.handle(request: request(unique: 43, opcode: .flush, nodeID: nodeID, payload: bytes(handle) + bytes(UInt32(0)) + bytes(UInt32(0)) + bytes(UInt64(0))))
        #expect(try FuseProtocol.decodeOutHeader(flush).error == 0)

        let release = server.handle(request: request(unique: 44, opcode: .release, nodeID: nodeID, payload: bytes(handle) + bytes(UInt32(0)) + bytes(UInt32(0)) + bytes(UInt64(0))))
        #expect(try FuseProtocol.decodeOutHeader(release).error == 0)
        #expect(try String(contentsOf: root.url.appendingPathComponent("draft.txt"), encoding: .utf8) == "hello world")

        let renameIn = bytes(UInt64(HostFS.rootNodeID)) + Array("draft.txt\0final.txt\0".utf8)
        let rename = server.handle(request: request(unique: 45, opcode: .rename, nodeID: HostFS.rootNodeID, payload: renameIn))

        #expect(try FuseProtocol.decodeOutHeader(rename).error == 0)
        #expect(FileManager.default.fileExists(atPath: root.url.appendingPathComponent("final.txt").path))

        let unlink = server.handle(request: request(unique: 46, opcode: .unlink, nodeID: HostFS.rootNodeID, payload: Array("final.txt\0".utf8)))

        #expect(try FuseProtocol.decodeOutHeader(unlink).error == 0)
        #expect(!FileManager.default.fileExists(atPath: root.url.appendingPathComponent("final.txt").path))
    }

    @Test func mutationRaceErrnosReachTheGuestWithoutBecomingEIO() throws {
        let root = try TestFuseServerRoot()
        try root.write("original", to: "existing.txt")
        try root.write("remove me", to: "victim.txt")
        try root.write("rename me", to: "before.txt")
        let server = try FuseServer(hostFS: HostFS(rootPath: root.url.path))

        let exclusiveCreateIn = bytes(UInt32(0x40 | 0x80 | 0x2))
            + bytes(UInt32(0o644))
            + bytes(UInt32(0))
            + bytes(UInt32(0))
            + Array("existing.txt\0".utf8)
        let exclusiveCreate = server.handle(request: request(
            unique: 47,
            opcode: .create,
            nodeID: HostFS.rootNodeID,
            payload: exclusiveCreateIn
        ))

        let firstUnlink = server.handle(request: request(
            unique: 48,
            opcode: .unlink,
            nodeID: HostFS.rootNodeID,
            payload: Array("victim.txt\0".utf8)
        ))
        let secondUnlink = server.handle(request: request(
            unique: 49,
            opcode: .unlink,
            nodeID: HostFS.rootNodeID,
            payload: Array("victim.txt\0".utf8)
        ))

        let renameIn = bytes(UInt64(HostFS.rootNodeID)) + Array("before.txt\0after.txt\0".utf8)
        let firstRename = server.handle(request: request(
            unique: 50,
            opcode: .rename,
            nodeID: HostFS.rootNodeID,
            payload: renameIn
        ))
        let losingRename = server.handle(request: request(
            unique: 51,
            opcode: .rename,
            nodeID: HostFS.rootNodeID,
            payload: bytes(UInt64(HostFS.rootNodeID)) + Array("before.txt\0loser.txt\0".utf8)
        ))

        #expect(try FuseProtocol.decodeOutHeader(exclusiveCreate).error == -EEXIST)
        #expect(try FuseProtocol.decodeOutHeader(firstUnlink).error == 0)
        #expect(try FuseProtocol.decodeOutHeader(secondUnlink).error == -ENOENT)
        #expect(try FuseProtocol.decodeOutHeader(firstRename).error == 0)
        #expect(try FuseProtocol.decodeOutHeader(losingRename).error == -ENOENT)
        #expect(try Data(contentsOf: root.url.appendingPathComponent("existing.txt")) == Data("original".utf8))
        #expect(FileManager.default.fileExists(atPath: root.url.appendingPathComponent("after.txt").path))
        #expect(!FileManager.default.fileExists(atPath: root.url.appendingPathComponent("loser.txt").path))
    }

    @Test func nonexclusiveCreateOpensAHostWinnerWhileExclusiveCreateReturnsEEXIST() throws {
        let root = try TestFuseServerRoot()
        try root.write("host winner", to: "winner.txt")
        let server = try FuseServer(hostFS: HostFS(rootPath: root.url.path))
        func create(flags: UInt32, unique: UInt64) -> [UInt8] {
            server.handle(request: request(
                unique: unique,
                opcode: .create,
                nodeID: HostFS.rootNodeID,
                payload: bytes(flags) + bytes(UInt32(0o644))
                    + bytes(UInt32(0)) + bytes(UInt32(0)) + Array("winner.txt\0".utf8)
            ))
        }

        let ordinary = create(flags: 0x40, unique: 52)
        #expect(try FuseProtocol.decodeOutHeader(ordinary).error == 0)
        #expect(payload(from: ordinary).leUInt64(at: 0) != 0)
        let exclusive = create(flags: 0x40 | 0x80, unique: 53)
        #expect(try FuseProtocol.decodeOutHeader(exclusive).error == -EEXIST)
    }

    @Test func symlinkAndReadlinkMutateHostFilesystem() throws {
        let root = try TestFuseServerRoot()
        try root.write("target", to: "target.txt")
        let server = try FuseServer(hostFS: HostFS(rootPath: root.url.path))

        let symlink = server.handle(request: request(unique: 46, opcode: .symlink, nodeID: HostFS.rootNodeID, payload: Array("link.txt\0target.txt\0".utf8)))
        let symlinkPayload = payload(from: symlink)
        let nodeID = symlinkPayload.leUInt64(at: 0)

        #expect(try FuseProtocol.decodeOutHeader(symlink).error == 0)
        #expect(symlinkPayload.leUInt32(at: 100) & UInt32(S_IFMT) == UInt32(S_IFLNK))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: root.url.appendingPathComponent("link.txt").path) == "target.txt")

        let readlink = server.handle(request: request(unique: 47, opcode: .readlink, nodeID: nodeID))

        #expect(try FuseProtocol.decodeOutHeader(readlink).error == 0)
        #expect(String(decoding: payload(from: readlink), as: UTF8.self) == "target.txt")
    }

    @Test func linkCreatesHardLinkWithSharedNodeIDAndRealNlink() throws {
        let root = try TestFuseServerRoot()
        try root.write("payload", to: "source.txt")
        let server = try FuseServer(hostFS: HostFS(rootPath: root.url.path))
        let lookup = server.handle(request: request(
            unique: 480,
            opcode: .lookup,
            nodeID: HostFS.rootNodeID,
            payload: Array("source.txt\0".utf8)
        ))
        let sourceNodeID = payload(from: lookup).leUInt64(at: 0)

        let link = server.handle(request: request(
            unique: 481,
            opcode: .link,
            nodeID: HostFS.rootNodeID,
            payload: bytes(sourceNodeID) + Array("linked.txt\0".utf8)
        ))
        let linkedPayload = payload(from: link)

        #expect(try FuseProtocol.decodeOutHeader(link).error == 0)
        #expect(linkedPayload.leUInt64(at: 0) == sourceNodeID)
        #expect(linkedPayload.leUInt64(at: 40) == sourceNodeID)
        #expect(linkedPayload.leUInt32(at: 104) == 2)
        let sourceStatus = try hostStat(root.url.appendingPathComponent("source.txt"))
        let linkedStatus = try hostStat(root.url.appendingPathComponent("linked.txt"))
        #expect(sourceStatus.st_ino == linkedStatus.st_ino)
        #expect(sourceStatus.st_nlink == 2)

        let linkedLookup = server.handle(request: request(
            unique: 482,
            opcode: .lookup,
            nodeID: HostFS.rootNodeID,
            payload: Array("linked.txt\0".utf8)
        ))
        #expect(payload(from: linkedLookup).leUInt64(at: 0) == sourceNodeID)
        #expect(payload(from: linkedLookup).leUInt32(at: 104) == 2)
    }

    @Test func setattrChangesModeAndKeepsSameModeNoopCompatible() throws {
        let root = try TestFuseServerRoot()
        try root.write("payload", to: "watched.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: root.url.appendingPathComponent("watched.txt").path)
        let server = try FuseServer(hostFS: HostFS(rootPath: root.url.path))
        let lookup = server.handle(request: request(unique: 52, opcode: .lookup, nodeID: HostFS.rootNodeID, payload: Array("watched.txt\0".utf8)))
        let nodeID = payload(from: lookup).leUInt64(at: 0)

        let sameMode = server.handle(request: request(unique: 53, opcode: .setattr, nodeID: nodeID, payload: setattrIn(mode: 0o640)))

        #expect(try FuseProtocol.decodeOutHeader(sameMode).error == 0)
        #expect(payload(from: sameMode).leUInt32(at: 76) & 0o7777 == 0o640)
        #expect(try FileManager.default.attributesOfItem(atPath: root.url.appendingPathComponent("watched.txt").path)[.posixPermissions] as? Int == 0o640)

        let differentMode = server.handle(request: request(unique: 54, opcode: .setattr, nodeID: nodeID, payload: setattrIn(mode: 0o600)))

        #expect(try FuseProtocol.decodeOutHeader(differentMode).error == 0)
        #expect(payload(from: differentMode).leUInt32(at: 76) & 0o7777 == 0o600)
        #expect(try FileManager.default.attributesOfItem(atPath: root.url.appendingPathComponent("watched.txt").path)[.posixPermissions] as? Int == 0o600)
    }

    @Test func setattrNeverFollowsASymlinkToMutateItsTarget() throws {
        let root = try TestFuseServerRoot()
        try root.write("target", to: "target.txt")
        let target = root.url.appendingPathComponent("target.txt")
        let link = root.url.appendingPathComponent("link.txt")
        #expect(chmod(target.path, mode_t(0o640)) == 0)
        #expect(symlink("target.txt", link.path) == 0)
        let before = try hostStat(target)
        let server = try FuseServer(hostFS: HostFS(rootPath: root.url.path))
        let lookup = server.handle(request: request(
            unique: 55,
            opcode: .lookup,
            nodeID: HostFS.rootNodeID,
            payload: Array("link.txt\0".utf8)
        ))
        let nodeID = payload(from: lookup).leUInt64(at: 0)

        let response = server.handle(request: request(
            unique: 56,
            opcode: .setattr,
            nodeID: nodeID,
            payload: FuseProtocol.encodeSetattrIn(FuseSetattrIn(
                valid: [.mode, .mtime],
                mtimeSeconds: 1_500_000_000,
                mode: 0o777
            ))
        ))
        let after = try hostStat(target)

        #expect(try FuseProtocol.decodeOutHeader(response).error == -FuseProtocol.linuxErrno(EOPNOTSUPP))
        #expect(after.st_mode & mode_t(0o7777) == before.st_mode & mode_t(0o7777))
        #expect(after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec)
        #expect(after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec)
    }

    @Test func setattrSizeTruncatesAndGrowsHostFile() throws {
        let root = try TestFuseServerRoot()
        try root.write("0123456789ABCDEF", to: "resize.txt")
        let server = try FuseServer(hostFS: HostFS(rootPath: root.url.path))
        let file = root.url.appendingPathComponent("resize.txt")
        let lookup = server.handle(request: request(unique: 60, opcode: .lookup, nodeID: HostFS.rootNodeID, payload: Array("resize.txt\0".utf8)))
        let nodeID = payload(from: lookup).leUInt64(at: 0)

        let shrink = server.handle(request: request(unique: 61, opcode: .setattr, nodeID: nodeID, payload: setattrSize(5)))
        #expect(try FuseProtocol.decodeOutHeader(shrink).error == 0)
        #expect(payload(from: shrink).leUInt64(at: 24) == 5)
        #expect(try Data(contentsOf: file) == Data("01234".utf8))

        let open = server.handle(request: request(unique: 62, opcode: .open, nodeID: nodeID, payload: bytes(UInt32(bitPattern: O_RDWR)) + bytes(UInt32(0))))
        let handle = payload(from: open).leUInt64(at: 0)
        let grow = server.handle(request: request(unique: 63, opcode: .setattr, nodeID: nodeID, payload: setattrSize(10, fileHandle: handle)))
        #expect(try FuseProtocol.decodeOutHeader(grow).error == 0)
        #expect(payload(from: grow).leUInt64(at: 24) == 10)
        let grown = try Data(contentsOf: file)
        #expect(grown.count == 10)
        #expect(grown.prefix(5) == Data("01234".utf8))
        #expect(Array(grown.suffix(5)) == [0, 0, 0, 0, 0])
    }

    @Test func setattrSizeOnReadOnlyShareFails() throws {
        let root = try TestFuseServerRoot()
        try root.write("keepme", to: "ro.txt")
        let server = try FuseServer(hostFS: HostFS(rootPath: root.url.path, readOnly: true))
        let lookup = server.handle(request: request(unique: 70, opcode: .lookup, nodeID: HostFS.rootNodeID, payload: Array("ro.txt\0".utf8)))
        let nodeID = payload(from: lookup).leUInt64(at: 0)

        let truncate = server.handle(request: request(unique: 71, opcode: .setattr, nodeID: nodeID, payload: setattrSize(0)))

        #expect(try FuseProtocol.decodeOutHeader(truncate).error == -EROFS)
        #expect(try Data(contentsOf: root.url.appendingPathComponent("ro.txt")) == Data("keepme".utf8))
    }

    @Test func setattrAppliesCombinedSizeAndNanosecondTimestampsAndReturnsActualCtime() throws {
        let root = try TestFuseServerRoot()
        try root.write("0123456789", to: "metadata.txt")
        let file = root.url.appendingPathComponent("metadata.txt")
        let server = try FuseServer(hostFS: HostFS(rootPath: root.url.path))
        let lookup = server.handle(request: request(
            unique: 72,
            opcode: .lookup,
            nodeID: HostFS.rootNodeID,
            payload: Array("metadata.txt\0".utf8)
        ))
        let nodeID = payload(from: lookup).leUInt64(at: 0)
        let wire = FuseSetattrIn(
            valid: [.size, .atime, .mtime, .ctime, .lockOwner],
            size: 4,
            lockOwner: 0xfeed_beef,
            atimeSeconds: 1_600_000_001,
            mtimeSeconds: 1_700_000_002,
            ctimeSeconds: 42,
            atimeNsec: 123_456_789,
            mtimeNsec: 987_654_321,
            ctimeNsec: 111_222_333
        )

        let response = server.handle(request: request(
            unique: 73,
            opcode: .setattr,
            nodeID: nodeID,
            payload: FuseProtocol.encodeSetattrIn(wire)
        ))
        let result = payload(from: response)
        let status = try hostStat(file)

        #expect(try FuseProtocol.decodeOutHeader(response).error == 0)
        #expect(status.st_size == 4)
        #expect(status.st_atimespec.tv_sec == 1_600_000_001)
        #expect(status.st_atimespec.tv_nsec == 123_456_789)
        #expect(status.st_mtimespec.tv_sec == 1_700_000_002)
        #expect(status.st_mtimespec.tv_nsec == 987_654_321)
        #expect(result.leUInt64(at: 24) == 4)
        #expect(Int64(bitPattern: result.leUInt64(at: 40)) == 1_600_000_001)
        #expect(Int64(bitPattern: result.leUInt64(at: 48)) == 1_700_000_002)
        #expect(Int64(bitPattern: result.leUInt64(at: 56)) == Int64(status.st_ctimespec.tv_sec))
        #expect(result.leUInt32(at: 72) == UInt32(status.st_ctimespec.tv_nsec))
    }

    @Test func setattrNowUsesUtimeNowAndOmitPreservesTheOtherTimestamp() throws {
        let root = try TestFuseServerRoot()
        try root.write("payload", to: "touch.txt")
        let file = root.url.appendingPathComponent("touch.txt")
        let server = try FuseServer(hostFS: HostFS(rootPath: root.url.path))
        let lookup = server.handle(request: request(
            unique: 74,
            opcode: .lookup,
            nodeID: HostFS.rootNodeID,
            payload: Array("touch.txt\0".utf8)
        ))
        let nodeID = payload(from: lookup).leUInt64(at: 0)
        let initial = FuseSetattrIn(
            valid: [.atime, .mtime],
            atimeSeconds: 1_500_000_003,
            mtimeSeconds: 1_500_000_004,
            atimeNsec: 222_333_444,
            mtimeNsec: 333_444_555
        )
        _ = server.handle(request: request(
            unique: 75,
            opcode: .setattr,
            nodeID: nodeID,
            payload: FuseProtocol.encodeSetattrIn(initial)
        ))
        let before = try hostStat(file)
        let beforeNow = Int64(Date().timeIntervalSince1970) - 1

        let response = server.handle(request: request(
            unique: 76,
            opcode: .setattr,
            nodeID: nodeID,
            payload: FuseProtocol.encodeSetattrIn(FuseSetattrIn(
                valid: [.mtime, .mtimeNow],
                mtimeNsec: UInt32.max
            ))
        ))
        let afterNow = Int64(Date().timeIntervalSince1970) + 1
        let after = try hostStat(file)

        #expect(try FuseProtocol.decodeOutHeader(response).error == 0)
        #expect(after.st_atimespec.tv_sec == before.st_atimespec.tv_sec)
        #expect(after.st_atimespec.tv_nsec == before.st_atimespec.tv_nsec)
        #expect(Int64(after.st_mtimespec.tv_sec) >= beforeNow)
        #expect(Int64(after.st_mtimespec.tv_sec) <= afterNow)
    }

    @Test func setattrRejectsInvalidMetadataBeforeAnyMutation() throws {
        let root = try TestFuseServerRoot()
        try root.write("unchanged", to: "guarded.txt")
        let file = root.url.appendingPathComponent("guarded.txt")
        let server = try FuseServer(hostFS: HostFS(rootPath: root.url.path))
        let lookup = server.handle(request: request(
            unique: 77,
            opcode: .lookup,
            nodeID: HostFS.rootNodeID,
            payload: Array("guarded.txt\0".utf8)
        ))
        let nodeID = payload(from: lookup).leUInt64(at: 0)

        let invalidNanoseconds = server.handle(request: request(
            unique: 78,
            opcode: .setattr,
            nodeID: nodeID,
            payload: FuseProtocol.encodeSetattrIn(FuseSetattrIn(
                valid: [.size, .mtime],
                size: 1,
                mtimeSeconds: 1_600_000_000,
                mtimeNsec: 1_000_000_000
            ))
        ))
        let unknownFlag = server.handle(request: request(
            unique: 80,
            opcode: .setattr,
            nodeID: nodeID,
            payload: FuseProtocol.encodeSetattrIn(FuseSetattrIn(
                valid: FuseSetattrValid(rawValue: 1 << 31)
            ))
        ))
        let shortFrame = server.handle(request: request(
            unique: 81,
            opcode: .setattr,
            nodeID: nodeID,
            payload: [UInt8](repeating: 0, count: FuseSetattrIn.byteCount - 1)
        ))

        #expect(try FuseProtocol.decodeOutHeader(invalidNanoseconds).error == -EINVAL)
        #expect(try FuseProtocol.decodeOutHeader(unknownFlag).error == -EINVAL)
        #expect(try FuseProtocol.decodeOutHeader(shortFrame).error == -EINVAL)
        #expect(try Data(contentsOf: file) == Data("unchanged".utf8))
    }

    @Test func setattrAcceptsContainerOwnershipWithoutChangingHostOwner() throws {
        let root = try TestFuseServerRoot()
        try root.write("owned", to: "owner.txt")
        let file = root.url.appendingPathComponent("owner.txt")
        let before = try hostStat(file)
        let server = try FuseServer(hostFS: HostFS(rootPath: root.url.path, guestUID: 1_000, guestGID: 1_000))
        let lookup = server.handle(request: request(
            unique: 82,
            opcode: .lookup,
            nodeID: HostFS.rootNodeID,
            payload: Array("owner.txt\0".utf8)
        ))
        let nodeID = payload(from: lookup).leUInt64(at: 0)

        let response = server.handle(request: request(
            unique: 83,
            opcode: .setattr,
            nodeID: nodeID,
            payload: FuseProtocol.encodeSetattrIn(FuseSetattrIn(
                valid: [.uid, .gid],
                uid: 1_234,
                gid: 5_678
            ))
        ))
        let after = try hostStat(file)

        #expect(try FuseProtocol.decodeOutHeader(response).error == 0)
        #expect(payload(from: response).leUInt32(at: 84) == 1_234)
        #expect(payload(from: response).leUInt32(at: 88) == 5_678)
        #expect(after.st_uid == before.st_uid)
        #expect(after.st_gid == before.st_gid)

        let refreshed = server.handle(request: request(
            unique: 84,
            opcode: .getattr,
            nodeID: nodeID,
            payload: FuseProtocol.encodeGetattrIn(FuseGetattrIn())
        ))
        #expect(try FuseProtocol.decodeOutHeader(refreshed).error == 0)
        #expect(payload(from: refreshed).leUInt32(at: 84) == 1_234)
        #expect(payload(from: refreshed).leUInt32(at: 88) == 5_678)
    }

    @Test func setattrValidatesFileHandleNodeAndSupportsUnlinkedOpenFiles() throws {
        let root = try TestFuseServerRoot()
        try root.write("alpha", to: "alpha.txt")
        try root.write("bravo", to: "bravo.txt")
        let server = try FuseServer(hostFS: HostFS(rootPath: root.url.path))
        let alphaLookup = server.handle(request: request(
            unique: 84,
            opcode: .lookup,
            nodeID: HostFS.rootNodeID,
            payload: Array("alpha.txt\0".utf8)
        ))
        let bravoLookup = server.handle(request: request(
            unique: 85,
            opcode: .lookup,
            nodeID: HostFS.rootNodeID,
            payload: Array("bravo.txt\0".utf8)
        ))
        let alphaNode = payload(from: alphaLookup).leUInt64(at: 0)
        let bravoNode = payload(from: bravoLookup).leUInt64(at: 0)
        let opened = server.handle(request: request(
            unique: 86,
            opcode: .open,
            nodeID: alphaNode,
            payload: bytes(UInt32(bitPattern: O_RDWR)) + bytes(UInt32(0))
        ))
        let handle = payload(from: opened).leUInt64(at: 0)
        let handleRequest = FuseProtocol.encodeSetattrIn(FuseSetattrIn(
            valid: [.fileHandle, .size],
            fileHandle: handle,
            size: 3
        ))

        let mismatch = server.handle(request: request(
            unique: 87,
            opcode: .setattr,
            nodeID: bravoNode,
            payload: handleRequest
        ))
        let missing = server.handle(request: request(
            unique: 88,
            opcode: .setattr,
            nodeID: alphaNode,
            payload: FuseProtocol.encodeSetattrIn(FuseSetattrIn(
                valid: [.fileHandle, .size],
                fileHandle: UInt64.max,
                size: 3
            ))
        ))

        #expect(try FuseProtocol.decodeOutHeader(mismatch).error == -EBADF)
        #expect(try FuseProtocol.decodeOutHeader(missing).error == -EBADF)
        #expect(try Data(contentsOf: root.url.appendingPathComponent("alpha.txt")) == Data("alpha".utf8))
        #expect(try Data(contentsOf: root.url.appendingPathComponent("bravo.txt")) == Data("bravo".utf8))

        let unlink = server.handle(request: request(
            unique: 89,
            opcode: .unlink,
            nodeID: HostFS.rootNodeID,
            payload: Array("alpha.txt\0".utf8)
        ))
        let detached = server.handle(request: request(
            unique: 90,
            opcode: .setattr,
            nodeID: alphaNode,
            payload: handleRequest
        ))

        #expect(try FuseProtocol.decodeOutHeader(unlink).error == 0)
        #expect(try FuseProtocol.decodeOutHeader(detached).error == 0)
        #expect(payload(from: detached).leUInt64(at: 24) == 3)
        #expect(!FileManager.default.fileExists(atPath: root.url.appendingPathComponent("alpha.txt").path))
    }

    @Test func setattrKillprivIsFlagDrivenAndKeepsNonExecutableSgid() throws {
        let root = try TestFuseServerRoot()
        try root.write("privileged", to: "privileged.txt")
        let file = root.url.appendingPathComponent("privileged.txt")
        #expect(chmod(file.path, mode_t(0o6750)) == 0)
        let server = try FuseServer(hostFS: HostFS(rootPath: root.url.path), killPrivV2: true)
        let lookup = server.handle(request: request(
            unique: 91,
            opcode: .lookup,
            nodeID: HostFS.rootNodeID,
            payload: Array("privileged.txt\0".utf8)
        ))
        let nodeID = payload(from: lookup).leUInt64(at: 0)

        let noKill = server.handle(request: request(
            unique: 92,
            opcode: .setattr,
            nodeID: nodeID,
            payload: setattrSize(4)
        ))
        #expect(try FuseProtocol.decodeOutHeader(noKill).error == 0)
        #expect(try hostStat(file).st_mode & mode_t(S_ISUID | S_ISGID) == mode_t(S_ISUID | S_ISGID))

        let kill = server.handle(request: request(
            unique: 93,
            opcode: .setattr,
            nodeID: nodeID,
            payload: FuseProtocol.encodeSetattrIn(FuseSetattrIn(valid: .killSuidGid))
        ))
        #expect(try FuseProtocol.decodeOutHeader(kill).error == 0)
        #expect(try hostStat(file).st_mode & mode_t(S_ISUID | S_ISGID) == 0)

        #expect(chmod(file.path, mode_t(0o2640)) == 0)
        let preserveSgid = server.handle(request: request(
            unique: 94,
            opcode: .setattr,
            nodeID: nodeID,
            payload: FuseProtocol.encodeSetattrIn(FuseSetattrIn(valid: .killSuidGid))
        ))
        #expect(try FuseProtocol.decodeOutHeader(preserveSgid).error == 0)
        #expect(try hostStat(file).st_mode & mode_t(S_ISGID) == mode_t(S_ISGID))
    }

    @Test func mkdirAndRmdirMutateHostFilesystem() throws {
        let root = try TestFuseServerRoot()
        let server = try FuseServer(hostFS: HostFS(rootPath: root.url.path))
        let mkdirIn = bytes(UInt32(0o755)) + bytes(UInt32(0)) + Array("nested\0".utf8)

        let mkdir = server.handle(request: request(unique: 50, opcode: .mkdir, nodeID: HostFS.rootNodeID, payload: mkdirIn))

        #expect(try FuseProtocol.decodeOutHeader(mkdir).error == 0)
        #expect(payload(from: mkdir).leUInt32(at: 108) == 1_000)
        #expect(payload(from: mkdir).leUInt32(at: 112) == 1_000)
        #expect(FileManager.default.fileExists(atPath: root.url.appendingPathComponent("nested").path))

        let rmdir = server.handle(request: request(unique: 51, opcode: .rmdir, nodeID: HostFS.rootNodeID, payload: Array("nested\0".utf8)))

        #expect(try FuseProtocol.decodeOutHeader(rmdir).error == 0)
        #expect(!FileManager.default.fileExists(atPath: root.url.appendingPathComponent("nested").path))
    }

    @Test func statfsAndErrorResponsesUseFuseOutHeaders() throws {
        let root = try TestFuseServerRoot()
        let server = try FuseServer(hostFS: HostFS(rootPath: root.url.path))

        let statfs = server.handle(request: request(unique: 30, opcode: .statfs, nodeID: HostFS.rootNodeID))
        let missing = server.handle(request: request(unique: 31, opcode: .lookup, nodeID: HostFS.rootNodeID, payload: Array("missing\0".utf8)))
        let unsupported = server.handle(request: request(unique: 32, opcodeRaw: 9_999, nodeID: HostFS.rootNodeID))

        #expect(try FuseProtocol.decodeOutHeader(statfs).length == UInt32(FuseOutHeader.byteCount + 80))
        #expect(payload(from: statfs).leUInt64(at: 0) > 0)
        // Negative dentries are never cached, so a miss is a plain ENOENT.
        #expect(try FuseProtocol.decodeOutHeader(missing).error == -ENOENT)
        #expect(try FuseProtocol.decodeOutHeader(unsupported).error == -FuseProtocol.linuxErrno(ENOSYS))
    }

    @Test func initKeepsWritebackOptInButEnablesKillprivV2ByDefault() throws {
        let root = try TestFuseServerRoot()
        let initIn = bytes(UInt32(7)) + bytes(UInt32(38)) + bytes(UInt32(131_072)) + bytes(UInt32(FuseInitFlag.asyncRead.rawValue))
        let defaultServer = try FuseServer(hostFS: HostFS(rootPath: root.url.path))
        let optInServer = try FuseServer(hostFS: HostFS(rootPath: root.url.path), writebackCache: true, killPrivV2: false)

        let defaultResponse = defaultServer.handle(request: request(unique: 33, opcode: .initOp, nodeID: HostFS.rootNodeID, payload: initIn))
        let optInResponse = optInServer.handle(request: request(unique: 34, opcode: .initOp, nodeID: HostFS.rootNodeID, payload: initIn))
        let defaultFlags = payload(from: defaultResponse).leUInt32(at: 12)
        let optInFlags = payload(from: optInResponse).leUInt32(at: 12)

        #expect(defaultFlags & FuseInitFlag.writebackCache.rawValue == 0)
        #expect(defaultFlags & FuseInitFlag.handleKillprivV2.rawValue == FuseInitFlag.handleKillprivV2.rawValue)
        #expect(optInFlags & FuseInitFlag.writebackCache.rawValue == FuseInitFlag.writebackCache.rawValue)
        #expect(optInFlags & FuseInitFlag.handleKillprivV2.rawValue == 0)
    }

    @Test func cachePolicyDefaultsSafeAndActivatedValuesAreBounded() throws {
        let root = try TestFuseServerRoot()
        try root.write("host editable", to: "watched.txt")
        let defaultServer = try FuseServer(hostFS: HostFS(rootPath: root.url.path))
        let activatedServer = try FuseServer(hostFS: HostFS(rootPath: root.url.path))
        let initIn = bytes(UInt32(7)) + bytes(UInt32(38)) + bytes(UInt32(131_072)) + bytes(UInt32(0))
        _ = activatedServer.handle(request: request(
            unique: 34,
            opcode: .initOp,
            nodeID: HostFS.rootNodeID,
            payload: initIn
        ))
        // FuseServer's activation hook is internal; production activation is gated by VirtioFS.
        activatedServer.markFuseInitCompleted()
        #expect(activatedServer.activateCoherentCaching())

        func fileFlags(_ server: FuseServer, unique: UInt64) throws -> UInt32 {
            let lookup = server.handle(request: request(
                unique: unique,
                opcode: .lookup,
                nodeID: HostFS.rootNodeID,
                payload: Array("watched.txt\0".utf8)
            ))
            let nodeID = payload(from: lookup).leUInt64(at: 0)
            let opened = server.handle(request: request(
                unique: unique + 1,
                opcode: .open,
                nodeID: nodeID,
                payload: bytes(UInt32(O_RDONLY)) + bytes(UInt32(0))
            ))
            return payload(from: opened).leUInt32(at: 8)
        }

        let defaultDir = defaultServer.handle(request: request(unique: 37, opcode: .opendir, nodeID: HostFS.rootNodeID))
        let activatedDir = activatedServer.handle(request: request(unique: 38, opcode: .opendir, nodeID: HostFS.rootNodeID))
        let defaultLookup = defaultServer.handle(request: request(
            unique: 43,
            opcode: .lookup,
            nodeID: HostFS.rootNodeID,
            payload: Array("watched.txt\0".utf8)
        ))

        #expect(try fileFlags(defaultServer, unique: 35) == (1 << 5))
        // Metadata TTL activation never emits irrevocable KEEP_CACHE/CACHE_DIR open flags.
        #expect(try fileFlags(activatedServer, unique: 39) == (1 << 5))
        #expect(payload(from: defaultDir).leUInt32(at: 8) == 0)
        #expect(payload(from: activatedDir).leUInt32(at: 8) == 0)
        #expect(payload(from: defaultLookup).leUInt64(at: 16) == 0)  // entry_valid
        #expect(payload(from: defaultLookup).leUInt64(at: 24) == 0)  // attr_valid

        let activatedLookup = activatedServer.handle(request: request(
            unique: 45,
            opcode: .lookup,
            nodeID: HostFS.rootNodeID,
            payload: Array("watched.txt\0".utf8)
        ))
        #expect(payload(from: activatedLookup).leUInt64(at: 16) == VirtioFS.maximumCoherentCacheValiditySeconds)
        #expect(payload(from: activatedLookup).leUInt64(at: 24) == VirtioFS.maximumCoherentCacheValiditySeconds)
    }

    @Test func linuxErrnoTranslatesEveryDivergentDarwinCode() {
        let divergent: [(darwin: Int32, linux: Int32)] = [
            (EDEADLK, 35),
            (EAGAIN, 11),
            (EINPROGRESS, 115),
            (EALREADY, 114),
            (ENOTSOCK, 88),
            (EDESTADDRREQ, 89),
            (EMSGSIZE, 90),
            (EPROTOTYPE, 91),
            (ENOPROTOOPT, 92),
            (EPROTONOSUPPORT, 93),
            (ESOCKTNOSUPPORT, 94),
            (ENOTSUP, 95),
            (EPFNOSUPPORT, 96),
            (EAFNOSUPPORT, 97),
            (EADDRINUSE, 98),
            (EADDRNOTAVAIL, 99),
            (ENETDOWN, 100),
            (ENETUNREACH, 101),
            (ENETRESET, 102),
            (ECONNABORTED, 103),
            (ECONNRESET, 104),
            (ENOBUFS, 105),
            (EISCONN, 106),
            (ENOTCONN, 107),
            (ESHUTDOWN, 108),
            (ETOOMANYREFS, 109),
            (ETIMEDOUT, 110),
            (ECONNREFUSED, 111),
            (ELOOP, 40),
            (ENAMETOOLONG, 36),
            (EHOSTDOWN, 112),
            (EHOSTUNREACH, 113),
            (ENOTEMPTY, 39),
            (EPROCLIM, 11),
            (EUSERS, 87),
            (EDQUOT, 122),
            (ESTALE, 116),
            (EREMOTE, 66),
            (EBADRPC, FuseProtocol.eproto),
            (ERPCMISMATCH, FuseProtocol.eproto),
            (EPROGUNAVAIL, FuseProtocol.eproto),
            (EPROGMISMATCH, FuseProtocol.eproto),
            (EPROCUNAVAIL, FuseProtocol.eproto),
            (ENOLCK, 37),
            (ENOSYS, 38),
            (EFTYPE, 22),
            (EAUTH, 13),
            (ENEEDAUTH, 13),
            (EPWROFF, 5),
            (EDEVERR, 5),
            (EOVERFLOW, 75),
            (EBADEXEC, 8),
            (EBADARCH, 8),
            (ESHLIBVERS, 8),
            (EBADMACHO, 8),
            (ECANCELED, 125),
            (EIDRM, 43),
            (ENOMSG, 42),
            (EILSEQ, 84),
            (ENOATTR, 61),
            (EBADMSG, 74),
            (EMULTIHOP, 72),
            (ENODATA, 61),
            (ENOLINK, 67),
            (ENOSR, 63),
            (ENOSTR, 60),
            (EPROTO, FuseProtocol.eproto),
            (ETIME, 62),
            (EOPNOTSUPP, 95),
            (ENOPOLICY, 95),
            (ENOTRECOVERABLE, 131),
            (EOWNERDEAD, 130),
            (EQFULL, 105),
            (ENOTCAPABLE, 13),
        ]

        for mapping in divergent {
            #expect(FuseProtocol.linuxErrno(mapping.darwin) == mapping.linux)
        }
        for shared in (1 as Int32)...10 {
            #expect(FuseProtocol.linuxErrno(shared) == shared)
        }
        for shared in (12 as Int32)...34 {
            #expect(FuseProtocol.linuxErrno(shared) == shared)
        }
        #expect(FuseProtocol.linuxErrno(0) == 0)
        #expect(FuseProtocol.linuxErrno(-1) == 5)
        #expect(FuseProtocol.linuxErrno(108) == 5)
        #expect(FuseProtocol.linuxErrno(9_999) == 5)
    }

    @Test func lookupMissGrantsBoundedNegativeDentryWhileCoherent() throws {
        let root = try TestFuseServerRoot()
        let server = try FuseServer(hostFS: HostFS(rootPath: root.url.path))
        let initIn = bytes(UInt32(7)) + bytes(UInt32(38)) + bytes(UInt32(131_072)) + bytes(UInt32(0))
        _ = server.handle(request: request(unique: 79, opcode: .initOp, nodeID: HostFS.rootNodeID, payload: initIn))
        server.markFuseInitCompleted()
        #expect(server.activateCoherentCaching())

        let miss = server.handle(request: request(unique: 80, opcode: .lookup, nodeID: HostFS.rootNodeID, payload: Array("nope.txt\0".utf8)))
        let header = try FuseProtocol.decodeOutHeader(miss)
        #expect(header.error == 0)
        #expect(header.length == UInt32(FuseOutHeader.byteCount + 128))
        let entry = Array(miss.dropFirst(FuseOutHeader.byteCount))
        #expect(entry.leUInt64(at: 0) == 0)
        #expect(entry.leUInt64(at: 16) == FuseServer.negativeCoherentCacheValiditySeconds)
        #expect(entry.leUInt64(at: 24) == 0)

        // Deactivation must immediately fall back to plain ENOENT misses.
        server.deactivateCoherentCaching()
        let incoherentMiss = server.handle(request: request(unique: 81, opcode: .lookup, nodeID: HostFS.rootNodeID, payload: Array("nope.txt\0".utf8)))
        let incoherentHeader = try FuseProtocol.decodeOutHeader(incoherentMiss)
        #expect(incoherentHeader.error == -ENOENT)
        #expect(incoherentHeader.length == UInt32(FuseOutHeader.byteCount))
    }

    @Test func directLookupMissAlsoNeverReturnsNegativeDentry() throws {
        let root = try TestFuseServerRoot()
        let server = try FuseServer(hostFS: HostFS(rootPath: root.url.path))

        let missRequest = request(unique: 81, opcode: .lookup, nodeID: HostFS.rootNodeID, payload: Array("nope.txt\0".utf8))
        let header = try FuseProtocol.decodeInHeader(missRequest)
        let payload = missRequest[FuseInHeader.byteCount..<Int(header.length)]
        var output = [UInt8](repeating: 0, count: FuseOutHeader.byteCount + 128)
        let count = output.withUnsafeMutableBytes { buffer in
            server.writeLookupResponse(
                header: header,
                payload: payload,
                writable: [VirtqueueSegment(pointer: buffer.baseAddress!, length: buffer.count, isDeviceWritable: true)]
            )
        }

        #expect(count == FuseOutHeader.byteCount)
        #expect(try FuseProtocol.decodeOutHeader(output).error == -ENOENT)
    }

    @Test func deactivationImmediatelyRestoresZeroTimeouts() throws {
        let root = try TestFuseServerRoot()
        try root.write("cached", to: "cached.txt")
        let server = try FuseServer(hostFS: HostFS(rootPath: root.url.path))
        let initIn = bytes(UInt32(7)) + bytes(UInt32(38)) + bytes(UInt32(131_072)) + bytes(UInt32(0))
        _ = server.handle(request: request(unique: 82, opcode: .initOp, nodeID: HostFS.rootNodeID, payload: initIn))
        server.markFuseInitCompleted()
        #expect(server.activateCoherentCaching())
        server.deactivateCoherentCaching()

        let lookup = server.handle(request: request(unique: 83, opcode: .lookup, nodeID: HostFS.rootNodeID, payload: Array("cached.txt\0".utf8)))
        let entry = payload(from: lookup)
        let nodeID = entry.leUInt64(at: 0)
        let getattr = server.handle(request: request(
            unique: 84,
            opcode: .getattr,
            nodeID: nodeID,
            payload: FuseProtocol.encodeGetattrIn(FuseGetattrIn())
        ))

        #expect(entry.leUInt64(at: 16) == 0)
        #expect(entry.leUInt64(at: 24) == 0)
        #expect(payload(from: getattr).leUInt64(at: 0) == 0)
    }

    @Test func cachePolicyTransitionsAndResponseSnapshotsAreThreadSafe() async throws {
        let root = try TestFuseServerRoot()
        let server = try FuseServer(hostFS: HostFS(rootPath: root.url.path))
        server.markFuseInitCompleted()
        let getattr = request(
            unique: 85,
            opcode: .getattr,
            nodeID: HostFS.rootNodeID,
            payload: FuseProtocol.encodeGetattrIn(FuseGetattrIn())
        )

        var allSnapshotsValid = true
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for _ in 0..<2_000 {
                    guard server.activateCoherentCaching() else { return false }
                    server.deactivateCoherentCaching()
                }
                return true
            }
            for _ in 0..<8 {
                group.addTask {
                    for _ in 0..<1_000 {
                        let response = server.handle(request: getattr)
                        guard response.count == FuseOutHeader.byteCount + 104 else { return false }
                        let validity = response.leUInt64(at: FuseOutHeader.byteCount)
                        guard validity == 0
                                || validity == VirtioFS.maximumCoherentCacheValiditySeconds else {
                            return false
                        }
                        _ = server.coherentCachingActive
                    }
                    return true
                }
            }
            for await valid in group where !valid {
                allSnapshotsValid = false
            }
        }

        server.deactivateCoherentCaching()
        #expect(allSnapshotsValid)
        #expect(payload(from: server.handle(request: getattr)).leUInt64(at: 0) == 0)
    }

    @Test func writeWithKillSuidgidClearsPrivilegeBits() throws {
        let root = try TestFuseServerRoot()
        try root.write("payload", to: "suid.bin")
        let path = root.url.appendingPathComponent("suid.bin").path
        try FileManager.default.setAttributes([.posixPermissions: 0o4755], ofItemAtPath: path)
        let server = try FuseServer(hostFS: HostFS(rootPath: root.url.path))
        let nodeID = payload(from: server.handle(request: request(unique: 90, opcode: .lookup, nodeID: HostFS.rootNodeID, payload: Array("suid.bin\0".utf8)))).leUInt64(at: 0)
        let handle = payload(from: server.handle(request: request(unique: 91, opcode: .open, nodeID: nodeID, payload: bytes(UInt32(bitPattern: O_RDWR)) + bytes(UInt32(0))))).leUInt64(at: 0)

        let data = Array("x".utf8)
        let killFlag = UInt32(1 << 2) // FUSE_WRITE_KILL_SUIDGID
        let writeIn = bytes(handle) + bytes(UInt64(0)) + bytes(UInt32(data.count)) + bytes(killFlag) + bytes(UInt64(0)) + bytes(UInt32(0)) + bytes(UInt32(0)) + data
        let write = server.handle(request: request(unique: 92, opcode: .write, nodeID: nodeID, payload: writeIn))

        #expect(try FuseProtocol.decodeOutHeader(write).error == 0)
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int ?? 0
        #expect(mode & 0o4000 == 0)  // S_ISUID cleared
    }

    @Test func truncateClearsPrivilegeBitsWhenKernelSetsKillprivV2Flag() throws {
        let root = try TestFuseServerRoot()
        try root.write("privileged", to: "suidtrunc.bin")
        let path = root.url.appendingPathComponent("suidtrunc.bin").path
        try FileManager.default.setAttributes([.posixPermissions: 0o6755], ofItemAtPath: path)  // suid+sgid
        let server = try FuseServer(hostFS: HostFS(rootPath: root.url.path))
        let nodeID = payload(from: server.handle(request: request(unique: 97, opcode: .lookup, nodeID: HostFS.rootNodeID, payload: Array("suidtrunc.bin\0".utf8)))).leUInt64(at: 0)

        // An O_TRUNC open arrives as SETATTR size=0 (FUSE_ATOMIC_O_TRUNC is not advertised). Under
        // KILLPRIV_V2 the kernel explicitly sets FATTR_KILL_SUIDGID when the caller lacks CAP_FSETID.
        let trunc = server.handle(request: request(
            unique: 98,
            opcode: .setattr,
            nodeID: nodeID,
            payload: FuseProtocol.encodeSetattrIn(FuseSetattrIn(
                valid: [.size, .killSuidGid],
                size: 0
            ))
        ))

        #expect(try FuseProtocol.decodeOutHeader(trunc).error == 0)
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int ?? 0
        #expect(mode & 0o6000 == 0)  // S_ISUID and S_ISGID cleared
    }

    @Test func truncateKeepsPrivilegeBitsWhenKillprivV2Disabled() throws {
        let root = try TestFuseServerRoot()
        try root.write("privileged", to: "keepsuid.bin")
        let path = root.url.appendingPathComponent("keepsuid.bin").path
        try FileManager.default.setAttributes([.posixPermissions: 0o6755], ofItemAtPath: path)
        let server = try FuseServer(hostFS: HostFS(rootPath: root.url.path), killPrivV2: false)
        let nodeID = payload(from: server.handle(request: request(unique: 99, opcode: .lookup, nodeID: HostFS.rootNodeID, payload: Array("keepsuid.bin\0".utf8)))).leUInt64(at: 0)

        _ = server.handle(request: request(unique: 100, opcode: .setattr, nodeID: nodeID, payload: setattrSize(0)))

        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int ?? 0
        #expect(mode & 0o6000 == 0o6000)  // bits preserved: no V2 contract, kernel owns the kill
    }

    @Test func daxSetupAndRemoveMappingRequireConfiguredWindowAndOpenHandle() throws {
        let root = try TestFuseServerRoot()
        try root.write("hello dory", to: "hello.txt")
        let hostFS = try HostFS(rootPath: root.url.path)
        let server = try FuseServer(
            hostFS: hostFS,
            daxWindow: DaxWindow(guestBase: 0x1_0000_0000, length: 0x20_000)
        )

        let lookup = server.handle(request: request(unique: 60, opcode: .lookup, nodeID: HostFS.rootNodeID, payload: Array("hello.txt\0".utf8)))
        let nodeID = payload(from: lookup).leUInt64(at: 0)

        let missingHandleSetup = server.handle(request: request(
            unique: 61,
            opcode: .setupmapping,
            nodeID: nodeID,
            payload: FuseProtocol.encodeSetupMappingIn(FuseSetupMappingIn(fileHandle: 999, fileOffset: 0, length: 0x4000, flags: 0, memoryOffset: 0))
        ))
        #expect(try FuseProtocol.decodeOutHeader(missingHandleSetup).error == -EBADF)

        let open = server.handle(request: request(unique: 62, opcode: .open, nodeID: nodeID, payload: bytes(UInt32(O_RDONLY)) + bytes(UInt32(0))))
        let handle = payload(from: open).leUInt64(at: 0)

        let unauthorizedWriteMapping = server.handle(request: request(
            unique: 620,
            opcode: .setupmapping,
            nodeID: nodeID,
            payload: FuseProtocol.encodeSetupMappingIn(FuseSetupMappingIn(
                fileHandle: handle,
                fileOffset: 0,
                length: 0x4000,
                flags: FuseSetupMappingFlag.write.rawValue,
                memoryOffset: 0
            ))
        ))
        #expect(try FuseProtocol.decodeOutHeader(unauthorizedWriteMapping).error == -EBADF)

        let mismatchedNodeMapping = server.handle(request: request(
            unique: 621,
            opcode: .setupmapping,
            nodeID: HostFS.rootNodeID,
            payload: FuseProtocol.encodeSetupMappingIn(FuseSetupMappingIn(
                fileHandle: handle,
                fileOffset: 0,
                length: 0x4000,
                flags: 0,
                memoryOffset: 0
            ))
        ))
        #expect(try FuseProtocol.decodeOutHeader(mismatchedNodeMapping).error == -EBADF)

        let setup = server.handle(request: request(
            unique: 63,
            opcode: .setupmapping,
            nodeID: nodeID,
            payload: FuseProtocol.encodeSetupMappingIn(FuseSetupMappingIn(fileHandle: handle, fileOffset: 0, length: 0x4000, flags: 0, memoryOffset: 0x4000))
        ))
        #expect(try FuseProtocol.decodeOutHeader(setup).error == 0)

        let overlap = server.handle(request: request(
            unique: 64,
            opcode: .setupmapping,
            nodeID: nodeID,
            payload: FuseProtocol.encodeSetupMappingIn(FuseSetupMappingIn(fileHandle: handle, fileOffset: 0, length: 0x4000, flags: 0, memoryOffset: 0x4000))
        ))
        #expect(try FuseProtocol.decodeOutHeader(overlap).error == -EBUSY)

        let remove = server.handle(request: request(
            unique: 65,
            opcode: .removemapping,
            nodeID: nodeID,
            payload: FuseProtocol.encodeRemoveMappingIn(FuseRemoveMappingIn(mappings: [
                FuseRemoveMappingOne(memoryOffset: 0x4000, length: 0x4000),
            ]))
        ))
        #expect(try FuseProtocol.decodeOutHeader(remove).error == 0)
    }

    @Test func daxMappingOpcodesReturnENOSYSWithoutWindow() throws {
        let root = try TestFuseServerRoot()
        let server = try FuseServer(hostFS: HostFS(rootPath: root.url.path))
        let setup = server.handle(request: request(
            unique: 70,
            opcode: .setupmapping,
            nodeID: HostFS.rootNodeID,
            payload: FuseProtocol.encodeSetupMappingIn(FuseSetupMappingIn(fileHandle: 1, fileOffset: 0, length: 0x4000, flags: 0, memoryOffset: 0))
        ))
        let remove = server.handle(request: request(
            unique: 71,
            opcode: .removemapping,
            nodeID: HostFS.rootNodeID,
            payload: FuseProtocol.encodeRemoveMappingIn(FuseRemoveMappingIn(mappings: [
                FuseRemoveMappingOne(memoryOffset: 0, length: 0x4000),
            ]))
        ))

        #expect(try FuseProtocol.decodeOutHeader(setup).error == -FuseProtocol.linuxErrno(ENOSYS))
        #expect(try FuseProtocol.decodeOutHeader(remove).error == -FuseProtocol.linuxErrno(ENOSYS))
    }

    @Test func flockOwnersConflictShareAndReleaseIndependently() throws {
        let root = try TestFuseServerRoot()
        try root.write("lock me", to: "flock.txt")
        let server = try FuseServer(hostFS: HostFS(rootPath: root.url.path))
        let lookup = server.handle(request: request(
            unique: 700,
            opcode: .lookup,
            nodeID: HostFS.rootNodeID,
            payload: Array("flock.txt\0".utf8)
        ))
        let nodeID = payload(from: lookup).leUInt64(at: 0)
        func open(_ unique: UInt64) throws -> UInt64 {
            let response = server.handle(request: request(
                unique: unique,
                opcode: .open,
                nodeID: nodeID,
                payload: bytes(UInt32(2)) + bytes(UInt32(0)) // Linux O_RDWR
            ))
            #expect(try FuseProtocol.decodeOutHeader(response).error == 0)
            return payload(from: response).leUInt64(at: 0)
        }
        let firstHandle = try open(701)
        let secondHandle = try open(702)
        let thirdHandle = try open(703)

        func setLock(
            _ unique: UInt64,
            handle: UInt64,
            owner: UInt64,
            type: UInt32
        ) throws -> Int32 {
            let response = server.handle(request: request(
                unique: unique,
                opcode: .setlk,
                nodeID: nodeID,
                payload: lockPayload(handle: handle, owner: owner, type: type, flags: 1)
            ))
            return try FuseProtocol.decodeOutHeader(response).error
        }

        #expect(try setLock(704, handle: firstHandle, owner: 1, type: 1) == 0)
        #expect(try setLock(705, handle: secondHandle, owner: 2, type: 1) == -FuseProtocol.linuxErrno(EAGAIN))
        let unsupportedQuery = server.handle(request: request(
            unique: 706,
            opcode: .getlk,
            nodeID: nodeID,
            payload: lockPayload(handle: secondHandle, owner: 2, type: 1, flags: 1)
        ))
        #expect(try FuseProtocol.decodeOutHeader(unsupportedQuery).error == -FuseProtocol.linuxErrno(EOPNOTSUPP))

        #expect(try setLock(707, handle: firstHandle, owner: 1, type: 2) == 0)
        #expect(try setLock(708, handle: secondHandle, owner: 2, type: 0) == 0)
        #expect(try setLock(709, handle: thirdHandle, owner: 3, type: 0) == 0)
        #expect(try setLock(710, handle: firstHandle, owner: 1, type: 1) == -FuseProtocol.linuxErrno(EAGAIN))

        let secondRelease = try directReleaseResponse(
            server: server,
            request: request(
                unique: 711,
                opcode: .release,
                nodeID: nodeID,
                payload: releasePayload(handle: secondHandle, owner: 2)
            )
        )
        #expect(try FuseProtocol.decodeOutHeader(secondRelease).error == 0)
        #expect(try setLock(712, handle: firstHandle, owner: 1, type: 1) == -FuseProtocol.linuxErrno(EAGAIN))

        let thirdRelease = try directReleaseResponse(
            server: server,
            request: request(
                unique: 713,
                opcode: .release,
                nodeID: nodeID,
                payload: releasePayload(handle: thirdHandle, owner: 3)
            )
        )
        #expect(try FuseProtocol.decodeOutHeader(thirdRelease).error == 0)
        #expect(try setLock(714, handle: firstHandle, owner: 1, type: 1) == 0)
    }

    @Test func recordLocksPreserveRangesOwnersFlushAndConnectionReset() throws {
        let root = try TestFuseServerRoot()
        try root.write("012345678901234567890123456789", to: "record-lock.txt")
        let hostFS = try HostFS(rootPath: root.url.path)
        let server = FuseServer(hostFS: hostFS)
        let lookup = server.handle(request: request(
            unique: 720,
            opcode: .lookup,
            nodeID: HostFS.rootNodeID,
            payload: Array("record-lock.txt\0".utf8)
        ))
        let nodeID = payload(from: lookup).leUInt64(at: 0)
        func open(_ unique: UInt64) throws -> UInt64 {
            let response = server.handle(request: request(
                unique: unique,
                opcode: .open,
                nodeID: nodeID,
                payload: bytes(UInt32(2)) + bytes(UInt32(0))
            ))
            #expect(try FuseProtocol.decodeOutHeader(response).error == 0)
            return payload(from: response).leUInt64(at: 0)
        }
        let handles = try (0..<8).map { try open(721 + UInt64($0)) }
        func setLock(
            _ unique: UInt64,
            handle: UInt64,
            owner: UInt64,
            start: UInt64,
            end: UInt64,
            type: UInt32
        ) throws -> Int32 {
            let response = server.handle(request: request(
                unique: unique,
                opcode: .setlk,
                nodeID: nodeID,
                payload: lockPayload(
                    handle: handle,
                    owner: owner,
                    start: start,
                    end: end,
                    type: type
                )
            ))
            return try FuseProtocol.decodeOutHeader(response).error
        }

        #expect(try setLock(730, handle: handles[0], owner: 11, start: 0, end: 9, type: 0) == 0)
        #expect(try setLock(731, handle: handles[1], owner: 12, start: 0, end: 9, type: 0) == 0)
        #expect(try setLock(732, handle: handles[2], owner: 13, start: 0, end: 9, type: 1) == -FuseProtocol.linuxErrno(EAGAIN))

        let query = server.handle(request: request(
            unique: 733,
            opcode: .getlk,
            nodeID: nodeID,
            payload: lockPayload(handle: handles[2], owner: 13, start: 0, end: 9, type: 1)
        ))
        #expect(try FuseProtocol.decodeOutHeader(query).error == 0)
        let queryPayload = payload(from: query)
        #expect(queryPayload.leUInt64(at: 0) == 0)
        #expect(queryPayload.leUInt64(at: 8) == 9)
        #expect(queryPayload.leUInt32(at: 16) == 0) // Linux F_RDLCK

        #expect(try setLock(734, handle: handles[2], owner: 13, start: 10, end: 19, type: 1) == 0)
        #expect(try setLock(735, handle: handles[2], owner: 13, start: 10, end: 14, type: 2) == 0)
        #expect(try setLock(736, handle: handles[3], owner: 14, start: 10, end: 14, type: 1) == 0)
        #expect(try setLock(737, handle: handles[4], owner: 15, start: 15, end: 19, type: 1) == -FuseProtocol.linuxErrno(EAGAIN))

        _ = server.handle(request: request(
            unique: 738,
            opcode: .flush,
            nodeID: nodeID,
            payload: flushPayload(handle: handles[0], owner: 11)
        ))
        #expect(try setLock(739, handle: handles[5], owner: 16, start: 0, end: 9, type: 1) == -FuseProtocol.linuxErrno(EAGAIN))
        _ = server.handle(request: request(
            unique: 740,
            opcode: .flush,
            nodeID: nodeID,
            payload: flushPayload(handle: handles[1], owner: 12)
        ))
        #expect(try setLock(741, handle: handles[5], owner: 16, start: 0, end: 9, type: 1) == 0)

        #expect(try setLock(742, handle: handles[6], owner: 17, start: 20, end: 29, type: 1) == 0)
        server.resetConnection()

        let replacement = try FuseServer(hostFS: HostFS(rootPath: root.url.path))
        let replacementLookup = replacement.handle(request: request(
            unique: 743,
            opcode: .lookup,
            nodeID: HostFS.rootNodeID,
            payload: Array("record-lock.txt\0".utf8)
        ))
        let replacementNodeID = payload(from: replacementLookup).leUInt64(at: 0)
        let replacementOpen = replacement.handle(request: request(
            unique: 744,
            opcode: .open,
            nodeID: replacementNodeID,
            payload: bytes(UInt32(2)) + bytes(UInt32(0))
        ))
        let replacementHandle = payload(from: replacementOpen).leUInt64(at: 0)
        let afterReset = replacement.handle(request: request(
            unique: 745,
            opcode: .setlk,
            nodeID: replacementNodeID,
            payload: lockPayload(handle: replacementHandle, owner: 18, start: 20, end: 29, type: 1)
        ))
        #expect(try FuseProtocol.decodeOutHeader(afterReset).error == 0)
    }

    @Test func blockingRecordLockWaitsThenAcquiresWithoutLeaking() throws {
        let root = try TestFuseServerRoot()
        try root.write("blocking", to: "blocking-lock.txt")
        let server = try FuseServer(hostFS: HostFS(rootPath: root.url.path))
        let lookup = server.handle(request: request(
            unique: 750,
            opcode: .lookup,
            nodeID: HostFS.rootNodeID,
            payload: Array("blocking-lock.txt\0".utf8)
        ))
        let nodeID = payload(from: lookup).leUInt64(at: 0)
        func open(_ unique: UInt64) -> UInt64 {
            let response = server.handle(request: request(
                unique: unique,
                opcode: .open,
                nodeID: nodeID,
                payload: bytes(UInt32(2)) + bytes(UInt32(0))
            ))
            return payload(from: response).leUInt64(at: 0)
        }
        let firstHandle = open(751)
        let secondHandle = open(752)
        let firstLock = server.handle(request: request(
            unique: 753,
            opcode: .setlk,
            nodeID: nodeID,
            payload: lockPayload(handle: firstHandle, owner: 21, start: 0, end: 7, type: 1)
        ))
        #expect(try FuseProtocol.decodeOutHeader(firstLock).error == 0)

        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let result = LockedResponse()
        DispatchQueue.global(qos: .userInitiated).async {
            started.signal()
            result.store(server.handle(request: request(
                unique: 754,
                opcode: .setlkw,
                nodeID: nodeID,
                payload: lockPayload(handle: secondHandle, owner: 22, start: 0, end: 7, type: 1)
            )))
            finished.signal()
        }
        #expect(started.wait(timeout: .now() + 1) == .success)
        #expect(finished.wait(timeout: .now() + 0.1) == .timedOut)

        let unlock = server.handle(request: request(
            unique: 755,
            opcode: .setlk,
            nodeID: nodeID,
            payload: lockPayload(handle: firstHandle, owner: 21, start: 0, end: 7, type: 2)
        ))
        #expect(try FuseProtocol.decodeOutHeader(unlock).error == 0)
        #expect(finished.wait(timeout: .now() + 2) == .success)
        #expect(try FuseProtocol.decodeOutHeader(result.load()).error == 0)

        let release = server.handle(request: request(
            unique: 756,
            opcode: .release,
            nodeID: nodeID,
            payload: releasePayload(handle: secondHandle, owner: 22)
        ))
        #expect(try FuseProtocol.decodeOutHeader(release).error == 0)
        let reacquire = server.handle(request: request(
            unique: 757,
            opcode: .setlk,
            nodeID: nodeID,
            payload: lockPayload(handle: firstHandle, owner: 21, start: 0, end: 7, type: 1)
        ))
        #expect(try FuseProtocol.decodeOutHeader(reacquire).error == 0)
    }

    @Test func interruptCancelsBlockingRecordLockAndLeavesNoOwnerLock() throws {
        let root = try TestFuseServerRoot()
        try root.write("interrupt", to: "interrupt-lock.txt")
        let server = try FuseServer(hostFS: HostFS(rootPath: root.url.path))
        let lookup = server.handle(request: request(
            unique: 760,
            opcode: .lookup,
            nodeID: HostFS.rootNodeID,
            payload: Array("interrupt-lock.txt\0".utf8)
        ))
        let nodeID = payload(from: lookup).leUInt64(at: 0)
        func open(_ unique: UInt64) -> UInt64 {
            let response = server.handle(request: request(
                unique: unique,
                opcode: .open,
                nodeID: nodeID,
                payload: bytes(UInt32(2)) + bytes(UInt32(0))
            ))
            return payload(from: response).leUInt64(at: 0)
        }
        let firstHandle = open(761)
        let secondHandle = open(762)
        let ownerLock = server.handle(request: request(
            unique: 763,
            opcode: .setlk,
            nodeID: nodeID,
            payload: lockPayload(handle: firstHandle, owner: 31, start: 0, end: 7, type: 1)
        ))
        #expect(try FuseProtocol.decodeOutHeader(ownerLock).error == 0)

        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let result = LockedResponse()
        DispatchQueue.global(qos: .userInitiated).async {
            started.signal()
            result.store(server.handle(request: request(
                unique: 764,
                opcode: .setlkw,
                nodeID: nodeID,
                payload: lockPayload(handle: secondHandle, owner: 32, start: 0, end: 7, type: 1)
            )))
            finished.signal()
        }
        #expect(started.wait(timeout: .now() + 1) == .success)
        #expect(finished.wait(timeout: .now() + 0.1) == .timedOut)

        let interrupt = server.handle(request: request(
            unique: 765,
            opcode: .interrupt,
            nodeID: HostFS.rootNodeID,
            payload: bytes(UInt64(764))
        ))
        #expect(interrupt.isEmpty)
        #expect(finished.wait(timeout: .now() + 1) == .success)
        #expect(try FuseProtocol.decodeOutHeader(result.load()).error == -FuseProtocol.linuxErrno(EINTR))

        let unlock = server.handle(request: request(
            unique: 766,
            opcode: .setlk,
            nodeID: nodeID,
            payload: lockPayload(handle: firstHandle, owner: 31, start: 0, end: 7, type: 2)
        ))
        #expect(try FuseProtocol.decodeOutHeader(unlock).error == 0)
        let cleanAcquire = server.handle(request: request(
            unique: 767,
            opcode: .setlk,
            nodeID: nodeID,
            payload: lockPayload(handle: secondHandle, owner: 33, start: 0, end: 7, type: 1)
        ))
        #expect(try FuseProtocol.decodeOutHeader(cleanAcquire).error == 0)

        let thirdHandle = open(768)
        let releaseFinished = DispatchSemaphore(value: 0)
        let releaseResult = LockedResponse()
        DispatchQueue.global(qos: .userInitiated).async {
            releaseResult.store(server.handle(request: request(
                unique: 769,
                opcode: .setlkw,
                nodeID: nodeID,
                payload: lockPayload(handle: thirdHandle, owner: 34, start: 0, end: 7, type: 1)
            )))
            releaseFinished.signal()
        }
        #expect(releaseFinished.wait(timeout: .now() + 0.1) == .timedOut)
        let waiterRelease = server.handle(request: request(
            unique: 770,
            opcode: .release,
            nodeID: nodeID,
            payload: releasePayload(handle: thirdHandle, owner: 34)
        ))
        #expect(try FuseProtocol.decodeOutHeader(waiterRelease).error == 0)
        #expect(releaseFinished.wait(timeout: .now() + 1) == .success)
        #expect(try FuseProtocol.decodeOutHeader(releaseResult.load()).error == -FuseProtocol.linuxErrno(EINTR))
    }
}

private func request(unique: UInt64, opcode: FuseOpcode, nodeID: UInt64, payload: [UInt8] = []) -> [UInt8] {
    request(unique: unique, opcodeRaw: opcode.rawValue, nodeID: nodeID, payload: payload)
}

private func request(unique: UInt64, opcodeRaw: UInt32, nodeID: UInt64, payload: [UInt8] = []) -> [UInt8] {
    FuseProtocol.encodeInHeader(FuseInHeader(
        length: UInt32(FuseInHeader.byteCount + payload.count),
        opcode: opcodeRaw,
        unique: unique,
        nodeID: nodeID,
        uid: 1000,
        gid: 1000,
        pid: 42
    )) + payload
}

private func payload(from response: [UInt8]) -> [UInt8] {
    Array(response.dropFirst(FuseOutHeader.byteCount))
}

private func alignedDirentPlusLength(nameLength: Int) -> Int {
    var length = 128 + 24 + nameLength
    while length % 8 != 0 { length += 1 }
    return length
}

private func bytes(_ value: UInt32) -> [UInt8] {
    var value = value.littleEndian
    return withUnsafeBytes(of: &value) { Array($0) }
}

private func bytes(_ value: UInt64) -> [UInt8] {
    var value = value.littleEndian
    return withUnsafeBytes(of: &value) { Array($0) }
}

private func lockPayload(
    handle: UInt64,
    owner: UInt64,
    start: UInt64 = 0,
    end: UInt64 = .max,
    type: UInt32,
    pid: UInt32 = 42,
    flags: UInt32 = 0
) -> [UInt8] {
    bytes(handle) + bytes(owner) + bytes(start) + bytes(end)
        + bytes(type) + bytes(pid) + bytes(flags) + bytes(UInt32(0))
}

private func flushPayload(handle: UInt64, owner: UInt64) -> [UInt8] {
    bytes(handle) + bytes(UInt32(0)) + bytes(UInt32(0)) + bytes(owner)
}

private func releasePayload(handle: UInt64, owner: UInt64) -> [UInt8] {
    bytes(handle) + bytes(UInt32(0)) + bytes(UInt32(0)) + bytes(owner)
}

private func directReleaseResponse(server: FuseServer, request: [UInt8]) throws -> [UInt8] {
    let header = try FuseProtocol.decodeInHeader(request)
    let payload = request[FuseInHeader.byteCount..<Int(header.length)]
    var destination = [UInt8](repeating: 0, count: FuseOutHeader.byteCount)
    let count = destination.withUnsafeMutableBytes { buffer -> Int in
        server.writeReleaseResponse(
            header: header,
            payload: payload,
            writable: [VirtqueueSegment(
                pointer: buffer.baseAddress!,
                length: buffer.count,
                isDeviceWritable: true
            )]
        )
    }
    return Array(destination.prefix(count))
}

private func directGetattrResponse(server: FuseServer, request: [UInt8]) throws -> [UInt8] {
    let header = try FuseProtocol.decodeInHeader(request)
    let payload = request[FuseInHeader.byteCount..<Int(header.length)]
    var destination = [UInt8](repeating: 0, count: FuseOutHeader.byteCount + 104)
    let count = destination.withUnsafeMutableBytes { buffer -> Int in
        server.writeGetattrResponse(
            header: header,
            payload: payload,
            writable: [VirtqueueSegment(
                pointer: buffer.baseAddress!,
                length: buffer.count,
                isDeviceWritable: true
            )]
        )
    }
    return Array(destination.prefix(count))
}

private func directWriteResponse(server: FuseServer, request: [UInt8]) throws -> [UInt8] {
    let header = try FuseProtocol.decodeInHeader(request)
    let payload = request[FuseInHeader.byteCount..<Int(header.length)]
    var destination = [UInt8](repeating: 0, count: FuseOutHeader.byteCount + 8)
    let count = destination.withUnsafeMutableBytes { buffer -> Int in
        server.writeWriteResponse(
            header: header,
            payload: payload,
            writable: [VirtqueueSegment(
                pointer: buffer.baseAddress!,
                length: buffer.count,
                isDeviceWritable: true
            )]
        )
    }
    return Array(destination.prefix(count))
}

private func directReadResponse(server: FuseServer, request: [UInt8]) throws -> [UInt8] {
    let header = try FuseProtocol.decodeInHeader(request)
    let payload = request[FuseInHeader.byteCount..<Int(header.length)]
    var destination = [UInt8](repeating: 0, count: FuseOutHeader.byteCount + 128)
    let count = destination.withUnsafeMutableBytes { buffer -> Int in
        server.writeReadResponse(
            header: header,
            payload: payload,
            writable: [VirtqueueSegment(
                pointer: buffer.baseAddress!,
                length: buffer.count,
                isDeviceWritable: true
            )]
        )
    }
    return Array(destination.prefix(count))
}

private func setattrIn(mode: UInt32) -> [UInt8] {
    FuseProtocol.encodeSetattrIn(FuseSetattrIn(valid: .mode, mode: mode))
}

private func setattrSize(_ size: UInt64, fileHandle: UInt64? = nil) -> [UInt8] {
    FuseProtocol.encodeSetattrIn(FuseSetattrIn(
        valid: fileHandle == nil ? .size : [.size, .fileHandle],
        fileHandle: fileHandle ?? 0,
        size: size
    ))
}

private func hostStat(_ url: URL) throws -> stat {
    var status = stat()
    guard lstat(url.path, &status) == 0 else {
        throw CocoaError(.fileReadUnknown)
    }
    return status
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

private final class TestFuseServerRoot {
    let url: URL

    init() throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dory-fuseserver-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func write(_ text: String, to relativePath: String) throws {
        try text.write(to: url.appendingPathComponent(relativePath), atomically: true, encoding: .utf8)
    }
}

private final class LockedResponse: @unchecked Sendable {
    private let lock = NSLock()
    private var response: [UInt8] = []

    func store(_ response: [UInt8]) {
        lock.withLock { self.response = response }
    }

    func load() -> [UInt8] {
        lock.withLock { response }
    }
}
