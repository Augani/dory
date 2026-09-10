import Darwin
import DoryJITRuntimeC

enum DoryJITIndirectBranchTargetCacheError: Error, Sendable, Equatable {
  case invalidEntryCount(Int)
  case unavailable(Int32)
}

struct DoryJITIndirectBranchTargetCacheDiagnostics: Sendable, Hashable {
  let hits: UInt64
  let misses: UInt64
  let fills: UInt64

  var hitRate: Double? {
    let lookups = hits + misses
    return lookups == 0 ? nil : Double(hits) / Double(lookups)
  }
}

/// Direct-mapped per-vCPU indirect-branch target cache. Its 32-byte C entries and shift/mask
/// index are intentionally stable so the tier-1 emitter can perform the hit path inline.
final class DoryJITIndirectBranchTargetCache: @unchecked Sendable {
  static let defaultEntryCount = 4_096

  private let storage: OpaquePointer

  init(entryCount: Int = defaultEntryCount) throws {
    guard entryCount > 0, entryCount.nonzeroBitCount == 1 else {
      throw DoryJITIndirectBranchTargetCacheError.invalidEntryCount(entryCount)
    }
    var created: OpaquePointer?
    let result = dory_jit_ibtc_create(entryCount, &created)
    guard result == 0, let created else {
      throw DoryJITIndirectBranchTargetCacheError.unavailable(result)
    }
    storage = created
  }

  deinit {
    dory_jit_ibtc_destroy(storage)
  }

  var entryCount: Int { dory_jit_ibtc_entry_count(storage) }
  var entryMask: UInt64 { UInt64(entryCount - 1) }
  var entriesBaseAddress: UInt64 {
    guard let entries = dory_jit_ibtc_entries(storage) else { return 0 }
    return UInt64(UInt(bitPattern: entries))
  }

  func index(for guestRIP: UInt64) -> Int {
    dory_jit_ibtc_index(storage, guestRIP)
  }

  func lookup(guestRIP: UInt64, generation: UInt64) throws -> UInt64? {
    var hostAddress: UInt64 = 0
    let result = dory_jit_ibtc_lookup(storage, guestRIP, generation, &hostAddress)
    if result == ENOENT { return nil }
    guard result == 0 else {
      throw DoryJITIndirectBranchTargetCacheError.unavailable(result)
    }
    return hostAddress
  }

  func fill(guestRIP: UInt64, generation: UInt64, hostAddress: UInt64) throws {
    let result = dory_jit_ibtc_fill(storage, guestRIP, generation, hostAddress)
    guard result == 0 else {
      throw DoryJITIndirectBranchTargetCacheError.unavailable(result)
    }
  }

  func removeAll() {
    dory_jit_ibtc_clear(storage)
  }

  var diagnostics: DoryJITIndirectBranchTargetCacheDiagnostics {
    .init(
      hits: dory_jit_ibtc_hit_count(storage),
      misses: dory_jit_ibtc_miss_count(storage),
      fills: dory_jit_ibtc_fill_count(storage)
    )
  }
}
