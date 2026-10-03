import AppKit
import DoryOperations
import Foundation
import Testing
@testable import DoryVMMKit

@MainActor
@Suite(.serialized) struct DoryDesktopClipboardCoordinatorTests {
    @Test func stoppedGuestReadCannotPublishOrStartAnotherMIMERequest() async throws {
        let fixture = ClipboardLifetimeFixture(block: .get)
        let pasteboard = makePasteboard("host clipboard")
        let coordinator = makeCoordinator(fixture, pasteboard: pasteboard, direction: .guestToHost)
        defer { coordinator.stop(); fixture.release() }
        coordinator.start()
        coordinator.markGuestReady()
        try #require(await clipboardEventually { fixture.availabilityCount == 1 })
        try #require(await clipboardEventually {
            _ = coordinator.handleMacShortcut(copyEvent())
            return fixture.getCount == 1
        })
        let shortcutsBeforeStop = fixture.shortcuts
        coordinator.stop()
        fixture.release()
        try #require(await clipboardEventually { fixture.finishedCount == 1 })
        try await Task.sleep(for: .milliseconds(30))
        #expect(pasteboard.string(forType: .string) == "host clipboard")
        #expect(fixture.getCount == 1)
        #expect(fixture.shortcuts == shortcutsBeforeStop)
    }

    @Test func oldReadinessReplyCannotAuthorizeRestartedCoordinator() async throws {
        let fixture = ClipboardLifetimeFixture(block: .availability)
        let pasteboard = makePasteboard("host clipboard")
        let coordinator = makeCoordinator(fixture, pasteboard: pasteboard, direction: .hostToGuest)
        defer { coordinator.stop(); fixture.release() }
        coordinator.start()
        coordinator.markGuestReady()
        try #require(await clipboardEventually { fixture.availabilityCount == 1 })
        coordinator.stop()
        coordinator.start()
        fixture.grantFocus()
        fixture.release()
        try #require(await clipboardEventually { fixture.finishedCount == 1 })
        try await Task.sleep(for: .milliseconds(30))
        pasteboard.clearContents()
        pasteboard.setString("new host clipboard", forType: .string)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification,
                                        object: NSApplication.shared)
        try await Task.sleep(for: .milliseconds(30))
        #expect(fixture.setCount == 0)
        #expect(fixture.shortcuts.isEmpty)
        // Only a new probe, never the old queued reply, may admit this run.
        coordinator.markGuestReady()
        try #require(await clipboardEventually { fixture.setCount == 1 })
        #expect(fixture.availabilityCount == 2)
    }

    @Test func slowGuestReadDoesNotOverwriteANewerHostClipboardCopy() async throws {
        let fixture = ClipboardLifetimeFixture(block: .get)
        let pasteboard = makePasteboard("initial host clipboard")
        let coordinator = makeCoordinator(fixture, pasteboard: pasteboard, direction: .guestToHost)
        defer { coordinator.stop(); fixture.release() }
        coordinator.start()
        coordinator.markGuestReady()
        try #require(await clipboardEventually { fixture.availabilityCount == 1 })
        try #require(await clipboardEventually {
            _ = coordinator.handleMacShortcut(copyEvent())
            return fixture.getCount == 1
        })
        pasteboard.clearContents()
        pasteboard.setString("new host copy", forType: .string)
        fixture.release()
        try #require(await clipboardEventually { fixture.finishedCount == 1 })
        try await Task.sleep(for: .milliseconds(30))
        #expect(pasteboard.string(forType: .string) == "new host copy")
    }

    @Test func repeatedReadNotificationsCoalesceWhileTransportIsBlocked() async throws {
        let fixture = ClipboardLifetimeFixture(block: .get)
        let pasteboard = makePasteboard("host clipboard")
        let coordinator = makeCoordinator(fixture, pasteboard: pasteboard, direction: .guestToHost)
        defer { coordinator.stop(); fixture.release() }
        coordinator.start()
        coordinator.start() // An accidental duplicate start must not add a second poller/run.
        coordinator.markGuestReady()
        try #require(await clipboardEventually { fixture.availabilityCount == 1 })
        for _ in 0..<100 {
            _ = coordinator.handleMacShortcut(copyEvent())
        }
        try #require(await clipboardEventually {
            _ = coordinator.handleMacShortcut(copyEvent())
            return fixture.getCount == 1
        })
        coordinator.stop()
        fixture.release()
        try #require(await clipboardEventually { fixture.finishedCount == 1 })
        try await Task.sleep(for: .milliseconds(30))
        #expect(fixture.getCount == 1)
        #expect(pasteboard.string(forType: .string) == "host clipboard")
    }

    @Test func pasteQueueIsBoundedAndStopRevokesQueuedWritesAndShortcuts() async throws {
        let fixture = ClipboardLifetimeFixture(block: .set)
        let pasteboard = makePasteboard("host clipboard")
        let coordinator = makeCoordinator(fixture, pasteboard: pasteboard, direction: .hostToGuest)
        defer { coordinator.stop(); fixture.release() }
        coordinator.start()
        coordinator.markGuestReady()
        try #require(await clipboardEventually { fixture.setCount == 1 })
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: 0, context: nil, characters: "v", charactersIgnoringModifiers: "v",
            isARepeat: false, keyCode: 9
        ))
        for _ in 0..<20 { #expect(coordinator.handleMacShortcut(event)) }
        #expect(fixture.logs.filter { $0.contains("queue exhausted") }.count == 12)
        coordinator.stop()
        #expect(!coordinator.handleMacShortcut(event))
        fixture.release()
        try #require(await clipboardEventually { fixture.finishedCount == 1 })
        try await Task.sleep(for: .milliseconds(30))
        #expect(fixture.setCount == 1)
        #expect(fixture.shortcuts.isEmpty)
    }

    @Test func headlessOrUnfocusedCoordinatorCannotProbeCopyPasteOrPublish() async throws {
        let fixture = ClipboardLifetimeFixture(block: .get)
        let pasteboard = makePasteboard("host clipboard")
        let coordinator = makeCoordinator(fixture, pasteboard: pasteboard, direction: .bidirectional)
        defer { coordinator.stop(); fixture.release() }
        fixture.focus.invalidate()
        coordinator.start()
        coordinator.markGuestReady()
        #expect(!coordinator.handleMacShortcut(copyEvent()))
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification,
                                        object: NSApplication.shared)
        try await Task.sleep(for: .milliseconds(50))
        #expect(fixture.availabilityCount == 0)
        #expect(fixture.getCount == 0)
        #expect(fixture.setCount == 0)
        #expect(fixture.shortcuts.isEmpty)
        #expect(pasteboard.string(forType: .string) == "host clipboard")
    }

    @Test func newFocusCannotAuthorizeAReadFromThePreviousFocusLease() async throws {
        let fixture = ClipboardLifetimeFixture(block: .get)
        let pasteboard = makePasteboard("host clipboard")
        let coordinator = makeCoordinator(fixture, pasteboard: pasteboard, direction: .guestToHost)
        defer { coordinator.stop(); fixture.release() }
        coordinator.start()
        coordinator.markGuestReady()
        try #require(await clipboardEventually {
            _ = coordinator.handleMacShortcut(copyEvent())
            return fixture.getCount == 1
        })
        fixture.focus.invalidate()
        fixture.grantFocus()
        // No new transfer is scheduled: merely returning to the VM must not authorize old work.
        fixture.release()
        try #require(await clipboardEventually { fixture.finishedCount == 1 })
        try await Task.sleep(for: .milliseconds(30))
        #expect(pasteboard.string(forType: .string) == "host clipboard")
        #expect(fixture.getCount == 1)
    }

    @Test func focusChurnCannotAccumulateUnboundedWorkBehindABlockedWrite() async throws {
        let fixture = ClipboardLifetimeFixture(block: .set)
        let pasteboard = makePasteboard("host clipboard")
        let coordinator = makeCoordinator(fixture, pasteboard: pasteboard, direction: .hostToGuest)
        defer { coordinator.stop(); fixture.release() }
        coordinator.start()
        coordinator.markGuestReady()
        try #require(await clipboardEventually { fixture.setCount == 1 })
        let paste = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: 0, context: nil, characters: "v", charactersIgnoringModifiers: "v",
            isARepeat: false, keyCode: 9
        ))
        for _ in 0..<100 {
            fixture.focus.invalidate()
            fixture.grantFocus()
            #expect(coordinator.handleMacShortcut(paste))
        }
        // One blocked initial write plus eleven waiting actions fill the instance-wide quota,
        // despite every iteration having a fresh per-focus paste allowance.
        #expect(fixture.logs.filter { $0.contains("transport queue exhausted") }.count == 89)
        coordinator.stop()
        fixture.release()
        try #require(await clipboardEventually { fixture.finishedCount == 1 })
        try await Task.sleep(for: .milliseconds(30))
        #expect(fixture.setCount == 1)
        #expect(fixture.shortcuts.isEmpty)
    }

    @Test func transportQuotaIncludesPendingMainActorClipboardCompletions() async throws {
        let fixture = ClipboardLifetimeFixture(block: .get)
        let pasteboard = makePasteboard("host clipboard")
        let coordinator = makeCoordinator(fixture, pasteboard: pasteboard, direction: .hostToGuest)
        defer { coordinator.stop(); fixture.release() }
        coordinator.start()
        coordinator.markGuestReady()
        try #require(await clipboardEventually { fixture.setCount == 1 })
        try await Task.sleep(for: .milliseconds(20))
        fixture.drainSetCompletions()
        let paste = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: 0, context: nil, characters: "v", charactersIgnoringModifiers: "v",
            isARepeat: false, keyCode: 9
        ))
        // Deliberately do not yield the MainActor. Each admitted RPC is known to finish, but its
        // publication/shortcut callback remains queued and must keep its work credit.
        for index in 0..<100 {
            fixture.grantFocus()
            #expect(coordinator.handleMacShortcut(paste))
            if index < 12 { #expect(fixture.waitForSetCompletion() == .success) }
        }
        #expect(fixture.setCount == 13) // Initial synchronization, then twelve held callbacks.
        #expect(fixture.logs.filter { $0.contains("transport queue exhausted") }.count == 88)
        coordinator.stop()
        try await Task.sleep(for: .milliseconds(30))
        #expect(fixture.shortcuts.isEmpty)
    }

    private func makePasteboard(_ value: String) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: .init("dev.dory.test.clipboard.\(UUID())"))
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        return pasteboard
    }

    private func makeCoordinator(
        _ fixture: ClipboardLifetimeFixture, pasteboard: NSPasteboard,
        direction: DoryVMClipboardDirection
    ) -> DoryDesktopClipboardCoordinator {
        fixture.grantFocus()
        return DoryDesktopClipboardCoordinator(
            policy: .init(text: direction, image: .off, files: .off),
            transport: .init(availability: { fixture.available() }, get: { fixture.get($0) },
                             set: { fixture.set($0, data: $1) }),
            focusLease: fixture.focus,
            sendShortcut: { fixture.shortcut($0) }, pasteboard: pasteboard,
            startupRetryDelay: 0.01, startupRetryLimit: 0, pollInterval: 60,
            log: { fixture.log($0) }
        )
    }

    private func copyEvent() -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                        timestamp: 0, windowNumber: 0, context: nil, characters: "c",
                        charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8)!
    }
}

private final class ClipboardLifetimeFixture: @unchecked Sendable {
    enum Block { case availability, get, set }
    private let lock = NSLock()
    private let unblock = DispatchSemaphore(value: 0)
    private let setCompletion = DispatchSemaphore(value: 0)
    private let block: Block
    let focus = DoryDesktopClipboardFocusLease(consoleIsActive: { true },
                                              clock: { DispatchTime.now().uptimeNanoseconds })
    private var availableCalls = 0
    private var getCalls = 0
    private var setCalls = 0
    private var finishedCalls = 0
    private var recordedShortcuts: [UInt16] = []
    private var recordedLogs: [String] = []

    init(block: Block) { self.block = block }
    func grantFocus() { focus.update(leaseID: UUID(), active: true) }
    var availabilityCount: Int { lock.withLock { availableCalls } }
    var getCount: Int { lock.withLock { getCalls } }
    var setCount: Int { lock.withLock { setCalls } }
    var finishedCount: Int { lock.withLock { finishedCalls } }
    var shortcuts: [UInt16] { lock.withLock { recordedShortcuts } }
    var logs: [String] { lock.withLock { recordedLogs } }

    func available() -> Bool {
        let count = lock.withLock { availableCalls += 1; return availableCalls }
        waitIfNeeded(.availability, count: count)
        return true
    }
    func get(_ mimeType: String) -> Data {
        let count = lock.withLock { getCalls += 1; return getCalls }
        waitIfNeeded(.get, count: count)
        return Data("guest clipboard".utf8)
    }
    func set(_ mimeType: String, data: Data) {
        let count = lock.withLock { setCalls += 1; return setCalls }
        waitIfNeeded(.set, count: count)
        setCompletion.signal()
    }
    func waitForSetCompletion() -> DispatchTimeoutResult {
        setCompletion.wait(timeout: .now() + 0.2)
    }
    func drainSetCompletions() { while setCompletion.wait(timeout: .now()) == .success {} }
    func shortcut(_ code: UInt16) { lock.withLock { recordedShortcuts.append(code) } }
    func log(_ message: String) { lock.withLock { recordedLogs.append(message) } }
    func release() { unblock.signal() }
    private func waitIfNeeded(_ operation: Block, count: Int) {
        guard operation == block, count == 1 else { return }
        _ = unblock.wait(timeout: .now() + 3)
        lock.withLock { finishedCalls += 1 }
    }
}

@MainActor
private func clipboardEventually(_ predicate: () -> Bool) async -> Bool {
    for _ in 0..<1_000 {
        if predicate() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return false
}
