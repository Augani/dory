import Foundation
import Testing

@testable import DoryMachinePC

@Suite struct DoryPCAPICErrorTests {
  @Test(arguments: [false, true])
  func invalidTimerVectorReplacesOldTimerWithoutDeliveringIt(masked: Bool) throws {
    let apic = DoryPCLocalAPIC(apicID: 0)
    let mmio = DoryPCLocalAPICMMIO(apic: apic)
    try mmio.write(offset: 0x320, bytes: [0x50, 0, 0, 0])
    try mmio.write(offset: 0x380, bytes: [10, 0, 0, 0])
    apic.advanceTimer(by: 3)

    try mmio.write(offset: 0x320, bytes: [0x05, 0, masked ? 1 : 0, 0])
    #expect(apic.snapshot().timer.vector == 0x05)
    #expect(apic.snapshot().timer.masked == masked)
    #expect(apic.snapshot().timer.currentCount == 7)
    apic.advanceTimer(by: 7)

    #expect(apic.snapshot().timer.currentCount == 0)
    #expect(apic.snapshot().interruptRequest.isEmpty)
    try mmio.write(offset: 0x280, bytes: [0, 0, 0, 0])
    #expect(try mmio.read(offset: 0x280, byteCount: 4) == [0x40, 0, 0, 0])
  }

  @Test func errorStatusLatchesAccumulatesAndRearmsOnlyOnWrite() throws {
    let apic = DoryPCLocalAPIC(apicID: 0)
    let mmio = DoryPCLocalAPICMMIO(apic: apic)
    try apic.configureSpuriousVector(0xFF, softwareEnabled: true)
    #expect(try mmio.read(offset: 0x370, byteCount: 4) == [0, 0, 1, 0])
    try mmio.write(offset: 0x370, bytes: [0x60, 0, 0, 0])

    apic.recordError(.sendIllegalVector)
    #expect(apic.acknowledge(interruptsEnabled: true) == 0x60)
    #expect(apic.endOfInterrupt() == 0x60)
    apic.recordError(.receiveIllegalVector)
    #expect(apic.acknowledge(interruptsEnabled: true) == nil)
    #expect(try mmio.read(offset: 0x280, byteCount: 4) == [0, 0, 0, 0])

    // xAPIC ignores the written value, publishes both accumulated errors, and rearms.
    try mmio.write(offset: 0x280, bytes: [0xFF, 0xFF, 0xFF, 0xFF])
    for _ in 0..<2 {
      #expect(try mmio.read(offset: 0x280, byteCount: 4) == [0x60, 0, 0, 0])
    }
    apic.recordError(.sendIllegalVector)
    #expect(apic.acknowledge(interruptsEnabled: true) == 0x60)
    #expect(apic.endOfInterrupt() == 0x60)
    try mmio.write(offset: 0x280, bytes: [0, 0, 0, 0])
    #expect(try mmio.read(offset: 0x280, byteCount: 4) == [0x20, 0, 0, 0])
    try mmio.write(offset: 0x280, bytes: [0, 0, 0, 0])
    #expect(try mmio.read(offset: 0x280, byteCount: 4) == [0, 0, 0, 0])
  }

  @Test func maskedAndInvalidErrorVectorsStillRecordErrorsWithoutIllegalIRRBits() throws {
    let apic = DoryPCLocalAPIC(apicID: 0)
    let mmio = DoryPCLocalAPICMMIO(apic: apic)
    try apic.configureSpuriousVector(0xFF, softwareEnabled: true)
    try mmio.write(offset: 0x370, bytes: [0x60, 0, 1, 0])
    apic.recordError(.sendIllegalVector)
    try mmio.write(offset: 0x280, bytes: [0, 0, 0, 0])
    #expect(apic.snapshot().interruptRequest.isEmpty)
    #expect(try mmio.read(offset: 0x280, byteCount: 4) == [0x20, 0, 0, 0])

    try mmio.write(offset: 0x370, bytes: [0x05, 0xFF, 0xFE, 0xFF])
    #expect(try mmio.read(offset: 0x370, byteCount: 4) == [0x05, 0, 0, 0])
    apic.recordError(.sendIllegalVector)
    try mmio.write(offset: 0x280, bytes: [0, 0, 0, 0])
    #expect(try mmio.read(offset: 0x280, byteCount: 4) == [0x60, 0, 0, 0])
    #expect(apic.snapshot().interruptRequest.isEmpty)
  }

  @Test(arguments: [UInt32(0), UInt32(1)])
  func illegalIPIReportsSenderErrorBeforeDestinationLookup(deliveryMode: UInt32) throws {
    let source = DoryPCLocalAPIC(apicID: 0)
    let target = DoryPCLocalAPIC(apicID: 1)
    let controller = try DoryPCMultiprocessorController(localAPICs: [source, target])
    let mmio = DoryPCLocalAPICMMIO(apic: source, onInterruptCommand: { high, low in
      try controller.handleInterruptCommand(sourceAPICID: 0, high: high, low: low)
    })
    // Even a nonexistent target cannot convert an illegal vector into a host failure.
    try mmio.write(offset: 0x310, bytes: [0, 0, 0, 0x7F])
    try mmio.write(offset: 0x300, bytes: [0x05, UInt8(deliveryMode), 0, 0])
    try mmio.write(offset: 0x280, bytes: [0, 0, 0, 0])
    #expect(try mmio.read(offset: 0x280, byteCount: 4) == [0x20, 0, 0, 0])
    #expect(source.snapshot().interruptRequest.isEmpty)
    #expect(target.snapshot().interruptRequest.isEmpty)
    #expect(controller.snapshot().pendingEvents.isEmpty)
  }

  @Test func errorPendingWorkCallbackCanReenterRegisterTransport() throws {
    let probe = APICErrorRegisterReentryProbe()
    let apic = DoryPCLocalAPIC(apicID: 0, onPendingWork: { probe.observe() })
    let mmio = DoryPCLocalAPICMMIO(apic: apic)
    probe.mmio = mmio
    try apic.configureSpuriousVector(0xFF, softwareEnabled: true)
    try mmio.write(offset: 0x370, bytes: [0x60, 0, 0, 0])

    try mmio.write(offset: 0x320, bytes: [0x05, 0, 0, 0])

    #expect(probe.observedLVT == [0x60, 0, 0, 0])
    #expect(apic.snapshot().interruptRequest == [0x60])
  }

  @Test func advertisedLVTEntriesResetMaskedAndDiscardReservedBits() throws {
    let apic = DoryPCLocalAPIC(apicID: 0)
    let mmio = DoryPCLocalAPICMMIO(apic: apic)
    #expect(apic.snapshot().timer.vector == 0)
    #expect(apic.snapshot().timer.masked)
    for offset: UInt64 in [0x320, 0x330, 0x340, 0x350, 0x360, 0x370] {
      #expect(try mmio.read(offset: offset, byteCount: 4) == [0, 0, 1, 0])
    }
    for offset: UInt64 in [0x330, 0x340, 0x350, 0x360] {
      try mmio.write(offset: offset, bytes: [0x60, 0xFF, 0xFF, 0xFF])
      let expected: [UInt8] = [0x60, (offset >= 0x350 ? 0xA7 : 0x07), 1, 0]
      #expect(try mmio.read(offset: offset, byteCount: 4) == expected)
    }
    try mmio.write(offset: 0x320, bytes: [0x60, 0xFF, 0xFF, 0xFF])
    #expect(try mmio.read(offset: 0x320, byteCount: 4) == [0x60, 0, 3, 0])
    // Fixed delivery with an illegal vector is logged even when the LVT entry is masked.
    try mmio.write(offset: 0x350, bytes: [0x05, 0, 1, 0])
    try mmio.write(offset: 0x280, bytes: [0, 0, 0, 0])
    #expect(try mmio.read(offset: 0x280, byteCount: 4) == [0x40, 0, 0, 0])
  }

  @Test func reservedRegisterAccessReportsErrorWhileReadOnlyWritesAreIgnored() throws {
    let apic = DoryPCLocalAPIC(apicID: 0)
    let mmio = DoryPCLocalAPICMMIO(apic: apic)
    try mmio.write(offset: 0x30, bytes: [0xFF, 0xFF, 0xFF, 0xFF])
    #expect(try mmio.read(offset: 0x30, byteCount: 4) == [0x14, 0, 5, 0])
    try mmio.write(offset: 0x280, bytes: [0, 0, 0, 0])
    #expect(try mmio.read(offset: 0x280, byteCount: 4) == [0, 0, 0, 0])

    #expect(try mmio.read(offset: 0x2E0, byteCount: 4) == [0, 0, 0, 0])
    try mmio.write(offset: 0x2F0, bytes: [0, 0, 0, 0])
    try mmio.write(offset: 0x280, bytes: [0, 0, 0, 0])
    #expect(try mmio.read(offset: 0x280, byteCount: 4) == [0x80, 0, 0, 0])
    #expect(apic.snapshot().interruptRequest.isEmpty)
  }
}

private final class APICErrorRegisterReentryProbe: @unchecked Sendable {
  weak var mmio: DoryPCLocalAPICMMIO?
  private(set) var observedLVT: [UInt8]?

  func observe() {
    observedLVT = try? mmio?.read(offset: 0x370, byteCount: 4)
  }
}
