import Foundation

/// One explicit Mac clipboard action, serialized with its owner on the main actor. A runtime
/// generation survives Guest Tools reconnect, so authority binds the exact healthy connection.
@MainActor
final class DoryVZMacClipboardActionAuthority {
  struct Ticket: Sendable, Equatable {
    fileprivate let id: UUID
    fileprivate let focusGeneration: UUID
    let sessionIdentity: UUID
    let pasteboardChangeCount: Int
    let startedAtUptimeNanoseconds: UInt64
    let deadlineUptimeNanoseconds: UInt64
  }

  private var focusGeneration = UUID()
  private var current: Ticket?

  func begin(
    sessionIdentity: UUID?, pasteboardChangeCount: Int, isInteractive: Bool,
    nowUptimeNanoseconds: UInt64, timeoutNanoseconds: UInt64
  ) -> Ticket? {
    guard isInteractive, let sessionIdentity, current == nil, timeoutNanoseconds > 0 else {
      return nil
    }
    let deadline = nowUptimeNanoseconds.addingReportingOverflow(timeoutNanoseconds)
    guard !deadline.overflow else { return nil }
    let ticket = Ticket(id: UUID(), focusGeneration: focusGeneration,
      sessionIdentity: sessionIdentity, pasteboardChangeCount: pasteboardChangeCount,
      startedAtUptimeNanoseconds: nowUptimeNanoseconds,
      deadlineUptimeNanoseconds: deadline.partialValue)
    current = ticket
    return ticket
  }

  func owns(_ ticket: Ticket) -> Bool { current == ticket }
  var isBusy: Bool { current != nil }

  func permits(
    _ ticket: Ticket, sessionIdentity: UUID?, pasteboardChangeCount: Int,
    isInteractive: Bool, nowUptimeNanoseconds: UInt64
  ) -> Bool {
    current == ticket && ticket.focusGeneration == focusGeneration && isInteractive
      && sessionIdentity == ticket.sessionIdentity
      && pasteboardChangeCount == ticket.pasteboardChangeCount
      && nowUptimeNanoseconds >= ticket.startedAtUptimeNanoseconds
      && nowUptimeNanoseconds < ticket.deadlineUptimeNanoseconds
  }

  /// No suspension may occur between this final check and the caller's AppKit mutation.
  @discardableResult
  func performIfCurrent(
    _ ticket: Ticket, sessionIdentity: UUID?, pasteboardChangeCount: Int,
    isInteractive: Bool, nowUptimeNanoseconds: UInt64, mutation: () throws -> Void
  ) rethrows -> Bool {
    guard permits(ticket, sessionIdentity: sessionIdentity,
      pasteboardChangeCount: pasteboardChangeCount, isInteractive: isInteractive,
      nowUptimeNanoseconds: nowUptimeNanoseconds) else { return false }
    try mutation()
    return true
  }

  /// Old completion/deadline callbacks can retire only their own task, never its successor.
  @discardableResult
  func finish(_ ticket: Ticket) -> Bool {
    guard current == ticket else { return false }
    current = nil
    return true
  }

  func revoke() {
    focusGeneration = UUID()
    current = nil
  }
}
