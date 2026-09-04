import DoryDBTX86
import Foundation
import Testing

@testable import DoryMachinePC

@Suite struct DoryPCPortIOTests {
  @Test func routesInterpreterPortIOIntoTheUART() throws {
    let bus = DoryPCPortIOBus()
    let uart = DoryPCUART16550()
    try bus.attach(uart)
    bus.seal()
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: [0xEE])
    var state = try DoryX86ArchitecturalState(
      registers: .init(rax: UInt64(UInt8(ascii: "D")), rdx: 0x3F8),
      rip: 0x1000,
      cs: .init(selector: 0x08, attributes: 0xC09B, limit: .max),
      control: .init(cr0: 0x21)
    )

    let result = DoryX86Interpreter().step(
      state: &state,
      memory: memory,
      mode: .protected32,
      ioBus: bus
    )

    guard case .retired = result else {
      Issue.record("expected OUT DX, AL to retire")
      return
    }
    #expect(uart.drainTransmittedBytes() == [UInt8(ascii: "D")])
  }

  @Test func supportsDivisorLatchReceiveAndLineStatus() throws {
    let uart = DoryPCUART16550(queueCapacity: 8)
    try uart.write(portOffset: 3, value: 0x80, width: .byte)
    try uart.write(portOffset: 0, value: 0x34, width: .byte)
    try uart.write(portOffset: 1, value: 0x12, width: .byte)
    #expect(try uart.read(portOffset: 0, width: .byte) == 0x34)
    #expect(try uart.read(portOffset: 1, width: .byte) == 0x12)

    try uart.write(portOffset: 3, value: 0x03, width: .byte)
    uart.enqueueReceivedBytes([0x41])
    #expect(try uart.read(portOffset: 5, width: .byte) == 0x61)
    #expect(try uart.read(portOffset: 0, width: .byte) == 0x41)
    #expect(try uart.read(portOffset: 5, width: .byte) == 0x60)
  }

  @Test func sealsMappingsRejectsOverlapAndBoundsQueues() throws {
    let bus = DoryPCPortIOBus()
    let uart = DoryPCUART16550(queueCapacity: 2)
    try bus.attach(uart)
    #expect(throws: DoryPCPortIOError.overlappingRange(base: 0x3F8, count: 8)) {
      try bus.attach(DoryPCUART16550())
    }
    bus.seal()
    #expect(throws: DoryPCPortIOError.sealed) {
      try bus.attach(DoryPCUART16550(basePort: 0x2F8))
    }
    uart.enqueueReceivedBytes([1, 2, 3])
    try uart.write(portOffset: 0, value: 4, width: .byte)
    try uart.write(portOffset: 0, value: 5, width: .byte)
    try uart.write(portOffset: 0, value: 6, width: .byte)
    #expect(uart.dropCounts.received == 1)
    #expect(uart.dropCounts.transmitted == 1)
  }

  @Test func unclaimedPortsBehaveAsAnOpenBus() throws {
    let bus = DoryPCPortIOBus()
    bus.seal()

    #expect(try bus.read(port: 0x2FF, width: .byte) == 0xFF)
    #expect(try bus.read(port: 0x2FF, width: .word) == 0xFFFF)
    #expect(try bus.read(port: 0x2FF, width: .doubleword) == 0xFFFF_FFFF)
    try bus.write(port: 0x2FF, value: 0x5A, width: .byte)
    #expect(try bus.read(port: 0x2FF, width: .byte) == 0xFF)
  }

  @Test func receiveInterruptTracksTheEnabledFIFOLevel() throws {
    let levels = LockedLevels()
    let uart = DoryPCUART16550()
    uart.connectInterruptSink { levels.append($0) }
    try uart.write(portOffset: 1, value: 1, width: .byte)
    uart.enqueueReceivedBytes([0x41, 0x42])
    _ = try uart.read(portOffset: 0, width: .byte)
    _ = try uart.read(portOffset: 0, width: .byte)

    #expect(levels.values == [false, true, false])
  }

  @Test func machineRoutesUARTReceiveInterruptToLegacyIRQ4() throws {
    let machine = try DoryPCDirectKernelMachine(memoryBytes: 2 * 1024 * 1024)
    try machine.serial.write(portOffset: 1, value: 1, width: .byte)
    machine.serial.enqueueReceivedBytes([0x41])

    #expect(machine.legacyPIC.snapshot().masterRequest & (1 << 4) != 0)
  }
}

private final class LockedLevels: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [Bool] = []
  var values: [Bool] { lock.withLock { storage } }
  func append(_ value: Bool) { lock.withLock { storage.append(value) } }
}
