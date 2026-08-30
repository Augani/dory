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
    case updateCursor = 0x0300
    case moveCursor = 0x0301
  }

  private enum Response: UInt32 {
    case okNoData = 0x1100
    case okDisplayInfo = 0x1101
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

  private struct BackingEntry: Sendable, Hashable {
    let address: UInt64
    let length: UInt32
  }

  private struct Resource {
    let id: UInt32
    let format: DoryVirtioGPUFormat
    let width: UInt32
    let height: UInt32
    var backing: [BackingEntry] = []
    var pixels: [UInt8]
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
  private var resources: [UInt32: Resource] = [:]
  private var bindings: [UInt32: ScanoutBinding] = [:]

  public init(
    scanouts: [DoryVirtioGPUScanout],
    maximumResourceBytes: UInt64 = 256 * 1024 * 1024,
    maximumBackingEntries: Int = 65_536,
    displaySink: (any DoryVirtioGPUDisplaySink)? = nil
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
  }

  public var offeredFeatures: DoryVirtioFeatures { [] }

  /// `events_read`, `events_clear`, `num_scanouts`, `num_capsets`.
  public var configuration: [UInt8] {
    littleEndian(UInt32(0)) + littleEndian(UInt32(0))
      + littleEndian(UInt32(scanouts.count)) + littleEndian(UInt32(0))
  }

  public func connectDisplaySink(_ sink: (any DoryVirtioGPUDisplaySink)?) {
    lock.withLock { displaySink = sink }
  }

  public func reset() {
    lock.withLock {
      resources.removeAll(keepingCapacity: true)
      bindings.removeAll(keepingCapacity: true)
    }
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
        guard resources[id] == nil else { return false }
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
      let removed = lock.withLock { () -> Bool in
        guard resources.removeValue(forKey: id) != nil else { return false }
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
      var entries: [BackingEntry] = []
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
        entries.append(.init(address: address, length: length))
        total = updated
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
    _ entries: [BackingEntry],
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
      let (address, overflow) = entry.address.addingReportingOverflow(skip)
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
