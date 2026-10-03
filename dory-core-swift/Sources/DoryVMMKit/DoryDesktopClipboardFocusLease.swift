import Darwin
import Foundation
import DoryVMDisplayWireContracts
import SystemConfiguration

/// A focus grant must be renewed by the real display owner. It independently expires if the
/// application or broker disappears, including while an agent RPC is blocking a private queue.
public final class DoryDesktopClipboardFocusLease: @unchecked Sendable {
    public static let lifetimeNanoseconds = DoryVMDisplayCommand.maximumFocusLeaseLifetimeNanoseconds
    private let lock = NSLock()
    private let consoleIsActive: @Sendable () -> Bool
    private let clock: @Sendable () -> UInt64
    private var leaseID: UUID?
    private var generation: UUID?
    private var expiresAt: UInt64 = 0
    private var hostAwake = true

    public convenience init() {
        self.init(consoleIsActive: Self.isActiveConsoleUser,
                  clock: { DispatchTime.now().uptimeNanoseconds })
    }

    init(consoleIsActive: @escaping @Sendable () -> Bool,
         clock: @escaping @Sendable () -> UInt64) {
        self.consoleIsActive = consoleIsActive
        self.clock = clock
    }

    @discardableResult
    public func update(
        leaseID: UUID, active: Bool, expiresAtUptimeNanoseconds: UInt64? = nil
    ) -> Bool {
        let now = clock()
        return lock.withLock {
            if !active {
                guard self.leaseID == leaseID else { return false }
                self.leaseID = nil
                generation = nil
                expiresAt = 0
                return true
            }
            guard hostAwake, consoleIsActive() else {
                self.leaseID = nil
                generation = nil
                expiresAt = 0
                return false
            }
            let maximumDeadline = now.addingReportingOverflow(Self.lifetimeNanoseconds)
            let boundedDeadline = maximumDeadline.overflow ? UInt64.max : maximumDeadline.partialValue
            let requestedDeadline = expiresAtUptimeNanoseconds ?? boundedDeadline
            guard requestedDeadline > now, requestedDeadline <= boundedDeadline else { return false }
            if self.leaseID != leaseID || generation == nil || now >= expiresAt {
                generation = UUID()
            }
            self.leaseID = leaseID
            expiresAt = requestedDeadline
            return true
        }
    }

    public func invalidate() {
        lock.withLock { leaseID = nil; generation = nil; expiresAt = 0 }
    }

    func setHostAwake(_ awake: Bool) {
        lock.withLock {
            hostAwake = awake
            leaseID = nil
            generation = nil
            expiresAt = 0
        }
    }

    var currentGeneration: UUID? {
        guard consoleIsActive() else {
            invalidate()
            return nil
        }
        let now = clock()
        return lock.withLock {
            guard hostAwake, now < expiresAt else {
                generation = nil
                return nil
            }
            return generation
        }
    }

    private static func isActiveConsoleUser() -> Bool {
        var userID: uid_t = 0
        var groupID: gid_t = 0
        guard let user = SCDynamicStoreCopyConsoleUser(nil, &userID, &groupID) as String?,
              user != "loginwindow", user != "_mbsetupuser", userID != 0 else { return false }
        return userID == geteuid()
    }
}
