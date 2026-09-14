import Foundation
import Testing

@testable import DoryDBTX86

// Intel SDM Vol. 1 §13.4 and Vol. 2B XSAVE/XRSTOR. This suite qualifies the
// standard x87+SSE layout and, when AVX is admitted, its YMM_Hi128 extension.
// XSAVEOPT and compacted layouts remain unavailable.
@Suite struct DoryX86XStateTransferTests {
  private let profile = DoryX86CPUProfile(
    identifier: "test-only.base-xsave",
    features: DoryX86CPUProfile.compatibleV1.features.union([.xsave]),
    physicalAddressBits: 40, linearAddressBits: 48, virtualTSCFrequencyHz: 1_000_000_000,
    allowingUnqualifiedSIMDAndExtendedState: true)
  private let avxProfile = DoryX86CPUProfile(
    identifier: "test-only.avx-xsave",
    features: DoryX86CPUProfile.compatibleV1.features.union([.xsave, .avx]),
    physicalAddressBits: 40, linearAddressBits: 48, virtualTSCFrequencyHz: 1_000_000_000,
    allowingUnqualifiedSIMDAndExtendedState: true)

  @Test func userModeRoundTripsBaseX87AndSSEStateThroughStandardLayout() throws {
    let memory = try fixtureMemory()
    var state = try initialState()
    try memory.write(at: 0x21A0, bytes: Array(repeating: 0xE7, count: 96))
    let interpreter = DoryX86Interpreter(profile: profile)

    try expectRetired(interpreter.step(state: &state, memory: memory, mode: .long64), at: 0x1000)
    let image = try memory.read(at: 0x2000, byteCount: 576)
    #expect(Array(image[512..<520]) == [3] + Array(repeating: 0, count: 7))
    #expect(image[520..<576].allSatisfy { $0 == 0 })
    #expect(Array(image[416..<512]) == Array(repeating: 0xE7, count: 96))

    var saved = state.floatingPoint
    saved.xstateInUseMask = state.registers.rax
    state.floatingPoint.x87ControlWord = 0x027F
    state.floatingPoint.mxcsr = 0x1F80
    state.floatingPoint.ymm[0] = try .init(
      bytes: Array(repeating: 0xD3, count: 16) + Array(saved.ymm[0].bytes.suffix(16)),
      expectedByteCount: 32)
    state.rip = 0x1010
    try expectRetired(interpreter.step(state: &state, memory: memory, mode: .long64), at: 0x1010)
    #expect(state.floatingPoint == saved)
  }

  @Test func avxRoundTripsYMMHi128Through832ByteStandardLayout() throws {
    let memory = try fixtureMemory()
    var state = try initialState()
    state.control.xcr0 = 7
    state.registers.rax = 7
    for index in 0..<16 {
      state.floatingPoint.ymm[index] = try .init(
        bytes: Array(repeating: UInt8(index), count: 16)
          + Array(repeating: UInt8(0xA0 + index), count: 16),
        expectedByteCount: 32)
    }
    var saved = state.floatingPoint
    saved.xstateInUseMask = state.registers.rax
    let interpreter = DoryX86Interpreter(profile: avxProfile)

    try expectRetired(interpreter.step(state: &state, memory: memory, mode: .long64), at: 0x1000)
    let image = try memory.read(at: 0x2000, byteCount: 832)
    #expect(Array(image[512..<520]) == [7] + Array(repeating: 0, count: 7))
    for index in 0..<16 {
      #expect(Array(image[576 + index * 16..<576 + (index + 1) * 16])
        == Array(repeating: UInt8(0xA0 + index), count: 16))
    }

    state.floatingPoint.ymm[0] = try .init(bytes: Array(repeating: 0xD3, count: 32), expectedByteCount: 32)
    state.floatingPoint.ymm[15] = try .init(bytes: Array(repeating: 0xC4, count: 32), expectedByteCount: 32)
    state.rip = 0x1010
    try expectRetired(interpreter.step(state: &state, memory: memory, mode: .long64), at: 0x1010)
    #expect(state.floatingPoint == saved)
  }

  @Test func requestedInitialYMMHi128RestoreZerosOnlyUpperHalves() throws {
    let memory = try fixtureMemory()
    var state = try initialState()
    state.control.xcr0 = 7
    state.registers.rax = 4
    state.rip = 0x1010
    state.floatingPoint.ymm[0] = try .init(
      bytes: Array(repeating: 0x71, count: 16) + Array(repeating: 0xD3, count: 16),
      expectedByteCount: 32)
    try memory.write(at: 0x2000, bytes: Array(repeating: 0, count: 832))

    try expectRetired(
      DoryX86Interpreter(profile: avxProfile).step(state: &state, memory: memory, mode: .long64),
      at: 0x1010)
    #expect(Array(state.floatingPoint.ymm[0].bytes.prefix(16)) == Array(repeating: 0x71, count: 16))
    #expect(Array(state.floatingPoint.ymm[0].bytes.suffix(16)) == Array(repeating: 0, count: 16))
  }

  @Test func ymmOnlySaveUsesXINUSEForXStateBV() throws {
    let memory = try fixtureMemory()
    var state = try initialState()
    state.control.xcr0 = 7
    state.registers.rax = 4
    state.floatingPoint.ymm = .init(repeating: .ymmZero(), count: 16)
    state.floatingPoint.mxcsr = 0x1FA0

    try expectRetired(
      DoryX86Interpreter(profile: avxProfile).step(state: &state, memory: memory, mode: .long64),
      at: 0x1000)
    let image = try memory.read(at: 0x2000, byteCount: 832)
    #expect(Array(image[512..<520]) == Array(repeating: 0, count: 8))
    #expect(Array(image[24..<28]) == [0xA0, 0x1F, 0, 0])
    #expect(Array(image[28..<32]) == [0xFF, 0xFF, 0, 0])
  }

  @Test func ymmOnlyRestoreTransfersAndValidatesMXCSRWithoutXMMData() throws {
    let memory = try fixtureMemory()
    var state = try initialState()
    state.control.xcr0 = 7
    state.registers.rax = 4
    state.rip = 0x1010
    state.floatingPoint.ymm[0] = try .init(
      bytes: Array(repeating: 0x71, count: 16) + Array(repeating: 0xD3, count: 16),
      expectedByteCount: 32)
    var image = [UInt8](repeating: 0, count: 832)
    image.replaceSubrange(24..<28, with: [0xA0, 0x1F, 0, 0])
    image.replaceSubrange(28..<32, with: [0xBF, 0x1F, 0, 0])
    image.replaceSubrange(576..<592, with: Array(repeating: 0xA4, count: 16))
    image[512] = 4
    try memory.write(at: 0x2000, bytes: image)
    let interpreter = DoryX86Interpreter(profile: avxProfile)

    try expectRetired(interpreter.step(state: &state, memory: memory, mode: .long64), at: 0x1010)
    #expect(state.floatingPoint.mxcsr == 0x1FA0)
    #expect(state.floatingPoint.mxcsrMask == 0xFFFF)
    #expect(Array(state.floatingPoint.ymm[0].bytes.prefix(16)) == Array(repeating: 0x71, count: 16))
    #expect(Array(state.floatingPoint.ymm[0].bytes.suffix(16)) == Array(repeating: 0xA4, count: 16))

    image.replaceSubrange(24..<28, with: [0, 0, 0, 0x80])
    try memory.write(at: 0x2000, bytes: image)
    state.rip = 0x1010
    let before = state
    #expect(interpreter.step(state: &state, memory: memory, mode: .long64) == gp(at: 0x1010))
    #expect(state == before)
  }

  @Test func avxSSEOnlyRequestUses576ByteFootprint() throws {
    let saveMemory = try XStateTransferMemory(
      code: [0x0F, 0xAE, 0x23], bytes: Array(repeating: 0, count: 576))
    var state = try initialState()
    state.control.xcr0 = 7
    state.registers.rax = 2
    let savedMXCSR = state.floatingPoint.mxcsr
    let savedXMM = Array(state.floatingPoint.ymm[0].bytes.prefix(16))
    let interpreter = DoryX86Interpreter(profile: avxProfile)

    try expectRetired(interpreter.step(state: &state, memory: saveMemory, mode: .long64), at: 0x1000)
    #expect(saveMemory.preflights == [0x2000..<0x2240])

    let restoreMemory = try XStateTransferMemory(
      code: [0x0F, 0xAE, 0x2B], codeAddress: 0x1010, bytes: saveMemory.bytes)
    state.floatingPoint.mxcsr = 0x1F80
    state.floatingPoint.ymm[0] = try .init(bytes: Array(repeating: 0xD3, count: 32), expectedByteCount: 32)
    state.rip = 0x1010
    try expectRetired(interpreter.step(state: &state, memory: restoreMemory, mode: .long64), at: 0x1010)
    #expect(restoreMemory.reads == [0x2000..<0x2240])
    #expect(state.floatingPoint.mxcsr == savedMXCSR)
    #expect(Array(state.floatingPoint.ymm[0].bytes.prefix(16)) == savedXMM)
  }

  @Test func avxPartialSavePreservesUnrequestedYMMHi128AndHeader() throws {
    let memory = try fixtureMemory()
    var state = try initialState()
    state.control.xcr0 = 7
    state.registers.rax = 2
    var header = [UInt8](repeating: 0xD4, count: 64)
    header[0] = 0x05
    try memory.write(at: 0x2000, bytes: Array(repeating: 0xC3, count: 832))
    try memory.write(at: 0x2000 + 512, bytes: header)
    let upperHalves = try memory.read(at: 0x2000 + 576, byteCount: 256)

    try expectRetired(
      DoryX86Interpreter(profile: avxProfile).step(state: &state, memory: memory, mode: .long64),
      at: 0x1000)
    let image = try memory.read(at: 0x2000, byteCount: 832)
    header[0] = 0x07
    #expect(Array(image[512..<576]) == header)
    #expect(Array(image[576..<832]) == upperHalves)
  }

  @Test func featureOSXSAVEMasksAndAlignmentFaultBeforeDataTransfer() throws {
    let code = try fixtureMemory()
    var baseline = try initialState()
    let beforeBaseline = baseline
    #expect(DoryX86Interpreter().step(state: &baseline, memory: code, mode: .long64) == ud())
    #expect(baseline == beforeBaseline)

    var noOSXSAVE = try initialState()
    noOSXSAVE.control.cr4 &= ~(1 << 18)
    let beforeNoOSXSAVE = noOSXSAVE
    #expect(DoryX86Interpreter(profile: profile).step(state: &noOSXSAVE, memory: code, mode: .long64) == ud())
    #expect(noOSXSAVE == beforeNoOSXSAVE)

    // XSAVE/XRSTOR are not x87 instructions: CR0.EM does not cause #NM. Only
    // CR0.TS blocks the transfer after OSXSAVE has been enabled.
    var emOnly = try initialState()
    emOnly.control.cr0 |= 1 << 2
    try expectRetired(
      DoryX86Interpreter(profile: profile).step(state: &emOnly, memory: code, mode: .long64),
      at: 0x1000)

    var taskSwitched = try initialState()
    taskSwitched.control.cr0 |= 1 << 3
    let beforeTaskSwitched = taskSwitched
    #expect(
      DoryX86Interpreter(profile: profile).step(state: &taskSwitched, memory: code, mode: .long64)
        == nm())
    #expect(taskSwitched == beforeTaskSwitched)

    for request: UInt64 in [4, 3] {
      var state = try initialState()
      state.registers.rax = request
      if request == 3 { state.registers.rbx = 0x2001 }
      if request == 4 { state.control.xcr0 = 7 } // Unsupported effective component.
      let before = state
      #expect(DoryX86Interpreter(profile: profile).step(state: &state, memory: code, mode: .long64) == gp())
      #expect(state == before)
    }
  }

  @Test func partialSSESaveIncludesMXCSRAndPreservesUnrequestedStateAndHeader() throws {
    let memory = try fixtureMemory()
    var state = try initialState()
    state.registers.rax = 2
    var header = [UInt8](repeating: 0xD4, count: 64)
    header[0] = 0x05
    try memory.write(at: 0x2000, bytes: Array(repeating: 0xC3, count: 576))
    try memory.write(at: 0x2000 + 512, bytes: header)
    let x87Prefix = try memory.read(at: 0x2000, byteCount: 24)
    let x87Registers = try memory.read(at: 0x2000 + 32, byteCount: 128)

    try expectRetired(
      DoryX86Interpreter(profile: profile).step(state: &state, memory: memory, mode: .long64),
      at: 0x1000)
    let image = try memory.read(at: 0x2000, byteCount: 576)
    #expect(Array(image[0..<24]) == x87Prefix)
    #expect(Array(image[32..<160]) == x87Registers)
    #expect(Array(image[24..<28]) == [0xA0, 0x1F, 0, 0])
    #expect(Array(image[28..<32]) == [0xFF, 0xFF, 0, 0])
    header[0] = 0x07
    #expect(Array(image[512..<576]) == header)
  }

  @Test func sseRestoreIgnoresMXCSRMaskAndInitializesClearComponent() throws {
    let memory = try fixtureMemory()
    var state = try initialState()
    state.registers.rax = 2
    state.rip = 0x1010
    var image = [UInt8](repeating: 0, count: 576)
    image.replaceSubrange(24..<28, with: [0xA0, 0x1F, 0, 0])
    image.replaceSubrange(28..<32, with: [0xBF, 0x1F, 0, 0])
    image.replaceSubrange(160..<176, with: Array(repeating: 0x71, count: 16))
    image[512] = 2
    try memory.write(at: 0x2000, bytes: image)
    let preservedX87 = state.floatingPoint.x87
    let interpreter = DoryX86Interpreter(profile: profile)

    try expectRetired(interpreter.step(state: &state, memory: memory, mode: .long64), at: 0x1010)
    #expect(state.floatingPoint.x87 == preservedX87)
    #expect(state.floatingPoint.mxcsr == 0x1FA0)
    #expect(state.floatingPoint.mxcsrMask == 0xFFFF)
    #expect(Array(state.floatingPoint.ymm[0].bytes.prefix(16)) == Array(repeating: 0x71, count: 16))

    state.floatingPoint.mxcsr = 0
    state.floatingPoint.ymm[0] = try .init(
      bytes: Array(repeating: 0xD3, count: 32), expectedByteCount: 32)
    image[512] = 0
    try memory.write(at: 0x2000, bytes: image)
    state.rip = 0x1010
    try expectRetired(interpreter.step(state: &state, memory: memory, mode: .long64), at: 0x1010)
    #expect(state.floatingPoint.mxcsr == 0x1FA0)
    #expect(Array(state.floatingPoint.ymm[0].bytes.prefix(16)) == Array(repeating: 0, count: 16))
  }

  @Test func rexWControlsX87PointerWidthForXSAVEAndXRSTOR() throws {
    for rexW in [false, true] {
      let memory = try fixtureMemory()
      let saveBytes: [UInt8] = rexW ? [0x48, 0x0F, 0xAE, 0x23] : [0x0F, 0xAE, 0x23]
      let restoreBytes: [UInt8] = rexW ? [0x48, 0x0F, 0xAE, 0x2B] : [0x0F, 0xAE, 0x2B]
      try memory.write(at: 0x1000, bytes: saveBytes)
      try memory.write(at: 0x1010, bytes: restoreBytes)
      try memory.write(at: 0x2000 + 24, bytes: Array(repeating: 0xC3, count: 8))
      var state = try initialState()
      state.registers.rax = 1
      state.floatingPoint.x87InstructionPointer = 0x1122_3344_5566_7788
      state.floatingPoint.x87InstructionSelector = 0xBEEF
      state.floatingPoint.x87DataPointer = 0x8877_6655_4433_2211
      state.floatingPoint.x87DataSelector = 0xCAFE
      let interpreter = DoryX86Interpreter(profile: profile)

      #expect(interpreter.step(state: &state, memory: memory, mode: .long64)
        == .retired(try DoryX86Decoder().decode(saveBytes, at: 0x1000, mode: .long64)))
      let image = try memory.read(at: 0x2000, byteCount: 32)
      #expect(Array(image[24..<32]) == Array(repeating: 0xC3, count: 8))
      if rexW {
        #expect(Array(image[8..<16]) == [0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11])
        #expect(Array(image[16..<24]) == [0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88])
      } else {
        #expect(Array(image[8..<14]) == [0x88, 0x77, 0x66, 0x55, 0xEF, 0xBE])
        #expect(Array(image[16..<22]) == [0x11, 0x22, 0x33, 0x44, 0xFE, 0xCA])
      }

      state.floatingPoint.x87InstructionPointer = 0
      state.floatingPoint.x87InstructionSelector = 0
      state.floatingPoint.x87DataPointer = 0
      state.floatingPoint.x87DataSelector = 0
      state.rip = 0x1010
      #expect(interpreter.step(state: &state, memory: memory, mode: .long64)
        == .retired(try DoryX86Decoder().decode(restoreBytes, at: 0x1010, mode: .long64)))
      #expect(state.floatingPoint.x87InstructionPointer ==
        (rexW ? 0x1122_3344_5566_7788 : 0x5566_7788))
      #expect(state.floatingPoint.x87InstructionSelector == (rexW ? 0 : 0xBEEF))
      #expect(state.floatingPoint.x87DataPointer ==
        (rexW ? 0x8877_6655_4433_2211 : 0x4433_2211))
      #expect(state.floatingPoint.x87DataSelector == (rexW ? 0 : 0xCAFE))
    }
  }

  @Test func reservedOrCompactedHeaderFailsAtomicallyBeforeRestore() throws {
    let memory = try fixtureMemory()
    var state = try initialState()
    let interpreter = DoryX86Interpreter(profile: profile)
    try expectRetired(interpreter.step(state: &state, memory: memory, mode: .long64), at: 0x1000)
    for (offset, value) in [(520, UInt8(1)), (527, UInt8(0x80))] {
      state.floatingPoint.mxcsr = 0x1F80
      state.floatingPoint.ymm[0] = try .init(
        bytes: Array(repeating: 0xD3, count: 32), expectedByteCount: 32)
      state.rip = 0x1010
      try memory.write(at: 0x2000 + UInt64(offset), bytes: [value])
      let before = state
      #expect(interpreter.step(state: &state, memory: memory, mode: .long64) == gp(at: 0x1010))
      #expect(state == before)
      try memory.write(at: 0x2000 + UInt64(offset), bytes: [0])
    }
  }

  @Test func saveWritePreflightFaultPublishesNoPartialExtendedStateImage() throws {
    let faultAddress: UInt64 = 0x223F
    let destination = [UInt8](repeating: 0xE7, count: 576)
    let memory = try XStateTransferMemory(
      code: [0x0F, 0xAE, 0x23], bytes: destination,
      preflightFailure: .pageFault(address: faultAddress, errorCode: 7))
    var state = try initialState()
    let before = state

    #expect(DoryX86Interpreter(profile: profile).step(state: &state, memory: memory, mode: .long64)
      == pageFault(address: faultAddress, code: 7))
    var expected = before
    expected.control.cr2 = faultAddress
    #expect(state == expected)
    #expect(memory.preflights == [0x2000..<0x2240])
    #expect(memory.reads.isEmpty && memory.writes.isEmpty)
    #expect(memory.bytes == destination)
  }

  @Test func restoreReadFaultPublishesNoPartialFloatingPointState() throws {
    let faultAddress: UInt64 = 0x2000
    let memory = try XStateTransferMemory(
      code: [0x0F, 0xAE, 0x2B], codeAddress: 0x1010, bytes: Array(repeating: 0x71, count: 576),
      readFailure: .pageFault(address: faultAddress, errorCode: 4))
    var state = try initialState()
    state.rip = 0x1010
    let before = state

    #expect(DoryX86Interpreter(profile: profile).step(state: &state, memory: memory, mode: .long64)
      == pageFault(address: faultAddress, code: 4, at: 0x1010))
    var expected = before
    expected.control.cr2 = faultAddress
    #expect(state == expected)
    #expect(memory.reads == [0x2000..<0x2240])
    #expect(memory.preflights.isEmpty && memory.writes.isEmpty)
  }

  @Test(arguments: [UInt64(4), UInt64(7)])
  func avx832ByteDestinationAndSourceFaultWithoutPartialTransfer(request: UInt64) throws {
    let destination = [UInt8](repeating: 0xE7, count: 831)
    let saveMemory = try XStateTransferMemory(code: [0x0F, 0xAE, 0x23], bytes: destination)
    var saveState = try initialState()
    saveState.control.xcr0 = 7
    saveState.registers.rax = request
    let beforeSave = saveState

    #expect(DoryX86Interpreter(profile: avxProfile).step(
      state: &saveState, memory: saveMemory, mode: .long64) == pageFault(address: 0x2000, code: 2))
    var expectedSave = beforeSave
    expectedSave.control.cr2 = 0x2000
    #expect(saveState == expectedSave)
    #expect(saveMemory.preflights == [0x2000..<0x2340])
    #expect(saveMemory.reads.isEmpty && saveMemory.writes.isEmpty)
    #expect(saveMemory.bytes == destination)

    let source = [UInt8](repeating: 0x71, count: 831)
    let restoreMemory = try XStateTransferMemory(
      code: [0x0F, 0xAE, 0x2B], codeAddress: 0x1010, bytes: source)
    var restoreState = try initialState()
    restoreState.control.xcr0 = 7
    restoreState.registers.rax = request
    restoreState.rip = 0x1010
    let beforeRestore = restoreState

    #expect(DoryX86Interpreter(profile: avxProfile).step(
      state: &restoreState, memory: restoreMemory, mode: .long64)
      == pageFault(address: 0x2000, code: 0, at: 0x1010))
    var expectedRestore = beforeRestore
    expectedRestore.control.cr2 = 0x2000
    #expect(restoreState == expectedRestore)
    #expect(restoreMemory.reads == [0x2000..<0x2340])
    #expect(restoreMemory.preflights.isEmpty && restoreMemory.writes.isEmpty)
  }

  @Test func fxrstorRestoresMXCSRAndRejectsReservedBitsAtomically() throws {
    let memory = try fixtureMemory()
    let code: [UInt8] = [0x0F, 0xAE, 0x0B] // FXRSTOR [RBX]
    try memory.write(at: 0x1010, bytes: code)
    var state = try initialState()
    state.control.cr4 |= 1 << 9
    state.rip = 0x1010
    var image = [UInt8](repeating: 0, count: 512)
    image.replaceSubrange(24..<28, with: [0x80, 0x3F, 0, 0])
    image.replaceSubrange(28..<32, with: [0xFF, 0xFF, 0xFF, 0xFF])
    try memory.write(at: 0x2000, bytes: image)
    let interpreter = DoryX86Interpreter(profile: profile)
    #expect(interpreter.step(state: &state, memory: memory, mode: .long64)
      == .retired(try DoryX86Decoder().decode(code, at: 0x1010, mode: .long64)))
    #expect(state.floatingPoint.mxcsr == 0x3F80)
    #expect(state.floatingPoint.mxcsrMask == 0xFFFF)

    image[27] = 0x80
    try memory.write(at: 0x2000, bytes: image)
    state.rip = 0x1010
    let before = state
    #expect(interpreter.step(state: &state, memory: memory, mode: .long64) == gp(at: 0x1010))
    #expect(state == before)
    #expect(try memory.read(at: 0x2000, byteCount: 512) == image)
  }

  @Test func xrstorMXCSRIsIndependentOfComponentPresenceAndImageMask() throws {
    for request: UInt64 in [2, 4] {
      for present: UInt8 in [0, UInt8(request)] {
        let memory = try fixtureMemory()
        var state = try initialState()
        state.control.xcr0 = 7
        state.registers.rax = request
        state.rip = 0x1010
        state.floatingPoint.mxcsrMask = 0xFFBF
        var image = [UInt8](repeating: 0, count: request == 2 ? 576 : 832)
        image.replaceSubrange(24..<28, with: [0x80, 0x3F, 0, 0])
        image.replaceSubrange(28..<32, with: [0xFF, 0xFF, 0xFF, 0xFF])
        image[512] = present
        try memory.write(at: 0x2000, bytes: image)
        let interpreter = DoryX86Interpreter(profile: avxProfile)
        try expectRetired(interpreter.step(state: &state, memory: memory, mode: .long64), at: 0x1010)
        #expect(state.floatingPoint.mxcsr == 0x3F80)
        #expect(state.floatingPoint.mxcsrMask == 0xFFBF)

        // A previous image cannot enable DAZ in this processor's validity mask.
        for invalid: [UInt8] in [[0xC0, 0x3F, 0, 0], [0, 0, 0, 0x80]] {
          image.replaceSubrange(24..<28, with: invalid)
          try memory.write(at: 0x2000, bytes: image)
          state.rip = 0x1010
          let before = state
          #expect(interpreter.step(state: &state, memory: memory, mode: .long64) == gp(at: 0x1010))
          #expect(state == before)
          #expect(try memory.read(at: 0x2000, byteCount: image.count) == image)
        }
      }
    }
  }

  @Test func nonLongModeYMMTransfersPreserveHighEightSlotsAndRegisters() throws {
    for mode: DoryX86ExecutionMode in [.real16, .protected16, .protected32] {
      let memory = try fixtureMemory()
      let rm: UInt8 = mode == .protected32 ? 3 : 7 // [EBX] or [BX]
      let saveCode: [UInt8] = [0x0F, 0xAE, 0x20 | rm]
      let restoreCode: [UInt8] = [0x0F, 0xAE, 0x28 | rm]
      try memory.write(at: 0x1000, bytes: saveCode)
      try memory.write(at: 0x1010, bytes: restoreCode)
      var state = try initialState()
      state.cs = .init(attributes: mode == .protected32 ? 0xC09B : 0x009B, limit: .max)
      state.control.cr0 = mode == .real16 ? 0x10 : 0x11
      state.control.xcr0 = 7
      state.registers.rax = 4
      for index in 0..<16 {
        state.floatingPoint.ymm[index] = try .init(
          bytes: Array(repeating: UInt8(index + 1), count: 32), expectedByteCount: 32)
      }
      var image = [UInt8](repeating: 0, count: 832)
      image.replaceSubrange(704..<832, with: repeatElement(0xE7, count: 128))
      try memory.write(at: 0x2000, bytes: image)
      let interpreter = DoryX86Interpreter(profile: avxProfile)
      #expect(interpreter.step(state: &state, memory: memory, mode: mode)
        == .retired(try DoryX86Decoder().decode(saveCode, at: 0x1000, mode: mode)))
      image = try memory.read(at: 0x2000, byteCount: 832)
      for index in 0..<8 {
        #expect(Array(image[576 + index * 16..<592 + index * 16])
          == Array(repeating: UInt8(index + 1), count: 16))
      }
      #expect(Array(image[704..<832]) == Array(repeating: 0xE7, count: 128))
      let preserved = state.floatingPoint.ymm
      for present: UInt8 in [4, 0] {
        image[512] = present
        image.replaceSubrange(576..<704, with: repeatElement(0xA4, count: 128))
        try memory.write(at: 0x2000, bytes: image)
        state.rip = 0x1010
        #expect(interpreter.step(state: &state, memory: memory, mode: mode)
          == .retired(try DoryX86Decoder().decode(restoreCode, at: 0x1010, mode: mode)))
        for index in 0..<8 {
          #expect(state.floatingPoint.ymm[index].bytes.prefix(16) == preserved[index].bytes.prefix(16))
          #expect(Array(state.floatingPoint.ymm[index].bytes.suffix(16))
            == Array(repeating: present == 4 ? 0xA4 : 0, count: 16))
        }
        #expect(Array(state.floatingPoint.ymm[8..<16]) == Array(preserved[8..<16]))
      }
    }
  }

  @Test func restoredZeroYMMUseSurvivesStateCopySnapshotAndSaveThenClearsOnInit() throws {
    let memory = try fixtureMemory()
    var state = try initialState()
    state.control.xcr0 = 7
    state.registers.rax = 4
    state.rip = 0x1010
    var image = [UInt8](repeating: 0, count: 832)
    image[512] = 4
    try memory.write(at: 0x2000, bytes: image)
    let interpreter = DoryX86Interpreter(profile: avxProfile)
    try expectRetired(interpreter.step(state: &state, memory: memory, mode: .long64), at: 0x1010)
    #expect(state.floatingPoint.ymm.allSatisfy { $0.bytes.suffix(16).allSatisfy { $0 == 0 } })
    let copied = state
    state = try JSONDecoder().decode(DoryX86ArchitecturalState.self, from: JSONEncoder().encode(copied))
    #expect(state == copied)
    state.rip = 0x1000
    try expectRetired(interpreter.step(state: &state, memory: memory, mode: .long64), at: 0x1000)
    #expect(try memory.read(at: 0x2200, byteCount: 1) == [4])

    image[512] = 0
    try memory.write(at: 0x2000, bytes: image)
    state.rip = 0x1010
    try expectRetired(interpreter.step(state: &state, memory: memory, mode: .long64), at: 0x1010)
    state.rip = 0x1000
    try expectRetired(interpreter.step(state: &state, memory: memory, mode: .long64), at: 0x1000)
    #expect(try memory.read(at: 0x2200, byteCount: 1) == [0])

    // Old snapshots omit the new field and retain value-based use detection.
    let old = try JSONEncoder().encode(DoryX86FloatingPointState())
    #expect(!String(decoding: old, as: UTF8.self).contains("xstateInUseMask"))
    state.floatingPoint = try JSONDecoder().decode(DoryX86FloatingPointState.self, from: old)
    #expect(state.floatingPoint.xstateInUseMask == 0)
    state.floatingPoint.ymm[0] = try .init(bytes: Array(repeating: 1, count: 32), expectedByteCount: 32)
    state.rip = 0x1000
    try expectRetired(interpreter.step(state: &state, memory: memory, mode: .long64), at: 0x1000)
    #expect(try memory.read(at: 0x2200, byteCount: 1) == [4])
  }

  @Test func rawRequestsAreMaskedByXCR0BeforeFootprintAndSupportChecks() throws {
    for request: UInt64 in [0, 2, 4, 7] {
      let count = request & 4 == 0 ? 576 : 832
      let saveMemory = try XStateTransferMemory(
        code: [0x0F, 0xAE, 0x23], bytes: Array(repeating: 0, count: count))
      var state = try initialState()
      state.control.xcr0 = request & 4 == 0 ? 3 : 7
      state.registers.rax = request | (request & 4 == 0 ? 0x8000_0004 : 0x8000_0000)
      state.registers.rdx = 0x8000_0001
      let interpreter = DoryX86Interpreter(profile: avxProfile)
      try expectRetired(interpreter.step(state: &state, memory: saveMemory, mode: .long64), at: 0x1000)
      #expect(saveMemory.preflights == [0x2000..<0x2000 + UInt64(count)])
      #expect(saveMemory.bytes[512] == UInt8(request))
      let restoreMemory = try XStateTransferMemory(
        code: [0x0F, 0xAE, 0x2B], codeAddress: 0x1010, bytes: saveMemory.bytes)
      state.rip = 0x1010
      try expectRetired(interpreter.step(state: &state, memory: restoreMemory, mode: .long64), at: 0x1010)
      #expect(restoreMemory.reads == [0x2000..<0x2000 + UInt64(count)])
    }
  }

  @Test func xstateHeaderValidationIsIndependentOfEffectiveRequest() throws {
    for (xcr0, header): (UInt64, UInt8) in [(3, 4), (7, 8)] {
      let memory = try fixtureMemory()
      var state = try initialState()
      state.control.xcr0 = xcr0
      state.registers.rax = 0
      state.registers.rdx = 0x8000_0000
      state.rip = 0x1010
      var image = [UInt8](repeating: 0, count: 576)
      image[512] = header
      try memory.write(at: 0x2000, bytes: image)
      let before = state
      #expect(DoryX86Interpreter(profile: avxProfile).step(state: &state, memory: memory, mode: .long64)
        == gp(at: 0x1010))
      #expect(state == before)
    }
  }

  private func fixtureMemory() throws -> DoryX86ByteArrayMemory {
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, byteCount: 0x2000)
    try memory.write(at: 0x1000, bytes: [0x0F, 0xAE, 0x23]) // XSAVE [RBX]
    try memory.write(at: 0x1010, bytes: [0x0F, 0xAE, 0x2B]) // XRSTOR [RBX]
    return memory
  }

  private func initialState() throws -> DoryX86ArchitecturalState {
    var floatingPoint = try DoryX86FloatingPointState(x87ControlWord: 0x027F, mxcsr: 0x1FA0)
    floatingPoint.x87[0] = try .init(
      bytes: [1, 2, 3, 4, 5, 6, 7, 0x80, 0xFF, 0x3F], expectedByteCount: 10)
    floatingPoint.x87TagWord = 0xFFFC
    floatingPoint.ymm[0] = try .init(bytes: Array(repeating: 0x5A, count: 32), expectedByteCount: 32)
    return try .init(registers: .init(rax: 3, rbx: 0x2000), rip: 0x1000,
      cs: .init(selector: 3, attributes: 0xA0FB, limit: .max),
      control: .init(cr0: 0x11, cr4: 1 << 18, xcr0: 3), floatingPoint: floatingPoint)
  }

  private func expectRetired(_ result: DoryX86InterpreterResult, at address: UInt64) throws {
    let bytes: [UInt8] = address == 0x1000 ? [0x0F, 0xAE, 0x23] : [0x0F, 0xAE, 0x2B]
    #expect(result == .retired(try DoryX86Decoder().decode(bytes, at: address, mode: .long64)))
  }

  private func ud() -> DoryX86InterpreterResult {
    .exception(.init(kind: .invalidOpcode, vector: 6, instructionPointer: 0x1000))
  }

  private func nm() -> DoryX86InterpreterResult {
    .exception(.init(kind: .deviceNotAvailable, vector: 7, instructionPointer: 0x1000))
  }

  private func gp(at address: UInt64 = 0x1000) -> DoryX86InterpreterResult {
    .exception(.init(kind: .generalProtection, vector: 13, errorCode: 0, instructionPointer: address))
  }

  private func pageFault(
    address: UInt64, code: UInt32, at instructionPointer: UInt64 = 0x1000
  ) -> DoryX86InterpreterResult {
    .exception(.init(kind: .pageFault, vector: 14, errorCode: code,
      instructionPointer: instructionPointer, linearAddress: address))
  }
}

private final class XStateTransferMemory: DoryX86Memory, @unchecked Sendable {
  private let code: DoryX86ByteArrayMemory
  private let image: DoryX86ByteArrayMemory
  private let preflightFailure: DoryX86MemoryError?
  private let readFailure: DoryX86MemoryError?
  private(set) var reads: [Range<UInt64>] = []
  private(set) var preflights: [Range<UInt64>] = []
  private(set) var writes: [Range<UInt64>] = []
  var bytes: [UInt8] { image.snapshot() }

  init(
    code: [UInt8], codeAddress: UInt64 = 0x1000, bytes: [UInt8],
    preflightFailure: DoryX86MemoryError? = nil,
    readFailure: DoryX86MemoryError? = nil
  ) throws {
    self.code = try .init(baseAddress: codeAddress, bytes: code)
    image = try .init(baseAddress: 0x2000, bytes: bytes)
    self.preflightFailure = preflightFailure
    self.readFailure = readFailure
  }

  func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8] {
    try code.instructionBytes(at: address, maximumCount: maximumCount)
  }

  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    reads.append(address..<address + UInt64(byteCount))
    if let readFailure { throw readFailure }
    return try image.read(at: address, byteCount: byteCount)
  }

  func validateRead(at address: UInt64, byteCount: Int) throws {
    try image.validateRead(at: address, byteCount: byteCount)
  }

  func write(at address: UInt64, bytes: [UInt8]) throws {
    writes.append(address..<address + UInt64(bytes.count))
    try image.write(at: address, bytes: bytes)
  }

  func validateWrite(at address: UInt64, byteCount: Int) throws {
    preflights.append(address..<address + UInt64(byteCount))
    if let preflightFailure { throw preflightFailure }
    try image.validateWrite(at: address, byteCount: byteCount)
  }

  func synchronize() {}
}
