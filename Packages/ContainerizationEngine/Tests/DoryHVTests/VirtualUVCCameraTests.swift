import Darwin
import Foundation
import Testing
@testable import DoryHV

struct VirtualUVCCameraTests {
    @Test func descriptorPublishesACompositeUVCBulkCamera() throws {
        let source = FixtureCameraFrameSource(frames: [])
        let backend = DoryVirtualUVCCameraBackend(frameSource: source)

        let device = try descriptor(type: 0x01, length: 18, from: backend)
        #expect(device.count == 18)
        #expect(device[4...6] == [0xEF, 0x02, 0x01])
        #expect(device[8...11] == [0xF1, 0xD0, 0x01, 0xCA])

        let configuration = try descriptor(type: 0x02, length: 512, from: backend)
        let declaredLength = Int(configuration[2]) | Int(configuration[3]) << 8
        #expect(declaredLength == configuration.count)
        #expect(configuration[4] == 2)
        #expect(configuration.containsSubsequence([0x0E, 0x01, 0x00]))
        #expect(configuration.containsSubsequence([0x0E, 0x02, 0x00]))
        #expect(configuration.containsSubsequence([7, 0x05, 0x81, 0x02, 0x00, 0x02, 0]))

        let product = try descriptor(type: 0x03, index: 2, length: 255, from: backend)
        #expect(try decodeUSBString(product) == "Dory Camera")
        #expect(DoryVirtualUVCCamera.descriptor().busID == DoryVirtualUVCCamera.busID)
        #expect(DoryVirtualUVCCamera.descriptor().interfaceCount == 2)
    }

    @Test func probeCommitAcceptsTheAdvertisedMJPEGModes() throws {
        let backend = DoryVirtualUVCCameraBackend(
            frameSource: FixtureCameraFrameSource(frames: [])
        )
        var control = [UInt8](repeating: 0, count: 34)
        control[0] = 1
        control[2] = 1
        control[3] = 1
        putLE(UInt32(333_333), into: &control, at: 4)

        _ = try backend.control(
            HostUsbControlSetup(
                requestType: 0x21,
                request: 0x01,
                value: 0x0100,
                index: 1,
                length: 34
            ),
            payload: control,
            direction: .out,
            timeout: 1
        )
        let current = try backend.control(
            HostUsbControlSetup(
                requestType: 0xA1,
                request: 0x81,
                value: 0x0100,
                index: 1,
                length: 34
            ),
            payload: [],
            direction: .in,
            timeout: 1
        )

        #expect(current.actualLength == 34)
        #expect(current.data[2] == 1)
        #expect(current.data[3] == 1)
        #expect(leUInt32(current.data, at: 4) == 333_333)
        #expect(leUInt32(current.data, at: 22) == 16 * 1_024)
        #expect(leUInt32(current.data, at: 26) == 48_000_000)
    }

    @Test func bulkTransfersFrameWithUVCHeadersAndAlternatingFrameIDs() throws {
        let firstFrame = Data([0xFF, 0xD8, 1, 2, 3, 4, 5, 0xFF, 0xD9])
        let secondFrame = Data([0xFF, 0xD8, 9, 8, 0xFF, 0xD9])
        let source = FixtureCameraFrameSource(frames: [firstFrame, secondFrame])
        let backend = DoryVirtualUVCCameraBackend(frameSource: source)
        try enableStreaming(backend)

        let firstPart = try bulkRead(backend, length: 7)
        let secondPart = try bulkRead(backend, length: 7)
        let nextFrame = try bulkRead(backend, length: 64)

        #expect(firstPart.data[0] == 2)
        #expect(firstPart.data[1] & 0x80 != 0)
        #expect(firstPart.data[1] & 0x02 == 0)
        #expect(secondPart.data[1] & 0x02 != 0)
        #expect(firstPart.data[1] & 0x01 == secondPart.data[1] & 0x01)
        #expect(nextFrame.data[1] & 0x01 != firstPart.data[1] & 0x01)
        #expect(Data(firstPart.data.dropFirst(2) + secondPart.data.dropFirst(2)) == firstFrame)
        #expect(Data(nextFrame.data.dropFirst(2)) == secondFrame)
        #expect(source.frameRequests == [[1_280, 720], [1_280, 720]])

        try backend.abort(endpointAddress: nil)
        #expect(source.stopCount == 1)
    }

    @Test func committedVGAStreamRequestsVGAFramesFromTheHost() throws {
        let source = FixtureCameraFrameSource(frames: [Data([0xFF, 0xD8, 0xFF, 0xD9])])
        let backend = DoryVirtualUVCCameraBackend(frameSource: source)
        var control = [UInt8](repeating: 0, count: 34)
        control[0] = 1
        control[2] = 1
        control[3] = 1
        putLE(UInt32(333_333), into: &control, at: 4)
        _ = try backend.control(
            HostUsbControlSetup(
                requestType: 0x21,
                request: 0x01,
                value: 0x0200,
                index: 1,
                length: 34
            ),
            payload: control,
            direction: .out,
            timeout: 1
        )
        try enableStreaming(backend)

        _ = try bulkRead(backend, length: 512)

        #expect(source.frameRequests == [[640, 480]])
    }

    @Test func transfersFailClosedUntilConfiguredAndStreaming() throws {
        let backend = DoryVirtualUVCCameraBackend(
            frameSource: FixtureCameraFrameSource(frames: [Data([0xFF, 0xD8, 0xFF, 0xD9])])
        )

        #expect(throws: HostUsbTransferError.failed(errno: EPIPE)) {
            try bulkRead(backend, length: 512)
        }
        #expect(throws: HostUsbTransferError.endpointNotFound(0x82)) {
            try backend.transfer(
                endpointAddress: 0x82,
                payload: [],
                expectedLength: 512,
                direction: .in,
                kind: .bulk,
                timeout: 1
            )
        }
    }

    private func descriptor(
        type: UInt8,
        index: UInt8 = 0,
        length: UInt16,
        from backend: DoryVirtualUVCCameraBackend
    ) throws -> [UInt8] {
        try backend.control(
            HostUsbControlSetup(
                requestType: 0x80,
                request: 0x06,
                value: UInt16(type) << 8 | UInt16(index),
                index: 0,
                length: length
            ),
            payload: [],
            direction: .in,
            timeout: 1
        ).data
    }

    private func enableStreaming(_ backend: DoryVirtualUVCCameraBackend) throws {
        _ = try backend.control(
            HostUsbControlSetup(
                requestType: 0,
                request: 0x09,
                value: 1,
                index: 0,
                length: 0
            ),
            payload: [],
            direction: .out,
            timeout: 1
        )
        _ = try backend.control(
            HostUsbControlSetup(
                requestType: 1,
                request: 0x0B,
                value: 0,
                index: 1,
                length: 0
            ),
            payload: [],
            direction: .out,
            timeout: 1
        )
    }

    private func bulkRead(
        _ backend: DoryVirtualUVCCameraBackend,
        length: UInt32
    ) throws -> HostUsbTransferResult {
        try backend.transfer(
            endpointAddress: 0x81,
            payload: [],
            expectedLength: length,
            direction: .in,
            kind: .bulk,
            timeout: 1
        )
    }

    private func decodeUSBString(_ descriptor: [UInt8]) throws -> String {
        guard descriptor.count >= 2,
              descriptor[1] == 3,
              descriptor.count.isMultiple(of: 2) else {
            throw FixtureError.invalidStringDescriptor
        }
        let codeUnits = stride(from: 2, to: descriptor.count, by: 2).map {
            UInt16(descriptor[$0]) | UInt16(descriptor[$0 + 1]) << 8
        }
        return String(decoding: codeUnits, as: UTF16.self)
    }

    private func leUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
    }

    private func putLE<T: FixedWidthInteger>(
        _ value: T,
        into bytes: inout [UInt8],
        at offset: Int
    ) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { raw in
            bytes.replaceSubrange(offset..<(offset + raw.count), with: raw)
        }
    }
}

private enum FixtureError: Error {
    case invalidStringDescriptor
}

private final class FixtureCameraFrameSource: DoryUVCCameraFrameSource, @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [Data]
    private var requests: [[Int]] = []
    private(set) var stopCount = 0

    init(frames: [Data]) {
        self.frames = frames
    }

    var frameRequests: [[Int]] {
        lock.withLock { requests }
    }

    func nextJPEGFrame(width: Int, height: Int, timeout: TimeInterval) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        requests.append([width, height])
        guard !frames.isEmpty else { return nil }
        return frames.removeFirst()
    }

    func stop() {
        lock.lock()
        stopCount += 1
        lock.unlock()
    }
}

private extension Array where Element: Equatable {
    func containsSubsequence(_ subsequence: [Element]) -> Bool {
        guard !subsequence.isEmpty, subsequence.count <= count else { return false }
        return indices.dropLast(subsequence.count - 1).contains { start in
            Array(self[start..<(start + subsequence.count)]) == subsequence
        }
    }
}
