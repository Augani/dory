import Dispatch
import DoryJITRuntimeC
import Foundation
import Testing

@testable import DoryDBTX86

@Suite struct DoryX86NativePairAtomicityTests {
  @Test func alignedScalarJITAtomicHelpersUseLockFreeHostOperationsAtEveryWidth() throws {
    #if arch(arm64)
      let fixture = try PairAtomicityFixture()
      let offset: UInt64 = 0x100

      for byteCount: UInt32 in [1, 2, 4, 8] {
        let bitCount = UInt64(byteCount) * 8
        let mask = bitCount == 64 ? UInt64.max : (UInt64(1) << bitCount) - 1
        let initial = 0xA5A5_A5A5_A5A5_A5A5 & mask
        let replacement = 0x3C3C_3C3C_3C3C_3C3C & mask
        let exchanged = 0x1212_1212_1212_1212 & mask
        fixture.memory.storeBytes(of: initial, toByteOffset: Int(offset), as: UInt64.self)

        var observed: UInt64 = 0
        // Failed compare-exchange must report the actual scalar value and leave it intact.
        #expect(dory_jit_atomic_compare_exchange_from_context(
          fixture.context, fixture.memory, offset, initial ^ mask, replacement, byteCount, &observed
        ) == DORY_JIT_ATOMIC_RESOLUTION_SUCCESS.rawValue)
        #expect(observed == initial)
        #expect(fixture.memory.load(fromByteOffset: Int(offset), as: UInt64.self) & mask == initial)

        #expect(dory_jit_atomic_compare_exchange_from_context(
          fixture.context, fixture.memory, offset, initial, replacement, byteCount, &observed
        ) == DORY_JIT_ATOMIC_RESOLUTION_SUCCESS.rawValue)
        #expect(observed == initial)
        #expect(fixture.memory.load(fromByteOffset: Int(offset), as: UInt64.self) & mask == replacement)

        #expect(dory_jit_atomic_exchange_from_context(
          fixture.context, fixture.memory, offset, exchanged, byteCount, &observed
        ) == DORY_JIT_ATOMIC_RESOLUTION_SUCCESS.rawValue)
        #expect(observed == replacement)

        #expect(dory_jit_atomic_fetch_add_from_context(
          fixture.context, fixture.memory, offset, 3, byteCount, &observed
        ) == DORY_JIT_ATOMIC_RESOLUTION_SUCCESS.rawValue)
        #expect(observed == exchanged)

        #expect(dory_jit_atomic_rmw_from_context(
          fixture.context, fixture.memory, offset, 5, byteCount, 0, &observed
        ) == DORY_JIT_ATOMIC_RESOLUTION_SUCCESS.rawValue)
        #expect(observed == (exchanged + 3) & mask)
        #expect(
          fixture.memory.load(fromByteOffset: Int(offset), as: UInt64.self) & mask
            == (exchanged + 8) & mask
        )
      }
    #endif
  }

  @Test func mismatchingCMPXCHG16BDoesNotOverwriteConcurrentOrdinaryStores() throws {
    #if arch(arm64)
      let fixture = try PairAtomicityFixture()
      let started = DispatchSemaphore(value: 0)
      let finished = DispatchSemaphore(value: 0)
      DispatchQueue.global().async {
        started.signal()
        fixture.runOrdinaryWriter()
        finished.signal()
      }
      started.wait()
      var invalidResolutions = 0
      var invalidObservations = 0
      for _ in 0..<500_000 {
        // The high half remains 1, so every comparison must fail. A failed
        // comparison may observe a concurrent low-half store but may not undo it.
        var values = dory_jit_atomic_pair_values(
          expected_low: 0, expected_high: 0,
          desired_low: .max, desired_high: .max,
          observed_low: 0, observed_high: 0
        )
        let status = dory_jit_atomic_compare_exchange_pair_from_context(
          fixture.context, fixture.memory, 0, 16, &values
        )
        if status != DORY_JIT_ATOMIC_RESOLUTION_SUCCESS.rawValue { invalidResolutions += 1 }
        if values.observed_high != 1 { invalidObservations += 1 }
      }
      dory_jit_pending_work_store_release(fixture.stop, 1)
      finished.wait()
      #expect(invalidResolutions == 0)
      #expect(invalidObservations == 0)
      #expect(fixture.writeCount.pointee > 1_000, "The ordinary writer must overlap the CAS loop")
      #expect(fixture.overwrittenStores == 0, "CMPXCHG16B mismatch overwrote an ordinary store")
      #expect(fixture.memory.load(as: UInt64.self) == fixture.writeCount.pointee)
      #expect(fixture.memory.load(fromByteOffset: 8, as: UInt64.self) == 1)
    #endif
  }
}

#if arch(arm64)
// The writer is real generated AArch64 code, independent of C/Swift alias or
// data-race optimization assumptions. It uses ordinary acquire/release scalar
// accesses, never dory_jit_atomic_lock or any locked-RMW helper. On a mismatch
// the old two-load/two-store CMPXCHG16B helper can restore an obsolete low half
// between the writer's STLR and LDAR. A single hardware CAS cannot do so.
private final class PairAtomicityFixture: @unchecked Sendable {
  typealias Writer = @convention(c) (
    UnsafeMutableRawPointer, UnsafeMutablePointer<UInt8>, UnsafeMutablePointer<UInt64>
  ) -> UInt64

  let memory: UnsafeMutableRawPointer
  let context: UnsafeMutablePointer<UInt64>
  let stop: UnsafeMutablePointer<UInt8>
  let writeCount: UnsafeMutablePointer<UInt64>
  private let tlb: OpaquePointer
  private let region: OpaquePointer
  private let writer: Writer
  // Read only after the completion semaphore establishes the happens-before edge.
  private(set) var overwrittenStores: UInt64 = 0

  init() throws {
    var createdTLB: OpaquePointer?
    try #require(dory_jit_tlb_create(16, &createdTLB) == 0)
    let tlb = try #require(createdTLB)
    var createdRegion: OpaquePointer?
    let regionStatus = dory_jit_region_create(4096, &createdRegion)
    guard regionStatus == 0, let region = createdRegion else {
      dory_jit_tlb_destroy(tlb)
      throw DoryJITRuntimeError.unavailable(regionStatus)
    }
    let words: [UInt32] = [
      0xD280_0003,  // mov x3, #0       ; monotonically increasing stored value
      0xD280_0004,  // mov x4, #0       ; overwritten-store count
      0x9100_0463,  // add x3, x3, #1
      0xC89F_FC03,  // stlr x3, [x0]    ; ordinary store, no helper mutex
      0xC8DF_FC05,  // ldar x5, [x0]
      0xEB03_00BF,  // cmp x5, x3
      0x9A84_0484,  // cinc x4, x4, ne
      0x08DF_FC25,  // ldarb w5, [x1]   ; acquire stop flag
      0x34FF_FF45,  // cbz w5, -24      ; continue at ADD
      0xF900_0043,  // str x3, [x2]     ; final write count
      0xAA04_03E0,  // mov x0, x4
      0xD65F_03C0,  // ret
    ]
    let publicationStatus = words.withUnsafeBytes {
      dory_jit_region_publish(region, 0, $0.bindMemory(to: UInt8.self).baseAddress, $0.count)
    }
    guard publicationStatus == 0, let entry = dory_jit_region_entry(region, 0) else {
      dory_jit_region_destroy(region)
      dory_jit_tlb_destroy(tlb)
      throw DoryJITRuntimeError.publicationFailed(publicationStatus)
    }
    self.tlb = tlb
    self.region = region
    writer = unsafeBitCast(entry, to: Writer.self)
    memory = .allocate(byteCount: 4096, alignment: 4096)
    memory.initializeMemory(as: UInt8.self, repeating: 0, count: 4096)
    memory.storeBytes(of: UInt64(1), toByteOffset: 8, as: UInt64.self)
    context = .allocate(capacity: DoryJITExecutableRegion.contextWordCount)
    context.initialize(repeating: 0, count: DoryJITExecutableRegion.contextWordCount)
    context[DoryJITExecutableRegion.hostAddressSpaceBaseWordIndex] = UInt64(UInt(bitPattern: memory))
    context[DoryJITExecutableRegion.hostAddressSpaceByteCountWordIndex] = 4096
    context[DoryJITExecutableRegion.tlbAddressSpaceGenerationWordIndex] = 1
    context[DoryJITExecutableRegion.tlbStorageWordIndex] = UInt64(UInt(bitPattern: tlb))
    // Page zero, address-space generation one: the production resolver's exact tag.
    precondition(dory_jit_tlb_fill(tlb, DORY_JIT_TLB_ACCESS_WRITE, 0, 1,
      UInt64(UInt(bitPattern: memory))) == 0)
    stop = .allocate(capacity: 1)
    stop.initialize(to: 0)
    writeCount = .allocate(capacity: 1)
    writeCount.initialize(to: 0)
  }

  deinit {
    dory_jit_region_destroy(region)
    dory_jit_tlb_destroy(tlb)
    memory.deallocate()
    context.deallocate()
    stop.deallocate()
    writeCount.deallocate()
  }

  func runOrdinaryWriter() {
    overwrittenStores = writer(memory, stop, writeCount)
  }
}
#endif
