import Darwin
import Foundation
import Hypervisor
import Synchronization

/// Candidate-bound RawHV host scheduling profile.
///
/// AppKit owns the user-interactive class. Sustained guest execution and device work are
/// user-initiated: they remain latency-sensitive while yielding the system's highest scheduling
/// class to input and presentation. Revision changes require a new runtime-envelope identity and
/// matched physical responsiveness/workload calibration before release qualification.
public enum RawHVSchedulingPolicy {
    public static let revision: UInt16 = 1
    public static let vCPUThreadQualityOfService: QualityOfService = .userInitiated
    public static let machineOwnerThreadQualityOfService: QualityOfService = .userInitiated
    public static let machineOwnerThreadStackSize = 1 << 21
    public static let blockIOWorkerDispatchQoS: DispatchQoS = .userInitiated
    public static let networkIOWorkerDispatchQoS: DispatchQoS = .userInitiated
    public static let fileSystemWorkerDispatchQoS: DispatchQoS = .userInitiated

    static func applyToCurrentVCPUThread() {
        applyUserInitiated(to: vCPUThreadQualityOfService)
    }

    static func applyToCurrentMachineOwnerThread() {
        applyUserInitiated(to: machineOwnerThreadQualityOfService)
    }

    private static func applyUserInitiated(to qualityOfService: QualityOfService) {
        Thread.current.qualityOfService = qualityOfService
        _ = pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0)
    }
}

/// Guest-visible identity of one occupied virtio-mmio slot.
///
/// This intentionally carries only the low-level bus identity. Product device roles belong to the
/// resolved virtual-hardware topology contract and must not be inferred from attachment order.
public struct VirtioMMIOSlotIdentity: Equatable, Sendable {
    public let slot: Int
    public let baseAddress: UInt64
    public let size: UInt64
    public let interrupt: UInt32

    init(slot: Int, baseAddress: UInt64, size: UInt64, interrupt: UInt32) {
        self.slot = slot
        self.baseAddress = baseAddress
        self.size = size
        self.interrupt = interrupt
    }
}

/// Canonical low-level input for the eventual virtual-hardware ABI fingerprint. The resolved
/// topology layer will prefix device roles and capabilities; this layer contributes stable
/// slot/MMIO/IRQ identities in a fixed byte order independent of attachment order.
enum VirtioMMIOLayoutCanonicalizer {
    static func fingerprintInput(for identities: [VirtioMMIOSlotIdentity]) -> [UInt8] {
        let sorted = identities.sorted { lhs, rhs in
            if lhs.slot != rhs.slot { return lhs.slot < rhs.slot }
            if lhs.baseAddress != rhs.baseAddress { return lhs.baseAddress < rhs.baseAddress }
            if lhs.interrupt != rhs.interrupt { return lhs.interrupt < rhs.interrupt }
            return lhs.size < rhs.size
        }
        var bytes = Array("dory.virtio-mmio.layout".utf8)
        bytes.append(0)
        appendBigEndian(UInt32(1), to: &bytes)
        appendBigEndian(UInt32(sorted.count), to: &bytes)
        for identity in sorted {
            appendBigEndian(UInt32(identity.slot), to: &bytes)
            appendBigEndian(identity.baseAddress, to: &bytes)
            appendBigEndian(identity.size, to: &bytes)
            appendBigEndian(identity.interrupt, to: &bytes)
        }
        return bytes
    }

    private static func appendBigEndian<T: FixedWidthInteger>(_ value: T, to bytes: inout [UInt8]) {
        withUnsafeBytes(of: value.bigEndian) { bytes.append(contentsOf: $0) }
    }
}

/// Owns the one-to-one relationship between stable virtio slots and attached MMIO devices.
/// Configuration is serialized even though normal callers attach before vCPU startup, so duplicate
/// concurrent requests cannot leak a second device into `MMIOBus`.
final class VirtioMMIOSlotOwnership {
    private struct Attachment {
        let device: MMIODevice
        let identity: VirtioMMIOSlotIdentity
    }

    private struct State {
        var attachmentsBySlot: [Int: Attachment] = [:]
        var attachedDeviceIdentities: Set<ObjectIdentifier> = []
    }

    private let lock = NSLock()
    private var state = State()
    private let maximumSlots: Int
    private let baseAddress: UInt64
    private let slotSize: UInt64
    private let firstInterrupt: UInt32

    init(maximumSlots: Int, baseAddress: UInt64, slotSize: UInt64, firstInterrupt: UInt32) {
        precondition(maximumSlots > 0)
        precondition(slotSize > 0)
        self.maximumSlots = maximumSlots
        self.baseAddress = baseAddress
        self.slotSize = slotSize
        self.firstInterrupt = firstInterrupt
    }

    var identities: [VirtioMMIOSlotIdentity] {
        lock.lock()
        defer { lock.unlock() }
        return state.attachmentsBySlot.values.map(\.identity).sorted { $0.slot < $1.slot }
    }

    var fingerprintInput: [UInt8] {
        VirtioMMIOLayoutCanonicalizer.fingerprintInput(for: identities)
    }

    @discardableResult
    func attach(
        _ device: MMIODevice,
        at slot: Int,
        attachToBus: (MMIODevice) -> Void
    ) throws -> VirtioMMIOSlotIdentity {
        let slotIdentity = try identity(for: slot)
        lock.lock()
        defer { lock.unlock() }
        return try attachLocked(
            device,
            identity: slotIdentity,
            attachToBus: attachToBus
        )
    }

    private func attachLocked(
        _ device: MMIODevice,
        identity slotIdentity: VirtioMMIOSlotIdentity,
        attachToBus: (MMIODevice) -> Void
    ) throws -> VirtioMMIOSlotIdentity {
        let slot = slotIdentity.slot
        guard device.baseAddress == slotIdentity.baseAddress else {
            throw VMError.invalidConfiguration(
                "virtio slot \(slot) requires MMIO base 0x\(String(slotIdentity.baseAddress, radix: 16)), got 0x\(String(device.baseAddress, radix: 16))"
            )
        }
        guard device.size == slotIdentity.size else {
            throw VMError.invalidConfiguration(
                "virtio slot \(slot) requires MMIO size 0x\(String(slotIdentity.size, radix: 16)), got 0x\(String(device.size, radix: 16))"
            )
        }
        guard state.attachmentsBySlot[slot] == nil else {
            throw VMError.invalidConfiguration("virtio slot \(slot) is already occupied")
        }
        let deviceIdentity = ObjectIdentifier(device)
        guard !state.attachedDeviceIdentities.contains(deviceIdentity) else {
            throw VMError.invalidConfiguration("virtio MMIO device is already attached")
        }
        attachToBus(device)
        state.attachmentsBySlot[slot] = Attachment(device: device, identity: slotIdentity)
        state.attachedDeviceIdentities.insert(deviceIdentity)
        return slotIdentity
    }

    private func identity(for slot: Int) throws -> VirtioMMIOSlotIdentity {
        guard slot >= 0, slot < maximumSlots else {
            throw VMError.invalidConfiguration(
                "virtio slot \(slot) is outside 0..<\(maximumSlots)"
            )
        }
        guard let unsignedSlot = UInt64(exactly: slot) else {
            throw VMError.invalidConfiguration("virtio slot \(slot) cannot be represented")
        }
        let (offset, offsetOverflow) = unsignedSlot.multipliedReportingOverflow(by: slotSize)
        let (address, addressOverflow) = baseAddress.addingReportingOverflow(offset)
        guard !offsetOverflow, !addressOverflow else {
            throw VMError.invalidConfiguration("virtio slot \(slot) MMIO address overflows")
        }
        guard let interruptOffset = UInt32(exactly: slot) else {
            throw VMError.invalidConfiguration("virtio slot \(slot) interrupt cannot be represented")
        }
        let (interrupt, interruptOverflow) = firstInterrupt.addingReportingOverflow(interruptOffset)
        guard !interruptOverflow else {
            throw VMError.invalidConfiguration("virtio slot \(slot) interrupt overflows")
        }
        return VirtioMMIOSlotIdentity(
            slot: slot,
            baseAddress: address,
            size: slotSize,
            interrupt: interrupt
        )
    }
}

enum VirtioMMIODeviceTree {
    static func appendNodes(
        for identities: [VirtioMMIOSlotIdentity],
        to fdt: FDTBuilder
    ) {
        for identity in identities.sorted(by: { $0.slot < $1.slot }) {
            fdt.beginNode("virtio_mmio@\(String(identity.baseAddress, radix: 16))")
            fdt.property("compatible", string: "virtio,mmio")
            fdt.property("reg", cells64: [identity.baseAddress, identity.size])
            fdt.property("interrupts", cells: [0, identity.interrupt, 1])
            fdt.endNode()
        }
    }
}

#if arch(arm64)
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
    /// QEMU's arm64 `virt` platform reserves 32 virtio-mmio transports. Dory preserves that
    /// bounded window while allowing holes within it.
    public static let virtioSlotCount = 32
    public static let virtioFirstIRQ: UInt32 = 16  // SPI numbers 16... (intid 48...)
    public static let ramBase: UInt64 = 0x8000_0000
    public static let dtbOffset: UInt64 = 256 << 20
    /// Direct-boot initrds live beyond the kernel/DTB reservation while remaining well inside
    /// the minimum supported 1-GiB guest. Keeping this deterministic also makes the DTB contract
    /// straightforward to test and diagnose.
    public static let initrdOffset: UInt64 = 320 << 20
    public static let daxWindowBase: UInt64 = 0xC_0000_0000
}

public struct MachineConfiguration {
    public let bootPayload: MachineBootPayload
    public var commandLine: String
    public var memoryBytes: UInt64
    public var cpuCount: Int

    public init(
        kernelPath: String,
        initrdPath: String? = nil,
        commandLine: String,
        memoryBytes: UInt64,
        cpuCount: Int
    ) {
        self.bootPayload = .legacyPaths(kernel: kernelPath, initrd: initrdPath)
        self.commandLine = commandLine
        self.memoryBytes = memoryBytes
        self.cpuCount = cpuCount
    }

    public init(
        bootPayload: MachineBootPayload,
        commandLine: String,
        memoryBytes: UInt64,
        cpuCount: Int
    ) {
        self.bootPayload = bootPayload
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

/// One-way, lock-free publication from stop ownership into each vCPU's exit loop.
///
/// `Machine` remains single-run: the condition-protected stop reason, vCPU handles, wakeups, and
/// joins own the lifecycle. This signal only removes that global condition from the common path
/// after a vCPU exit. A releasing request paired with an acquiring read also makes state published
/// before the stop request visible before a vCPU leaves its loop.
final class VCPUStopSignal: Sendable {
    private let requested = Atomic<Bool>(false)

    var isRequested: Bool {
        requested.load(ordering: .acquiring)
    }

    func request() {
        requested.store(true, ordering: .releasing)
    }
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
    private let virtioSlotOwnership = VirtioMMIOSlotOwnership(
        maximumSlots: GuestLayout.virtioSlotCount,
        baseAddress: GuestLayout.virtioBase,
        slotSize: GuestLayout.virtioSlotSize,
        firstInterrupt: GuestLayout.virtioFirstIRQ
    )

    public init(configuration: MachineConfiguration) throws {
        try hvCreateVM()
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

    /// Pulses a guest system interrupt. On arm64 these are GIC SPIs declared edge-triggered in the DTB.
    public func raiseGSI(_ gsi: UInt32) {
        setGSI(gsi, asserted: true)
    }

    /// Drives a level-sensitive guest system interrupt. UART input uses this to keep the PL011
    /// receive line asserted until the guest has drained the pending bytes.
    public func setGSI(_ gsi: UInt32, asserted: Bool) {
        let intid = 32 + gsi
        _ = hv_gic_set_spi(intid, asserted)
    }

    /// Compatibility spelling for arm64 callers; new shared engine code should use `raiseGSI`.
    public func raiseSPI(_ spi: UInt32) {
        raiseGSI(spi)
    }

    public func requestStop(_ reason: GuestStopReason) {
        stopAll(reason)
    }

    public func loadBootPayload() throws {
        try configuration.bootPayload.consumeForGuestLoad { kernelData, loadInitrd in
            let kernel = try KernelImage(data: kernelData)
            entryPoint = try kernel.load(into: memory)
            dtbAddress = GuestLayout.ramBase + GuestLayout.dtbOffset
            let (kernelEndOffset, kernelEndOverflowed) =
                kernel.textOffset.addingReportingOverflow(kernel.imageSize)
            guard !kernelEndOverflowed,
                  kernelEndOffset < GuestLayout.dtbOffset else {
                throw VMError.bootFailure("kernel image overlaps DTB placement")
            }
            let initrdRange = try loadInitrdIfPresent(try loadInitrd())
            let dtb = try buildDeviceTree(initrdRange: initrdRange)
            try memory.write(dtb, at: dtbAddress)
        }
    }

    private func loadInitrdIfPresent(_ data: Data?) throws -> Range<UInt64>? {
        guard let data else { return nil }
        guard !data.isEmpty else {
            throw VMError.bootFailure("initrd is empty")
        }
        let start = GuestLayout.ramBase + GuestLayout.initrdOffset
        let (end, overflowed) = start.addingReportingOverflow(UInt64(data.count))
        guard !overflowed,
              end > start,
              end <= GuestLayout.ramBase + configuration.memoryBytes else {
            throw VMError.bootFailure("initrd does not fit in guest memory")
        }
        try copyBootData(data, at: start)
        return start..<end
    }

    private func buildDeviceTree(initrdRange: Range<UInt64>?) throws -> [UInt8] {
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
        if let initrdRange {
            fdt.property("linux,initrd-start", cells64: [initrdRange.lowerBound])
            fdt.property("linux,initrd-end", cells64: [initrdRange.upperBound])
        }
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

        VirtioMMIODeviceTree.appendNodes(for: attachedVirtioSlots, to: fdt)

        fdt.endNode()
        return fdt.finish()
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
    private let stopSignal = VCPUStopSignal()
    private var registeredCPUs = 0
    private var finishedSecondaries = 0
    private var vcpusExited = false

    /// Boots the guest with `configuration.cpuCount` vCPUs. Every vCPU gets a dedicated thread
    /// (Hypervisor.framework requires create/run/destroy on one thread); secondaries are created
    /// up front so the kernel's redistributor walk sees all GIC frames, then parked until PSCI
    /// CPU_ON. The calling thread becomes the boot CPU. Returns when the guest stops.
    public func run() throws -> GuestStopReason {
        // Attachment is a cold boot operation. Freeze the sorted routing table before any vCPU
        // can read it concurrently, and give each vCPU its own hot lookup cache in `runLoop`.
        bus.seal()
        let count = max(1, configuration.cpuCount)
        teamHandles = Array(repeating: nil, count: count)
        secondaryStarts = Array(repeating: nil, count: count)
        cpuStarted = Array(repeating: false, count: count)
        cpuStarted[0] = true

        for index in 1..<count {
            let thread = Thread { [self] in cpuMain(index: index) }
            thread.name = "dory-hv.vcpu\(index)"
            thread.qualityOfService = RawHVSchedulingPolicy.vCPUThreadQualityOfService
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
        let terminalReason = stopReason
            ?? .crash("boot CPU exited without a published stop reason")
        stopAll(terminalReason)
        teamCondition.lock()
        while finishedSecondaries < count - 1 {
            teamCondition.wait()
        }
        defer { teamCondition.unlock() }
        return stopReason ?? terminalReason
    }

    private func cpuMain(index: Int) {
        RawHVSchedulingPolicy.applyToCurrentVCPUThread()
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

            runLoop(vcpu: vcpu, index: index)
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
        let publishesReason = stopReason == nil
        if publishesReason { stopReason = reason }
        stopSignal.request()
        // Cancel running vCPUs exactly once: a second pass could touch a handle a finished thread
        // has already destroyed.
        var handles: [hv_vcpu_t] = []
        if !vcpusExited {
            vcpusExited = true
            handles = teamHandles.compactMap { $0 }
        }
        teamCondition.broadcast()
        teamCondition.unlock()
        if publishesReason {
            FileHandle.standardError.write(
                Data("dory-hv: guest stop reason: \(reason)\n".utf8)
            )
        }
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

    private func runLoop(vcpu: VCPU, index: Int) {
        var mmioRouteCache = MMIORouteCache()
        while true {
            if stopSignal.isRequested { return }

            do {
                let event = try vcpu.run()
                switch event {
                case .canceled:
                    if !stopSignal.isRequested {
                        stopAll(.crash(
                            "cpu\(index) Hypervisor run was canceled without a stop request"
                        ))
                    }
                    return
                case .vtimerActivated:
                    // With the in-kernel GIC the timer PPI is delivered by the GIC itself; unmask
                    // and continue so the vtimer can fire again.
                    try vcpu.setVTimerMask(false)
                case .exception(let syndrome, _, let physicalAddress):
                    if let stop = try handleException(
                        vcpu: vcpu,
                        syndrome: syndrome,
                        physicalAddress: physicalAddress,
                        mmioRouteCache: &mmioRouteCache
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

    private func handleException(
        vcpu: VCPU,
        syndrome: UInt64,
        physicalAddress: UInt64,
        mmioRouteCache: inout MMIORouteCache
    ) throws -> GuestStopReason? {
        guard let exceptionClass = ExceptionClass(syndrome: syndrome) else {
            let pc = try vcpu.read(HV_REG_PC)
            return .crash("unhandled exception class \(syndrome >> 26), syndrome 0x\(String(syndrome, radix: 16)), pc 0x\(String(pc, radix: 16))")
        }
        switch exceptionClass {
        case .dataAbortLowerEL:
            try handleMMIO(
                vcpu: vcpu,
                syndrome: syndrome,
                physicalAddress: physicalAddress,
                routeCache: &mmioRouteCache
            )
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

    private func handleMMIO(
        vcpu: VCPU,
        syndrome: UInt64,
        physicalAddress: UInt64,
        routeCache: inout MMIORouteCache
    ) throws {
        if restoreIfReleasedRAM(physicalAddress) { return }
        let abort = DataAbortInfo(syndrome: syndrome)
        guard abort.isValid else {
            let pc = try vcpu.read(HV_REG_PC)
            throw VMError.unexpectedExit("data abort without syndrome info at pa 0x\(String(physicalAddress, radix: 16)), pc 0x\(String(pc, radix: 16))")
        }
        guard let (device, offset) = bus.device(for: physicalAddress, cache: &routeCache) else {
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
#else
/// Device-wiring view of the x86 guest layout. Every value is sourced from `X86GuestLayout`, the
/// single source of truth also used to build the PVH boot plan, MPTABLE, and kernel command line,
/// so the device model and the boot contract can never drift apart.
public enum GuestLayout {
    public static let uartBase = X86GuestLayout.uartBase
    public static let uartIRQ = UInt32(X86GuestLayout.uartIRQ)
    public static let rtcBase = X86GuestLayout.rtcBase
    public static let virtioBase = X86GuestLayout.virtioBase
    public static let virtioSlotSize = X86GuestLayout.virtioSlotSize
    public static let virtioSlotCount = X86GuestLayout.virtioSlotCount
    public static let virtioFirstIRQ = UInt32(X86GuestLayout.virtioFirstIRQ)
    public static let ramBase = X86GuestLayout.ramBase
    public static let daxWindowBase = X86GuestLayout.daxWindowBase
}

public struct MachineConfiguration {
    public let bootPayload: MachineBootPayload
    public var commandLine: String
    public var memoryBytes: UInt64
    public var cpuCount: Int

    public init(
        kernelPath: String,
        initrdPath: String? = nil,
        commandLine: String,
        memoryBytes: UInt64,
        cpuCount: Int
    ) {
        self.bootPayload = .legacyPaths(kernel: kernelPath, initrd: initrdPath)
        self.commandLine = commandLine
        self.memoryBytes = memoryBytes
        self.cpuCount = cpuCount
    }

    public init(
        bootPayload: MachineBootPayload,
        commandLine: String,
        memoryBytes: UInt64,
        cpuCount: Int
    ) {
        self.bootPayload = bootPayload
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

public final class Machine: @unchecked Sendable {
    public let configuration: MachineConfiguration
    public let memory: GuestMemory
    public let bus = MMIOBus()
    public let pioBus = PIOBus()
    public private(set) var entryPoint: UInt64 = 0
    public private(set) var startInfoAddress: UInt64 = 0
    private let stopLock = NSLock()
    private var stopReason: GuestStopReason?
    private let virtioSlotOwnership = VirtioMMIOSlotOwnership(
        maximumSlots: GuestLayout.virtioSlotCount,
        baseAddress: GuestLayout.virtioBase,
        slotSize: GuestLayout.virtioSlotSize,
        firstInterrupt: GuestLayout.virtioFirstIRQ
    )

    public init(configuration: MachineConfiguration) throws {
        try hvCreateVM()
        var configuration = configuration
        if configuration.memoryBytes > X86GuestLayout.mmioHoleBase {
            fputs(
                "dory-hv: capping guest memory to \(X86GuestLayout.mmioHoleBase >> 20) MiB (x86 MMIO hole at 0x\(String(X86GuestLayout.mmioHoleBase, radix: 16)))\n",
                stderr
            )
            configuration.memoryBytes = X86GuestLayout.mmioHoleBase
        }
        self.configuration = configuration
        self.memory = try GuestMemory(guestBase: 0, size: configuration.memoryBytes)
        try memory.mapIntoGuest()
    }

    deinit {
        hv_vm_destroy()
    }

    public func loadBootPayload() throws {
        try configuration.bootPayload.consumeForGuestLoad { kernelData, loadInitrd in
            let kernel = try PVHKernelImage(data: kernelData)
            entryPoint = try kernel.load(into: memory)
            startInfoAddress = X86GuestLayout.pvhStartInfo

            let initrdData = try loadInitrd()
            if let initrdData, initrdData.isEmpty {
                throw VMError.bootFailure("initrd is empty")
            }
            let initrdAddress = X86GuestLayout.initrd
            if let initrdData {
                let (end, overflowed) = initrdAddress.addingReportingOverflow(UInt64(initrdData.count))
                guard !overflowed, end <= configuration.memoryBytes else {
                    throw VMError.bootFailure("initrd does not fit in guest memory")
                }
                try copyBootData(initrdData, at: initrdAddress)
            }

            let virtioDevices = try attachedVirtioSlots.map { identity -> X86VirtioMMIODevice in
                guard let interrupt = UInt8(exactly: identity.interrupt) else {
                    throw VMError.invalidConfiguration(
                        "virtio slot \(identity.slot) interrupt \(identity.interrupt) exceeds x86 IOAPIC encoding"
                    )
                }
                return X86VirtioMMIODevice(
                    slot: identity.slot,
                    baseAddress: identity.baseAddress,
                    size: identity.size,
                    irq: interrupt
                )
            }
            let plan = X86BootPlanBuilder.build(
                baseCommandLine: configuration.commandLine,
                memoryBytes: configuration.memoryBytes,
                virtioDevices: virtioDevices
            )
            let pvh = PVHBootBuilder.build(
                commandLine: plan.commandLine,
                commandLinePhysicalAddress: X86GuestLayout.pvhCommandLine,
                modulesPhysicalAddress: X86GuestLayout.pvhModules,
                memoryMapPhysicalAddress: X86GuestLayout.pvhMemoryMap,
                modules: initrdData.map {
                    [PVHModule(physicalAddress: initrdAddress, size: UInt64($0.count))]
                } ?? [],
                memoryMap: plan.memoryMap
            )
            try memory.write(Array(pvh.startInfo), at: X86GuestLayout.pvhStartInfo)
            try memory.write(Array(pvh.commandLine), at: X86GuestLayout.pvhCommandLine)
            if !pvh.modules.isEmpty {
                try memory.write(Array(pvh.modules), at: X86GuestLayout.pvhModules)
            }
            try memory.write(Array(pvh.memoryMap), at: X86GuestLayout.pvhMemoryMap)

            let mpTable = MPTableBuilder.build(
                tablePhysicalAddress: UInt32(X86GuestLayout.mpConfigurationTable),
                cpuCount: configuration.cpuCount,
                virtioInterruptPins: plan.virtioDevices.map(\.irq)
            )
            try memory.write(Array(mpTable.floatingPointer), at: X86GuestLayout.mpFloatingPointer)
            try memory.write(Array(mpTable.configurationTable), at: X86GuestLayout.mpConfigurationTable)
        }
    }

    public func attachConsole(_ uart: UART16550) {
        pioBus.attach(uart)
    }

    public func attachRTC(_ rtc: CMOSRTC) {
        pioBus.attach(rtc)
    }

    public func attachResetController(_ controller: I8042) {
        pioBus.attach(controller)
    }

    public func raiseGSI(_ gsi: UInt32) {
        _ = hv_vm_ioapic_pulse_irq(Int32(gsi))
    }

    public func raiseSPI(_ spi: UInt32) {
        raiseGSI(spi)
    }

    public func requestStop(_ reason: GuestStopReason) {
        stopLock.lock()
        if stopReason == nil {
            stopReason = reason
        }
        stopLock.unlock()
    }

    public func run() throws -> GuestStopReason {
        if entryPoint == 0 || startInfoAddress == 0 {
            try loadBootPayload()
        }
        bus.seal()
        let vcpu = try VCPU()
        try vcpu.configurePVHEntry(entryPoint: entryPoint, startInfoAddress: startInfoAddress)
        var executor = X86VMExitExecutor()

        while true {
            if let reason = currentStopReason() {
                return reason
            }
            let state: X86VMExitState
            switch try vcpu.run() {
            case .vmExit(let exitState):
                state = exitState
            }
            var registers = try vcpu.snapshotGeneralRegisters()
            let action = try executor.execute(state: state, registers: &registers, pioBus: pioBus)
            try vcpu.applyGeneralRegisters(registers)
            switch action {
            case .advanceRIP(let length):
                try vcpu.advanceRIP(by: length)
            case .writeMSR(let write, let length):
                try vcpu.applyGuestMSRWrite(write)
                try vcpu.advanceRIP(by: length)
            case .controlRegister(let controlRegister):
                try handleControlRegister(controlRegister, vcpu: vcpu, registers: &registers)
                try vcpu.applyGeneralRegisters(registers)
                try vcpu.advanceRIP(by: controlRegister.instructionLength)
            case .invalidateTLB(let length):
                try vcpu.invalidateTLB()
                try vcpu.advanceRIP(by: length)
            case .halted:
                try vcpu.advanceRIP(by: state.instructionLength)
                usleep(1_000)
            case .eptViolation(let violation):
                if memory.restorePage(guestAddress: violation.guestPhysicalAddress) {
                    continue
                }
                let ripAdvance = try handleEPTViolation(violation, vcpu: vcpu, registers: &registers)
                try vcpu.applyGeneralRegisters(registers)
                try vcpu.advanceRIP(by: UInt32(ripAdvance))
            case .eptMisconfiguration(let guestPhysicalAddress):
                throw VMError.unexpectedExit(
                    "x86 EPT misconfiguration at gpa 0x\(String(guestPhysicalAddress, radix: 16))"
                )
            }
        }
    }

    private func currentStopReason() -> GuestStopReason? {
        stopLock.lock()
        defer { stopLock.unlock() }
        return stopReason
    }

    private func handleControlRegister(
        _ exit: X86ControlRegisterExit,
        vcpu: VCPU,
        registers: inout X86RegisterState
    ) throws {
        switch exit.access {
        case .moveToCR:
            try vcpu.write(controlRegister(exit.controlRegister), registers.read(exit.register))
        case .moveFromCR:
            registers.write(exit.register, value: try vcpu.read(controlRegister(exit.controlRegister)), width: 8)
        case .clts:
            let cr0 = try vcpu.read(HV_X86_CR0)
            try vcpu.write(HV_X86_CR0, cr0 & ~(1 << 3))
        case .lmsw:
            let cr0 = try vcpu.read(HV_X86_CR0)
            var lowBits = UInt64(exit.lmswSourceData & 0xF)
            if cr0 & 1 != 0 {
                lowBits |= 1
            }
            try vcpu.write(HV_X86_CR0, (cr0 & ~0xF) | lowBits)
        }
    }

    private func controlRegister(_ number: UInt8) throws -> hv_x86_reg_t {
        switch number {
        case 0:
            return HV_X86_CR0
        case 3:
            return HV_X86_CR3
        case 4:
            return HV_X86_CR4
        case 8:
            return HV_X86_TPR
        default:
            throw VMError.unexpectedExit("unsupported x86 control register CR\(number)")
        }
    }

    private func handleEPTViolation(
        _ violation: X86EPTViolation,
        vcpu: VCPU,
        registers: inout X86RegisterState
    ) throws -> Int {
        guard violation.read || violation.write else {
            throw VMError.unexpectedExit(
                "x86 EPT violation without read/write at gpa 0x\(String(violation.guestPhysicalAddress, radix: 16))"
            )
        }
        let rip = try vcpu.read(HV_X86_RIP)
        let cr0 = try vcpu.read(HV_X86_CR0)
        let cr3 = try vcpu.read(HV_X86_CR3)
        let instructionBytes: [UInt8]
        do {
            instructionBytes = try X86InstructionFetch.readBytes(
                rip: rip,
                cr0: cr0,
                cr3: cr3,
                count: 15,
                memory: memory
            )
        } catch {
            throw VMError.unexpectedExit(
                "x86 MMIO instruction fetch failed at rip 0x\(String(rip, radix: 16)), gpa 0x\(String(violation.guestPhysicalAddress, radix: 16)): \(error)"
            )
        }
        do {
            let instruction = try X86MMIODecoder.decode(instructionBytes)
            return try X86MMIOExecutor.execute(
                instruction: instruction,
                physicalAddress: violation.guestPhysicalAddress,
                bus: bus,
                registers: &registers
            )
        } catch {
            let hexBytes = instructionBytes.map { String(format: "%02x", $0) }.joined(separator: " ")
            throw VMError.unexpectedExit(
                "x86 MMIO decode failed at rip 0x\(String(rip, radix: 16)), gpa 0x\(String(violation.guestPhysicalAddress, radix: 16)), bytes [\(hexBytes)]: \(error)"
            )
        }
    }
}
#endif

extension GuestStopReason: CustomStringConvertible {
    public var description: String {
        switch self {
        case .powerOff:
            "guest requested power off"
        case .reset:
            "guest requested reset"
        case .crash(let detail):
            "guest crash: \(detail)"
        }
    }
}

private extension Machine {
    /// Copies immutable boot bytes directly into guest RAM without materializing a second
    /// full-sized `[UInt8]` buffer.
    func copyBootData(_ data: Data, at guestAddress: UInt64) throws {
        guard !data.isEmpty else { return }
        let destination = try memory.hostPointer(
            at: guestAddress,
            count: UInt64(data.count)
        )
        data.withUnsafeBytes { source in
            destination.copyMemory(from: source.baseAddress!, byteCount: source.count)
        }
    }
}

public extension Machine {
    var attachedVirtioSlots: [VirtioMMIOSlotIdentity] {
        virtioSlotOwnership.identities
    }

    var virtioMMIOLayoutFingerprintInput: [UInt8] {
        virtioSlotOwnership.fingerprintInput
    }

    @discardableResult
    func attachVirtioSlot(
        _ device: MMIODevice,
        at slot: Int
    ) throws -> VirtioMMIOSlotIdentity {
        try virtioSlotOwnership.attach(device, at: slot) { bus.attach($0) }
    }
}
