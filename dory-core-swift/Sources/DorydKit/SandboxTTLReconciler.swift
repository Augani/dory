import Foundation

public protocol SandboxMachineManaging: Sendable {
    func list() -> [DoryMachineStatus]
    @discardableResult
    func stop(id: String) throws -> DoryMachineStatus
    func delete(id: String) throws
}

extension MachineManager: SandboxMachineManaging {}

/// Daemon-owned expiry for sandbox machines. Expiration lives in persisted machine metadata, so a
/// CLI crash, logout, sleep, or doryd restart cannot orphan a temporary VM indefinitely.
public final class SandboxTTLReconciler: @unchecked Sendable {
    public static let sandboxMarkerKey = "DORY_SANDBOX"
    public static let expiresAtKey = "DORY_SANDBOX_EXPIRES_AT"

    private let machines: any SandboxMachineManaging
    private let interval: TimeInterval
    private let manifestDirectory: String?
    private let now: @Sendable () -> Date
    private let eventHandler: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "dev.dory.sandbox-ttl", qos: .utility)
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?

    public init(
        machines: any SandboxMachineManaging,
        interval: TimeInterval = 15,
        manifestDirectory: String? = nil,
        now: @escaping @Sendable () -> Date = Date.init,
        eventHandler: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.machines = machines
        self.interval = max(1, interval)
        self.manifestDirectory = manifestDirectory
        self.now = now
        self.eventHandler = eventHandler
    }

    @discardableResult
    public func reconcileNow() -> [String] {
        let epoch = UInt64(max(0, now().timeIntervalSince1970.rounded(.down)))
        let expired = machines.list().filter { status in
            guard status.environment[Self.sandboxMarkerKey] == "1",
                  let raw = status.environment[Self.expiresAtKey],
                  let expiration = UInt64(raw),
                  expiration > 0 else {
                return false
            }
            return expiration <= epoch
        }

        var deleted: [String] = []
        for sandbox in expired {
            do {
                _ = try? machines.stop(id: sandbox.id)
                try machines.delete(id: sandbox.id)
                deleted.append(sandbox.id)
                do {
                    try updateManifest(machineID: sandbox.id, status: "expired", epoch: epoch)
                } catch {
                    eventHandler("deleted expired sandbox \(sandbox.id), but manifest update failed: \(error)")
                    continue
                }
                eventHandler("deleted expired sandbox \(sandbox.id)")
            } catch {
                eventHandler("failed to delete expired sandbox \(sandbox.id): \(error)")
            }
        }
        return deleted
    }

    private func updateManifest(machineID: String, status: String, epoch: UInt64) throws {
        guard let manifestDirectory else { return }
        let path = "\(manifestDirectory)/\(machineID).json"
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return
        }
        let source = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: source)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["sandbox"] as? String == machineID else {
            throw CocoaError(.fileReadCorruptFile)
        }
        object["status"] = status
        object["updatedEpoch"] = epoch
        let updated = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let temporary = "\(manifestDirectory)/.sandbox-manifest-\(UUID().uuidString)"
        try updated.write(to: URL(fileURLWithPath: temporary), options: [.withoutOverwriting])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary)
        do {
            _ = try FileManager.default.replaceItemAt(
                source,
                withItemAt: URL(fileURLWithPath: temporary),
                backupItemName: nil,
                options: []
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        } catch {
            try? FileManager.default.removeItem(atPath: temporary)
            throw error
        }
    }

    public func start() {
        lock.lock()
        guard timer == nil else {
            lock.unlock()
            return
        }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: interval, leeway: .seconds(1))
        source.setEventHandler { [weak self] in
            _ = self?.reconcileNow()
        }
        timer = source
        lock.unlock()
        source.resume()
    }

    public func stop() {
        lock.lock()
        let source = timer
        timer = nil
        lock.unlock()
        source?.setEventHandler {}
        source?.cancel()
    }

    deinit {
        stop()
    }
}
