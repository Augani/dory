import Foundation

enum DependencyCondition: String, Sendable, Equatable {
    case started = "service_started"
    case healthy = "service_healthy"
    case completedSuccessfully = "service_completed_successfully"
}

struct ComposeDependency: Sendable, Equatable {
    var service: String
    var condition: DependencyCondition
}

struct ComposeHealthcheck: Sendable, Equatable {
    var test: [String]
    var interval: TimeInterval
    var timeout: TimeInterval
    var retries: Int
    var startPeriod: TimeInterval
    var startInterval: TimeInterval?

    var config: HealthcheckConfig {
        HealthcheckConfig(interval: interval, timeout: timeout, retries: retries, startPeriod: startPeriod)
    }

    var dockerConfig: DockerHealthConfig {
        if test == ["NONE"] {
            return DockerHealthConfig(Test: test)
        }
        return DockerHealthConfig(
            Test: test.isEmpty ? nil : test,
            Interval: Self.nanoseconds(interval),
            Timeout: Self.nanoseconds(timeout),
            Retries: retries,
            StartPeriod: Self.nanoseconds(startPeriod),
            StartInterval: startInterval.map(Self.nanoseconds)
        )
    }

    nonisolated private static func nanoseconds(_ seconds: TimeInterval) -> Int64 {
        Int64((seconds * 1_000_000_000).rounded())
    }
}

struct ComposeLogging: Sendable, Equatable {
    var driver: String?
    var options: [String: String]

    var dockerConfig: DockerLogConfig {
        DockerLogConfig(Type: driver, Config: options.isEmpty ? nil : options)
    }
}

struct ComposeService: Sendable, Equatable {
    var name: String
    var image: String?
    var build: String?
    var command: [String]
    var entrypoint: [String]
    var environment: [String: String]
    var ports: [String]
    var volumes: [String]
    var networks: [String]
    var dependsOn: [ComposeDependency]
    var restart: String?
    var healthcheck: ComposeHealthcheck?
    var profiles: [String]
    var hostname: String?
    var domainname: String?
    var user: String?
    var workingDir: String?
    var tty: Bool
    var stdinOpen: Bool
    var initProcessEnabled: Bool?
    var readOnly: Bool?
    var privileged: Bool?
    var capAdd: [String]
    var capDrop: [String]
    var dns: [String]
    var dnsOptions: [String]
    var dnsSearch: [String]
    var extraHosts: [String]
    var groupAdd: [String]
    var networkMode: String?
    var tmpfs: [String: String]
    var sysctls: [String: String]
    var securityOpt: [String]
    var storageOpt: [String: String]
    var logging: ComposeLogging?
    var ulimits: [DockerUlimit]
    var stopSignal: String?
    var stopGracePeriod: TimeInterval?
    var shmSize: Int64?
    var memoryLimitBytes: Int64?
    var memoryReservationBytes: Int64?
    var memorySwapBytes: Int64?
    var memorySwappiness: Int64?
    var oomKillDisable: Bool?
    var oomScoreAdj: Int?
    var pidsLimit: Int64?
    var ipcMode: String?
    var pidMode: String?
    var usernsMode: String?
    var utsMode: String?
    var runtimeName: String?
    var isolation: String?
    var links: [String]
    var volumesFrom: [String]

    init(
        name: String,
        image: String? = nil,
        build: String? = nil,
        command: [String] = [],
        entrypoint: [String] = [],
        environment: [String: String] = [:],
        ports: [String] = [],
        volumes: [String] = [],
        networks: [String] = [],
        dependsOn: [ComposeDependency] = [],
        restart: String? = nil,
        healthcheck: ComposeHealthcheck? = nil,
        profiles: [String] = [],
        hostname: String? = nil,
        domainname: String? = nil,
        user: String? = nil,
        workingDir: String? = nil,
        tty: Bool = false,
        stdinOpen: Bool = false,
        initProcessEnabled: Bool? = nil,
        readOnly: Bool? = nil,
        privileged: Bool? = nil,
        capAdd: [String] = [],
        capDrop: [String] = [],
        dns: [String] = [],
        dnsOptions: [String] = [],
        dnsSearch: [String] = [],
        extraHosts: [String] = [],
        groupAdd: [String] = [],
        networkMode: String? = nil,
        tmpfs: [String: String] = [:],
        sysctls: [String: String] = [:],
        securityOpt: [String] = [],
        storageOpt: [String: String] = [:],
        logging: ComposeLogging? = nil,
        ulimits: [DockerUlimit] = [],
        stopSignal: String? = nil,
        stopGracePeriod: TimeInterval? = nil,
        shmSize: Int64? = nil,
        memoryLimitBytes: Int64? = nil,
        memoryReservationBytes: Int64? = nil,
        memorySwapBytes: Int64? = nil,
        memorySwappiness: Int64? = nil,
        oomKillDisable: Bool? = nil,
        oomScoreAdj: Int? = nil,
        pidsLimit: Int64? = nil,
        ipcMode: String? = nil,
        pidMode: String? = nil,
        usernsMode: String? = nil,
        utsMode: String? = nil,
        runtimeName: String? = nil,
        isolation: String? = nil,
        links: [String] = [],
        volumesFrom: [String] = []
    ) {
        self.name = name
        self.image = image
        self.build = build
        self.command = command
        self.entrypoint = entrypoint
        self.environment = environment
        self.ports = ports
        self.volumes = volumes
        self.networks = networks
        self.dependsOn = dependsOn
        self.restart = restart
        self.healthcheck = healthcheck
        self.profiles = profiles
        self.hostname = hostname
        self.domainname = domainname
        self.user = user
        self.workingDir = workingDir
        self.tty = tty
        self.stdinOpen = stdinOpen
        self.initProcessEnabled = initProcessEnabled
        self.readOnly = readOnly
        self.privileged = privileged
        self.capAdd = capAdd
        self.capDrop = capDrop
        self.dns = dns
        self.dnsOptions = dnsOptions
        self.dnsSearch = dnsSearch
        self.extraHosts = extraHosts
        self.groupAdd = groupAdd
        self.networkMode = networkMode
        self.tmpfs = tmpfs
        self.sysctls = sysctls
        self.securityOpt = securityOpt
        self.storageOpt = storageOpt
        self.logging = logging
        self.ulimits = ulimits
        self.stopSignal = stopSignal
        self.stopGracePeriod = stopGracePeriod
        self.shmSize = shmSize
        self.memoryLimitBytes = memoryLimitBytes
        self.memoryReservationBytes = memoryReservationBytes
        self.memorySwapBytes = memorySwapBytes
        self.memorySwappiness = memorySwappiness
        self.oomKillDisable = oomKillDisable
        self.oomScoreAdj = oomScoreAdj
        self.pidsLimit = pidsLimit
        self.ipcMode = ipcMode
        self.pidMode = pidMode
        self.usernsMode = usernsMode
        self.utsMode = utsMode
        self.runtimeName = runtimeName
        self.isolation = isolation
        self.links = links
        self.volumesFrom = volumesFrom
    }
}

struct ComposeProject: Sendable, Equatable {
    var name: String
    var services: [ComposeService]
    var networks: [String]
    var volumes: [String]

    func service(named name: String) -> ComposeService? { services.first { $0.name == name } }

    /// Start order honoring depends_on (dependencies first).
    func startOrder() throws -> [String] {
        var deps: [String: [String]] = [:]
        for service in services { deps[service.name] = service.dependsOn.map(\.service) }
        return try DependencyGraph(dependencies: deps).topologicalOrder()
    }
}

enum ComposeParser {
    static func parse(
        _ text: String,
        projectName: String,
        variables: [String: String] = [:],
        activeProfiles: Set<String> = []
    ) throws -> ComposeProject {
        try parse([text], projectName: projectName, variables: variables, activeProfiles: activeProfiles)
    }

    static func parse(
        _ texts: [String],
        projectName: String,
        variables: [String: String] = [:],
        activeProfiles: Set<String> = []
    ) throws -> ComposeProject {
        guard !texts.isEmpty else { throw YAMLError.malformed("compose file list is empty") }
        let merged = try texts.reduce(YAMLValue.mapping([:])) { partial, text in
            let parsed = try YAMLParser.parse(text)
            let interpolated = ComposeInterpolation.interpolate(parsed, variables: variables)
            return merge(partial, interpolated, path: [])
        }
        guard let root = stripTags(merged).mappingValue else {
            throw YAMLError.malformed("compose root is not a mapping")
        }

        let servicesMap = root["services"]?.mappingValue ?? [:]
        let services = servicesMap.keys.sorted().compactMap { name -> ComposeService? in
            guard let value = servicesMap[name]?.mappingValue else { return nil }
            return parseService(name: name, value: value)
        }.filter {
            serviceIsEnabled($0, activeProfiles: activeProfiles)
        }

        let networks = Array((root["networks"]?.mappingValue ?? [:]).keys).sorted()
        let volumes = Array((root["volumes"]?.mappingValue ?? [:]).keys).sorted()
        return ComposeProject(name: projectName, services: services, networks: networks, volumes: volumes)
    }

    static func activeProfiles(from value: String?) -> Set<String> {
        guard let value else { return [] }
        return Set(value.split(separator: ",").map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })
    }

    private static let concatenatedServiceFields: Set<String> = [
        "dns", "dns_search", "expose", "external_links", "ports", "tmpfs",
    ]

    private static let keyedServiceFields: Set<String> = [
        "environment", "labels",
    ]

    private static let targetMergedServiceFields: Set<String> = [
        "devices", "volumes",
    ]

    private static func merge(_ base: YAMLValue, _ override: YAMLValue, path: [String]) -> YAMLValue {
        if case let .tagged(.override, value) = override {
            return stripTags(value)
        }
        if isServiceField(path, in: keyedServiceFields) {
            return mergeKeyedCollection(base, override)
        }
        if isServiceField(path, in: targetMergedServiceFields) {
            return mergeTargetedSequence(base, override)
        }
        if isServiceField(path, in: concatenatedServiceFields),
           let baseItems = strictSequence(base),
           let overrideItems = strictSequence(override) {
            return .sequence(baseItems + overrideItems)
        }

        guard case let .mapping(baseMap) = base, case let .mapping(overrideMap) = override else {
            return override
        }

        var merged = baseMap
        for (key, value) in overrideMap {
            if case .tagged(.reset, _) = value {
                merged[key] = nil
                continue
            }
            if let existing = merged[key] {
                merged[key] = merge(existing, value, path: path + [key])
            } else {
                merged[key] = stripTags(value)
            }
        }
        return .mapping(merged)
    }

    private static func stripTags(_ value: YAMLValue) -> YAMLValue {
        switch value {
        case let .tagged(_, inner): return stripTags(inner)
        case let .mapping(map): return .mapping(map.mapValues(stripTags))
        case let .sequence(items): return .sequence(items.map(stripTags))
        default: return value
        }
    }

    private static func isServiceField(_ path: [String], in fields: Set<String>) -> Bool {
        path.count >= 3 && path[0] == "services" && fields.contains(path[path.count - 1])
    }

    private static func strictSequence(_ value: YAMLValue) -> [YAMLValue]? {
        if case let .sequence(items) = value { return items }
        return nil
    }

    private static func mergeKeyedCollection(_ base: YAMLValue, _ override: YAMLValue) -> YAMLValue {
        guard var merged = keyedEntries(base), let overrideEntries = keyedEntries(override) else {
            return override
        }
        for (key, value) in overrideEntries {
            merged[key] = value
        }
        return .mapping(merged)
    }

    private static func keyedEntries(_ value: YAMLValue) -> [String: YAMLValue]? {
        switch value {
        case let .mapping(map):
            return map
        case let .sequence(items):
            return items.reduce(into: [:]) { result, item in
                guard let entry = item.stringValue else { return }
                if let separator = entry.firstIndex(of: "=") {
                    result[String(entry[..<separator])] = .string(String(entry[entry.index(after: separator)...]))
                } else {
                    result[entry] = .string("")
                }
            }
        default:
            return nil
        }
    }

    private static func mergeTargetedSequence(_ base: YAMLValue, _ override: YAMLValue) -> YAMLValue {
        guard var merged = strictSequence(base), let overrideItems = strictSequence(override) else {
            return override
        }
        var indexesByTarget: [String: Int] = [:]
        for (index, item) in merged.enumerated() {
            guard let target = mountTarget(item) else { continue }
            indexesByTarget[target] = index
        }
        for item in overrideItems {
            guard let target = mountTarget(item) else {
                merged.append(item)
                continue
            }
            if let index = indexesByTarget[target] {
                merged[index] = item
            } else {
                indexesByTarget[target] = merged.count
                merged.append(item)
            }
        }
        return .sequence(merged)
    }

    private static func mountTarget(_ value: YAMLValue) -> String? {
        switch value {
        case let .mapping(map):
            return map["target"]?.stringValue ?? map["destination"]?.stringValue
        case let .string(spec):
            let parts = spec.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            if parts.count >= 2 { return parts[1] }
            return parts.first
        default:
            return nil
        }
    }

    private static func serviceIsEnabled(_ service: ComposeService, activeProfiles: Set<String>) -> Bool {
        guard !service.profiles.isEmpty else { return true }
        if activeProfiles.contains("*") { return true }
        return !Set(service.profiles).isDisjoint(with: activeProfiles)
    }

    private static func parseService(name: String, value: [String: YAMLValue]) -> ComposeService {
        let memorySwappiness = value["mem_swappiness"].flatMap(parseInt64)

        return ComposeService(
            name: name,
            image: value["image"]?.stringValue,
            build: value["build"]?.stringValue ?? value["build"]?["context"]?.stringValue,
            command: value["command"]?.stringList ?? [],
            entrypoint: value["entrypoint"]?.stringList ?? [],
            environment: parseStringMap(value["environment"]),
            ports: value["ports"]?.stringList ?? [],
            volumes: value["volumes"]?.stringList ?? [],
            networks: parseServiceNetworks(value["networks"]),
            dependsOn: parseDependsOn(value["depends_on"]),
            restart: value["restart"]?.stringValue,
            healthcheck: parseHealthcheck(value["healthcheck"]),
            profiles: value["profiles"]?.stringList ?? [],
            hostname: value["hostname"]?.stringValue,
            domainname: value["domainname"]?.stringValue,
            user: value["user"]?.stringValue,
            workingDir: value["working_dir"]?.stringValue,
            tty: value["tty"]?.boolValue ?? false,
            stdinOpen: value["stdin_open"]?.boolValue ?? false,
            initProcessEnabled: value["init"]?.boolValue,
            readOnly: value["read_only"]?.boolValue,
            privileged: value["privileged"]?.boolValue,
            capAdd: value["cap_add"]?.stringList ?? [],
            capDrop: value["cap_drop"]?.stringList ?? [],
            dns: value["dns"]?.stringList ?? [],
            dnsOptions: value["dns_opt"]?.stringList ?? [],
            dnsSearch: value["dns_search"]?.stringList ?? [],
            extraHosts: value["extra_hosts"]?.stringList ?? [],
            groupAdd: value["group_add"]?.stringList ?? [],
            networkMode: value["network_mode"]?.stringValue,
            tmpfs: parseTmpfs(value["tmpfs"]),
            sysctls: parseStringMap(value["sysctls"]),
            securityOpt: value["security_opt"]?.stringList ?? [],
            storageOpt: parseStringMap(value["storage_opt"]),
            logging: parseLogging(value["logging"]),
            ulimits: parseUlimits(value["ulimits"]),
            stopSignal: value["stop_signal"]?.stringValue,
            stopGracePeriod: duration(value["stop_grace_period"]?.stringValue),
            shmSize: value["shm_size"].flatMap(parseByteSize),
            memoryLimitBytes: value["mem_limit"].flatMap(parseByteSize),
            memoryReservationBytes: value["mem_reservation"].flatMap(parseByteSize),
            memorySwapBytes: value["memswap_limit"].flatMap(parseByteSize),
            memorySwappiness: memorySwappiness,
            oomKillDisable: value["oom_kill_disable"]?.boolValue,
            oomScoreAdj: value["oom_score_adj"].flatMap(parseInt),
            pidsLimit: value["pids_limit"].flatMap(parseInt64),
            ipcMode: value["ipc"]?.stringValue,
            pidMode: value["pid"]?.stringValue,
            usernsMode: value["userns_mode"]?.stringValue,
            utsMode: value["uts"]?.stringValue,
            runtimeName: value["runtime"]?.stringValue,
            isolation: value["isolation"]?.stringValue,
            links: value["links"]?.stringList ?? [],
            volumesFrom: value["volumes_from"]?.stringList ?? []
        )
    }

    private static func parseDependsOn(_ value: YAMLValue?) -> [ComposeDependency] {
        switch value {
        case let .sequence(items):
            return items.compactMap { $0.stringValue.map { ComposeDependency(service: $0, condition: .started) } }
        case let .mapping(map):
            return map.keys.sorted().map { service in
                let condition = map[service]?["condition"]?.stringValue
                return ComposeDependency(service: service, condition: DependencyCondition(rawValue: condition ?? "") ?? .started)
            }
        default:
            return []
        }
    }

    private static func parseServiceNetworks(_ value: YAMLValue?) -> [String] {
        switch value {
        case let .mapping(map):
            return map.keys.sorted()
        default:
            return value?.stringList ?? []
        }
    }

    private static func parseHealthcheck(_ value: YAMLValue?) -> ComposeHealthcheck? {
        guard let map = value?.mappingValue else { return nil }
        if map["disable"]?.boolValue == true {
            return ComposeHealthcheck(test: ["NONE"], interval: 30, timeout: 30, retries: 3, startPeriod: 0)
        }
        let test: [String]
        switch map["test"] {
        case let .string(string): test = ["CMD-SHELL", string]
        case let .sequence(items): test = items.compactMap(\.stringValue)
        default: test = []
        }
        return ComposeHealthcheck(
            test: test,
            interval: duration(map["interval"]?.stringValue) ?? 30,
            timeout: duration(map["timeout"]?.stringValue) ?? 30,
            retries: Int(map["retries"]?.stringValue ?? "") ?? 3,
            startPeriod: duration(map["start_period"]?.stringValue) ?? 0,
            startInterval: duration(map["start_interval"]?.stringValue)
        )
    }

    private static func parseLogging(_ value: YAMLValue?) -> ComposeLogging? {
        guard let map = value?.mappingValue else { return nil }
        return ComposeLogging(driver: map["driver"]?.stringValue, options: parseStringMap(map["options"]))
    }

    private static func parseUlimits(_ value: YAMLValue?) -> [DockerUlimit] {
        guard let map = value?.mappingValue else { return [] }
        return map.keys.sorted().compactMap { name in
            guard let limit = map[name] else { return nil }
            if let nested = limit.mappingValue {
                let soft = nested["soft"].flatMap(parseInt64)
                let hard = nested["hard"].flatMap(parseInt64)
                return DockerUlimit(Name: name, Soft: soft, Hard: hard)
            }
            guard let parsed = parseInt64(limit) else { return nil }
            return DockerUlimit(Name: name, Soft: parsed, Hard: parsed)
        }
    }

    private static func parseTmpfs(_ value: YAMLValue?) -> [String: String] {
        switch value {
        case let .mapping(map):
            return map.reduce(into: [:]) { result, entry in result[entry.key] = entry.value.stringValue ?? "" }
        case let .sequence(items):
            return items.reduce(into: [:]) { result, item in
                guard let entry = item.stringValue else { return }
                let parsed = parseTmpfsEntry(entry)
                result[parsed.path] = parsed.options
            }
        case let .string(entry):
            let parsed = parseTmpfsEntry(entry)
            return [parsed.path: parsed.options]
        default:
            return [:]
        }
    }

    private static func parseTmpfsEntry(_ entry: String) -> (path: String, options: String) {
        guard let separator = entry.firstIndex(of: ":") else { return (entry, "") }
        return (String(entry[..<separator]), String(entry[entry.index(after: separator)...]))
    }

    private static func parseStringMap(_ value: YAMLValue?) -> [String: String] {
        switch value {
        case let .mapping(map):
            return map.reduce(into: [:]) { result, entry in result[entry.key] = entry.value.stringValue ?? "" }
        case let .sequence(items):
            return items.reduce(into: [:]) { result, item in
                guard let entry = item.stringValue else { return }
                if let separator = entry.firstIndex(of: "=") {
                    result[String(entry[..<separator])] = String(entry[entry.index(after: separator)...])
                } else {
                    result[entry] = ""
                }
            }
        default:
            return [:]
        }
    }

    nonisolated private static func parseInt(_ value: YAMLValue) -> Int? {
        parseInt64(value).map(Int.init)
    }

    nonisolated private static func parseInt64(_ value: YAMLValue) -> Int64? {
        guard let text = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if let integer = Int64(text) { return integer }
        return Double(text).map(Int64.init)
    }

    nonisolated private static func parseByteSize(_ value: YAMLValue) -> Int64? {
        guard let raw = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else {
            return nil
        }
        if let direct = Int64(raw) { return direct }
        let units: [(String, Double)] = [
            ("gib", 1_073_741_824), ("gb", 1_000_000_000), ("g", 1_073_741_824),
            ("mib", 1_048_576), ("mb", 1_000_000), ("m", 1_048_576),
            ("kib", 1_024), ("kb", 1_000), ("k", 1_024),
            ("b", 1),
        ]
        guard let unit = units.first(where: { raw.hasSuffix($0.0) }) else { return nil }
        let number = raw.dropLast(unit.0.count).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(number) else { return nil }
        return Int64((value * unit.1).rounded())
    }

    /// Parse Compose durations like "1m30s", "10s", "500ms".
    static func duration(_ text: String?) -> TimeInterval? {
        guard let text, !text.isEmpty else { return nil }
        if let plain = TimeInterval(text) { return plain }
        var total: TimeInterval = 0
        var number = ""
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c.isNumber || c == "." { number.append(c) }
            else {
                var unit = String(c)
                let next = text.index(after: i)
                if c == "m", next < text.endIndex, text[next] == "s" { unit = "ms"; i = next }
                let value = TimeInterval(number) ?? 0
                switch unit {
                case "ms": total += value / 1000
                case "s": total += value
                case "m": total += value * 60
                case "h": total += value * 3600
                default: break
                }
                number = ""
            }
            i = text.index(after: i)
        }
        return total
    }
}
