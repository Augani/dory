import Darwin
import Foundation
import Testing
@testable import DoryHV

struct HostFSTests {
    @Test func rootGetattrReturnsDirectoryAttributes() throws {
        let root = try TestHostFSRoot()
        let fs = try HostFS(rootPath: root.url.path)

        let attrs = try fs.getattr(nodeID: HostFS.rootNodeID)

        #expect(attrs.nodeID == HostFS.rootNodeID)
        #expect(attrs.isDirectory)
        #expect(attrs.uid == 1000)
        #expect(attrs.gid == 1000)
    }

    @Test func lookupGetattrAndReadSquashIdentity() throws {
        let root = try TestHostFSRoot()
        try root.write("hello dory", to: "hello.txt")
        let fs = try HostFS(rootPath: root.url.path)

        let entry = try fs.lookup(parent: HostFS.rootNodeID, name: "hello.txt")
        let attrs = try fs.getattr(nodeID: entry.nodeID)
        let handle = try fs.openRead(nodeID: entry.nodeID)
        defer { fs.close(handle: handle) }

        #expect(entry.name == "hello.txt")
        #expect(attrs.isRegularFile)
        #expect(attrs.size == 10)
        #expect(attrs.uid == 1000)
        #expect(attrs.gid == 1000)
        #expect(String(decoding: try fs.read(handle: handle, offset: 6, count: 4), as: UTF8.self) == "dory")
    }

    @Test func readdirplusReturnsSortedEntriesWithAttributes() throws {
        let root = try TestHostFSRoot()
        try root.write("b", to: "b.txt")
        try root.write("a", to: "a.txt")
        try FileManager.default.createDirectory(at: root.url.appendingPathComponent("dir"), withIntermediateDirectories: false)
        let fs = try HostFS(rootPath: root.url.path)

        let entries = try fs.readdirplus(nodeID: HostFS.rootNodeID)

        #expect(entries.map(\.name) == ["a.txt", "b.txt", "dir"])
        #expect(entries[0].attributes.isRegularFile)
        #expect(entries[2].attributes.isDirectory)
    }

    @Test func hiddenNamesAreInvisibleToLookupReaddirAndNested() throws {
        let root = try TestHostFSRoot()
        try FileManager.default.createDirectory(at: root.url.appendingPathComponent(".ssh"), withIntermediateDirectories: false)
        try root.write("PRIVATE KEY", to: ".ssh/id_rsa")
        try FileManager.default.createDirectory(at: root.url.appendingPathComponent("project"), withIntermediateDirectories: false)
        try root.write("code", to: "project/main.swift")
        try FileManager.default.createDirectory(at: root.url.appendingPathComponent("project/.ssh"), withIntermediateDirectories: false)
        try root.write("nested secret", to: "project/.ssh/id_rsa")
        let fs = try HostFS(rootPath: root.url.path, hiddenNames: [".ssh"])

        // A hidden name is not listed and cannot be looked up (so no node id → no read/open path).
        #expect(try fs.readdirplus(nodeID: HostFS.rootNodeID).map(\.name) == ["project"])
        #expect(throws: HostFSError.self) { _ = try fs.lookup(parent: HostFS.rootNodeID, name: ".ssh") }

        // Hiding is by name at any depth: the same name nested under an allowed dir is also hidden.
        let project = try fs.lookup(parent: HostFS.rootNodeID, name: "project")
        #expect(try fs.readdirplus(nodeID: project.nodeID).map(\.name) == ["main.swift"])
        #expect(throws: HostFSError.self) { _ = try fs.lookup(parent: project.nodeID, name: ".ssh") }

        // Non-hidden siblings still resolve normally.
        let file = try fs.lookup(parent: project.nodeID, name: "main.swift")
        #expect(file.attributes.isRegularFile)
    }

    @Test func hiddenNamesRejectMutationsBeforeHostChanges() throws {
        let root = try TestHostFSRoot()
        try root.write("keep", to: ".env")
        try root.write("secret", to: ".secret")
        try root.write("visible", to: "visible.txt")
        try FileManager.default.createDirectory(at: root.url.appendingPathComponent(".cache"), withIntermediateDirectories: false)
        let fs = try HostFS(rootPath: root.url.path, hiddenNames: [".cache", ".env", ".secret", ".ssh", ".target"])

        #expect(throws: HostFSError.notFound(".env")) {
            _ = try fs.createFile(parent: HostFS.rootNodeID, name: ".env")
        }
        #expect(try String(contentsOf: root.url.appendingPathComponent(".env"), encoding: .utf8) == "keep")

        #expect(throws: HostFSError.notFound(".ssh")) {
            _ = try fs.mkdir(parent: HostFS.rootNodeID, name: ".ssh")
        }
        #expect(!FileManager.default.fileExists(atPath: root.url.appendingPathComponent(".ssh").path))

        #expect(throws: HostFSError.notFound(".env")) {
            try fs.unlink(parent: HostFS.rootNodeID, name: ".env")
        }
        #expect(try String(contentsOf: root.url.appendingPathComponent(".env"), encoding: .utf8) == "keep")

        #expect(throws: HostFSError.notFound(".cache")) {
            try fs.rmdir(parent: HostFS.rootNodeID, name: ".cache")
        }
        var isDirectory = ObjCBool(false)
        let cacheExists = FileManager.default.fileExists(atPath: root.url.appendingPathComponent(".cache").path, isDirectory: &isDirectory)
        #expect(cacheExists)
        #expect(isDirectory.boolValue)

        #expect(throws: HostFSError.notFound(".target")) {
            _ = try fs.rename(parent: HostFS.rootNodeID, name: "visible.txt", newParent: HostFS.rootNodeID, newName: ".target")
        }
        #expect(FileManager.default.fileExists(atPath: root.url.appendingPathComponent("visible.txt").path))
        #expect(!FileManager.default.fileExists(atPath: root.url.appendingPathComponent(".target").path))

        #expect(throws: HostFSError.notFound(".secret")) {
            _ = try fs.rename(parent: HostFS.rootNodeID, name: ".secret", newParent: HostFS.rootNodeID, newName: "revealed.txt")
        }
        #expect(try String(contentsOf: root.url.appendingPathComponent(".secret"), encoding: .utf8) == "secret")
        #expect(!FileManager.default.fileExists(atPath: root.url.appendingPathComponent("revealed.txt").path))
    }

    @Test func statfsReturnsHostFilesystemShape() throws {
        let root = try TestHostFSRoot()
        let fs = try HostFS(rootPath: root.url.path)

        let stat = try fs.statfs()

        #expect(stat.blockSize > 0)
        #expect(stat.blocks > 0)
        #expect(stat.nameMax > 0)
    }

    @Test func lookupRejectsTraversalAndNestedNames() throws {
        let root = try TestHostFSRoot()
        let fs = try HostFS(rootPath: root.url.path)

        #expect(throws: HostFSError.invalidName("..")) {
            _ = try fs.lookup(parent: HostFS.rootNodeID, name: "..")
        }
        #expect(throws: HostFSError.invalidName("a/b")) {
            _ = try fs.lookup(parent: HostFS.rootNodeID, name: "a/b")
        }
    }

    @Test func openReadDoesNotFollowSymlinks() throws {
        let root = try TestHostFSRoot()
        try root.write("inside", to: "target.txt")
        symlink("target.txt", root.url.appendingPathComponent("link.txt").path)
        let fs = try HostFS(rootPath: root.url.path)

        let link = try fs.lookup(parent: HostFS.rootNodeID, name: "link.txt")

        #expect(link.attributes.isSymlink)
        #expect(throws: HostFSError.notRegularFile(link.nodeID)) {
            _ = try fs.openRead(nodeID: link.nodeID)
        }
    }

    @Test func createAndReadSymlinkAreVisibleOnHost() throws {
        let root = try TestHostFSRoot()
        try root.write("inside", to: "target.txt")
        let fs = try HostFS(rootPath: root.url.path)

        let link = try fs.symlink(parent: HostFS.rootNodeID, name: "link.txt", target: "target.txt")

        #expect(link.attributes.isSymlink)
        #expect(try fs.readlink(nodeID: link.nodeID) == "target.txt")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: root.url.appendingPathComponent("link.txt").path) == "target.txt")
    }

    @Test func directoryOpenAsFileIsRejected() throws {
        let root = try TestHostFSRoot()
        try FileManager.default.createDirectory(at: root.url.appendingPathComponent("dir"), withIntermediateDirectories: false)
        let fs = try HostFS(rootPath: root.url.path)

        let dir = try fs.lookup(parent: HostFS.rootNodeID, name: "dir")

        #expect(throws: HostFSError.notRegularFile(dir.nodeID)) {
            _ = try fs.openRead(nodeID: dir.nodeID)
        }
    }

    @Test func createWriteFsyncRenameAndUnlinkAreVisibleOnHost() throws {
        let root = try TestHostFSRoot()
        let fs = try HostFS(rootPath: root.url.path)

        let created = try fs.createFile(parent: HostFS.rootNodeID, name: "draft.txt")
        let handle = try fs.openReadWrite(nodeID: created.nodeID)
        try fs.write(handle: handle, offset: 0, data: Array("hello".utf8))
        try fs.write(handle: handle, offset: 5, data: Array(" world".utf8))
        try fs.fsync(handle: handle)
        fs.close(handle: handle)

        #expect(try String(contentsOf: root.url.appendingPathComponent("draft.txt"), encoding: .utf8) == "hello world")

        let renamed = try fs.rename(parent: HostFS.rootNodeID, name: "draft.txt", newParent: HostFS.rootNodeID, newName: "final.txt")

        #expect(renamed.name == "final.txt")
        #expect(FileManager.default.fileExists(atPath: root.url.appendingPathComponent("final.txt").path))
        #expect(!FileManager.default.fileExists(atPath: root.url.appendingPathComponent("draft.txt").path))

        try fs.unlink(parent: HostFS.rootNodeID, name: "final.txt")

        #expect(!FileManager.default.fileExists(atPath: root.url.appendingPathComponent("final.txt").path))
    }

    @Test func createFileAndOpenReturnsWritableHandle() throws {
        let root = try TestHostFSRoot()
        let fs = try HostFS(rootPath: root.url.path)

        let created = try fs.createFileAndOpen(parent: HostFS.rootNodeID, name: "draft.txt")
        defer { fs.close(handle: created.fd) }

        #expect(created.entry.attributes.isRegularFile)
        try fs.write(handle: created.fd, offset: 0, data: Array("hello".utf8))
        #expect(try String(contentsOf: root.url.appendingPathComponent("draft.txt"), encoding: .utf8) == "hello")

        let lookedUp = try fs.lookup(parent: HostFS.rootNodeID, name: "draft.txt")
        #expect(lookedUp.nodeID == created.entry.nodeID)
    }

    @Test func mkdirAndRmdirAreVisibleOnHost() throws {
        let root = try TestHostFSRoot()
        let fs = try HostFS(rootPath: root.url.path)

        let dir = try fs.mkdir(parent: HostFS.rootNodeID, name: "nested")

        #expect(dir.attributes.isDirectory)
        #expect(FileManager.default.fileExists(atPath: root.url.appendingPathComponent("nested").path))

        try fs.rmdir(parent: HostFS.rootNodeID, name: "nested")

        #expect(!FileManager.default.fileExists(atPath: root.url.appendingPathComponent("nested").path))
    }

    @Test func unlinkForgetsOnlyTheRemovedFileNode() throws {
        let root = try TestHostFSRoot()
        try root.write("one", to: "file.txt")
        try root.write("two", to: "file-extra.txt")
        let fs = try HostFS(rootPath: root.url.path)
        let file = try fs.lookup(parent: HostFS.rootNodeID, name: "file.txt")
        let sibling = try fs.lookup(parent: HostFS.rootNodeID, name: "file-extra.txt")

        try fs.unlink(parent: HostFS.rootNodeID, name: "file.txt")

        #expect(throws: HostFSError.notFound("node \(file.nodeID)")) {
            _ = try fs.cachedAttributes(nodeID: file.nodeID)
        }
        #expect(try fs.cachedAttributes(nodeID: sibling.nodeID).size == 3)
    }

    @Test func rmdirForgetsDescendantNodes() throws {
        let root = try TestHostFSRoot()
        try FileManager.default.createDirectory(at: root.url.appendingPathComponent("nested"), withIntermediateDirectories: false)
        try root.write("child", to: "nested/child.txt")
        let fs = try HostFS(rootPath: root.url.path)
        let dir = try fs.lookup(parent: HostFS.rootNodeID, name: "nested")
        let child = try fs.lookup(parent: dir.nodeID, name: "child.txt")

        try FileManager.default.removeItem(at: root.url.appendingPathComponent("nested/child.txt"))
        try fs.rmdir(parent: HostFS.rootNodeID, name: "nested")

        #expect(throws: HostFSError.notFound("node \(dir.nodeID)")) {
            _ = try fs.cachedAttributes(nodeID: dir.nodeID)
        }
        #expect(throws: HostFSError.notFound("node \(child.nodeID)")) {
            _ = try fs.cachedAttributes(nodeID: child.nodeID)
        }
    }

    @Test func xattrRoundTripsThroughOpenHandle() throws {
        let root = try TestHostFSRoot()
        try root.write("payload", to: "file.txt")
        let fs = try HostFS(rootPath: root.url.path)
        let entry = try fs.lookup(parent: HostFS.rootNodeID, name: "file.txt")
        let handle = try fs.openReadWrite(nodeID: entry.nodeID)
        defer { fs.close(handle: handle) }

        try fs.setXattr(handle: handle, name: "user.dory.test", value: Array("value".utf8))

        #expect(String(decoding: try fs.getXattr(handle: handle, name: "user.dory.test"), as: UTF8.self) == "value")
        #expect(try fs.listXattrs(handle: handle).contains("user.dory.test"))
    }

    @Test func readonlyShareRejectsMutatingOperations() throws {
        let root = try TestHostFSRoot()
        try root.write("payload", to: "file.txt")
        let fs = try HostFS(rootPath: root.url.path, readOnly: true)
        let entry = try fs.lookup(parent: HostFS.rootNodeID, name: "file.txt")
        let readHandle = try fs.openRead(nodeID: entry.nodeID)
        defer { fs.close(handle: readHandle) }

        #expect(String(decoding: try fs.read(handle: readHandle, offset: 0, count: 7), as: UTF8.self) == "payload")
        #expect(throws: HostFSError.readOnly) {
            _ = try fs.openReadWrite(nodeID: entry.nodeID)
        }
        #expect(throws: HostFSError.readOnly) {
            _ = try fs.createFile(parent: HostFS.rootNodeID, name: "new.txt")
        }
        #expect(throws: HostFSError.readOnly) {
            try fs.unlink(parent: HostFS.rootNodeID, name: "file.txt")
        }
    }
}

private final class TestHostFSRoot {
    let url: URL

    init() throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dory-hostfs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func write(_ text: String, to relativePath: String) throws {
        try text.write(to: url.appendingPathComponent(relativePath), atomically: true, encoding: .utf8)
    }
}
