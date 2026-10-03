import Foundation

/// One synthetic EDID 1.4 base block shared by the ARM MMIO and PC PCI GPU devices.
/// The preferred timing and physical size follow the current app-owned display surface.
public enum DoryVirtioGPUSyntheticEDID {
  public static func make(
    scanoutID: UInt32,
    width: UInt32,
    height: UInt32,
    physicalWidthMillimeters: UInt16,
    physicalHeightMillimeters: UInt16
  ) -> [UInt8] {
    var edid = [UInt8](repeating: 0, count: 128)
    edid[0..<8] = [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]
    // EISA manufacturer code "DOR", stored most-significant byte first.
    edid[8] = 0x11
    edid[9] = 0xF2
    edid[10] = UInt8(truncatingIfNeeded: scanoutID &+ 1)
    edid[11] = UInt8(truncatingIfNeeded: (scanoutID &+ 1) >> 8)
    edid[12] = UInt8(truncatingIfNeeded: scanoutID)
    edid[13] = UInt8(truncatingIfNeeded: scanoutID >> 8)
    edid[14] = UInt8(truncatingIfNeeded: scanoutID >> 16)
    edid[15] = UInt8(truncatingIfNeeded: scanoutID >> 24)
    edid[16] = 1
    edid[17] = 36 // 2026 - 1990
    edid[18] = 1
    edid[19] = 4
    edid[20] = 0x80
    edid[21] = UInt8(clamping: max(1, Int(physicalWidthMillimeters) / 10))
    edid[22] = UInt8(clamping: max(1, Int(physicalHeightMillimeters) / 10))
    edid[23] = 120 // gamma 2.20
    edid[24] = 0x0A // standard RGB + preferred timing in descriptor 1
    for index in stride(from: 38, to: 54, by: 2) {
      edid[index] = 0x01
      edid[index + 1] = 0x01
    }

    let width = min(4_095, width)
    let height = min(4_095, height)
    let horizontalBlanking = min(4_095, UInt32(max(160, ((Int(width) / 5 + 7) / 8) * 8)))
    let verticalBlanking = min(4_095, UInt32(max(45, Int(height) / 20)))
    let horizontalSyncOffset = min(1_023, max(8, horizontalBlanking / 3))
    let horizontalSyncPulse = min(1_023, max(8, horizontalBlanking - horizontalSyncOffset * 2))
    let verticalSyncOffset: UInt32 = min(63, max(1, verticalBlanking / 4))
    let verticalSyncPulse: UInt32 = min(63, max(1, verticalBlanking / 8))
    let totalPixels = UInt64(width + horizontalBlanking) * UInt64(height + verticalBlanking)
    let pixelClock10KHz = UInt16(clamping: max(1, Int(totalPixels * 60 / 10_000)))
    let physicalWidth = UInt32(physicalWidthMillimeters)
    let physicalHeight = UInt32(physicalHeightMillimeters)
    var timing = [UInt8](repeating: 0, count: 18)
    timing[0] = UInt8(truncatingIfNeeded: pixelClock10KHz)
    timing[1] = UInt8(truncatingIfNeeded: pixelClock10KHz >> 8)
    timing[2] = UInt8(truncatingIfNeeded: width)
    timing[3] = UInt8(truncatingIfNeeded: horizontalBlanking)
    timing[4] = UInt8(((width >> 8) & 0x0F) << 4 | ((horizontalBlanking >> 8) & 0x0F))
    timing[5] = UInt8(truncatingIfNeeded: height)
    timing[6] = UInt8(truncatingIfNeeded: verticalBlanking)
    timing[7] = UInt8(((height >> 8) & 0x0F) << 4 | ((verticalBlanking >> 8) & 0x0F))
    timing[8] = UInt8(truncatingIfNeeded: horizontalSyncOffset)
    timing[9] = UInt8(truncatingIfNeeded: horizontalSyncPulse)
    timing[10] = UInt8((verticalSyncOffset & 0x0F) << 4 | (verticalSyncPulse & 0x0F))
    let horizontalOffsetHigh = ((horizontalSyncOffset >> 8) & 0x03) << 6
    let horizontalPulseHigh = ((horizontalSyncPulse >> 8) & 0x03) << 4
    let verticalOffsetHigh = ((verticalSyncOffset >> 4) & 0x03) << 2
    let verticalPulseHigh = (verticalSyncPulse >> 4) & 0x03
    timing[11] = UInt8(
      horizontalOffsetHigh | horizontalPulseHigh | verticalOffsetHigh | verticalPulseHigh
    )
    timing[12] = UInt8(truncatingIfNeeded: physicalWidth)
    timing[13] = UInt8(truncatingIfNeeded: physicalHeight)
    timing[14] = UInt8(((physicalWidth >> 8) & 0x0F) << 4 | ((physicalHeight >> 8) & 0x0F))
    timing[17] = 0x1E
    edid.replaceSubrange(54..<72, with: timing)

    var nameDescriptor = [UInt8](repeating: 0x20, count: 18)
    nameDescriptor[0..<5] = [0x00, 0x00, 0x00, 0xFC, 0x00]
    let name = Array("Dory Display\n".utf8.prefix(13))
    nameDescriptor.replaceSubrange(5..<(5 + name.count), with: name)
    edid.replaceSubrange(72..<90, with: nameDescriptor)

    var rangeDescriptor = [UInt8](repeating: 0, count: 18)
    rangeDescriptor[0..<5] = [0x00, 0x00, 0x00, 0xFD, 0x00]
    rangeDescriptor[5] = 48
    rangeDescriptor[6] = 60
    rangeDescriptor[7] = 30
    rangeDescriptor[8] = 160
    rangeDescriptor[9] = UInt8(clamping: max(1, Int(pixelClock10KHz) / 1_000))
    edid.replaceSubrange(90..<108, with: rangeDescriptor)

    var serialDescriptor = [UInt8](repeating: 0x20, count: 18)
    serialDescriptor[0..<5] = [0x00, 0x00, 0x00, 0xFF, 0x00]
    let serial = Array(String(format: "DORY-%02u\n", scanoutID).utf8.prefix(13))
    serialDescriptor.replaceSubrange(5..<(5 + serial.count), with: serial)
    edid.replaceSubrange(108..<126, with: serialDescriptor)
    edid[126] = 0
    edid[127] = UInt8(truncatingIfNeeded: 0 &- edid[0..<127].reduce(0) {
      $0 &+ UInt32($1)
    })
    return edid
  }
}
