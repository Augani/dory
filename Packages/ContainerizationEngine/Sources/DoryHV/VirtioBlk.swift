import Darwin
import Foundation

/// virtio-blk backed by a raw disk image. Requests are served synchronously on the kicking vCPU's
/// thread with zero-copy pread/pwrite straight into guest RAM.
public final class VirtioBlk: VirtioDeviceBackend {
    public let deviceID: UInt32 = 2
    public let queueCount = 1
    public var deviceFeatures: UInt64 { 1 << 9 }  // VIRTIO_BLK_F_FLUSH

    private let fileDescriptor: Int32
    private let capacitySectors: UInt64
    private let identity: String
    private let readOnly: Bool

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

    public init(path: String, identity: String, readOnly: Bool = false) throws {
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
    }

    deinit {
        close(fileDescriptor)
    }

    public var configSpace: [UInt8] {
        var config = [UInt8]()
        withUnsafeBytes(of: capacitySectors.littleEndian) { config.append(contentsOf: $0) }
        return config
    }

    public func handleKick(queue: Int, transport: VirtioMMIOTransport) {
        guard queue == 0 else { return }
        let virtqueue = transport.queues[0]
        var interrupt = false
        while let chain = (try? virtqueue.pop()) ?? nil {
            let written = process(chain: chain)
            let wants = (try? virtqueue.push(chain, written: written)) ?? false
            interrupt = interrupt || wants
        }
        if interrupt {
            transport.notifyUsed()
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
            status = transfer(dataSegments, from: sector, into: &written, reading: true)
        case .write:
            status = readOnly ? .ioError : transfer(dataSegments, from: sector, into: &written, reading: false)
        case .flush:
            status = fcntl(fileDescriptor, F_FULLFSYNC) == 0 ? .ok : .ioError
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
}
