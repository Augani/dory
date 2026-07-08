import Foundation
import IOKit
import IOKit.pwr_mgt

public final class IOKitPowerEventSource: PowerEventSource, @unchecked Sendable {
    private let lock = NSLock()
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var rootPort: io_connect_t = 0
    private var onWillSleep: (@Sendable () -> Void)?
    private var onWake: (@Sendable () -> Void)?
    private var runLoop: CFRunLoop?
    private var workerThread: Thread?

    public init() {}

    public func start(
        onWillSleep: @escaping @Sendable () -> Void,
        onWake: @escaping @Sendable () -> Void
    ) throws {
        lock.lock()
        if rootPort != 0 {
            self.onWillSleep = onWillSleep
            self.onWake = onWake
            lock.unlock()
            return
        }
        self.onWillSleep = onWillSleep
        self.onWake = onWake
        lock.unlock()

        let start = PowerObserverStart()
        let thread = Thread { [weak self] in
            self?.runPowerObserver(start: start)
        }
        thread.name = "dev.dory.doryd.power-observer"
        lock.lock()
        workerThread = thread
        lock.unlock()
        thread.start()

        guard start.wait(timeout: 5) else {
            stop()
            throw PowerObserverError.registrationFailed
        }
        if let error = start.error {
            stop()
            throw error
        }
    }

    public func stop() {
        lock.lock()
        let localNotifyPort = notifyPort
        let localNotifier = notifier
        let localRootPort = rootPort
        let localRunLoop = runLoop
        notifyPort = nil
        notifier = 0
        rootPort = 0
        runLoop = nil
        workerThread = nil
        onWillSleep = nil
        onWake = nil
        lock.unlock()

        if let localNotifyPort {
            let source = IONotificationPortGetRunLoopSource(localNotifyPort).takeUnretainedValue()
            if let localRunLoop {
                CFRunLoopRemoveSource(localRunLoop, source, .commonModes)
            }
            IONotificationPortDestroy(localNotifyPort)
        }
        if localNotifier != 0 {
            IOObjectRelease(localNotifier)
        }
        if localRootPort != 0 {
            IOServiceClose(localRootPort)
        }
        if let localRunLoop {
            CFRunLoopStop(localRunLoop)
        }
    }

    private func runPowerObserver(start: PowerObserverStart) {
        var localNotifyPort: IONotificationPortRef?
        var localNotifier: io_object_t = 0
        let context = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let port = IORegisterForSystemPower(
            context,
            &localNotifyPort,
            powerCallback,
            &localNotifier
        )
        guard port != 0, let localNotifyPort else {
            start.complete(error: PowerObserverError.registrationFailed)
            return
        }

        let currentRunLoop = CFRunLoopGetCurrent()
        let source = IONotificationPortGetRunLoopSource(localNotifyPort).takeUnretainedValue()
        CFRunLoopAddSource(currentRunLoop, source, .commonModes)

        lock.lock()
        rootPort = port
        notifyPort = localNotifyPort
        notifier = localNotifier
        runLoop = currentRunLoop
        lock.unlock()

        start.complete(error: nil)
        CFRunLoopRun()
    }

    fileprivate func handle(messageType: UInt32, messageArgument: UnsafeMutableRawPointer?) {
        switch messageType {
        case ioMessageCanSystemSleep:
            allowPowerChange(messageArgument)
        case ioMessageSystemWillSleep:
            lock.lock()
            let callback = onWillSleep
            lock.unlock()
            callback?()
            allowPowerChange(messageArgument)
        case ioMessageSystemHasPoweredOn:
            lock.lock()
            let callback = onWake
            lock.unlock()
            callback?()
        default:
            break
        }
    }

    private func allowPowerChange(_ messageArgument: UnsafeMutableRawPointer?) {
        lock.lock()
        let port = rootPort
        lock.unlock()
        guard port != 0 else { return }
        IOAllowPowerChange(port, Int(bitPattern: messageArgument))
    }

    deinit {
        stop()
    }
}

public enum PowerObserverError: Error, Sendable, Equatable {
    case registrationFailed
}

private final class PowerObserverStart: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var storedError: Error?

    var error: Error? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }

    func complete(error: Error?) {
        lock.lock()
        storedError = error
        lock.unlock()
        semaphore.signal()
    }

    func wait(timeout seconds: TimeInterval) -> Bool {
        semaphore.wait(timeout: .now() + seconds) == .success
    }
}

private let powerCallback: IOServiceInterestCallback = { context, _, messageType, messageArgument in
    guard let context else { return }
    let source = Unmanaged<IOKitPowerEventSource>.fromOpaque(context).takeUnretainedValue()
    source.handle(messageType: messageType, messageArgument: messageArgument)
}

private let ioMessageCanSystemSleep: UInt32 = 0xE000_0270
private let ioMessageSystemWillSleep: UInt32 = 0xE000_0280
private let ioMessageSystemHasPoweredOn: UInt32 = 0xE000_0300
