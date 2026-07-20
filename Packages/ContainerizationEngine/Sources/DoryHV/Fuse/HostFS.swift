import Darwin
import Foundation

public enum HostFSError: Error, Equatable {
    case invalidRoot(String)
    case invalidName(String)
    case notFound(String)
    /// A live FUSE node no longer names the host object it was created for. Path-based callers
    /// must revalidate the dentry instead of observing a false absence during atomic replacement.
    case staleIdentity(UInt64)
    case notDirectory(UInt64)
    case notRegularFile(UInt64)
    case readOnly
    case permissionDenied(String)
    case operationNotSupported(String)
    case systemCall(String, Int32)
    case io(String)
}

public struct HostFSAttributes: Equatable, Sendable {
    public var nodeID: UInt64
    public var mode: UInt32
    public var size: UInt64
    /// Backing inode link count, exported as `fuse_attr.nlink`.
    public var linkCount: UInt32 = 1
    public var uid: UInt32
    public var gid: UInt32
    public var atimeSeconds: Int64
    public var mtimeSeconds: Int64
    public var ctimeSeconds: Int64
    public var atimeNsec: UInt32 = 0
    public var mtimeNsec: UInt32 = 0
    public var ctimeNsec: UInt32 = 0

    public var isDirectory: Bool { (mode & UInt32(S_IFMT)) == UInt32(S_IFDIR) }
    public var isRegularFile: Bool { (mode & UInt32(S_IFMT)) == UInt32(S_IFREG) }
    public var isSymlink: Bool { (mode & UInt32(S_IFMT)) == UInt32(S_IFLNK) }
}

public struct HostFSEntry: Equatable, Sendable {
    public var name: String
    public var nodeID: UInt64
    public var attributes: HostFSAttributes
}

public enum HostFSAccessMode: Int32, Equatable, Sendable {
    case readOnly = 0
    case writeOnly = 1
    case readWrite = 2

    fileprivate var darwinFlag: Int32 {
        switch self {
        case .readOnly: O_RDONLY
        case .writeOnly: O_WRONLY
        case .readWrite: O_RDWR
        }
    }

    fileprivate var permitsWrite: Bool { self != .readOnly }
}

public struct HostFSStat: Equatable, Sendable {
    public var blockSize: UInt64
    public var blocks: UInt64
    public var blocksFree: UInt64
    public var blocksAvailable: UInt64
    public var files: UInt64
    public var filesFree: UInt64
    public var nameMax: UInt32
}

/// The FUSE identities already known for one host path at the instant an invalidation is built.
///
/// An event can race an unlink or atomic replacement, so `nodeIDs` and `parentNodeIDs` may each
/// contain both the current identity and retained detached identities. Empty arrays mean that the
/// corresponding path has never been looked up (or all of its identities have been forgotten).
/// `staleNodeIDs` is the subset that no longer matches the host object's current
/// device/inode/generation identity. It lets the coordinator emit DELETE for a replaced watched
/// inode without deleting a new dentry that Linux may already have resolved at the same name.
/// `unverifiedNodeIDs` contains
/// fast-created identities that have not yet been reconciled with a host inode; those are treated
/// as deleted only when FSEvents also reports a namespace mutation. `survivingLinkNodeIDs` marks a
/// stale pathname whose inode is still reachable through another verified hard-link binding; that
/// dentry needs ENTRY + attribute invalidation, never DELETE/IN_DELETE_SELF for the shared inode.
public struct HostFSInvalidationSnapshot: Equatable, Sendable {
    public var nodeIDs: [UInt64]
    public var staleNodeIDs: [UInt64]
    public var unverifiedNodeIDs: [UInt64]
    public var survivingLinkNodeIDs: [UInt64]
    public var parentNodeIDs: [UInt64]
    public var entryName: String?

    public init(
        nodeIDs: [UInt64],
        staleNodeIDs: [UInt64] = [],
        unverifiedNodeIDs: [UInt64] = [],
        survivingLinkNodeIDs: [UInt64] = [],
        parentNodeIDs: [UInt64],
        entryName: String?
    ) {
        self.nodeIDs = nodeIDs
        self.staleNodeIDs = staleNodeIDs
        self.unverifiedNodeIDs = unverifiedNodeIDs
        self.survivingLinkNodeIDs = survivingLinkNodeIDs
        self.parentNodeIDs = parentNodeIDs
        self.entryName = entryName
    }
}

public enum HostFSTimestampUpdate: Equatable, Sendable {
    case value(seconds: Int64, nanoseconds: UInt32)
    case now
}

/// Host-side subset of one FUSE SETATTR operation. Ownership is intentionally virtual: container
/// UID/GID changes are accepted without changing the macOS account that owns the shared tree. The
/// export remains user-owned on the host while image entrypoints such as Postgres can perform their
/// normal recursive `chown` before dropping privileges.
public struct HostFSSetattrRequest: Equatable, Sendable {
    public var mode: UInt32?
    public var uid: UInt32?
    public var gid: UInt32?
    public var size: UInt64?
    public var atime: HostFSTimestampUpdate?
    public var mtime: HostFSTimestampUpdate?
    public var ctimeRequested: Bool
    public var killSuidGid: Bool

    public init(
        mode: UInt32? = nil,
        uid: UInt32? = nil,
        gid: UInt32? = nil,
        size: UInt64? = nil,
        atime: HostFSTimestampUpdate? = nil,
        mtime: HostFSTimestampUpdate? = nil,
        ctimeRequested: Bool = false,
        killSuidGid: Bool = false
    ) {
        self.mode = mode
        self.uid = uid
        self.gid = gid
        self.size = size
        self.atime = atime
        self.mtime = mtime
        self.ctimeRequested = ctimeRequested
        self.killSuidGid = killSuidGid
    }

    fileprivate var requestsMutation: Bool {
        mode != nil || uid != nil || gid != nil || size != nil || atime != nil || mtime != nil
            || ctimeRequested || killSuidGid
    }

    fileprivate var requiresDescriptorMutation: Bool {
        mode != nil || size != nil || atime != nil || mtime != nil || killSuidGid
    }
}

public final class HostFS: @unchecked Sendable {
    public static let rootNodeID: UInt64 = 1
    public static let maxReadCount: Int = 1 << 20

    /// Darwin resolves these constraints inside one VFS operation. Unlike walking/caching parent
    /// descriptors in userspace, a concurrent host rename cannot move an already-checked parent
    /// outside the export between validation and the operation.
    private static let containedOpenFlags = O_NOFOLLOW_ANY | O_RESOLVE_BENEATH
    /// `O_SYMLINK` deliberately opens the final link itself, so it cannot be combined with
    /// `O_NOFOLLOW_ANY`. `O_RESOLVE_BENEATH` still atomically prevents intermediate traversal from
    /// escaping `rootFD`, and `freadlink` then reads the pinned link rather than another pathname.
    private static let containedSymlinkOpenFlags = O_SYMLINK | O_RESOLVE_BENEATH
    private static let containedStatFlags = AT_SYMLINK_NOFOLLOW_ANY | AT_RESOLVE_BENEATH
    private static let containedUnlinkFlags = AT_SYMLINK_NOFOLLOW_ANY | AT_RESOLVE_BENEATH
    private static let containedLinkFlags = AT_SYMLINK_NOFOLLOW_ANY | AT_RESOLVE_BENEATH
    private static let containedRenameFlags = UInt32(RENAME_NOFOLLOW_ANY | RENAME_RESOLVE_BENEATH)
    private static let containedExclusiveRenameFlags = UInt32(
        RENAME_EXCL | RENAME_NOFOLLOW_ANY | RENAME_RESOLVE_BENEATH
    )

    private struct Node: Sendable {
        var id: UInt64
        /// Preferred live pathname for descriptor-relative operations. Hard-link aliases all share
        /// this Node/FUSE identity; when this binding disappears another attached path takes over.
        var relativePath: String
        /// Current directory-entry bindings for this host inode. This is the inverse of
        /// `idsByRelativePath` and keeps detach/FORGET work proportional to one inode's aliases.
        var attachedPaths: Set<String>
        /// Removed/replaced bindings retained only while the FUSE identity is pinned. Host events
        /// can then DELETE precisely the stale dentry without detaching a surviving hard-link name.
        var tombstonePaths: Set<String> = []
        var attributes: HostFSAttributes
        /// True when the cached nlink came from a live pathname and therefore still includes every
        /// attached binding. Handle-based fstat may already observe a concurrent unlink.
        var linkCountIncludesAttachedBindings = true
        var fileKey: FileKey
        /// Descriptor retained for the entire FUSE-node lifetime. Holding the open file
        /// description prevents Darwin from recycling this inode number while the guest can still
        /// refer to its node ID, including after every pathname has been removed.
        var identityFD: Int32
        /// Number of lookup references handed to the guest in fuse_entry_out records. A detached
        /// node stays alive until the matching FORGET/BATCH_FORGET requests release these refs.
        var lookupCount: UInt64 = 0
        /// Number of live FUSE file or directory handles that reference this node. The kernel may
        /// FORGET its final lookup before RELEASE/RELEASEDIR, so handles independently pin identity.
        var openHandleCount: UInt64 = 0
        /// The inode has no live name in this share. Open handles can still pin its old host object.
        var isDetached: Bool { attachedPaths.isEmpty }
    }

    private struct RemovedLinkState: Sendable {
        var fileKey: FileKey
        var remainingLinkCount: UInt32
    }

    private struct PinnedIdentity {
        var fd: Int32
        var status: stat
    }

    private let rootPath: String
    /// Accept both the caller's standardized spelling and the canonical `realpath` spelling.
    /// FSEvents reports paths in the spelling used to create its stream, which can differ across
    /// macOS aliases such as `/var` and `/private/var`.
    private let hostEventRootPaths: [String]
    private let rootFD: Int32
    private let guestUID: UInt32
    private let guestGID: UInt32
    private let readOnly: Bool
    /// Entry names hidden from the guest at any depth. A lookup of a hidden name fails as if the
    /// path does not exist, hidden entries are omitted from directory listings, and entry-creating
    /// or entry-removing operations reject hidden names before touching the host.
    /// Compare case-insensitively so the denylist cannot be bypassed through a case-insensitive
    /// APFS lookup such as `.SSH` resolving the host's `.ssh` directory.
    private let hiddenNameKeys: Set<String>
    /// Entry names hidden only as direct children of the export root. Safe whole-home shares use
    /// this set so home credentials remain private without shadowing normal project directories.
    private let rootHiddenNameKeys: Set<String>
    private var nextNodeID: UInt64 = 2
    private var nodes: [UInt64: Node] = [:]
    private var idsByFileKey: [FileKey: Set<UInt64>] = [:]
    private var idsByRelativePath: [String: [UInt64]] = [:]
    private var detachedIDsByRelativePath: [String: Set<UInt64>] = [:]
    /// Direct child names of every known path, maintained as the union of the attached and
    /// detached key sets. Recursive detaches and directory-event fanout walk real subtrees through
    /// this index instead of prefix-scanning every registered key, which turned each CREATE in an
    /// npm-scale install into an O(all known paths) string scan.
    private var knownChildNamesByParentPath: [String: Set<String>] = [:]
    /// Called after the guest resolves a real host path. Production uses this to subscribe
    /// FSEvents only to the accessed top-level project/volume instead of the entire export root.
    private var eventObservationHandler: (@Sendable (String) -> Void)?
    private let lock = NSLock()

    /// Deterministic test seam for the narrow unlinkat-to-index-update window.
    var unlinkPostHostMutationTestHook: (@Sendable () -> Void)?
    /// Deterministic test seam for the narrow linkat-to-identity-verification window.
    var linkPostHostMutationTestHook: (@Sendable () -> Void)?
    /// Deterministic resource-exhaustion seam. A configured errno is returned before opening or
    /// duplicating an identity descriptor; production leaves it nil.
    var identityPinOpenTestErrno: Int32?
    /// Runs after a pathname has been pinned and statted but before registration. Tests use this
    /// to replace the name deterministically and prove the returned node retains the old identity.
    var identityPinPostOpenTestHook: (@Sendable (_ relativePath: String, _ fd: Int32) -> Void)?
    /// Runs after OPEN has duplicated the node identity and, for FUSE handles, reserved its
    /// open-handle reference. Tests use it to force a concurrent FORGET before pathname reopen.
    var openIdentityPinnedTestHook: (@Sendable (_ nodeID: UInt64) -> Void)?
    /// Observes descriptor retirement without relying on process-global descriptor numbers, which
    /// may be reused immediately by another parallel test.
    var identityPinClosedTestHook: (@Sendable (_ nodeID: UInt64, _ fd: Int32) -> Void)?

    func identityFileKeyForTesting(nodeID: UInt64) -> FileKey? {
        lock.withLock {
            guard let node = nodes[nodeID] else { return nil }
            return pinnedFileKeyLocked(node)
        }
    }

    public init(
        rootPath: String,
        // The host filesystem server runs as the signed-in macOS user. Export that identity by
        // default so the standard PUID/PGID convention (`id -u` / `id -g`) sees the same owner on
        // both sides of a bind mount. Guest chown remains virtual and never changes host ownership.
        guestUID: UInt32 = getuid(),
        guestGID: UInt32 = getgid(),
        readOnly: Bool = false,
        hiddenNames: Set<String> = [],
        rootHiddenNames: Set<String> = []
    ) throws {
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(rootPath, &resolved) != nil else {
            throw HostFSError.invalidRoot(rootPath)
        }
        let rootBytes = resolved.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let root = String(decoding: rootBytes, as: UTF8.self)
        let fd = open(root, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else {
            throw HostFSError.invalidRoot(rootPath)
        }

        self.rootPath = root
        let suppliedRoot = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        self.hostEventRootPaths = Array(Set([root, suppliedRoot])).sorted { $0.count > $1.count }
        self.rootFD = fd
        self.guestUID = guestUID
        self.guestGID = guestGID
        self.readOnly = readOnly
        self.hiddenNameKeys = Set(hiddenNames.map(Self.hiddenNameKey))
        self.rootHiddenNameKeys = Set(rootHiddenNames.map(Self.hiddenNameKey))

        var st = stat()
        guard fstat(fd, &st) == 0 else {
            Darwin.close(fd)
            throw HostFSError.invalidRoot(rootPath)
        }
        let identityFD = fcntl(fd, F_DUPFD_CLOEXEC, 0)
        guard identityFD >= 0 else {
            let savedErrno = errno
            Darwin.close(fd)
            throw HostFSError.systemCall("pin root identity", savedErrno)
        }
        let attrs = Self.attributes(from: st, nodeID: Self.rootNodeID, uid: guestUID, gid: guestGID)
        self.nodes[Self.rootNodeID] = Node(
            id: Self.rootNodeID,
            relativePath: "",
            attachedPaths: [""],
            attributes: attrs,
            fileKey: FileKey(st),
            identityFD: identityFD
        )
        self.idsByFileKey[FileKey(st)] = [Self.rootNodeID]
        self.idsByRelativePath["", default: []].append(Self.rootNodeID)
    }

    public func setEventObservationHandler(_ handler: (@Sendable (String) -> Void)?) {
        lock.withLock { eventObservationHandler = handler }
    }

    private func notifyEventObservation(for relativePath: String) {
        guard !relativePath.isEmpty else { return }
        let handler = lock.withLock { eventObservationHandler }
        handler?(rootPath + "/" + relativePath)
    }

    deinit {
        for node in nodes.values {
            Darwin.close(node.identityFD)
            identityPinClosedTestHook?(node.id, node.identityFD)
        }
        Darwin.close(rootFD)
    }

    public func getattr(nodeID: UInt64) throws -> HostFSAttributes {
        let node = try node(for: nodeID)
        if node.isDetached {
            // A node ID identifies an inode, not its former pathname. LOOKUP and open-handle refs
            // may legitimately outlive unlink/replacement, and Linux can issue GETATTR without FH
            // while completing an already-authorized open. Serve the pinned inode so host atomic
            // replacement never leaks ESTALE to ordinary path readers.
            guard node.lookupCount > 0 || node.openHandleCount > 0 else {
                throw HostFSError.staleIdentity(nodeID)
            }
            return refreshCachedAttributes(
                nodeID: nodeID,
                from: try identityStatus(for: node)
            )
        }
        // Fast CREATE/MKDIR responses start with synthetic attributes so the creating syscall does
        // not need an immediate fstat round trip. Reconcile on the first explicit GETATTR instead of
        // trusting the synthetic identity forever; host-side edits/replacements must still become
        // visible once the guest asks for fresh metadata.
        var st = stat()
        let result = node.relativePath.isEmpty
            ? fstat(rootFD, &st)
            : fstatat(rootFD, cPath(node.relativePath), &st, Self.containedStatFlags)
        guard result == 0 else {
            let savedErrno = errno
            if !node.relativePath.isEmpty,
               savedErrno == ENOENT || savedErrno == ENOTDIR {
                let retainedStatus = try identityStatus(for: node)
                let hasFuseReference = node.lookupCount > 0 || node.openHandleCount > 0
                detachSnapshotPathBinding(
                    nodeID: nodeID,
                    relativePath: node.relativePath,
                    recursive: node.attributes.isDirectory
                )
                if (try? attachedNode(for: nodeID)) != nil {
                    return try getattr(nodeID: nodeID)
                }
                if hasFuseReference {
                    return refreshCachedAttributes(nodeID: nodeID, from: retainedStatus)
                }
                throw HostFSError.staleIdentity(nodeID)
            }
            throw HostFSError.systemCall("getattr \(node.relativePath)", savedErrno)
        }
        let identity = try identityStatus(for: node)
        let key = FileKey(st)
        guard key == FileKey(identity) else {
            // nodeid:generation identifies one object for the lifetime of its lookup references.
            // Never retarget an old node id when an editor atomically replaces the host inode. The
            // old ID remains a valid inode while LOOKUP/FH refs exist, so return its pinned attrs
            // after detaching only the stale pathname instead of exposing ESTALE to the application.
            let hasFuseReference = node.lookupCount > 0 || node.openHandleCount > 0
            detachSnapshotPathBinding(
                nodeID: nodeID,
                relativePath: node.relativePath,
                recursive: node.attributes.isDirectory
            )
            if (try? attachedNode(for: nodeID)) != nil {
                return try getattr(nodeID: nodeID)
            }
            if hasFuseReference {
                return refreshCachedAttributes(nodeID: nodeID, from: identity)
            }
            throw HostFSError.staleIdentity(nodeID)
        }

        let attrs = Self.attributes(
            from: st,
            nodeID: nodeID,
            uid: node.attributes.uid,
            gid: node.attributes.gid
        )
        if node.fileKey.isSynthetic {
            try reconcileSyntheticIdentity(nodeID: nodeID, from: identity)
            return attrs
        }
        lock.withLock {
            guard var current = nodes[nodeID], !current.isDetached else { return }
            current.attributes = attrs
            current.linkCountIncludesAttachedBindings = true
            nodes[nodeID] = current
        }
        return attrs
    }

    /// Returns attributes for an already-open FUSE handle, including after the original path has
    /// been unlinked or atomically replaced. The retained descriptor owns the old inode identity;
    /// path-based revalidation must not turn a valid Linux open file description into ENOENT.
    public func getattr(nodeID: UInt64, handle fd: Int32) throws -> HostFSAttributes {
        let node = try node(for: nodeID)
        let status = try verifiedStatus(handle: fd, node: node)
        return refreshCachedAttributes(nodeID: nodeID, from: status)
    }

    public func cachedAttributes(nodeID: UInt64) throws -> HostFSAttributes {
        try node(for: nodeID).attributes
    }

    /// Takes a non-mutating snapshot for a host-side filesystem event.
    ///
    /// The path is standardized lexically because a delete event may no longer exist on disk. The
    /// snapshot never registers the path and never adds a FUSE lookup reference. It stats the exact
    /// path to classify replacement and, only for a stale hard-link node, verifies known aliases.
    /// Paths outside this share, non-absolute paths, paths containing NUL, and paths traversing a
    /// hidden entry name are rejected with `nil`.
    public func invalidationSnapshot(forHostPath hostPath: String) -> HostFSInvalidationSnapshot? {
        guard let relativePath = eventRelativePath(forHostPath: hostPath) else { return nil }

        if relativePath.isEmpty {
            return lock.withLock {
                var current = stat()
                let currentKey = fstat(rootFD, &current) == 0 ? FileKey(current) : nil
                let matchingIDs = Set(
                    (idsByRelativePath[""] ?? [])
                        + Array(detachedIDsByRelativePath[""] ?? [])
                )
                let matching = matchingIDs.compactMap { nodes[$0] }
                return HostFSInvalidationSnapshot(
                    nodeIDs: matching.map(\.id).sorted(),
                    staleNodeIDs: matching.filter {
                        $0.isDetached
                            || (!$0.fileKey.isSynthetic && pinnedFileKeyLocked($0) != currentKey)
                    }.map(\.id).sorted(),
                    unverifiedNodeIDs: matching.filter { $0.fileKey.isSynthetic }.map(\.id).sorted(),
                    survivingLinkNodeIDs: [],
                    parentNodeIDs: [],
                    entryName: nil
                )
            }
        }

        let parentPath: String
        let entryName: String
        if let separator = relativePath.lastIndex(of: "/") {
            parentPath = String(relativePath[..<separator])
            entryName = String(relativePath[relativePath.index(after: separator)...])
        } else {
            parentPath = ""
            entryName = relativePath
        }

        return lock.withLock {
            var current = stat()
            let currentKey = fstatat(
                rootFD,
                cPath(relativePath),
                &current,
                Self.containedStatFlags
            ) == 0 ? FileKey(current) : nil
            let matchingIDs = Set(
                (idsByRelativePath[relativePath] ?? [])
                    + Array(detachedIDsByRelativePath[relativePath] ?? [])
            )
            let matching = matchingIDs.compactMap { nodes[$0] }
            let stale = matching.filter {
                $0.isDetached
                    || (!$0.fileKey.isSynthetic && pinnedFileKeyLocked($0) != currentKey)
            }
            let parentIDs = Set(
                (idsByRelativePath[parentPath] ?? [])
                    + Array(detachedIDsByRelativePath[parentPath] ?? [])
            )
            return HostFSInvalidationSnapshot(
                nodeIDs: matching.map(\.id).sorted(),
                staleNodeIDs: stale.map(\.id).sorted(),
                unverifiedNodeIDs: matching.filter { $0.fileKey.isSynthetic }.map(\.id).sorted(),
                survivingLinkNodeIDs: stale.filter {
                    if let pinnedLinkCount = pinnedLinkCountLocked($0) {
                        return pinnedLinkCount > 0
                    }
                    return $0.attributes.linkCount > 1
                        || hasVerifiedLiveBindingLocked($0, excluding: relativePath)
                }.map(\.id).sorted(),
                parentNodeIDs: parentIDs.filter { nodes[$0] != nil }.sorted(),
                entryName: entryName
            )
        }
    }

    /// Reconciles the HostFS namespace with identities proven stale by an FSEvents snapshot.
    ///
    /// Reverse DELETE disconnects Linux's old dentry, but open-file `fstat(2)` may omit
    /// FUSE_GETATTR_FH and ask HostFS for the detached node's cached attributes. Tombstone the
    /// exact stale binding before publishing that notification and refresh nlink from the pinned
    /// old inode. The descriptor reports zero for a final atomic replacement and a positive count
    /// when an unseen hard-link alias still survives, avoiding both stale-one and double-decrement
    /// results without touching the old inode's data pages.
    func reconcileHostInvalidation(
        forHostPath hostPath: String,
        staleNodeIDs: [UInt64]
    ) {
        guard !staleNodeIDs.isEmpty,
              let relativePath = eventRelativePath(forHostPath: hostPath) else { return }
        let stale = Set(staleNodeIDs)
        lock.withLock {
            for nodeID in stale.sorted() {
                guard let node = nodes[nodeID] else { continue }
                if node.attachedPaths.contains(relativePath) {
                    detachPathBindingLocked(
                        nodeID: nodeID,
                        relativePath: relativePath,
                        linkRemovalConfirmed: true
                    )
                } else if node.tombstonePaths.contains(relativePath) {
                    // A guest lookup can discover/register the replacement before its FSEvent is
                    // delivered. Registration has already detached the old binding in that case;
                    // still refresh the retained tombstone so event ordering cannot preserve a
                    // pre-replacement handle-GETATTR nlink value.
                    refreshTombstonedLinkCountLocked(nodeID: nodeID)
                }
            }
        }
    }

    /// Event-only cold path: verify that a stale name's inode still has another name in this share.
    /// We do not trust the binding index alone because multiple host aliases may disappear in one
    /// coalesced FSEvents batch.
    private func hasVerifiedLiveBindingLocked(_ node: Node, excluding eventPath: String) -> Bool {
        guard !node.fileKey.isSynthetic else { return false }
        guard let identityKey = pinnedFileKeyLocked(node) else { return false }
        for path in node.attachedPaths where path != eventPath {
            var status = stat()
            let result = path.isEmpty
                ? fstat(rootFD, &status)
                : fstatat(rootFD, cPath(path), &status, Self.containedStatFlags)
            if result == 0, FileKey(status) == identityKey { return true }
        }
        return false
    }

    /// Returns every already-known host path that shares an inode identity with this event path.
    /// Hard-link names share one FUSE node but still need per-name dentry invalidation and watcher
    /// nudges, so fanout walks only the canonical node's indexed live path bindings.
    public func knownIdentityAliasHostPaths(forHostPath hostPath: String) -> [String] {
        guard let relativePath = eventRelativePath(forHostPath: hostPath) else { return [] }
        return lock.withLock {
            var keys = Set<FileKey>()
            let exactIDs = (idsByRelativePath[relativePath] ?? [])
                + Array(detachedIDsByRelativePath[relativePath] ?? [])
            for id in exactIDs {
                if let node = nodes[id], !node.fileKey.isSynthetic,
                   let identityKey = pinnedFileKeyLocked(node) {
                    keys.insert(identityKey)
                }
            }

            var current = stat()
            let statResult = relativePath.isEmpty
                ? fstat(rootFD, &current)
                : fstatat(rootFD, cPath(relativePath), &current, Self.containedStatFlags)
            if statResult == 0 {
                keys.insert(FileKey(current))
            }

            var paths: Set<String> = [relativePath]
            for key in keys {
                for id in idsByFileKey[key] ?? [] {
                    if let node = nodes[id], !node.isDetached {
                        paths.formUnion(node.attachedPaths)
                    }
                }
            }
            return paths.map { relative in
                relative.isEmpty ? rootPath : rootPath + "/" + relative
            }.sorted()
        }
    }

    /// Returns the directory itself and its immediate namespace bindings that Linux has already
    /// resolved. Directory-level FSEvents use this bounded set to recover exact invalidation and
    /// watcher targets without subscribing the broad home share to one event per package file.
    public func knownHostPaths(inHostDirectory hostDirectory: String) -> [String] {
        guard let directory = eventRelativePath(forHostPath: hostDirectory) else { return [] }
        return lock.withLock {
            var relatives = [String]()
            if directory.isEmpty
                || idsByRelativePath[directory] != nil
                || detachedIDsByRelativePath[directory] != nil {
                relatives.append(directory)
            }
            for name in knownChildNamesByParentPath[directory] ?? [] {
                relatives.append(directory.isEmpty ? name : directory + "/" + name)
            }
            return relatives.map { relative in
                relative.isEmpty ? rootPath : rootPath + "/" + relative
            }.sorted()
        }
    }

    /// Returns cached namespace bindings whose pinned identity no longer matches the host path.
    ///
    /// APFS FSEvents can report only the destination side of a host rename.  A destination-only
    /// event is enough to invalidate that name, but it otherwise leaves a watched source dentry
    /// alive in Linux with no `FUSE_NOTIFY_DELETE` for the source.  The coordinator uses this
    /// bounded-to-known-identities scan only for rename batches to synthesize the missing source
    /// invalidation.  It never discovers or registers new paths, and it only returns paths that
    /// the guest has already resolved through this HostFS instance.
    /// Every node ID this share currently tracks, for the loss-recovery content/attribute sweep.
    /// Over-invalidation is safe: an attribute/content invalidation drops clean cached state and
    /// never touches dentries or the mounts beneath them.
    public func knownNodeIDsForLossRecovery() -> [UInt64] {
        lock.withLock { nodes.keys.sorted() }
    }

    public func knownStaleHostPathsForNamespaceReconciliation() -> [String] {
        lock.withLock {
            idsByRelativePath.keys.compactMap { relativePath in
                // The share root is handled by explicit root-change/rescan policy.  Namespace
                // reconciliation is solely for cached child dentries.
                guard !relativePath.isEmpty,
                      let attachedIDs = idsByRelativePath[relativePath] else {
                    return nil
                }
                let attachedNodes = attachedIDs.compactMap { nodes[$0] }.filter {
                    $0.attachedPaths.contains(relativePath)
                }
                guard !attachedNodes.isEmpty else { return nil }

                var current = stat()
                let currentKey = fstatat(
                    rootFD,
                    cPath(relativePath),
                    &current,
                    Self.containedStatFlags
                ) == 0 ? FileKey(current) : nil
                let stale = attachedNodes.contains { node in
                    node.fileKey.isSynthetic || pinnedFileKeyLocked(node) != currentKey
                }
                guard stale else { return nil }
                return rootPath + "/" + relativePath
            }.sorted()
        }
    }

    private func eventRelativePath(forHostPath hostPath: String) -> String? {
        guard hostPath.hasPrefix("/"), !hostPath.utf8.contains(0) else { return nil }
        let standardizedPath = URL(fileURLWithPath: hostPath).standardizedFileURL.path
        var relativePath: String?
        for eventRoot in hostEventRootPaths {
            if standardizedPath == eventRoot {
                relativePath = ""
                break
            }
            if eventRoot == "/", standardizedPath.hasPrefix("/") {
                relativePath = String(standardizedPath.dropFirst())
                break
            }
            let rootPrefix = eventRoot + "/"
            if standardizedPath.hasPrefix(rootPrefix) {
                relativePath = String(standardizedPath.dropFirst(rootPrefix.count))
                break
            }
        }
        guard let relativePath else { return nil }
        let components = relativePath.split(separator: "/").map(String.init)
        guard !components.contains(where: isHiddenAtAnyDepth),
              components.first.map({ !rootHiddenNameKeys.contains(Self.hiddenNameKey($0)) }) ?? true else {
            return nil
        }
        return relativePath
    }

    public func recordWrite(nodeID: UInt64, offset: UInt64, count: Int) {
        guard count > 0 else { return }
        let endOffset = offset &+ UInt64(count)
        var ts = timespec()
        clock_gettime(CLOCK_REALTIME, &ts)
        lock.withLock {
            guard var node = nodes[nodeID] else { return }
            node.attributes.size = max(node.attributes.size, endOffset)
            node.attributes.mtimeSeconds = Int64(ts.tv_sec)
            node.attributes.ctimeSeconds = Int64(ts.tv_sec)
            node.attributes.mtimeNsec = UInt32(truncatingIfNeeded: ts.tv_nsec)
            node.attributes.ctimeNsec = UInt32(truncatingIfNeeded: ts.tv_nsec)
            nodes[nodeID] = node
        }
    }

    /// An append write ignores the guest-supplied offset. Refresh from the exact open file
    /// description so a malicious or stale wire offset cannot inflate the detached-node cache.
    public func recordAppendWrite(nodeID: UInt64, handle fd: Int32) throws {
        let node = try node(for: nodeID)
        let status = try verifiedStatus(handle: fd, node: node)
        _ = refreshCachedAttributes(nodeID: nodeID, from: status)
    }

    public func lookup(parent: UInt64, name: String) throws -> HostFSEntry {
        guard let entry = try lookupIfExists(parent: parent, name: name) else {
            throw HostFSError.notFound(name)
        }
        return entry
    }

    public func lookupIfExists(parent: UInt64, name: String) throws -> HostFSEntry? {
        try validateComponent(name)
        try requireVisible(name, parent: parent)
        let parentNode = try attachedNode(for: parent)
        guard parentNode.attributes.isDirectory else {
            throw HostFSError.notDirectory(parent)
        }
        let relative = join(parentNode.relativePath, name)
        // Arm the narrow top-level observation root before the namespace stat becomes the lookup
        // linearization point. A host replacement after this call is therefore observable before
        // Linux can cache the positive result.
        notifyEventObservation(for: relative)
        var st = stat()
        let result = fstatat(rootFD, cPath(relative), &st, Self.containedStatFlags)
        guard result == 0 else {
            let savedErrno = errno
            if savedErrno == ENOENT || savedErrno == ENOTDIR {
                detachLookupMiss(relativePath: relative)
                return nil
            }
            throw HostFSError.systemCall("lookup \(relative)", savedErrno)
        }
        guard Self.isSupportedFileType(st.st_mode) else {
            // Linux resolves FIFO open semantics in the VFS before a FUSE OPEN request reaches
            // userspace. Advertising a host FIFO (or another special inode we cannot proxy) can
            // therefore block a guest task forever even though openFile rejects non-regular files.
            // Hide unsupported special files at lookup time so access fails promptly and cannot
            // pin a VM request queue.
            detachLookupMiss(relativePath: relative)
            throw HostFSError.operationNotSupported("special host file: \(relative)")
        }

        // A real (non-synthetic) identity is already pinned for the common repeated-lookup case.
        // The contained fstatat above is the namespace linearization point: when its generation-
        // aware key still matches that pin, reopening and fstatting the same object adds no safety.
        // Fast-created synthetic identities and host replacements deliberately miss this path and
        // go through pinIdentity/register below.
        if let cached = cachedLookupEntry(name: name, relativePath: relative, status: st) {
            return cached
        }

        let identity: PinnedIdentity
        do {
            identity = try pinIdentity(relativePath: relative, expectedMode: st.st_mode)
        } catch HostFSError.systemCall(_, let code) where code == ENOENT || code == ENOTDIR {
            detachLookupMiss(relativePath: relative)
            return nil
        }
        return register(name: name, relativePath: relative, identity: identity)
    }

    private func cachedLookupEntry(
        name: String,
        relativePath: String,
        status: stat
    ) -> HostFSEntry? {
        let key = FileKey(status)
        return lock.withLock {
            guard let currentID = idsByRelativePath[relativePath]?.first,
                  var current = nodes[currentID],
                  !current.isDetached,
                  current.fileKey == key else {
                return nil
            }
            let attrs = Self.attributes(
                from: status,
                nodeID: currentID,
                uid: current.attributes.uid,
                gid: current.attributes.gid
            )
            current.attributes = attrs
            current.linkCountIncludesAttachedBindings = true
            nodes[currentID] = current
            return HostFSEntry(name: name, nodeID: currentID, attributes: attrs)
        }
    }

    public func openRead(nodeID: UInt64) throws -> Int32 {
        try openFile(nodeID: nodeID, accessMode: .readOnly, append: false)
    }

    public func openWrite(nodeID: UInt64, append: Bool = false) throws -> Int32 {
        try openFile(nodeID: nodeID, accessMode: .writeOnly, append: append)
    }

    public func openReadWrite(nodeID: UInt64, append: Bool = false) throws -> Int32 {
        try openFile(nodeID: nodeID, accessMode: .readWrite, append: append)
    }

    private struct OpenNodeSnapshot {
        var node: Node
        var identityFD: Int32
        var identityKey: FileKey
    }

    public func openFile(
        nodeID: UInt64,
        accessMode: HostFSAccessMode,
        append: Bool
    ) throws -> Int32 {
        guard !readOnly || !accessMode.permitsWrite else { throw HostFSError.readOnly }
        let snapshot = try pinNodeForOpen(nodeID: nodeID, retainOpenHandle: false)
        return try openFile(
            nodeID: nodeID,
            accessMode: accessMode,
            append: append,
            snapshot: snapshot
        )
    }

    /// Opens a FUSE file handle while atomically converting the kernel's lookup reference into an
    /// open-handle reference. FORGET may race OPEN on another request queue; reserving the handle
    /// under the same lock as the identity duplicate prevents that race from retiring the node.
    func openFileForFuseHandle(
        nodeID: UInt64,
        accessMode: HostFSAccessMode,
        append: Bool
    ) throws -> Int32 {
        guard !readOnly || !accessMode.permitsWrite else { throw HostFSError.readOnly }
        let snapshot = try pinNodeForOpen(nodeID: nodeID, retainOpenHandle: true)
        do {
            return try openFile(
                nodeID: nodeID,
                accessMode: accessMode,
                append: append,
                snapshot: snapshot
            )
        } catch {
            releaseOpenHandle(nodeID: nodeID)
            throw error
        }
    }

    private func openFile(
        nodeID: UInt64,
        accessMode: HostFSAccessMode,
        append: Bool,
        snapshot: OpenNodeSnapshot
    ) throws -> Int32 {
        let node = snapshot.node
        defer { Darwin.close(snapshot.identityFD) }
        openIdentityPinnedTestHook?(nodeID)
        guard node.attributes.isRegularFile else {
            throw HostFSError.notRegularFile(nodeID)
        }

        if node.fileKey.isSynthetic {
            var identityStatus = stat()
            guard fstat(snapshot.identityFD, &identityStatus) == 0 else {
                throw HostFSError.systemCall("fstat pinned open identity", errno)
            }
            try reconcileSyntheticIdentity(nodeID: nodeID, from: identityStatus)
        } else if snapshot.identityKey != node.fileKey {
            throw HostFSError.staleIdentity(nodeID)
        }
        if node.isDetached {
            return try reopenPinnedFile(
                nodeID: nodeID,
                identityFD: snapshot.identityFD,
                expectedKey: snapshot.identityKey,
                accessMode: accessMode,
                append: append
            )
        }

        let darwinAppend = append && accessMode.permitsWrite ? O_APPEND : 0
        let fd = openat(
            rootFD,
            cPath(node.relativePath),
            accessMode.darwinFlag | darwinAppend | O_CLOEXEC | Self.containedOpenFlags
        )
        guard fd >= 0 else {
            let savedErrno = errno
            var currentStatus = stat()
            if fstatat(
                rootFD,
                cPath(node.relativePath),
                &currentStatus,
                Self.containedStatFlags
            ) == 0, FileKey(currentStatus) != snapshot.identityKey {
                return try reopenAfterConfirmedPathReplacement(
                    node: node,
                    identityFD: snapshot.identityFD,
                    expectedKey: snapshot.identityKey,
                    accessMode: accessMode,
                    append: append
                )
            }
            if savedErrno == ENOENT || savedErrno == ENOTDIR {
                return try reopenAfterConfirmedPathReplacement(
                    node: node,
                    identityFD: snapshot.identityFD,
                    expectedKey: snapshot.identityKey,
                    accessMode: accessMode,
                    append: append
                )
            }
            if savedErrno == ELOOP {
                throw HostFSError.permissionDenied(node.relativePath)
            }
            throw HostFSError.systemCall("openat \(node.relativePath)", savedErrno)
        }
        let openedKey: FileKey
        do {
            openedKey = try fileKey(for: fd, operation: "fstat \(node.relativePath)")
        } catch {
            Darwin.close(fd)
            throw error
        }
        guard openedKey == snapshot.identityKey else {
            Darwin.close(fd)
            return try reopenAfterConfirmedPathReplacement(
                node: node,
                identityFD: snapshot.identityFD,
                expectedKey: snapshot.identityKey,
                accessMode: accessMode,
                append: append
            )
        }
        return fd
    }

    private func pinNodeForOpen(
        nodeID: UInt64,
        retainOpenHandle: Bool
    ) throws -> OpenNodeSnapshot {
        try lock.withLock {
            guard var node = nodes[nodeID] else {
                throw HostFSError.notFound("node \(nodeID)")
            }
            guard !node.isDetached || node.lookupCount > 0 else {
                throw HostFSError.staleIdentity(nodeID)
            }
            let fd = fcntl(node.identityFD, F_DUPFD_CLOEXEC, 0)
            guard fd >= 0 else {
                throw HostFSError.systemCall("duplicate pinned open identity", errno)
            }
            do {
                let identityKey = try fileKey(
                    for: fd,
                    operation: "fstat pinned open identity"
                )
                if retainOpenHandle {
                    let (sum, overflow) = node.openHandleCount.addingReportingOverflow(1)
                    node.openHandleCount = overflow ? UInt64.max : sum
                    nodes[nodeID] = node
                }
                return OpenNodeSnapshot(
                    node: node,
                    identityFD: fd,
                    identityKey: identityKey
                )
            } catch {
                Darwin.close(fd)
                throw error
            }
        }
    }

    private func reopenAfterConfirmedPathReplacement(
        node: Node,
        identityFD: Int32,
        expectedKey: FileKey,
        accessMode: HostFSAccessMode,
        append: Bool
    ) throws -> Int32 {
        do {
            let fd = try reopenPinnedFile(
                nodeID: node.id,
                identityFD: identityFD,
                expectedKey: expectedKey,
                accessMode: accessMode,
                append: append
            )
            detachSnapshotPathBinding(
                nodeID: node.id,
                relativePath: node.relativePath
            )
            return fd
        } catch {
            detachSnapshotPathBinding(
                nodeID: node.id,
                relativePath: node.relativePath
            )
            throw error
        }
    }

    private func reopenPinnedFile(
        nodeID: UInt64,
        identityFD: Int32,
        expectedKey: FileKey,
        accessMode: HostFSAccessMode,
        append: Bool
    ) throws -> Int32 {
        let appendFlag = append && accessMode.permitsWrite ? O_APPEND : 0
        let fd = Darwin.open(
            "/dev/fd/\(identityFD)",
            accessMode.darwinFlag | appendFlag | O_CLOEXEC
        )
        guard fd >= 0 else {
            throw HostFSError.systemCall("reopen pinned identity", errno)
        }
        do {
            guard try fileKey(for: fd, operation: "fstat reopened identity") == expectedKey else {
                throw HostFSError.staleIdentity(nodeID)
            }
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    private func fileKey(for fd: Int32, operation: String) throws -> FileKey {
        var status = stat()
        guard fstat(fd, &status) == 0 else {
            throw HostFSError.systemCall(operation, errno)
        }
        return FileKey(status)
    }

    public func readlink(nodeID: UInt64) throws -> String {
        let node = try attachedNode(for: nodeID)
        guard node.attributes.isSymlink else {
            throw HostFSError.notRegularFile(nodeID)
        }
        let fd = openat(
            rootFD,
            cPath(node.relativePath),
            O_RDONLY | O_CLOEXEC | Self.containedSymlinkOpenFlags
        )
        guard fd >= 0 else {
            let savedErrno = errno
            if savedErrno == ENOENT || savedErrno == ENOTDIR || savedErrno == ELOOP
                || savedErrno == ENOTCAPABLE {
                detach(nodeID: nodeID, recursive: false, linkRemovalConfirmed: true)
                if (try? attachedNode(for: nodeID)) != nil {
                    return try readlink(nodeID: nodeID)
                }
                throw HostFSError.staleIdentity(nodeID)
            }
            throw HostFSError.systemCall("open symlink \(node.relativePath)", savedErrno)
        }
        defer { Darwin.close(fd) }
        do {
            try validateOpenedIdentity(fd: fd, node: node)
        } catch HostFSError.staleIdentity where (try? attachedNode(for: nodeID)) != nil {
            return try readlink(nodeID: nodeID)
        } catch {
            throw error
        }
        var capacity = Int(PATH_MAX)
        while true {
            var buffer = [CChar](repeating: 0, count: capacity)
            let count = freadlink(fd, &buffer, capacity)
            guard count >= 0 else {
                let savedErrno = errno
                throw HostFSError.systemCall("readlink \(node.relativePath)", savedErrno)
            }
            if count < capacity {
                return String(decoding: buffer.prefix(count).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
            capacity *= 2
        }
    }

    public func read(handle fd: Int32, offset: UInt64, count: Int) throws -> [UInt8] {
        guard count >= 0 else { throw HostFSError.invalidName("read count") }
        guard let signedOffset = off_t(exactly: offset) else {
            throw HostFSError.invalidName("read offset")
        }
        let clampedCount = min(count, Self.maxReadCount)
        var buffer = [UInt8](repeating: 0, count: clampedCount)
        let readCount = pread(fd, &buffer, clampedCount, signedOffset)
        guard readCount >= 0 else {
            let savedErrno = errno
            throw HostFSError.systemCall("pread", savedErrno)
        }
        if readCount < clampedCount {
            buffer.removeSubrange(readCount..<buffer.count)
        }
        return buffer
    }

    @discardableResult
    public func write(
        handle fd: Int32,
        offset: UInt64,
        data: [UInt8],
        append: Bool = false
    ) throws -> Int {
        try data.withUnsafeBytes { raw in
            try write(handle: fd, offset: offset, bytes: raw, append: append)
        }
    }

    @discardableResult
    public func write(
        handle fd: Int32,
        offset: UInt64,
        bytes: UnsafeRawBufferPointer,
        append: Bool = false
    ) throws -> Int {
        guard !readOnly else { throw HostFSError.readOnly }
        guard let signedOffset = off_t(exactly: offset) else {
            throw HostFSError.invalidName("write offset")
        }
        let written = append
            ? Darwin.write(fd, bytes.baseAddress, bytes.count)
            : pwrite(fd, bytes.baseAddress, bytes.count, signedOffset)
        guard written >= 0 else {
            let savedErrno = errno
            throw HostFSError.systemCall(append ? "append write" : "pwrite", savedErrno)
        }
        return written
    }

    public func fsync(handle fd: Int32) throws {
        guard !readOnly else { throw HostFSError.readOnly }
        guard Darwin.fsync(fd) == 0 else {
            let savedErrno = errno
            throw HostFSError.systemCall("fsync", savedErrno)
        }
    }

    /// Applies a complete FUSE SETATTR request after validating every policy decision. Mutations use
    /// a descriptor whose device/inode/generation identity has been checked against the FUSE node,
    /// preventing a host-side path replacement from redirecting chmod, truncate, or timestamp updates.
    public func applySetattr(
        nodeID: UInt64,
        handle suppliedFD: Int32? = nil,
        request: HostFSSetattrRequest
    ) throws -> HostFSAttributes {
        if request.requestsMutation, readOnly {
            throw HostFSError.readOnly
        }

        let node = try suppliedFD == nil ? attachedNode(for: nodeID) : node(for: nodeID)
        if request.size != nil, !node.attributes.isRegularFile {
            throw HostFSError.notRegularFile(nodeID)
        }
        if request.requiresDescriptorMutation, node.attributes.isSymlink {
            throw HostFSError.operationNotSupported("setattr on symlink")
        }

        if let suppliedFD {
            let initialStatus = try verifiedStatus(handle: suppliedFD, node: node)
            return try applySetattr(request, nodeID: nodeID, handle: suppliedFD, initialStatus: initialStatus)
        }

        // UID/GID and Linux ctime writeback are policy-only no-ops on macOS. UID/GID are retained in
        // the FUSE node so the guest kernel can enforce the requested container ownership without
        // changing the macOS user's ownership of the backing tree.
        guard request.requiresDescriptorMutation else {
            updateVirtualOwnership(nodeID: nodeID, uid: request.uid, gid: request.gid)
            return try getattr(nodeID: nodeID)
        }

        let fd = try openSetattrHandle(node: node, requiresWrite: request.size != nil)
        defer { Darwin.close(fd) }
        let initialStatus = try verifiedStatus(handle: fd, node: node)
        return try applySetattr(request, nodeID: nodeID, handle: fd, initialStatus: initialStatus)
    }

    private func applySetattr(
        _ request: HostFSSetattrRequest,
        nodeID: UInt64,
        handle fd: Int32,
        initialStatus: stat
    ) throws -> HostFSAttributes {
        if let size = request.size {
            guard let signedSize = off_t(exactly: size) else {
                throw HostFSError.systemCall("ftruncate size", EOVERFLOW)
            }
            guard ftruncate(fd, signedSize) == 0 else {
                let savedErrno = errno
                throw HostFSError.systemCall("ftruncate", savedErrno)
            }
        }

        if let mode = request.mode {
            guard fchmod(fd, mode_t(mode & 0o7777)) == 0 else {
                let savedErrno = errno
                throw HostFSError.systemCall("fchmod", savedErrno)
            }
        } else if request.size != nil, !request.killSuidGid {
            // The host may clear set-id bits during ftruncate. Under HANDLE_KILLPRIV_V2 the absence
            // of FATTR_KILL_SUIDGID means the guest caller retained those privileges (CAP_FSETID), so
            // restore any bits the host removed rather than silently applying a stricter policy.
            let originalPrivileged = initialStatus.st_mode & mode_t(S_ISUID | S_ISGID)
            if originalPrivileged != 0 {
                var current = stat()
                guard fstat(fd, &current) == 0 else {
                    let savedErrno = errno
                    throw HostFSError.systemCall("fstat after ftruncate", savedErrno)
                }
                if current.st_mode & mode_t(S_ISUID | S_ISGID) != originalPrivileged {
                    let restored = (current.st_mode & ~mode_t(S_ISUID | S_ISGID)) | originalPrivileged
                    guard fchmod(fd, restored) == 0 else {
                        let savedErrno = errno
                        throw HostFSError.systemCall("restore set-id bits", savedErrno)
                    }
                }
            }
        }

        if request.killSuidGid {
            try clearPrivilegedBits(
                handle: fd,
                clearSetGIDRegardlessOfGroupExecute: request.uid != nil || request.gid != nil
            )
        }

        if request.atime != nil || request.mtime != nil {
            let times = try [
                timestamp(request.atime),
                timestamp(request.mtime),
            ]
            let result = times.withUnsafeBufferPointer { buffer in
                futimens(fd, buffer.baseAddress)
            }
            guard result == 0 else {
                let savedErrno = errno
                throw HostFSError.systemCall("futimens", savedErrno)
            }
        }

        var current = stat()
        guard fstat(fd, &current) == 0 else {
            let savedErrno = errno
            throw HostFSError.systemCall("fstat setattr result", savedErrno)
        }
        updateVirtualOwnership(nodeID: nodeID, uid: request.uid, gid: request.gid)
        return refreshCachedAttributes(nodeID: nodeID, from: current)
    }

    private func updateVirtualOwnership(nodeID: UInt64, uid: UInt32?, gid: UInt32?) {
        guard uid != nil || gid != nil else { return }
        lock.withLock {
            guard var node = nodes[nodeID] else { return }
            if let uid { node.attributes.uid = uid }
            if let gid { node.attributes.gid = gid }
            nodes[nodeID] = node
        }
    }

    private func timestamp(_ update: HostFSTimestampUpdate?) throws -> timespec {
        guard let update else {
            return timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT))
        }
        switch update {
        case .now:
            return timespec(tv_sec: 0, tv_nsec: Int(UTIME_NOW))
        case let .value(seconds, nanoseconds):
            guard nanoseconds < 1_000_000_000, let hostSeconds = time_t(exactly: seconds) else {
                throw HostFSError.systemCall("timestamp", EINVAL)
            }
            return timespec(tv_sec: hostSeconds, tv_nsec: Int(nanoseconds))
        }
    }

    private func openSetattrHandle(node: Node, requiresWrite: Bool) throws -> Int32 {
        let fd: Int32
        if node.relativePath.isEmpty {
            fd = dup(rootFD)
        } else {
            let access = requiresWrite ? O_WRONLY : O_RDONLY
            let directory = node.attributes.isDirectory ? O_DIRECTORY : 0
            fd = openat(
                rootFD,
                cPath(node.relativePath),
                access | directory | O_CLOEXEC | Self.containedOpenFlags
            )
        }
        guard fd >= 0 else {
            let savedErrno = errno
            throw HostFSError.systemCall("openat setattr \(node.relativePath)", savedErrno)
        }
        return fd
    }

    private func verifiedStatus(handle fd: Int32, node: Node) throws -> stat {
        if node.fileKey.isSynthetic, node.isDetached {
            throw HostFSError.notFound("node \(node.id)")
        }
        try validateOpenedIdentity(fd: fd, node: node)
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            let savedErrno = errno
            throw HostFSError.systemCall("fstat setattr handle", savedErrno)
        }
        return info
    }

    private func refreshCachedAttributes(nodeID: UInt64, from info: stat) -> HostFSAttributes {
        lock.withLock {
            guard var node = nodes[nodeID] else {
                return Self.attributes(
                    from: info,
                    nodeID: nodeID,
                    uid: guestUID,
                    gid: guestGID
                )
            }
            let attributes = Self.attributes(
                from: info,
                nodeID: nodeID,
                uid: node.attributes.uid,
                gid: node.attributes.gid
            )
            node.attributes = attributes
            node.linkCountIncludesAttachedBindings = false
            nodes[nodeID] = node
            return attributes
        }
    }

    // Clears set-user-ID and, for write/truncate, set-group-ID only when the file is group-executable.
    // Linux's HANDLE_KILLPRIV_V2 contract always clears SGID for ownership changes, hence the override.
    public func clearPrivilegedBits(
        handle fd: Int32,
        clearSetGIDRegardlessOfGroupExecute: Bool = false
    ) throws {
        guard !readOnly else { return }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            let savedErrno = errno
            throw HostFSError.systemCall("fstat killpriv", savedErrno)
        }
        var bitsToClear = info.st_mode & mode_t(S_ISUID)
        if clearSetGIDRegardlessOfGroupExecute || info.st_mode & mode_t(S_IXGRP) != 0 {
            bitsToClear |= info.st_mode & mode_t(S_ISGID)
        }
        guard bitsToClear != 0 else { return }
        guard fchmod(fd, info.st_mode & ~bitsToClear) == 0 else {
            let savedErrno = errno
            throw HostFSError.systemCall("fchmod killpriv", savedErrno)
        }
    }

    // nodeID variant of clearPrivilegedBits for the truncate path, which may not carry an open handle
    // (an O_TRUNC open arrives as SETATTR size with no fh). Opens the node write-only without following
    // symlinks, clears via the fd, and closes.
    public func clearPrivilegedBits(nodeID: UInt64) throws {
        guard !readOnly else { return }
        let node = try attachedNode(for: nodeID)
        guard node.attributes.isRegularFile else { return }
        let fd = openat(
            rootFD,
            cPath(node.relativePath),
            O_WRONLY | O_CLOEXEC | Self.containedOpenFlags
        )
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }
        try validateOpenedIdentity(fd: fd, node: node)
        try clearPrivilegedBits(handle: fd)
    }

    public func truncate(handle fd: Int32, size: UInt64) throws {
        guard !readOnly else { throw HostFSError.readOnly }
        guard let signedSize = off_t(exactly: size) else {
            throw HostFSError.invalidName("truncate size")
        }
        guard ftruncate(fd, signedSize) == 0 else {
            let savedErrno = errno
            throw HostFSError.systemCall("ftruncate", savedErrno)
        }
    }

    public func truncate(nodeID: UInt64, size: UInt64) throws {
        guard !readOnly else { throw HostFSError.readOnly }
        let node = try attachedNode(for: nodeID)
        guard node.attributes.isRegularFile else {
            throw HostFSError.notRegularFile(nodeID)
        }
        guard let signedSize = off_t(exactly: size) else {
            throw HostFSError.invalidName("truncate size")
        }
        let fd = openat(
            rootFD,
            cPath(node.relativePath),
            O_WRONLY | O_CLOEXEC | Self.containedOpenFlags
        )
        guard fd >= 0 else {
            let savedErrno = errno
            if savedErrno == ELOOP { throw HostFSError.permissionDenied(node.relativePath) }
            throw HostFSError.systemCall("openat truncate \(node.relativePath)", savedErrno)
        }
        defer { Darwin.close(fd) }
        try validateOpenedIdentity(fd: fd, node: node)
        guard ftruncate(fd, signedSize) == 0 else {
            let savedErrno = errno
            throw HostFSError.systemCall("ftruncate", savedErrno)
        }
    }

    public func close(handle fd: Int32) {
        Darwin.close(fd)
    }

    public func createFile(parent: UInt64, name: String, mode: UInt16 = 0o644) throws -> HostFSEntry {
        let created = try createFileAndOpen(parent: parent, name: name, mode: mode)
        Darwin.close(created.fd)
        return created.entry
    }

    public func createFileAndOpen(
        parent: UInt64,
        name: String,
        mode: UInt16 = 0o644,
        accessMode: HostFSAccessMode = .readWrite,
        preferredIdentityAccessMode: HostFSAccessMode? = nil,
        exclusive: Bool = false,
        truncate: Bool = false,
        append: Bool = false,
        syntheticAttributes: Bool = false,
        retainOpenHandle: Bool = false
    ) throws -> (entry: HostFSEntry, fd: Int32) {
        guard !readOnly else { throw HostFSError.readOnly }
        try validateComponent(name)
        try requireVisible(name, parent: parent)
        let parentNode = try attachedNode(for: parent)
        guard parentNode.attributes.isDirectory else { throw HostFSError.notDirectory(parent) }
        let relative = join(parentNode.relativePath, name)
        let createOptions = (exclusive ? O_EXCL : 0) | (truncate ? O_TRUNC : 0)
        // Descriptor exhaustion is checked before O_CREAT mutates the namespace so the forced
        // test path observes no created file. A real F_DUPFD_CLOEXEC failure after creation is
        // tolerated residue: RLIMIT_NOFILE is raised at startup, so that window requires an
        // exhaustion the rest of the server cannot survive either.
        if let forcedErrno = identityPinOpenTestErrno {
            throw HostFSError.systemCall("pin identity \(relative)", forcedErrno)
        }
        var accessCandidates = [HostFSAccessMode]()
        if let preferredIdentityAccessMode {
            accessCandidates.append(preferredIdentityAccessMode)
        }
        if !accessCandidates.contains(accessMode) {
            accessCandidates.append(accessMode)
        }
        var fd: Int32 = -1
        var savedErrno: Int32 = EACCES
        var openedCandidate = accessMode
        var openedWithAppend = false
        for candidate in accessCandidates {
            let appendRequested = append && candidate.permitsWrite
            fd = openat(
                rootFD,
                cPath(relative),
                O_CREAT | createOptions | (appendRequested ? O_APPEND : 0) | candidate.darwinFlag
                    | O_CLOEXEC | Self.containedOpenFlags,
                mode_t(mode)
            )
            if fd >= 0 {
                openedCandidate = candidate
                openedWithAppend = appendRequested
                break
            }
            savedErrno = errno
            guard savedErrno == EACCES || savedErrno == EPERM || savedErrno == EINVAL
                    || savedErrno == EROFS || savedErrno == ETXTBSY else {
                break
            }
        }
        guard fd >= 0 else {
            throw HostFSError.systemCall("create \(relative)", savedErrno)
        }
        do {
            let identity = try pinIdentity(
                duplicating: fd,
                accessMode: openedCandidate,
                appendAlreadySet: openedWithAppend,
                relativePath: relative
            )
            if syntheticAttributes {
                return (
                    registerCreatedFile(
                        name: name,
                        relativePath: relative,
                        mode: mode,
                        identity: identity,
                        retainOpenHandle: retainOpenHandle
                    ),
                    fd
                )
            }
            return (
                register(
                    name: name,
                    relativePath: relative,
                    identity: identity,
                    retainOpenHandle: retainOpenHandle
                ),
                fd
            )
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    public func mkdir(
        parent: UInt64,
        name: String,
        mode: UInt16 = 0o755,
        syntheticAttributes: Bool = false
    ) throws -> HostFSEntry {
        guard !readOnly else { throw HostFSError.readOnly }
        try validateComponent(name)
        try requireVisible(name, parent: parent)
        let parentNode = try attachedNode(for: parent)
        guard parentNode.attributes.isDirectory else { throw HostFSError.notDirectory(parent) }
        let relative = join(parentNode.relativePath, name)
        let stagingName = temporaryEntryName()
        let result = stagingName.withCString { pointer in
            mkdirat(rootFD, pointer, mode_t(mode))
        }
        guard result == 0 else {
            let savedErrno = errno
            throw HostFSError.systemCall("stage mkdir \(relative)", savedErrno)
        }
        let installResult = renameatx_np(
            rootFD,
            cPath(stagingName),
            rootFD,
            cPath(relative),
            Self.containedExclusiveRenameFlags
        )
        guard installResult == 0 else {
            let savedErrno = errno
            _ = unlinkat(rootFD, cPath(stagingName), AT_REMOVEDIR | Self.containedUnlinkFlags)
            throw HostFSError.systemCall("mkdir \(relative)", savedErrno)
        }
        if syntheticAttributes {
            return try registerCreatedDirectory(name: name, relativePath: relative, mode: mode)
        }
        return try lookup(parent: parent, name: name)
    }

    public func symlink(parent: UInt64, name: String, target: String) throws -> HostFSEntry {
        guard !readOnly else { throw HostFSError.readOnly }
        try validateComponent(name)
        try requireVisible(name, parent: parent)
        guard !target.isEmpty, !target.utf8.contains(0) else {
            throw HostFSError.invalidName(target)
        }
        let parentNode = try attachedNode(for: parent)
        guard parentNode.attributes.isDirectory else { throw HostFSError.notDirectory(parent) }
        let relative = join(parentNode.relativePath, name)
        let stagingName = temporaryEntryName()
        let result = target.withCString { targetPointer in
            stagingName.withCString { namePointer in
                symlinkat(targetPointer, rootFD, namePointer)
            }
        }
        guard result == 0 else {
            let savedErrno = errno
            throw HostFSError.systemCall("stage symlink \(relative)", savedErrno)
        }
        let installResult = renameatx_np(
            rootFD,
            cPath(stagingName),
            rootFD,
            cPath(relative),
            Self.containedExclusiveRenameFlags
        )
        guard installResult == 0 else {
            let savedErrno = errno
            _ = unlinkat(rootFD, cPath(stagingName), Self.containedUnlinkFlags)
            throw HostFSError.systemCall("symlink \(relative)", savedErrno)
        }
        return try lookup(parent: parent, name: name)
    }

    /// Creates a POSIX hard link and binds the new dentry to the source inode's existing canonical
    /// FUSE node. A pre/post identity check prevents a raced host replacement from silently linking
    /// a different object under the guest-requested name.
    public func link(nodeID: UInt64, newParent: UInt64, name: String) throws -> HostFSEntry {
        guard !readOnly else { throw HostFSError.readOnly }
        try validateComponent(name)
        try requireVisible(name, parent: newParent)
        let source = try attachedNode(for: nodeID)
        guard !source.attributes.isDirectory else {
            throw HostFSError.systemCall("link directory", EPERM)
        }
        let parent = try attachedNode(for: newParent)
        guard parent.attributes.isDirectory else { throw HostFSError.notDirectory(newParent) }
        let destination = join(parent.relativePath, name)
        let sourceIdentity = try identityStatus(for: source)
        let sourceKey = FileKey(sourceIdentity)
        if source.fileKey.isSynthetic {
            try reconcileSyntheticIdentity(nodeID: nodeID, from: sourceIdentity)
        }

        var before = stat()
        let sourceStatus = fstatat(
            rootFD,
            cPath(source.relativePath),
            &before,
            Self.containedStatFlags
        )
        if sourceStatus != 0 {
            let savedErrno = errno
            guard savedErrno == ENOENT || savedErrno == ENOTDIR else {
                throw HostFSError.systemCall("link source \(source.relativePath)", savedErrno)
            }
            detach(
                nodeID: nodeID,
                recursive: source.attributes.isDirectory,
                linkRemovalConfirmed: true
            )
            if let retry = try? attachedNode(for: nodeID) {
                return try link(nodeID: retry.id, newParent: newParent, name: name)
            }
            throw HostFSError.staleIdentity(nodeID)
        }
        if FileKey(before) != sourceKey {
            detach(
                nodeID: nodeID,
                recursive: source.attributes.isDirectory,
                linkRemovalConfirmed: true
            )
            if let retry = try? attachedNode(for: nodeID) {
                return try link(nodeID: retry.id, newParent: newParent, name: name)
            }
            throw HostFSError.staleIdentity(nodeID)
        }

        let result = linkat(
            rootFD,
            cPath(source.relativePath),
            rootFD,
            cPath(destination),
            Self.containedLinkFlags
        )
        guard result == 0 else {
            let savedErrno = errno
            throw HostFSError.systemCall("link \(destination)", savedErrno)
        }
        linkPostHostMutationTestHook?()

        var linked = stat()
        let statusResult = fstatat(
            rootFD,
            cPath(destination),
            &linked,
            Self.containedStatFlags
        )
        guard statusResult == 0 else {
            let savedErrno = errno
            // The new name may already have been removed or atomically replaced by the host. Its
            // identity is unknown, so pathname cleanup could delete an unrelated replacement.
            throw HostFSError.systemCall("verify hard link \(destination)", savedErrno)
        }
        guard FileKey(linked) == sourceKey else {
            // A mismatched destination may be a host replacement installed after linkat. Never
            // unlink it by name. Reconcile the source binding only when its own identity also moved.
            var currentSource = stat()
            let sourceResult = fstatat(
                rootFD,
                cPath(source.relativePath),
                &currentSource,
                Self.containedStatFlags
            )
            let sourceErrno = sourceResult == 0 ? 0 : errno
            if sourceResult == 0, FileKey(currentSource) != sourceKey {
                detach(
                    nodeID: nodeID,
                    recursive: source.attributes.isDirectory,
                    linkRemovalConfirmed: true
                )
            } else if sourceResult != 0, sourceErrno == ENOENT || sourceErrno == ENOTDIR {
                detach(
                    nodeID: nodeID,
                    recursive: source.attributes.isDirectory,
                    linkRemovalConfirmed: true
                )
            }
            throw HostFSError.staleIdentity(nodeID)
        }
        return try lock.withLock {
            guard let pinned = nodes[nodeID], pinnedFileKeyLocked(pinned) == sourceKey else {
                throw HostFSError.staleIdentity(nodeID)
            }
            bindPathLocked(nodeID: nodeID, relativePath: destination)
            let attrs = Self.attributes(
                from: linked,
                nodeID: nodeID,
                uid: pinned.attributes.uid,
                gid: pinned.attributes.gid
            )
            if var current = nodes[nodeID] {
                current.attributes = attrs
                current.linkCountIncludesAttachedBindings = true
                nodes[nodeID] = current
            }
            return HostFSEntry(name: name, nodeID: nodeID, attributes: attrs)
        }
    }

    public func unlink(parent: UInt64, name: String) throws {
        guard !readOnly else { throw HostFSError.readOnly }
        try validateComponent(name)
        try requireVisible(name, parent: parent)
        let parentNode = try attachedNode(for: parent)
        guard parentNode.attributes.isDirectory else { throw HostFSError.notDirectory(parent) }
        let relative = join(parentNode.relativePath, name)
        var before = stat()
        let removedLink: RemovedLinkState? = {
            guard fstatat(rootFD, cPath(relative), &before, Self.containedStatFlags) == 0 else {
                return nil
            }
            let linkCount = UInt32(clamping: UInt64(before.st_nlink))
            return RemovedLinkState(
                fileKey: FileKey(before),
                remainingLinkCount: linkCount > 0 ? linkCount - 1 : 0
            )
        }()
        let result = unlinkat(rootFD, cPath(relative), Self.containedUnlinkFlags)
        guard result == 0 else {
            let savedErrno = errno
            throw HostFSError.systemCall("unlink \(relative)", savedErrno)
        }
        unlinkPostHostMutationTestHook?()
        detach(
            relativePath: relative,
            recursive: false,
            linkRemovalConfirmed: removedLink == nil,
            removedLink: removedLink
        )
    }

    public func rmdir(parent: UInt64, name: String) throws {
        guard !readOnly else { throw HostFSError.readOnly }
        try validateComponent(name)
        try requireVisible(name, parent: parent)
        let parentNode = try attachedNode(for: parent)
        guard parentNode.attributes.isDirectory else { throw HostFSError.notDirectory(parent) }
        let relative = join(parentNode.relativePath, name)
        let result = unlinkat(
            rootFD,
            cPath(relative),
            AT_REMOVEDIR | Self.containedUnlinkFlags
        )
        guard result == 0 else {
            let savedErrno = errno
            throw HostFSError.systemCall("rmdir \(relative)", savedErrno)
        }
        detach(relativePath: relative, linkRemovalConfirmed: true)
    }

    public func rename(parent: UInt64, name: String, newParent: UInt64, newName: String) throws -> HostFSEntry {
        guard !readOnly else { throw HostFSError.readOnly }
        try validateComponent(name)
        try validateComponent(newName)
        try requireVisible(name, parent: parent)
        try requireVisible(newName, parent: newParent)
        let parentNode = try attachedNode(for: parent)
        let newParentNode = try attachedNode(for: newParent)
        guard parentNode.attributes.isDirectory else { throw HostFSError.notDirectory(parent) }
        guard newParentNode.attributes.isDirectory else { throw HostFSError.notDirectory(newParent) }
        let oldRelative = join(parentNode.relativePath, name)
        let newRelative = join(newParentNode.relativePath, newName)
        let result = renameatx_np(
            rootFD,
            cPath(oldRelative),
            rootFD,
            cPath(newRelative),
            Self.containedRenameFlags
        )
        guard result == 0 else {
            let savedErrno = errno
            throw HostFSError.systemCall("rename \(oldRelative)", savedErrno)
        }
        moveRegisteredPath(from: oldRelative, to: newRelative)
        return try lookup(parent: newParent, name: newName)
    }

    public func readdirplus(nodeID: UInt64) throws -> [HostFSEntry] {
        let node = try attachedNode(for: nodeID)
        guard node.attributes.isDirectory else {
            throw HostFSError.notDirectory(nodeID)
        }
        let path = node.relativePath.isEmpty ? "." : node.relativePath
        let fd = openat(
            rootFD,
            cPath(path),
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | Self.containedOpenFlags
        )
        guard fd >= 0 else {
            let savedErrno = errno
            if savedErrno == ENOENT || savedErrno == ENOTDIR || savedErrno == ELOOP
                || savedErrno == ENOTCAPABLE {
                detach(nodeID: nodeID, recursive: true, linkRemovalConfirmed: true)
                throw HostFSError.staleIdentity(nodeID)
            }
            throw HostFSError.systemCall("open directory \(node.relativePath)", savedErrno)
        }
        do {
            try validateOpenedIdentity(fd: fd, node: node)
        } catch {
            Darwin.close(fd)
            throw error
        }
        guard let directory = fdopendir(fd) else {
            let savedErrno = errno
            Darwin.close(fd)
            throw HostFSError.systemCall("fdopendir \(node.relativePath)", savedErrno)
        }
        defer { closedir(directory) }

        var names: [String] = []
        errno = 0
        while let entry = readdir(directory) {
            let length = Int(entry.pointee.d_namlen)
            let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes in
                String(decoding: bytes.prefix(length), as: UTF8.self)
            }
            if name != ".", name != "..", !isHiddenName(name, parent: nodeID) {
                names.append(name)
            }
            errno = 0
        }
        let savedErrno = errno
        guard savedErrno == 0 else {
            throw HostFSError.systemCall("readdir \(node.relativePath)", savedErrno)
        }
        var entries: [HostFSEntry] = []
        for name in names.sorted() {
            do {
                entries.append(try lookup(parent: nodeID, name: name))
            } catch HostFSError.operationNotSupported {
                // Unsupported host special files are intentionally absent from directory listings
                // for the same reason direct lookup rejects them: FUSE cannot safely proxy their
                // host-side blocking/IPC semantics.
                continue
            }
        }
        return entries
    }

    public func statfs() throws -> HostFSStat {
        var st = Darwin.statfs()
        guard Darwin.fstatfs(rootFD, &st) == 0 else {
            let savedErrno = errno
            throw HostFSError.systemCall("fstatfs", savedErrno)
        }
        return Self.hostFSStat(from: st)
    }

    /// Darwin's POSIX `statvfs` compatibility structure truncates block counts to 32 bits, which
    /// wraps host filesystems above 16 TiB at 4 KiB blocks. Keep the native `statfs` fields 64-bit
    /// all the way into FUSE_STATFS so large external pools cannot become false-ENOSPC mounts.
    static func hostFSStat(from st: Darwin.statfs) -> HostFSStat {
        let blockSize = UInt64(st.f_bsize)
        let blocks = UInt64(st.f_blocks)
        let blocksFree = UInt64(st.f_bfree)
        let blocksAvailable = UInt64(st.f_bavail)
        let files = UInt64(st.f_files)
        let filesFree = UInt64(st.f_ffree)
        let nameMax = UInt32(NAME_MAX)
        return HostFSStat(
            blockSize: blockSize,
            blocks: blocks,
            blocksFree: blocksFree,
            blocksAvailable: blocksAvailable,
            files: files,
            filesFree: filesFree,
            nameMax: nameMax
        )
    }

    public func setXattr(handle fd: Int32, name: String, value: [UInt8]) throws {
        guard !readOnly else { throw HostFSError.readOnly }
        let result = value.withUnsafeBytes { raw in
            fsetxattr(fd, name, raw.baseAddress, value.count, 0, 0)
        }
        guard result == 0 else {
            let savedErrno = errno
            throw HostFSError.systemCall("fsetxattr \(name)", savedErrno)
        }
    }

    public func getXattr(handle fd: Int32, name: String) throws -> [UInt8] {
        let size = fgetxattr(fd, name, nil, 0, 0, 0)
        guard size >= 0 else {
            let savedErrno = errno
            throw HostFSError.systemCall("fgetxattr \(name)", savedErrno)
        }
        var data = [UInt8](repeating: 0, count: size)
        let read = data.withUnsafeMutableBytes { raw in
            fgetxattr(fd, name, raw.baseAddress, size, 0, 0)
        }
        guard read >= 0 else {
            let savedErrno = errno
            throw HostFSError.systemCall("fgetxattr \(name)", savedErrno)
        }
        return data
    }

    public func listXattrs(handle fd: Int32) throws -> [String] {
        let size = flistxattr(fd, nil, 0, 0)
        guard size >= 0 else {
            let savedErrno = errno
            throw HostFSError.systemCall("flistxattr", savedErrno)
        }
        guard size > 0 else { return [] }
        var data = [CChar](repeating: 0, count: size)
        let read = flistxattr(fd, &data, size, 0)
        guard read >= 0 else {
            let savedErrno = errno
            throw HostFSError.systemCall("flistxattr", savedErrno)
        }
        return data.split(separator: 0).map { String(cString: Array($0) + [0]) }.sorted()
    }

    /// Records lookup references represented by successful `fuse_entry_out` replies. The guest may
    /// issue one FORGET for many accumulated lookups, so the count is saturating and 64-bit.
    public func retainLookup(nodeID: UInt64, count: UInt64 = 1) {
        guard nodeID != Self.rootNodeID, count > 0 else { return }
        lock.withLock {
            guard var node = nodes[nodeID] else { return }
            let (sum, overflow) = node.lookupCount.addingReportingOverflow(count)
            node.lookupCount = overflow ? UInt64.max : sum
            nodes[nodeID] = node
        }
    }

    public func retainLookups(nodeIDs: [UInt64]) {
        guard !nodeIDs.isEmpty else { return }
        lock.withLock {
            for nodeID in nodeIDs where nodeID != Self.rootNodeID {
                guard var node = nodes[nodeID] else { continue }
                let (sum, overflow) = node.lookupCount.addingReportingOverflow(1)
                node.lookupCount = overflow ? UInt64.max : sum
                nodes[nodeID] = node
            }
        }
    }

    /// Pins a node for a FUSE OPEN/OPENDIR handle. This reference is separate from lookup refs:
    /// FORGET is allowed to arrive while the handle remains usable.
    public func retainOpenHandle(nodeID: UInt64) throws {
        try lock.withLock {
            guard var node = nodes[nodeID] else {
                throw HostFSError.notFound("node \(nodeID)")
            }
            let (sum, overflow) = node.openHandleCount.addingReportingOverflow(1)
            node.openHandleCount = overflow ? UInt64.max : sum
            nodes[nodeID] = node
        }
    }

    /// Releases the identity pin owned by a FUSE file or directory handle. Unknown and duplicate
    /// releases are harmless; FuseServer removes a typed handle only once before calling this.
    public func releaseOpenHandle(nodeID: UInt64) {
        lock.withLock {
            guard var node = nodes[nodeID], node.openHandleCount > 0 else { return }
            node.openHandleCount -= 1
            nodes[nodeID] = node
            if nodeID != Self.rootNodeID, node.lookupCount == 0, node.openHandleCount == 0 {
                retireNodeLocked(nodeID)
            }
        }
    }

    /// Applies a FUSE_FORGET lookup decrement. Once the guest has released the final lookup, the
    /// node can be retired if no open handle still pins it; node IDs are monotonic and never reused.
    public func forgetLookup(nodeID: UInt64, count: UInt64) {
        guard nodeID != Self.rootNodeID, count > 0 else { return }
        lock.withLock {
            guard var node = nodes[nodeID] else { return }
            node.lookupCount = count >= node.lookupCount ? 0 : node.lookupCount - count
            if node.lookupCount == 0, node.openHandleCount == 0 {
                retireNodeLocked(nodeID)
            } else {
                nodes[nodeID] = node
            }
        }
    }

    /// Drops every reference owned by one FUSE connection. A transport reset starts a new node-id
    /// namespace from the guest's perspective, so retaining old lookup/open pins would both leak
    /// descriptors and let stale handles keep tombstones alive indefinitely.
    func resetFuseReferences() {
        lock.withLock {
            if var root = nodes[Self.rootNodeID] {
                root.lookupCount = 0
                root.openHandleCount = 0
                nodes[Self.rootNodeID] = root
            }
            let retired = nodes.keys.filter { $0 != Self.rootNodeID }
            for nodeID in retired {
                retireNodeLocked(nodeID)
            }
        }
    }

    private func node(for id: UInt64) throws -> Node {
        guard let node = lock.withLock({ nodes[id] }) else {
            throw HostFSError.notFound("node \(id)")
        }
        return node
    }

    private func attachedNode(for id: UInt64) throws -> Node {
        let node = try node(for: id)
        guard !node.isDetached else { throw HostFSError.staleIdentity(id) }
        return node
    }

    private func validateComponent(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw HostFSError.invalidName(name)
        }
    }

    private func requireVisible(_ name: String, parent: UInt64) throws {
        guard !isHiddenName(name, parent: parent) else {
            throw HostFSError.notFound(name)
        }
    }

    private func isHiddenName(_ name: String, parent: UInt64) -> Bool {
        isHiddenAtAnyDepth(name)
            || (parent == Self.rootNodeID && rootHiddenNameKeys.contains(Self.hiddenNameKey(name)))
    }

    private func isHiddenAtAnyDepth(_ name: String) -> Bool {
        hiddenNameKeys.contains(Self.hiddenNameKey(name))
    }

    private static func hiddenNameKey(_ name: String) -> String {
        name.lowercased()
    }

    private func detach(
        relativePath: String,
        recursive: Bool = true,
        linkRemovalConfirmed: Bool = false,
        removedLink: RemovedLinkState? = nil
    ) {
        lock.withLock {
            detachLocked(
                relativePath: relativePath,
                recursive: recursive,
                linkRemovalConfirmed: linkRemovalConfirmed,
                removedLink: removedLink
            )
        }
    }

    /// A fresh negative lookup is the dominant create-heavy path. If HostFS has never mapped the
    /// exact name, there cannot be an attached identity at that name to detach, so avoid scanning
    /// every registered descendant prefix. A previously mapped name may represent a removed
    /// directory, and must retain the recursive cleanup that retires its known children.
    private func detachLookupMiss(relativePath: String) {
        lock.withLock {
            let wasMapped = idsByRelativePath[relativePath]?.isEmpty == false
            detachLocked(
                relativePath: relativePath,
                recursive: wasMapped,
                linkRemovalConfirmed: true
            )
        }
    }

    private func detach(
        nodeID: UInt64,
        recursive: Bool,
        linkRemovalConfirmed: Bool = false
    ) {
        guard nodeID != Self.rootNodeID else { return }
        lock.withLock {
            guard let node = nodes[nodeID] else { return }
            let path = node.relativePath
            let stillOwnsPath = node.attachedPaths.contains(path)
            if recursive, stillOwnsPath {
                let prefix = path + "/"
                for descendant in idsByRelativePath.keys.filter({ $0.hasPrefix(prefix) }).sorted(by: { $0.count > $1.count }) {
                    guard let ids = idsByRelativePath[descendant] else { continue }
                    for id in ids {
                        detachPathBindingLocked(
                            nodeID: id,
                            relativePath: descendant,
                            linkRemovalConfirmed: linkRemovalConfirmed
                        )
                    }
                }
            }
            if stillOwnsPath {
                detachPathBindingLocked(
                    nodeID: nodeID,
                    relativePath: path,
                    linkRemovalConfirmed: linkRemovalConfirmed
                )
            }
        }
    }

    /// Detaches only the pathname captured by an OPEN snapshot. A guest RENAME can move the live
    /// binding after that snapshot but before openat(2); reloading `node.relativePath` here would
    /// incorrectly tombstone the destination that now names the same still-live inode.
    private func detachSnapshotPathBinding(
        nodeID: UInt64,
        relativePath: String,
        recursive: Bool = false
    ) {
        guard nodeID != Self.rootNodeID else { return }
        lock.withLock {
            guard let node = nodes[nodeID],
                  node.attachedPaths.contains(relativePath),
                  idsByRelativePath[relativePath]?.contains(nodeID) == true else {
                return
            }
            if recursive {
                let prefix = relativePath + "/"
                for descendant in idsByRelativePath.keys
                    .filter({ $0.hasPrefix(prefix) })
                    .sorted(by: { $0.count > $1.count }) {
                    for childID in idsByRelativePath[descendant] ?? [] {
                        detachPathBindingLocked(
                            nodeID: childID,
                            relativePath: descendant,
                            linkRemovalConfirmed: true
                        )
                    }
                }
            }
            detachPathBindingLocked(
                nodeID: nodeID,
                relativePath: relativePath,
                linkRemovalConfirmed: true
            )
        }
    }

    private func detachLocked(
        relativePath: String,
        recursive: Bool,
        excluding excludedIDs: Set<UInt64> = [],
        linkRemovalConfirmed: Bool = false,
        removedLink: RemovedLinkState? = nil
    ) {
        var affectedPaths = [relativePath]
        if recursive {
            affectedPaths.append(contentsOf: attachedDescendantPathsLocked(of: relativePath))
        }
        // Children first so a directory descriptor cannot survive after its parent mapping moves.
        for path in affectedPaths.sorted(by: { $0.count > $1.count }) {
            guard let mapped = idsByRelativePath[path] else { continue }
            let ids = mapped.filter { !excludedIDs.contains($0) }
            for id in ids {
                detachPathBindingLocked(
                    nodeID: id,
                    relativePath: path,
                    linkRemovalConfirmed: linkRemovalConfirmed,
                    removedLink: path == relativePath ? removedLink : nil
                )
            }
        }
    }

    /// Recomputes the child-name index from the two path key sets and compares it with the
    /// incrementally maintained copy. Any divergence means a mutation site missed its hook.
    func childIndexIsConsistentForTesting() -> Bool {
        lock.withLock {
            var expected: [String: Set<String>] = [:]
            for path in Set(idsByRelativePath.keys).union(detachedIDsByRelativePath.keys)
            where !path.isEmpty {
                let (parent, name) = splitParentLocked(path)
                expected[parent, default: []].insert(name)
            }
            return expected == knownChildNamesByParentPath
        }
    }

    private func splitParentLocked(_ path: String) -> (parent: String, name: String) {
        guard let separator = path.lastIndex(of: "/") else { return ("", path) }
        return (String(path[..<separator]), String(path[path.index(after: separator)...]))
    }

    private func notePathKeyPresentLocked(_ path: String) {
        guard !path.isEmpty else { return }
        let (parent, name) = splitParentLocked(path)
        knownChildNamesByParentPath[parent, default: []].insert(name)
    }

    private func notePathKeyMaybeAbsentLocked(_ path: String) {
        guard !path.isEmpty,
              idsByRelativePath[path] == nil,
              detachedIDsByRelativePath[path] == nil else { return }
        let (parent, name) = splitParentLocked(path)
        knownChildNamesByParentPath[parent]?.remove(name)
        if knownChildNamesByParentPath[parent]?.isEmpty == true {
            knownChildNamesByParentPath.removeValue(forKey: parent)
        }
    }

    /// Depth-first walk of the known subtree below `relativePath`, returning only paths with live
    /// attached bindings. Cost is proportional to the actual known subtree, not the whole index.
    private func attachedDescendantPathsLocked(of relativePath: String) -> [String] {
        var result = [String]()
        var stack = [relativePath]
        while let directory = stack.popLast() {
            for name in knownChildNamesByParentPath[directory] ?? [] {
                let child = directory.isEmpty ? name : directory + "/" + name
                stack.append(child)
                if idsByRelativePath[child] != nil { result.append(child) }
            }
        }
        return result
    }

    private func insertFileKeyIndexLocked(_ key: FileKey, nodeID: UInt64) {
        idsByFileKey[key, default: []].insert(nodeID)
    }

    private func removeFileKeyIndexLocked(_ key: FileKey, nodeID: UInt64) {
        idsByFileKey[key]?.remove(nodeID)
        if idsByFileKey[key]?.isEmpty == true {
            idsByFileKey.removeValue(forKey: key)
        }
    }

    private func refreshTombstonedLinkCountLocked(nodeID id: UInt64) {
        guard var node = nodes[id], !node.tombstonePaths.isEmpty else { return }
        var identityStatus = stat()
        guard fstat(node.identityFD, &identityStatus) == 0 else { return }
        node.attributes.linkCount = UInt32(clamping: UInt64(identityStatus.st_nlink))
        node.linkCountIncludesAttachedBindings = false
        if node.isDetached, node.attributes.linkCount == 0 {
            removeFileKeyIndexLocked(node.fileKey, nodeID: id)
        }
        nodes[id] = node
    }

    /// Removes one directory-entry binding without destroying a canonical hard-link identity that
    /// still has another live name. The stale path remains indexed only while lookup/open refs pin
    /// the node, allowing a later host event to target the old dentry precisely.
    private func detachPathBindingLocked(
        nodeID id: UInt64,
        relativePath: String,
        linkRemovalConfirmed: Bool = false,
        removedLink: RemovedLinkState? = nil
    ) {
        guard id != Self.rootNodeID, var node = nodes[id],
              node.attachedPaths.remove(relativePath) != nil else {
            return
        }
        let cachedCountIncludesRemovedBinding = node.linkCountIncludesAttachedBindings

        idsByRelativePath[relativePath]?.removeAll { $0 == id }
        if idsByRelativePath[relativePath]?.isEmpty == true {
            idsByRelativePath.removeValue(forKey: relativePath)
        }
        node.tombstonePaths.insert(relativePath)
        detachedIDsByRelativePath[relativePath, default: []].insert(id)

        // Prefer the real post-unlink count from a surviving alias. This avoids double-decrementing
        // when an fd-based getattr already observed the host unlink before its pathname reconciled.
        var reconciledLinkCount = false
        let identityKey = pinnedFileKeyLocked(node)
        for path in node.attachedPaths {
            var status = stat()
            let result = path.isEmpty
                ? fstat(rootFD, &status)
                : fstatat(rootFD, cPath(path), &status, Self.containedStatFlags)
            if result == 0, FileKey(status) == identityKey {
                node.attributes = Self.attributes(
                    from: status,
                    nodeID: id,
                    uid: node.attributes.uid,
                    gid: node.attributes.gid
                )
                node.linkCountIncludesAttachedBindings = true
                reconciledLinkCount = true
                break
            }
        }
        if !reconciledLinkCount,
           let removedLink,
           identityKey == removedLink.fileKey {
            // This count is derived from the exact identity observed immediately before unlinkat.
            // It is stable even if a handle fstat publishes the post-unlink nlink in the window
            // before this binding is detached from the HostFS indexes.
            node.attributes.linkCount = removedLink.remainingLinkCount
            node.linkCountIncludesAttachedBindings = true
            reconciledLinkCount = true
        }
        if !reconciledLinkCount, linkRemovalConfirmed {
            // A host-side unlink/replacement may race a handle GETATTR on either side of the
            // mutation. The retained identity descriptor is authoritative after the pathname has
            // been proven stale: nlink is zero for a final removal and remains positive for even
            // an as-yet-unseen hard-link alias. Prefer it over guessing whether a cached handle
            // count already excluded the binding being detached.
            var identityStatus = stat()
            if fstat(node.identityFD, &identityStatus) == 0,
               FileKey(identityStatus) == identityKey {
                node.attributes.linkCount = UInt32(clamping: UInt64(identityStatus.st_nlink))
                node.linkCountIncludesAttachedBindings = false
                reconciledLinkCount = true
            }
        }
        if !reconciledLinkCount,
           cachedCountIncludesRemovedBinding || linkRemovalConfirmed {
            // Every detached non-directory binding represented one host link. Directory nlink has
            // parent/child semantics, but a directory with no remaining binding is unlinked.
            if node.attributes.isDirectory {
                if node.attachedPaths.isEmpty { node.attributes.linkCount = 0 }
            } else if node.attributes.linkCount > 0 {
                node.attributes.linkCount -= 1
            }
        }

        if node.relativePath == relativePath {
            node.relativePath = node.attachedPaths.first ?? relativePath
        }
        if node.attachedPaths.isEmpty {
            // A positive nlink proves an as-yet-unresolved alias may still exist. Keep the identity
            // index while FUSE refs pin this tombstone so discovering that alias reuses nodeID.
            if node.attributes.linkCount == 0 {
                removeFileKeyIndexLocked(node.fileKey, nodeID: id)
            }
        }
        nodes[id] = node
        if node.attachedPaths.isEmpty, node.lookupCount == 0, node.openHandleCount == 0 {
            retireNodeLocked(id)
        }
    }

    /// Adds a live pathname to an existing canonical inode and clears an older tombstone for the
    /// same node/path if that name was removed and later linked back to the inode.
    private func bindPathLocked(nodeID id: UInt64, relativePath: String) {
        guard var node = nodes[id] else { return }
        let wasDetached = node.attachedPaths.isEmpty
        let inserted = node.attachedPaths.insert(relativePath).inserted
        if inserted, idsByRelativePath[relativePath]?.contains(id) != true {
            idsByRelativePath[relativePath, default: []].append(id)
            notePathKeyPresentLocked(relativePath)
        }
        if wasDetached {
            node.relativePath = relativePath
            insertFileKeyIndexLocked(node.fileKey, nodeID: id)
        }
        if node.tombstonePaths.remove(relativePath) != nil {
            detachedIDsByRelativePath[relativePath]?.remove(id)
            if detachedIDsByRelativePath[relativePath]?.isEmpty == true {
                detachedIDsByRelativePath.removeValue(forKey: relativePath)
            }
            notePathKeyMaybeAbsentLocked(relativePath)
        }
        nodes[id] = node
    }

    /// Moves one live binding without changing the host inode's link count. Other hard-link names
    /// on the same node remain untouched.
    private func movePathBindingLocked(nodeID id: UInt64, from source: String, to destination: String) {
        guard var node = nodes[id], node.attachedPaths.remove(source) != nil else { return }
        idsByRelativePath[source]?.removeAll { $0 == id }
        if idsByRelativePath[source]?.isEmpty == true {
            idsByRelativePath.removeValue(forKey: source)
        }
        notePathKeyMaybeAbsentLocked(source)
        node.attachedPaths.insert(destination)
        if idsByRelativePath[destination]?.contains(id) != true {
            idsByRelativePath[destination, default: []].append(id)
            notePathKeyPresentLocked(destination)
        }
        if node.relativePath == source { node.relativePath = destination }
        if node.tombstonePaths.remove(destination) != nil {
            detachedIDsByRelativePath[destination]?.remove(id)
            if detachedIDsByRelativePath[destination]?.isEmpty == true {
                detachedIDsByRelativePath.removeValue(forKey: destination)
            }
            notePathKeyMaybeAbsentLocked(destination)
        }
        nodes[id] = node
    }

    private func retireNodeLocked(_ id: UInt64) {
        guard id != Self.rootNodeID, let node = nodes.removeValue(forKey: id) else { return }
        removeFileKeyIndexLocked(node.fileKey, nodeID: id)
        for path in node.tombstonePaths {
            detachedIDsByRelativePath[path]?.remove(id)
            if detachedIDsByRelativePath[path]?.isEmpty == true {
                detachedIDsByRelativePath.removeValue(forKey: path)
            }
            notePathKeyMaybeAbsentLocked(path)
        }
        for path in node.attachedPaths {
            idsByRelativePath[path]?.removeAll { $0 == id }
            if idsByRelativePath[path]?.isEmpty == true {
                idsByRelativePath.removeValue(forKey: path)
            }
            notePathKeyMaybeAbsentLocked(path)
        }
        closeIdentityFD(node.identityFD, nodeID: id)
    }

    /// A guest-issued rename preserves the FUSE identity of the source and every registered child.
    /// If the rename overwrote a destination, those destination nodes become tombstones first.
    private func moveRegisteredPath(from oldPath: String, to newPath: String) {
        guard oldPath != newPath else { return }
        lock.withLock {
            // POSIX rename is a no-op when both names are hard links to the same inode.
            let oldIDs = Set(idsByRelativePath[oldPath] ?? [])
            let newIDs = Set(idsByRelativePath[newPath] ?? [])
            if !oldIDs.isDisjoint(with: newIDs) { return }

            let oldPrefix = oldPath + "/"
            let movingPaths = idsByRelativePath.keys
                .filter { $0 == oldPath || $0.hasPrefix(oldPrefix) }
                .sorted { $0.count < $1.count }
            let movingIDs = Set(movingPaths.flatMap { idsByRelativePath[$0] ?? [] })

            detachLocked(
                relativePath: newPath,
                recursive: true,
                excluding: movingIDs,
                linkRemovalConfirmed: true
            )
            for source in movingPaths {
                guard let ids = idsByRelativePath[source] else { continue }
                let suffix = String(source.dropFirst(oldPath.count))
                let destination = newPath + suffix
                for id in ids {
                    movePathBindingLocked(nodeID: id, from: source, to: destination)
                }
            }
        }
    }

    private func register(
        name: String,
        relativePath: String,
        identity: PinnedIdentity,
        retainOpenHandle: Bool = false
    ) -> HostFSEntry {
        let st = identity.status
        let key = FileKey(st)
        let result = lock.withLock { () -> (entry: HostFSEntry, retainedIdentityFD: Bool) in
            if let currentID = idsByRelativePath[relativePath]?.first,
               var current = nodes[currentID], !current.isDetached {
                // The pathname cache is only advisory. Coalesce when the descriptor that pins the
                // existing node still identifies the object opened for this registration.
                if pinnedFileKeyLocked(current) == key {
                    if current.fileKey != key {
                        if let canonicalID = canonicalNodeIDLocked(for: key, excluding: currentID) {
                            // A synthetic fast-create identity raced discovery through another hard
                            // link. It was already exposed and cannot be retargeted, so tombstone it
                            // and make this pathname resolve to the established canonical identity.
                            detachPathBindingLocked(nodeID: currentID, relativePath: relativePath)
                            bindPathLocked(nodeID: canonicalID, relativePath: relativePath)
                            let canonicalOwner = nodes[canonicalID]?.attributes
                            let attrs = Self.attributes(
                                from: st,
                                nodeID: canonicalID,
                                uid: canonicalOwner?.uid ?? guestUID,
                                gid: canonicalOwner?.gid ?? guestGID
                            )
                            if var canonical = nodes[canonicalID] {
                                canonical.attributes = attrs
                                canonical.linkCountIncludesAttachedBindings = true
                                if retainOpenHandle {
                                    let (sum, overflow) = canonical.openHandleCount.addingReportingOverflow(1)
                                    canonical.openHandleCount = overflow ? UInt64.max : sum
                                }
                                nodes[canonicalID] = canonical
                            }
                            return (
                                HostFSEntry(name: name, nodeID: canonicalID, attributes: attrs),
                                false
                            )
                        }
                        removeFileKeyIndexLocked(current.fileKey, nodeID: currentID)
                        current.fileKey = key
                        insertFileKeyIndexLocked(key, nodeID: currentID)
                    }
                    let attrs = Self.attributes(
                        from: st,
                        nodeID: currentID,
                        uid: current.attributes.uid,
                        gid: current.attributes.gid
                    )
                    current.attributes = attrs
                    current.linkCountIncludesAttachedBindings = true
                    if retainOpenHandle {
                        let (sum, overflow) = current.openHandleCount.addingReportingOverflow(1)
                        current.openHandleCount = overflow ? UInt64.max : sum
                    }
                    nodes[currentID] = current
                    return (HostFSEntry(name: name, nodeID: currentID, attributes: attrs), false)
                }

                // Same path, different host identity: the old node remains a tombstone while it has
                // live lookup refs. A fresh monotonic node id is allocated below for the replacement.
                detachLocked(
                    relativePath: relativePath,
                    recursive: current.attributes.isDirectory,
                    linkRemovalConfirmed: true
                )
            }

            if let canonicalID = canonicalNodeIDLocked(for: key) {
                bindPathLocked(nodeID: canonicalID, relativePath: relativePath)
                let canonicalOwner = nodes[canonicalID]?.attributes
                let attrs = Self.attributes(
                    from: st,
                    nodeID: canonicalID,
                    uid: canonicalOwner?.uid ?? guestUID,
                    gid: canonicalOwner?.gid ?? guestGID
                )
                if var canonical = nodes[canonicalID] {
                    canonical.attributes = attrs
                    canonical.linkCountIncludesAttachedBindings = true
                    if retainOpenHandle {
                        let (sum, overflow) = canonical.openHandleCount.addingReportingOverflow(1)
                        canonical.openHandleCount = overflow ? UInt64.max : sum
                    }
                    nodes[canonicalID] = canonical
                }
                return (HostFSEntry(name: name, nodeID: canonicalID, attributes: attrs), false)
            }

            let id = nextNodeID
            nextNodeID += 1
            let attrs = Self.attributes(from: st, nodeID: id, uid: guestUID, gid: guestGID)
            nodes[id] = Node(
                id: id,
                relativePath: relativePath,
                attachedPaths: [relativePath],
                attributes: attrs,
                fileKey: key,
                identityFD: identity.fd,
                openHandleCount: retainOpenHandle ? 1 : 0
            )
            insertFileKeyIndexLocked(key, nodeID: id)
            if idsByRelativePath[relativePath]?.contains(id) != true {
                idsByRelativePath[relativePath, default: []].append(id)
                notePathKeyPresentLocked(relativePath)
            }
            return (HostFSEntry(name: name, nodeID: id, attributes: attrs), true)
        }
        if !result.retainedIdentityFD {
            Darwin.close(identity.fd)
        }
        notifyEventObservation(for: relativePath)
        return result.entry
    }

    private func registerCreatedFile(
        name: String,
        relativePath: String,
        mode: UInt16,
        identity: PinnedIdentity,
        retainOpenHandle: Bool = false
    ) -> HostFSEntry {
        return registerCreatedNode(
            name: name,
            relativePath: relativePath,
            mode: mode,
            type: UInt32(S_IFREG),
            identity: identity,
            retainOpenHandle: retainOpenHandle
        )
    }

    private func registerCreatedDirectory(
        name: String,
        relativePath: String,
        mode: UInt16
    ) throws -> HostFSEntry {
        let identity = try pinIdentity(relativePath: relativePath, expectedMode: mode_t(S_IFDIR))
        return registerCreatedNode(
            name: name,
            relativePath: relativePath,
            mode: mode,
            type: UInt32(S_IFDIR),
            identity: identity
        )
    }

    private func registerCreatedNode(
        name: String,
        relativePath: String,
        mode: UInt16,
        type: UInt32,
        identity: PinnedIdentity,
        retainOpenHandle: Bool = false
    ) -> HostFSEntry {
        var ts = timespec()
        clock_gettime(CLOCK_REALTIME, &ts)
        let entry = lock.withLock {
            // CREATE/MKDIR should normally follow a negative lookup, but a raced host replacement
            // can leave an older identity registered at the same path. Never overwrite that node.
            detachLocked(
                relativePath: relativePath,
                recursive: true,
                linkRemovalConfirmed: true
            )
            let id = nextNodeID
            nextNodeID += 1
            let key = FileKey(syntheticNodeID: id)
            let attrs = HostFSAttributes(
                nodeID: id,
                mode: type | UInt32(mode),
                size: 0,
                linkCount: type == UInt32(S_IFDIR) ? 2 : 1,
                uid: guestUID,
                gid: guestGID,
                atimeSeconds: Int64(ts.tv_sec),
                mtimeSeconds: Int64(ts.tv_sec),
                ctimeSeconds: Int64(ts.tv_sec),
                atimeNsec: UInt32(truncatingIfNeeded: ts.tv_nsec),
                mtimeNsec: UInt32(truncatingIfNeeded: ts.tv_nsec),
                ctimeNsec: UInt32(truncatingIfNeeded: ts.tv_nsec)
            )
            nodes[id] = Node(
                id: id,
                relativePath: relativePath,
                attachedPaths: [relativePath],
                attributes: attrs,
                fileKey: key,
                identityFD: identity.fd,
                openHandleCount: retainOpenHandle ? 1 : 0
            )
            insertFileKeyIndexLocked(key, nodeID: id)
            idsByRelativePath[relativePath, default: []].append(id)
            notePathKeyPresentLocked(relativePath)
            return HostFSEntry(name: name, nodeID: id, attributes: attrs)
        }
        notifyEventObservation(for: relativePath)
        return entry
    }

    private func join(_ parent: String, _ name: String) -> String {
        parent.isEmpty ? name : parent + "/" + name
    }

    private func pinIdentity(relativePath: String, expectedMode: mode_t) throws -> PinnedIdentity {
        let operation = "pin identity \(relativePath)"
        if let forcedErrno = identityPinOpenTestErrno {
            throw HostFSError.systemCall(operation, forcedErrno)
        }

        let fileType = expectedMode & mode_t(S_IFMT)
        let containmentFlags = fileType == mode_t(S_IFLNK)
            ? Self.containedSymlinkOpenFlags
            : Self.containedOpenFlags
        let directoryFlag = fileType == mode_t(S_IFDIR) ? O_DIRECTORY : 0
        // LOOKUP pins every visible host identity before FUSE OPEN can reject unsupported file
        // kinds. Opening a FIFO read-only without O_NONBLOCK waits for a writer and can therefore
        // wedge the request queue merely by resolving the pathname. Keep special-file identity
        // discovery non-blocking; regular files, directories, and symlinks retain their existing
        // open semantics.
        // Always use O_NONBLOCK because the path may be replaced with a FIFO after the caller's
        // namespace stat but before openat. It is inert for regular files and directories.
        let nonBlockingFlag = O_NONBLOCK
        let accessCandidates: [Int32]
        if fileType == mode_t(S_IFREG), !readOnly {
            // One descriptor pins both identity and every access mode the host user currently has.
            // O_APPEND is harmless for positional pwrite(2), but lets a logical append handle use
            // write(2) atomically after the pathname has been replaced.
            accessCandidates = [O_RDWR | O_APPEND, O_RDONLY, O_WRONLY | O_APPEND]
        } else {
            accessCandidates = [O_RDONLY]
        }
        var fd: Int32 = -1
        var savedErrno: Int32 = EACCES
        for access in accessCandidates {
            fd = openat(
                rootFD,
                cPath(relativePath),
                O_EVTONLY | access | O_CLOEXEC | directoryFlag | nonBlockingFlag
                    | containmentFlags
            )
            if fd >= 0 { break }
            savedErrno = errno
            guard savedErrno == EACCES || savedErrno == EPERM || savedErrno == EINVAL
                    || savedErrno == EROFS || savedErrno == ETXTBSY else {
                throw HostFSError.systemCall(operation, savedErrno)
            }
        }
        guard fd >= 0 else { throw HostFSError.systemCall(operation, savedErrno) }

        var status = stat()
        guard fstat(fd, &status) == 0 else {
            let savedErrno = errno
            Darwin.close(fd)
            throw HostFSError.systemCall("fstat identity \(relativePath)", savedErrno)
        }
        guard Self.isSupportedFileType(status.st_mode) else {
            Darwin.close(fd)
            throw HostFSError.operationNotSupported("special host file: \(relativePath)")
        }
        identityPinPostOpenTestHook?(relativePath, fd)
        return PinnedIdentity(fd: fd, status: status)
    }

    private static func isSupportedFileType(_ mode: mode_t) -> Bool {
        switch mode & mode_t(S_IFMT) {
        case mode_t(S_IFREG), mode_t(S_IFDIR), mode_t(S_IFLNK):
            return true
        default:
            return false
        }
    }

    /// Pins the identity of a just-created file with one duplicate of its open descriptor. The
    /// caller constructed the descriptor's flags, so the O_APPEND fixup that a path-based pin must
    /// probe with F_GETFL is decided directly: writable identity descriptors keep O_APPEND so a
    /// logical append handle can reopen them after a pathname replacement. With RLIMIT_NOFILE
    /// raised at startup, a failed duplicate closes the created descriptor and surfaces EMFILE
    /// instead of paying a reservation descriptor on every create in an install storm.
    private func pinIdentity(
        duplicating fd: Int32,
        accessMode: HostFSAccessMode,
        appendAlreadySet: Bool,
        relativePath: String
    ) throws -> PinnedIdentity {
        let identityFD = fcntl(fd, F_DUPFD_CLOEXEC, 0)
        guard identityFD >= 0 else {
            let savedErrno = errno
            throw HostFSError.systemCall("pin identity \(relativePath)", savedErrno)
        }
        var status = stat()
        guard fstat(identityFD, &status) == 0 else {
            let savedErrno = errno
            Darwin.close(identityFD)
            throw HostFSError.systemCall("fstat identity \(relativePath)", savedErrno)
        }
        if status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
           accessMode != .readOnly,
           status.st_mode & 0o222 != 0,
           !appendAlreadySet,
           fcntl(identityFD, F_SETFL, accessMode.darwinFlag | O_APPEND) != 0 {
            let savedErrno = errno
            Darwin.close(identityFD)
            throw HostFSError.systemCall("set identity append \(relativePath)", savedErrno)
        }
        return PinnedIdentity(fd: identityFD, status: status)
    }

    /// Reads the pinned identity atomically with the node table. Retirement closes `identityFD`
    /// under the same lock, so a FORGET racing an in-flight request on another queue can neither
    /// surface EBADF nor let a recycled descriptor number impersonate this node's identity and
    /// misclassify a live path as replaced.
    private func identityStatus(for node: Node) throws -> stat {
        try lock.withLock {
            guard let current = nodes[node.id] else {
                throw HostFSError.staleIdentity(node.id)
            }
            var status = stat()
            guard fstat(current.identityFD, &status) == 0 else {
                let savedErrno = errno
                throw HostFSError.systemCall("fstat identity \(current.relativePath)", savedErrno)
            }
            return status
        }
    }

    private func pinnedFileKeyLocked(_ node: Node) -> FileKey? {
        var status = stat()
        guard fstat(node.identityFD, &status) == 0 else { return nil }
        return FileKey(status)
    }

    private func pinnedLinkCountLocked(_ node: Node) -> UInt32? {
        var status = stat()
        guard fstat(node.identityFD, &status) == 0 else { return nil }
        return UInt32(clamping: UInt64(status.st_nlink))
    }

    private func closeIdentityFD(_ fd: Int32, nodeID: UInt64) {
        Darwin.close(fd)
        identityPinClosedTestHook?(nodeID, fd)
    }

    private func canonicalNodeIDLocked(for key: FileKey, excluding excludedID: UInt64? = nil) -> UInt64? {
        (idsByFileKey[key] ?? [])
            .filter { id in
                guard id != excludedID, let node = nodes[id] else { return false }
                guard !node.isDetached || node.attributes.linkCount > 0 else { return false }
                return pinnedFileKeyLocked(node) == key
            }
            .min()
    }

    private func validateOpenedIdentity(fd: Int32, node: Node) throws {
        var opened = stat()
        guard fstat(fd, &opened) == 0 else {
            let savedErrno = errno
            throw HostFSError.systemCall("fstat \(node.relativePath)", savedErrno)
        }
        let identity = try identityStatus(for: node)
        let openedKey = FileKey(opened)
        let identityKey = FileKey(identity)
        guard openedKey == identityKey else {
            detach(
                nodeID: node.id,
                recursive: node.attributes.isDirectory,
                linkRemovalConfirmed: true
            )
            throw HostFSError.staleIdentity(node.id)
        }
        if node.fileKey.isSynthetic {
            try reconcileSyntheticIdentity(nodeID: node.id, from: identity)
            return
        }
        guard identityKey == node.fileKey else {
            detach(
                nodeID: node.id,
                recursive: node.attributes.isDirectory,
                linkRemovalConfirmed: true
            )
            throw HostFSError.staleIdentity(node.id)
        }
    }

    /// Reconciles an experimental synthetic CREATE/MKDIR identity without allowing it to become a
    /// second live node for an already-known hard-linked inode. An exposed synthetic ID cannot be
    /// retargeted to a different canonical ID, so a collision is tombstoned and reported ESTALE.
    private func reconcileSyntheticIdentity(nodeID: UInt64, from info: stat) throws {
        let key = FileKey(info)
        let collided: Bool = lock.withLock {
            guard var current = nodes[nodeID], !current.isDetached, current.fileKey.isSynthetic else {
                return false
            }
            if let canonicalID = canonicalNodeIDLocked(for: key, excluding: nodeID) {
                let paths = current.attachedPaths
                for path in paths {
                    detachPathBindingLocked(nodeID: nodeID, relativePath: path)
                    bindPathLocked(nodeID: canonicalID, relativePath: path)
                }
                if var canonical = nodes[canonicalID] {
                    canonical.attributes = Self.attributes(
                        from: info,
                        nodeID: canonicalID,
                        uid: canonical.attributes.uid,
                        gid: canonical.attributes.gid
                    )
                    canonical.linkCountIncludesAttachedBindings = false
                    nodes[canonicalID] = canonical
                }
                return true
            }
            removeFileKeyIndexLocked(current.fileKey, nodeID: nodeID)
            current.fileKey = key
            current.attributes = Self.attributes(
                from: info,
                nodeID: nodeID,
                uid: current.attributes.uid,
                gid: current.attributes.gid
            )
            current.linkCountIncludesAttachedBindings = false
            insertFileKeyIndexLocked(key, nodeID: nodeID)
            nodes[nodeID] = current
            return false
        }
        if collided { throw HostFSError.staleIdentity(nodeID) }
    }

    private func temporaryEntryName() -> String {
        ".dory-hostfs-stage-\(UUID().uuidString)"
    }

    private func cPath(_ relative: String) -> [CChar] {
        relative.isEmpty ? [0] : Array(relative.utf8CString)
    }

    private static func attributes(from st: stat, nodeID: UInt64, uid: UInt32, gid: UInt32) -> HostFSAttributes {
        HostFSAttributes(
            nodeID: nodeID,
            mode: UInt32(st.st_mode),
            size: UInt64(max(0, st.st_size)),
            linkCount: UInt32(clamping: UInt64(st.st_nlink)),
            uid: uid,
            gid: gid,
            atimeSeconds: Int64(st.st_atimespec.tv_sec),
            mtimeSeconds: Int64(st.st_mtimespec.tv_sec),
            ctimeSeconds: Int64(st.st_ctimespec.tv_sec),
            atimeNsec: UInt32(truncatingIfNeeded: st.st_atimespec.tv_nsec),
            mtimeNsec: UInt32(truncatingIfNeeded: st.st_mtimespec.tv_nsec),
            ctimeNsec: UInt32(truncatingIfNeeded: st.st_ctimespec.tv_nsec)
        )
    }

}

struct FileKey: Hashable, Sendable {
    var device: UInt64
    var inode: UInt64
    /// Darwin increments `st_gen` on filesystems that expose inode generations. APFS commonly
    /// reports zero, so every live FileKey is backed by Node.identityFD; the retained descriptor
    /// prevents inode-number reuse until the node is retired. Birthtime cannot be part of identity
    /// because APFS rewrites it when an older mtime is installed with futimens.
    var generation: UInt32
    var isSynthetic: Bool { device == UInt64.max }

    init(_ st: stat) {
        self.device = UInt64(st.st_dev)
        self.inode = UInt64(st.st_ino)
        self.generation = st.st_gen
    }

    init(device: UInt64, inode: UInt64, generation: UInt32) {
        self.device = device
        self.inode = inode
        self.generation = generation
    }

    init(syntheticNodeID: UInt64) {
        self.device = UInt64.max
        self.inode = syntheticNodeID
        self.generation = 0
    }
}

private extension NSLock {
    func withLock<R>(_ body: () throws -> R) rethrows -> R {
        lock()
        defer { unlock() }
        return try body()
    }
}
