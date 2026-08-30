#if arch(arm64)
  import Foundation
  import Testing
  @testable import DoryNativeHVArm64

  @Suite(.serialized)
  struct NativeHVArm64EngineTests {
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
  }
#endif
