#if arch(arm64)
  import DoryPhase0AHostNativeWorkload
  import Foundation
  import Testing
  @testable import DoryNativeHVArm64

  @Suite(.serialized)
  struct NativeHVArm64EngineTests {
    @Test func hostNativeCounterLoopPreservesExactIterationCount() {
      #expect(dory_phase0a_native_counter_loop(10_000) == 10_000)
    }

    @Test func executesGuestAndCapturesArchitecturalState() throws {
      guard #available(macOS 15.0, *) else { return }
      guard ProcessInfo.processInfo.environment["DORY_RUN_NATIVE_HV_SMOKE"] == "1" else {
        return
      }
      let receipt = try DoryNativeHVArm64Smoke.run()
      #expect(receipt.hypercallNumber == 42)
      #expect(receipt.architecturalX0 == UInt64.max)
      #expect(receipt.programCounter == 0x8000_0008)
      #expect(receipt.dirtyPageCount == 1)
    }

    @Test func minimalHarnessExecutesFixedCounterLoop() throws {
      guard #available(macOS 15.0, *) else { return }
      guard ProcessInfo.processInfo.environment["DORY_RUN_NATIVE_HV_SMOKE"] == "1" else {
        return
      }

      let count = try DoryNativeHVArm64MinimalHarness.runCounterLoop()
      #expect(count == DoryNativeHVArm64MinimalHarness.counterLoopIterations)
    }
  }
#endif
