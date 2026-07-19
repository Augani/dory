import CryptoKit
import Darwin
import Foundation

public enum CorporateConnectivityError: Error, CustomStringConvertible, Sendable {
    case invalidProfile([String])
    case unsafePath(String)
    case ownershipConflict(String)
    case unavailable(String)

    public var description: String {
        switch self {
        case let .invalidProfile(errors):
            "invalid corporate connectivity profile: " + errors.joined(separator: "; ")
        case let .unsafePath(path):
            "refusing unsafe corporate connectivity path: \(path)"
        case let .ownershipConflict(detail):
            "corporate connectivity ownership conflict: \(detail)"
        case let .unavailable(detail):
            detail
        }
    }
}

public struct CorporateProxyLayer: Codable, Sendable, Equatable {
    public enum Source: String, Codable, Sendable {
        case disabled
        case system
        case manual
        case inheritHost = "inherit-host"
    }

    public var source: Source
    public var httpProxy: String?
    public var httpsProxy: String?
    public var noProxy: [String]
    public var pacURL: String?

    public init(
        source: Source = .disabled,
        httpProxy: String? = nil,
        httpsProxy: String? = nil,
        noProxy: [String] = [],
        pacURL: String? = nil
    ) {
        self.source = source
        self.httpProxy = httpProxy
        self.httpsProxy = httpsProxy
        self.noProxy = noProxy
        self.pacURL = pacURL
    }

    public var isConfigured: Bool {
        source != .disabled && (source == .system || httpProxy != nil || httpsProxy != nil || pacURL != nil)
    }
}

public struct CorporateRegistryConfiguration: Codable, Sendable, Equatable {
    public var mirrors: [String]
    public var insecureRegistries: [String]
    public var probeRegistries: [String]

    public init(
        mirrors: [String] = [],
        insecureRegistries: [String] = [],
        probeRegistries: [String] = ["https://registry-1.docker.io/v2/"]
    ) {
        self.mirrors = mirrors
        self.insecureRegistries = insecureRegistries
        self.probeRegistries = probeRegistries
    }
}

public struct CorporateCAConfiguration: Codable, Sendable, Equatable {
    public enum Scope: String, Codable, Sendable, CaseIterable {
        case hostProbe = "host-probe"
        case dockerdRegistry = "dockerd-registry"
        case buildKit = "buildkit"
        case containers
    }

    public var id: String
    public var path: String
    public var sha256: String
    public var scopes: [Scope]

    public init(id: String, path: String, sha256: String, scopes: [Scope]) {
        self.id = id
        self.path = path
        self.sha256 = sha256
        self.scopes = scopes
    }
}

public struct CorporateSplitDNSRule: Codable, Sendable, Equatable {
    public var domain: String
    public var servers: [String]
    public var probeNames: [String]
    public var requireSOA: Bool
    public var followCNAME: Bool

    public init(
        domain: String,
        servers: [String],
        probeNames: [String] = [],
        requireSOA: Bool = true,
        followCNAME: Bool = true
    ) {
        self.domain = domain
        self.servers = servers
        self.probeNames = probeNames
        self.requireSOA = requireSOA
        self.followCNAME = followCNAME
    }
}

/// One explicit, versioned contract for the four proxy consumers Dory has to reason about.
/// Docker's client contract cannot represent different BuildKit and default-container proxy
/// values; validation therefore rejects contradictory effective values instead of silently using
/// one for both.
public struct CorporateConnectivityProfile: Codable, Sendable, Equatable {
    public static let schema = "dev.dory.corporate-connectivity"
    public static let currentVersion = 1
    public static let defaultBridgeSubnet = "192.168.127.0/24"

    public var schema: String
    public var version: Int
    public var enabled: Bool
    public var host: CorporateProxyLayer
    public var dockerd: CorporateProxyLayer
    public var buildKit: CorporateProxyLayer
    public var containers: CorporateProxyLayer
    public var registries: CorporateRegistryConfiguration
    public var certificateAuthorities: [CorporateCAConfiguration]
    public var splitDNS: [CorporateSplitDNSRule]
    public var bridgeSubnet: String
    public var updatedAt: Date

    public init(
        enabled: Bool = false,
        host: CorporateProxyLayer = CorporateProxyLayer(source: .system),
        dockerd: CorporateProxyLayer = CorporateProxyLayer(source: .inheritHost),
        buildKit: CorporateProxyLayer = CorporateProxyLayer(source: .inheritHost),
        containers: CorporateProxyLayer = CorporateProxyLayer(source: .inheritHost),
        registries: CorporateRegistryConfiguration = CorporateRegistryConfiguration(),
        certificateAuthorities: [CorporateCAConfiguration] = [],
        splitDNS: [CorporateSplitDNSRule] = [],
        bridgeSubnet: String = Self.defaultBridgeSubnet,
        updatedAt: Date = Date()
    ) {
        self.schema = Self.schema
        self.version = Self.currentVersion
        self.enabled = enabled
        self.host = host
        self.dockerd = dockerd
        self.buildKit = buildKit
        self.containers = containers
        self.registries = registries
        self.certificateAuthorities = certificateAuthorities
        self.splitDNS = splitDNS
        self.bridgeSubnet = bridgeSubnet
        self.updatedAt = updatedAt
    }

    public static var sample: CorporateConnectivityProfile {
        CorporateConnectivityProfile(
            enabled: false,
            host: CorporateProxyLayer(source: .system),
            dockerd: CorporateProxyLayer(source: .inheritHost),
            buildKit: CorporateProxyLayer(source: .inheritHost),
            containers: CorporateProxyLayer(source: .inheritHost),
            registries: CorporateRegistryConfiguration(),
            bridgeSubnet: Self.defaultBridgeSubnet
        )
    }
}

public struct CorporateDNSResolver: Codable, Sendable, Equatable {
    public var order: Int
    public var domain: String?
    public var nameservers: [String]
    public var searchDomains: [String]
    public var interface: String?
    public var scoped: Bool
}

public struct CorporateSystemSnapshot: Codable, Sendable, Equatable {
    public static let schema = "dev.dory.corporate-connectivity.system"
    public var schema = Self.schema
    public var version = 1
    public var generatedAt: Date
    public var httpProxy: String?
    public var httpsProxy: String?
    public var pacURL: String?
    public var pacAutoDiscovery: Bool
    public var bypassDomains: [String]
    public var dnsResolvers: [CorporateDNSResolver]
    public var defaultGateway: String?
    public var defaultInterface: String?
    public var interfaces: [String]
    public var tunnelInterfaces: [String]
    public var bridgeSubnetCollisionRoutes: [String]
    public var fingerprint: String
}

public struct CorporateConnectivityMutation: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case observe
        case writeProfile = "write-profile"
        case dockerClientProxy = "docker-client-proxy"
        case guestDockerdProxy = "guest-dockerd-proxy"
        case guestRegistry = "guest-registry"
        case guestCA = "guest-ca"
        case restartDockerd = "restart-dockerd"
        case restoreOwnedState = "restore-owned-state"
    }

    public var kind: Kind
    public var target: String
    public var detail: String
    public var requiresRestart: Bool
    public var destructive: Bool

    public init(
        kind: Kind,
        target: String,
        detail: String,
        requiresRestart: Bool = false,
        destructive: Bool = false
    ) {
        self.kind = kind
        self.target = target
        self.detail = detail
        self.requiresRestart = requiresRestart
        self.destructive = destructive
    }
}

public struct CorporateConnectivityProbeEvidence: Codable, Sendable, Equatable {
    public var kind: String
    public var target: String
    public var succeeded: Bool
    public var detail: String
    public var dnsServer: String?
    public var routeInterface: String?
    public var routeGateway: String?
    public var proxy: String?
    public var caIDs: [String]
    public var queryType: String?
}

public struct CorporateConnectivityStatus: Codable, Sendable, Equatable {
    public static let schema = "dev.dory.corporate-connectivity.status"
    public var schema = Self.schema
    public var version = 1
    public var generatedAt: Date
    public var profilePath: String
    public var enabled: Bool
    public var profile: CorporateConnectivityProfile?
    public var profileDigest: String?
    public var valid: Bool
    public var validationErrors: [String]
    public var warnings: [String]
    public var system: CorporateSystemSnapshot
    public var plan: [CorporateConnectivityMutation]
    public var probes: [CorporateConnectivityProbeEvidence]
    public var dockerClientState: String
    public var guestState: String
    public var applied: Bool
    public var dockerdRestarted: Bool
}

public struct CorporateConnectivityValidation: Sendable, Equatable {
    public var errors: [String]
    public var warnings: [String]
    public var effectiveHost: CorporateProxyLayer
    public var effectiveDockerd: CorporateProxyLayer
    public var effectiveWorkload: CorporateProxyLayer

    public var valid: Bool { errors.isEmpty }
}

public enum CorporateConnectivityValidator {
    public static func validate(
        _ profile: CorporateConnectivityProfile,
        home: String,
        system: CorporateSystemSnapshot
    ) -> CorporateConnectivityValidation {
        var errors: [String] = []
        var warnings: [String] = []
        if profile.schema != CorporateConnectivityProfile.schema {
            errors.append("schema must be \(CorporateConnectivityProfile.schema)")
        }
        if profile.version != CorporateConnectivityProfile.currentVersion {
            errors.append("version \(profile.version) is unsupported")
        }

        let systemLayer = CorporateProxyLayer(
            source: .manual,
            httpProxy: system.httpProxy,
            httpsProxy: system.httpsProxy,
            noProxy: system.bypassDomains,
            pacURL: system.pacURL
        )
        let host = resolve(profile.host, inherited: systemLayer, name: "host", errors: &errors, warnings: &warnings)
        let dockerd = resolve(profile.dockerd, inherited: host, name: "dockerd", errors: &errors, warnings: &warnings)
        let build = resolve(profile.buildKit, inherited: host, name: "buildKit", errors: &errors, warnings: &warnings)
        let containers = resolve(profile.containers, inherited: host, name: "containers", errors: &errors, warnings: &warnings)

        if canonicalProxy(build) != canonicalProxy(containers) {
            errors.append("BuildKit and container proxy values differ; Docker's proxies.default contract cannot honor different values")
        }
        if profile.enabled, host.pacURL != nil, host.httpProxy == nil, host.httpsProxy == nil,
           [profile.dockerd, profile.buildKit, profile.containers].contains(where: { $0.source == .inheritHost }) {
            errors.append("the system PAC was detected but did not yield concrete proxy endpoints for non-macOS consumers")
        }

        for (name, layer) in [("host", host), ("dockerd", dockerd), ("buildKit", build), ("containers", containers)] {
            validateProxyURL(layer.httpProxy, field: "\(name).httpProxy", errors: &errors)
            validateProxyURL(layer.httpsProxy, field: "\(name).httpsProxy", errors: &errors)
            if layer.noProxy.contains(where: { $0.contains("\n") || $0.contains("\r") || $0.contains(",,") }) {
                errors.append("\(name).noProxy contains an invalid entry")
            }
        }
        for mirror in profile.registries.mirrors {
            guard let url = URL(string: mirror), url.scheme == "https", url.host != nil,
                  url.user == nil, url.password == nil else {
                errors.append("registry mirror must be a credential-free HTTPS URL: \(mirror)")
                continue
            }
        }
        for registry in profile.registries.insecureRegistries {
            if registry.contains("://") || registry.contains("/") || registry.contains(where: { $0.isWhitespace }) {
                errors.append("insecure registry must be an explicit host[:port], not a URL: \(registry)")
            }
        }

        let allowedCARoot = URL(fileURLWithPath: home)
            .appendingPathComponent(".dory/corporate-ca", isDirectory: true)
            .standardizedFileURL.path + "/"
        var caIDs = Set<String>()
        for ca in profile.certificateAuthorities {
            if ca.id.isEmpty || !ca.id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) {
                errors.append("CA id must use letters, digits, '-' or '_': \(ca.id)")
            }
            if !caIDs.insert(ca.id).inserted { errors.append("duplicate CA id: \(ca.id)") }
            let path = URL(fileURLWithPath: ca.path).standardizedFileURL.path
            if !path.hasPrefix(allowedCARoot) {
                errors.append("CA \(ca.id) must be stored under ~/.dory/corporate-ca")
            } else {
                do {
                    let digest = SHA256.hash(data: try safeCAData(path: path))
                        .map { String(format: "%02x", $0) }.joined()
                    if digest != ca.sha256.lowercased() {
                        errors.append("CA \(ca.id) digest differs from the profile")
                    }
                } catch {
                    errors.append("CA \(ca.id) is unsafe or unreadable: \(error)")
                }
            }
            if ca.scopes.isEmpty { errors.append("CA \(ca.id) has no trust scope") }
            if ca.scopes.contains(.containers) {
                warnings.append("CA \(ca.id) container scope is declarative: base images must opt into the Dory CA bundle or bake it into their own trust store")
            }
        }

        guard let bridge = IPv4CIDR(profile.bridgeSubnet) else {
            errors.append("bridgeSubnet is not a valid IPv4 CIDR")
            return CorporateConnectivityValidation(
                errors: errors,
                warnings: warnings,
                effectiveHost: host,
                effectiveDockerd: dockerd,
                effectiveWorkload: build
            )
        }
        let collisionRules = system.bridgeSubnetCollisionRoutes.filter { route in
            guard let candidate = route.split(separator: " ").first.map(String.init),
                  let cidr = IPv4CIDR(candidate) else { return false }
            return bridge.overlaps(cidr)
        }
        if !collisionRules.isEmpty {
            errors.append("bridge subnet \(profile.bridgeSubnet) collides with active route(s): \(collisionRules.joined(separator: ", "))")
        }

        for rule in profile.splitDNS {
            let normalized = rule.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
            if normalized.isEmpty || normalized.contains(where: { $0.isWhitespace }) {
                errors.append("split DNS domain is invalid: \(rule.domain)")
            }
            if rule.servers.isEmpty { errors.append("split DNS rule \(rule.domain) has no server") }
            for server in rule.servers where !isIPAddress(server) {
                errors.append("split DNS server must be a literal IP address: \(server)")
            }
        }

        return CorporateConnectivityValidation(
            errors: errors,
            warnings: warnings,
            effectiveHost: host,
            effectiveDockerd: dockerd,
            effectiveWorkload: build
        )
    }

    private static func resolve(
        _ layer: CorporateProxyLayer,
        inherited: CorporateProxyLayer,
        name: String,
        errors: inout [String],
        warnings: inout [String]
    ) -> CorporateProxyLayer {
        switch layer.source {
        case .disabled:
            return CorporateProxyLayer()
        case .inheritHost:
            return CorporateProxyLayer(
                source: .manual,
                httpProxy: inherited.httpProxy,
                httpsProxy: inherited.httpsProxy,
                noProxy: normalizedNoProxy(inherited.noProxy + layer.noProxy),
                pacURL: inherited.pacURL
            )
        case .manual:
            if layer.httpProxy == nil, layer.httpsProxy == nil, layer.pacURL == nil {
                warnings.append("\(name) is manual but has no endpoint")
            }
            return CorporateProxyLayer(
                source: .manual,
                httpProxy: layer.httpProxy,
                httpsProxy: layer.httpsProxy,
                noProxy: normalizedNoProxy(layer.noProxy),
                pacURL: layer.pacURL
            )
        case .system:
            if name != "host" {
                errors.append("\(name).source=system is ambiguous; use inherit-host or manual")
            }
            return CorporateProxyLayer(
                source: .manual,
                httpProxy: inherited.httpProxy,
                httpsProxy: inherited.httpsProxy,
                noProxy: normalizedNoProxy(inherited.noProxy + layer.noProxy),
                pacURL: inherited.pacURL
            )
        }
    }

    private static func validateProxyURL(_ raw: String?, field: String, errors: inout [String]) {
        guard let raw, !raw.isEmpty else { return }
        guard let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil,
              (url.path.isEmpty || url.path == "/"), url.query == nil, url.fragment == nil else {
            errors.append("\(field) must be a credential-free http(s) proxy origin")
            return
        }
    }

    private static func canonicalProxy(_ layer: CorporateProxyLayer) -> String {
        [layer.httpProxy ?? "", layer.httpsProxy ?? "", normalizedNoProxy(layer.noProxy).joined(separator: ",")]
            .joined(separator: "\n")
    }

    static func normalizedNoProxy(_ values: [String]) -> [String] {
        Array(Set(values.flatMap { $0.split(separator: ",").map(String.init) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty })).sorted()
    }

    static func safeCAData(path: String) throws -> Data {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw CorporateConnectivityError.unsafePath(path)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              info.st_size > 0,
              info.st_size <= 4 * 1024 * 1024,
              (info.st_mode & 0o022) == 0 else {
            try? handle.close()
            throw CorporateConnectivityError.unsafePath(path)
        }
        let data = try handle.readToEnd() ?? Data()
        try handle.close()
        guard !data.isEmpty, data.count <= 4 * 1024 * 1024 else {
            throw CorporateConnectivityError.unsafePath(path)
        }
        return data
    }

    private static func isIPAddress(_ value: String) -> Bool {
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        return value.withCString { inet_pton(AF_INET, $0, &ipv4) == 1 || inet_pton(AF_INET6, $0, &ipv6) == 1 }
    }
}

private struct IPv4CIDR {
    var network: UInt32
    var mask: UInt32

    init?(_ value: String) {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let prefix = Int(parts[1]), (0...32).contains(prefix) else { return nil }
        var addressString = String(parts[0])
        let octets = addressString.split(separator: ".", omittingEmptySubsequences: false)
        if (1...3).contains(octets.count) {
            addressString += String(repeating: ".0", count: 4 - octets.count)
        }
        var address = in_addr()
        guard addressString.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else { return nil }
        let host = UInt32(bigEndian: address.s_addr)
        let mask: UInt32 = prefix == 0 ? 0 : UInt32.max << UInt32(32 - prefix)
        self.mask = mask
        self.network = host & mask
    }

    func overlaps(_ other: IPv4CIDR) -> Bool {
        let shared = min(mask.nonzeroBitCount, other.mask.nonzeroBitCount)
        let commonMask: UInt32 = shared == 0 ? 0 : UInt32.max << UInt32(32 - shared)
        return (network & commonMask) == (other.network & commonMask)
    }
}

public final class CorporateConnectivitySystemInspector: @unchecked Sendable {
    private let runner: any HealthCommandRunning
    private let environment: [String: String]

    public init(
        runner: any HealthCommandRunning = ProcessHealthCommandRunner(),
        environment: [String: String] = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
    ) {
        self.runner = runner
        self.environment = environment
    }

    public func snapshot(bridgeSubnet: String = CorporateConnectivityProfile.defaultBridgeSubnet) -> CorporateSystemSnapshot {
        let proxy = runner.run(executablePath: "/usr/sbin/scutil", arguments: ["--proxy"], environment: environment, timeout: 3)
        let dns = runner.run(executablePath: "/usr/sbin/scutil", arguments: ["--dns"], environment: environment, timeout: 3)
        let route = runner.run(executablePath: "/sbin/route", arguments: ["-n", "get", "default"], environment: environment, timeout: 3)
        let interfaces = runner.run(executablePath: "/sbin/ifconfig", arguments: ["-l"], environment: environment, timeout: 3)
        let routes = runner.run(executablePath: "/usr/sbin/netstat", arguments: ["-rn", "-f", "inet"], environment: environment, timeout: 3)
        return Self.parse(
            proxy: proxy.stdout,
            dns: dns.stdout,
            route: route.stdout,
            interfaces: interfaces.stdout,
            routes: routes.stdout,
            bridgeSubnet: bridgeSubnet
        )
    }

    public static func parse(
        proxy: String,
        dns: String,
        route: String,
        interfaces: String,
        routes: String,
        bridgeSubnet: String
    ) -> CorporateSystemSnapshot {
        let proxyValues = parseSCUtilDictionary(proxy)
        let http = enabledProxy(proxyValues, prefix: "HTTP")
        let https = enabledProxy(proxyValues, prefix: "HTTPS")
        let pac = proxyValues["ProxyAutoConfigEnable"] == "1" ? proxyValues["ProxyAutoConfigURLString"] : nil
        let bypass = proxyValues
            .filter { $0.key.hasPrefix("ExceptionsList") }
            .map(\.value)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) }
            .filter { !$0.isEmpty }
        let parsedResolvers = parseDNSResolvers(dns)
        let defaultGateway = lineValue("gateway", in: route)
        let defaultInterface = lineValue("interface", in: route)
        let interfaceNames = interfaces.split(whereSeparator: \.isWhitespace).map(String.init).sorted()
        let tunnels = interfaceNames.filter { $0.hasPrefix("utun") || $0.hasPrefix("ppp") || $0.hasPrefix("ipsec") || $0.hasPrefix("tailscale") }
        let routeLines = activeCIDRRoutes(routes)
        let rawFingerprint = [
            http ?? "", https ?? "", pac ?? "", bypass.sorted().joined(separator: ","),
            parsedResolvers.description, defaultGateway ?? "", defaultInterface ?? "",
            interfaceNames.joined(separator: ","), routeLines.joined(separator: "\n"), bridgeSubnet,
        ].joined(separator: "\n")
        let fingerprint = SHA256.hash(data: Data(rawFingerprint.utf8)).map { String(format: "%02x", $0) }.joined()
        return CorporateSystemSnapshot(
            generatedAt: Date(),
            httpProxy: http,
            httpsProxy: https,
            pacURL: pac,
            pacAutoDiscovery: proxyValues["ProxyAutoDiscoveryEnable"] == "1",
            bypassDomains: CorporateConnectivityValidator.normalizedNoProxy(bypass),
            dnsResolvers: parsedResolvers,
            defaultGateway: defaultGateway,
            defaultInterface: defaultInterface,
            interfaces: interfaceNames,
            tunnelInterfaces: tunnels,
            bridgeSubnetCollisionRoutes: routeLines,
            fingerprint: fingerprint
        )
    }

    private static func enabledProxy(_ values: [String: String], prefix: String) -> String? {
        guard values["\(prefix)Enable"] == "1", let host = values["\(prefix)Proxy"], !host.isEmpty else { return nil }
        let port = values["\(prefix)Port"].flatMap(Int.init)
        let scheme = prefix.lowercased()
        return "\(scheme)://\(host)" + (port.map { ":\($0)" } ?? "")
    }

    private static func parseSCUtilDictionary(_ output: String) -> [String: String] {
        var values: [String: String] = [:]
        var arrayKey: String?
        for rawLine in output.split(separator: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "}" { arrayKey = nil; continue }
            let line = String(rawLine)
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("<array>") {
                arrayKey = key
            } else if let arrayKey,
                      Int(key.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))) != nil {
                let index = key.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                values["\(arrayKey).\(index)"] = value
            } else {
                values[key] = value
            }
        }
        return values
    }

    private static func parseDNSResolvers(_ output: String) -> [CorporateDNSResolver] {
        var result: [CorporateDNSResolver] = []
        var current: [String: [String]] = [:]
        func finish() {
            guard !current.isEmpty else { return }
            let flags = current["flags"]?.joined(separator: " ") ?? ""
            result.append(CorporateDNSResolver(
                order: Int(current["order"]?.first ?? "") ?? result.count,
                domain: current["domain"]?.first,
                nameservers: current["nameserver" ] ?? [],
                searchDomains: current["search domain"] ?? [],
                interface: current["if_index"]?.first?.split(separator: " ").last
                    .map(String.init)?
                    .trimmingCharacters(in: CharacterSet(charactersIn: "()")),
                scoped: flags.localizedCaseInsensitiveContains("Scoped")
            ))
            current = [:]
        }
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("resolver #") { finish(); continue }
            guard let separator = line.firstIndex(of: ":") else { continue }
            var key = String(line[..<separator]).trimmingCharacters(in: .whitespaces).lowercased()
            key = key.replacingOccurrences(of: #"\[[0-9]+\]"#, with: "", options: .regularExpression)
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { current[key, default: []].append(value) }
        }
        finish()
        return result.sorted { $0.order < $1.order }
    }

    private static func lineValue(_ name: String, in output: String) -> String? {
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == name else { continue }
            return parts[1].trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static func activeCIDRRoutes(_ output: String) -> [String] {
        output.split(separator: "\n").compactMap { raw -> String? in
            let fields = raw.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 4, fields[0].contains("/"), IPv4CIDR(fields[0]) != nil else { return nil }
            return "\(fields[0]) via \(fields[1]) dev \(fields.last ?? "unknown")"
        }.sorted()
    }
}

public struct CorporateConnectivityStore: Sendable {
    private struct OwnershipState: Codable {
        var schema = "dev.dory.corporate-connectivity.ownership"
        var version = 1
        var hadPreviousDefault: Bool
        var previousDefaultJSON: String?
        var appliedDefaultDigest: String?
        var appliedProfileDigest: String
        var updatedAt: Date
    }

    public let home: String
    public let profilePath: String
    public let ownershipPath: String
    public let dockerConfigPath: String

    public init(home: String = NSHomeDirectory()) {
        self.home = URL(fileURLWithPath: home).standardizedFileURL.path
        self.profilePath = self.home + "/.dory/corporate-connectivity.json"
        self.ownershipPath = self.home + "/.dory/corporate-connectivity-state.json"
        self.dockerConfigPath = self.home + "/.docker/config.json"
    }

    public func load() throws -> CorporateConnectivityProfile? {
        guard FileManager.default.fileExists(atPath: profilePath) else { return nil }
        let data = try readSafeRegularFile(profilePath, maximumBytes: 1024 * 1024)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CorporateConnectivityProfile.self, from: data)
    }

    public func save(_ profile: CorporateConnectivityProfile) throws {
        let directory = URL(fileURLWithPath: profilePath).deletingLastPathComponent().path
        try ensurePrivateDirectory(directory)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try writePrivate(try encoder.encode(profile), to: profilePath)
    }

    public func removeProfile() throws {
        guard FileManager.default.fileExists(atPath: profilePath) else { return }
        let data = try readSafeRegularFile(profilePath, maximumBytes: 1024 * 1024)
        _ = data
        try FileManager.default.removeItem(atPath: profilePath)
    }

    public func profileDigest(_ profile: CorporateConnectivityProfile) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(profile)).map { String(format: "%02x", $0) }.joined()
    }

    /// Updates only proxies.default and records the exact prior value. Disable restores it only
    /// while the current value still equals Dory's applied digest, protecting edits made later by
    /// the user or another tool.
    public func reconcileDockerClientProxy(
        _ proxy: CorporateProxyLayer?,
        profileDigest: String
    ) throws -> String {
        let configURL = URL(fileURLWithPath: dockerConfigPath)
        try ensurePrivateDirectory(configURL.deletingLastPathComponent().path)
        var root: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: dockerConfigPath) {
            let data = try readSafeRegularFile(dockerConfigPath, maximumBytes: 4 * 1024 * 1024)
            guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CorporateConnectivityError.unavailable("~/.docker/config.json is not a JSON object")
            }
            root = decoded
        }
        var proxies = root["proxies"] as? [String: Any] ?? [:]
        let previous = proxies["default"]
        let ownership = try loadOwnership()

        guard let proxy, proxy.isConfigured else {
            guard let ownership else { return "no Dory-owned Docker client proxy to restore" }
            let currentDigest = previous.flatMap(jsonDigest)
            guard currentDigest == ownership.appliedDefaultDigest else {
                throw CorporateConnectivityError.ownershipConflict(
                    "~/.docker/config.json proxies.default changed after Dory applied it; leaving it untouched"
                )
            }
            if ownership.hadPreviousDefault, let prior = ownership.previousDefaultJSON,
               let priorData = prior.data(using: .utf8) {
                proxies["default"] = try JSONSerialization.jsonObject(with: priorData)
            } else {
                proxies.removeValue(forKey: "default")
            }
            if proxies.isEmpty { root.removeValue(forKey: "proxies") } else { root["proxies"] = proxies }
            try writeDockerConfig(root)
            try? FileManager.default.removeItem(atPath: ownershipPath)
            return "restored the exact pre-Dory proxies.default value"
        }

        var desired: [String: Any] = [:]
        if let value = proxy.httpProxy { desired["httpProxy"] = value }
        if let value = proxy.httpsProxy { desired["httpsProxy"] = value }
        let noProxy = CorporateConnectivityValidator.normalizedNoProxy(proxy.noProxy)
        if !noProxy.isEmpty { desired["noProxy"] = noProxy.joined(separator: ",") }
        let desiredDigest = jsonDigest(desired)
        if let ownership, ownership.appliedDefaultDigest != previous.flatMap(jsonDigest) {
            throw CorporateConnectivityError.ownershipConflict(
                "~/.docker/config.json proxies.default changed after Dory applied it; re-import the profile after reviewing that edit"
            )
        }
        if ownership == nil {
            let previousJSON = previous.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
                .flatMap { String(data: $0, encoding: .utf8) }
            try saveOwnership(OwnershipState(
                hadPreviousDefault: previous != nil,
                previousDefaultJSON: previousJSON,
                appliedDefaultDigest: desiredDigest,
                appliedProfileDigest: profileDigest,
                updatedAt: Date()
            ))
        } else if var updated = ownership {
            updated.appliedDefaultDigest = desiredDigest
            updated.appliedProfileDigest = profileDigest
            updated.updatedAt = Date()
            try saveOwnership(updated)
        }
        proxies["default"] = desired
        root["proxies"] = proxies
        try writeDockerConfig(root)
        return previous.flatMap(jsonDigest) == desiredDigest
            ? "Docker client proxies.default already matched the profile"
            : "updated only Docker client proxies.default; preserved every unrelated key"
    }

    private func writeDockerConfig(_ root: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try writePrivate(data + Data("\n".utf8), to: dockerConfigPath)
    }

    private func loadOwnership() throws -> OwnershipState? {
        guard FileManager.default.fileExists(atPath: ownershipPath) else { return nil }
        let data = try readSafeRegularFile(ownershipPath, maximumBytes: 1024 * 1024)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(OwnershipState.self, from: data)
    }

    private func saveOwnership(_ state: OwnershipState) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writePrivate(try encoder.encode(state), to: ownershipPath)
    }

    private func jsonDigest(_ object: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func ensurePrivateDirectory(_ path: String) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: path) {
            var info = stat()
            guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
                  info.st_uid == getuid() else { throw CorporateConnectivityError.unsafePath(path) }
        } else {
            try fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        guard chmod(path, 0o700) == 0 else { throw CorporateConnectivityError.unavailable("could not secure \(path): \(String(cString: strerror(errno)))") }
    }

    private func readSafeRegularFile(_ path: String, maximumBytes: Int) throws -> Data {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_size >= 0, info.st_size <= maximumBytes else {
            throw CorporateConnectivityError.unsafePath(path)
        }
        return try Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe])
    }

    private func writePrivate(_ data: Data, to path: String) throws {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        try ensurePrivateDirectory(directory)
        var existing = stat()
        if lstat(path, &existing) == 0 {
            guard (existing.st_mode & S_IFMT) == S_IFREG, existing.st_uid == getuid() else {
                throw CorporateConnectivityError.unsafePath(path)
            }
        } else if errno != ENOENT {
            throw CorporateConnectivityError.unavailable(
                "could not inspect \(path): \(String(cString: strerror(errno)))"
            )
        }
        let temporary = path + ".tmp-\(getpid())-\(UUID().uuidString)"
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CorporateConnectivityError.unavailable("could not create \(temporary): \(String(cString: strerror(errno)))") }
        defer { close(fd); unlink(temporary) }
        let writeOK = data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return data.isEmpty }
            var offset = 0
            while offset < data.count {
                let count = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
                if count <= 0 { return false }
                offset += count
            }
            return true
        }
        guard writeOK, fsync(fd) == 0, fchmod(fd, 0o600) == 0 else {
            throw CorporateConnectivityError.unavailable("could not publish \(path): \(String(cString: strerror(errno)))")
        }
        guard rename(temporary, path) == 0 else {
            throw CorporateConnectivityError.unavailable("could not atomically replace \(path): \(String(cString: strerror(errno)))")
        }
    }
}

public struct CorporateGuestApplyResult: Sendable, Equatable {
    public var state: String
    public var changed: Bool
    public var dockerdRestarted: Bool

    public init(state: String, changed: Bool, dockerdRestarted: Bool) {
        self.state = state
        self.changed = changed
        self.dockerdRestarted = dockerdRestarted
    }
}

public typealias CorporateGuestApply = @Sendable (
    _ profile: CorporateConnectivityProfile,
    _ validation: CorporateConnectivityValidation,
    _ profileDigest: String
) throws -> CorporateGuestApplyResult

public protocol WakeNetworkReconciling: Sendable {
    func reconcileAfterWake(now: Date) -> String
}

public final class CorporateConnectivityProber: @unchecked Sendable {
    private let runner: any HealthCommandRunning
    private let environment: [String: String]

    public init(
        runner: any HealthCommandRunning = ProcessHealthCommandRunner(),
        environment: [String: String] = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
    ) {
        self.runner = runner
        self.environment = environment
    }

    public func probe(
        profile: CorporateConnectivityProfile,
        validation: CorporateConnectivityValidation,
        system: CorporateSystemSnapshot
    ) -> [CorporateConnectivityProbeEvidence] {
        guard profile.enabled, validation.valid else { return [] }
        var evidence = splitDNSProbes(profile.splitDNS)
        evidence.append(contentsOf: registryProbes(
            profile.registries.probeRegistries,
            proxy: validation.effectiveHost,
            certificateAuthorities: profile.certificateAuthorities.filter { $0.scopes.contains(.hostProbe) },
            system: system
        ))
        return evidence
    }

    private func splitDNSProbes(_ rules: [CorporateSplitDNSRule]) -> [CorporateConnectivityProbeEvidence] {
        var result: [CorporateConnectivityProbeEvidence] = []
        for rule in rules {
            let names = rule.probeNames.isEmpty ? [rule.domain] : rule.probeNames
            for server in rule.servers {
                let route = routeEvidence(to: server)
                if rule.requireSOA {
                    result.append(digEvidence(
                        server: server,
                        name: rule.domain,
                        type: "SOA",
                        route: route
                    ))
                }
                for name in names {
                    let cname = rule.followCNAME ? digEvidence(server: server, name: name, type: "CNAME", route: route) : nil
                    if let cname { result.append(cname) }
                    result.append(digEvidence(server: server, name: name, type: "A", route: route))
                    result.append(digEvidence(server: server, name: name, type: "AAAA", route: route))
                }
            }
        }
        return result
    }

    private func digEvidence(
        server: String,
        name: String,
        type: String,
        route: (interface: String?, gateway: String?)
    ) -> CorporateConnectivityProbeEvidence {
        let output = runner.run(
            executablePath: "/usr/bin/dig",
            arguments: ["+time=2", "+tries=1", "+short", "@\(server)", name, type],
            environment: environment,
            timeout: 4
        )
        let answer = output.stdout.split(separator: "\n").map(String.init)
        // An empty CNAME is a valid terminal name. A/AAAA and SOA require an answer.
        let succeeded = output.exitCode == 0 && (type == "CNAME" || !answer.isEmpty)
        let detail: String
        if succeeded {
            detail = answer.isEmpty ? "terminal name (no CNAME)" : answer.prefix(8).joined(separator: ", ")
        } else {
            detail = compact(output.stderr.isEmpty ? "no answer" : output.stderr)
        }
        return CorporateConnectivityProbeEvidence(
            kind: "split-dns",
            target: name,
            succeeded: succeeded,
            detail: detail,
            dnsServer: server,
            routeInterface: route.interface,
            routeGateway: route.gateway,
            proxy: nil,
            caIDs: [],
            queryType: type
        )
    }

    private func registryProbes(
        _ targets: [String],
        proxy: CorporateProxyLayer,
        certificateAuthorities: [CorporateCAConfiguration],
        system: CorporateSystemSnapshot
    ) -> [CorporateConnectivityProbeEvidence] {
        let caIDs = certificateAuthorities.map(\.id)
        let caBundle: Result<String?, Error>
        do {
            caBundle = .success(try temporaryCABundle(certificateAuthorities))
        } catch {
            caBundle = .failure(error)
        }
        defer {
            if case let .success(path?) = caBundle { try? FileManager.default.removeItem(atPath: path) }
        }
        return targets.map { raw in
            if case let .failure(error) = caBundle {
                return CorporateConnectivityProbeEvidence(
                    kind: "registry", target: raw, succeeded: false,
                    detail: "could not construct the declared CA bundle: \(error)",
                    dnsServer: nil, routeInterface: nil, routeGateway: nil, proxy: nil,
                    caIDs: caIDs, queryType: nil
                )
            }
            guard let url = URL(string: raw), let host = url.host else {
                return CorporateConnectivityProbeEvidence(
                    kind: "registry", target: raw, succeeded: false, detail: "invalid probe URL",
                    dnsServer: nil, routeInterface: nil, routeGateway: nil, proxy: nil, caIDs: caIDs, queryType: nil
                )
            }
            let selectedProxy = (url.scheme?.lowercased() == "https" ? proxy.httpsProxy : proxy.httpProxy)
                ?? proxy.httpProxy
            if selectedProxy == nil, proxy.pacURL != nil {
                return CorporateConnectivityProbeEvidence(
                    kind: "registry",
                    target: raw,
                    succeeded: false,
                    detail: "a PAC is active, but no concrete URL-specific proxy was resolved; configure a manual host probe proxy before treating this probe as evidence",
                    dnsServer: nil,
                    routeInterface: nil,
                    routeGateway: nil,
                    proxy: nil,
                    caIDs: caIDs,
                    queryType: nil
                )
            }
            let routeHost: String
            if let selectedProxy, let proxyURL = URL(string: selectedProxy), let proxyHost = proxyURL.host {
                routeHost = proxyHost
            } else {
                routeHost = host
            }
            let resolver = resolverFor(host: routeHost, system: system)
            let resolved = resolve(host: routeHost, server: resolver)
            let route = resolved.address.map(routeEvidence(to:)) ?? (interface: nil, gateway: nil)

            var arguments = [
                "--silent", "--show-error", "--output", "/dev/null",
                "--connect-timeout", "4", "--max-time", "10",
                "--write-out", "%{http_code} %{remote_ip} %{proxy_used}",
            ]
            if let selectedProxy { arguments += ["--proxy", selectedProxy] }
            if case let .success(caPath?) = caBundle { arguments += ["--cacert", caPath] }
            if selectedProxy == nil, let address = resolved.address {
                arguments += ["--resolve", "\(host):\(url.port ?? 443):\(address)"]
            }
            arguments.append(raw)
            let output = runner.run(executablePath: "/usr/bin/curl", arguments: arguments, environment: environment, timeout: 12)
            let fields = output.stdout.split(whereSeparator: \.isWhitespace).map(String.init)
            let code = fields.first.flatMap(Int.init) ?? 0
            let succeeded = output.exitCode == 0 && (200...499).contains(code)
            let detail = succeeded
                ? "HTTP \(code), remote \(fields.count > 1 ? fields[1] : (resolved.address ?? "unknown"))"
                : compact(output.stderr.isEmpty ? "curl exit \(output.exitCode), HTTP \(code)" : output.stderr)
            return CorporateConnectivityProbeEvidence(
                kind: "registry",
                target: raw,
                succeeded: succeeded,
                detail: detail,
                dnsServer: resolver,
                routeInterface: route.interface,
                routeGateway: route.gateway,
                proxy: selectedProxy,
                caIDs: caIDs,
                queryType: "A/AAAA"
            )
        }
    }

    private func temporaryCABundle(_ authorities: [CorporateCAConfiguration]) throws -> String? {
        guard !authorities.isEmpty else { return nil }
        var bundle = Data()
        if let system = try? Data(contentsOf: URL(fileURLWithPath: "/etc/ssl/cert.pem")) {
            bundle.append(system)
            if bundle.last != 0x0A { bundle.append(0x0A) }
        }
        for authority in authorities {
            let data = try CorporateConnectivityValidator.safeCAData(path: authority.path)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == authority.sha256.lowercased() else {
                throw CorporateConnectivityError.unavailable("CA \(authority.id) changed after validation")
            }
            bundle.append(data)
            if bundle.last != 0x0A { bundle.append(0x0A) }
        }
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("dory-corporate-ca-\(UUID().uuidString).pem").path
        try bundle.write(to: URL(fileURLWithPath: path), options: [.atomic])
        guard chmod(path, 0o600) == 0 else {
            try? FileManager.default.removeItem(atPath: path)
            throw CorporateConnectivityError.unavailable("could not secure temporary CA bundle")
        }
        return path
    }

    private func resolverFor(host: String, system: CorporateSystemSnapshot) -> String? {
        let normalized = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let matching = system.dnsResolvers.filter { resolver in
            guard let domain = resolver.domain?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) else {
                return false
            }
            return normalized == domain || normalized.hasSuffix("." + domain)
        }.sorted { ($0.domain?.count ?? 0) > ($1.domain?.count ?? 0) }
        return matching.first?.nameservers.first
            ?? system.dnsResolvers.sorted { $0.order < $1.order }.compactMap(\.nameservers.first).first
    }

    private func resolve(host: String, server: String?) -> (address: String?, detail: String) {
        guard let server else { return (nil, "no active DNS server") }
        for type in ["A", "AAAA"] {
            let output = runner.run(
                executablePath: "/usr/bin/dig",
                arguments: ["+time=2", "+tries=1", "+short", "@\(server)", host, type],
                environment: environment,
                timeout: 4
            )
            if output.exitCode == 0,
               let address = output.stdout.split(separator: "\n").map(String.init).first(where: Self.isIPAddress) {
                return (address, "resolved by \(server)")
            }
        }
        return (nil, "no address from \(server)")
    }

    private func routeEvidence(to address: String) -> (interface: String?, gateway: String?) {
        let output = runner.run(
            executablePath: "/sbin/route",
            arguments: ["-n", "get", address],
            environment: environment,
            timeout: 3
        )
        return (
            lineValue("interface", output.stdout),
            lineValue("gateway", output.stdout)
        )
    }

    private func lineValue(_ name: String, _ output: String) -> String? {
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == name {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private func compact(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(500).description
    }

    private static func isIPAddress(_ value: String) -> Bool {
        var ipv4 = in_addr(); var ipv6 = in6_addr()
        return value.withCString { inet_pton(AF_INET, $0, &ipv4) == 1 || inet_pton(AF_INET6, $0, &ipv6) == 1 }
    }
}

public final class CorporateConnectivityReconciler: WakeNetworkReconciling, @unchecked Sendable {
    private let store: CorporateConnectivityStore
    private let inspector: CorporateConnectivitySystemInspector
    private let prober: CorporateConnectivityProber
    private let guestApply: CorporateGuestApply?
    private let incidentWriter: IncidentWriter?
    private let interval: TimeInterval
    private let queue = DispatchQueue(label: "dev.dory.corporate-connectivity")
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var lastFingerprint: String?
    private var lastProfileDigest: String?
    private var lastStatus: CorporateConnectivityStatus?

    public init(
        home: String = NSHomeDirectory(),
        inspector: CorporateConnectivitySystemInspector = CorporateConnectivitySystemInspector(),
        prober: CorporateConnectivityProber = CorporateConnectivityProber(),
        guestApply: CorporateGuestApply? = nil,
        incidentWriter: IncidentWriter? = nil,
        interval: TimeInterval = 10
    ) {
        self.store = CorporateConnectivityStore(home: home)
        self.inspector = inspector
        self.prober = prober
        self.guestApply = guestApply
        self.incidentWriter = incidentWriter
        self.interval = max(2, interval)
    }

    public func start() {
        lock.lock()
        guard timer == nil else { lock.unlock(); return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(1))
        source.setEventHandler { [weak self] in self?.reconcileIfSystemChanged() }
        timer = source
        lock.unlock()
        source.resume()
    }

    public func stop() {
        lock.lock()
        let current = timer
        timer = nil
        lock.unlock()
        current?.cancel()
    }

    public func currentStatus(runProbes: Bool = true) -> CorporateConnectivityStatus {
        do {
            guard let profile = try store.load() else {
                let system = inspector.snapshot()
                return emptyStatus(system: system)
            }
            return status(profile: profile, apply: false, persist: false, runProbes: runProbes)
        } catch {
            let system = inspector.snapshot()
            var result = emptyStatus(system: system)
            result.validationErrors = ["\(error)"]
            result.valid = false
            return result
        }
    }

    public func plan(_ profile: CorporateConnectivityProfile, runProbes: Bool = false) -> CorporateConnectivityStatus {
        status(profile: profile, apply: false, persist: false, runProbes: runProbes)
    }

    public func apply(_ profile: CorporateConnectivityProfile, runProbes: Bool = true) -> CorporateConnectivityStatus {
        status(profile: profile, apply: true, persist: true, runProbes: runProbes)
    }

    public func disable() -> CorporateConnectivityStatus {
        do {
            var profile = try store.load() ?? .sample
            profile.enabled = false
            profile.updatedAt = Date()
            return apply(profile, runProbes: false)
        } catch {
            var result = emptyStatus(system: inspector.snapshot())
            result.valid = false
            result.validationErrors = ["\(error)"]
            return result
        }
    }

    @discardableResult
    public func reconcileCurrent(runProbes: Bool = false) -> CorporateConnectivityStatus {
        do {
            guard let profile = try store.load() else {
                let status = emptyStatus(system: inspector.snapshot())
                remember(status)
                return status
            }
            return status(profile: profile, apply: true, persist: false, runProbes: runProbes)
        } catch {
            var status = emptyStatus(system: inspector.snapshot())
            status.valid = false
            status.validationErrors = ["\(error)"]
            remember(status)
            incidentWriter?.record(type: "network.corporate_reconcile_failed", detail: "\(error)")
            return status
        }
    }

    public func reconcileAfterWake(now _: Date) -> String {
        let result = reconcileCurrent(runProbes: true)
        return result.valid
            ? "corporate connectivity reconciled; \(result.probes.filter(\.succeeded).count)/\(result.probes.count) probes passed"
            : "corporate connectivity blocked: \(result.validationErrors.joined(separator: "; "))"
    }

    public func cachedStatus() -> CorporateConnectivityStatus? {
        lock.lock(); defer { lock.unlock() }
        return lastStatus
    }

    private func status(
        profile: CorporateConnectivityProfile,
        apply: Bool,
        persist: Bool,
        runProbes: Bool
    ) -> CorporateConnectivityStatus {
        let system = inspector.snapshot(bridgeSubnet: profile.bridgeSubnet)
        let validation = CorporateConnectivityValidator.validate(profile, home: store.home, system: system)
        let digest = try? store.profileDigest(profile)
        let plan = mutationPlan(profile: profile, validation: validation)
        var dockerState = "not applied"
        var guestState = "not applied"
        var restarted = false
        var errors = validation.errors
        var warnings = validation.warnings
        var didApply = false

        if apply, validation.valid, let digest {
            let priorProfile = persist ? (try? store.load()) : nil
            do {
                let workload = profile.enabled ? validation.effectiveWorkload : nil
                dockerState = try store.reconcileDockerClientProxy(workload, profileDigest: digest)
                if let guestApply {
                    let guest = try guestApply(profile, validation, digest)
                    guestState = guest.state
                    restarted = guest.dockerdRestarted
                } else {
                    guestState = profile.enabled ? "guest agent unavailable; settings will apply on the next managed-engine reconcile" : "no managed guest"
                }
                // Publish the profile only after both mutable consumers accepted it. This keeps
                // the persisted intent aligned with the effective client/guest state.
                if persist { try store.save(profile) }
                didApply = true
                incidentWriter?.record(
                    type: "network.corporate_reconciled",
                    detail: "profile=\(digest.prefix(12)) system=\(system.fingerprint.prefix(12)) restarted=\(restarted)"
                )
            } catch {
                errors.append("\(error)")
                if persist {
                    let rollbackProfile: CorporateConnectivityProfile = {
                        if let priorProfile { return priorProfile }
                        var disabled = profile
                        disabled.enabled = false
                        return disabled
                    }()
                    let rollbackValidation = CorporateConnectivityValidator.validate(
                        rollbackProfile,
                        home: store.home,
                        system: system
                    )
                    if rollbackValidation.valid, let rollbackDigest = try? store.profileDigest(rollbackProfile) {
                        var rollbackFailures: [String] = []
                        if let guestApply {
                            do {
                                _ = try guestApply(rollbackProfile, rollbackValidation, rollbackDigest)
                            } catch {
                                rollbackFailures.append("guest: \(error)")
                            }
                        }
                        do {
                            let priorWorkload = rollbackProfile.enabled ? rollbackValidation.effectiveWorkload : nil
                            _ = try store.reconcileDockerClientProxy(priorWorkload, profileDigest: rollbackDigest)
                        } catch {
                            rollbackFailures.append("Docker client: \(error)")
                        }
                        if let priorProfile {
                            do { try store.save(priorProfile) } catch { rollbackFailures.append("profile: \(error)") }
                        } else {
                            do { try store.removeProfile() } catch { rollbackFailures.append("profile: \(error)") }
                        }
                        if rollbackFailures.isEmpty {
                            warnings.append("the failed corporate-connectivity apply was rolled back to the prior effective state")
                        } else {
                            errors.append("corporate-connectivity rollback was incomplete: \(rollbackFailures.joined(separator: "; "))")
                        }
                    } else {
                        errors.append("corporate-connectivity rollback could not validate the prior profile")
                    }
                }
                incidentWriter?.record(type: "network.corporate_reconcile_failed", detail: "\(error)")
            }
        }
        if !profile.enabled {
            warnings.append("corporate connectivity profile is disabled")
        }
        let probes = runProbes && errors.isEmpty
            ? prober.probe(profile: profile, validation: validation, system: system)
            : []
        let failedProbes = probes.filter { !$0.succeeded && !($0.queryType == "CNAME" && $0.detail.contains("terminal")) }
        if !failedProbes.isEmpty {
            warnings.append("\(failedProbes.count) corporate connectivity probe(s) failed; inspect probes for exact DNS, route, proxy and CA provenance")
        }
        let result = CorporateConnectivityStatus(
            generatedAt: Date(),
            profilePath: store.profilePath,
            enabled: profile.enabled,
            profile: profile,
            profileDigest: digest,
            valid: errors.isEmpty,
            validationErrors: errors,
            warnings: Array(Set(warnings)).sorted(),
            system: system,
            plan: plan,
            probes: probes,
            dockerClientState: dockerState,
            guestState: guestState,
            applied: didApply,
            dockerdRestarted: restarted
        )
        remember(result)
        return result
    }

    private func mutationPlan(
        profile: CorporateConnectivityProfile,
        validation: CorporateConnectivityValidation
    ) -> [CorporateConnectivityMutation] {
        var plan = [CorporateConnectivityMutation(
            kind: .observe,
            target: "macOS dynamic store",
            detail: "observe system/PAC proxy, resolver order, scoped interfaces and routes; never rewrite macOS network settings"
        )]
        if profile.enabled {
            plan.append(CorporateConnectivityMutation(
                kind: .writeProfile,
                target: store.profilePath,
                detail: "atomically publish schema-v1 profile with owner-only permissions"
            ))
            plan.append(CorporateConnectivityMutation(
                kind: .dockerClientProxy,
                target: store.dockerConfigPath + "#proxies.default",
                detail: "apply the validated shared BuildKit/container proxy and preserve unrelated Docker config"
            ))
            if validation.effectiveDockerd.isConfigured {
                plan.append(CorporateConnectivityMutation(
                    kind: .guestDockerdProxy,
                    target: "/var/lib/docker/.dory-corporate/dockerd.env",
                    detail: "apply pull proxy and NO_PROXY without putting credentials in arguments or logs",
                    requiresRestart: true
                ))
            }
            if !profile.registries.mirrors.isEmpty || !profile.registries.insecureRegistries.isEmpty {
                plan.append(CorporateConnectivityMutation(
                    kind: .guestRegistry,
                    target: "/var/lib/docker/.dory-corporate/dockerd.args",
                    detail: "apply explicit registry mirrors/insecure registries",
                    requiresRestart: true
                ))
            }
            if !profile.certificateAuthorities.isEmpty {
                plan.append(CorporateConnectivityMutation(
                    kind: .guestCA,
                    target: "/usr/local/share/ca-certificates/dory-corporate-*",
                    detail: "install only digest-pinned CAs in their declared guest scopes",
                    requiresRestart: true
                ))
            }
            if plan.contains(where: \.requiresRestart) {
                plan.append(CorporateConnectivityMutation(
                    kind: .restartDockerd,
                    target: "managed guest dockerd",
                    detail: "restart dockerd only when the effective guest digest changed; retain VM/data disk and use live-restore",
                    requiresRestart: true
                ))
            }
        } else {
            plan.append(CorporateConnectivityMutation(
                kind: .restoreOwnedState,
                target: "Docker client and managed guest",
                detail: "restore only state whose current digest still matches Dory's ownership record"
            ))
        }
        return plan
    }

    private func reconcileIfSystemChanged() {
        do {
            guard let profile = try store.load() else { return }
            let snapshot = inspector.snapshot(bridgeSubnet: profile.bridgeSubnet)
            let digest = try store.profileDigest(profile)
            lock.lock()
            let changed = lastFingerprint != snapshot.fingerprint || lastProfileDigest != digest
            lock.unlock()
            if changed { _ = reconcileCurrent(runProbes: false) }
        } catch {
            incidentWriter?.record(type: "network.corporate_monitor_failed", detail: "\(error)")
        }
    }

    private func remember(_ status: CorporateConnectivityStatus) {
        lock.lock()
        lastFingerprint = status.system.fingerprint
        lastProfileDigest = status.profileDigest
        lastStatus = status
        lock.unlock()
    }

    private func emptyStatus(system: CorporateSystemSnapshot) -> CorporateConnectivityStatus {
        CorporateConnectivityStatus(
            generatedAt: Date(),
            profilePath: store.profilePath,
            enabled: false,
            profile: nil,
            profileDigest: nil,
            valid: true,
            validationErrors: [],
            warnings: ["no corporate connectivity profile is configured"],
            system: system,
            plan: [CorporateConnectivityMutation(
                kind: .observe,
                target: "macOS dynamic store",
                detail: "system/PAC proxy, scoped DNS and routes are observed without mutation"
            )],
            probes: [],
            dockerClientState: "unmanaged",
            guestState: "unmanaged",
            applied: false,
            dockerdRestarted: false
        )
    }
}
