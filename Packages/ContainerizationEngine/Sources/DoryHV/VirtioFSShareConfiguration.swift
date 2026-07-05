import Foundation

public struct VirtioFSShareConfiguration: Equatable, Sendable {
    public var tag: String
    public var path: String
    public var readOnly: Bool
    public var dax: Bool
    /// Where the guest mounts this share. `nil` mounts under `/mnt/dory/<tag>`; a value mounts at
    /// that absolute guest path so a host directory can appear at its identical macOS path (e.g.
    /// `$HOME` at `$HOME`), which is what makes `-v /Users/…:/…` bind mounts resolve transparently.
    public var guestMountPoint: String?
    /// Entry names hidden from the guest at any depth (see `HostFS.hiddenNames`). The `:safe` share
    /// option applies `sensitiveNames` so a whole-home share never exposes credential stores or
    /// shell rc files to containers.
    public var hiddenNames: Set<String>

    /// Credential stores, cloud/CLI secrets, and shell rc files that must never be exposed by a
    /// broad host share. Hidden by name at any depth. This is a defense-in-depth default for the
    /// convenience home share; the stronger guarantee is per-bind-mount on-demand sharing.
    public static let sensitiveNames: Set<String> = [
        ".ssh", ".aws", ".gcloud", ".azure", ".kube", ".docker", ".gnupg", ".config",
        ".netrc", ".npmrc", ".pypirc", ".pgpass", ".git-credentials", ".terraform.d",
        ".zshrc", ".zshenv", ".zprofile", ".zlogin", ".bashrc", ".bash_profile", ".profile",
        "Library",
    ]

    public init(tag: String, path: String, readOnly: Bool = false, dax: Bool = false, guestMountPoint: String? = nil, hiddenNames: Set<String> = []) throws {
        guard !tag.isEmpty, Array(tag.utf8).count < VirtioFS.tagByteCount else {
            throw VMError.invalidConfiguration("invalid virtio-fs share tag: \(tag)")
        }
        guard tag.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" }) else {
            throw VMError.invalidConfiguration("virtio-fs share tag must contain only letters, numbers, '.', '_', or '-'")
        }
        guard !path.isEmpty else {
            throw VMError.invalidConfiguration("virtio-fs share \(tag) has an empty host path")
        }
        if let guestMountPoint, !guestMountPoint.hasPrefix("/") {
            throw VMError.invalidConfiguration("virtio-fs share \(tag) guest mount point must be absolute: \(guestMountPoint)")
        }
        self.tag = tag
        self.path = path
        self.readOnly = readOnly
        self.dax = dax
        self.guestMountPoint = guestMountPoint
        self.hiddenNames = hiddenNames
    }

    public init(argument: String) throws {
        let split = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard split.count == 2 else {
            throw VMError.invalidConfiguration("share must be tag=/host/path[:ro|:rw][:dax]")
        }
        let tag = String(split[0])
        var components = String(split[1]).components(separatedBy: ":")
        var path = components.removeFirst()
        var readOnly = false
        var dax = false
        var guestMountPoint: String?
        var hiddenNames: Set<String> = []
        for option in components {
            switch option {
            case "ro": readOnly = true
            case "rw": readOnly = false
            case "dax": dax = true
            case "safe": hiddenNames.formUnion(Self.sensitiveNames)
            case "": path += ":"
            case let option where option.hasPrefix("at="):
                guestMountPoint = String(option.dropFirst(3))
            case let option where option.hasPrefix("hide="):
                hiddenNames.formUnion(option.dropFirst(5).split(separator: ",").map(String.init))
            default:
                throw VMError.invalidConfiguration("unknown virtio-fs share option ':\(option)' (expected ro, rw, dax, safe, hide=a,b, or at=/guest/path)")
            }
        }
        try self.init(tag: tag, path: path, readOnly: readOnly, dax: dax, guestMountPoint: guestMountPoint, hiddenNames: hiddenNames)
    }

    public func makeBackend(daxGuestBase: UInt64? = nil) throws -> VirtioFS {
        let hostFS = try HostFS(rootPath: path, readOnly: readOnly, hiddenNames: hiddenNames)
        guard dax else {
            return try VirtioFS(tag: tag, hostFS: hostFS)
        }
        guard let daxGuestBase else {
            throw VMError.invalidConfiguration("virtio-fs share \(tag) requests dax but no guest window base was allocated")
        }
        return try VirtioFS(tag: tag, hostFS: hostFS, daxConfiguration: VirtioFSDaxConfiguration(guestBase: daxGuestBase))
    }
}
