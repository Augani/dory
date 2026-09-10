import Darwin
import DoryJITRuntimeC

enum DoryJITBlockCacheError: Error, Sendable, Equatable {
  case unavailable(Int32)
  case invalidCapacity(Int)
}

struct DoryJITBlockCacheKey: Sendable, Hashable {
  let physicalRIP: UInt64
  let executionMode: DoryX86ExecutionMode
  let privilegeLevel: UInt8
  let pagingEnabled: Bool

  fileprivate var runtimeValue: dory_jit_block_key {
    var key = dory_jit_block_key()
    key.physical_rip = physicalRIP
    switch executionMode {
    case .real16: key.execution_mode = 0
    case .protected16: key.execution_mode = 1
    case .protected32: key.execution_mode = 2
    case .long64: key.execution_mode = 3
    }
    key.privilege_level = privilegeLevel
    key.paging_enabled = pagingEnabled ? 1 : 0
    return key
  }
}

/// C-owned open-addressed dispatch table. Values are nonzero Swift slot identifiers; the owning
/// executor retains block objects separately and retires those slots only while its dispatch lock
/// is held.
final class DoryJITBlockCache: @unchecked Sendable {
  private let storage: OpaquePointer

  init(initialCapacity: Int = 4_096) throws {
    guard initialCapacity > 0 else {
      throw DoryJITBlockCacheError.invalidCapacity(initialCapacity)
    }
    var created: OpaquePointer?
    let result = dory_jit_block_cache_create(initialCapacity, &created)
    guard result == 0, let created else {
      throw DoryJITBlockCacheError.unavailable(result)
    }
    storage = created
  }

  deinit {
    dory_jit_block_cache_destroy(storage)
  }

  var count: Int { dory_jit_block_cache_count(storage) }
  var capacity: Int { dory_jit_block_cache_capacity(storage) }

  func lookup(_ key: DoryJITBlockCacheKey) throws -> UInt64? {
    var value: UInt64 = 0
    let result = dory_jit_block_cache_lookup(storage, key.runtimeValue, &value)
    if result == ENOENT { return nil }
    guard result == 0 else { throw DoryJITBlockCacheError.unavailable(result) }
    return value
  }

  @discardableResult
  func insert(_ key: DoryJITBlockCacheKey, value: UInt64) throws -> UInt64? {
    var replaced: UInt64 = 0
    let result = dory_jit_block_cache_insert(storage, key.runtimeValue, value, &replaced)
    guard result == 0 else { throw DoryJITBlockCacheError.unavailable(result) }
    return replaced == 0 ? nil : replaced
  }

  @discardableResult
  func remove(_ key: DoryJITBlockCacheKey) throws -> UInt64? {
    var removed: UInt64 = 0
    let result = dory_jit_block_cache_remove(storage, key.runtimeValue, &removed)
    if result == ENOENT { return nil }
    guard result == 0 else { throw DoryJITBlockCacheError.unavailable(result) }
    return removed == 0 ? nil : removed
  }

  func removeAll() {
    dory_jit_block_cache_clear(storage)
  }
}
