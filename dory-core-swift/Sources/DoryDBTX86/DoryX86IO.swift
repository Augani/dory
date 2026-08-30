import Foundation

/// Device boundary for x86 port-mapped I/O. Implementations own device synchronization and
/// must either complete an access exactly once or throw before exposing a partial device change.
public protocol DoryX86IOBus: AnyObject, Sendable {
  func read(port: UInt16, width: DoryX86OperandWidth) throws -> UInt32
  func write(port: UInt16, value: UInt32, width: DoryX86OperandWidth) throws
}

public enum DoryX86IOBusError: Error, Codable, Sendable, Hashable {
  case unmappedPort(UInt16, width: DoryX86OperandWidth)
}
