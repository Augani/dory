import DoryDBTX86
import Foundation

// Build with `swift run -c release dory-x86-generation-benchmark [iterations]`.
// These microbenchmarks measure memory-generation queries, not VM throughput.
struct Measurement: Encodable {
  let scenario: String
  let iterations: Int
  let elapsedNanoseconds: UInt64
  let checksum: UInt64
}

struct Report: Encodable {
  let schemaVersion = 1
  let optimizedBuild: Bool
  let measurements: [Measurement]
}

enum BenchmarkError: Error { case usage, missingGeneration }

do {
  let arguments = CommandLine.arguments.dropFirst()
  guard arguments.count <= 1,
    let iterations = arguments.first.flatMap(Int.init) ?? (arguments.isEmpty ? 250_000 : nil),
    (1...100_000_000).contains(iterations)
  else { throw BenchmarkError.usage }

  var measurements: [Measurement] = []
  for scenario in ["hot-repeated", "cache-collision", "interleaved-data-write-hot-read", "cached-code-write"] {
    let memory = try DoryX86MmapMemory(validatingByteCount: 0x402000)
    // Populate generation metadata before timing, consistently across candidates.
    for page in 0...512 {
      try memory.writeScalar(at: UInt64(page * 4096), value: 0, byteCount: 1)
    }
    _ = try memory.codeGeneration(at: 0, byteCount: 16)
    var checksum: UInt64 = 0
    let start = DispatchTime.now().uptimeNanoseconds
    for index in 0..<iterations {
      var address: UInt64 = 0
      switch scenario {
      case "cache-collision":
        address = index.isMultiple(of: 2) ? 0 : 0x100000
      case "interleaved-data-write-hot-read":
        try memory.writeScalar(
          at: UInt64((index % 512 + 1) * 4096), value: UInt64(index & 0xff), byteCount: 1)
      case "cached-code-write":
        try memory.writeScalar(at: 0, value: UInt64(index & 0xff), byteCount: 1)
      default: break
      }
      guard let generation = try memory.codeGeneration(at: address, byteCount: 16) else {
        throw BenchmarkError.missingGeneration
      }
      checksum &+= generation
    }
    measurements.append(.init(
      scenario: scenario, iterations: iterations,
      elapsedNanoseconds: DispatchTime.now().uptimeNanoseconds - start, checksum: checksum))
  }
  #if DEBUG
    let optimized = false
  #else
    let optimized = true
  #endif
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  FileHandle.standardOutput.write(try encoder.encode(Report(
    optimizedBuild: optimized, measurements: measurements)) + Data("\n".utf8))
} catch {
  FileHandle.standardError.write(Data(
    "generation benchmark failed: \(error); usage: dory-x86-generation-benchmark [iterations: 1...100000000]\n".utf8))
  exit(1)
}
