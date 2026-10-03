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
    Thread.detachNewThread {
      _ = try? firstBus.read(at: blocking.baseAddress, byteCount: 1)
      firstReturned.signal()
    }
    try #require(blocking.entered.wait(timeout: .now() + 2) == .success)
    var releasedBlockingRead = false
    defer {
      if !releasedBlockingRead { blocking.release.signal() }
    }

    let secondStarted = DispatchSemaphore(value: 0)
    let secondReturned = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
      secondStarted.signal()
      _ = try? secondBus.read(at: secondMMIO.baseAddress, byteCount: 1)
      secondReturned.signal()
    }
    let portStarted = DispatchSemaphore(value: 0)
    let portReturned = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
      portStarted.signal()
      _ = try? ports.read(port: sharedPort.basePort, width: .byte)
      portReturned.signal()
    }

    try #require(secondStarted.wait(timeout: .now() + 2) == .success)
    try #require(portStarted.wait(timeout: .now() + 2) == .success)
    #expect(secondReturned.wait(timeout: .now() + .milliseconds(25)) == .timedOut)
    #expect(portReturned.wait(timeout: .now() + .milliseconds(25)) == .timedOut)
    #expect(try secondBus.read(at: 0, byteCount: 1) == [0])
    #expect(try independentPorts.read(port: independentPort.basePort, width: .byte) == 0x44)

    // Asynchronous device/DMA completion must be able to publish memory while a guest access is
    // blocked inside another device callback, otherwise the two sides can deadlock each other.
    let synchronizationStarted = DispatchSemaphore(value: 0)
    let synchronizationReturned = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
      synchronizationStarted.signal()
      secondBus.synchronize()
      synchronizationReturned.signal()
    }
    try #require(synchronizationStarted.wait(timeout: .now() + 2) == .success)
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

  @Test func inlineDeviceCallbackRejectsTrackedPageTableDMAWithoutWriting() throws {
    let coordinator = DoryPCDeviceAccessCoordinator()
    let ram = try DoryX86ByteArrayMemory(byteCount: 1 << 20)
    let memory = try bus(ram: ram, coordinator: coordinator)
    memory.seal()
    memory.trackPageTablePage(containing: 0x1000)
    let dma = DoryPCDMAGuestMemory(bus: memory)
    dma.installTrackedPageTableWriteObserver {}
    let deviceDMA = DoryPCDMAGuestMemory(
      bus: memory, permitsTrackedPageTableWrites: false)
    let unboundDMA = DoryPCDMAGuestMemory(bus: memory)

    #expect(throws: DoryPCPhysicalMemoryError.unsupportedAccess(
      offset: 0xffe, byteCount: 4, write: true
    )) {
      try deviceDMA.validate(at: 0xffe, byteCount: 4, deviceWillWrite: true)
    }
    try deviceDMA.validate(at: 0xffe, byteCount: 4, deviceWillWrite: false)
    try deviceDMA.validate(at: 0x2000, byteCount: 4, deviceWillWrite: true)
    try dma.validate(at: 0xffe, byteCount: 4, deviceWillWrite: true)

    #expect(throws: DoryPCPhysicalMemoryError.unsupportedAccess(
      offset: 0x1000, byteCount: 4, write: true
    )) {
      try deviceDMA.write(at: 0x1000, bytes: [1, 2, 3, 4])
    }
    #expect(throws: DoryPCPhysicalMemoryError.unsupportedAccess(
      offset: 0xffe, byteCount: 4, write: true
    )) {
      try deviceDMA.write(at: 0xffe, bytes: [1, 2, 3, 4])
    }
    #expect(throws: DoryPCPhysicalMemoryError.unsupportedAccess(
      offset: 0x1000, byteCount: 4, write: true
    )) {
      try unboundDMA.write(at: 0x1000, bytes: [1, 2, 3, 4])
    }

    #expect(coordinator.isActiveOnCurrentThread == false)
    try coordinator.withAccess {
      #expect(coordinator.isActiveOnCurrentThread)
      try coordinator.withAccess {
        #expect(coordinator.isActiveOnCurrentThread)
        #expect(throws: DoryPCPhysicalMemoryError.unsupportedAccess(
          offset: 0x1000, byteCount: 4, write: true
        )) {
          try dma.write(at: 0x1000, bytes: [1, 2, 3, 4])
        }
      }
      #expect(coordinator.isActiveOnCurrentThread)
    }
    #expect(coordinator.isActiveOnCurrentThread == false)
    #expect(try memory.read(at: 0xffe, byteCount: 4) == [0, 0, 0, 0])
    #expect(try memory.read(at: 0x1000, byteCount: 4) == [0, 0, 0, 0])
    #expect(memory.hasPendingPageTableWrite == false)
    try deviceDMA.write(at: 0x2000, bytes: [5, 6, 7, 8])
    #expect(try memory.read(at: 0x2000, byteCount: 4) == [5, 6, 7, 8])
    try deviceDMA.validate(at: 0x3000, byteCount: 4, deviceWillWrite: true)
    memory.trackPageTablePage(containing: 0x3000)
    #expect(throws: DoryPCPhysicalMemoryError.unsupportedAccess(
      offset: 0x3000, byteCount: 4, write: true
    )) {
      try deviceDMA.write(at: 0x3000, bytes: [9, 10, 11, 12])
    }
    #expect(try memory.read(at: 0x3000, byteCount: 4) == [0, 0, 0, 0])
  }

  @Test func soleDispatchOwnerCanPublishTrackedDMAInsideDeviceAccess() throws {
    let coordinator = DoryPCDeviceAccessCoordinator()
    let memory = try bus(
      ram: DoryX86ByteArrayMemory(byteCount: 1 << 20), coordinator: coordinator)
    memory.seal()
    memory.trackPageTablePage(containing: 0x1000)
    let wake = DoryPCPendingWorkWake(processorCount: 1)
    let observed = TrackedDMAWriteCount()
    let dma = DoryPCDMAGuestMemory(bus: memory)
    dma.installTrackedPageTableWriteObserver(
      { observed.record() },
      admission: { wake.isCurrentDispatchThread(forProcessor: 0) }
    )

    #expect(throws: DoryPCPhysicalMemoryError.unsupportedAccess(
      offset: 0x1000, byteCount: 4, write: true
    )) {
      try dma.write(at: 0x1000, bytes: [1, 2, 3, 4])
    }
    wake.setDispatchThread(Thread.current, forProcessor: 0)
    defer { wake.setDispatchThread(nil, forProcessor: 0) }
    try coordinator.withAccess {
      try dma.validate(at: 0x1000, byteCount: 4, deviceWillWrite: true)
      try dma.write(at: 0x1000, bytes: [1, 2, 3, 4])
    }
    #expect(observed.count == 1)
    #expect(try memory.read(at: 0x1000, byteCount: 4) == [1, 2, 3, 4])

    let remoteDone = DispatchSemaphore(value: 0)
    let remoteRejected = TrackedDMAWriteCount()
    Thread.detachNewThread {
      defer { remoteDone.signal() }
      do {
        try dma.write(at: 0x1004, bytes: [5, 6, 7, 8])
      } catch DoryPCPhysicalMemoryError.unsupportedAccess {
        remoteRejected.record()
      } catch {}
    }
    #expect(remoteDone.wait(timeout: .now() + 2) == .success)
    #expect(remoteRejected.count == 1)
    #expect(observed.count == 1)
    #expect(try memory.read(at: 0x1004, byteCount: 4) == [0, 0, 0, 0])
  }

  @Test func deviceDMAWriteCannotBypassMMIOAdmissionWithoutPreflight() throws {
    let coordinator = DoryPCDeviceAccessCoordinator()
    let memory = try bus(
      ram: DoryX86ByteArrayMemory(byteCount: 1 << 20), coordinator: coordinator)
    let register = ConstantMMIODevice(baseAddress: 0x20_0000, value: 0x22)
    try memory.attach(register)
    memory.seal()
    let dma = DoryPCDMAGuestMemory(bus: memory, permitsTrackedPageTableWrites: false)

    #expect(throws: DoryX86MemoryError.unmapped(
      address: register.baseAddress, byteCount: 1, access: .write
    )) {
      try dma.write(at: register.baseAddress, bytes: [0xff])
    }
    #expect(try memory.read(at: register.baseAddress, byteCount: 1) == [0x22])
  }

  @Test func deviceDMAReadCannotBypassMMIOAdmissionWithoutPreflight() throws {
    let coordinator = DoryPCDeviceAccessCoordinator()
    let memory = try bus(
      ram: DoryX86ByteArrayMemory(byteCount: 1 << 20), coordinator: coordinator)
    let register = ConstantMMIODevice(baseAddress: 0x20_0000, value: 0x22)
    try memory.attach(register)
    memory.seal()
    let dma = DoryPCDMAGuestMemory(bus: memory, permitsTrackedPageTableWrites: false)

    #expect(throws: DoryX86MemoryError.unmapped(
      address: register.baseAddress, byteCount: 1, access: .read
    )) {
      _ = try dma.read(at: register.baseAddress, byteCount: 1)
    }
    #expect(try dma.read(at: register.baseAddress, byteCount: 0).isEmpty)
    try memory.write(at: 0x100, bytes: [0x5A])
    #expect(try dma.read(at: 0x100, byteCount: 1) == [0x5A])
    #expect(try memory.read(at: register.baseAddress, byteCount: 1) == [0x22])
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

private final class TrackedDMAWriteCount: @unchecked Sendable {
  private let lock = NSLock()
  private var value = 0

  var count: Int { lock.withLock { value } }
  func record() { lock.withLock { value += 1 } }
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
