import Darwin
import Foundation
import Hypervisor

/// Diagnostic: measures which madvise advice actually releases physical pages, on a plain anon
/// mmap and on the same region after hv_vm_map. Prints resident/footprint before and after.
public enum MadviseProbe {
    private static let megabytes = 512
    private static let madvZero: Int32 = 11

    public static func run() throws {
        try scenario(label: "plain mmap", mapIntoVM: false)
        try scenario(label: "hv_vm_map", mapIntoVM: true)
    }

    private static func scenario(label: String, mapIntoVM: Bool) throws {
        let size = megabytes << 20
        guard let region = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0),
              region != MAP_FAILED else {
            throw VMError.outOfMemory("mmap failed")
        }
        defer { munmap(region, size) }

        if mapIntoVM {
            try hvCheck(hv_vm_create(nil), "hv_vm_create")
            try hvCheck(
                hv_vm_map(region, 0x8000_0000, size, hv_memory_flags_t(HV_MEMORY_READ | HV_MEMORY_WRITE | HV_MEMORY_EXEC)),
                "hv_vm_map"
            )
        }
        defer { if mapIntoVM { hv_vm_destroy() } }

        memset(region, 0xA5, size)
        report("\(label): after touching \(megabytes)MB")

        for (name, advice) in [("MADV_ZERO", madvZero), ("MADV_FREE_REUSABLE", MADV_FREE_REUSABLE), ("MADV_FREE", MADV_FREE)] {
            let result = madvise(region, size, advice)
            report("\(label): madvise(\(name)) -> \(result == 0 ? "ok" : "errno \(errno)")")
            if result == 0 { break }
        }
        report("\(label): final")
    }

    private static func report(_ label: String) {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        _ = proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &info, size)
        var vmInfo = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let _ = withUnsafeMutablePointer(to: &vmInfo) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        print("\(label): resident \(info.pti_resident_size >> 20) MB, footprint \(UInt64(vmInfo.phys_footprint) >> 20) MB")
    }
}
