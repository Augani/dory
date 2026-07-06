import Foundation

enum HealthStatus: String, Sendable {
    case pass, warn, fail, skip

    init(_ raw: String) { self = HealthStatus(rawValue: raw) ?? .warn }

    var label: String {
        switch self {
        case .pass: "Pass"
        case .warn: "Warn"
        case .fail: "Fail"
        case .skip: "Skip"
        }
    }
}

enum HealthCategory: String, CaseIterable, Identifiable, Sendable {
    case engine = "Engine"
    case networking = "Networking"
    case fileSharing = "File sharing"
    case resources = "Disk & memory"
    case helpers = "Shell integration"
    case compatibility = "Compatibility"

    var id: String { rawValue }

    static func of(_ checkID: String) -> HealthCategory {
        switch checkID.split(separator: ".").first.map(String.init) ?? "" {
        case "socket", "docker", "context", "vm": .engine
        case "network", "registry", "ports", "domains": .networking
        case "mount", "mounts", "watch": .fileSharing
        case "disk", "memory": .resources
        case "helpers": .helpers
        case "compat": .compatibility
        default: .engine
        }
    }
}

struct DoctorCheck: Decodable, Sendable, Hashable {
    let id: String
    let status: String
    let code: String
    let title: String
    let detail: String
    let action: String?

    var health: HealthStatus { HealthStatus(status) }
    var category: HealthCategory { HealthCategory.of(id) }
}

struct DoctorReport: Decodable, Sendable {
    let results: [DoctorCheck]
}

struct IdleProxyState: Decodable, Sendable, Hashable {
    let state: String?
    let detail: String?
    let available: Bool?
}

struct IdleBlocker: Decodable, Sendable, Hashable {
    let type: String
    let detail: String

    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        var resolvedType = "blocker"
        var parts: [String] = []
        for key in container.allKeys {
            guard let value = Self.scalar(container, key) else { continue }
            if key.stringValue == "type" {
                resolvedType = value
            } else {
                parts.append("\(key.stringValue): \(value)")
            }
        }
        self.type = resolvedType
        self.detail = parts.sorted().joined(separator: ", ")
    }

    private static func scalar(_ container: KeyedDecodingContainer<DynamicKey>, _ key: DynamicKey) -> String? {
        if let value = try? container.decode(String.self, forKey: key) { return value }
        if let value = try? container.decode(Int.self, forKey: key) { return String(value) }
        if let value = try? container.decode(Bool.self, forKey: key) { return String(value) }
        if let value = try? container.decode(Double.self, forKey: key) { return String(value) }
        return nil
    }

    var humanType: String {
        switch type {
        case "running-container": "Running container"
        case "published-port": "Published port"
        case "pinned": "Pinned to stay awake"
        case "kubernetes-config": "Kubernetes enabled"
        case "engine": "Engine"
        default: type.replacingOccurrences(of: "-", with: " ").capitalized
        }
    }
}

func decodeFlexibleInt<Key: CodingKey>(_ container: KeyedDecodingContainer<Key>, _ key: Key) -> Int? {
    if let value = try? container.decode(Int.self, forKey: key) { return value }
    if let value = try? container.decode(Double.self, forKey: key) { return Int(value) }
    if let value = try? container.decode(String.self, forKey: key) { return Int(value) }
    return nil
}

struct IdlePolicy: Decodable, Sendable, Hashable {
    var sleepAfterMinutes: Int
    var keepPublishedPortsAwake: Bool
    var keepKubernetesAwake: Bool
    var keepPinnedProjectsAwake: Bool
    var showWakeNotifications: Bool

    static let fallback = IdlePolicy()

    enum CodingKeys: String, CodingKey {
        case sleepAfterMinutes, keepPublishedPortsAwake, keepKubernetesAwake, keepPinnedProjectsAwake, showWakeNotifications
    }

    init(
        sleepAfterMinutes: Int = 15,
        keepPublishedPortsAwake: Bool = true,
        keepKubernetesAwake: Bool = true,
        keepPinnedProjectsAwake: Bool = true,
        showWakeNotifications: Bool = true
    ) {
        self.sleepAfterMinutes = sleepAfterMinutes
        self.keepPublishedPortsAwake = keepPublishedPortsAwake
        self.keepKubernetesAwake = keepKubernetesAwake
        self.keepPinnedProjectsAwake = keepPinnedProjectsAwake
        self.showWakeNotifications = showWakeNotifications
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sleepAfterMinutes = decodeFlexibleInt(container, .sleepAfterMinutes) ?? 15
        keepPublishedPortsAwake = (try? container.decode(Bool.self, forKey: .keepPublishedPortsAwake)) ?? true
        keepKubernetesAwake = (try? container.decode(Bool.self, forKey: .keepKubernetesAwake)) ?? true
        keepPinnedProjectsAwake = (try? container.decode(Bool.self, forKey: .keepPinnedProjectsAwake)) ?? true
        showWakeNotifications = (try? container.decode(Bool.self, forKey: .showWakeNotifications)) ?? true
    }
}

struct IdleStatus: Decodable, Sendable {
    let mode: String
    let autoIdleEnabled: Bool
    let canSleep: Bool
    let sleepAfterMinutes: Int?
    let blockers: [IdleBlocker]
    let proxyState: IdleProxyState?
    let policy: IdlePolicy?

    enum CodingKeys: String, CodingKey {
        case mode, blockers, policy
        case autoIdleEnabled = "auto_idle_enabled"
        case canSleep = "can_sleep"
        case sleepAfterMinutes = "sleep_after_minutes"
        case proxyState = "proxy_state"
    }

    // Tolerant of a hand-edited ~/.dory/config: a null/float/string in any field must not throw and
    // wipe the whole Auto-Idle card. Every field falls back to a sane default.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = (try? container.decode(String.self, forKey: .mode)) ?? "manual"
        autoIdleEnabled = (try? container.decode(Bool.self, forKey: .autoIdleEnabled)) ?? false
        canSleep = (try? container.decode(Bool.self, forKey: .canSleep)) ?? true
        sleepAfterMinutes = decodeFlexibleInt(container, .sleepAfterMinutes)
        blockers = (try? container.decode([IdleBlocker].self, forKey: .blockers)) ?? []
        proxyState = try? container.decode(IdleProxyState.self, forKey: .proxyState)
        policy = try? container.decode(IdlePolicy.self, forKey: .policy)
    }
}

struct IdleHistoryEntry: Decodable, Sendable, Hashable {
    let at: String
    let state: String
    let detail: String?
}

struct FailableDecodable<Wrapped: Decodable>: Decodable {
    let value: Wrapped?
    init(from decoder: Decoder) throws {
        value = try? Wrapped(from: decoder)
    }
}

struct HealthSnapshot: Sendable {
    var checks: [DoctorCheck] = []
    var idle: IdleStatus?
    var history: [IdleHistoryEntry] = []
    var cliMissing = false
    var doctorError: String?
    var activeProbed = false
    var generatedAt = Date()

    func checks(in category: HealthCategory) -> [DoctorCheck] {
        checks.filter { $0.category == category }
    }

    var failing: Int { checks.filter { $0.health == .fail }.count }
    var warning: Int { checks.filter { $0.health == .warn }.count }
    var passing: Int { checks.filter { $0.health == .pass }.count }
    var skipped: Int { checks.filter { $0.health == .skip }.count }
}

enum DoryCLI {
    static func url() -> URL? {
        let fileManager = FileManager.default
        if let override = ProcessInfo.processInfo.environment["DORY_CLI"],
           !override.isEmpty,
           fileManager.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        if let bundled = bundledPath(named: "dory") {
            return URL(fileURLWithPath: bundled)
        }
        for candidate in ["/usr/local/bin/dory", "/opt/homebrew/bin/dory"] where fileManager.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        return nil
    }

    private static func bundledPath(named name: String) -> String? {
        let fileManager = FileManager.default
        if let auxiliary = Bundle.main.url(forAuxiliaryExecutable: name)?.path,
           fileManager.isExecutableFile(atPath: auxiliary) {
            return auxiliary
        }
        let bundleURL = Bundle.main.bundleURL
        let candidates = [
            bundleURL.appendingPathComponent("Contents/Helpers/\(name)").path,
            bundleURL.appendingPathComponent("Helpers/\(name)").path,
        ]
        return candidates.first { fileManager.isExecutableFile(atPath: $0) }
    }
}

enum HealthDiagnostics {
    static func load(active: Bool) async -> HealthSnapshot {
        guard let cli = DoryCLI.url() else {
            return HealthSnapshot(cliMissing: true)
        }
        let doctorArgs = active ? ["doctor", "--json", "--active"] : ["doctor", "--json"]
        async let doctorRun = run(cli, doctorArgs)
        async let compatRun = run(cli, ["compat", "--json"])
        async let idleRun = run(cli, ["idle", "status", "--json"])
        async let historyRun = run(cli, ["idle", "history", "--json", "--limit", "40"])
        let (doctor, compat, idle, history) = await (doctorRun, compatRun, idleRun, historyRun)

        var snapshot = HealthSnapshot(activeProbed: active)
        var checks: [DoctorCheck] = []
        if let report: DoctorReport = decode(doctor.stdout) {
            checks += report.results
        } else if !doctor.ok {
            snapshot.doctorError = firstLine(doctor.stderr.isEmpty ? doctor.stdout : doctor.stderr)
        }
        if let report: DoctorReport = decode(compat.stdout) {
            checks += report.results
        } else if !compat.ok, !compat.stderr.isEmpty {
            snapshot.doctorError = snapshot.doctorError ?? firstLine(compat.stderr)
        }
        snapshot.checks = checks
        snapshot.idle = decode(idle.stdout)
        if let rows: [FailableDecodable<IdleHistoryEntry>] = decode(history.stdout) {
            snapshot.history = rows.compactMap(\.value).reversed()
        }
        return snapshot
    }

    @discardableResult
    static func runControl(_ arguments: [String]) async -> (ok: Bool, output: String) {
        guard let cli = DoryCLI.url() else { return (false, "Dory CLI not found") }
        let result = await run(cli, arguments)
        let output = result.stdout.isEmpty ? result.stderr : result.stdout
        return (result.ok, output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func run(_ cli: URL, _ arguments: [String], timeout: TimeInterval = 90) async -> (ok: Bool, stdout: String, stderr: String) {
        let environment = childEnvironment()
        return await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            let process = Process()
            process.executableURL = cli
            process.arguments = arguments
            process.environment = environment
            let outPipe = Pipe()
            process.standardOutput = outPipe
            // stderr goes to a file, not a pipe: a file has no 64 KiB backpressure, so a chatty child
            // can never fill the buffer and deadlock while we are draining stdout.
            let errURL = fileManager.temporaryDirectory.appendingPathComponent("dory-health-\(UUID().uuidString).log")
            fileManager.createFile(atPath: errURL.path, contents: nil)
            let errHandle = try? FileHandle(forWritingTo: errURL)
            process.standardError = errHandle ?? FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                try? errHandle?.close()
                try? fileManager.removeItem(at: errURL)
                return (false, "", error.localizedDescription)
            }
            // Backstop a wedged CLI so the panel cannot spin forever; SIGTERM by pid, then reap.
            let pid = process.processIdentifier
            let watchdog = DispatchWorkItem { if kill(pid, 0) == 0 { kill(pid, SIGTERM) } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            watchdog.cancel()
            try? errHandle?.close()
            let errData = (try? Data(contentsOf: errURL)) ?? Data()
            try? fileManager.removeItem(at: errURL)
            let stdout = String(data: outData, encoding: .utf8) ?? ""
            var stderr = String(data: errData, encoding: .utf8) ?? ""
            if process.terminationReason == .uncaughtSignal, stderr.isEmpty {
                stderr = "Diagnostics timed out after \(Int(timeout))s"
            }
            return (process.terminationStatus == 0, stdout, stderr)
        }.value
    }

    private static func childEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        // A Finder-launched app has a minimal PATH. Put the bundle's Helpers (where dory, docker,
        // kubectl, and the doctor scripts live) first, then the system bins so /usr/bin/python3 and
        // the bundled docker resolve for the shelled-out CLI.
        let helpers = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers").path
        var pathParts = [helpers, "/usr/bin", "/bin", "/usr/sbin", "/sbin", "/usr/local/bin", "/opt/homebrew/bin"]
        if let existing = environment["PATH"], !existing.isEmpty {
            pathParts.append(existing)
        }
        environment["PATH"] = pathParts.joined(separator: ":")
        if environment["DORY_DOCKER_BIN"] == nil, let docker = HostTools.docker() {
            environment["DORY_DOCKER_BIN"] = docker
        }
        return environment
    }

    private static func decode<T: Decodable>(_ text: String) -> T? {
        guard let data = text.data(using: .utf8), !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func firstLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? "Diagnostics failed to run"
    }
}
