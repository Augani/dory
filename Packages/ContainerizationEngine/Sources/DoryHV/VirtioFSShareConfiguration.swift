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

    public func makeBackend(daxGuestBase _: UInt64? = nil, requestQueueCount: Int? = nil) throws -> VirtioFS {
        // `dax` is mutable for source compatibility. Recheck at the production construction boundary
        // so a caller cannot parse a safe share, flip the bit, and bypass initializer validation.
        guard !dax else {
            throw VMError.invalidConfiguration(Self.daxUnsupportedReason)
        }
        let hostFS = try HostFS(
            rootPath: path,
            readOnly: readOnly,
            hiddenNames: hiddenNames,
            rootHiddenNames: rootHiddenNames
        )
        return try VirtioFS(tag: tag, hostFS: hostFS, requestQueueCount: requestQueueCount)
    }
}
