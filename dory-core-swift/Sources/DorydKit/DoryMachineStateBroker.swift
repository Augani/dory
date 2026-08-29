import Darwin
import DoryOperations
import Foundation

/// A permanent runtime quarantine for one acquired machine-directory generation.
///
/// These reasons intentionally carry no durable filesystem identity. Device and inode values are
/// process-local evidence exposed separately by ``DoryMachineDirectoryLease/generation`` and are
/// never a persistence contract.
public enum DoryMachineDirectoryLeaseQuarantineReason: Sendable, Equatable {
    /// The trusted state root detected and permanently quarantined its own namespace drift.
    case trustedRoot(DoryTrustedDirectoryRootQuarantineReason)
    /// The retained machine-directory descriptor can no longer be inspected.
    case retainedDescriptorUnavailable(errno: Int32)
    /// The retained descriptor no longer has its acquired identity.
    case retainedDirectoryIdentityChanged
    /// The retained directory is no longer an exact euid-owned mode-0700 directory on the root
    /// filesystem.
    case retainedDirectoryMetadataChanged
    /// The machine ID no longer names an openable no-follow directory beneath the trusted root.
    case currentEntryUnavailable(errno: Int32)
    /// The newly opened current machine entry could not be inspected.
    case currentEntryInspectionFailed(errno: Int32)
    /// The current machine entry is no longer an exact euid-owned mode-0700 directory.
    case currentEntryMetadataChanged
    /// The current machine entry crosses the trusted root's filesystem boundary.
    case currentEntryCrossesRootDevice
    /// The current machine entry names a different device/inode generation.
    case currentEntryIdentityChanged
}

public enum DoryMachineDirectoryLeaseHealth: Sendable, Equatable {
    case healthy
    case quarantined(DoryMachineDirectoryLeaseQuarantineReason)
}

public enum DoryMachineStateBrokerError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidMachineID(String)
    case trustedRoot(DoryTrustedDirectoryRootError)
    case leaseQuarantined(DoryMachineDirectoryLeaseQuarantineReason)

    public var description: String {
        switch self {
        case let .invalidMachineID(machineID):
            "invalid machine identifier: \(machineID)"
        case let .trustedRoot(error):
            "trusted machine-state root rejected the operation: \(error)"
        case let .leaseQuarantined(reason):
            "machine-directory lease is quarantined: \(reason)"
        }
    }
}

/// Daemon-owned entry point for acquiring one machine's durable state-directory authority.
///
/// The broker never derives an authority by joining path strings. It validates the machine ID as
/// one bounded component, then asks ``DoryTrustedDirectoryRoot`` to open that child relative to
/// the root's retained descriptor.
public final class DoryMachineStateBroker: @unchecked Sendable {
    private let trustedRoot: DoryTrustedDirectoryRoot
    private let effectiveUserID: uid_t

    /// Acquires and owns the canonical daemon state root.
    public init(canonicalStateRootPath: String) throws {
        do {
            trustedRoot = try DoryTrustedDirectoryRoot(
                canonicalAbsolutePath: canonicalStateRootPath
            )
        } catch let error as DoryTrustedDirectoryRootError {
            throw DoryMachineStateBrokerError.trustedRoot(error)
        }
        effectiveUserID = geteuid()
    }

    /// Injects an already acquired root, primarily for composition and focused testing.
    public init(trustedRoot: DoryTrustedDirectoryRoot) {
        self.trustedRoot = trustedRoot
        effectiveUserID = geteuid()
    }

    public var rootHealth: DoryTrustedDirectoryRootHealth {
        trustedRoot.health
    }

    /// Pins the current private directory generation for `machineID`.
    ///
    /// Machine IDs deliberately use the daemon's existing 1...63-byte ASCII identifier grammar,
    /// which is narrower than a generic filesystem component.
    public func acquireMachineDirectoryLease(
        machineID: String
    ) throws -> DoryMachineDirectoryLease {
        guard Self.isValidMachineID(machineID) else {
            throw DoryMachineStateBrokerError.invalidMachineID(machineID)
        }

        let component: DoryTrustedPathComponent
        do {
            component = try DoryTrustedPathComponent(validating: machineID)
        } catch {
            throw DoryMachineStateBrokerError.invalidMachineID(machineID)
        }

        let handle: DoryTrustedDirectoryHandle
        do {
            handle = try trustedRoot.openPrivateChildDirectory(component)
        } catch let error as DoryTrustedDirectoryRootError {
            throw DoryMachineStateBrokerError.trustedRoot(error)
        }

        return DoryMachineDirectoryLease(
            machineID: machineID,
            component: component,
            trustedRoot: trustedRoot,
            handle: handle,
            effectiveUserID: effectiveUserID
        )
    }

    private static func isValidMachineID(_ value: String) -> Bool {
        let bytes = value.utf8
        guard (1...63).contains(bytes.count),
              let first = bytes.first,
              isASCIILetterOrDigit(first) else {
            return false
        }
        return bytes.dropFirst().allSatisfy { byte in
            isASCIILetterOrDigit(byte) || byte == 0x5f || byte == 0x2e || byte == 0x2d
        }
    }

    private static func isASCIILetterOrDigit(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39)
            || (byte >= 0x41 && byte <= 0x5a)
            || (byte >= 0x61 && byte <= 0x7a)
    }
}

/// One pinned machine-directory generation.
///
/// Every borrow first revalidates both the trusted root pathname and the root's current machine-ID
/// child against the retained generation. The only authority exposed to callers is a synchronous
/// borrowed `dirfd`; the descriptor remains owned by this lease and must not be closed or retained.
/// One closure can therefore admit disk and boot resources from exactly the same generation.
public final class DoryMachineDirectoryLease: @unchecked Sendable {
    public let machineID: String
    public let generation: DoryTrustedDirectoryIdentity

    private let component: DoryTrustedPathComponent
    private let trustedRoot: DoryTrustedDirectoryRoot
    private let handle: DoryTrustedDirectoryHandle
    private let effectiveUserID: uid_t
    private let operationLock = NSRecursiveLock()
    private let healthLock = NSLock()
    private var storedHealth: DoryMachineDirectoryLeaseHealth = .healthy

    fileprivate init(
        machineID: String,
        component: DoryTrustedPathComponent,
        trustedRoot: DoryTrustedDirectoryRoot,
        handle: DoryTrustedDirectoryHandle,
        effectiveUserID: uid_t
    ) {
        self.machineID = machineID
        self.component = component
        self.trustedRoot = trustedRoot
        self.handle = handle
        self.effectiveUserID = effectiveUserID
        generation = handle.identity
    }

    public var health: DoryMachineDirectoryLeaseHealth {
        healthLock.lock()
        defer { healthLock.unlock() }
        return storedHealth
    }

    /// Revalidates root health, retained-directory metadata, and the current child generation.
    @discardableResult
    public func revalidate() throws -> DoryTrustedDirectoryIdentity {
        operationLock.lock()
        defer { operationLock.unlock() }
        return try revalidateLocked()
    }

    /// Borrows the pinned machine-directory descriptor after a successful revalidation.
    ///
    /// The callback is synchronous and serialized with other operations on this lease. It must not
    /// close the descriptor or allow the integer descriptor value to escape. Descriptor-relative
    /// resources opened by the callback may be returned when they have independent ownership.
    public func withBorrowedDescriptor<T>(
        _ body: (Int32) throws -> T
    ) throws -> T {
        operationLock.lock()
        defer { operationLock.unlock() }
        _ = try revalidateLocked()
        return try handle.withBorrowedDescriptor(body)
    }

    private func revalidateLocked() throws -> DoryTrustedDirectoryIdentity {
        try requireHealthy()

        let currentHandle: DoryTrustedDirectoryHandle
        do {
            // This operation revalidates the root pathname before opening the current child with
            // openat(2), O_NOFOLLOW, and the primitive's exact metadata/device policy.
            currentHandle = try trustedRoot.openPrivateChildDirectory(component)
        } catch let error as DoryTrustedDirectoryRootError {
            throw mapCurrentEntryOrRootError(error)
        }

        var retainedStatus = stat()
        let inspectResult = handle.withBorrowedDescriptor { descriptor in
            fstat(descriptor, &retainedStatus)
        }
        guard inspectResult == 0 else {
            throw quarantine(.retainedDescriptorUnavailable(errno: errno))
        }
        guard UInt64(truncatingIfNeeded: retainedStatus.st_dev) == generation.device,
              UInt64(truncatingIfNeeded: retainedStatus.st_ino) == generation.inode else {
            throw quarantine(.retainedDirectoryIdentityChanged)
        }
        guard Self.isPrivateDirectory(
            retainedStatus,
            effectiveUserID: effectiveUserID,
            rootDevice: trustedRoot.identity.device
        ) else {
            throw quarantine(.retainedDirectoryMetadataChanged)
        }
        guard currentHandle.identity == generation else {
            throw quarantine(.currentEntryIdentityChanged)
        }

        try requireHealthy()
        return generation
    }

    private func mapCurrentEntryOrRootError(
        _ error: DoryTrustedDirectoryRootError
    ) -> DoryMachineStateBrokerError {
        switch error {
        case let .quarantined(reason):
            quarantine(.trustedRoot(reason))
        case let .cannotOpenChild(_, code):
            quarantine(.currentEntryUnavailable(errno: code))
        case let .cannotInspectChild(_, code):
            quarantine(.currentEntryInspectionFailed(errno: code))
        case .unsafeChildDirectory:
            quarantine(.currentEntryMetadataChanged)
        case .crossDeviceChild:
            quarantine(.currentEntryCrossesRootDevice)
        default:
            .trustedRoot(error)
        }
    }

    private static func isPrivateDirectory(
        _ status: stat,
        effectiveUserID: uid_t,
        rootDevice: UInt64
    ) -> Bool {
        status.st_mode & S_IFMT == S_IFDIR
            && status.st_uid == effectiveUserID
            && status.st_mode & mode_t(0o7777) == mode_t(0o700)
            && UInt64(truncatingIfNeeded: status.st_dev) == rootDevice
    }

    private func requireHealthy() throws {
        healthLock.lock()
        defer { healthLock.unlock() }
        if case let .quarantined(reason) = storedHealth {
            throw DoryMachineStateBrokerError.leaseQuarantined(reason)
        }
    }

    private func quarantine(
        _ proposedReason: DoryMachineDirectoryLeaseQuarantineReason
    ) -> DoryMachineStateBrokerError {
        healthLock.lock()
        defer { healthLock.unlock() }
        let reason: DoryMachineDirectoryLeaseQuarantineReason
        switch storedHealth {
        case .healthy:
            storedHealth = .quarantined(proposedReason)
            reason = proposedReason
        case let .quarantined(existing):
            reason = existing
        }
        return .leaseQuarantined(reason)
    }
}
