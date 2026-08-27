import Darwin
import DoryFSWorkerContracts
import Foundation

/// Fail-closed errors raised while converting the exact bootstrap envelope and XPC-transferred
/// directory descriptors into pinned worker authority. Errors identify shares only by their
/// unforgeable capability; host paths and process-local descriptor numbers never cross this API.
public enum DoryFSWorkerRootAuthorityError: Error, Equatable, Sendable {
    /// A worker process accepts exactly one bootstrap attempt. A failed attempt is terminal too;
    /// the supervisor must replace the process instead of substituting another authority set.
    case bootstrapAlreadyAttempted
    case bootstrapNotAccepted
    case descriptorCountMismatch(expected: Int, actual: Int)
    case rootDescriptorUnavailable(DoryFSShareCapabilityID, errno: Int32)
    case rootInspectionFailed(DoryFSShareCapabilityID, errno: Int32)
    case rootIsNotDirectory(DoryFSShareCapabilityID)
    case rootIdentityMismatch(DoryFSShareCapabilityID)
    case unknownCapability(DoryFSShareCapabilityID)
    case descriptorBorrowFailed(DoryFSShareCapabilityID, errno: Int32)
}

/// Owns the immutable share roots for one signed worker process.
///
/// The public surface deliberately has no URL, path, bookmark, mutation, or root-enumeration API.
/// Bootstrap consumes already-open directory descriptors transferred by XPC, duplicates them with
/// close-on-exec, and independently checks the sealed device/inode/generation identity. The sole
/// authority-use seam is a synchronous descriptor borrow selected by typed capability.
///
/// The worker deliberately shares the runner's host filesystem namespace. Darwin App Sandbox does
/// not treat an inherited directory descriptor as authority to open its descendants, and an
/// unsandboxed runner cannot mint a Powerbox grant for another sandbox identity. Applying App
/// Sandbox here would therefore make every valid `openat` fail with `EPERM`; confinement is instead
/// the exact signed-XPC, one-shot descriptor, no-path, no-follow capability boundary below.
public final class DoryFSWorkerRootAuthority: @unchecked Sendable {
    private enum Lifecycle {
        case uninitialized
        case resolving
        case accepted([DoryFSShareCapabilityID: OwnedRoot])
        case failed
    }

    private static let processBootstrapAdmission = DoryFSWorkerBootstrapAdmission()

    private let bootstrapAdmission: DoryFSWorkerBootstrapAdmission
    private let stateLock = NSLock()
    private var lifecycle: Lifecycle = .uninitialized

    /// Uses the process-wide one-shot gate. Production callers cannot substitute path reopening or
    /// opt out of the descriptor identity check.
    public init() {
        bootstrapAdmission = Self.processBootstrapAdmission
    }

    /// Decodes and consumes one exact bootstrap envelope, returning its exact receipt bytes only
    /// after every transferred descriptor has been duplicated and matched to its sealed identity.
    ///
    /// Any error permanently consumes the process bootstrap attempt. Every duplicate acquired by
    /// the failed transaction is synchronously released before the error is returned.
    public func bootstrap(
        exactBytes: Data,
        rootDescriptors: [FileHandle]
    ) throws -> Data {
        guard bootstrapAdmission.claim() else {
            throw DoryFSWorkerRootAuthorityError.bootstrapAlreadyAttempted
        }
        setLifecycle(.resolving)

        var acquired = [OwnedRoot]()
        do {
            let bootstrap = try DoryFSWorkerBootstrapCodec.decode(exactBytes)
            guard rootDescriptors.count == bootstrap.shares.count else {
                throw DoryFSWorkerRootAuthorityError.descriptorCountMismatch(
                    expected: bootstrap.shares.count,
                    actual: rootDescriptors.count
                )
            }
            acquired.reserveCapacity(bootstrap.shares.count)
            for share in bootstrap.shares {
                acquired.append(try acquireRoot(for: share, from: rootDescriptors))
            }

            var roots = [DoryFSShareCapabilityID: OwnedRoot](
                minimumCapacity: acquired.count
            )
            for root in acquired {
                // Duplicate capabilities and descriptor indices are rejected by the exact codec.
                // Retain this invariant locally so future codec versions cannot overwrite roots.
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
    /// always closed on callback exit, including thrown exits. A consumer that needs longer-lived
    /// authority must duplicate it explicitly as part of its own bounded lifetime.
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

    // Focused tests use a fresh one-shot gate per scenario. Descriptor acquisition itself is not
    // injectable: tests exercise the same Darwin duplication and inspection path as production.
    init(bootstrapAdmission: DoryFSWorkerBootstrapAdmission) {
        self.bootstrapAdmission = bootstrapAdmission
    }

    private func acquireRoot(
        for share: DoryFSShareBootstrapAuthority,
        from descriptors: [FileHandle]
    ) throws -> OwnedRoot {
        let index = Int(share.rootDescriptorIndex)
        guard descriptors.indices.contains(index) else {
            throw DoryFSWorkerRootAuthorityError.descriptorCountMismatch(
                expected: index + 1,
                actual: descriptors.count
            )
        }

        let duplicate = fcntl(descriptors[index].fileDescriptor, F_DUPFD_CLOEXEC, 0)
        guard duplicate >= 0 else {
            throw DoryFSWorkerRootAuthorityError.rootDescriptorUnavailable(
                share.capabilityID,
                errno: errno
            )
        }
        var transferred = false
        defer {
            if !transferred { _ = Darwin.close(duplicate) }
        }

        var status = stat()
        guard fstat(duplicate, &status) == 0 else {
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
            throw DoryFSWorkerRootAuthorityError.rootIdentityMismatch(share.capabilityID)
        }

        transferred = true
        return OwnedRoot(capabilityID: share.capabilityID, descriptor: duplicate)
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

private final class OwnedRoot: @unchecked Sendable {
    let capabilityID: DoryFSShareCapabilityID

    private let releaseLock = NSLock()
    private var descriptor: Int32

    init(capabilityID: DoryFSShareCapabilityID, descriptor: Int32) {
        self.capabilityID = capabilityID
        self.descriptor = descriptor
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
    }

    deinit {
        release()
    }
}
