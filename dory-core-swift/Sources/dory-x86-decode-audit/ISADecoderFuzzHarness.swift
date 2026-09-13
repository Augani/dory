import DoryDBTX86
import Foundation

// P2-04 item 7: A bounded decoder fuzz harness with retained seeds and
// explicit bounds. The harness generates random byte sequences within the
// 15-byte x86 instruction limit, decodes them in every execution mode, and
// verifies that the decoder either produces a valid decoded instruction or
// a well-formed error. The harness never executes the decoded instructions;
// it only tests decoder robustness.
//
// Seeds are retained so that any decoder crash, hang, or unexpected error
// can be reproduced exactly. The harness uses a deterministic PRNG seeded
// from a fixed root, so the same seed always produces the same byte sequences.

public enum ISADecoderFuzzError: Error, Sendable, Equatable {
  case decoderCrashed(seed: UInt64, bytes: [UInt8], mode: DoryX86ExecutionMode)
  case unexpectedError(seed: UInt64, bytes: [UInt8], mode: DoryX86ExecutionMode, message: String)
  case decodedLengthExceedsInput(seed: UInt64, bytes: [UInt8], decoded: [UInt8])
  case decodedBytesDoNotPrefixInput(seed: UInt64, bytes: [UInt8], decoded: [UInt8])
}

/// A single fuzz case result, retained for reproducibility.
public struct ISADecoderFuzzCase: Codable, Sendable, Hashable {
  public let seed: UInt64
  public let bytes: [UInt8]
  public let mode: DoryX86ExecutionMode
  public let outcome: String  // "decoded", "rejected", "crashed", "unexpectedError"
  public let decodedLength: Int?
  public let errorCategory: String?
  public let errorMessage: String?

  public init(
    seed: UInt64, bytes: [UInt8], mode: DoryX86ExecutionMode,
    outcome: String, decodedLength: Int? = nil,
    errorCategory: String? = nil, errorMessage: String? = nil
  ) {
    self.seed = seed
    self.bytes = bytes
    self.mode = mode
    self.outcome = outcome
    self.decodedLength = decodedLength
    self.errorCategory = errorCategory
    self.errorMessage = errorMessage
  }
}

/// A deterministic PRNG (SplitMix64) for reproducible fuzz seeds.
public struct ISAFuzzPRNG: Sendable {
  private var state: UInt64

  public init(seed: UInt64) {
    self.state = seed
  }

  public mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }

  public mutating func nextBytes(count: Int) -> [UInt8] {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(count)
    var remaining = count
    while remaining > 0 {
      let value = next()
      let toTake = min(8, remaining)
      for i in 0..<toTake {
        bytes.append(UInt8(truncatingIfNeeded: value >> (i * 8)))
      }
      remaining -= toTake
    }
    return bytes
  }
}

/// P2-04 item 7: A bounded decoder fuzz harness.
public enum ISADecoderFuzzHarness {
  /// The maximum number of bytes in an x86 instruction (15).
  public static let maxInstructionBytes = 15

  /// The minimum number of bytes to try (1 — a single byte is a valid
  /// instruction prefix or opcode).
  public static let minInstructionBytes = 1

  /// Run the fuzz harness with a fixed root seed and case count.
  /// Returns all case results, including any failures.
  public static func run(
    rootSeed: UInt64, caseCount: Int,
    decoder: DoryX86Decoder = .init()
  ) -> [ISADecoderFuzzCase] {
    var prng = ISAFuzzPRNG(seed: rootSeed)
    var results: [ISADecoderFuzzCase] = []
    results.reserveCapacity(caseCount * 4)  // 4 modes per case

    for caseIndex in 0..<caseCount {
      let caseSeed = prng.next()
      let byteCount = Int(prng.next() % UInt64(maxInstructionBytes - minInstructionBytes + 1))
        + minInstructionBytes
      var casePRNG = ISAFuzzPRNG(seed: caseSeed)
      let bytes = casePRNG.nextBytes(count: byteCount)

      for mode: DoryX86ExecutionMode in [.real16, .protected16, .protected32, .long64] {
        let result = decode(
          bytes: bytes, mode: mode, seed: caseSeed, decoder: decoder)
        results.append(result)
        if result.outcome == "crashed" || result.outcome == "unexpectedError" {
          return results  // Stop on first failure for reproducibility
        }
      }
      _ = caseIndex  // suppress unused warning
    }

    return results
  }

  /// Decode a single byte sequence in a single mode, classifying the outcome.
  public static func decode(
    bytes: [UInt8], mode: DoryX86ExecutionMode, seed: UInt64,
    decoder: DoryX86Decoder
  ) -> ISADecoderFuzzCase {
    do {
      let instruction = try decoder.decode(bytes, at: 0, mode: mode)
      // Verify the decoded bytes are a prefix of the input and don't exceed it.
      let decoded = instruction.bytes
      if decoded.count > bytes.count {
        return .init(
          seed: seed, bytes: bytes, mode: mode, outcome: "crashed",
          errorMessage: "decoded length \(decoded.count) exceeds input \(bytes.count)")
      }
      if !bytes.prefix(decoded.count).elementsEqual(decoded) {
        return .init(
          seed: seed, bytes: bytes, mode: mode, outcome: "crashed",
          errorMessage: "decoded bytes are not a prefix of input")
      }
      return .init(
        seed: seed, bytes: bytes, mode: mode, outcome: "decoded",
        decodedLength: decoded.count)
    } catch let error as DoryX86DecodeError {
      let category: String
      switch error {
      case .truncated: category = "truncated"
      case .instructionTooLong: category = "instructionTooLong"
      case .unsupportedOpcode: category = "unsupportedOpcode"
      case .invalidEncoding: category = "invalidEncoding"
      }
      return .init(
        seed: seed, bytes: bytes, mode: mode, outcome: "rejected",
        errorCategory: category, errorMessage: error.description)
    } catch {
      // Any non-DoryX86DecodeError is an unexpected decoder bug.
      return .init(
        seed: seed, bytes: bytes, mode: mode, outcome: "unexpectedError",
        errorMessage: String(describing: error))
    }
  }

  /// Summarize fuzz results by outcome.
  public static func summarize(_ cases: [ISADecoderFuzzCase]) -> [String: Int] {
    cases.reduce(into: [String: Int]()) { result, fuzzCase in
      result[fuzzCase.outcome, default: 0] += 1
    }
  }
}
