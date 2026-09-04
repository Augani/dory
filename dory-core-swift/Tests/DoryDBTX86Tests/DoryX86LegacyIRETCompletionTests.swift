import Testing

@testable import DoryDBTX86

// Intel SDM 092 Vol. 2A IRET/IRETD, pp. 3-491--497, and Vol. 3A
// §§3.4.5.1 and 11.1.2.1. These tests cover ordinary legacy protected-mode
// returns. Task and virtual-8086 returns remain outside the exposed contract.
@Suite struct DoryX86LegacyIRETCompletionTests {
  @Test func codeSelectorFailuresUseArchitecturalErrorCodes() throws {
    let cases: [(UInt8, UInt16, UInt64, UInt32)] = [
      (0, 0, 0, 0),
      (3, 8, codeDescriptor(dpl: 0), 8),
      (0, 8, dataDescriptor(dpl: 0), 8),
      (0, 0x1B, codeDescriptor(dpl: 0), 0x18),
      (0, 9, codeDescriptor(dpl: 2, conforming: true), 8),
    ]
    for (currentCPL, selector, descriptor, errorCode) in cases {
      let memory = try fixture(
        frame: [0x1234, UInt64(selector), 2, 0x3000, 0x23],
        descriptors: selector & 0xFFF8 == 0 ? [:] : [selector & 0xFFF8: descriptor],
        frameAddress: currentCPL == 3 ? 0x28000 : 0x18000
      )
      var state = try protectedState(cpl: currentCPL)
      let before = state

      #expect(step(&state, memory) == fault(.generalProtection, vector: 13, errorCode: errorCode))
      #expect(state == before)
    }
  }

  @Test func nonPresentCodeAndOutOfLimitTargetHaveDistinctFaults() throws {
    do {
      let memory = try fixture(
        frame: [0x1234, 0x1B, 2, 0x3000, 0x23],
        descriptors: [0x18: codeDescriptor(dpl: 3, present: false)]
      )
      var state = try protectedState()
      let before = state
      #expect(step(&state, memory) == fault(.segmentNotPresent, vector: 11, errorCode: 0x18))
      #expect(state == before)
    }

    do {
      let memory = try fixture(
        frame: [0x1000, 8, 2],
        descriptors: [8: codeDescriptor(dpl: 0, limit: 0x0FFF)]
      )
      var state = try protectedState()
      let before = state
      #expect(step(&state, memory) == fault(.generalProtection, vector: 13, errorCode: 0))
      #expect(state == before)
    }
  }

  @Test func conformingAndNonconformingPrivilegeRulesAcceptTheirValidForms() throws {
    for (selector, descriptor): (UInt16, UInt64) in [
      (0x1B, codeDescriptor(dpl: 3)),
      (0x1B, codeDescriptor(dpl: 0, conforming: true)),
    ] {
      let memory = try fixture(
        frame: [0x1234, UInt64(selector), 2, 0x3000, 0x23],
        descriptors: [0x18: descriptor, 0x20: dataDescriptor(dpl: 3)]
      )
      var state = try protectedState()
      #expect(step(&state, memory).isRetired)
      #expect(state.rip == 0x1234 && state.cs.selector == selector)
      #expect(state.ss.selector == 0x23 && state.registers.rsp == 0x3000)
    }
  }

  @Test func outerStackSelectorFailuresUseGPOrSelectorSS() throws {
    let cases: [(UInt16, UInt64?, DoryX86InterpreterResult)] = [
      (0, nil, fault(.generalProtection, vector: 13, errorCode: 0)),
      (0x20, dataDescriptor(dpl: 3), fault(.generalProtection, vector: 13, errorCode: 0x20)),
      (0x23, codeDescriptor(dpl: 3), fault(.generalProtection, vector: 13, errorCode: 0x20)),
      (
        0x23,
        dataDescriptor(dpl: 3, present: false),
        fault(.stackSegment, vector: 12, errorCode: 0x20)
      ),
    ]
    for (stackSelector, stackDescriptor, expectedFault) in cases {
      var descriptors: [UInt16: UInt64] = [0x18: codeDescriptor(dpl: 3)]
      if let stackDescriptor { descriptors[stackSelector & 0xFFF8] = stackDescriptor }
      let memory = try fixture(
        frame: [0x1234, 0x1B, 2, 0x3000, UInt64(stackSelector)],
        descriptors: descriptors
      )
      var state = try protectedState()
      state.nmiBlocked = true
      var expectedState = state
      expectedState.nmiBlocked = false

      #expect(step(&state, memory) == expectedFault)
      #expect(state == expectedState)
    }
  }

  @Test func localDescriptorTableMustBeUsableAndItsFullLimitIsHonored() throws {
    for invalidLDT in [
      DoryX86SegmentState(),
      .init(selector: 0x28, attributes: 0x02, limit: 0xFFFF, base: 0x5000),
      .init(selector: 0x2C, attributes: 0x82, limit: 0xFFFF, base: 0x5000),
      .init(selector: 0x28, attributes: 0x82, limit: 7, base: 0x5000),
      .init(selector: 0x28, attributes: 0x82, limit: 0xFFFF, base: UInt64.max - 4),
    ] {
      let memory = try fixture(frame: [0x1234, 0x0F, 2, 0x3000, 0x23], descriptors: [:])
      var state = try protectedState()
      state.ldtr = invalidLDT
      let before = state
      #expect(step(&state, memory) == fault(.generalProtection, vector: 13, errorCode: 0x0C))
      #expect(state == before)
    }

    let memory = try fixture(
      frame: [0x1234, 0x0F, 2, 0x3000, 0x23],
      descriptors: [0x20: dataDescriptor(dpl: 3)]
    )
    try write64(memory, at: 0x5008, value: codeDescriptor(dpl: 3, accessed: false))
    var state = try protectedState()
    state.ldtr = .init(selector: 0x28, attributes: 0x82, limit: .max, base: 0x5000)

    #expect(step(&state, memory).isRetired)
    #expect(state.cs.selector == 0x0F)
    #expect(try memory.read(at: 0x500D, byteCount: 1) == [0xFB])
  }

  @Test func descriptorAccessedBitsArePreflightedAndSetBeforeStatePublication() throws {
    let backing = try fixture(
      frame: [0x1234, 0x1B, 2, 0x3000, 0x23],
      descriptors: [
        0x18: codeDescriptor(dpl: 3, accessed: false),
        0x20: dataDescriptor(dpl: 3, accessed: false),
      ]
    )
    let denied = IRETDescriptorTrackingMemory(backing: backing, deniedWrite: 0x2025)
    var state = try protectedState()
    state.nmiBlocked = true
    var expected = state
    expected.nmiBlocked = false
    expected.control.cr2 = 0x2025

    #expect(
      step(&state, denied)
        == .exception(
          .init(
            kind: .pageFault,
            vector: 14,
            errorCode: 3,
            instructionPointer: 0x1000,
            linearAddress: 0x2025
          ))
    )
    #expect(state == expected)
    #expect(denied.dataWrites.isEmpty)
    #expect(try backing.read(at: 0x201D, byteCount: 1) == [0xFA])
    #expect(try backing.read(at: 0x2025, byteCount: 1) == [0xF2])

    let memory = try fixture(
      frame: [0x1234, 0x1B, 2, 0x3000, 0x23],
      descriptors: [
        0x18: codeDescriptor(dpl: 3, accessed: false),
        0x20: dataDescriptor(dpl: 3, accessed: false),
      ]
    )
    var successful = try protectedState()
    #expect(step(&successful, memory).isRetired)
    #expect(try memory.read(at: 0x201D, byteCount: 1) == [0xFB])
    #expect(try memory.read(at: 0x2025, byteCount: 1) == [0xF3])
    #expect(successful.cs.attributes & 1 != 0 && successful.ss.attributes & 1 != 0)
  }

  @Test func outerReturnInvalidatesOnlyNowInaccessibleDataSegments() throws {
    let memory = try fixture(
      frame: [0x1234, 0x1B, 2, 0x3000, 0x23],
      descriptors: [0x18: codeDescriptor(dpl: 3), 0x20: dataDescriptor(dpl: 3)]
    )
    var state = try protectedState()
    state.ds = .init(selector: 0x10, attributes: 0xC092, limit: .max, base: 0x1111)
    state.es = .init(selector: 0x18, attributes: 0xC09E, limit: .max, base: 0x2222)
    state.fs = .init(selector: 0x23, attributes: 0xC0F2, limit: .max, base: 0x3333)
    state.gs = .init(selector: 3, attributes: 0xC0F2, limit: .max, base: 0x4444)
    let expectedES = state.es
    let expectedFS = state.fs

    #expect(step(&state, memory).isRetired)
    #expect(state.ds == .init())
    #expect(state.gs == .init())
    #expect(state.es == expectedES)
    #expect(state.fs == expectedFS)
  }

  @Test func descriptorReadFaultPublishesOnlyNMIUnblockAndCR2() throws {
    let backing = try fixture(
      frame: [0x1234, 0x1B, 2, 0x3000, 0x23],
      descriptors: [:]
    )
    let memory = IRETDescriptorTrackingMemory(backing: backing, deniedRead: 0x2018)
    var state = try protectedState()
    state.nmiBlocked = true
    var expected = state
    expected.nmiBlocked = false
    expected.control.cr2 = 0x2018

    #expect(
      step(&state, memory)
        == .exception(
          .init(
            kind: .pageFault,
            vector: 14,
            errorCode: 1,
            instructionPointer: 0x1000,
            linearAddress: 0x2018
          ))
    )
    #expect(state == expected)
    #expect(memory.dataWrites.isEmpty)
  }

  @Test func unsupportedTaskAndVirtual8086ReturnsFailBeforeDescriptorEffects() throws {
    for kind in 0..<3 {
      let memory = try fixture(
        frame: [0x1234, 8, kind == 2 ? DoryX86RFLAGS.virtual8086.rawValue | 2 : 2],
        descriptors: [8: codeDescriptor(dpl: 0, accessed: false)]
      )
      let tracking = IRETDescriptorTrackingMemory(backing: memory)
      var state = try protectedState()
      if kind == 0 { state.rflags.insert(.nestedTask) }
      if kind == 1 { state.rflags.insert(.virtual8086) }
      state.nmiBlocked = true
      var expected = state
      expected.nmiBlocked = false

      #expect(step(&state, tracking) == fault(.generalProtection, vector: 13, errorCode: 0))
      #expect(state == expected)
      #expect(tracking.descriptorReads.isEmpty && tracking.dataWrites.isEmpty)
    }
  }

  private func step(
    _ state: inout DoryX86ArchitecturalState,
    _ memory: any DoryX86Memory
  ) -> DoryX86InterpreterResult {
    DoryX86Interpreter().step(state: &state, memory: memory, mode: .protected32)
  }

  private func protectedState(cpl: UInt8 = 0) throws -> DoryX86ArchitecturalState {
    try .init(
      registers: .init(rsp: 0x8000),
      rip: 0x1000,
      rflags: [.reservedOne, .interruptEnable],
      cs: .init(selector: cpl == 3 ? 0x1B : 8, attributes: 0xC09B | UInt16(cpl) << 5, limit: .max),
      ss: .init(
        selector: cpl == 3 ? 0x23 : 0x10,
        attributes: 0xC093 | UInt16(cpl) << 5,
        limit: .max,
        base: cpl == 3 ? 0x20000 : 0x10000
      ),
      gdtr: .init(limit: 0x2F, base: 0x2000),
      control: .init(cr0: 0x10011, cr2: 0xDEAD)
    )
  }

  private func fixture(
    frame: [UInt64],
    descriptors: [UInt16: UInt64],
    frameAddress: UInt64 = 0x18000
  ) throws -> DoryX86ByteArrayMemory {
    let memory = try DoryX86ByteArrayMemory(byteCount: 0x60000)
    try memory.write(at: 0x1000, bytes: [0xCF])
    for (index, value) in frame.enumerated() {
      try memory.writeScalar(at: frameAddress + UInt64(index * 4), value: value, byteCount: 4)
    }
    for (offset, value) in descriptors {
      try write64(memory, at: 0x2000 + UInt64(offset), value: value)
    }
    return memory
  }

  private func codeDescriptor(
    dpl: UInt8,
    conforming: Bool = false,
    present: Bool = true,
    accessed: Bool = true,
    limit: UInt32 = .max
  ) -> UInt64 {
    descriptor(
      access: UInt8(
        0x1A | (accessed ? 1 : 0) | (conforming ? 4 : 0) | Int(dpl & 3) << 5
          | (present ? 0x80 : 0)),
      limit: limit
    )
  }

  private func dataDescriptor(
    dpl: UInt8,
    present: Bool = true,
    accessed: Bool = true
  ) -> UInt64 {
    descriptor(
      access: UInt8(0x12 | (accessed ? 1 : 0) | Int(dpl & 3) << 5 | (present ? 0x80 : 0)),
      base: 0x20000
    )
  }

  private func descriptor(access: UInt8, base: UInt64 = 0, limit: UInt32 = .max) -> UInt64 {
    let granular = limit > 0xFFFFF
    let encodedLimit = granular ? limit >> 12 : limit
    return UInt64(encodedLimit & 0xFFFF)
      | (base & 0xFFFF) << 16
      | ((base >> 16) & 0xFF) << 32
      | UInt64(access) << 40
      | UInt64((encodedLimit >> 16) & 0x0F) << 48
      | UInt64(granular ? 0xC : 4) << 52
      | ((base >> 24) & 0xFF) << 56
  }

  private func write64(
    _ memory: DoryX86ByteArrayMemory,
    at address: UInt64,
    value: UInt64
  ) throws {
    try memory.writeScalar(at: address, value: value, byteCount: 8)
  }

  private func fault(
    _ kind: DoryX86Exception.Kind,
    vector: UInt8,
    errorCode: UInt32
  ) -> DoryX86InterpreterResult {
    .exception(
      .init(
        kind: kind,
        vector: vector,
        errorCode: errorCode,
        instructionPointer: 0x1000
      ))
  }
}

extension DoryX86InterpreterResult {
  fileprivate var isRetired: Bool {
    if case .retired = self { return true }
    return false
  }
}

private final class IRETDescriptorTrackingMemory: DoryX86Memory, @unchecked Sendable {
  let backing: DoryX86ByteArrayMemory
  let deniedRead: UInt64?
  let deniedWrite: UInt64?
  private(set) var descriptorReads: [UInt64] = []
  private(set) var dataWrites: [UInt64] = []

  init(
    backing: DoryX86ByteArrayMemory,
    deniedRead: UInt64? = nil,
    deniedWrite: UInt64? = nil
  ) {
    self.backing = backing
    self.deniedRead = deniedRead
    self.deniedWrite = deniedWrite
  }

  func instructionBytes(at address: UInt64, maximumCount: Int) throws -> [UInt8] {
    try backing.instructionBytes(at: address, maximumCount: maximumCount)
  }

  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    if address >= 0x2000 && address < 0x6000 { descriptorReads.append(address) }
    if address == deniedRead {
      throw DoryX86MemoryError.pageFault(address: address, errorCode: 1)
    }
    return try backing.read(at: address, byteCount: byteCount)
  }

  func validateRead(at address: UInt64, byteCount: Int) throws {
    if address == deniedRead {
      throw DoryX86MemoryError.pageFault(address: address, errorCode: 1)
    }
    try backing.validateRead(at: address, byteCount: byteCount)
  }

  func write(at address: UInt64, bytes: [UInt8]) throws {
    dataWrites.append(address)
    try backing.write(at: address, bytes: bytes)
  }

  func validateWrite(at address: UInt64, byteCount: Int) throws {
    if address == deniedWrite {
      throw DoryX86MemoryError.pageFault(address: address, errorCode: 3)
    }
    try backing.validateWrite(at: address, byteCount: byteCount)
  }

  func synchronize() { backing.synchronize() }
}
