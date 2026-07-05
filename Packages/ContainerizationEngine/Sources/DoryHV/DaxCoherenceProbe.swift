import Darwin
import Foundation
import Hypervisor

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

        try hvCheck(hv_vm_create(nil), "hv_vm_create")
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
