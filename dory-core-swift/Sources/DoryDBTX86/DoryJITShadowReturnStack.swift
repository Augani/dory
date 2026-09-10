import Darwin
import DoryJITRuntimeC

enum DoryJITShadowReturnStackError: Error, Sendable, Equatable {
  case invalidEntryCount(Int)
  case unavailable(Int32)
}

/// Per-vCPU return predictor storage. The generated path owns the same C entry and top-pointer
/// ABI; these methods provide its checked dispatcher/test fallback.
final class DoryJITShadowReturnStack: @unchecked Sendable {
  static let defaultEntryCount = 64

  private let storage: OpaquePointer

  init(entryCount: Int = defaultEntryCount) throws {
    guard entryCount > 0, entryCount.nonzeroBitCount == 1 else {
      throw DoryJITShadowReturnStackError.invalidEntryCount(entryCount)
    }
    var created: OpaquePointer?
    let result = dory_jit_shadow_return_stack_create(entryCount, &created)
    guard result == 0, let created else {
      throw DoryJITShadowReturnStackError.unavailable(result)
    }
    storage = created
  }

  deinit {
    dory_jit_shadow_return_stack_destroy(storage)
  }

  var entryCount: Int { dory_jit_shadow_return_stack_entry_count(storage) }
  var entryMask: UInt64 { UInt64(entryCount - 1) }
  var entriesBaseAddress: UInt64 {
    guard let entries = dory_jit_shadow_return_stack_entries(storage) else { return 0 }
    return UInt64(UInt(bitPattern: entries))
  }
  var topAddress: UInt64 {
    guard let top = dory_jit_shadow_return_stack_top(storage) else { return 0 }
    return UInt64(UInt(bitPattern: top))
  }

  func push(
    guestRSP: UInt64,
    guestRIP: UInt64,
    hostAddress: UInt64,
    generation: UInt64
  ) throws {
    let result = dory_jit_shadow_return_stack_push(
      storage, guestRSP, guestRIP, hostAddress, generation)
    guard result == 0 else { throw DoryJITShadowReturnStackError.unavailable(result) }
  }

  func lookupAndPop(guestRSP: UInt64, guestRIP: UInt64, generation: UInt64) throws -> UInt64? {
    var hostAddress: UInt64 = 0
    let result = dory_jit_shadow_return_stack_lookup_and_pop(
      storage, guestRSP, guestRIP, generation, &hostAddress)
    if result == ENOENT { return nil }
    guard result == 0 else { throw DoryJITShadowReturnStackError.unavailable(result) }
    return hostAddress
  }

  func removeAll() {
    dory_jit_shadow_return_stack_clear(storage)
  }
}
