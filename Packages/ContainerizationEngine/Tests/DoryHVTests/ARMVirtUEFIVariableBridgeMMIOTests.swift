#if arch(arm64)
import DoryFirmware
import Foundation
import Testing

@testable import DoryHV

@Suite struct ARMVirtUEFIVariableBridgeMMIOTests {
    @Test func exposesIdentityAndPersistsMailboxCommands() throws {
        let fixture = try BridgeFixture()
        defer { fixture.remove() }
        let device = try ARMVirtUEFIVariableBridgeMMIO(store: fixture.store)

        #expect(device.baseAddress == DoryUEFIVariableBridgeV1ABI.baseAddress)
        #expect(device.size == DoryUEFIVariableBridgeV1ABI.byteCount)
        #expect(device.read(offset: DoryUEFIVariableBridgeV1ABI.magicOffset, width: 8)
            == DoryUEFIVariableBridgeV1ABI.magic)
        #expect(device.read(offset: DoryUEFIVariableBridgeV1ABI.versionOffset, width: 4)
            == DoryUEFIVariableBridgeV1ABI.version)

        let vendor = UUID(uuidString: "12345678-1234-5678-90ab-cdef12345678")!
        write(bytes(of: vendor), at: DoryUEFIVariableBridgeV1ABI.vendorOffset, to: device)
        write(Array("BootOrder".utf8), at: DoryUEFIVariableBridgeV1ABI.nameOffset, to: device)
        write([0, 1, 2, 3], at: DoryUEFIVariableBridgeV1ABI.dataOffset, to: device)
        device.write(
            offset: DoryUEFIVariableBridgeV1ABI.nameLengthOffset,
            value: UInt64("BootOrder".utf8.count),
            width: 4
        )
        device.write(offset: DoryUEFIVariableBridgeV1ABI.dataLengthOffset, value: 4, width: 4)
        device.write(
            offset: DoryUEFIVariableBridgeV1ABI.attributesOffset,
            value: UInt64(
                DoryUEFIVariableAttributes([.nonVolatile, .bootServiceAccess]).rawValue
            ),
            width: 4
        )
        device.write(
            offset: DoryUEFIVariableBridgeV1ABI.commandOffset,
            value: UInt64(DoryUEFIVariableBridgeCommand.set.rawValue),
            width: 4
        )

        #expect(status(device) == .success)
        #expect(device.read(offset: DoryUEFIVariableBridgeV1ABI.generationOffset, width: 8) == 2)
        let persisted = try fixture.store.load().snapshot
        let key = try DoryUEFIVariableKey(vendor: vendor, name: "BootOrder")
        #expect(persisted.variable(for: key)?.data == Data([0, 1, 2, 3]))

        write(bytes(of: vendor), at: DoryUEFIVariableBridgeV1ABI.vendorOffset, to: device)
        write(Array("BootOrder".utf8), at: DoryUEFIVariableBridgeV1ABI.nameOffset, to: device)
        device.write(
            offset: DoryUEFIVariableBridgeV1ABI.nameLengthOffset,
            value: UInt64("BootOrder".utf8.count),
            width: 4
        )
        device.write(
            offset: DoryUEFIVariableBridgeV1ABI.commandOffset,
            value: UInt64(DoryUEFIVariableBridgeCommand.get.rawValue),
            width: 4
        )
        #expect(status(device) == .success)
        #expect(device.read(offset: DoryUEFIVariableBridgeV1ABI.dataLengthOffset, width: 4) == 4)
        #expect(read(count: 4, at: DoryUEFIVariableBridgeV1ABI.dataOffset, from: device)
            == [0, 1, 2, 3])
    }

    @Test func rejectsMalformedCommandsAndIgnoresReadOnlyWrites() throws {
        let fixture = try BridgeFixture()
        defer { fixture.remove() }
        let device = try ARMVirtUEFIVariableBridgeMMIO(store: fixture.store)

        device.write(offset: DoryUEFIVariableBridgeV1ABI.magicOffset, value: 0, width: 8)
        #expect(device.read(offset: DoryUEFIVariableBridgeV1ABI.magicOffset, width: 8)
            == DoryUEFIVariableBridgeV1ABI.magic)
        device.write(
            offset: DoryUEFIVariableBridgeV1ABI.nameLengthOffset,
            value: UInt64(DoryUEFIVariableBridgeV1ABI.nameByteCount + 1),
            width: 4
        )
        device.write(
            offset: DoryUEFIVariableBridgeV1ABI.commandOffset,
            value: UInt64(DoryUEFIVariableBridgeCommand.get.rawValue),
            width: 4
        )
        #expect(status(device) == .invalidRequest)
        device.write(offset: DoryUEFIVariableBridgeV1ABI.commandOffset, value: 0xffff, width: 4)
        #expect(status(device) == .invalidRequest)
        #expect(device.read(offset: DoryUEFIVariableBridgeV1ABI.statusOffset, width: 2) == 0)
    }

    private func status(
        _ device: ARMVirtUEFIVariableBridgeMMIO
    ) -> DoryUEFIVariableBridgeStatus? {
        DoryUEFIVariableBridgeStatus(rawValue: UInt32(device.read(
            offset: DoryUEFIVariableBridgeV1ABI.statusOffset,
            width: 4
        )))
    }

    private func write(
        _ bytes: [UInt8],
        at offset: UInt64,
        to device: ARMVirtUEFIVariableBridgeMMIO
    ) {
        for (index, byte) in bytes.enumerated() {
            device.write(offset: offset + UInt64(index), value: UInt64(byte), width: 1)
        }
    }

    private func read(
        count: Int,
        at offset: UInt64,
        from device: ARMVirtUEFIVariableBridgeMMIO
    ) -> [UInt8] {
        (0..<count).map {
            UInt8(device.read(offset: offset + UInt64($0), width: 1))
        }
    }

    private func bytes(of uuid: UUID) -> [UInt8] {
        var raw = uuid.uuid
        return withUnsafeBytes(of: &raw) { Array($0) }
    }
}

private final class BridgeFixture {
    let directory: String
    let store: DoryUEFIVariableStoreFile

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-uefi-mmio-\(UUID().uuidString)", isDirectory: true).path
        store = try DoryUEFIVariableStoreFile(directory: directory)
        try store.initialize(DoryUEFIVariableStoreSnapshot())
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: directory)
    }
}
#endif
