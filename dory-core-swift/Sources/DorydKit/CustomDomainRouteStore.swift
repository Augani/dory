import Darwin
import Foundation

public struct CustomDomainRouteConfiguration: Codable, Equatable, Sendable {
    public var hostname: String
    public var publishedPort: UInt16

    public init(hostname: String, publishedPort: UInt16) {
        self.hostname = hostname
        self.publishedPort = publishedPort
    }

    public var xpcDictionary: NSDictionary {
        [
            "hostname": hostname,
            "address": "127.0.0.1",
            "port": publishedPort,
        ] as NSDictionary
    }
}

public final class CustomDomainRouteStore: @unchecked Sendable {
    public enum StoreError: Error, CustomStringConvertible {
        case invalidRoute(String)
        case tooManyRoutes
        case unsafePath(String)
        case unreadable(String)
        case writeFailed(String)

        public var description: String {
            switch self {
            case let .invalidRoute(detail): "invalid custom domain route: \(detail)"
            case .tooManyRoutes: "custom domain routes are limited to 128 entries"
            case let .unsafePath(path): "custom domain route path is unsafe: \(path)"
            case let .unreadable(detail): "custom domain routes could not be read: \(detail)"
            case let .writeFailed(detail): "custom domain routes could not be saved: \(detail)"
            }
        }
    }

    private struct Document: Codable {
        var schema = "dev.dory.custom-domains"
        var version = 1
        var routes: [CustomDomainRouteConfiguration]
    }

    private static let maximumRoutes = 128
    private static let maximumBytes = 256 * 1024
    private let lock = NSLock()
    public let path: String

    public init(
        home: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        path = ((environment["DORY_CUSTOM_DOMAIN_ROUTES"] ?? "\(home)/.dory/custom-domains.json") as NSString)
            .expandingTildeInPath
    }

    public func configuredRoutes() throws -> [CustomDomainRouteConfiguration] {
        lock.lock()
        defer { lock.unlock() }
        return try loadLocked()
    }

    @discardableResult
    public func replace(
        _ routes: [DomainRoute],
        automaticSuffix: String
    ) throws -> [CustomDomainRouteConfiguration] {
        guard routes.count <= Self.maximumRoutes else { throw StoreError.tooManyRoutes }
        let normalizedSuffix = DomainRouter.normalize(automaticSuffix)
        var unique: [String: CustomDomainRouteConfiguration] = [:]
        for route in routes {
            guard route.address == "127.0.0.1" else {
                throw StoreError.invalidRoute("targets must use Dory's loopback-published ports")
            }
            guard route.pathPrefix.isEmpty else {
                throw StoreError.invalidRoute("path prefixes are not supported for custom domains")
            }
            let hostname = DomainRouter.normalize(route.hostname)
            guard DomainRouter.isValidHostnamePattern(hostname) else {
                throw StoreError.invalidRoute("\(route.hostname) is not a DNS hostname or leftmost wildcard")
            }
            let comparable = hostname.hasPrefix("*.") ? String(hostname.dropFirst(2)) : hostname
            guard comparable != normalizedSuffix, !comparable.hasSuffix(".\(normalizedSuffix)") else {
                throw StoreError.invalidRoute("\(hostname) is already owned by Dory's automatic domain suffix")
            }
            guard route.port > 0 else {
                throw StoreError.invalidRoute("published port must be between 1 and 65535")
            }
            guard unique[hostname] == nil else {
                throw StoreError.invalidRoute("\(hostname) is duplicated")
            }
            unique[hostname] = CustomDomainRouteConfiguration(
                hostname: hostname,
                publishedPort: route.port
            )
        }
        let result = unique.values.sorted { $0.hostname < $1.hostname }
        lock.lock()
        defer { lock.unlock() }
        try saveLocked(result)
        return result
    }

    public func activeRoutes(
        containers: DockerContainerList,
        automaticSuffix: String
    ) -> [DomainRoute] {
        guard case let .ok(rows) = containers,
              let configured = try? configuredRoutes() else {
            return []
        }
        let publishedPorts = Set(rows.lazy.filter(\.isRunning).flatMap { row in
            row.ports.compactMap { port -> UInt16? in
                let proto = (port.type ?? "tcp").lowercased()
                guard proto == "tcp" || proto == "tcp6",
                      let publicPort = port.publicPort else {
                    return nil
                }
                return UInt16(exactly: publicPort)
            }
        })
        let normalizedSuffix = DomainRouter.normalize(automaticSuffix)
        return configured.compactMap { route in
            let comparable = route.hostname.hasPrefix("*.")
                ? String(route.hostname.dropFirst(2))
                : route.hostname
            guard comparable != normalizedSuffix,
                  !comparable.hasSuffix(".\(normalizedSuffix)"),
                  publishedPorts.contains(route.publishedPort) else {
                return nil
            }
            return DomainRoute(
                hostname: route.hostname,
                address: "127.0.0.1",
                port: PrivilegedPortMapping.effectiveBackendPort(forPublishedPort: route.publishedPort)
            )
        }
    }

    private func loadLocked() throws -> [CustomDomainRouteConfiguration] {
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        try validateRegularFile(path)
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
            guard data.count <= Self.maximumBytes else {
                throw StoreError.unreadable("file exceeds \(Self.maximumBytes) bytes")
            }
            let document = try JSONDecoder().decode(Document.self, from: data)
            guard document.schema == "dev.dory.custom-domains", document.version == 1,
                  document.routes.count <= Self.maximumRoutes else {
                throw StoreError.unreadable("schema or route count is invalid")
            }
            var seen: Set<String> = []
            var normalizedRoutes: [CustomDomainRouteConfiguration] = []
            for route in document.routes {
                let hostname = DomainRouter.normalize(route.hostname)
                guard DomainRouter.isValidHostnamePattern(hostname), route.publishedPort > 0,
                      seen.insert(hostname).inserted else {
                    throw StoreError.unreadable("a route is invalid or duplicated")
                }
                normalizedRoutes.append(CustomDomainRouteConfiguration(
                    hostname: hostname,
                    publishedPort: route.publishedPort
                ))
            }
            return normalizedRoutes.sorted { $0.hostname < $1.hostname }
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError.unreadable(error.localizedDescription)
        }
    }

    private func saveLocked(_ routes: [CustomDomainRouteConfiguration]) throws {
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try validateDirectory(directory.path)
            var existing = stat()
            if lstat(path, &existing) == 0 {
                try validateRegularFile(path)
            } else if errno != ENOENT {
                throw StoreError.unsafePath(path)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(Document(routes: routes))
            try data.write(to: url, options: .atomic)
            try validateRegularFile(path, requirePrivatePermissions: false)
            guard chmod(path, 0o600) == 0 else {
                throw StoreError.writeFailed(String(cString: strerror(errno)))
            }
            try validateRegularFile(path)
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError.writeFailed(error.localizedDescription)
        }
    }

    private func validateDirectory(_ candidate: String) throws {
        var info = stat()
        guard lstat(candidate, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid() else {
            throw StoreError.unsafePath(candidate)
        }
        guard chmod(candidate, 0o700) == 0 else {
            throw StoreError.unsafePath(candidate)
        }
    }

    private func validateRegularFile(
        _ candidate: String,
        requirePrivatePermissions: Bool = true
    ) throws {
        var info = stat()
        guard lstat(candidate, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(),
              info.st_nlink == 1,
              info.st_size >= 0,
              info.st_size <= Self.maximumBytes,
              !requirePrivatePermissions || (info.st_mode & 0o077) == 0 else {
            throw StoreError.unsafePath(candidate)
        }
    }
}
