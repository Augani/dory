import Foundation

public struct DoryVirtioGPUBackingEntry: Sendable, Hashable {
  public let guestAddress: UInt64
  public let length: UInt32

  public init(guestAddress: UInt64, length: UInt32) {
    self.guestAddress = guestAddress
    self.length = length
  }
}

public struct DoryVirtioGPUResource3D: Sendable, Hashable {
  public let resourceID: UInt32
  public let target: UInt32
  public let format: UInt32
  public let bind: UInt32
  public let width: UInt32
  public let height: UInt32
  public let depth: UInt32
  public let arraySize: UInt32
  public let lastLevel: UInt32
  public let samples: UInt32
  public let flags: UInt32

  public init(
    resourceID: UInt32,
    target: UInt32,
    format: UInt32,
    bind: UInt32,
    width: UInt32,
    height: UInt32,
    depth: UInt32,
    arraySize: UInt32,
    lastLevel: UInt32,
    samples: UInt32,
    flags: UInt32
  ) {
    self.resourceID = resourceID
    self.target = target
    self.format = format
    self.bind = bind
    self.width = width
    self.height = height
    self.depth = depth
    self.arraySize = arraySize
    self.lastLevel = lastLevel
    self.samples = samples
    self.flags = flags
  }
}

public struct DoryVirtioGPUTransfer3D: Sendable, Hashable {
  public enum Direction: Sendable, Hashable {
    case toHost
    case fromHost
  }

  public let direction: Direction
  public let resourceID: UInt32
  public let contextID: UInt32
  public let x: UInt32
  public let y: UInt32
  public let z: UInt32
  public let width: UInt32
  public let height: UInt32
  public let depth: UInt32
  public let offset: UInt64
  public let level: UInt32
  public let stride: UInt32
  public let layerStride: UInt32

  public init(
    direction: Direction,
    resourceID: UInt32,
    contextID: UInt32,
    x: UInt32,
    y: UInt32,
    z: UInt32,
    width: UInt32,
    height: UInt32,
    depth: UInt32,
    offset: UInt64,
    level: UInt32,
    stride: UInt32,
    layerStride: UInt32
  ) {
    self.direction = direction
    self.resourceID = resourceID
    self.contextID = contextID
    self.x = x
    self.y = y
    self.z = z
    self.width = width
    self.height = height
    self.depth = depth
    self.offset = offset
    self.level = level
    self.stride = stride
    self.layerStride = layerStride
  }
}

public enum DoryVirtioGPUAccelerationError: Error, Sendable, Equatable {
  case unsupportedOperation
}

extension DoryVirtioGPUAccelerationAuthority {
  public func createContext(id: UInt32, capsetID: UInt32, name: String) throws {
    throw DoryVirtioGPUAccelerationError.unsupportedOperation
  }

  public func destroyContext(id: UInt32) throws {
    throw DoryVirtioGPUAccelerationError.unsupportedOperation
  }

  public func attachResource(contextID: UInt32, resourceID: UInt32) throws {
    throw DoryVirtioGPUAccelerationError.unsupportedOperation
  }

  public func detachResource(contextID: UInt32, resourceID: UInt32) throws {
    throw DoryVirtioGPUAccelerationError.unsupportedOperation
  }

  public func submit3D(contextID: UInt32, command: [UInt8]) throws {
    throw DoryVirtioGPUAccelerationError.unsupportedOperation
  }

  public func createResource3D(_ resource: DoryVirtioGPUResource3D) throws {
    throw DoryVirtioGPUAccelerationError.unsupportedOperation
  }

  public func attachBacking(resourceID: UInt32, entries: [DoryVirtioGPUBackingEntry]) throws {
    throw DoryVirtioGPUAccelerationError.unsupportedOperation
  }

  public func detachBacking(resourceID: UInt32) throws {
    throw DoryVirtioGPUAccelerationError.unsupportedOperation
  }

  public func transfer3D(
    _ transfer: DoryVirtioGPUTransfer3D,
    entries: [DoryVirtioGPUBackingEntry]
  ) throws {
    throw DoryVirtioGPUAccelerationError.unsupportedOperation
  }

  public func unrefResource(resourceID: UInt32) throws {
    throw DoryVirtioGPUAccelerationError.unsupportedOperation
  }
}
