import Foundation
import Testing
@testable import DoryMachinePC

@Suite struct DoryPCBootTimelineTests {
  private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 100
    func read() -> UInt64 { lock.withLock { value } }
    func set(_ value: UInt64) { lock.withLock { self.value = value } }
  }

  private func transmit(_ text: String, to uart: DoryPCUART16550) throws {
    for byte in text.utf8 { try uart.write(portOffset: 0, value: UInt32(byte), width: .byte) }
  }

  @Test func observesAtTransmissionBeforeConsoleDrain() throws {
    let clock = Clock()
    let timeline = DoryPCBootTimeline(now: clock.read)
    let uart = DoryPCUART16550()
    uart.observeBoot(with: timeline)
    clock.set(120)
    try transmit("Linux ver", to: uart)
    clock.set(140)
    try transmit("sion ", to: uart)
    clock.set(1_000)
    #expect(String(decoding: uart.drainTransmittedBytes(), as: UTF8.self) == "Linux version ")
    let event = try #require(timeline.snapshot().events.last)
    #expect(event.milestone == .kernel)
    #expect(event.elapsedNanoseconds == 40)
  }

  @Test func divisorWritesDoNotCreateGuestSerialMilestones() throws {
    let uart = DoryPCUART16550()
    let timeline = DoryPCBootTimeline()
    uart.observeBoot(with: timeline)
    try uart.write(portOffset: 3, value: 0x80, width: .byte)
    try transmit("Linux version ", to: uart)
    #expect(timeline.snapshot().observedSerialBytes == 0)
    #expect(timeline.snapshot().events.count == 1)
    try uart.write(portOffset: 3, value: 0, width: .byte)
    try transmit("Linux Linux version ", to: uart)
    #expect(timeline.snapshot().events.last?.milestone == .kernel)
  }

  @Test func grubMenuBootMessageDoesNotRequireTheInteractiveBanner() throws {
    let clock = Clock()
    let timeline = DoryPCBootTimeline(now: clock.read)
    let uart = DoryPCUART16550()
    uart.observeBoot(with: timeline)
    try transmit("\u{1b}[H\u{1b}[J\u{1b}[1;1H  Boot", to: uart)
    clock.set(180)
    try transmit("ing `Dory PC production-compatible smoke'\n\r", to: uart)
    #expect(timeline.snapshot().events.last?.milestone == .grub)
    #expect(timeline.snapshot().events.last?.elapsedNanoseconds == 80)
    try transmit("GNU GRUB", to: uart)
    #expect(timeline.snapshot().events.filter { $0.milestone == .grub }.count == 1)
  }

  @Test func observationsSurviveConsoleOverflowAndRemainBounded() throws {
    let uart = DoryPCUART16550(queueCapacity: 1)
    let timeline = DoryPCBootTimeline()
    uart.observeBoot(with: timeline)
    let text = "GNU GRUB Linux version VFS: Mounted root Run /init as init process\n"
    for _ in 0..<1_000 { try transmit(text, to: uart) }
    let snapshot = timeline.snapshot()
    #expect(snapshot.events.count == DoryPCBootTimeline.Milestone.allCases.count)
    #expect(snapshot.unobservedMilestones.isEmpty)
    #expect(snapshot.observedSerialBytes == UInt64(text.utf8.count * 1_000))
    #expect(uart.dropCounts.transmitted == text.utf8.count * 1_000 - 1)
  }

  @Test func terminalSnapshotCensorsMissingStagesAndFreezesObservation() throws {
    let clock = Clock()
    let timeline = DoryPCBootTimeline(now: clock.read)
    let uart = DoryPCUART16550()
    uart.observeBoot(with: timeline)
    clock.set(150)
    timeline.finish(reason: "deadline")
    clock.set(999)
    try transmit("Linux version ", to: uart)
    timeline.finish(reason: "later-stop")
    let snapshot = timeline.snapshot()
    #expect(snapshot.terminationReason == "deadline")
    #expect(snapshot.elapsedNanoseconds == 50)
    #expect(snapshot.unobservedStatus == "censored")
    #expect(snapshot.unobservedMilestones.contains(.kernel))
    #expect(snapshot.observedSerialBytes == 0)
  }

  @Test func replacementDoesNotCarryPartialMarkersIntoAnotherBoot() throws {
    let uart = DoryPCUART16550()
    let first = DoryPCBootTimeline()
    uart.observeBoot(with: first)
    try transmit("Linux ver", to: uart)
    let second = DoryPCBootTimeline()
    #expect(first.snapshot().observationID != second.snapshot().observationID)
    uart.observeBoot(with: second)
    try transmit("sion ", to: uart)
    #expect(second.snapshot().events.count == 1)
    try transmit("Linux version ", to: uart)
    #expect(second.snapshot().events.last?.milestone == .kernel)
    #expect(first.snapshot().events.count == 1)
    uart.observeBoot(with: nil)
    try transmit("GNU GRUB", to: uart)
    #expect(!second.snapshot().events.contains { $0.milestone == .grub })
  }
}
