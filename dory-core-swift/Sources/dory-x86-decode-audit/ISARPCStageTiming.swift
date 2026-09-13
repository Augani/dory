import Foundation

// P2-05 item 4: Separate host orchestration/RPC latency from guest execution.
// Measure the distinct stages of a command's lifecycle:
//   command submitted → daemon accepted → transport delivered →
//   guest scheduled → command started → process exited → reply received
//
// Each stage is recorded as a monotonic timestamp. The deltas between
// stages give the latency breakdown. This separates host orchestration
// overhead from actual guest execution time.

/// P2-05 item 4: RPC stage timing for one command lifecycle.
/// All timestamps are host monotonic nanoseconds (DispatchTime.uptimeNanoseconds).
public struct ISARPCStageTiming: Codable, Sendable, Hashable {
  public let commandSubmittedNanoseconds: UInt64
  public let daemonAcceptedNanoseconds: UInt64?
  public let transportDeliveredNanoseconds: UInt64?
  public let guestScheduledNanoseconds: UInt64?
  public let commandStartedNanoseconds: UInt64?
  public let processExitedNanoseconds: UInt64?
  public let replyReceivedNanoseconds: UInt64?

  public init(
    commandSubmittedNanoseconds: UInt64,
    daemonAcceptedNanoseconds: UInt64? = nil,
    transportDeliveredNanoseconds: UInt64? = nil,
    guestScheduledNanoseconds: UInt64? = nil,
    commandStartedNanoseconds: UInt64? = nil,
    processExitedNanoseconds: UInt64? = nil,
    replyReceivedNanoseconds: UInt64? = nil
  ) {
    self.commandSubmittedNanoseconds = commandSubmittedNanoseconds
    self.daemonAcceptedNanoseconds = daemonAcceptedNanoseconds
    self.transportDeliveredNanoseconds = transportDeliveredNanoseconds
    self.guestScheduledNanoseconds = guestScheduledNanoseconds
    self.commandStartedNanoseconds = commandStartedNanoseconds
    self.processExitedNanoseconds = processExitedNanoseconds
    self.replyReceivedNanoseconds = replyReceivedNanoseconds
  }

  /// Latency from command submission to daemon acceptance (host orchestration).
  public var submissionToAcceptanceNanoseconds: UInt64? {
    guard let accepted = daemonAcceptedNanoseconds else { return nil }
    return accepted &- commandSubmittedNanoseconds
  }

  /// Latency from daemon acceptance to transport delivery (host transport).
  public var acceptanceToDeliveryNanoseconds: UInt64? {
    guard let accepted = daemonAcceptedNanoseconds,
      let delivered = transportDeliveredNanoseconds else { return nil }
    return delivered &- accepted
  }

  /// Latency from transport delivery to guest scheduling (guest scheduling).
  public var deliveryToSchedulingNanoseconds: UInt64? {
    guard let delivered = transportDeliveredNanoseconds,
      let scheduled = guestScheduledNanoseconds else { return nil }
    return scheduled &- delivered
  }

  /// Latency from guest scheduling to command start (guest dispatch).
  public var schedulingToStartNanoseconds: UInt64? {
    guard let scheduled = guestScheduledNanoseconds,
      let started = commandStartedNanoseconds else { return nil }
    return started &- scheduled
  }

  /// Actual guest execution time: from command start to process exit.
  public var guestExecutionNanoseconds: UInt64? {
    guard let started = commandStartedNanoseconds,
      let exited = processExitedNanoseconds else { return nil }
    return exited &- started
  }

  /// Latency from process exit to reply received (host reply transport).
  public var exitToReplyNanoseconds: UInt64? {
    guard let exited = processExitedNanoseconds,
      let reply = replyReceivedNanoseconds else { return nil }
    return reply &- exited
  }

  /// Total host orchestration latency (everything except guest execution).
  public var totalHostOrchestrationNanoseconds: UInt64? {
    guard let reply = replyReceivedNanoseconds else { return nil }
    let guest = guestExecutionNanoseconds ?? 0
    return reply &- commandSubmittedNanoseconds &- guest
  }

  /// Total end-to-end latency.
  public var totalLatencyNanoseconds: UInt64? {
    guard let reply = replyReceivedNanoseconds else { return nil }
    return reply &- commandSubmittedNanoseconds
  }
}

/// P2-05 item 4: A builder for RPC stage timing that records timestamps
/// as the command progresses through its lifecycle.
public final class ISARPCStageTimingBuilder: @unchecked Sendable {
  private let lock = NSLock()
  private var timing: ISARPCStageTiming

  public init() {
    timing = .init(commandSubmittedNanoseconds: DispatchTime.now().uptimeNanoseconds)
  }

  public func recordDaemonAccepted() {
    lock.withLock {
      timing = .init(
        commandSubmittedNanoseconds: timing.commandSubmittedNanoseconds,
        daemonAcceptedNanoseconds: DispatchTime.now().uptimeNanoseconds,
        transportDeliveredNanoseconds: timing.transportDeliveredNanoseconds,
        guestScheduledNanoseconds: timing.guestScheduledNanoseconds,
        commandStartedNanoseconds: timing.commandStartedNanoseconds,
        processExitedNanoseconds: timing.processExitedNanoseconds,
        replyReceivedNanoseconds: timing.replyReceivedNanoseconds)
    }
  }

  public func recordTransportDelivered() {
    lock.withLock {
      timing = .init(
        commandSubmittedNanoseconds: timing.commandSubmittedNanoseconds,
        daemonAcceptedNanoseconds: timing.daemonAcceptedNanoseconds,
        transportDeliveredNanoseconds: DispatchTime.now().uptimeNanoseconds,
        guestScheduledNanoseconds: timing.guestScheduledNanoseconds,
        commandStartedNanoseconds: timing.commandStartedNanoseconds,
        processExitedNanoseconds: timing.processExitedNanoseconds,
        replyReceivedNanoseconds: timing.replyReceivedNanoseconds)
    }
  }

  public func recordGuestScheduled() {
    lock.withLock {
      timing = .init(
        commandSubmittedNanoseconds: timing.commandSubmittedNanoseconds,
        daemonAcceptedNanoseconds: timing.daemonAcceptedNanoseconds,
        transportDeliveredNanoseconds: timing.transportDeliveredNanoseconds,
        guestScheduledNanoseconds: DispatchTime.now().uptimeNanoseconds,
        commandStartedNanoseconds: timing.commandStartedNanoseconds,
        processExitedNanoseconds: timing.processExitedNanoseconds,
        replyReceivedNanoseconds: timing.replyReceivedNanoseconds)
    }
  }

  public func recordCommandStarted() {
    lock.withLock {
      timing = .init(
        commandSubmittedNanoseconds: timing.commandSubmittedNanoseconds,
        daemonAcceptedNanoseconds: timing.daemonAcceptedNanoseconds,
        transportDeliveredNanoseconds: timing.transportDeliveredNanoseconds,
        guestScheduledNanoseconds: timing.guestScheduledNanoseconds,
        commandStartedNanoseconds: DispatchTime.now().uptimeNanoseconds,
        processExitedNanoseconds: timing.processExitedNanoseconds,
        replyReceivedNanoseconds: timing.replyReceivedNanoseconds)
    }
  }

  public func recordProcessExited() {
    lock.withLock {
      timing = .init(
        commandSubmittedNanoseconds: timing.commandSubmittedNanoseconds,
        daemonAcceptedNanoseconds: timing.daemonAcceptedNanoseconds,
        transportDeliveredNanoseconds: timing.transportDeliveredNanoseconds,
        guestScheduledNanoseconds: timing.guestScheduledNanoseconds,
        commandStartedNanoseconds: timing.commandStartedNanoseconds,
        processExitedNanoseconds: DispatchTime.now().uptimeNanoseconds,
        replyReceivedNanoseconds: timing.replyReceivedNanoseconds)
    }
  }

  public func recordReplyReceived() {
    lock.withLock {
      timing = .init(
        commandSubmittedNanoseconds: timing.commandSubmittedNanoseconds,
        daemonAcceptedNanoseconds: timing.daemonAcceptedNanoseconds,
        transportDeliveredNanoseconds: timing.transportDeliveredNanoseconds,
        guestScheduledNanoseconds: timing.guestScheduledNanoseconds,
        commandStartedNanoseconds: timing.commandStartedNanoseconds,
        processExitedNanoseconds: timing.processExitedNanoseconds,
        replyReceivedNanoseconds: DispatchTime.now().uptimeNanoseconds)
    }
  }

  public func build() -> ISARPCStageTiming {
    lock.withLock { timing }
  }
}
