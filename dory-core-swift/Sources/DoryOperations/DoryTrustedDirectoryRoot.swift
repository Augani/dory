import Darwin
import Foundation

/// One runtime-only filesystem generation. Device and inode values are deliberately not Codable:
/// they identify an opened object for this daemon lifetime, not durable storage identity.
public struct DoryTrustedDirectoryIdentity: Sendable, Equatable, Hashable {
    public let device: UInt64
    public let inode: UInt64

    init(_ status: stat) {
        device = UInt64(truncatingIfNeeded: status.st_dev)
        inode = UInt64(truncatingIfNeeded: status.st_ino)
    }
}

/// A path component that is safe to pass to a descriptor-relative filesystem operation.
public struct DoryTrustedPathComponent: Sendable, Equatable, Hashable {
    public let value: String

    public init(validating value: String) throws {
        let byteCount = value.utf8.count
        guard (1...Int(NAME_MAX)).contains(byteCount),
              value != ".",
              value != "..",
              !value.contains("/"),
              !value.contains("\0") else {
            throw DoryTrustedDirectoryRootError.invalidComponent(value)
        }
        self.value = value
    }
}

public enum DoryTrustedDirectoryRootQuarantineReason: Sendable, Equatable {
    /// The configured pathname no longer resolves without following a link, or has disappeared.
    case pathnameUnavailable(errno: Int32)
    /// An ancestor is no longer root/euid-owned and protected against group/world replacement.
    case ancestorPolicyViolated(path: String)
    /// The configured pathname now names another filesystem object.
    case rootIdentityChanged
    /// The retained or newly opened root is no longer an euid-owned exact-mode private directory.
    case rootMetadataChanged
    /// The retained descriptor itself could no longer be inspected.
    case retainedDescriptorUnavailable(errno: Int32)
}

public enum DoryTrustedDirectoryRootHealth: Sendable, Equatable {
    case healthy
    case quarantined(DoryTrustedDirectoryRootQuarantineReason)
}

public enum DoryTrustedDirectoryRootError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidAbsolutePath(String)
    case invalidComponent(String)
    case cannotOpenDirectory(path: String, errno: Int32)
    case cannotInspectDirectory(path: String, errno: Int32)
    case unsafeAncestor(path: String)
    case unsafeManagedRoot(path: String)
    case cannotOpenChild(component: String, errno: Int32)
    case cannotInspectChild(component: String, errno: Int32)
    case unsafeChildDirectory(component: String)
    case crossDeviceChild(component: String)
    case quarantined(DoryTrustedDirectoryRootQuarantineReason)

    public var description: String {
        switch self {
        case let .invalidAbsolutePath(path):
            "trusted directory root must be a canonical absolute path: \(path)"
        case let .invalidComponent(component):
            "trusted directory component is invalid: \(component)"
        case let .cannotOpenDirectory(path, code):
            "could not open trusted directory path \(path): errno \(code)"
        case let .cannotInspectDirectory(path, code):
            "could not inspect trusted directory path \(path): errno \(code)"
        case let .unsafeAncestor(path):
            "trusted directory ancestor is replaceable or has an untrusted owner: \(path)"
        case let .unsafeManagedRoot(path):
            "managed root is not an euid-owned exact-mode 0700 directory: \(path)"
        case let .cannotOpenChild(component, code):
            "could not open trusted child directory \(component): errno \(code)"
        case let .cannotInspectChild(component, code):
            "could not inspect trusted child directory \(component): errno \(code)"
        case let .unsafeChildDirectory(component):
            "trusted child is not an euid-owned exact-mode 0700 directory: \(component)"
        case let .crossDeviceChild(component):
            "trusted child crosses the managed-root filesystem boundary: \(component)"
        case let .quarantined(reason):
            "trusted directory root is quarantined: \(reason)"
        }
    }
}

/// An owned, already-validated private directory descriptor.
///
/// The descriptor remains pinned to the opened directory if its pathname is later renamed or
/// replaced. Callers may use it only as borrowed authority; ownership never leaves this object.
public final class DoryTrustedDirectoryHandle: @unchecked Sendable {
    public let identity: DoryTrustedDirectoryIdentity

    private let descriptor: Int32

    fileprivate init(descriptor: Int32, status: stat) {
        self.descriptor = descriptor
        identity = DoryTrustedDirectoryIdentity(status)
    }

    public func withBorrowedDescriptor<T>(
        _ body: (Int32) throws -> T
    ) rethrows -> T {
        try body(descriptor)
    }

    deinit {
        Darwin.close(descriptor)
    }
}

/// Daemon-owned authority for one private managed directory tree.
///
/// Acquisition walks from `/` one component at a time and never follows a symbolic link. Safe
/// ancestors may be root- or euid-owned and must not be group/world writable. A root-owned sticky
/// directory is the sole writable-ancestor exception; sticky ownership prevents a different user
/// from replacing an euid-owned child entry. The managed root itself is always an exact euid-owned
/// mode-0700 directory.
///
/// The pathname is retained only to detect namespace drift. All descendant authority is derived
/// from the retained descriptor, never by concatenating or reopening the root pathname.
public final class DoryTrustedDirectoryRoot: @unchecked Sendable {
    public let canonicalPath: String
    public let identity: DoryTrustedDirectoryIdentity

    private let descriptor: Int32
    private let effectiveUserID: uid_t
    private let healthLock = NSLock()
    private var storedHealth: DoryTrustedDirectoryRootHealth = .healthy

    public init(canonicalAbsolutePath path: String) throws {
        let components = try Self.canonicalComponents(path)
        let effectiveUserID = geteuid()
        let opened = try Self.openByWalking(
            path: path,
            components: components,
            effectiveUserID: effectiveUserID
        )
        canonicalPath = path
        descriptor = opened.descriptor
        identity = DoryTrustedDirectoryIdentity(opened.status)
        self.effectiveUserID = effectiveUserID
    }

    public var health: DoryTrustedDirectoryRootHealth {
        healthLock.lock()
        defer { healthLock.unlock() }
        return storedHealth
    }

    /// Rewalks the configured pathname and compares it with both the captured generation and the
    /// retained descriptor. Any failure permanently quarantines this authority.
    @discardableResult
    public func revalidateRootPathname() throws -> DoryTrustedDirectoryIdentity {
        try requireHealthy()

        let components: [DoryTrustedPathComponent]
        do {
            components = try Self.canonicalComponents(canonicalPath)
        } catch {
            throw quarantine(.rootMetadataChanged)
        }

        let reopened: OpenedDirectory
        do {
            reopened = try Self.openByWalking(
                path: canonicalPath,
                components: components,
                effectiveUserID: effectiveUserID
            )
        } catch let error as DoryTrustedDirectoryRootError {
            switch error {
            case let .cannotOpenDirectory(_, code):
                throw quarantine(.pathnameUnavailable(errno: code))
            case let .cannotInspectDirectory(_, code):
                throw quarantine(.pathnameUnavailable(errno: code))
            case let .unsafeAncestor(path):
                throw quarantine(.ancestorPolicyViolated(path: path))
            case .unsafeManagedRoot:
                throw quarantine(.rootMetadataChanged)
            default:
                throw quarantine(.rootMetadataChanged)
            }
        } catch {
            throw quarantine(.rootMetadataChanged)
        }
        defer { Darwin.close(reopened.descriptor) }

        guard DoryTrustedDirectoryIdentity(reopened.status) == identity else {
            throw quarantine(.rootIdentityChanged)
        }

        var retainedStatus = stat()
        guard fstat(descriptor, &retainedStatus) == 0 else {
            throw quarantine(.retainedDescriptorUnavailable(errno: errno))
        }
        guard Self.isManagedDirectory(retainedStatus, effectiveUserID: effectiveUserID),
              DoryTrustedDirectoryIdentity(retainedStatus) == identity else {
            throw quarantine(.rootMetadataChanged)
        }

        try requireHealthy()
        return identity
    }

    /// Opens one direct private child without following links or crossing onto another filesystem.
    /// The root pathname is revalidated first; the returned descriptor is pinned independently.
    public func openPrivateChildDirectory(
        _ component: DoryTrustedPathComponent
    ) throws -> DoryTrustedDirectoryHandle {
        try revalidateRootPathname()

        let childDescriptor = openat(
            descriptor,
            component.value,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard childDescriptor >= 0 else {
            throw DoryTrustedDirectoryRootError.cannotOpenChild(
                component: component.value,
                errno: errno
            )
        }
        var transferred = false
        defer {
            if !transferred { Darwin.close(childDescriptor) }
        }

        var childStatus = stat()
        guard fstat(childDescriptor, &childStatus) == 0 else {
            throw DoryTrustedDirectoryRootError.cannotInspectChild(
                component: component.value,
                errno: errno
            )
        }
        guard Self.isManagedDirectory(childStatus, effectiveUserID: effectiveUserID) else {
            throw DoryTrustedDirectoryRootError.unsafeChildDirectory(
                component: component.value
            )
        }
        guard DoryTrustedDirectoryIdentity(childStatus).device == identity.device else {
            throw DoryTrustedDirectoryRootError.crossDeviceChild(
                component: component.value
            )
        }

        // A mode/owner change to the pinned root during the child open is a root health fault.
        var retainedStatus = stat()
        guard fstat(descriptor, &retainedStatus) == 0 else {
            throw quarantine(.retainedDescriptorUnavailable(errno: errno))
        }
        guard Self.isManagedDirectory(retainedStatus, effectiveUserID: effectiveUserID),
              DoryTrustedDirectoryIdentity(retainedStatus) == identity else {
            throw quarantine(.rootMetadataChanged)
        }
        try requireHealthy()

        transferred = true
        return DoryTrustedDirectoryHandle(
            descriptor: childDescriptor,
            status: childStatus
        )
    }

    /// Borrows the root descriptor only while the root pathname is healthy and still names the
    /// captured generation. This is the integration seam for higher-level resource brokers.
    public func withBorrowedDescriptor<T>(
        _ body: (Int32) throws -> T
    ) throws -> T {
        try revalidateRootPathname()
        return try body(descriptor)
    }

    deinit {
        Darwin.close(descriptor)
    }

    private struct OpenedDirectory {
        let descriptor: Int32
        let status: stat
    }

    private static func canonicalComponents(
        _ path: String
    ) throws -> [DoryTrustedPathComponent] {
        guard path.hasPrefix("/"),
              path != "/",
              path.utf8.count < Int(PATH_MAX),
              !path.hasSuffix("/"),
              !path.contains("//"),
              !path.contains("\0") else {
            throw DoryTrustedDirectoryRootError.invalidAbsolutePath(path)
        }
        let rawComponents = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        guard !rawComponents.isEmpty else {
            throw DoryTrustedDirectoryRootError.invalidAbsolutePath(path)
        }
        do {
            return try rawComponents.map {
                try DoryTrustedPathComponent(validating: String($0))
            }
        } catch {
            throw DoryTrustedDirectoryRootError.invalidAbsolutePath(path)
        }
    }

    private static func openByWalking(
        path: String,
        components: [DoryTrustedPathComponent],
        effectiveUserID: uid_t
    ) throws -> OpenedDirectory {
        var currentDescriptor = open(
            "/",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard currentDescriptor >= 0 else {
            throw DoryTrustedDirectoryRootError.cannotOpenDirectory(
                path: "/",
                errno: errno
            )
        }
        var currentPath = ""
        var currentStatus = stat()

        do {
            guard fstat(currentDescriptor, &currentStatus) == 0 else {
                throw DoryTrustedDirectoryRootError.cannotInspectDirectory(
                    path: "/",
                    errno: errno
                )
            }
            guard isSafeAncestor(currentStatus, effectiveUserID: effectiveUserID) else {
                throw DoryTrustedDirectoryRootError.unsafeAncestor(path: "/")
            }

            for (index, component) in components.enumerated() {
                currentPath += "/" + component.value
                let nextDescriptor = openat(
                    currentDescriptor,
                    component.value,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                guard nextDescriptor >= 0 else {
                    throw DoryTrustedDirectoryRootError.cannotOpenDirectory(
                        path: currentPath,
                        errno: errno
                    )
                }
                Darwin.close(currentDescriptor)
                currentDescriptor = nextDescriptor

                guard fstat(currentDescriptor, &currentStatus) == 0 else {
                    throw DoryTrustedDirectoryRootError.cannotInspectDirectory(
                        path: currentPath,
                        errno: errno
                    )
                }
                let isManagedRoot = index == components.count - 1
                if isManagedRoot {
                    guard isManagedDirectory(
                        currentStatus,
                        effectiveUserID: effectiveUserID
                    ) else {
                        throw DoryTrustedDirectoryRootError.unsafeManagedRoot(
                            path: path
                        )
                    }
                } else {
                    guard isSafeAncestor(
                        currentStatus,
                        effectiveUserID: effectiveUserID
                    ) else {
                        throw DoryTrustedDirectoryRootError.unsafeAncestor(
                            path: currentPath
                        )
                    }
                }
            }
            return OpenedDirectory(
                descriptor: currentDescriptor,
                status: currentStatus
            )
        } catch {
            Darwin.close(currentDescriptor)
            throw error
        }
    }

    private static func isSafeAncestor(
        _ status: stat,
        effectiveUserID: uid_t
    ) -> Bool {
        guard status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == 0 || status.st_uid == effectiveUserID else {
            return false
        }
        let permissions = status.st_mode & mode_t(0o7777)
        if permissions & mode_t(0o022) == 0 { return true }
        return status.st_uid == 0 && permissions & mode_t(S_ISVTX) != 0
    }

    private static func isManagedDirectory(
        _ status: stat,
        effectiveUserID: uid_t
    ) -> Bool {
        status.st_mode & S_IFMT == S_IFDIR
            && status.st_uid == effectiveUserID
            && status.st_mode & mode_t(0o7777) == mode_t(0o700)
    }

    private func requireHealthy() throws {
        healthLock.lock()
        defer { healthLock.unlock() }
        if case let .quarantined(reason) = storedHealth {
            throw DoryTrustedDirectoryRootError.quarantined(reason)
        }
    }

    private func quarantine(
        _ proposedReason: DoryTrustedDirectoryRootQuarantineReason
    ) -> DoryTrustedDirectoryRootError {
        healthLock.lock()
        defer { healthLock.unlock() }
        let reason: DoryTrustedDirectoryRootQuarantineReason
        switch storedHealth {
        case .healthy:
            storedHealth = .quarantined(proposedReason)
            reason = proposedReason
        case let .quarantined(existing):
            reason = existing
        }
        return .quarantined(reason)
    }
}
