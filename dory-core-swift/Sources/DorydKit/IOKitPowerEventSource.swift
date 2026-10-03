import Foundation
import IOKit
import IOKit.pwr_mgt

enum IOKitPowerObserverEvent: Sendable {
    case willSleep
    case wake
}

/// Registration, run-loop delivery, and teardown all belong to the observer worker. Stop is
/// the only cross-thread operation; it must also wake a run loop that has not entered run yet.
protocol IOKitPowerObserverConnection: AnyObject, Sendable {
    func run()
    func stop()
    func close()
}

public final class IOKitPowerEventSource: PowerEventSource, @unchecked Sendable {
    typealias ObserverFactory = @Sendable (
        @escaping @Sendable (IOKitPowerObserverEvent) -> Void
    ) throws -> any IOKitPowerObserverConnection

    private let lock = NSLock()
    private let observerFactory: ObserverFactory
    private let observerRevokedForTesting: (@Sendable () -> Void)?
    private var observer: PowerObserverLifetime?

    public convenience init() {
        self.init(observerFactory: { try SystemPowerObserverConnection(callback: $0) })
    }

    /// Internal transport injection keeps lifecycle regression tests independent of host power.
    init(
        observerFactory: @escaping ObserverFactory,
        observerRevokedForTesting: (@Sendable () -> Void)? = nil
    ) {
        self.observerFactory = observerFactory
        self.observerRevokedForTesting = observerRevokedForTesting
    }

    public func start(
        onWillSleep: @escaping @Sendable () -> Void,
        onWake: @escaping @Sendable () -> Void
    ) throws {
        let lifetime: PowerObserverLifetime
        while true {
            lock.lock()
            if let existing = observer {
                if existing.replaceCallbacks(onWillSleep: onWillSleep, onWake: onWake) {
                    lifetime = existing
                    lock.unlock()
                    break
                }
                lock.unlock()
                // A callback can stop its own observer, but cannot synchronously join and replace
                // that same worker. Leave the revoked generation in place until it exits.
                guard !existing.isWorkerThread else { throw PowerObserverError.registrationFailed }
                existing.join()
                retire(existing)
                continue
            }
            let created = PowerObserverLifetime(
                factory: observerFactory,
                revokedForTesting: observerRevokedForTesting,
                onWillSleep: onWillSleep,
                onWake: onWake
            )
            observer = created
            lifetime = created
            lock.unlock()
            created.launch()
            break
        }

        guard lifetime.waitUntilStarted(timeout: 5), lifetime.isAcceptingEvents else {
            stop(lifetime)
            throw lifetime.startError ?? PowerObserverError.registrationFailed
        }
    }

    public func stop() {
        lock.lock()
        let lifetime = observer
        lock.unlock()
        if let lifetime { stop(lifetime) }
    }

    private func stop(_ lifetime: PowerObserverLifetime) {
        lifetime.cancel()
        // Every caller joins the exact same generation. A shared, consumable semaphore or clearing
        // the worker before joining lets a second stop return while a control callback is active.
        guard !lifetime.isWorkerThread else { return }
        lifetime.join()
        retire(lifetime)
    }

    private func retire(_ lifetime: PowerObserverLifetime) {
        lock.lock()
        if observer === lifetime { observer = nil }
        lock.unlock()
    }

    deinit { stop() }
}

private final class PowerObserverLifetime: @unchecked Sendable {
    private let condition = NSCondition()
    private let exited = DispatchGroup()
    private let factory: IOKitPowerEventSource.ObserverFactory
    private let revokedForTesting: (@Sendable () -> Void)?
    private var worker: Thread?
    private var connection: (any IOKitPowerObserverConnection)?
    private var cancelled = false
    private var started = false
    private var error: Error?
    private var onWillSleep: (@Sendable () -> Void)?
    private var onWake: (@Sendable () -> Void)?

    init(
        factory: @escaping IOKitPowerEventSource.ObserverFactory,
        revokedForTesting: (@Sendable () -> Void)?,
        onWillSleep: @escaping @Sendable () -> Void,
        onWake: @escaping @Sendable () -> Void
    ) {
        self.factory = factory
        self.revokedForTesting = revokedForTesting
        self.onWillSleep = onWillSleep
        self.onWake = onWake
        exited.enter()
    }

    func launch() {
        let thread = Thread { [self] in run() }
        thread.name = "dev.dory.doryd.power-observer"
        condition.lock()
        worker = thread
        condition.unlock()
        thread.start()
    }

    var isWorkerThread: Bool {
        condition.lock()
        defer { condition.unlock() }
        return worker === Thread.current
    }

    var isAcceptingEvents: Bool {
        condition.lock()
        defer { condition.unlock() }
        return started && error == nil && !cancelled
    }

    var startError: Error? {
        condition.lock()
        defer { condition.unlock() }
        return error
    }

    func replaceCallbacks(
        onWillSleep: @escaping @Sendable () -> Void,
        onWake: @escaping @Sendable () -> Void
    ) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard !cancelled else { return false }
        self.onWillSleep = onWillSleep
        self.onWake = onWake
        return true
    }

    func waitUntilStarted(timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        condition.lock()
        defer { condition.unlock() }
        while !started {
            if !condition.wait(until: deadline), !started { return false }
        }
        return true
    }

    func cancel() {
        condition.lock()
        let newlyCancelled = !cancelled
        cancelled = true
        onWillSleep = nil
        onWake = nil
        let activeConnection = connection
        condition.unlock()
        if newlyCancelled { revokedForTesting?() }
        activeConnection?.stop()
    }

    func join() { exited.wait() }

    private func run() {
        defer {
            condition.lock()
            cancelled = true
            onWillSleep = nil
            onWake = nil
            connection = nil
            worker = nil
            condition.unlock()
            exited.leave()
        }

        condition.lock()
        let wasCancelled = cancelled
        condition.unlock()
        guard !wasCancelled else {
            completeStart(error: PowerObserverError.registrationFailed)
            return
        }

        do {
            let registered = try factory { [weak self] event in self?.handle(event) }
            defer { registered.close() }
            condition.lock()
            if cancelled {
                condition.unlock()
                completeStart(error: PowerObserverError.registrationFailed)
                return
            }
            connection = registered
            condition.unlock()
            completeStart(error: nil)
            registered.run()
        } catch {
            completeStart(error: error)
        }
    }

    private func completeStart(error: Error?) {
        condition.lock()
        self.error = error
        started = true
        // Concurrent start callers coalesce onto one registration and all must be released.
        condition.broadcast()
        condition.unlock()
    }

    private func handle(_ event: IOKitPowerObserverEvent) {
        condition.lock()
        let callback: (@Sendable () -> Void)?
        if cancelled {
            callback = nil
        } else {
            switch event {
            case .willSleep: callback = onWillSleep
            case .wake: callback = onWake
            }
        }
        condition.unlock()
        // The callback runs on this generation's worker. Stop revokes future admission first and
        // then joins the worker, including a callback selected immediately before cancellation.
        callback?()
    }
}

private final class SystemPowerObserverConnection: IOKitPowerObserverConnection, @unchecked Sendable {
    private let callback: @Sendable (IOKitPowerObserverEvent) -> Void
    private let runLoop: CFRunLoop
    private let stopLock = NSLock()
    private var stopRequested = false
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var rootPort: io_connect_t = 0
    private var source: CFRunLoopSource?

    init(callback: @escaping @Sendable (IOKitPowerObserverEvent) -> Void) throws {
        self.callback = callback
        runLoop = CFRunLoopGetCurrent()
        rootPort = IORegisterForSystemPower(
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &notifyPort,
            systemPowerCallback,
            &notifier
        )
        guard rootPort != 0, let notifyPort else {
            close()
            throw PowerObserverError.registrationFailed
        }
        let source = IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue()
        CFRunLoopAddSource(runLoop, source, .commonModes)
        self.source = source
    }

    func run() { CFRunLoopRun() }

    func stop() {
        stopLock.lock()
        guard !stopRequested else { stopLock.unlock(); return }
        stopRequested = true
        stopLock.unlock()
        // Queue the stop as well as waking the loop: CFRunLoopStop alone can be lost when stop
        // races the gap between successful registration and the first CFRunLoopRun call.
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) {
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        CFRunLoopWakeUp(runLoop)
    }

    func close() {
        if let source { CFRunLoopRemoveSource(runLoop, source, .commonModes) }
        if notifier != 0 { IOObjectRelease(notifier) }
        if rootPort != 0 { IOServiceClose(rootPort) }
        if let notifyPort { IONotificationPortDestroy(notifyPort) }
        source = nil
        notifier = 0
        rootPort = 0
        notifyPort = nil
    }

    fileprivate func handle(messageType: UInt32, messageArgument: UnsafeMutableRawPointer?) {
        switch messageType {
        case ioMessageCanSystemSleep:
            allowPowerChange(messageArgument)
        case ioMessageSystemWillSleep:
            callback(.willSleep)
            allowPowerChange(messageArgument)
        case ioMessageSystemHasPoweredOn:
            callback(.wake)
        default:
            break
        }
    }

    private func allowPowerChange(_ argument: UnsafeMutableRawPointer?) {
        // This port belongs to the callback's exact registration, never a successor observer.
        if rootPort != 0 { IOAllowPowerChange(rootPort, Int(bitPattern: argument)) }
    }
}

public enum PowerObserverError: Error, Sendable, Equatable {
    case registrationFailed
}

private let systemPowerCallback: IOServiceInterestCallback = { context, _, type, argument in
    guard let context else { return }
    let connection = Unmanaged<SystemPowerObserverConnection>.fromOpaque(context).takeUnretainedValue()
    connection.handle(messageType: type, messageArgument: argument)
}

private let ioMessageCanSystemSleep: UInt32 = 0xE000_0270
private let ioMessageSystemWillSleep: UInt32 = 0xE000_0280
private let ioMessageSystemHasPoweredOn: UInt32 = 0xE000_0300
