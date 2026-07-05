import Testing
@testable import DoryHV

@Suite struct X86MMIODecoderTests {
    @Test func decodesByteWriteFromRegisterToMemory() throws {
        let instruction = try X86MMIODecoder.decode([0x88, 0x18])

        #expect(instruction.access == .write(register: 3, width: 1))
        #expect(instruction.length == 2)
    }

    @Test func decodesDwordWriteWithSIBAndDisplacement() throws {
        let instruction = try X86MMIODecoder.decode([
            0x89, 0x94, 0x88, 0x78, 0x56, 0x34, 0x12,
        ])

        #expect(instruction.access == .write(register: 2, width: 4))
        #expect(instruction.length == 7)
    }

    @Test func decodesRexWideReadIntoExtendedRegister() throws {
        let instruction = try X86MMIODecoder.decode([0x4C, 0x8B, 0x03])

        #expect(instruction.access == .read(register: 8, width: 8, signExtend: false, destinationWidth: 8))
        #expect(instruction.length == 3)
    }

    @Test func decodesOperandSizeOverrideWordRead() throws {
        let instruction = try X86MMIODecoder.decode([0x66, 0x8B, 0x43, 0x10])

        #expect(instruction.access == .read(register: 0, width: 2, signExtend: false, destinationWidth: 2))
        #expect(instruction.length == 4)
    }

    @Test func decodesImmediateWriteToMemory() throws {
        let byte = try X86MMIODecoder.decode([0xC6, 0x05, 0x44, 0x33, 0x22, 0x11, 0x7F])
        let dword = try X86MMIODecoder.decode([0xC7, 0x40, 0x04, 0xEF, 0xBE, 0xAD, 0xDE])

        #expect(byte.access == .writeImmediate(value: 0x7F, width: 1))
        #expect(byte.length == 7)
        #expect(dword.access == .writeImmediate(value: 0xDEAD_BEEF, width: 4))
        #expect(dword.length == 7)
    }

    @Test func signExtendsImm32ForQwordWrite() throws {
        let negative = try X86MMIODecoder.decode([0x48, 0xC7, 0x40, 0x08, 0xFF, 0xFF, 0xFF, 0xFF])
        let positive = try X86MMIODecoder.decode([0x48, 0xC7, 0x00, 0xEF, 0xBE, 0xAD, 0x7E])

        #expect(negative.access == .writeImmediate(value: 0xFFFF_FFFF_FFFF_FFFF, width: 8))
        #expect(negative.length == 8)
        #expect(positive.access == .writeImmediate(value: 0x7EAD_BEEF, width: 8))
        #expect(positive.length == 7)
    }

    @Test func decodesMovzxAndMovsxMemoryReads() throws {
        let zeroExtend = try X86MMIODecoder.decode([0x0F, 0xB7, 0x0D, 0x04, 0x03, 0x02, 0x01])
        let signExtend = try X86MMIODecoder.decode([0x0F, 0xBE, 0x54, 0x24, 0x08])

        #expect(zeroExtend.access == .read(register: 1, width: 2, signExtend: false, destinationWidth: 4))
        #expect(zeroExtend.length == 7)
        #expect(signExtend.access == .read(register: 2, width: 1, signExtend: true, destinationWidth: 4))
        #expect(signExtend.length == 5)
    }

    @Test func rejectsRegisterOnlyAddressing() {
        #expect(throws: X86MMIODecodeError.registerAddressing) {
            _ = try X86MMIODecoder.decode([0x8B, 0xC1])
        }
    }

    @Test func rejectsUnsupportedOpcodeWithDiagnostic() {
        #expect(throws: X86MMIODecodeError.unsupportedOpcode([0xA1])) {
            _ = try X86MMIODecoder.decode([0xA1, 0, 0, 0, 0])
        }
    }

    @Test func rejectsTruncatedAddressingForms() {
        #expect(throws: X86MMIODecodeError.truncated("SIB")) {
            _ = try X86MMIODecoder.decode([0x8B, 0x04])
        }
        #expect(throws: X86MMIODecodeError.truncated("displacement")) {
            _ = try X86MMIODecoder.decode([0x8B, 0x05, 0x01])
        }
    }
}
