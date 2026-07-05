import Darwin
import Foundation
import Hypervisor

#if arch(arm64)
/// Track 1.7 DAX go/no-go: proves that a file-backed host mmap mapped into guest physical memory with
/// hv_vm_map stays coherent in both directions. The host writes a pattern into a MAP_SHARED file, maps
/// it at the DAX guest-physical base, and runs a three-instruction guest that reads the pattern and
/// writes a marker back. Success means guest reads see host writes AND host (plus the on-disk file)
/// sees the guest write, the exact property FUSE_SETUPMAPPING relies on. Requires the
/// com.apple.security.hypervisor entitlement; run as a signed helper, not a plain unit test.
public enum DaxCoherenceProbe {
    private static let hostPattern: UInt32 = 0xDEAD_BEEF
    private static let guestMarker: UInt32 = 0xCAFE_BABE

    public static func run(daxGuestBase: UInt64 = GuestLayout.daxWindowBase) throws -> String {
        let mapBytes = Int(DaxWindow.pageSize)
        let path = NSTemporaryDirectory() + "dory-dax-probe-\(getpid())"
        let fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { throw VMError.invalidConfiguration("dax probe: open failed errno \(errno)") }
        defer { close(fd); unlink(path) }
        guard ftruncate(fd, off_t(mapBytes)) == 0 else {
            throw VMError.invalidConfiguration("dax probe: ftruncate failed errno \(errno)")
        }
        guard let fileRegion = mmap(nil, mapBytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0),
              fileRegion != MAP_FAILED else {
            throw VMError.outOfMemory("dax probe: mmap failed errno \(errno)")
        }
        defer { munmap(fileRegion, mapBytes) }
        fileRegion.storeBytes(of: hostPattern.littleEndian, toByteOffset: 0, as: UInt32.self)

        try hvCreateVM()
        defer { hv_vm_destroy() }

        let ramBase = GuestLayout.ramBase
        let memory = try GuestMemory(guestBase: ramBase, size: UInt64(DaxWindow.pageSize))
        try memory.mapIntoGuest()
        try memory.write(UInt32(0xB940_0020), at: ramBase)       // ldr w0, [x1]
        try memory.write(UInt32(0xB900_0022), at: ramBase + 4)   // str w2, [x1]
        try memory.write(UInt32(0xD400_0002), at: ramBase + 8)   // hvc #0

        try hvCheck(
            hv_vm_map(fileRegion, daxGuestBase, mapBytes,
                      hv_memory_flags_t(HV_MEMORY_READ | HV_MEMORY_WRITE)),
            "hv_vm_map(dax window)"
        )

        let vcpu = try VCPU()
        try vcpu.write(HV_REG_CPSR, 0x3C5)
        try vcpu.write(HV_REG_PC, ramBase)
        try vcpu.write(HV_REG_X1, daxGuestBase)
        try vcpu.write(HV_REG_X2, UInt64(guestMarker))

        let event = try vcpu.run()
        guard case .exception(let syndrome, _, _) = event,
              ExceptionClass(syndrome: syndrome) == .hvc64 else {
            throw VMError.unexpectedExit("dax probe: expected HVC trap, got \(event)")
        }

        let guestRead = UInt32(truncatingIfNeeded: try vcpu.read(HV_REG_X0))
        guard guestRead == hostPattern else {
            throw VMError.unexpectedExit(
                "dax probe FAILED host->guest: guest read 0x\(String(guestRead, radix: 16)), expected 0x\(String(hostPattern, radix: 16))")
        }

        let hostSeesGuestWrite = UInt32(littleEndian: fileRegion.load(fromByteOffset: 0, as: UInt32.self))
        guard hostSeesGuestWrite == guestMarker else {
            throw VMError.unexpectedExit(
                "dax probe FAILED guest->host: host mmap read 0x\(String(hostSeesGuestWrite, radix: 16)), expected 0x\(String(guestMarker, radix: 16))")
        }

        _ = msync(fileRegion, mapBytes, MS_SYNC)
        var onDisk: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &onDisk) { pread(fd, $0.baseAddress, 4, 0) }
        guard UInt32(littleEndian: onDisk) == guestMarker else {
            throw VMError.unexpectedExit(
                "dax probe FAILED persistence: on-disk word 0x\(String(UInt32(littleEndian: onDisk), radix: 16)), expected 0x\(String(guestMarker, radix: 16))")
        }

        return "dax coherence passed at base 0x\(String(daxGuestBase, radix: 16)): host->guest 0x\(String(hostPattern, radix: 16)) read by guest; guest->host 0x\(String(guestMarker, radix: 16)) visible in host mmap and on disk"
    }
}
#else
public enum DaxCoherenceProbe {
    private static let hostPattern: UInt32 = 0xDEAD_BEEF
    private static let guestMarker: UInt32 = 0xCAFE_BABE
    private static let codeAddress: UInt64 = 0x1000
    private static let pml4Address: UInt64 = 0x2000
    private static let pdptAddress: UInt64 = 0x3000
    private static let lowPDAddress: UInt64 = 0x4000
    private static let daxPDAddress: UInt64 = 0x5000
    private static let ramBytes: UInt64 = 2 << 20

    public static func run(daxGuestBase: UInt64 = GuestLayout.daxWindowBase) throws -> String {
        let mapBytes = Int(DaxWindow.pageSize)
        guard daxGuestBase.isMultiple(of: UInt64(2 << 20)) else {
            throw VMError.invalidConfiguration("x86 dax probe base must be 2 MiB aligned")
        }
        guard daxGuestBase >= ramBytes else {
            throw VMError.invalidConfiguration("x86 dax probe base must not overlap probe RAM")
        }

        let path = NSTemporaryDirectory() + "dory-dax-probe-\(getpid())"
        let fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { throw VMError.invalidConfiguration("dax probe: open failed errno \(errno)") }
        defer { close(fd); unlink(path) }
        guard ftruncate(fd, off_t(mapBytes)) == 0 else {
            throw VMError.invalidConfiguration("dax probe: ftruncate failed errno \(errno)")
        }
        guard let fileRegion = mmap(nil, mapBytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0),
              fileRegion != MAP_FAILED else {
            throw VMError.outOfMemory("dax probe: mmap failed errno \(errno)")
        }
        defer { munmap(fileRegion, mapBytes) }
        fileRegion.storeBytes(of: hostPattern.littleEndian, toByteOffset: 0, as: UInt32.self)

        try hvCreateVM()
        defer { hv_vm_destroy() }

        let memory = try GuestMemory(guestBase: 0, size: ramBytes)
        try memory.mapIntoGuest()
        try writeProbeCode(to: memory, daxGuestBase: daxGuestBase)
        try writePageTables(to: memory, daxGuestBase: daxGuestBase)

        try hvCheck(
            hv_vm_map(fileRegion, daxGuestBase, mapBytes, hv_memory_flags_t(HV_MEMORY_READ | HV_MEMORY_WRITE)),
            "hv_vm_map(dax window)"
        )

        let vcpu = try VCPU()
        try configureLongMode(vcpu)

        guard case .vmExit(let state) = try vcpu.run() else {
            throw VMError.unexpectedExit("x86 dax probe returned without a VM exit")
        }
        guard X86VMExitDecoder.decode(state) == .halt else {
            throw VMError.unexpectedExit(
                "x86 dax probe expected HLT exit, got reason \(state.reason) qualification 0x\(String(state.qualification, radix: 16))"
            )
        }

        let guestRead = UInt32(truncatingIfNeeded: try vcpu.read(HV_X86_RAX))
        guard guestRead == hostPattern else {
            throw VMError.unexpectedExit(
                "dax probe FAILED host->guest: guest read 0x\(String(guestRead, radix: 16)), expected 0x\(String(hostPattern, radix: 16))"
            )
        }

        let hostSeesGuestWrite = UInt32(littleEndian: fileRegion.load(fromByteOffset: 0, as: UInt32.self))
        guard hostSeesGuestWrite == guestMarker else {
            throw VMError.unexpectedExit(
                "dax probe FAILED guest->host: host mmap read 0x\(String(hostSeesGuestWrite, radix: 16)), expected 0x\(String(guestMarker, radix: 16))"
            )
        }

        _ = msync(fileRegion, mapBytes, MS_SYNC)
        var onDisk: UInt32 = 0
        _ = withUnsafeMutableBytes(of: &onDisk) { pread(fd, $0.baseAddress, 4, 0) }
        guard UInt32(littleEndian: onDisk) == guestMarker else {
            throw VMError.unexpectedExit(
                "dax probe FAILED persistence: on-disk word 0x\(String(UInt32(littleEndian: onDisk), radix: 16)), expected 0x\(String(guestMarker, radix: 16))"
            )
        }

        return "dax coherence passed at base 0x\(String(daxGuestBase, radix: 16)): host->guest 0x\(String(hostPattern, radix: 16)) read by guest; guest->host 0x\(String(guestMarker, radix: 16)) visible in host mmap and on disk"
    }

    private static func writeProbeCode(to memory: GuestMemory, daxGuestBase: UInt64) throws {
        var code: [UInt8] = [0x48, 0xBB]  // movabs rbx, imm64
        code.append(contentsOf: littleEndianBytes(daxGuestBase))
        code.append(contentsOf: [0x8B, 0x03])  // mov eax, dword ptr [rbx]
        code.append(0xBA)  // mov edx, imm32
        code.append(contentsOf: littleEndianBytes(guestMarker))
        code.append(contentsOf: [0x89, 0x13])  // mov dword ptr [rbx], edx
        code.append(0xF4)  // hlt
        try memory.write(code, at: codeAddress)
    }

    private static func writePageTables(to memory: GuestMemory, daxGuestBase: UInt64) throws {
        let presentWrite: UInt64 = 0x003
        let hugePresentWrite: UInt64 = 0x083
        let pml4Index = pageTableIndex(daxGuestBase, shift: 39)
        let pdptIndex = pageTableIndex(daxGuestBase, shift: 30)
        let pdIndex = pageTableIndex(daxGuestBase, shift: 21)

        if pml4Index != 0 {
            throw VMError.invalidConfiguration("x86 dax probe base must be below 512 GiB")
        }
        try memory.write(pml4Entry(pdptAddress, flags: presentWrite), at: pml4Address)

        try memory.write(pml4Entry(lowPDAddress, flags: presentWrite), at: pdptAddress)
        try memory.write(hugePageEntry(0, flags: hugePresentWrite), at: lowPDAddress)

        if pdptIndex == 0 {
            try memory.write(hugePageEntry(daxGuestBase, flags: hugePresentWrite), at: lowPDAddress + pdIndex * 8)
        } else {
            try memory.write(pml4Entry(daxPDAddress, flags: presentWrite), at: pdptAddress + pdptIndex * 8)
            try memory.write(hugePageEntry(daxGuestBase, flags: hugePresentWrite), at: daxPDAddress + pdIndex * 8)
        }
    }

    private static func configureLongMode(_ vcpu: VCPU) throws {
        try vcpu.write(HV_X86_RIP, codeAddress)
        try vcpu.write(HV_X86_RFLAGS, 0x2)
        try vcpu.write(HV_X86_RAX, 0)
        try vcpu.write(HV_X86_RBX, 0)
        try vcpu.write(HV_X86_RDX, 0)
        try vcpu.write(HV_X86_RSP, 0x8000)
        try vcpu.write(HV_X86_CR3, pml4Address)
        try vcpu.write(HV_X86_CR4, 1 << 5)  // PAE
        try vcpu.writeVMCS(UInt32(VMCS_GUEST_IA32_EFER), 0x500)  // LME | LMA
        try vcpu.write(HV_X86_CR0, (1 << 31) | 0x21)  // PG | PE | NE

        try writeControl(vcpu, field: UInt32(VMCS_CTRL_PIN_BASED), requested: 0)
        try writeControl(
            vcpu,
            field: UInt32(VMCS_CTRL_CPU_BASED),
            requested: UInt32(CPU_BASED_HLT | CPU_BASED_SECONDARY_CTLS)
        )
        try writeControl(
            vcpu,
            field: UInt32(VMCS_CTRL_CPU_BASED2),
            requested: UInt32(CPU_BASED2_EPT | CPU_BASED2_UNRESTRICTED)
        )
        try writeControl(vcpu, field: UInt32(VMCS_CTRL_VMEXIT_CONTROLS), requested: 0)
        try writeControl(vcpu, field: UInt32(VMCS_CTRL_VMENTRY_CONTROLS), requested: UInt32(VMENTRY_LOAD_EFER))

        try writeSegment(
            vcpu,
            selectorField: UInt32(VMCS_GUEST_CS),
            baseField: UInt32(VMCS_GUEST_CS_BASE),
            limitField: UInt32(VMCS_GUEST_CS_LIMIT),
            accessField: UInt32(VMCS_GUEST_CS_AR),
            selector: 0x08,
            accessRights: 0xA09B
        )
        for (selectorField, baseField, limitField, accessField) in [
            (VMCS_GUEST_SS, VMCS_GUEST_SS_BASE, VMCS_GUEST_SS_LIMIT, VMCS_GUEST_SS_AR),
            (VMCS_GUEST_DS, VMCS_GUEST_DS_BASE, VMCS_GUEST_DS_LIMIT, VMCS_GUEST_DS_AR),
            (VMCS_GUEST_ES, VMCS_GUEST_ES_BASE, VMCS_GUEST_ES_LIMIT, VMCS_GUEST_ES_AR),
            (VMCS_GUEST_FS, VMCS_GUEST_FS_BASE, VMCS_GUEST_FS_LIMIT, VMCS_GUEST_FS_AR),
            (VMCS_GUEST_GS, VMCS_GUEST_GS_BASE, VMCS_GUEST_GS_LIMIT, VMCS_GUEST_GS_AR),
        ] {
            try writeSegment(
                vcpu,
                selectorField: UInt32(selectorField),
                baseField: UInt32(baseField),
                limitField: UInt32(limitField),
                accessField: UInt32(accessField),
                selector: 0x10,
                accessRights: 0xC093
            )
        }
        try vcpu.writeVMCS(UInt32(VMCS_GUEST_LDTR), 0)
        try vcpu.writeVMCS(UInt32(VMCS_GUEST_LDTR_BASE), 0)
        try vcpu.writeVMCS(UInt32(VMCS_GUEST_LDTR_LIMIT), 0)
        try vcpu.writeVMCS(UInt32(VMCS_GUEST_LDTR_AR), 0x1_0000)
        try vcpu.writeVMCS(UInt32(VMCS_GUEST_TR), 0x18)
        try vcpu.writeVMCS(UInt32(VMCS_GUEST_TR_BASE), 0)
        try vcpu.writeVMCS(UInt32(VMCS_GUEST_TR_LIMIT), 0x67)
        try vcpu.writeVMCS(UInt32(VMCS_GUEST_TR_AR), 0x8B)
        try vcpu.writeVMCS(UInt32(VMCS_GUEST_GDTR_BASE), 0)
        try vcpu.writeVMCS(UInt32(VMCS_GUEST_GDTR_LIMIT), 0)
        try vcpu.writeVMCS(UInt32(VMCS_GUEST_IDTR_BASE), 0)
        try vcpu.writeVMCS(UInt32(VMCS_GUEST_IDTR_LIMIT), 0x3FF)
        try vcpu.writeVMCS(UInt32(VMCS_GUEST_ACTIVITY_STATE), 0)
        try vcpu.writeVMCS(UInt32(VMCS_GUEST_INTERRUPTIBILITY), 0)
    }

    private static func writeControl(_ vcpu: VCPU, field: UInt32, requested: UInt32) throws {
        var requiredOne: UInt64 = 0
        var allowedOne: UInt64 = 0
        try hvCheck(
            hv_vmx_vcpu_get_cap_write_vmcs(vcpu.handle, field, &requiredOne, &allowedOne),
            "hv_vmx_vcpu_get_cap_write_vmcs"
        )
        try vcpu.writeVMCS(field, (UInt64(requested) | requiredOne) & allowedOne)
    }

    private static func writeSegment(
        _ vcpu: VCPU,
        selectorField: UInt32,
        baseField: UInt32,
        limitField: UInt32,
        accessField: UInt32,
        selector: UInt16,
        accessRights: UInt64
    ) throws {
        try vcpu.writeVMCS(selectorField, UInt64(selector))
        try vcpu.writeVMCS(baseField, 0)
        try vcpu.writeVMCS(limitField, 0xFFFF_FFFF)
        try vcpu.writeVMCS(accessField, accessRights)
    }

    private static func pml4Entry(_ address: UInt64, flags: UInt64) -> UInt64 {
        (address & 0x000F_FFFF_FFFF_F000) | flags
    }

    private static func hugePageEntry(_ address: UInt64, flags: UInt64) -> UInt64 {
        (address & 0x000F_FFFF_FFE0_0000) | flags
    }

    private static func pageTableIndex(_ address: UInt64, shift: UInt64) -> UInt64 {
        (address >> shift) & 0x1FF
    }

    private static func littleEndianBytes(_ value: UInt64) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }

    private static func littleEndianBytes(_ value: UInt32) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }
}
#endif
