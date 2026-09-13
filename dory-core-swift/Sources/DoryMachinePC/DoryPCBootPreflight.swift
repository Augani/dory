import Foundation

/// A deterministic, side-effect-free plan describing where a direct-kernel PVH boot would place
/// its kernel segments and PVH handoff artifacts in guest-physical memory.
///
/// Produced by ``DoryPCBootPreflight`` after validating raw ELF64 and Linux x86 PVH
/// boot-protocol payload placement, before any machine, RAM, or firmware variable store is
/// constructed or mutated. ACPI and SMBIOS table placement is planned separately by the machine
/// after preflight; this plan does not claim UEFI installer qualification.
public struct DoryPCBootPreflightPlan: Sendable, Hashable {
  /// The PVH `PHYS32_ENTRY` note physical entry point, validated to name file bytes of a load
  /// segment whose physical range lies within guest RAM.
  public let entryPoint: UInt64
  /// Loadable ELF64 program segments (`PT_LOAD` with `memorySize > 0`), in file order.
  public let kernelSegments: [DoryPCPVHKernelSegment]
  /// Guest-physical ranges that the kernel segments would occupy, including BSS, sorted by
  /// physical address. Every range is contained within a `ram` memory-map entry.
  public let kernelRanges: [Range<UInt64>]
  /// Guest-physical ranges that the PVH handoff artifacts (start info, command line, modules,
  /// memory map, initrd) would occupy, sorted by physical address. Excludes ACPI and SMBIOS
  /// tables, which are planned by the machine after preflight.
  public let bootArtifactRanges: [Range<UInt64>]

  public init(
    entryPoint: UInt64,
    kernelSegments: [DoryPCPVHKernelSegment],
    kernelRanges: [Range<UInt64>],
    bootArtifactRanges: [Range<UInt64>]
  ) {
    self.entryPoint = entryPoint
    self.kernelSegments = kernelSegments
    self.kernelRanges = kernelRanges
    self.bootArtifactRanges = bootArtifactRanges
  }
}

/// A public, deterministic admission boundary for the direct-kernel PVH boot path.
///
/// Preflight validates raw ELF64 little-endian x86_64 kernel images and Linux x86 PVH
/// boot-protocol payload placement against the guest memory map derived from the requested
/// RAM size, using checked arithmetic for every offset, size, and alignment calculation. It
/// rejects truncated headers, unsupported ELF forms, unbounded program-header tables,
/// overflowing file/virtual segment ranges, nonsensical alignment, BSS or entry addresses
/// outside RAM, and overlapping kernel/boot artifacts before any machine state is touched.
///
/// Preflight never writes RAM, constructs a machine, mutates firmware variables, creates disks,
/// or allocates host mappings. It is purely a planning and validation step that may be invoked
/// before ``DoryPCDirectKernelMachine/load(kernel:initrd:commandLine:)`` to reject malformed or
/// overlapping boot artifacts deterministically. ACPI and SMBIOS table placement is validated
/// separately by the machine because SMBIOS table content depends on the CPU profile; preflight
/// does not claim UEFI installer qualification.
public enum DoryPCBootPreflight {
  /// The default direct-kernel command line used when the caller does not supply one, matching
  /// ``DoryPCDirectKernelMachine/load(kernel:initrd:commandLine:)``.
  public static let defaultCommandLine =
    "console=ttyS0 earlycon=uart,io,0x3f8,115200 panic=-1"

  /// Validates raw ELF64 kernel bytes and PVH boot artifact placement against the guest memory
  /// map derived from `memoryBytes`, without constructing a machine or writing RAM.
  ///
  /// - Parameters:
  ///   - kernel: Raw ELF64 little-endian x86_64 executable kernel image bytes.
  ///   - initrd: Optional initial ramdisk bytes. When non-empty, placed at `bootLayout.initrd`.
  ///   - commandLine: Non-empty kernel command line without embedded NUL bytes. Must fit within
  ///     ``DoryPCPVHBootBuilder/maximumCommandLineBytes`` bytes including the trailing NUL.
  ///   - memoryBytes: Guest RAM size in bytes. Must satisfy the same bounds as
  ///     ``DoryPCDirectKernelMachine/init(memoryBytes:)`` (at least 1 MiB, 1 MiB-aligned, and no
  ///     greater than ``DoryPCV1ABI/maximumMemoryBytes``).
  ///   - bootLayout: PVH handoff artifact placement. Defaults to the frozen DoryPC-v1 layout.
  ///   - acpiRSDPAddress: Physical address of the ACPI RSDP that the PVH start info will
  ///     advertise. Only the value is carried into the start info; preflight does not validate
  ///     ACPI tables.
  /// - Returns: A plan describing the validated kernel and boot artifact placement.
  /// - Throws: ``DoryPCPVHKernelError``, ``DoryPCPVHBootError``, or ``DoryPCMachineError`` for
  ///   any malformed or overlapping boot artifact, before any machine or RAM mutation.
  public static func plan(
    kernel: Data,
    initrd: [UInt8] = [],
    commandLine: String = defaultCommandLine,
    memoryBytes: Int,
    bootLayout: DoryPCPVHBootLayout = .init(),
    acpiRSDPAddress: UInt64 = DoryPCV1ABI.acpiBase
  ) throws -> DoryPCBootPreflightPlan {
    try validateMemoryBytes(memoryBytes)
    let kernelImage = try DoryPCPVHKernelImage(data: kernel)
    let memoryMap = try DoryPCPVHBootBuilder.memoryMap(memoryBytes: UInt64(memoryBytes))
    let bootImage = try DoryPCPVHBootBuilder.build(
      commandLine: commandLine,
      initrd: initrd,
      memoryMap: memoryMap,
      layout: bootLayout,
      rsdpPhysicalAddress: acpiRSDPAddress
    )
    return try validate(kernel: kernelImage, boot: bootImage, memoryMap: memoryMap)
  }

  /// Validates already-parsed kernel and boot image placement against the supplied memory map.
  ///
  /// The direct-kernel loader calls this entry point to share its parsed artifacts with preflight
  /// so the deterministic kernel-in-RAM and kernel/boot/reserved-overlap checks run before any
  /// machine-specific DMA validation or RAM write. Callers that hold only raw bytes should use
  /// ``plan(kernel:initrd:commandLine:memoryBytes:bootLayout:acpiRSDPAddress:)`` instead.
  public static func validate(
    kernel: DoryPCPVHKernelImage,
    boot: DoryPCPVHBootImage,
    memoryMap: [DoryPCMemoryMapEntry]
  ) throws -> DoryPCBootPreflightPlan {
    let ramRanges = try ramRanges(from: memoryMap)
    let kernelRanges = try sortedKernelRanges(from: kernel)
    try assertKernelSegments(kernelRanges, within: ramRanges)
    let bootRanges = boot.physicalRanges
    try assertNoOverlap(
      among: kernelRanges + bootRanges + reservedLowMemoryRanges(),
      overlapError: DoryPCMachineError.overlappingBootArtifacts
    )
    return DoryPCBootPreflightPlan(
      entryPoint: kernel.physicalEntryPoint,
      kernelSegments: kernel.segments,
      kernelRanges: kernelRanges,
      bootArtifactRanges: bootRanges
    )
  }

  // MARK: - Checked helpers

  /// Validates `memoryBytes` with the same bounds as the direct-kernel machine constructor so
  /// preflight rejects an impossible RAM size before deriving the guest memory map.
  private static func validateMemoryBytes(_ memoryBytes: Int) throws {
    guard memoryBytes >= 1024 * 1024,
      memoryBytes % (1024 * 1024) == 0,
      UInt64(memoryBytes) <= DoryPCV1ABI.maximumMemoryBytes
    else {
      throw DoryPCMachineError.invalidMemorySize(memoryBytes)
    }
  }

  /// Builds the `ram` ranges from the memory map using checked addition. A zero-size or
  /// overflowing entry is rejected as an invalid boot range; the memory-map builder already
  /// rejects these, but preflight remains self-contained and never masks an overflow.
  private static func ramRanges(from memoryMap: [DoryPCMemoryMapEntry]) throws -> [Range<UInt64>] {
    try memoryMap.filter { $0.kind == .ram }.map { entry in
      try checkedRange(address: entry.address, count: entry.size)
    }
  }

  /// Builds the loadable kernel segment ranges (memorySize > 0) using checked addition, sorted by
  /// physical address. The ELF parser already rejects overlapping segments; preflight preserves
  /// that order and re-derives each range with checked arithmetic.
  private static func sortedKernelRanges(from kernel: DoryPCPVHKernelImage) throws -> [Range<UInt64>] {
    try kernel.segments.filter { $0.memorySize > 0 }
      .map { try checkedRange(address: $0.physicalAddress, count: $0.memorySize) }
      .sorted { $0.lowerBound < $1.lowerBound }
  }

  /// Rejects any kernel segment range that is not fully contained within a `ram` memory-map
  /// entry. This catches BSS or load addresses that fall in a reserved hole, the MMIO aperture,
  /// or outside the configured RAM size, before the machine attempts a DMA write.
  private static func assertKernelSegments(
    _ kernelRanges: [Range<UInt64>],
    within ramRanges: [Range<UInt64>]
  ) throws {
    for segment in kernelRanges {
      guard ramRanges.contains(where: { ram in
        ram.lowerBound <= segment.lowerBound && segment.upperBound <= ram.upperBound
      }) else {
        throw DoryPCMachineError.bootArtifactOutsideRAM
      }
    }
  }

  /// Rejects any overlap among the supplied ranges. Ranges are sorted by lower bound first; a
  /// shared or adjacent boundary is not an overlap. Used for the kernel/boot/reserved-low-memory
  /// overlap check that must pass before the machine plans ACPI/SMBIOS tables.
  private static func assertNoOverlap(
    among ranges: [Range<UInt64>],
    overlapError: DoryPCMachineError
  ) throws {
    let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
    for pair in zip(sorted, sorted.dropFirst()) where pair.0.overlaps(pair.1) {
      throw overlapError
    }
  }

  /// Forms `address..<address + count` using checked addition. A zero count, a count exceeding
  /// `Int.max`, or an overflowing upper bound is rejected as an invalid boot range so no address
  /// masking can turn invalid input into a plausible location.
  private static func checkedRange(address: UInt64, count: UInt64) throws -> Range<UInt64> {
    let end = address.addingReportingOverflow(count)
    guard count > 0, count <= UInt64(Int.max), !end.overflow else {
      throw DoryPCMachineError.invalidBootRange
    }
    return address..<end.partialValue
  }

  /// The legacy first page and the explicitly supplied initial stack, which no kernel segment or
  /// boot artifact may overwrite. Matches the reserved ranges enforced by the direct-kernel
  /// loader's full overlap check.
  private static func reservedLowMemoryRanges() -> [Range<UInt64>] {
    [0..<0x1000, 0x7000..<0x8000]
  }
}
