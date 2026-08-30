import Foundation

public enum DoryJITExitCode: UInt32, Codable, Sendable, Hashable {
  case dispatch = 0
  case interpreter = 1
  case halt = 2
  case system = 3
  case portIO = 4
}

public enum DoryARM64CompilationTier: String, Codable, Sendable, Hashable {
  case baseline
  case interpreterFallback
}

public struct DoryARM64CompiledBlock: Codable, Sendable, Hashable {
  public let guestStart: UInt64
  public let guestByteCount: UInt32
  public let machineWords: [UInt32]
  public let tier: DoryARM64CompilationTier
  public let exitCode: DoryJITExitCode

  public init(
    guestStart: UInt64,
    guestByteCount: UInt32,
    machineWords: [UInt32],
    tier: DoryARM64CompilationTier,
    exitCode: DoryJITExitCode
  ) {
    self.guestStart = guestStart
    self.guestByteCount = guestByteCount
    self.machineWords = machineWords
    self.tier = tier
    self.exitCode = exitCode
  }

  public var machineBytes: [UInt8] {
    machineWords.flatMap { word in
      (0..<4).map { UInt8(truncatingIfNeeded: word >> UInt32($0 * 8)) }
    }
  }
}

/// Baseline ABI: x0 points to 16 UInt64 GPR slots followed by RIP and RFLAGS. Generated code
/// returns a DoryJITExitCode in w0. The layout is intentionally independent of Swift struct ABI.
public struct DoryARM64BaselineEmitter: Sendable {
  private static let ripOffset = 16 * 8

  public init() {}

  public func compile(_ block: DoryIRBasicBlock) -> DoryARM64CompiledBlock {
    var words: [UInt32] = []
    for statement in block.statements {
      guard emit(statement, into: &words) else {
        return fallback(block)
      }
    }
    guard let exit = emit(block.terminator, into: &words) else {
      return fallback(block)
    }
    words.append(encodeMoveWideZero32(register: 0, immediate: UInt16(exit.rawValue)))
    words.append(0xD65F_03C0)
    return .init(
      guestStart: block.guestStart,
      guestByteCount: block.guestByteCount,
      machineWords: words,
      tier: .baseline,
      exitCode: exit
    )
  }

  private func fallback(_ block: DoryIRBasicBlock) -> DoryARM64CompiledBlock {
    var words: [UInt32] = []
    emitImmediate(block.guestStart, register: 9, into: &words)
    words.append(encodeStore64(register: 9, base: 0, byteOffset: Self.ripOffset))
    words.append(
      encodeMoveWideZero32(register: 0, immediate: UInt16(DoryJITExitCode.interpreter.rawValue)))
    words.append(0xD65F_03C0)
    return .init(
      guestStart: block.guestStart,
      guestByteCount: block.guestByteCount,
      machineWords: words,
      tier: .interpreterFallback,
      exitCode: .interpreter
    )
  }

  private func emit(_ statement: DoryIRStatement, into words: inout [UInt32]) -> Bool {
    guard case .copy(let destination, let source) = statement,
      case .register(let target) = destination,
      target.bank == "x86.gpr",
      target.index < 16,
      target.width == .i32 || target.width == .i64
    else { return false }

    switch source {
    case .register(let sourceRegister)
    where sourceRegister.bank == "x86.gpr"
      && sourceRegister.index < 16
      && sourceRegister.width == target.width:
      let sourceOffset = Int(sourceRegister.index) * 8
      words.append(
        target.width == .i64
          ? encodeLoad64(register: 9, base: 0, byteOffset: sourceOffset)
          : encodeLoad32(register: 9, base: 0, byteOffset: sourceOffset)
      )
    case .immediate(let value, let width) where width == target.width:
      emitImmediate(target.width == .i32 ? value & 0xffff_ffff : value, register: 9, into: &words)
    default:
      return false
    }
    words.append(
      encodeStore64(register: 9, base: 0, byteOffset: Int(target.index) * 8)
    )
    return true
  }

  private func emit(
    _ terminator: DoryIRTerminator,
    into words: inout [UInt32]
  ) -> DoryJITExitCode? {
    let target: UInt64
    let exit: DoryJITExitCode
    switch terminator {
    case .next(let address), .branch(let address):
      target = address
      exit = .dispatch
    case .exit(let reason, let resumeAt):
      target = resumeAt
      exit =
        switch reason {
        case .halt: .halt
        case .system: .system
        case .portIO: .portIO
        case .interpreter, .indirectControl, .instructionBudget: .interpreter
        }
    case .conditional:
      return nil
    }
    emitImmediate(target, register: 9, into: &words)
    words.append(encodeStore64(register: 9, base: 0, byteOffset: Self.ripOffset))
    return exit
  }

  private func emitImmediate(
    _ value: UInt64,
    register: UInt32,
    into words: inout [UInt32]
  ) {
    var emitted = false
    for halfword in 0..<4 {
      let immediate = UInt16(truncatingIfNeeded: value >> UInt64(halfword * 16))
      if !emitted {
        words.append(
          encodeMoveWideZero64(
            register: register,
            immediate: immediate,
            halfword: UInt32(halfword)
          ))
        emitted = true
      } else if immediate != 0 {
        words.append(
          encodeMoveWideKeep64(
            register: register,
            immediate: immediate,
            halfword: UInt32(halfword)
          ))
      }
    }
  }

  private func encodeLoad64(register: UInt32, base: UInt32, byteOffset: Int) -> UInt32 {
    0xF940_0000 | UInt32(byteOffset / 8) << 10 | base << 5 | register
  }

  private func encodeLoad32(register: UInt32, base: UInt32, byteOffset: Int) -> UInt32 {
    0xB940_0000 | UInt32(byteOffset / 4) << 10 | base << 5 | register
  }

  private func encodeStore64(register: UInt32, base: UInt32, byteOffset: Int) -> UInt32 {
    0xF900_0000 | UInt32(byteOffset / 8) << 10 | base << 5 | register
  }

  private func encodeMoveWideZero64(
    register: UInt32,
    immediate: UInt16,
    halfword: UInt32
  ) -> UInt32 {
    0xD280_0000 | halfword << 21 | UInt32(immediate) << 5 | register
  }

  private func encodeMoveWideKeep64(
    register: UInt32,
    immediate: UInt16,
    halfword: UInt32
  ) -> UInt32 {
    0xF280_0000 | halfword << 21 | UInt32(immediate) << 5 | register
  }

  private func encodeMoveWideZero32(register: UInt32, immediate: UInt16) -> UInt32 {
    0x5280_0000 | UInt32(immediate) << 5 | register
  }
}

public struct DoryJITBlockKey: Codable, Sendable, Hashable {
  public let guestStart: UInt64
  public let addressSpaceID: UInt64
  public let codeGeneration: UInt64

  public init(guestStart: UInt64, addressSpaceID: UInt64, codeGeneration: UInt64) {
    self.guestStart = guestStart
    self.addressSpaceID = addressSpaceID
    self.codeGeneration = codeGeneration
  }
}

public final class DoryJITCodeCache: @unchecked Sendable {
  private struct Entry {
    let block: DoryARM64CompiledBlock
    var lastUse: UInt64
  }

  public let maximumBytes: Int
  private let lock = NSLock()
  private var entries: [DoryJITBlockKey: Entry] = [:]
  private var byteCount = 0
  private var clock: UInt64 = 0

  public init(maximumBytes: Int) {
    self.maximumBytes = max(0, maximumBytes)
  }

  public var residentByteCount: Int { lock.withLock { byteCount } }
  public var residentBlockCount: Int { lock.withLock { entries.count } }

  public func block(for key: DoryJITBlockKey) -> DoryARM64CompiledBlock? {
    lock.withLock {
      guard var entry = entries[key] else { return nil }
      clock &+= 1
      entry.lastUse = clock
      entries[key] = entry
      return entry.block
    }
  }

  public func insert(_ block: DoryARM64CompiledBlock, for key: DoryJITBlockKey) {
    lock.withLock {
      if let previous = entries.removeValue(forKey: key) {
        byteCount -= previous.block.machineBytes.count
      }
      let size = block.machineBytes.count
      guard size <= maximumBytes else { return }
      while byteCount + size > maximumBytes, let victim = leastRecentlyUsedKey() {
        if let removed = entries.removeValue(forKey: victim) {
          byteCount -= removed.block.machineBytes.count
        }
      }
      clock &+= 1
      entries[key] = .init(block: block, lastUse: clock)
      byteCount += size
    }
  }

  public func invalidate(addressSpaceID: UInt64, guestRange: Range<UInt64>) {
    lock.withLock {
      let victims = entries.filter { key, entry in
        guard key.addressSpaceID == addressSpaceID else { return false }
        let blockRange = key.guestStart..<(key.guestStart &+ UInt64(entry.block.guestByteCount))
        return blockRange.overlaps(guestRange)
      }.map(\.key)
      for key in victims {
        if let removed = entries.removeValue(forKey: key) {
          byteCount -= removed.block.machineBytes.count
        }
      }
    }
  }

  public func invalidateAll() {
    lock.withLock {
      entries.removeAll(keepingCapacity: true)
      byteCount = 0
    }
  }

  private func leastRecentlyUsedKey() -> DoryJITBlockKey? {
    entries.min { lhs, rhs in
      if lhs.value.lastUse != rhs.value.lastUse {
        return lhs.value.lastUse < rhs.value.lastUse
      }
      return lhs.key.guestStart < rhs.key.guestStart
    }?.key
  }
}
