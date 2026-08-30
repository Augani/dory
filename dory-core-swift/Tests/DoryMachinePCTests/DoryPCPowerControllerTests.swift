import DoryDBTX86
import DoryMachinePC
import Foundation
import Testing

@Suite struct DoryPCPowerControllerTests {
  @Test func softOffRequiresThePublishedSleepTypeAndEnableBit() throws {
    let controller = DoryPCPowerController()
    let port = DoryPCACPIPMControlPort(controller: controller)

    try port.write(portOffset: 0, value: 4 << 10 | 1 << 13, width: .word)
    #expect(controller.consumeRequestedAction() == nil)
    try port.write(
      portOffset: 0,
      value: UInt32(DoryPCPowerController.softOffSleepType << 10 | 1 << 13),
      width: .word
    )

    #expect(controller.consumeRequestedAction() == .powerOff)
    #expect(try port.read(portOffset: 0, width: .word) & (1 << 13) == 0)
  }

  @Test func resetPortAcceptsOnlyTheFADTResetValue() throws {
    let controller = DoryPCPowerController()
    let port = DoryPCResetControlPort(controller: controller)
    try port.write(portOffset: 0, value: 4, width: .byte)
    #expect(controller.consumeRequestedAction() == nil)
    try port.write(
      portOffset: 0,
      value: UInt32(DoryPCPowerController.resetValue),
      width: .byte
    )
    #expect(controller.consumeRequestedAction() == .reset)
  }

  @Test func machineReportsGuestPowerActionsAsTerminalStops() throws {
    let powerOff = try DoryPCDirectKernelMachine(memoryBytes: 2 * 1024 * 1024)
    try powerOff.ioBus.write(
      port: DoryPCPowerController.pm1ControlPort,
      value: UInt32(DoryPCPowerController.softOffSleepType << 10 | 1 << 13),
      width: .word
    )
    try powerOff.load(kernel: makeMinimalELF())
    #expect(try powerOff.run(maximumInstructions: 1) == .poweredOff(instructionCount: 0))

    let reset = try DoryPCDirectKernelMachine(memoryBytes: 2 * 1024 * 1024)
    try reset.ioBus.write(
      port: DoryPCPowerController.resetPort,
      value: UInt32(DoryPCPowerController.resetValue),
      width: .byte
    )
    try reset.load(kernel: makeMinimalELF())
    #expect(try reset.run(maximumInstructions: 1) == .reset(instructionCount: 0))
  }
}

private func makeMinimalELF() -> Data {
  let segmentOffset = 0x200
  var data = Data(repeating: 0, count: segmentOffset + 1)
  data.replaceSubrange(0..<4, with: [0x7F, 0x45, 0x4C, 0x46])
  data[4] = 2
  data[5] = 1
  data[6] = 1
  write(UInt16(0x3E), to: &data, at: 18)
  write(UInt64(0x40), to: &data, at: 32)
  write(UInt16(56), to: &data, at: 54)
  write(UInt16(2), to: &data, at: 56)
  write(UInt32(1), to: &data, at: 0x40)
  write(UInt64(segmentOffset), to: &data, at: 0x48)
  write(UInt64(0x10_0000), to: &data, at: 0x58)
  write(UInt64(1), to: &data, at: 0x60)
  write(UInt64(1), to: &data, at: 0x68)
  write(UInt32(4), to: &data, at: 0x78)
  write(UInt64(0x180), to: &data, at: 0x80)
  write(UInt64(20), to: &data, at: 0x98)
  data.replaceSubrange(
    0x180..<0x194,
    with: [
      4, 0, 0, 0, 4, 0, 0, 0, 0x12, 0, 0, 0, 0x58, 0x65, 0x6E, 0,
      0, 0x00, 0x10, 0,
    ])
  data[segmentOffset] = 0xF4
  return data
}

private func write<T: FixedWidthInteger>(_ value: T, to data: inout Data, at offset: Int) {
  for index in 0..<MemoryLayout<T>.size {
    data[offset + index] = UInt8(truncatingIfNeeded: value >> T(index * 8))
  }
}
