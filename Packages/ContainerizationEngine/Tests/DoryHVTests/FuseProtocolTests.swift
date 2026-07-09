import Testing
@testable import DoryHV

struct FuseProtocolTests {
    @Test func inHeaderRoundTripsLittleEndianFields() throws {
        let header = FuseInHeader(
            length: 56,
            opcode: FuseOpcode.initOp.rawValue,
            unique: 0x0102_0304_0506_0708,
            nodeID: 1,
            uid: 501,
            gid: 20,
            pid: 1234,
            totalExtlen: 16,
            padding: 0
        )

        let bytes = FuseProtocol.encodeInHeader(header)
        let decoded = try FuseProtocol.decodeInHeader(bytes)

        #expect(bytes.count == FuseInHeader.byteCount)
        #expect(bytes[0..<4].elementsEqual([56, 0, 0, 0]))
        #expect(bytes[4..<8].elementsEqual([26, 0, 0, 0]))
        #expect(bytes[8..<16].elementsEqual([8, 7, 6, 5, 4, 3, 2, 1]))
        #expect(decoded == header)
    }

    @Test func initNegotiationCapsMinorAndPreservesUnique() throws {
        let header = FuseInHeader(
            length: UInt32(FuseInHeader.byteCount + FuseInitIn.byteCount),
            opcode: FuseOpcode.initOp.rawValue,
            unique: 0xabc,
            nodeID: 1,
            uid: 0,
            gid: 0,
            pid: 42
        )
        let request = FuseInitIn(major: 7, minor: 45, maxReadahead: 131_072, flags: FuseInitFlag.asyncRead.rawValue)

        let response = FuseProtocol.negotiateInit(header: header, request: request)
        let outHeader = try FuseProtocol.decodeOutHeader(Array(response.prefix(FuseOutHeader.byteCount)))
        let payload = Array(response.dropFirst(FuseOutHeader.byteCount))

        #expect(outHeader == FuseOutHeader(length: UInt32(FuseOutHeader.byteCount + FuseInitOut.byteCount), error: 0, unique: 0xabc))
        #expect(payload.count == FuseInitOut.byteCount)
        #expect(payload[0..<4].elementsEqual([7, 0, 0, 0]))
        #expect(payload[4..<8].elementsEqual([38, 0, 0, 0]))
        #expect(payload[8..<12].elementsEqual([0, 0, 2, 0]))
        #expect(payload.leUInt32(at: 12) & FuseInitFlag.writebackCache.rawValue == 0)
        #expect(payload.leUInt32(at: 12) & FuseInitFlag.parallelDirops.rawValue == FuseInitFlag.parallelDirops.rawValue)
    }

    @Test func initNegotiationCanEnableWritebackCache() throws {
        let header = FuseInHeader(
            length: UInt32(FuseInHeader.byteCount + FuseInitIn.byteCount),
            opcode: FuseOpcode.initOp.rawValue,
            unique: 0x456,
            nodeID: 1,
            uid: 0,
            gid: 0,
            pid: 42
        )
        let request = FuseInitIn(major: 7, minor: 38, maxReadahead: 131_072, flags: FuseInitFlag.asyncRead.rawValue)

        let response = FuseProtocol.negotiateInit(header: header, request: request, writebackCache: true)
        let payload = Array(response.dropFirst(FuseOutHeader.byteCount))

        #expect(payload.leUInt32(at: 12) & FuseInitFlag.writebackCache.rawValue == FuseInitFlag.writebackCache.rawValue)
        #expect(payload.leUInt32(at: 12) & FuseInitFlag.parallelDirops.rawValue == FuseInitFlag.parallelDirops.rawValue)
    }

    @Test func initNegotiationCanAdvertiseDaxMapAlignment() throws {
        let header = FuseInHeader(
            length: UInt32(FuseInHeader.byteCount + FuseInitIn.byteCount),
            opcode: FuseOpcode.initOp.rawValue,
            unique: 0xdef,
            nodeID: 1,
            uid: 0,
            gid: 0,
            pid: 42
        )
        let request = FuseInitIn(major: 7, minor: 38, maxReadahead: 0, flags: 0)

        let response = FuseProtocol.negotiateInit(header: header, request: request, daxMapAlignmentLog2: 12)
        let payload = Array(response.dropFirst(FuseOutHeader.byteCount))

        #expect(payload.leUInt32(at: 12) & FuseInitFlag.mapAlignment.rawValue == FuseInitFlag.mapAlignment.rawValue)
        #expect(payload.leUInt16(at: 30) == 12)
    }

    @Test func initNegotiationRejectsMinorsBelowVirtiofsdFloor() throws {
        let header = FuseInHeader(
            length: UInt32(FuseInHeader.byteCount + FuseInitIn.byteCount),
            opcode: FuseOpcode.initOp.rawValue,
            unique: 99,
            nodeID: 1,
            uid: 0,
            gid: 0,
            pid: 42
        )
        let request = FuseInitIn(major: 7, minor: 26, maxReadahead: 0, flags: 0)

        let response = FuseProtocol.negotiateInit(header: header, request: request)
        let outHeader = try FuseProtocol.decodeOutHeader(response)

        #expect(outHeader.length == UInt32(FuseOutHeader.byteCount))
        #expect(outHeader.error == -FuseProtocol.eproto)
        #expect(outHeader.unique == 99)
    }

    @Test func initInRejectsShortFrames() {
        #expect(throws: FuseProtocolError.shortFrame) {
            _ = try FuseProtocol.decodeInitIn([0, 1, 2])
        }
    }

    @Test func setupMappingRoundTripsLittleEndianFields() throws {
        let request = FuseSetupMappingIn(
            fileHandle: 0x0102_0304_0506_0708,
            fileOffset: 0x1000,
            length: 0x4000,
            flags: 0x55,
            memoryOffset: 0x8000
        )

        let bytes = FuseProtocol.encodeSetupMappingIn(request)
        let decoded = try FuseProtocol.decodeSetupMappingIn(bytes)

        #expect(bytes.count == FuseSetupMappingIn.byteCount)
        #expect(bytes[0..<8].elementsEqual([8, 7, 6, 5, 4, 3, 2, 1]))
        #expect(bytes[8..<16].elementsEqual([0, 0x10, 0, 0, 0, 0, 0, 0]))
        #expect(decoded == request)
    }

    @Test func removeMappingRoundTripsMultipleMappings() throws {
        let request = FuseRemoveMappingIn(mappings: [
            FuseRemoveMappingOne(memoryOffset: 0x4000, length: 0x1000),
            FuseRemoveMappingOne(memoryOffset: 0x8000, length: 0x2000),
        ])

        let bytes = FuseProtocol.encodeRemoveMappingIn(request)
        let decoded = try FuseProtocol.decodeRemoveMappingIn(bytes)

        #expect(bytes.count == FuseRemoveMappingIn.headerByteCount + 2 * FuseRemoveMappingIn.oneByteCount)
        #expect(bytes[0..<4].elementsEqual([2, 0, 0, 0]))
        #expect(decoded == request)
    }

    @Test func mappingPayloadsRejectShortFrames() {
        #expect(throws: FuseProtocolError.shortFrame) {
            _ = try FuseProtocol.decodeSetupMappingIn([0, 1, 2])
        }
        #expect(throws: FuseProtocolError.shortFrame) {
            _ = try FuseProtocol.decodeRemoveMappingIn([1, 0, 0, 0, 0, 0, 0, 0])
        }
    }
}

private extension Array where Element == UInt8 {
    func leUInt16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func leUInt32(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }
}
