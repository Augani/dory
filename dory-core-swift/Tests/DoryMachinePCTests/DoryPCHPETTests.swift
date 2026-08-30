import DoryMachinePC
import Foundation
import Testing

@Suite struct DoryPCHPETTests {
  @Test func exposesStandardCapabilitiesAndCounterControl() throws {
    let hpet = DoryPCHPET()
    let capabilities = try read64(hpet, 0x00)
    #expect(capabilities & 0xFF == 1)
    #expect((capabilities >> 8) & 0x1F == 2)
    #expect(capabilities & (1 << 13) != 0)
    #expect(capabilities >> 32 == UInt64(DoryPCHPET.femtosecondsPerTick))

    hpet.advance(by: 20)
    #expect(try read64(hpet, 0xF0) == 0)
    try write64(hpet, 0x10, 1)
    hpet.advance(by: 20)
    #expect(try read64(hpet, 0xF0) == 20)
    try write64(hpet, 0xF0, 100)
    #expect(try read64(hpet, 0xF0) == 100)
  }

  @Test func oneShotEdgeTimerPulsesTheSelectedRoute() throws {
    let recorder = HPETInterruptRecorder()
    let hpet = DoryPCHPET { recorder.append(timer: $0, route: $1, asserted: $2) }
    try write64(hpet, 0x100, UInt64(1 << 2) | UInt64(11 << 9))
    try write64(hpet, 0x108, 50)
    try write64(hpet, 0x10, 1)

    #expect(hpet.ticksUntilNextInterrupt() == 50)
    hpet.advance(by: 49)
    #expect(recorder.values.isEmpty)
    hpet.advance(by: 1)

    #expect(
      recorder.values == [
        .init(timer: 0, route: 11, asserted: true), .init(timer: 0, route: 11, asserted: false),
      ])
    #expect(hpet.snapshot().interruptStatus == 1)
    #expect(!hpet.snapshot().timers[0].armed)
    try write64(hpet, 0x20, 1)
    #expect(hpet.snapshot().interruptStatus == 0)
  }

  @Test func periodicLevelTimerRearmsAndDeassertsWhenStatusClears() throws {
    let recorder = HPETInterruptRecorder()
    let hpet = DoryPCHPET { recorder.append(timer: $0, route: $1, asserted: $2) }
    let periodicLevelEnabled =
      UInt64(1 << 1) | UInt64(1 << 2) | UInt64(1 << 3)
      | UInt64(1 << 6) | UInt64(8 << 9)
    try write64(hpet, 0x100, periodicLevelEnabled)
    try write64(hpet, 0x108, 25)
    try write64(hpet, 0x10, 1)

    hpet.advance(by: 60)
    #expect(recorder.values == [.init(timer: 0, route: 8, asserted: true)])
    #expect(hpet.snapshot().timers[0].comparator == 75)
    #expect(hpet.ticksUntilNextInterrupt() == 0)

    try write64(hpet, 0x20, 1)
    #expect(recorder.values.last == .init(timer: 0, route: 8, asserted: false))
    #expect(hpet.ticksUntilNextInterrupt() == 15)
  }

  @Test func machineMapsHPETAndRoutesComparatorInterrupts() throws {
    let machine = try DoryPCDirectKernelMachine(memoryBytes: 2 * 1024 * 1024)
    try machine.localAPIC.configureSpuriousVector(0xFF, softwareEnabled: true)
    try machine.ioAPIC.configure(
      pin: 5,
      route: .init(vector: 0x45, destinationAPICID: 0, masked: false)
    )
    try machine.physicalMemory.write(
      at: 0xFED0_0100,
      bytes: littleEndian(UInt64(1 << 2) | UInt64(5 << 9))
    )
    try machine.physicalMemory.write(at: 0xFED0_0108, bytes: littleEndian(UInt64(10)))
    try machine.physicalMemory.write(at: 0xFED0_0010, bytes: littleEndian(UInt64(1)))

    machine.hpet.advance(by: 10)

    #expect(machine.localAPIC.snapshot().interruptRequest.contains(0x45))
  }

  private func read64(_ hpet: DoryPCHPET, _ offset: UInt64) throws -> UInt64 {
    try hpet.read(offset: offset, byteCount: 8).enumerated().reduce(0) {
      $0 | UInt64($1.element) << UInt64($1.offset * 8)
    }
  }

  private func write64(_ hpet: DoryPCHPET, _ offset: UInt64, _ value: UInt64) throws {
    try hpet.write(offset: offset, bytes: littleEndian(value))
  }

  private func littleEndian(_ value: UInt64) -> [UInt8] {
    (0..<8).map { UInt8(truncatingIfNeeded: value >> UInt64($0 * 8)) }
  }
}

private struct HPETInterrupt: Sendable, Hashable {
  let timer: Int
  let route: Int
  let asserted: Bool
}

private final class HPETInterruptRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [HPETInterrupt] = []

  var values: [HPETInterrupt] { lock.withLock { storage } }

  func append(timer: Int, route: Int, asserted: Bool) {
    lock.withLock { storage.append(.init(timer: timer, route: route, asserted: asserted)) }
  }
}
