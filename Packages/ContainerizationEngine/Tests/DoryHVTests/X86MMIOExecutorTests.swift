import Testing
@testable import DoryHV

@Suite struct X86MMIOExecutorTests {
    private final class StubDevice: MMIODevice {
        let baseAddress: UInt64
        let size: UInt64
        var readValue: UInt64
        var writes: [(offset: UInt64, value: UInt64, width: Int)] = []

        init(baseAddress: UInt64 = 0xD000_0000, size: UInt64 = 0x1000, readValue: UInt64 = 0) {
            self.baseAddress = baseAddress
            self.size = size
            self.readValue = readValue
        }

        func read(offset: UInt64, width: Int) -> UInt64 {
            readValue
        }

        func write(offset: UInt64, value: UInt64, width: Int) {
            writes.append((offset, value, width))
        }
    }

    @Test func readExecutesDeviceReadAndZeroExtendsDwordRegisterWrite() throws {
        let bus = MMIOBus()
        let device = StubDevice(readValue: 0xFFFF_FFFF_CAFE_BEEF)
        bus.attach(device)
        var registers = X86RegisterState()
        registers.write(0, value: 0xDEAD_BEEF_DEAD_BEEF, width: 8)

        let advanced = try X86MMIOExecutor.execute(
            instruction: X86MMIOInstruction(access: .read(register: 0, width: 4, signExtend: false, destinationWidth: 4), length: 3),
            physicalAddress: 0xD000_0040,
            bus: bus,
            registers: &registers
        )

        #expect(advanced == 3)
        #expect(registers.read(0) == 0xCAFE_BEEF)
    }

    @Test func readExecutesSignedByteReadIntoDwordRegister() throws {
        let bus = MMIOBus()
        let device = StubDevice(readValue: 0x80)
        bus.attach(device)
        var registers = X86RegisterState()

        _ = try X86MMIOExecutor.execute(
            instruction: X86MMIOInstruction(access: .read(register: 2, width: 1, signExtend: true, destinationWidth: 4), length: 5),
            physicalAddress: 0xD000_0008,
            bus: bus,
            registers: &registers
        )

        #expect(registers.read(2) == 0xFFFF_FF80)
    }

    @Test func registerWriteMasksValueToAccessWidth() throws {
        let bus = MMIOBus()
        let device = StubDevice()
        bus.attach(device)
        var registers = X86RegisterState()
        registers.write(3, value: 0x1234_5678_ABCD_EF42, width: 8)

        _ = try X86MMIOExecutor.execute(
            instruction: X86MMIOInstruction(access: .write(register: 3, width: 2), length: 2),
            physicalAddress: 0xD000_0002,
            bus: bus,
            registers: &registers
        )

        #expect(device.writes.count == 1)
        #expect(device.writes[0].offset == 2)
        #expect(device.writes[0].value == 0xEF42)
        #expect(device.writes[0].width == 2)
    }

    @Test func immediateWriteMasksToAccessWidth() throws {
        let bus = MMIOBus()
        let device = StubDevice()
        bus.attach(device)
        var registers = X86RegisterState()

        _ = try X86MMIOExecutor.execute(
            instruction: X86MMIOInstruction(access: .writeImmediate(value: 0x1FF, width: 1), length: 7),
            physicalAddress: 0xD000_0004,
            bus: bus,
            registers: &registers
        )

        #expect(device.writes.first?.value == 0xFF)
        #expect(device.writes.first?.width == 1)
    }

    @Test func byteAndWordRegisterWritesPreserveUpperBits() {
        var registers = X86RegisterState()
        registers.write(1, value: 0xAAAA_BBBB_CCCC_DDDD, width: 8)
        registers.write(1, value: 0x12, width: 1)
        #expect(registers.read(1) == 0xAAAA_BBBB_CCCC_DD12)

        registers.write(1, value: 0x3456, width: 2)
        #expect(registers.read(1) == 0xAAAA_BBBB_CCCC_3456)
    }

    @Test func unmappedPhysicalAddressThrows() throws {
        let bus = MMIOBus()
        var registers = X86RegisterState()

        #expect(throws: X86MMIOExecutionError.unmappedPhysicalAddress(0xE000_0000)) {
            _ = try X86MMIOExecutor.execute(
                instruction: X86MMIOInstruction(access: .writeImmediate(value: 1, width: 4), length: 6),
                physicalAddress: 0xE000_0000,
                bus: bus,
                registers: &registers
            )
        }
    }
}
