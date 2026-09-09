import Darwin
import DoryJITRuntimeC

public enum DoryX86JITTLBAccess: Sendable, CaseIterable {
  case read
  case write
  case execute

  fileprivate var runtimeValue: dory_jit_tlb_access {
    switch self {
    case .read: DORY_JIT_TLB_ACCESS_READ
    case .write: DORY_JIT_TLB_ACCESS_WRITE
    case .execute: DORY_JIT_TLB_ACCESS_EXECUTE
    }
  }
}

public enum DoryX86JITTLBError: Error, Sendable, Equatable {
  case unavailable(Int32)
  case invalidEntryCount(Int)
  case invalidAddressSpaceGeneration(UInt64)
}

/// Per-vCPU direct-mapped translation storage shared by generated code and its slow path.
///
/// Each access class owns a distinct power-of-two array. An entry is exactly two words: an exact
/// tag and the wrapping delta from the guest linear address to its host address. The tag packs the
/// canonical 48-bit virtual page number and a nonzero 28-bit address-space generation without a
/// hash, so equality cannot admit an alias.
public final class DoryX86JITTLB: @unchecked Sendable {
  public static let defaultEntryCount = 1_024
  public static let entryByteCount = 16
  public static let pageShift = 12
  public static let addressSpaceGenerationBitCount = 28
  public static let maximumAddressSpaceGeneration: UInt64 =
    (1 << addressSpaceGenerationBitCount) - 1

  private let storage: OpaquePointer
  public let entryCount: Int

  public init(entryCount: Int = defaultEntryCount) throws {
    guard entryCount > 0, entryCount.nonzeroBitCount == 1 else {
      throw DoryX86JITTLBError.invalidEntryCount(entryCount)
    }
    var created: OpaquePointer?
    let result = dory_jit_tlb_create(entryCount, &created)
    guard result == 0, let created else {
      throw DoryX86JITTLBError.unavailable(result)
    }
    storage = created
    self.entryCount = dory_jit_tlb_entry_count(created)
    precondition(dory_jit_tlb_entry_size() == Self.entryByteCount)
  }

  deinit {
    dory_jit_tlb_destroy(storage)
  }

  public var allocatedByteCount: Int {
    entryCount * Self.entryByteCount * DoryX86JITTLBAccess.allCases.count
  }

  public func entriesBaseAddress(for access: DoryX86JITTLBAccess) -> UInt64 {
    guard let pointer = dory_jit_tlb_entries(storage, access.runtimeValue) else { return 0 }
    return UInt64(UInt(bitPattern: pointer))
  }

  public func lookup(
    linearAddress: UInt64,
    addressSpaceGeneration: UInt64,
    access: DoryX86JITTLBAccess
  ) throws -> UInt64? {
    let tag = try Self.tag(
      linearAddress: linearAddress,
      addressSpaceGeneration: addressSpaceGeneration
    )
    var hostAddress: UInt64 = 0
    let result = dory_jit_tlb_lookup(
      storage,
      access.runtimeValue,
      linearAddress,
      tag,
      &hostAddress
    )
    if result == ENOENT { return nil }
    guard result == 0 else { throw DoryX86JITTLBError.unavailable(result) }
    return hostAddress
  }

  public func fill(
    linearAddress: UInt64,
    addressSpaceGeneration: UInt64,
    access: DoryX86JITTLBAccess,
    hostAddress: UInt64
  ) throws {
    let tag = try Self.tag(
      linearAddress: linearAddress,
      addressSpaceGeneration: addressSpaceGeneration
    )
    let result = dory_jit_tlb_fill(
      storage,
      access.runtimeValue,
      linearAddress,
      tag,
      hostAddress
    )
    guard result == 0 else { throw DoryX86JITTLBError.unavailable(result) }
  }

  public func invalidate(linearAddress: UInt64) {
    dory_jit_tlb_invalidate_page(storage, linearAddress)
  }

  public func invalidateAll() {
    dory_jit_tlb_invalidate_all(storage)
  }

  public static func tag(
    linearAddress: UInt64,
    addressSpaceGeneration: UInt64
  ) throws -> UInt64 {
    guard (1...maximumAddressSpaceGeneration).contains(addressSpaceGeneration) else {
      throw DoryX86JITTLBError.invalidAddressSpaceGeneration(addressSpaceGeneration)
    }
    let virtualPageNumberMask: UInt64 = (1 << 36) - 1
    let virtualPageNumber = (linearAddress >> pageShift) & virtualPageNumberMask
    return (virtualPageNumber << addressSpaceGenerationBitCount) | addressSpaceGeneration
  }
}
