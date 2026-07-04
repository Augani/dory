import Foundation

public struct VirtioFSShareConfiguration: Equatable, Sendable {
    public var tag: String
    public var path: String
    public var readOnly: Bool
    public var dax: Bool

    public init(tag: String, path: String, readOnly: Bool = false, dax: Bool = false) throws {
        guard !tag.isEmpty, Array(tag.utf8).count < VirtioFS.tagByteCount else {
            throw VMError.invalidConfiguration("invalid virtio-fs share tag: \(tag)")
        }
        guard tag.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" }) else {
            throw VMError.invalidConfiguration("virtio-fs share tag must contain only letters, numbers, '.', '_', or '-'")
        }
        guard !path.isEmpty else {
            throw VMError.invalidConfiguration("virtio-fs share \(tag) has an empty host path")
        }
        self.tag = tag
        self.path = path
        self.readOnly = readOnly
        self.dax = dax
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
        for option in components {
            switch option {
            case "ro": readOnly = true
            case "rw": readOnly = false
            case "dax": dax = true
            case "": path += ":"
            default:
                throw VMError.invalidConfiguration("unknown virtio-fs share option ':\(option)' (expected ro, rw, or dax)")
            }
        }
        try self.init(tag: tag, path: path, readOnly: readOnly, dax: dax)
    }

    public func makeBackend(daxGuestBase: UInt64? = nil) throws -> VirtioFS {
        let hostFS = try HostFS(rootPath: path, readOnly: readOnly)
        guard dax else {
            return try VirtioFS(tag: tag, hostFS: hostFS)
        }
        guard let daxGuestBase else {
            throw VMError.invalidConfiguration("virtio-fs share \(tag) requests dax but no guest window base was allocated")
        }
        return try VirtioFS(tag: tag, hostFS: hostFS, daxConfiguration: VirtioFSDaxConfiguration(guestBase: daxGuestBase))
    }
}
