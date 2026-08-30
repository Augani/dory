#if arch(arm64)
  import DoryExecutionContracts
  import Hypervisor

  @available(macOS 15.0, *)
  enum DoryARM64HypervisorRegisterBank {
    static func apply(_ state: DoryARM64ArchitecturalState, to handle: hv_vcpu_t) throws {
      for (index, value) in state.generalRegisters.enumerated() {
        try writeGeneral(handle, register: generalRegister(index), value: value)
      }
      try writeGeneral(handle, register: HV_REG_PC, value: state.programCounter)
      try writeGeneral(handle, register: HV_REG_FPCR, value: state.floatingPointControl)
      try writeGeneral(handle, register: HV_REG_FPSR, value: state.floatingPointStatus)
      try writeGeneral(handle, register: HV_REG_CPSR, value: state.currentProgramStatus)
      for (index, value) in state.simdRegisters.enumerated() {
        var vector = hv_simd_fp_uchar16_t()
        withUnsafeMutableBytes(of: &vector) { bytes in
          var low = value.low.littleEndian
          var high = value.high.littleEndian
          withUnsafeBytes(of: &low) { bytes[0..<8].copyBytes(from: $0) }
          withUnsafeBytes(of: &high) { bytes[8..<16].copyBytes(from: $0) }
        }
        try doryNativeHVCheck(
          hv_vcpu_set_simd_fp_reg(handle, simdRegister(index), vector),
          "hv_vcpu_set_simd_fp_reg"
        )
      }
      for item in state.systemRegisters {
        try doryNativeHVCheck(
          hv_vcpu_set_sys_reg(handle, hypervisorRegister(item.register), item.value),
          "hv_vcpu_set_sys_reg(\(item.register.rawValue))"
        )
      }
      try doryNativeHVCheck(
        hv_vcpu_set_pending_interrupt(handle, HV_INTERRUPT_TYPE_IRQ, state.irqPending),
        "hv_vcpu_set_pending_interrupt(IRQ)"
      )
      try doryNativeHVCheck(
        hv_vcpu_set_pending_interrupt(handle, HV_INTERRUPT_TYPE_FIQ, state.fiqPending),
        "hv_vcpu_set_pending_interrupt(FIQ)"
      )
      try doryNativeHVCheck(
        hv_vcpu_set_vtimer_mask(handle, state.virtualTimerMasked),
        "hv_vcpu_set_vtimer_mask"
      )
    }

    static func capture(from handle: hv_vcpu_t) throws -> DoryARM64ArchitecturalState {
      let general = try (0..<DoryARM64ArchitecturalState.generalRegisterCount).map {
        try readGeneral(handle, register: generalRegister($0))
      }
      let simd = try (0..<DoryARM64ArchitecturalState.simdRegisterCount).map { index in
        var vector = hv_simd_fp_uchar16_t()
        try doryNativeHVCheck(
          hv_vcpu_get_simd_fp_reg(handle, simdRegister(index), &vector),
          "hv_vcpu_get_simd_fp_reg"
        )
        return withUnsafeBytes(of: vector) { bytes in
          DoryARM64SIMDRegister(
            low: UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: 0, as: UInt64.self)),
            high: UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: 8, as: UInt64.self))
          )
        }
      }
      let system = try DoryARM64ArchitecturalState.requiredSystemRegisters.map { register in
        var value: UInt64 = 0
        try doryNativeHVCheck(
          hv_vcpu_get_sys_reg(handle, hypervisorRegister(register), &value),
          "hv_vcpu_get_sys_reg(\(register.rawValue))"
        )
        return DoryARM64SystemRegisterValue(register: register, value: value)
      }
      var irq = false
      var fiq = false
      var timerMasked = false
      try doryNativeHVCheck(
        hv_vcpu_get_pending_interrupt(handle, HV_INTERRUPT_TYPE_IRQ, &irq),
        "hv_vcpu_get_pending_interrupt(IRQ)"
      )
      try doryNativeHVCheck(
        hv_vcpu_get_pending_interrupt(handle, HV_INTERRUPT_TYPE_FIQ, &fiq),
        "hv_vcpu_get_pending_interrupt(FIQ)"
      )
      try doryNativeHVCheck(
        hv_vcpu_get_vtimer_mask(handle, &timerMasked),
        "hv_vcpu_get_vtimer_mask"
      )
      return try DoryARM64ArchitecturalState(
        generalRegisters: general,
        programCounter: readGeneral(handle, register: HV_REG_PC),
        floatingPointControl: readGeneral(handle, register: HV_REG_FPCR),
        floatingPointStatus: readGeneral(handle, register: HV_REG_FPSR),
        currentProgramStatus: readGeneral(handle, register: HV_REG_CPSR),
        simdRegisters: simd,
        systemRegisters: system,
        irqPending: irq,
        fiqPending: fiq,
        virtualTimerMasked: timerMasked
      )
    }

    static func readGeneral(_ handle: hv_vcpu_t, index: Int) throws -> UInt64 {
      try readGeneral(handle, register: generalRegister(index))
    }

    static func writeGeneral(_ handle: hv_vcpu_t, index: Int, value: UInt64) throws {
      try writeGeneral(handle, register: generalRegister(index), value: value)
    }

    static func readProgramCounter(_ handle: hv_vcpu_t) throws -> UInt64 {
      try readGeneral(handle, register: HV_REG_PC)
    }

    static func advanceProgramCounter(_ handle: hv_vcpu_t) throws {
      let pc = try readGeneral(handle, register: HV_REG_PC)
      try writeGeneral(handle, register: HV_REG_PC, value: pc &+ 4)
    }

    private static func readGeneral(_ handle: hv_vcpu_t, register: hv_reg_t) throws -> UInt64 {
      var value: UInt64 = 0
      try doryNativeHVCheck(hv_vcpu_get_reg(handle, register, &value), "hv_vcpu_get_reg")
      return value
    }

    private static func writeGeneral(
      _ handle: hv_vcpu_t,
      register: hv_reg_t,
      value: UInt64
    ) throws {
      try doryNativeHVCheck(hv_vcpu_set_reg(handle, register, value), "hv_vcpu_set_reg")
    }

    private static func generalRegister(_ index: Int) -> hv_reg_t {
      hv_reg_t(HV_REG_X0.rawValue + UInt32(index))
    }

    private static func simdRegister(_ index: Int) -> hv_simd_fp_reg_t {
      hv_simd_fp_reg_t(HV_SIMD_FP_REG_Q0.rawValue + UInt32(index))
    }

    private static func hypervisorRegister(_ register: DoryARM64SystemRegister) -> hv_sys_reg_t {
      switch register {
      case .actlrEL1: HV_SYS_REG_ACTLR_EL1
      case .afsr0EL1: HV_SYS_REG_AFSR0_EL1
      case .afsr1EL1: HV_SYS_REG_AFSR1_EL1
      case .amairEL1: HV_SYS_REG_AMAIR_EL1
      case .apiAKeyHighEL1: HV_SYS_REG_APIAKEYHI_EL1
      case .apiAKeyLowEL1: HV_SYS_REG_APIAKEYLO_EL1
      case .apiBKeyHighEL1: HV_SYS_REG_APIBKEYHI_EL1
      case .apiBKeyLowEL1: HV_SYS_REG_APIBKEYLO_EL1
      case .apdAKeyHighEL1: HV_SYS_REG_APDAKEYHI_EL1
      case .apdAKeyLowEL1: HV_SYS_REG_APDAKEYLO_EL1
      case .apdBKeyHighEL1: HV_SYS_REG_APDBKEYHI_EL1
      case .apdBKeyLowEL1: HV_SYS_REG_APDBKEYLO_EL1
      case .apgAKeyHighEL1: HV_SYS_REG_APGAKEYHI_EL1
      case .apgAKeyLowEL1: HV_SYS_REG_APGAKEYLO_EL1
      case .contextIDREL1: HV_SYS_REG_CONTEXTIDR_EL1
      case .cpacrEL1: HV_SYS_REG_CPACR_EL1
      case .csselrEL1: HV_SYS_REG_CSSELR_EL1
      case .cntkctlEL1: HV_SYS_REG_CNTKCTL_EL1
      case .cntvControlEL0: HV_SYS_REG_CNTV_CTL_EL0
      case .cntvCompareEL0: HV_SYS_REG_CNTV_CVAL_EL0
      case .elrEL1: HV_SYS_REG_ELR_EL1
      case .esrEL1: HV_SYS_REG_ESR_EL1
      case .farEL1: HV_SYS_REG_FAR_EL1
      case .mairEL1: HV_SYS_REG_MAIR_EL1
      case .mpidrEL1: HV_SYS_REG_MPIDR_EL1
      case .parEL1: HV_SYS_REG_PAR_EL1
      case .sctlrEL1: HV_SYS_REG_SCTLR_EL1
      case .spEL0: HV_SYS_REG_SP_EL0
      case .spEL1: HV_SYS_REG_SP_EL1
      case .spsrEL1: HV_SYS_REG_SPSR_EL1
      case .tcrEL1: HV_SYS_REG_TCR_EL1
      case .tpidrEL0: HV_SYS_REG_TPIDR_EL0
      case .tpidrEL1: HV_SYS_REG_TPIDR_EL1
      case .tpidrroEL0: HV_SYS_REG_TPIDRRO_EL0
      case .ttbr0EL1: HV_SYS_REG_TTBR0_EL1
      case .ttbr1EL1: HV_SYS_REG_TTBR1_EL1
      case .vbarEL1: HV_SYS_REG_VBAR_EL1
      }
    }
  }
#endif
