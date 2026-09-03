import Foundation
import DoryMachinePC
import DoryDBTX86

let kernelPath = "/tmp/vmlinux-x86_64"
guard FileManager.default.fileExists(atPath: kernelPath) else {
    print("vmlinux not available at \(kernelPath)")
    exit(1)
}

let kernelData = try Data(contentsOf: URL(fileURLWithPath: kernelPath))
print("Kernel size: \(kernelData.count) bytes")

let machine = try DoryPCDirectKernelMachine(
    memoryBytes: 16 * 1024 * 1024 * 1024,
    executionTier: .baselineJIT
)

try machine.load(kernel: kernelData, commandLine: "console=ttyS0 earlyprintk=serial,ttyS0,115200 panic=-1 mem=1G")
print("Entry point: 0x\(String(machine.state?.rip ?? 0, radix: 16))")

let stop = try machine.run(maximumInstructions: 500_000_000, exceptionPolicy: .deliver)
print("Stop: \(stop)")

if let state = machine.state {
    print("RIP: 0x\(String(state.rip, radix: 16))")
    print("CR0: 0x\(String(state.control.cr0, radix: 16))")
    print("CR3: 0x\(String(state.control.cr3, radix: 16))")
    print("CR4: 0x\(String(state.control.cr4, radix: 16))")
    print("EFER: 0x\(String(state.control.efer, radix: 16))")
    print("CS selector: 0x\(String(state.cs.selector, radix: 16))")
    print("RSP: 0x\(String(state.registers.rsp, radix: 16))")
    print("RAX: 0x\(String(state.registers.rax, radix: 16))")
    print("RBX: 0x\(String(state.registers.rbx, radix: 16))")
    print("RCX: 0x\(String(state.registers.rcx, radix: 16))")
    print("RDX: 0x\(String(state.registers.rdx, radix: 16))")
    print("RSI: 0x\(String(state.registers.rsi, radix: 16))")
    print("RDI: 0x\(String(state.registers.rdi, radix: 16))")
    print("GS base: 0x\(String(state.gs.base, radix: 16))")
}

let serial = machine.serial.drainTransmittedBytes()
if !serial.isEmpty {
    let str = String(bytes: serial, encoding: .ascii) ?? ""
    print("\nSerial output (\(serial.count) bytes):")
    print(str.prefix(4000))
}

// Check pvh_start_info at phys 0x40dd780
let pvhStartInfoPhys: UInt64 = 0x40dd780
if let data = try? machine.memory.read(at: pvhStartInfoPhys, byteCount: 64) {
    print("\npvh_start_info (phys 0x\(String(pvhStartInfoPhys, radix: 16))):")
    for i in stride(from: 0, to: 64, by: 8) {
        let val = data[i..<i+8].withUnsafeBytes { $0.load(as: UInt64.self) }
        print("  +0x\(String(i, radix: 16)): 0x\(String(val, radix: 16))")
    }
    let magic0 = data[0..<4].withUnsafeBytes { $0.load(as: UInt32.self) }
    print("  magic@0: 0x\(String(magic0, radix: 16)) (expected 0x336ec578)")
}

// Check our start_info at phys 0x90000
let ourStartInfoPhys: UInt64 = 0x90000
if let data = try? machine.memory.read(at: ourStartInfoPhys, byteCount: 64) {
    print("\nour start_info (phys 0x\(String(ourStartInfoPhys, radix: 16))):")
    for i in stride(from: 0, to: 64, by: 8) {
        let val = data[i..<i+8].withUnsafeBytes { $0.load(as: UInt64.self) }
        print("  +0x\(String(i, radix: 16)): 0x\(String(val, radix: 16))")
    }
}

// Check the e820 memory map entries at phys 0x93000
// Each entry is 24 bytes: addr(8) + size(8) + type(4) + pad(4)
let memmapPhys: UInt64 = 0x93000
if let data = try? machine.memory.read(at: memmapPhys, byteCount: 120) {
    print("\ne820 memory map entries (phys 0x\(String(memmapPhys, radix: 16))):")
    for i in 0..<5 {
        let off = i * 24
        let addr = data[off..<off+8].withUnsafeBytes { $0.load(as: UInt64.self) }
        let size = data[off+8..<off+16].withUnsafeBytes { $0.load(as: UInt64.self) }
        let type = data[off+16..<off+20].withUnsafeBytes { $0.load(as: UInt32.self) }
        let typeName = type == 1 ? "RAM" : type == 2 ? "reserved" : type == 3 ? "ACPI" : "type=\(type)"
        print("  [\(i)]: addr=0x\(String(addr, radix: 16)) size=0x\(String(size, radix: 16)) \(typeName)")
    }
}

// Check the kernel's e820_table at known addresses
// e820_table is typically in .init.data. Let's check the symbol.
// e820_table_firmware is at a known address. Let's look for e820 entries.
// The kernel's e820_table has nr_entries at offset 0, then entries at offset 8 (or similar)
// Let's check a few likely locations
let e820TablePhys: UInt64 = 0x3ae83a0  // nr_cpu_ids area - might be nearby
// Actually, let's check pvh_bootparams which might have the e820 info
let pvhBootparamsPhys: UInt64 = 0x40dd7c0
if let data = try? machine.memory.read(at: pvhBootparamsPhys, byteCount: 256) {
    print("\npvh_bootparams (phys 0x\(String(pvhBootparamsPhys, radix: 16))):")
    for i in stride(from: 0, to: 256, by: 8) {
        let val = data[i..<i+8].withUnsafeBytes { $0.load(as: UInt64.self) }
        if val != 0 {
            print("  +0x\(String(i, radix: 16)): 0x\(String(val, radix: 16))")
        }
    }
}

// Check __per_cpu_offset
let percpuOffsetPhys: UInt64 = 0x2fbc0e0
if let data = try? machine.memory.read(at: percpuOffsetPhys, byteCount: 32) {
    print("\n__per_cpu_offset (phys 0x\(String(percpuOffsetPhys, radix: 16))):")
    for i in 0..<4 {
        let val = data[i*8..<i*8+8].withUnsafeBytes { $0.load(as: UInt64.self) }
        print("  [\(i)]: 0x\(String(val, radix: 16))")
    }
}

// Check max_pfn - this tells the kernel how many pages are available
// max_pfn is typically set from the e820 memory map
// Let's check phys_base area and other boot parameters
let physBasePhys: UInt64 = 0x382a010
if let data = try? machine.memory.read(at: physBasePhys, byteCount: 8) {
    let val = data[0..<8].withUnsafeBytes { $0.load(as: UInt64.self) }
    print("\nphys_base: 0x\(String(val, radix: 16))")
}

// Check xen_start_info pointer (at 0xffffffff84501600 → phys 0x4501600)
let xenStartInfoPtrPhys: UInt64 = 0x4501600
if let data = try? machine.memory.read(at: xenStartInfoPtrPhys, byteCount: 8) {
    let ptr = data[0..<8].withUnsafeBytes { $0.load(as: UInt64.self) }
    print("\nxen_start_info ptr: 0x\(String(ptr, radix: 16))")
    // Read [xen_start_info + 0x20] - this is used as memory limit
    if ptr != 0 {
        let physAddr = ptr & 0x3fffffff  // convert direct map virt to phys
        if let data2 = try? machine.memory.read(at: physAddr + 0x20, byteCount: 8) {
            let val = data2[0..<8].withUnsafeBytes { $0.load(as: UInt64.self) }
            print("xen_start_info+0x20: 0x\(String(val, radix: 16)) (used as memory limit)")
        }
        // Also read the full start_info struct
        if let data3 = try? machine.memory.read(at: physAddr, byteCount: 64) {
            print("start_info struct at 0x\(String(physAddr, radix: 16)):")
            for i in stride(from: 0, to: 64, by: 8) {
                let val = data3[i..<i+8].withUnsafeBytes { $0.load(as: UInt64.self) }
                print("  +0x\(String(i, radix: 16)): 0x\(String(val, radix: 16))")
            }
        }
    }
}

// Check ini_nr_pages (at 0xffffffff840cb000 → phys 0x40cb000)
let iniNrPagesPhys: UInt64 = 0x40cb000
if let data = try? machine.memory.read(at: iniNrPagesPhys, byteCount: 8) {
    let val = data[0..<8].withUnsafeBytes { $0.load(as: UInt64.self) }
    print("\nini_nr_pages: 0x\(String(val, radix: 16)) (\(val / 1024 / 1024 / 1024) GB)")
}

// Check max_pfn at 0xffffffff8459a548 → phys = 0x459a548
let maxPfnPhys: UInt64 = 0x459a548
if let data = try? machine.memory.read(at: maxPfnPhys, byteCount: 8) {
    let val = data[0..<8].withUnsafeBytes { $0.load(as: UInt64.self) }
    print("max_pfn: 0x\(String(val, radix: 16)) (\(val * 4096 / 1024 / 1024) MB)")
}

// Check max_pfn_mapped at 0xffffffff84507900 → phys = 0x4507900
let maxPfnMappedPhys: UInt64 = 0x4507900
if let data = try? machine.memory.read(at: maxPfnMappedPhys, byteCount: 8) {
    let val = data[0..<8].withUnsafeBytes { $0.load(as: UInt64.self) }
    print("max_pfn_mapped: 0x\(String(val, radix: 16)) (\(val * 4096 / 1024 / 1024) MB)")
}

// Check page_offset_base at 0xffffffff82fab6a8 → phys = 0x2fab6a8
let pageOffsetBasePhys: UInt64 = 0x2fab6a8
if let data = try? machine.memory.read(at: pageOffsetBasePhys, byteCount: 8) {
    let val = data[0..<8].withUnsafeBytes { $0.load(as: UInt64.self) }
    print("page_offset_base: 0x\(String(val, radix: 16))")
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
    0xffffffff8402ff20: "xen_prepare_pvh",
    0xffffffff8402f300: "xen_pvh_init",
    0xffffffff84030130: "pvh_start_xen",
]
for entry in traceLog {
    let name = funcNames[entry.rip] ?? "0x\(String(entry.rip, radix: 16))"
    print("  \(name): RDI=0x\(String(entry.rdi, radix: 16)) RSI=0x\(String(entry.rsi, radix: 16)) RAX=0x\(String(entry.rax, radix: 16)) RBX=0x\(String(entry.rbx, radix: 16))")
}
