import Darwin
import Foundation
import Testing
@testable import DoryHV

@Suite(.serialized)
struct VirtioBlkSafetyTests {
    private func makeDisk(byteCount: Int, fill: UInt8 = 0) throws -> String {
        let path = NSTemporaryDirectory() + "/dory-virtioblk-safety-\(UUID().uuidString).img"
        try Data(repeating: fill, count: byteCount).write(to: URL(fileURLWithPath: path))
        return path
    }

    private func transfer(
        _ block: VirtioBlk,
        sector: UInt64,
        bytes: inout [UInt8],
        reading: Bool
    ) -> VirtioBlk.RequestStatus {
        bytes.withUnsafeMutableBytes { buffer in
            var written = 0
            let segment = VirtqueueSegment(
                pointer: buffer.baseAddress!,
                length: buffer.count,
                isDeviceWritable: reading
            )
            return block.transfer([segment][...], from: sector, into: &written, reading: reading)
        }
    }

    private func fileSize(_ path: String) throws -> off_t {
        var info = stat()
        let result = path.withCString { Darwin.lstat($0, &info) }
        try #require(result == 0)
        return info.st_size
    }

    @Test
    func checkedRangesRejectOverflowAndCapacityOverrun() {
        #expect(VirtioBlk.checkedByteRange(
            sector: UInt64.max,
            byteCount: 512,
            capacityBytes: 4096
        ) == nil)
        #expect(VirtioBlk.checkedSectorRange(
            sector: 0,
            sectorCount: UInt64.max,
            capacityBytes: 4096
        ) == nil)
        #expect(VirtioBlk.checkedByteRange(
            sector: 7,
            byteCount: 1024,
            capacityBytes: 4096
        ) == nil)
        #expect(VirtioBlk.checkedByteRange(
            sector: 8,
            byteCount: 0,
            capacityBytes: 4096
        ) == VirtioBlk.ByteRange(offset: 4096, length: 0))
    }

    @Test
    func overflowingReadAndWriteAreRejectedWithoutExtendingTheImage() throws {
        let path = try makeDisk(byteCount: 4096, fill: 0xA5)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let block = try VirtioBlk(path: path, identity: "safety", asyncIO: false, discard: false)
        var writeBytes = [UInt8](repeating: 0x11, count: 512)
        var readBytes = [UInt8](repeating: 0xCC, count: 512)

        let writeStatus = transfer(
            block,
            sector: UInt64.max,
            bytes: &writeBytes,
            reading: false
        )
        let readStatus = transfer(
            block,
            sector: UInt64.max,
            bytes: &readBytes,
            reading: true
        )

        #expect(writeStatus == .ioError)
        #expect(readStatus == .ioError)
        #expect(readBytes.allSatisfy { $0 == 0xCC })
        #expect(try fileSize(path) == 4096)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)).allSatisfy { $0 == 0xA5 })
    }

    @Test
    func overCapacityChainIsRejectedBeforeItsFirstSegmentIsWritten() throws {
        let path = try makeDisk(byteCount: 4096, fill: 0x7A)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let block = try VirtioBlk(path: path, identity: "safety", asyncIO: false, discard: false)
        var first = [UInt8](repeating: 0x11, count: 512)
        var second = [UInt8](repeating: 0x22, count: 512)

        let status = first.withUnsafeMutableBytes { firstBuffer in
            second.withUnsafeMutableBytes { secondBuffer in
                var written = 0
                let segments = [
                    VirtqueueSegment(
                        pointer: firstBuffer.baseAddress!,
                        length: firstBuffer.count,
                        isDeviceWritable: false
                    ),
                    VirtqueueSegment(
                        pointer: secondBuffer.baseAddress!,
                        length: secondBuffer.count,
                        isDeviceWritable: false
                    ),
                ]
                return block.transfer(segments[...], from: 7, into: &written, reading: false)
            }
        }

        #expect(status == .ioError)
        #expect(try fileSize(path) == 4096)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)).allSatisfy { $0 == 0x7A })
    }

    @Test
    func malformedLaterSegmentIsRejectedBeforeDiskMutation() throws {
        let path = try makeDisk(byteCount: 4096, fill: 0x39)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let block = try VirtioBlk(path: path, identity: "safety", asyncIO: false, discard: false)
        var first = [UInt8](repeating: 0x11, count: 512)
        var wrongDirection = [UInt8](repeating: 0x22, count: 512)

        let status = first.withUnsafeMutableBytes { firstBuffer in
            wrongDirection.withUnsafeMutableBytes { secondBuffer in
                var written = 0
                let segments = [
                    VirtqueueSegment(
                        pointer: firstBuffer.baseAddress!,
                        length: firstBuffer.count,
                        isDeviceWritable: false
                    ),
                    VirtqueueSegment(
                        pointer: secondBuffer.baseAddress!,
                        length: secondBuffer.count,
                        isDeviceWritable: true
                    ),
                ]
                return block.transfer(segments[...], from: 0, into: &written, reading: false)
            }
        }

        #expect(status == .ioError)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)).allSatisfy { $0 == 0x39 })
    }

    @Test
    func vectoredWriteCoalescesSegmentsAndResumesAtTheExactPartialOffset() throws {
        final class Trace: @unchecked Sendable {
            let lock = NSLock()
            var offsets = [off_t]()
            var lengths = [[Int]]()
            var markers = [[UInt8]]()
        }
        let trace = Trace()
        let path = try makeDisk(byteCount: 4_096)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let block = try VirtioBlk(
            path: path,
            identity: "vectored-write",
            asyncIO: false,
            queueCount: 1,
            discard: false,
            flushTelemetry: .production,
            ioOperations: VirtioBlkIOOperations(
                read: { _, _, _, _ in VirtioBlkHostIOResult(count: -1, code: EIO) },
                write: { _, vectors, count, offset in
                    let vectorCount = Int(count)
                    let call = trace.lock.withLock { () -> Int in
                        trace.offsets.append(offset)
                        trace.lengths.append((0..<vectorCount).map { vectors[$0].iov_len })
                        trace.markers.append((0..<vectorCount).map {
                            vectors[$0].iov_base!.load(as: UInt8.self)
                        })
                        return trace.offsets.count
                    }
                    return VirtioBlkHostIOResult(
                        count: call == 1 ? 700 : 836,
                        code: 0
                    )
                },
                monotonicNanoseconds: { 0 }
            )
        )
        var payload = [UInt8](repeating: 0x11, count: 512)
            + [UInt8](repeating: 0x22, count: 512)
            + [UInt8](repeating: 0x33, count: 512)
        var written = 0

        let status = payload.withUnsafeMutableBytes { buffer -> VirtioBlk.RequestStatus in
            let segments = (0..<3).map { index in
                VirtqueueSegment(
                    pointer: buffer.baseAddress! + index * 512,
                    length: 512,
                    isDeviceWritable: false
                )
            }
            return block.transfer(segments[...], from: 0, into: &written, reading: false)
        }

        #expect(status == .ok)
        #expect(written == 0)
        #expect(trace.lock.withLock { trace.offsets } == [0, 700])
        #expect(trace.lock.withLock { trace.lengths } == [[512, 512, 512], [324, 512]])
        #expect(trace.lock.withLock { trace.markers } == [[0x11, 0x22, 0x33], [0x22, 0x33]])
        let statistics = block.statistics
        #expect(statistics.writeRequests == 1)
        #expect(statistics.writeBytes == 1_536)
        #expect(statistics.writeSystemCalls == 2)
        #expect(statistics.partialIOSystemCalls == 1)
        #expect(statistics.failedIOSystemCalls == 0)
        #expect(statistics.transferSegments == 3)
    }

    @Test
    func realVectoredReadAndWritePreserveMultiSegmentPayload() throws {
        let path = try makeDisk(byteCount: 4_096, fill: 0xC7)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let block = try VirtioBlk(
            path: path,
            identity: "real-vectored-io",
            asyncIO: false,
            queueCount: 1,
            discard: false
        )
        var source = [UInt8](repeating: 0x11, count: 512)
            + [UInt8](repeating: 0x22, count: 512)
            + [UInt8](repeating: 0x33, count: 512)
        var destination = [UInt8](repeating: 0, count: source.count)
        var writeUsedLength = 0
        var readUsedLength = 0

        let writeStatus = source.withUnsafeMutableBytes { buffer -> VirtioBlk.RequestStatus in
            let segments = (0..<3).map { index in
                VirtqueueSegment(
                    pointer: buffer.baseAddress! + index * 512,
                    length: 512,
                    isDeviceWritable: false
                )
            }
            return block.transfer(
                segments[...],
                from: 1,
                into: &writeUsedLength,
                reading: false
            )
        }
        let readStatus = destination.withUnsafeMutableBytes { buffer -> VirtioBlk.RequestStatus in
            let segments = (0..<3).map { index in
                VirtqueueSegment(
                    pointer: buffer.baseAddress! + index * 512,
                    length: 512,
                    isDeviceWritable: true
                )
            }
            return block.transfer(
                segments[...],
                from: 1,
                into: &readUsedLength,
                reading: true
            )
        }

        #expect(writeStatus == .ok)
        #expect(readStatus == .ok)
        #expect(writeUsedLength == 0)
        #expect(readUsedLength == source.count)
        #expect(destination == source)
        let statistics = block.statistics
        #expect(statistics.writeRequests == 1)
        #expect(statistics.readRequests == 1)
        #expect(statistics.writeBytes == UInt64(source.count))
        #expect(statistics.readBytes == UInt64(source.count))
        #expect(statistics.writeSystemCalls == 1)
        #expect(statistics.readSystemCalls == 1)
        #expect(statistics.transferSegments == 6)
    }

    @Test
    func vectoredReadRetriesEINTRAndPublishesTheExactPartialByteCountOnFailure() throws {
        final class CallState: @unchecked Sendable {
            let lock = NSLock()
            var call = 0
            var offsets = [off_t]()
            var lengths = [[Int]]()
        }
        let calls = CallState()
        let path = try makeDisk(byteCount: 4_096)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let block = try VirtioBlk(
            path: path,
            identity: "vectored-read",
            asyncIO: false,
            queueCount: 1,
            discard: false,
            flushTelemetry: .production,
            ioOperations: VirtioBlkIOOperations(
                read: { _, vectors, count, offset in
                    let vectorCount = Int(count)
                    let call = calls.lock.withLock { () -> Int in
                        calls.call += 1
                        calls.offsets.append(offset)
                        calls.lengths.append((0..<vectorCount).map { vectors[$0].iov_len })
                        return calls.call
                    }
                    switch call {
                    case 1:
                        return VirtioBlkHostIOResult(count: -1, code: EINTR)
                    case 2:
                        var remaining = 600
                        for index in 0..<vectorCount where remaining > 0 {
                            let count = min(remaining, vectors[index].iov_len)
                            memset(vectors[index].iov_base, 0xAB, count)
                            remaining -= count
                        }
                        return VirtioBlkHostIOResult(count: 600, code: 0)
                    default:
                        return VirtioBlkHostIOResult(count: -1, code: EIO)
                    }
                },
                write: { _, _, _, _ in VirtioBlkHostIOResult(count: -1, code: EIO) },
                monotonicNanoseconds: { 0 }
            )
        )
        var payload = [UInt8](repeating: 0, count: 1_024)
        var written = 0

        let status = payload.withUnsafeMutableBytes { buffer -> VirtioBlk.RequestStatus in
            let segments = (0..<2).map { index in
                VirtqueueSegment(
                    pointer: buffer.baseAddress! + index * 512,
                    length: 512,
                    isDeviceWritable: true
                )
            }
            return block.transfer(segments[...], from: 0, into: &written, reading: true)
        }

        #expect(status == .ioError)
        #expect(written == 600)
        #expect(payload[..<600].allSatisfy { $0 == 0xAB })
        #expect(payload[600...].allSatisfy { $0 == 0 })
        #expect(calls.lock.withLock { calls.offsets } == [0, 0, 600])
        #expect(calls.lock.withLock { calls.lengths } == [
            [512, 512],
            [512, 512],
            [424],
        ])
        let statistics = block.statistics
        #expect(statistics.readRequests == 1)
        #expect(statistics.readBytes == 600)
        #expect(statistics.readSystemCalls == 3)
        #expect(statistics.partialIOSystemCalls == 1)
        #expect(statistics.interruptedIOSystemCalls == 1)
        #expect(statistics.failedIOSystemCalls == 1)
        #expect(statistics.transferSegments == 2)
    }

    @Test
    func pathologicalShortWritesStopAtTheResolvedHostOperationBudget() throws {
        final class Calls: @unchecked Sendable {
            let lock = NSLock()
            var count = 0
        }
        let calls = Calls()
        let path = try makeDisk(byteCount: 4_096)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let block = try VirtioBlk(
            path: path,
            identity: "short-write-budget",
            asyncIO: false,
            queueCount: 1,
            discard: false,
            flushTelemetry: .production,
            limits: VirtioBlkLimits(
                maximumTransferBytes: 4_096,
                maximumChainsPerDrain: 8,
                maximumHostIOOperationsPerRequest: 2
            ),
            ioOperations: VirtioBlkIOOperations(
                read: { _, _, _, _ in VirtioBlkHostIOResult(count: -1, code: EIO) },
                write: { _, _, _, _ in
                    calls.lock.withLock { calls.count += 1 }
                    return VirtioBlkHostIOResult(count: 1, code: 0)
                },
                monotonicNanoseconds: { 0 }
            )
        )
        var payload = [UInt8](repeating: 0x5A, count: 512)
        var written = 0

        let status = payload.withUnsafeMutableBytes { buffer -> VirtioBlk.RequestStatus in
            let segment = VirtqueueSegment(
                pointer: buffer.baseAddress!,
                length: buffer.count,
                isDeviceWritable: false
            )
            return block.transfer([segment][...], from: 0, into: &written, reading: false)
        }

        #expect(status == .ioError)
        #expect(calls.lock.withLock { calls.count } == 2)
        let statistics = block.statistics
        #expect(statistics.writeBytes == 2)
        #expect(statistics.writeSystemCalls == 2)
        #expect(statistics.partialIOSystemCalls == 2)
        #expect(statistics.failedIOSystemCalls == 0)
        #expect(statistics.hostIOBudgetExhaustions == 1)
    }

    @Test
    func pathologicalShortWriteZeroesStopsAtTheResolvedRangeOperationBudget() throws {
        final class Trace: @unchecked Sendable {
            let lock = NSLock()
            var offsets = [off_t]()
            var vectorLengths = [[Int]]()
            var punchCalls = 0
        }
        let trace = Trace()
        let path = try makeDisk(byteCount: 4_096, fill: 0xA6)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let block = try VirtioBlk(
            path: path,
            identity: "short-write-zeroes-budget",
            asyncIO: false,
            queueCount: 1,
            discard: true,
            flushTelemetry: .production,
            limits: VirtioBlkLimits(
                maximumTransferBytes: 4_096,
                maximumChainsPerDrain: 8,
                maximumDiscardSegmentsPerRequest: 2,
                maximumWriteZeroesSegmentsPerRequest: 1,
                maximumWriteZeroesBytesPerRequest: 4_096,
                maximumRangeHostOperationsPerRequest: 2,
                maximumRangeHostOperationsPerDrain: 2
            ),
            ioOperations: VirtioBlkIOOperations(
                read: { _, _, _, _ in VirtioBlkHostIOResult(count: -1, code: EIO) },
                write: { _, vectors, count, offset in
                    trace.lock.withLock {
                        trace.offsets.append(offset)
                        trace.vectorLengths.append((0..<Int(count)).map {
                            vectors[$0].iov_len
                        })
                    }
                    return VirtioBlkHostIOResult(count: 1, code: 0)
                },
                monotonicNanoseconds: { 0 }
            ),
            rangeOperations: VirtioBlkRangeOperations(punchHole: { _, _, _ in
                trace.lock.withLock { trace.punchCalls += 1 }
                return VirtioBlkHostIOResult(count: -1, code: EIO)
            })
        )
        var range = [UInt8]()
        withUnsafeBytes(of: UInt64(0).littleEndian) { range.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(1).littleEndian) { range.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(0).littleEndian) { range.append(contentsOf: $0) }

        let status = range.withUnsafeMutableBytes { buffer -> VirtioBlk.RequestStatus in
            let segment = VirtqueueSegment(
                pointer: buffer.baseAddress!,
                length: buffer.count,
                isDeviceWritable: false
            )
            return block.applyDiscardOrWriteZeroes([segment][...], writeZeroes: true)
        }

        #expect(status == .ioError)
        #expect(trace.lock.withLock { trace.offsets } == [0, 1])
        #expect(trace.lock.withLock { trace.vectorLengths } == [[512], [511]])
        #expect(trace.lock.withLock { trace.punchCalls } == 0)
        let statistics = block.statistics
        #expect(statistics.writeZeroesRequests == 1)
        #expect(statistics.writeZeroesRequestedBytes == 512)
        #expect(statistics.writeZeroesHostWrittenBytes == 2)
        #expect(statistics.writeZeroesHostOperations == 2)
        #expect(statistics.rangePartialHostOperations == 2)
        #expect(statistics.rangeFailedHostOperations == 0)
        #expect(statistics.rangeHostOperationBudgetExhaustions == 1)
        #expect(statistics.rangeSegments == 1)
        #expect(statistics.writeRequests == 0)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)).allSatisfy { $0 == 0xA6 })
    }

    @Test
    func oversizedTransferIsRejectedBeforeDiskMutation() throws {
        let path = try makeDisk(byteCount: 8_192, fill: 0x5C)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let block = try VirtioBlk(
            path: path,
            identity: "safety",
            asyncIO: false,
            queueCount: 1,
            discard: false,
            flushTelemetry: .production,
            limits: VirtioBlkLimits(maximumTransferBytes: 4_096, maximumChainsPerDrain: 8)
        )
        var bytes = [UInt8](repeating: 0xAA, count: 4_608)

        let status = transfer(block, sector: 0, bytes: &bytes, reading: false)

        #expect(status == .ioError)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)).allSatisfy { $0 == 0x5C })
    }

    @Test
    func capacityRemainsBoundToSizeCapturedAtInitialization() throws {
        let path = try makeDisk(byteCount: 4096)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let block = try VirtioBlk(path: path, identity: "safety", asyncIO: false, discard: false)
        try #require(truncate(path, 8192) == 0)
        var bytes = [UInt8](repeating: 0xEF, count: 512)

        let status = transfer(block, sector: 8, bytes: &bytes, reading: false)

        #expect(status == .ioError)
        #expect(try fileSize(path) == 8192)
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(data[4096...].allSatisfy { $0 == 0 })
    }

    @Test
    func trailingPartialSectorIsNotAddressable() throws {
        let path = try makeDisk(byteCount: 768, fill: 0x64)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let block = try VirtioBlk(path: path, identity: "safety", asyncIO: false, discard: false)
        var bytes = [UInt8](repeating: 0xAA, count: 512)

        let status = transfer(block, sector: 1, bytes: &bytes, reading: false)

        #expect(status == .ioError)
        #expect(try fileSize(path) == 768)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)).allSatisfy { $0 == 0x64 })
    }

    @Test
    func discardAndWriteZeroesRejectOverflowBeforeMutation() throws {
        let path = try makeDisk(byteCount: 4096, fill: 0xB4)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let block = try VirtioBlk(path: path, identity: "safety", asyncIO: false)
        var request = [UInt8]()
        withUnsafeBytes(of: UInt64.max.littleEndian) { request.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(1).littleEndian) { request.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(0).littleEndian) { request.append(contentsOf: $0) }

        let statuses = request.withUnsafeMutableBytes { buffer -> [VirtioBlk.RequestStatus] in
            let segment = VirtqueueSegment(
                pointer: buffer.baseAddress!,
                length: buffer.count,
                isDeviceWritable: false
            )
            return [
                block.applyDiscardOrWriteZeroes([segment][...], writeZeroes: false),
                block.applyDiscardOrWriteZeroes([segment][...], writeZeroes: true),
            ]
        }

        #expect(statuses == [.ioError, .ioError])
        #expect(try fileSize(path) == 4096)
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)).allSatisfy { $0 == 0xB4 })
    }

    @Test
    func pathInitializerRejectsSymlinksAndNonRegularFiles() throws {
        let target = try makeDisk(byteCount: 4096)
        let link = target + ".link"
        let directory = target + ".directory"
        defer {
            try? FileManager.default.removeItem(atPath: link)
            try? FileManager.default.removeItem(atPath: directory)
            try? FileManager.default.removeItem(atPath: target)
        }
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false)

        #expect(throws: VMError.self) {
            _ = try VirtioBlk(path: link, identity: "safety", readOnly: true)
        }
        #expect(throws: VMError.self) {
            _ = try VirtioBlk(path: directory, identity: "safety", readOnly: true)
        }
    }

    @Test
    func descriptorInitializerDuplicatesCallerDescriptor() throws {
        let path = try makeDisk(byteCount: 4096)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let descriptor = open(path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        try #require(descriptor >= 0)
        let block: VirtioBlk
        do {
            block = try VirtioBlk(
                fileDescriptor: descriptor,
                identity: "safety",
                asyncIO: false,
                discard: false
            )
        } catch {
            close(descriptor)
            throw error
        }
        close(descriptor)
        var bytes = [UInt8](repeating: 0xD3, count: 512)

        let status = transfer(block, sector: 0, bytes: &bytes, reading: false)

        #expect(status == .ok)
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(data[..<512].allSatisfy { $0 == 0xD3 })
    }

    @Test
    func writableBackendRejectsReadOnlyDescriptor() throws {
        let path = try makeDisk(byteCount: 4096)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        try #require(descriptor >= 0)
        defer { close(descriptor) }

        #expect(throws: VMError.self) {
            _ = try VirtioBlk(
                fileDescriptor: descriptor,
                identity: "safety",
                readOnly: false
            )
        }
    }

    @Test
    func getIDUsesStrictWritableLayoutAndPublishesExactlyTwentyPaddedBytes() throws {
        let harness = try makeQueueHarness(identity: "dory-id")
        defer { try? FileManager.default.removeItem(atPath: harness.diskPath) }
        let header = harness.guestBase + 0x20_000
        let firstOutput = header + 0x100
        let secondOutput = header + 0x200
        let status = header + 0x300
        try writeRequestHeader(type: 8, sector: 0, at: header, harness: harness)
        try installDescriptor(index: 0, address: header, length: 16, flags: 1, next: 1, harness: harness)
        try installDescriptor(index: 1, address: firstOutput, length: 7, flags: 3, next: 2, harness: harness)
        try installDescriptor(index: 2, address: secondOutput, length: 13, flags: 3, next: 3, harness: harness)
        try installDescriptor(index: 3, address: status, length: 1, flags: 2, next: 0, harness: harness)
        try harness.memory.write([UInt8](repeating: 0xA5, count: 20), at: firstOutput)
        try harness.memory.write(UInt8(0xFF), at: status)
        try publish([0], startingAt: 0, harness: harness)

        harness.block.handleKick(queue: 0, transport: harness.transport)

        let expected = Array("dory-id".utf8) + [UInt8](repeating: 0, count: 13)
        #expect(try harness.memory.readBytes(at: firstOutput, count: 7) == Array(expected[..<7]))
        #expect(try harness.memory.readBytes(at: secondOutput, count: 13) == Array(expected[7...]))
        #expect(try harness.memory.read(UInt8.self, at: status) == VirtioBlk.RequestStatus.ok.rawValue)
        #expect(try usedLength(at: 0, harness: harness) == 21)
    }

    @Test
    func zeroLengthRequestDescriptorIsRejectedWithoutLosingItsStatusCompletion() throws {
        let harness = try makeQueueHarness()
        defer { try? FileManager.default.removeItem(atPath: harness.diskPath) }
        let header = harness.guestBase + 0x20_000
        let status = header + 0x200
        try writeRequestHeader(type: 4, sector: 0, at: header, harness: harness)
        try installDescriptor(index: 0, address: header, length: 16, flags: 1, next: 1, harness: harness)
        try installDescriptor(index: 1, address: header + 0x100, length: 0, flags: 1, next: 2, harness: harness)
        try installDescriptor(index: 2, address: status, length: 1, flags: 2, next: 0, harness: harness)
        try harness.memory.write(UInt8(0xFF), at: status)
        try publish([0], startingAt: 0, harness: harness)

        harness.block.handleKick(queue: 0, transport: harness.transport)

        #expect(try harness.memory.read(UInt8.self, at: status) == VirtioBlk.RequestStatus.ioError.rawValue)
        #expect(try usedLength(at: 0, harness: harness) == 1)
        #expect(harness.block.statistics.invalidRequests == 1)
    }

    @Test
    func queueDrainIsBoundedAndMalformedPopIsObservable() throws {
        let harness = try makeQueueHarness(
            limits: VirtioBlkLimits(maximumTransferBytes: 4_096, maximumChainsPerDrain: 1)
        )
        defer { try? FileManager.default.removeItem(atPath: harness.diskPath) }
        let buffer = harness.guestBase + 0x20_000
        for request in UInt16(0)..<2 {
            let head = request * 2
            let header = buffer + UInt64(request) * 0x200
            let status = header + 0x100
            try writeRequestHeader(type: 4, sector: 0, at: header, harness: harness)
            try installDescriptor(index: head, address: header, length: 16, flags: 1, next: head + 1, harness: harness)
            try installDescriptor(index: head + 1, address: status, length: 1, flags: 2, next: 0, harness: harness)
        }
        try publish([0, 2], startingAt: 0, harness: harness)

        harness.block.handleKick(queue: 0, transport: harness.transport)
        #expect(try usedIndex(harness) == 1)
        #expect(harness.block.statistics.boundedDrainStops == 1)

        harness.block.handleKick(queue: 0, transport: harness.transport)
        #expect(try usedIndex(harness) == 2)
        #expect(harness.block.statistics.boundedDrainStops == 1)

        try installDescriptor(
            index: 4,
            address: harness.guestBase + harness.memory.size + 0x100,
            length: 16,
            flags: 0,
            next: 0,
            harness: harness
        )
        try publish([4], startingAt: 2, harness: harness)
        harness.block.handleKick(queue: 0, transport: harness.transport)

        #expect(try usedIndex(harness) == 2)
        #expect(harness.block.statistics.queuePopFaults == 1)
    }

    @Test
    func asynchronousSingleKickDrainsAcrossFairBoundedWorkTurns() throws {
        let harness = try makeQueueHarness(
            asyncIO: true,
            limits: VirtioBlkLimits(
                maximumTransferBytes: 4_096,
                maximumChainsPerDrain: 1
            )
        )
        defer { try? FileManager.default.removeItem(atPath: harness.diskPath) }
        let buffer = harness.guestBase + 0x20_000
        for request in UInt16(0)..<3 {
            let head = request * 2
            let header = buffer + UInt64(request) * 0x200
            let status = header + 0x100
            try writeRequestHeader(type: 4, sector: 0, at: header, harness: harness)
            try installDescriptor(
                index: head,
                address: header,
                length: 16,
                flags: 1,
                next: head + 1,
                harness: harness
            )
            try installDescriptor(
                index: head + 1,
                address: status,
                length: 1,
                flags: 2,
                next: 0,
                harness: harness
            )
        }
        try publish([0, 2, 4], startingAt: 0, harness: harness)

        harness.transport.write(offset: 0x050, value: 0, width: 4)

        #expect(waitUntil { (try? usedIndex(harness)) == 3 })
        let statistics = harness.block.statistics
        #expect(statistics.queueWorkTurns == 3)
        #expect(statistics.boundedDrainStops == 2)
        #expect(statistics.queueHighWatermark == 3)
        #expect(statistics.queueDepth == 0)
        #expect(statistics.requestCompletions == 3)
        #expect(statistics.requestServiceLatencyNanoseconds > 0)
        #expect(statistics.maximumRequestServiceLatencyNanoseconds > 0)
        #expect(statistics.flushes == 3)
    }

    @Test
    func discardHostOperationBudgetSplitsOneKickAcrossFairWorkTurns() throws {
        final class PunchTrace: @unchecked Sendable {
            let lock = NSLock()
            var ranges = [(off_t, off_t)]()
        }
        let trace = PunchTrace()
        let harness = try makeQueueHarness(
            asyncIO: true,
            discard: true,
            limits: VirtioBlkLimits(
                maximumTransferBytes: 4_096,
                maximumChainsPerDrain: 8,
                maximumRangeHostOperationsPerDrain: 1
            ),
            rangeOperations: VirtioBlkRangeOperations(punchHole: { _, offset, length in
                trace.lock.withLock { trace.ranges.append((offset, length)) }
                return VirtioBlkHostIOResult(count: 0, code: 0)
            })
        )
        defer { try? FileManager.default.removeItem(atPath: harness.diskPath) }
        let buffer = harness.guestBase + 0x20_000
        for request in UInt16(0)..<2 {
            let head = request * 3
            let header = buffer + UInt64(request) * 0x300
            let range = header + 0x100
            let status = header + 0x200
            try writeRequestHeader(type: 11, sector: 0, at: header, harness: harness)
            try writeRangeEntry(
                sector: UInt64(request) * 8,
                sectorCount: 8,
                flags: 0,
                at: range,
                harness: harness
            )
            try harness.memory.write(UInt8(0xFF), at: status)
            try installDescriptor(
                index: head,
                address: header,
                length: 16,
                flags: 1,
                next: head + 1,
                harness: harness
            )
            try installDescriptor(
                index: head + 1,
                address: range,
                length: 16,
                flags: 1,
                next: head + 2,
                harness: harness
            )
            try installDescriptor(
                index: head + 2,
                address: status,
                length: 1,
                flags: 2,
                next: 0,
                harness: harness
            )
        }
        try publish([0, 3], startingAt: 0, harness: harness)

        harness.transport.write(offset: 0x050, value: 0, width: 4)

        #expect(waitUntil { (try? usedIndex(harness)) == 2 })
        #expect(trace.lock.withLock { trace.ranges.map { $0.0 } } == [0, 4_096])
        #expect(trace.lock.withLock { trace.ranges.map { $0.1 } } == [4_096, 4_096])
        let statistics = harness.block.statistics
        #expect(statistics.queueWorkTurns == 2)
        #expect(statistics.boundedDrainStops == 1)
        #expect(statistics.rangeTurnBudgetStops == 1)
        #expect(statistics.discardRequests == 2)
        #expect(statistics.discardRequestedBytes == 8_192)
        #expect(statistics.discardHostOperations == 2)
        #expect(statistics.discardIgnoredRanges == 0)
        #expect(statistics.rangeSegments == 2)
        #expect(statistics.requestCompletions == 2)
    }

    @Test
    func resetWaitsForAdmittedZeroingAndRevokesItsLateCompletion() throws {
        final class Trace: @unchecked Sendable {
            let lock = NSLock()
            var writeCalls = 0
            var offeredBytes = 0
            var punchCalls = 0
        }
        let trace = Trace()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let harness = try makeQueueHarness(
            asyncIO: true,
            discard: true,
            ioOperations: VirtioBlkIOOperations(
                read: { _, _, _, _ in VirtioBlkHostIOResult(count: -1, code: EIO) },
                write: { _, vectors, count, _ in
                    let byteCount = (0..<Int(count)).reduce(0) {
                        $0 + vectors[$1].iov_len
                    }
                    trace.lock.withLock {
                        trace.writeCalls += 1
                        trace.offeredBytes = byteCount
                    }
                    started.signal()
                    _ = release.wait(timeout: .now() + 2)
                    return VirtioBlkHostIOResult(count: byteCount, code: 0)
                },
                monotonicNanoseconds: { DispatchTime.now().uptimeNanoseconds }
            ),
            rangeOperations: VirtioBlkRangeOperations(punchHole: { _, _, _ in
                trace.lock.withLock { trace.punchCalls += 1 }
                return VirtioBlkHostIOResult(count: -1, code: EIO)
            })
        )
        defer {
            release.signal()
            try? FileManager.default.removeItem(atPath: harness.diskPath)
        }
        let header = harness.guestBase + 0x20_000
        let range = header + 0x100
        let status = header + 0x200
        try writeRequestHeader(type: 13, sector: 0, at: header, harness: harness)
        try writeRangeEntry(
            sector: 0,
            sectorCount: 1,
            flags: 0,
            at: range,
            harness: harness
        )
        try harness.memory.write(UInt8(0xFF), at: status)
        try installDescriptor(index: 0, address: header, length: 16, flags: 1, next: 1, harness: harness)
        try installDescriptor(index: 1, address: range, length: 16, flags: 1, next: 2, harness: harness)
        try installDescriptor(index: 2, address: status, length: 1, flags: 2, next: 0, harness: harness)
        try publish([0], startingAt: 0, harness: harness)

        harness.transport.write(offset: 0x050, value: 0, width: 4)
        #expect(started.wait(timeout: .now() + 1) == .success)
        #expect(harness.transport.read(offset: 0x008, width: 4) == UInt64(harness.block.deviceID))

        let resetFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            harness.transport.write(offset: 0x070, value: 0, width: 4)
            resetFinished.signal()
        }
        #expect(resetFinished.wait(timeout: .now() + 0.02) == .timedOut)
        release.signal()
        #expect(resetFinished.wait(timeout: .now() + 1) == .success)
        #expect(waitUntil { harness.block.statistics.revokedRequests == 1 })

        #expect(trace.lock.withLock { trace.writeCalls } == 1)
        #expect(trace.lock.withLock { trace.offeredBytes } == 512)
        #expect(trace.lock.withLock { trace.punchCalls } == 0)
        #expect(try harness.memory.read(UInt16.self, at: harness.usedRing + 2) == 0)
        let statistics = harness.block.statistics
        #expect(statistics.writeZeroesRequests == 1)
        #expect(statistics.writeZeroesRequestedBytes == 512)
        #expect(statistics.writeZeroesHostWrittenBytes == 512)
        #expect(statistics.writeZeroesHostOperations == 1)
        #expect(statistics.requestCompletions == 0)
        #expect(statistics.completionFaults == 0)
        #expect(statistics.queueDepth == 0)
    }

    @Test
    func resetWaitsForTheAdmittedHostCallAndRevokesItsLateCompletion() throws {
        final class Calls: @unchecked Sendable {
            let lock = NSLock()
            var count = 0
        }
        let calls = Calls()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let harness = try makeQueueHarness(
            asyncIO: true,
            ioOperations: VirtioBlkIOOperations(
                read: { _, _, _, _ in VirtioBlkHostIOResult(count: -1, code: EIO) },
                write: { _, vectors, count, _ in
                    calls.lock.withLock { calls.count += 1 }
                    started.signal()
                    _ = release.wait(timeout: .now() + 2)
                    let byteCount = (0..<Int(count)).reduce(0) {
                        $0 + vectors[$1].iov_len
                    }
                    return VirtioBlkHostIOResult(count: byteCount, code: 0)
                },
                monotonicNanoseconds: { DispatchTime.now().uptimeNanoseconds }
            )
        )
        defer {
            release.signal()
            try? FileManager.default.removeItem(atPath: harness.diskPath)
        }
        let header = harness.guestBase + 0x20_000
        let data = header + 0x100
        let status = header + 0x400
        try writeRequestHeader(type: 1, sector: 0, at: header, harness: harness)
        try harness.memory.write([UInt8](repeating: 0x8A, count: 512), at: data)
        try harness.memory.write(UInt8(0xFF), at: status)
        try installDescriptor(index: 0, address: header, length: 16, flags: 1, next: 1, harness: harness)
        try installDescriptor(index: 1, address: data, length: 512, flags: 1, next: 2, harness: harness)
        try installDescriptor(index: 2, address: status, length: 1, flags: 2, next: 0, harness: harness)
        try publish([0], startingAt: 0, harness: harness)

        harness.transport.write(offset: 0x050, value: 0, width: 4)
        #expect(started.wait(timeout: .now() + 1) == .success)
        #expect(harness.transport.read(offset: 0x008, width: 4) == UInt64(harness.block.deviceID))

        let resetFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            harness.transport.write(offset: 0x070, value: 0, width: 4)
            resetFinished.signal()
        }
        #expect(resetFinished.wait(timeout: .now() + 0.02) == .timedOut)
        release.signal()
        #expect(resetFinished.wait(timeout: .now() + 1) == .success)
        #expect(waitUntil { harness.block.statistics.revokedRequests == 1 })

        #expect(calls.lock.withLock { calls.count } == 1)
        #expect(try harness.memory.read(UInt16.self, at: harness.usedRing + 2) == 0)
        let statistics = harness.block.statistics
        #expect(statistics.writeRequests == 1)
        #expect(statistics.writeBytes == 512)
        #expect(statistics.writeSystemCalls == 1)
        #expect(statistics.requestCompletions == 0)
        #expect(statistics.completionFaults == 0)
        #expect(statistics.queueDepth == 0)
    }

    private struct QueueHarness {
        let diskPath: String
        let guestBase: UInt64
        let descriptorTable: UInt64
        let availableRing: UInt64
        let usedRing: UInt64
        let memory: GuestMemory
        let block: VirtioBlk
        let transport: VirtioMMIOTransport
    }

    private func makeQueueHarness(
        identity: String = "safety",
        asyncIO: Bool = false,
        discard: Bool = false,
        limits: VirtioBlkLimits = .production,
        ioOperations: VirtioBlkIOOperations = .production,
        rangeOperations: VirtioBlkRangeOperations = .production
    ) throws -> QueueHarness {
        let diskPath = try makeDisk(byteCount: 1 << 20)
        let guestBase: UInt64 = 0xD400_0000
        let memory = try GuestMemory(guestBase: guestBase, size: 1 << 20)
        let block = try VirtioBlk(
            path: diskPath,
            identity: identity,
            asyncIO: asyncIO,
            queueCount: 1,
            discard: discard,
            flushTelemetry: .production,
            limits: limits,
            ioOperations: ioOperations,
            rangeOperations: rangeOperations
        )
        let transport = VirtioMMIOTransport(
            baseAddress: GuestLayout.virtioBase,
            backend: block,
            memory: memory
        ) {}
        let descriptorTable = guestBase + 0x10_000
        let availableRing = guestBase + 0x12_000
        let usedRing = guestBase + 0x14_000
        #expect(transport.queues[0].configure(
            size: 8,
            descriptorTable: descriptorTable,
            availRing: availableRing,
            usedRing: usedRing
        ))
        #expect(transport.queues[0].setReady(true))
        block.deviceReady(transport: transport)
        try memory.write(UInt16(0), at: availableRing)
        try memory.write(UInt16(0), at: availableRing + 2)
        try memory.write(UInt16(0), at: usedRing + 2)
        return QueueHarness(
            diskPath: diskPath,
            guestBase: guestBase,
            descriptorTable: descriptorTable,
            availableRing: availableRing,
            usedRing: usedRing,
            memory: memory,
            block: block,
            transport: transport
        )
    }

    private func installDescriptor(
        index: UInt16,
        address: UInt64,
        length: Int,
        flags: UInt16,
        next: UInt16,
        harness: QueueHarness
    ) throws {
        let descriptor = harness.descriptorTable + UInt64(index) * 16
        try harness.memory.write(address, at: descriptor)
        try harness.memory.write(UInt32(length), at: descriptor + 8)
        try harness.memory.write(flags, at: descriptor + 12)
        try harness.memory.write(next, at: descriptor + 14)
    }

    private func writeRequestHeader(
        type: UInt32,
        sector: UInt64,
        at address: UInt64,
        harness: QueueHarness
    ) throws {
        try harness.memory.write(type, at: address)
        try harness.memory.write(UInt32(0), at: address + 4)
        try harness.memory.write(sector, at: address + 8)
    }

    private func writeRangeEntry(
        sector: UInt64,
        sectorCount: UInt32,
        flags: UInt32,
        at address: UInt64,
        harness: QueueHarness
    ) throws {
        try harness.memory.write(sector, at: address)
        try harness.memory.write(sectorCount, at: address + 8)
        try harness.memory.write(flags, at: address + 12)
    }

    private func publish(
        _ heads: [UInt16],
        startingAt start: UInt16,
        harness: QueueHarness
    ) throws {
        for (offset, head) in heads.enumerated() {
            let slot = (Int(start) + offset) % 8
            try harness.memory.write(
                head,
                at: harness.availableRing + 4 + UInt64(slot) * 2
            )
        }
        try harness.memory.write(start + UInt16(heads.count), at: harness.availableRing + 2)
    }

    private func usedIndex(_ harness: QueueHarness) throws -> UInt16 {
        try harness.memory.read(UInt16.self, at: harness.usedRing + 2)
    }

    private func usedLength(at slot: Int, harness: QueueHarness) throws -> UInt32 {
        try harness.memory.read(UInt32.self, at: harness.usedRing + 8 + UInt64(slot) * 8)
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ predicate: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            usleep(1_000)
        }
        return predicate()
    }
}
