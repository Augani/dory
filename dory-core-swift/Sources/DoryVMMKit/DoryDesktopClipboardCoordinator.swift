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

/// Host-side clipboard integration shared by the raw Hypervisor.framework and
/// Virtualization.framework desktop paths. Guest commands travel over Dory's authenticated agent
/// channel; AppKit access stays on the main thread and blocking work stays on one private queue.
public final class DoryDesktopClipboardCoordinator: @unchecked Sendable {
    public typealias Executor = @Sendable (
        _ argv: [String],
        _ stdin: Data,
        _ timeoutMs: UInt64,
        _ outputLimitBytes: UInt64
    ) throws -> DoryExecResult
    public typealias ShortcutSender = @MainActor @Sendable (_ linuxKeyCode: UInt16) -> Void

    private let policy: DoryVMClipboardPolicy
    private let execute: Executor
    private let sendShortcut: ShortcutSender
    private let pasteboard: NSPasteboard
    private let startupRetryDelay: TimeInterval
    private let startupRetryLimit: Int
    private let queue = DispatchQueue(label: "dev.dory.desktop-clipboard", qos: .userInitiated)
    private let log: @Sendable (String) -> Void
    private var observations = [NSObjectProtocol]()
    private var guestReady = false
    private var lastPushedHostChangeCount = -1

    public convenience init(
        policy: DoryDesktopClipboardPolicy,
        execute: @escaping Executor,
        sendShortcut: @escaping ShortcutSender,
        log: @escaping @Sendable (String) -> Void
    ) {
        self.init(
            policy: policy.virtualMachinePolicy,
            execute: execute,
            sendShortcut: sendShortcut,
            pasteboard: .general,
            startupRetryDelay: 1,
            startupRetryLimit: 60,
            log: log
        )
    }

    public convenience init(
        policy: DoryVMClipboardPolicy,
        execute: @escaping Executor,
        sendShortcut: @escaping ShortcutSender,
        log: @escaping @Sendable (String) -> Void
    ) {
        self.init(
            policy: policy,
            execute: execute,
            sendShortcut: sendShortcut,
            pasteboard: .general,
            startupRetryDelay: 1,
            startupRetryLimit: 60,
            log: log
        )
    }

    convenience init(
        policy: DoryDesktopClipboardPolicy,
        execute: @escaping Executor,
        sendShortcut: @escaping ShortcutSender,
        pasteboard: NSPasteboard,
        startupRetryDelay: TimeInterval,
        startupRetryLimit: Int,
        log: @escaping @Sendable (String) -> Void
    ) {
        self.init(
            policy: policy.virtualMachinePolicy,
            execute: execute,
            sendShortcut: sendShortcut,
            pasteboard: pasteboard,
            startupRetryDelay: startupRetryDelay,
            startupRetryLimit: startupRetryLimit,
            log: log
        )
    }

    init(
        policy: DoryVMClipboardPolicy,
        execute: @escaping Executor,
        sendShortcut: @escaping ShortcutSender,
        pasteboard: NSPasteboard,
        startupRetryDelay: TimeInterval,
        startupRetryLimit: Int,
        log: @escaping @Sendable (String) -> Void
    ) {
        self.policy = policy
        self.execute = execute
        self.sendShortcut = sendShortcut
        self.pasteboard = pasteboard
        self.startupRetryDelay = startupRetryDelay
        self.startupRetryLimit = max(0, startupRetryLimit)
        self.log = log
    }

    @MainActor
    public func start() {
        lastPushedHostChangeCount = pasteboard.changeCount
        observations.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: NSApplication.shared,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pushHostClipboardIfChanged(force: false) }
        })
        observations.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApplication.shared,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pullGuestClipboard() }
        })
    }

    @MainActor
    public func markGuestReady() {
        queue.async { [weak self] in
            guard let self else { return }
            let available: Bool
            do {
                let result = try self.execute(
                    ["/usr/bin/test", "-x", "/usr/lib/dory/clipboard"],
                    Data(),
                    5_000,
                    4_096
                )
                available = result.exitCode == 0 && !result.timedOut
            } catch {
                available = false
                self.log("clipboard capability probe failed: \(error)")
            }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
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
    }

    @MainActor
    public func stop() {
        guestReady = false
        for observation in observations {
            NotificationCenter.default.removeObserver(observation)
        }
        observations.removeAll()
    }

    /// Returns true when a macOS Command+C/X/V gesture was translated to its Linux Ctrl shortcut.
    @MainActor
    public func handleMacShortcut(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command),
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
            queue.async { [weak self] in
                guard let self else { return }
                let didWrite = self.writeGuestClipboard(payload)
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if didWrite {
                            self.lastPushedHostChangeCount = self.pasteboard.changeCount
                        }
                        self.sendShortcut(47)
                    }
                }
            }
            return true
        default:
            return false
        }
    }

    @MainActor
    private func scheduleGuestReadIfAllowed() {
        guard guestReady, policy.text.allowsGuestToHost || policy.image.allowsGuestToHost else {
            return
        }
        queue.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.readGuestClipboardAndPublishToHost()
        }
    }

    @MainActor
    private func pushHostClipboardIfChanged(
        force: Bool,
        startupRetriesRemaining: Int = 0
    ) {
        guard guestReady else { return }
        let changeCount = pasteboard.changeCount
        guard force || changeCount != lastPushedHostChangeCount,
              let payload = Self.readHostClipboard(from: pasteboard),
              allowsHostToGuest(payload) else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let didWrite = self.writeGuestClipboard(payload)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if didWrite, self.pasteboard.changeCount == changeCount {
                        self.lastPushedHostChangeCount = changeCount
                    } else if !didWrite,
                              self.guestReady,
                              startupRetriesRemaining > 0 {
                        DispatchQueue.main.asyncAfter(
                            deadline: .now() + self.startupRetryDelay
                        ) { [weak self] in
                            MainActor.assumeIsolated {
                                self?.pushHostClipboardIfChanged(
                                    force: true,
                                    startupRetriesRemaining: startupRetriesRemaining - 1
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    @MainActor
    private func pullGuestClipboard() {
        guard guestReady, policy.text.allowsGuestToHost || policy.image.allowsGuestToHost else {
            return
        }
        queue.async { [weak self] in self?.readGuestClipboardAndPublishToHost() }
    }

    private func writeGuestClipboard(_ payload: DoryDesktopClipboardPayload) -> Bool {
        do {
            let result = try execute(
                ["/usr/lib/dory/clipboard", "set", payload.mimeType],
                payload.data,
                5_000,
                64 * 1024
            )
            guard result.exitCode == 0, !result.timedOut else {
                log("clipboard write failed (exit=\(result.exitCode), timedOut=\(result.timedOut))")
                return false
            }
            return true
        } catch {
            log("clipboard write failed: \(error)")
            return false
        }
    }

    private func readGuestClipboardAndPublishToHost() {
        guard let payload = readGuestClipboard() else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                Self.writeHostClipboard(payload, to: self.pasteboard)
                self.lastPushedHostChangeCount = self.pasteboard.changeCount
            }
        }
    }

    private func readGuestClipboard() -> DoryDesktopClipboardPayload? {
        for mimeType in ["image/png", "text/plain;charset=utf-8", "text/plain"] {
            guard direction(for: mimeType).allowsGuestToHost else { continue }
            do {
                let result = try execute(
                    ["/usr/lib/dory/clipboard", "get", mimeType],
                    Data(),
                    5_000,
                    UInt64(DoryDesktopClipboardPayload.maximumBytes)
                )
                guard result.exitCode == 0, !result.timedOut, !result.stdoutTruncated else { continue }
                if mimeType == "image/png", result.stdout.isEmpty { continue }
                if let payload = DoryDesktopClipboardPayload(mimeType: mimeType, data: result.stdout) {
                    return payload
                }
            } catch {
                log("clipboard read failed: \(error)")
                return nil
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
