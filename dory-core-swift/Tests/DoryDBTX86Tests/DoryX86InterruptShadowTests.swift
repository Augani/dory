import Foundation
import Testing

@testable import DoryDBTX86

@Suite struct DoryX86InterruptShadowTests {
  @Test func snapshotRoundTripAndOlderJSONDefault() throws {
    var shadowed = DoryX86ArchitecturalState.reset()
    shadowed.interruptShadow = .movSS
    let encoded = try JSONEncoder().encode(shadowed)
    #expect(try JSONDecoder().decode(DoryX86ArchitecturalState.self, from: encoded) == shadowed)

    var oldObject = try #require(
      JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    oldObject.removeValue(forKey: "interruptShadow")
    let oldData = try JSONSerialization.data(withJSONObject: oldObject)
    #expect(
      try JSONDecoder().decode(DoryX86ArchitecturalState.self, from: oldData)
        .interruptShadow == nil)
    #expect(DoryX86ArchitecturalState.reset().interruptShadow == nil)
  }

  @Test func stiCreatesShadowOnlyWhenItChangesIFAndFollowingRetirementConsumesIt() throws {
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: [0xFB, 0x90, 0xFB])
    var state = try realState(rip: 0x1000)
    let interpreter = DoryX86Interpreter()

    guard case .retired = interpreter.step(state: &state, memory: memory, mode: .real16) else {
      Issue.record("STI did not retire")
      return
    }
    #expect(state.rflags.contains(.interruptEnable))
    #expect(state.interruptShadow == .sti)

    guard case .retired = interpreter.step(state: &state, memory: memory, mode: .real16) else {
      Issue.record("instruction following STI did not retire")
      return
    }
    #expect(state.interruptShadow == nil)

    guard case .retired = interpreter.step(state: &state, memory: memory, mode: .real16) else {
      Issue.record("second STI did not retire")
      return
    }
    #expect(state.rflags.contains(.interruptEnable))
    #expect(state.interruptShadow == nil)
  }

  @Test func faultingFollowingInstructionKeepsShadowUntilEventDelivery() throws {
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: [0x0F, 0x0B])
    var state = try realState(rip: 0x1000, interruptShadow: .sti)
    let before = state

    guard
      case .exception(let exception) = DoryX86Interpreter().step(
        state: &state, memory: memory, mode: .real16)
    else {
      Issue.record("UD2 did not fault")
      return
    }
    #expect(exception.kind == .invalidOpcode)
    #expect(state == before)
  }

  @Test func movSSCreatesShadowOnlyAfterSuccessfulDescriptorLoad() throws {
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: [0x8E, 0xD0, 0x90])
    var state = try realState(rip: 0x1000)
    state.registers.rax = 0x1234
    let interpreter = DoryX86Interpreter()

    guard case .retired = interpreter.step(state: &state, memory: memory, mode: .real16) else {
      Issue.record("MOV SS did not retire")
      return
    }
    #expect(state.ss.selector == 0x1234)
    #expect(state.ss.base == 0x1_2340)
    #expect(state.interruptShadow == .movSS)

    guard case .retired = interpreter.step(state: &state, memory: memory, mode: .real16) else {
      Issue.record("instruction following MOV SS did not retire")
      return
    }
    #expect(state.interruptShadow == nil)

    let faultMemory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: [0x8E, 0xD0])
    var faultState = try protectedState(rip: 0x1000)
    faultState.registers.rax = 8
    let before = faultState
    guard
      case .exception(let exception) = interpreter.step(
        state: &faultState, memory: faultMemory, mode: .protected32)
    else {
      Issue.record("invalid MOV SS descriptor did not fault")
      return
    }
    #expect(exception.kind == .generalProtection)
    #expect(faultState == before)
  }

  @Test func aSecondShadowCreatingInstructionDoesNotExtendAnActiveShadow() throws {
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: [0x8E, 0xD0])
    var state = try realState(rip: 0x1000, interruptShadow: .sti)
    state.registers.rax = 0x20

    guard
      case .retired = DoryX86Interpreter().step(
        state: &state, memory: memory, mode: .real16)
    else {
      Issue.record("MOV SS following a shadow did not retire")
      return
    }
    #expect(state.ss.selector == 0x20)
    #expect(state.interruptShadow == nil)
  }

  @Test func popSSDecodesLegacyWidthsAndRejectsLongMode() throws {
    let decoder = DoryX86Decoder()
    #expect(
      try decoder.decode([0x17], at: 0x1000, mode: .real16).operation
        == .popSegment(.ss, width: .word))
    #expect(
      try decoder.decode([0x66, 0x17], at: 0x1000, mode: .real16).operation
        == .popSegment(.ss, width: .doubleword))
    #expect(
      try decoder.decode([0x17], at: 0x1000, mode: .protected32).operation
        == .popSegment(.ss, width: .doubleword))
    #expect(
      try decoder.decode([0x66, 0x17], at: 0x1000, mode: .protected32).operation
        == .popSegment(.ss, width: .word))
    #expect(throws: DoryX86DecodeError.self) {
      try decoder.decode([0x17], at: 0x1000, mode: .long64)
    }
  }

  @Test func popSSPublishesStackSegmentPointerAndShadowAtomically() throws {
    for (bytes, width, increment): ([UInt8], DoryX86OperandWidth, UInt64) in [
      ([0x17], .word, 2), ([0x66, 0x17], .doubleword, 4),
    ] {
      let memory = try DoryX86ByteArrayMemory(byteCount: 0x2000)
      try memory.write(at: 0x1000, bytes: bytes)
      try memory.write(at: 0x1800, bytes: [0x34, 0x12, 0xAA, 0xBB])
      var state = try realState(rip: 0x1000)
      state.registers.rsp = 0x1800

      guard
        case .retired(let decoded) = DoryX86Interpreter().step(
          state: &state, memory: memory, mode: .real16)
      else {
        Issue.record("POP SS did not retire")
        continue
      }
      #expect(decoded.operation == .popSegment(.ss, width: width))
      #expect(state.ss.selector == 0x1234)
      #expect(state.registers.rsp == 0x1800 + increment)
      #expect(state.interruptShadow == .movSS)
    }

    let memory = try DoryX86ByteArrayMemory(byteCount: 0x2000)
    try memory.write(at: 0x1000, bytes: [0x17])
    try memory.write(at: 0x1800, bytes: [8, 0, 0, 0])
    var state = try protectedState(rip: 0x1000)
    state.registers.rsp = 0x1800
    let before = state
    guard
      case .exception(let exception) = DoryX86Interpreter().step(
        state: &state, memory: memory, mode: .protected32)
    else {
      Issue.record("invalid POP SS descriptor did not fault")
      return
    }
    #expect(exception.kind == .generalProtection)
    #expect(state == before)
    #expect(try memory.read(at: 0x1800, byteCount: 4) == [8, 0, 0, 0])
  }

  @Test func externalDeliveryDoesNotConsumeShadowAndAcceptedEventClearsIt() throws {
    let memory = try DoryX86ByteArrayMemory(byteCount: 0x400)
    try memory.write(at: 0x80, bytes: [0, 2, 0, 0])
    var state = try realState(
      rip: 0x100, interruptShadow: .sti,
      rflags: [.reservedOne, .interruptEnable])
    state.registers.rsp = 0x300
    let before = state
    let delivery = DoryX86InterruptDelivery()

    try delivery.deliver(
      vector: 0x20, source: .externalMaskable, state: &state,
      physicalMemory: memory, mode: .real16)
    #expect(state == before)

    try delivery.deliver(
      vector: 0x20, source: .hardwareException, state: &state,
      physicalMemory: memory, mode: .real16)
    #expect(state.interruptShadow == nil)
    #expect(state.rip == 0x200)
    #expect(state.registers.rsp == 0x2FA)
  }

  @Test func acceptedNMIClearsShadowButBlockedNMIDoesNot() throws {
    let memory = try DoryX86ByteArrayMemory(byteCount: 0x400)
    try memory.write(at: 8, bytes: [0, 2, 0, 0])
    var state = try realState(
      rip: 0x100, interruptShadow: .sti,
      rflags: [.reservedOne, .interruptEnable])
    state.registers.rsp = 0x300
    let delivery = DoryX86InterruptDelivery()

    try delivery.deliver(
      vector: 2, source: .nonMaskable, state: &state,
      physicalMemory: memory, mode: .real16)
    #expect(state.interruptShadow == nil)
    #expect(state.nmiBlocked)

    state.interruptShadow = .movSS
    let blocked = state
    try delivery.deliver(
      vector: 2, source: .nonMaskable, state: &state,
      physicalMemory: memory, mode: .real16)
    #expect(state == blocked)

    var movSSBlocked = try realState(
      rip: 0x100, interruptShadow: .movSS,
      rflags: [.reservedOne, .interruptEnable])
    movSSBlocked.registers.rsp = 0x300
    let beforeMOVSSBlockedNMI = movSSBlocked
    try delivery.deliver(
      vector: 2, source: .nonMaskable, state: &movSSBlocked,
      physicalMemory: memory, mode: .real16)
    #expect(movSSBlocked == beforeMOVSSBlockedNMI)
  }

  @Test func bothNativeTiersDeclineEveryEntryPointWhileInterruptShadowIsActive() throws {
    #if arch(arm64)
      for optimization in [DoryARM64JITOptimization.baseline, .optimizing] {
        for shadow in [DoryX86InterruptShadow.sti, .movSS] {
          try assertNativeEntryDeclines(optimization: optimization, shadow: shadow)
        }
      }
    #endif
  }

  #if arch(arm64)
    @inline(never)
    private func assertNativeEntryDeclines(
      optimization: DoryARM64JITOptimization,
      shadow: DoryX86InterruptShadow
    ) throws {
      let code: [UInt8] = [0x48, 0xFF, 0xC0]
      let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: code)
      let executor = try DoryARM64BaselineExecutor(
        maximumCodeBytes: 4096, optimization: optimization)
      var state = try DoryX86ArchitecturalState(rip: 0x1000, interruptShadow: shadow)
      state.registers.rax = 41
      let beforeState = state
      let beforeMemory = memory.snapshot()
      let beforeDiagnostics = executor.diagnostics
      var fetchCount = 0

      let direct = try executor.execute(
        byteProvider: { count in
          fetchCount += 1
          return Array(code.prefix(count))
        }, at: state.rip, mode: .long64, addressSpaceID: 1,
        maximumInstructions: 1, state: &state, memory: memory)
      let summary = try executor.executeSummary(
        byteProvider: { count in
          fetchCount += 1
          return Array(code.prefix(count))
        }, at: state.rip, mode: .long64, addressSpaceID: 1,
        maximumInstructions: 1, state: &state, memory: memory)
      let chained = try executor.executeChainedSummary(
        byteProvider: { _, count in
          fetchCount += 1
          return Array(code.prefix(count))
        }, at: state.rip, mode: .long64, addressSpaceID: 1,
        maximumInstructions: 1, state: &state, memory: memory)

      #expect(direct == nil)
      #expect(summary == nil)
      #expect(chained == nil)
      #expect(fetchCount == 0)
      #expect(state == beforeState)
      #expect(memory.snapshot() == beforeMemory)
      #expect(executor.diagnostics == beforeDiagnostics)
    }
  #endif

  private func realState(
    rip: UInt64,
    interruptShadow: DoryX86InterruptShadow? = nil,
    rflags: DoryX86RFLAGS = .reset
  ) throws -> DoryX86ArchitecturalState {
    try DoryX86ArchitecturalState(
      rip: rip,
      rflags: rflags,
      cs: .init(selector: 0, attributes: 0x9B, limit: 0xFFFF),
      ss: .init(selector: 0, attributes: 0x93, limit: 0xFFFF),
      idtr: .init(limit: 0x3FF),
      interruptShadow: interruptShadow
    )
  }

  private func protectedState(rip: UInt64) throws -> DoryX86ArchitecturalState {
    var state = try DoryX86ArchitecturalState(
      rip: rip,
      cs: .init(selector: 8, attributes: 0xC09B, limit: .max),
      ss: .init(selector: 0x10, attributes: 0xC093, limit: .max),
      gdtr: .init(limit: 0)
    )
    state.control.cr0 |= 1
    return state
  }
}
