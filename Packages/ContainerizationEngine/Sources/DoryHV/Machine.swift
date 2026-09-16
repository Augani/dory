import Darwin
import DoryFirmware
import DoryMachineARMVirt
import DoryOperations
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
  /// Owns a created VM while `Machine` is still being initialized.
  ///
  /// A failed class initializer does not run the enclosing instance's `deinit`, but it does
  /// release initialized stored properties. Keeping the VM in this separate owner therefore
  /// closes the gap between `hvCreateVM()` and a fully initialized `Machine`.
  final class MachineVMOwnership {
    private var destroyVM: (() -> Void)?

    init(createVM: () throws -> Void, destroyVM: @escaping () -> Void) throws {
      try createVM()
      self.destroyVM = destroyVM
    }

    func destroy() {
      destroyVM?()
      destroyVM = nil
    }

    deinit {
      destroy()
    }
  }

  /// Device-wiring view of the frozen `dory.armvirt@1` machine ABI. The ABI package is the sole
  /// authority for guest-visible addresses and interrupt assignments.
  public enum GuestLayout {
    public static let firmwareCodeBase = DoryARMVirtV1ABI.firmwareCodeBase
    public static let firmwareCodeBytes = DoryARMVirtV1ABI.firmwareCodeBytes
    public static let firmwareVariableBase = DoryARMVirtV1ABI.firmwareVariableBase
    public static let firmwareVariableBytes = DoryARMVirtV1ABI.firmwareVariableBytes
    public static let gicDistributorBase = DoryARMVirtV1ABI.gicDistributorBase
    public static let gicRedistributorBase = DoryARMVirtV1ABI.gicRedistributorBase
    public static let uartBase = DoryARMVirtV1ABI.uartBase
    public static let uartIRQ = DoryARMVirtV1ABI.uartSPI
    public static let rtcBase = DoryARMVirtV1ABI.rtcBase
    public static let virtioBase = DoryARMVirtV1ABI.virtioBase
    public static let virtioSlotSize = DoryARMVirtV1ABI.virtioSlotBytes
    public static let virtioSlotCount = DoryARMVirtV1ABI.virtioSlotCount
    public static let virtioFirstIRQ = DoryARMVirtV1ABI.virtioFirstSPI
    public static let ramBase = DoryARMVirtV1ABI.ramBase
    public static let dtbOffset = DoryARMVirtV1ABI.dtbOffset
    public static let initrdOffset = DoryARMVirtV1ABI.initrdOffset
    public static let daxWindowBase = DoryARMVirtV1ABI.daxWindowBase
  }

  public enum MachineARMVirtBoot: Sendable {
    case directLinux(payload: MachineBootPayload, commandLine: String)
    case uefi(
      launchPlan: DoryARMVirtUEFILaunchPlan,
      artifacts: DoryVerifiedFirmwareArtifacts,
      variableStore: DoryUEFIVariableStoreAuthority
    )
  }

  public struct MachineConfiguration {
    public let boot: MachineARMVirtBoot
    public var memoryBytes: UInt64
    public var cpuCount: Int

    public init(
      kernelPath: String,
      initrdPath: String? = nil,
      commandLine: String,
      memoryBytes: UInt64,
      cpuCount: Int
    ) {
      self.boot = .directLinux(
        payload: .legacyPaths(kernel: kernelPath, initrd: initrdPath),
        commandLine: commandLine
      )
      self.memoryBytes = memoryBytes
      self.cpuCount = cpuCount
    }

    public init(
      bootPayload: MachineBootPayload,
      commandLine: String,
      memoryBytes: UInt64,
      cpuCount: Int
    ) {
      self.boot = .directLinux(payload: bootPayload, commandLine: commandLine)
      self.memoryBytes = memoryBytes
      self.cpuCount = cpuCount
    }

    public init(
      uefiLaunchPlan: DoryARMVirtUEFILaunchPlan,
      artifacts: DoryVerifiedFirmwareArtifacts,
      variableStore: DoryUEFIVariableStoreFile,
      memoryBytes: UInt64,
      cpuCount: Int
    ) {
      self.boot = .uefi(
        launchPlan: uefiLaunchPlan,
        artifacts: artifacts,
        variableStore: DoryUEFIVariableStoreAuthority(file: variableStore)
      )
      self.memoryBytes = memoryBytes
      self.cpuCount = cpuCount
    }

    public init(
      uefiLaunchPlan: DoryARMVirtUEFILaunchPlan,
      artifacts: DoryVerifiedFirmwareArtifacts,
      variableStore: DoryUEFIVariableStoreAuthority,
      memoryBytes: UInt64,
      cpuCount: Int
    ) {
      self.boot = .uefi(
        launchPlan: uefiLaunchPlan,
        artifacts: artifacts,
        variableStore: variableStore
      )
      self.memoryBytes = memoryBytes
      self.cpuCount = cpuCount
    }

    func validateDoryARMVirtV1() throws {
      do {
        // Validate the frozen physical address map before hvCreateVM() so a malformed
        // ABI layout fails during configuration admission rather than after allocation.
        try DoryARMVirtV1ABI.validateRegions()
        try DoryARMVirtV1ABI.validateMemoryBytes(memoryBytes)
        try DoryARMVirtV1ABI.validateVCPUCount(cpuCount)
      } catch {
        throw VMError.invalidConfiguration(
          "\(DoryARMVirtV1ABI.identity) resource admission failed: \(error)"
        )
      }
      if case .uefi(let launchPlan, let artifacts, let variableStore) = boot {
        guard launchPlan.firmware == artifacts.manifest else {
          throw VMError.invalidConfiguration(
            "UEFI launch plan and verified firmware manifest differ"
          )
        }
        do {
          let load = try variableStore.load()
          guard load.source == .primary else {
            throw VMError.invalidConfiguration("UEFI variable-store recovery is required")
          }
          guard load.snapshot.generation == launchPlan.variableStoreGeneration else {
            throw VMError.invalidConfiguration(
              "UEFI launch generation \(launchPlan.variableStoreGeneration) does not match store generation \(load.snapshot.generation)"
            )
          }
        } catch let error as VMError {
          throw error
        } catch {
          throw VMError.invalidConfiguration("UEFI variable-store admission failed: \(error)")
        }
      }
    }
  }

  public enum GuestStopReason: Sendable {
    case powerOff
    case reset
    case crash(String)
    case cpuOff
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

  /// Commits a PSCI CPU_ON state transition only when the machine can hand the start tuple to
  /// a live secondary vCPU. `Machine.startSecondary` calls this while holding `teamCondition`,
  /// which also serializes handle removal during vCPU-thread teardown.
  struct ARMPSCISecondaryStartAdmission {
    static let unavailableResult: Int64 = -3  // PSCI_DENIED

    @discardableResult
    static func requestOn(
      state: inout ARMPSCICPUState,
      target: UInt64,
      entry: UInt64,
      executableRanges: [Range<UInt64>],
      isStopping: Bool,
      hasLiveVCPU: (Int) -> Bool
    ) -> (result: Int64, index: Int?) {
      // Validate against a proposal first. This preserves normal PSCI errors (including
      // ALREADY_ON and ON_PENDING), but prevents a rejected start from consuming the off state.
      var proposedState = state
      let result = proposedState.requestOn(
        target: target,
        entry: entry,
        executableRanges: executableRanges
      )
      guard result == 0, let index = proposedState.index(for: target) else {
        return (result, nil)
      }
      guard !isStopping, hasLiveVCPU(index) else {
        return (unavailableResult, nil)
      }
      state = proposedState
      return (0, index)
    }
  }

  /// The virtual machine: RAM, GIC, devices, and the vCPU threads. SMP: secondaries are created
  /// eagerly, parked, and released by PSCI CPU_ON. Thread-shared state is guarded by
  /// `teamCondition`; devices serialize their own guest-facing surfaces.
  public final class Machine: @unchecked Sendable {
    private let vmOwnership: MachineVMOwnership
    public let configuration: MachineConfiguration
    public let memory: GuestMemory
    public let bus = MMIOBus()

    nonisolated static func log(_ message: String) {
      FileHandle.standardError.write(Data("dory-hv: \(message)\n".utf8))
    }
    private var entryPoint: UInt64 = 0
    private var dtbAddress: UInt64 = 0
    private var initialPstate: UInt64 = DoryARMVirtV1InitialCPUState.resetPSTATE
    private let firmwareCode: ARMVirtFirmwareCodeMemory?
    private let variableBridge: ARMVirtUEFIVariableBridgeMMIO?
    private var sysregLogCount = 0
    private let redistributorMMIO: GICRedistributorMMIO
    private let virtioSlotOwnership = VirtioMMIOSlotOwnership(
      maximumSlots: GuestLayout.virtioSlotCount,
      baseAddress: GuestLayout.virtioBase,
      slotSize: GuestLayout.virtioSlotSize,
      firstInterrupt: GuestLayout.virtioFirstIRQ
    )

    public init(configuration: MachineConfiguration) throws {
      try configuration.validateDoryARMVirtV1()
      self.vmOwnership = try MachineVMOwnership(
        createVM: hvCreateVM,
        destroyVM: { _ = hv_vm_destroy() }
      )
      self.configuration = configuration
      switch configuration.boot {
      case .directLinux:
        self.firmwareCode = nil
        self.variableBridge = nil
      case .uefi(_, let artifacts, let variableStore):
        self.firmwareCode = try ARMVirtFirmwareCodeMemory(artifacts: artifacts)
        self.variableBridge = try ARMVirtUEFIVariableBridgeMMIO(store: variableStore)
      }
      self.memory = try GuestMemory(guestBase: GuestLayout.ramBase, size: configuration.memoryBytes)
      try memory.mapIntoGuest()
      try firmwareCode?.mapIntoGuest()
      try Self.createGIC()

      var redistributorStride = 0
      try hvCheck(
        hv_gic_get_redistributor_size(&redistributorStride), "hv_gic_get_redistributor_size")
      let redistributorRegionSize = try Self.gicRedistributorRegionSize()
      let distributorSize = try Self.gicDistributorSize()
      try Self.validateGICLayout(
        distributorBytes: distributorSize,
        redistributorBytes: redistributorRegionSize
      )
      self.redistributorMMIO = GICRedistributorMMIO(
        baseAddress: GuestLayout.gicRedistributorBase,
        size: redistributorRegionSize,
        stride: UInt64(redistributorStride)
      )
      bus.attach(
        GICDistributorMMIO(
          baseAddress: GuestLayout.gicDistributorBase,
          size: distributorSize
        ))
      bus.attach(redistributorMMIO)
      if let variableBridge { bus.attach(variableBridge) }
    }

    deinit {
      try? firmwareCode?.unmapFromGuest()
      vmOwnership.destroy()
    }

    // Dirty tracking (P2-02 item 8):
    //
    // GuestMemory tracks per-page mapping state for free-page-reporting reclamation, but
    // there is no general dirty-bitmap for live snapshots. Guest CPU stores, virtio DMA,
    // filesystem writes and GPU/shared mappings all modify guest RAM through the same
    // shared-memory backing, and none are currently tracked for snapshot purposes.
    // Live snapshots are NOT supported until a dirty-tracking layer covers all writers:
    // CPU stores (via stage-2 write-protect or a soft-dirty bitmap), DMA (via the virtio
    // queue completion path), filesystem (via the virtiofs write path), and GPU shared
    // mappings (via the renderer worker resource lifecycle). The current page-state
    // tracking in GuestMemory is sufficient only for free-page-reporting reclamation.

    private static func createGIC() throws {
      let config = hv_gic_config_create()
      try hvCheck(
        hv_gic_config_set_distributor_base(config, GuestLayout.gicDistributorBase),
        "gic set distributor base")
      try hvCheck(
        hv_gic_config_set_redistributor_base(config, GuestLayout.gicRedistributorBase),
        "gic set redistributor base")
      try hvCheck(hv_gic_create(config), "hv_gic_create")
    }

    public static func gicDistributorSize() throws -> UInt64 {
      var size = 0
      try hvCheck(hv_gic_get_distributor_size(&size), "hv_gic_get_distributor_size")
      return UInt64(size)
    }

    public static func gicRedistributorRegionSize() throws -> UInt64 {
      var size = 0
      try hvCheck(
        hv_gic_get_redistributor_region_size(&size), "hv_gic_get_redistributor_region_size")
      return UInt64(size)
    }

    public static func reservedIntid(_ interrupt: hv_gic_intid_t) throws -> UInt32 {
      var intid: UInt32 = 0
      try hvCheck(hv_gic_get_intid(interrupt, &intid), "hv_gic_get_intid")
      return intid
    }

    static func validateGICLayout(
      distributorBytes: UInt64,
      redistributorBytes: UInt64
    ) throws {
      guard distributorBytes > 0,
        distributorBytes <= DoryARMVirtV1ABI.gicDistributorReservedBytes
      else {
        throw VMError.invalidConfiguration(
          "host GIC distributor size \(distributorBytes) exceeds the \(DoryARMVirtV1ABI.identity) reservation"
        )
      }
      guard redistributorBytes > 0,
        redistributorBytes <= DoryARMVirtV1ABI.gicRedistributorReservedBytes
      else {
        throw VMError.invalidConfiguration(
          "host GIC redistributor size \(redistributorBytes) exceeds the \(DoryARMVirtV1ABI.identity) reservation"
        )
      }
    }

    static func validateTimerInterrupts(
      virtual: UInt32,
      physical: UInt32,
      hypervisor: UInt32
    ) throws {
      let expectedVirtual = 16 + DoryARMVirtV1ABI.virtualTimerPPI
      let expectedPhysical = 16 + DoryARMVirtV1ABI.nonsecurePhysicalTimerPPI
      let expectedHypervisor = 16 + DoryARMVirtV1ABI.hypervisorPhysicalTimerPPI
      guard virtual == expectedVirtual,
        physical == expectedPhysical,
        hypervisor == expectedHypervisor
      else {
        throw VMError.invalidConfiguration(
          "host architectural timer INTIDs \(virtual)/\(physical)/\(hypervisor) do not match \(DoryARMVirtV1ABI.identity) \(expectedVirtual)/\(expectedPhysical)/\(expectedHypervisor)"
        )
      }
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
      switch configuration.boot {
      case .directLinux(let bootPayload, let commandLine):
        try loadDirectLinuxBootPayload(bootPayload, commandLine: commandLine)
      case .uefi(let launchPlan, _, let variableStore):
        let load = try variableStore.load()
        guard load.source == .primary,
          load.snapshot.generation == launchPlan.variableStoreGeneration
        else {
          throw VMError.bootFailure("UEFI variable-store generation changed after admission")
        }
        let attachedSlots = Set(attachedVirtioSlots.map(\.slot))
        let requiredSlots = Set(launchPlan.bootDevices.map(\.virtioSlot))
        guard requiredSlots.isSubset(of: attachedSlots) else {
          throw VMError.bootFailure("UEFI boot devices are not attached at their frozen slots")
        }
        let state = launchPlan.initialCPUState
        dtbAddress = state.x0
        let dtb = try buildDeviceTree(commandLine: "", initrdRange: nil)
        try memory.write(dtb, at: dtbAddress)
        entryPoint = state.programCounter
        initialPstate = state.pstate
      }
    }

    private func loadDirectLinuxBootPayload(
      _ bootPayload: MachineBootPayload,
      commandLine: String
    ) throws {
      try bootPayload.consumeForGuestLoad { kernelData, loadInitrd in
        let kernel = try KernelImage(data: kernelData)
        dtbAddress = GuestLayout.ramBase + GuestLayout.dtbOffset
        // Reserve the DTB and all subsequent boot payload space before copying
        // the kernel; a rejected image must not overwrite those structures.
        entryPoint = try kernel.load(
          into: memory,
          reservedRanges: [dtbAddress..<(GuestLayout.ramBase + configuration.memoryBytes)]
        )
        let initrdRange = try loadInitrdIfPresent(try loadInitrd())
        let dtb = try buildDeviceTree(
          commandLine: commandLine,
          initrdRange: initrdRange
        )
        try memory.write(dtb, at: dtbAddress)
        let state = try DoryARMVirtV1InitialCPUState.directLinux(
          entryPoint: entryPoint,
          deviceTreeAddress: dtbAddress
        )
        initialPstate = state.pstate
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
        end <= GuestLayout.ramBase + configuration.memoryBytes
      else {
        throw VMError.bootFailure("initrd does not fit in guest memory")
      }
      try copyBootData(data, at: start)
      return start..<end
    }

    private func buildDeviceTree(
      commandLine: String,
      initrdRange: Range<UInt64>?
    ) throws -> [UInt8] {
      let virtualTimer = try Self.reservedIntid(HV_GIC_INT_EL1_VIRTUAL_TIMER)
      let physicalTimer = try Self.reservedIntid(HV_GIC_INT_EL1_PHYSICAL_TIMER)
      let hypTimer = try Self.reservedIntid(HV_GIC_INT_EL2_PHYSICAL_TIMER)
      try Self.validateTimerInterrupts(
        virtual: virtualTimer,
        physical: physicalTimer,
        hypervisor: hypTimer
      )
      let distributorSize = try Self.gicDistributorSize()
      let redistributorSize = try Self.gicRedistributorRegionSize()
      return try DoryARMVirtV1DeviceTree.build(
        configuration: .init(
          commandLine: commandLine,
          memoryBytes: configuration.memoryBytes,
          vCPUCount: configuration.cpuCount,
          initrdRange: initrdRange,
          gicDistributorBytes: distributorSize,
          gicRedistributorRegionBytes: redistributorSize,
          gicRedistributorStride: redistributorMMIO.stride,
          virtioDevices: attachedVirtioSlots.map {
            DoryARMVirtV1MMIODevice(
              slot: $0.slot,
              baseAddress: $0.baseAddress,
              byteCount: $0.size,
              spi: $0.interrupt
            )
          }
        ))
    }

    public func attachConsole(_ uart: PL011) {
      bus.attach(uart)
    }

    // MARK: SMP team

    /// Lifecycle rendezvous protocol (P2-02 item 6):
    ///
    /// 1. `requestStop` or an internal crash calls `stopAll`, which publishes the stop reason,
    ///    requests the stop signal, cancels running vCPUs via `hv_vcpus_exit` (exactly once,
    ///    guarded by `vcpusExited`), and calls `executionPause.stop()` to wake parked vCPUs.
    /// 2. Each vCPU's `runLoop` checks `stopSignal.isRequested` at the top of every iteration and
    ///    after `executionPause.enter` returns. A vCPU in `hv_vcpu_run` (including WFI) is woken
    ///    by `hv_vcpus_exit` and returns `.canceled`, which exits the loop.
    /// 3. `cpuMain`'s defer increments `finishedSecondaries` for each secondary and broadcasts
    ///    `teamCondition`. The primary's `run()` method joins all secondaries via
    ///    `while finishedSecondaries < count - 1 { teamCondition.wait() }` before returning.
    /// 4. `Machine.deinit` calls `hv_vm_destroy` only after `run()` has returned, so no live
    ///    vCPU thread races VM teardown.
    ///
    /// Stop works while CPU_ON, WFI, MMIO, renderer or disk I/O is active: `hv_vcpus_exit`
    /// interrupts a vCPU trapped in any of these states, and the stop signal prevents re-entry.
    private let teamCondition = NSCondition()
    private var teamHandles: [hv_vcpu_t?] = []
    private var secondaryStarts: [(entry: UInt64, context: UInt64)?] = []
    private var psciCPUState = ARMPSCICPUState(cpuCount: 1)
    private var stopReason: GuestStopReason?
    private let stopSignal = VCPUStopSignal()
    private var registeredCPUs = 0
    private var finishedSecondaries = 0
    private var vcpusExited = false
    private let executionPause = GuestExecutionPauseCoordinator()
    private var pauseExitRequests: Set<hv_vcpu_t> = []
    /// Access is serialized by `teamCondition`. See `MappedPageFaultRetryBudget` for why an
    /// already-mapped stage-2 fault cannot be retried indefinitely.
    private var mappedPageFaultRetryBudget = MappedPageFaultRetryBudget()

    /// Clock semantics (P2-02 item 7):
    ///
    /// The ARM architectural timer is backed by Hypervisor.framework's virtual timer. The guest
    /// programs CNTV_TVAL_EL0 / CNTV_CTL_EL0 and the framework delivers the virtual timer PPI
    /// (INTID 27) through the in-kernel GIC. `hv_vcpu_run` blocks on WFI until an interrupt
    /// arrives, so the guest idle loop does not busy-poll.
    ///
    /// Guest time advances during host sleep and pause: Hypervisor.framework's virtual timer
    /// is driven by the host monotonic clock, and `hv_vcpu_run` resumes when the timer fires.
    /// During a `pauseGuestExecution` the vCPU is blocked in `executionPause.enter`, so the
    /// virtual timer may fire and pend; on resume the pending interrupt is delivered. This
    /// means guest wall-clock time advances during pause, which matches the Linux guest's
    /// expectation that `CNTVCT_EL0` tracks real time. A future live-snapshot feature must
    /// decide whether to freeze the virtual timer during snapshot capture.
    /// The device tree advertises a 24 MHz fixed clock for the APB peripheral bus; the
    /// architectural counter frequency is set by Hypervisor.framework from the host.

    public var executionState: DoryVirtualMachineState { executionPause.state }

    public func pauseGuestExecution() throws {
      try executionPause.pause { [self] in
        teamCondition.lock()
        defer { teamCondition.unlock() }
        var handles = teamHandles.compactMap { $0 }
        pauseExitRequests.formUnion(handles)
        if !handles.isEmpty { hv_vcpus_exit(&handles, UInt32(handles.count)) }
      }
    }

    public func resumeGuestExecution() throws { try executionPause.resume() }

    /// Boots the guest with `configuration.cpuCount` vCPUs. Every vCPU gets a dedicated thread
    /// (Hypervisor.framework requires create/run/destroy on one thread); secondaries are created
    /// up front so the kernel's redistributor walk sees all GIC frames, then parked until PSCI
    /// CPU_ON. The calling thread becomes the boot CPU. Returns when the guest stops.
    public func run() throws -> GuestStopReason {
      // Attachment is a cold boot operation. Freeze the sorted routing table before any vCPU
      // can read it concurrently, and give each vCPU its own hot lookup cache in `runLoop`.
      bus.seal()
      let count = max(1, configuration.cpuCount)
      // requestStop can arrive as the owner thread begins running. Publish the
      // team arrays under the same lock used by stop/pause and handle teardown.
      teamCondition.withLock {
        teamHandles = Array(repeating: nil, count: count)
        secondaryStarts = Array(repeating: nil, count: count)
        psciCPUState = ARMPSCICPUState(cpuCount: count)
      }

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
      let terminalReason = teamCondition.withLock {
        stopReason ?? .crash("boot CPU exited without a published stop reason")
      }
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
        let initialSCTLR = try (index == 0 ? 0 : vcpu.readSystem(HV_SYS_REG_SCTLR_EL1))
        let redistributorFrameIndex = register(vcpu: vcpu, index: index)
        defer {
          // Pin the owner until both exit requests and redistributor MMIO have drained.
          withExtendedLifetime(vcpu) {
            teamCondition.withLock {
              teamHandles[index] = nil
              pauseExitRequests.remove(vcpu.handle)
            }
            // Never hold teamCondition while waiting for the redistributor access lock.
            redistributorMMIO.removeHandle(vcpu.handle, at: redistributorFrameIndex)
          }
        }

        if index == 0 {
          try vcpu.write(HV_REG_CPSR, initialPstate)
          try vcpu.write(HV_REG_PC, entryPoint)
          try vcpu.write(HV_REG_X0, dtbAddress)
          try vcpu.write(HV_REG_X1, 0)
          try vcpu.write(HV_REG_X2, 0)
          try vcpu.write(HV_REG_X3, 0)
          _ = runLoop(vcpu: vcpu, index: index)
        } else {
          while let start = parkUntilStarted(index: index) {
            try vcpu.write(HV_REG_CPSR, 0x3C5)
            try vcpu.write(HV_REG_PC, start.entry)
            try vcpu.write(HV_REG_X0, start.context)
            let canRun = teamCondition.withLock {
              guard stopReason == nil else { return false }
              psciCPUState.completeOn(index: index)
              return true
            }
            guard canRun else { return }
            // CPU_OFF parks this already-created vCPU so a later CPU_ON can
            // resume it. Any terminal run-loop outcome exits the host thread.
            guard runLoop(vcpu: vcpu, index: index) else { return }
            // A retained vCPU must enter the next physical entry address with its
            // original translation/cache controls and without the previous virtual timer.
            // Finish every fallible operation BEFORE publishing OFF: after that point a
            // concurrent CPU_ON may enqueue a tuple that this same owner must consume.
            try vcpu.writeSystem(HV_SYS_REG_SCTLR_EL1, initialSCTLR)
            try vcpu.writeSystem(HV_SYS_REG_CNTV_CTL_EL0, 0)
            try vcpu.setVTimerMask(false)
            let canPark = teamCondition.withLock {
              guard stopReason == nil else { return false }
              let result = psciCPUState.requestOff(index: index)
              precondition(result == 0)
              return true
            }
            guard canPark else { return }
          }
        }
      } catch {
        stopAll(.crash("cpu\(index) failed: \(error)"))
      }
    }

    private func register(vcpu: VCPU, index: Int) -> Int {
      // Map this vCPU to its redistributor frame by the base the GIC actually assigned it,
      // rather than assuming creation order.
      var redistributorBase: hv_ipa_t = 0
      var frameIndex = index
      if hv_gic_get_redistributor_base(vcpu.handle, &redistributorBase) == HV_SUCCESS,
        redistributorMMIO.stride > 0
      {
        frameIndex = Int(
          (redistributorBase - GuestLayout.gicRedistributorBase) / redistributorMMIO.stride)
      }
      // Publish the frame before announcing readiness, without nesting the two locks.
      redistributorMMIO.setHandle(vcpu.handle, at: frameIndex)
      teamCondition.lock()
      teamHandles[index] = vcpu.handle
      if index != 0 { registeredCPUs += 1 }
      teamCondition.broadcast()
      teamCondition.unlock()
      return frameIndex
    }

    private func parkUntilStarted(index: Int) -> (entry: UInt64, context: UInt64)? {
      teamCondition.lock()
      defer { teamCondition.unlock() }
      while secondaryStarts[index] == nil, stopReason == nil {
        teamCondition.wait()
      }
      // Stop wins over an accepted but not yet consumed start request.
      guard stopReason == nil else {
        secondaryStarts[index] = nil
        return nil
      }
      let start = secondaryStarts[index]
      secondaryStarts[index] = nil
      return start
    }

    private func stopAll(_ reason: GuestStopReason) {
      executionPause.stop()
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
      if !handles.isEmpty {
        hv_vcpus_exit(&handles, UInt32(handles.count))
      }
      teamCondition.unlock()
      if publishesReason {
        FileHandle.standardError.write(
          Data("dory-hv: guest stop reason: \(reason)\n".utf8)
        )
      }
    }

    private func startSecondary(mpidr: UInt64, entry: UInt64, context: UInt64) -> Int64 {
      teamCondition.lock()
      defer { teamCondition.unlock() }
      var executableRanges = [GuestLayout.ramBase..<(GuestLayout.ramBase + configuration.memoryBytes)]
      if firmwareCode != nil {
        executableRanges.append(
          GuestLayout.firmwareCodeBase..<(GuestLayout.firmwareCodeBase + GuestLayout.firmwareCodeBytes)
        )
      }
      let admission = ARMPSCISecondaryStartAdmission.requestOn(
        state: &psciCPUState,
        target: mpidr, entry: entry,
        executableRanges: executableRanges,
        isStopping: stopReason != nil,
        hasLiveVCPU: { teamHandles[$0] != nil }
      )
      guard admission.result == 0, let index = admission.index else { return admission.result }
      secondaryStarts[index] = (entry: entry, context: context)
      teamCondition.broadcast()
      return 0
    }

    /// Returns true when a secondary requests PSCI CPU_OFF. Its owner prepares the
    /// retained vCPU before publishing OFF and parking. All other exits are terminal.
    private func runLoop(vcpu: VCPU, index: Int) -> Bool {
      // WFI / idle waiting (P2-02 item 5):
      // `hv_vcpu_run` blocks inside Hypervisor.framework when the guest executes WFI; it
      // returns only when an interrupt (SPI, PPI, SGI, or virtual timer) is pending or when
      // `hv_vcpus_exit` cancels the run. The guest idle loop therefore never busy-polls.
      // Device IRQs, timer PPIs, and stop/pause requests all wake the correct vCPU:
      //   - Device IRQs and timer PPIs are delivered by the in-kernel GIC, which wakes the
      //     specific vCPU that has the interrupt targeted.
      //   - Stop calls `hv_vcpus_exit`, which cancels all running vCPUs and returns `.canceled`.
      //   - Pause adds the vCPU handle to `pauseExitRequests`, calls `hv_vcpus_exit`, and the
      //     `.canceled` handler below checks `pauseExitRequests` to distinguish pause from stop.
      var mmioRouteCache = MMIORouteCache()
      while true {
        if stopSignal.isRequested { return false }

        do {
          guard try executionPause.enter(participant: index) else { return false }
          defer { executionPause.leave(participant: index) }
          if stopSignal.isRequested { return false }
          let event = try vcpu.run()
          switch event {
          case .canceled:
            let requestedForPause = teamCondition.withLock {
              pauseExitRequests.remove(vcpu.handle) != nil
            }
            if requestedForPause, !stopSignal.isRequested { continue }
            if !stopSignal.isRequested {
              stopAll(
                .crash(
                  "cpu\(index) Hypervisor run was canceled without a stop request"
                ))
            }
            return false
          case .vtimerActivated:
            // With the in-kernel GIC the timer PPI is delivered by the GIC itself; unmask
            // and continue so the vtimer can fire again.
            try vcpu.setVTimerMask(false)
          case .exception(let syndrome, let virtualAddress, let physicalAddress):
            if let stop = try handleException(
              vcpu: vcpu,
              vcpuIndex: index,
              syndrome: syndrome,
              virtualAddress: virtualAddress,
              physicalAddress: physicalAddress,
              mmioRouteCache: &mmioRouteCache
            ) {
              if case .cpuOff = stop {
                // Leave PSCI state ON until cpuMain finishes preparing the retained
                // vCPU. No CPU_ON may succeed while that preparation can still fail.
                return true
              }
              stopAll(stop)
              return false
            }
          case .unknown(let raw):
            stopAll(.crash("unknown exit reason \(raw)"))
            return false
          }
        } catch {
          stopAll(.crash("\(error)"))
          return false
        }
      }
    }

    private func handleException(
      vcpu: VCPU,
      vcpuIndex: Int,
      syndrome: UInt64,
      virtualAddress: UInt64,
      physicalAddress: UInt64,
      mmioRouteCache: inout MMIORouteCache
    ) throws -> GuestStopReason? {
      guard let exceptionClass = ExceptionClass(syndrome: syndrome) else {
        // Guest-fault injection: unknown exception class — inject SError instead
        // of crashing the VM.
        let pc = try vcpu.read(HV_REG_PC)
        Self.log("unhandled exception class \(syndrome >> 26), syndrome 0x\(String(syndrome, radix: 16)), pc 0x\(String(pc, radix: 16)) — injecting SError")
        try vcpu.injectSError()
        return nil
      }
      switch exceptionClass {
      case .dataAbortLowerEL:
        try handleMMIO(
          vcpu: vcpu,
          vcpuIndex: vcpuIndex,
          syndrome: syndrome,
          virtualAddress: virtualAddress,
          physicalAddress: physicalAddress,
          routeCache: &mmioRouteCache
        )
        return nil
      case .instructionAbortLowerEL:
        switch restoreIfReleasedRAM(physicalAddress) {
        case .restored:
          resolveMappedPageFault(vcpuIndex: vcpuIndex, physicalAddress: physicalAddress)
          return nil
        case .alreadyMapped:
          guard retryMappedPageFault(vcpuIndex: vcpuIndex, physicalAddress: physicalAddress)
          else {
            Self.log("instruction abort kept faulting on mapped RAM at pa 0x\(String(physicalAddress, radix: 16)) — injecting SError")
            try vcpu.injectSError()
            return nil
          }
          return nil
        case .notReleased:
          resolveMappedPageFault(vcpuIndex: vcpuIndex, physicalAddress: physicalAddress)
          // Guest-fault injection: instruction abort outside RAM — inject SError
          // instead of crashing the VM.
          Self.log("instruction abort outside RAM at pa 0x\(String(physicalAddress, radix: 16)) — injecting SError")
          try vcpu.injectSError()
          return nil
        case .restoreFailed:
          resolveMappedPageFault(vcpuIndex: vcpuIndex, physicalAddress: physicalAddress)
          // Restore attempt failed — inject SError so the guest can handle the fault.
          Self.log("instruction abort RAM restore failed at pa 0x\(String(physicalAddress, radix: 16)) — injecting SError")
          try vcpu.injectSError()
          return nil
        }
      case .hvc64:
        try vcpu.write(HV_REG_X0, SMCCC.result(
          function: UInt32(truncatingIfNeeded: try vcpu.read(HV_REG_X0)),
          argument: try vcpu.read(HV_REG_X1)))
        return nil
      case .smc64:
        let result = try handleSMC(vcpu: vcpu)
        // Successful CPU_OFF never returns to the old instruction stream. In particular,
        // do not perform a fallible PC update after committing a power-state transition.
        if case .cpuOff? = result { return result }
        try advancePC(vcpu)
        return result
      case .systemRegisterTrap:
        if try handleSystemRegisterTrap(vcpu: vcpu, syndrome: syndrome) {
          try advancePC(vcpu)
        }
        return nil
      case .floatingPointSIMD, .illegalExecutionState, .branchTarget, .breakpointLowerEL:
        // These are architecturally guest-visible synchronous exceptions. The
        // current virtual CPU does not emulate the optional facility that made
        // them trap, so deliver an SError to the guest instead of converting a
        // guest fault into a host-side VM termination.
        let pc = try vcpu.read(HV_REG_PC)
        Self.log("guest exception class \(exceptionClass.rawValue) at pc 0x\(String(pc, radix: 16)) — injecting SError")
        try vcpu.injectSError()
        return nil
      }
    }

    private func handleMMIO(
      vcpu: VCPU,
      vcpuIndex: Int,
      syndrome: UInt64,
      virtualAddress: UInt64,
      physicalAddress: UInt64,
      routeCache: inout MMIORouteCache
    ) throws {
      switch restoreIfReleasedRAM(physicalAddress) {
      case .restored:
        resolveMappedPageFault(vcpuIndex: vcpuIndex, physicalAddress: physicalAddress)
        return
      case .alreadyMapped:
        guard retryMappedPageFault(vcpuIndex: vcpuIndex, physicalAddress: physicalAddress)
        else {
          Self.log("data abort kept faulting on mapped RAM at pa 0x\(String(physicalAddress, radix: 16)) — injecting synchronous external data abort")
          try injectSynchronousExternalDataAbort(vcpu: vcpu, virtualAddress: virtualAddress)
          return
        }
        return
      case .notReleased:
        resolveMappedPageFault(vcpuIndex: vcpuIndex, physicalAddress: physicalAddress)
        break  // Not a released RAM page — fall through to MMIO device lookup.
      case .restoreFailed:
        resolveMappedPageFault(vcpuIndex: vcpuIndex, physicalAddress: physicalAddress)
        // RAM restore failed — make the fault visible to the guest instead of terminating the VM.
        Self.log("RAM restore failed at pa 0x\(String(physicalAddress, radix: 16)) — injecting synchronous external data abort")
        try injectSynchronousExternalDataAbort(vcpu: vcpu, virtualAddress: virtualAddress)
        return
      }
      let abort = DataAbortInfo(syndrome: syndrome)
      guard abort.isValid else {
        let pc = try vcpu.read(HV_REG_PC)
        // ISV=0 means Hypervisor.framework could not provide a decodable
        // load/store syndrome (for example an atomic or paired access). There
        // is no safe way to synthesize the register side effects, so preserve
        // the guest-visible fault rather than crashing the entire VM.
        Self.log("data abort without syndrome info at pa 0x\(String(physicalAddress, radix: 16)), pc 0x\(String(pc, radix: 16)) — injecting synchronous external data abort")
        try injectSynchronousExternalDataAbort(vcpu: vcpu, virtualAddress: virtualAddress)
        return
      }
      guard let (device, offset) = bus.device(for: physicalAddress, cache: &routeCache) else {
        // Guest-fault injection: instead of terminating the VM on an unmapped MMIO
        // access, take a synchronous external data abort to EL1 so the guest's own
        // handler can log, retry, or panic without losing the entire VM.
        let pc = try vcpu.read(HV_REG_PC)
        Self.log("guest touched unmapped pa 0x\(String(physicalAddress, radix: 16)), pc 0x\(String(pc, radix: 16)) — injecting synchronous external data abort")
        try injectSynchronousExternalDataAbort(vcpu: vcpu, virtualAddress: virtualAddress)
        return
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
        try vcpu.write(HV_REG_X0, PSCIPolicy.featuresResult(for: queried))
      case PSCI.migrateInfoType:
        try vcpu.write(HV_REG_X0, 2)  // migration not required
      case PSCI.systemOff:
        return .powerOff
      case PSCI.systemReset:
        return .reset
      case PSCI.cpuSuspend, PSCI.cpuSuspend32:
        // PSCI 1.0 CPU_SUSPEND: the calling CPU enters a power state and is resumed by an
        // interrupt.  DoryHV does not implement the complete suspend/resume state
        // transition (power-state validation, resume entry, context save/restore), so
        // advertising it as a successful no-op would be untruthful.  The SMC handler
        // explicitly rejects CPU_SUSPEND with SMCCC/PSCI NOT_SUPPORTED (-1 in X0) and
        // performs no CPU state transition.  WFI remains the only supported idle
        // mechanism: the Hypervisor.framework run loop blocks the calling vCPU until an
        // interrupt arrives.
        try vcpu.write(HV_REG_X0, PSCIPolicy.cpuSuspendResult)
      case PSCI.cpuOff:
        // PSCI 1.0 CPU_OFF: the calling CPU is turned off.  Unlike CPU_SUSPEND, this is a
        // one-way operation — the CPU can only be brought back by CPU_ON.  Secondary vCPUs
        // exit their run loop; CPU 0 is rejected because the primary must use SYSTEM_OFF.
        let isPrimary = teamCondition.withLock { teamHandles[0] == vcpu.handle }
        if isPrimary {
          try vcpu.write(HV_REG_X0, PSCIPolicy.denied)
        } else {
          let cpuIndex = teamCondition.withLock {
            (teamHandles.firstIndex { $0 == vcpu.handle }) ?? -1
          }
          let result = teamCondition.withLock {
            // Validate only. cpuMain commits OFF once the retained worker is ready for
            // another start; publishing it here would race fallible exit preparation.
            var proposedState = psciCPUState
            return cpuIndex >= 0 ? proposedState.requestOff(index: cpuIndex) : -3
          }
          if result == 0 {
            return .cpuOff
          } else {
            try vcpu.write(HV_REG_X0, UInt64(bitPattern: result))
          }
        }
      case PSCI.cpuOn, PSCI.cpuOn32:
        let mask: UInt64 = function == PSCI.cpuOn32 ? 0xFFFF_FFFF : .max
        let target = try vcpu.read(HV_REG_X1) & mask
        let entry = try vcpu.read(HV_REG_X2) & mask
        let context = try vcpu.read(HV_REG_X3) & mask
        let result = startSecondary(mpidr: target, entry: entry, context: context)
        try vcpu.write(HV_REG_X0, UInt64(bitPattern: Int64(result)))
      case PSCI.affinityInfo, PSCI.affinityInfo32:
        let mask: UInt64 = function == PSCI.affinityInfo32 ? 0xFFFF_FFFF : .max
        let target = try vcpu.read(HV_REG_X1) & mask
        let lowestLevel = try vcpu.read(HV_REG_X2) & mask
        let result = teamCondition.withLock {
          psciCPUState.affinityInfo(target: target, lowestLevel: lowestLevel)
        }
        try vcpu.write(HV_REG_X0, UInt64(bitPattern: result))
      default:
        try vcpu.write(HV_REG_X0, UInt64(bitPattern: -1))
      }
      return nil
    }

    /// Returns true when the trapped instruction should retire (RAZ/WI). False means an
    /// UNDEFINED exception was delivered and PC already points at the vector.
    private func handleSystemRegisterTrap(vcpu: VCPU, syndrome: UInt64) throws -> Bool {
      let trap = ARMSystemRegisterTrap(syndrome: syndrome)
      let shouldLog = teamCondition.withLock {
        guard sysregLogCount < 8 else { return false }
        sysregLogCount += 1
        return true
      }
      if shouldLog {
        let action = trap.disposition == .readAsZeroWriteIgnore ? "RAZ/WI" : "UNDEFINED"
        FileHandle.standardError.write(
          Data(
            "dory-hv: sysreg trap (\(trap.isRead ? "read" : "write")) \(trap.encodingDescription), \(action)\n"
              .utf8))
      }
      switch trap.disposition {
      case .readAsZeroWriteIgnore:
        if trap.isRead && trap.registerIndex != 31 {
          try vcpu.write(registerFor(trap.registerIndex), 0)
        }
        return true
      case .undefined:
        try injectUndefinedInstruction(vcpu: vcpu)
        return false
      }
    }

    /// Take a 32-bit UNDEFINED exception to EL1. Used when a trapped encoding is not in the
    /// reviewed RAZ/WI set, so the guest cannot observe a successful zeroed ID/timer register.
    private func injectUndefinedInstruction(vcpu: VCPU) throws {
      let pc = try vcpu.read(HV_REG_PC)
      let cpsr = try vcpu.read(HV_REG_CPSR)
      let vbar = try vcpu.readSystem(HV_SYS_REG_VBAR_EL1)
      let sctlr = try vcpu.readSystem(HV_SYS_REG_SCTLR_EL1)
      let pfr1 = try vcpu.readSystem(HV_SYS_REG_ID_AA64PFR1_EL1)
      let vectorOffset = ARMUndefinedInstructionEntry.vectorOffset(cpsr: cpsr)
      try vcpu.writeSystem(HV_SYS_REG_ELR_EL1, pc)
      try vcpu.writeSystem(HV_SYS_REG_SPSR_EL1, cpsr)
      // EC=0x00 unknown/undefined, IL=1 (A64 instruction).
      try vcpu.writeSystem(HV_SYS_REG_ESR_EL1, 1 << 25)
      try vcpu.write(HV_REG_CPSR, ARMUndefinedInstructionEntry.pstate(
        cpsr: cpsr, sctlr: sctlr, hasMTE: (pfr1 >> 8) & 0xF != 0))
      try vcpu.write(HV_REG_PC, vbar &+ vectorOffset)
    }

    /// Take a synchronous external data abort to EL1. This is used for host-visible data faults
    /// that have no safe device emulation path; the faulting PC is preserved in ELR_EL1 and FAR
    /// reports the VA supplied by Hypervisor.framework.
    private func injectSynchronousExternalDataAbort(
      vcpu: VCPU,
      virtualAddress: UInt64
    ) throws {
      let pc = try vcpu.read(HV_REG_PC)
      let cpsr = try vcpu.read(HV_REG_CPSR)
      let vbar = try vcpu.readSystem(HV_SYS_REG_VBAR_EL1)
      let sctlr = try vcpu.readSystem(HV_SYS_REG_SCTLR_EL1)
      let pfr1 = try vcpu.readSystem(HV_SYS_REG_ID_AA64PFR1_EL1)
      try vcpu.writeSystem(HV_SYS_REG_ELR_EL1, pc)
      try vcpu.writeSystem(HV_SYS_REG_SPSR_EL1, cpsr)
      try vcpu.writeSystem(HV_SYS_REG_ESR_EL1, ARMGuestSynchronousFault.externalDataAbortESR)
      try vcpu.writeSystem(HV_SYS_REG_FAR_EL1, virtualAddress)
      try vcpu.write(HV_REG_CPSR, ARMUndefinedInstructionEntry.pstate(
        cpsr: cpsr, sctlr: sctlr, hasMTE: (pfr1 >> 8) & 0xF != 0))
      try vcpu.write(HV_REG_PC, vbar &+ ARMUndefinedInstructionEntry.vectorOffset(cpsr: cpsr))
    }

    /// A fault inside the RAM window MIGHT be the guest touching a page that free page reporting
    /// returned to macOS. restorePage remaps it and returns the tri-state result so the caller
    /// can distinguish a successful restore (retry the instruction) from a genuine fault (inject
    /// SError) from a restore failure (retry with escalation, then inject SError).
    private func restoreIfReleasedRAM(_ physicalAddress: UInt64) -> GuestMemory.RestorePageResult {
      memory.restorePage(guestAddress: physicalAddress)
    }

    private func retryMappedPageFault(vcpuIndex: Int, physicalAddress: UInt64) -> Bool {
      teamCondition.withLock {
        mappedPageFaultRetryBudget.retryAlreadyMapped(
          vcpuIndex: vcpuIndex,
          physicalAddress: physicalAddress
        )
      }
    }

    private func resolveMappedPageFault(vcpuIndex: Int, physicalAddress: UInt64) {
      teamCondition.withLock {
        mappedPageFaultRetryBudget.resolve(
          vcpuIndex: vcpuIndex,
          physicalAddress: physicalAddress
        )
      }
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
    static let cpuSuspend: UInt32 = 0xC400_0001
    static let cpuSuspend32: UInt32 = 0x8400_0001
    static let cpuOff: UInt32 = 0x8400_0002
    static let cpuOn: UInt32 = 0xC400_0003
    static let cpuOn32: UInt32 = 0x8400_0003
    static let affinityInfo: UInt32 = 0xC400_0004
    static let affinityInfo32: UInt32 = 0x8400_0004
    static let migrateInfoType: UInt32 = 0x8400_0006
    static let systemOff: UInt32 = 0x8400_0008
    static let systemReset: UInt32 = 0x8400_0009
    static let features: UInt32 = 0x8400_000A
  }

  /// SMCCC 1.1 discovery surface for Linux running at EL1 through HVC.
  ///
  /// Dory has no secure monitor and no physical SoC firmware to expose. It nevertheless answers
  /// the standard discovery calls so Linux does not repeatedly probe an absent conduit. The three
  /// speculation-mitigation calls are explicitly `NOT_REQUIRED`: generated guest code executes on
  /// the host under Dory's Hypervisor.framework process boundary, not on a pass-through CPU.
  enum SMCCC {
    static let version: UInt32 = 0x8000_0000
    static let architectureFeatures: UInt32 = 0x8000_0001
    static let architectureSoCID: UInt32 = 0x8000_0002
    static let architectureSoCID64: UInt32 = 0xC000_0002
    static let architectureWorkaround1: UInt32 = 0x8000_8000
    static let architectureWorkaround2: UInt32 = 0x8000_7FFF
    static let architectureWorkaround3: UInt32 = 0x8000_3FFF

    static let success: UInt64 = 0
    static let notSupported: UInt64 = UInt64(bitPattern: -1)
    static let notRequired: UInt64 = UInt64(bitPattern: -2)
    static let version1_1: UInt64 = 0x0001_0001

    /// Implementation-defined virtual SoC identity: `DR` (Dory) with ARM board ABI revision 1.
    static let virtualSoCVersion: UInt64 = 0x4452_0001
    static let virtualSoCRevision: UInt64 = 0

    static func result(function: UInt32, argument: UInt64) -> UInt64 {
      switch function {
      case version:
        return version1_1
      case architectureFeatures:
        switch UInt32(truncatingIfNeeded: argument) {
        case version, architectureFeatures, architectureSoCID, architectureSoCID64:
          return success
        case architectureWorkaround1, architectureWorkaround2, architectureWorkaround3:
          return notRequired
        default:
          return notSupported
        }
      case architectureSoCID, architectureSoCID64:
        switch argument {
        case 0: return virtualSoCVersion
        case 1: return virtualSoCRevision
        default: return notSupported
        }
      case architectureWorkaround1, architectureWorkaround2, architectureWorkaround3:
        return notRequired
      default:
        return notSupported
      }
    }
  }

  /// Advertised PSCI function set and CPU_SUSPEND return policy.
  ///
  /// DoryHV does not implement the complete PSCI CPU_SUSPEND suspend/resume state
  /// transition (power-state validation, resume entry, context save/restore).
  /// Rather than advertising CPU_SUSPEND as a successful no-op, the SMC handler
  /// explicitly rejects it with SMCCC/PSCI NOT_SUPPORTED.  WFI remains the only
  /// supported idle mechanism: the Hypervisor.framework run loop blocks the
  /// calling vCPU until an interrupt arrives.
  ///
  /// This helper centralizes the advertised function set and the CPU_SUSPEND
  /// result policy so they can be unit-tested without a live Hypervisor.framework
  /// VM/vCPU, which is unavailable in unit tests.
  enum PSCIPolicy {
    /// SMCCC NOT_SUPPORTED, encoded as -1 in X0 (PSCI return code).
    static let notSupported: UInt64 = UInt64(bitPattern: -1)

    /// PSCI_SUCCESS, encoded as 0 in X0.
    static let success: UInt64 = 0

    /// PSCI_DENIED, encoded as -3 in X0. The primary CPU cannot be powered
    /// off independently and a CPU that is not online cannot satisfy CPU_OFF.
    static let denied: UInt64 = UInt64(bitPattern: -3)

    /// PSCI function IDs advertised as supported through PSCI_FEATURES.
    ///
    /// CPU_SUSPEND/CPU_SUSPEND32 are deliberately excluded until a complete
    /// suspend/resume state transition is implemented and validated.  Every
    /// identifier here is answered with 0 (success) by PSCI_FEATURES.
    static let advertisedFunctions: Set<UInt32> = [
      PSCI.version, PSCI.features, PSCI.systemOff, PSCI.systemReset,
      PSCI.cpuOn, PSCI.cpuOn32, PSCI.affinityInfo, PSCI.affinityInfo32,
      PSCI.migrateInfoType, PSCI.cpuOff,
    ]

    /// Returns the PSCI_FEATURES result for `function`: 0 (success) when the
    /// function is advertised, NOT_SUPPORTED otherwise.
    static func featuresResult(for function: UInt32) -> UInt64 {
      advertisedFunctions.contains(function) ? success : notSupported
    }

    /// Returns true when `function` is a CPU_SUSPEND identifier (32- or 64-bit
    /// calling convention).  These are deliberately rejected.
    static func isCpuSuspend(_ function: UInt32) -> Bool {
      function == PSCI.cpuSuspend || function == PSCI.cpuSuspend32
    }

    /// CPU_SUSPEND return policy: NOT_SUPPORTED, with no CPU state transition.
    /// The SMC handler writes this to X0 and performs no suspension.
    static let cpuSuspendResult: UInt64 = notSupported
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
    case cpuOff
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
          switch memory.restorePage(guestAddress: violation.guestPhysicalAddress) {
          case .restored, .alreadyMapped:
            continue
          case .notReleased:
            break  // Not a released RAM page — fall through to EPT violation handler.
          case .restoreFailed:
            throw VMError.unexpectedExit(
              "x86 EPT violation RAM restore failed at gpa 0x\(String(violation.guestPhysicalAddress, radix: 16))"
            )
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
        registers.write(
          exit.register, value: try vcpu.read(controlRegister(exit.controlRegister)), width: 8)
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
    case .cpuOff:
      "secondary vCPU requested PSCI CPU_OFF"
    }
  }
}

extension Machine {
  /// Copies immutable boot bytes directly into guest RAM without materializing a second
  /// full-sized `[UInt8]` buffer.
  fileprivate func copyBootData(_ data: Data, at guestAddress: UInt64) throws {
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

extension Machine {
  public var attachedVirtioSlots: [VirtioMMIOSlotIdentity] {
    virtioSlotOwnership.identities
  }

  public var virtioMMIOLayoutFingerprintInput: [UInt8] {
    virtioSlotOwnership.fingerprintInput
  }

  @discardableResult
  public func attachVirtioSlot(
    _ device: MMIODevice,
    at slot: Int
  ) throws -> VirtioMMIOSlotIdentity {
    try virtioSlotOwnership.attach(device, at: slot) { bus.attach($0) }
  }
}
