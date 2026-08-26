import Darwin
import DoryFSWorkerContracts
import Foundation

/// Fail-closed errors raised while converting the exact bootstrap envelope into pinned directory
/// authority. Errors identify shares only by their unforgeable capability; host paths and bookmark
/// bytes never cross this API boundary.
public enum DoryFSWorkerRootAuthorityError: Error, Equatable, Sendable {
    /// A worker process accepts exactly one bootstrap attempt. A failed attempt is terminal too;
    /// the supervisor must replace the process instead of substituting a different authority set.
    case bootstrapAlreadyAttempted
    case bootstrapNotAccepted
    case bookmarkResolutionFailed(DoryFSShareCapabilityID)
    case staleBookmark(DoryFSShareCapabilityID)
    case nonFileBookmark(DoryFSShareCapabilityID)
    case securityScopeDenied(DoryFSShareCapabilityID)
    case rootOpenFailed(DoryFSShareCapabilityID, errno: Int32)
    case rootInspectionFailed(DoryFSShareCapabilityID, errno: Int32)
    case rootIsNotDirectory(DoryFSShareCapabilityID)
    case rootIdentityMismatch(DoryFSShareCapabilityID)
    case unknownCapability(DoryFSShareCapabilityID)
    case descriptorBorrowFailed(DoryFSShareCapabilityID, errno: Int32)
}

/// Owns the immutable share roots for one worker process.
///
/// The public surface deliberately has no URL, path, bookmark, mutation, or root-enumeration API.
/// The sole authority-use seam is a synchronous descriptor borrow selected by the typed capability
/// from the accepted bootstrap. Each borrow receives a temporary close-on-exec duplicate; the
/// integer is invalid once the callback returns and closing it cannot revoke the retained root.
public final class DoryFSWorkerRootAuthority: @unchecked Sendable {
    private enum Lifecycle {
        case uninitialized
        case resolving
        case accepted([DoryFSShareCapabilityID: OwnedRoot])
        case failed
    }

    private static let processBootstrapAdmission = DoryFSWorkerBootstrapAdmission()

    private let resolver: any DoryFSWorkerBookmarkResolving
    private let bootstrapAdmission: DoryFSWorkerBootstrapAdmission
    private let stateLock = NSLock()
    private var lifecycle: Lifecycle = .uninitialized

    /// Uses the process-wide one-shot gate and Foundation's security-scoped bookmark resolver.
    public init() {
        resolver = DoryFSWorkerFoundationBookmarkResolver.shared
        bootstrapAdmission = Self.processBootstrapAdmission
    }

    /// Decodes and consumes one exact bootstrap envelope, returning its exact receipt bytes only
    /// after every share has resolved, entered scope, opened, and matched its sealed identity.
    ///
    /// Any error permanently consumes the process bootstrap attempt. All roots and security scopes
    /// acquired by the failed transaction are synchronously released before the error is returned.
    public func bootstrap(exactBytes: Data) throws -> Data {
        guard bootstrapAdmission.claim() else {
            throw DoryFSWorkerRootAuthorityError.bootstrapAlreadyAttempted
        }
        setLifecycle(.resolving)

        var acquired = [OwnedRoot]()
        do {
            let bootstrap = try DoryFSWorkerBootstrapCodec.decode(exactBytes)
            acquired.reserveCapacity(bootstrap.shares.count)
            for share in bootstrap.shares {
                acquired.append(try acquireRoot(for: share))
            }

            var roots = [DoryFSShareCapabilityID: OwnedRoot](
                minimumCapacity: acquired.count
            )
            for root in acquired {
                // Duplicate capabilities are rejected by the exact bootstrap codec. Retain the
                // check as a local invariant so future codec versions cannot silently overwrite.
                guard roots.updateValue(root, forKey: root.capabilityID) == nil else {
                    throw DoryFSWorkerRootAuthorityError.rootIdentityMismatch(root.capabilityID)
                }
            }
            setLifecycle(.accepted(roots))
            acquired.removeAll(keepingCapacity: false)
            return DoryFSWorkerBootstrapCodec.encode(
                DoryFSWorkerBootstrapReceipt(accepting: bootstrap)
            )
        } catch {
            // `OwnedRoot.release()` is idempotent because both this rollback and ARC teardown can
            // observe the same temporary owner while unwinding.
            for root in acquired.reversed() {
                root.release()
            }
            setLifecycle(.failed)
            throw error
        }
    }

    /// Borrows the pinned directory for one accepted capability during `body` only.
    ///
    /// The callback is nonescaping and cannot return the descriptor. The temporary duplicate is
    /// always closed on callback exit, including thrown exits. Code in the future worker runtime
    /// may construct its share engine inside this lexical scope; it must not retain the integer.
    public func withBorrowedRootFileDescriptor<Result>(
        for capabilityID: DoryFSShareCapabilityID,
        _ body: (Int32) throws -> Result
    ) throws -> Result {
        let root = try acceptedRoot(for: capabilityID)
        let borrowed = root.duplicateForBorrow()
        guard borrowed >= 0 else {
            throw DoryFSWorkerRootAuthorityError.descriptorBorrowFailed(
                capabilityID,
                errno: errno
            )
        }
        defer { _ = Darwin.close(borrowed) }
        return try body(borrowed)
    }

    // Dependency injection is intentionally internal: production callers cannot replace bookmark
    // semantics or opt out of the process-wide gate. Focused tests use a fresh gate per scenario.
    init(
        resolver: any DoryFSWorkerBookmarkResolving,
        bootstrapAdmission: DoryFSWorkerBootstrapAdmission
    ) {
        self.resolver = resolver
        self.bootstrapAdmission = bootstrapAdmission
    }

    private func acquireRoot(
        for share: DoryFSShareBootstrapAuthority
    ) throws -> OwnedRoot {
        let resolution: DoryFSWorkerResolvedBookmark
        do {
            resolution = try resolver.resolve(share.securityScopedBookmark)
        } catch {
            throw DoryFSWorkerRootAuthorityError.bookmarkResolutionFailed(share.capabilityID)
        }
        guard resolution.url.isFileURL else {
            throw DoryFSWorkerRootAuthorityError.nonFileBookmark(share.capabilityID)
        }
        guard resolver.startAccessingSecurityScopedResource(resolution.url) else {
            throw DoryFSWorkerRootAuthorityError.securityScopeDenied(share.capabilityID)
        }

        var descriptor: Int32 = -1
        var transferred = false
        defer {
            if !transferred {
                if descriptor >= 0 {
                    _ = Darwin.close(descriptor)
                }
                resolver.stopAccessingSecurityScopedResource(resolution.url)
            }
        }

        descriptor = Self.openDirectoryWithoutFollowing(resolution.url)
        guard descriptor >= 0 else {
            throw DoryFSWorkerRootAuthorityError.rootOpenFailed(
                share.capabilityID,
                errno: errno
            )
        }

        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw DoryFSWorkerRootAuthorityError.rootInspectionFailed(
                share.capabilityID,
                errno: errno
            )
        }
        guard status.st_mode & S_IFMT == S_IFDIR else {
            throw DoryFSWorkerRootAuthorityError.rootIsNotDirectory(share.capabilityID)
        }
        guard UInt64(truncatingIfNeeded: status.st_dev)
                    == share.expectedRootIdentity.device,
              UInt64(truncatingIfNeeded: status.st_ino)
                    == share.expectedRootIdentity.inode,
              UInt64(truncatingIfNeeded: status.st_gen)
                    == share.expectedRootIdentity.generation else {
            // Foundation's stale bit is advisory: resolution still returned a usable URL, and
            // Apple's contract asks persistent clients to replace their stored bookmark. This
            // worker consumes a one-shot process-transfer bookmark and never stores it, so a stale
            // result is safe only when the independently sealed descriptor identity still matches.
            // If it does not, distinguish a bookmark that no longer names the sealed root from a
            // fresh-bookmark identity race without exposing either path or identity on the wire.
            if resolution.isStale {
                throw DoryFSWorkerRootAuthorityError.staleBookmark(share.capabilityID)
            }
            throw DoryFSWorkerRootAuthorityError.rootIdentityMismatch(share.capabilityID)
        }

        transferred = true
        return OwnedRoot(
            capabilityID: share.capabilityID,
            descriptor: descriptor,
            scopedURL: resolution.url,
            resolver: resolver
        )
    }

    private func acceptedRoot(
        for capabilityID: DoryFSShareCapabilityID
    ) throws -> OwnedRoot {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard case .accepted(let roots) = lifecycle else {
            throw DoryFSWorkerRootAuthorityError.bootstrapNotAccepted
        }
        guard let root = roots[capabilityID] else {
            throw DoryFSWorkerRootAuthorityError.unknownCapability(capabilityID)
        }
        return root
    }

    private func setLifecycle(_ newValue: Lifecycle) {
        stateLock.lock()
        lifecycle = newValue
        stateLock.unlock()
    }

    private static func openDirectoryWithoutFollowing(_ url: URL) -> Int32 {
        url.withUnsafeFileSystemRepresentation { representation in
            guard let representation else {
                errno = EINVAL
                return -1
            }
            return Darwin.open(
                representation,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
    }
}

struct DoryFSWorkerResolvedBookmark {
    let url: URL
    let isStale: Bool
}

protocol DoryFSWorkerBookmarkResolving: AnyObject {
    func resolve(_ bookmark: Data) throws -> DoryFSWorkerResolvedBookmark
    func startAccessingSecurityScopedResource(_ url: URL) -> Bool
    func stopAccessingSecurityScopedResource(_ url: URL)
}

final class DoryFSWorkerBootstrapAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private var consumed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !consumed else { return false }
        consumed = true
        return true
    }
}

private final class DoryFSWorkerFoundationBookmarkResolver:
    DoryFSWorkerBookmarkResolving,
    @unchecked Sendable
{
    static let shared = DoryFSWorkerFoundationBookmarkResolver()

    func resolve(_ bookmark: Data) throws -> DoryFSWorkerResolvedBookmark {
        var stale = false
        let url = try URL(
            resolvingBookmarkData: bookmark,
            // The runner sends a one-shot process-transfer bookmark with an implicit ephemeral
            // scope. Defer activation so RootAuthority can fail closed on the Bool result and pair
            // every successful start with exactly one stop during rollback or teardown.
            options: [.withoutUI, .withoutImplicitStartAccessing],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        return DoryFSWorkerResolvedBookmark(url: url, isStale: stale)
    }

    func startAccessingSecurityScopedResource(_ url: URL) -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    func stopAccessingSecurityScopedResource(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
}

private final class OwnedRoot: @unchecked Sendable {
    let capabilityID: DoryFSShareCapabilityID

    private let releaseLock = NSLock()
    private var descriptor: Int32
    private let scopedURL: URL
    private let resolver: any DoryFSWorkerBookmarkResolving

    init(
        capabilityID: DoryFSShareCapabilityID,
        descriptor: Int32,
        scopedURL: URL,
        resolver: any DoryFSWorkerBookmarkResolving
    ) {
        self.capabilityID = capabilityID
        self.descriptor = descriptor
        self.scopedURL = scopedURL
        self.resolver = resolver
    }

    func duplicateForBorrow() -> Int32 {
        releaseLock.lock()
        defer { releaseLock.unlock() }
        guard descriptor >= 0 else {
            errno = EBADF
            return -1
        }
        return fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
    }

    func release() {
        releaseLock.lock()
        guard descriptor >= 0 else {
            releaseLock.unlock()
            return
        }
        let ownedDescriptor = descriptor
        descriptor = -1
        releaseLock.unlock()

        _ = Darwin.close(ownedDescriptor)
        resolver.stopAccessingSecurityScopedResource(scopedURL)
    }

    deinit {
        release()
    }
}
