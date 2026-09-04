import DoryDBTX86
import Foundation
import Testing

@testable import DoryMachinePC

// TI TL16C550D SLLS597E, IER/IIR and Table 5 (pp.35-36):
// https://www.ti.com/lit/ds/symlink/tl16c550d.pdf
// Non-FIFO THRE handshake only. Transmission completes synchronously; these
// tests do not claim baud-rate timing, FIFO, modem, or loopback qualification.
@Suite struct DoryPCUARTTransmitInterruptTests {
  @Test func emptyTransmitterInterruptAcknowledgesOnceAndReenablesExplicitly() throws {
    let uart = DoryPCUART16550()
    let levels = UARTInterruptLevels()
    uart.connectInterruptSink { levels.append($0) }
    #expect(try uart.read(portOffset: 2, width: .byte) == 1)
    try uart.write(portOffset: 1, value: 2, width: .byte)
    #expect(levels.values == [false, true])
    #expect(try uart.read(portOffset: 5, width: .byte) == 0x60)
    #expect(levels.values == [false, true]) // LSR does not acknowledge THRE.
    #expect(try uart.read(portOffset: 2, width: .byte) == 2)
    #expect(levels.values == [false, true, false])
    #expect(try uart.read(portOffset: 2, width: .byte) == 1)
    try uart.write(portOffset: 1, value: 2, width: .byte)
    #expect(try uart.read(portOffset: 2, width: .byte) == 1)
    try uart.write(portOffset: 1, value: 0, width: .byte)
    try uart.write(portOffset: 1, value: 2, width: .byte)
    #expect(levels.values == [false, true, false, true])
    try uart.write(portOffset: 1, value: 0, width: .byte)
    #expect(try uart.read(portOffset: 2, width: .byte) == 1)
    #expect(levels.values == [false, true, false, true, false])
  }

  @Test func THRWriteAcknowledgesAndReassertsEvenWithoutAnIIRRead() throws {
    let uart = DoryPCUART16550()
    let levels = UARTInterruptLevels()
    uart.connectInterruptSink { levels.append($0) }
    try uart.write(portOffset: 1, value: 2, width: .byte)
    try uart.write(portOffset: 0, value: 0x44, width: .byte)
    #expect(levels.values == [false, true, false, true])
    #expect(try uart.read(portOffset: 2, width: .byte) == 2)
    #expect(try uart.read(portOffset: 2, width: .byte) == 1)
    #expect(levels.values == [false, true, false, true, false])
    #expect(uart.drainTransmittedBytes() == [0x44])
    try uart.write(portOffset: 0, value: 0x4F, width: .byte)
    #expect(levels.values.last == true)
    #expect(try uart.read(portOffset: 2, width: .byte) == 2)
    #expect(uart.drainTransmittedBytes() == [0x4F])
  }

  @Test func receivePriorityDoesNotAcknowledgeThePendingTransmitInterrupt() throws {
    let uart = DoryPCUART16550()
    let levels = UARTInterruptLevels()
    uart.connectInterruptSink { levels.append($0) }
    try uart.write(portOffset: 1, value: 3, width: .byte)
    uart.enqueueReceivedBytes([0x41, 0x42])
    #expect(try uart.read(portOffset: 2, width: .byte) == 4)
    #expect(try uart.read(portOffset: 0, width: .byte) == 0x41)
    #expect(try uart.read(portOffset: 2, width: .byte) == 4)
    #expect(try uart.read(portOffset: 0, width: .byte) == 0x42)
    #expect(levels.values == [false, true])
    #expect(try uart.read(portOffset: 2, width: .byte) == 2)
    #expect(levels.values == [false, true, false])
    #expect(try uart.read(portOffset: 2, width: .byte) == 1)
  }

  @Test func divisorLatchAccessDoesNotTransmitOrChangeTheInterruptEnableRegister() throws {
    let uart = DoryPCUART16550()
    let levels = UARTInterruptLevels()
    uart.connectInterruptSink { levels.append($0) }
    try uart.write(portOffset: 1, value: 2, width: .byte)
    #expect(try uart.read(portOffset: 2, width: .byte) == 2)
    try uart.write(portOffset: 3, value: 0x80, width: .byte)
    try uart.write(portOffset: 0, value: 0x44, width: .byte)
    try uart.write(portOffset: 1, value: 0, width: .byte)
    try uart.write(portOffset: 1, value: 2, width: .byte)
    #expect(try uart.read(portOffset: 0, width: .byte) == 0x44)
    #expect(try uart.read(portOffset: 1, width: .byte) == 2)
    #expect(try uart.read(portOffset: 2, width: .byte) == 1)
    #expect(levels.values == [false, true, false])
    #expect(uart.drainTransmittedBytes().isEmpty)
    try uart.write(portOffset: 3, value: 3, width: .byte)
    #expect(try uart.read(portOffset: 1, width: .byte) == 2)
    try uart.write(portOffset: 0, value: 0x45, width: .byte)
    #expect(try uart.read(portOffset: 2, width: .byte) == 2)
    #expect(uart.drainTransmittedBytes() == [0x45])
  }

  @Test func captureDrainAndCapacityDoNotControlTheHardwareEmptyInterrupt() throws {
    let uart = DoryPCUART16550(queueCapacity: 2)
    try uart.write(portOffset: 1, value: 2, width: .byte)
    #expect(try uart.read(portOffset: 2, width: .byte) == 2)
    for byte: UInt32 in [0x41, 0x42, 0x43] {
      try uart.write(portOffset: 0, value: byte, width: .byte)
      #expect(try uart.read(portOffset: 2, width: .byte) == 2)
      #expect(try uart.read(portOffset: 2, width: .byte) == 1)
    }
    #expect(uart.dropCounts.transmitted == 1)
    #expect(uart.drainTransmittedBytes(maximumCount: 1) == [0x41])
    #expect(try uart.read(portOffset: 2, width: .byte) == 1)
    #expect(uart.drainTransmittedBytes() == [0x42])
    #expect(try uart.read(portOffset: 2, width: .byte) == 1)
    #expect(try uart.read(portOffset: 5, width: .byte) == 0x60)
  }

  @Test func polledConsoleOutputStillWorksWithInterruptsDisabled() throws {
    let uart = DoryPCUART16550()
    let levels = UARTInterruptLevels()
    uart.connectInterruptSink { levels.append($0) }
    let message = Array("kernel printk through a polled UART\r\n".utf8)
    for byte in message {
      #expect(try uart.read(portOffset: 5, width: .byte) & 0x20 != 0)
      try uart.write(portOffset: 0, value: UInt32(byte), width: .byte)
    }
    #expect(uart.drainTransmittedBytes() == message)
    #expect(levels.values == [false])
    #expect(try uart.read(portOffset: 2, width: .byte) == 1)
  }

  @Test func completeMessageTransmitsOneBytePerIRQThroughPICAndIOAPIC() throws {
    let machine = try DoryPCDirectKernelMachine(memoryBytes: 2 * 1024 * 1024)
    let bus = machine.ioBus
    // PIC IRQ4 -> vector24, IOAPIC pin4 -> vector34. Both receive the UART's
    // real machine wiring; acknowledge each edge and finish both EOI protocols.
    try bus.write(port: 0x20, value: 0x11, width: .byte)
    for value: UInt32 in [0x20, 4, 1, 0xEF] {
      try bus.write(port: 0x21, value: value, width: .byte)
    }
    try machine.localAPIC.configureSpuriousVector(0xFF, softwareEnabled: true)
    try machine.ioAPIC.configure(pin: 4,
      route: .init(vector: 0x34, destinationAPICID: 0, masked: false))
    let message = Array("DORY_UART_IRQ_TEST complete userspace-sized serial record\r\n".utf8)
    try bus.write(port: 0x3F9, value: 2, width: .byte)
    // Linux's 16450 tx_loadsz is one. This bounded ISR model cannot make forward
    // progress without a distinct THRE interrupt for every subsequent byte.
    for byte in message {
      #expect(machine.legacyPIC.acknowledge(interruptsEnabled: true) == 0x24)
      #expect(machine.localAPIC.acknowledge(interruptsEnabled: true) == 0x34)
      #expect(try bus.read(port: 0x3FA, width: .byte) == 2)
      #expect(try bus.read(port: 0x3FA, width: .byte) == 1)
      try bus.write(port: 0x3F8, value: UInt32(byte), width: .byte)
      try bus.write(port: 0x20, value: 0x20, width: .byte)
      #expect(machine.localAPIC.endOfInterrupt() == 0x34)
    }
    // The final empty interrupt finds no more data and disables THRI.
    #expect(machine.legacyPIC.acknowledge(interruptsEnabled: true) == 0x24)
    #expect(machine.localAPIC.acknowledge(interruptsEnabled: true) == 0x34)
    #expect(try bus.read(port: 0x3FA, width: .byte) == 2)
    try bus.write(port: 0x3F9, value: 0, width: .byte)
    try bus.write(port: 0x20, value: 0x20, width: .byte)
    #expect(machine.localAPIC.endOfInterrupt() == 0x34)
    #expect(machine.legacyPIC.acknowledge(interruptsEnabled: true) == nil)
    #expect(machine.localAPIC.acknowledge(interruptsEnabled: true) == nil)
    #expect(machine.serial.drainTransmittedBytes() == message)
    #expect(machine.serial.dropCounts.transmitted == 0)
  }
}

private final class UARTInterruptLevels: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [Bool] = []
  var values: [Bool] { lock.withLock { storage } }
  func append(_ value: Bool) { lock.withLock { storage.append(value) } }
}
