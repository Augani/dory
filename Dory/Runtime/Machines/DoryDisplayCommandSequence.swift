/// The display broker orders commands across all app connections to one runtime.
/// A process-local counter alone restarts at one when a window app relaunches.
/// System uptime survives that relaunch; the local cursor handles equal clock ticks.
nonisolated struct DoryDisplayCommandSequence: Sendable {
  private(set) var lastSequence: UInt64 = 0

  mutating func next(uptimeNanoseconds: UInt64) -> UInt64? {
    guard uptimeNanoseconds > 0, lastSequence < UInt64.max else { return nil }
    let sequence = max(lastSequence + 1, uptimeNanoseconds)
    guard sequence < UInt64.max else { return nil }
    lastSequence = sequence
    return sequence
  }
}
