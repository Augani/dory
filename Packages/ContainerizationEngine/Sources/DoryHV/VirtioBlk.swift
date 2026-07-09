import Darwin
import Foundation

/// virtio-blk backed by a raw disk image. Requests use zero-copy pread/pwrite straight into guest
/// RAM; disk I/O is drained on dedicated ordered workers so the kicking vCPU is not parked inside
/// host file syscalls during metadata-heavy workloads. The device exposes a small multiqueue setup
/// by default; set `DORY_BLK_QUEUES=1` to force the legacy single-queue shape.
public final class VirtioBlk: VirtioDeviceBackend {
    public let deviceID: UInt32 = 2
    public let queueCount: Int
    public var deviceFeatures: UInt64 {
        var features = Self.Feature.flush
        if queueCount > 1 {
            features |= Self.Feature.multiqueue
        }
        return features
    }

    private let fileDescriptor: Int32
    private let capacitySectors: UInt64
    private let identity: String
    private let readOnly: Bool
    private let asyncIO: Bool
    private let ioQueues: [DispatchQueue]
    private let drainLock = NSLock()
    private var activeDrainers: [Bool]
    private var kickGenerations: [UInt64]
    private let requestCondition = NSCondition()
    private var inFlightTransfers = 0
    private var flushActive = false

    private enum Feature {
        static let flush: UInt64 = 1 << 9       // VIRTIO_BLK_F_FLUSH
        static let multiqueue: UInt64 = 1 << 12 // VIRTIO_BLK_F_MQ
    }

    private enum RequestType: UInt32 {
        case read = 0
        case write = 1
        case flush = 4
        case getID = 8
    }

    private enum RequestStatus: UInt8 {
        case ok = 0
        case ioError = 1
        case unsupported = 2
    }

    public init(
        path: String,
        identity: String,
        readOnly: Bool = false,
        asyncIO: Bool? = nil,
        queueCount requestedQueueCount: Int? = nil
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
        withUnsafeBytes(of: capacitySectors.littleEndian) { config.append(contentsOf: $0) }
        config.append(contentsOf: Array(repeating: 0, count: 26))
        withUnsafeBytes(of: UInt16(queueCount).littleEndian) { config.append(contentsOf: $0) }
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

    private func flush() -> RequestStatus {
        requestCondition.lock()
        while flushActive {
            requestCondition.wait()
        }
        flushActive = true
        while inFlightTransfers > 0 {
            requestCondition.wait()
        }
        requestCondition.unlock()

        let status: RequestStatus = fsync(fileDescriptor) == 0 ? .ok : .ioError

        requestCondition.lock()
        flushActive = false
        requestCondition.broadcast()
        requestCondition.unlock()
        return status
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
