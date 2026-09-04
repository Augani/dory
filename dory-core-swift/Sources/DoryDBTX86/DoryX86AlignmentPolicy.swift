/// Alignment-check admission shared by the interpreter and native-entry guards.
///
/// Intel SDM 092 Vol. 3A Event 17 and Table 7-7 require CR0.AM, RFLAGS.AC,
/// and CPL 3 (including virtual-8086 mode). Ordinary word/dword/qword, stack,
/// string-element, scalar floating-point, MMX, and bit-string accesses use their
/// natural 2/4/8-byte boundary. Byte accesses have no alignment requirement.
/// https://cdrdv2.intel.com/v1/dl/getContent/671190
///
/// Deliberate exclusions remain at their existing instruction-specific sites:
/// - implicit descriptor/TSS/interrupt accesses use supervisor semantics and do
///   not call this policy;
/// - CMPXCHG16B, already-classified aligned SIMD forms, and FXSAVE/FXRSTOR
///   retain their instruction-specific #GP behavior;
/// - 128-bit forms routed through the unaligned vector helper retain Dory's
///   no-#AC implementation choice. Their per-opcode #GP classification remains
///   a separate SIMD inventory concern;
/// - packed BCD has no distinct Table 7-7 data-type boundary and remains
///   unqualified rather than inheriting the extended-real rule by assumption.
/// - split-lock and UC bus-lock #AC require processor controls Dory does not
///   advertise or represent; this policy covers alignment violations only.
enum DoryX86AlignmentPolicy {
  static func isEnabled(state: DoryX86ArchitecturalState) -> Bool {
    let alignmentMask = UInt64(1 << 18)
    guard state.control.cr0 & 1 != 0,
      state.control.cr0 & alignmentMask != 0,
      state.rflags.contains(.alignmentCheck)
    else { return false }
    let virtual8086 = state.control.efer & (1 << 10) == 0
      && state.rflags.contains(.virtual8086)
    return virtual8086 || state.cs.selector & 3 == 3
  }

  static func naturalAlignment(byteCount: Int) -> Int? {
    switch byteCount {
    case 2: 2
    case 4: 4
    case 8: 8
    default: nil
    }
  }

  static func faults(
    address: UInt64,
    alignment: Int?,
    state: DoryX86ArchitecturalState
  ) -> Bool {
    guard isEnabled(state: state), let alignment, alignment > 1 else { return false }
    return address % UInt64(alignment) != 0
  }
}
