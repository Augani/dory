import Darwin
import Foundation
import Testing
@testable import DoryHV

struct HostFSTests {
    @Test func statfsPreservesBlockCountsAboveDarwinStatvfs32BitLimit() {
        var status = Darwin.statfs()
        status.f_bsize = 4096
        status.f_blocks = UInt64(UInt32.max) + 4_194_304
        status.f_bfree = UInt64(UInt32.max) + 2_097_152
        status.f_bavail = UInt64(UInt32.max) + 1_048_576
        status.f_files = UInt64(UInt32.max) + 524_288
        status.f_ffree = UInt64(UInt32.max) + 262_144

        let translated = HostFS.hostFSStat(from: status)

        #expect(translated.blockSize == 4096)
        #expect(translated.blocks == status.f_blocks)
        #expect(translated.blocksFree == status.f_bfree)
        #expect(translated.blocksAvailable == status.f_bavail)
        #expect(translated.files == status.f_files)
        #expect(translated.filesFree == status.f_ffree)
        #expect(translated.blocks * translated.blockSize > 16 * 1024 * 1024 * 1024 * 1024)
    }

    @Test func inodeGenerationParticipatesInCanonicalIdentity() {
        let original = FileKey(
            device: 7,
            inode: 42,
            generation: 1
        )
        let recycled = FileKey(
            device: 7,
            inode: 42,
            generation: 2
        )
        let hardLinkAlias = FileKey(
            device: 7,
            inode: 42,
            generation: 1
        )
        let identityIndex = [original: UInt64(9)]

        #expect(original != recycled)
        #expect(identityIndex[recycled] == nil)
        #expect(identityIndex[hardLinkAlias] == 9)
    }

    @Test func identityPinClosesOnlyAfterReplacementNodeIsForgotten() throws {
        let root = try TestHostFSRoot()
        try root.write("old", to: "raced.txt")
        let file = root.url.appendingPathComponent("raced.txt")
        let replacement = Data("replacement".utf8)
        let closes = IdentityPinCloseRecorder()
        let fs = try HostFS(rootPath: root.url.path)
        fs.identityPinClosedTestHook = { nodeID, _ in closes.record(nodeID) }
        fs.identityPinPostOpenTestHook = { relativePath, _ in
            guard relativePath == "raced.txt" else { return }
            try! FileManager.default.removeItem(at: file)
            try! replacement.write(to: file)
        }

        let old = try fs.lookup(parent: HostFS.rootNodeID, name: "raced.txt")
        fs.identityPinPostOpenTestHook = nil
        fs.retainLookup(nodeID: old.nodeID)
        let pinnedOldKey = try #require(fs.identityFileKeyForTesting(nodeID: old.nodeID))
        let replacementKey = FileKey(try hostStatus(file))

        #expect(pinnedOldKey != replacementKey)

        let current = try fs.lookup(parent: HostFS.rootNodeID, name: "raced.txt")
        #expect(current.nodeID != old.nodeID)
        #expect(fs.identityFileKeyForTesting(nodeID: old.nodeID) == pinnedOldKey)
        #expect(!closes.contains(old.nodeID))

        fs.forgetLookup(nodeID: old.nodeID, count: 1)
        #expect(closes.contains(old.nodeID))
    }

    @Test func identityPinExhaustionFailsLookupWithoutRegisteringAWeakIdentity() throws {
        let root = try TestHostFSRoot()
        try root.write("payload", to: "limited.txt")
        let fs = try HostFS(rootPath: root.url.path)
        fs.identityPinOpenTestErrno = EMFILE

        #expect(throws: HostFSError.systemCall("pin identity limited.txt", EMFILE)) {
            _ = try fs.lookup(parent: HostFS.rootNodeID, name: "limited.txt")
        }
        #expect(throws: HostFSError.systemCall("pin identity created.txt", EMFILE)) {
            _ = try fs.createFileAndOpen(parent: HostFS.rootNodeID, name: "created.txt")
        }
        #expect(!FileManager.default.fileExists(atPath: root.url.appendingPathComponent("created.txt").path))

        fs.identityPinOpenTestErrno = nil
        let registered = try fs.lookup(parent: HostFS.rootNodeID, name: "limited.txt")
        let created = try fs.createFileAndOpen(parent: HostFS.rootNodeID, name: "created.txt")
        defer { fs.close(handle: created.fd) }
        #expect(registered.nodeID == 2)
        #expect(created.entry.nodeID == 3)
    }

    @Test func hostFSDeinitClosesRootAndRegisteredIdentityPins() throws {
        let root = try TestHostFSRoot()
        try root.write("payload", to: "live.txt")
        let closes = IdentityPinCloseRecorder()
        var hostFS: HostFS? = try HostFS(rootPath: root.url.path)
        hostFS?.identityPinClosedTestHook = { nodeID, _ in closes.record(nodeID) }
        let entry = try #require(try hostFS?.lookup(parent: HostFS.rootNodeID, name: "live.txt"))

        hostFS = nil

        #expect(closes.contains(HostFS.rootNodeID))
        #expect(closes.contains(entry.nodeID))
    }

    @Test func rootGetattrReturnsDirectoryAttributes() throws {
        let root = try TestHostFSRoot()
        let fs = try HostFS(rootPath: root.url.path)

        let attrs = try fs.getattr(nodeID: HostFS.rootNodeID)

        #expect(attrs.nodeID == HostFS.rootNodeID)
        #expect(attrs.isDirectory)
        #expect(attrs.uid == getuid())
        #expect(attrs.gid == getgid())
    }

    @Test func lookupGetattrAndReadUseHostIdentity() throws {
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
        #expect(attrs.uid == getuid())
        #expect(attrs.gid == getgid())
        #expect(String(decoding: try fs.read(handle: handle, offset: 6, count: 4), as: UTF8.self) == "dory")
    }

    @Test func repeatedLookupReusesMatchingPinnedIdentity() throws {
        let root = try TestHostFSRoot()
        try root.write("stable", to: "stable.txt")
        let fs = try HostFS(rootPath: root.url.path)
        let first = try fs.lookup(parent: HostFS.rootNodeID, name: "stable.txt")

        // A matching real identity must not need another descriptor. Synthetic creates and
        // replacements are covered separately and still take the full identity-pinning path.
        fs.identityPinOpenTestErrno = EMFILE
        let second = try fs.lookup(parent: HostFS.rootNodeID, name: "stable.txt")

        #expect(second.nodeID == first.nodeID)
        #expect(second.attributes.size == 6)
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

    @Test func directoryEventExpansionReturnsOnlyKnownImmediateBindings() throws {
        let root = try TestHostFSRoot()
        try FileManager.default.createDirectory(
            at: root.url.appendingPathComponent("project/nested"),
            withIntermediateDirectories: true
        )
        try root.write("top", to: "project/top.txt")
        try root.write("deep", to: "project/nested/deep.txt")
        let fs = try HostFS(rootPath: root.url.path)
        let project = try fs.lookup(parent: HostFS.rootNodeID, name: "project")
        _ = try fs.lookup(parent: project.nodeID, name: "top.txt")
        let nested = try fs.lookup(parent: project.nodeID, name: "nested")
        _ = try fs.lookup(parent: nested.nodeID, name: "deep.txt")

        let marker = "/\(root.url.lastPathComponent)/"
        let relative = fs.knownHostPaths(
            inHostDirectory: root.url.appendingPathComponent("project").path
        ).compactMap { path -> String? in
            guard let range = path.range(of: marker) else { return nil }
            return String(path[range.upperBound...])
        }
        #expect(relative == ["project", "project/nested", "project/top.txt"])
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

    @Test func rootHiddenNamesProtectHomeWithoutShadowingProjectLibraries() throws {
        let root = try TestHostFSRoot()
        try FileManager.default.createDirectory(
            at: root.url.appendingPathComponent("Library"),
            withIntermediateDirectories: false
        )
        try FileManager.default.createDirectory(
            at: root.url.appendingPathComponent("project/vendor/ezyang/htmlpurifier/library"),
            withIntermediateDirectories: true
        )
        try root.write("autoload", to: "project/vendor/ezyang/htmlpurifier/library/HTMLPurifier.composer.php")
        let fs = try HostFS(rootPath: root.url.path, rootHiddenNames: ["Library"])

        #expect(try fs.readdirplus(nodeID: HostFS.rootNodeID).map(\.name) == ["project"])
        #expect(throws: HostFSError.notFound("Library")) {
            _ = try fs.lookup(parent: HostFS.rootNodeID, name: "Library")
        }
        #expect(throws: HostFSError.notFound("library")) {
            _ = try fs.mkdir(parent: HostFS.rootNodeID, name: "library")
        }

        let project = try fs.lookup(parent: HostFS.rootNodeID, name: "project")
        let created = try fs.mkdir(parent: project.nodeID, name: "library")
        #expect(created.attributes.isDirectory)
        let vendor = try fs.lookup(parent: project.nodeID, name: "vendor")
        let ezyang = try fs.lookup(parent: vendor.nodeID, name: "ezyang")
        let purifier = try fs.lookup(parent: ezyang.nodeID, name: "htmlpurifier")
        let library = try fs.lookup(parent: purifier.nodeID, name: "library")
        let composer = try fs.lookup(parent: library.nodeID, name: "HTMLPurifier.composer.php")
        #expect(composer.attributes.isRegularFile)
    }

    @Test func hiddenNamesCannotBeBypassedWithCaseVariants() throws {
        let root = try TestHostFSRoot()
        try FileManager.default.createDirectory(
            at: root.url.appendingPathComponent(".SSH"),
            withIntermediateDirectories: false
        )
        try root.write("PRIVATE KEY", to: ".SSH/id_rsa")
        let fs = try HostFS(rootPath: root.url.path, hiddenNames: [".ssh"])

        #expect(try fs.readdirplus(nodeID: HostFS.rootNodeID).isEmpty)
        #expect(throws: HostFSError.notFound(".SSH")) {
            _ = try fs.lookup(parent: HostFS.rootNodeID, name: ".SSH")
        }
        #expect(throws: HostFSError.notFound(".SsH")) {
            _ = try fs.mkdir(parent: HostFS.rootNodeID, name: ".SsH")
        }
        #expect(fs.invalidationSnapshot(forHostPath: root.realPath + "/.SSH") == nil)
        #expect(FileManager.default.fileExists(atPath: root.url.appendingPathComponent(".SSH/id_rsa").path))
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

    @Test func invalidationSnapshotReportsOnlyAlreadyKnownExactPaths() throws {
        let root = try TestHostFSRoot()
        try FileManager.default.createDirectory(
            at: root.url.appendingPathComponent("Sources"),
            withIntermediateDirectories: false
        )
        try root.write("known", to: "Sources/App.swift")
        try root.write("not looked up", to: "Sources/Unseen.swift")
        let fs = try HostFS(rootPath: root.url.path)
        let sources = try fs.lookup(parent: HostFS.rootNodeID, name: "Sources")
        let app = try fs.lookup(parent: sources.nodeID, name: "App.swift")

        #expect(
            fs.invalidationSnapshot(forHostPath: root.realPath + "/Sources/App.swift")
                == HostFSInvalidationSnapshot(
                    nodeIDs: [app.nodeID],
                    parentNodeIDs: [sources.nodeID],
                    entryName: "App.swift"
                )
        )
        #expect(
            fs.invalidationSnapshot(forHostPath: root.realPath + "/Sources/Unseen.swift")
                == HostFSInvalidationSnapshot(
                    nodeIDs: [],
                    parentNodeIDs: [sources.nodeID],
                    entryName: "Unseen.swift"
                )
        )
        #expect(
            fs.invalidationSnapshot(forHostPath: root.realPath)
                == HostFSInvalidationSnapshot(
                    nodeIDs: [HostFS.rootNodeID],
                    parentNodeIDs: [],
                    entryName: nil
                )
        )

        // Taking the snapshot must not acquire a lookup reference: the ordinary unlink can retire
        // this otherwise-unreferenced node immediately.
        try fs.unlink(parent: sources.nodeID, name: "App.swift")
        #expect(throws: HostFSError.notFound("node \(app.nodeID)")) {
            _ = try fs.cachedAttributes(nodeID: app.nodeID)
        }
    }

    @Test func invalidationSnapshotIncludesRetainedReplacementIdentities() throws {
        let root = try TestHostFSRoot()
        try root.write("old", to: "watched.txt")
        let fs = try HostFS(rootPath: root.url.path)
        let old = try fs.lookup(parent: HostFS.rootNodeID, name: "watched.txt")
        fs.retainLookup(nodeID: old.nodeID)

        let path = root.url.appendingPathComponent("watched.txt")
        try FileManager.default.removeItem(at: path)
        try root.write("replacement", to: "watched.txt")
        #expect(try fs.getattr(nodeID: old.nodeID).size == 3)
        #expect(try fs.getattr(nodeID: old.nodeID).linkCount == 0)
        let replacement = try fs.lookup(parent: HostFS.rootNodeID, name: "watched.txt")

        #expect(
            fs.invalidationSnapshot(forHostPath: root.realPath + "/watched.txt")
                == HostFSInvalidationSnapshot(
                    nodeIDs: [old.nodeID, replacement.nodeID].sorted(),
                    staleNodeIDs: [old.nodeID],
                    parentNodeIDs: [HostFS.rootNodeID],
                    entryName: "watched.txt"
                )
        )

        fs.forgetLookup(nodeID: old.nodeID, count: 1)
        #expect(
            fs.invalidationSnapshot(forHostPath: root.realPath + "/watched.txt")?.nodeIDs
                == [replacement.nodeID]
        )
    }

    @Test func invalidationSnapshotDetectsReplacementBeforeGuestReconcilesOldNode() throws {
        let root = try TestHostFSRoot()
        try root.write("old", to: "watched.txt")
        let fs = try HostFS(rootPath: root.url.path)
        let old = try fs.lookup(parent: HostFS.rootNodeID, name: "watched.txt")
        fs.retainLookup(nodeID: old.nodeID)

        let path = root.url.appendingPathComponent("watched.txt")
        try FileManager.default.removeItem(at: path)
        try root.write("replacement", to: "watched.txt")

        #expect(
            fs.invalidationSnapshot(forHostPath: root.realPath + "/watched.txt")
                == HostFSInvalidationSnapshot(
                    nodeIDs: [old.nodeID],
                    staleNodeIDs: [old.nodeID],
                    parentNodeIDs: [HostFS.rootNodeID],
                    entryName: "watched.txt"
                )
        )
    }

    @Test func hostInvalidationTombstonesAtomicReplacementWithAuthoritativeZeroLinkCount() throws {
        let root = try TestHostFSRoot()
        try root.write("old", to: "watched.txt")
        let fs = try HostFS(rootPath: root.url.path)
        let old = try fs.lookup(parent: HostFS.rootNodeID, name: "watched.txt")
        fs.retainLookup(nodeID: old.nodeID)
        let oldFD = try fs.openRead(nodeID: old.nodeID)
        try fs.retainOpenHandle(nodeID: old.nodeID)
        defer {
            fs.forgetLookup(nodeID: old.nodeID, count: 1)
            fs.close(handle: oldFD)
            fs.releaseOpenHandle(nodeID: old.nodeID)
        }

        // Match the live mmap probe: fstat the open handle before the host replacement. This
        // publishes nlink=1 from a handle and marks the cache as potentially post-unlink, which
        // previously caused later detachment to preserve the stale count forever.
        #expect(try fs.getattr(nodeID: old.nodeID, handle: oldFD).linkCount == 1)
        try root.write("replacement", to: "watched.txt")

        // Exercise the opposite delivery order too: the guest can resolve the replacement before
        // FSEvents reaches the coordinator. The old identity is already a tombstone by the time
        // reconciliation runs, and must still converge to nlink=0.
        let replacement = try fs.lookup(parent: HostFS.rootNodeID, name: "watched.txt")
        #expect(replacement.nodeID != old.nodeID)
        #expect(replacement.attributes.linkCount == 1)

        let path = root.realPath + "/watched.txt"
        let snapshot = try #require(fs.invalidationSnapshot(forHostPath: path))
        #expect(snapshot.staleNodeIDs == [old.nodeID])
        fs.reconcileHostInvalidation(forHostPath: path, staleNodeIDs: snapshot.staleNodeIDs)

        #expect(try fs.cachedAttributes(nodeID: old.nodeID).linkCount == 0)
        #expect(try fs.getattr(nodeID: old.nodeID).linkCount == 0)
        #expect(try fs.getattr(nodeID: old.nodeID, handle: oldFD).linkCount == 0)
        #expect(String(decoding: try fs.read(handle: oldFD, offset: 0, count: 32), as: UTF8.self) == "old")
    }

    @Test func hostInvalidationRetainsPinnedCountForUnseenSurvivingHardLink() throws {
        let root = try TestHostFSRoot()
        try root.write("shared", to: "known.txt")
        try FileManager.default.linkItem(
            at: root.url.appendingPathComponent("known.txt"),
            to: root.url.appendingPathComponent("unseen.txt")
        )
        let fs = try HostFS(rootPath: root.url.path)
        let known = try fs.lookup(parent: HostFS.rootNodeID, name: "known.txt")
        fs.retainLookup(nodeID: known.nodeID)
        let fd = try fs.openRead(nodeID: known.nodeID)
        try fs.retainOpenHandle(nodeID: known.nodeID)
        defer {
            fs.forgetLookup(nodeID: known.nodeID, count: 1)
            fs.close(handle: fd)
            fs.releaseOpenHandle(nodeID: known.nodeID)
        }

        #expect(try fs.getattr(nodeID: known.nodeID, handle: fd).linkCount == 2)
        try FileManager.default.removeItem(at: root.url.appendingPathComponent("known.txt"))
        // A handle fstat can publish the real post-unlink count before the event snapshot. The
        // snapshot must use the pinned inode's current nlink rather than assuming a cached count of
        // one means this was a final unlink.
        #expect(try fs.getattr(nodeID: known.nodeID, handle: fd).linkCount == 1)
        let path = root.realPath + "/known.txt"
        let snapshot = try #require(fs.invalidationSnapshot(forHostPath: path))
        #expect(snapshot.staleNodeIDs == [known.nodeID])
        #expect(snapshot.survivingLinkNodeIDs == [known.nodeID])

        fs.reconcileHostInvalidation(forHostPath: path, staleNodeIDs: snapshot.staleNodeIDs)

        #expect(try fs.cachedAttributes(nodeID: known.nodeID).linkCount == 1)
        let unseen = try fs.lookup(parent: HostFS.rootNodeID, name: "unseen.txt")
        #expect(unseen.nodeID == known.nodeID)
        #expect(unseen.attributes.linkCount == 1)
    }

    @Test func invalidationSnapshotSeparatesUnverifiedFastCreateIdentity() throws {
        let root = try TestHostFSRoot()
        let fs = try HostFS(rootPath: root.url.path)
        let created = try fs.createFileAndOpen(
            parent: HostFS.rootNodeID,
            name: "fast.txt",
            syntheticAttributes: true
        )
        defer { fs.close(handle: created.fd) }

        #expect(
            fs.invalidationSnapshot(forHostPath: root.realPath + "/fast.txt")
                == HostFSInvalidationSnapshot(
                    nodeIDs: [created.entry.nodeID],
                    unverifiedNodeIDs: [created.entry.nodeID],
                    parentNodeIDs: [HostFS.rootNodeID],
                    entryName: "fast.txt"
                )
        )
    }

    @Test func hardLinkAliasesShareOneNodeIdentityAndRealLinkCount() throws {
        let root = try TestHostFSRoot()
        try root.write("shared inode", to: "a.txt")
        try FileManager.default.linkItem(
            at: root.url.appendingPathComponent("a.txt"),
            to: root.url.appendingPathComponent("b.txt")
        )
        let fs = try HostFS(rootPath: root.url.path)
        let first = try fs.lookup(parent: HostFS.rootNodeID, name: "a.txt")
        let second = try fs.lookup(parent: HostFS.rootNodeID, name: "b.txt")

        #expect(first.nodeID == second.nodeID)
        #expect(first.attributes.linkCount == 2)
        #expect(second.attributes.linkCount == 2)
        let aliases = fs.knownIdentityAliasHostPaths(forHostPath: root.realPath + "/a.txt")
        #expect(Set(aliases.map { URL(fileURLWithPath: $0).lastPathComponent }) == ["a.txt", "b.txt"])

        #expect(
            fs.invalidationSnapshot(forHostPath: root.realPath + "/a.txt")
                == HostFSInvalidationSnapshot(
                    nodeIDs: [first.nodeID],
                    parentNodeIDs: [HostFS.rootNodeID],
                    entryName: "a.txt"
                )
        )
        #expect(
            fs.invalidationSnapshot(forHostPath: root.realPath + "/b.txt")
                == HostFSInvalidationSnapshot(
                    nodeIDs: [first.nodeID],
                    parentNodeIDs: [HostFS.rootNodeID],
                    entryName: "b.txt"
                )
        )
    }

    @Test func virtualOwnershipFollowsHardLinksAndResetsForHostReplacement() throws {
        let root = try TestHostFSRoot()
        try root.write("original", to: "owned.txt")
        let fs = try HostFS(rootPath: root.url.path, guestUID: 1_000, guestGID: 1_000)
        let original = try fs.lookup(parent: HostFS.rootNodeID, name: "owned.txt")

        let changed = try fs.applySetattr(
            nodeID: original.nodeID,
            request: HostFSSetattrRequest(uid: 999, gid: 998)
        )
        #expect(changed.uid == 999)
        #expect(changed.gid == 998)

        let alias = try fs.link(
            nodeID: original.nodeID,
            newParent: HostFS.rootNodeID,
            name: "alias.txt"
        )
        #expect(alias.nodeID == original.nodeID)
        #expect(alias.attributes.uid == 999)
        #expect(alias.attributes.gid == 998)
        #expect(try fs.getattr(nodeID: original.nodeID).uid == 999)

        try root.write("replacement", to: "owned.txt")
        let replacement = try fs.lookup(parent: HostFS.rootNodeID, name: "owned.txt")
        #expect(replacement.nodeID != original.nodeID)
        #expect(replacement.attributes.uid == 1_000)
        #expect(replacement.attributes.gid == 1_000)
        #expect(try fs.getattr(nodeID: original.nodeID).uid == 999)
    }

    @Test func createdEntriesUseTheRequestingContainerOwner() throws {
        let root = try TestHostFSRoot()
        let fs = try HostFS(rootPath: root.url.path)

        let directory = try fs.mkdir(
            parent: HostFS.rootNodeID,
            name: "cache",
            ownerUID: 1_000,
            ownerGID: 1_001
        )
        let file = try fs.createFile(
            parent: directory.nodeID,
            name: "entry.bin",
            ownerUID: 1_000,
            ownerGID: 1_001
        )
        let link = try fs.symlink(
            parent: directory.nodeID,
            name: "entry-link",
            target: "entry.bin",
            ownerUID: 1_000,
            ownerGID: 1_001
        )

        for entry in [directory, file, link] {
            #expect(entry.attributes.uid == 1_000)
            #expect(entry.attributes.gid == 1_001)
            #expect(try fs.getattr(nodeID: entry.nodeID).uid == 1_000)
            #expect(try fs.getattr(nodeID: entry.nodeID).gid == 1_001)
        }
    }

    @Test func unlinkingOneHardLinkKeepsCanonicalNodeAliveThroughItsOtherBinding() throws {
        let root = try TestHostFSRoot()
        try root.write("shared inode", to: "a.txt")
        try FileManager.default.linkItem(
            at: root.url.appendingPathComponent("a.txt"),
            to: root.url.appendingPathComponent("b.txt")
        )
        let fs = try HostFS(rootPath: root.url.path)
        let first = try fs.lookup(parent: HostFS.rootNodeID, name: "a.txt")
        let second = try fs.lookup(parent: HostFS.rootNodeID, name: "b.txt")

        try fs.unlink(parent: HostFS.rootNodeID, name: "a.txt")

        #expect(try fs.lookupIfExists(parent: HostFS.rootNodeID, name: "a.txt") == nil)
        let survivor = try fs.lookup(parent: HostFS.rootNodeID, name: "b.txt")
        #expect(survivor.nodeID == first.nodeID)
        #expect(survivor.nodeID == second.nodeID)
        #expect(try fs.getattr(nodeID: survivor.nodeID).linkCount == 1)
        let fd = try fs.openRead(nodeID: survivor.nodeID)
        defer { fs.close(handle: fd) }
        #expect(String(decoding: try fs.read(handle: fd, offset: 0, count: 12), as: UTF8.self) == "shared inode")
    }

    @Test func unseenHardLinkAliasReusesPinnedCanonicalIdentityAfterKnownNameDisappears() throws {
        let root = try TestHostFSRoot()
        try root.write("shared inode", to: "a.txt")
        try FileManager.default.linkItem(
            at: root.url.appendingPathComponent("a.txt"),
            to: root.url.appendingPathComponent("b.txt")
        )
        let fs = try HostFS(rootPath: root.url.path)
        let known = try fs.lookup(parent: HostFS.rootNodeID, name: "a.txt")
        fs.retainLookup(nodeID: known.nodeID)

        try FileManager.default.removeItem(at: root.url.appendingPathComponent("a.txt"))
        #expect(
            fs.invalidationSnapshot(forHostPath: root.realPath + "/a.txt")
                == HostFSInvalidationSnapshot(
                    nodeIDs: [known.nodeID],
                    staleNodeIDs: [known.nodeID],
                    survivingLinkNodeIDs: [known.nodeID],
                    parentNodeIDs: [HostFS.rootNodeID],
                    entryName: "a.txt"
                )
        )
        #expect(try fs.getattr(nodeID: known.nodeID).linkCount == 1)

        let discovered = try fs.lookup(parent: HostFS.rootNodeID, name: "b.txt")
        #expect(discovered.nodeID == known.nodeID)
        #expect(discovered.attributes.linkCount == 1)
    }

    @Test func postUnlinkHandleGetattrCannotDoubleDecrementUnseenAliasLinkCount() throws {
        let root = try TestHostFSRoot()
        try root.write("shared inode", to: "a.txt")
        try FileManager.default.linkItem(
            at: root.url.appendingPathComponent("a.txt"),
            to: root.url.appendingPathComponent("b.txt")
        )
        let fs = try HostFS(rootPath: root.url.path)
        let known = try fs.lookup(parent: HostFS.rootNodeID, name: "a.txt")
        fs.retainLookup(nodeID: known.nodeID)
        let fd = try fs.openRead(nodeID: known.nodeID)
        try fs.retainOpenHandle(nodeID: known.nodeID)
        fs.unlinkPostHostMutationTestHook = {
            // Runs after unlinkat has reduced host nlink to one but before HostFS detaches a.txt.
            // The handle refresh must not make the subsequent detach decrement that count again.
            _ = try? fs.getattr(nodeID: known.nodeID, handle: fd)
        }

        try fs.unlink(parent: HostFS.rootNodeID, name: "a.txt")
        fs.unlinkPostHostMutationTestHook = nil

        #expect(try fs.cachedAttributes(nodeID: known.nodeID).linkCount == 1)
        let discovered = try fs.lookup(parent: HostFS.rootNodeID, name: "b.txt")
        #expect(discovered.nodeID == known.nodeID)
        #expect(discovered.attributes.linkCount == 1)

        fs.forgetLookup(nodeID: known.nodeID, count: 1)
        fs.close(handle: fd)
        fs.releaseOpenHandle(nodeID: known.nodeID)
    }

    @Test func openHardLinkHandleSurvivesAliasAndFinalNameUnlink() throws {
        let root = try TestHostFSRoot()
        try root.write("shared inode", to: "a.txt")
        try FileManager.default.linkItem(
            at: root.url.appendingPathComponent("a.txt"),
            to: root.url.appendingPathComponent("b.txt")
        )
        let fs = try HostFS(rootPath: root.url.path)
        let first = try fs.lookup(parent: HostFS.rootNodeID, name: "a.txt")
        let second = try fs.lookup(parent: HostFS.rootNodeID, name: "b.txt")
        #expect(first.nodeID == second.nodeID)
        fs.retainLookup(nodeID: first.nodeID, count: 2)
        let fd = try fs.openRead(nodeID: first.nodeID)
        try fs.retainOpenHandle(nodeID: first.nodeID)

        try fs.unlink(parent: HostFS.rootNodeID, name: "a.txt")
        #expect(String(decoding: try fs.read(handle: fd, offset: 0, count: 12), as: UTF8.self) == "shared inode")
        #expect(try hostStatus(root.url.appendingPathComponent("b.txt")).st_nlink == 1)
        try fs.unlink(parent: HostFS.rootNodeID, name: "b.txt")
        #expect(try fs.getattr(nodeID: first.nodeID, handle: fd).linkCount == 0)
        #expect(String(decoding: try fs.read(handle: fd, offset: 0, count: 12), as: UTF8.self) == "shared inode")
        var unlinkedStatus = stat()
        #expect(fstat(fd, &unlinkedStatus) == 0)
        #expect(unlinkedStatus.st_nlink == 0)

        fs.forgetLookup(nodeID: first.nodeID, count: 2)
        #expect(try fs.cachedAttributes(nodeID: first.nodeID).linkCount == 0)
        fs.close(handle: fd)
        fs.releaseOpenHandle(nodeID: first.nodeID)
        #expect(throws: HostFSError.notFound("node \(first.nodeID)")) {
            _ = try fs.cachedAttributes(nodeID: first.nodeID)
        }
    }

    @Test func replacingOneHardLinkAliasTombstonesOnlyThatBinding() throws {
        let root = try TestHostFSRoot()
        try root.write("old", to: "a.txt")
        try FileManager.default.linkItem(
            at: root.url.appendingPathComponent("a.txt"),
            to: root.url.appendingPathComponent("b.txt")
        )
        let fs = try HostFS(rootPath: root.url.path)
        let old = try fs.lookup(parent: HostFS.rootNodeID, name: "a.txt")
        #expect(try fs.lookup(parent: HostFS.rootNodeID, name: "b.txt").nodeID == old.nodeID)
        fs.retainLookup(nodeID: old.nodeID, count: 2)

        try root.write("replacement", to: "a.txt")
        let replacement = try fs.lookup(parent: HostFS.rootNodeID, name: "a.txt")
        let survivingAlias = try fs.lookup(parent: HostFS.rootNodeID, name: "b.txt")

        #expect(replacement.nodeID != old.nodeID)
        #expect(survivingAlias.nodeID == old.nodeID)
        #expect(try fs.getattr(nodeID: old.nodeID).linkCount == 1)
        #expect(try fs.getattr(nodeID: replacement.nodeID).linkCount == 1)
        #expect(
            fs.invalidationSnapshot(forHostPath: root.realPath + "/a.txt")
                == HostFSInvalidationSnapshot(
                    nodeIDs: [old.nodeID, replacement.nodeID].sorted(),
                    staleNodeIDs: [old.nodeID],
                    survivingLinkNodeIDs: [old.nodeID],
                    parentNodeIDs: [HostFS.rootNodeID],
                    entryName: "a.txt"
                )
        )
        #expect(
            fs.invalidationSnapshot(forHostPath: root.realPath + "/b.txt")
                == HostFSInvalidationSnapshot(
                    nodeIDs: [old.nodeID],
                    parentNodeIDs: [HostFS.rootNodeID],
                    entryName: "b.txt"
                )
        )
        let aliases = fs.knownIdentityAliasHostPaths(forHostPath: root.realPath + "/a.txt")
        #expect(Set(aliases.map { URL(fileURLWithPath: $0).lastPathComponent }) == ["a.txt", "b.txt"])
    }

    @Test func renamingOneHardLinkBindingPreservesTheSharedNode() throws {
        let root = try TestHostFSRoot()
        try root.write("shared inode", to: "a.txt")
        try FileManager.default.linkItem(
            at: root.url.appendingPathComponent("a.txt"),
            to: root.url.appendingPathComponent("b.txt")
        )
        let fs = try HostFS(rootPath: root.url.path)
        let shared = try fs.lookup(parent: HostFS.rootNodeID, name: "a.txt")
        #expect(try fs.lookup(parent: HostFS.rootNodeID, name: "b.txt").nodeID == shared.nodeID)

        let renamed = try fs.rename(
            parent: HostFS.rootNodeID,
            name: "a.txt",
            newParent: HostFS.rootNodeID,
            newName: "c.txt"
        )

        #expect(renamed.nodeID == shared.nodeID)
        #expect(try fs.lookup(parent: HostFS.rootNodeID, name: "b.txt").nodeID == shared.nodeID)
        #expect(try fs.lookup(parent: HostFS.rootNodeID, name: "c.txt").nodeID == shared.nodeID)
        #expect(try fs.getattr(nodeID: shared.nodeID).linkCount == 2)
    }

    @Test func namespaceReconciliationFindsCachedRenameSourceWhenOnlyDestinationIsReported() throws {
        let root = try TestHostFSRoot()
        try root.write("source", to: "rename-source.txt")
        let fs = try HostFS(rootPath: root.url.path)
        let source = try fs.lookup(parent: HostFS.rootNodeID, name: "rename-source.txt")
        fs.retainLookup(nodeID: source.nodeID)

        try FileManager.default.moveItem(
            at: root.url.appendingPathComponent("rename-source.txt"),
            to: root.url.appendingPathComponent("rename-destination.txt")
        )

        let stale = fs.knownStaleHostPathsForNamespaceReconciliation()
        #expect(stale.map { URL(fileURLWithPath: $0).lastPathComponent } == ["rename-source.txt"])
    }

    @Test func renameOverwriteDetachesOnlyTheDestinationHardLinkBinding() throws {
        let root = try TestHostFSRoot()
        try root.write("source", to: "source.txt")
        try root.write("destination", to: "destination.txt")
        try FileManager.default.linkItem(
            at: root.url.appendingPathComponent("destination.txt"),
            to: root.url.appendingPathComponent("destination-alias.txt")
        )
        let fs = try HostFS(rootPath: root.url.path)
        let source = try fs.lookup(parent: HostFS.rootNodeID, name: "source.txt")
        let overwritten = try fs.lookup(parent: HostFS.rootNodeID, name: "destination.txt")
        #expect(
            try fs.lookup(parent: HostFS.rootNodeID, name: "destination-alias.txt").nodeID
                == overwritten.nodeID
        )

        let moved = try fs.rename(
            parent: HostFS.rootNodeID,
            name: "source.txt",
            newParent: HostFS.rootNodeID,
            newName: "destination.txt"
        )

        #expect(moved.nodeID == source.nodeID)
        #expect(try fs.lookup(parent: HostFS.rootNodeID, name: "destination.txt").nodeID == source.nodeID)
        #expect(
            try fs.lookup(parent: HostFS.rootNodeID, name: "destination-alias.txt").nodeID
                == overwritten.nodeID
        )
        #expect(try fs.getattr(nodeID: overwritten.nodeID).linkCount == 1)
        let fd = try fs.openRead(nodeID: overwritten.nodeID)
        defer { fs.close(handle: fd) }
        #expect(String(decoding: try fs.read(handle: fd, offset: 0, count: 11), as: UTF8.self) == "destination")
    }

    @Test func guestHardLinkCreationUsesCanonicalIdentityAndUpdatesLinkCount() throws {
        let root = try TestHostFSRoot()
        try root.write("payload", to: "source.txt")
        let fs = try HostFS(rootPath: root.url.path)
        let source = try fs.lookup(parent: HostFS.rootNodeID, name: "source.txt")

        let linked = try fs.link(
            nodeID: source.nodeID,
            newParent: HostFS.rootNodeID,
            name: "linked.txt"
        )

        #expect(linked.nodeID == source.nodeID)
        #expect(linked.attributes.linkCount == 2)
        #expect(try fs.lookup(parent: HostFS.rootNodeID, name: "source.txt").nodeID == source.nodeID)
        #expect(try fs.lookup(parent: HostFS.rootNodeID, name: "linked.txt").nodeID == source.nodeID)
        #expect(try fs.getattr(nodeID: source.nodeID).linkCount == 2)
        let sourceStatus = try hostStatus(root.url.appendingPathComponent("source.txt"))
        let linkedStatus = try hostStatus(root.url.appendingPathComponent("linked.txt"))
        #expect(sourceStatus.st_ino == linkedStatus.st_ino)
        #expect(sourceStatus.st_nlink == 2)
    }

    @Test func racedHardLinkDestinationReplacementIsNeverDeletedDuringVerification() throws {
        let root = try TestHostFSRoot()
        try root.write("source payload", to: "source.txt")
        let fs = try HostFS(rootPath: root.url.path)
        let source = try fs.lookup(parent: HostFS.rootNodeID, name: "source.txt")
        let linkedURL = root.url.appendingPathComponent("linked.txt")
        fs.linkPostHostMutationTestHook = {
            // Foundation's atomic write replaces the just-created hard-link dentry with a distinct
            // inode before HostFS performs its post-link identity verification.
            try? "unrelated host replacement".write(
                to: linkedURL,
                atomically: true,
                encoding: .utf8
            )
        }

        #expect(throws: HostFSError.staleIdentity(source.nodeID)) {
            _ = try fs.link(
                nodeID: source.nodeID,
                newParent: HostFS.rootNodeID,
                name: "linked.txt"
            )
        }
        fs.linkPostHostMutationTestHook = nil

        #expect(
            try String(
                contentsOf: linkedURL,
                encoding: .utf8
            ) == "unrelated host replacement"
        )
        #expect(
            try String(
                contentsOf: root.url.appendingPathComponent("source.txt"),
                encoding: .utf8
            ) == "source payload"
        )
        #expect(try fs.getattr(nodeID: source.nodeID).linkCount == 1)
    }

    @Test func invalidationSnapshotIncludesRetainedReplacementParents() throws {
        let root = try TestHostFSRoot()
        try FileManager.default.createDirectory(
            at: root.url.appendingPathComponent("Sources"),
            withIntermediateDirectories: false
        )
        let fs = try HostFS(rootPath: root.url.path)
        let oldParent = try fs.lookup(parent: HostFS.rootNodeID, name: "Sources")
        fs.retainLookup(nodeID: oldParent.nodeID)

        try FileManager.default.moveItem(
            at: root.url.appendingPathComponent("Sources"),
            to: root.url.appendingPathComponent("Sources-old")
        )
        try FileManager.default.createDirectory(
            at: root.url.appendingPathComponent("Sources"),
            withIntermediateDirectories: false
        )
        #expect(try fs.getattr(nodeID: oldParent.nodeID).isDirectory)
        let replacementParent = try fs.lookup(parent: HostFS.rootNodeID, name: "Sources")

        #expect(
            fs.invalidationSnapshot(forHostPath: root.realPath + "/Sources/New.swift")
                == HostFSInvalidationSnapshot(
                    nodeIDs: [],
                    parentNodeIDs: [oldParent.nodeID, replacementParent.nodeID].sorted(),
                    entryName: "New.swift"
                )
        )
    }

    @Test func invalidationSnapshotRejectsOutsideRelativeNulAndHiddenPaths() throws {
        let root = try TestHostFSRoot()
        try root.write("visible", to: "visible.txt")
        let fs = try HostFS(rootPath: root.url.path, hiddenNames: [".secret"])
        let visible = try fs.lookup(parent: HostFS.rootNodeID, name: "visible.txt")
        let outside = root.url.deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString)/file.txt").path

        #expect(fs.invalidationSnapshot(forHostPath: outside) == nil)
        #expect(fs.invalidationSnapshot(forHostPath: "relative/file.txt") == nil)
        #expect(fs.invalidationSnapshot(forHostPath: root.realPath + "/bad\0name") == nil)
        #expect(fs.invalidationSnapshot(forHostPath: root.realPath + "/.secret/key") == nil)
        #expect(fs.invalidationSnapshot(forHostPath: root.realPath + "/nested/.secret") == nil)

        #expect(
            fs.invalidationSnapshot(forHostPath: root.realPath + "/nested/../visible.txt")
                == HostFSInvalidationSnapshot(
                    nodeIDs: [visible.nodeID],
                    parentNodeIDs: [HostFS.rootNodeID],
                    entryName: "visible.txt"
                )
        )
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

    @Test func movedParentSymlinkSwapCannotEscapeShareBeforeHostInvalidation() throws {
        let root = try TestHostFSRoot()
        let knownURL = root.url.appendingPathComponent("known", isDirectory: true)
        try FileManager.default.createDirectory(at: knownURL, withIntermediateDirectories: false)
        try root.write("outside payload", to: "known/payload.txt")
        try root.write("rename source", to: "source.txt")
        try FileManager.default.createDirectory(
            at: knownURL.appendingPathComponent("empty", isDirectory: true),
            withIntermediateDirectories: false
        )
        try FileManager.default.createSymbolicLink(
            at: knownURL.appendingPathComponent("target-link"),
            withDestinationURL: URL(fileURLWithPath: "payload.txt")
        )

        let fs = try HostFS(rootPath: root.url.path)
        let known = try fs.lookup(parent: HostFS.rootNodeID, name: "known")
        let payload = try fs.lookup(parent: known.nodeID, name: "payload.txt")
        let targetLink = try fs.lookup(parent: known.nodeID, name: "target-link")
        let source = try fs.lookup(parent: HostFS.rootNodeID, name: "source.txt")
        _ = try fs.readdirplus(nodeID: known.nodeID)

        let outsideRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dory-hostfs-outside-\(UUID().uuidString)", isDirectory: true)
        let movedURL = outsideRoot.appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outsideRoot) }
        try FileManager.default.moveItem(at: knownURL, to: movedURL)
        try FileManager.default.createSymbolicLink(at: knownURL, withDestinationURL: movedURL)

        // Every call below occurs before an FSEvents invalidation has reconciled the cached nodes.
        #expect(throws: HostFSError.self) { _ = try fs.getattr(nodeID: payload.nodeID) }
        #expect(throws: HostFSError.self) { _ = try fs.openRead(nodeID: payload.nodeID) }
        #expect(throws: HostFSError.self) { _ = try fs.openReadWrite(nodeID: payload.nodeID) }
        #expect(throws: HostFSError.self) { try fs.truncate(nodeID: payload.nodeID, size: 0) }
        #expect(throws: HostFSError.self) {
            _ = try fs.createFile(parent: known.nodeID, name: "created.txt")
        }
        #expect(throws: HostFSError.self) {
            _ = try fs.mkdir(parent: known.nodeID, name: "created-directory")
        }
        #expect(throws: HostFSError.self) {
            _ = try fs.symlink(parent: known.nodeID, name: "created-link", target: "payload.txt")
        }
        #expect(throws: HostFSError.self) {
            _ = try fs.link(nodeID: source.nodeID, newParent: known.nodeID, name: "linked.txt")
        }
        #expect(throws: HostFSError.self) {
            _ = try fs.rename(
                parent: HostFS.rootNodeID,
                name: "source.txt",
                newParent: known.nodeID,
                newName: "renamed.txt"
            )
        }
        #expect(throws: HostFSError.self) {
            _ = try fs.rename(
                parent: known.nodeID,
                name: "payload.txt",
                newParent: HostFS.rootNodeID,
                newName: "escaped.txt"
            )
        }
        #expect(throws: HostFSError.self) {
            _ = try fs.link(
                nodeID: payload.nodeID,
                newParent: HostFS.rootNodeID,
                name: "escaped-link.txt"
            )
        }
        #expect(throws: HostFSError.self) {
            try fs.unlink(parent: known.nodeID, name: "payload.txt")
        }
        #expect(throws: HostFSError.self) {
            try fs.rmdir(parent: known.nodeID, name: "empty")
        }
        #expect(throws: HostFSError.self) { _ = try fs.readlink(nodeID: targetLink.nodeID) }
        // Keep this last: a failed directory open intentionally detaches the cached parent and its
        // descendants, while every mutation above must reach its contained kernel operation.
        #expect(throws: HostFSError.self) { _ = try fs.readdirplus(nodeID: known.nodeID) }

        #expect(
            try String(contentsOf: movedURL.appendingPathComponent("payload.txt"), encoding: .utf8)
                == "outside payload"
        )
        #expect(
            try String(
                contentsOf: root.url.appendingPathComponent("source.txt"),
                encoding: .utf8
            ) == "rename source"
        )
        for name in [
            "created.txt", "created-directory", "created-link", "linked.txt", "renamed.txt",
        ] {
            #expect(!FileManager.default.fileExists(atPath: movedURL.appendingPathComponent(name).path))
        }
        #expect(!FileManager.default.fileExists(atPath: root.url.appendingPathComponent("escaped.txt").path))
        #expect(!FileManager.default.fileExists(atPath: root.url.appendingPathComponent("escaped-link.txt").path))
        let rootNames = try FileManager.default.contentsOfDirectory(atPath: root.url.path)
        #expect(!rootNames.contains { $0.hasPrefix(".dory-hostfs-stage-") })
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

    @Test func fifoLookupDoesNotBlockAndIsRejectedBeforeGuestVFSOpen() throws {
        let root = try TestHostFSRoot()
        let fifoPath = root.url.appendingPathComponent("host-fifo").path
        #expect(mkfifo(fifoPath, 0o600) == 0)
        let fs = try HostFS(rootPath: root.url.path)

        #expect(throws: HostFSError.operationNotSupported("special host file: host-fifo")) {
            _ = try fs.lookup(parent: HostFS.rootNodeID, name: "host-fifo")
        }
        #expect(try fs.readdirplus(nodeID: HostFS.rootNodeID).isEmpty)
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

    @Test func createCanPinBroaderIdentityThanItsLogicalWriteOnlyHandle() throws {
        let root = try TestHostFSRoot()
        let fs = try HostFS(rootPath: root.url.path)
        let created = try fs.createFileAndOpen(
            parent: HostFS.rootNodeID,
            name: "generated.txt",
            accessMode: .writeOnly,
            preferredIdentityAccessMode: .readWrite
        )
        defer { fs.close(handle: created.fd) }
        #expect(try fs.write(handle: created.fd, offset: 0, data: Array("old".utf8)) == 3)

        try root.write("replacement", to: "generated.txt")
        let oldRead = try fs.openRead(nodeID: created.entry.nodeID)
        defer { fs.close(handle: oldRead) }

        #expect(String(decoding: try fs.read(handle: oldRead, offset: 0, count: 32), as: UTF8.self) == "old")
        #expect(try String(contentsOf: root.url.appendingPathComponent("generated.txt"), encoding: .utf8) == "replacement")
    }

    @Test func exclusiveReadOnlyCreateWithModeZeroReturnsItsDescriptorAndCanBeUnlinked() throws {
        let root = try TestHostFSRoot()
        let fs = try HostFS(rootPath: root.url.path)
        let path = root.url.appendingPathComponent("mode-zero.lock")

        let created = try fs.createFileAndOpen(
            parent: HostFS.rootNodeID,
            name: "mode-zero.lock",
            mode: 0,
            accessMode: .readOnly,
            preferredIdentityAccessMode: .readWrite,
            exclusive: true,
            syntheticAttributes: true,
            retainOpenHandle: true
        )
        defer { fs.close(handle: created.fd) }

        var status = stat()
        #expect(fstat(created.fd, &status) == 0)
        #expect(status.st_mode & 0o7777 == 0)
        #expect(FileManager.default.fileExists(atPath: path.path))
        try fs.unlink(parent: HostFS.rootNodeID, name: "mode-zero.lock")
        #expect(!FileManager.default.fileExists(atPath: path.path))
    }

    @Test func preferredCreateIdentityFallsBackToRequestedAccessForRestrictiveHostWinner() throws {
        let root = try TestHostFSRoot()
        try root.write("host", to: "winner.txt")
        let path = root.url.appendingPathComponent("winner.txt")
        #expect(chmod(path.path, 0o200) == 0)
        let fs = try HostFS(rootPath: root.url.path)

        let opened = try fs.createFileAndOpen(
            parent: HostFS.rootNodeID,
            name: "winner.txt",
            accessMode: .writeOnly,
            preferredIdentityAccessMode: .readWrite,
            exclusive: false
        )
        defer { fs.close(handle: opened.fd) }

        #expect(try fs.write(handle: opened.fd, offset: 0, data: Array("W".utf8)) == 1)
    }

    @Test func syntheticCreateReplacementIsNeverRetargetedOnExplicitGetattr() throws {
        let root = try TestHostFSRoot()
        let fs = try HostFS(rootPath: root.url.path)
        let created = try fs.createFileAndOpen(
            parent: HostFS.rootNodeID,
            name: "generated.txt",
            syntheticAttributes: true
        )
        fs.close(handle: created.fd)

        try root.write("host replacement is longer", to: "generated.txt")
        #expect(throws: HostFSError.staleIdentity(created.entry.nodeID)) {
            _ = try fs.getattr(nodeID: created.entry.nodeID)
        }
        let replacement = try fs.lookup(parent: HostFS.rootNodeID, name: "generated.txt")

        #expect(replacement.nodeID != created.entry.nodeID)
        #expect(replacement.attributes.size == 26)
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

    @Test func hostRemovedDirectoryCanBeRecreatedWithChildren() throws {
        let root = try TestHostFSRoot()
        let nodeModulesURL = root.url.appendingPathComponent("node_modules", isDirectory: true)
        try FileManager.default.createDirectory(at: nodeModulesURL, withIntermediateDirectories: false)
        try root.write("old", to: "node_modules/old.txt")
        let fs = try HostFS(rootPath: root.url.path)

        let original = try fs.lookup(parent: HostFS.rootNodeID, name: "node_modules")
        _ = try fs.lookup(parent: original.nodeID, name: "old.txt")

        // Simulate a host-side `rm -rf node_modules` between container runs. Looking up the child
        // above intentionally primes HostFS's cached directory descriptor for the now-removed inode.
        try FileManager.default.removeItem(at: nodeModulesURL)
        let recreated = try fs.mkdir(parent: HostFS.rootNodeID, name: "node_modules")

        let child = try fs.mkdir(parent: recreated.nodeID, name: "axios")

        #expect(child.attributes.isDirectory)
        #expect(FileManager.default.fileExists(atPath: nodeModulesURL.appendingPathComponent("axios").path))
    }

    @Test func hostReplacementGetsNewNodeIDWhileOldLookupRemainsTombstoned() throws {
        let root = try TestHostFSRoot()
        try root.write("old", to: "watched.txt")
        let fs = try HostFS(rootPath: root.url.path)
        let old = try fs.lookup(parent: HostFS.rootNodeID, name: "watched.txt")
        fs.retainLookup(nodeID: old.nodeID)

        let path = root.url.appendingPathComponent("watched.txt")
        try FileManager.default.removeItem(at: path)
        try root.write("replacement", to: "watched.txt")
        let pendingOpen = try fs.openRead(nodeID: old.nodeID)
        defer { fs.close(handle: pendingOpen) }
        #expect(String(decoding: try fs.read(handle: pendingOpen, offset: 0, count: 32), as: UTF8.self) == "old")
        var oldStatus = stat()
        #expect(fstat(pendingOpen, &oldStatus) == 0)
        #expect(oldStatus.st_nlink == 0)

        // Reverse invalidation can detach the old binding before another already-issued OPEN is
        // serviced. Its nonzero lookup reference still authorizes opening the same pinned inode.
        let detachedPendingOpen = try fs.openRead(nodeID: old.nodeID)
        defer { fs.close(handle: detachedPendingOpen) }
        #expect(
            String(decoding: try fs.read(handle: detachedPendingOpen, offset: 0, count: 32), as: UTF8.self)
                == "old"
        )
        let replacement = try fs.lookup(parent: HostFS.rootNodeID, name: "watched.txt")

        #expect(replacement.nodeID > old.nodeID)
        #expect(try fs.cachedAttributes(nodeID: old.nodeID).size == 3)
        // The old node remains a valid inode while its lookup/open references are live. A
        // pathless GETATTR must use the pinned identity just like fstat, not leak ESTALE merely
        // because the host replaced its former name.
        #expect(try fs.getattr(nodeID: old.nodeID).size == 3)
        #expect(try fs.getattr(nodeID: old.nodeID).linkCount == 0)
        #expect(try fs.getattr(nodeID: replacement.nodeID).size == 11)

        fs.forgetLookup(nodeID: old.nodeID, count: 1)
        #expect(throws: HostFSError.notFound("node \(old.nodeID)")) {
            _ = try fs.cachedAttributes(nodeID: old.nodeID)
        }
    }

    @Test func replacementRaceReadWriteAndAppendMutateOnlyPinnedOldIdentity() throws {
        let root = try TestHostFSRoot()
        try root.write("old", to: "watched.txt")
        let fs = try HostFS(rootPath: root.url.path)
        let old = try fs.lookup(parent: HostFS.rootNodeID, name: "watched.txt")
        fs.retainLookup(nodeID: old.nodeID)
        defer { fs.forgetLookup(nodeID: old.nodeID, count: 1) }

        try root.write("replacement", to: "watched.txt")
        let oldFD = try fs.openReadWrite(nodeID: old.nodeID, append: true)
        defer { fs.close(handle: oldFD) }
        #expect(try fs.write(handle: oldFD, offset: 0, data: Array("+append".utf8), append: true) == 7)
        #expect(String(decoding: try fs.read(handle: oldFD, offset: 0, count: 32), as: UTF8.self) == "old+append")
        #expect(
            try String(contentsOf: root.url.appendingPathComponent("watched.txt"), encoding: .utf8)
                == "replacement"
        )

        let replacement = try fs.lookup(parent: HostFS.rootNodeID, name: "watched.txt")
        #expect(replacement.nodeID != old.nodeID)
    }

    @Test func guestRenameRacingOpenDoesNotDetachTheRenamedBinding() throws {
        let root = try TestHostFSRoot()
        try root.write("payload", to: "before.txt")
        let fs = try HostFS(rootPath: root.url.path)
        let entry = try fs.lookup(parent: HostFS.rootNodeID, name: "before.txt")
        fs.retainLookup(nodeID: entry.nodeID)
        defer { fs.forgetLookup(nodeID: entry.nodeID, count: 1) }
        fs.openIdentityPinnedTestHook = { nodeID in
            guard nodeID == entry.nodeID else { return }
            fs.openIdentityPinnedTestHook = nil
            _ = try! fs.rename(
                parent: HostFS.rootNodeID,
                name: "before.txt",
                newParent: HostFS.rootNodeID,
                newName: "after.txt"
            )
        }

        let fd = try fs.openRead(nodeID: entry.nodeID)
        defer { fs.close(handle: fd) }

        #expect(String(decoding: try fs.read(handle: fd, offset: 0, count: 32), as: UTF8.self) == "payload")
        let renamed = try fs.lookup(parent: HostFS.rootNodeID, name: "after.txt")
        #expect(renamed.nodeID == entry.nodeID)
        #expect(try fs.getattr(nodeID: entry.nodeID).size == 7)
    }

    @Test func pinnedReopenRechecksPermissionsAfterReplacement() throws {
        let root = try TestHostFSRoot()
        try root.write("old", to: "watched.txt")
        let path = root.url.appendingPathComponent("watched.txt")
        #expect(chmod(path.path, 0o600) == 0)
        let fs = try HostFS(rootPath: root.url.path)
        let old = try fs.lookup(parent: HostFS.rootNodeID, name: "watched.txt")
        fs.retainLookup(nodeID: old.nodeID)
        defer { fs.forgetLookup(nodeID: old.nodeID, count: 1) }

        #expect(chmod(path.path, 0) == 0)
        try root.write("replacement", to: "replacement.tmp")
        #expect(rename(root.url.appendingPathComponent("replacement.tmp").path, path.path) == 0)
        #expect(throws: HostFSError.systemCall("reopen pinned identity", EACCES)) {
            _ = try fs.openRead(nodeID: old.nodeID)
        }
        #expect(try String(contentsOf: path, encoding: .utf8) == "replacement")
    }

    @Test func identityPinPreservesReadOnlyAndWriteOnlyCapabilitiesAfterReplacement() throws {
        let root = try TestHostFSRoot()
        try root.write("read-old", to: "read-capability.txt")
        try root.write("write-old", to: "write-capability.txt")
        let readPath = root.url.appendingPathComponent("read-capability.txt")
        let writePath = root.url.appendingPathComponent("write-capability.txt")
        #expect(chmod(readPath.path, 0o400) == 0)
        #expect(chmod(writePath.path, 0o200) == 0)

        let fs = try HostFS(rootPath: root.url.path)
        let readNode = try fs.lookup(parent: HostFS.rootNodeID, name: "read-capability.txt")
        let writeNode = try fs.lookup(parent: HostFS.rootNodeID, name: "write-capability.txt")
        fs.retainLookup(nodeID: readNode.nodeID)
        fs.retainLookup(nodeID: writeNode.nodeID)
        defer {
            fs.forgetLookup(nodeID: readNode.nodeID, count: 1)
            fs.forgetLookup(nodeID: writeNode.nodeID, count: 1)
        }

        try root.write("read-new", to: "read-replacement.tmp")
        #expect(chmod(root.url.appendingPathComponent("read-replacement.tmp").path, 0) == 0)
        #expect(rename(
            root.url.appendingPathComponent("read-replacement.tmp").path,
            readPath.path
        ) == 0)
        try root.write("write-new", to: "write-replacement.tmp")
        #expect(rename(
            root.url.appendingPathComponent("write-replacement.tmp").path,
            writePath.path
        ) == 0)

        let readFD = try fs.openRead(nodeID: readNode.nodeID)
        defer { fs.close(handle: readFD) }
        #expect(
            String(decoding: try fs.read(handle: readFD, offset: 0, count: 32), as: UTF8.self)
                == "read-old"
        )
        #expect(throws: HostFSError.systemCall("reopen pinned identity", EACCES)) {
            _ = try fs.openWrite(nodeID: readNode.nodeID)
        }

        let writeFD = try fs.openWrite(nodeID: writeNode.nodeID)
        defer { fs.close(handle: writeFD) }
        #expect(try fs.write(handle: writeFD, offset: 0, data: Array("W".utf8)) == 1)
        #expect(throws: HostFSError.systemCall("reopen pinned identity", EACCES)) {
            _ = try fs.openRead(nodeID: writeNode.nodeID)
        }
    }

    @Test func detachedOpenNodeServesCachedGetattrUntilItsHandleIsReleased() throws {
        let root = try TestHostFSRoot()
        try root.write("old", to: "watched.txt")
        let fs = try HostFS(rootPath: root.url.path)
        let old = try fs.lookup(parent: HostFS.rootNodeID, name: "watched.txt")
        fs.retainLookup(nodeID: old.nodeID)
        let oldFD = try fs.openRead(nodeID: old.nodeID)
        try fs.retainOpenHandle(nodeID: old.nodeID)

        try root.write("replacement", to: "watched.txt")

        #expect(try fs.getattr(nodeID: old.nodeID).size == 3)
        #expect(try fs.getattr(nodeID: old.nodeID, handle: oldFD).size == 3)

        fs.forgetLookup(nodeID: old.nodeID, count: 1)
        fs.close(handle: oldFD)
        fs.releaseOpenHandle(nodeID: old.nodeID)
        #expect(throws: HostFSError.notFound("node \(old.nodeID)")) {
            _ = try fs.getattr(nodeID: old.nodeID)
        }
    }

    @Test func unlinkRetainsLiveNodeUntilAllLookupReferencesAreForgotten() throws {
        let root = try TestHostFSRoot()
        try root.write("payload", to: "live.txt")
        let fs = try HostFS(rootPath: root.url.path)
        let entry = try fs.lookup(parent: HostFS.rootNodeID, name: "live.txt")
        fs.retainLookup(nodeID: entry.nodeID, count: 3)

        try fs.unlink(parent: HostFS.rootNodeID, name: "live.txt")
        #expect(try fs.cachedAttributes(nodeID: entry.nodeID).size == 7)

        fs.forgetLookup(nodeID: entry.nodeID, count: 2)
        #expect(try fs.cachedAttributes(nodeID: entry.nodeID).size == 7)

        fs.forgetLookup(nodeID: entry.nodeID, count: 1)
        #expect(throws: HostFSError.notFound("node \(entry.nodeID)")) {
            _ = try fs.cachedAttributes(nodeID: entry.nodeID)
        }
    }

    @Test func doubleUnlinkPreservesHostENOENT() throws {
        let root = try TestHostFSRoot()
        try root.write("payload", to: "victim.txt")
        let fs = try HostFS(rootPath: root.url.path)

        try fs.unlink(parent: HostFS.rootNodeID, name: "victim.txt")

        #expect(throws: HostFSError.systemCall("unlink victim.txt", ENOENT)) {
            try fs.unlink(parent: HostFS.rootNodeID, name: "victim.txt")
        }
    }

    @Test func exclusiveCreatePreservesHostEEXIST() throws {
        let root = try TestHostFSRoot()
        try root.write("original", to: "existing.txt")
        let fs = try HostFS(rootPath: root.url.path)

        #expect(throws: HostFSError.systemCall("create existing.txt", EEXIST)) {
            _ = try fs.createFileAndOpen(
                parent: HostFS.rootNodeID,
                name: "existing.txt",
                accessMode: .readWrite,
                exclusive: true
            )
        }
        #expect(try Data(contentsOf: root.url.appendingPathComponent("existing.txt")) == Data("original".utf8))
    }

    @Test func openHandleReferencePinsNodeAfterFinalForgetUntilRelease() throws {
        let root = try TestHostFSRoot()
        try root.write("payload", to: "open.txt")
        let fs = try HostFS(rootPath: root.url.path)
        let entry = try fs.lookup(parent: HostFS.rootNodeID, name: "open.txt")
        fs.retainLookup(nodeID: entry.nodeID)
        let fd = try fs.openRead(nodeID: entry.nodeID)
        try fs.retainOpenHandle(nodeID: entry.nodeID)

        fs.forgetLookup(nodeID: entry.nodeID, count: 1)

        #expect(try fs.cachedAttributes(nodeID: entry.nodeID).size == 7)
        #expect(String(decoding: try fs.read(handle: fd, offset: 0, count: 7), as: UTF8.self) == "payload")

        fs.close(handle: fd)
        fs.releaseOpenHandle(nodeID: entry.nodeID)
        #expect(throws: HostFSError.notFound("node \(entry.nodeID)")) {
            _ = try fs.cachedAttributes(nodeID: entry.nodeID)
        }
    }

    @Test func guestRenamePreservesLiveNodeIdentityAndUpdatesItsPath() throws {
        let root = try TestHostFSRoot()
        try root.write("payload", to: "before.txt")
        let fs = try HostFS(rootPath: root.url.path)
        let before = try fs.lookup(parent: HostFS.rootNodeID, name: "before.txt")
        fs.retainLookup(nodeID: before.nodeID)

        let after = try fs.rename(
            parent: HostFS.rootNodeID,
            name: "before.txt",
            newParent: HostFS.rootNodeID,
            newName: "after.txt"
        )

        #expect(after.nodeID == before.nodeID)
        #expect(try fs.getattr(nodeID: before.nodeID).size == 7)
        #expect(throws: HostFSError.notFound("before.txt")) {
            _ = try fs.lookup(parent: HostFS.rootNodeID, name: "before.txt")
        }

        fs.forgetLookup(nodeID: before.nodeID, count: 1)
        #expect(throws: HostFSError.notFound("node \(before.nodeID)")) {
            _ = try fs.cachedAttributes(nodeID: before.nodeID)
        }
        let rediscovered = try fs.lookup(parent: HostFS.rootNodeID, name: "after.txt")
        #expect(rediscovered.nodeID > before.nodeID)
    }

    @Test func losingRenamePreservesHostENOENT() throws {
        let root = try TestHostFSRoot()
        try root.write("payload", to: "before.txt")
        let fs = try HostFS(rootPath: root.url.path)

        _ = try fs.rename(
            parent: HostFS.rootNodeID,
            name: "before.txt",
            newParent: HostFS.rootNodeID,
            newName: "after.txt"
        )

        #expect(throws: HostFSError.systemCall("rename before.txt", ENOENT)) {
            _ = try fs.rename(
                parent: HostFS.rootNodeID,
                name: "before.txt",
                newParent: HostFS.rootNodeID,
                newName: "loser.txt"
            )
        }
        #expect(FileManager.default.fileExists(atPath: root.url.appendingPathComponent("after.txt").path))
        #expect(!FileManager.default.fileExists(atPath: root.url.appendingPathComponent("loser.txt").path))
    }

    @Test func missingMappedDirectoryStillDetachesKnownDescendantsRecursively() throws {
        let root = try TestHostFSRoot()
        try FileManager.default.createDirectory(
            at: root.url.appendingPathComponent("removed"),
            withIntermediateDirectories: false
        )
        try root.write("child", to: "removed/child.txt")
        let fs = try HostFS(rootPath: root.url.path)
        let directory = try fs.lookup(parent: HostFS.rootNodeID, name: "removed")
        let child = try fs.lookup(parent: directory.nodeID, name: "child.txt")

        try FileManager.default.removeItem(at: root.url.appendingPathComponent("removed"))
        #expect(try fs.lookupIfExists(parent: HostFS.rootNodeID, name: "removed") == nil)

        #expect(throws: HostFSError.notFound("node \(directory.nodeID)")) {
            _ = try fs.cachedAttributes(nodeID: directory.nodeID)
        }
        #expect(throws: HostFSError.notFound("node \(child.nodeID)")) {
            _ = try fs.cachedAttributes(nodeID: child.nodeID)
        }
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

    @Test func childIndexStaysConsistentAcrossNamespaceMutations() throws {
        let root = try TestHostFSRoot()
        let fs = try HostFS(rootPath: root.url.path)
        #expect(fs.childIndexIsConsistentForTesting())

        let dir = try fs.mkdir(parent: HostFS.rootNodeID, name: "pkg")
        let nested = try fs.mkdir(parent: dir.nodeID, name: "lib")
        _ = try fs.createFile(parent: nested.nodeID, name: "index.js")
        _ = try fs.createFile(parent: dir.nodeID, name: "package.json")
        #expect(fs.childIndexIsConsistentForTesting())

        _ = try fs.rename(parent: dir.nodeID, name: "package.json", newParent: nested.nodeID, newName: "renamed.json")
        #expect(fs.childIndexIsConsistentForTesting())

        try fs.unlink(parent: nested.nodeID, name: "index.js")
        try fs.unlink(parent: nested.nodeID, name: "renamed.json")
        try fs.rmdir(parent: dir.nodeID, name: "lib")
        #expect(fs.childIndexIsConsistentForTesting())

        fs.forgetLookup(nodeID: nested.nodeID, count: UInt64.max)
        try fs.rmdir(parent: HostFS.rootNodeID, name: "pkg")
        fs.forgetLookup(nodeID: dir.nodeID, count: UInt64.max)
        #expect(fs.childIndexIsConsistentForTesting())
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

private func hostStatus(_ url: URL) throws -> stat {
    var status = stat()
    guard lstat(url.path, &status) == 0 else {
        throw CocoaError(.fileReadUnknown)
    }
    return status
}

private final class IdentityPinCloseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var nodeIDs: Set<UInt64> = []

    func record(_ nodeID: UInt64) {
        lock.lock()
        nodeIDs.insert(nodeID)
        lock.unlock()
    }

    func contains(_ nodeID: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return nodeIDs.contains(nodeID)
    }
}

private final class TestHostFSRoot {
    let url: URL

    var realPath: String { url.resolvingSymlinksInPath().path }

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
