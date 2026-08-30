import Foundation

public enum DoryPCProcessorLifecycle: String, Codable, Sendable, Hashable {
  case running
  case waitingForStartup
}

public enum DoryPCProcessorEvent: Sendable, Hashable {
  case initialize(apicID: UInt32)
  case startup(apicID: UInt32, vector: UInt8)
  case nonMaskableInterrupt(apicID: UInt32)
}

public enum DoryPCMultiprocessorError: Error, Sendable, Equatable {
  case emptyTopology
  case duplicateAPICID(UInt32)
  case invalidDeliveryMode(UInt8)
  case logicalDestinationUnsupported
  case missingDestination(UInt32)
}

public struct DoryPCProcessorTopologySnapshot: Sendable, Hashable {
  public let lifecycles: [UInt32: DoryPCProcessorLifecycle]
  public let pendingEvents: [DoryPCProcessorEvent]
}

/// Physical-destination xAPIC ICR and AP startup state shared by every execution engine.
public final class DoryPCMultiprocessorController: @unchecked Sendable {
  public let localAPICs: [DoryPCLocalAPIC]

  private let lock = NSLock()
  private let apicsByID: [UInt32: DoryPCLocalAPIC]
  private var lifecycles: [UInt32: DoryPCProcessorLifecycle]
  private var pendingEvents: [DoryPCProcessorEvent] = []

  public init(localAPICs: [DoryPCLocalAPIC]) throws {
    guard !localAPICs.isEmpty else { throw DoryPCMultiprocessorError.emptyTopology }
    var byID: [UInt32: DoryPCLocalAPIC] = [:]
    for apic in localAPICs {
      guard byID.updateValue(apic, forKey: apic.apicID) == nil else {
        throw DoryPCMultiprocessorError.duplicateAPICID(apic.apicID)
      }
    }
    self.localAPICs = localAPICs
    apicsByID = byID
    lifecycles = Dictionary(
      uniqueKeysWithValues: localAPICs.map {
        ($0.apicID, $0.apicID == localAPICs[0].apicID ? .running : .waitingForStartup)
      }
    )
  }

  public func handleInterruptCommand(sourceAPICID: UInt32, high: UInt32, low: UInt32) throws {
    guard low & (1 << 11) == 0 else {
      throw DoryPCMultiprocessorError.logicalDestinationUnsupported
    }
    let targets = try resolvedTargets(sourceAPICID: sourceAPICID, high: high, low: low)
    let deliveryMode = UInt8(truncatingIfNeeded: low >> 8) & 0x7
    let vector = UInt8(truncatingIfNeeded: low)
    switch deliveryMode {
    case 0:
      for target in targets { try target.inject(vector: vector) }
    case 1:
      if let target = targets.min(by: { $0.apicID < $1.apicID }) {
        try target.inject(vector: vector)
      }
    case 4:
      lock.withLock {
        for target in targets where lifecycles[target.apicID] == .running {
          pendingEvents.append(.nonMaskableInterrupt(apicID: target.apicID))
        }
      }
    case 5:
      // An INIT deassert command completes the electrical handshake but does not reset twice.
      guard low & (1 << 14) != 0 || low & (1 << 15) == 0 else { return }
      lock.withLock {
        for target in targets {
          lifecycles[target.apicID] = .waitingForStartup
          pendingEvents.append(.initialize(apicID: target.apicID))
        }
      }
    case 6:
      lock.withLock {
        for target in targets where lifecycles[target.apicID] == .waitingForStartup {
          lifecycles[target.apicID] = .running
          pendingEvents.append(.startup(apicID: target.apicID, vector: vector))
        }
      }
    default:
      throw DoryPCMultiprocessorError.invalidDeliveryMode(deliveryMode)
    }
  }

  public func drainEvents() -> [DoryPCProcessorEvent] {
    lock.withLock {
      defer { pendingEvents.removeAll(keepingCapacity: true) }
      return pendingEvents
    }
  }

  public func snapshot() -> DoryPCProcessorTopologySnapshot {
    lock.withLock { .init(lifecycles: lifecycles, pendingEvents: pendingEvents) }
  }

  private func resolvedTargets(
    sourceAPICID: UInt32,
    high: UInt32,
    low: UInt32
  ) throws -> [DoryPCLocalAPIC] {
    switch (low >> 18) & 0x3 {
    case 1:
      guard let source = apicsByID[sourceAPICID] else {
        throw DoryPCMultiprocessorError.missingDestination(sourceAPICID)
      }
      return [source]
    case 2:
      return localAPICs
    case 3:
      return localAPICs.filter { $0.apicID != sourceAPICID }
    default:
      let destination = high >> 24
      guard let target = apicsByID[destination] else {
        throw DoryPCMultiprocessorError.missingDestination(destination)
      }
      return [target]
    }
  }
}
