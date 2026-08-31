import DoryDBTX86
import Foundation
import Testing

@testable import DoryMachinePC

@Suite struct DoryPCLegacyInterruptTests {
  @Test func picRemapsMasksCascadesAndAcknowledgesInPriorityOrder() throws {
    let pair = DoryPCPIC8259Pair()
    let master = DoryPCPIC8259Port(pair: pair, slave: false)
    let slave = DoryPCPIC8259Port(pair: pair, slave: true)
    try initialize(master, offset: 0x20, cascade: 4)
    try initialize(slave, offset: 0x28, cascade: 2)
    try master.write(portOffset: 1, value: 0xF8, width: .byte)
    try slave.write(portOffset: 1, value: 0xFD, width: .byte)

    try pair.raise(irq: 1)
    try pair.raise(irq: 9)
    #expect(pair.acknowledge(interruptsEnabled: true) == 0x21)
    try master.write(portOffset: 0, value: 0x20, width: .byte)
    #expect(pair.acknowledge(interruptsEnabled: true) == 0x29)
    try slave.write(portOffset: 0, value: 0x20, width: .byte)
    try master.write(portOffset: 0, value: 0x20, width: .byte)

    let snapshot = pair.snapshot()
    #expect(snapshot.masterVectorOffset == 0x20)
    #expect(snapshot.slaveVectorOffset == 0x28)
    #expect(snapshot.masterInService == 0)
    #expect(snapshot.slaveInService == 0)
  }

  @Test func pitProgramsPeriodicCounterAndCoalescesElapsedClocks() throws {
    let counter = LockedCounter()
    let pit = DoryPCPIT8254 { counter.increment() }
    try pit.write(portOffset: 3, value: 0x34, width: .byte)
    try pit.write(portOffset: 0, value: 10, width: .byte)
    try pit.write(portOffset: 0, value: 0, width: .byte)

    pit.advance(by: 26)

    let snapshot = pit.snapshot()
    #expect(snapshot.mode == .rateGenerator)
    #expect(snapshot.reload == 10)
    #expect(snapshot.current == 4)
    #expect(counter.value == 1)
  }

  @Test func picPredictsCascadedPriorityAcceptance() throws {
    let pair = DoryPCPIC8259Pair()
    let master = DoryPCPIC8259Port(pair: pair, slave: false)
    let slave = DoryPCPIC8259Port(pair: pair, slave: true)
    try initialize(master, offset: 0x20, cascade: 4)
    try initialize(slave, offset: 0x28, cascade: 2)
    try master.write(portOffset: 1, value: 0xFA, width: .byte)
    try slave.write(portOffset: 1, value: 0xFE, width: .byte)

    #expect(pair.canAccept(irq: 0, interruptsEnabled: true))
    #expect(pair.canAccept(irq: 8, interruptsEnabled: true))
    #expect(!pair.canAccept(irq: 1, interruptsEnabled: true))
    #expect(!pair.canAccept(irq: 8, interruptsEnabled: false))

    try pair.raise(irq: 0)
    #expect(pair.acknowledge(interruptsEnabled: true) == 0x20)
    #expect(!pair.canAccept(irq: 8, interruptsEnabled: true))
  }

  @Test func pitOneShotDisarmsAtTerminalCount() throws {
    let counter = LockedCounter()
    let pit = DoryPCPIT8254 { counter.increment() }
    try pit.write(portOffset: 3, value: 0x30, width: .byte)
    try pit.write(portOffset: 0, value: 2, width: .byte)
    try pit.write(portOffset: 0, value: 0, width: .byte)

    pit.advance(by: 2)
    pit.advance(by: 100)

    #expect(counter.value == 1)
    #expect(!pit.snapshot().armed)
  }

  @Test func systemControlPortDrivesAndReportsPITChannel2() throws {
    let pit = DoryPCPIT8254 {}
    let systemControl = DoryPCSystemControlPortB(pit: pit)

    // Gate channel 2 off, select channel 2 / low-high / mode 0, and load a three-clock count.
    try systemControl.write(portOffset: 0, value: 0, width: .byte)
    try pit.write(portOffset: 3, value: 0xB0, width: .byte)
    try pit.write(portOffset: 2, value: 3, width: .byte)
    try pit.write(portOffset: 2, value: 0, width: .byte)
    pit.advance(by: 10)
    #expect(try systemControl.read(portOffset: 0, width: .byte) & 0x20 == 0)

    try systemControl.write(portOffset: 0, value: 3, width: .byte)
    #expect(try systemControl.read(portOffset: 0, width: .byte) & 0x03 == 3)
    pit.advance(by: 2)
    #expect(try systemControl.read(portOffset: 0, width: .byte) & 0x20 == 0)
    pit.advance(by: 1)
    #expect(try systemControl.read(portOffset: 0, width: .byte) & 0x20 != 0)
  }

  private func initialize(
    _ port: DoryPCPIC8259Port,
    offset: UInt8,
    cascade: UInt8
  ) throws {
    try port.write(portOffset: 0, value: 0x11, width: .byte)
    try port.write(portOffset: 1, value: UInt32(offset), width: .byte)
    try port.write(portOffset: 1, value: UInt32(cascade), width: .byte)
    try port.write(portOffset: 1, value: 1, width: .byte)
  }
}

private final class LockedCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var value: Int { lock.withLock { count } }
  func increment() { lock.withLock { count += 1 } }
}
