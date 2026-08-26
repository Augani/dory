import CryptoKit
import Foundation
import Testing
@testable import DoryHV

@Suite struct VirtioMMIOSlotOwnershipTests {
    private final class Device: MMIODevice {
        let baseAddress: UInt64
        let size: UInt64

        init(slot: Int, baseAddress: UInt64 = GuestLayout.virtioBase, size: UInt64 = GuestLayout.virtioSlotSize) {
            self.baseAddress = baseAddress + UInt64(slot) * GuestLayout.virtioSlotSize
            self.size = size
        }

        func read(offset: UInt64, width: Int) -> UInt64 { 0 }
        func write(offset: UInt64, value: UInt64, width: Int) {}
    }

    private func ownership() -> VirtioMMIOSlotOwnership {
        VirtioMMIOSlotOwnership(
            maximumSlots: GuestLayout.virtioSlotCount,
            baseAddress: GuestLayout.virtioBase,
            slotSize: GuestLayout.virtioSlotSize,
            firstInterrupt: GuestLayout.virtioFirstIRQ
        )
    }

    @Test func rejectsDuplicateOutOfRangeAndMismatchedAttachmentsBeforeBusMutation() throws {
        let slots = ownership()
        var attached = [ObjectIdentifier]()
        let first = Device(slot: 4)

        let identity = try slots.attach(first, at: 4) {
            attached.append(ObjectIdentifier($0))
        }
        #expect(identity.slot == 4)
        #expect(attached == [ObjectIdentifier(first)])

        #expect(throws: VMError.self) {
            try slots.attach(Device(slot: 4), at: 4) {
                attached.append(ObjectIdentifier($0))
            }
        }
        #expect(throws: VMError.self) {
            try slots.attach(Device(slot: 0), at: -1) {
                attached.append(ObjectIdentifier($0))
            }
        }
        #expect(throws: VMError.self) {
            try slots.attach(Device(slot: GuestLayout.virtioSlotCount), at: GuestLayout.virtioSlotCount) {
                attached.append(ObjectIdentifier($0))
            }
        }
        #expect(throws: VMError.self) {
            try slots.attach(Device(slot: 3), at: 2) {
                attached.append(ObjectIdentifier($0))
            }
        }
        #expect(throws: VMError.self) {
            try slots.attach(Device(slot: 2, size: GuestLayout.virtioSlotSize / 2), at: 2) {
                attached.append(ObjectIdentifier($0))
            }
        }

        #expect(attached == [ObjectIdentifier(first)])
        #expect(slots.identities == [identity])
    }

    @Test func removingOptionalSlotPreservesLaterMMIOIRQAndGoldenDTBNode() throws {
        let complete = ownership()
        for slot in [7, 1, 4] {
            try complete.attach(Device(slot: slot), at: slot) { _ in }
        }

        let withoutOptional = ownership()
        for slot in [7, 1] {
            try withoutOptional.attach(Device(slot: slot), at: slot) { _ in }
        }

        #expect(complete.identities.map(\.slot) == [1, 4, 7])
        #expect(withoutOptional.identities.map(\.slot) == [1, 7])
        let completeLater = try #require(complete.identities.first(where: { $0.slot == 7 }))
        let reducedLater = try #require(withoutOptional.identities.first(where: { $0.slot == 7 }))
        #expect(completeLater == reducedLater)
        #expect(reducedLater.baseAddress == GuestLayout.virtioBase + 7 * GuestLayout.virtioSlotSize)
        #expect(reducedLater.interrupt == GuestLayout.virtioFirstIRQ + 7)

        let blob = deviceTreeFixture(identities: withoutOptional.identities)
        let firstNode = try #require(offset(of: "virtio_mmio@c100200", in: blob))
        let laterNode = try #require(offset(of: "virtio_mmio@c100e00", in: blob))
        #expect(firstNode < laterNode)
        #expect(offset(of: "virtio_mmio@c100800", in: blob) == nil)
        // A dense two-device rebuild would incorrectly move slot 7 to physical slot 1 or 2.
        #expect(offset(of: "virtio_mmio@c100400", in: blob) == nil)
        #expect(sha256Hex(blob) == "b9059c38679db69abbec79af8a4dc2d5eb076c14d659586843964066b3e0891c")
    }

    @Test func attachmentOrderDoesNotChangeCanonicalFingerprintInput() throws {
        let forward = ownership()
        for slot in [1, 4, 7] {
            try forward.attach(Device(slot: slot), at: slot) { _ in }
        }
        let reverse = ownership()
        for slot in [7, 4, 1] {
            try reverse.attach(Device(slot: slot), at: slot) { _ in }
        }

        #expect(forward.identities == reverse.identities)
        #expect(forward.fingerprintInput == reverse.fingerprintInput)
        #expect(
            hex(forward.fingerprintInput)
                == "646f72792e76697274696f2d6d6d696f2e6c61796f757400000000010000000300000001000000000c10020000000000000002000000001100000004000000000c10080000000000000002000000001400000007000000000c100e00000000000000020000000017"
        )
    }

    @Test func x86SparseBootPlanUsesActualSlotsInDeterministicOrder() {
        let slot1 = X86VirtioMMIODevice(
            slot: 1,
            baseAddress: X86GuestLayout.virtioBase + X86GuestLayout.virtioSlotSize,
            size: X86GuestLayout.virtioSlotSize,
            irq: X86GuestLayout.virtioFirstIRQ + 1
        )
        let slot7 = X86VirtioMMIODevice(
            slot: 7,
            baseAddress: X86GuestLayout.virtioBase + 7 * X86GuestLayout.virtioSlotSize,
            size: X86GuestLayout.virtioSlotSize,
            irq: X86GuestLayout.virtioFirstIRQ + 7
        )
        let plan = X86BootPlanBuilder.build(
            memoryBytes: 512 * 1_024 * 1_024,
            virtioDevices: [slot7, slot1]
        )

        #expect(plan.virtioDevices.map(\.slot) == [1, 7])
        #expect(plan.virtioDevices.map(\.irq) == [17, 23])
        #expect(plan.commandLine.contains("virtio_mmio.device=4096@0xd0001000:17"))
        #expect(plan.commandLine.contains("virtio_mmio.device=4096@0xd0007000:23"))
        #expect(!plan.commandLine.contains("virtio_mmio.device=4096@0xd0000000:16"))
    }

    private func deviceTreeFixture(identities: [VirtioMMIOSlotIdentity]) -> [UInt8] {
        let fdt = FDTBuilder()
        fdt.beginNode("")
        fdt.property("#address-cells", cells: [2])
        fdt.property("#size-cells", cells: [2])
        VirtioMMIODeviceTree.appendNodes(for: identities, to: fdt)
        fdt.endNode()
        return fdt.finish()
    }

    private func offset(of string: String, in bytes: [UInt8]) -> Int? {
        let needle = Array(string.utf8) + [0]
        guard needle.count <= bytes.count else { return nil }
        return (0...(bytes.count - needle.count)).first { start in
            bytes[start..<(start + needle.count)].elementsEqual(needle)
        }
    }

    private func sha256Hex(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
