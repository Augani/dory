import Foundation

public struct DoryIdlePolicy: Equatable, Sendable {
    public var sleepAfterMinutes: Int
    public var keepPublishedPortsAwake: Bool
    public var keepKubernetesAwake: Bool
    public var keepPinnedProjectsAwake: Bool
    public var showWakeNotifications: Bool

    public init(
        sleepAfterMinutes: Int = 15,
        keepPublishedPortsAwake: Bool = true,
        keepKubernetesAwake: Bool = true,
        keepPinnedProjectsAwake: Bool = true,
        showWakeNotifications: Bool = true
    ) {
        self.sleepAfterMinutes = max(1, sleepAfterMinutes)
        self.keepPublishedPortsAwake = keepPublishedPortsAwake
        self.keepKubernetesAwake = keepKubernetesAwake
        self.keepPinnedProjectsAwake = keepPinnedProjectsAwake
        self.showWakeNotifications = showWakeNotifications
    }

    init(dictionary: [String: Any]) {
        self.init(
            sleepAfterMinutes: Self.int(dictionary["sleepAfterMinutes"]) ?? 15,
            keepPublishedPortsAwake: Self.bool(dictionary["keepPublishedPortsAwake"]) ?? true,
            keepKubernetesAwake: Self.bool(dictionary["keepKubernetesAwake"]) ?? true,
            keepPinnedProjectsAwake: Self.bool(dictionary["keepPinnedProjectsAwake"]) ?? true,
            showWakeNotifications: Self.bool(dictionary["showWakeNotifications"]) ?? true
        )
    }

    public var xpcDictionary: NSDictionary {
        [
            "sleepAfterMinutes": sleepAfterMinutes,
            "keepPublishedPortsAwake": keepPublishedPortsAwake,
            "keepKubernetesAwake": keepKubernetesAwake,
            "keepPinnedProjectsAwake": keepPinnedProjectsAwake,
            "showWakeNotifications": showWakeNotifications,
        ] as NSDictionary
    }

    private static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return value as? Int
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            switch string.lowercased() {
            case "1", "true", "yes", "on": return true
            case "0", "false", "no", "off": return false
            default: return nil
            }
        }
        return nil
    }
}

public final class IdlePolicyStore: @unchecked Sendable {
    public enum StoreError: Error, CustomStringConvertible {
        case invalidMode(String)
        case invalidKey(String)
        case invalidValue(String)
        case writeFailed(String)

        public var description: String {
            switch self {
            case let .invalidMode(mode):
                return "invalid runtime mode: \(mode)"
            case let .invalidKey(key):
                return "unknown idle policy key: \(key)"
            case let .invalidValue(value):
                return "invalid idle policy value: \(value)"
            case let .writeFailed(message):
                return "could not write idle policy: \(message)"
            }
        }
    }

    private static let runtimeModes = Set(["manual", "auto-idle", "always-on", "battery-saver"])
    // ISO8601DateFormatter isn't Sendable, but only its `string(from:)` is called here and that read
    // path is thread-safe; sharing one instance avoids reallocating a formatter on every status().
    nonisolated(unsafe) private static let iso8601Formatter = ISO8601DateFormatter()
    private static let integerKeys = Set(["sleepAfterMinutes"])
    private static let boolKeys = Set([
        "keepPublishedPortsAwake",
        "keepKubernetesAwake",
        "keepPinnedProjectsAwake",
        "showWakeNotifications",
    ])

    private let lock = NSLock()
    private let configPath: String
    private let statePath: String
    private let historyPath: String
    private let kubeconfigPath: String
    private let dockerContainers: @Sendable () -> DockerContainerList

    public init(
        home: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        dockerContainers: @escaping @Sendable () -> DockerContainerList = { .ok([]) }
    ) {
        self.configPath = (environment["DORY_CONFIG"] ?? "\(home)/.dory/config.json").expandedTilde
        self.statePath = (environment["DORY_IDLE_STATE"] ?? "\(home)/.dory/idle-state.json").expandedTilde
        self.historyPath = URL(fileURLWithPath: statePath)
            .deletingLastPathComponent()
            .appendingPathComponent("idle-history.jsonl")
            .path
        self.kubeconfigPath = (environment["DORY_KUBECONFIG"] ?? "\(home)/.kube/dory-config").expandedTilde
        self.dockerContainers = dockerContainers
    }

    public func currentPolicy() -> DoryIdlePolicy {
        lock.lock()
        defer { lock.unlock() }
        return policy(from: loadConfigLocked())
    }

    public func currentRuntimeMode() -> String {
        lock.lock()
        defer { lock.unlock() }
        return runtimeMode(from: loadConfigLocked())
    }

    public func managedEngineSleepEnabled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return Self.autoIdleEnabled(runtimeMode(from: loadConfigLocked()))
    }

    public func schedulerConfiguration(base: IdleSleepConfiguration) -> IdleSleepConfiguration {
        lock.lock()
        defer { lock.unlock() }
        let config = loadConfigLocked()
        let mode = runtimeMode(from: config)
        let policy = policy(from: config)
        return IdleSleepConfiguration(
            enabled: Self.autoIdleEnabled(mode),
            idleAfterSeconds: TimeInterval(Self.effectiveSleepAfterMinutes(
                mode: mode,
                configuredMinutes: policy.sleepAfterMinutes
            ) * 60),
            checkIntervalSeconds: base.checkIntervalSeconds
        )
    }

    public func status() -> NSDictionary {
        let snapshot = currentSnapshot()

        return [
            "generated_at": Self.iso8601Formatter.string(from: Date()),
            "mode": snapshot.mode,
            "auto_idle_enabled": Self.autoIdleEnabled(snapshot.mode),
            "sleep_after_minutes": snapshot.policy.sleepAfterMinutes,
            "effective_sleep_after_minutes": Self.effectiveSleepAfterMinutes(
                mode: snapshot.mode,
                configuredMinutes: snapshot.policy.sleepAfterMinutes
            ),
            "can_sleep": snapshot.blockers.isEmpty,
            "blockers": snapshot.blockers,
            "proxy_state": readProxyState(),
            "policy": snapshot.policy.xpcDictionary,
        ] as NSDictionary
    }

    public func canSleepNow() -> Bool {
        currentSnapshot().blockers.isEmpty
    }

    public func history(limit: Int) -> NSArray {
        let effectiveLimit = max(0, limit)
        guard effectiveLimit > 0,
              let text = try? String(contentsOfFile: historyPath, encoding: .utf8) else {
            return []
        }
        let records = text
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> NSDictionary? in
                guard let data = String(line).data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data),
                      let dictionary = Self.plistDictionary(object) else {
                    return nil
                }
                return dictionary
            }
        return Array(records.suffix(effectiveLimit)) as NSArray
    }

    @discardableResult
    public func setRuntimeMode(_ mode: String) throws -> NSDictionary {
        let trimmed = mode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.runtimeModes.contains(trimmed) else {
            throw StoreError.invalidMode(mode)
        }
        lock.lock()
        do {
            var config = loadConfigLocked()
            config["runtimeMode"] = trimmed
            try saveConfigLocked(config)
            lock.unlock()
        } catch {
            lock.unlock()
            throw error
        }
        return status()
    }

    @discardableResult
    public func setPolicy(key: String, value: String) throws -> NSDictionary {
        let parsed: Any
        if Self.integerKeys.contains(key) {
            guard let intValue = Int(value), intValue > 0 else {
                throw StoreError.invalidValue(value)
            }
            parsed = intValue
        } else if Self.boolKeys.contains(key) {
            guard let boolValue = Self.parseBool(value) else {
                throw StoreError.invalidValue(value)
            }
            parsed = boolValue
        } else {
            throw StoreError.invalidKey(key)
        }

        lock.lock()
        do {
            var config = loadConfigLocked()
            var idle = config["idle"] as? [String: Any] ?? defaultIdlePolicy()
            idle[key] = parsed
            config["idle"] = idle
            try saveConfigLocked(config)
            lock.unlock()
        } catch {
            lock.unlock()
            throw error
        }
        return status()
    }

    private func blockers(policy: DoryIdlePolicy) -> [NSDictionary] {
        switch dockerContainers() {
        case let .ok(containers):
            return containerBlockers(containers, policy: policy)
        case let .unavailable(reason):
            return [["type": "engine", "reason": reason] as NSDictionary]
        }
    }

    private func containerBlockers(_ containers: [DockerContainerSummary], policy: DoryIdlePolicy) -> [NSDictionary] {
        var blockers: [NSDictionary] = []
        var runningNames: Set<String> = []
        for container in containers where container.isRunning {
            let name = container.displayName
            let publishedPorts = container.ports.compactMap(\.publicPort)
            if policy.keepPublishedPortsAwake, !publishedPorts.isEmpty {
                runningNames.insert(name)
                for port in publishedPorts {
                    blockers.append([
                        "type": "published-port",
                        "container": name,
                        "port": port,
                    ] as NSDictionary)
                }
            }
            if !runningNames.contains(name) {
                blockers.append([
                    "type": "running-container",
                    "container": name,
                ] as NSDictionary)
            }
            if policy.keepPinnedProjectsAwake,
               (container.labels["io.dory.keep-awake"] == "true"
                   || container.labels["dev.dory.keep-awake"] == "true") {
                blockers.append([
                    "type": "pinned",
                    "container": name,
                ] as NSDictionary)
            }
        }
        return blockers
    }

    private struct PolicySnapshot {
        var mode: String
        var policy: DoryIdlePolicy
        var blockers: [NSDictionary]
    }

    private func currentSnapshot() -> PolicySnapshot {
        lock.lock()
        let config = loadConfigLocked()
        let mode = runtimeMode(from: config)
        let policy = policy(from: config)
        lock.unlock()

        var blockers = blockers(policy: policy)
        if policy.keepKubernetesAwake, FileManager.default.fileExists(atPath: kubeconfigPath) {
            blockers.append([
                "type": "kubernetes-config",
                "path": kubeconfigPath,
            ] as NSDictionary)
        }
        return PolicySnapshot(mode: mode, policy: policy, blockers: blockers)
    }

    private func loadConfigLocked() -> [String: Any] {
        let defaults = defaultConfig()
        guard FileManager.default.fileExists(atPath: configPath) else {
            // Absent config: defaults are the correct baseline for a fresh install.
            return defaults
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              let object = try? JSONSerialization.jsonObject(with: data),
              var config = object as? [String: Any] else {
            // Present but undecodable: preserve the user's file before a later write can
            // clobber it with regenerated defaults, and surface the problem instead of
            // silently resetting their policy.
            preserveCorruptConfigLocked()
            return defaults
        }
        if config["runtimeMode"] == nil {
            config["runtimeMode"] = defaults["runtimeMode"]
        }
        var idle = defaults["idle"] as? [String: Any] ?? [:]
        if let persisted = config["idle"] as? [String: Any] {
            for (key, value) in persisted {
                idle[key] = value
            }
        }
        config["idle"] = idle
        return config
    }

    private func preserveCorruptConfigLocked() {
        let backupPath = configPath + ".corrupt"
        guard !FileManager.default.fileExists(atPath: backupPath) else { return }
        do {
            try FileManager.default.copyItem(atPath: configPath, toPath: backupPath)
            FileHandle.standardError.write(Data(
                "doryd: corrupt idle config at \(configPath); backed up to \(backupPath), using defaults\n".utf8
            ))
        } catch {
            FileHandle.standardError.write(Data(
                "doryd: corrupt idle config at \(configPath); backup failed (\(error)); using defaults without overwriting\n".utf8
            ))
        }
    }

    private func saveConfigLocked(_ config: [String: Any]) throws {
        do {
            let url = URL(fileURLWithPath: configPath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: [.atomic])
        } catch {
            throw StoreError.writeFailed("\(error)")
        }
    }

    private func runtimeMode(from config: [String: Any]) -> String {
        let mode = (config["runtimeMode"] as? String) ?? "always-on"
        return Self.runtimeModes.contains(mode) ? mode : "always-on"
    }

    private func policy(from config: [String: Any]) -> DoryIdlePolicy {
        DoryIdlePolicy(dictionary: config["idle"] as? [String: Any] ?? defaultIdlePolicy())
    }

    private func readProxyState() -> NSDictionary {
        guard FileManager.default.fileExists(atPath: statePath) else {
            return [
                "available": false,
                "path": statePath,
                "state": "unknown",
                "detail": "doryd has not written idle state yet",
            ] as NSDictionary
        }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: statePath))
            let object = try JSONSerialization.jsonObject(with: data)
            var dictionary = Self.plistDictionary(object) as? [String: Any] ?? [:]
            dictionary["available"] = true
            dictionary["path"] = dictionary["path"] ?? statePath
            return dictionary as NSDictionary
        } catch {
            return [
                "available": false,
                "path": statePath,
                "state": "unknown",
                "detail": "could not read state: \(error)",
            ] as NSDictionary
        }
    }

    private func defaultConfig() -> [String: Any] {
        [
            "runtimeMode": "always-on",
            "idle": defaultIdlePolicy(),
            "network": [
                "probes": [],
                "lanVisible": false,
            ],
        ]
    }

    private func defaultIdlePolicy() -> [String: Any] {
        [
            "sleepAfterMinutes": 15,
            "keepPublishedPortsAwake": true,
            "keepKubernetesAwake": true,
            "keepPinnedProjectsAwake": true,
            "showWakeNotifications": true,
        ]
    }

    private static func autoIdleEnabled(_ mode: String) -> Bool {
        mode == "auto-idle" || mode == "battery-saver"
    }

    private static func effectiveSleepAfterMinutes(mode: String, configuredMinutes: Int) -> Int {
        mode == "battery-saver" ? min(5, configuredMinutes) : configuredMinutes
    }

    private static func parseBool(_ raw: String) -> Bool? {
        switch raw.lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }

    private static func plistDictionary(_ object: Any) -> NSDictionary? {
        guard let dictionary = object as? [String: Any] else { return nil }
        return plistValue(dictionary) as? NSDictionary
    }

    private static func plistValue(_ value: Any) -> Any {
        if value is NSNull {
            return ""
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.mapValues(plistValue) as NSDictionary
        }
        if let array = value as? [Any] {
            return array.map(plistValue) as NSArray
        }
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return number
        }
        return "\(value)"
    }
}

private extension String {
    var expandedTilde: String {
        NSString(string: self).expandingTildeInPath
    }
}
