import Darwin
import Foundation
import Hypervisor

/// Guest physical layout, modeled on QEMU's virt machine so every address is one Linux has been
/// booting on for a decade.
public enum GuestLayout {
    // The in-kernel GIC sizes its redistributor region for the architectural vCPU maximum (32 MiB
    // observed), so the UART and virtio windows sit safely above the whole span.
    public static let gicDistributorBase: UInt64 = 0x0800_0000
    public static let gicRedistributorBase: UInt64 = 0x080A_0000
    public static let uartBase: UInt64 = 0x0C00_0000
    public static let uartIRQ: UInt32 = 1  // SPI number (intid 32 + 1)
    public static let rtcBase: UInt64 = 0x0C09_0000
    public static let virtioBase: UInt64 = 0x0C10_0000
    public static let virtioSlotSize: UInt64 = 0x200
    public static let virtioFirstIRQ: UInt32 = 16  // SPI numbers 16... (intid 48...)
    public static let ramBase: UInt64 = 0x8000_0000
    public static let dtbOffset: UInt64 = 256 << 20
    public static let daxWindowBase: UInt64 = 0xC_0000_0000
}

public struct MachineConfiguration {
    public var kernelPath: String
    public var commandLine: String
    public var memoryBytes: UInt64
    public var cpuCount: Int

    public init(kernelPath: String, commandLine: String, memoryBytes: UInt64, cpuCount: Int) {
        self.kernelPath = kernelPath
        self.commandLine = commandLine
        self.memoryBytes = memoryBytes
        self.cpuCount = cpuCount
    }
}

public enum GuestStopReason: Sendable {
    case powerOff
    case reset
    case crash(String)
}

/// The virtual machine: RAM, GIC, devices, and the vCPU threads. SMP: secondaries are created
/// eagerly, parked, and released by PSCI CPU_ON. Thread-shared state is guarded by
/// `teamCondition`; devices serialize their own guest-facing surfaces.
public final class Machine: @unchecked Sendable {
    public let configuration: MachineConfiguration
    public let memory: GuestMemory
    public let bus = MMIOBus()
    private var entryPoint: UInt64 = 0
    private var dtbAddress: UInt64 = 0
    private var sysregLogCount = 0
    private let redistributorMMIO: GICRedistributorMMIO

    public init(configuration: MachineConfiguration) throws {
        try hvCheck(hv_vm_create(nil), "hv_vm_create")
        self.configuration = configuration
        self.memory = try GuestMemory(guestBase: GuestLayout.ramBase, size: configuration.memoryBytes)
        try memory.mapIntoGuest()
        try Self.createGIC()

        var redistributorStride = 0
        try hvCheck(hv_gic_get_redistributor_size(&redistributorStride), "hv_gic_get_redistributor_size")
        self.redistributorMMIO = GICRedistributorMMIO(
            baseAddress: GuestLayout.gicRedistributorBase,
            size: try Self.gicRedistributorRegionSize(),
            stride: UInt64(redistributorStride)
        )
        bus.attach(GICDistributorMMIO(
            baseAddress: GuestLayout.gicDistributorBase,
            size: try Self.gicDistributorSize()
        ))
        bus.attach(redistributorMMIO)
    }

    deinit {
        hv_vm_destroy()
    }

    private static func createGIC() throws {
        let config = hv_gic_config_create()
        try hvCheck(hv_gic_config_set_distributor_base(config, GuestLayout.gicDistributorBase), "gic set distributor base")
        try hvCheck(hv_gic_config_set_redistributor_base(config, GuestLayout.gicRedistributorBase), "gic set redistributor base")
        try hvCheck(hv_gic_create(config), "hv_gic_create")
    }

    public static func gicDistributorSize() throws -> UInt64 {
        var size = 0
        try hvCheck(hv_gic_get_distributor_size(&size), "hv_gic_get_distributor_size")
        return UInt64(size)
    }

    public static func gicRedistributorRegionSize() throws -> UInt64 {
        var size = 0
        try hvCheck(hv_gic_get_redistributor_region_size(&size), "hv_gic_get_redistributor_region_size")
        return UInt64(size)
    }

    public static func reservedIntid(_ interrupt: hv_gic_intid_t) throws -> UInt32 {
        var intid: UInt32 = 0
        try hvCheck(hv_gic_get_intid(interrupt, &intid), "hv_gic_get_intid")
        return intid
    }

    /// Pulses a shared peripheral interrupt (declared edge-triggered in the DTB).
    public func raiseSPI(_ spi: UInt32) {
        let intid = 32 + spi
        _ = hv_gic_set_spi(intid, true)
    }

    public func loadBootPayload() throws {
        let kernel = try KernelImage(contentsOf: configuration.kernelPath)
        entryPoint = try kernel.load(into: memory)
        dtbAddress = GuestLayout.ramBase + GuestLayout.dtbOffset
        guard kernel.textOffset + kernel.imageSize < GuestLayout.dtbOffset else {
            throw VMError.bootFailure("kernel image overlaps DTB placement")
        }
        let dtb = try buildDeviceTree()
        try memory.write(dtb, at: dtbAddress)
    }

    private func buildDeviceTree() throws -> [UInt8] {
        let gicPhandle: UInt32 = 1
        let clockPhandle: UInt32 = 2
        let virtualTimer = try Self.reservedIntid(HV_GIC_INT_EL1_VIRTUAL_TIMER)
        let physicalTimer = try Self.reservedIntid(HV_GIC_INT_EL1_PHYSICAL_TIMER)
        let hypTimer = try Self.reservedIntid(HV_GIC_INT_EL2_PHYSICAL_TIMER)
        let distributorSize = try Self.gicDistributorSize()
        let redistributorSize = try Self.gicRedistributorRegionSize()

        let fdt = FDTBuilder()
        fdt.beginNode("")
        fdt.property("compatible", string: "linux,dummy-virt")
        fdt.property("#address-cells", cells: [2])
        fdt.property("#size-cells", cells: [2])
        fdt.property("interrupt-parent", cells: [gicPhandle])

        fdt.beginNode("chosen")
        fdt.property("bootargs", string: configuration.commandLine)
        fdt.property("stdout-path", string: "/pl011@\(String(GuestLayout.uartBase, radix: 16))")
        fdt.endNode()

        fdt.beginNode("memory@\(String(GuestLayout.ramBase, radix: 16))")
        fdt.property("device_type", string: "memory")
        fdt.property("reg", cells64: [GuestLayout.ramBase, configuration.memoryBytes])
        fdt.endNode()

        fdt.beginNode("cpus")
        fdt.property("#address-cells", cells: [1])
        fdt.property("#size-cells", cells: [0])
        for cpu in 0..<configuration.cpuCount {
            fdt.beginNode("cpu@\(cpu)")
            fdt.property("device_type", string: "cpu")
            fdt.property("compatible", string: "arm,arm-v8")
            fdt.property("enable-method", string: "psci")
            fdt.property("reg", cells: [UInt32(cpu)])
            fdt.endNode()
        }
        fdt.endNode()

        fdt.beginNode("psci")
        fdt.property("compatible", strings: ["arm,psci-1.0", "arm,psci-0.2"])
        fdt.property("method", string: "smc")
        fdt.endNode()

        fdt.beginNode("intc@\(String(GuestLayout.gicDistributorBase, radix: 16))")
        fdt.property("compatible", string: "arm,gic-v3")
        fdt.property("#interrupt-cells", cells: [3])
        fdt.property("#address-cells", cells: [2])
        fdt.property("#size-cells", cells: [2])
        fdt.emptyProperty("ranges")
        fdt.emptyProperty("interrupt-controller")
        // Advertise only the redistributors that exist (one per vCPU); the driver stops at the
        // end of the region without needing the Last bit on the final frame.
        let advertisedRedistributors = min(redistributorSize, redistributorMMIO.stride * UInt64(configuration.cpuCount))
        fdt.property("reg", cells64: [
            GuestLayout.gicDistributorBase, distributorSize,
            GuestLayout.gicRedistributorBase, advertisedRedistributors,
        ])
        fdt.property("phandle", cells: [gicPhandle])
        fdt.endNode()

        fdt.beginNode("timer")
        fdt.property("compatible", string: "arm,armv8-timer")
        // Cells per interrupt: type (1 = PPI), number (intid - 16), flags (4 = level high).
        fdt.property("interrupts", cells: [
            1, 13, 4,
            1, physicalTimer - 16, 4,
            1, virtualTimer - 16, 4,
            1, hypTimer - 16, 4,
        ])
        fdt.endNode()

        fdt.beginNode("apb-pclk")
        fdt.property("compatible", string: "fixed-clock")
        fdt.property("#clock-cells", cells: [0])
        fdt.property("clock-frequency", cells: [24_000_000])
        fdt.property("clock-output-names", string: "clk24mhz")
        fdt.property("phandle", cells: [clockPhandle])
        fdt.endNode()

        fdt.beginNode("pl011@\(String(GuestLayout.uartBase, radix: 16))")
        fdt.property("compatible", strings: ["arm,pl011", "arm,primecell"])
        fdt.property("reg", cells64: [GuestLayout.uartBase, 0x1000])
        fdt.property("interrupts", cells: [0, GuestLayout.uartIRQ, 4])
        fdt.property("clocks", cells: [clockPhandle, clockPhandle])
        fdt.property("clock-names", strings: ["uartclk", "apb_pclk"])
        fdt.endNode()

        fdt.beginNode("pl031@\(String(GuestLayout.rtcBase, radix: 16))")
        fdt.property("compatible", strings: ["arm,pl031", "arm,primecell"])
        fdt.property("reg", cells64: [GuestLayout.rtcBase, 0x1000])
        fdt.property("clocks", cells: [clockPhandle])
        fdt.property("clock-names", strings: ["apb_pclk"])
        fdt.endNode()

        for (slot, device) in virtioSlots.enumerated() {
            let base = GuestLayout.virtioBase + UInt64(slot) * GuestLayout.virtioSlotSize
            fdt.beginNode("virtio_mmio@\(String(base, radix: 16))")
            fdt.property("compatible", string: "virtio,mmio")
            fdt.property("reg", cells64: [base, GuestLayout.virtioSlotSize])
            fdt.property("interrupts", cells: [0, GuestLayout.virtioFirstIRQ + UInt32(slot), 1])
            fdt.endNode()
            _ = device
        }

        fdt.endNode()
        return fdt.finish()
    }

    private var virtioSlots: [MMIODevice] = []

    public func attachVirtioSlot(_ device: MMIODevice) {
        virtioSlots.append(device)
        bus.attach(device)
    }

    public func attachConsole(_ uart: PL011) {
        bus.attach(uart)
    }

    // MARK: SMP team

    private let teamCondition = NSCondition()
    private var teamHandles: [hv_vcpu_t?] = []
    private var secondaryStarts: [(entry: UInt64, context: UInt64)?] = []
    private var cpuStarted: [Bool] = []
    private var stopReason: GuestStopReason?
    private var registeredCPUs = 0
    private var finishedSecondaries = 0
    private var vcpusExited = false

    /// Boots the guest with `configuration.cpuCount` vCPUs. Every vCPU gets a dedicated thread
    /// (Hypervisor.framework requires create/run/destroy on one thread); secondaries are created
    /// up front so the kernel's redistributor walk sees all GIC frames, then parked until PSCI
    /// CPU_ON. The calling thread becomes the boot CPU. Returns when the guest stops.
    public func run() throws -> GuestStopReason {
        let count = max(1, configuration.cpuCount)
        teamHandles = Array(repeating: nil, count: count)
        secondaryStarts = Array(repeating: nil, count: count)
        cpuStarted = Array(repeating: false, count: count)
        cpuStarted[0] = true

        for index in 1..<count {
            let thread = Thread { [self] in cpuMain(index: index) }
            thread.name = "dory-hv.vcpu\(index)"
            thread.stackSize = 1 << 21
            thread.start()
        }

        teamCondition.lock()
        while registeredCPUs < count - 1, stopReason == nil {
            teamCondition.wait()
        }
        let abortedDuringBringup = stopReason != nil
        teamCondition.unlock()

        if !abortedDuringBringup {
            cpuMain(index: 0)
        }

        // The guest has stopped (or bring-up failed). Wake every secondary, cancel any still
        // running under Hypervisor.framework, and JOIN them all before returning so the caller
        // (and Machine.deinit -> hv_vm_destroy) never races a live vCPU thread.
        stopAll(stopReason ?? .powerOff)
        teamCondition.lock()
        while finishedSecondaries < count - 1 {
            teamCondition.wait()
        }
        defer { teamCondition.unlock() }
        return stopReason ?? .crash("boot CPU exited without a stop reason")
    }

    private func cpuMain(index: Int) {
        defer {
            if index != 0 {
                teamCondition.lock()
                finishedSecondaries += 1
                teamCondition.broadcast()
                teamCondition.unlock()
            }
        }
        do {
            let vcpu = try VCPU()
            try vcpu.writeSystem(HV_SYS_REG_MPIDR_EL1, 0x8000_0000 | UInt64(index))
            register(vcpu: vcpu, index: index)

            if index == 0 {
                try vcpu.write(HV_REG_CPSR, 0x3C5)
                try vcpu.write(HV_REG_PC, entryPoint)
                try vcpu.write(HV_REG_X0, dtbAddress)
                try vcpu.write(HV_REG_X1, 0)
                try vcpu.write(HV_REG_X2, 0)
                try vcpu.write(HV_REG_X3, 0)
            } else {
                guard let start = parkUntilStarted(index: index) else { return }
                try vcpu.write(HV_REG_CPSR, 0x3C5)
                try vcpu.write(HV_REG_PC, start.entry)
                try vcpu.write(HV_REG_X0, start.context)
            }

            runLoop(vcpu: vcpu)
        } catch {
            stopAll(.crash("cpu\(index) failed: \(error)"))
        }
    }

    private func register(vcpu: VCPU, index: Int) {
        // Map this vCPU to its redistributor frame by the base the GIC actually assigned it,
        // rather than assuming creation order.
        var redistributorBase: hv_ipa_t = 0
        var frameIndex = index
        if hv_gic_get_redistributor_base(vcpu.handle, &redistributorBase) == HV_SUCCESS,
           redistributorMMIO.stride > 0 {
            frameIndex = Int((redistributorBase - GuestLayout.gicRedistributorBase) / redistributorMMIO.stride)
        }
        teamCondition.lock()
        teamHandles[index] = vcpu.handle
        redistributorMMIO.setHandle(vcpu.handle, at: frameIndex)
        if index != 0 { registeredCPUs += 1 }
        teamCondition.broadcast()
        teamCondition.unlock()
    }

    private func parkUntilStarted(index: Int) -> (entry: UInt64, context: UInt64)? {
        teamCondition.lock()
        defer { teamCondition.unlock() }
        while secondaryStarts[index] == nil, stopReason == nil {
            teamCondition.wait()
        }
        return secondaryStarts[index]
    }

    private func stopAll(_ reason: GuestStopReason) {
        teamCondition.lock()
        if stopReason == nil { stopReason = reason }
        // Cancel running vCPUs exactly once: a second pass could touch a handle a finished thread
        // has already destroyed.
        var handles: [hv_vcpu_t] = []
        if !vcpusExited {
            vcpusExited = true
            handles = teamHandles.compactMap { $0 }
        }
        teamCondition.broadcast()
        teamCondition.unlock()
        if !handles.isEmpty {
            hv_vcpus_exit(&handles, UInt32(handles.count))
        }
    }

    private func startSecondary(mpidr: UInt64, entry: UInt64, context: UInt64) -> Int64 {
        let index = Int(mpidr & 0xFF)
        teamCondition.lock()
        defer { teamCondition.unlock() }
        guard index > 0, index < cpuStarted.count else { return -2 }  // INVALID_PARAMETERS
        guard !cpuStarted[index] else { return -4 }  // ALREADY_ON
        cpuStarted[index] = true
        secondaryStarts[index] = (entry: entry, context: context)
        teamCondition.broadcast()
        return 0
    }

    private func runLoop(vcpu: VCPU) {
        while true {
            teamCondition.lock()
            let stopped = stopReason != nil
            teamCondition.unlock()
            if stopped { return }

            do {
                let event = try vcpu.run()
                switch event {
                case .canceled:
                    return
                case .vtimerActivated:
                    // With the in-kernel GIC the timer PPI is delivered by the GIC itself; unmask
                    // and continue so the vtimer can fire again.
                    try vcpu.setVTimerMask(false)
                case .exception(let syndrome, _, let physicalAddress):
                    if let stop = try handleException(
                        vcpu: vcpu, syndrome: syndrome, physicalAddress: physicalAddress
                    ) {
                        stopAll(stop)
                        return
                    }
                case .unknown(let raw):
                    stopAll(.crash("unknown exit reason \(raw)"))
                    return
                }
            } catch {
                stopAll(.crash("\(error)"))
                return
            }
        }
    }

    private func handleException(vcpu: VCPU, syndrome: UInt64, physicalAddress: UInt64) throws -> GuestStopReason? {
        guard let exceptionClass = ExceptionClass(syndrome: syndrome) else {
            let pc = try vcpu.read(HV_REG_PC)
            return .crash("unhandled exception class \(syndrome >> 26), syndrome 0x\(String(syndrome, radix: 16)), pc 0x\(String(pc, radix: 16))")
        }
        switch exceptionClass {
        case .dataAbortLowerEL:
            try handleMMIO(vcpu: vcpu, syndrome: syndrome, physicalAddress: physicalAddress)
            return nil
        case .instructionAbortLowerEL:
            guard restoreIfReleasedRAM(physicalAddress) else {
                return .crash("instruction abort outside RAM at pa 0x\(String(physicalAddress, radix: 16))")
            }
            return nil
        case .hvc64:
            // HVC returns with PC already past the instruction; unknown hypercalls get
            // SMCCC NOT_SUPPORTED.
            try vcpu.write(HV_REG_X0, UInt64(bitPattern: -1))
            return nil
        case .smc64:
            let result = try handleSMC(vcpu: vcpu)
            try advancePC(vcpu)
            return result
        case .systemRegisterTrap:
            try handleSystemRegisterTrap(vcpu: vcpu, syndrome: syndrome)
            try advancePC(vcpu)
            return nil
        }
    }

    private func handleMMIO(vcpu: VCPU, syndrome: UInt64, physicalAddress: UInt64) throws {
        if restoreIfReleasedRAM(physicalAddress) { return }
        let abort = DataAbortInfo(syndrome: syndrome)
        guard abort.isValid else {
            let pc = try vcpu.read(HV_REG_PC)
            throw VMError.unexpectedExit("data abort without syndrome info at pa 0x\(String(physicalAddress, radix: 16)), pc 0x\(String(pc, radix: 16))")
        }
        guard let (device, offset) = bus.device(for: physicalAddress) else {
            let pc = try vcpu.read(HV_REG_PC)
            throw VMError.unexpectedExit("guest touched unmapped pa 0x\(String(physicalAddress, radix: 16)), pc 0x\(String(pc, radix: 16))")
        }
        if abort.isWrite {
            let value = abort.registerIndex == 31 ? 0 : try vcpu.read(registerFor(abort.registerIndex))
            device.write(offset: offset, value: truncate(value, width: abort.width), width: abort.width)
        } else {
            var value = device.read(offset: offset, width: abort.width)
            value = truncate(value, width: abort.width)
            if abort.signExtend {
                value = signExtend(value, width: abort.width, to64: abort.sixtyFourBit)
            } else if !abort.sixtyFourBit {
                value &= 0xFFFF_FFFF
            }
            if abort.registerIndex != 31 {
                try vcpu.write(registerFor(abort.registerIndex), value)
            }
        }
        try advancePC(vcpu)
    }

    private func handleSMC(vcpu: VCPU) throws -> GuestStopReason? {
        let function = UInt32(truncatingIfNeeded: try vcpu.read(HV_REG_X0))
        switch function {
        case PSCI.version:
            try vcpu.write(HV_REG_X0, 0x0001_0000)
        case PSCI.features:
            let queried = UInt32(truncatingIfNeeded: try vcpu.read(HV_REG_X1))
            let supported: Set<UInt32> = [PSCI.version, PSCI.features, PSCI.systemOff, PSCI.systemReset, PSCI.cpuOn, PSCI.migrateInfoType]
            try vcpu.write(HV_REG_X0, supported.contains(queried) ? 0 : UInt64(bitPattern: -1))
        case PSCI.migrateInfoType:
            try vcpu.write(HV_REG_X0, 2)  // migration not required
        case PSCI.systemOff:
            return .powerOff
        case PSCI.systemReset:
            return .reset
        case PSCI.cpuOn:
            let target = try vcpu.read(HV_REG_X1)
            let entry = try vcpu.read(HV_REG_X2)
            let context = try vcpu.read(HV_REG_X3)
            let result = startSecondary(mpidr: target, entry: entry, context: context)
            try vcpu.write(HV_REG_X0, UInt64(bitPattern: Int64(result)))
        default:
            try vcpu.write(HV_REG_X0, UInt64(bitPattern: -1))
        }
        return nil
    }

    private func handleSystemRegisterTrap(vcpu: VCPU, syndrome: UInt64) throws {
        // RAZ/WI for trapped system registers the hardware does not virtualize (debug, PMU).
        let isRead = syndrome & 1 == 1
        let registerIndex = Int((syndrome >> 5) & 0x1F)
        if sysregLogCount < 8 {
            sysregLogCount += 1
            let encoding = String(format: "op0=%d op1=%d crn=%d crm=%d op2=%d",
                                  Int((syndrome >> 20) & 0b11), Int((syndrome >> 14) & 0b111),
                                  Int((syndrome >> 10) & 0b1111), Int((syndrome >> 1) & 0b1111),
                                  Int((syndrome >> 17) & 0b111))
            FileHandle.standardError.write(Data("dory-hv: sysreg trap (\(isRead ? "read" : "write")) \(encoding), RAZ/WI\n".utf8))
        }
        if isRead && registerIndex != 31 {
            try vcpu.write(registerFor(registerIndex), 0)
        }
    }

    /// A fault inside the RAM window MIGHT be the guest touching a page that free page reporting
    /// returned to macOS. restorePage remaps it and returns true; if the page was never released
    /// this returns false, so a genuine guest fault falls through to the crash path with a
    /// diagnostic instead of an unkillable refault loop.
    private func restoreIfReleasedRAM(_ physicalAddress: UInt64) -> Bool {
        memory.restorePage(guestAddress: physicalAddress)
    }

    private func advancePC(_ vcpu: VCPU) throws {
        let pc = try vcpu.read(HV_REG_PC)
        try vcpu.write(HV_REG_PC, pc + 4)
    }

    private func registerFor(_ index: Int) -> hv_reg_t {
        hv_reg_t(HV_REG_X0.rawValue + UInt32(index))
    }

    private func truncate(_ value: UInt64, width: Int) -> UInt64 {
        switch width {
        case 1: return value & 0xFF
        case 2: return value & 0xFFFF
        case 4: return value & 0xFFFF_FFFF
        default: return value
        }
    }

    private func signExtend(_ value: UInt64, width: Int, to64: Bool) -> UInt64 {
        let bits = width * 8
        let signBit = UInt64(1) << (bits - 1)
        var extended = value
        if value & signBit != 0 {
            extended |= ~((UInt64(1) << bits) - 1)
        }
        return to64 ? extended : extended & 0xFFFF_FFFF
    }
}

enum PSCI {
    static let version: UInt32 = 0x8400_0000
    static let cpuOn: UInt32 = 0xC400_0003
    static let migrateInfoType: UInt32 = 0x8400_0006
    static let systemOff: UInt32 = 0x8400_0008
    static let systemReset: UInt32 = 0x8400_0009
    static let features: UInt32 = 0x8400_000A
}
