public struct DoryARMVirtV1MMIODevice: Sendable, Equatable, Hashable {
  public let slot: Int
  public let baseAddress: UInt64
  public let byteCount: UInt64
  public let spi: UInt32

  public init(slot: Int, baseAddress: UInt64, byteCount: UInt64, spi: UInt32) {
    self.slot = slot
    self.baseAddress = baseAddress
    self.byteCount = byteCount
    self.spi = spi
  }
}

public struct DoryARMVirtV1DeviceTreeConfiguration: Sendable, Equatable {
  public let commandLine: String
  public let memoryBytes: UInt64
  public let vCPUCount: Int
  public let initrdRange: Range<UInt64>?
  public let gicDistributorBytes: UInt64
  public let gicRedistributorRegionBytes: UInt64
  public let gicRedistributorStride: UInt64
  public let virtioDevices: [DoryARMVirtV1MMIODevice]

  public init(
    commandLine: String,
    memoryBytes: UInt64,
    vCPUCount: Int,
    initrdRange: Range<UInt64>? = nil,
    gicDistributorBytes: UInt64,
    gicRedistributorRegionBytes: UInt64,
    gicRedistributorStride: UInt64,
    virtioDevices: [DoryARMVirtV1MMIODevice]
  ) {
    self.commandLine = commandLine
    self.memoryBytes = memoryBytes
    self.vCPUCount = vCPUCount
    self.initrdRange = initrdRange
    self.gicDistributorBytes = gicDistributorBytes
    self.gicRedistributorRegionBytes = gicRedistributorRegionBytes
    self.gicRedistributorStride = gicRedistributorStride
    self.virtioDevices = virtioDevices
  }
}

public enum DoryARMVirtV1DeviceTreeError: Error, Equatable, Sendable {
  case invalidGICLayout
  case invalidInitrdRange
  case invalidVirtioDevice(slot: Int)
  case duplicateVirtioSlot(Int)
}

public enum DoryARMVirtV1DeviceTree {
  public static func build(
    configuration: DoryARMVirtV1DeviceTreeConfiguration
  ) throws -> [UInt8] {
    try DoryARMVirtV1ABI.validateMemoryBytes(configuration.memoryBytes)
    try DoryARMVirtV1ABI.validateVCPUCount(configuration.vCPUCount)
    guard configuration.gicDistributorBytes > 0,
      configuration.gicDistributorBytes <= DoryARMVirtV1ABI.gicDistributorReservedBytes,
      configuration.gicRedistributorRegionBytes > 0,
      configuration.gicRedistributorRegionBytes
        <= DoryARMVirtV1ABI.gicRedistributorReservedBytes,
      configuration.gicRedistributorStride > 0
    else {
      throw DoryARMVirtV1DeviceTreeError.invalidGICLayout
    }

    let ramEnd = DoryARMVirtV1ABI.ramBase + configuration.memoryBytes
    if let initrd = configuration.initrdRange {
      guard initrd.lowerBound >= DoryARMVirtV1ABI.ramBase,
        initrd.lowerBound < initrd.upperBound,
        initrd.upperBound <= ramEnd
      else {
        throw DoryARMVirtV1DeviceTreeError.invalidInitrdRange
      }
    }

    var seenSlots = Set<Int>()
    for device in configuration.virtioDevices {
      guard DoryARMVirtV1ABI.virtioSlots.indices.contains(device.slot),
        seenSlots.insert(device.slot).inserted
      else {
        if seenSlots.contains(device.slot) {
          throw DoryARMVirtV1DeviceTreeError.duplicateVirtioSlot(device.slot)
        }
        throw DoryARMVirtV1DeviceTreeError.invalidVirtioDevice(slot: device.slot)
      }
      let fixed = DoryARMVirtV1ABI.virtioSlots[device.slot]
      guard device.baseAddress == fixed.baseAddress,
        device.byteCount == fixed.byteCount,
        device.spi == fixed.spi
      else {
        throw DoryARMVirtV1DeviceTreeError.invalidVirtioDevice(slot: device.slot)
      }
    }

    let (activeRedistributorBytes, redistributorOverflow) =
      configuration.gicRedistributorStride.multipliedReportingOverflow(
        by: UInt64(configuration.vCPUCount)
      )
    guard !redistributorOverflow else {
      throw DoryARMVirtV1DeviceTreeError.invalidGICLayout
    }
    let advertisedRedistributors = min(
      configuration.gicRedistributorRegionBytes,
      activeRedistributorBytes
    )
    let gicPhandle: UInt32 = 1
    let clockPhandle: UInt32 = 2
    let fdt = DoryFlattenedDeviceTreeBuilder()
    fdt.beginNode("")
    fdt.property("compatible", strings: ["dory,armvirt-1", "linux,dummy-virt"])
    fdt.property("#address-cells", cells: [2])
    fdt.property("#size-cells", cells: [2])
    fdt.property("interrupt-parent", cells: [gicPhandle])

    fdt.beginNode("chosen")
    fdt.property("bootargs", string: configuration.commandLine)
    fdt.property("stdout-path", string: "/pl011@\(String(DoryARMVirtV1ABI.uartBase, radix: 16))")
    if let initrd = configuration.initrdRange {
      fdt.property("linux,initrd-start", cells64: [initrd.lowerBound])
      fdt.property("linux,initrd-end", cells64: [initrd.upperBound])
    }
    fdt.endNode()

    fdt.beginNode("memory@\(String(DoryARMVirtV1ABI.ramBase, radix: 16))")
    fdt.property("device_type", string: "memory")
    fdt.property("reg", cells64: [DoryARMVirtV1ABI.ramBase, configuration.memoryBytes])
    fdt.endNode()

    fdt.beginNode("cpus")
    fdt.property("#address-cells", cells: [1])
    fdt.property("#size-cells", cells: [0])
    for cpu in 0..<configuration.vCPUCount {
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

    fdt.beginNode("intc@\(String(DoryARMVirtV1ABI.gicDistributorBase, radix: 16))")
    fdt.property("compatible", string: "arm,gic-v3")
    fdt.property("#interrupt-cells", cells: [3])
    fdt.property("#address-cells", cells: [2])
    fdt.property("#size-cells", cells: [2])
    fdt.emptyProperty("ranges")
    fdt.emptyProperty("interrupt-controller")
    fdt.property(
      "reg",
      cells64: [
        DoryARMVirtV1ABI.gicDistributorBase, configuration.gicDistributorBytes,
        DoryARMVirtV1ABI.gicRedistributorBase, advertisedRedistributors,
      ])
    fdt.property("phandle", cells: [gicPhandle])
    fdt.endNode()

    fdt.beginNode("timer")
    fdt.property("compatible", string: "arm,armv8-timer")
    fdt.property(
      "interrupts",
      cells: [
        1, DoryARMVirtV1ABI.securePhysicalTimerPPI, 4,
        1, DoryARMVirtV1ABI.nonsecurePhysicalTimerPPI, 4,
        1, DoryARMVirtV1ABI.virtualTimerPPI, 4,
        1, DoryARMVirtV1ABI.hypervisorPhysicalTimerPPI, 4,
      ])
    fdt.endNode()

    fdt.beginNode("apb-pclk")
    fdt.property("compatible", string: "fixed-clock")
    fdt.property("#clock-cells", cells: [0])
    fdt.property("clock-frequency", cells: [24_000_000])
    fdt.property("clock-output-names", string: "clk24mhz")
    fdt.property("phandle", cells: [clockPhandle])
    fdt.endNode()

    fdt.beginNode("pl011@\(String(DoryARMVirtV1ABI.uartBase, radix: 16))")
    fdt.property("compatible", strings: ["arm,pl011", "arm,primecell"])
    fdt.property("reg", cells64: [DoryARMVirtV1ABI.uartBase, DoryARMVirtV1ABI.uartBytes])
    fdt.property("interrupts", cells: [0, DoryARMVirtV1ABI.uartSPI, 4])
    fdt.property("clocks", cells: [clockPhandle, clockPhandle])
    fdt.property("clock-names", strings: ["uartclk", "apb_pclk"])
    fdt.endNode()

    fdt.beginNode("pl031@\(String(DoryARMVirtV1ABI.rtcBase, radix: 16))")
    fdt.property("compatible", strings: ["arm,pl031", "arm,primecell"])
    fdt.property("reg", cells64: [DoryARMVirtV1ABI.rtcBase, DoryARMVirtV1ABI.rtcBytes])
    fdt.property("clocks", cells: [clockPhandle])
    fdt.property("clock-names", strings: ["apb_pclk"])
    fdt.endNode()

    for device in configuration.virtioDevices.sorted(by: { $0.slot < $1.slot }) {
      fdt.beginNode("virtio_mmio@\(String(device.baseAddress, radix: 16))")
      fdt.property("compatible", string: "virtio,mmio")
      fdt.property("reg", cells64: [device.baseAddress, device.byteCount])
      fdt.property("interrupts", cells: [0, device.spi, 1])
      fdt.endNode()
    }

    fdt.endNode()
    return fdt.finish()
  }
}
