public protocol DoryCPUExecutionEngine: AnyObject, Sendable {
  associatedtype ArchitecturalState: Codable & Sendable

  var architecture: DoryExecutionArchitecture { get }
  var executionGeneration: UInt64 { get }

  func createVCPU(
    id: DoryVCPUIdentifier,
    initialState: ArchitecturalState
  ) throws -> DoryVCPU
  /// Must execute on the same engine-owned thread that created the vCPU.
  func destroyVCPU(_ vcpu: DoryVCPU) throws
  func reset(_ vcpu: DoryVCPU, to state: ArchitecturalState) throws
  func mapMemory(_ mapping: DoryGuestMemoryMapping) throws
  func unmapMemory(_ range: DoryGuestAddressRange, mappingGeneration: UInt64) throws
  func inject(_ interrupt: DoryArchitecturalInterrupt, into vcpu: DoryVCPU) throws
  func acknowledgeInterrupt(on vcpu: DoryVCPU) throws -> DoryInterruptAcknowledgement?
  func run(_ vcpu: DoryVCPU, until deadline: DoryVirtualDeadline?) throws -> DoryCPUExit
  func complete(_ token: DoryExecutionResumeToken, with response: DoryCPUExitResponse) throws
  func pause(_ vcpu: DoryVCPU, at barrier: DorySnapshotBarrierProgress) throws
  func resume(_ vcpu: DoryVCPU, after barrier: DorySnapshotBarrierProgress) throws
  func cancel(_ request: DoryExecutionCancellationRequest) throws
  /// Must execute on the vCPU's owning thread after it has reached the requested barrier.
  func captureState(of vcpu: DoryVCPU) throws -> DoryVCPUArchitecturalState<ArchitecturalState>
  func dirtyPages(in region: DoryGuestMemoryRegion, since epoch: UInt64) throws -> DoryDirtyPageSet
}
