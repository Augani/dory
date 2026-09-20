import Foundation

/// Reviewed stock-Mesa Venus protocol levels. Venus clients require an exact wire-format match,
/// then clamp the renderer's newer Vulkan XML and extension protocol versions to their own level.
/// Keeping this table beside activation makes that compatibility assumption explicit and testable.
struct DoryVenusGuestProtocolProfile: Equatable, Sendable {
    let distribution: String
    let mesa: String
    let wireFormatVersion: UInt32
    let vkXMLVersion: UInt32
    let commandSerializationSpecVersion: UInt32
    let venusProtocolSpecVersion: UInt32
}

enum DoryVenusCapsetCompatibility {
    static let reviewedStockGuests: [DoryVenusGuestProtocolProfile] = [
        DoryVenusGuestProtocolProfile(
            distribution: "Ubuntu 24.04 HWE",
            mesa: "24.2.x",
            wireFormatVersion: 1,
            vkXMLVersion: vulkanVersion(major: 1, minor: 3, patch: 269),
            commandSerializationSpecVersion: 1,
            venusProtocolSpecVersion: 2
        ),
        DoryVenusGuestProtocolProfile(
            distribution: "Ubuntu 25.04",
            mesa: "25.0.x",
            wireFormatVersion: 1,
            vkXMLVersion: vulkanVersion(major: 1, minor: 3, patch: 269),
            commandSerializationSpecVersion: 1,
            venusProtocolSpecVersion: 2
        ),
        DoryVenusGuestProtocolProfile(
            distribution: "Fedora 42",
            mesa: "25.1.x",
            wireFormatVersion: 1,
            vkXMLVersion: vulkanVersion(major: 1, minor: 4, patch: 307),
            commandSerializationSpecVersion: 1,
            venusProtocolSpecVersion: 3
        ),
    ]

    // virgl_renderer_capset_venus is forty little-endian dwords through use_guest_vram.
    static let minimumCapsetByteCount = 40 * MemoryLayout<UInt32>.size

    static func accepts(_ bytes: Data) -> Bool {
        guard bytes.count >= minimumCapsetByteCount else { return false }
        let capset = Array(bytes.prefix(minimumCapsetByteCount))
        let wire = capset.leUInt32(at: 0)
        let xml = capset.leUInt32(at: 4)
        let commandSerialization = capset.leUInt32(at: 8)
        let venusProtocol = capset.leUInt32(at: 12)
        let supportsBlobIDZero = capset.leUInt32(at: 16)
        let firstExtensionMask = capset.leUInt32(at: 20)
        let allowsWaitSyncs = capset.leUInt32(at: 148)
        let supportsMultipleTimelines = capset.leUInt32(at: 152)
        let usesGuestVRAM = capset.leUInt32(at: 156)

        guard supportsBlobIDZero == 1,
              firstExtensionMask & 1 == 1,
              allowsWaitSyncs == 1,
              supportsMultipleTimelines == 1,
              usesGuestVRAM == 1 else {
            return false
        }
        return reviewedStockGuests.allSatisfy { guest in
            wire == guest.wireFormatVersion
                && xml >= guest.vkXMLVersion
                && commandSerialization >= guest.commandSerializationSpecVersion
                && venusProtocol >= guest.venusProtocolSpecVersion
        }
    }

    static func makeTestCapset(
        wireFormatVersion: UInt32 = 1,
        vkXMLVersion: UInt32 = vulkanVersion(major: 1, minor: 4, patch: 343),
        commandSerializationSpecVersion: UInt32 = 1,
        venusProtocolSpecVersion: UInt32 = 4,
        useGuestVRAM: UInt32 = 1
    ) -> Data {
        var dwords = [UInt32](repeating: 0, count: 40)
        dwords[0] = wireFormatVersion
        dwords[1] = vkXMLVersion
        dwords[2] = commandSerializationSpecVersion
        dwords[3] = venusProtocolSpecVersion
        dwords[4] = 1
        dwords[5] = 1
        dwords[37] = 1
        dwords[38] = 1
        dwords[39] = useGuestVRAM
        return dwords.withUnsafeBytes { Data($0) }
    }

    private static func vulkanVersion(major: UInt32, minor: UInt32, patch: UInt32) -> UInt32 {
        major << 22 | minor << 12 | patch
    }
}

private extension Array where Element == UInt8 {
    func leUInt32(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }
}
