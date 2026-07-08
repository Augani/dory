import Darwin
import Foundation

public enum NetworkingAuthorizationApplyError: Error, Sendable, Equatable, CustomStringConvertible {
    case missingPayload(String)
    case unsafeRequest(String)
    case commandFailed(String, String)

    public var description: String {
        switch self {
        case let .missingPayload(id):
            return "networking authorization request is missing file payload: \(id)"
        case let .unsafeRequest(id):
            return "networking authorization request is not allowed: \(id)"
        case let .commandFailed(id, message):
            return "networking authorization command failed for \(id): \(message)"
        }
    }
}

public struct NetworkingAuthorizationApplyResult: Sendable, Equatable, Codable {
    public var id: String
    public var kind: NetworkingAuthorizationRequestKind
    public var action: String
    public var target: String
    public var dryRun: Bool

    public init(
        id: String,
        kind: NetworkingAuthorizationRequestKind,
        action: String,
        target: String,
        dryRun: Bool
    ) {
        self.id = id
        self.kind = kind
        self.action = action
        self.target = target
        self.dryRun = dryRun
    }
}

public struct NetworkingAuthorizationApplier: Sendable {
    public var fileSystemRoot: String
    public var dryRun: Bool
    private let runCommand: @Sendable ([String]) throws -> String

    public init(
        fileSystemRoot: String = "/",
        dryRun: Bool = false,
        runCommand: (@Sendable ([String]) throws -> String)? = nil
    ) {
        self.fileSystemRoot = fileSystemRoot
        self.dryRun = dryRun
        self.runCommand = runCommand ?? NetworkingAuthorizationApplier.runCommand
    }

    @discardableResult
    public func apply(_ plan: NetworkingAuthorizationPlan) throws -> [NetworkingAuthorizationApplyResult] {
        let expected = try expectedPlan(for: plan)
        try validate(plan: plan, expected: expected)
        try preflight(plan.requests)
        return try plan.requests.map(apply)
    }

    private func expectedPlan(for plan: NetworkingAuthorizationPlan) throws -> NetworkingAuthorizationPlan {
        let caPath = plan.requests.first { $0.kind == .localCATrust }?.filePath
        return try NetworkingAuthorizationPlan.make(configuration: NetworkingConfiguration(
            suffix: plan.suffix,
            dnsBindAddress: plan.dnsBindAddress,
            dnsPort: plan.dnsPort,
            httpProxyPort: plan.httpProxyPort,
            httpsProxyPort: plan.httpsProxyPort,
            localCACertificatePath: caPath
        ))
    }

    private func validate(plan: NetworkingAuthorizationPlan, expected: NetworkingAuthorizationPlan) throws {
        let expectedByID = Dictionary(uniqueKeysWithValues: expected.requests.map { ($0.id, $0) })
        guard Set(plan.requests.map(\.id)) == Set(expectedByID.keys) else {
            throw NetworkingAuthorizationApplyError.unsafeRequest("request-set")
        }
        for request in plan.requests {
            guard expectedByID[request.id] == request else {
                throw NetworkingAuthorizationApplyError.unsafeRequest(request.id)
            }
        }
    }

    private func apply(_ request: NetworkingAuthorizationRequest) throws -> NetworkingAuthorizationApplyResult {
        switch request.kind {
        case .resolverFile, .pfAnchor:
            guard let filePath = request.filePath, let contents = request.fileContents else {
                throw NetworkingAuthorizationApplyError.missingPayload(request.id)
            }
            if !dryRun {
                try writeManagedFile(path: filePath, contents: contents)
            }
            return NetworkingAuthorizationApplyResult(
                id: request.id,
                kind: request.kind,
                action: "write-file",
                target: filePath,
                dryRun: dryRun
            )
        case .pfEnable:
            try run(request.command, requestID: request.id)
            try run(["/sbin/pfctl", "-E"], requestID: request.id)
            return NetworkingAuthorizationApplyResult(
                id: request.id,
                kind: request.kind,
                action: "run-command",
                target: request.command.joined(separator: " "),
                dryRun: dryRun
            )
        case .localCATrust:
            guard let filePath = request.filePath else {
                throw NetworkingAuthorizationApplyError.missingPayload(request.id)
            }
            if !dryRun, !FileManager.default.fileExists(atPath: rootedPath(filePath)) {
                throw NetworkingAuthorizationApplyError.missingPayload(request.id)
            }
            try run(request.command, requestID: request.id)
            return NetworkingAuthorizationApplyResult(
                id: request.id,
                kind: request.kind,
                action: "run-command",
                target: request.command.joined(separator: " "),
                dryRun: dryRun
            )
        }
    }

    private func preflight(_ requests: [NetworkingAuthorizationRequest]) throws {
        guard !dryRun else { return }
        for request in requests where request.kind == .localCATrust {
            guard let filePath = request.filePath,
                  FileManager.default.fileExists(atPath: rootedPath(filePath)) else {
                throw NetworkingAuthorizationApplyError.missingPayload(request.id)
            }
        }
    }

    private func run(_ command: [String], requestID: String) throws {
        guard !command.isEmpty else {
            throw NetworkingAuthorizationApplyError.unsafeRequest(requestID)
        }
        guard !dryRun else { return }
        do {
            _ = try runCommand(command)
        } catch {
            throw NetworkingAuthorizationApplyError.commandFailed(requestID, "\(error)")
        }
    }

    private func writeManagedFile(path: String, contents: String) throws {
        let target = rootedPath(path)
        let directory = (target as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let temporary = "\(target).tmp.\(UUID().uuidString)"
        try Data(contents.utf8).write(to: URL(fileURLWithPath: temporary), options: .atomic)
        chmod(temporary, 0o644)
        if rename(temporary, target) != 0 {
            let code = errno
            try? FileManager.default.removeItem(atPath: temporary)
            throw NetworkingAuthorizationApplyError.commandFailed(path, String(cString: strerror(code)))
        }
        chmod(target, 0o644)
    }

    private func rootedPath(_ absolutePath: String) -> String {
        guard fileSystemRoot != "/" else { return absolutePath }
        let relative = absolutePath.drop { $0 == "/" }
        return URL(fileURLWithPath: fileSystemRoot).appendingPathComponent(String(relative)).path
    }

    private static func runCommand(_ command: [String]) throws -> String {
        try DoryShell.run(command[0], Array(command.dropFirst()))
    }
}
