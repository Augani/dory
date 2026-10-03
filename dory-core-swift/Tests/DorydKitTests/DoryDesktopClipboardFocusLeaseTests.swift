import Foundation
import Testing
@testable import DoryVMMKit

struct DoryDesktopClipboardFocusLeaseTests {
    @Test func renewalsPreserveGenerationButExpiryOrRevocationNeverDoes() throws {
        let clock = FocusClock()
        let lease = DoryDesktopClipboardFocusLease(consoleIsActive: { true }, clock: { clock.now })
        #expect(lease.currentGeneration == nil)
        let owner = UUID()
        #expect(lease.update(leaseID: owner, active: true))
        let first = try #require(lease.currentGeneration)
        clock.advance(500_000_000)
        #expect(lease.update(leaseID: owner, active: true))
        #expect(lease.currentGeneration == first)
        clock.advance(DoryDesktopClipboardFocusLease.lifetimeNanoseconds)
        #expect(lease.currentGeneration == nil)
        lease.update(leaseID: owner, active: true)
        let second = try #require(lease.currentGeneration)
        #expect(second != first)
        lease.update(leaseID: owner, active: false)
        #expect(lease.currentGeneration == nil)
        lease.update(leaseID: owner, active: true)
        #expect(lease.currentGeneration != second)
    }

    @Test func staleOwnerCannotRevokeCurrentFocusAndConsoleChangeRevokesImmediately() throws {
        let console = FocusConsole()
        let lease = DoryDesktopClipboardFocusLease(consoleIsActive: { console.active }, clock: { 1 })
        let old = UUID()
        let current = UUID()
        lease.update(leaseID: old, active: true)
        lease.update(leaseID: current, active: true)
        let generation = try #require(lease.currentGeneration)
        #expect(!lease.update(leaseID: old, active: false))
        #expect(lease.currentGeneration == generation)
        console.setActive(false)
        #expect(lease.currentGeneration == nil)
        #expect(!lease.update(leaseID: current, active: true))
        console.setActive(true)
        #expect(lease.currentGeneration == nil)
        lease.update(leaseID: current, active: true)
        #expect(lease.currentGeneration != generation)
        lease.setHostAwake(false)
        #expect(lease.currentGeneration == nil)
        #expect(!lease.update(leaseID: current, active: true))
        lease.setHostAwake(true)
        #expect(lease.currentGeneration == nil)
        lease.update(leaseID: current, active: true)
        #expect(lease.currentGeneration != generation)
        lease.invalidate()
        #expect(lease.currentGeneration == nil)
    }

    @Test func delayedGrantCannotExtendItsOriginalExpiryOrReauthorizeAfterExpiry() throws {
        let clock = FocusClock()
        let lease = DoryDesktopClipboardFocusLease(consoleIsActive: { true }, clock: { clock.now })
        let owner = UUID()
        #expect(lease.update(leaseID: owner, active: true, expiresAtUptimeNanoseconds: 101))
        let generation = try #require(lease.currentGeneration)
        clock.advance(99)
        #expect(lease.update(leaseID: owner, active: true, expiresAtUptimeNanoseconds: 101))
        #expect(lease.currentGeneration == generation)
        clock.advance(1)
        #expect(lease.currentGeneration == nil)
        #expect(!lease.update(leaseID: owner, active: true, expiresAtUptimeNanoseconds: 101))
        #expect(!lease.update(leaseID: owner, active: true, expiresAtUptimeNanoseconds: .max))
        #expect(lease.currentGeneration == nil)
    }
}

private final class FocusClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 1
    var now: UInt64 { lock.withLock { value } }
    func advance(_ interval: UInt64) { lock.withLock { value += interval } }
}

private final class FocusConsole: @unchecked Sendable {
    private let lock = NSLock()
    private var value = true
    var active: Bool { lock.withLock { value } }
    func setActive(_ value: Bool) { lock.withLock { self.value = value } }
}
