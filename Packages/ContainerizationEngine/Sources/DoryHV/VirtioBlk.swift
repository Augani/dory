import Darwin
import Foundation

public struct VirtioBlkStatistics: Equatable, Sendable {
    public var flushes: UInt64
    public var maximumFlushLatencyNanoseconds: UInt64
    public var slowFlushes: UInt64

    public init(
        flushes: UInt64,
        maximumFlushLatencyNanoseconds: UInt64,
        slowFlushes: UInt64
    ) {
        self.flushes = flushes
        self.maximumFlushLatencyNanoseconds = maximumFlushLatencyNanoseconds
        self.slowFlushes = slowFlushes
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

/// virtio-blk backed by a raw disk image. Requests use zero-copy pread/pwrite straight into guest
/// RAM; disk I/O is drained on dedicated ordered workers so the kicking vCPU is not parked inside
/// host file syscalls during metadata-heavy workloads. The device exposes a small multiqueue setup
/// by default; set `DORY_BLK_QUEUES=1` to force the legacy single-queue shape.
public final class VirtioBlk: VirtioDeviceBackend {
    public let deviceID: UInt32 = 2
    public let queueCount: Int
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
    private let identity: String
    private let readOnly: Bool
    private let asyncIO: Bool
    private let discardEnabled: Bool
    private let discardBlockSize: Int
    private let ioQueues: [DispatchQueue]
    private let drainLock = NSLock()
    private var activeDrainers: [Bool]
    private var kickGenerations: [UInt64]
    private let requestCondition = NSCondition()
    private var inFlightTransfers = 0
    private var flushActive = false
    private let flushTelemetry: VirtioBlkFlushTelemetryConfiguration
    private let statisticsLock = NSLock()
    private var flushCount: UInt64 = 0
    private var maximumFlushLatencyNanoseconds: UInt64 = 0
    private var slowFlushCount: UInt64 = 0

    private enum Feature {
        static let readOnly: UInt64 = 1 << 5     // VIRTIO_BLK_F_RO
        static let flush: UInt64 = 1 << 9        // VIRTIO_BLK_F_FLUSH
        static let multiqueue: UInt64 = 1 << 12  // VIRTIO_BLK_F_MQ
        static let discard: UInt64 = 1 << 13     // VIRTIO_BLK_F_DISCARD
        static let writeZeroes: UInt64 = 1 << 14 // VIRTIO_BLK_F_WRITE_ZEROES
    }

    // Per-segment discard/write-zeroes tunables surfaced in config space. Generous single-segment caps
    // (2 GiB) keep fstrim from fragmenting into many round trips; punch-hole handles any length.
    private enum Discard {
        static let maxSectors: UInt32 = 1 << 22  // 2 GiB / 512
        static let maxSegments: UInt32 = 256
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

    public convenience init(
        path: String,
        identity: String,
        readOnly: Bool = false,
        asyncIO: Bool? = nil,
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

    init(
        path: String,
        identity: String,
        readOnly: Bool = false,
        asyncIO: Bool? = nil,
        queueCount requestedQueueCount: Int? = nil,
        discard: Bool? = nil,
        flushTelemetry: VirtioBlkFlushTelemetryConfiguration
    ) throws {
        let descriptor = open(path, readOnly ? O_RDONLY : O_RDWR)
        guard descriptor >= 0 else {
            throw VMError.invalidConfiguration("cannot open disk image \(path): errno \(errno)")
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            close(descriptor)
            throw VMError.invalidConfiguration("cannot stat disk image \(path)")
        }
        self.fileDescriptor = descriptor
        self.capacitySectors = UInt64(info.st_size) / 512
        self.identity = identity
        self.readOnly = readOnly
        self.asyncIO = asyncIO ?? Self.asyncIOEnabledFromEnvironment()
        self.flushTelemetry = flushTelemetry
        // Discard/write-zeroes only make sense on a writable image; keep them off for read-only shares.
        self.discardEnabled = !readOnly && (discard ?? Self.discardEnabledFromEnvironment())
        // F_PUNCHHOLE requires fs-block alignment; capture the backing filesystem's block size so
        // sub-block discard slivers can be zero-written instead of failing the whole request.
        var fsInfo = statfs()
        let blockSize = fstatfs(descriptor, &fsInfo) == 0 ? Int(fsInfo.f_bsize) : 4096
        self.discardBlockSize = blockSize > 0 ? blockSize : 4096
        self.queueCount = Self.clampedQueueCount(requestedQueueCount ?? Self.queueCountFromEnvironment())
        self.ioQueues = (0..<self.queueCount).map { index in
            DispatchQueue(label: "dory-hv.virtioblk.io.\(index)", qos: .userInteractive)
        }
        self.activeDrainers = Array(repeating: false, count: self.queueCount)
        self.kickGenerations = Array(repeating: 0, count: self.queueCount)
    }

    deinit {
        close(fileDescriptor)
    }

    public var configSpace: [UInt8] {
        var config = [UInt8]()
        withUnsafeBytes(of: capacitySectors.littleEndian) { config.append(contentsOf: $0) }  // capacity @0
        config.append(contentsOf: Array(repeating: 0, count: 26))                            // @8..33
        withUnsafeBytes(of: UInt16(queueCount).littleEndian) { config.append(contentsOf: $0) }  // num_queues @34
        guard discardEnabled else { return config }
        withUnsafeBytes(of: Discard.maxSectors.littleEndian) { config.append(contentsOf: $0) }      // max_discard_sectors @36
        withUnsafeBytes(of: Discard.maxSegments.littleEndian) { config.append(contentsOf: $0) }     // max_discard_seg @40
        withUnsafeBytes(of: Discard.sectorAlignment.littleEndian) { config.append(contentsOf: $0) } // discard_sector_alignment @44
        withUnsafeBytes(of: Discard.maxSectors.littleEndian) { config.append(contentsOf: $0) }      // max_write_zeroes_sectors @48
        withUnsafeBytes(of: Discard.maxSegments.littleEndian) { config.append(contentsOf: $0) }     // max_write_zeroes_seg @52
        config.append(1)                      // write_zeroes_may_unmap @56
        config.append(contentsOf: [0, 0, 0])  // unused @57..59
        return config
    }

    public func handleKick(queue: Int, transport: VirtioMMIOTransport) {
        guard queue >= 0, queue < queueCount else { return }
        guard asyncIO else {
            drainInline(queue: queue, transport: transport)
            return
        }
        let shouldStart: Bool = drainLock.withLock {
            kickGenerations[queue] &+= 1
            guard !activeDrainers[queue] else { return false }
            activeDrainers[queue] = true
            return true
        }
        guard shouldStart else { return }
        ioQueues[queue].async { [self] in drain(queue: queue, transport: transport) }
    }

    private func drainInline(queue: Int, transport: VirtioMMIOTransport) {
        let virtqueue = transport.queues[queue]
        var interrupt = false
        while let chain = (transport.withQueueLock { (try? virtqueue.pop()) ?? nil }) {
            let written = process(chain: chain)
            let wants = transport.withQueueLock { (try? virtqueue.push(chain, written: written)) ?? false }
            interrupt = interrupt || wants
        }
        if interrupt {
            transport.notifyUsed()
        }
    }

    private func drain(queue: Int, transport: VirtioMMIOTransport) {
        let virtqueue = transport.queues[queue]
        while true {
            let generation = drainLock.withLock { kickGenerations[queue] }
            var interrupt = false
            while let chain = (transport.withQueueLock { (try? virtqueue.pop()) ?? nil }) {
                let written = process(chain: chain)
                let wants = transport.withQueueLock { (try? virtqueue.push(chain, written: written)) ?? false }
                interrupt = interrupt || wants
            }
            if interrupt {
                transport.notifyUsed()
            }
            let exit = drainLock.withLock {
                guard kickGenerations[queue] == generation else { return false }
                activeDrainers[queue] = false
                return true
            }
            if exit { break }
        }
    }

    private func process(chain: VirtqueueChain) -> Int {
        let segments = chain.segments
        guard segments.count >= 2,
              !segments[0].isDeviceWritable, segments[0].length >= 16,
              let statusSegment = segments.last, statusSegment.isDeviceWritable, statusSegment.length >= 1 else {
            return 0
        }

        let header = segments[0].pointer
        let rawType = header.loadUnaligned(fromByteOffset: 0, as: UInt32.self)
        let sector = header.loadUnaligned(fromByteOffset: 8, as: UInt64.self)
        let dataSegments = segments[1..<(segments.count - 1)]

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
            status = readOnly ? .ioError : withTransferPermit {
                applyDiscardOrWriteZeroes(dataSegments, writeZeroes: false)
            }
        case .writeZeroes:
            status = readOnly ? .ioError : withTransferPermit {
                applyDiscardOrWriteZeroes(dataSegments, writeZeroes: true)
            }
        case .flush:
            status = flush()
        case .getID:
            let id = [UInt8](identity.utf8.prefix(20))
            for segment in dataSegments where segment.isDeviceWritable {
                let count = min(segment.length, id.count)
                id.withUnsafeBytes { segment.pointer.copyMemory(from: $0.baseAddress!, byteCount: count) }
                written += count
                break
            }
            status = .ok
        case nil:
            status = .unsupported
        }

        statusSegment.pointer.storeBytes(of: status.rawValue, as: UInt8.self)
        return written + 1
    }

    private func withTransferPermit(_ body: () -> RequestStatus) -> RequestStatus {
        requestCondition.lock()
        while flushActive {
            requestCondition.wait()
        }
        inFlightTransfers += 1
        requestCondition.unlock()

        let status = body()

        requestCondition.lock()
        inFlightTransfers -= 1
        requestCondition.broadcast()
        requestCondition.unlock()
        return status
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
        statisticsLock.withLock {
            VirtioBlkStatistics(
                flushes: flushCount,
                maximumFlushLatencyNanoseconds: maximumFlushLatencyNanoseconds,
                slowFlushes: slowFlushCount
            )
        }
    }

    private func transfer(
        _ segments: ArraySlice<VirtqueueSegment>,
        from sector: UInt64,
        into written: inout Int,
        reading: Bool
    ) -> RequestStatus {
        var offset = off_t(UInt64(littleEndian: sector) * 512)
        for segment in segments {
            if reading {
                guard segment.isDeviceWritable else { return .ioError }
                var done = 0
                while done < segment.length {
                    let bytes = pread(fileDescriptor, segment.pointer + done, segment.length - done, offset + off_t(done))
                    guard bytes > 0 else { return .ioError }
                    done += bytes
                }
                written += segment.length
            } else {
                guard !segment.isDeviceWritable else { return .ioError }
                var done = 0
                while done < segment.length {
                    let bytes = pwrite(fileDescriptor, segment.pointer + done, segment.length - done, offset + off_t(done))
                    guard bytes > 0 else { return .ioError }
                    done += bytes
                }
            }
            offset += off_t(segment.length)
        }
        return .ok
    }

    // Applies a guest DISCARD or WRITE_ZEROES request. The data segments carry a packed array of
    // `struct virtio_blk_discard_write_zeroes { le64 sector; le32 num_sectors; le32 flags; }`. Discard
    // and unmap-flagged write-zeroes punch a hole (returning blocks to the host and reading back zeros);
    // plain write-zeroes overwrites with zeros while keeping the allocation. Ranges are bounds-checked
    // in sector space so a malformed guest request cannot touch bytes outside the image.
    func applyDiscardOrWriteZeroes(_ segments: ArraySlice<VirtqueueSegment>, writeZeroes: Bool) -> RequestStatus {
        guard discardEnabled else { return .unsupported }
        var entryCount = 0
        for segment in segments {
            guard !segment.isDeviceWritable,
                  segment.length >= Discard.entryByteCount,
                  segment.length % Discard.entryByteCount == 0 else { return .ioError }
            let segmentEntries = segment.length / Discard.entryByteCount
            guard segmentEntries <= Int(Discard.maxSegments) - entryCount else { return .ioError }
            entryCount += segmentEntries
            var validationOffset = 0
            while validationOffset + Discard.entryByteCount <= segment.length {
                let base = segment.pointer + validationOffset
                let sector = UInt64(littleEndian: base.loadUnaligned(fromByteOffset: 0, as: UInt64.self))
                let numSectors = UInt64(UInt32(littleEndian: base.loadUnaligned(fromByteOffset: 8, as: UInt32.self)))
                let flags = UInt32(littleEndian: base.loadUnaligned(fromByteOffset: 12, as: UInt32.self))
                validationOffset += Discard.entryByteCount
                guard numSectors <= UInt64(Discard.maxSectors) else { return .ioError }
                if writeZeroes {
                    guard flags & ~Discard.unmapFlag == 0 else { return .unsupported }
                } else {
                    guard flags == 0 else { return .unsupported }
                }
                guard sector <= capacitySectors,
                      numSectors <= capacitySectors - sector else { return .ioError }
            }
        }
        guard entryCount > 0 else { return .ioError }
        for segment in segments {
            var offset = 0
            while offset + Discard.entryByteCount <= segment.length {
                let base = segment.pointer + offset
                let sector = UInt64(littleEndian: base.loadUnaligned(fromByteOffset: 0, as: UInt64.self))
                let numSectors = UInt64(UInt32(littleEndian: base.loadUnaligned(fromByteOffset: 8, as: UInt32.self)))
                let flags = UInt32(littleEndian: base.loadUnaligned(fromByteOffset: 12, as: UInt32.self))
                offset += Discard.entryByteCount

                guard numSectors > 0 else { continue }

                let byteOffset = off_t(sector * 512)
                let byteLength = off_t(numSectors * 512)
                let deallocate = !writeZeroes || (flags & Discard.unmapFlag) != 0
                let ok = deallocate
                    ? deallocateRange(
                        offset: byteOffset,
                        length: byteLength,
                        zeroFallback: writeZeroes
                    )
                    : writeZerosPreservingAllocation(offset: byteOffset, length: byteLength)
                guard ok else { return .ioError }
            }
        }
        return .ok
    }

    // Deallocates a byte range so it reads back as zeros and returns blocks to the host. F_PUNCHHOLE
    // only accepts fs-block-aligned ranges, so this punches the aligned interior. WRITE_ZEROES must
    // still read back as zero and therefore zero-writes unsupported/unaligned pieces; plain DISCARD
    // may be ignored by the device and must never inflate a sparse image when hole punching is not
    // available (for example, an external exFAT/SMB-backed home directory).
    private func deallocateRange(offset: off_t, length: off_t, zeroFallback: Bool) -> Bool {
        let block = off_t(discardBlockSize)
        let end = offset + length
        let alignedStart = ((offset + block - 1) / block) * block
        let alignedEnd = (end / block) * block
        guard alignedEnd > alignedStart else {
            return zeroFallback ? writeZerosPreservingAllocation(offset: offset, length: length) : true
        }
        var punch = fpunchhole_t(fp_flags: 0, reserved: 0, fp_offset: alignedStart, fp_length: alignedEnd - alignedStart)
        let punched = withUnsafeMutablePointer(to: &punch) { fcntl(fileDescriptor, F_PUNCHHOLE, $0) }
        guard punched == 0 else {
            return zeroFallback ? writeZerosPreservingAllocation(offset: offset, length: length) : true
        }
        if zeroFallback, alignedStart > offset,
           !writeZerosPreservingAllocation(offset: offset, length: alignedStart - offset) {
            return false
        }
        if zeroFallback, end > alignedEnd,
           !writeZerosPreservingAllocation(offset: alignedEnd, length: end - alignedEnd) {
            return false
        }
        return true
    }

    private func writeZerosPreservingAllocation(offset: off_t, length: off_t) -> Bool {
        let chunkSize = 64 * 1024
        let zeros = [UInt8](repeating: 0, count: chunkSize)
        var remaining = Int(length)
        var position = offset
        return zeros.withUnsafeBytes { raw in
            while remaining > 0 {
                let take = min(chunkSize, remaining)
                let written = pwrite(fileDescriptor, raw.baseAddress, take, position)
                guard written > 0 else { return false }
                remaining -= written
                position += off_t(written)
            }
            return true
        }
    }

    private static func discardEnabledFromEnvironment() -> Bool {
        guard let value = ProcessInfo.processInfo.environment["DORY_BLK_DISCARD"]?.lowercased() else {
            return true
        }
        return !["0", "false", "no", "off"].contains(value)
    }

    private static func asyncIOEnabledFromEnvironment() -> Bool {
        guard let value = ProcessInfo.processInfo.environment["DORY_BLK_ASYNC"]?.lowercased() else {
            return true
        }
        return !["0", "false", "no", "off"].contains(value)
    }

    private static func queueCountFromEnvironment() -> Int {
        guard let value = ProcessInfo.processInfo.environment["DORY_BLK_QUEUES"].flatMap(Int.init) else {
            return min(4, max(1, ProcessInfo.processInfo.activeProcessorCount))
        }
        return value
    }

    private static func clampedQueueCount(_ count: Int) -> Int {
        min(16, max(1, count))
    }
}

extension VirtioBlk: @unchecked Sendable {}
