import Dispatch
import DoryDBTX86
import Foundation
import Testing

@testable import DoryMachinePC

@Suite(.serialized) struct DoryPCDeviceAccessCoordinatorTests {
  @Test func sharedDomainSerializesMMIOAndPortIOWithoutBlockingRAM() throws {
    let coordinator = DoryPCDeviceAccessCoordinator()
    let firstRAM = try DoryX86ByteArrayMemory(byteCount: 1 << 20)
    let secondRAM = try DoryX86ByteArrayMemory(byteCount: 1 << 20)
    let firstBus = try bus(ram: firstRAM, coordinator: coordinator)
    let secondBus = try bus(ram: secondRAM, coordinator: coordinator)
    let ports = DoryPCPortIOBus(deviceAccessCoordinator: coordinator)
    let independentPorts = DoryPCPortIOBus()
    let blocking = BlockingMMIODevice(baseAddress: 0x20_0000)
    let secondMMIO = ConstantMMIODevice(baseAddress: 0x20_0000, value: 0x22)
    let sharedPort = ConstantPortIODevice(basePort: 0x500, value: 0x33)
    let independentPort = ConstantPortIODevice(basePort: 0x500, value: 0x44)
    try firstBus.attach(blocking)
    try secondBus.attach(secondMMIO)
    try ports.attach(sharedPort)
    try independentPorts.attach(independentPort)
    firstBus.seal()
    secondBus.seal()
    ports.seal()
    independentPorts.seal()

    let firstReturned = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      _ = try? firstBus.read(at: blocking.baseAddress, byteCount: 1)
      firstReturned.signal()
    }
    #expect(blocking.entered.wait(timeout: .now() + 2) == .success)
    var releasedBlockingRead = false
    defer {
      if !releasedBlockingRead { blocking.release.signal() }
    }

    let secondReturned = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      _ = try? secondBus.read(at: secondMMIO.baseAddress, byteCount: 1)
      secondReturned.signal()
    }
    let portReturned = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      _ = try? ports.read(port: sharedPort.basePort, width: .byte)
      portReturned.signal()
    }

    #expect(secondReturned.wait(timeout: .now() + .milliseconds(25)) == .timedOut)
    #expect(portReturned.wait(timeout: .now() + .milliseconds(25)) == .timedOut)
    #expect(try secondBus.read(at: 0, byteCount: 1) == [0])
    #expect(try independentPorts.read(port: independentPort.basePort, width: .byte) == 0x44)

    // Asynchronous device/DMA completion must be able to publish memory while a guest access is
    // blocked inside another device callback, otherwise the two sides can deadlock each other.
    let synchronizationReturned = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      secondBus.synchronize()
      synchronizationReturned.signal()
    }
    #expect(synchronizationReturned.wait(timeout: .now() + 2) == .success)

    blocking.release.signal()
    releasedBlockingRead = true
    #expect(firstReturned.wait(timeout: .now() + 2) == .success)
    #expect(secondReturned.wait(timeout: .now() + 2) == .success)
    #expect(portReturned.wait(timeout: .now() + 2) == .success)
  }

  @Test func synchronousNestedDeviceRoutingIsReentrant() throws {
    let coordinator = DoryPCDeviceAccessCoordinator()
    let ports = DoryPCPortIOBus(deviceAccessCoordinator: coordinator)
    let port = ConstantPortIODevice(basePort: 0x500, value: 0x5a)
    try ports.attach(port)
    ports.seal()
    let memory = try bus(
      ram: DoryX86ByteArrayMemory(byteCount: 1 << 20), coordinator: coordinator)
    let nested = NestedMMIODevice(baseAddress: 0x20_0000) {
      UInt8(truncatingIfNeeded: try ports.read(port: port.basePort, width: .byte))
    }
    try memory.attach(nested)
    memory.seal()

    #expect(try memory.read(at: nested.baseAddress, byteCount: 1) == [0x5a])
  }

  private func bus(
    ram: any DoryX86PhysicalRAM,
    coordinator: DoryPCDeviceAccessCoordinator
  ) throws -> DoryPCPhysicalMemoryBus {
    try DoryPCPhysicalMemoryBus(
      ram: ram,
      mmioHoleStart: DoryPCV1ABI.mmioHoleStart,
      above4GRAMStart: DoryPCV1ABI.above4GRAMStart,
      deviceAccessCoordinator: coordinator
    )
  }
}

private final class BlockingMMIODevice: DoryPCMMIODevice, @unchecked Sendable {
  let baseAddress: UInt64
  let byteCount: UInt64 = 1
  let entered = DispatchSemaphore(value: 0)
  let release = DispatchSemaphore(value: 0)

  init(baseAddress: UInt64) { self.baseAddress = baseAddress }

  func read(offset: UInt64, byteCount: Int) throws -> [UInt8] {
    entered.signal()
    release.wait()
    return [0x11]
  }

  func write(offset: UInt64, bytes: [UInt8]) throws {}
}

private final class ConstantMMIODevice: DoryPCMMIODevice, @unchecked Sendable {
  let baseAddress: UInt64
  let byteCount: UInt64 = 1
  let value: UInt8

  init(baseAddress: UInt64, value: UInt8) {
    self.baseAddress = baseAddress
    self.value = value
  }

  func read(offset: UInt64, byteCount: Int) throws -> [UInt8] { [value] }

  func write(offset: UInt64, bytes: [UInt8]) throws {}
}

private final class NestedMMIODevice: DoryPCMMIODevice, @unchecked Sendable {
  let baseAddress: UInt64
  let byteCount: UInt64 = 1
  private let nestedRead: @Sendable () throws -> UInt8

  init(baseAddress: UInt64, nestedRead: @escaping @Sendable () throws -> UInt8) {
    self.baseAddress = baseAddress
    self.nestedRead = nestedRead
  }

  func read(offset: UInt64, byteCount: Int) throws -> [UInt8] { [try nestedRead()] }

  func write(offset: UInt64, bytes: [UInt8]) throws {}
}

private final class ConstantPortIODevice: DoryPCPortIODevice, @unchecked Sendable {
  let basePort: UInt16
  let portCount: UInt16 = 1
  let value: UInt32

  init(basePort: UInt16, value: UInt32) {
    self.basePort = basePort
    self.value = value
  }

  func read(portOffset: UInt16, width: DoryX86OperandWidth) throws -> UInt32 { value }

  func write(portOffset: UInt16, value: UInt32, width: DoryX86OperandWidth) throws {}
}
