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

        let getattr = server.handle(request: request(unique: 11, opcode: .getattr, nodeID: nodeID))
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
        #expect(openPayload.leUInt32(at: 8) == (1 << 1) | (1 << 5))

        let readIn = bytes(handle) + bytes(UInt64(6)) + bytes(UInt32(4)) + bytes(UInt32(0)) + bytes(UInt64(0)) + bytes(UInt32(0)) + bytes(UInt32(0))
        let read = server.handle(request: request(unique: 13, opcode: .read, nodeID: nodeID, payload: readIn))

        #expect(try FuseProtocol.decodeOutHeader(read).error == 0)
        #expect(String(decoding: payload(from: read), as: UTF8.self) == "dory")

        let release = server.handle(request: request(unique: 14, opcode: .release, nodeID: nodeID, payload: bytes(handle) + bytes(UInt32(0)) + bytes(UInt32(0)) + bytes(UInt64(0))))

        #expect(try FuseProtocol.decodeOutHeader(release).error == 0)

        let readAfterRelease = server.handle(request: request(unique: 15, opcode: .read, nodeID: nodeID, payload: readIn))

        #expect(try FuseProtocol.decodeOutHeader(readAfterRelease).error == -EBADF)
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
        let createIn = bytes(UInt32(O_CREAT | O_RDWR)) + bytes(UInt32(0o644)) + bytes(UInt32(0)) + bytes(UInt32(0)) + Array("direct.txt\0".utf8)
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

    @Test func directMetadataMissResponsesMatchArrayPath() throws {
        let root = try TestFuseServerRoot()
        try root.write("exists", to: "exists.txt")
        let server = try FuseServer(hostFS: HostFS(rootPath: root.url.path), negativeDentryCaching: true)

        let missingRequest = request(unique: 201, opcode: .lookup, nodeID: HostFS.rootNodeID, payload: Array("missing.txt\0".utf8))
        let missingHeader = try FuseProtocol.decodeInHeader(missingRequest)
        let missingPayload = missingRequest[FuseInHeader.byteCount..<Int(missingHeader.length)]
        let missingArrayPath = server.handle(request: missingRequest)
        var missingDest = [UInt8](repeating: 0, count: FuseOutHeader.byteCount + 128)
        let missingCount = missingDest.withUnsafeMutableBytes { buffer -> Int in
            let segment = VirtqueueSegment(pointer: buffer.baseAddress!, length: buffer.count, isDeviceWritable: true)
            return server.writeLookupMissResponse(header: missingHeader, payload: missingPayload, writable: [segment])
        }

        // Negative-dentry caching: a miss now replies with a full fuse_entry_out carrying nodeid=0 and a
        // nonzero entry_valid (a cacheable negative), identical on both the direct and array dispatch paths.
        #expect(missingCount == FuseOutHeader.byteCount + 128)
        #expect(Array(missingDest[0..<missingCount]) == missingArrayPath)
        #expect(try FuseProtocol.decodeOutHeader(Array(missingDest)).error == 0)
        #expect(payload(from: Array(missingDest[0..<missingCount])).leUInt64(at: 0) == 0)
        #expect(payload(from: Array(missingDest[0..<missingCount])).leUInt64(at: 16) > 0)

        let hitRequest = request(unique: 202, opcode: .lookup, nodeID: HostFS.rootNodeID, payload: Array("exists.txt\0".utf8))
        let hitHeader = try FuseProtocol.decodeInHeader(hitRequest)
        let hitPayload = hitRequest[FuseInHeader.byteCount..<Int(hitHeader.length)]
        var hitDest = [UInt8](repeating: 0, count: FuseOutHeader.byteCount)
        let hitCount = hitDest.withUnsafeMutableBytes { buffer -> Int in
            let segment = VirtqueueSegment(pointer: buffer.baseAddress!, length: buffer.count, isDeviceWritable: true)
            return server.writeLookupMissResponse(header: hitHeader, payload: hitPayload, writable: [segment])
        }

        #expect(hitCount == 0)

        let getxattrRequest = request(unique: 203, opcode: .getxattr, nodeID: HostFS.rootNodeID)
        let getxattrHeader = try FuseProtocol.decodeInHeader(getxattrRequest)
        let getxattrArrayPath = server.handle(request: getxattrRequest)
        var getxattrDest = [UInt8](repeating: 0, count: FuseOutHeader.byteCount)
        let getxattrCount = getxattrDest.withUnsafeMutableBytes { buffer -> Int in
            let segment = VirtqueueSegment(pointer: buffer.baseAddress!, length: buffer.count, isDeviceWritable: true)
            return server.writeGetXattrNoDataResponse(header: getxattrHeader, writable: [segment])
        }

        #expect(getxattrCount == FuseOutHeader.byteCount)
        #expect(Array(getxattrDest) == getxattrArrayPath)
    }

    @Test func directCreateAndGetattrResponsesAreValid() throws {
        let root = try TestFuseServerRoot()
        let server = try FuseServer(hostFS: HostFS(rootPath: root.url.path))
        let createIn = bytes(UInt32(O_CREAT | O_RDWR)) + bytes(UInt32(0o644)) + bytes(UInt32(0)) + bytes(UInt32(0)) + Array("created-direct.txt\0".utf8)
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
        #expect(FileManager.default.fileExists(atPath: root.url.appendingPathComponent("created-direct.txt").path))

        let getattrRequest = request(unique: 211, opcode: .getattr, nodeID: nodeID)
        let getattrHeader = try FuseProtocol.decodeInHeader(getattrRequest)
        let getattrArrayPath = server.handle(request: getattrRequest)
        var getattrDest = [UInt8](repeating: 0, count: FuseOutHeader.byteCount + 104)
        let getattrCount = getattrDest.withUnsafeMutableBytes { buffer -> Int in
            let segment = VirtqueueSegment(pointer: buffer.baseAddress!, length: buffer.count, isDeviceWritable: true)
            return server.writeGetattrResponse(header: getattrHeader, writable: [segment])
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

        let readIn = bytes(UInt64(HostFS.rootNodeID)) + bytes(UInt64(0)) + bytes(UInt32(4096)) + bytes(UInt32(0)) + bytes(UInt64(0)) + bytes(UInt32(0)) + bytes(UInt32(0))
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

    @Test func createWriteFsyncRenameAndUnlinkMutateHostFilesystem() throws {
        let root = try TestFuseServerRoot()
        let server = try FuseServer(hostFS: HostFS(rootPath: root.url.path))
        let createIn = bytes(UInt32(O_CREAT | O_RDWR)) + bytes(UInt32(0o644)) + bytes(UInt32(0)) + bytes(UInt32(0)) + Array("draft.txt\0".utf8)

        let create = server.handle(request: request(unique: 40, opcode: .create, nodeID: HostFS.rootNodeID, payload: createIn))
        let createPayload = payload(from: create)
        let nodeID = createPayload.leUInt64(at: 0)
        let handle = createPayload.leUInt64(at: 128)

        #expect(try FuseProtocol.decodeOutHeader(create).error == 0)
        #expect(nodeID != 0)
        #expect(handle != 0)
        #expect(createPayload.leUInt32(at: 136) == (1 << 1) | (1 << 5))

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

    @Test func setattrSameModeSucceedsForFSEventsRelayWithoutChangingMode() throws {
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

        #expect(try FuseProtocol.decodeOutHeader(differentMode).error == -FuseProtocol.linuxErrno(EOPNOTSUPP))
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

        #expect(try FuseProtocol.decodeOutHeader(truncate).error != 0)
        #expect(try Data(contentsOf: root.url.appendingPathComponent("ro.txt")) == Data("keepme".utf8))
    }

    @Test func mkdirAndRmdirMutateHostFilesystem() throws {
        let root = try TestFuseServerRoot()
        let server = try FuseServer(hostFS: HostFS(rootPath: root.url.path))
        let mkdirIn = bytes(UInt32(0o755)) + bytes(UInt32(0)) + Array("nested\0".utf8)

        let mkdir = server.handle(request: request(unique: 50, opcode: .mkdir, nodeID: HostFS.rootNodeID, payload: mkdirIn))

        #expect(try FuseProtocol.decodeOutHeader(mkdir).error == 0)
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
        // Negative-dentry caching is opt-in (off by default), so a miss is a plain ENOENT.
        #expect(try FuseProtocol.decodeOutHeader(missing).error == -ENOENT)
        #expect(try FuseProtocol.decodeOutHeader(unsupported).error == -FuseProtocol.linuxErrno(ENOSYS))
    }

    @Test func initEnablesWritebackAndKillprivV2ByDefault() throws {
        let root = try TestFuseServerRoot()
        let initIn = bytes(UInt32(7)) + bytes(UInt32(38)) + bytes(UInt32(131_072)) + bytes(UInt32(FuseInitFlag.asyncRead.rawValue))
        let defaultServer = try FuseServer(hostFS: HostFS(rootPath: root.url.path))
        let optOutServer = try FuseServer(hostFS: HostFS(rootPath: root.url.path), writebackCache: false, killPrivV2: false)

        let defaultResponse = defaultServer.handle(request: request(unique: 33, opcode: .initOp, nodeID: HostFS.rootNodeID, payload: initIn))
        let optOutResponse = optOutServer.handle(request: request(unique: 34, opcode: .initOp, nodeID: HostFS.rootNodeID, payload: initIn))
        let defaultFlags = payload(from: defaultResponse).leUInt32(at: 12)
        let optOutFlags = payload(from: optOutResponse).leUInt32(at: 12)

        #expect(defaultFlags & FuseInitFlag.writebackCache.rawValue == FuseInitFlag.writebackCache.rawValue)
        #expect(defaultFlags & FuseInitFlag.handleKillprivV2.rawValue == FuseInitFlag.handleKillprivV2.rawValue)
        #expect(optOutFlags & FuseInitFlag.writebackCache.rawValue == 0)
        #expect(optOutFlags & FuseInitFlag.handleKillprivV2.rawValue == 0)
    }

    @Test func linuxErrnoTranslatesDivergentDarwinCodes() {
        #expect(FuseProtocol.linuxErrno(ENOSYS) == 38)      // Darwin 78 -> Linux 38 (else guest sees EREMCHG)
        #expect(FuseProtocol.linuxErrno(EOPNOTSUPP) == 95)  // Darwin 102 -> Linux 95
        #expect(FuseProtocol.linuxErrno(ENODATA) == 61)     // Darwin 96 -> Linux 61
        #expect(FuseProtocol.linuxErrno(ENOENT) == ENOENT)  // 2 == 2, coincident codes pass through
        #expect(FuseProtocol.linuxErrno(EIO) == EIO)        // 5 == 5
        #expect(FuseProtocol.linuxErrno(EINVAL) == EINVAL)  // 22 == 22
    }

    @Test func lookupMissReturnsCacheableNegativeDentry() throws {
        let root = try TestFuseServerRoot()
        let server = try FuseServer(hostFS: HostFS(rootPath: root.url.path), negativeDentryCaching: true, entryValiditySeconds: 7)

        let miss = server.handle(request: request(unique: 80, opcode: .lookup, nodeID: HostFS.rootNodeID, payload: Array("nope.txt\0".utf8)))
        let header = try FuseProtocol.decodeOutHeader(miss)
        let body = payload(from: miss)

        #expect(header.error == 0)
        #expect(header.length == UInt32(FuseOutHeader.byteCount + 128))
        #expect(body.leUInt64(at: 0) == 0)     // nodeid = 0 => negative dentry
        #expect(body.leUInt64(at: 16) == 7)    // entry_valid = configured timeout
        #expect(body.leUInt64(at: 24) == 0)    // attr_valid = 0 for negatives
    }

    @Test func negativeDentryDisabledReturnsPlainENOENT() throws {
        let root = try TestFuseServerRoot()
        let server = try FuseServer(hostFS: HostFS(rootPath: root.url.path), negativeDentryCaching: false)

        let miss = server.handle(request: request(unique: 81, opcode: .lookup, nodeID: HostFS.rootNodeID, payload: Array("nope.txt\0".utf8)))

        #expect(try FuseProtocol.decodeOutHeader(miss).error == -ENOENT)
        #expect(miss.count == FuseOutHeader.byteCount)
    }

    @Test func entryAndAttrTimeoutsAreConfigurable() throws {
        let root = try TestFuseServerRoot()
        try root.write("cached", to: "cached.txt")
        let server = try FuseServer(hostFS: HostFS(rootPath: root.url.path), entryValiditySeconds: 30, attrValiditySeconds: 30)

        let lookup = server.handle(request: request(unique: 82, opcode: .lookup, nodeID: HostFS.rootNodeID, payload: Array("cached.txt\0".utf8)))
        let entry = payload(from: lookup)
        let nodeID = entry.leUInt64(at: 0)
        let getattr = server.handle(request: request(unique: 83, opcode: .getattr, nodeID: nodeID))

        #expect(entry.leUInt64(at: 16) == 30)  // entry_valid
        #expect(entry.leUInt64(at: 24) == 30)  // attr_valid
        #expect(payload(from: getattr).leUInt64(at: 0) == 30)  // attr_valid on GETATTR
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

    @Test func truncateClearsPrivilegeBitsUnderKillprivV2() throws {
        let root = try TestFuseServerRoot()
        try root.write("privileged", to: "suidtrunc.bin")
        let path = root.url.appendingPathComponent("suidtrunc.bin").path
        try FileManager.default.setAttributes([.posixPermissions: 0o6755], ofItemAtPath: path)  // suid+sgid
        let server = try FuseServer(hostFS: HostFS(rootPath: root.url.path))
        let nodeID = payload(from: server.handle(request: request(unique: 97, opcode: .lookup, nodeID: HostFS.rootNodeID, payload: Array("suidtrunc.bin\0".utf8)))).leUInt64(at: 0)

        // An O_TRUNC open arrives as SETATTR size=0 (FUSE_ATOMIC_O_TRUNC is not advertised); under
        // KILLPRIV_V2 the server must drop suid/sgid on the truncate just as it does on write.
        let trunc = server.handle(request: request(unique: 98, opcode: .setattr, nodeID: nodeID, payload: setattrSize(0)))

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

private func setattrIn(mode: UInt32) -> [UInt8] {
    var data = [UInt8](repeating: 0, count: 88)
    replaceLE(UInt32(1), at: 0, in: &data)
    replaceLE(mode, at: 68, in: &data)
    return data
}

private func setattrSize(_ size: UInt64, fileHandle: UInt64? = nil) -> [UInt8] {
    var data = [UInt8](repeating: 0, count: 88)
    var valid = FuseSetattrValid.size.rawValue
    if let fileHandle {
        valid |= FuseSetattrValid.fileHandle.rawValue
        data.replaceSubrange(8..<16, with: bytes(fileHandle))
    }
    replaceLE(valid, at: 0, in: &data)
    data.replaceSubrange(16..<24, with: bytes(size))
    return data
}

private func replaceLE(_ value: UInt32, at offset: Int, in data: inout [UInt8]) {
    let bytes = bytes(value)
    data.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
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
