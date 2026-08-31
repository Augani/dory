import AppKit
import Darwin
import DoryFirmware
import DoryHV
import DoryMachinePC
import DoryOperations
import DoryVirtio
import DorydKit
import DoryVMMKit
import Foundation

enum DoryPCMode {
    struct Configuration {
        let envelope: DoryPCRuntimeLaunchEnvelope
        let authority: DoryPCUEFIRuntimeAuthority
        let stateDirectory: String
        let handoffSocketPath: String
        let consoleSocketPath: String
        let controlSocketPath: String
        let displayPresentation: DoryMachineDisplayPresentation
    }

    @MainActor
    static func run(_ configuration: Configuration) throws {
        let controller = try Controller(configuration: configuration)
        try controller.run()
    }

    @MainActor
    private final class Controller: NSObject, NSApplicationDelegate, NSWindowDelegate {
        private final class MachineState: @unchecked Sendable {
            private let lock = NSLock()
            private var machine: DoryPCUEFIMachine
            private var stopping = false

            init(machine: DoryPCUEFIMachine) { self.machine = machine }

            func current() -> DoryPCUEFIMachine { lock.withLock { machine } }

            func replace(_ replacement: DoryPCUEFIMachine) -> Bool {
                lock.withLock {
                    guard !stopping else { return false }
                    machine = replacement
                    return true
                }
            }

            func requestStop() {
                let current = lock.withLock { () -> DoryPCUEFIMachine in
                    stopping = true
                    return machine
                }
                current.machine.powerController.request(.powerOff)
            }

            var isStopping: Bool { lock.withLock { stopping } }
        }

        private final class ReadyPublisher: @unchecked Sendable {
            private let lock = NSLock()
            private var published = false
            private let publishOperation: @Sendable () throws -> Void

            init(_ publishOperation: @escaping @Sendable () throws -> Void) {
                self.publishOperation = publishOperation
            }

            func publishOnce() throws {
                let shouldPublish = lock.withLock { () -> Bool in
                    guard !published else { return false }
                    published = true
                    return true
                }
                if shouldPublish { try publishOperation() }
            }
        }

        private let configuration: Configuration
        private let application = NSApplication.shared
        private let stateLock: EngineStateDirectoryLock
        private let serialLog: FileHandle
        private let serialOutput: BoundedSerialConsolePublisher
        private let serialInput: RawHVSerialConsoleInput
        private let lifecycleServer: VmmLifecycleReceiptServer
        private let machineState: MachineState
        private let keyboardInput: DoryPCDesktopInputSink
        private let pointerInput: DoryPCDesktopInputSink
        private let displaySink: DoryPCSoftwareDisplaySink?
        private let mailbox: DesktopFrameMailbox?
        private let window: NSWindow?
        private let readyPublisher: ReadyPublisher
        private let executionQueue = DispatchQueue(
            label: "dev.dory.dory-hv.dorypc.execution",
            qos: .userInitiated
        )
        private let signalQueue = DispatchQueue(
            label: "dev.dory.dory-hv.dorypc.signals",
            qos: .userInitiated
        )
        private var signalSources = [DispatchSourceSignal]()
        private var stopError: Error?

        init(configuration: Configuration) throws {
            let envelope = configuration.envelope
            guard envelope.graphics == .none || envelope.graphics == .software else {
                throw VMError.invalidConfiguration(
                    "DoryPC accelerated graphics requires the signed renderer authority"
                )
            }
            let devices = envelope.devices
            guard devices.networkAttachment == .disconnected,
                  !devices.audioInput,
                  !devices.audioOutput,
                  !devices.cameraInput,
                  !devices.clipboard,
                  !devices.clockSynchronization,
                  !devices.dynamicDisplay,
                  !devices.removableUSBHotplug else {
                throw VMError.invalidConfiguration(
                    "DoryPC launch requested a host device backend that is not admitted by this runner"
                )
            }
            self.configuration = configuration
            try FileManager.default.createDirectory(
                atPath: configuration.stateDirectory,
                withIntermediateDirectories: true
            )
            stateLock = try EngineStateDirectoryLock(stateDirectory: configuration.stateDirectory)
            serialLog = try Self.openSerialLog(configuration.stateDirectory + "/serial.log")
            serialOutput = try BoundedSerialConsolePublisher(destinations: [
                .init(fileHandle: FileHandle.standardError),
                .init(fileHandle: serialLog, synchronizeOnStop: true),
            ])

            let mailbox = devices.displays.isEmpty ? nil : DesktopFrameMailbox(scanoutID: 0)
            self.mailbox = mailbox
            let readyPublisher = ReadyPublisher {
                let graphics = envelope.graphics == .software
                    ? DoryRuntimeGraphicsSelection.resolvedSoftware(
                        operationID: envelope.operationID,
                        resolvedPlanSHA256: envelope.resolvedPlanSHA256,
                        planRevision: envelope.planRevision
                    )
                    : nil
                try VmmHandoffClient.send(
                    path: configuration.handoffSocketPath,
                    ready: VmmReadyMessage(
                        machineID: envelope.machineID,
                        operationID: DoryOperationIdentity.canonical(envelope.operationID),
                        controlSocketPath: configuration.controlSocketPath,
                        graphicsSelection: graphics,
                        detail: "DoryPC-v1 x86_64 Linux firmware is running through DoryDBT"
                    )
                )
            }
            self.readyPublisher = readyPublisher
            let displaySink = mailbox.map { mailbox in
                DoryPCSoftwareDisplaySink(mailbox: mailbox) {
                    do { try readyPublisher.publishOnce() }
                    catch {
                        FileHandle.standardError.write(
                            Data("dory-hv DoryPC readiness failed: \(error)\n".utf8)
                        )
                    }
                }
            }
            self.displaySink = displaySink
            let machine = try configuration.authority.makeMachine(displaySink: displaySink)
            machineState = MachineState(machine: machine)
            keyboardInput = DoryPCDesktopInputSink(device: machine.keyboardDevice)
            pointerInput = DoryPCDesktopInputSink(device: machine.tabletDevice)
            serialInput = try RawHVSerialConsoleInput(
                socketPath: configuration.consoleSocketPath,
                receive: { [machineState] bytes in
                    machineState.current().machine.serial.enqueueReceivedBytes(bytes)
                    return true
                }
            )
            lifecycleServer = VmmLifecycleReceiptServer(
                socketPath: configuration.controlSocketPath
            )

            if let display = devices.displays.first, let mailbox {
                let scale = max(1, CGFloat(display.backingScaleFactor))
                let size = NSSize(
                    width: CGFloat(display.widthPixels) / scale,
                    height: CGFloat(display.heightPixels) / scale
                )
                let view = try DesktopMetalView(
                    frame: NSRect(origin: .zero, size: size),
                    keyboardInput: keyboardInput,
                    pointerInput: pointerInput,
                    guestBackingScaleFactor: scale,
                    scanoutID: 0
                )
                mailbox.view = view
                let window = NSWindow(
                    contentRect: NSRect(origin: .zero, size: size),
                    styleMask: [.titled, .closable, .miniaturizable, .resizable],
                    backing: .buffered,
                    defer: false
                )
                window.title = "\(envelope.machineID) — Dory Desktop"
                window.contentView = view
                window.minSize = NSSize(width: 640, height: 400)
                window.collectionBehavior.insert(.fullScreenPrimary)
                window.tabbingMode = .disallowed
                window.center()
                self.window = window
            } else {
                window = nil
            }
            super.init()
            window?.delegate = self
        }

        func run() throws {
            defer { cleanup() }
            try lifecycleServer.start()
            DoryDesktopApplicationIdentity.install(on: application)
            application.setActivationPolicy(window == nil ? .accessory : .regular)
            application.delegate = self
            installSignals()
            window?.makeKeyAndOrderFront(nil)
            if window != nil { application.activate() }
            if window == nil { try readyPublisher.publishOnce() }
            startExecution()
            application.run()
            if let stopError { throw stopError }
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            machineState.requestStop()
            return false
        }

        func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
            machineState.requestStop()
            return .terminateCancel
        }

        private func startExecution() {
            executionQueue.async { [weak self] in self?.execute() }
        }

        private nonisolated func execute() {
            do {
                while true {
                    let composed = machineState.current()
                    let stop = try composed.machine.run(
                        maximumInstructions: 250_000,
                        exceptionPolicy: .deliver
                    )
                    for byte in composed.machine.serial.drainTransmittedBytes() {
                        serialOutput.enqueue(byte)
                    }
                    switch stop {
                    case .instructionBudget:
                        continue
                    case .reset:
                        guard !machineState.isStopping else {
                            finish(nil)
                            return
                        }
                        let replacement = try configuration.authority.makeMachine(
                            displaySink: displaySink
                        )
                        keyboardInput.replaceDevice(replacement.keyboardDevice)
                        pointerInput.replaceDevice(replacement.tabletDevice)
                        guard machineState.replace(replacement) else {
                            finish(nil)
                            return
                        }
                    case .poweredOff:
                        finish(nil)
                        return
                    case .halted(let count):
                        throw VMError.bootFailure(
                            "DoryPC halted without a pending wake source after \(count) instructions"
                        )
                    case .exception(let exception, let count):
                        throw VMError.bootFailure(
                            "DoryPC stopped on unhandled \(exception) after \(count) instructions"
                        )
                    case .tripleFault(let count):
                        throw VMError.bootFailure(
                            "DoryPC triple-faulted after \(count) instructions"
                        )
                    }
                }
            } catch {
                finish(error)
            }
        }

        private nonisolated func finish(_ error: Error?) {
            DesktopAppRunLoop.perform { [weak self] in
                guard let self else { return }
                if self.stopError == nil { self.stopError = error }
                self.application.stop(nil)
                if let event = NSEvent.otherEvent(
                    with: .applicationDefined,
                    location: .zero,
                    modifierFlags: [],
                    timestamp: 0,
                    windowNumber: 0,
                    context: nil,
                    subtype: 0,
                    data1: 0,
                    data2: 0
                ) {
                    self.application.postEvent(event, atStart: false)
                }
            }
        }

        private func installSignals() {
            for number in [SIGTERM, SIGINT] {
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: signalQueue)
                source.setEventHandler { [weak machineState] in machineState?.requestStop() }
                source.resume()
                signalSources.append(source)
            }
        }

        private func cleanup() {
            machineState.requestStop()
            signalSources.forEach { $0.cancel() }
            signalSources.removeAll()
            lifecycleServer.stop()
            serialInput.stop()
            _ = serialOutput.stop()
            try? serialLog.close()
            mailbox?.disable()
        }

        private static func openSerialLog(_ path: String) throws -> FileHandle {
            let descriptor = Darwin.open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else {
                throw VMError.invalidConfiguration(
                    "could not open DoryPC serial log: errno \(errno)"
                )
            }
            var status = stat()
            guard fstat(descriptor, &status) == 0,
                  status.st_mode & S_IFMT == S_IFREG,
                  status.st_uid == geteuid(),
                  status.st_mode & 0o077 == 0 else {
                let code = errno
                Darwin.close(descriptor)
                throw VMError.invalidConfiguration(
                    "DoryPC serial log is not an owner-private regular file: errno \(code)"
                )
            }
            return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        }
    }
}
