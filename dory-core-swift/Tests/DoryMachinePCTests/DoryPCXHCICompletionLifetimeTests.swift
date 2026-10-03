@testable import DoryMachinePC
import DoryVirtio
import Foundation
import Testing

struct DoryPCXHCICompletionLifetimeTests {
  enum Retirement: CaseIterable, Sendable {
    case unplug, controllerReset, memoryReplacement, portReset, sameEndpointReconfiguration
  }

  enum DisconnectRetirement: CaseIterable, Sendable {
    case controllerReset, memoryReplacement, portReset, reconnect
  }

  enum NotificationRetirement: CaseIterable, Sendable {
    case controllerReset, memoryReplacement, portReset
  }

  enum PreTransferPath: CaseIterable, Sendable {
    case link, noOp, stopped, malformedBulk, malformedControl
  }

  enum ContextCommand: CaseIterable, Sendable {
    case address, configure, deconfigure, evaluate, resetEndpoint, stopEndpoint, setDequeue, resetDevice
  }

  enum CommandRetirement: CaseIterable, Sendable {
    case controllerReset, memoryReplacement, portReset, endpointReplacement, slotReplacement
  }

  enum DomainRetirement: CaseIterable, Sendable {
    case none, controllerReset, memoryReplacement
  }

  @Test(arguments: DomainRetirement.allCases)
  func commandExecutionWaitsForDeviceDomainOutsideControllerLock(
    retirement: DomainRetirement
  ) throws {
    let fixture = try Fixture(control: false)
    let memory = Memory(fixture.machine.physicalMemory, guardedExecution: true)
    fixture.controller.connectGuestMemory(memory)
    try fixture.prepareEnableSlot(at: 0xF000)
    try fixture.installFreshEventRing()
    let finished = DispatchSemaphore(value: 0)
    let failure = Failure()
    var slotsBefore = fixture.controller.slotStates
    var eventsBefore: [UInt8] = []
    var writesBefore = 0
    try fixture.machine.physicalMemory.deviceAccessCoordinator.withAccess {
      DispatchQueue.global().async {
        do { try fixture.controller.writeBAR(offset: 0x2000, bytes: bytes(UInt32(0))) }
        catch { failure.record(error) }
        finished.signal()
      }
      try #require(memory.guardWaiting.wait(timeout: .now() + 1) == .success)
      #expect(finished.wait(timeout: .now()) == .timedOut)
      // The owning CPU domain can still acquire the controller while the foreign drain waits.
      let waitingSlots = try probeControllerWhileDomainHeld(fixture.controller)
      #expect(waitingSlots == [.init(slotID: 1, addressed: true)])
      switch retirement {
      case .none: break
      case .controllerReset:
        try fixture.controller.writeBAR(offset: 0x40, bytes: bytes(UInt32(1 << 1)))
      case .memoryReplacement:
        fixture.controller.connectGuestMemory(Memory(fixture.machine.physicalMemory, guardedExecution: true))
      }
      slotsBefore = fixture.controller.slotStates
      eventsBefore = try fixture.machine.physicalMemory.read(at: 0xE000, byteCount: 512)
      writesBefore = memory.writeCount
    }
    try #require(finished.wait(timeout: .now() + 1) == .success)
    if let error = failure.error { throw error }
    if retirement == .none {
      try fixture.expectSingleEnabledSlotCompletion()
    } else {
      #expect(fixture.controller.slotStates == slotsBefore)
      #expect(try fixture.machine.physicalMemory.read(at: 0xE000, byteCount: 512) == eventsBefore)
      #expect(memory.writeCount == writesBefore)
    }
  }

  @Test(arguments: DomainRetirement.allCases)
  func asyncCommandContinuationUsesCurrentProviderDomain(
    retirement: DomainRetirement
  ) throws {
    let fixture = try Fixture(control: false)
    let memory = Memory(fixture.machine.physicalMemory, guardedExecution: true)
    fixture.controller.connectGuestMemory(memory)
    try fixture.prepareEnableSlot(at: 0xF000)
    try fixture.installFreshEventRing()
    let publishedTail = DispatchSemaphore(value: 0)
    let failure = Failure()
    var slotsBefore = fixture.controller.slotStates
    var eventsBefore: [UInt8] = []
    var writesBefore = 0
    memory.onNextRead(at: 0xF010) {
      memory.onNextRead(at: 0xF010) {
        do {
          try fixture.publishEnableSlot(at: 0xF010)
          try fixture.controller.writeBAR(offset: 0x2000, bytes: bytes(UInt32(0)))
        } catch { failure.record(error) }
      }
      do { try fixture.controller.writeBAR(offset: 0x2000, bytes: bytes(UInt32(0))) }
      catch { failure.record(error) }
    }
    memory.onExecutionGuardReturn { publishedTail.signal() }
    try fixture.machine.physicalMemory.deviceAccessCoordinator.withAccess {
      try fixture.controller.writeBAR(offset: 0x2000, bytes: bytes(UInt32(0)))
      try #require(memory.guardWaiting.wait(timeout: .now() + 1) == .success)
      // A bounded probe throws out of withAccess and releases the domain if lock order regresses.
      let waitingSlots = try probeControllerWhileDomainHeld(fixture.controller)
      #expect(waitingSlots == [
        .init(slotID: 1, addressed: true), .init(slotID: 2, addressed: false),
      ])
      switch retirement {
      case .none: break
      case .controllerReset:
        try fixture.controller.writeBAR(offset: 0x40, bytes: bytes(UInt32(1 << 1)))
      case .memoryReplacement:
        fixture.controller.connectGuestMemory(Memory(fixture.machine.physicalMemory, guardedExecution: true))
      }
      slotsBefore = fixture.controller.slotStates
      eventsBefore = try fixture.machine.physicalMemory.read(at: 0xE000, byteCount: 512)
      writesBefore = memory.writeCount
    }
    try #require(publishedTail.wait(timeout: .now() + 1) == .success)
    if let error = failure.error { throw error }
    if retirement == .none {
      #expect(fixture.controller.slotStates == [
        .init(slotID: 1, addressed: true), .init(slotID: 2, addressed: false),
        .init(slotID: 3, addressed: false),
      ])
      let event = try fixture.machine.physicalMemory.read(at: 0xE010, byteCount: 16)
      #expect(value32(Array(event[8..<12])) >> 24 == 1)
      #expect(value32(Array(event[12..<16])) >> 24 == 3)
      #expect(try fixture.machine.physicalMemory.read(at: 0xE020, byteCount: 16) == [UInt8](repeating: 0, count: 16))
    } else {
      #expect(fixture.controller.slotStates == slotsBefore)
      #expect(try fixture.machine.physicalMemory.read(at: 0xE000, byteCount: 512) == eventsBefore)
      #expect(memory.writeCount == writesBefore)
    }
  }

  @Test func overlappingEnableSlotDoorbellsConsumeOneCommand() throws {
    let fixture = try Fixture(control: false)
    let memory = Memory(fixture.machine.physicalMemory)
    fixture.controller.connectGuestMemory(memory)
    try fixture.prepareEnableSlot(at: 0xF000)
    try fixture.installFreshEventRing()
    memory.holdRead(at: 0xF000)
    let finished = DispatchSemaphore(value: 0)
    let failure = Failure()
    DispatchQueue.global().async {
      do { try fixture.controller.writeBAR(offset: 0x2000, bytes: bytes(UInt32(0))) }
      catch { failure.record(error) }
      finished.signal()
    }
    defer { memory.resumeRead.signal() }
    try #require(memory.readEntered.wait(timeout: .now() + 1) == .success)
    try fixture.controller.writeBAR(offset: 0x2000, bytes: bytes(UInt32(0)))
    #expect(fixture.controller.slotStates == [.init(slotID: 1, addressed: true)])
    memory.resumeRead.signal()
    try #require(finished.wait(timeout: .now() + 1) == .success)
    if let error = failure.error { throw error }
    try fixture.expectSingleEnabledSlotCompletion()
  }

  @Test func sameThreadReadCallbackDoorbellReentryDoesNotDuplicateCommand() throws {
    let fixture = try Fixture(control: false)
    let memory = Memory(fixture.machine.physicalMemory)
    fixture.controller.connectGuestMemory(memory)
    try fixture.prepareEnableSlot(at: 0xF000)
    try fixture.installFreshEventRing()
    let failure = Failure()
    memory.onNextRead(at: 0xF000) {
      do { try fixture.controller.writeBAR(offset: 0x2000, bytes: bytes(UInt32(0))) }
      catch { failure.record(error) }
    }
    try fixture.controller.writeBAR(offset: 0x2000, bytes: bytes(UInt32(0)))
    if let error = failure.error { throw error }
    try fixture.expectSingleEnabledSlotCompletion()
  }

  @Test(arguments: [false, true])
  func retiredCommandOwnerUnwindCannotClearHeldSuccessor(replaceMemory: Bool) throws {
    let fixture = try Fixture(control: false)
    let oldMemory = Memory(fixture.machine.physicalMemory)
    fixture.controller.connectGuestMemory(oldMemory)
    try fixture.prepareEnableSlot(at: 0xF000)
    oldMemory.holdRead(at: 0xF000)
    let oldFinished = DispatchSemaphore(value: 0)
    let successorFinished = DispatchSemaphore(value: 0)
    let successorEntered = DispatchSemaphore(value: 0)
    let resumeSuccessor = DispatchSemaphore(value: 0)
    let failure = Failure()
    DispatchQueue.global().async {
      do { try fixture.controller.writeBAR(offset: 0x2000, bytes: bytes(UInt32(0))) }
      catch { failure.record(error) }
      oldFinished.signal()
    }
    defer {
      oldMemory.resumeRead.signal()
      resumeSuccessor.signal()
    }
    try #require(oldMemory.readEntered.wait(timeout: .now() + 1) == .success)
    let successorMemory: Memory
    if replaceMemory {
      successorMemory = Memory(fixture.machine.physicalMemory)
      fixture.controller.connectGuestMemory(successorMemory)
    } else {
      try fixture.resetAndReconfigureConnectedDevice()
      successorMemory = oldMemory
    }
    try fixture.prepareEnableSlot(at: 0xF000)
    try fixture.installFreshEventRing()
    successorMemory.holdRead(at: 0xF000, entered: successorEntered, resume: resumeSuccessor)
    DispatchQueue.global().async {
      do { try fixture.controller.writeBAR(offset: 0x2000, bytes: bytes(UInt32(0))) }
      catch { failure.record(error) }
      successorFinished.signal()
    }
    try #require(successorEntered.wait(timeout: .now() + 1) == .success)
    let writesBefore = successorMemory.writeCount
    oldMemory.resumeRead.signal()
    try #require(oldFinished.wait(timeout: .now() + 1) == .success)
    #expect(fixture.controller.slotStates == [.init(slotID: 1, addressed: true)])
    #expect(successorMemory.writeCount == writesBefore)
    try fixture.controller.writeBAR(offset: 0x2000, bytes: bytes(UInt32(0)))
    #expect(fixture.controller.slotStates == [.init(slotID: 1, addressed: true)])
    #expect(successorFinished.wait(timeout: .now()) == .timedOut)
    #expect(try fixture.machine.physicalMemory.read(at: 0xE000, byteCount: 512) == [UInt8](repeating: 0, count: 512))
    resumeSuccessor.signal()
    try #require(successorFinished.wait(timeout: .now() + 1) == .success)
    if let error = failure.error { throw error }
    try fixture.expectSingleEnabledSlotCompletion()
  }

  @Test func kickBehindSecondEmptyTailContinuesSameCommandOwner() throws {
    let fixture = try Fixture(control: false)
    let memory = Memory(fixture.machine.physicalMemory)
    fixture.controller.connectGuestMemory(memory)
    try fixture.prepareEnableSlot(at: 0xF000)
    try fixture.installFreshEventRing()
    let secondTailEntered = DispatchSemaphore(value: 0)
    let resumeSecondTail = DispatchSemaphore(value: 0)
    let publishedTail = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    let failure = Failure()
    memory.onNextRead(at: 0xF010) {
      memory.holdRead(at: 0xF010, entered: secondTailEntered, resume: resumeSecondTail)
      do { try fixture.controller.writeBAR(offset: 0x2000, bytes: bytes(UInt32(0))) }
      catch { failure.record(error) }
    }
    DispatchQueue.global().async {
      do { try fixture.controller.writeBAR(offset: 0x2000, bytes: bytes(UInt32(0))) }
      catch { failure.record(error) }
      finished.signal()
    }
    defer { resumeSecondTail.signal() }
    try #require(secondTailEntered.wait(timeout: .now() + 1) == .success)
    #expect(fixture.controller.slotStates == [
      .init(slotID: 1, addressed: true), .init(slotID: 2, addressed: false),
    ])
    memory.onNextRead(at: 0xF020) { publishedTail.signal() }
    try fixture.publishEnableSlot(at: 0xF010)
    try fixture.controller.writeBAR(offset: 0x2000, bytes: bytes(UInt32(0)))
    resumeSecondTail.signal()
    try #require(finished.wait(timeout: .now() + 1) == .success)
    try #require(publishedTail.wait(timeout: .now() + 1) == .success)
    if let error = failure.error { throw error }
    #expect(fixture.controller.slotStates == [
      .init(slotID: 1, addressed: true), .init(slotID: 2, addressed: false),
      .init(slotID: 3, addressed: false),
    ])
    let events = try (0..<2).map { index in
      try fixture.machine.physicalMemory.read(at: UInt64(0xE000 + index * 16), byteCount: 16)
    }
    #expect(events.allSatisfy {
      value32(Array($0[8..<12])) >> 24 == 1 && (value32(Array($0[12..<16])) >> 10) & 0x3F == 33
    })
    #expect(value32(Array(events[0][12..<16])) >> 24 == 2)
    #expect(value32(Array(events[1][12..<16])) >> 24 == 3)
    #expect(try fixture.machine.physicalMemory.read(at: 0xE020, byteCount: 16) == [UInt8](repeating: 0, count: 16))
  }

  @Test(arguments: [false, true])
  func doorbellAtEmptyTailOwnerHandoffCannotBeLost(kickFirst: Bool) throws {
    for _ in 0..<16 {
      let fixture = try Fixture(control: false)
      let memory = Memory(fixture.machine.physicalMemory)
      fixture.controller.connectGuestMemory(memory)
      try fixture.machine.physicalMemory.write(at: 0xF000, bytes: [UInt8](repeating: 0, count: 32))
      try fixture.controller.writeBAR(offset: 0x58, bytes: bytes(UInt64(0xF001)))
      try fixture.installFreshEventRing()
      memory.holdRead(at: 0xF000)
      let oldFinished = DispatchSemaphore(value: 0)
      let kickStarted = DispatchSemaphore(value: 0)
      let kickFinished = DispatchSemaphore(value: 0)
      let publishedTail = DispatchSemaphore(value: 0)
      let failure = Failure()
      DispatchQueue.global().async {
        do { try fixture.controller.writeBAR(offset: 0x2000, bytes: bytes(UInt32(0))) }
        catch { failure.record(error) }
        oldFinished.signal()
      }
      defer {
        memory.resumeRead.signal()
        kickStarted.signal()
      }
      try #require(memory.readEntered.wait(timeout: .now() + 1) == .success)
      memory.onNextRead(at: 0xF010) { publishedTail.signal() }
      try fixture.publishEnableSlot(at: 0xF000)
      DispatchQueue.global().async {
        _ = kickStarted.wait(timeout: .now() + 2)
        do { try fixture.controller.writeBAR(offset: 0x2000, bytes: bytes(UInt32(0))) }
        catch { failure.record(error) }
        kickFinished.signal()
      }
      if kickFirst {
        kickStarted.signal()
        memory.resumeRead.signal()
      } else {
        memory.resumeRead.signal()
        kickStarted.signal()
      }
      try #require(oldFinished.wait(timeout: .now() + 1) == .success)
      try #require(kickFinished.wait(timeout: .now() + 1) == .success)
      try #require(publishedTail.wait(timeout: .now() + 1) == .success)
      if let error = failure.error { throw error }
      try fixture.expectSingleEnabledSlotCompletion()
    }
  }

  @Test(arguments: ContextCommand.allCases, CommandRetirement.allCases)
  func retiredContextCommandCannotWriteOrMutateSuccessor(
    command: ContextCommand, retirement: CommandRetirement
  ) throws {
    let fixture = try Fixture(control: false)
    let memory = Memory(fixture.machine.physicalMemory)
    fixture.controller.connectGuestMemory(memory)
    let heldAddress = try fixture.prepareContextCommand(command)
    memory.holdRead(at: heldAddress)
    let finished = DispatchSemaphore(value: 0)
    let failure = Failure()
    DispatchQueue.global().async {
      do { try fixture.controller.writeBAR(offset: 0x2000, bytes: bytes(UInt32(0))) }
      catch { failure.record(error) }
      finished.signal()
    }
    defer { memory.resumeRead.signal() }
    try #require(memory.readEntered.wait(timeout: .now() + 1) == .success)
    switch retirement {
    case .controllerReset:
      try fixture.resetAndReconfigureConnectedDevice()
    case .memoryReplacement:
      fixture.controller.connectGuestMemory(Memory(fixture.machine.physicalMemory))
    case .portReset:
      try fixture.controller.writeBAR(offset: 0x440, bytes: bytes(UInt32(1 << 4)))
    case .endpointReplacement:
      try fixture.replaceCommandSlot(replaceSlot: false)
    case .slotReplacement:
      try fixture.replaceCommandSlot(replaceSlot: true)
    }
    try fixture.installFreshEventRing()
    let slotsBefore = fixture.controller.slotStates
    let contextBefore = try fixture.machine.physicalMemory.read(at: 0x6000, byteCount: 1_024)
    let statusBefore = try fixture.controller.readBAR(offset: 0x44, byteCount: 4)
    let writesBefore = memory.writeCount
    memory.resumeRead.signal()
    try #require(finished.wait(timeout: .now() + 1) == .success)
    if let error = failure.error { throw error }
    #expect(fixture.controller.slotStates == slotsBefore)
    #expect(try fixture.machine.physicalMemory.read(at: 0x6000, byteCount: 1_024) == contextBefore)
    #expect(try fixture.machine.physicalMemory.read(at: 0xE000, byteCount: 512) == [UInt8](repeating: 0, count: 512))
    #expect(try fixture.controller.readBAR(offset: 0x44, byteCount: 4) == statusBefore)
    #expect(memory.writeCount == writesBefore)
  }

  @Test(arguments: ContextCommand.allCases)
  func admittedContextCommandStillCompletes(command: ContextCommand) throws {
    let fixture = try Fixture(control: false)
    _ = try fixture.prepareContextCommand(command)
    try fixture.installFreshEventRing()
    try fixture.controller.writeBAR(offset: 0x2000, bytes: bytes(UInt32(0)))
    let event = try fixture.machine.physicalMemory.read(at: 0xE000, byteCount: 16)
    #expect(value32(Array(event[8..<12])) >> 24 == 1)
    #expect((value32(Array(event[12..<16])) >> 10) & 0x3F == 33)
    #expect(fixture.controller.slotStates == [.init(slotID: 1, addressed: command != .resetDevice)])
    switch command {
    case .resetEndpoint, .stopEndpoint, .setDequeue:
      #expect(value32(try fixture.machine.physicalMemory.read(at: 0x6060, byteCount: 4)) & 7 == 3)
    case .deconfigure, .resetDevice:
      #expect(try fixture.machine.physicalMemory.read(at: 0x6040, byteCount: 960) == [UInt8](repeating: 0, count: 960))
    case .address, .configure, .evaluate:
      break
    }
    if command == .setDequeue {
      #expect(value64(try fixture.machine.physicalMemory.read(at: 0x6068, byteCount: 8)) == 0xC101)
    }
  }

  @Test(arguments: [false, true])
  func contextCommandPreservesUnrelatedTransferProgress(evaluate: Bool) throws {
    let fixture = try Fixture(control: false)
    let memory = Memory(fixture.machine.physicalMemory)
    fixture.controller.connectGuestMemory(memory)
    _ = try fixture.prepareContextCommand(evaluate ? .evaluate : .configure)
    if !evaluate {
      var input = [UInt8](repeating: 0, count: 1_056)
      input.replaceSubrange(4..<8, with: bytes(UInt32(1 << 5)))
      input.replaceSubrange(196..<200, with: bytes(UInt32(512 << 16 | 6 << 3)))
      input.replaceSubrange(200..<208, with: bytes(UInt64(0xC101)))
      try fixture.machine.physicalMemory.write(at: 0x8000, bytes: input)
    }
    memory.holdRead(at: evaluate ? 0x6000 : 0x8000)
    let finished = DispatchSemaphore(value: 0)
    let failure = Failure()
    DispatchQueue.global().async {
      do { try fixture.controller.writeBAR(offset: 0x2000, bytes: bytes(UInt32(0))) }
      catch { failure.record(error) }
      finished.signal()
    }
    defer { memory.resumeRead.signal() }
    try #require(memory.readEntered.wait(timeout: .now() + 1) == .success)
    fixture.device.resume.signal()
    try fixture.controller.writeBAR(offset: 0x2004, bytes: bytes(UInt32(3)))
    #expect(value64(try fixture.machine.physicalMemory.read(at: 0x6068, byteCount: 8)) == 0xB011)
    memory.resumeRead.signal()
    try #require(finished.wait(timeout: .now() + 1) == .success)
    if let error = failure.error { throw error }
    #expect(value64(try fixture.machine.physicalMemory.read(at: 0x6068, byteCount: 8)) == 0xB011)
    try fixture.machine.physicalMemory.write(at: 0xD010, bytes: [0xCC, 0xCC, 0xCC, 0xCC])
    try fixture.machine.physicalMemory.write(at: 0xB010, bytes:
      bytes(UInt64(0xD010)) + bytes(UInt32(4)) + bytes(UInt32(1 << 10 | 1 << 5 | 1)))
    fixture.device.resume.signal()
    try fixture.controller.writeBAR(offset: 0x2004, bytes: bytes(UInt32(3)))
    #expect(try fixture.machine.physicalMemory.read(at: 0xD010, byteCount: 4) == [9, 8, 7, 6])
  }

  @Test(arguments: [UInt8(9), UInt8(10)])
  func retiredSlotCommandCannotAllocateOrRemoveSuccessorSlots(commandType: UInt8) throws {
    let fixture = try Fixture(control: false)
    let memory = Memory(fixture.machine.physicalMemory)
    fixture.controller.connectGuestMemory(memory)
    let control = UInt32(commandType) << 10 | UInt32(1)
      | (commandType == 10 ? UInt32(1 << 24) : 0)
    try fixture.machine.physicalMemory.write(at: 0x3030, bytes:
      [UInt8](repeating: 0, count: 12) + bytes(control))
    memory.holdRead(at: 0x3030)
    let finished = DispatchSemaphore(value: 0)
    let failure = Failure()
    DispatchQueue.global().async {
      do { try fixture.controller.writeBAR(offset: 0x2000, bytes: bytes(UInt32(0))) }
      catch { failure.record(error) }
      finished.signal()
    }
    defer { memory.resumeRead.signal() }
    try #require(memory.readEntered.wait(timeout: .now() + 1) == .success)
    try fixture.resetAndReconfigureConnectedDevice()
    try fixture.installFreshEventRing()
    let successorSlots = fixture.controller.slotStates
    let contextBefore = try fixture.machine.physicalMemory.read(at: 0x6000, byteCount: 128)
    let statusBefore = try fixture.controller.readBAR(offset: 0x44, byteCount: 4)
    let writesBefore = memory.writeCount
    memory.resumeRead.signal()
    try #require(finished.wait(timeout: .now() + 1) == .success)
    if let error = failure.error { throw error }
    #expect(successorSlots == [.init(slotID: 1, addressed: true)])
    #expect(fixture.controller.slotStates == successorSlots)
    #expect(try fixture.machine.physicalMemory.read(at: 0x6000, byteCount: 128) == contextBefore)
    #expect(try fixture.machine.physicalMemory.read(at: 0xE000, byteCount: 512) == [UInt8](repeating: 0, count: 512))
    #expect(try fixture.controller.readBAR(offset: 0x44, byteCount: 4) == statusBefore)
    #expect(memory.writeCount == writesBefore)
  }

  @Test(arguments: NotificationRetirement.allCases)
  func delayedConnectNotificationCannotPublishIntoSuccessorRing(
    retirement: NotificationRetirement
  ) throws {
    let fixture = try Fixture(control: false)
    let device = BlockingDevice()
    device.holdNotificationInstallation()
    let finished = DispatchSemaphore(value: 0)
    let failure = Failure()
    DispatchQueue.global().async {
      do { try fixture.controller.connect(port: 2, device: device) }
      catch { failure.record(error) }
      finished.signal()
    }
    defer { device.resumeNotification.signal() }
    try #require(device.notificationEntered.wait(timeout: .now() + 1) == .success)
    switch retirement {
    case .controllerReset:
      try fixture.controller.writeBAR(offset: 0x40, bytes: bytes(UInt32(1 << 1)))
      try fixture.controller.writeBAR(offset: 0x40, bytes: bytes(UInt32(1)))
    case .memoryReplacement:
      fixture.controller.connectGuestMemory(Memory(fixture.machine.physicalMemory))
    case .portReset:
      try fixture.controller.writeBAR(offset: 0x450, bytes: bytes(UInt32(1 << 4)))
    }
    try fixture.installFreshEventRing()
    let statusBefore = try fixture.controller.readBAR(offset: 0x44, byteCount: 4)
    device.resumeNotification.signal()
    try #require(finished.wait(timeout: .now() + 1) == .success)
    if let error = failure.error { throw error }
    #expect(try fixture.machine.physicalMemory.read(at: 0xE000, byteCount: 512) == [UInt8](repeating: 0, count: 512))
    #expect(try fixture.controller.readBAR(offset: 0x44, byteCount: 4) == statusBefore)
  }

  @Test(arguments: [false, true])
  func delayedPortResetNotificationCannotPublishIntoSuccessorRing(
    replaceMemory: Bool
  ) throws {
    let fixture = try Fixture(control: false)
    fixture.device.holdReset()
    let finished = DispatchSemaphore(value: 0)
    let failure = Failure()
    DispatchQueue.global().async {
      do { try fixture.controller.writeBAR(offset: 0x440, bytes: bytes(UInt32(1 << 4))) }
      catch { failure.record(error) }
      finished.signal()
    }
    defer { fixture.device.resumeReset.signal() }
    try #require(fixture.device.resetEntered.wait(timeout: .now() + 1) == .success)
    if replaceMemory {
      fixture.controller.connectGuestMemory(Memory(fixture.machine.physicalMemory))
    } else {
      try fixture.controller.writeBAR(offset: 0x40, bytes: bytes(UInt32(1 << 1)))
      try fixture.controller.writeBAR(offset: 0x40, bytes: bytes(UInt32(1)))
    }
    try fixture.installFreshEventRing()
    let statusBefore = try fixture.controller.readBAR(offset: 0x44, byteCount: 4)
    fixture.device.resumeReset.signal()
    try #require(finished.wait(timeout: .now() + 1) == .success)
    if let error = failure.error { throw error }
    #expect(try fixture.machine.physicalMemory.read(at: 0xE000, byteCount: 512) == [UInt8](repeating: 0, count: 512))
    #expect(try fixture.controller.readBAR(offset: 0x44, byteCount: 4) == statusBefore)
  }

  @Test(arguments: PreTransferPath.allCases, [false, true])
  func retiredPreTransferReadCannotWriteContextOrCompletion(
    path: PreTransferPath, replaceMemory: Bool
  ) throws {
    let fixture = try Fixture(control: path == .malformedControl)
    let memory = Memory(fixture.machine.physicalMemory)
    fixture.controller.connectGuestMemory(memory)
    if path == .stopped {
      try fixture.stopBulkEndpoint()
    }
    let transferAddress: UInt64 = path == .malformedControl ? 0x9000 : 0xB000
    let parameter: UInt64 = path == .link ? 0xB100 : 0xABC
    let control: UInt32 = switch path {
    case .link: 6 << 10 | 1
    case .noOp: 7 << 10 | 1 << 5 | 1
    case .stopped: 1 << 10 // A stopped endpoint must not be revived before cycle validation.
    case .malformedBulk: 2 << 10 | 1
    case .malformedControl: 1 << 10 | 1
    }
    try fixture.machine.physicalMemory.write(at: transferAddress, bytes:
      bytes(parameter) + [UInt8](repeating: 0, count: 4) + bytes(control))
    memory.holdRead(at: transferAddress)
    let finished = DispatchSemaphore(value: 0)
    let failure = Failure()
    DispatchQueue.global().async {
      do { try fixture.controller.writeBAR(offset: 0x2004, bytes: bytes(UInt32(path == .malformedControl ? 1 : 3))) }
      catch { failure.record(error) }
      finished.signal()
    }
    defer { memory.resumeRead.signal() }
    try #require(memory.readEntered.wait(timeout: .now() + 1) == .success)
    if replaceMemory {
      fixture.controller.connectGuestMemory(Memory(fixture.machine.physicalMemory))
    } else {
      try fixture.resetAndReconfigureConnectedDevice()
    }
    try fixture.installFreshEventRing()
    let contextBefore = try fixture.machine.physicalMemory.read(at: 0x6000, byteCount: 128)
    let statusBefore = try fixture.controller.readBAR(offset: 0x44, byteCount: 4)
    let writesBefore = memory.writeCount
    memory.resumeRead.signal()
    try #require(finished.wait(timeout: .now() + 1) == .success)
    if let error = failure.error { throw error }
    #expect(try fixture.machine.physicalMemory.read(at: 0x6000, byteCount: 128) == contextBefore)
    #expect(try fixture.machine.physicalMemory.read(at: 0xE000, byteCount: 512) == [UInt8](repeating: 0, count: 512))
    #expect(try fixture.controller.readBAR(offset: 0x44, byteCount: 4) == statusBefore)
    #expect(memory.writeCount == writesBefore)
    #expect(fixture.device.entered.wait(timeout: .now()) == .timedOut)
  }

  @Test(arguments: DisconnectRetirement.allCases)
  func heldDisconnectCannotPublishIntoSuccessorContextOrEventRing(
    retirement: DisconnectRetirement
  ) throws {
    let fixture = try Fixture(control: false)
    fixture.device.holdCancellation()
    let finished = DispatchSemaphore(value: 0)
    let failure = Failure()
    DispatchQueue.global().async {
      do { try fixture.controller.disconnect(port: 1) }
      catch { failure.record(error) }
      finished.signal()
    }
    defer { fixture.device.resumeCancellation.signal() }
    try #require(fixture.device.cancellationEntered.wait(timeout: .now() + 1) == .success)
    #expect(finished.wait(timeout: .now()) == .timedOut)
    let replacementMemory = Memory(fixture.machine.physicalMemory)
    switch retirement {
    case .controllerReset:
      try fixture.resetAndInstallReplacement()
    case .memoryReplacement:
      fixture.controller.connectGuestMemory(replacementMemory)
    case .portReset:
      try fixture.controller.writeBAR(offset: 0x440, bytes: bytes(UInt32(1 << 4)))
    case .reconnect:
      try fixture.controller.connect(port: 1, device: DoryPCUSBRecordingDevice())
      try fixture.readdressAndConfigure()
    }
    try fixture.installFreshEventRing()
    let contextBefore = try fixture.machine.physicalMemory.read(at: 0x6000, byteCount: 128)
    let eventRingBefore = try fixture.machine.physicalMemory.read(at: 0xE000, byteCount: 512)
    let writesBefore = replacementMemory.writeCount
    let statusBefore = try fixture.controller.readBAR(offset: 0x44, byteCount: 4)
    fixture.device.resumeCancellation.signal()
    try #require(finished.wait(timeout: .now() + 1) == .success)
    if let error = failure.error { throw error }
    #expect(try fixture.machine.physicalMemory.read(at: 0x6000, byteCount: 128) == contextBefore)
    #expect(try fixture.machine.physicalMemory.read(at: 0xE000, byteCount: 512) == eventRingBefore)
    #expect(replacementMemory.writeCount == writesBefore)
    #expect(try fixture.controller.readBAR(offset: 0x44, byteCount: 4) == statusBefore)
  }

  @Test(arguments: [false, true])
  func ownedDisconnectPublishesAfterCancellationEvenWithRepeatedNoOpDisconnect(
    repeated: Bool
  ) throws {
    let fixture = try Fixture(control: false)
    fixture.device.holdCancellation()
    let finished = DispatchSemaphore(value: 0)
    let failure = Failure()
    DispatchQueue.global().async {
      do { try fixture.controller.disconnect(port: 1) }
      catch { failure.record(error) }
      finished.signal()
    }
    defer { fixture.device.resumeCancellation.signal() }
    try #require(fixture.device.cancellationEntered.wait(timeout: .now() + 1) == .success)
    if repeated { try fixture.controller.disconnect(port: 1) }
    try fixture.installFreshEventRing()
    fixture.device.resumeCancellation.signal()
    try #require(finished.wait(timeout: .now() + 1) == .success)
    if let error = failure.error { throw error }
    #expect(value32(try fixture.machine.physicalMemory.read(at: 0x6020, byteCount: 4)) & 7 == 4)
    #expect(value32(try fixture.machine.physicalMemory.read(at: 0x6060, byteCount: 4)) & 7 == 4)
    let events = try (0..<3).map { index in
      try fixture.machine.physicalMemory.read(at: UInt64(0xE000 + index * 16), byteCount: 16)
    }
    #expect(events.prefix(2).allSatisfy {
      value32(Array($0[8..<12])) >> 24 == 22 && (value32(Array($0[12..<16])) >> 10) & 0x3f == 32
    })
    #expect((value32(Array(events[2][12..<16])) >> 10) & 0x3f == 34)
    #expect(try fixture.machine.physicalMemory.read(at: 0xE030, byteCount: 16) == [UInt8](repeating: 0, count: 16))
  }

  @Test(arguments: [false, true], Retirement.allCases)
  func retiredTransferCannotWritePayloadContextOrSuccessEvent(
    control: Bool, retirement: Retirement
  ) throws {
    let fixture = try Fixture(control: control)
    let finished = DispatchSemaphore(value: 0)
    let failure = Failure()
    DispatchQueue.global().async {
      do { try fixture.controller.writeBAR(offset: 0x2004, bytes: bytes(UInt32(control ? 1 : 3))) }
      catch { failure.record(error) }
      finished.signal()
    }
    #expect(fixture.device.entered.wait(timeout: .now() + 1) == .success)
    let replacementMemory = Memory(fixture.machine.physicalMemory)
    switch retirement {
    case .unplug:
      try fixture.controller.disconnect(port: 1)
      try fixture.controller.connect(port: 1, device: DoryPCUSBRecordingDevice())
      try fixture.readdressAndConfigure()
    case .controllerReset:
      try fixture.controller.writeBAR(offset: 0x40, bytes: bytes(UInt32(1 << 1)))
    case .memoryReplacement:
      fixture.controller.connectGuestMemory(replacementMemory)
    case .portReset:
      try fixture.controller.writeBAR(offset: 0x440, bytes: bytes(UInt32(1 << 4)))
    case .sameEndpointReconfiguration:
      try fixture.readdressAndConfigure()
    }
    let contextBefore = try fixture.machine.physicalMemory.read(
      at: control ? 0x6020 : 0x6060, byteCount: 32)
    fixture.device.resume.signal()
    #expect(finished.wait(timeout: .now() + 1) == .success)
    if let error = failure.error { throw error }
    #expect(try fixture.machine.physicalMemory.read(at: 0xD000, byteCount: 4) == [0xCC, 0xCC, 0xCC, 0xCC])
    #expect(try fixture.machine.physicalMemory.read(at: control ? 0x6020 : 0x6060, byteCount: 32) == contextBefore)
    #expect(replacementMemory.writeCount == 0)
    let successEvents = try (0..<16).filter { index in
      let event = try fixture.machine.physicalMemory.read(at: UInt64(0x2000 + index * 16), byteCount: 16)
      let code = value32(Array(event[8..<12])) >> 24
      let type = (value32(Array(event[12..<16])) >> 10) & 0x3f
      return type == 32 && (code == 1 || code == 13)
    }
    #expect(successEvents.isEmpty)
  }

  @Test func retiredReadinessCallbackCannotWakeAReplacementDevice() throws {
    let fixture = try Fixture(control: false)
    let oldHandler = fixture.device.readyHandler
    try fixture.controller.disconnect(port: 1)
    let replacement = DoryPCUSBRecordingDevice(queuedResults: [try .init(status: .success, payload: [7])])
    try fixture.controller.connect(port: 1, device: replacement)
    try fixture.readdressAndConfigure()
    oldHandler?()
    #expect(replacement.transfers.isEmpty)
    #expect(try fixture.machine.physicalMemory.read(at: 0xD000, byteCount: 4) == [0xCC, 0xCC, 0xCC, 0xCC])
  }

  private func probeControllerWhileDomainHeld(
    _ controller: DoryPCXHCIController
  ) throws -> [DoryPCXHCISlotState] {
    let probe = ControllerProbe()
    let finished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      do {
        let slots = controller.slotStates
        _ = try controller.readBAR(offset: 0x44, byteCount: 4)
        probe.record(slots: slots)
      } catch { probe.record(error: error) }
      finished.signal()
    }
    // On timeout, unwinding the caller's withAccess releases the domain. The probe can then
    // finish even if a regressed drain was holding xHCI while waiting for that same domain.
    try #require(finished.wait(timeout: .now() + 1) == .success)
    if let error = probe.error { throw error }
    return try #require(probe.slots)
  }

  private final class ControllerProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var capturedSlots: [DoryPCXHCISlotState]?
    private var capturedError: (any Error)?
    var slots: [DoryPCXHCISlotState]? { lock.withLock { capturedSlots } }
    var error: (any Error)? { lock.withLock { capturedError } }
    func record(slots: [DoryPCXHCISlotState]) { lock.withLock { capturedSlots = slots } }
    func record(error: any Error) { lock.withLock { capturedError = error } }
  }

  private final class Fixture: @unchecked Sendable {
    let controller: DoryPCXHCIController
    let machine: DoryPCDirectKernelMachine
    let device = BlockingDevice()

    init(control: Bool) throws {
      controller = try .init()
      machine = try .init(memoryBytes: 2 * 1024 * 1024, pciFunctions: [controller])
      try controller.writeConfiguration(offset: 4, bytes: [2, 0])
      try machine.physicalMemory.write(at: 0x1000, bytes: bytes(UInt64(0x2000)) + bytes(UInt32(32)) + [0, 0, 0, 0])
      try machine.physicalMemory.write(at: 0x4008, bytes: bytes(UInt64(0x6000)))
      var input = [UInt8](repeating: 0, count: 96)
      input.replaceSubrange(4..<8, with: bytes(UInt32(3)))
      input.replaceSubrange(32..<36, with: bytes(UInt32(1 << 27 | 3 << 20)))
      input.replaceSubrange(36..<40, with: bytes(UInt32(1 << 16)))
      input.replaceSubrange(68..<72, with: bytes(UInt32(64 << 16 | 4 << 3)))
      input.replaceSubrange(72..<80, with: bytes(UInt64(0x9001)))
      try machine.physicalMemory.write(at: 0x5000, bytes: input)
      var configured = [UInt8](repeating: 0, count: 1_056)
      configured.replaceSubrange(4..<8, with: bytes(UInt32(1 << 3)))
      configured.replaceSubrange(132..<136, with: bytes(UInt32(512 << 16 | 6 << 3)))
      configured.replaceSubrange(136..<144, with: bytes(UInt64(0xB001)))
      try machine.physicalMemory.write(at: 0x8000, bytes: configured)
      try machine.physicalMemory.write(at: 0x3000, bytes:
        command(control: 9 << 10 | 1)
          + command(parameter: 0x5000, control: 1 << 24 | 11 << 10 | 1)
          + command(parameter: 0x8000, control: 1 << 24 | 12 << 10 | 1))
      try machine.physicalMemory.write(at: 0xD000, bytes: [0xCC, 0xCC, 0xCC, 0xCC])
      if control {
        let setup = UInt64(0x80) | UInt64(6) << 8 | UInt64(1) << 24 | UInt64(4) << 48
        try machine.physicalMemory.write(at: 0x9000, bytes:
          bytes(setup) + bytes(UInt32(8)) + bytes(UInt32(2 << 10 | 1 << 6 | 1)))
        try machine.physicalMemory.write(at: 0x9010, bytes:
          bytes(UInt64(0xD000)) + bytes(UInt32(4)) + bytes(UInt32(3 << 10 | 1 << 16 | 1)))
        try machine.physicalMemory.write(at: 0x9020, bytes:
          [UInt8](repeating: 0, count: 12) + bytes(UInt32(4 << 10 | 1 << 5 | 1)))
      } else {
        try machine.physicalMemory.write(at: 0xB000, bytes:
          bytes(UInt64(0xD000)) + bytes(UInt32(4)) + bytes(UInt32(1 << 10 | 1 << 5 | 1)))
      }
      try controller.writeBAR(offset: 0x1028, bytes: bytes(UInt32(1)))
      try controller.writeBAR(offset: 0x1030, bytes: bytes(UInt64(0x1000)))
      try controller.writeBAR(offset: 0x1038, bytes: bytes(UInt64(0x2000)))
      try controller.writeBAR(offset: 0x58, bytes: bytes(UInt64(0x3001)))
      try controller.writeBAR(offset: 0x70, bytes: bytes(UInt64(0x4000)))
      try controller.writeBAR(offset: 0x78, bytes: bytes(UInt32(8)))
      try controller.writeBAR(offset: 0x40, bytes: bytes(UInt32(1)))
      try controller.connect(port: 1, device: device)
      try controller.writeBAR(offset: 0x2000, bytes: bytes(UInt32(0)))
    }

    func readdressAndConfigure() throws {
      try machine.physicalMemory.write(at: 0x3030, bytes:
        command(parameter: 0x5000, control: 1 << 24 | 11 << 10 | 1)
          + command(parameter: 0x8000, control: 1 << 24 | 12 << 10 | 1))
      try controller.writeBAR(offset: 0x2000, bytes: bytes(UInt32(0)))
    }

    func stopBulkEndpoint() throws {
      try machine.physicalMemory.write(at: 0x3030, bytes:
        command(control: 1 << 24 | 3 << 16 | 15 << 10 | 1))
      try controller.writeBAR(offset: 0x2000, bytes: bytes(UInt32(0)))
      #expect(value32(try machine.physicalMemory.read(at: 0x6060, byteCount: 4)) & 7 == 3)
    }

    func prepareEnableSlot(at address: UInt64) throws {
      try #require(address & 0x3F == 0)
      try publishEnableSlot(at: address)
      try controller.writeBAR(offset: 0x58, bytes: bytes(address | 1))
    }

    func publishEnableSlot(at address: UInt64) throws {
      try machine.physicalMemory.write(at: address, bytes:
        command(control: 9 << 10 | 1) + [UInt8](repeating: 0, count: 16))
    }

    func expectSingleEnabledSlotCompletion() throws {
      #expect(controller.slotStates == [
        .init(slotID: 1, addressed: true), .init(slotID: 2, addressed: false),
      ])
      let event = try machine.physicalMemory.read(at: 0xE000, byteCount: 16)
      #expect(value32(Array(event[8..<12])) >> 24 == 1)
      #expect((value32(Array(event[12..<16])) >> 10) & 0x3F == 33)
      #expect(value32(Array(event[12..<16])) >> 24 == 2)
      #expect(try machine.physicalMemory.read(at: 0xE010, byteCount: 16) == [UInt8](repeating: 0, count: 16))
    }

    func prepareContextCommand(_ command: ContextCommand) throws -> UInt64 {
      let type: UInt32
      let parameter: UInt64
      let flags: UInt32
      let heldAddress: UInt64
      switch command {
      case .address:
        type = 11; parameter = 0x5000; flags = 0; heldAddress = 0x5000
      case .configure:
        type = 12; parameter = 0x8000; flags = 0; heldAddress = 0x8000
      case .deconfigure:
        type = 12; parameter = 0; flags = 1 << 9; heldAddress = 0x6000
      case .evaluate:
        type = 13; parameter = 0xC800; flags = 0; heldAddress = 0xC800
        var input = [UInt8](repeating: 0, count: 1_056)
        input.replaceSubrange(4..<8, with: bytes(UInt32(1 << 3)))
        input.replaceSubrange(132..<136, with: bytes(UInt32(64 << 16 | 6 << 3)))
        input.replaceSubrange(136..<144, with: bytes(UInt64(0xC101)))
        try machine.physicalMemory.write(at: 0xC800, bytes: input)
      case .resetEndpoint:
        type = 14; parameter = 0; flags = 3 << 16; heldAddress = 0x6060
        try controller.disconnect(port: 1)
        try controller.connect(port: 1, device: DoryPCUSBRecordingDevice(
          queuedResults: [try .init(status: .stalled)]
        ))
        try readdressAndConfigure()
        try controller.writeBAR(offset: 0x2004, bytes: bytes(UInt32(3)))
        #expect(value32(try machine.physicalMemory.read(at: 0x6060, byteCount: 4)) & 7 == 2)
      case .stopEndpoint:
        type = 15; parameter = 0; flags = 3 << 16; heldAddress = 0x6060
      case .setDequeue:
        type = 16; parameter = 0xC101; flags = 3 << 16; heldAddress = 0x6060
        try stopBulkEndpoint()
      case .resetDevice:
        type = 17; parameter = 0; flags = 0; heldAddress = 0x6000
      }
      try machine.physicalMemory.write(at: 0xF000, bytes:
        self.command(parameter: parameter, control: 1 << 24 | type << 10 | flags | 1)
          + [UInt8](repeating: 0, count: 16))
      try controller.writeBAR(offset: 0x58, bytes: bytes(UInt64(0xF001)))
      return heldAddress
    }

    func replaceCommandSlot(replaceSlot: Bool) throws {
      var commands: [UInt8] = []
      if replaceSlot {
        commands += command(control: 1 << 24 | 10 << 10 | 1)
        commands += command(control: 9 << 10 | 1)
        commands += command(parameter: 0x5000, control: 1 << 24 | 11 << 10 | 1)
      }
      commands += command(parameter: 0x8000, control: 1 << 24 | 12 << 10 | 1)
      commands += [UInt8](repeating: 0, count: 16)
      try machine.physicalMemory.write(at: 0xF100, bytes: commands)
      try controller.writeBAR(offset: 0x58, bytes: bytes(UInt64(0xF101)))
      try controller.writeBAR(offset: 0x2000, bytes: bytes(UInt32(0)))
      #expect(controller.slotStates == [.init(slotID: 1, addressed: true)])
      // Restore the exact old cursor/cycle: slot/endpoint authority must reject this ABA,
      // not merely a changed command-ring address.
      try controller.writeBAR(offset: 0x58, bytes: bytes(UInt64(0xF001)))
    }

    func installFreshEventRing() throws {
      try machine.physicalMemory.write(at: 0xC000, bytes:
        bytes(UInt64(0xE000)) + bytes(UInt32(32)) + [0, 0, 0, 0])
      try controller.writeBAR(offset: 0x1028, bytes: bytes(UInt32(1)))
      try controller.writeBAR(offset: 0x1030, bytes: bytes(UInt64(0xC000)))
      try controller.writeBAR(offset: 0x1038, bytes: bytes(UInt64(0xE000)))
    }

    func resetAndInstallReplacement() throws {
      try controller.writeBAR(offset: 0x40, bytes: bytes(UInt32(1 << 1)))
      try controller.connect(port: 1, device: DoryPCUSBRecordingDevice())
      try configureAfterControllerReset()
    }

    func resetAndReconfigureConnectedDevice() throws {
      try controller.writeBAR(offset: 0x40, bytes: bytes(UInt32(1 << 1)))
      try configureAfterControllerReset()
    }

    private func configureAfterControllerReset() throws {
      try machine.physicalMemory.write(at: 0x3000, bytes: [UInt8](repeating: 0, count: 128))
      try machine.physicalMemory.write(at: 0x3000, bytes:
        command(control: 9 << 10 | 1)
          + command(parameter: 0x5000, control: 1 << 24 | 11 << 10 | 1)
          + command(parameter: 0x8000, control: 1 << 24 | 12 << 10 | 1))
      try controller.writeBAR(offset: 0x1028, bytes: bytes(UInt32(1)))
      try controller.writeBAR(offset: 0x1030, bytes: bytes(UInt64(0x1000)))
      try controller.writeBAR(offset: 0x1038, bytes: bytes(UInt64(0x2000)))
      try controller.writeBAR(offset: 0x58, bytes: bytes(UInt64(0x3001)))
      try controller.writeBAR(offset: 0x70, bytes: bytes(UInt64(0x4000)))
      try controller.writeBAR(offset: 0x78, bytes: bytes(UInt32(8)))
      try controller.writeBAR(offset: 0x40, bytes: bytes(UInt32(1)))
      try controller.writeBAR(offset: 0x2000, bytes: bytes(UInt32(0)))
      #expect(controller.slotStates == [.init(slotID: 1, addressed: true)])
    }
    private func command(parameter: UInt64 = 0, control: UInt32) -> [UInt8] {
      bytes(parameter) + [UInt8](repeating: 0, count: 4) + bytes(control)
    }
  }

  private final class BlockingDevice: DoryPCUSBDevice, DoryPCUSBTransferReadyNotifying, @unchecked Sendable {
    let speed: DoryPCXHCIPortSpeed = .high
    let entered = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    let cancellationEntered = DispatchSemaphore(value: 0)
    let resumeCancellation = DispatchSemaphore(value: 0)
    let notificationEntered = DispatchSemaphore(value: 0)
    let resumeNotification = DispatchSemaphore(value: 0)
    let resetEntered = DispatchSemaphore(value: 0)
    let resumeReset = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var ready: (@Sendable () -> Void)?
    private var blocksCancellation = false
    private var blocksNotification = false
    private var blocksReset = false
    var readyHandler: (@Sendable () -> Void)? { lock.withLock { ready } }
    func holdNotificationInstallation() { lock.withLock { blocksNotification = true } }
    func setTransferReadyHandler(_ handler: (@Sendable () -> Void)?) {
      let shouldBlock = lock.withLock {
        ready = handler
        guard handler != nil, blocksNotification else { return false }
        blocksNotification = false
        return true
      }
      if shouldBlock {
        notificationEntered.signal()
        _ = resumeNotification.wait(timeout: .now() + 2)
      }
    }
    func perform(_ transfer: DoryPCUSBTransfer) -> DoryPCUSBTransferResult {
      entered.signal()
      _ = resume.wait(timeout: .now() + 2)
      return try! .init(status: .success, payload: [9, 8, 7, 6])
    }
    func holdReset() { lock.withLock { blocksReset = true } }
    func reset() {
      guard lock.withLock({ blocksReset }) else { return }
      resetEntered.signal()
      _ = resumeReset.wait(timeout: .now() + 2)
    }
    func holdCancellation() { lock.withLock { blocksCancellation = true } }
    func cancelAll() {
      guard lock.withLock({ blocksCancellation }) else { return }
      cancellationEntered.signal()
      _ = resumeCancellation.wait(timeout: .now() + 2)
    }
  }

  private final class Failure: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (any Error)?
    var error: (any Error)? { lock.withLock { stored } }
    func record(_ error: any Error) { lock.withLock { stored = error } }
  }

  private final class Memory: DoryPCGuestMemoryDeviceExecutionGuard, @unchecked Sendable {
    private struct ReadGate {
      let entered: DispatchSemaphore
      let resume: DispatchSemaphore
    }
    let readEntered = DispatchSemaphore(value: 0)
    let resumeRead = DispatchSemaphore(value: 0)
    let guardWaiting = DispatchSemaphore(value: 0)
    private let bus: DoryPCPhysicalMemoryBus
    private let guardedDMA: DoryPCDMAGuestMemory?
    private let lock = NSLock()
    private var writes = 0
    private var heldReads: [UInt64: ReadGate] = [:]
    private var callbackAddress: UInt64?
    private var readCallback: (@Sendable () -> Void)?
    private var guardReturned: (@Sendable () -> Void)?
    var writeCount: Int { lock.withLock { writes } }
    init(_ bus: DoryPCPhysicalMemoryBus, guardedExecution: Bool = false) {
      self.bus = bus
      guardedDMA = guardedExecution ? DoryPCDMAGuestMemory(bus: bus) : nil
    }
    func onExecutionGuardReturn(_ callback: @escaping @Sendable () -> Void) {
      lock.withLock { guardReturned = callback }
    }
    func withDeviceExecutionGuard(_ body: () -> Void) {
      guard let guardedDMA else { body(); return }
      let asynchronous = !bus.deviceAccessCoordinator.isActiveOnCurrentThread
      if asynchronous { guardWaiting.signal() }
      guardedDMA.withDeviceExecutionGuard(body)
      if asynchronous { lock.withLock { guardReturned }?() }
    }
    func holdRead(at address: UInt64) {
      holdRead(at: address, entered: readEntered, resume: resumeRead)
    }
    func holdRead(at address: UInt64, entered: DispatchSemaphore, resume: DispatchSemaphore) {
      lock.withLock { heldReads[address] = .init(entered: entered, resume: resume) }
    }
    func onNextRead(at address: UInt64, _ callback: @escaping @Sendable () -> Void) {
      lock.withLock {
        callbackAddress = address
        readCallback = callback
      }
    }
    func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
      let bytes = try guardedDMA?.read(at: address, byteCount: byteCount)
        ?? bus.read(at: address, byteCount: byteCount)
      let callbacks = lock.withLock { () -> (ReadGate?, (@Sendable () -> Void)?) in
        let gate = heldReads.removeValue(forKey: address)
        guard callbackAddress == address else { return (gate, nil) }
        let callback = readCallback
        callbackAddress = nil
        readCallback = nil
        return (gate, callback)
      }
      callbacks.1?()
      if let gate = callbacks.0 {
        gate.entered.signal()
        _ = gate.resume.wait(timeout: .now() + 2)
      }
      return bytes
    }
    func validate(at address: UInt64, byteCount: Int, deviceWillWrite: Bool) throws {
      if let guardedDMA {
        try guardedDMA.validate(at: address, byteCount: byteCount, deviceWillWrite: deviceWillWrite)
        return
      }
      _ = try bus.read(at: address, byteCount: byteCount)
    }
    func write(at address: UInt64, bytes: [UInt8]) throws {
      lock.withLock { writes += 1 }
      if let guardedDMA { try guardedDMA.write(at: address, bytes: bytes); return }
      try bus.write(at: address, bytes: bytes)
    }
    func synchronize() { guardedDMA?.synchronize() }
  }
}

private func bytes<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
  (0..<MemoryLayout<T>.size).map { UInt8(truncatingIfNeeded: value >> T($0 * 8)) }
}

private func value32(_ bytes: [UInt8]) -> UInt32 {
  bytes.enumerated().reduce(0) { $0 | UInt32($1.element) << UInt32($1.offset * 8) }
}

private func value64(_ bytes: [UInt8]) -> UInt64 {
  bytes.enumerated().reduce(0) { $0 | UInt64($1.element) << UInt64($1.offset * 8) }
}
