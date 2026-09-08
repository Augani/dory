#if arch(arm64)
  import DoryExecutionContracts
  import Foundation
  import Testing
  @testable import DoryNativeHVArm64

  @Suite struct NativeHVArm64HostClockTests {
    @Test func capturedTickHasAlreadyExpiredAndEarlierTickHasNot() {
      let now = DoryNativeHVArm64HostClock.nowTicks()
      let deadline = DoryVirtualDeadline(monotonicTicks: now)
      #expect(DoryNativeHVArm64HostClock.hasExpired(deadline, at: now))
      #expect(DoryNativeHVArm64HostClock.hasExpired(deadline, at: now &+ 1))
      if now > 0 {
        #expect(!DoryNativeHVArm64HostClock.hasExpired(deadline, at: now &- 1))
      }
    }

    @Test func futureNanosecondDeadlineIsNotExpiredAndConvertsBack() {
      let now = DoryNativeHVArm64HostClock.nowTicks()
      let deadline = DoryNativeHVArm64HostClock.deadline(nanosecondsFromNow: 250_000_000)
      #expect(!DoryNativeHVArm64HostClock.hasExpired(deadline, at: now))
      #expect(deadline.monotonicTicks > now)
      let remaining = DoryNativeHVArm64HostClock.nanosecondsUntil(deadline, from: now)
      #expect(remaining > 100_000_000)
      #expect(remaining < 500_000_000)
    }

    @Test func expiredDeadlineReportsZeroRemainingNanoseconds() {
      let now = DoryNativeHVArm64HostClock.nowTicks()
      let deadline = DoryVirtualDeadline(monotonicTicks: now)
      #expect(DoryNativeHVArm64HostClock.nanosecondsUntil(deadline, from: now) == 0)
      #expect(DoryNativeHVArm64HostClock.nanosecondsUntil(deadline, from: now &+ 10) == 0)
    }

    @Test func runningVCPUErrorDescribesTheFailure() {
      let error = DoryNativeHVArm64Error.vcpuStillRunning(DoryVCPUIdentifier(3))
      #expect(error.description.contains("still executing"))
      #expect(error.description.contains("3"))
    }

    @Test func fullWidthConversionRoundsUpAndSaturatesOnlyTheQuotient() {
      #expect(DoryNativeHVArm64HostClock.scaledCeiling(1, multiplier: 3, divisor: 125) == 1)
      #expect(DoryNativeHVArm64HostClock.scaledCeiling(125, multiplier: 3, divisor: 125) == 3)
      #expect(DoryNativeHVArm64HostClock.scaledCeiling(.max, multiplier: 3, divisor: 125) == 442_721_857_769_029_239)
      #expect(DoryNativeHVArm64HostClock.scaledCeiling(.max, multiplier: 125, divisor: 3) == .max)
      #expect(DoryNativeHVArm64HostClock.scaledCeiling(.max, multiplier: .max, divisor: .max) == .max)
      #expect(DoryNativeHVArm64HostClock.scaledCeiling(0, multiplier: 125, divisor: 3) == 0)
      #expect(DoryNativeHVArm64HostClock.ticks(addingNanoseconds: 1, to: .max) == .max)
    }

    @Test func tickNanosecondRoundTripDoesNotMoveBackward() {
      let now = DoryNativeHVArm64HostClock.nowTicks()
      let later = DoryNativeHVArm64HostClock.ticks(addingNanoseconds: 1_000_000, to: now)
      #expect(later >= now)
      let remaining = DoryNativeHVArm64HostClock.nanosecondsUntil(
        DoryVirtualDeadline(monotonicTicks: later),
        from: now
      )
      #expect(remaining >= 500_000)
    }
  }
#endif
