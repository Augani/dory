import DoryVirtio
import Foundation

public enum DoryPCHostVisibleGPUApertureError: Error, Sendable, Equatable {
  case invalidConfiguration
  case duplicateResource(UInt32)
  case overlappingMapping(UInt32)
  case staleMapping(UInt32)
  case unmappedAccess(offset: UInt64, byteCount: Int, write: Bool)
}

public struct DoryPCHostVisibleGPUApertureSnapshot: Sendable, Equatable {
  public struct Mapping: Sendable, Equatable {
    public let workspaceID: UUID
    public let resourceID: UInt32
    public let resourceGeneration: UInt64
    public let workerGeneration: UInt64
    public let deviceGeneration: UInt64
    public let offset: UInt64
    public let byteCount: UInt64
  }

  public let regionID: UInt8
  public let byteCount: UInt64
  public let apertureGeneration: UInt64
  public let mapAdmissionGeneration: UInt64
  public let isResetting: Bool
  public let pendingResetCount: Int
  public let mappings: [Mapping]
}

/// One sparse, generation-bound host-visible GPU region. PCI owns placement of the containing BAR;
/// this object owns only offsets within it and therefore remains valid when firmware or Linux
/// relocates the 64-bit BAR. Holes never expose the worker arena and overlapping leases are
/// rejected before any guest access can resolve.
public final class DoryPCHostVisibleGPUAperture: DoryVirtioGPUHostVisibleAperture,
  @unchecked Sendable
{
  public static let sharedMemoryRegionID: UInt8 = 1
  public static let guestPageByteCount: UInt64 = 4_096
  public static let hostMappingGranule: UInt64 = 16_384

  private final class LiveMapping {
    let lease: DoryVirtioGPUBlobMapping
    let upperBound: UInt64
    var activeAccesses = 0
    var retiring = false

    init(lease: DoryVirtioGPUBlobMapping, upperBound: UInt64) {
      self.lease = lease
      self.upperBound = upperBound
    }
  }

  public let regionID: UInt8
  public let byteCount: UInt64

  private let lock = NSCondition()
  private var generation: UInt64 = 1
  private var admissionGeneration: UInt64 = 1
  private var resetting = false
  private var pendingResetCount = 0
  private var generationExhausted = false
  private var minimumDeviceGeneration: UInt64 = 1
  private var admittedWorkspaceID: UUID?
  private var admittedDeviceGeneration: UInt64?
  private var admittedWorkerGeneration: UInt64?
  private var mappings: [UInt32: LiveMapping] = [:]
  /// Accesses are much more frequent than MAP_BLOB/UNMAP_BLOB. Keep a sorted offset index so
  /// every guest CPU and DMA read/write avoids scanning the complete resource table.
  private var mappingsByOffset: [LiveMapping] = []

  public init(
    byteCount: UInt64,
    regionID: UInt8 = DoryPCHostVisibleGPUAperture.sharedMemoryRegionID
  ) throws {
    guard regionID == Self.sharedMemoryRegionID,
      byteCount >= 256 * 1_024 * 1_024,
      byteCount <= DoryPCV1ABI.pcie64MMIOBytes,
      byteCount.nonzeroBitCount == 1,
      byteCount.isMultiple(of: Self.hostMappingGranule)
    else { throw DoryPCHostVisibleGPUApertureError.invalidConfiguration }
    self.regionID = regionID
    self.byteCount = byteCount
  }

  public var snapshot: DoryPCHostVisibleGPUApertureSnapshot {
    lock.withLock {
      .init(
        regionID: regionID,
        byteCount: byteCount,
        apertureGeneration: generation,
        mapAdmissionGeneration: admissionGeneration,
        isResetting: resetting,
        pendingResetCount: pendingResetCount,
        mappings: mappingsByOffset.map { live in
          .init(
            workspaceID: live.lease.workspaceID,
            resourceID: live.lease.resourceID,
            resourceGeneration: live.lease.resourceGeneration,
            workerGeneration: live.lease.workerGeneration,
            deviceGeneration: live.lease.deviceGeneration,
            offset: live.lease.hostVisibleOffset,
            byteCount: live.lease.byteCount
          )
        }
      )
    }
  }

  public var apertureGeneration: UInt64 { lock.withLock { generation } }

  public var mapAdmissionGeneration: UInt64 { lock.withLock { admissionGeneration } }

  public func map(
    _ mapping: DoryVirtioGPUBlobMapping,
    expectedApertureGeneration: UInt64
  ) throws {
    let (upperBound, overflow) = mapping.hostVisibleOffset.addingReportingOverflow(
      mapping.byteCount
    )
    guard mapping.workspaceID != UUID(uuidString: "00000000-0000-0000-0000-000000000000"),
      mapping.resourceID != 0, mapping.resourceGeneration != 0,
      mapping.workerGeneration != 0, mapping.deviceGeneration != 0,
      (0...3).contains(mapping.mapInfo),
      mapping.hostVisibleOffset.isMultiple(of: Self.guestPageByteCount),
      mapping.byteCount > 0, mapping.memory.byteCount == mapping.byteCount,
      !overflow, upperBound <= byteCount
    else { throw DoryPCHostVisibleGPUApertureError.invalidConfiguration }
    try lock.withLock {
      // A second reset may already be waiting for the first to retire its readers. Do not
      // admit a successor mapping in the handoff between those reset invocations: it would
      // become visible to the guest only to be revoked by the queued reset.
      guard !resetting, pendingResetCount == 0, !generationExhausted,
        admissionGeneration == expectedApertureGeneration, generation < .max else {
        throw DoryPCHostVisibleGPUApertureError.staleMapping(mapping.resourceID)
      }
      guard mapping.deviceGeneration >= minimumDeviceGeneration,
        admittedWorkspaceID.map({ $0 == mapping.workspaceID }) ?? true,
        admittedDeviceGeneration.map({ $0 == mapping.deviceGeneration }) ?? true,
        admittedWorkerGeneration.map({ $0 == mapping.workerGeneration }) ?? true
      else { throw DoryPCHostVisibleGPUApertureError.staleMapping(mapping.resourceID) }
      guard mappings[mapping.resourceID] == nil else {
        throw DoryPCHostVisibleGPUApertureError.duplicateResource(mapping.resourceID)
      }
      let insertion = insertionIndex(for: mapping.hostVisibleOffset)
      guard (insertion == 0 || mappingsByOffset[insertion - 1].upperBound <= mapping.hostVisibleOffset),
        (insertion == mappingsByOffset.count
          || upperBound <= mappingsByOffset[insertion].lease.hostVisibleOffset)
      else {
        throw DoryPCHostVisibleGPUApertureError.overlappingMapping(mapping.resourceID)
      }
      admittedWorkspaceID = mapping.workspaceID
      admittedDeviceGeneration = mapping.deviceGeneration
      admittedWorkerGeneration = mapping.workerGeneration
      let live = LiveMapping(lease: mapping, upperBound: upperBound)
      mappings[mapping.resourceID] = live
      mappingsByOffset.insert(live, at: insertion)
      // A PCI access that resolved before this mapping existed must not gain access to it.
      generation += 1
    }
  }

  @discardableResult
  public func unmap(resourceID: UInt32, identity: DoryVirtioGPUBlobIdentity) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard let live = mappings[resourceID],
      live.lease.workspaceID == identity.workspaceID,
      live.lease.resourceGeneration == identity.resourceGeneration,
      live.lease.workerGeneration == identity.workerGeneration,
      live.lease.deviceGeneration == identity.deviceGeneration,
      !live.retiring
    else { return false }
    live.retiring = true
    while live.activeAccesses != 0 { lock.wait() }
    // reset() releases this condition while draining active readers. It may clear the old
    // resource and a later generation may reuse the same ID before this waiter resumes.
    guard !resetting, mappings[resourceID] === live else { return false }
    mappings.removeValue(forKey: resourceID)
    let index = insertionIndex(for: live.lease.hostVisibleOffset) - 1
    precondition(index < mappingsByOffset.count && mappingsByOffset[index] === live)
    mappingsByOffset.remove(at: index)
    // Revoke routes captured before unmap, including routes to a newly reused offset.
    if generation == .max {
      generationExhausted = true
    } else {
      generation += 1
    }
    return true
  }

  public func reset() {
    lock.lock()
    if resetting {
      pendingResetCount += 1
      while resetting { lock.wait() }
      pendingResetCount -= 1
      // Another reset may have completed while a new-generation map acquired the lock before
      // this waiter. Every reset invocation must linearize against the state it observes now.
    }
    resetting = true
    for live in mappings.values { live.retiring = true }
    while mappings.values.contains(where: { $0.activeAccesses != 0 }) { lock.wait() }
    mappings.removeAll(keepingCapacity: false)
    mappingsByOffset.removeAll(keepingCapacity: false)
    if let admittedDeviceGeneration {
      if admittedDeviceGeneration == .max {
        generationExhausted = true
      } else {
        minimumDeviceGeneration = admittedDeviceGeneration + 1
      }
    }
    admittedDeviceGeneration = nil
    admittedWorkspaceID = nil
    admittedWorkerGeneration = nil
    if generation == .max {
      generationExhausted = true
    } else {
      generation += 1
    }
    if admissionGeneration == .max {
      generationExhausted = true
    } else {
      admissionGeneration += 1
    }
    resetting = false
    lock.broadcast()
    lock.unlock()
  }

  public func read(
    offset: UInt64,
    byteCount: Int,
    expectedApertureGeneration: UInt64? = nil
  ) throws -> [UInt8] {
    let resolved = try resolve(
      offset: offset, byteCount: byteCount, write: false,
      expectedApertureGeneration: expectedApertureGeneration
    )
    defer { release(resolved.live) }
    return try resolved.memory.read(offset: resolved.mappingOffset, byteCount: byteCount)
  }

  public func write(
    offset: UInt64,
    bytes: [UInt8],
    expectedApertureGeneration: UInt64? = nil
  ) throws {
    let resolved = try resolve(
      offset: offset, byteCount: bytes.count, write: true,
      expectedApertureGeneration: expectedApertureGeneration
    )
    defer { release(resolved.live) }
    try resolved.memory.write(offset: resolved.mappingOffset, bytes: bytes)
  }

  public func compareExchange(
    offset: UInt64,
    expected: UInt64,
    desired: UInt64,
    byteCount: Int,
    expectedApertureGeneration: UInt64? = nil
  ) throws -> UInt64? {
    let resolved = try resolve(
      offset: offset, byteCount: byteCount, write: true,
      expectedApertureGeneration: expectedApertureGeneration
    )
    defer { release(resolved.live) }
    return try resolved.memory.compareExchange(
      offset: resolved.mappingOffset, expected: expected, desired: desired, byteCount: byteCount
    )
  }

  public func validateRead(
    offset: UInt64,
    byteCount: Int,
    expectedApertureGeneration: UInt64? = nil
  ) throws {
    let resolved = try resolve(
      offset: offset, byteCount: byteCount, write: false,
      expectedApertureGeneration: expectedApertureGeneration
    )
    release(resolved.live)
  }

  public func validateWrite(
    offset: UInt64,
    byteCount: Int,
    expectedApertureGeneration: UInt64? = nil
  ) throws {
    let resolved = try resolve(
      offset: offset, byteCount: byteCount, write: true,
      expectedApertureGeneration: expectedApertureGeneration
    )
    release(resolved.live)
  }

  public func synchronize() {
    let liveMappings = lock.withLock { () -> [LiveMapping] in
      let values = mappings.values.filter { !$0.retiring }
      for live in values { live.activeAccesses += 1 }
      return values
    }
    for live in liveMappings {
      live.lease.memory.synchronize()
      release(live)
    }
  }

  private func resolve(
    offset: UInt64,
    byteCount: Int,
    write: Bool,
    expectedApertureGeneration: UInt64?
  ) throws -> (
    memory: DoryVirtioGPUBlobMemoryRegion,
    mappingOffset: UInt64,
    live: LiveMapping
  ) {
    guard byteCount > 0, offset <= self.byteCount,
      UInt64(byteCount) <= self.byteCount - offset
    else {
      throw DoryPCHostVisibleGPUApertureError.unmappedAccess(
        offset: offset,
        byteCount: byteCount,
        write: write
      )
    }
    return try lock.withLock {
      if let expectedApertureGeneration, expectedApertureGeneration != generation {
        throw DoryPCHostVisibleGPUApertureError.unmappedAccess(
          offset: offset,
          byteCount: byteCount,
          write: write
        )
      }
      let insertion = insertionIndex(for: offset)
      guard insertion > 0 else {
        throw DoryPCHostVisibleGPUApertureError.unmappedAccess(
          offset: offset,
          byteCount: byteCount,
          write: write
        )
      }
      let live = mappingsByOffset[insertion - 1]
      guard !live.retiring, offset < live.upperBound,
        UInt64(byteCount) <= live.upperBound - offset,
        !write || live.lease.memory.access == .readWrite
      else {
        throw DoryPCHostVisibleGPUApertureError.unmappedAccess(
          offset: offset,
          byteCount: byteCount,
          write: write
        )
      }
      live.activeAccesses += 1
      return (live.lease.memory, offset - live.lease.hostVisibleOffset, live)
    }
  }

  /// First mapping whose starting offset is greater than the requested offset.
  private func insertionIndex(for offset: UInt64) -> Int {
    var lower = 0
    var upper = mappingsByOffset.count
    while lower < upper {
      let middle = lower + (upper - lower) / 2
      if mappingsByOffset[middle].lease.hostVisibleOffset <= offset {
        lower = middle + 1
      } else {
        upper = middle
      }
    }
    return lower
  }

  private func release(_ live: LiveMapping) {
    lock.lock()
    precondition(live.activeAccesses > 0)
    live.activeAccesses -= 1
    if live.activeAccesses == 0 { lock.broadcast() }
    lock.unlock()
  }
}
