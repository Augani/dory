import Darwin
import Dispatch
import DoryJITRuntimeC
import Foundation
import Testing

@testable import DoryDBTX86

// These probes deliberately hold one machine's interpreter/native atomic coordinator while a
// worker attempts the matching native helper. Running the probes concurrently can starve the
// worker pool with coordinator owners and produce a test-created deadlock rather than exercise
// guest atomicity.
@Suite(.serialized) struct DoryX86NativePairAtomicityTests {
  @Test(arguments: [1, 2, 4, 8] as [UInt32])
  func mmapScalarTransactionsShareTheNativeAtomicDomain(byteCount: UInt32) throws {
    let memory = try DoryX86MmapMemory(validatingByteCount: 0x2000)
    let address: UInt64 = 0x100
    let hostAddress = try #require(
      UnsafeMutableRawPointer(
        bitPattern: UInt(memory.hostAddressSpaceBase + address)))
    let mask = UInt64.max >> (64 - byteCount * 8)
    let first = 0x8877_6655_4433_2211 & mask
    let second = 0x0123_4567_89AB_CDEF & mask
    let third = 0xFEDC_BA98_7654_3210 & mask

    try memory.writeScalar(at: address, value: first, byteCount: Int(byteCount))
    var observed: UInt64 = 0
    #expect(dory_atomic_scalar_load_seq_cst(hostAddress, byteCount, &observed) == 0)
    #expect(observed == first)

    #expect(dory_atomic_scalar_store_seq_cst(hostAddress, second, byteCount) == 0)
    #expect(try memory.readScalar(at: address, byteCount: Int(byteCount)) == second)
    #expect(
      try memory.read(at: address, byteCount: Int(byteCount))
        == (0..<Int(byteCount)).map {
          UInt8(truncatingIfNeeded: second >> UInt64($0 * 8))
        })

    #expect(
      try memory.compareExchangeScalar(
        at: address,
        expected: second,
        desired: third,
        byteCount: Int(byteCount)
      ) == second)
    #expect(dory_atomic_scalar_load_seq_cst(hostAddress, byteCount, &observed) == 0)
    #expect(observed == third)
  }

  @Test func nativeScalarTransactionsRejectMisalignedHostAddresses() throws {
    let memory = try DoryX86MmapMemory(validatingByteCount: 0x1000)
    let misaligned = try #require(
      UnsafeMutableRawPointer(
        bitPattern: UInt(memory.hostAddressSpaceBase + 1)))
    var observed: UInt64 = 0
    #expect(dory_atomic_scalar_load_seq_cst(misaligned, 8, &observed) == EINVAL)
    #expect(dory_atomic_scalar_store_seq_cst(misaligned, 1, 8) == EINVAL)
    #expect(
      dory_atomic_scalar_compare_exchange_seq_cst(misaligned, 0, 1, 8, &observed) == EINVAL)
  }

  @Test(arguments: [1, 2, 4, 8] as [UInt32])
  func scalarNativeHelpersWaitForOwningMachineCoordinator(byteCount: UInt32) throws {
    #if arch(arm64)
      let fixture = try PairAtomicityFixture()
      let offset: UInt64 = 0x100
      let mask = UInt64.max >> (64 - byteCount * 8)

      for helper in ScalarAtomicHelper.allCases {
        fixture.memory.storeBytes(of: UInt64(0x35), toByteOffset: Int(offset), as: UInt64.self)
        let probe = ScalarAtomicGateProbe()
        let completed = DispatchGroup()
        let result = ScalarAtomicResult()
        completed.enter()
        try fixture.coordinator.withLock {
          Thread.detachNewThread {
            result.run(helper, fixture: fixture, offset: offset, byteCount: byteCount, probe: probe)
            completed.leave()
          }
          try #require(try probe.waitUntilBlocked(timeout: .now() + 2),
            "\(helper) did not block on the owning machine's coordinator")
          // Admission requires a kernel-observed wait inside the invocation, not
          // merely a worker scheduled (or descheduled) just before the helper call.
          #expect(completed.wait(timeout: .now()) == .timedOut,
            "\(helper) completed while the owning machine's coordinator was held")
          #expect(fixture.memory.load(fromByteOffset: Int(offset), as: UInt64.self) == 0x35,
            "\(helper) changed memory before acquiring the owning machine's coordinator")
        }
        try #require(completed.wait(timeout: .now() + 2) == .success)
        #expect(result.status == DORY_JIT_ATOMIC_RESOLUTION_SUCCESS.rawValue)
        #expect(result.observed == 0x35)
        // Reading after completion also keeps the failure path free of concurrent loads.
        #expect(fixture.memory.load(fromByteOffset: Int(offset), as: UInt64.self)
          == helper.finalValue & mask)
      }
    #endif
  }

  @Test func rejectedScalarNativeOperandsDoNotWaitForMachineCoordinator() throws {
    #if arch(arm64)
      let fixture = try PairAtomicityFixture()
      fixture.memory.storeBytes(of: UInt64(0x35), toByteOffset: 0x100, as: UInt64.self)
      fixture.memory.storeBytes(of: UInt64(0x35), toByteOffset: 0xFF8, as: UInt64.self)
      let operands: [(UInt64, UInt32, UInt32)] = [
        (0x101, 8, DORY_JIT_ATOMIC_RESOLUTION_FALLBACK.rawValue),  // Unaligned host operand.
        (0xFFF, 8, DORY_JIT_ATOMIC_RESOLUTION_FALLBACK.rawValue),  // Split page operand.
        (0x100, 3, DORY_JIT_ATOMIC_RESOLUTION_ERROR.rawValue),  // Invalid scalar width.
      ]

      for helper in ScalarAtomicHelper.allCases {
        for (offset, byteCount, status) in operands {
          let completed = DispatchGroup()
          let result = ScalarAtomicResult()
          completed.enter()
          try fixture.coordinator.withLock {
            Thread.detachNewThread {
              result.run(helper, fixture: fixture, offset: offset, byteCount: byteCount)
              completed.leave()
            }
            // Rejected operands must return even while this thread owns the gate.
            try #require(completed.wait(timeout: .now() + 2) == .success,
              "\(helper) waited for the coordinator on a rejected operand")
          }
          #expect(result.status == status)
          #expect(result.observed == UInt64.max)
          #expect(fixture.memory.load(fromByteOffset: 0x100, as: UInt64.self) == 0x35)
          #expect(fixture.memory.load(fromByteOffset: 0xFF8, as: UInt64.self) == 0x35)
        }
      }
    #endif
  }

  @Test func scalarNativeHelpersEnterTheOrdinaryMemoryRangeAuthority() throws {
    #if arch(arm64)
      let fixture = try PairAtomicityFixture()
      let offset: UInt64 = 0x100
      let lowerBound = UInt64(UInt(bitPattern: fixture.memory)) + offset

      for helper in ScalarAtomicHelper.allCases {
        fixture.memory.storeBytes(of: UInt64(0x35), toByteOffset: Int(offset), as: UInt64.self)
        let exclusive = fixture.memoryAccessCoordinator.acquireExclusive(
          ranges: [lowerBound..<(lowerBound + 8)])
        let probe = ScalarAtomicGateProbe()
        let completed = DispatchGroup()
        let result = ScalarAtomicResult()
        completed.enter()
        Thread.detachNewThread {
          result.run(helper, fixture: fixture, offset: offset, byteCount: 8, probe: probe)
          completed.leave()
        }
        try #require(try probe.waitUntilBlocked(timeout: .now() + 2),
          "\(helper) did not join the ordinary memory range authority")
        #expect(completed.wait(timeout: .now()) == .timedOut)
        #expect(fixture.memory.load(fromByteOffset: Int(offset), as: UInt64.self) == 0x35)
        exclusive.release()
        try #require(completed.wait(timeout: .now() + 2) == .success)
        #expect(result.status == DORY_JIT_ATOMIC_RESOLUTION_SUCCESS.rawValue)
      }
    #endif
  }

  @Test func nativeCMPXCHG16BEntersTheOrdinaryMemoryRangeAuthority() throws {
    #if arch(arm64)
      let fixture = try PairAtomicityFixture()
      let lowerBound = UInt64(UInt(bitPattern: fixture.memory))
      let exclusive = fixture.memoryAccessCoordinator.acquireExclusive(
        ranges: [lowerBound..<(lowerBound + 16)])
      let probe = ScalarAtomicGateProbe()
      let completed = DispatchGroup()
      let result = PairAtomicResult()
      completed.enter()
      Thread.detachNewThread {
        result.run(fixture: fixture, probe: probe)
        completed.leave()
      }
      try #require(try probe.waitUntilBlocked(timeout: .now() + 2),
        "CMPXCHG16B did not join the ordinary memory range authority")
      #expect(completed.wait(timeout: .now()) == .timedOut)
      exclusive.release()
      try #require(completed.wait(timeout: .now() + 2) == .success)
      #expect(result.status == DORY_JIT_ATOMIC_RESOLUTION_SUCCESS.rawValue)
      #expect(result.observedLow == 0)
      #expect(result.observedHigh == 1)
    #endif
  }

  @Test func nativeAtomicHelpersDeclineWithoutMemoryRangeAuthority() throws {
    #if arch(arm64)
      let fixture = try PairAtomicityFixture()
      fixture.context[DoryJITExecutableRegion.memoryAccessCoordinatorWordIndex] = 0
      fixture.memory.storeBytes(of: UInt64(0x35), toByteOffset: 0x100, as: UInt64.self)
      var observed: UInt64 = 0
      #expect(
        dory_jit_atomic_exchange_from_context(
          fixture.context,
          fixture.memory,
          0x100,
          0x12,
          8,
          &observed
        ) == DORY_JIT_ATOMIC_RESOLUTION_FALLBACK.rawValue
      )
      var values = dory_jit_atomic_pair_values(
        expected_low: 0,
        expected_high: 1,
        desired_low: 0xAAAA,
        desired_high: 0xBBBB,
        observed_low: 0,
        observed_high: 0
      )
      #expect(
        dory_jit_atomic_compare_exchange_pair_from_context(
          fixture.context,
          fixture.memory,
          0,
          16,
          &values
        ) == DORY_JIT_ATOMIC_RESOLUTION_FALLBACK.rawValue
      )
      #expect(fixture.memory.load(fromByteOffset: 0x100, as: UInt64.self) == 0x35)
      #expect(fixture.memory.load(as: UInt64.self) == 0)
      #expect(fixture.memory.load(fromByteOffset: 8, as: UInt64.self) == 1)
    #endif
  }

  @Test func independentMachineCoordinatorsDoNotSerializeOneAnother() throws {
    #if arch(arm64)
      let firstMachine = try PairAtomicityFixture()
      let secondMachine = try PairAtomicityFixture()
      secondMachine.memory.storeBytes(of: UInt64(0x35), toByteOffset: 0x100, as: UInt64.self)
      let completed = DispatchGroup()
      let result = ScalarAtomicResult()
      completed.enter()
      try firstMachine.coordinator.withLock {
        Thread.detachNewThread {
          result.run(.exchange, fixture: secondMachine, offset: 0x100, byteCount: 8)
          completed.leave()
        }
        try #require(completed.wait(timeout: .now() + 2) == .success,
          "an independent virtual machine waited for another machine's coordinator")
      }
      #expect(result.status == DORY_JIT_ATOMIC_RESOLUTION_SUCCESS.rawValue)
      #expect(result.observed == 0x35)
      #expect(secondMachine.memory.load(fromByteOffset: 0x100, as: UInt64.self) == 0x12)
    #endif
  }

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
      Thread.detachNewThread {
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
private enum ScalarAtomicHelper: CaseIterable, Sendable {
  case compareExchange, compareExchangeMismatch, exchange, fetchAdd
  case add, subtract, and, or, xor, negate

  var finalValue: UInt64 {
    switch self {
    case .compareExchange, .exchange: return 0x12
    case .compareExchangeMismatch: return 0x35
    case .fetchAdd, .add: return 0x47
    case .subtract: return 0x23
    case .and: return 0x10
    case .or: return 0x37
    case .xor: return 0x27
    case .negate: return 0 &- 0x35
    }
  }
}

// Written by one worker and read only after its completion group establishes happens-before.
private final class ScalarAtomicResult: @unchecked Sendable {
  private(set) var status: Int32 = -1
  private(set) var observed: UInt64 = .max

  func run(
    _ helper: ScalarAtomicHelper, fixture: PairAtomicityFixture, offset: UInt64, byteCount: UInt32,
    probe: ScalarAtomicGateProbe? = nil
  ) {
    // Resolve Swift properties before the probe interval. The interval contains
    // only the C invocation and scalar result assignments; its only blocking
    // operation is the native gate (the fixture supplies a resident TLB hit).
    let context = fixture.context
    let memory = fixture.memory
    var observed = UInt64.max
    let status: Int32
    switch helper {
    case .compareExchange, .compareExchangeMismatch:
      let expected: UInt64 = helper == .compareExchange ? 0x35 : 0
      probe?.begin()
      status = dory_jit_atomic_compare_exchange_from_context(
        context, memory, offset, expected, 0x12, byteCount, &observed)
      probe?.end()
    case .exchange:
      probe?.begin()
      status = dory_jit_atomic_exchange_from_context(
        context, memory, offset, 0x12, byteCount, &observed)
      probe?.end()
    case .fetchAdd:
      probe?.begin()
      status = dory_jit_atomic_fetch_add_from_context(
        context, memory, offset, 0x12, byteCount, &observed)
      probe?.end()
    default:
      let operation: UInt32
      switch helper {
      case .add: operation = UInt32(DORY_JIT_ATOMIC_RMW_ADD.rawValue)
      case .subtract: operation = UInt32(DORY_JIT_ATOMIC_RMW_SUBTRACT.rawValue)
      case .and: operation = UInt32(DORY_JIT_ATOMIC_RMW_AND.rawValue)
      case .or: operation = UInt32(DORY_JIT_ATOMIC_RMW_OR.rawValue)
      case .xor: operation = UInt32(DORY_JIT_ATOMIC_RMW_XOR.rawValue)
      case .negate: operation = UInt32(DORY_JIT_ATOMIC_RMW_NEGATE.rawValue)
      default: preconditionFailure("Expected a generic RMW helper")
      }
      probe?.begin()
      status = dory_jit_atomic_rmw_from_context(
        context, memory, offset, 0x12, byteCount, operation, &observed)
      probe?.end()
    }
    self.status = status
    self.observed = observed
  }
}

private final class PairAtomicResult: @unchecked Sendable {
  private(set) var status: Int32 = -1
  private(set) var observedLow: UInt64 = .max
  private(set) var observedHigh: UInt64 = .max

  func run(fixture: PairAtomicityFixture, probe: ScalarAtomicGateProbe) {
    var values = dory_jit_atomic_pair_values(
      expected_low: 0,
      expected_high: 0,
      desired_low: 0xAAAA,
      desired_high: 0xBBBB,
      observed_low: 0,
      observed_high: 0
    )
    probe.begin()
    status = dory_jit_atomic_compare_exchange_pair_from_context(
      fixture.context,
      fixture.memory,
      0,
      16,
      &values
    )
    probe.end()
    observedLow = values.observed_low
    observedHigh = values.observed_high
  }
}

private final class ScalarAtomicGateProbe: @unchecked Sendable {
  // 0: setup; 1: native invocation; 2: returned. The release/acquire edge also
  // publishes the Mach thread port. It is never read before phase 1 is observed.
  private let phase: UnsafeMutablePointer<UInt8> = .allocate(capacity: 1)
  private var worker: mach_port_t = 0

  init() { phase.initialize(to: 0) }
  deinit { phase.deallocate() }

  func begin() {
    worker = pthread_mach_thread_np(pthread_self())
    dory_jit_pending_work_store_release(phase, 1)
  }

  func end() { dory_jit_pending_work_store_release(phase, 2) }

  func waitUntilBlocked(timeout: DispatchTime) throws -> Bool {
    while DispatchTime.now() < timeout {
      let current = dory_jit_pending_work_load_acquire(phase)
      if current == 2 { return false }
      if current == 1 {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(
          MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
          $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            thread_info(worker, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
          }
        }
        // Recheck after the snapshot: a finished dispatch worker may already be
        // parked on unrelated queue work. Such a wait must never count as admission.
        if dory_jit_pending_work_load_acquire(phase) == 2 { return false }
        try #require(status == KERN_SUCCESS, "Cannot inspect the native helper worker")
        if info.run_state == TH_STATE_WAITING { return true }
      }
      // Yield only to let the worker progress. Elapsed time is a failure bound,
      // never evidence of contention; a descheduled runnable worker cannot pass.
      sched_yield()
    }
    return false
  }
}

// The writer is real generated AArch64 code, independent of C/Swift alias or
// data-race optimization assumptions. It uses ordinary acquire/release scalar
// accesses, never the machine coordinator or any locked-RMW helper. On a mismatch
// the old two-load/two-store CMPXCHG16B helper can restore an obsolete low half
// between the writer's STLR and LDAR. A single hardware CAS cannot do so.
private final class PairAtomicityFixture: @unchecked Sendable {
  typealias Writer = @convention(c) (
    UnsafeMutableRawPointer, UnsafeMutablePointer<UInt8>, UnsafeMutablePointer<UInt64>
  ) -> UInt64

  let memory: UnsafeMutableRawPointer
  let context: UnsafeMutablePointer<UInt64>
  let coordinator = DoryX86AtomicCoordinator()
  let memoryAccessCoordinator = DoryX86MemoryAccessCoordinator()
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
    context[DoryJITExecutableRegion.atomicCoordinatorWordIndex] = coordinator.opaqueReference
    context[DoryJITExecutableRegion.memoryAccessCoordinatorWordIndex] =
      memoryAccessCoordinator.opaqueReference
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
