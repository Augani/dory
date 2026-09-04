import Foundation
import Testing

@testable import DoryDBTX86

/// Decode and execute coverage for SSE2 scalar floating-point instructions
/// discovered in the x86_64 Linux busybox binary audit: `SQRTSD`, `CVTSD2SS`,
/// `CVTSS2SD`, and `CMPLTSD`/`CMPSS`.
@Suite struct DoryX86SSE2ScalarFPTests {
  private let decoder = DoryX86Decoder()
  private let interpreter = DoryX86Interpreter()

  private func state(
    rip: UInt64 = 0x1000,
    configuring: (inout DoryX86FloatingPointState) throws -> Void
  ) throws -> DoryX86ArchitecturalState {
    var floatingPoint = try DoryX86FloatingPointState()
    try configuring(&floatingPoint)
    return try DoryX86ArchitecturalState(rip: rip,
      control: .init(cr4: 1 << 9), floatingPoint: floatingPoint)
  }

  private func ymmBytes(_ index: Int, in state: DoryX86ArchitecturalState) -> [UInt8] {
    Array(state.floatingPoint.ymm[index].bytes.prefix(16))
  }

  private func expectRetired(_ result: DoryX86InterpreterResult) {
    guard case .retired = result else {
      Issue.record("instruction did not retire: \(result)")
      return
    }
  }

  // MARK: - SQRTSD

  @Test func sqrtsdComputesScalarDoubleSquareRoot() throws {
    // F2 0F 51 C0: SQRTSD xmm0, xmm0
    let instruction = try decoder.decode(
      [0xF2, 0x0F, 0x51, 0xC0], at: 0x1000, mode: .long64)
    #expect(
      instruction.operation
        == .scalarSquareRoot(
          format: .scalarDouble, destination: 0, source: .register(0)))

    // sqrt(16.0) = 4.0
    let sixteen = Double(16.0).bitPattern
    var current = try state { floatingPoint in
      var bytes = [UInt8](repeating: 0, count: 32)
      for i in 0..<8 {
        bytes[i] = UInt8(truncatingIfNeeded: sixteen >> UInt64(i * 8))
      }
      floatingPoint.ymm[0] = try .init(bytes: bytes, expectedByteCount: 32)
    }
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: [0xF2, 0x0F, 0x51, 0xC0])
    let result = interpreter.step(state: &current, memory: memory, mode: .long64)
    expectRetired(result)
    let resultBytes = ymmBytes(0, in: current)
    let resultBits = resultBytes.enumerated().reduce(UInt64(0)) {
      $0 | UInt64($1.element) << UInt64($1.offset * 8)
    }
    #expect(Double(bitPattern: resultBits) == 4.0)
  }

  @Test func sqrtssComputesScalarSingleSquareRoot() throws {
    // F3 0F 51 C0: SQRTSS xmm0, xmm0
    let instruction = try decoder.decode(
      [0xF3, 0x0F, 0x51, 0xC0], at: 0x1000, mode: .long64)
    #expect(
      instruction.operation
        == .scalarSquareRoot(
          format: .scalarSingle, destination: 0, source: .register(0)))

    // sqrt(25.0f) = 5.0f
    let twentyFive = Float(25.0).bitPattern
    var current = try state { floatingPoint in
      var bytes = [UInt8](repeating: 0, count: 32)
      for i in 0..<4 {
        bytes[i] = UInt8(truncatingIfNeeded: twentyFive >> UInt32(i * 8))
      }
      floatingPoint.ymm[0] = try .init(bytes: bytes, expectedByteCount: 32)
    }
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: [0xF3, 0x0F, 0x51, 0xC0])
    let result = interpreter.step(state: &current, memory: memory, mode: .long64)
    expectRetired(result)
    let resultBytes = ymmBytes(0, in: current)
    let resultBits = UInt32(resultBytes[0]) | UInt32(resultBytes[1]) << 8
      | UInt32(resultBytes[2]) << 16 | UInt32(resultBytes[3]) << 24
    #expect(Float(bitPattern: resultBits) == 5.0)
  }

  // MARK: - CVTSD2SS

  @Test func cvtsd2ssConvertsDoubleToSingle() throws {
    // F2 0F 5A C0: CVTSD2SS xmm0, xmm0
    let instruction = try decoder.decode(
      [0xF2, 0x0F, 0x5A, 0xC0], at: 0x1000, mode: .long64)
    #expect(
      instruction.operation
        == .scalarConvert(
          direction: .doubleToSingle, destination: 0, source: .register(0)))

    // Convert 3.141592653589793 (double) to Float(3.141592653589793)
    let pi = Double(3.141592653589793).bitPattern
    var current = try state { floatingPoint in
      var bytes = [UInt8](repeating: 0, count: 32)
      for i in 0..<8 {
        bytes[i] = UInt8(truncatingIfNeeded: pi >> UInt64(i * 8))
      }
      floatingPoint.ymm[0] = try .init(bytes: bytes, expectedByteCount: 32)
    }
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: [0xF2, 0x0F, 0x5A, 0xC0])
    let result = interpreter.step(state: &current, memory: memory, mode: .long64)
    expectRetired(result)
    let resultBytes = ymmBytes(0, in: current)
    let resultBits = UInt32(resultBytes[0]) | UInt32(resultBytes[1]) << 8
      | UInt32(resultBytes[2]) << 16 | UInt32(resultBytes[3]) << 24
    #expect(Float(bitPattern: resultBits) == Float(3.141592653589793))
  }

  // MARK: - CVTSS2SD

  @Test func cvtss2sdConvertsSingleToDouble() throws {
    // F3 0F 5A C0: CVTSS2SD xmm0, xmm0
    let instruction = try decoder.decode(
      [0xF3, 0x0F, 0x5A, 0xC0], at: 0x1000, mode: .long64)
    #expect(
      instruction.operation
        == .scalarConvert(
          direction: .singleToDouble, destination: 0, source: .register(0)))

    // Convert 2.5f (single) to 2.5 (double)
    let twoPointFive = Float(2.5).bitPattern
    var current = try state { floatingPoint in
      var bytes = [UInt8](repeating: 0, count: 32)
      for i in 0..<4 {
        bytes[i] = UInt8(truncatingIfNeeded: twoPointFive >> UInt32(i * 8))
      }
      floatingPoint.ymm[0] = try .init(bytes: bytes, expectedByteCount: 32)
    }
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: [0xF3, 0x0F, 0x5A, 0xC0])
    let result = interpreter.step(state: &current, memory: memory, mode: .long64)
    expectRetired(result)
    let resultBytes = ymmBytes(0, in: current)
    let resultBits = resultBytes.enumerated().reduce(UInt64(0)) {
      $0 | UInt64($1.element) << UInt64($1.offset * 8)
    }
    #expect(Double(bitPattern: resultBits) == 2.5)
  }

  // MARK: - CMPLTSD

  @Test func cmpltsdSetsMaskWhenLessThan() throws {
    // F2 0F C2 C0 01: CMPLTSD xmm0, xmm0, 1 (less-than)
    let instruction = try decoder.decode(
      [0xF2, 0x0F, 0xC2, 0xC0, 0x01], at: 0x1000, mode: .long64)
    #expect(
      instruction.operation
        == .scalarCompare(
          predicate: .lessThan, format: .scalarDouble,
          destination: 0, source: .register(0)))

    // xmm0 low = 1.0, compare with itself: 1.0 < 1.0 is false -> mask = 0
    let one = Double(1.0).bitPattern
    var current = try state { floatingPoint in
      var bytes = [UInt8](repeating: 0, count: 32)
      for i in 0..<8 {
        bytes[i] = UInt8(truncatingIfNeeded: one >> UInt64(i * 8))
      }
      floatingPoint.ymm[0] = try .init(bytes: bytes, expectedByteCount: 32)
    }
    let memory = try DoryX86ByteArrayMemory(
      baseAddress: 0x1000, bytes: [0xF2, 0x0F, 0xC2, 0xC0, 0x01])
    let result = interpreter.step(state: &current, memory: memory, mode: .long64)
    expectRetired(result)
    let lowBytes = Array(ymmBytes(0, in: current).prefix(8))
    #expect(lowBytes == Array(repeating: 0, count: 8))
  }

  @Test func cmpltsdSetsAllOnesWhenLessThan() throws {
    // F2 0F C2 C1 01: CMPLTSD xmm0, xmm1, 1 (less-than)
    // xmm0 = 1.0, xmm1 = 2.0: 1.0 < 2.0 is true -> mask = 0xFF...
    let one = Double(1.0).bitPattern
    let two = Double(2.0).bitPattern
    var current = try state { floatingPoint in
      var bytes0 = [UInt8](repeating: 0, count: 32)
      var bytes1 = [UInt8](repeating: 0, count: 32)
      for i in 0..<8 {
        bytes0[i] = UInt8(truncatingIfNeeded: one >> UInt64(i * 8))
        bytes1[i] = UInt8(truncatingIfNeeded: two >> UInt64(i * 8))
      }
      floatingPoint.ymm[0] = try .init(bytes: bytes0, expectedByteCount: 32)
      floatingPoint.ymm[1] = try .init(bytes: bytes1, expectedByteCount: 32)
    }
    let memory = try DoryX86ByteArrayMemory(
      baseAddress: 0x1000, bytes: [0xF2, 0x0F, 0xC2, 0xC1, 0x01])
    let result = interpreter.step(state: &current, memory: memory, mode: .long64)
    expectRetired(result)
    let lowBytes = Array(ymmBytes(0, in: current).prefix(8))
    #expect(lowBytes == Array(repeating: 0xFF, count: 8))
  }

  @Test func cmpssEqualPredicateWorks() throws {
    // F3 0F C2 C0 00: CMPSS xmm0, xmm0, 0 (equal)
    let instruction = try decoder.decode(
      [0xF3, 0x0F, 0xC2, 0xC0, 0x00], at: 0x1000, mode: .long64)
    #expect(
      instruction.operation
        == .scalarCompare(
          predicate: .equal, format: .scalarSingle,
          destination: 0, source: .register(0)))

    // xmm0 = 3.14f, compare with itself: equal -> mask = 0xFF...
    let pi = Float(3.14).bitPattern
    var current = try state { floatingPoint in
      var bytes = [UInt8](repeating: 0, count: 32)
      for i in 0..<4 {
        bytes[i] = UInt8(truncatingIfNeeded: pi >> UInt32(i * 8))
      }
      floatingPoint.ymm[0] = try .init(bytes: bytes, expectedByteCount: 32)
    }
    let memory = try DoryX86ByteArrayMemory(
      baseAddress: 0x1000, bytes: [0xF3, 0x0F, 0xC2, 0xC0, 0x00])
    let result = interpreter.step(state: &current, memory: memory, mode: .long64)
    expectRetired(result)
    let lowBytes = Array(ymmBytes(0, in: current).prefix(4))
    #expect(lowBytes == Array(repeating: 0xFF, count: 4))
  }
}
