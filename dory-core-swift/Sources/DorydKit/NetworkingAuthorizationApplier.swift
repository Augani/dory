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
    private static let managedMarker = Data("# Managed by Dory. Do not edit.\n".utf8)
    private static let pfAnchorName = "com.apple/dev.dory"
    private static let pfAnchorPath = "/etc/pf.anchors/dev.dory"
    private static let pfTokenPath = "/var/run/dev.dory/system-pf-enable-token"
    private static let maximumManagedFileBytes = 1 << 20

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
        guard !dryRun else {
            return try plan.requests.map { try result(for: $0, removing: false) }
        }

        let fileRequests = plan.requests.filter {
            $0.kind == .resolverFile || $0.kind == .pfAnchor
        }
        let snapshots = try fileRequests.map { request -> ManagedFileSnapshot in
            guard let path = request.filePath else {
                throw NetworkingAuthorizationApplyError.missingPayload(request.id)
            }
            return ManagedFileSnapshot(path: path, contents: try readManagedFile(path: path))
        }
        let hadPFToken = try readPFToken() != nil
        var acquiredPFToken = false
        var trustPathAttempted: String?

        do {
            var results: [NetworkingAuthorizationApplyResult] = []
            for request in plan.requests {
                switch request.kind {
                case .resolverFile, .pfAnchor:
                    guard let filePath = request.filePath, let contents = request.fileContents else {
                        throw NetworkingAuthorizationApplyError.missingPayload(request.id)
                    }
                    try writeManagedFile(path: filePath, contents: contents)
                case .pfEnable:
                    _ = try runOutput(request.command, requestID: request.id)
                    acquiredPFToken = try ensurePFEnabled(requestID: request.id)
                case .localCATrust:
                    guard let filePath = request.filePath else {
                        throw NetworkingAuthorizationApplyError.missingPayload(request.id)
                    }
                    trustPathAttempted = filePath
                    _ = try runOutput(request.command, requestID: request.id)
                }
                results.append(try result(for: request, removing: false))
            }
            return results
        } catch {
            if let trustPathAttempted {
                _ = try? runCommand([
                    "/usr/bin/security", "remove-trusted-cert", "-d", rootedPath(trustPathAttempted),
                ])
            }
            if acquiredPFToken {
                try? releaseOwnedPFToken()
            }
            for snapshot in snapshots.reversed() {
                if let contents = snapshot.contents {
                    try? writeManagedFile(path: snapshot.path, data: contents, permissions: 0o644)
                } else {
                    try? removeManagedFile(path: snapshot.path)
                }
            }
            if let oldAnchor = snapshots.first(where: { $0.path == Self.pfAnchorPath })?.contents,
               hadPFToken,
               oldAnchor.starts(with: Self.managedMarker) {
                _ = try? runCommand([
                    "/sbin/pfctl", "-a", Self.pfAnchorName, "-f", Self.pfAnchorPath,
                ])
            } else {
                _ = try? runCommand([
                    "/sbin/pfctl", "-a", Self.pfAnchorName, "-F", "all",
                ])
            }
            throw error
        }
    }

    @discardableResult
    public func remove(_ plan: NetworkingAuthorizationPlan) throws -> [NetworkingAuthorizationApplyResult] {
        let expected = try expectedPlan(for: plan)
        try validate(plan: plan, expected: expected)
        try preflightRemoval(plan.requests)
        guard !dryRun else {
            return try plan.requests.reversed().map { try result(for: $0, removing: true) }
        }

        if let trust = plan.requests.first(where: { $0.kind == .localCATrust }),
           let path = trust.filePath {
            _ = try runOutput(
                ["/usr/bin/security", "remove-trusted-cert", "-d", rootedPath(path)],
                requestID: trust.id
            )
        }
        _ = try runOutput(
            ["/sbin/pfctl", "-a", Self.pfAnchorName, "-F", "all"],
            requestID: "pf.dev.dory.disable"
        )
        try releaseOwnedPFToken()
        for request in plan.requests.reversed()
        where request.kind == .resolverFile || request.kind == .pfAnchor {
            guard let path = request.filePath else {
                throw NetworkingAuthorizationApplyError.missingPayload(request.id)
            }
            try removeManagedFile(path: path)
        }
        return try plan.requests.reversed().map { try result(for: $0, removing: true) }
    }

    /// The resolver and CA trust are persistent files, while PF's enable reference and loaded
    /// anchor are boot-scoped. The root launch daemon calls this on every launch so an explicitly
    /// authorized installation survives reboot without accumulating PF references.
    public func restorePFIfAuthorized() throws {
        guard !dryRun,
              let anchor = try readManagedFile(path: Self.pfAnchorPath),
              anchor.starts(with: Self.managedMarker) else {
            return
        }
        _ = try runOutput(
            ["/sbin/pfctl", "-a", Self.pfAnchorName, "-f", Self.pfAnchorPath],
            requestID: "pf.dev.dory.restore"
        )
        _ = try ensurePFEnabled(requestID: "pf.dev.dory.restore")
    }

    private func expectedPlan(for plan: NetworkingAuthorizationPlan) throws -> NetworkingAuthorizationPlan {
        let caPath = plan.requests.first { $0.kind == .localCATrust }?.filePath
        return try NetworkingAuthorizationPlan.make(configuration: NetworkingConfiguration(
            suffix: plan.suffix,
            dnsBindAddress: plan.dnsBindAddress,
            dnsPort: plan.dnsPort,
            httpProxyPort: plan.httpProxyPort,
            httpsProxyPort: plan.httpsProxyPort,
            privilegedTCPForwards: plan.privilegedTCPForwards,
            localCACertificatePath: caPath
        ))
    }

    private func validate(plan: NetworkingAuthorizationPlan, expected: NetworkingAuthorizationPlan) throws {
        // Compare the ordered sequence, not just the set: requests are applied in the
        // order supplied, so a reordered plan could otherwise load the pf anchor
        // (pfEnable) before its file (pfAnchor) is written.
        guard plan.requests.count == expected.requests.count else {
            throw NetworkingAuthorizationApplyError.unsafeRequest("request-set")
        }
        for (submitted, canonical) in zip(plan.requests, expected.requests) {
            guard submitted == canonical else {
                throw NetworkingAuthorizationApplyError.unsafeRequest(submitted.id)
            }
        }
    }

    private func result(
        for request: NetworkingAuthorizationRequest,
        removing: Bool
    ) throws -> NetworkingAuthorizationApplyResult {
        switch request.kind {
        case .resolverFile, .pfAnchor:
            guard let filePath = request.filePath, request.fileContents != nil else {
                throw NetworkingAuthorizationApplyError.missingPayload(request.id)
            }
            return NetworkingAuthorizationApplyResult(
                id: request.id,
                kind: request.kind,
                action: removing ? "remove-file" : "write-file",
                target: filePath,
                dryRun: dryRun
            )
        case .pfEnable:
            return NetworkingAuthorizationApplyResult(
                id: request.id,
                kind: request.kind,
                action: removing ? "release-pf-reference" : "run-command",
                target: removing ? Self.pfAnchorName : request.command.joined(separator: " "),
                dryRun: dryRun
            )
        case .localCATrust:
            guard let filePath = request.filePath else {
                throw NetworkingAuthorizationApplyError.missingPayload(request.id)
            }
            return NetworkingAuthorizationApplyResult(
                id: request.id,
                kind: request.kind,
                action: removing ? "remove-trust" : "run-command",
                target: removing ? filePath : request.command.joined(separator: " "),
                dryRun: dryRun
            )
        }
    }

    private func preflight(_ requests: [NetworkingAuthorizationRequest]) throws {
        guard !dryRun else { return }
        for request in requests where request.kind == .localCATrust {
            guard let filePath = request.filePath, try isSafeRegularFile(filePath) else {
                throw NetworkingAuthorizationApplyError.missingPayload(request.id)
            }
        }
    }

    private func preflightRemoval(_ requests: [NetworkingAuthorizationRequest]) throws {
        guard !dryRun else { return }
        for request in requests {
            switch request.kind {
            case .resolverFile, .pfAnchor:
                guard let path = request.filePath, let expected = request.fileContents else {
                    throw NetworkingAuthorizationApplyError.missingPayload(request.id)
                }
                if let existing = try readManagedFile(path: path),
                   existing != Data(expected.utf8) {
                    throw NetworkingAuthorizationApplyError.unsafeRequest(request.id)
                }
            case .localCATrust:
                guard let path = request.filePath, try isSafeRegularFile(path) else {
                    throw NetworkingAuthorizationApplyError.missingPayload(request.id)
                }
            case .pfEnable:
                _ = try readPFToken()
            }
        }
    }

    private func runOutput(_ command: [String], requestID: String) throws -> String {
        guard !command.isEmpty else {
            throw NetworkingAuthorizationApplyError.unsafeRequest(requestID)
        }
        do {
            return try runCommand(command)
        } catch {
            throw NetworkingAuthorizationApplyError.commandFailed(requestID, "\(error)")
        }
    }

    private func writeManagedFile(path: String, contents: String) throws {
        try writeManagedFile(path: path, data: Data(contents.utf8), permissions: 0o644)
    }

    private func writeManagedFile(path: String, data: Data, permissions: mode_t) throws {
        let target = rootedPath(path)
        let directory = (target as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let temporary = "\(target).tmp.\(UUID().uuidString)"
        try data.write(to: URL(fileURLWithPath: temporary), options: .atomic)
        guard chmod(temporary, permissions) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(atPath: temporary)
            throw NetworkingAuthorizationApplyError.commandFailed(path, String(cString: strerror(code)))
        }
        if rename(temporary, target) != 0 {
            let code = errno
            try? FileManager.default.removeItem(atPath: temporary)
            throw NetworkingAuthorizationApplyError.commandFailed(path, String(cString: strerror(code)))
        }
    }

    private func readManagedFile(path: String) throws -> Data? {
        let target = rootedPath(path)
        let descriptor = open(target, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else {
            throw NetworkingAuthorizationApplyError.unsafeRequest(path)
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0,
              info.st_size <= Self.maximumManagedFileBytes,
              fileSystemRoot != "/" || info.st_uid == 0 else {
            throw NetworkingAuthorizationApplyError.unsafeRequest(path)
        }
        let data = try readAll(
            descriptor: descriptor,
            expectedBytes: Int(info.st_size),
            maximumBytes: Self.maximumManagedFileBytes,
            requestID: path
        )
        guard data.starts(with: Self.managedMarker) else {
            throw NetworkingAuthorizationApplyError.unsafeRequest(path)
        }
        return data
    }

    private func removeManagedFile(path: String) throws {
        let target = rootedPath(path)
        if unlink(target) != 0, errno != ENOENT {
            throw NetworkingAuthorizationApplyError.commandFailed(
                path,
                String(cString: strerror(errno))
            )
        }
    }

    private func isSafeRegularFile(_ path: String) throws -> Bool {
        let descriptor = open(rootedPath(path), O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0, errno == ENOENT { return false }
        guard descriptor >= 0 else {
            throw NetworkingAuthorizationApplyError.unsafeRequest(path)
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw NetworkingAuthorizationApplyError.unsafeRequest(path)
        }
        return info.st_mode & S_IFMT == S_IFREG
            && info.st_size > 0
            && info.st_size <= Self.maximumManagedFileBytes
    }

    private func ensurePFEnabled(requestID: String) throws -> Bool {
        if try readPFToken() != nil { return false }
        let output = try runOutput(["/sbin/pfctl", "-E"], requestID: requestID)
        guard let token = SourcePreservingLANPrivilegedController.pfEnableToken(from: output) else {
            throw NetworkingAuthorizationApplyError.commandFailed(
                requestID,
                "pfctl -E did not return a releasable enable token"
            )
        }
        do {
            try persistPFToken(token)
        } catch {
            _ = try? runCommand(["/sbin/pfctl", "-X", token])
            throw error
        }
        return true
    }

    private func persistPFToken(_ token: String) throws {
        let path = rootedPath(Self.pfTokenPath)
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw NetworkingAuthorizationApplyError.commandFailed(
                Self.pfTokenPath,
                String(cString: strerror(errno))
            )
        }
        defer { close(descriptor) }
        let bytes = Array((token + "\n").utf8)
        do {
            try writeAll(descriptor: descriptor, bytes: bytes, requestID: Self.pfTokenPath)
        } catch {
            _ = unlink(path)
            throw error
        }
        guard fsync(descriptor) == 0 else {
            let code = errno
            _ = unlink(path)
            throw NetworkingAuthorizationApplyError.commandFailed(Self.pfTokenPath, String(cString: strerror(code)))
        }
    }

    private func readPFToken() throws -> String? {
        let path = rootedPath(Self.pfTokenPath)
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else {
            throw NetworkingAuthorizationApplyError.unsafeRequest(Self.pfTokenPath)
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0,
              info.st_size <= 64,
              fileSystemRoot != "/" || info.st_uid == 0 else {
            throw NetworkingAuthorizationApplyError.unsafeRequest(Self.pfTokenPath)
        }
        let data = try readAll(
            descriptor: descriptor,
            expectedBytes: Int(info.st_size),
            maximumBytes: 64,
            requestID: Self.pfTokenPath
        )
        guard let token = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              token.wholeMatch(of: /[0-9]+/) != nil else {
            throw NetworkingAuthorizationApplyError.unsafeRequest(Self.pfTokenPath)
        }
        return token
    }

    private func readAll(
        descriptor: Int32,
        expectedBytes: Int,
        maximumBytes: Int,
        requestID: String
    ) throws -> Data {
        var data = Data()
        data.reserveCapacity(expectedBytes)
        var buffer = [UInt8](repeating: 0, count: min(64 * 1024, max(1, maximumBytes)))
        while true {
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                while true {
                    let value = Darwin.read(descriptor, raw.baseAddress, raw.count)
                    if value < 0, errno == EINTR { continue }
                    return value
                }
            }
            guard count >= 0 else {
                throw NetworkingAuthorizationApplyError.commandFailed(
                    requestID,
                    String(cString: strerror(errno))
                )
            }
            if count == 0 { break }
            guard data.count <= maximumBytes - count else {
                throw NetworkingAuthorizationApplyError.unsafeRequest(requestID)
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.count == expectedBytes else {
            throw NetworkingAuthorizationApplyError.unsafeRequest(requestID)
        }
        return data
    }

    private func writeAll(
        descriptor: Int32,
        bytes: [UInt8],
        requestID: String
    ) throws {
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { raw -> Int in
                let base = raw.baseAddress?.advanced(by: offset)
                while true {
                    let value = Darwin.write(descriptor, base, raw.count - offset)
                    if value < 0, errno == EINTR { continue }
                    return value
                }
            }
            guard written > 0 else {
                let message = written == 0 ? "short write" : String(cString: strerror(errno))
                throw NetworkingAuthorizationApplyError.commandFailed(requestID, message)
            }
            offset += written
        }
    }

    private func releaseOwnedPFToken() throws {
        guard let token = try readPFToken() else { return }
        _ = try runOutput(
            ["/sbin/pfctl", "-X", token],
            requestID: "pf.dev.dory.disable"
        )
        try removeManagedFile(path: Self.pfTokenPath)
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

private struct ManagedFileSnapshot {
    var path: String
    var contents: Data?
}
