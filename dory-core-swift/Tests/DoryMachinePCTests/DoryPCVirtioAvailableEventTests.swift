import DoryMachinePC
import DoryVirtio
import Testing

// This is a small Linux-style driver: it decides whether to notify from the
// negotiated event field. Unconditionally kicking would hide the second-request
// stall found while auditing the IO guest's single completed backend read.
@Suite struct DoryPCVirtioAvailableEventTests {
  @Test func negotiatedEventIndexDrivesReadWriteAndFlushAsSuccessiveRequests() throws {
    for eventIndex in [true, false] {
      let storage = DoryVirtioInMemoryBlockStorage(byteCount: 4096)
      let block = try DoryPCVirtioBlockPCIDevice(address: .init(bus: 0, device: 2, function: 0),
        initialBARAddress: 0xD000_0000, storage: storage, identifier: "event-index-regression",
        maximumQueueSize: 8)
      let machine = try DoryPCDirectKernelMachine(memoryBytes: 2 * 1024 * 1024, pciFunctions: [block])
      try machine.localAPIC.configureSpuriousVector(0xFF, softwareEnabled: true)
      try block.writeConfiguration(offset: 4, bytes: [2, 0])
      // Program MSI-X queue vector1, routed to physical APIC0, vector0x74.
      try block.writeConfiguration(offset: 0x62, bytes: [1, 0x80])
      try block.writeBAR(offset: 0x810, bytes: littleEndian(UInt64(0xFEE0_0000)))
      try block.writeBAR(offset: 0x818, bytes: littleEndian(UInt32(0x74)))
      try block.writeBAR(offset: 0x81C, bytes: littleEndian(UInt32(0)))
      try block.writeBAR(offset: 0x08, bytes: littleEndian(UInt32(0)))
      try block.writeBAR(offset: 0x0C, bytes: littleEndian(UInt32(1 << 9) | (eventIndex ? 1 << 29 : 0)))
      try block.writeBAR(offset: 0x08, bytes: littleEndian(UInt32(1)))
      try block.writeBAR(offset: 0x0C, bytes: littleEndian(UInt32(1)))
      try block.writeBAR(offset: 0x14, bytes: [0x0F])
      try block.writeBAR(offset: 0x18, bytes: littleEndian(UInt16(8)))
      try block.writeBAR(offset: 0x1A, bytes: littleEndian(UInt16(1)))
      try block.writeBAR(offset: 0x20, bytes: littleEndian(UInt64(0x1000)))
      try block.writeBAR(offset: 0x28, bytes: littleEndian(UInt64(0x2000)))
      try block.writeBAR(offset: 0x30, bytes: littleEndian(UInt64(0x3000)))
      try block.writeBAR(offset: 0x1C, bytes: littleEndian(UInt16(1)))
      #expect(block.transport.deviceState.snapshot().negotiatedFeatures.contains(.eventIndex) == eventIndex)
      let eventAddress: UInt64 = 0x3044 // used header4 + 8 entries * 8 bytes
      if !eventIndex { try machine.physicalMemory.write(at: eventAddress, bytes: [0xEF, 0xBE]) }
      let pattern = (0..<512).map { UInt8(truncatingIfNeeded: $0 * 37) }
      for (index, requestType) in [UInt32(0), 1, 4].enumerated() {
        let flush = requestType == 4
        try descriptor(machine, at: 0x1000, address: 0x4000, length: 16, flags: 1, next: flush ? 2 : 1)
        try descriptor(machine, at: 0x1010, address: 0x5000, length: 512,
          flags: requestType == 0 ? 3 : 1, next: 2)
        try descriptor(machine, at: 0x1020, address: 0x6000, length: 1, flags: 2, next: 0)
        try machine.physicalMemory.write(at: 0x4000,
          bytes: littleEndian(requestType) + [0, 0, 0, 0] + littleEndian(UInt64(flush ? 0 : 1)))
        try machine.physicalMemory.write(at: 0x5000, bytes: requestType == 1 ? pattern : [UInt8](repeating: 0xA5, count: 512))
        try machine.physicalMemory.write(at: 0x6000, bytes: [0xFF])
        try machine.physicalMemory.write(at: 0x2004 + UInt64(index * 2), bytes: [0, 0])
        let old = UInt16(index), new = old + 1
        // Request an interrupt for this used entry before making work visible.
        try machine.physicalMemory.write(at: 0x2014, bytes: littleEndian(old))
        try machine.physicalMemory.write(at: 0x2002, bytes: littleEndian(new))
        let event = try read16(machine, eventAddress)
        let notify = eventIndex ? (new &- event &- 1) < (new &- old) : try read16(machine, 0x3000) & 1 == 0
        #expect(notify)
        if notify { try machine.physicalMemory.write(at: 0xD000_0100, bytes: [0, 0]) }
        #expect(try read16(machine, 0x3002) == new)
        #expect(try machine.physicalMemory.read(at: 0x6000, byteCount: 1) == [0])
        #expect(machine.localAPIC.snapshot().interruptRequest.contains(0x74))
        #expect(machine.localAPIC.acknowledge(interruptsEnabled: true) == 0x74)
        #expect(machine.localAPIC.endOfInterrupt() == 0x74)
        if eventIndex { #expect(try read16(machine, eventAddress) == new) }
        if requestType == 0 {
          #expect(try machine.physicalMemory.read(at: 0x5000, byteCount: 512) == [UInt8](repeating: 0, count: 512))
        }
      }
      let diagnostics = block.blockDevice.diagnostics
      #expect(diagnostics.successfulRequestCount == 3 && diagnostics.failedRequestCount == 0)
      #expect(diagnostics.readRequestCount == 1 && diagnostics.writeRequestCount == 1 && diagnostics.flushRequestCount == 1)
      #expect(try storage.read(offset: 512, byteCount: 512) == pattern)
      #expect(!block.transport.deviceState.snapshot().status.contains(.deviceNeedsReset))
      #expect(try block.transport.queue(at: 0).snapshot().outstandingHeads.isEmpty)
      if !eventIndex { #expect(try read16(machine, eventAddress) == 0xBEEF) }
    }
  }

  @Test func initialArmCoversBothReadyOrdersBlockedReceiveQueuesAndResetReuse() throws {
    for eventIndex in [true, false] {
      for readyFirst in [true, false] {
        for receiveBlocked in [true, false] {
          let machine = try DoryPCDirectKernelMachine(memoryBytes: 2 * 1024 * 1024)
          let transport = try DoryPCVirtioPCITransport(queueCount: 1, maximumQueueSize: 8,
            offeredFeatures: [.eventIndex])
          let counter = AvailableEventRequestCounter()
          transport.connectQueueProcessor(memory: machine.physicalMemory,
            canProcess: { _ in !receiveBlocked }) { _, _, _ in
              counter.increment()
              return 1
            }
          for generation in 0..<2 {
            if generation != 0 { try transport.writeBAR(offset: 0x14, bytes: [0]) }
            try machine.physicalMemory.write(at: 0x2000, bytes: [UInt8](repeating: 0, count: 22))
            try machine.physicalMemory.write(at: 0x3000, bytes: [UInt8](repeating: 0, count: 70))
            // The optional field is device-owned; a driver need not initialize
            // it to zero. Reuse the same stale tail after reset/reconfiguration.
            try machine.physicalMemory.write(at: 0x3044, bytes: [0xEF, 0xBE])
            try transport.writeBAR(offset: 0x08, bytes: littleEndian(UInt32(0)))
            try transport.writeBAR(offset: 0x0C, bytes: littleEndian(UInt32(eventIndex ? 1 << 29 : 0)))
            try transport.writeBAR(offset: 0x08, bytes: littleEndian(UInt32(1)))
            try transport.writeBAR(offset: 0x0C, bytes: littleEndian(UInt32(1)))
            try transport.writeBAR(offset: 0x14, bytes: [readyFirst ? 0x0F : 0x0B])
            try configureQueue(transport)
            if !readyFirst { try transport.writeBAR(offset: 0x14, bytes: [0x0F]) }
            #expect(try read16(machine, 0x3044) == (eventIndex ? 0 : 0xBEEF))
            #expect(counter.value == (receiveBlocked ? 0 : generation))
            // Repeated status writes must not reprocess an already consumed
            // request or manufacture a request before one is available.
            try transport.writeBAR(offset: 0x14, bytes: [0x0F])
            try descriptor(machine, at: 0x1000, address: 0x4000, length: 1, flags: 2, next: 0)
            try machine.physicalMemory.write(at: 0x2002, bytes: [1, 0])
            let event = try read16(machine, 0x3044)
            let kick = !eventIndex || (UInt16(1) &- event &- 1) < 1
            #expect(kick)
            if kick { try transport.writeBAR(offset: 0x100, bytes: [0, 0]) }
            #expect(counter.value == (receiveBlocked ? 0 : generation + 1))
            #expect(try read16(machine, 0x3002) == (receiveBlocked ? 0 : 1))
            try transport.writeBAR(offset: 0x14, bytes: [0x0F])
            #expect(counter.value == (receiveBlocked ? 0 : generation + 1))
            #expect(!transport.deviceState.snapshot().status.contains(.deviceNeedsReset))
          }
        }
      }
    }
  }

  @Test func rejectedDriverReadyTransitionDoesNotArmOrConsumeQueue() throws {
    let machine = try DoryPCDirectKernelMachine(memoryBytes: 2 * 1024 * 1024)
    let transport = try DoryPCVirtioPCITransport(queueCount: 1, maximumQueueSize: 8,
      offeredFeatures: [.eventIndex])
    let counter = AvailableEventRequestCounter()
    transport.connectQueueProcessor(memory: machine.physicalMemory) { _, _, _ in
      counter.increment()
      return 1
    }
    try machine.physicalMemory.write(at: 0x3044, bytes: [0xEF, 0xBE])
    try transport.writeBAR(offset: 0x08, bytes: littleEndian(UInt32(0)))
    try transport.writeBAR(offset: 0x0C, bytes: littleEndian(UInt32(1 << 29)))
    try transport.writeBAR(offset: 0x08, bytes: littleEndian(UInt32(1)))
    try transport.writeBAR(offset: 0x0C, bytes: littleEndian(UInt32(3))) // Unoffered feature33.
    try configureQueue(transport)
    try transport.writeBAR(offset: 0x14, bytes: [0x0F])
    #expect(!transport.deviceState.snapshot().status.contains(.driverOK))
    #expect(try read16(machine, 0x3044) == 0xBEEF && counter.value == 0)
  }

  @Test func ordinaryQueuesWithStagedWorkStillWaitForTheirExplicitNotification() throws {
    for readyFirst in [true, false] {
      let machine = try DoryPCDirectKernelMachine(memoryBytes: 2 * 1024 * 1024)
      let transport = try DoryPCVirtioPCITransport(queueCount: 1, maximumQueueSize: 8,
        offeredFeatures: [.eventIndex])
      let counter = AvailableEventRequestCounter()
      transport.connectQueueProcessor(memory: machine.physicalMemory) { _, _, _ in
        counter.increment()
        return 1
      }
      try descriptor(machine, at: 0x1000, address: 0x4000, length: 1, flags: 2, next: 0)
      try machine.physicalMemory.write(at: 0x2002, bytes: [1, 0])
      try machine.physicalMemory.write(at: 0x3044, bytes: [0xEF, 0xBE])
      try transport.writeBAR(offset: 0x08, bytes: littleEndian(UInt32(1)))
      try transport.writeBAR(offset: 0x0C, bytes: littleEndian(UInt32(1))) // VERSION_1 only.
      try transport.writeBAR(offset: 0x14, bytes: [readyFirst ? 0x0F : 0x0B])
      try configureQueue(transport)
      if !readyFirst { try transport.writeBAR(offset: 0x14, bytes: [0x0F]) }
      #expect(counter.value == 0)
      #expect(try read16(machine, 0x3002) == 0)
      #expect(try read16(machine, 0x3044) == 0xBEEF)
      try transport.writeBAR(offset: 0x100, bytes: [0, 0])
      #expect(counter.value == 1)
      #expect(try read16(machine, 0x3002) == 1)
      #expect(try read16(machine, 0x3044) == 0xBEEF)
    }
  }

  private func configureQueue(_ transport: DoryPCVirtioPCITransport) throws {
    try transport.writeBAR(offset: 0x18, bytes: littleEndian(UInt16(8)))
    try transport.writeBAR(offset: 0x20, bytes: littleEndian(UInt64(0x1000)))
    try transport.writeBAR(offset: 0x28, bytes: littleEndian(UInt64(0x2000)))
    try transport.writeBAR(offset: 0x30, bytes: littleEndian(UInt64(0x3000)))
    try transport.writeBAR(offset: 0x1C, bytes: littleEndian(UInt16(1)))
  }

  private func descriptor(_ machine: DoryPCDirectKernelMachine, at table: UInt64, address: UInt64,
    length: UInt32, flags: UInt16, next: UInt16) throws {
    try machine.physicalMemory.write(at: table,
      bytes: littleEndian(address) + littleEndian(length) + littleEndian(flags) + littleEndian(next))
  }
  private func read16(_ machine: DoryPCDirectKernelMachine, _ address: UInt64) throws -> UInt16 {
    let bytes = try machine.physicalMemory.read(at: address, byteCount: 2)
    return UInt16(bytes[0]) | UInt16(bytes[1]) << 8
  }
  private func littleEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
    (0..<MemoryLayout<T>.size).map { UInt8(truncatingIfNeeded: value >> T($0 * 8)) }
  }
}

/// These test transports are driven serially; the Sendable callback captures a
/// counter without exporting it to any concurrent executor.
private final class AvailableEventRequestCounter: @unchecked Sendable {
  private(set) var value = 0
  func increment() { value += 1 }
}
