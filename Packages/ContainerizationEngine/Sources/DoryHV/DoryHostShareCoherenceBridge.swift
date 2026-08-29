import DoryFSWorkerContracts
import Foundation

public enum DoryHostShareCoherenceBridgeError: Error, Equatable, Sendable {
    case unknownCapability
    case policyViolation
    case invalidGuestPath
    case notificationFailure
    case watcherFailure
}

public struct DoryHostShareCoherenceEndpoint: @unchecked Sendable {
    public let capabilityID: DoryFSShareCapabilityID
    public let backend: VirtioFS
    public let guestRoot: String
    public let policy: DoryFSShareCoherencePolicy

    public init(
        capabilityID: DoryFSShareCapabilityID,
        backend: VirtioFS,
        guestRoot: String,
        policy: DoryFSShareCoherencePolicy
    ) throws {
        guard guestRoot.hasPrefix("/"), guestRoot != "/",
              !guestRoot.hasSuffix("/"), !guestRoot.utf8.contains(0),
              !guestRoot.split(separator: "/", omittingEmptySubsequences: false)
                  .contains("..") else {
            throw DoryHostShareCoherenceBridgeError.invalidGuestPath
        }
        self.capabilityID = capabilityID
        self.backend = backend
        self.guestRoot = guestRoot
        self.policy = policy
    }
}

/// Runner half of host-edit coherence. The actor preserves invalidation-before-watcher ordering;
/// the terminal latch closes every sibling VirtioFS publication gate synchronously on any loss.
public actor DoryHostShareCoherenceBridge {
    private final class TerminalLatch: @unchecked Sendable {
        private let lock = NSLock()
        private let backends: [VirtioFS]
        private let onFatal: @Sendable (String) -> Void
        private var failed = false

        init(
            backends: [VirtioFS],
            onFatal: @escaping @Sendable (String) -> Void
        ) {
            self.backends = backends
            self.onFatal = onFatal
        }

        func fail(_ reason: String) {
            let shouldReport = lock.withLock { () -> Bool in
                guard !failed else { return false }
                failed = true
                // Close all request-publication gates while the terminal lock is held. A quiet
                // sibling mount may otherwise keep serving cached pages without another RPC.
                for backend in backends { backend.failStopRequestPublication() }
                return true
            }
            if shouldReport { onFatal(reason) }
        }

        var isFailed: Bool { lock.withLock { failed } }
    }

    private static let reverseInvalidationDeadline: Duration = .seconds(1)
    private let endpoints: [DoryFSShareCapabilityID: DoryHostShareCoherenceEndpoint]
    private let guestEvents: any GuestFSEventSending
    private let terminal: TerminalLatch

    public init(
        endpoints: [DoryHostShareCoherenceEndpoint],
        guestEvents: any GuestFSEventSending,
        onFatal: @escaping @Sendable (String) -> Void
    ) {
        self.endpoints = Dictionary(uniqueKeysWithValues: endpoints.map {
            ($0.capabilityID, $0)
        })
        self.guestEvents = guestEvents
        terminal = TerminalLatch(
            backends: endpoints.map(\.backend),
            onFatal: onFatal
        )
    }

    /// May be called directly from an XPC lifecycle callback; it performs the fail-stop latch
    /// synchronously and does not wait for actor scheduling.
    public nonisolated func failStop(_ reason: String) {
        terminal.fail(reason)
    }

    public func process(_ batch: DoryFSWorkerCoherenceBatch) async throws {
        guard !terminal.isFailed else {
            throw DoryHostShareCoherenceBridgeError.notificationFailure
        }
        guard let endpoint = endpoints[batch.shareCapabilityID],
              endpoint.policy != .disabled else {
            terminal.fail("filesystem coherence referenced an unknown or disabled capability")
            throw DoryHostShareCoherenceBridgeError.unknownCapability
        }
        if endpoint.policy == .invalidationOnly, !batch.nudgeRelativePaths.isEmpty {
            terminal.fail("filesystem worker crossed its invalidation-only policy")
            throw DoryHostShareCoherenceBridgeError.policyViolation
        }

        let invalidations = batch.invalidations.map { value in
            switch value {
            case .inode(let nodeID, let offset, let length):
                VirtioFSInvalidation.inode(
                    nodeID: nodeID,
                    offset: offset,
                    length: length
                )
            case .entry(let parentNodeID, let name, let flags):
                VirtioFSInvalidation.entry(
                    parentNodeID: parentNodeID,
                    name: name,
                    flags: flags
                )
            case .delete(let parentNodeID, let childNodeID, let name):
                VirtioFSInvalidation.delete(
                    parentNodeID: parentNodeID,
                    childNodeID: childNodeID,
                    name: name
                )
            }
        }
        do {
            if !invalidations.isEmpty {
                try await endpoint.backend.invalidateAtomically(
                    invalidations,
                    maximumBatchSize: min(
                        128,
                        max(1, endpoint.backend.notificationBacklogLimit)
                    ),
                    timeout: Self.reverseInvalidationDeadline
                )
            }
        } catch {
            terminal.fail("host-share reverse invalidation failed")
            throw DoryHostShareCoherenceBridgeError.notificationFailure
        }

        guard !batch.nudgeRelativePaths.isEmpty else { return }
        let guestPaths: [String]
        do {
            guestPaths = try batch.nudgeRelativePaths.map {
                try Self.guestPath(root: endpoint.guestRoot, relative: $0)
            }
        } catch {
            terminal.fail("host-share watcher path validation failed")
            throw DoryHostShareCoherenceBridgeError.invalidGuestPath
        }
        do {
            let result = try await guestEvents.send(
                operationID: batch.batchID,
                paths: guestPaths
            )
            guard result.pathCount == UInt32(guestPaths.count), result.failed == 0 else {
                throw DoryHostShareCoherenceBridgeError.watcherFailure
            }
        } catch {
            terminal.fail("host-share watcher notification failed")
            throw DoryHostShareCoherenceBridgeError.watcherFailure
        }
    }

    private static func guestPath(root: String, relative: String) throws -> String {
        let path = relative.isEmpty ? root : root + "/" + relative
        guard path.utf8.count <= GuestFSEventBatchCodec.maximumPathBytes,
              path.hasPrefix("/"), !path.utf8.contains(0),
              !path.split(separator: "/", omittingEmptySubsequences: false)
                  .contains("..") else {
            throw DoryHostShareCoherenceBridgeError.invalidGuestPath
        }
        return path
    }
}
