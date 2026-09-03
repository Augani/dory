import Foundation
import Testing
@testable import DoryMachinePC
import DoryDBTX86

@Suite struct DoryPCLinuxBootTests {
    @Test func realLinuxKernelLoadsAndBoots() throws {
        let kernelPath = "/tmp/vmlinux-x86_64"
        guard FileManager.default.fileExists(atPath: kernelPath) else {
            Issue.record("vmlinux not available at \(kernelPath)")
            return
        }

        let kernelData = try Data(contentsOf: URL(fileURLWithPath: kernelPath))
        print("Kernel size: \(kernelData.count) bytes")

        let machine = try DoryPCDirectKernelMachine(
            memoryBytes: 1 * 1024 * 1024 * 1024,
            executionTier: .baselineJIT
        )

        try machine.load(kernel: kernelData, commandLine: "console=ttyS0 earlyprintk=serial,ttyS0,115200 panic=-1")
        print("Entry point: 0x\(String(machine.state?.rip ?? 0, radix: 16))")

        // Run with exception delivery so page faults are handled by the guest.
        let stop = try machine.run(maximumInstructions: 120_000_000, exceptionPolicy: .deliver)
        print("Stop: \(stop)")

        // Dump state for debugging
        if let state = machine.state {
            print("RIP: 0x\(String(state.rip, radix: 16))")
            print("CR0: 0x\(String(state.control.cr0, radix: 16))")
            print("CR3: 0x\(String(state.control.cr3, radix: 16))")
            print("CR4: 0x\(String(state.control.cr4, radix: 16))")
            print("EFER: 0x\(String(state.control.efer, radix: 16))")
            print("CS selector: 0x\(String(state.cs.selector, radix: 16))")
            print("RSP: 0x\(String(state.registers.rsp, radix: 16))")
            print("RBP: 0x\(String(state.registers.rbp, radix: 16))")
            print("RAX: 0x\(String(state.registers.rax, radix: 16))")
            print("RBX: 0x\(String(state.registers.rbx, radix: 16))")
            print("RCX: 0x\(String(state.registers.rcx, radix: 16))")
            print("RDX: 0x\(String(state.registers.rdx, radix: 16))")
            print("RSI: 0x\(String(state.registers.rsi, radix: 16))")
            print("RDI: 0x\(String(state.registers.rdi, radix: 16))")
            print("R8:  0x\(String(state.registers.r8, radix: 16))")
            print("R9:  0x\(String(state.registers.r9, radix: 16))")

            // Walk the page table for the faulting RIP
            let cr3 = state.control.cr3 & ~0xfff
            let pml4Index = (state.rip >> 39) & 0x1ff
            let pml4Addr = cr3 + pml4Index * 8
            let pml4Bytes = try machine.memory.read(at: pml4Addr, byteCount: 8)
            let pml4Entry = pml4Bytes.withUnsafeBytes { $0.load(as: UInt64.self) }
            print("PML4[\(pml4Index)] @ 0x\(String(pml4Addr, radix: 16)): 0x\(String(pml4Entry, radix: 16))")

            if pml4Entry & 1 != 0 {
                let pdptAddr = (pml4Entry & 0x000f_ffff_ffff_f000) + ((state.rip >> 30) & 0x1ff) * 8
                let pdptBytes = try machine.memory.read(at: pdptAddr, byteCount: 8)
                let pdptEntry = pdptBytes.withUnsafeBytes { $0.load(as: UInt64.self) }
                print("PDPT[\((state.rip >> 30) & 0x1ff)] @ 0x\(String(pdptAddr, radix: 16)): 0x\(String(pdptEntry, radix: 16))")

                if pdptEntry & 1 != 0 && pdptEntry & (1 << 7) == 0 {
                    let pdAddr = (pdptEntry & 0x000f_ffff_ffff_f000) + ((state.rip >> 21) & 0x1ff) * 8
                    let pdBytes = try machine.memory.read(at: pdAddr, byteCount: 8)
                    let pdEntry = pdBytes.withUnsafeBytes { $0.load(as: UInt64.self) }
                    print("PD[\((state.rip >> 21) & 0x1ff)] @ 0x\(String(pdAddr, radix: 16)): 0x\(String(pdEntry, radix: 16))")
                }
            }
        }

        let serial = machine.serial.drainTransmittedBytes()
        if !serial.isEmpty {
            let str = String(bytes: serial, encoding: .ascii) ?? ""
            print("Serial output (\(serial.count) bytes):")
            print(str.prefix(4000))
        }

        // Debug: check boot_pageset in physical memory
        // boot_pageset static VA = 0xffffffff844de080
        // Kernel loaded at physical 0x4000000, virtual base 0xffffffff81000000
        // Physical = 0x4000000 + (VA - 0xffffffff81000000)
        let bootPagesetVA: UInt64 = 0xffffffff844de080
        let kernelPhysBase: UInt64 = 0x4000000
        let kernelVirtBase: UInt64 = 0xffffffff81000000
        let bootPagesetPhys = kernelPhysBase + (bootPagesetVA - kernelVirtBase)
        print("\nboot_pageset VA: 0x\(String(bootPagesetVA, radix: 16))")
        print("boot_pageset expected physical (linear): 0x\(String(bootPagesetPhys, radix: 16))")

        // Walk page table for boot_pageset VA
        if let state = machine.state {
            let cr3 = state.control.cr3 & ~0xfff
            let pml4Index = (bootPagesetVA >> 39) & 0x1ff
            let pdptIndex = (bootPagesetVA >> 30) & 0x1ff
            let pdIndex = (bootPagesetVA >> 21) & 0x1ff
            let pml4Addr = cr3 + pml4Index * 8
            if let pml4Bytes = try? machine.memory.read(at: pml4Addr, byteCount: 8) {
                let pml4Entry = pml4Bytes.withUnsafeBytes { $0.load(as: UInt64.self) }
                print("PML4[\(pml4Index)] for boot_pageset: 0x\(String(pml4Entry, radix: 16))")
                if pml4Entry & 1 != 0 {
                    let pdptAddr = (pml4Entry & 0x000f_ffff_ffff_f000) + pdptIndex * 8
                    if let pdptBytes = try? machine.memory.read(at: pdptAddr, byteCount: 8) {
                        let pdptEntry = pdptBytes.withUnsafeBytes { $0.load(as: UInt64.self) }
                        print("PDPT[\(pdptIndex)] for boot_pageset: 0x\(String(pdptEntry, radix: 16))")
                        if pdptEntry & 1 != 0 && pdptEntry & (1 << 7) == 0 {
                            let pdAddr = (pdptEntry & 0x000f_ffff_ffff_f000) + pdIndex * 8
                            if let pdBytes = try? machine.memory.read(at: pdAddr, byteCount: 8) {
                                let pdEntry = pdBytes.withUnsafeBytes { $0.load(as: UInt64.self) }
                                print("PD[\(pdIndex)] for boot_pageset: 0x\(String(pdEntry, radix: 16))")
                                if pdEntry & 1 != 0 {
                                    if pdEntry & (1 << 7) != 0 {
                                        // 2MB page
                                        let pageBase = pdEntry & 0x000f_ffff_ffe0_0000
                                        let physAddr = pageBase + (bootPagesetVA & 0x1fffff)
                                        print("2MB page base: 0x\(String(pageBase, radix: 16))")
                                        print("boot_pageset actual physical: 0x\(String(physAddr, radix: 16))")
                                        if let data = try? machine.memory.read(at: physAddr, byteCount: 64) {
                                            print("boot_pageset contents (first 64 bytes):")
                                            for i in stride(from: 0, to: 64, by: 8) {
                                                let val = data[i..<i+8].withUnsafeBytes { $0.load(as: UInt64.self) }
                                                print("  +0x\(String(i, radix: 16)): 0x\(String(val, radix: 16))")
                                            }
                                        }
                                    } else {
                                        // 4KB page - walk PT
                                        let ptIndex = (bootPagesetVA >> 12) & 0x1ff
                                        let ptAddr = (pdEntry & 0x000f_ffff_ffff_f000) + ptIndex * 8
                                        if let ptBytes = try? machine.memory.read(at: ptAddr, byteCount: 8) {
                                            let ptEntry = ptBytes.withUnsafeBytes { $0.load(as: UInt64.self) }
                                            print("PT[\(ptIndex)] for boot_pageset: 0x\(String(ptEntry, radix: 16))")
                                            if ptEntry & 1 != 0 {
                                                let pageBase = ptEntry & 0x000f_ffff_ffff_f000
                                                let physAddr = pageBase + (bootPagesetVA & 0xfff)
                                                print("boot_pageset actual physical: 0x\(String(physAddr, radix: 16))")
                                                if let data = try? machine.memory.read(at: physAddr, byteCount: 64) {
                                                    print("boot_pageset contents (first 64 bytes):")
                                                    for i in stride(from: 0, to: 64, by: 8) {
                                                        let val = data[i..<i+8].withUnsafeBytes { $0.load(as: UInt64.self) }
                                                        print("  +0x\(String(i, radix: 16)): 0x\(String(val, radix: 16))")
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        } else if pdptEntry & 1 != 0 && pdptEntry & (1 << 7) != 0 {
                            // 1GB page
                            let pageBase = pdptEntry & 0x000f_ffff_c000_0000
                            let physAddr = pageBase + (bootPagesetVA & 0x3fffffff)
                            print("1GB page base: 0x\(String(pageBase, radix: 16))")
                            print("boot_pageset actual physical: 0x\(String(physAddr, radix: 16))")
                            if let data = try? machine.memory.read(at: physAddr, byteCount: 64) {
                                print("boot_pageset contents (first 64 bytes):")
                                for i in stride(from: 0, to: 64, by: 8) {
                                    let val = data[i..<i+8].withUnsafeBytes { $0.load(as: UInt64.self) }
                                    print("  +0x\(String(i, radix: 16)): 0x\(String(val, radix: 16))")
                                }
                            }
                        }
                    }
                }
            }
        }

        // Also check the linear-mapped physical address
        if let data = try? machine.memory.read(at: bootPagesetPhys, byteCount: 64) {
            print("\nboot_pageset at linear-mapped physical 0x\(String(bootPagesetPhys, radix: 16)):")
            for i in stride(from: 0, to: 64, by: 8) {
                let val = data[i..<i+8].withUnsafeBytes { $0.load(as: UInt64.self) }
                print("  +0x\(String(i, radix: 16)): 0x\(String(val, radix: 16))")
            }
        }

        // Print function trace log
        let traceLog = machine.functionTraceLog
        print("\nFunction trace log (\(traceLog.count) entries):")
        let funcNames: [UInt64: String] = [
            0xffffffff816f9750: "per_cpu_pages_init",
            0xffffffff84072c10: "build_all_zonelists_init",
            0xffffffff8256b000: "build_all_zonelists",
            0xffffffff81706120: "__build_all_zonelists",
            0xffffffff8406fde0: "mm_core_init",
            0xffffffff8404d920: "mem_init",
            0xffffffff84072c90: "setup_per_cpu_pageset",
        ]
        for entry in traceLog {
            let name = funcNames[entry.rip] ?? "0x\(String(entry.rip, radix: 16))"
            print("  \(name): RDI=0x\(String(entry.rdi, radix: 16)) RSI=0x\(String(entry.rsi, radix: 16)) RAX=0x\(String(entry.rax, radix: 16)) RBX=0x\(String(entry.rbx, radix: 16))")
        }

        // Check __per_cpu_offset and __cpu_possible_mask
        // __per_cpu_offset at VA 0xffffffff82fbc0e0 -> phys 0x2fbc0e0
        let percpuOffsetPhys: UInt64 = 0x2fbc0e0
        if let data = try? machine.memory.read(at: percpuOffsetPhys, byteCount: 32) {
            print("\n__per_cpu_offset (phys 0x\(String(percpuOffsetPhys, radix: 16))):")
            for i in 0..<4 {
                let val = data[i*8..<i*8+8].withUnsafeBytes { $0.load(as: UInt64.self) }
                print("  [\(i)]: 0x\(String(val, radix: 16))")
            }
        }

        // __cpu_possible_mask at VA 0xffffffff82fcd5e0 -> phys 0x2fcd5e0
        let cpuPossiblePhys: UInt64 = 0x2fcd5e0
        if let data = try? machine.memory.read(at: cpuPossiblePhys, byteCount: 16) {
            print("\n__cpu_possible_mask (phys 0x\(String(cpuPossiblePhys, radix: 16))):")
            for i in 0..<2 {
                let val = data[i*8..<i*8+8].withUnsafeBytes { $0.load(as: UInt64.self) }
                print("  [\(i)]: 0x\(String(val, radix: 16))")
            }
        }

        // Check nr_cpu_ids at VA 0xffffffff83ae83a0 -> phys 0x3ae83a0
        let nrCpuIdsPhys: UInt64 = 0x3ae83a0
        if let data = try? machine.memory.read(at: nrCpuIdsPhys, byteCount: 4) {
            let val = data[0..<4].withUnsafeBytes { $0.load(as: UInt32.self) }
            print("\nnr_cpu_ids (phys 0x\(String(nrCpuIdsPhys, radix: 16))): \(val)")
        }

        // Check GS base (MSR 0xC0000101)
        if let state = machine.state {
            print("\nGS base: 0x\(String(state.gs.base, radix: 16))")
            print("KernelGSBase: 0x\(String(state.modelSpecific.kernelGSBase, radix: 16))")
            print("FS base: 0x\(String(state.fs.base, radix: 16))")
        }

        // Check phys_base at VA 0xffffffff8382a010 -> phys 0x382a010
        let physBasePhys: UInt64 = 0x382a010
        if let data = try? machine.memory.read(at: physBasePhys, byteCount: 8) {
            let val = data[0..<8].withUnsafeBytes { $0.load(as: UInt64.self) }
            print("\nphys_base (phys 0x\(String(physBasePhys, radix: 16))): 0x\(String(val, radix: 16))")
        }

        // Check pvh_start_info at VA 0xffffffff840dd780 -> phys 0x40dd780
        let pvhStartInfoPhys: UInt64 = 0x40dd780
        if let data = try? machine.memory.read(at: pvhStartInfoPhys, byteCount: 64) {
            print("\npvh_start_info (phys 0x\(String(pvhStartInfoPhys, radix: 16))):")
            for i in stride(from: 0, to: 64, by: 8) {
                let val = data[i..<i+8].withUnsafeBytes { $0.load(as: UInt64.self) }
                print("  +0x\(String(i, radix: 16)): 0x\(String(val, radix: 16))")
            }
            // Check magic at offset 0 and offset 2
            let magic0 = data[0..<4].withUnsafeBytes { $0.load(as: UInt32.self) }
            let magic2 = data[2..<6].withUnsafeBytes { $0.load(as: UInt32.self) }
            print("  magic@0: 0x\(String(magic0, radix: 16)) (expected 0x336ec578)")
            print("  magic@2: 0x\(String(magic2, radix: 16))")
        }

        // Check what's at the PVH start_info we provided (phys 0x90000)
        let ourStartInfoPhys: UInt64 = 0x90000
        if let data = try? machine.memory.read(at: ourStartInfoPhys, byteCount: 64) {
            print("\nour start_info (phys 0x\(String(ourStartInfoPhys, radix: 16))):")
            for i in stride(from: 0, to: 64, by: 8) {
                let val = data[i..<i+8].withUnsafeBytes { $0.load(as: UInt64.self) }
                print("  +0x\(String(i, radix: 16)): 0x\(String(val, radix: 16))")
            }
        }

        // Check what's at the per-CPU offset address
        // __per_cpu_offset[0] = 0xffff8880ba550000 (from previous run)
        // This is a dynamic address - check if it's mapped
        if let data = try? machine.memory.read(at: percpuOffsetPhys, byteCount: 8) {
            let offset = data[0..<8].withUnsafeBytes { $0.load(as: UInt64.self) }
            print("per_cpu_offset[0]: 0x\(String(offset, radix: 16))")
            // boot_pageset + per_cpu_offset[0] = where per-CPU pageset lives
            let bootPagesetVA: UInt64 = 0xffffffff844de080
            let perCpuPagesetVA = bootPagesetVA &+ offset
            print("per-CPU pageset VA: 0x\(String(perCpuPagesetVA, radix: 16))")
        }
    }
}
