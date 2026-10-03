@testable import DorydKit
import Foundation
import XCTest

final class IOKitPowerEventSourceTests: XCTestCase {
    func testConcurrentStartsShareRegistrationAndBroadcastCompletion() throws {
        let registrationGate = DispatchSemaphore(value: 0)
        let factory = MockPowerObserverFactory(registrationGate: registrationGate)
        let source = IOKitPowerEventSource(observerFactory: { try factory.make(callback: $0) })
        defer { registrationGate.signal(); source.stop() }
        let first = PowerObserverCall { try source.start(onWillSleep: {}, onWake: {}) }
        XCTAssertEqual(factory.registered.wait(timeout: .now() + 2), .success)
        let second = PowerObserverCall { try source.start(onWillSleep: {}, onWake: {}) }

        registrationGate.signal()

        XCTAssertTrue(first.wait())
        XCTAssertTrue(second.wait())
        XCTAssertNil(first.error)
        XCTAssertNil(second.error)
        XCTAssertEqual(factory.connections.count, 1)
        source.stop()
        XCTAssertEqual(try XCTUnwrap(factory.connections.first).closeCount, 1)
    }

    func testConcurrentStopsAndRestartJoinHeldCallbackWithoutRetiringSuccessor() throws {
        let factory = MockPowerObserverFactory()
        let revoked = DispatchSemaphore(value: 0)
        let callbackEntered = DispatchSemaphore(value: 0)
        let callbackRelease = DispatchSemaphore(value: 0)
        let counts = PowerObserverCounts()
        let source = IOKitPowerEventSource(
            observerFactory: { try factory.make(callback: $0) },
            observerRevokedForTesting: { revoked.signal() }
        )
        defer { callbackRelease.signal(); source.stop() }
        try source.start(onWillSleep: {}, onWake: {
            counts.increment("old")
            callbackEntered.signal()
            if callbackRelease.wait(timeout: .now() + 3) != .success {
                counts.increment("callback-timeout")
            }
        })
        let original = try XCTUnwrap(factory.connections.first)
        original.enqueue(.wake)
        XCTAssertEqual(callbackEntered.wait(timeout: .now() + 2), .success)
        let firstStop = PowerObserverCall { source.stop() }
        XCTAssertEqual(revoked.wait(timeout: .now() + 2), .success)
        let secondStop = PowerObserverCall { source.stop() }
        XCTAssertEqual(original.stopRequested.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(original.stopRequested.wait(timeout: .now() + 2), .success)
        let restart = PowerObserverCall {
            try source.start(onWillSleep: {}, onWake: { counts.increment("new") })
        }

        XCTAssertFalse(firstStop.wait(timeout: 0.05))
        XCTAssertFalse(secondStop.wait(timeout: 0.05))
        XCTAssertFalse(restart.wait(timeout: 0.05))
        original.deliverStale(.wake)
        XCTAssertEqual(counts.value("old"), 1)
        XCTAssertEqual(factory.connections.count, 1)
        callbackRelease.signal()

        XCTAssertTrue(firstStop.wait())
        XCTAssertTrue(secondStop.wait())
        XCTAssertTrue(restart.wait())
        XCTAssertNil(restart.error)
        XCTAssertEqual(original.closeCount, 1)
        XCTAssertEqual(counts.value("callback-timeout"), 0)
        XCTAssertEqual(factory.connections.count, 2)
        let successor = try XCTUnwrap(factory.connections.last)
        successor.enqueue(.wake)
        XCTAssertEqual(successor.delivered.wait(timeout: .now() + 2), .success)
        original.deliverStale(.willSleep)
        original.deliverStale(.wake)
        XCTAssertEqual(counts.value("old"), 1)
        XCTAssertEqual(counts.value("new"), 1)
    }

    func testCancelledRegistrationCannotInstallIntoRestartedObserver() throws {
        let registrationGate = DispatchSemaphore(value: 0)
        let factory = MockPowerObserverFactory(registrationGate: registrationGate)
        let revoked = DispatchSemaphore(value: 0)
        let counts = PowerObserverCounts()
        let source = IOKitPowerEventSource(
            observerFactory: { try factory.make(callback: $0) },
            observerRevokedForTesting: { revoked.signal() }
        )
        defer { registrationGate.signal(); source.stop() }
        let originalStart = PowerObserverCall {
            try source.start(onWillSleep: {}, onWake: { counts.increment("old") })
        }
        XCTAssertEqual(factory.registered.wait(timeout: .now() + 2), .success)
        let stop = PowerObserverCall { source.stop() }
        XCTAssertEqual(revoked.wait(timeout: .now() + 2), .success)
        let restart = PowerObserverCall {
            try source.start(onWillSleep: {}, onWake: { counts.increment("new") })
        }
        XCTAssertFalse(stop.wait(timeout: 0.05))
        XCTAssertFalse(restart.wait(timeout: 0.05))
        registrationGate.signal()
        // The factory only holds its first generation; the replacement must use a fresh worker.
        XCTAssertTrue(originalStart.wait())
        XCTAssertEqual(originalStart.error as? PowerObserverError, .registrationFailed)
        XCTAssertTrue(stop.wait())
        XCTAssertTrue(restart.wait())
        XCTAssertNil(restart.error)
        XCTAssertEqual(factory.connections.count, 2)
        let original = try XCTUnwrap(factory.connections.first)
        let successor = try XCTUnwrap(factory.connections.last)
        XCTAssertEqual(original.runCount, 0)
        XCTAssertEqual(original.closeCount, 1)
        original.deliverStale(.wake)
        successor.enqueue(.wake)
        XCTAssertEqual(successor.delivered.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(counts.value("old"), 0)
        XCTAssertEqual(counts.value("new"), 1)
    }

    func testStopBeforeRunEntryIsNotLost() throws {
        let runGate = DispatchSemaphore(value: 0)
        let factory = MockPowerObserverFactory(runGate: runGate)
        let source = IOKitPowerEventSource(observerFactory: { try factory.make(callback: $0) })
        defer { runGate.signal(); source.stop() }
        try source.start(onWillSleep: {}, onWake: {})
        let connection = try XCTUnwrap(factory.connections.first)
        XCTAssertEqual(connection.runEntered.wait(timeout: .now() + 2), .success)
        let stop = PowerObserverCall { source.stop() }
        XCTAssertEqual(connection.stopRequested.wait(timeout: .now() + 2), .success)
        XCTAssertFalse(stop.wait(timeout: 0.05))
        runGate.signal()

        XCTAssertTrue(stop.wait())
        XCTAssertEqual(connection.closeCount, 1)
        XCTAssertEqual(connection.delivered.wait(timeout: .now() + 0.05), .timedOut)
    }

    func testCallbackCanStopButCannotSynchronouslyRestartItsOwnWorker() throws {
        let factory = MockPowerObserverFactory()
        let counts = PowerObserverCounts()
        let source = IOKitPowerEventSource(observerFactory: { try factory.make(callback: $0) })
        defer { source.stop() }
        try source.start(onWillSleep: {}, onWake: {
            source.stop()
            do {
                try source.start(onWillSleep: {}, onWake: {})
                counts.increment("unexpected-reentrant-start")
            } catch {
                if error as? PowerObserverError == .registrationFailed {
                    counts.increment("reentrant-start-rejected")
                }
            }
        })
        let original = try XCTUnwrap(factory.connections.first)
        original.enqueue(.wake)
        XCTAssertEqual(original.delivered.wait(timeout: .now() + 2), .success)
        source.stop()
        XCTAssertEqual(counts.value("reentrant-start-rejected"), 1)
        XCTAssertEqual(counts.value("unexpected-reentrant-start"), 0)
        XCTAssertEqual(original.closeCount, 1)

        try source.start(onWillSleep: {}, onWake: { counts.increment("new") })
        let successor = try XCTUnwrap(factory.connections.last)
        original.deliverStale(.wake)
        successor.enqueue(.wake)
        XCTAssertEqual(successor.delivered.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(counts.value("new"), 1)
        XCTAssertEqual(factory.connections.count, 2)
    }
}

private final class MockPowerObserverFactory: @unchecked Sendable {
    let registered = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let registrationGate: DispatchSemaphore?
    private let runGate: DispatchSemaphore?
    private var storedConnections: [MockPowerObserverConnection] = []

    init(registrationGate: DispatchSemaphore? = nil, runGate: DispatchSemaphore? = nil) {
        self.registrationGate = registrationGate
        self.runGate = runGate
    }

    var connections: [MockPowerObserverConnection] {
        lock.lock()
        defer { lock.unlock() }
        return storedConnections
    }

    func make(
        callback: @escaping @Sendable (IOKitPowerObserverEvent) -> Void
    ) throws -> any IOKitPowerObserverConnection {
        let connection = MockPowerObserverConnection(callback: callback, runGate: runGate)
        lock.lock()
        let isFirst = storedConnections.isEmpty
        storedConnections.append(connection)
        lock.unlock()
        registered.signal()
        if isFirst, let registrationGate,
           registrationGate.wait(timeout: .now() + 3) != .success {
            connection.close()
            throw PowerObserverError.registrationFailed
        }
        return connection
    }
}

private final class MockPowerObserverConnection: IOKitPowerObserverConnection, @unchecked Sendable {
    let runEntered = DispatchSemaphore(value: 0)
    let stopRequested = DispatchSemaphore(value: 0)
    let delivered = DispatchSemaphore(value: 0)
    private let condition = NSCondition()
    private let callback: @Sendable (IOKitPowerObserverEvent) -> Void
    private let runGate: DispatchSemaphore?
    private var events: [IOKitPowerObserverEvent] = []
    private var stopped = false
    private var storedCloseCount = 0
    private var storedRunCount = 0

    init(
        callback: @escaping @Sendable (IOKitPowerObserverEvent) -> Void,
        runGate: DispatchSemaphore?
    ) {
        self.callback = callback
        self.runGate = runGate
    }

    var closeCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return storedCloseCount
    }

    var runCount: Int {
        condition.lock()
        defer { condition.unlock() }
        return storedRunCount
    }

    func enqueue(_ event: IOKitPowerObserverEvent) {
        condition.lock()
        events.append(event)
        condition.broadcast()
        condition.unlock()
    }

    func deliverStale(_ event: IOKitPowerObserverEvent) { callback(event) }

    func run() {
        condition.lock()
        storedRunCount += 1
        condition.unlock()
        runEntered.signal()
        if let runGate { _ = runGate.wait(timeout: .now() + 3) }
        condition.lock()
        while !stopped {
            if events.isEmpty {
                condition.wait()
                continue
            }
            let event = events.removeFirst()
            condition.unlock()
            callback(event)
            delivered.signal()
            condition.lock()
        }
        condition.unlock()
    }

    func stop() {
        condition.lock()
        stopped = true
        condition.broadcast()
        condition.unlock()
        stopRequested.signal()
    }

    func close() {
        condition.lock()
        storedCloseCount += 1
        condition.unlock()
    }
}

private final class PowerObserverCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    func increment(_ key: String) {
        lock.lock()
        counts[key, default: 0] += 1
        lock.unlock()
    }

    func value(_ key: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[key, default: 0]
    }
}

private final class PowerObserverCall: @unchecked Sendable {
    private let finished = DispatchGroup()
    private let lock = NSLock()
    private var storedError: Error?

    init(_ action: @escaping @Sendable () throws -> Void) {
        finished.enter()
        Thread { [self] in
            do { try action() }
            catch {
                lock.lock()
                storedError = error
                lock.unlock()
            }
            finished.leave()
        }.start()
    }

    var error: Error? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }

    func wait(timeout: TimeInterval = 2) -> Bool {
        finished.wait(timeout: .now() + timeout) == .success
    }
}
