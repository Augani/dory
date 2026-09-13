import DoryDBTX86
import Foundation

// P2-04 item 8: A feature promotion gate that prevents a CPU feature from
// being advertised to the guest until the conformance ledger has
// independently verified at least one instruction form that requires that
// feature. This prevents the engine from claiming support for a feature
// whose instruction forms have only been decoded, not independently verified.
//
// The gate is intentionally conservative: it requires independent
// verification (real hardware or an independent decoder/executor), not
// just interpreter or Tier1 agreement, because interpreter and Tier1 share
// the same decoder and helpers.

public enum ISAFeaturePromotionError: Error, Sendable, Equatable {
  case featureNotIndependentlyVerified(feature: String, formsRequiring: Int, formsVerified: Int)
}

/// P2-04 item 8: A gate that checks whether a CPU feature can be safely
/// promoted (advertised to the guest) based on the conformance ledger.
public enum ISAFeaturePromotionGate {
  /// Map DoryX86Feature to the string identifiers used in the conformance
  /// ledger's feature prerequisites.
  public static func featureIdentifier(_ feature: DoryX86Feature) -> String {
    switch feature {
    case .x87: return "x87"
    case .tsc: return "tsc"
    case .rdtscp: return "rdtscp"
    case .msr: return "msr"
    case .cmpxchg8b: return "cmpxchg8b"
    case .apic: return "apic"
    case .sysenter: return "sysenter"
    case .cmov: return "cmov"
    case .clflush: return "clflush"
    case .mmx: return "mmx"
    case .fxsave: return "fxsave"
    case .sse: return "sse"
    case .sse2: return "sse2"
    case .sse3: return "sse3"
    case .ssse3: return "ssse3"
    case .sse41: return "sse4.1"
    case .sse42: return "sse4.2"
    case .popcnt: return "popcnt"
    case .cmpxchg16b: return "cmpxchg16b"
    case .syscall: return "syscall"
    case .executeDisable: return "execute_disable"
    case .oneGiBPages: return "1gib_pages"
    case .longMode: return "long_mode"
    case .lahf64: return "lahf64"
    case .invariantTSC: return "invariant_tsc"
    case .xsave: return "xsave"
    case .osxsave: return "osxsave"
    case .avx: return "avx"
    case .avx2: return "avx2"
    case .pageSizeExtension: return "page_size_extension"
    case .physicalAddressExtension: return "physical_address_extension"
    case .pageGlobalEnable: return "page_global_enable"
    case .pageAttributeTable: return "page_attribute_table"
    case .f16c: return "f16c"
    case .fma: return "fma"
    case .bmi1: return "bmi1"
    case .bmi2: return "bmi2"
    case .lzcnt: return "lzcnt"
    case .movbe: return "movbe"
    case .rdrand: return "rdrand"
    case .rdseed: return "rdseed"
    }
  }

  /// Check whether a feature can be promoted given the conformance ledger.
  /// Returns the number of forms requiring the feature and the number of
  /// those forms that have been independently verified.
  public static func canPromote(
    feature: DoryX86Feature,
    ledgerEntries: [ISAConformanceLedgerEntry]
  ) -> (canPromote: Bool, formsRequiring: Int, formsVerified: Int) {
    let featureID = featureIdentifier(feature)
    let formsRequiring = ledgerEntries.filter {
      $0.featurePrerequisites.requiredFeatures.contains(featureID)
    }
    let formsVerified = formsRequiring.filter {
      $0.conformanceState >= .independentlyVerified
    }
    // A feature with no instruction forms in the ledger is treated as
    // not promotable — we have no evidence either way.
    let canPromote = !formsRequiring.isEmpty && formsVerified.count == formsRequiring.count
    return (canPromote, formsRequiring.count, formsVerified.count)
  }

  /// Check all features and return the ones that cannot be promoted.
  public static func nonPromotableFeatures(
    features: [DoryX86Feature],
    ledgerEntries: [ISAConformanceLedgerEntry]
  ) -> [(feature: DoryX86Feature, formsRequiring: Int, formsVerified: Int)] {
    features.compactMap { feature in
      let result = canPromote(feature: feature, ledgerEntries: ledgerEntries)
      if result.canPromote { return nil }
      return (feature, result.formsRequiring, result.formsVerified)
    }
  }
}
