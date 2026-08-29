import Darwin
import Foundation
import Testing
@testable import dory_hv

@Suite(.serialized)
struct BoundedSerialConsolePublisherTests {
    @Test func fixedRingRejectsOverflowAndPreservesFIFOAcrossWraparound() {
        var ring = BoundedSerialByteRing(capacity: 4)
        let accepted1 = ring.append(1)
        let accepted2 = ring.append(2)
        let accepted3 = ring.append(3)
        let accepted4 = ring.append(4)
        let rejected5 = ring.append(5)
        #expect(accepted1)
        #expect(accepted2)
        #expect(accepted3)
        #expect(accepted4)
        #expect(!rejected5)
        #expect(ring.count == 4)

        let firstRemoval = ring.removeFirst(maxCount: 2)
        #expect(firstRemoval == [1, 2])
        let accepted5 = ring.append(5)
        let accepted6 = ring.append(6)
        #expect(accepted5)
        #expect(accepted6)
        let secondRemoval = ring.removeFirst(maxCount: 8)
        #expect(secondRemoval == [3, 4, 5, 6])
        #expect(ring.isEmpty)
    }

    @Test func publisherBatchesInOrderFlushesAndSynchronizesAtStop() throws {
        let fixture = try TemporarySerialFile()
        defer { fixture.closeAndRemove() }
        let publisher = try BoundedSerialConsolePublisher(
            destinations: [
                .init(fileDescriptor: fixture.fileDescriptor, synchronizeOnStop: true),
            ],
            capacityBytes: 64 * 1_024,
            batchBytes: 4 * 1_024,
            coalescingInterval: 1
        )

        let prefix = (0..<20_000).map { UInt8(truncatingIfNeeded: $0) }
        for byte in prefix { #expect(publisher.enqueue(byte)) }
        let flushed = publisher.flush(timeout: 2)
        #expect(flushed.processedBytes == UInt64(prefix.count))
        #expect(flushed.pendingBytes == 0)
        #expect(flushed.overflowDroppedBytes == 0)
        #expect(flushed.writeFailureCount == 0)
        #expect(flushed.batches > 0)
        #expect(flushed.writeSystemCalls < flushed.acceptedBytes)

        let suffix = Array("\nserial-tail\n".utf8)
        for byte in suffix { #expect(publisher.enqueue(byte)) }
        let stopped = publisher.stop(timeout: 2)
        #expect(stopped.isClean)
        #expect(stopped.processedBytes == UInt64(prefix.count + suffix.count))
        #expect(stopped.synchronizationFailureCount == 0)
        #expect(!publisher.enqueue(0xFF))
        #expect(publisher.snapshot.rejectedAfterStopBytes == 1)

        let persisted = try fixture.read(count: prefix.count + suffix.count)
        #expect(persisted == prefix + suffix)
    }

    @Test func invalidConfigurationAndDescriptorFailureAreVisible() {
        #expect(throws: BoundedSerialConsolePublisher.StartError.self) {
            _ = try BoundedSerialConsolePublisher(destinations: [])
        }
        #expect(throws: BoundedSerialConsolePublisher.StartError.self) {
            _ = try BoundedSerialConsolePublisher(destinations: [
                .init(fileDescriptor: -1),
            ])
        }
    }
}

private final class TemporarySerialFile {
    enum Failure: Error {
        case create(Int32)
        case read(Int32)
        case shortRead(expected: Int, actual: Int)
    }

    let fileDescriptor: Int32
    private let path: String
    private var retired = false

    init() throws {
        var template = Array("\(NSTemporaryDirectory())dory-serial-output.XXXXXX".utf8CString)
        let descriptor = template.withUnsafeMutableBufferPointer { buffer in
            Darwin.mkstemp(buffer.baseAddress!)
        }
        guard descriptor >= 0 else { throw Failure.create(errno) }
        self.fileDescriptor = descriptor
        self.path = String(
            decoding: template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
    }

    func read(count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let result = bytes.withUnsafeMutableBytes { buffer in
                Darwin.pread(
                    fileDescriptor,
                    buffer.baseAddress!.advanced(by: offset),
                    count - offset,
                    off_t(offset)
                )
            }
            if result > 0 {
                offset += result
            } else if result < 0, errno == EINTR {
                continue
            } else if result < 0 {
                throw Failure.read(errno)
            } else {
                throw Failure.shortRead(expected: count, actual: offset)
            }
        }
        return bytes
    }

    func closeAndRemove() {
        guard !retired else { return }
        retired = true
        Darwin.close(fileDescriptor)
        Darwin.unlink(path)
    }

    deinit {
        closeAndRemove()
    }
}
