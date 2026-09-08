#if arch(arm64)
  import Darwin
  import DoryExecutionContracts

  /// Host `mach_absolute_time()` mapping for `DoryVirtualDeadline`.
  ///
  /// Apple documents the same tick unit for x86 `hv_vcpu_run_until` (`HV_DEADLINE`).
  /// ARM64 Hypervisor.framework has no `hv_vcpu_run_until`, so the engine compares this
  /// clock itself and wakes `hv_vcpu_run` with `hv_vcpus_exit`.
  enum DoryNativeHVArm64HostClock {
    static func nowTicks() -> UInt64 {
      mach_absolute_time()
    }

    static func hasExpired(_ deadline: DoryVirtualDeadline, at ticks: UInt64) -> Bool {
      ticks >= deadline.monotonicTicks
    }

    static func deadline(nanosecondsFromNow nanoseconds: UInt64) -> DoryVirtualDeadline {
      DoryVirtualDeadline(
        monotonicTicks: ticks(addingNanoseconds: nanoseconds, to: nowTicks())
      )
    }

    static func nanosecondsUntil(_ deadline: DoryVirtualDeadline, from ticks: UInt64) -> UInt64 {
      guard deadline.monotonicTicks > ticks else { return 0 }
      return ticksToNanoseconds(deadline.monotonicTicks - ticks)
    }

    static func ticks(addingNanoseconds nanoseconds: UInt64, to ticks: UInt64) -> UInt64 {
      let added = nanosecondsToTicks(nanoseconds)
      let (result, overflow) = ticks.addingReportingOverflow(added)
      return overflow ? UInt64.max : result
    }

    private static func timebase() -> mach_timebase_info_data_t {
      var info = mach_timebase_info_data_t()
      mach_timebase_info(&info)
      return info
    }

    private static func ticksToNanoseconds(_ ticks: UInt64) -> UInt64 {
      let info = timebase()
      let numer = UInt64(info.numer)
      let denom = UInt64(max(info.denom, 1))
      return scaledCeiling(ticks, multiplier: numer, divisor: denom)
    }

    private static func nanosecondsToTicks(_ nanoseconds: UInt64) -> UInt64 {
      let info = timebase()
      let numer = UInt64(max(info.numer, 1))
      let denom = UInt64(info.denom)
      return scaledCeiling(nanoseconds, multiplier: denom, divisor: numer)
    }

    /// Divide the full-width product; only saturate when the final result cannot fit.
    /// Round positive fractions up so a requested interval never expires early.
    static func scaledCeiling(_ value: UInt64, multiplier: UInt64, divisor: UInt64) -> UInt64 {
      precondition(divisor != 0)
      let product = value.multipliedFullWidth(by: multiplier)
      guard product.high < divisor else { return .max }
      let result = divisor.dividingFullWidth(product)
      guard result.remainder != 0 else { return result.quotient }
      let (rounded, overflow) = result.quotient.addingReportingOverflow(1)
      return overflow ? .max : rounded
    }
  }
#endif
