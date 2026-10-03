import AppKit
import Foundation
import Testing
@testable import DoryVMMKit

@MainActor
@Suite(.serialized) struct DoryVZMacClipboardActionAuthorityTests {
  @Test func healthyExactActionPublishesToOnlyItsNamedPasteboard() throws {
    let board = makePasteboard()
    defer { board.releaseGlobally() }
    let authority = DoryVZMacClipboardActionAuthority()
    let session = UUID()
    let ticket = try #require(authority.begin(sessionIdentity: session,
      pasteboardChangeCount: board.changeCount, isInteractive: true,
      nowUptimeNanoseconds: 10, timeoutNanoseconds: 100))
    let published = authority.performIfCurrent(ticket, sessionIdentity: session,
      pasteboardChangeCount: board.changeCount, isInteractive: true,
      nowUptimeNanoseconds: 20) {
      board.clearContents()
      #expect(board.setString("guest copy", forType: .string))
    }
    #expect(published)
    #expect(board.string(forType: .string) == "guest copy")
    let finished = authority.finish(ticket)
    #expect(finished)
    #expect(!authority.isBusy)
  }

  @Test func slowGuestResultCannotOverwriteANewerHostCopy() throws {
    let board = makePasteboard()
    defer { board.releaseGlobally() }
    let authority = DoryVZMacClipboardActionAuthority()
    let session = UUID()
    let ticket = try #require(authority.begin(sessionIdentity: session,
      pasteboardChangeCount: board.changeCount, isInteractive: true,
      nowUptimeNanoseconds: 10, timeoutNanoseconds: 100))
    board.clearContents()
    board.setString("new host copy", forType: .string)
    let published = authority.performIfCurrent(ticket, sessionIdentity: session,
      pasteboardChangeCount: board.changeCount, isInteractive: true,
      nowUptimeNanoseconds: 20) { board.clearContents() }
    #expect(!published)
    #expect(board.string(forType: .string) == "new host copy")
  }

  @Test func focusLossAndReturnCannotReauthorizeAnOldCopyOrRetireSuccessor() throws {
    let authority = DoryVZMacClipboardActionAuthority()
    let session = UUID()
    let old = try #require(authority.begin(sessionIdentity: session,
      pasteboardChangeCount: 7, isInteractive: true, nowUptimeNanoseconds: 10,
      timeoutNanoseconds: 100))
    authority.revoke()
    let successor = try #require(authority.begin(sessionIdentity: session,
      pasteboardChangeCount: 7, isInteractive: true, nowUptimeNanoseconds: 20,
      timeoutNanoseconds: 100))
    #expect(!authority.permits(old, sessionIdentity: session, pasteboardChangeCount: 7,
      isInteractive: true, nowUptimeNanoseconds: 30))
    let staleFinish = authority.finish(old)
    #expect(!staleFinish)
    #expect(authority.owns(successor))
    #expect(authority.permits(successor, sessionIdentity: session, pasteboardChangeCount: 7,
      isInteractive: true, nowUptimeNanoseconds: 30))
  }

  @Test func sameRuntimeToolsReconnectRejectsOldSessionResult() throws {
    let authority = DoryVZMacClipboardActionAuthority()
    let oldSession = UUID()
    let ticket = try #require(authority.begin(sessionIdentity: oldSession,
      pasteboardChangeCount: 7, isInteractive: true, nowUptimeNanoseconds: 10,
      timeoutNanoseconds: 100))
    let replacementSession = UUID()
    var mutations = 0
    let published = authority.performIfCurrent(ticket, sessionIdentity: replacementSession,
      pasteboardChangeCount: 7, isInteractive: true,
      nowUptimeNanoseconds: 20) { mutations += 1 }
    #expect(!published)
    #expect(mutations == 0)
  }

  @Test(arguments: [UInt64(9), UInt64(110), UInt64.max])
  func originalDeadlineCannotBeRenewedByDelayedPublication(now: UInt64) throws {
    let authority = DoryVZMacClipboardActionAuthority()
    let session = UUID()
    let ticket = try #require(authority.begin(sessionIdentity: session,
      pasteboardChangeCount: 7, isInteractive: true, nowUptimeNanoseconds: 10,
      timeoutNanoseconds: 100))
    var mutations = 0
    let published = authority.performIfCurrent(ticket, sessionIdentity: session,
      pasteboardChangeCount: 7, isInteractive: true,
      nowUptimeNanoseconds: now) { mutations += 1 }
    #expect(!published)
    #expect(mutations == 0)
    #expect(ticket.deadlineUptimeNanoseconds == 110)
  }

  @Test func inactiveMissingSessionAndOverlappingRequestsNeverAcquireAuthority() throws {
    let authority = DoryVZMacClipboardActionAuthority()
    let session = UUID()
    let inactive = authority.begin(sessionIdentity: session, pasteboardChangeCount: 7,
      isInteractive: false, nowUptimeNanoseconds: 10, timeoutNanoseconds: 100)
    #expect(inactive == nil)
    let disconnected = authority.begin(sessionIdentity: nil, pasteboardChangeCount: 7,
      isInteractive: true, nowUptimeNanoseconds: 10, timeoutNanoseconds: 100)
    #expect(disconnected == nil)
    let overflow = authority.begin(sessionIdentity: session, pasteboardChangeCount: 7,
      isInteractive: true, nowUptimeNanoseconds: .max, timeoutNanoseconds: 100)
    #expect(overflow == nil)
    let first = try #require(authority.begin(sessionIdentity: session,
      pasteboardChangeCount: 7, isInteractive: true, nowUptimeNanoseconds: 10,
      timeoutNanoseconds: 100))
    let overlapping = authority.begin(sessionIdentity: session, pasteboardChangeCount: 7,
      isInteractive: true, nowUptimeNanoseconds: 20, timeoutNanoseconds: 100)
    #expect(overlapping == nil)
    #expect(!authority.permits(first, sessionIdentity: session, pasteboardChangeCount: 7,
      isInteractive: false, nowUptimeNanoseconds: 20))
  }

  private func makePasteboard() -> NSPasteboard {
    let board = NSPasteboard(name: NSPasteboard.Name("dory-mac-clipboard-test-\(UUID())"))
    board.clearContents()
    board.setString("initial host copy", forType: .string)
    return board
  }
}
