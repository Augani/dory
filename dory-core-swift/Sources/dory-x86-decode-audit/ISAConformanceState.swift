import DoryDBTX86
import Foundation

// P2-04 item 2: Track distinct conformance states for each instruction vector.
// A generic family checkbox must not cover untested operand forms. Each vector
// progresses through these states independently, and a state is only reached
// when explicit evidence exists for that exact form.

/// The conformance state of a single instruction vector within the x86
/// conformance ledger. States are ordered: a vector cannot skip a state.
public enum ISAConformanceState: String, Codable, Sendable, Hashable, Comparable {
  /// The byte vector was rejected by the decoder as a malformed or unsupported
  /// encoding. This is distinct from a valid unsupported instruction that the
  /// decoder recognizes but the execution engines do not implement.
  case rejected

  /// The decoder recognized the encoding as a valid x86 instruction form but
  /// has not yet been exercised through any execution engine. This covers both
  /// fully decoded instructions and recognized-but-unsupported system
  /// instructions (e.g. MONITOR).
  case recognized

  /// The interpreter successfully retired the instruction with architecturally
  /// defined results. The interpreter shares decoder and helpers with the JIT,
  /// so this alone does not establish independent correctness.
  case interpreted

  /// The baseline (Tier1) JIT successfully retired the instruction with
  /// results matching the interpreter. Agreement between interpreter and Tier1
  /// cannot detect a shared decoder/helper bug.
  case loweredTier1

  /// The optimizing (Tier2) JIT successfully retired the instruction with
  /// results matching the interpreter and Tier1. Tier2 is not yet admitted
  /// for production; this state is only reached when Tier2 is exercised.
  case loweredTier2

  /// An independent reference (real Intel/AMD hardware or an independent
  /// decoder/executor) confirmed the architecturally defined results for
  /// this exact form. This is the state that breaks shared-decoder blindness.
  case independentlyVerified

  /// A real workload (kernel boot, userspace application, or installer)
  /// exercised this exact form and produced correct observable behavior.
  /// Workload qualification is separate from per-instruction verification;
  /// it covers integration but does not replace independent reference proof.
  case workloadQualified

  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.rank < rhs.rank
  }

  private var rank: Int {
    switch self {
    case .rejected: 0
    case .recognized: 1
    case .interpreted: 2
    case .loweredTier1: 3
    case .loweredTier2: 4
    case .independentlyVerified: 5
    case .workloadQualified: 6
    }
  }
}

/// The privilege level required to execute an instruction form.
/// x86 has four privilege rings (0-3); Dory's baseline profile admits
/// ring 0 (supervisor) and ring 3 (user). Instructions that require
/// a specific privilege level must be tested at that level.
public enum ISAPrivilegeLevel: String, Codable, Sendable, Hashable {
  /// The instruction executes at any privilege level (ring 0-3).
  case any

  /// The instruction requires supervisor privilege (ring 0).
  case supervisor

  /// The instruction executes at user privilege (ring 3) and does not
  /// require supervisor access. Most user-mode instructions are `.any`.
  case user
}

/// CPUID feature flags required to execute an instruction form.
/// Derived from Intel SDM Vol. 2 CPUID feature flag tables.
/// An empty set means the instruction is part of the baseline ISA.
public struct ISAFeaturePrerequisites: Codable, Sendable, Hashable {
  public let requiredFeatures: Set<String>
  public let faultOnMissing: String  // e.g. "#UD" or "#GP(0)"

  public init(requiredFeatures: Set<String> = [], faultOnMissing: String = "#UD") {
    self.requiredFeatures = requiredFeatures
    self.faultOnMissing = faultOnMissing
  }

  public static let none = ISAFeaturePrerequisites()
}

/// P2-04 item 1: A machine-readable instruction ledger entry keyed by
/// encoding map/opcode/prefix/form, with operand and address sizes, mode,
/// privilege, feature prerequisites, fault behavior, and memory ordering.
public struct ISAConformanceLedgerEntry: Codable, Sendable, Hashable {
  public let vectorID: String
  public let encodingMap: String  // e.g. "legacy", "0F", "0F01", "VEX", "EVEX"
  public let opcode: String  // hex opcode bytes without prefixes
  public let prefixForm: String  // e.g. "none", "REX.W", "VEX.128", "66 0F"
  public let form: String  // e.g. "register", "memory", "immediate"
  public let mode: DoryX86ExecutionMode
  public let privilege: ISAPrivilegeLevel
  public let featurePrerequisites: ISAFeaturePrerequisites
  public let faultBehavior: String  // e.g. "none", "#UD", "#GP(0)", "#PF", "#SS"
  public let memoryOrdering: String  // e.g. "none", "TSO", "locked", "serializing"
  public let conformanceState: ISAConformanceState

  public init(
    vectorID: String,
    encodingMap: String,
    opcode: String,
    prefixForm: String,
    form: String,
    mode: DoryX86ExecutionMode,
    privilege: ISAPrivilegeLevel,
    featurePrerequisites: ISAFeaturePrerequisites,
    faultBehavior: String,
    memoryOrdering: String,
    conformanceState: ISAConformanceState
  ) {
    self.vectorID = vectorID
    self.encodingMap = encodingMap
    self.opcode = opcode
    self.prefixForm = prefixForm
    self.form = form
    self.mode = mode
    self.privilege = privilege
    self.featurePrerequisites = featurePrerequisites
    self.faultBehavior = faultBehavior
    self.memoryOrdering = memoryOrdering
    self.conformanceState = conformanceState
  }
}

/// Derives the encoding map from a decoded instruction's byte sequence.
/// The encoding map identifies which opcode map the instruction uses:
///   - "legacy" for 1-byte opcodes
///   - "0F" for 2-byte opcodes (0F xx)
///   - "0F01" for group 2 system instructions (0F 01 ModRM)
///   - "VEX" for VEX-encoded instructions
///   - "EVEX" for EVEX-encoded instructions
public enum ISAEncodingMap {
  public static func derive(from bytes: [UInt8], prefixes: DoryX86InstructionPrefixes) -> String {
    if prefixes.vex != nil { return "VEX" }
    var cursor = 0
    while cursor < bytes.count {
      let byte = bytes[cursor]
      switch byte {
      case 0x26, 0x2E, 0x36, 0x3E, 0x64, 0x65, 0xF0, 0xF2, 0xF3, 0x66, 0x67:
        cursor += 1
      case 0x40...0x4F:  // REX
        cursor += 1
      default:
        if byte == 0x0F {
          if cursor + 1 < bytes.count, bytes[cursor + 1] == 0x01 {
            return "0F01"
          }
          return "0F"
        }
        return "legacy"
      }
    }
    return "legacy"
  }
}

/// Derives the prefix form string from decoded instruction prefixes.
public enum ISAPrefixForm {
  public static func derive(from prefixes: DoryX86InstructionPrefixes) -> String {
    var parts: [String] = []
    if prefixes.lock { parts.append("LOCK") }
    if let repeatPrefix = prefixes.repeatPrefix {
      parts.append(String(format: "REP%02X", repeatPrefix))
    }
    if let segment = prefixes.segmentOverride {
      parts.append(String(format: "SEG%02X", segment))
    }
    if prefixes.operandSizeOverride { parts.append("66") }
    if prefixes.addressSizeOverride { parts.append("67") }
    if let rex = prefixes.rex {
      var rexParts = ["REX"]
      if rex.w { rexParts.append(".W") }
      if rex.r { rexParts.append(".R") }
      if rex.x { rexParts.append(".X") }
      if rex.b { rexParts.append(".B") }
      parts.append(rexParts.joined())
    }
    if let vex = prefixes.vex {
      var vexParts = ["VEX"]
      if vex.largeVector { vexParts.append(".256") } else { vexParts.append(".128") }
      if vex.w { vexParts.append(".W") }
      parts.append(vexParts.joined())
    }
    return parts.isEmpty ? "none" : parts.joined(separator: " ")
  }
}

/// Derives the conformance state from an ISAInventoryRecord's fields.
/// This maps the existing qualification fields to the ordered conformance
/// state enum. The state is the highest reached state for which explicit
/// evidence exists.
public enum ISAConformanceStateResolver {
  public static func resolve(
    decoderSupport: String,
    interpreterSemantics: ISAQualification,
    jitBaseline: ISAQualification,
    jitOptimizing: ISAQualification,
    independentReference: ISAQualification,
    executedFormCount _: Int,
    realWorkload _: ISAQualification? = nil
  ) -> ISAConformanceState {
    if decoderSupport == "rejected" { return .rejected }
    // Counts and caller-authored annotations cannot authenticate a workload.
    // Retain these parameters for source compatibility, without promotion power.
    if independentReference.status == "verified" { return .independentlyVerified }
    if jitOptimizing.status == "supported" { return .loweredTier2 }
    if jitBaseline.status == "supported" { return .loweredTier1 }
    if interpreterSemantics.status == "supported" { return .interpreted }
    return .recognized
  }

  // Top-tier authority comes entirely from the opaque, catalog-derived two-leg
  // proof. A plain reference annotation can affect only the lower-tier fallback.
  static func resolve(
    decoderSupport: String,
    interpreterSemantics: ISAQualification,
    jitBaseline: ISAQualification,
    jitOptimizing: ISAQualification,
    independentReference: ISAQualification,
    executedFormCount: Int,
    vector: ISAVector,
    authenticatedProof: ISAWorkloadQualifiedProof?
  ) -> ISAConformanceState {
    let state = resolve(
      decoderSupport: decoderSupport, interpreterSemantics: interpreterSemantics,
      jitBaseline: jitBaseline, jitOptimizing: jitOptimizing,
      independentReference: independentReference, executedFormCount: executedFormCount)
    if state != .rejected && authenticatedProof?.authenticates(vector) == true {
      return .workloadQualified
    }
    return state
  }
}
