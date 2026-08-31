import Foundation

public enum DoryVirtioGPUFormat: UInt32, Sendable, Hashable {
  case b8g8r8a8UNorm = 1
  case b8g8r8x8UNorm = 2
  case a8r8g8b8UNorm = 3
  case x8r8g8b8UNorm = 4
  case r8g8b8a8UNorm = 67
  case x8b8g8r8UNorm = 68
  case a8b8g8r8UNorm = 121
  case r8g8b8x8UNorm = 134

  public var bytesPerPixel: Int { 4 }
}

public struct DoryVirtioGPURectangle: Sendable, Hashable {
  public let x: UInt32
  public let y: UInt32
  public let width: UInt32
  public let height: UInt32

  public init(x: UInt32, y: UInt32, width: UInt32, height: UInt32) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }
}

public struct DoryVirtioGPUScanout: Sendable, Hashable {
  public let id: UInt32
  public let rectangle: DoryVirtioGPURectangle
  public let enabled: Bool

  public init(id: UInt32, rectangle: DoryVirtioGPURectangle, enabled: Bool = true) {
    self.id = id
    self.rectangle = rectangle
    self.enabled = enabled
  }
}

public struct DoryVirtioGPUFrame: Sendable, Hashable {
  public let scanoutID: UInt32
  public let resourceID: UInt32
  public let scanoutRectangle: DoryVirtioGPURectangle
  public let damagedRectangle: DoryVirtioGPURectangle
  public let resourceWidth: UInt32
  public let resourceHeight: UInt32
  public let format: DoryVirtioGPUFormat
  public let pixels: [UInt8]

  public init(
    scanoutID: UInt32,
    resourceID: UInt32,
    scanoutRectangle: DoryVirtioGPURectangle,
    damagedRectangle: DoryVirtioGPURectangle,
    resourceWidth: UInt32,
    resourceHeight: UInt32,
    format: DoryVirtioGPUFormat,
    pixels: [UInt8]
  ) {
    self.scanoutID = scanoutID
    self.resourceID = resourceID
    self.scanoutRectangle = scanoutRectangle
    self.damagedRectangle = damagedRectangle
    self.resourceWidth = resourceWidth
    self.resourceHeight = resourceHeight
    self.format = format
    self.pixels = pixels
  }
}

public struct DoryVirtioGPUCapset: Sendable, Hashable {
  public let id: UInt32
  public let maximumVersion: UInt32
  public let data: [UInt8]

  public init(id: UInt32, maximumVersion: UInt32, data: [UInt8]) {
    self.id = id
    self.maximumVersion = maximumVersion
    self.data = data
  }
}

public struct DoryVirtioGPUAccelerationCapabilities: Sendable, Hashable {
  public static let maximumCapsetBytes = 1 * 1024 * 1024

  public let features: DoryVirtioFeatures
  public let capsets: [DoryVirtioGPUCapset]

  public init(features: DoryVirtioFeatures, capsets: [DoryVirtioGPUCapset]) throws {
    let allowedFeatures: DoryVirtioFeatures = [
      .gpuVirgl, .gpuResourceUUID, .gpuResourceBlob, .gpuContextInit,
    ]
    guard !capsets.isEmpty,
      capsets.count <= 16,
      Set(capsets.map(\.id)).count == capsets.count,
      capsets.allSatisfy({ $0.id != 0 && !$0.data.isEmpty }),
      capsets.reduce(UInt64(0), { $0 + UInt64($1.data.count) }) <= UInt64(Self.maximumCapsetBytes),
      allowedFeatures.isSuperset(of: features),
      features.contains(.gpuVirgl)
    else { throw DoryVirtioGPUError.invalidAccelerationCapabilities }
    self.features = features
    self.capsets = capsets
  }
}

/// Generation-scoped renderer authority. Capability discovery is intentionally inseparable from
/// the authority that will execute accelerated commands; a software-only device never advertises
/// renderer features merely because renderer libraries happen to exist on the host.
public protocol DoryVirtioGPUAccelerationAuthority: AnyObject, Sendable {
  var capabilities: DoryVirtioGPUAccelerationCapabilities { get }
  func reset()
  func createContext(id: UInt32, capsetID: UInt32, name: String) throws
  func destroyContext(id: UInt32) throws
  func attachResource(contextID: UInt32, resourceID: UInt32) throws
  func detachResource(contextID: UInt32, resourceID: UInt32) throws
  func submit3D(contextID: UInt32, command: [UInt8]) throws
  func createResource3D(_ resource: DoryVirtioGPUResource3D) throws
  func attachBacking(
    resourceID: UInt32,
    entries: [DoryVirtioGPUBackingEntry],
    memory: any DoryVirtioGuestMemory
  ) throws
  func detachBacking(resourceID: UInt32) throws
  func transfer3D(
    _ transfer: DoryVirtioGPUTransfer3D,
    entries: [DoryVirtioGPUBackingEntry],
    memory: any DoryVirtioGuestMemory
  ) throws
  func unrefResource(resourceID: UInt32) throws
}

extension DoryVirtioFeatures {
  public static let gpuVirgl = Self(rawValue: 1 << 0)
  public static let gpuResourceUUID = Self(rawValue: 1 << 2)
  public static let gpuResourceBlob = Self(rawValue: 1 << 3)
  public static let gpuContextInit = Self(rawValue: 1 << 4)
}

public protocol DoryVirtioGPUDisplaySink: AnyObject, Sendable {
  func present(_ frame: DoryVirtioGPUFrame)
}

public enum DoryVirtioGPUError: Error, Sendable, Equatable {
  case invalidScanoutCount(Int)
  case invalidDimensions(width: UInt32, height: UInt32)
  case malformedRequest
  case invalidDescriptorDirection
  case requestTooLarge(UInt64)
  case guestAddressOverflow
  case invalidAccelerationCapabilities
}

/// Transport-neutral VirtIO GPU 2D device. The core deliberately exposes only bounded software
/// resources; Metal presentation and PCI/MMIO transport live outside this module.
public final class DoryVirtioGPUDevice: @unchecked Sendable {
  public static let controlQueue: UInt16 = 0
  public static let cursorQueue: UInt16 = 1

  private enum Command: UInt32 {
    case getDisplayInfo = 0x0100
    case resourceCreate2D = 0x0101
    case resourceUnref = 0x0102
    case setScanout = 0x0103
    case resourceFlush = 0x0104
    case transferToHost2D = 0x0105
    case resourceAttachBacking = 0x0106
    case resourceDetachBacking = 0x0107
    case getCapsetInfo = 0x0108
    case getCapset = 0x0109
    case resourceAssignUUID = 0x010B
    case contextCreate = 0x0200
    case contextDestroy = 0x0201
    case contextAttachResource = 0x0202
    case contextDetachResource = 0x0203
    case resourceCreate3D = 0x0204
    case transferToHost3D = 0x0205
    case transferFromHost3D = 0x0206
    case submit3D = 0x0207
    case updateCursor = 0x0300
    case moveCursor = 0x0301
  }

  private enum Response: UInt32 {
    case okNoData = 0x1100
    case okDisplayInfo = 0x1101
    case okCapsetInfo = 0x1102
    case okCapset = 0x1103
    case okResourceUUID = 0x1105
    case errorUnspecified = 0x1200
    case errorOutOfMemory = 0x1201
    case errorInvalidScanout = 0x1202
    case errorInvalidResource = 0x1203
    case errorInvalidParameter = 0x1205
  }

  private struct Header {
    let flags: UInt32
    let fenceID: UInt64
    let contextID: UInt32
    let ringIndex: UInt8
  }

  private struct Resource {
    let id: UInt32
    let format: DoryVirtioGPUFormat
    let width: UInt32
    let height: UInt32
    var backing: [DoryVirtioGPUBackingEntry] = []
    var pixels: [UInt8]
  }

  private struct RendererResource {
    let descriptor: DoryVirtioGPUResource3D
    var backing: [DoryVirtioGPUBackingEntry] = []
  }

  private struct ScanoutBinding {
    let resourceID: UInt32
    let rectangle: DoryVirtioGPURectangle
  }

  public let scanouts: [DoryVirtioGPUScanout]
  public let maximumResourceBytes: UInt64
  public let maximumBackingEntries: Int

  private let lock = NSLock()
  private weak var displaySink: (any DoryVirtioGPUDisplaySink)?
  private let accelerationAuthority: (any DoryVirtioGPUAccelerationAuthority)?
  private var resources: [UInt32: Resource] = [:]
  private var rendererResources: [UInt32: RendererResource] = [:]
  private var rendererContexts: Set<UInt32> = []
  private var resourceUUIDs: [UInt32: [UInt8]] = [:]
  private var bindings: [UInt32: ScanoutBinding] = [:]

  public init(
    scanouts: [DoryVirtioGPUScanout],
    maximumResourceBytes: UInt64 = 256 * 1024 * 1024,
    maximumBackingEntries: Int = 65_536,
    displaySink: (any DoryVirtioGPUDisplaySink)? = nil,
    accelerationAuthority: (any DoryVirtioGPUAccelerationAuthority)? = nil
  ) throws {
    guard (1...16).contains(scanouts.count),
      Set(scanouts.map(\.id)).count == scanouts.count,
      scanouts.enumerated().allSatisfy({ UInt32($0.offset) == $0.element.id })
    else { throw DoryVirtioGPUError.invalidScanoutCount(scanouts.count) }
    guard scanouts.allSatisfy({ Self.valid($0.rectangle) }) else {
      let invalid = scanouts.first { !Self.valid($0.rectangle) }!.rectangle
      throw DoryVirtioGPUError.invalidDimensions(
        width: invalid.width,
        height: invalid.height
      )
    }
    self.scanouts = scanouts
    self.maximumResourceBytes = max(4, maximumResourceBytes)
    self.maximumBackingEntries = max(1, maximumBackingEntries)
    self.displaySink = displaySink
    self.accelerationAuthority = accelerationAuthority
  }

  public var offeredFeatures: DoryVirtioFeatures {
    accelerationAuthority?.capabilities.features ?? []
  }

  /// `events_read`, `events_clear`, `num_scanouts`, `num_capsets`.
  public var configuration: [UInt8] {
    littleEndian(UInt32(0)) + littleEndian(UInt32(0))
      + littleEndian(UInt32(scanouts.count))
      + littleEndian(UInt32(accelerationAuthority?.capabilities.capsets.count ?? 0))
  }

  public func connectDisplaySink(_ sink: (any DoryVirtioGPUDisplaySink)?) {
    lock.withLock { displaySink = sink }
  }

  public func reset() {
    lock.withLock {
      resources.removeAll(keepingCapacity: true)
      rendererResources.removeAll(keepingCapacity: true)
      rendererContexts.removeAll(keepingCapacity: true)
      resourceUUIDs.removeAll(keepingCapacity: true)
      bindings.removeAll(keepingCapacity: true)
    }
    accelerationAuthority?.reset()
  }

  public func process(
    queue: UInt16,
    chain: DoryVirtioDescriptorChain,
    memory: any DoryVirtioGuestMemory
  ) throws -> UInt32 {
    guard queue == Self.controlQueue || queue == Self.cursorQueue else {
      throw DoryVirtioGPUError.malformedRequest
    }
    let readable = chain.descriptors.filter { !$0.deviceWillWrite }
    let writable = chain.descriptors.filter(\.deviceWillWrite)
    guard !readable.isEmpty, !writable.isEmpty,
      chain.descriptors.drop(while: { !$0.deviceWillWrite }).allSatisfy(\.deviceWillWrite)
    else { throw DoryVirtioGPUError.invalidDescriptorDirection }
    let request = try gather(readable, memory: memory)
    guard request.count >= 24 else { throw DoryVirtioGPUError.malformedRequest }
    let header = Header(
      flags: read32(request, 4),
      fenceID: read64(request, 8),
      contextID: read32(request, 16),
      ringIndex: request[20]
    )
    let command = Command(rawValue: read32(request, 0))
    let cursorCommand = command == .updateCursor || command == .moveCursor
    guard (queue == Self.cursorQueue) == cursorCommand else {
      let response = response(.errorInvalidParameter, header: header)
      guard UInt64(response.count) <= chain.writableByteCount else {
        throw DoryVirtioGPUError.malformedRequest
      }
      try scatter(response, into: writable, memory: memory)
      return UInt32(response.count)
    }
    let response = try execute(command, request: request, header: header, memory: memory)
    guard UInt64(response.count) <= chain.writableByteCount else {
      throw DoryVirtioGPUError.malformedRequest
    }
    try scatter(response, into: writable, memory: memory)
    return UInt32(response.count)
  }

  private func execute(
    _ command: Command?,
    request: [UInt8],
    header: Header,
    memory: any DoryVirtioGuestMemory
  ) throws -> [UInt8] {
    guard let command else { return response(.errorUnspecified, header: header) }
    switch command {
    case .getDisplayInfo:
      guard request.count == 24 else { return response(.errorInvalidParameter, header: header) }
      var result = response(.okDisplayInfo, header: header)
      for index in 0..<16 {
        if index < scanouts.count {
          let scanout = scanouts[index]
          result += rectangleBytes(scanout.rectangle)
          result += littleEndian(UInt32(scanout.enabled ? 1 : 0))
          result += littleEndian(UInt32(0))
        } else {
          result += [UInt8](repeating: 0, count: 24)
        }
      }
      return result

    case .getCapsetInfo:
      guard request.count == 32,
        let capabilities = accelerationAuthority?.capabilities
      else { return response(.errorInvalidParameter, header: header) }
      let index = Int(read32(request, 24))
      guard capabilities.capsets.indices.contains(index) else {
        return response(.errorInvalidParameter, header: header)
      }
      let capset = capabilities.capsets[index]
      return response(.okCapsetInfo, header: header)
        + littleEndian(capset.id)
        + littleEndian(capset.maximumVersion)
        + littleEndian(UInt32(capset.data.count))
        + littleEndian(UInt32(0))

    case .getCapset:
      guard request.count == 32,
        let capabilities = accelerationAuthority?.capabilities
      else { return response(.errorInvalidParameter, header: header) }
      let id = read32(request, 24)
      let version = read32(request, 28)
      guard let capset = capabilities.capsets.first(where: { $0.id == id }),
        version <= capset.maximumVersion
      else { return response(.errorInvalidParameter, header: header) }
      return response(.okCapset, header: header) + capset.data

    case .resourceAssignUUID:
      guard request.count == 32, offeredFeatures.contains(.gpuResourceUUID) else {
        return response(.errorInvalidParameter, header: header)
      }
      let resourceID = read32(request, 24)
      guard lock.withLock({ resources[resourceID] != nil || rendererResources[resourceID] != nil })
      else { return response(.errorInvalidResource, header: header) }
      let uuid = lock.withLock { () -> [UInt8] in
        if let existing = resourceUUIDs[resourceID] { return existing }
        var value = UUID().uuid
        let bytes = withUnsafeBytes(of: &value) { Array($0) }
        resourceUUIDs[resourceID] = bytes
        return bytes
      }
      return response(.okResourceUUID, header: header) + uuid

    case .resourceCreate2D:
      guard request.count == 40 else { return response(.errorInvalidParameter, header: header) }
      let id = read32(request, 24)
      let format = DoryVirtioGPUFormat(rawValue: read32(request, 28))
      let width = read32(request, 32)
      let height = read32(request, 36)
      guard id != 0, let format, Self.valid(width: width, height: height),
        let byteCount = resourceByteCount(width: width, height: height),
        byteCount <= maximumResourceBytes
      else { return response(.errorInvalidParameter, header: header) }
      let inserted = lock.withLock { () -> Bool in
        guard resources[id] == nil, rendererResources[id] == nil else { return false }
        resources[id] = Resource(
          id: id,
          format: format,
          width: width,
          height: height,
          pixels: [UInt8](repeating: 0, count: Int(byteCount))
        )
        return true
      }
      return response(inserted ? .okNoData : .errorInvalidResource, header: header)

    case .resourceUnref:
      guard request.count == 32 else { return response(.errorInvalidParameter, header: header) }
      let id = read32(request, 24)
      let rendererResource = lock.withLock { rendererResources[id] != nil }
      if rendererResource {
        do {
          try accelerationAuthority?.unrefResource(resourceID: id)
        } catch {
          return response(.errorInvalidParameter, header: header)
        }
      }
      let removed = lock.withLock { () -> Bool in
        let removed =
          resources.removeValue(forKey: id) != nil
          || rendererResources.removeValue(forKey: id) != nil
        guard removed else { return false }
        resourceUUIDs.removeValue(forKey: id)
        bindings = bindings.filter { $0.value.resourceID != id }
        return true
      }
      return response(removed ? .okNoData : .errorInvalidResource, header: header)

    case .resourceAttachBacking:
      guard request.count >= 32 else { return response(.errorInvalidParameter, header: header) }
      let id = read32(request, 24)
      let entryCount = Int(read32(request, 28))
      guard entryCount > 0, entryCount <= maximumBackingEntries,
        request.count == 32 + entryCount * 16
      else { return response(.errorInvalidParameter, header: header) }
      var entries: [DoryVirtioGPUBackingEntry] = []
      entries.reserveCapacity(entryCount)
      var total: UInt64 = 0
      for index in 0..<entryCount {
        let offset = 32 + index * 16
        let address = read64(request, offset)
        let length = read32(request, offset + 8)
        let (end, addressOverflow) = address.addingReportingOverflow(UInt64(length))
        let (updated, totalOverflow) = total.addingReportingOverflow(UInt64(length))
        guard length > 0, !addressOverflow, end >= address, !totalOverflow,
          updated <= maximumResourceBytes
        else { return response(.errorInvalidParameter, header: header) }
        try memory.validate(at: address, byteCount: Int(length), deviceWillWrite: false)
        entries.append(.init(guestAddress: address, length: length))
        total = updated
      }
      if lock.withLock({ rendererResources[id] != nil }) {
        guard lock.withLock({ rendererResources[id]?.backing.isEmpty == true }) else {
          return response(.errorInvalidResource, header: header)
        }
        do {
          try accelerationAuthority?.attachBacking(
            resourceID: id,
            entries: entries,
            memory: memory
          )
        } catch {
          return response(.errorInvalidParameter, header: header)
        }
        let attached = lock.withLock { () -> Bool in
          guard var resource = rendererResources[id] else { return false }
          resource.backing = entries
          rendererResources[id] = resource
          return true
        }
        return response(attached ? .okNoData : .errorInvalidResource, header: header)
      }
      let attached = lock.withLock { () -> Bool in
        guard var resource = resources[id], resource.backing.isEmpty,
          total >= UInt64(resource.pixels.count)
        else { return false }
        resource.backing = entries
        resources[id] = resource
        return true
      }
      return response(attached ? .okNoData : .errorInvalidResource, header: header)

    case .resourceDetachBacking:
      guard request.count == 32 else { return response(.errorInvalidParameter, header: header) }
      let id = read32(request, 24)
      if lock.withLock({ rendererResources[id] != nil }) {
        do {
          try accelerationAuthority?.detachBacking(resourceID: id)
        } catch {
          return response(.errorInvalidParameter, header: header)
        }
        let detached = lock.withLock { () -> Bool in
          guard var resource = rendererResources[id] else { return false }
          resource.backing = []
          rendererResources[id] = resource
          return true
        }
        return response(detached ? .okNoData : .errorInvalidResource, header: header)
      }
      let detached = lock.withLock { () -> Bool in
        guard var resource = resources[id] else { return false }
        resource.backing = []
        resources[id] = resource
        return true
      }
      return response(detached ? .okNoData : .errorInvalidResource, header: header)

    case .transferToHost2D:
      guard request.count == 56 else { return response(.errorInvalidParameter, header: header) }
      let rectangle = readRectangle(request, 24)
      let sourceOffset = read64(request, 40)
      let id = read32(request, 48)
      let transferred = try transfer(
        resourceID: id,
        rectangle: rectangle,
        sourceOffset: sourceOffset,
        memory: memory
      )
      return response(transferred ? .okNoData : .errorInvalidParameter, header: header)

    case .contextCreate:
      guard request.count == 96, header.contextID != 0,
        let accelerationAuthority
      else { return response(.errorInvalidParameter, header: header) }
      let nameLength = Int(read32(request, 24))
      let requestedCapset = read32(request, 28)
      guard nameLength <= 64, requestedCapset & ~UInt32(0xFF) == 0,
        let capsetID = resolvedCapsetID(
          requestedCapset,
          capabilities: accelerationAuthority.capabilities
        ),
        !lock.withLock({ rendererContexts.contains(header.contextID) })
      else { return response(.errorInvalidParameter, header: header) }
      let rawName = request[32..<(32 + nameLength)].prefix { $0 != 0 }
      let name = rawName.isEmpty ? "virtio-gpu" : String(decoding: rawName, as: UTF8.self)
      do {
        try accelerationAuthority.createContext(
          id: header.contextID,
          capsetID: capsetID,
          name: name
        )
      } catch {
        return response(.errorInvalidParameter, header: header)
      }
      _ = lock.withLock { rendererContexts.insert(header.contextID) }
      return response(.okNoData, header: header)

    case .contextDestroy:
      guard request.count == 24, header.contextID != 0,
        let accelerationAuthority,
        lock.withLock({ rendererContexts.contains(header.contextID) })
      else { return response(.errorInvalidParameter, header: header) }
      do {
        try accelerationAuthority.destroyContext(id: header.contextID)
      } catch {
        return response(.errorInvalidParameter, header: header)
      }
      _ = lock.withLock { rendererContexts.remove(header.contextID) }
      return response(.okNoData, header: header)

    case .contextAttachResource, .contextDetachResource:
      guard request.count == 32, header.contextID != 0,
        let accelerationAuthority
      else { return response(.errorInvalidParameter, header: header) }
      let resourceID = read32(request, 24)
      guard
        lock.withLock({
          rendererContexts.contains(header.contextID) && rendererResources[resourceID] != nil
        })
      else { return response(.errorInvalidResource, header: header) }
      do {
        if command == .contextAttachResource {
          try accelerationAuthority.attachResource(
            contextID: header.contextID,
            resourceID: resourceID
          )
        } else {
          try accelerationAuthority.detachResource(
            contextID: header.contextID,
            resourceID: resourceID
          )
        }
      } catch {
        return response(.errorInvalidParameter, header: header)
      }
      return response(.okNoData, header: header)

    case .resourceCreate3D:
      guard request.count == 72, accelerationAuthority != nil else {
        return response(.errorInvalidParameter, header: header)
      }
      let resource = DoryVirtioGPUResource3D(
        resourceID: read32(request, 24),
        target: read32(request, 28),
        format: read32(request, 32),
        bind: read32(request, 36),
        width: read32(request, 40),
        height: read32(request, 44),
        depth: read32(request, 48),
        arraySize: read32(request, 52),
        lastLevel: read32(request, 56),
        samples: read32(request, 60),
        flags: read32(request, 64)
      )
      guard valid(resource),
        lock.withLock({
          resources[resource.resourceID] == nil && rendererResources[resource.resourceID] == nil
        })
      else { return response(.errorInvalidParameter, header: header) }
      do {
        try accelerationAuthority?.createResource3D(resource)
      } catch {
        return response(.errorInvalidParameter, header: header)
      }
      lock.withLock { rendererResources[resource.resourceID] = .init(descriptor: resource) }
      return response(.okNoData, header: header)

    case .transferToHost3D, .transferFromHost3D:
      guard request.count == 72, let accelerationAuthority else {
        return response(.errorInvalidParameter, header: header)
      }
      let resourceID = read32(request, 56)
      let transfer = DoryVirtioGPUTransfer3D(
        direction: command == .transferToHost3D ? .toHost : .fromHost,
        resourceID: resourceID,
        contextID: header.contextID,
        x: read32(request, 24),
        y: read32(request, 28),
        z: read32(request, 32),
        width: read32(request, 36),
        height: read32(request, 40),
        depth: read32(request, 44),
        offset: read64(request, 48),
        level: read32(request, 60),
        stride: read32(request, 64),
        layerStride: read32(request, 68)
      )
      guard transfer.width > 0, transfer.height > 0, transfer.depth > 0,
        let entries = lock.withLock({ rendererResources[resourceID]?.backing }),
        header.contextID == 0 || lock.withLock({ rendererContexts.contains(header.contextID) })
      else { return response(.errorInvalidResource, header: header) }
      do {
        try accelerationAuthority.transfer3D(transfer, entries: entries, memory: memory)
      } catch {
        return response(.errorInvalidParameter, header: header)
      }
      return response(.okNoData, header: header)

    case .submit3D:
      guard request.count >= 32, header.contextID != 0,
        let accelerationAuthority,
        lock.withLock({ rendererContexts.contains(header.contextID) })
      else { return response(.errorInvalidParameter, header: header) }
      let byteCount = Int(read32(request, 24))
      guard byteCount > 0, byteCount.isMultiple(of: 4), request.count == 32 + byteCount else {
        return response(.errorInvalidParameter, header: header)
      }
      do {
        try accelerationAuthority.submit3D(
          contextID: header.contextID,
          command: Array(request[32...])
        )
      } catch {
        return response(.errorInvalidParameter, header: header)
      }
      return response(.okNoData, header: header)

    case .setScanout:
      guard request.count == 48 else { return response(.errorInvalidParameter, header: header) }
      let rectangle = readRectangle(request, 24)
      let scanoutID = read32(request, 40)
      let resourceID = read32(request, 44)
      guard Int(scanoutID) < scanouts.count else {
        return response(.errorInvalidScanout, header: header)
      }
      if resourceID == 0 {
        _ = lock.withLock { bindings.removeValue(forKey: scanoutID) }
        return response(.okNoData, header: header)
      }
      let bound = lock.withLock { () -> Bool in
        guard let resource = resources[resourceID], contains(rectangle, in: resource) else {
          return false
        }
        bindings[scanoutID] = .init(resourceID: resourceID, rectangle: rectangle)
        return true
      }
      return response(bound ? .okNoData : .errorInvalidResource, header: header)

    case .resourceFlush:
      guard request.count == 48 else { return response(.errorInvalidParameter, header: header) }
      let rectangle = readRectangle(request, 24)
      let resourceID = read32(request, 40)
      let flush = lock.withLock {
        () -> (Response?, [DoryVirtioGPUFrame], (any DoryVirtioGPUDisplaySink)?) in
        guard let resource = resources[resourceID], contains(rectangle, in: resource) else {
          return (
            resources[resourceID] == nil ? .errorInvalidResource : .errorInvalidParameter,
            [],
            displaySink
          )
        }
        let frames = bindings.compactMap { scanoutID, binding -> DoryVirtioGPUFrame? in
          guard binding.resourceID == resourceID else { return nil }
          return .init(
            scanoutID: scanoutID,
            resourceID: resourceID,
            scanoutRectangle: binding.rectangle,
            damagedRectangle: rectangle,
            resourceWidth: resource.width,
            resourceHeight: resource.height,
            format: resource.format,
            pixels: resource.pixels
          )
        }
        return (nil, frames, displaySink)
      }
      if let error = flush.0 { return response(error, header: header) }
      for frame in flush.1 { flush.2?.present(frame) }
      return response(.okNoData, header: header)

    case .updateCursor:
      // Cursor commands are accepted so the standard cursor queue remains usable. Host cursor
      // composition is layered above the 2D framebuffer sink and does not alter scanout pixels.
      guard request.count == 56 else { return response(.errorInvalidParameter, header: header) }
      let scanoutID = read32(request, 24)
      guard Int(scanoutID) < scanouts.count else {
        return response(.errorInvalidScanout, header: header)
      }
      let resourceID = read32(request, 40)
      let hotX = read32(request, 44)
      let hotY = read32(request, 48)
      let valid =
        resourceID == 0
        || lock.withLock {
          guard let resource = resources[resourceID] else { return false }
          return resource.width == 64 && resource.height == 64 && hotX < 64 && hotY < 64
        }
      return response(valid ? .okNoData : .errorInvalidResource, header: header)

    case .moveCursor:
      guard request.count == 56 else { return response(.errorInvalidParameter, header: header) }
      let scanoutID = read32(request, 24)
      return response(
        Int(scanoutID) < scanouts.count ? .okNoData : .errorInvalidScanout,
        header: header
      )
    }
  }

  private func transfer(
    resourceID: UInt32,
    rectangle: DoryVirtioGPURectangle,
    sourceOffset: UInt64,
    memory: any DoryVirtioGuestMemory
  ) throws -> Bool {
    let snapshot = lock.withLock { resources[resourceID] }
    guard let snapshot, !snapshot.backing.isEmpty, contains(rectangle, in: snapshot) else {
      return false
    }
    let rowBytes = UInt64(rectangle.width) * UInt64(snapshot.format.bytesPerPixel)
    let stride = UInt64(snapshot.width) * UInt64(snapshot.format.bytesPerPixel)
    var updated = snapshot
    for row in 0..<UInt64(rectangle.height) {
      let (rowStride, multiplyOverflow) = row.multipliedReportingOverflow(by: stride)
      let (logicalOffset, addOverflow) = sourceOffset.addingReportingOverflow(rowStride)
      guard !multiplyOverflow, !addOverflow,
        logicalOffset <= UInt64(updated.pixels.count),
        rowBytes <= UInt64(updated.pixels.count) - logicalOffset
      else { return false }
      let bytes = try readBacking(
        updated.backing,
        offset: logicalOffset,
        byteCount: Int(rowBytes),
        memory: memory
      )
      let destination =
        (UInt64(rectangle.y) + row) * stride
        + UInt64(rectangle.x) * UInt64(updated.format.bytesPerPixel)
      updated.pixels.replaceSubrange(
        Int(destination)..<(Int(destination) + bytes.count),
        with: bytes
      )
    }
    return lock.withLock {
      guard let current = resources[resourceID], current.width == updated.width,
        current.height == updated.height, current.format == updated.format,
        current.backing == updated.backing
      else { return false }
      resources[resourceID] = updated
      return true
    }
  }

  private func readBacking(
    _ entries: [DoryVirtioGPUBackingEntry],
    offset: UInt64,
    byteCount: Int,
    memory: any DoryVirtioGuestMemory
  ) throws -> [UInt8] {
    var skip = offset
    var remaining = byteCount
    var result: [UInt8] = []
    result.reserveCapacity(byteCount)
    for entry in entries {
      if skip >= UInt64(entry.length) {
        skip -= UInt64(entry.length)
        continue
      }
      let available = UInt64(entry.length) - skip
      let count = min(remaining, Int(available))
      let (address, overflow) = entry.guestAddress.addingReportingOverflow(skip)
      guard !overflow else { throw DoryVirtioGPUError.guestAddressOverflow }
      result += try memory.read(at: address, byteCount: count)
      remaining -= count
      skip = 0
      if remaining == 0 { break }
    }
    guard remaining == 0 else { throw DoryVirtioGPUError.malformedRequest }
    return result
  }

  private func response(_ type: Response, header: Header) -> [UInt8] {
    var flags = header.flags & 1
    if header.flags & 1 == 0 { flags = 0 }
    return littleEndian(type.rawValue) + littleEndian(flags) + littleEndian(header.fenceID)
      + littleEndian(header.contextID) + [header.ringIndex, 0, 0, 0]
  }

  private func gather(
    _ descriptors: [DoryVirtioDescriptor],
    memory: any DoryVirtioGuestMemory
  ) throws -> [UInt8] {
    guard descriptors.reduce(UInt64(0), { $0 + UInt64($1.length) }) <= maximumResourceBytes else {
      throw DoryVirtioGPUError.requestTooLarge(
        descriptors.reduce(UInt64(0), { $0 + UInt64($1.length) })
      )
    }
    var bytes: [UInt8] = []
    for descriptor in descriptors {
      let part = try memory.read(at: descriptor.address, byteCount: Int(descriptor.length))
      guard part.count == Int(descriptor.length) else {
        throw DoryVirtioGPUError.malformedRequest
      }
      bytes += part
    }
    return bytes
  }

  private func scatter(
    _ bytes: [UInt8],
    into descriptors: [DoryVirtioDescriptor],
    memory: any DoryVirtioGuestMemory
  ) throws {
    var offset = 0
    for descriptor in descriptors where offset < bytes.count {
      let count = min(Int(descriptor.length), bytes.count - offset)
      try memory.write(
        at: descriptor.address,
        bytes: Array(bytes[offset..<(offset + count)])
      )
      offset += count
    }
    guard offset == bytes.count else { throw DoryVirtioGPUError.malformedRequest }
  }

  private func resourceByteCount(width: UInt32, height: UInt32) -> UInt64? {
    let (pixels, overflow) = UInt64(width).multipliedReportingOverflow(by: UInt64(height))
    let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(by: 4)
    return overflow || byteOverflow ? nil : bytes
  }

  private static func valid(_ rectangle: DoryVirtioGPURectangle) -> Bool {
    let (_, xOverflow) = rectangle.x.addingReportingOverflow(rectangle.width)
    let (_, yOverflow) = rectangle.y.addingReportingOverflow(rectangle.height)
    return !xOverflow && !yOverflow && valid(width: rectangle.width, height: rectangle.height)
  }

  private static func valid(width: UInt32, height: UInt32) -> Bool {
    width > 0 && height > 0 && width <= 16_384 && height <= 16_384
  }

  private func valid(_ resource: DoryVirtioGPUResource3D) -> Bool {
    let widthIsValid =
      resource.target == 0
      ? resource.width > 0 && UInt64(resource.width) <= maximumResourceBytes
      : resource.width > 0 && resource.width <= 16_384
    return resource.resourceID != 0 && resource.format != 0 && widthIsValid
      && (1...16_384).contains(resource.height)
      && (1...16_384).contains(resource.depth)
      && (1...16_384).contains(resource.arraySize)
      && resource.lastLevel <= 31 && resource.samples <= 64
  }

  private func resolvedCapsetID(
    _ requested: UInt32,
    capabilities: DoryVirtioGPUAccelerationCapabilities
  ) -> UInt32? {
    let requestedID = requested & 0xFF
    if requestedID != 0 {
      return capabilities.capsets.contains(where: { $0.id == requestedID }) ? requestedID : nil
    }
    if capabilities.capsets.contains(where: { $0.id == 2 }) { return 2 }
    return capabilities.capsets.count == 1 ? capabilities.capsets[0].id : nil
  }

  private func contains(_ rectangle: DoryVirtioGPURectangle, in resource: Resource) -> Bool {
    guard rectangle.width > 0, rectangle.height > 0 else { return false }
    let (right, xOverflow) = rectangle.x.addingReportingOverflow(rectangle.width)
    let (bottom, yOverflow) = rectangle.y.addingReportingOverflow(rectangle.height)
    return !xOverflow && !yOverflow && right <= resource.width && bottom <= resource.height
  }

  private func readRectangle(_ bytes: [UInt8], _ offset: Int) -> DoryVirtioGPURectangle {
    .init(
      x: read32(bytes, offset),
      y: read32(bytes, offset + 4),
      width: read32(bytes, offset + 8),
      height: read32(bytes, offset + 12)
    )
  }

  private func rectangleBytes(_ rectangle: DoryVirtioGPURectangle) -> [UInt8] {
    littleEndian(rectangle.x) + littleEndian(rectangle.y)
      + littleEndian(rectangle.width) + littleEndian(rectangle.height)
  }
}

private func read32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
  (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << UInt32($1 * 8) }
}

private func read64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
  (0..<8).reduce(0) { $0 | UInt64(bytes[offset + $1]) << UInt64($1 * 8) }
}

private func littleEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
  (0..<MemoryLayout<T>.size).map { UInt8(truncatingIfNeeded: value >> T($0 * 8)) }
}
