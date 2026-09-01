import DoryFSWorkerContracts
import Foundation

public enum DoryHostShareCoherenceBridgeError: Error, Equatable, Sendable {
    case unknownCapability
    case policyViolation
    case invalidGuestPath
    case notificationFailure
    case watcherFailure
    case transactionViolation
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
    private struct ActiveTransaction {
        let id: UInt64
        let capability: DoryFSShareCapabilityID
        let count: UInt16
        var nextIndex: UInt16
        let backendTransaction: VirtioFSInvalidationTransaction
    }

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
    private let onDiagnostic: @Sendable (String) -> Void
    private let terminal: TerminalLatch
    private let interFrameDeadline: Duration
    private var activeTransaction: ActiveTransaction?
    private var transactionWatchdog: Task<Void, Never>?
    private var processingUniqueFrame = false

    public init(
        endpoints: [DoryHostShareCoherenceEndpoint],
        guestEvents: any GuestFSEventSending,
        onDiagnostic: @escaping @Sendable (String) -> Void = { _ in },
        interFrameDeadline: Duration = .seconds(5),
        onFatal: @escaping @Sendable (String) -> Void
    ) {
        self.endpoints = Dictionary(uniqueKeysWithValues: endpoints.map {
            ($0.capabilityID, $0)
        })
        self.guestEvents = guestEvents
        self.onDiagnostic = onDiagnostic
        self.interFrameDeadline = interFrameDeadline
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
        guard !processingUniqueFrame else {
            terminal.fail("filesystem coherence frames overlapped")
            throw DoryHostShareCoherenceBridgeError.transactionViolation
        }
        processingUniqueFrame = true
        defer { processingUniqueFrame = false }
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
        let maximumBatchSize = min(
            128,
            max(1, endpoint.backend.notificationBacklogLimit)
        )
        let isStandalone = batch.transactionCount == 1
        do {
            if isStandalone {
                guard activeTransaction == nil else {
                    throw DoryHostShareCoherenceBridgeError.transactionViolation
                }
                if !invalidations.isEmpty {
                    try await endpoint.backend.invalidateAtomically(
                        invalidations,
                        maximumBatchSize: maximumBatchSize,
                        timeout: Self.reverseInvalidationDeadline
                    )
                }
            } else if batch.transactionIndex == 0 {
                guard activeTransaction == nil, !invalidations.isEmpty else {
                    throw DoryHostShareCoherenceBridgeError.transactionViolation
                }
                let backendTransaction = try await endpoint.backend.beginInvalidationTransaction(
                    invalidations,
                    maximumBatchSize: maximumBatchSize,
                    timeout: Self.reverseInvalidationDeadline
                )
                guard !terminal.isFailed else {
                    throw DoryHostShareCoherenceBridgeError.notificationFailure
                }
                activeTransaction = ActiveTransaction(
                    id: batch.transactionID,
                    capability: batch.shareCapabilityID,
                    count: batch.transactionCount,
                    nextIndex: 1,
                    backendTransaction: backendTransaction
                )
                armTransactionWatchdog(transactionID: batch.transactionID)
                return
            } else {
                guard let current = activeTransaction,
                      current.id == batch.transactionID,
                      current.capability == batch.shareCapabilityID,
                      current.count == batch.transactionCount,
                      current.nextIndex == batch.transactionIndex,
                      !invalidations.isEmpty else {
                    throw DoryHostShareCoherenceBridgeError.transactionViolation
                }
                let finishing = batch.transactionIndex == batch.transactionCount - 1
                try await endpoint.backend.continueInvalidationTransaction(
                    current.backendTransaction,
                    invalidations: invalidations,
                    maximumBatchSize: maximumBatchSize,
                    timeout: Self.reverseInvalidationDeadline,
                    finishing: finishing
                )
                guard !terminal.isFailed else {
                    throw DoryHostShareCoherenceBridgeError.notificationFailure
                }
                if finishing {
                    transactionWatchdog?.cancel()
                    transactionWatchdog = nil
                    activeTransaction = nil
                } else {
                    activeTransaction?.nextIndex += 1
                    armTransactionWatchdog(transactionID: batch.transactionID)
                    return
                }
            }
        } catch let error as DoryHostShareCoherenceBridgeError {
            terminal.fail("host-share coherence transaction sequence failed")
            throw error
        } catch {
            terminal.fail("host-share reverse invalidation failed")
            throw DoryHostShareCoherenceBridgeError.notificationFailure
        }

        guard !terminal.isFailed else {
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
                onDiagnostic(
                    "host-share watcher skipped \(result.failed) of \(result.pathCount) paths; "
                        + "reverse cache invalidation remains active"
                )
                return
            }
        } catch {
            // Reverse invalidation has already completed. The Linux watcher nudge is a hot-reload
            // aid, not a cache or data-correctness boundary, and must never destroy a workload.
            onDiagnostic(
                "host-share watcher notification skipped for \(guestPaths.count) paths: \(error); "
                    + "reverse cache invalidation remains active"
            )
        }
    }

    private func armTransactionWatchdog(transactionID: UInt64) {
        transactionWatchdog?.cancel()
        let deadline = interFrameDeadline
        transactionWatchdog = Task { [weak self] in
            do {
                try await Task.sleep(for: deadline)
            } catch {
                return
            }
            await self?.transactionDidTimeOut(transactionID: transactionID)
        }
    }

    private func transactionDidTimeOut(transactionID: UInt64) {
        guard activeTransaction?.id == transactionID else { return }
        terminal.fail("filesystem coherence transaction timed out between frames")
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
