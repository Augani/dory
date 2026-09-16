import DoryDBTX86
import Foundation

// Build with `swift run -c release dory-x86-throughput-benchmark [instructions]`.
// Measures single-vCPU JIT throughput for a tight register-only loop.

struct Measurement: Encodable {
  let scenario: String
  let instructions: UInt64
  let elapsedNanoseconds: UInt64
  let mips: Double
  let chainAttempts: UInt64
  let chainAccepts: UInt64
  let chainRejections: UInt64
  let chainedRetiredInstructions: UInt64
  let tier1CompiledBlocks: UInt64
  let tier1CompilationDeclines: UInt64
  let directChainPatches: UInt64
}

struct Report: Encodable {
  let schemaVersion = 1
  let optimizedBuild: Bool
  let measurements: [Measurement]
}

enum BenchmarkError: Error { case usage }

do {
  let arguments = CommandLine.arguments.dropFirst()
  let instructionBudget: UInt64 = arguments.first.flatMap(UInt64.init) ?? 50_000_000
  guard instructionBudget >= 1_000 else { throw BenchmarkError.usage }

  // x86-64 tight loop: add rax, 1 ; jmp -6 (back to the add)
  // 48 83 C0 01    add rax, 1
  // EB FA          jmp short -6 (back to start)
  let loopBytes: [UInt8] = [0x48, 0x83, 0xC0, 0x01, 0xEB, 0xFA]

  let codeAddress: UInt64 = 0x1000
  let memoryBytes = Int(getpagesize()) * 4
  let physical = try DoryX86MmapMemory(validatingByteCount: memoryBytes)
  try physical.write(at: codeAddress, bytes: loopBytes)

  let initialState = try DoryX86ArchitecturalState(
    registers: .init(rax: 0),
    rip: codeAddress,
    rflags: [.reservedOne]
  )

  var measurements: [Measurement] = []

  for scenario in ["interpreter", "baseline-jit", "tier1-jit"] {
    var state = initialState
    let executor: DoryARM64BaselineExecutor
    switch scenario {
    case "interpreter":
      let start = DispatchTime.now().uptimeNanoseconds
      var retired: UInt64 = 0
      let interpreter = DoryX86Interpreter()
      // Run 2 instructions per iteration (add + jmp) so RIP returns to codeAddress.
      while retired + 1 < instructionBudget {
        _ = interpreter.step(state: &state, memory: physical, mode: .long64)
        _ = interpreter.step(state: &state, memory: physical, mode: .long64)
        retired &+= 2
      }
      let elapsed = DispatchTime.now().uptimeNanoseconds - start
      let mips = elapsed > 0 ? Double(retired) / Double(elapsed) * 1000.0 : 0
      measurements.append(.init(
        scenario: scenario, instructions: retired, elapsedNanoseconds: elapsed,
        mips: mips, chainAttempts: 0, chainAccepts: 0, chainRejections: 0,
        chainedRetiredInstructions: 0, tier1CompiledBlocks: 0,
        tier1CompilationDeclines: 0, directChainPatches: 0))
      continue
    case "baseline-jit":
      executor = try DoryARM64BaselineExecutor(
        maximumCodeBytes: 1_048_576,
        tier1Enabled: false,
        rawTargetPredictionOptions: .all
      )
    case "tier1-jit":
      executor = try DoryARM64BaselineExecutor(
        maximumCodeBytes: 1_048_576,
        tier1Enabled: true,
        rawTargetPredictionOptions: .all
      )
    default: continue
    }

    let pagingUnit = DoryX86PagingUnit()
    let translatedMemory = DoryX86TranslatedMemory(
      physicalMemory: physical,
      pagingUnit: pagingUnit,
      context: .init(state: state, mode: .long64)
    )

    let start = DispatchTime.now().uptimeNanoseconds
    var retired: UInt64 = 0
    while retired < instructionBudget {
      let stepBudget = min(instructionBudget - retired, 10_000_000)
      guard let execution = try executor.executeChainedSummary(
        byteProvider: { currentRIP, maximumCount in
          guard currentRIP == codeAddress else { return [] }
          return Array(loopBytes.prefix(maximumCount))
        },
        at: codeAddress,
        mode: .long64,
        addressSpaceID: 0,
        maximumInstructions: Int(stepBudget),
        state: &state,
        memory: translatedMemory
      ) else { break }
      retired &+= UInt64(execution.guestInstructionCount)
      if state.rip != codeAddress { break }
    }
    let elapsed = DispatchTime.now().uptimeNanoseconds - start
    let mips = elapsed > 0 ? Double(retired) / Double(elapsed) * 1000.0 : 0
    let diag = executor.diagnostics
    let chainRejections =
      diag.chainTargetBoundaryRejections
      + diag.chainTargetCompilerABIRejections
      + diag.chainTargetInterpreterGuardRejections
      + diag.chainTargetMissingMemoryRejections
      + diag.chainTargetRestartableWriterRejections
      + diag.chainTargetSourceShapeRejections
      + diag.chainTargetPublicationRejections
    measurements.append(.init(
      scenario: scenario, instructions: retired, elapsedNanoseconds: elapsed,
      mips: mips,
      chainAttempts: diag.chainTargetAttempts,
      chainAccepts: diag.chainTargetAccepts,
      chainRejections: chainRejections,
      chainedRetiredInstructions: diag.chainedRetiredInstructions,
      tier1CompiledBlocks: diag.tier1CompiledBlocks,
      tier1CompilationDeclines: diag.tier1CompilationDeclines,
      directChainPatches: diag.directChainPatches
    ))
  }

  #if DEBUG
    let optimized = false
  #else
    let optimized = true
  #endif
  let report = Report(optimizedBuild: optimized, measurements: measurements)
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  let data = try encoder.encode(report)
  FileHandle.standardOutput.write(data)
  print()
} catch {
  FileHandle.standardError.write(Data("error: \(error)\n".utf8))
  exit(1)
}
