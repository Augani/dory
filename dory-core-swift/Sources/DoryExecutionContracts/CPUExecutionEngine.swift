public protocol DoryCPUExecutionEngine: AnyObject, Sendable {
  associatedtype ArchitecturalState: Codable & Sendable

  var architecture: DoryExecutionArchitecture { get }
  var executionGeneration: UInt64 { get }

  func createVCPU(
    id: DoryVCPUIdentifier,
    initialState: ArchitecturalState
  ) throws -> DoryVCPU
  func reset(_ vcpu: DoryVCPU, to state: ArchitecturalState) throws
  func mapMemory(_ region: DoryGuestMemoryRegion) throws
  func unmapMemory(_ range: DoryGuestAddressRange, mappingGeneration: UInt64) throws
  func inject(_ interrupt: DoryArchitecturalInterrupt, into vcpu: DoryVCPU) throws
  func acknowledgeInterrupt(on vcpu: DoryVCPU) throws -> DoryInterruptAcknowledgement?
  func run(_ vcpu: DoryVCPU, until deadline: DoryVirtualDeadline?) throws -> DoryCPUExit
  func pause(at barrier: DorySnapshotBarrierProgress) throws
  func resume(after barrier: DorySnapshotBarrierProgress) throws
  func cancel(_ request: DoryExecutionCancellationRequest) throws
  func captureState() throws -> [DoryVCPUArchitecturalState<ArchitecturalState>]
  func dirtyPages(in region: DoryGuestMemoryRegion, since epoch: UInt64) throws -> DoryDirtyPageSet
}
