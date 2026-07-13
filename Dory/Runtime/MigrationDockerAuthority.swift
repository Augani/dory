import CryptoKit
import Foundation

enum MigrationDockerAuthorityError: Error, Sendable, Equatable, CustomStringConvertible {
    case unavailable(String)
    case invalid(String)
    case unsupported(String)

    var description: String {
        switch self {
        case let .unavailable(detail): "cannot read Docker authority: \(detail)"
        case let .invalid(detail): "invalid Docker authority: \(detail)"
        case let .unsupported(detail): "unsupported Docker authority: \(detail)"
        }
    }
}

struct MigrationDockerAuthority: Codable, Sendable, Equatable {
    static let minimumAPI = DockerAPIVersion(major: 1, minor: 40)
    static let maximumAPI = DockerAPIVersion(major: 1, minor: 55)

    let apiVersion: String
    let architecture: String
    let daemonID: String
    let dockerRootDirectory: String
    let engineVersion: String
    let operatingSystem: String
    let osType: String
    let product: String
    let socketAuthority: String
    let storageDriver: String

    var authorityID: String {
        "docker-engine:" + Self.digest(self)
    }

    var daemonIdentity: String {
        Self.digest(DaemonIdentity(
            architecture: architecture,
            daemonID: daemonID,
            dockerRootDirectory: dockerRootDirectory,
            osType: osType
        ))
    }

    static func read(from runtime: any ContainerRuntime) async throws -> MigrationDockerAuthority {
        guard runtime.supportsRawProxy else {
            throw MigrationDockerAuthorityError.unsupported("local raw Docker API is required")
        }
        async let version = object(path: "/version", runtime: runtime)
        async let info = object(path: "/info", runtime: runtime)
        return try parse(
            version: await version,
            info: await info,
            socketAuthority: runtime.migrationSourceIdentifier
        )
    }
}

private extension MigrationDockerAuthority {
    struct DaemonIdentity: Codable {
        let architecture: String
        let daemonID: String
        let dockerRootDirectory: String
        let osType: String
    }

    static func object(
        path: String,
        runtime: any ContainerRuntime
    ) async throws -> [String: Any] {
        guard let response = await runtime.proxyRequest(
            method: "GET",
            path: path,
            headers: [(name: "Accept", value: "application/json")],
            body: Data()
        ) else {
            throw MigrationDockerAuthorityError.unavailable(path)
        }
        guard response.isSuccess,
              let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            throw MigrationDockerAuthorityError.invalid(path)
        }
        return object
    }

    static func parse(
        version: [String: Any],
        info: [String: Any],
        socketAuthority: String
    ) throws -> MigrationDockerAuthority {
        let apiText = string(version["ApiVersion"])
        guard let api = DockerAPIVersion(apiText) else {
            throw MigrationDockerAuthorityError.invalid("missing API version")
        }
        guard api >= minimumAPI, api <= maximumAPI else {
            throw MigrationDockerAuthorityError.unsupported(
                "Docker API \(apiText) is outside the qualified 1.40-1.55 contract"
            )
        }
        let versionArchitecture = normalizedArchitecture(string(version["Arch"]))
        let infoArchitecture = normalizedArchitecture(string(info["Architecture"]))
        guard versionArchitecture == "arm64", infoArchitecture == "arm64" else {
            throw MigrationDockerAuthorityError.unsupported(
                "Apple Silicon v1 requires arm64 source and target engines"
            )
        }
        let versionOS = string(version["Os"]).lowercased()
        let infoOS = string(info["OSType"]).lowercased()
        guard versionOS == "linux", infoOS == "linux" else {
            throw MigrationDockerAuthorityError.unsupported("Linux Docker engines are required")
        }
        let authority = MigrationDockerAuthority(
            apiVersion: apiText,
            architecture: versionArchitecture,
            daemonID: string(info["ID"]),
            dockerRootDirectory: string(info["DockerRootDir"]),
            engineVersion: string(version["Version"]),
            operatingSystem: string(info["OperatingSystem"]),
            osType: versionOS,
            product: platformName(version) ?? string(info["Name"]),
            socketAuthority: socketAuthority,
            storageDriver: string(info["Driver"])
        )
        guard [
            authority.daemonID,
            authority.dockerRootDirectory,
            authority.engineVersion,
            authority.operatingSystem,
            authority.product,
            authority.socketAuthority,
            authority.storageDriver
        ].allSatisfy({ !$0.isEmpty }) else {
            throw MigrationDockerAuthorityError.invalid("one or more identity fields are empty")
        }
        return authority
    }

    static func string(_ value: Any?) -> String {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func platformName(_ version: [String: Any]) -> String? {
        let name = string((version["Platform"] as? [String: Any])?["Name"])
        return name.isEmpty ? nil : name
    }

    static func normalizedArchitecture(_ value: String) -> String {
        switch value.lowercased() {
        case "arm64", "aarch64": "arm64"
        default: value.lowercased()
        }
    }

    static func digest<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(value)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct DockerAPIVersion: Sendable, Equatable, Comparable {
    let major: Int
    let minor: Int

    init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    init?(_ value: String) {
        let fields = value.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 2,
              let major = Int(fields[0]),
              let minor = Int(fields[1]),
              major >= 0,
              minor >= 0 else { return nil }
        self.init(major: major, minor: minor)
    }

    static func < (lhs: DockerAPIVersion, rhs: DockerAPIVersion) -> Bool {
        (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
    }
}
