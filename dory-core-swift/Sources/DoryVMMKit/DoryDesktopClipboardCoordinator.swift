import AppKit
import DoryCore
import DoryOperations
import Foundation

private struct DoryDesktopClipboardPayload: Sendable, Equatable {
    // Leave headroom for the protobuf envelope under dory-proto's 16 MiB frame ceiling.
    static let maximumBytes = 15 * 1024 * 1024

    let mimeType: String
    let data: Data

    init?(mimeType: String, data: Data) {
        guard data.count <= Self.maximumBytes else { return nil }
        self.mimeType = mimeType
        self.data = data
    }
}

/// A deliberately narrow clipboard transport. Unlike the former exec closure, callers can only
/// negotiate the clipboard capability or exchange one whitelisted MIME payload.
public struct DoryDesktopClipboardTransport: Sendable {
    public typealias Availability = @Sendable () throws -> Bool
    public typealias Getter = @Sendable (_ mimeType: String) throws -> Data
    public typealias Setter = @Sendable (_ mimeType: String, _ data: Data) throws -> Void

    let availability: Availability
    let get: Getter
    let set: Setter

    public init(
        availability: @escaping Availability,
        get: @escaping Getter,
        set: @escaping Setter
    ) {
        self.availability = availability
        self.get = get
        self.set = set
    }
}

/// Host-side clipboard integration shared by the raw Hypervisor.framework and
/// Virtualization.framework desktop paths. Requests travel over Dory's authenticated agent
/// channel; AppKit access stays on the main thread and blocking work stays on one private queue.
public final class DoryDesktopClipboardCoordinator: @unchecked Sendable {
    public typealias ShortcutSender = @MainActor @Sendable (_ linuxKeyCode: UInt16) -> Void
    private struct Authority: Equatable, Sendable {
        let run: UUID
        let focus: UUID
    }
    private final class TransportAction: @unchecked Sendable {
        private let lock = NSLock()
        private var completed = false
        private let completion: @Sendable () -> Void
        init(completion: @escaping @Sendable () -> Void) { self.completion = completion }
        func complete() {
            let first = lock.withLock {
                guard !completed else { return false }
                completed = true
                return true
            }
            if first { completion() }
        }
        deinit { complete() }
    }

    private let policy: DoryVMClipboardPolicy
    private let transport: DoryDesktopClipboardTransport
    private let focusLease: DoryDesktopClipboardFocusLease
    private let sendShortcut: ShortcutSender
    private let pasteboard: NSPasteboard
    private let startupRetryDelay: TimeInterval
    private let startupRetryLimit: Int
    private let pollInterval: TimeInterval
    private let queue = DispatchQueue(label: "dev.dory.desktop-clipboard", qos: .userInitiated)
    private let log: @Sendable (String) -> Void
    private let lifecycleLock = NSLock()
    private var runGeneration: UUID?
    private var queuedPasteActions = 0
    private static let maximumQueuedPasteActions = 8
    // This quota survives focus and run changes: a blocked old RPC must not allow repeated
    // revoke/reacquire cycles to accumulate unbounded closures behind it.
    private var queuedTransportActions = 0
    private static let maximumQueuedTransportActions = 12
    private var observations = [NSObjectProtocol]()
    private var workspaceObservations = [NSObjectProtocol]()
    private var pollTimer: Timer?
    private var guestReady = false
    private var capabilityProbeInFlight = false
    private var guestReadInFlight = false
    private var hostWriteInFlight = false
    private var lastPushedHostChangeCount = -1
    private var lastPublishedGuestPayload: DoryDesktopClipboardPayload?
    private var localFocusProvider: (@MainActor @Sendable () -> Bool)?
    private var localFocusLeaseID: UUID?
    private var observedFocusGeneration: UUID?
    private var guestReadinessRequested = false

    public convenience init(
        policy: DoryDesktopClipboardPolicy,
        transport: DoryDesktopClipboardTransport,
        focusLease: DoryDesktopClipboardFocusLease = .init(),
        sendShortcut: @escaping ShortcutSender,
        log: @escaping @Sendable (String) -> Void
    ) {
        self.init(
            policy: policy.virtualMachinePolicy,
            transport: transport,
            focusLease: focusLease,
            sendShortcut: sendShortcut,
            pasteboard: .general,
            startupRetryDelay: 1,
            startupRetryLimit: 60,
            pollInterval: 0.5,
            log: log
        )
    }

    public convenience init(
        policy: DoryVMClipboardPolicy,
        transport: DoryDesktopClipboardTransport,
        focusLease: DoryDesktopClipboardFocusLease = .init(),
        sendShortcut: @escaping ShortcutSender,
        log: @escaping @Sendable (String) -> Void
    ) {
        self.init(
            policy: policy,
            transport: transport,
            focusLease: focusLease,
            sendShortcut: sendShortcut,
            pasteboard: .general,
            startupRetryDelay: 1,
            startupRetryLimit: 60,
            pollInterval: 0.5,
            log: log
        )
    }

    convenience init(
        policy: DoryDesktopClipboardPolicy,
        transport: DoryDesktopClipboardTransport,
        focusLease: DoryDesktopClipboardFocusLease = .init(),
        sendShortcut: @escaping ShortcutSender,
        pasteboard: NSPasteboard,
        startupRetryDelay: TimeInterval,
        startupRetryLimit: Int,
        pollInterval: TimeInterval = 0.5,
        log: @escaping @Sendable (String) -> Void
    ) {
        self.init(
            policy: policy.virtualMachinePolicy,
            transport: transport,
            focusLease: focusLease,
            sendShortcut: sendShortcut,
            pasteboard: pasteboard,
            startupRetryDelay: startupRetryDelay,
            startupRetryLimit: startupRetryLimit,
            pollInterval: pollInterval,
            log: log
        )
    }

    init(
        policy: DoryVMClipboardPolicy,
        transport: DoryDesktopClipboardTransport,
        focusLease: DoryDesktopClipboardFocusLease = .init(),
        sendShortcut: @escaping ShortcutSender,
        pasteboard: NSPasteboard,
        startupRetryDelay: TimeInterval,
        startupRetryLimit: Int,
        pollInterval: TimeInterval = 0.5,
        log: @escaping @Sendable (String) -> Void
    ) {
        self.policy = policy
        self.transport = transport
        self.focusLease = focusLease
        self.sendShortcut = sendShortcut
        self.pasteboard = pasteboard
        self.startupRetryDelay = startupRetryDelay
        self.startupRetryLimit = max(0, startupRetryLimit)
        self.pollInterval = max(0.01, pollInterval)
        self.log = log
    }

    /// Local windows use their actual VM view's first-responder state. Relay-owned desktops leave
    /// this unset: only authenticated focus commands may renew their supplied lease.
    @MainActor
    public func observeLocalDisplayFocus(_ provider: @escaping @MainActor @Sendable () -> Bool) {
        localFocusProvider = provider
        synchronizeFocus()
    }

    @MainActor
    private func synchronizeFocus() {
        if let localFocusProvider {
            if localFocusProvider() {
                let leaseID = localFocusLeaseID ?? UUID()
                localFocusLeaseID = leaseID
                focusLease.update(leaseID: leaseID, active: true)
            } else {
                localFocusLeaseID = nil
                focusLease.invalidate()
            }
        }
        let generation = focusLease.currentGeneration
        guard generation != observedFocusGeneration else { return }
        observedFocusGeneration = generation
        lifecycleLock.withLock { queuedPasteActions = 0 }
        capabilityProbeInFlight = false
        guestReadInFlight = false
        hostWriteInFlight = false
        lastPublishedGuestPayload = nil
        lastPushedHostChangeCount = -1
    }

    @MainActor
    public func start() {
        guard policy.text != .off || policy.image != .off else { return }
        let generation = lifecycleLock.withLock { () -> UUID? in
            guard runGeneration == nil else { return nil }
            let generation = UUID()
            runGeneration = generation
            queuedPasteActions = 0
            return generation
        }
        guard let generation else { return }
        guestReady = false
        capabilityProbeInFlight = false
        guestReadInFlight = false
        hostWriteInFlight = false
        lastPublishedGuestPayload = nil
        lastPushedHostChangeCount = pasteboard.changeCount
        observations.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: NSApplication.shared,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.permitsRun(generation) else { return }
                self.synchronizeFocus()
                self.pushHostClipboardIfChanged(force: false)
            }
        })
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification] {
            observations.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.permitsRun(generation),
                          self.localFocusProvider != nil else { return }
                    self.synchronizeFocus()
                }
            })
        }
        workspaceObservations.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: nil
        ) { [focusLease] _ in focusLease.invalidate() })
        for (name, awake) in [(NSWorkspace.willSleepNotification, false),
                              (NSWorkspace.didWakeNotification, true)] {
            workspaceObservations.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: nil
            ) { [focusLease] _ in focusLease.setHostAwake(awake) })
        }
        observations.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApplication.shared,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.permitsRun(generation) else { return }
                if self.localFocusProvider != nil {
                    self.localFocusLeaseID = nil
                    self.focusLease.invalidate()
                    self.synchronizeFocus()
                }
            }
        })
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) {
            [weak self] _ in
            Task { @MainActor in
                guard let self, self.permitsRun(generation) else { return }
                self.pollClipboard()
            }
        }
    }

    @MainActor
    public func markGuestReady() {
        guestReadinessRequested = true
        synchronizeFocus()
        probeGuestAvailabilityIfAllowed()
    }

    @MainActor
    private func probeGuestAvailabilityIfAllowed() {
        guard guestReadinessRequested, !guestReady,
              let generation = currentAuthority, !capabilityProbeInFlight else { return }
        capabilityProbeInFlight = scheduleTransport(generation: generation) { [weak self] _, action in
            guard let self else { return }
            let available: Bool
            do {
                available = try self.transport.availability()
            } catch {
                available = false
                self.log("clipboard capability probe failed: \(error)")
            }
            Task { @MainActor [weak self] in
                defer { action.complete() }
                guard let self, self.permits(generation) else { return }
                self.capabilityProbeInFlight = false
                self.guestReady = available
                if available {
                    // The agent commonly becomes ready a few seconds before GDM creates the
                    // user's Wayland/X11 clipboard. Keep retrying the initial transfer so a
                    // Mac clipboard copied before boot is not silently dropped.
                    self.pushHostClipboardIfChanged(
                        force: true,
                        startupRetriesRemaining: self.startupRetryLimit
                    )
                } else {
                    self.log("clipboard integration is unavailable until guest tools are updated")
                }
            }
        }
    }

    @MainActor
    public func stop() {
        lifecycleLock.withLock {
            runGeneration = nil
            queuedPasteActions = 0
        }
        // No work is admitted once the run is nil. Reset the sleep latch so a stopped instance
        // can be started after wake even if it removed its observers before didWake arrived.
        focusLease.setHostAwake(true)
        localFocusLeaseID = nil
        observedFocusGeneration = nil
        guestReadinessRequested = false
        guestReady = false
        capabilityProbeInFlight = false
        guestReadInFlight = false
        hostWriteInFlight = false
        pollTimer?.invalidate()
        pollTimer = nil
        for observation in observations {
            NotificationCenter.default.removeObserver(observation)
        }
        observations.removeAll()
        for observation in workspaceObservations {
            NSWorkspace.shared.notificationCenter.removeObserver(observation)
        }
        workspaceObservations.removeAll()
    }

    @MainActor
    private func pollClipboard() {
        synchronizeFocus()
        probeGuestAvailabilityIfAllowed()
        pushHostClipboardIfChanged(force: false)
        scheduleGuestReadIfAllowed()
    }

    /// Returns true when a macOS Command+C/X/V gesture was translated to its Linux Ctrl shortcut.
    @MainActor
    public func handleMacShortcut(_ event: NSEvent) -> Bool {
        synchronizeFocus()
        guard let generation = currentAuthority, event.modifierFlags.contains(.command),
              let character = event.charactersIgnoringModifiers?.lowercased() else {
            return false
        }
        switch character {
        case "c":
            sendShortcut(46)
            scheduleGuestReadIfAllowed()
            return true
        case "x":
            sendShortcut(45)
            scheduleGuestReadIfAllowed()
            return true
        case "v":
            guard guestReady,
                  let payload = Self.readHostClipboard(from: pasteboard),
                  allowsHostToGuest(payload) else {
                sendShortcut(47)
                return true
            }
            let changeCount = pasteboard.changeCount
            guard reservePasteAction(generation) else {
                log("clipboard paste queue exhausted (limit \(Self.maximumQueuedPasteActions))")
                return true
            }
            let scheduled = scheduleTransport(generation: generation) { [weak self] _, action in
                guard let self else { return }
                let didWrite = self.writeGuestClipboard(payload, generation: generation)
                Task { @MainActor [weak self] in
                    defer { action.complete() }
                    guard let self else { return }
                    self.synchronizeFocus()
                    guard self.permits(generation) else { return }
                    self.releasePasteAction(generation)
                    if didWrite, self.pasteboard.changeCount == changeCount {
                        self.lastPushedHostChangeCount = changeCount
                        self.lastPublishedGuestPayload = payload
                    }
                    self.sendShortcut(47)
                }
            }
            if !scheduled {
                releasePasteAction(generation)
                log("clipboard transport queue exhausted (limit \(Self.maximumQueuedTransportActions))")
            }
            return true
        default:
            return false
        }
    }

    @MainActor
    private func scheduleGuestReadIfAllowed() {
        synchronizeFocus()
        guard guestReady, !guestReadInFlight, let generation = currentAuthority,
              policy.text.allowsGuestToHost || policy.image.allowsGuestToHost else {
            return
        }
        let hostChangeCount = pasteboard.changeCount
        guestReadInFlight = scheduleTransport(generation: generation, after: 0.15) { [weak self] _, action in
            guard let self else { return }
            self.readGuestClipboardAndPublishToHost(
                generation: generation, hostChangeCount: hostChangeCount, action: action
            )
        }
    }

    @MainActor
    private func pushHostClipboardIfChanged(
        force: Bool,
        startupRetriesRemaining: Int = 0
    ) {
        synchronizeFocus()
        guard guestReady, !hostWriteInFlight, let generation = currentAuthority else { return }
        let changeCount = pasteboard.changeCount
        guard force || changeCount != lastPushedHostChangeCount,
              let payload = Self.readHostClipboard(from: pasteboard),
              allowsHostToGuest(payload) else { return }
        hostWriteInFlight = scheduleTransport(generation: generation) { [weak self] _, action in
            guard let self else { return }
            let didWrite = self.writeGuestClipboard(payload, generation: generation)
            Task { @MainActor [weak self] in
                defer { action.complete() }
                guard let self else { return }
                self.synchronizeFocus()
                guard self.permits(generation) else { return }
                self.hostWriteInFlight = false
                if didWrite, self.pasteboard.changeCount == changeCount {
                    self.lastPushedHostChangeCount = changeCount
                    self.lastPublishedGuestPayload = payload
                } else if !didWrite,
                          self.guestReady,
                          startupRetriesRemaining > 0 {
                    DispatchQueue.main.asyncAfter(
                        deadline: .now() + self.startupRetryDelay
                    ) { [weak self] in
                        Task { @MainActor in
                            guard let self, self.permits(generation) else { return }
                            self.pushHostClipboardIfChanged(
                                force: true,
                                startupRetriesRemaining: startupRetriesRemaining - 1
                            )
                        }
                    }
                }
            }
        }
    }

    private var currentAuthority: Authority? {
        guard let focus = focusLease.currentGeneration,
              let run = lifecycleLock.withLock({ runGeneration }) else { return nil }
        return Authority(run: run, focus: focus)
    }

    private func permitsRun(_ generation: UUID) -> Bool {
        lifecycleLock.withLock { runGeneration == generation }
    }

    private func permits(_ generation: Authority) -> Bool {
        currentAuthority == generation
    }

    private func scheduleTransport(
        generation: Authority, after delay: TimeInterval = 0,
        _ work: @escaping @Sendable (DoryDesktopClipboardCoordinator, TransportAction) -> Void
    ) -> Bool {
        guard permits(generation) else { return false }
        let admitted = lifecycleLock.withLock {
            guard runGeneration == generation.run,
                  queuedTransportActions < Self.maximumQueuedTransportActions else { return false }
            queuedTransportActions += 1
            return true
        }
        guard admitted else { return false }
        let action = TransportAction { [weak self] in
            guard let self else { return }
            self.lifecycleLock.withLock {
                precondition(self.queuedTransportActions > 0)
                self.queuedTransportActions -= 1
            }
        }
        queue.asyncAfter(deadline: .now() + max(0, delay)) { [weak self] in
            guard let self, self.permits(generation) else {
                action.complete()
                return
            }
            work(self, action)
        }
        return true
    }

    private func reservePasteAction(_ generation: Authority) -> Bool {
        guard focusLease.currentGeneration == generation.focus else { return false }
        return lifecycleLock.withLock {
            guard runGeneration == generation.run,
                  queuedPasteActions < Self.maximumQueuedPasteActions else { return false }
            queuedPasteActions += 1
            return true
        }
    }

    private func releasePasteAction(_ generation: Authority) {
        guard focusLease.currentGeneration == generation.focus else { return }
        lifecycleLock.withLock {
            guard runGeneration == generation.run else { return }
            precondition(queuedPasteActions > 0)
            queuedPasteActions -= 1
        }
    }

    private func writeGuestClipboard(
        _ payload: DoryDesktopClipboardPayload, generation: Authority
    ) -> Bool {
        // Already-submitted guest RPCs cannot be recalled by this transport. Revocation prevents
        // queued RPC admission and all later host publication/shortcut effects, without blocking
        // the MainActor on a guest that has stopped answering.
        guard permits(generation) else { return false }
        do {
            try transport.set(payload.mimeType, payload.data)
            return true
        } catch {
            log("clipboard write failed: \(error)")
            return false
        }
    }

    private func readGuestClipboardAndPublishToHost(
        generation: Authority, hostChangeCount: Int, action: TransportAction
    ) {
        guard permits(generation) else { return }
        let payload = readGuestClipboard(generation: generation)
        Task { @MainActor [weak self] in
            defer { action.complete() }
            guard let self else { return }
            self.synchronizeFocus()
            guard self.permits(generation) else { return }
            self.guestReadInFlight = false
            guard let payload, self.pasteboard.changeCount == hostChangeCount else { return }
            guard payload != self.lastPublishedGuestPayload else { return }
            Self.writeHostClipboard(payload, to: self.pasteboard)
            self.lastPushedHostChangeCount = self.pasteboard.changeCount
            self.lastPublishedGuestPayload = payload
        }
    }

    private func readGuestClipboard(generation: Authority) -> DoryDesktopClipboardPayload? {
        for mimeType in ["image/png", "text/plain;charset=utf-8", "text/plain"] {
            guard permits(generation) else { return nil }
            guard direction(for: mimeType).allowsGuestToHost else { continue }
            do {
                let data = try transport.get(mimeType)
                if mimeType == "image/png", data.isEmpty { continue }
                if let payload = DoryDesktopClipboardPayload(mimeType: mimeType, data: data) {
                    return payload
                }
            } catch {
                log("clipboard read failed for \(mimeType): \(error)")
                continue
            }
        }
        return nil
    }

    private func allowsHostToGuest(_ payload: DoryDesktopClipboardPayload) -> Bool {
        direction(for: payload.mimeType).allowsHostToGuest
    }

    private func direction(for mimeType: String) -> DoryVMClipboardDirection {
        mimeType == "image/png" ? policy.image : policy.text
    }

    @MainActor
    private static func readHostClipboard(
        from pasteboard: NSPasteboard
    ) -> DoryDesktopClipboardPayload? {
        if let png = pasteboard.data(forType: .png),
           let payload = DoryDesktopClipboardPayload(mimeType: "image/png", data: png) {
            return payload
        }
        if let tiff = pasteboard.data(forType: .tiff),
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]),
           let payload = DoryDesktopClipboardPayload(mimeType: "image/png", data: png) {
            return payload
        }
        guard let string = pasteboard.string(forType: .string) else { return nil }
        return DoryDesktopClipboardPayload(
            mimeType: "text/plain;charset=utf-8",
            data: Data(string.utf8)
        )
    }

    @MainActor
    private static func writeHostClipboard(
        _ payload: DoryDesktopClipboardPayload,
        to pasteboard: NSPasteboard
    ) {
        pasteboard.clearContents()
        if payload.mimeType == "image/png" {
            pasteboard.setData(payload.data, forType: .png)
        } else {
            pasteboard.setString(String(decoding: payload.data, as: UTF8.self), forType: .string)
        }
    }
}
