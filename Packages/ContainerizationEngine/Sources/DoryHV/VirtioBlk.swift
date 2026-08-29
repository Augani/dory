import Darwin
import Foundation

/// I/O, queue, and request event totals wrap modulo 2^64; the legacy flush totals saturate.
/// Queue depth and in-flight transfers are sampled gauges. High-watermarks and maximum latency
/// retain the largest value observed by this backend.
public struct VirtioBlkStatistics: Equatable, Sendable {
    public var flushes: UInt64
    public var maximumFlushLatencyNanoseconds: UInt64
    public var slowFlushes: UInt64
    public var invalidRequests: UInt64
    public var queuePopFaults: UInt64
    public var completionFaults: UInt64
    public var boundedDrainStops: UInt64
    public var queueWorkTurns: UInt64
    public var queueDepth: UInt64
    public var queueHighWatermark: UInt64
    public var requestCompletions: UInt64
    public var revokedRequests: UInt64
    public var requestServiceLatencyNanoseconds: UInt64
    public var maximumRequestServiceLatencyNanoseconds: UInt64
    public var readRequests: UInt64
    public var writeRequests: UInt64
    public var readBytes: UInt64
    public var writeBytes: UInt64
    public var readSystemCalls: UInt64
    public var writeSystemCalls: UInt64
    public var partialIOSystemCalls: UInt64
    public var interruptedIOSystemCalls: UInt64
    public var failedIOSystemCalls: UInt64
    public var hostIOBudgetExhaustions: UInt64
    public var transferSegments: UInt64
    public var inFlightTransfers: UInt64
    public var maximumInFlightTransfers: UInt64
    public var discardRequests: UInt64
    public var discardRequestedBytes: UInt64
    public var discardHostOperations: UInt64
    public var discardIgnoredRanges: UInt64
    public var writeZeroesRequests: UInt64
    public var writeZeroesRequestedBytes: UInt64
    public var writeZeroesHostWrittenBytes: UInt64
    public var writeZeroesHostOperations: UInt64
    public var rangePartialHostOperations: UInt64
    public var rangeInterruptedHostOperations: UInt64
    public var rangeFailedHostOperations: UInt64
    public var rangeHostOperationBudgetExhaustions: UInt64
    public var rangeSegments: UInt64
    public var rangeTurnBudgetStops: UInt64

    public init(
        flushes: UInt64,
        maximumFlushLatencyNanoseconds: UInt64,
        slowFlushes: UInt64,
        invalidRequests: UInt64 = 0,
        queuePopFaults: UInt64 = 0,
        completionFaults: UInt64 = 0,
        boundedDrainStops: UInt64 = 0,
        queueWorkTurns: UInt64 = 0,
        queueDepth: UInt64 = 0,
        queueHighWatermark: UInt64 = 0,
        requestCompletions: UInt64 = 0,
        revokedRequests: UInt64 = 0,
        requestServiceLatencyNanoseconds: UInt64 = 0,
        maximumRequestServiceLatencyNanoseconds: UInt64 = 0,
        readRequests: UInt64 = 0,
        writeRequests: UInt64 = 0,
        readBytes: UInt64 = 0,
        writeBytes: UInt64 = 0,
        readSystemCalls: UInt64 = 0,
        writeSystemCalls: UInt64 = 0,
        partialIOSystemCalls: UInt64 = 0,
        interruptedIOSystemCalls: UInt64 = 0,
        failedIOSystemCalls: UInt64 = 0,
        hostIOBudgetExhaustions: UInt64 = 0,
        transferSegments: UInt64 = 0,
        inFlightTransfers: UInt64 = 0,
        maximumInFlightTransfers: UInt64 = 0,
        discardRequests: UInt64 = 0,
        discardRequestedBytes: UInt64 = 0,
        discardHostOperations: UInt64 = 0,
        discardIgnoredRanges: UInt64 = 0,
        writeZeroesRequests: UInt64 = 0,
        writeZeroesRequestedBytes: UInt64 = 0,
        writeZeroesHostWrittenBytes: UInt64 = 0,
        writeZeroesHostOperations: UInt64 = 0,
        rangePartialHostOperations: UInt64 = 0,
        rangeInterruptedHostOperations: UInt64 = 0,
        rangeFailedHostOperations: UInt64 = 0,
        rangeHostOperationBudgetExhaustions: UInt64 = 0,
        rangeSegments: UInt64 = 0,
        rangeTurnBudgetStops: UInt64 = 0
    ) {
        self.flushes = flushes
        self.maximumFlushLatencyNanoseconds = maximumFlushLatencyNanoseconds
        self.slowFlushes = slowFlushes
        self.invalidRequests = invalidRequests
        self.queuePopFaults = queuePopFaults
        self.completionFaults = completionFaults
        self.boundedDrainStops = boundedDrainStops
        self.queueWorkTurns = queueWorkTurns
        self.queueDepth = queueDepth
        self.queueHighWatermark = queueHighWatermark
        self.requestCompletions = requestCompletions
        self.revokedRequests = revokedRequests
        self.requestServiceLatencyNanoseconds = requestServiceLatencyNanoseconds
        self.maximumRequestServiceLatencyNanoseconds = maximumRequestServiceLatencyNanoseconds
        self.readRequests = readRequests
        self.writeRequests = writeRequests
        self.readBytes = readBytes
        self.writeBytes = writeBytes
        self.readSystemCalls = readSystemCalls
        self.writeSystemCalls = writeSystemCalls
        self.partialIOSystemCalls = partialIOSystemCalls
        self.interruptedIOSystemCalls = interruptedIOSystemCalls
        self.failedIOSystemCalls = failedIOSystemCalls
        self.hostIOBudgetExhaustions = hostIOBudgetExhaustions
        self.transferSegments = transferSegments
        self.inFlightTransfers = inFlightTransfers
        self.maximumInFlightTransfers = maximumInFlightTransfers
        self.discardRequests = discardRequests
        self.discardRequestedBytes = discardRequestedBytes
        self.discardHostOperations = discardHostOperations
        self.discardIgnoredRanges = discardIgnoredRanges
        self.writeZeroesRequests = writeZeroesRequests
        self.writeZeroesRequestedBytes = writeZeroesRequestedBytes
        self.writeZeroesHostWrittenBytes = writeZeroesHostWrittenBytes
        self.writeZeroesHostOperations = writeZeroesHostOperations
        self.rangePartialHostOperations = rangePartialHostOperations
        self.rangeInterruptedHostOperations = rangeInterruptedHostOperations
        self.rangeFailedHostOperations = rangeFailedHostOperations
        self.rangeHostOperationBudgetExhaustions = rangeHostOperationBudgetExhaustions
        self.rangeSegments = rangeSegments
        self.rangeTurnBudgetStops = rangeTurnBudgetStops
    }
}

struct VirtioBlkLimits: Equatable, Sendable {
    static let production = VirtioBlkLimits(
        maximumTransferBytes: 16 * 1_024 * 1_024,
        maximumChainsPerDrain: 64,
        maximumTransferBytesPerDrain: 64 * 1_024 * 1_024,
        maximumIOVectorsPerSystemCall: 256,
        maximumHostIOOperationsPerRequest: 1_024,
        maximumDiscardSegmentsPerRequest: 64,
        maximumWriteZeroesSegmentsPerRequest: 4,
        maximumWriteZeroesBytesPerRequest: 16 * 1_024 * 1_024,
        maximumRangeHostOperationsPerRequest: 64,
        maximumRangeHostOperationsPerDrain: 64
    )

    let maximumTransferBytes: Int
    let maximumChainsPerDrain: Int
    let maximumTransferBytesPerDrain: Int
    let maximumIOVectorsPerSystemCall: Int
    let maximumHostIOOperationsPerRequest: Int
    let maximumDiscardSegmentsPerRequest: Int
    let maximumWriteZeroesSegmentsPerRequest: Int
    let maximumWriteZeroesBytesPerRequest: Int
    let maximumRangeHostOperationsPerRequest: Int
    let maximumRangeHostOperationsPerDrain: Int

    init(
        maximumTransferBytes: Int,
        maximumChainsPerDrain: Int,
        maximumTransferBytesPerDrain: Int = 64 * 1_024 * 1_024,
        maximumIOVectorsPerSystemCall: Int = 256,
        maximumHostIOOperationsPerRequest: Int = 1_024,
        maximumDiscardSegmentsPerRequest: Int = 64,
        maximumWriteZeroesSegmentsPerRequest: Int = 4,
        maximumWriteZeroesBytesPerRequest: Int = 16 * 1_024 * 1_024,
        maximumRangeHostOperationsPerRequest: Int = 64,
        maximumRangeHostOperationsPerDrain: Int = 64
    ) {
        precondition(maximumTransferBytes >= 512)
        precondition(maximumTransferBytes % 512 == 0)
        precondition(maximumChainsPerDrain > 0)
        precondition(maximumChainsPerDrain <= Int(Virtqueue.maximumSize))
        precondition(maximumTransferBytesPerDrain >= maximumTransferBytes)
        precondition(maximumIOVectorsPerSystemCall > 0)
        precondition(maximumIOVectorsPerSystemCall <= 256)
        precondition(maximumHostIOOperationsPerRequest > 0)
        precondition((1...256).contains(maximumDiscardSegmentsPerRequest))
        precondition((1...256).contains(maximumWriteZeroesSegmentsPerRequest))
        precondition(maximumWriteZeroesBytesPerRequest >= 512)
        precondition(maximumWriteZeroesBytesPerRequest % 512 == 0)
        precondition(
            maximumWriteZeroesBytesPerRequest / 512
                >= maximumWriteZeroesSegmentsPerRequest
        )
        precondition(
            UInt64(
                maximumWriteZeroesBytesPerRequest
                    / maximumWriteZeroesSegmentsPerRequest / 512
            ) <= UInt64(UInt32.max)
        )
        precondition(maximumRangeHostOperationsPerRequest > 0)
        precondition(maximumDiscardSegmentsPerRequest <= maximumRangeHostOperationsPerRequest)
        precondition(maximumRangeHostOperationsPerDrain > 0)
        self.maximumTransferBytes = maximumTransferBytes
        self.maximumChainsPerDrain = maximumChainsPerDrain
        self.maximumTransferBytesPerDrain = maximumTransferBytesPerDrain
        self.maximumIOVectorsPerSystemCall = maximumIOVectorsPerSystemCall
        self.maximumHostIOOperationsPerRequest = maximumHostIOOperationsPerRequest
        self.maximumDiscardSegmentsPerRequest = maximumDiscardSegmentsPerRequest
        self.maximumWriteZeroesSegmentsPerRequest = maximumWriteZeroesSegmentsPerRequest
        self.maximumWriteZeroesBytesPerRequest = maximumWriteZeroesBytesPerRequest
        self.maximumRangeHostOperationsPerRequest = maximumRangeHostOperationsPerRequest
        self.maximumRangeHostOperationsPerDrain = maximumRangeHostOperationsPerDrain
    }
}

struct VirtioBlkHostIOResult: Equatable, Sendable {
    var count: Int
    var code: Int32
}

struct VirtioBlkIOOperations: @unchecked Sendable {
    typealias VectoredOperation = (
        Int32,
        UnsafePointer<iovec>,
        Int32,
        off_t
    ) -> VirtioBlkHostIOResult

    var read: VectoredOperation
    var write: VectoredOperation
    var monotonicNanoseconds: () -> UInt64

    static var production: Self {
        Self(
            read: { descriptor, vectors, count, offset in
                let result = Darwin.preadv(descriptor, vectors, count, offset)
                return VirtioBlkHostIOResult(
                    count: result,
                    code: result < 0 ? errno : 0
                )
            },
            write: { descriptor, vectors, count, offset in
                let result = Darwin.pwritev(descriptor, vectors, count, offset)
                return VirtioBlkHostIOResult(
                    count: result,
                    code: result < 0 ? errno : 0
                )
            },
            monotonicNanoseconds: { DispatchTime.now().uptimeNanoseconds }
        )
    }
}

struct VirtioBlkRangeOperations: @unchecked Sendable {
    typealias PunchHoleOperation = (Int32, off_t, off_t) -> VirtioBlkHostIOResult

    var punchHole: PunchHoleOperation

    static var production: Self {
        Self(punchHole: { descriptor, offset, length in
            var punch = fpunchhole_t(
                fp_flags: 0,
                reserved: 0,
                fp_offset: offset,
                fp_length: length
            )
            let result = withUnsafeMutablePointer(to: &punch) {
                fcntl(descriptor, F_PUNCHHOLE, $0)
            }
            return VirtioBlkHostIOResult(
                count: Int(result),
                code: result < 0 ? errno : 0
            )
        })
    }
}

struct VirtioBlkFlushTelemetryConfiguration {
    var slowThresholdNanoseconds: UInt64
    var synchronize: (Int32) -> Int32
    var monotonicNanoseconds: () -> UInt64

    static var production: Self {
        Self(
            slowThresholdNanoseconds: 250_000_000,
            synchronize: { descriptor in Darwin.fsync(descriptor) },
            monotonicNanoseconds: { DispatchTime.now().uptimeNanoseconds }
        )
    }
}

/// virtio-blk backed by a raw disk image. Requests use zero-copy preadv/pwritev straight into guest
/// RAM; disk I/O is drained on dedicated ordered workers so the kicking vCPU is not parked inside
/// host file syscalls during metadata-heavy workloads. Production policy is explicit at the
/// initializer boundary; ambient process environment cannot silently change the guest ABI.
public final class VirtioBlk: VirtioDeviceBackend {
    public let deviceID: UInt32 = 2
    public let queueCount: Int
    public let kickSynchronization: VirtioKickSynchronization = .backendManaged
    public var deviceFeatures: UInt64 {
        var features = Self.Feature.flush
        if readOnly {
            features |= Self.Feature.readOnly
        }
        if queueCount > 1 {
            features |= Self.Feature.multiqueue
        }
        if discardEnabled {
            features |= Self.Feature.discard | Self.Feature.writeZeroes
        }
        return features
    }

    private let fileDescriptor: Int32
    private let capacitySectors: UInt64
    private let capacityBytes: UInt64
    private let identity: String
    private let readOnly: Bool
    private let asyncIO: Bool
    private let discardEnabled: Bool
    private let discardBlockSize: Int
    private let limits: VirtioBlkLimits
    private let ioOperations: VirtioBlkIOOperations
    private let rangeOperations: VirtioBlkRangeOperations
    private let ioQueues: [DispatchQueue]
    private let ioQueueKey = DispatchSpecificKey<Int>()
    private let drainLock = NSLock()
    private var deviceIsReady = false
    private var drainIsTerminal = false
    private var queueDrainStates: [QueueDrainState]
    private var queueDepthHighWatermark = 0
    private let requestCondition = NSCondition()
    private var inFlightTransfers = 0
    private var maximumInFlightTransferCount = 0
    private var flushActive = false
    private let flushTelemetry: VirtioBlkFlushTelemetryConfiguration
    private let statisticsLock = NSLock()
    private var flushCount: UInt64 = 0
    private var maximumFlushLatencyNanoseconds: UInt64 = 0
    private var slowFlushCount: UInt64 = 0
    private var invalidRequestCount: UInt64 = 0
    private var queuePopFaultCount: UInt64 = 0
    private var completionFaultCount: UInt64 = 0
    private var boundedDrainStopCount: UInt64 = 0
    private var queueWorkTurnCount: UInt64 = 0
    private var requestCompletionCount: UInt64 = 0
    private var revokedRequestCount: UInt64 = 0
    private var requestServiceLatencyNanoseconds: UInt64 = 0
    private var maximumRequestServiceLatencyNanoseconds: UInt64 = 0
    private var readRequestCount: UInt64 = 0
    private var writeRequestCount: UInt64 = 0
    private var readByteCount: UInt64 = 0
    private var writeByteCount: UInt64 = 0
    private var readSystemCallCount: UInt64 = 0
    private var writeSystemCallCount: UInt64 = 0
    private var partialIOSystemCallCount: UInt64 = 0
    private var interruptedIOSystemCallCount: UInt64 = 0
    private var failedIOSystemCallCount: UInt64 = 0
    private var hostIOBudgetExhaustionCount: UInt64 = 0
    private var transferSegmentCount: UInt64 = 0
    private var discardRequestCount: UInt64 = 0
    private var discardRequestedByteCount: UInt64 = 0
    private var discardHostOperationCount: UInt64 = 0
    private var discardIgnoredRangeCount: UInt64 = 0
    private var writeZeroesRequestCount: UInt64 = 0
    private var writeZeroesRequestedByteCount: UInt64 = 0
    private var writeZeroesHostWrittenByteCount: UInt64 = 0
    private var writeZeroesHostOperationCount: UInt64 = 0
    private var rangePartialHostOperationCount: UInt64 = 0
    private var rangeInterruptedHostOperationCount: UInt64 = 0
    private var rangeFailedHostOperationCount: UInt64 = 0
    private var rangeHostOperationBudgetExhaustionCount: UInt64 = 0
    private var rangeSegmentCount: UInt64 = 0
    private var rangeTurnBudgetStopCount: UInt64 = 0

    private struct QueueDrainState {
        var generation: UInt64 = 1
        var transportIdentity: ObjectIdentifier?
        var activeGeneration: UInt64?
        var kickPending = false
        var queueDepth = 0

        mutating func advanceGeneration() {
            generation &+= 1
            if generation == 0 { generation = 1 }
        }

        mutating func revoke(replacementTransportIdentity: ObjectIdentifier?) {
            advanceGeneration()
            transportIdentity = replacementTransportIdentity
            activeGeneration = nil
            kickPending = false
            queueDepth = 0
        }
    }

    private struct DrainEpoch: Sendable {
        let queue: Int
        let generation: UInt64
        let transportIdentity: ObjectIdentifier
    }

    private enum DrainBatchOutcome {
        case drained
        case pending
        case fault
        case stale
    }

    private enum QueuePopOutcome {
        case chain(VirtqueueChain)
        case empty
        case fault
        case stale
    }

    private enum QueueDepthOutcome {
        case depth(Int)
        case fault
        case stale
    }

    private enum QueuePushOutcome {
        case published(wantsInterrupt: Bool)
        case fault
        case stale
    }

    private struct RequestExecution {
        let written: Int
        let workBytes: Int
        let rangeHostOperations: Int

        init(written: Int, workBytes: Int, rangeHostOperations: Int = 0) {
            self.written = written
            self.workBytes = workBytes
            self.rangeHostOperations = rangeHostOperations
        }
    }

    private struct HostTransferReceipt {
        var status: RequestStatus
        var actualBytes = 0
        var systemCalls = 0
        var partialSystemCalls = 0
        var interruptedSystemCalls = 0
        var failedSystemCalls = 0
        var budgetExhaustions = 0
    }

    private struct RangeCommandExecution {
        var status: RequestStatus
        var requestedBytes: UInt64 = 0
        var hostWrittenBytes = 0
        var hostOperations = 0
        var partialHostOperations = 0
        var interruptedHostOperations = 0
        var failedHostOperations = 0
        var hostOperationBudgetExhaustions = 0
        var segmentCount = 0
        var ignoredDiscardRanges = 0
        var fairnessBytes = 0

        mutating func mergeHostTransfer(_ receipt: HostTransferReceipt) {
            hostWrittenBytes &+= receipt.actualBytes
            hostOperations &+= receipt.systemCalls
            partialHostOperations &+= receipt.partialSystemCalls
            interruptedHostOperations &+= receipt.interruptedSystemCalls
            failedHostOperations &+= receipt.failedSystemCalls
            hostOperationBudgetExhaustions &+= receipt.budgetExhaustions
        }
    }

    private enum Feature {
        static let readOnly: UInt64 = 1 << 5     // VIRTIO_BLK_F_RO
        static let flush: UInt64 = 1 << 9        // VIRTIO_BLK_F_FLUSH
        static let multiqueue: UInt64 = 1 << 12  // VIRTIO_BLK_F_MQ
        static let discard: UInt64 = 1 << 13     // VIRTIO_BLK_F_DISCARD
        static let writeZeroes: UInt64 = 1 << 14 // VIRTIO_BLK_F_WRITE_ZEROES
    }

    // DISCARD remains range-efficient because one aligned range is one hole-punch operation. Plain
    // WRITE_ZEROES is intentionally advertised as at most 16 MiB across four segments: the host
    // must write those bytes to preserve allocation, and the guest splits larger work fairly.
    private enum Discard {
        static let maxSectors: UInt32 = 1 << 22  // 2 GiB / 512
        static let sectorAlignment: UInt32 = 1
        static let entryByteCount = 16           // struct virtio_blk_discard_write_zeroes
        static let unmapFlag: UInt32 = 1 << 0    // VIRTIO_BLK_WRITE_ZEROES_FLAG_UNMAP
    }

    private enum RequestType: UInt32 {
        case read = 0
        case write = 1
        case flush = 4
        case getID = 8
        case discard = 11
        case writeZeroes = 13
    }

    enum RequestStatus: UInt8 {
        case ok = 0
        case ioError = 1
        case unsupported = 2
    }

    struct ByteRange: Equatable {
        let offset: off_t
        let length: off_t
    }

    private struct BackingFile {
        let descriptor: Int32
        let capacitySectors: UInt64
        let capacityBytes: UInt64
        let discardBlockSize: Int
    }

    private struct DiscardOperation {
        let range: ByteRange
        let deallocate: Bool
    }

    public convenience init(
        path: String,
        identity: String,
        readOnly: Bool = false,
        queueCount requestedQueueCount: Int? = nil,
        discard: Bool? = nil
    ) throws {
        try self.init(
            path: path,
            identity: identity,
            readOnly: readOnly,
            asyncIO: true,
            queueCount: requestedQueueCount,
            discard: discard,
            flushTelemetry: .production
        )
    }

    /// Synchronous execution exists only as a deterministic unit-test seam. Production callers
    /// cannot opt a vCPU back into host file I/O through the public initializer.
    convenience init(
        path: String,
        identity: String,
        readOnly: Bool = false,
        asyncIO: Bool,
        queueCount requestedQueueCount: Int? = nil,
        discard: Bool? = nil
    ) throws {
        try self.init(
            path: path,
            identity: identity,
            readOnly: readOnly,
            asyncIO: asyncIO,
            queueCount: requestedQueueCount,
            discard: discard,
            flushTelemetry: .production
        )
    }

    convenience init(
        path: String,
        identity: String,
        readOnly: Bool = false,
        asyncIO: Bool = true,
        queueCount requestedQueueCount: Int? = nil,
        discard: Bool? = nil,
        flushTelemetry: VirtioBlkFlushTelemetryConfiguration,
        limits: VirtioBlkLimits = .production,
        ioOperations: VirtioBlkIOOperations = .production,
        rangeOperations: VirtioBlkRangeOperations = .production
    ) throws {
        let descriptor = open(
            path,
            (readOnly ? O_RDONLY : O_RDWR) | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard descriptor >= 0 else {
            throw VMError.invalidConfiguration("cannot open disk image \(path): errno \(errno)")
        }
        do {
            let backing = try Self.inspectOwnedDescriptor(
                descriptor,
                readOnly: readOnly,
                description: "disk image \(path)"
            )
            try self.init(
                backing: backing,
                identity: identity,
                readOnly: readOnly,
                asyncIO: asyncIO,
                queueCount: requestedQueueCount,
                discard: discard,
                flushTelemetry: flushTelemetry,
                limits: limits,
                ioOperations: ioOperations,
                rangeOperations: rangeOperations
            )
        } catch {
            close(descriptor)
            throw error
        }
    }

    /// Creates a block backend from an already-open regular-file descriptor. The descriptor is
    /// duplicated with close-on-exec, so the caller retains ownership of the original descriptor.
    /// This is the seam a future broker can use to hand an authorized image descriptor to the VMM
    /// without making the VMM resolve a path itself.
    public convenience init(
        fileDescriptor: Int32,
        identity: String,
        readOnly: Bool = false,
        queueCount requestedQueueCount: Int? = nil,
        discard: Bool? = nil
    ) throws {
        try self.init(
            fileDescriptor: fileDescriptor,
            identity: identity,
            readOnly: readOnly,
            asyncIO: true,
            queueCount: requestedQueueCount,
            discard: discard,
            flushTelemetry: .production
        )
    }

    convenience init(
        fileDescriptor: Int32,
        identity: String,
        readOnly: Bool = false,
        asyncIO: Bool,
        queueCount requestedQueueCount: Int? = nil,
        discard: Bool? = nil
    ) throws {
        try self.init(
            fileDescriptor: fileDescriptor,
            identity: identity,
            readOnly: readOnly,
            asyncIO: asyncIO,
            queueCount: requestedQueueCount,
            discard: discard,
            flushTelemetry: .production
        )
    }

    convenience init(
        fileDescriptor: Int32,
        identity: String,
        readOnly: Bool = false,
        asyncIO: Bool = true,
        queueCount requestedQueueCount: Int? = nil,
        discard: Bool? = nil,
        flushTelemetry: VirtioBlkFlushTelemetryConfiguration,
        limits: VirtioBlkLimits = .production,
        ioOperations: VirtioBlkIOOperations = .production,
        rangeOperations: VirtioBlkRangeOperations = .production
    ) throws {
        let descriptor = fcntl(fileDescriptor, F_DUPFD_CLOEXEC, 0)
        guard descriptor >= 0 else {
            throw VMError.invalidConfiguration("cannot duplicate disk image descriptor: errno \(errno)")
        }
        do {
            let backing = try Self.inspectOwnedDescriptor(
                descriptor,
                readOnly: readOnly,
                description: "disk image descriptor"
            )
            try self.init(
                backing: backing,
                identity: identity,
                readOnly: readOnly,
                asyncIO: asyncIO,
                queueCount: requestedQueueCount,
                discard: discard,
                flushTelemetry: flushTelemetry,
                limits: limits,
                ioOperations: ioOperations,
                rangeOperations: rangeOperations
            )
        } catch {
            close(descriptor)
            throw error
        }
    }

    private init(
        backing: BackingFile,
        identity: String,
        readOnly: Bool,
        asyncIO: Bool,
        queueCount requestedQueueCount: Int?,
        discard: Bool?,
        flushTelemetry: VirtioBlkFlushTelemetryConfiguration,
        limits: VirtioBlkLimits,
        ioOperations: VirtioBlkIOOperations,
        rangeOperations: VirtioBlkRangeOperations
    ) throws {
        let resolvedQueueCount = requestedQueueCount ?? 1
        guard (1...16).contains(resolvedQueueCount) else {
            throw VMError.invalidConfiguration(
                "virtio-blk queue count must be resolved within 1...16"
            )
        }
        self.fileDescriptor = backing.descriptor
        self.capacitySectors = backing.capacitySectors
        self.capacityBytes = backing.capacityBytes
        self.identity = identity
        self.readOnly = readOnly
        self.asyncIO = asyncIO
        self.flushTelemetry = flushTelemetry
        // Discard/write-zeroes only make sense on a writable image; keep them off for read-only shares.
        self.discardEnabled = !readOnly && (discard ?? true)
        self.discardBlockSize = backing.discardBlockSize
        self.limits = limits
        self.ioOperations = ioOperations
        self.rangeOperations = rangeOperations
        self.queueCount = resolvedQueueCount
        self.ioQueues = (0..<self.queueCount).map { index in
            DispatchQueue(
                label: "dory-hv.virtioblk.io.\(index)",
                qos: RawHVSchedulingPolicy.blockIOWorkerDispatchQoS
            )
        }
        self.queueDrainStates = Array(repeating: QueueDrainState(), count: self.queueCount)
        for (index, queue) in ioQueues.enumerated() {
            queue.setSpecific(key: ioQueueKey, value: index)
        }
    }

    private static func inspectOwnedDescriptor(
        _ descriptor: Int32,
        readOnly: Bool,
        description: String
    ) throws -> BackingFile {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw VMError.invalidConfiguration("cannot stat \(description): errno \(errno)")
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw VMError.invalidConfiguration("\(description) is not a regular file")
        }
        guard info.st_size >= 0 else {
            throw VMError.invalidConfiguration("\(description) has an invalid size")
        }

        let descriptorFlags = fcntl(descriptor, F_GETFL)
        guard descriptorFlags >= 0 else {
            throw VMError.invalidConfiguration("cannot inspect \(description) access mode: errno \(errno)")
        }
        let accessMode = descriptorFlags & O_ACCMODE
        guard accessMode != O_WRONLY, readOnly || accessMode == O_RDWR else {
            throw VMError.invalidConfiguration("\(description) does not have the required access mode")
        }

        // Virtio-blk advertises capacity in complete 512-byte sectors. Freeze the addressable byte
        // capacity at construction so later requests cannot grow the image or reach a trailing
        // partial sector even if the path is replaced or the backing file is subsequently enlarged.
        let fileSize = UInt64(info.st_size)
        let capacitySectors = fileSize / 512
        let capacityBytes = capacitySectors * 512

        // F_PUNCHHOLE requires fs-block alignment; capture the backing filesystem's block size so
        // sub-block discard slivers can be zero-written instead of failing the whole request.
        var fsInfo = statfs()
        let blockSize = fstatfs(descriptor, &fsInfo) == 0 ? Int(fsInfo.f_bsize) : 4096
        return BackingFile(
            descriptor: descriptor,
            capacitySectors: capacitySectors,
            capacityBytes: capacityBytes,
            discardBlockSize: blockSize > 0 ? blockSize : 4096
        )
    }

    deinit {
        drainLock.withLock {
            drainIsTerminal = true
            deviceIsReady = false
            for index in queueDrainStates.indices {
                queueDrainStates[index].revoke(replacementTransportIdentity: nil)
            }
        }
        // Enqueued work captures the backend weakly. Join every other queue so no task can acquire
        // the backing descriptor after this point; an executing task retains self until its one
        // bounded turn has returned, so deinit can only run on that queue after its host I/O ends.
        let currentQueue = DispatchQueue.getSpecific(key: ioQueueKey)
        for (index, queue) in ioQueues.enumerated() where currentQueue != index {
            queue.sync {}
        }
        close(fileDescriptor)
    }

    public var configSpace: [UInt8] {
        var config = [UInt8]()
        withUnsafeBytes(of: capacitySectors.littleEndian) { config.append(contentsOf: $0) }  // capacity @0
        config.append(contentsOf: Array(repeating: 0, count: 26))                            // @8..33
        withUnsafeBytes(of: UInt16(queueCount).littleEndian) { config.append(contentsOf: $0) }  // num_queues @34
        guard discardEnabled else { return config }
        let maximumDiscardSegments = UInt32(limits.maximumDiscardSegmentsPerRequest)
        let maximumWriteZeroesSectors = UInt32(
            limits.maximumWriteZeroesBytesPerRequest
                / limits.maximumWriteZeroesSegmentsPerRequest / 512
        )
        let maximumWriteZeroesSegments = UInt32(
            limits.maximumWriteZeroesSegmentsPerRequest
        )
        withUnsafeBytes(of: Discard.maxSectors.littleEndian) { config.append(contentsOf: $0) }      // max_discard_sectors @36
        withUnsafeBytes(of: maximumDiscardSegments.littleEndian) { config.append(contentsOf: $0) }  // max_discard_seg @40
        withUnsafeBytes(of: Discard.sectorAlignment.littleEndian) { config.append(contentsOf: $0) } // discard_sector_alignment @44
        withUnsafeBytes(of: maximumWriteZeroesSectors.littleEndian) { config.append(contentsOf: $0) } // max_write_zeroes_sectors @48
        withUnsafeBytes(of: maximumWriteZeroesSegments.littleEndian) { config.append(contentsOf: $0) } // max_write_zeroes_seg @52
        config.append(1)                      // write_zeroes_may_unmap @56
        config.append(contentsOf: [0, 0, 0])  // unused @57..59
        return config
    }

    public func handleKick(queue: Int, transport: VirtioMMIOTransport) {
        guard (0..<queueCount).contains(queue),
              let epoch = beginDrain(queue: queue, transport: transport) else { return }
        if asyncIO {
            enqueueDrain(epoch, transport: transport)
        } else {
            let outcome = drainBatch(epoch: epoch, transport: transport)
            finishDrain(epoch, transport: transport, outcome: outcome, mayContinue: false)
        }
    }

    public func deviceReady(transport: VirtioMMIOTransport) {
        let identity = ObjectIdentifier(transport)
        drainLock.withLock {
            guard !drainIsTerminal else { return }
            deviceIsReady = true
            for index in queueDrainStates.indices {
                queueDrainStates[index].revoke(
                    replacementTransportIdentity: transport.queues[index].ready ? identity : nil
                )
            }
        }
    }

    public func deviceReset(transport: VirtioMMIOTransport) {
        let identity = ObjectIdentifier(transport)
        drainLock.withLock {
            guard !drainIsTerminal else { return }
            deviceIsReady = false
            for index in queueDrainStates.indices
            where queueDrainStates[index].transportIdentity == identity {
                queueDrainStates[index].revoke(replacementTransportIdentity: nil)
            }
        }
    }

    public func queueStateChanged(
        queue: Int,
        ready: Bool,
        transport: VirtioMMIOTransport
    ) {
        guard (0..<queueCount).contains(queue) else { return }
        let identity = ObjectIdentifier(transport)
        drainLock.withLock {
            guard !drainIsTerminal else { return }
            queueDrainStates[queue].revoke(
                replacementTransportIdentity: deviceIsReady && ready ? identity : nil
            )
        }
    }

    private func beginDrain(
        queue: Int,
        transport: VirtioMMIOTransport
    ) -> DrainEpoch? {
        let identity = ObjectIdentifier(transport)
        return drainLock.withLock {
            guard !drainIsTerminal,
                  deviceIsReady,
                  queueDrainStates[queue].transportIdentity == identity else { return nil }
            queueDrainStates[queue].kickPending = true
            guard queueDrainStates[queue].activeGeneration == nil else { return nil }
            queueDrainStates[queue].kickPending = false
            let generation = queueDrainStates[queue].generation
            queueDrainStates[queue].activeGeneration = generation
            return DrainEpoch(
                queue: queue,
                generation: generation,
                transportIdentity: identity
            )
        }
    }

    private func enqueueDrain(_ epoch: DrainEpoch, transport: VirtioMMIOTransport) {
        ioQueues[epoch.queue].async { [weak self, weak transport] in
            guard let self, let transport else { return }
            let outcome = self.drainBatch(epoch: epoch, transport: transport)
            self.finishDrain(
                epoch,
                transport: transport,
                outcome: outcome,
                mayContinue: true
            )
        }
    }

    private func finishDrain(
        _ epoch: DrainEpoch,
        transport: VirtioMMIOTransport,
        outcome: DrainBatchOutcome,
        mayContinue: Bool
    ) {
        let shouldContinue = drainLock.withLock { () -> Bool in
            guard isCurrentLocked(epoch) else { return false }
            let hasNewKick = queueDrainStates[epoch.queue].kickPending
            switch outcome {
            case .pending where mayContinue:
                queueDrainStates[epoch.queue].kickPending = false
                return true
            case .fault where mayContinue && hasNewKick:
                queueDrainStates[epoch.queue].kickPending = false
                return true
            case .drained where mayContinue && hasNewKick:
                queueDrainStates[epoch.queue].kickPending = false
                return true
            case .drained, .pending, .fault:
                queueDrainStates[epoch.queue].activeGeneration = nil
                return false
            case .stale:
                return false
            }
        }
        if shouldContinue { enqueueDrain(epoch, transport: transport) }
    }

    private func drainBatch(
        epoch: DrainEpoch,
        transport: VirtioMMIOTransport
    ) -> DrainBatchOutcome {
        guard isCurrent(epoch) else { return .stale }
        recordQueueWorkTurn()
        var interrupt = false
        var handled = 0
        var processedBytes = 0
        var processedRangeHostOperations = 0

        switch pendingDepth(epoch: epoch, transport: transport) {
        case let .depth(depth):
            observeQueueDepth(depth, epoch: epoch)
            if depth == 0 { return .drained }
        case .fault:
            recordQueuePopFault()
            return .fault
        case .stale:
            return .stale
        }

        while handled < limits.maximumChainsPerDrain,
              processedBytes < limits.maximumTransferBytesPerDrain,
              processedRangeHostOperations < limits.maximumRangeHostOperationsPerDrain {
            let chain: VirtqueueChain
            switch popNext(epoch: epoch, transport: transport) {
            case let .chain(next):
                chain = next
            case .empty:
                observeQueueDepth(0, epoch: epoch)
                notifyIfCurrent(interrupt, epoch: epoch, transport: transport)
                return .drained
            case .fault:
                recordQueuePopFault()
                notifyIfCurrent(interrupt, epoch: epoch, transport: transport)
                return .fault
            case .stale:
                return .stale
            }
            handled += 1

            let startedAt = ioOperations.monotonicNanoseconds()
            guard let execution = process(chain: chain, epoch: epoch) else {
                recordRevokedRequest()
                return .stale
            }
            let (nextProcessedBytes, byteCountOverflow) = processedBytes.addingReportingOverflow(
                execution.workBytes
            )
            processedBytes = byteCountOverflow ? Int.max : nextProcessedBytes
            let (nextRangeOperations, rangeOperationOverflow) =
                processedRangeHostOperations.addingReportingOverflow(
                    execution.rangeHostOperations
                )
            processedRangeHostOperations = rangeOperationOverflow
                ? Int.max : nextRangeOperations
            switch pushCompletion(
                chain,
                written: execution.written,
                epoch: epoch,
                transport: transport
            ) {
            case let .published(wantsInterrupt):
                interrupt = wantsInterrupt || interrupt
                recordRequestCompletion(startedAt: startedAt)
            case .stale:
                recordRevokedRequest()
                return .stale
            case .fault:
                // Host I/O may already have committed. Surface the failed publication as an exact
                // outcome-unknown boundary instead of converting it into an empty queue.
                recordCompletionFault()
                notifyIfCurrent(interrupt, epoch: epoch, transport: transport)
                return .fault
            }
        }

        switch pendingDepth(epoch: epoch, transport: transport) {
        case let .depth(depth) where depth > 0:
            observeQueueDepth(depth, epoch: epoch)
            recordBoundedDrainStop()
            if processedRangeHostOperations >= limits.maximumRangeHostOperationsPerDrain {
                recordRangeTurnBudgetStop()
            }
            notifyIfCurrent(interrupt, epoch: epoch, transport: transport)
            return .pending
        case .depth:
            observeQueueDepth(0, epoch: epoch)
            notifyIfCurrent(interrupt, epoch: epoch, transport: transport)
            return .drained
        case .fault:
            recordQueuePopFault()
            notifyIfCurrent(interrupt, epoch: epoch, transport: transport)
            return .fault
        case .stale:
            return .stale
        }
    }

    private func popNext(
        epoch: DrainEpoch,
        transport: VirtioMMIOTransport
    ) -> QueuePopOutcome {
        transport.withQueueLock {
            guard isCurrent(epoch) else { return .stale }
            do {
                return try transport.queues[epoch.queue].pop().map(QueuePopOutcome.chain) ?? .empty
            } catch {
                return .fault
            }
        }
    }

    private func pendingDepth(
        epoch: DrainEpoch,
        transport: VirtioMMIOTransport
    ) -> QueueDepthOutcome {
        transport.withQueueLock {
            guard isCurrent(epoch) else { return .stale }
            do {
                return .depth(Int(try transport.queues[epoch.queue].pendingCount()))
            } catch {
                return .fault
            }
        }
    }

    private func pushCompletion(
        _ chain: VirtqueueChain,
        written: Int,
        epoch: DrainEpoch,
        transport: VirtioMMIOTransport
    ) -> QueuePushOutcome {
        transport.withQueueLock {
            guard isCurrent(epoch) else { return .stale }
            do {
                switch try transport.queues[epoch.queue].pushOutcome(chain, written: written) {
                case let .published(wantsInterrupt):
                    return .published(wantsInterrupt: wantsInterrupt)
                case .revoked:
                    return isCurrent(epoch) ? .fault : .stale
                }
            } catch {
                return isCurrent(epoch) ? .fault : .stale
            }
        }
    }

    private func process(
        chain: VirtqueueChain,
        epoch: DrainEpoch
    ) -> RequestExecution? {
        // Disk I/O may outlive the queue kick. Hold the chain lease for every direct guest-pointer
        // read/write so reset or QueueReady reconfiguration cannot let the guest repurpose the
        // buffer until the host operation and status byte are complete. Admission orders the
        // lifecycle lock before the lease: a reset either revokes this work first or waits for the
        // one already-admitted bounded request, never allowing post-reset I/O to begin.
        drainLock.lock()
        guard isCurrentLocked(epoch) else {
            drainLock.unlock()
            return nil
        }
        var enteredLease = false
        let execution = chain.withLeaseHeld { access in
            enteredLease = true
            drainLock.unlock()
            return process(
                segments: access.segments,
                containsZeroLengthDescriptor: chain.containsZeroLengthDescriptor
            )
        }
        if !enteredLease { drainLock.unlock() }
        return execution
    }

    private func isCurrent(_ epoch: DrainEpoch) -> Bool {
        drainLock.withLock { isCurrentLocked(epoch) }
    }

    private func isCurrentLocked(_ epoch: DrainEpoch) -> Bool {
        !drainIsTerminal
            && deviceIsReady
            && queueDrainStates.indices.contains(epoch.queue)
            && queueDrainStates[epoch.queue].generation == epoch.generation
            && queueDrainStates[epoch.queue].activeGeneration == epoch.generation
            && queueDrainStates[epoch.queue].transportIdentity == epoch.transportIdentity
    }

    private func observeQueueDepth(_ depth: Int, epoch: DrainEpoch) {
        drainLock.withLock {
            guard isCurrentLocked(epoch) else { return }
            queueDrainStates[epoch.queue].queueDepth = max(0, depth)
            let aggregate = queueDrainStates.reduce(0) { partial, state in
                let (next, overflow) = partial.addingReportingOverflow(state.queueDepth)
                return overflow ? Int.max : next
            }
            queueDepthHighWatermark = max(queueDepthHighWatermark, aggregate)
        }
    }

    private func notifyIfCurrent(
        _ wantsInterrupt: Bool,
        epoch: DrainEpoch,
        transport: VirtioMMIOTransport
    ) {
        if wantsInterrupt, isCurrent(epoch) { transport.notifyUsed() }
    }

    private func process(
        segments: [VirtqueueSegment],
        containsZeroLengthDescriptor: Bool
    ) -> RequestExecution {
        guard segments.count >= 2,
              !segments[0].isDeviceWritable, segments[0].length == 16,
              let statusSegment = segments.last, statusSegment.isDeviceWritable, statusSegment.length >= 1 else {
            recordInvalidRequest()
            return RequestExecution(written: 0, workBytes: 0)
        }

        guard !containsZeroLengthDescriptor else {
            statusSegment.pointer.storeBytes(of: RequestStatus.ioError.rawValue, as: UInt8.self)
            recordInvalidRequest()
            return RequestExecution(written: 1, workBytes: 0)
        }

        let header = segments[0].pointer
        let rawType = header.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
        let sector = UInt64(littleEndian: header.loadUnaligned(fromByteOffset: 8, as: UInt64.self))
        let dataSegments = segments[1..<(segments.count - 1)]
        var workBytes = dataSegments.reduce(into: 0) { total, segment in
            let (next, overflow) = total.addingReportingOverflow(segment.length)
            total = overflow ? Int.max : next
        }
        var rangeHostOperations = 0

        var written = 0
        let status: RequestStatus
        switch RequestType(rawValue: UInt32(littleEndian: rawType)) {
        case .read:
            status = withTransferPermit {
                transfer(dataSegments, from: sector, into: &written, reading: true)
            }
        case .write:
            status = readOnly ? .ioError : withTransferPermit {
                transfer(dataSegments, from: sector, into: &written, reading: false)
            }
        case .discard:
            if readOnly {
                status = .ioError
            } else {
                let execution = withTransferPermit {
                    executeDiscardOrWriteZeroes(dataSegments, writeZeroes: false)
                }
                status = execution.status
                workBytes = max(workBytes, execution.fairnessBytes)
                rangeHostOperations = execution.hostOperations
            }
        case .writeZeroes:
            if readOnly {
                status = .ioError
            } else {
                let execution = withTransferPermit {
                    executeDiscardOrWriteZeroes(dataSegments, writeZeroes: true)
                }
                status = execution.status
                workBytes = max(workBytes, execution.fairnessBytes)
                rangeHostOperations = execution.hostOperations
            }
        case .flush:
            // VIRTIO_BLK_T_FLUSH has no data payload. Reject malformed chains instead of silently
            // treating guest-provided buffers as part of a valid durability operation.
            if dataSegments.isEmpty {
                status = flush()
            } else {
                recordInvalidRequest()
                status = .ioError
            }
        case .getID:
            written = writeIdentity(into: dataSegments)
            if written == 20 {
                status = .ok
            } else {
                recordInvalidRequest()
                status = .ioError
            }
        case nil:
            status = .unsupported
        }

        statusSegment.pointer.storeBytes(of: status.rawValue, as: UInt8.self)
        return RequestExecution(
            written: written + 1,
            workBytes: workBytes,
            rangeHostOperations: rangeHostOperations
        )
    }

    private func writeIdentity(into segments: ArraySlice<VirtqueueSegment>) -> Int {
        let identityByteCount = 20
        guard !segments.isEmpty,
              segments.allSatisfy({ $0.isDeviceWritable && $0.length > 0 }) else { return 0 }
        var capacity = 0
        for segment in segments {
            let (next, overflow) = capacity.addingReportingOverflow(segment.length)
            guard !overflow else { return 0 }
            capacity = next
        }
        guard capacity >= identityByteCount else { return 0 }

        var encoded = [UInt8](repeating: 0, count: identityByteCount)
        let source = Array(identity.utf8.prefix(identityByteCount))
        encoded.replaceSubrange(0..<source.count, with: source)
        var sourceOffset = 0
        for segment in segments where sourceOffset < identityByteCount {
            let count = min(segment.length, identityByteCount - sourceOffset)
            encoded[sourceOffset..<(sourceOffset + count)].withUnsafeBytes { bytes in
                segment.pointer.copyMemory(from: bytes.baseAddress!, byteCount: count)
            }
            sourceOffset += count
        }
        return sourceOffset
    }

    private func withTransferPermit<Result>(_ body: () -> Result) -> Result {
        requestCondition.lock()
        while flushActive {
            requestCondition.wait()
        }
        inFlightTransfers += 1
        maximumInFlightTransferCount = max(maximumInFlightTransferCount, inFlightTransfers)
        requestCondition.unlock()

        let result = body()

        requestCondition.lock()
        inFlightTransfers -= 1
        requestCondition.broadcast()
        requestCondition.unlock()
        return result
    }

    func flush() -> RequestStatus {
        requestCondition.lock()
        while flushActive {
            requestCondition.wait()
        }
        flushActive = true
        while inFlightTransfers > 0 {
            requestCondition.wait()
        }
        requestCondition.unlock()

        let startedAt = flushTelemetry.monotonicNanoseconds()
        let status: RequestStatus = flushTelemetry.synchronize(fileDescriptor) == 0 ? .ok : .ioError
        let finishedAt = flushTelemetry.monotonicNanoseconds()
        let duration = finishedAt >= startedAt ? finishedAt - startedAt : 0
        statisticsLock.withLock {
            if flushCount < UInt64.max {
                flushCount += 1
            }
            maximumFlushLatencyNanoseconds = max(maximumFlushLatencyNanoseconds, duration)
            if duration >= flushTelemetry.slowThresholdNanoseconds, slowFlushCount < UInt64.max {
                slowFlushCount += 1
            }
        }

        requestCondition.lock()
        flushActive = false
        requestCondition.broadcast()
        requestCondition.unlock()
        return status
    }

    public var statistics: VirtioBlkStatistics {
        let queueGauges = drainLock.withLock {
            (
                depth: queueDrainStates.reduce(0) { $0 + $1.queueDepth },
                highWatermark: queueDepthHighWatermark
            )
        }
        let transferGauges: (current: Int, maximum: Int) = {
            requestCondition.lock()
            defer { requestCondition.unlock() }
            return (inFlightTransfers, maximumInFlightTransferCount)
        }()
        return statisticsLock.withLock {
            VirtioBlkStatistics(
                flushes: flushCount,
                maximumFlushLatencyNanoseconds: maximumFlushLatencyNanoseconds,
                slowFlushes: slowFlushCount,
                invalidRequests: invalidRequestCount,
                queuePopFaults: queuePopFaultCount,
                completionFaults: completionFaultCount,
                boundedDrainStops: boundedDrainStopCount,
                queueWorkTurns: queueWorkTurnCount,
                queueDepth: UInt64(queueGauges.depth),
                queueHighWatermark: UInt64(queueGauges.highWatermark),
                requestCompletions: requestCompletionCount,
                revokedRequests: revokedRequestCount,
                requestServiceLatencyNanoseconds: requestServiceLatencyNanoseconds,
                maximumRequestServiceLatencyNanoseconds:
                    maximumRequestServiceLatencyNanoseconds,
                readRequests: readRequestCount,
                writeRequests: writeRequestCount,
                readBytes: readByteCount,
                writeBytes: writeByteCount,
                readSystemCalls: readSystemCallCount,
                writeSystemCalls: writeSystemCallCount,
                partialIOSystemCalls: partialIOSystemCallCount,
                interruptedIOSystemCalls: interruptedIOSystemCallCount,
                failedIOSystemCalls: failedIOSystemCallCount,
                hostIOBudgetExhaustions: hostIOBudgetExhaustionCount,
                transferSegments: transferSegmentCount,
                inFlightTransfers: UInt64(transferGauges.current),
                maximumInFlightTransfers: UInt64(transferGauges.maximum),
                discardRequests: discardRequestCount,
                discardRequestedBytes: discardRequestedByteCount,
                discardHostOperations: discardHostOperationCount,
                discardIgnoredRanges: discardIgnoredRangeCount,
                writeZeroesRequests: writeZeroesRequestCount,
                writeZeroesRequestedBytes: writeZeroesRequestedByteCount,
                writeZeroesHostWrittenBytes: writeZeroesHostWrittenByteCount,
                writeZeroesHostOperations: writeZeroesHostOperationCount,
                rangePartialHostOperations: rangePartialHostOperationCount,
                rangeInterruptedHostOperations: rangeInterruptedHostOperationCount,
                rangeFailedHostOperations: rangeFailedHostOperationCount,
                rangeHostOperationBudgetExhaustions:
                    rangeHostOperationBudgetExhaustionCount,
                rangeSegments: rangeSegmentCount,
                rangeTurnBudgetStops: rangeTurnBudgetStopCount
            )
        }
    }

    private func recordQueuePopFault() {
        statisticsLock.withLock { queuePopFaultCount &+= 1 }
    }

    private func recordInvalidRequest() {
        statisticsLock.withLock { invalidRequestCount &+= 1 }
    }

    private func recordCompletionFault() {
        statisticsLock.withLock { completionFaultCount &+= 1 }
    }

    private func recordBoundedDrainStop() {
        statisticsLock.withLock { boundedDrainStopCount &+= 1 }
    }

    private func recordRangeTurnBudgetStop() {
        statisticsLock.withLock { rangeTurnBudgetStopCount &+= 1 }
    }

    private func recordQueueWorkTurn() {
        statisticsLock.withLock { queueWorkTurnCount &+= 1 }
    }

    private func recordRevokedRequest() {
        statisticsLock.withLock { revokedRequestCount &+= 1 }
    }

    private func recordRequestCompletion(startedAt: UInt64) {
        let finishedAt = ioOperations.monotonicNanoseconds()
        let duration = finishedAt >= startedAt ? finishedAt - startedAt : 0
        statisticsLock.withLock {
            requestCompletionCount &+= 1
            requestServiceLatencyNanoseconds &+= duration
            maximumRequestServiceLatencyNanoseconds = max(
                maximumRequestServiceLatencyNanoseconds,
                duration
            )
        }
    }

    private func recordHostTransfer(
        reading: Bool,
        segments: Int,
        receipt: HostTransferReceipt
    ) {
        statisticsLock.withLock {
            if reading {
                readRequestCount &+= 1
                readByteCount &+= UInt64(receipt.actualBytes)
                readSystemCallCount &+= UInt64(receipt.systemCalls)
            } else {
                writeRequestCount &+= 1
                writeByteCount &+= UInt64(receipt.actualBytes)
                writeSystemCallCount &+= UInt64(receipt.systemCalls)
            }
            partialIOSystemCallCount &+= UInt64(receipt.partialSystemCalls)
            interruptedIOSystemCallCount &+= UInt64(receipt.interruptedSystemCalls)
            failedIOSystemCallCount &+= UInt64(receipt.failedSystemCalls)
            hostIOBudgetExhaustionCount &+= UInt64(receipt.budgetExhaustions)
            transferSegmentCount &+= UInt64(segments)
        }
    }

    private func recordRangeCommand(
        writeZeroes: Bool,
        execution: RangeCommandExecution
    ) {
        statisticsLock.withLock {
            if writeZeroes {
                writeZeroesRequestCount &+= 1
                writeZeroesRequestedByteCount &+= execution.requestedBytes
                writeZeroesHostWrittenByteCount &+= UInt64(execution.hostWrittenBytes)
                writeZeroesHostOperationCount &+= UInt64(execution.hostOperations)
            } else {
                discardRequestCount &+= 1
                discardRequestedByteCount &+= execution.requestedBytes
                discardHostOperationCount &+= UInt64(execution.hostOperations)
                discardIgnoredRangeCount &+= UInt64(execution.ignoredDiscardRanges)
            }
            rangePartialHostOperationCount &+= UInt64(execution.partialHostOperations)
            rangeInterruptedHostOperationCount &+= UInt64(execution.interruptedHostOperations)
            rangeFailedHostOperationCount &+= UInt64(execution.failedHostOperations)
            rangeHostOperationBudgetExhaustionCount &+=
                UInt64(execution.hostOperationBudgetExhaustions)
            rangeSegmentCount &+= UInt64(execution.segmentCount)
        }
    }

    static func checkedByteRange(
        sector: UInt64,
        byteCount: UInt64,
        capacityBytes: UInt64
    ) -> ByteRange? {
        let (byteOffset, offsetOverflow) = sector.multipliedReportingOverflow(by: 512)
        guard !offsetOverflow,
              byteOffset <= capacityBytes,
              byteCount <= capacityBytes - byteOffset,
              byteOffset <= UInt64(off_t.max),
              byteCount <= UInt64(off_t.max) - byteOffset else {
            return nil
        }
        return ByteRange(offset: off_t(byteOffset), length: off_t(byteCount))
    }

    static func checkedSectorRange(
        sector: UInt64,
        sectorCount: UInt64,
        capacityBytes: UInt64
    ) -> ByteRange? {
        let (byteCount, lengthOverflow) = sectorCount.multipliedReportingOverflow(by: 512)
        guard !lengthOverflow else { return nil }
        return checkedByteRange(
            sector: sector,
            byteCount: byteCount,
            capacityBytes: capacityBytes
        )
    }

    func transfer(
        _ segments: ArraySlice<VirtqueueSegment>,
        from sector: UInt64,
        into written: inout Int,
        reading: Bool
    ) -> RequestStatus {
        // Validate direction and the complete aggregate range before the first syscall. This avoids
        // partially mutating a disk when a later descriptor is malformed or outside capacity.
        guard !segments.isEmpty else { return .ioError }
        var totalByteCount: UInt64 = 0
        for segment in segments {
            guard segment.length > 0,
                  segment.isDeviceWritable == reading else { return .ioError }
            let (nextByteCount, overflow) = totalByteCount.addingReportingOverflow(UInt64(segment.length))
            guard !overflow else { return .ioError }
            totalByteCount = nextByteCount
        }
        // Virtio block read/write payloads are expressed in complete 512-byte sectors.
        guard totalByteCount > 0,
              totalByteCount <= UInt64(limits.maximumTransferBytes),
              totalByteCount % 512 == 0,
              let range = Self.checkedByteRange(
                sector: sector,
                byteCount: totalByteCount,
                capacityBytes: capacityBytes
              ) else { return .ioError }

        // Copy only bounded iovec metadata. Guest payload bytes remain zero-copy and protected by
        // the surrounding queue lease for the exact duration of every vectored host operation.
        let transferSegments = Array(segments)
        let receipt = performVectoredTransfer(
            transferSegments,
            at: range.offset,
            reading: reading
        )
        if reading { written += receipt.actualBytes }
        recordHostTransfer(
            reading: reading,
            segments: transferSegments.count,
            receipt: receipt
        )
        return receipt.status
    }

    private func performVectoredTransfer(
        _ segments: [VirtqueueSegment],
        at initialOffset: off_t,
        reading: Bool
    ) -> HostTransferReceipt {
        var receipt = HostTransferReceipt(status: .ioError)
        var segmentIndex = 0
        var segmentOffset = 0
        var fileOffset = initialOffset
        let operation = reading ? ioOperations.read : ioOperations.write

        while segmentIndex < segments.count {
            guard receipt.systemCalls < limits.maximumHostIOOperationsPerRequest else {
                receipt.budgetExhaustions &+= 1
                return receipt
            }

            var vectors = [iovec]()
            vectors.reserveCapacity(limits.maximumIOVectorsPerSystemCall)
            var offeredBytes = 0
            var vectorIndex = segmentIndex
            var vectorOffset = segmentOffset
            while vectorIndex < segments.count,
                  vectors.count < limits.maximumIOVectorsPerSystemCall {
                let segment = segments[vectorIndex]
                let length = segment.length - vectorOffset
                vectors.append(iovec(
                    iov_base: segment.pointer + vectorOffset,
                    iov_len: length
                ))
                offeredBytes += length
                vectorIndex += 1
                vectorOffset = 0
            }

            let result = vectors.withUnsafeBufferPointer { buffer in
                operation(
                    fileDescriptor,
                    buffer.baseAddress!,
                    Int32(buffer.count),
                    fileOffset
                )
            }
            receipt.systemCalls &+= 1

            if result.count < 0, result.code == EINTR {
                receipt.interruptedSystemCalls &+= 1
                continue
            }
            guard result.count > 0, result.count <= offeredBytes else {
                receipt.failedSystemCalls &+= 1
                return receipt
            }
            if result.count < offeredBytes { receipt.partialSystemCalls &+= 1 }

            receipt.actualBytes += result.count
            fileOffset += off_t(result.count)
            var consumed = result.count
            while consumed > 0, segmentIndex < segments.count {
                let available = segments[segmentIndex].length - segmentOffset
                if consumed < available {
                    segmentOffset += consumed
                    consumed = 0
                } else {
                    consumed -= available
                    segmentIndex += 1
                    segmentOffset = 0
                }
            }
        }

        receipt.status = .ok
        return receipt
    }

    // Applies a guest DISCARD or WRITE_ZEROES request. The data segments carry a packed array of
    // `struct virtio_blk_discard_write_zeroes { le64 sector; le32 num_sectors; le32 flags; }`.
    // Every entry and aggregate bound is validated before the first host operation. DISCARD may be
    // ignored when the backing store cannot punch a hole, as permitted by virtio; WRITE_ZEROES must
    // still produce zeros and therefore falls back to bounded allocation-preserving pwritev calls.
    func applyDiscardOrWriteZeroes(
        _ segments: ArraySlice<VirtqueueSegment>,
        writeZeroes: Bool
    ) -> RequestStatus {
        executeDiscardOrWriteZeroes(segments, writeZeroes: writeZeroes).status
    }

    private func executeDiscardOrWriteZeroes(
        _ segments: ArraySlice<VirtqueueSegment>,
        writeZeroes: Bool
    ) -> RangeCommandExecution {
        var execution = RangeCommandExecution(status: .ioError)
        defer { recordRangeCommand(writeZeroes: writeZeroes, execution: execution) }
        guard discardEnabled else {
            execution.status = .unsupported
            return execution
        }

        let maximumSegments = writeZeroes
            ? limits.maximumWriteZeroesSegmentsPerRequest
            : limits.maximumDiscardSegmentsPerRequest
        let maximumSectorsPerSegment = writeZeroes
            ? UInt64(
                limits.maximumWriteZeroesBytesPerRequest
                    / limits.maximumWriteZeroesSegmentsPerRequest / 512
            )
            : UInt64(Discard.maxSectors)
        var entryCount = 0
        var requestedBytes: UInt64 = 0
        var operations = [DiscardOperation]()
        operations.reserveCapacity(maximumSegments)

        for segment in segments {
            guard !segment.isDeviceWritable,
                  segment.length >= Discard.entryByteCount,
                  segment.length % Discard.entryByteCount == 0 else {
                return execution
            }
            let segmentEntries = segment.length / Discard.entryByteCount
            guard segmentEntries <= maximumSegments - entryCount else { return execution }
            entryCount += segmentEntries
            var validationOffset = 0
            while validationOffset + Discard.entryByteCount <= segment.length {
                let base = segment.pointer + validationOffset
                let sector = UInt64(littleEndian: base.loadUnaligned(
                    fromByteOffset: 0,
                    as: UInt64.self
                ))
                let numSectors = UInt64(UInt32(littleEndian: base.loadUnaligned(
                    fromByteOffset: 8,
                    as: UInt32.self
                )))
                let flags = UInt32(littleEndian: base.loadUnaligned(
                    fromByteOffset: 12,
                    as: UInt32.self
                ))
                validationOffset += Discard.entryByteCount
                guard numSectors <= maximumSectorsPerSegment else { return execution }
                if writeZeroes {
                    guard flags & ~Discard.unmapFlag == 0 else {
                        execution.status = .unsupported
                        return execution
                    }
                } else {
                    guard flags == 0 else {
                        execution.status = .unsupported
                        return execution
                    }
                }
                guard let range = Self.checkedSectorRange(
                    sector: sector,
                    sectorCount: numSectors,
                    capacityBytes: capacityBytes
                ) else { return execution }
                let rangeBytes = UInt64(range.length)
                let (nextRequestedBytes, overflow) = requestedBytes.addingReportingOverflow(
                    rangeBytes
                )
                guard !overflow,
                      !writeZeroes
                        || nextRequestedBytes <= UInt64(
                            limits.maximumWriteZeroesBytesPerRequest
                        ) else { return execution }
                requestedBytes = nextRequestedBytes
                operations.append(DiscardOperation(
                    range: range,
                    deallocate: !writeZeroes || (flags & Discard.unmapFlag) != 0
                ))
            }
        }

        guard entryCount > 0 else { return execution }
        execution.requestedBytes = requestedBytes
        execution.segmentCount = entryCount
        if writeZeroes {
            execution.fairnessBytes = Int(requestedBytes)
        }

        for operation in operations where operation.range.length > 0 {
            guard execution.hostOperations < limits.maximumRangeHostOperationsPerRequest else {
                execution.hostOperationBudgetExhaustions &+= 1
                return execution
            }
            let succeeded: Bool
            if operation.deallocate {
                succeeded = deallocateRange(
                    offset: operation.range.offset,
                    length: operation.range.length,
                    zeroFallback: writeZeroes,
                    execution: &execution
                )
            } else {
                succeeded = writeZerosPreservingAllocation(
                    offset: operation.range.offset,
                    length: operation.range.length,
                    execution: &execution
                )
            }
            guard succeeded else { return execution }
        }
        execution.status = .ok
        return execution
    }

    // Deallocates the aligned interior. Plain DISCARD is allowed to become an observable no-op when
    // hole punching is unavailable. WRITE_ZEROES with UNMAP instead zero-writes the complete range
    // on punch failure, and always zero-writes unaligned edges after a successful punch.
    private func deallocateRange(
        offset: off_t,
        length: off_t,
        zeroFallback: Bool,
        execution: inout RangeCommandExecution
    ) -> Bool {
        let block = off_t(discardBlockSize)
        let end = offset + length
        let startRemainder = offset % block
        let startAdjustment = startRemainder == 0 ? 0 : block - startRemainder
        guard startAdjustment < length else {
            if zeroFallback {
                return writeZerosPreservingAllocation(
                    offset: offset,
                    length: length,
                    execution: &execution
                )
            }
            execution.ignoredDiscardRanges &+= 1
            return true
        }
        let alignedStart = offset + startAdjustment
        let alignedEnd = end - (end % block)
        guard alignedEnd > alignedStart else {
            if zeroFallback {
                return writeZerosPreservingAllocation(
                    offset: offset,
                    length: length,
                    execution: &execution
                )
            }
            execution.ignoredDiscardRanges &+= 1
            return true
        }
        guard execution.hostOperations < limits.maximumRangeHostOperationsPerRequest else {
            execution.hostOperationBudgetExhaustions &+= 1
            return false
        }
        let punch = rangeOperations.punchHole(
            fileDescriptor,
            alignedStart,
            alignedEnd - alignedStart
        )
        execution.hostOperations &+= 1
        guard punch.count == 0 else {
            execution.failedHostOperations &+= 1
            if zeroFallback {
                return writeZerosPreservingAllocation(
                    offset: offset,
                    length: length,
                    execution: &execution
                )
            }
            execution.ignoredDiscardRanges &+= 1
            return true
        }
        if zeroFallback, alignedStart > offset,
           !writeZerosPreservingAllocation(
                offset: offset,
                length: alignedStart - offset,
                execution: &execution
           ) {
            return false
        }
        if zeroFallback, end > alignedEnd,
           !writeZerosPreservingAllocation(
                offset: alignedEnd,
                length: end - alignedEnd,
                execution: &execution
           ) {
            return false
        }
        return true
    }

    // Writes zeros through repeated references to one bounded 64 KiB buffer. A normal 16 MiB
    // request is one 256-iovec pwritev; short results rebuild the exact remaining file range.
    private func writeZerosPreservingAllocation(
        offset: off_t,
        length: off_t,
        execution: inout RangeCommandExecution
    ) -> Bool {
        let remainingBudget = max(
            0,
            limits.maximumRangeHostOperationsPerRequest - execution.hostOperations
        )
        let receipt = performZeroWrite(
            offset: offset,
            length: length,
            maximumHostOperations: remainingBudget
        )
        execution.mergeHostTransfer(receipt)
        return receipt.status == .ok
    }

    private func performZeroWrite(
        offset: off_t,
        length: off_t,
        maximumHostOperations: Int
    ) -> HostTransferReceipt {
        var receipt = HostTransferReceipt(status: .ioError)
        guard length > 0 else {
            receipt.status = .ok
            return receipt
        }
        let chunkSize = 64 * 1_024
        let zeros = [UInt8](repeating: 0, count: chunkSize)
        var remaining = length
        var position = offset
        return zeros.withUnsafeBytes { zeroBuffer in
            while remaining > 0 {
                guard receipt.systemCalls < maximumHostOperations else {
                    receipt.budgetExhaustions &+= 1
                    return receipt
                }

                var vectors = [iovec]()
                vectors.reserveCapacity(limits.maximumIOVectorsPerSystemCall)
                var offeredBytes = 0
                var vectorRemaining = remaining
                while vectorRemaining > 0,
                      vectors.count < limits.maximumIOVectorsPerSystemCall {
                    let count = Int(min(off_t(chunkSize), vectorRemaining))
                    vectors.append(iovec(
                        iov_base: UnsafeMutableRawPointer(
                            mutating: zeroBuffer.baseAddress!
                        ),
                        iov_len: count
                    ))
                    offeredBytes += count
                    vectorRemaining -= off_t(count)
                }

                let result = vectors.withUnsafeBufferPointer { buffer in
                    ioOperations.write(
                        fileDescriptor,
                        buffer.baseAddress!,
                        Int32(buffer.count),
                        position
                    )
                }
                receipt.systemCalls &+= 1
                if result.count < 0, result.code == EINTR {
                    receipt.interruptedSystemCalls &+= 1
                    continue
                }
                guard result.count > 0, result.count <= offeredBytes else {
                    receipt.failedSystemCalls &+= 1
                    return receipt
                }
                if result.count < offeredBytes {
                    receipt.partialSystemCalls &+= 1
                }
                receipt.actualBytes &+= result.count
                remaining -= off_t(result.count)
                position += off_t(result.count)
            }
            receipt.status = .ok
            return receipt
        }
    }

}

extension VirtioBlk: @unchecked Sendable {}
