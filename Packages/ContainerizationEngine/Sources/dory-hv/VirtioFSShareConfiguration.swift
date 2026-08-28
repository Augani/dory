import Darwin
import DoryFSWorkerContracts
import DoryHV
import Foundation

public struct VirtioFSShareConfiguration: Equatable, Sendable {
    /// DAX mappings bypass the FUSE request queues. If reverse invalidation is refused, the request
    /// publication gate therefore cannot stop guest CPU loads/stores while the VM restart is being
    /// scheduled. Read-only mappings still bypass the gate for stale reads, so production host
    /// shares reject DAX in both modes until a host-owned vCPU quiesce boundary exists.
    public static let daxUnsupportedReason = "virtio-fs DAX host shares are disabled because direct guest mappings bypass the reverse-invalidation fail-stop boundary; use plain virtio-fs"

    public var tag: String
    public var path: String
    public var readOnly: Bool
    public var dax: Bool
    /// Where the guest mounts this share. `nil` mounts under `/mnt/dory/<tag>`; a value mounts at
    /// that absolute guest path so a host directory can appear at its identical macOS path (e.g.
    /// `$HOME` at `$HOME`), which is what makes `-v /Users/…:/…` bind mounts resolve transparently.
    public var guestMountPoint: String?
    /// Entry names explicitly hidden from the guest at any depth (see `HostFS.hiddenNames`).
    public var hiddenNames: Set<String>
    /// Entry names hidden only when they are direct children of the share root. The `:safe` share
    /// option applies `sensitiveNames` here so a whole-home share protects the user's credential
    /// stores and shell files without hiding ordinary names inside projects.
    public var rootHiddenNames: Set<String>

    /// Credential stores, cloud/CLI secrets, and shell rc files that must never be exposed by a
    /// broad host share. These names are anchored to the share root, which is the user's home for
    /// the convenience home share. The stronger guarantee is per-bind-mount on-demand sharing.
    public static let sensitiveNames: Set<String> = [
        ".ssh", ".aws", ".gcloud", ".azure", ".kube", ".docker", ".dory", ".gnupg", ".config",
        ".codex", ".claude", ".colima", ".lima", ".orbstack", ".podman", ".rd",
        ".netrc", ".npmrc", ".pypirc", ".pgpass", ".gitconfig", ".git-credentials", ".terraform.d",
        ".zsh_history", ".bash_history",
        ".zshrc", ".zshenv", ".zprofile", ".zlogin", ".bashrc", ".bash_profile", ".profile",
        "Library",
    ]

    public init(
        tag: String,
        path: String,
        readOnly: Bool = false,
        dax: Bool = false,
        guestMountPoint: String? = nil,
        hiddenNames: Set<String> = [],
        rootHiddenNames: Set<String> = []
    ) throws {
        guard !tag.isEmpty, Array(tag.utf8).count < VirtioFS.tagByteCount else {
            throw VMError.invalidConfiguration("invalid virtio-fs share tag: \(tag)")
        }
        guard tag.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" }) else {
            throw VMError.invalidConfiguration("virtio-fs share tag must contain only letters, numbers, '.', '_', or '-'")
        }
        guard Self.isCanonicalAbsolutePath(path), path != "/" else {
            throw VMError.invalidConfiguration(
                "virtio-fs share \(tag) host path must be a canonical absolute path below '/': \(path)"
            )
        }
        if let guestMountPoint,
           (!Self.isCanonicalAbsolutePath(guestMountPoint) || guestMountPoint == "/") {
            throw VMError.invalidConfiguration(
                "virtio-fs share \(tag) guest mount point must be a canonical absolute path below '/': \(guestMountPoint)"
            )
        }
        guard hiddenNames.allSatisfy(Self.isValidHiddenName),
              rootHiddenNames.allSatisfy(Self.isValidHiddenName) else {
            throw VMError.invalidConfiguration(
                "virtio-fs share \(tag) hidden names must be individual path components"
            )
        }
        guard !dax else {
            throw VMError.invalidConfiguration(Self.daxUnsupportedReason)
        }
        self.tag = tag
        self.path = path
        self.readOnly = readOnly
        self.dax = dax
        self.guestMountPoint = guestMountPoint
        self.hiddenNames = hiddenNames
        self.rootHiddenNames = rootHiddenNames
    }

    public init(argument: String) throws {
        let split = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard split.count == 2 else {
            throw VMError.invalidConfiguration("share must be tag=/host/path[:ro|:rw][:safe][:at=/guest/path]")
        }
        let tag = String(split[0])
        var components = String(split[1]).components(separatedBy: ":")
        var path = components.removeFirst()
        var readOnly = false
        var dax = false
        var guestMountPoint: String?
        var hiddenNames: Set<String> = []
        var rootHiddenNames: Set<String> = []
        for option in components {
            switch option {
            case "ro": readOnly = true
            case "rw": readOnly = false
            case "dax": dax = true
            case "safe": rootHiddenNames.formUnion(Self.sensitiveNames)
            case "": path += ":"
            case let option where option.hasPrefix("at="):
                guestMountPoint = String(option.dropFirst(3))
            case let option where option.hasPrefix("hide="):
                let names = option.dropFirst(5).split(separator: ",", omittingEmptySubsequences: false)
                guard !names.isEmpty, names.allSatisfy({ !$0.isEmpty }) else {
                    throw VMError.invalidConfiguration("virtio-fs share \(tag) hide option must name one or more path components")
                }
                hiddenNames.formUnion(names.map(String.init))
            default:
                throw VMError.invalidConfiguration("unknown virtio-fs share option ':\(option)' (expected ro, rw, safe, hide=a,b, or at=/guest/path)")
            }
        }
        try self.init(
            tag: tag,
            path: path,
            readOnly: readOnly,
            dax: dax,
            guestMountPoint: guestMountPoint,
            hiddenNames: hiddenNames,
            rootHiddenNames: rootHiddenNames
        )
    }

    /// Distinct virtio-fs devices over an overlapping host subtree cannot preserve guest-originated
    /// coherence when either is writable: IgnoreSelf identifies dory-hv as the process but not which
    /// mount performed the mutation, so a write through one alias cannot invalidate the other (even
    /// when that other alias is read-only). Reject it until HostFS carries source-mount identity.
    public static func validateWritableTopology(_ shares: [Self]) throws {
        let canonical = shares.map { share in
            (
                share: share,
                canonicalPath: URL(fileURLWithPath: share.path)
                    .resolvingSymlinksInPath()
                    .standardizedFileURL.path
            )
        }
        for leftIndex in canonical.indices {
            for rightIndex in canonical.indices where rightIndex > leftIndex {
                let left = canonical[leftIndex]
                let right = canonical[rightIndex]
                if (!left.share.readOnly || !right.share.readOnly),
                   pathsOverlap(left.canonicalPath, right.canonicalPath) {
                    throw VMError.invalidConfiguration(
                        "virtio-fs shares '\(left.share.tag)' and '\(right.share.tag)' overlap while at least one is writable; "
                            + "use one shared root so guest writes, caches, and watchers have a single source mount"
                    )
                }
            }
        }
    }

    private static func pathsOverlap(_ left: String, _ right: String) -> Bool {
        if left == right { return true }
        let leftPrefix = left == "/" ? "/" : left + "/"
        let rightPrefix = right == "/" ? "/" : right + "/"
        return left.hasPrefix(rightPrefix) || right.hasPrefix(leftPrefix)
    }

    private static func isCanonicalAbsolutePath(_ path: String) -> Bool {
        path.hasPrefix("/")
            && !path.utf8.contains(0)
            && URL(fileURLWithPath: path).standardizedFileURL.path == path
    }

    private static func isValidHiddenName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".."
            && !name.contains("/") && !name.utf8.contains(0)
    }

    public func makeBackend(
        broker: DoryFSWorkerBroker,
        requestQueueCount: Int? = nil,
        onWorkerLifecycle: @escaping @Sendable (VirtioFSWorkerLifecycleEvent) -> Void = { _ in }
    ) throws -> VirtioFS {
        // `dax` is mutable for source compatibility. Recheck at the production construction boundary
        // so a caller cannot parse a safe share, flip the bit, and bypass initializer validation.
        guard !dax else {
            throw VMError.invalidConfiguration(Self.daxUnsupportedReason)
        }
        return try VirtioFS(
            tag: tag,
            broker: broker,
            requestQueueCount: requestQueueCount,
            onWorkerLifecycle: onWorkerLifecycle
        )
    }
}

struct DoryFilesystemWorkerLaunch: @unchecked Sendable {
    let client: DoryFSWorkerWorkspaceClient
    let capabilityByTag: [String: DoryFSShareCapabilityID]

    func broker(for share: VirtioFSShareConfiguration) throws -> DoryFSWorkerBroker {
        let capability = try capability(for: share)
        return try client.broker(for: capability)
    }

    func capability(
        for share: VirtioFSShareConfiguration
    ) throws -> DoryFSShareCapabilityID {
        guard let capability = capabilityByTag[share.tag] else {
            throw VMError.invalidConfiguration(
                "filesystem worker has no capability for virtio-fs tag \(share.tag)"
            )
        }
        return capability
    }

    @discardableResult
    func installCoherenceHandler(
        _ handler: @escaping @Sendable (DoryFSWorkerCoherenceBatch) async throws -> Void
    ) -> Bool {
        client.installCoherenceHandler(handler)
    }

    func installLifecycleHandler(
        _ handler: @escaping @Sendable (DoryFSWorkerChannelEvent) -> Void
    ) {
        client.installLifecycleHandler(handler)
    }
}

enum DoryFilesystemWorkerLauncher {
    static func start(
        shares: [VirtioFSShareConfiguration],
        coherencePolicyByTag: [String: DoryFSShareCoherencePolicy] = [:]
    ) async throws -> DoryFilesystemWorkerLaunch {
        let prepared = try prepare(
            shares: shares,
            coherencePolicyByTag: coherencePolicyByTag
        )
        let client = try await DoryFSWorkerWorkspaceClient.connect(
            exactBootstrapBytes: prepared.bytes,
            rootDescriptors: prepared.rootDescriptors
        )
        return DoryFilesystemWorkerLaunch(
            client: client,
            capabilityByTag: prepared.capabilities
        )
    }

    static func startBlocking(
        shares: [VirtioFSShareConfiguration],
        coherencePolicyByTag: [String: DoryFSShareCoherencePolicy] = [:]
    ) throws -> DoryFilesystemWorkerLaunch {
        let prepared = try prepare(
            shares: shares,
            coherencePolicyByTag: coherencePolicyByTag
        )
        let client = try DoryFSWorkerWorkspaceClient.connectBlocking(
            exactBootstrapBytes: prepared.bytes,
            rootDescriptors: prepared.rootDescriptors
        )
        return DoryFilesystemWorkerLaunch(
            client: client,
            capabilityByTag: prepared.capabilities
        )
    }

    static func prepare(
        shares: [VirtioFSShareConfiguration],
        coherencePolicyByTag: [String: DoryFSShareCoherencePolicy] = [:]
    ) throws -> (
        bytes: Data,
        rootDescriptors: [FileHandle],
        capabilities: [String: DoryFSShareCapabilityID]
    ) {
        guard !shares.isEmpty, shares.count <= DoryFSWorkerBootstrapCodec.maximumShares else {
            throw VMError.invalidConfiguration("invalid filesystem worker share count")
        }
        var seenTags = Set<String>()
        var capabilities = [String: DoryFSShareCapabilityID]()
        var authorities = [DoryFSShareBootstrapAuthority]()
        var rootDescriptors = [FileHandle]()
        authorities.reserveCapacity(shares.count)
        rootDescriptors.reserveCapacity(shares.count)
        for share in shares {
            guard seenTags.insert(share.tag).inserted else {
                throw VMError.invalidConfiguration(
                    "duplicate virtio-fs share tag: \(share.tag)"
                )
            }
            let descriptor = Darwin.open(
                share.path,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard descriptor >= 0 else {
                throw VMError.invalidConfiguration(
                    "cannot pin virtio-fs share \(share.tag): errno \(errno)"
                )
            }
            var status = stat()
            guard fstat(descriptor, &status) == 0,
                  status.st_mode & S_IFMT == S_IFDIR else {
                let savedErrno = errno
                Darwin.close(descriptor)
                throw VMError.invalidConfiguration(
                    "cannot inspect virtio-fs share \(share.tag): errno \(savedErrno)"
                )
            }
            // Keep the exact no-follow directory descriptor open and transfer it through signed
            // XPC. A bookmark created by this unsandboxed runner is only a locator, not a Powerbox
            // grant for another sandbox identity, while Darwin App Sandbox does not extend an
            // inherited directory descriptor to descendant `openat` operations. The dedicated
            // worker therefore shares this runner's host filesystem namespace but receives no host
            // paths: it duplicates only these descriptors and verifies the sealed identity below
            // before admitting any FUSE request.
            let rootDescriptorIndex = UInt16(rootDescriptors.count)
            rootDescriptors.append(FileHandle(
                fileDescriptor: descriptor,
                closeOnDealloc: true
            ))
            let capability = DoryFSShareCapabilityID.random()
            capabilities[share.tag] = capability
            authorities.append(try DoryFSShareBootstrapAuthority(
                capabilityID: capability,
                expectedRootIdentity: try DoryFSPinnedRootIdentity(
                    device: UInt64(truncatingIfNeeded: status.st_dev),
                    inode: UInt64(truncatingIfNeeded: status.st_ino),
                    generation: UInt64(truncatingIfNeeded: status.st_gen)
                ),
                readOnly: share.readOnly,
                coherencePolicy: coherencePolicyByTag[share.tag] ?? .disabled,
                guestIdentity: DoryFSGuestIdentityPolicy(uid: getuid(), gid: getgid()),
                resourceLimits: .production,
                rootDescriptorIndex: rootDescriptorIndex,
                hiddenComponents: Array(share.hiddenNames),
                rootHiddenComponents: Array(share.rootHiddenNames)
            ))
        }
        let bootstrap = try DoryFSWorkerBootstrap(
            workspaceID: .random(),
            generation: try DoryFSWorkerGeneration(
                rawValue: UInt64.random(in: 1...UInt64.max)
            ),
            workerLimits: .production,
            shares: authorities
        )
        return (
            bytes: try DoryFSWorkerBootstrapCodec.encode(bootstrap),
            rootDescriptors: rootDescriptors,
            capabilities: capabilities
        )
    }
}
