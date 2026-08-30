public struct DoryGuestPhysicalAddress: RawRepresentable, Codable, Sendable, Hashable, Comparable {
  public let rawValue: UInt64

  public init(rawValue: UInt64) {
    self.rawValue = rawValue
  }

  public init(_ rawValue: UInt64) {
    self.rawValue = rawValue
  }

  public static func < (lhs: Self, rhs: Self) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

public struct DoryGuestAddressRange: Codable, Sendable, Hashable {
  public let base: DoryGuestPhysicalAddress
  public let byteCount: UInt64

  public init(base: DoryGuestPhysicalAddress, byteCount: UInt64) throws {
    guard byteCount > 0 else { throw DoryExecutionContractError.emptyRange }
    guard base.rawValue.addingReportingOverflow(byteCount).overflow == false else {
      throw DoryExecutionContractError.addressOverflow(
        base: base.rawValue,
        byteCount: byteCount
      )
    }
    self.base = base
    self.byteCount = byteCount
  }

  public init(base: UInt64, byteCount: UInt64) throws {
    try self.init(base: DoryGuestPhysicalAddress(base), byteCount: byteCount)
  }

  public var endExclusive: DoryGuestPhysicalAddress {
    DoryGuestPhysicalAddress(base.rawValue + byteCount)
  }

  public func contains(_ address: DoryGuestPhysicalAddress) -> Bool {
    address >= base && address < endExclusive
  }

  public func overlaps(_ other: Self) -> Bool {
    base < other.endExclusive && other.base < endExclusive
  }

  private enum CodingKeys: String, CodingKey { case base, byteCount }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      base: container.decode(DoryGuestPhysicalAddress.self, forKey: .base),
      byteCount: container.decode(UInt64.self, forKey: .byteCount)
    )
  }
}

public enum DoryGuestMemoryPermission: String, Codable, CaseIterable, Sendable, Hashable {
  case read
  case write
  case execute
}

public enum DoryGuestMemoryOwnership: String, Codable, Sendable, Hashable {
  case executionEngine
  case machineModel
  case sharedDevice
}

public enum DoryDirtyTrackingMode: Codable, Sendable, Hashable {
  case disabled
  case epoch(UInt64)

  public var epoch: UInt64? {
    guard case .epoch(let value) = self else { return nil }
    return value
  }

  public func validate() throws {
    if case .epoch(let value) = self, value == 0 {
      throw DoryExecutionContractError.invalidGeneration(type: "dirty epoch", value: value)
    }
  }
}

public struct DoryGuestMemoryRegion: Codable, Sendable, Hashable {
  public let id: UInt32
  public let range: DoryGuestAddressRange
  public let pageSize: UInt64
  public let permissions: [DoryGuestMemoryPermission]
  public let ownership: DoryGuestMemoryOwnership
  public let mappingGeneration: UInt64
  public let dirtyTracking: DoryDirtyTrackingMode

  public init(
    id: UInt32,
    range: DoryGuestAddressRange,
    pageSize: UInt64,
    permissions: [DoryGuestMemoryPermission],
    ownership: DoryGuestMemoryOwnership,
    mappingGeneration: UInt64,
    dirtyTracking: DoryDirtyTrackingMode
  ) throws {
    guard id > 0 else { throw DoryExecutionContractError.zeroIdentifier(type: "memory region") }
    guard pageSize > 0, pageSize.nonzeroBitCount == 1 else {
      throw DoryExecutionContractError.invalidPageSize(pageSize)
    }
    guard range.base.rawValue.isMultiple(of: pageSize),
      range.byteCount.isMultiple(of: pageSize)
    else {
      throw DoryExecutionContractError.unalignedRange(
        base: range.base.rawValue,
        byteCount: range.byteCount,
        pageSize: pageSize
      )
    }
    guard !permissions.isEmpty else { throw DoryExecutionContractError.emptyPermissions }
    let canonicalPermissions = permissions.sorted { $0.rawValue < $1.rawValue }
    for pair in zip(canonicalPermissions, canonicalPermissions.dropFirst()) where pair.0 == pair.1 {
      throw DoryExecutionContractError.duplicatePermission(pair.0)
    }
    guard mappingGeneration > 0 else {
      throw DoryExecutionContractError.invalidGeneration(
        type: "memory mapping",
        value: mappingGeneration
      )
    }
    try dirtyTracking.validate()
    self.id = id
    self.range = range
    self.pageSize = pageSize
    self.permissions = canonicalPermissions
    self.ownership = ownership
    self.mappingGeneration = mappingGeneration
    self.dirtyTracking = dirtyTracking
  }

  private enum CodingKeys: String, CodingKey {
    case id, range, pageSize, permissions, ownership, mappingGeneration, dirtyTracking
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      id: container.decode(UInt32.self, forKey: .id),
      range: container.decode(DoryGuestAddressRange.self, forKey: .range),
      pageSize: container.decode(UInt64.self, forKey: .pageSize),
      permissions: container.decode([DoryGuestMemoryPermission].self, forKey: .permissions),
      ownership: container.decode(DoryGuestMemoryOwnership.self, forKey: .ownership),
      mappingGeneration: container.decode(UInt64.self, forKey: .mappingGeneration),
      dirtyTracking: container.decode(DoryDirtyTrackingMode.self, forKey: .dirtyTracking)
    )
  }
}

/// Process-local authority for one guest mapping. The host pointer is intentionally neither
/// codable nor part of snapshot state; durable contracts carry only `DoryGuestMemoryRegion`.
public struct DoryGuestMemoryMapping: @unchecked Sendable {
  public let region: DoryGuestMemoryRegion
  public let hostAddress: UnsafeMutableRawPointer
  public let hostByteCount: UInt64

  public init(
    region: DoryGuestMemoryRegion,
    hostAddress: UnsafeMutableRawPointer,
    hostByteCount: UInt64
  ) throws {
    guard hostByteCount >= region.range.byteCount else {
      throw DoryExecutionContractError.backingTooSmall(
        required: region.range.byteCount,
        actual: hostByteCount
      )
    }
    let address = UInt(bitPattern: hostAddress)
    guard UInt64(address).isMultiple(of: region.pageSize) else {
      throw DoryExecutionContractError.unalignedHostAddress(
        address: address,
        pageSize: region.pageSize
      )
    }
    self.region = region
    self.hostAddress = hostAddress
    self.hostByteCount = hostByteCount
  }
}

public struct DoryDirtyPageSet: Codable, Sendable, Hashable {
  public let regionID: UInt32
  public let mappingGeneration: UInt64
  public let dirtyEpoch: UInt64
  public let pageSize: UInt64
  public let regionByteCount: UInt64
  public let pageOffsets: [UInt64]

  public init(region: DoryGuestMemoryRegion, dirtyEpoch: UInt64, pageOffsets: [UInt64]) throws {
    try self.init(
      regionID: region.id,
      mappingGeneration: region.mappingGeneration,
      dirtyEpoch: dirtyEpoch,
      pageSize: region.pageSize,
      regionByteCount: region.range.byteCount,
      pageOffsets: pageOffsets
    )
  }

  private init(
    regionID: UInt32,
    mappingGeneration: UInt64,
    dirtyEpoch: UInt64,
    pageSize: UInt64,
    regionByteCount: UInt64,
    pageOffsets: [UInt64]
  ) throws {
    guard regionID > 0 else {
      throw DoryExecutionContractError.zeroIdentifier(type: "memory region")
    }
    guard mappingGeneration > 0 else {
      throw DoryExecutionContractError.invalidGeneration(
        type: "memory mapping",
        value: mappingGeneration
      )
    }
    guard dirtyEpoch > 0 else {
      throw DoryExecutionContractError.invalidGeneration(type: "dirty epoch", value: dirtyEpoch)
    }
    guard pageSize > 0, pageSize.nonzeroBitCount == 1 else {
      throw DoryExecutionContractError.invalidPageSize(pageSize)
    }
    guard regionByteCount > 0, regionByteCount.isMultiple(of: pageSize) else {
      throw DoryExecutionContractError.unalignedRange(
        base: 0,
        byteCount: regionByteCount,
        pageSize: pageSize
      )
    }
    var previous: UInt64?
    for offset in pageOffsets {
      guard offset < regionByteCount else {
        throw DoryExecutionContractError.dirtyPageOffsetOutOfRange(offset)
      }
      guard offset.isMultiple(of: pageSize) else {
        throw DoryExecutionContractError.dirtyPageOffsetUnaligned(offset)
      }
      if let previous, offset <= previous {
        throw DoryExecutionContractError.nonCanonicalDirtyPageOffsets
      }
      previous = offset
    }
    self.regionID = regionID
    self.mappingGeneration = mappingGeneration
    self.dirtyEpoch = dirtyEpoch
    self.pageSize = pageSize
    self.regionByteCount = regionByteCount
    self.pageOffsets = pageOffsets
  }

  private enum CodingKeys: String, CodingKey {
    case regionID, mappingGeneration, dirtyEpoch, pageSize, regionByteCount, pageOffsets
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      regionID: container.decode(UInt32.self, forKey: .regionID),
      mappingGeneration: container.decode(UInt64.self, forKey: .mappingGeneration),
      dirtyEpoch: container.decode(UInt64.self, forKey: .dirtyEpoch),
      pageSize: container.decode(UInt64.self, forKey: .pageSize),
      regionByteCount: container.decode(UInt64.self, forKey: .regionByteCount),
      pageOffsets: container.decode([UInt64].self, forKey: .pageOffsets)
    )
  }
}

public enum DoryGuestMemoryLayout {
  public static func validateNonoverlapping(_ regions: [DoryGuestMemoryRegion]) throws {
    let ordered = regions.sorted { lhs, rhs in
      if lhs.range.base != rhs.range.base { return lhs.range.base < rhs.range.base }
      return lhs.id < rhs.id
    }
    for pair in zip(ordered, ordered.dropFirst()) where pair.0.range.overlaps(pair.1.range) {
      throw DoryExecutionContractError.nonCanonicalCollection(type: "guest memory layout")
    }
  }
}
