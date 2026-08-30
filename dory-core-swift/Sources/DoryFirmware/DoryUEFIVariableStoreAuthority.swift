import Foundation

/// Type-erased, path-free persistence interface consumed by firmware/runtime code.
public struct DoryUEFIVariableStoreAuthority: @unchecked Sendable {
  private let loadImplementation: @Sendable () throws -> DoryUEFIVariableStoreLoad
  private let commitImplementation:
    @Sendable (DoryUEFIVariableStoreSnapshot, UInt64) throws -> Void

  public init(file: DoryUEFIVariableStoreFile) {
    loadImplementation = { try file.load() }
    commitImplementation = { snapshot, generation in
      try file.commit(snapshot, expectedGeneration: generation)
    }
  }

  public init(directoryDescriptor: DoryUEFIVariableStoreDirectoryDescriptor) {
    loadImplementation = { try directoryDescriptor.load() }
    commitImplementation = { snapshot, generation in
      try directoryDescriptor.commit(snapshot, expectedGeneration: generation)
    }
  }

  public func load() throws -> DoryUEFIVariableStoreLoad {
    try loadImplementation()
  }

  public func commit(
    _ snapshot: DoryUEFIVariableStoreSnapshot,
    expectedGeneration: UInt64
  ) throws {
    try commitImplementation(snapshot, expectedGeneration)
  }
}
