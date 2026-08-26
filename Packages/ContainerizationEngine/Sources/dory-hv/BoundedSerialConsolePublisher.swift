import Darwin
import Foundation

/// A fixed-capacity FIFO used by ``BoundedSerialConsolePublisher``.
///
/// Keeping the storage fixed is intentional: a guest can write an unlimited console stream, but
/// it cannot make the host helper grow without bound. The publisher reports rejected bytes rather
/// than blocking a vCPU on host I/O or silently allocating more memory.
struct BoundedSerialByteRing {
    private var storage: [UInt8]
    private var head = 0
    private(set) var count = 0

    init(capacity: Int) {
        precondition(capacity > 0)
        storage = [UInt8](repeating: 0, count: capacity)
    }

    var capacity: Int { storage.count }
    var isEmpty: Bool { count == 0 }

    @discardableResult
    mutating func append(_ byte: UInt8) -> Bool {
        guard count < storage.count else { return false }
        storage[(head + count) % storage.count] = byte
        count += 1
        return true
    }

    mutating func removeFirst(maxCount: Int) -> [UInt8] {
        precondition(maxCount > 0)
        let removalCount = min(count, maxCount)
        guard removalCount > 0 else { return [] }

        var result = [UInt8]()
        result.reserveCapacity(removalCount)
        let firstRun = min(removalCount, storage.count - head)
        result.append(contentsOf: storage[head..<(head + firstRun)])
        let secondRun = removalCount - firstRun
        if secondRun > 0 {
            result.append(contentsOf: storage[0..<secondRun])
        }
        head = (head + removalCount) % storage.count
        count -= removalCount
        return result
    }
}

/// Publishes a guest serial stream without performing host writes on a vCPU exit path.
///
/// `enqueue(_:)` performs one bounded FIFO mutation and never waits for a destination. A dedicated
/// worker coalesces bytes into ordered batches, writes each batch to every destination, and drains
/// or reports an exact failure receipt at shutdown. File descriptors are duplicated at creation so
/// the worker never races a caller closing or reusing its original descriptor.
final class BoundedSerialConsolePublisher: @unchecked Sendable {
    struct Destination: Sendable {
        let fileDescriptor: Int32
        let synchronizeOnStop: Bool

        init(fileDescriptor: Int32, synchronizeOnStop: Bool = false) {
            self.fileDescriptor = fileDescriptor
            self.synchronizeOnStop = synchronizeOnStop
        }

        init(fileHandle: FileHandle, synchronizeOnStop: Bool = false) {
            self.init(
                fileDescriptor: fileHandle.fileDescriptor,
                synchronizeOnStop: synchronizeOnStop
            )
        }
    }

    struct Snapshot: Equatable, Sendable {
        let acceptedBytes: UInt64
        let overflowDroppedBytes: UInt64
        let rejectedAfterStopBytes: UInt64
        let processedBytes: UInt64
        let pendingBytes: Int
        let peakPendingBytes: Int
        let batches: UInt64
        let writeSystemCalls: UInt64
        let writeFailureCount: UInt64
        let firstWriteErrno: Int32?
        let synchronizationFailureCount: UInt64
        let firstSynchronizationErrno: Int32?
        let workerExited: Bool

        var isClean: Bool {
            overflowDroppedBytes == 0
                && rejectedAfterStopBytes == 0
                && writeFailureCount == 0
                && synchronizationFailureCount == 0
                && pendingBytes == 0
                && workerExited
        }

        var diagnosticSummary: String {
            let writeErrno = firstWriteErrno.map(String.init) ?? "none"
            let synchronizationErrno = firstSynchronizationErrno.map(String.init) ?? "none"
            return "accepted=\(acceptedBytes) processed=\(processedBytes) pending=\(pendingBytes) "
                + "peakPending=\(peakPendingBytes) overflowDropped=\(overflowDroppedBytes) "
                + "rejectedAfterStop=\(rejectedAfterStopBytes) batches=\(batches) "
                + "writeCalls=\(writeSystemCalls) writeFailures=\(writeFailureCount) "
                + "firstWriteErrno=\(writeErrno) "
                + "syncFailures=\(synchronizationFailureCount) "
                + "firstSyncErrno=\(synchronizationErrno) "
                + "workerExited=\(workerExited)"
        }
    }

    enum StartError: Error, Equatable, CustomStringConvertible {
        case invalidConfiguration(String)
        case duplicateDescriptor(fileDescriptor: Int32, errno: Int32)

        var description: String {
            switch self {
            case .invalidConfiguration(let detail):
                return "invalid serial publisher configuration: \(detail)"
            case .duplicateDescriptor(let fileDescriptor, let error):
                return "could not duplicate serial destination fd \(fileDescriptor): errno \(error)"
            }
        }
    }

    private struct OwnedDestination: Sendable {
        let fileDescriptor: Int32
        let synchronizeOnStop: Bool
    }

    private final class State: @unchecked Sendable {
        let condition = NSCondition()
        let destinations: [OwnedDestination]
        let batchBytes: Int
        let coalescingInterval: TimeInterval
        var ring: BoundedSerialByteRing
        var accepting = true
        var stopRequested = false
        var forceDrain = false
        var workerExited = false
        var inFlightBytes = 0
        var acceptedBytes: UInt64 = 0
        var overflowDroppedBytes: UInt64 = 0
        var rejectedAfterStopBytes: UInt64 = 0
        var processedBytes: UInt64 = 0
        var peakPendingBytes = 0
        var batches: UInt64 = 0
        var writeSystemCalls: UInt64 = 0
        var writeFailureCount: UInt64 = 0
        var firstWriteErrno: Int32?
        var synchronizationFailureCount: UInt64 = 0
        var firstSynchronizationErrno: Int32?

        init(
            destinations: [OwnedDestination],
            capacityBytes: Int,
            batchBytes: Int,
            coalescingInterval: TimeInterval
        ) {
            self.destinations = destinations
            self.batchBytes = batchBytes
            self.coalescingInterval = coalescingInterval
            self.ring = BoundedSerialByteRing(capacity: capacityBytes)
        }

        var pendingBytes: Int { ring.count + inFlightBytes }

        func snapshotLocked() -> Snapshot {
            Snapshot(
                acceptedBytes: acceptedBytes,
                overflowDroppedBytes: overflowDroppedBytes,
                rejectedAfterStopBytes: rejectedAfterStopBytes,
                processedBytes: processedBytes,
                pendingBytes: pendingBytes,
                peakPendingBytes: peakPendingBytes,
                batches: batches,
                writeSystemCalls: writeSystemCalls,
                writeFailureCount: writeFailureCount,
                firstWriteErrno: firstWriteErrno,
                synchronizationFailureCount: synchronizationFailureCount,
                firstSynchronizationErrno: firstSynchronizationErrno,
                workerExited: workerExited
            )
        }
    }

    private struct WriteResult {
        let systemCalls: UInt64
        let failureErrno: Int32?
    }

    private let state: State
    private let worker: Thread

    init(
        destinations: [Destination],
        capacityBytes: Int = 256 * 1_024,
        batchBytes: Int = 16 * 1_024,
        coalescingInterval: TimeInterval = 0.001
    ) throws {
        guard !destinations.isEmpty else {
            throw StartError.invalidConfiguration("at least one destination is required")
        }
        guard capacityBytes > 0 else {
            throw StartError.invalidConfiguration("capacity must be positive")
        }
        guard batchBytes > 0, batchBytes <= capacityBytes else {
            throw StartError.invalidConfiguration("batch size must be within the FIFO capacity")
        }
        guard coalescingInterval >= 0, coalescingInterval.isFinite else {
            throw StartError.invalidConfiguration("coalescing interval must be finite and nonnegative")
        }

        var ownedDestinations = [OwnedDestination]()
        ownedDestinations.reserveCapacity(destinations.count)
        for destination in destinations {
            // The engine launches child helpers after the console is attached. Use an atomic
            // close-on-exec duplicate so serial authority cannot leak across those exec boundaries.
            let duplicate = Darwin.fcntl(destination.fileDescriptor, F_DUPFD_CLOEXEC, 0)
            guard duplicate >= 0 else {
                let savedErrno = errno
                for owned in ownedDestinations { Darwin.close(owned.fileDescriptor) }
                throw StartError.duplicateDescriptor(
                    fileDescriptor: destination.fileDescriptor,
                    errno: savedErrno
                )
            }
            ownedDestinations.append(OwnedDestination(
                fileDescriptor: duplicate,
                synchronizeOnStop: destination.synchronizeOnStop
            ))
        }

        let state = State(
            destinations: ownedDestinations,
            capacityBytes: capacityBytes,
            batchBytes: batchBytes,
            coalescingInterval: coalescingInterval
        )
        self.state = state
        let worker = Thread { Self.runWorker(state) }
        worker.name = "dory-hv.serial-output"
        worker.qualityOfService = .utility
        self.worker = worker
        worker.start()
    }

    /// Enqueues one byte without waiting for host I/O. `false` means the exact bounded policy
    /// rejected it because the FIFO was full or shutdown had already fenced new publication.
    @discardableResult
    func enqueue(_ byte: UInt8) -> Bool {
        state.condition.lock()
        defer { state.condition.unlock() }
        guard state.accepting else {
            state.rejectedAfterStopBytes &+= 1
            return false
        }
        let wasEmpty = state.ring.isEmpty
        guard state.ring.append(byte) else {
            state.overflowDroppedBytes &+= 1
            return false
        }
        state.acceptedBytes &+= 1
        state.peakPendingBytes = max(state.peakPendingBytes, state.pendingBytes)
        if wasEmpty || state.ring.count >= state.batchBytes {
            state.condition.signal()
        }
        return true
    }

    /// Waits only at an explicit non-vCPU boundary for all bytes accepted before this call.
    @discardableResult
    func flush(timeout: TimeInterval = 5) -> Snapshot {
        state.condition.lock()
        let target = state.acceptedBytes
        state.forceDrain = true
        state.condition.broadcast()
        waitLocked(
            until: { state.processedBytes >= target || state.workerExited },
            timeout: timeout
        )
        let result = state.snapshotLocked()
        state.condition.unlock()
        return result
    }

    /// Fences producers, drains accepted bytes, synchronizes durable destinations, and retires the
    /// worker. A timeout is represented by `workerExited == false`; it never turns into an unbounded
    /// shutdown wait.
    @discardableResult
    func stop(timeout: TimeInterval = 5) -> Snapshot {
        state.condition.lock()
        state.accepting = false
        state.stopRequested = true
        state.forceDrain = true
        state.condition.broadcast()
        waitLocked(until: { state.workerExited }, timeout: timeout)
        let result = state.snapshotLocked()
        state.condition.unlock()
        return result
    }

    var snapshot: Snapshot {
        state.condition.lock()
        defer { state.condition.unlock() }
        return state.snapshotLocked()
    }

    private func waitLocked(until predicate: () -> Bool, timeout: TimeInterval) {
        guard !predicate() else { return }
        guard timeout > 0, timeout.isFinite else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), state.condition.wait(until: deadline) {}
    }

    private static func runWorker(_ state: State) {
        while true {
            state.condition.lock()
            while state.ring.isEmpty, !state.stopRequested {
                state.condition.wait()
            }

            if state.ring.isEmpty, state.stopRequested {
                state.condition.unlock()
                finishWorker(state)
                return
            }

            if !state.forceDrain,
               !state.stopRequested,
               state.ring.count < state.batchBytes,
               state.coalescingInterval > 0 {
                let deadline = Date().addingTimeInterval(state.coalescingInterval)
                while state.ring.count < state.batchBytes,
                      !state.forceDrain,
                      !state.stopRequested,
                      state.condition.wait(until: deadline) {}
            }

            let batch = state.ring.removeFirst(maxCount: state.batchBytes)
            state.inFlightBytes = batch.count
            if state.ring.isEmpty { state.forceDrain = false }
            state.condition.unlock()

            var writeResults = [WriteResult]()
            writeResults.reserveCapacity(state.destinations.count)
            for destination in state.destinations {
                writeResults.append(writeAll(batch, to: destination.fileDescriptor))
            }

            state.condition.lock()
            state.inFlightBytes = 0
            state.processedBytes &+= UInt64(batch.count)
            state.batches &+= 1
            if state.ring.isEmpty { state.forceDrain = false }
            for result in writeResults {
                state.writeSystemCalls &+= result.systemCalls
                if let failureErrno = result.failureErrno {
                    state.writeFailureCount &+= 1
                    if state.firstWriteErrno == nil { state.firstWriteErrno = failureErrno }
                }
            }
            state.condition.broadcast()
            state.condition.unlock()
        }
    }

    private static func finishWorker(_ state: State) {
        var synchronizationErrors = [Int32]()
        for destination in state.destinations where destination.synchronizeOnStop {
            while Darwin.fsync(destination.fileDescriptor) != 0 {
                if errno == EINTR { continue }
                synchronizationErrors.append(errno)
                break
            }
        }
        for destination in state.destinations {
            Darwin.close(destination.fileDescriptor)
        }

        state.condition.lock()
        state.synchronizationFailureCount &+= UInt64(synchronizationErrors.count)
        if state.firstSynchronizationErrno == nil {
            state.firstSynchronizationErrno = synchronizationErrors.first
        }
        state.workerExited = true
        state.condition.broadcast()
        state.condition.unlock()
    }

    private static func writeAll(_ bytes: [UInt8], to fileDescriptor: Int32) -> WriteResult {
        var systemCalls: UInt64 = 0
        var failureErrno: Int32?
        bytes.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                systemCalls &+= 1
                let written = Darwin.write(
                    fileDescriptor,
                    baseAddress.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0, errno == EINTR { continue }
                failureErrno = written < 0 ? errno : EIO
                break
            }
        }
        return WriteResult(systemCalls: systemCalls, failureErrno: failureErrno)
    }

    deinit {
        _ = stop(timeout: 1)
        withExtendedLifetime(worker) {}
    }
}
