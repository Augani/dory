import Darwin
import Foundation

public enum NetworkingAuthorizationApplyError: Error, Sendable, Equatable, CustomStringConvertible {
    case missingPayload(String)
    case unsafeRequest(String)
    case commandFailed(String, String)
    case ownerMismatch(expected: uid_t, actual: uid_t)
    case notAuthorized

    public var description: String {
        switch self {
        case let .missingPayload(id):
            return "networking authorization request is missing file payload: \(id)"
        case let .unsafeRequest(id):
            return "networking authorization request is not allowed: \(id)"
        case let .commandFailed(id, message):
            return "networking authorization command failed for \(id): \(message)"
        case let .ownerMismatch(expected, actual):
            return "networking authorization belongs to uid \(expected), not uid \(actual)"
        case .notAuthorized:
            return "system networking has not been authorized"
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
    private static let mutationLockPath = "/var/run/dev.dory/system-network.lock"
    private static let authorizationStatePath = "/private/var/db/dev.dory/network-authorization.json"
    private static let trustedCASnapshotPath = "/private/var/db/dev.dory/local-ca.crt"
    private static let maximumManagedFileBytes = 1 << 20

    public var fileSystemRoot: String
    public var dryRun: Bool
    public var ownerUID: uid_t?
    private let runCommand: @Sendable ([String]) throws -> String
    private var requiresExistingAuthorization = false

    public init(
        fileSystemRoot: String = "/",
        dryRun: Bool = false,
        ownerUID: uid_t? = nil,
        runCommand: (@Sendable ([String]) throws -> String)? = nil
    ) {
        self.fileSystemRoot = fileSystemRoot
        self.dryRun = dryRun
        self.ownerUID = ownerUID
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
        let mutationLock = try acquireMutationLock()
        defer { releaseMutationLock(mutationLock) }

        let installedState = try readAuthorizationState()
        if requiresExistingAuthorization, installedState == nil {
            throw NetworkingAuthorizationApplyError.notAuthorized
        }
        let resolvedOwnerUID = try authorizationOwner(installedState: installedState)
        if let installedState {
            try validateStoredState(installedState)
        }
        let newCertificate = try certificateData(plan.requests, ownerUID: resolvedOwnerUID)
        let oldCertificate = try readSafeRegularFile(
            path: Self.trustedCASnapshotPath,
            requiredOwnerUID: fileSystemRoot == "/" ? 0 : nil
        )
        if installedState == nil, oldCertificate != nil {
            throw NetworkingAuthorizationApplyError.unsafeRequest(Self.trustedCASnapshotPath)
        }

        let oldPlan = installedState?.plan
        let managedPaths = Set<String>((plan.requests + (oldPlan?.requests ?? [])).compactMap { request in
            guard request.kind == .resolverFile || request.kind == .pfAnchor else { return nil }
            return request.filePath
        })
        let snapshots = try managedPaths.sorted().map { path in
            ManagedFileSnapshot(path: path, contents: try readManagedFile(path: path))
        }
        if let oldPlan {
            try preflightRemoval(oldPlan.requests)
        }
        let stateSnapshot = try readManagedFile(path: Self.authorizationStatePath)
        let certificateSnapshot = oldCertificate
        let oldResolverPath = oldPlan?.requests.first { $0.kind == .resolverFile }?.filePath
        let newResolverPath = plan.requests.first { $0.kind == .resolverFile }?.filePath
        let hadPFToken = try readPFToken() != nil
        var acquiredPFToken = false
        var newTrustAddAttempted = false
        var oldTrustRemoved = false
        let trustChanged = oldCertificate != newCertificate

        do {
            if let oldResolverPath, oldResolverPath != newResolverPath {
                try removeManagedFile(path: oldResolverPath)
            }
            if trustChanged, oldCertificate != nil {
                try removeSystemTrust(certificatePath: Self.trustedCASnapshotPath)
                oldTrustRemoved = true
            }
            if trustChanged, let newCertificate {
                try writeManagedFile(
                    path: Self.trustedCASnapshotPath,
                    data: newCertificate,
                    permissions: 0o600
                )
            } else if trustChanged {
                try removeManagedFile(path: Self.trustedCASnapshotPath)
            }
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
                    guard request.filePath != nil else {
                        throw NetworkingAuthorizationApplyError.missingPayload(request.id)
                    }
                    if trustChanged {
                        newTrustAddAttempted = true
                        try addSystemTrust(
                            certificatePath: Self.trustedCASnapshotPath,
                            requestID: request.id
                        )
                    }
                }
                results.append(try result(for: request, removing: false))
            }
            try persistAuthorizationState(
                NetworkingAuthorizationState(ownerUID: resolvedOwnerUID, plan: plan)
            )
            return results
        } catch {
            if newTrustAddAttempted {
                try? removeSystemTrust(certificatePath: Self.trustedCASnapshotPath)
            }
            if let certificateSnapshot {
                try? writeManagedFile(
                    path: Self.trustedCASnapshotPath,
                    data: certificateSnapshot,
                    permissions: 0o600
                )
            } else {
                try? removeManagedFile(path: Self.trustedCASnapshotPath)
            }
            if oldTrustRemoved, certificateSnapshot != nil {
                try? addSystemTrust(
                    certificatePath: Self.trustedCASnapshotPath,
                    requestID: "trust.local-ca.rollback"
                )
            }
            if acquiredPFToken {
                _ = try? releaseOwnedPFToken()
            }
            for snapshot in snapshots.reversed() {
                if let contents = snapshot.contents {
                    try? writeManagedFile(path: snapshot.path, data: contents, permissions: 0o644)
                } else {
                    try? removeManagedFile(path: snapshot.path)
                }
            }
            if let stateSnapshot {
                try? writeManagedFile(
                    path: Self.authorizationStatePath,
                    data: stateSnapshot,
                    permissions: 0o600
                )
            } else {
                try? removeManagedFile(path: Self.authorizationStatePath)
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

    /// Reconciles an already authorized user's canonical plan without another password prompt.
    /// A signed per-user doryd may update ports or suffixes, but it can never create the initial
    /// system authorization or take over another user's authorization.
    @discardableResult
    public func reconcileIfAuthorized(
        _ plan: NetworkingAuthorizationPlan,
        clientUID: uid_t
    ) throws -> Bool {
        var constrained = self
        constrained.ownerUID = clientUID
        constrained.requiresExistingAuthorization = true
        do {
            _ = try constrained.apply(plan)
            return true
        } catch NetworkingAuthorizationApplyError.notAuthorized {
            return false
        }
    }

    @discardableResult
    public func remove(_ plan: NetworkingAuthorizationPlan) throws -> [NetworkingAuthorizationApplyResult] {
        let expected = try expectedPlan(for: plan)
        try validate(plan: plan, expected: expected)
        let mutationLock: Int32? = dryRun ? nil : try acquireMutationLock()
        defer {
            if let mutationLock { releaseMutationLock(mutationLock) }
        }
        let installedState = dryRun ? nil : try readAuthorizationState()
        if let installedState {
            try validateStoredState(installedState)
            if let ownerUID, ownerUID != installedState.ownerUID {
                throw NetworkingAuthorizationApplyError.ownerMismatch(
                    expected: installedState.ownerUID,
                    actual: ownerUID
                )
            }
        }
        let installedPlan = installedState?.plan ?? plan
        try preflightRemoval(installedPlan.requests)
        guard !dryRun else {
            return try installedPlan.requests.reversed().map { try result(for: $0, removing: true) }
        }

        let persistedCertificate = try readSafeRegularFile(
            path: Self.trustedCASnapshotPath,
            requiredOwnerUID: fileSystemRoot == "/" ? 0 : nil
        )
        let managedPaths = installedPlan.requests.compactMap { request -> String? in
            guard request.kind == .resolverFile || request.kind == .pfAnchor else { return nil }
            return request.filePath
        }
        let snapshots = try managedPaths.map {
            ManagedFileSnapshot(path: $0, contents: try readManagedFile(path: $0))
        }
        let stateSnapshot = try readManagedFile(path: Self.authorizationStatePath)
        let hadPFToken = try readPFToken() != nil
        var trustPath: String?
        if let trust = installedPlan.requests.first(where: { $0.kind == .localCATrust }),
           let path = trust.filePath {
            if persistedCertificate != nil {
                trustPath = Self.trustedCASnapshotPath
            } else if try isSafeRegularFile(path) {
                trustPath = path
            } else {
                throw NetworkingAuthorizationApplyError.missingPayload(trust.id)
            }
        }
        var trustRemoved = false
        var tokenReleased = false
        do {
            if let trustPath {
                try removeSystemTrust(certificatePath: trustPath)
                trustRemoved = true
            }
            _ = try runOutput(
                ["/sbin/pfctl", "-a", Self.pfAnchorName, "-F", "all"],
                requestID: "pf.dev.dory.disable"
            )
            tokenReleased = try releaseOwnedPFToken()
            for path in managedPaths.reversed() {
                try removeManagedFile(path: path)
            }
            try removeManagedFile(path: Self.trustedCASnapshotPath)
            try removeManagedFile(path: Self.authorizationStatePath)
        } catch {
            for snapshot in snapshots {
                if let contents = snapshot.contents {
                    try? writeManagedFile(path: snapshot.path, data: contents, permissions: 0o644)
                }
            }
            if let stateSnapshot {
                try? writeManagedFile(
                    path: Self.authorizationStatePath,
                    data: stateSnapshot,
                    permissions: 0o600
                )
            }
            if let persistedCertificate {
                try? writeManagedFile(
                    path: Self.trustedCASnapshotPath,
                    data: persistedCertificate,
                    permissions: 0o600
                )
            }
            let hadAnchor = snapshots.contains {
                $0.path == Self.pfAnchorPath && $0.contents != nil
            }
            if hadAnchor, tokenReleased || !hadPFToken {
                _ = try? ensurePFEnabled(requestID: "pf.dev.dory.remove.rollback")
            }
            if hadAnchor {
                _ = try? runCommand([
                    "/sbin/pfctl", "-a", Self.pfAnchorName, "-f", Self.pfAnchorPath,
                ])
            }
            if trustRemoved, let trustPath {
                try? addSystemTrust(
                    certificatePath: trustPath,
                    requestID: "trust.local-ca.remove.rollback"
                )
            }
            throw error
        }
        return try installedPlan.requests.reversed().map { try result(for: $0, removing: true) }
    }

    /// The resolver and CA trust are persistent files, while PF's enable reference and loaded
    /// anchor are boot-scoped. The root launch daemon calls this on every launch so an explicitly
    /// authorized installation survives reboot without accumulating PF references.
    public func restorePFIfAuthorized() throws {
        guard !dryRun else { return }
        let mutationLock = try acquireMutationLock()
        defer { releaseMutationLock(mutationLock) }
        guard let anchor = try readManagedFile(path: Self.pfAnchorPath),
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

    private func authorizationOwner(
        installedState: NetworkingAuthorizationState?
    ) throws -> uid_t {
        if let installedState {
            if let ownerUID, ownerUID != installedState.ownerUID {
                throw NetworkingAuthorizationApplyError.ownerMismatch(
                    expected: installedState.ownerUID,
                    actual: ownerUID
                )
            }
            return installedState.ownerUID
        }
        if let ownerUID { return ownerUID }
        if fileSystemRoot != "/" { return getuid() }
        throw NetworkingAuthorizationApplyError.unsafeRequest("owner-uid")
    }

    private func validateStoredState(_ state: NetworkingAuthorizationState) throws {
        guard state.version == 1 else {
            throw NetworkingAuthorizationApplyError.unsafeRequest("authorization-state-version")
        }
        let expected = try expectedPlan(for: state.plan)
        try validate(plan: state.plan, expected: expected)
    }

    private func certificateData(
        _ requests: [NetworkingAuthorizationRequest],
        ownerUID: uid_t
    ) throws -> Data? {
        guard let request = requests.first(where: { $0.kind == .localCATrust }),
              let path = request.filePath else {
            return nil
        }
        guard let data = try readSafeRegularFile(path: path, requiredOwnerUID: ownerUID) else {
            throw NetworkingAuthorizationApplyError.missingPayload(request.id)
        }
        return data
    }

    private func readAuthorizationState() throws -> NetworkingAuthorizationState? {
        guard let data = try readManagedFile(path: Self.authorizationStatePath) else {
            return nil
        }
        let payload = data.dropFirst(Self.managedMarker.count)
        do {
            return try JSONDecoder().decode(NetworkingAuthorizationState.self, from: payload)
        } catch {
            throw NetworkingAuthorizationApplyError.unsafeRequest("authorization-state")
        }
    }

    private func persistAuthorizationState(_ state: NetworkingAuthorizationState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = Self.managedMarker
        data.append(try encoder.encode(state))
        data.append(0x0A)
        try writeManagedFile(
            path: Self.authorizationStatePath,
            data: data,
            permissions: 0o600
        )
    }

    private func addSystemTrust(certificatePath: String, requestID: String) throws {
        _ = try runOutput([
            "/usr/bin/security", "add-trusted-cert", "-d", "-r", "trustRoot",
            "-k", "/Library/Keychains/System.keychain", rootedPath(certificatePath),
        ], requestID: requestID)
    }

    private func removeSystemTrust(certificatePath: String) throws {
        _ = try runOutput([
            "/usr/bin/security", "remove-trusted-cert", "-d", rootedPath(certificatePath),
        ], requestID: "trust.local-ca.remove")
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
                guard request.filePath != nil else {
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
        try ensureOwnedDirectory(directory, requestID: path)
        let temporary = "\(target).tmp.\(UUID().uuidString)"
        let descriptor = open(
            temporary,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            permissions
        )
        guard descriptor >= 0 else {
            throw NetworkingAuthorizationApplyError.commandFailed(
                path,
                String(cString: strerror(errno))
            )
        }
        var descriptorOpen = true
        defer {
            if descriptorOpen { close(descriptor) }
            _ = unlink(temporary)
        }
        try writeAll(
            descriptor: descriptor,
            bytes: Array(data),
            requestID: path
        )
        guard fchmod(descriptor, permissions) == 0, fsync(descriptor) == 0 else {
            let code = errno
            throw NetworkingAuthorizationApplyError.commandFailed(path, String(cString: strerror(code)))
        }
        close(descriptor)
        descriptorOpen = false
        if rename(temporary, target) != 0 {
            let code = errno
            throw NetworkingAuthorizationApplyError.commandFailed(path, String(cString: strerror(code)))
        }
        let directoryDescriptor = open(directory, O_RDONLY | O_CLOEXEC)
        if directoryDescriptor >= 0 {
            _ = fsync(directoryDescriptor)
            close(directoryDescriptor)
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

    private func ensureOwnedDirectory(_ directory: String, requestID: String) throws {
        if fileSystemRoot != "/" {
            try FileManager.default.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755]
            )
        } else if mkdir(directory, 0o755) != 0, errno != EEXIST {
            throw NetworkingAuthorizationApplyError.commandFailed(
                requestID,
                String(cString: strerror(errno))
            )
        }
        var info = stat()
        guard lstat(directory, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              fileSystemRoot != "/" || (info.st_uid == 0 && info.st_mode & 0o022 == 0) else {
            throw NetworkingAuthorizationApplyError.unsafeRequest(requestID)
        }
    }

    private func acquireMutationLock() throws -> Int32 {
        let path = rootedPath(Self.mutationLockPath)
        try ensureOwnedDirectory(
            (path as NSString).deletingLastPathComponent,
            requestID: Self.mutationLockPath
        )
        let descriptor = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw NetworkingAuthorizationApplyError.commandFailed(
                Self.mutationLockPath,
                String(cString: strerror(errno))
            )
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1,
              fileSystemRoot != "/" || info.st_uid == 0 else {
            close(descriptor)
            throw NetworkingAuthorizationApplyError.unsafeRequest(Self.mutationLockPath)
        }
        let deadline = Date().addingTimeInterval(15)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            guard code == EWOULDBLOCK, Date() < deadline else {
                close(descriptor)
                let message = code == EWOULDBLOCK
                    ? "timed out waiting for the networking mutation lock"
                    : String(cString: strerror(code))
                throw NetworkingAuthorizationApplyError.commandFailed(
                    Self.mutationLockPath,
                    message
                )
            }
            usleep(50_000)
        }
        return descriptor
    }

    private func releaseMutationLock(_ descriptor: Int32) {
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    private func isSafeRegularFile(_ path: String) throws -> Bool {
        try safeRegularFileOwner(path) != nil
    }

    private func safeRegularFileOwner(_ path: String) throws -> uid_t? {
        let descriptor = open(rootedPath(path), O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else {
            throw NetworkingAuthorizationApplyError.unsafeRequest(path)
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw NetworkingAuthorizationApplyError.unsafeRequest(path)
        }
        guard info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0,
              info.st_size <= Self.maximumManagedFileBytes else {
            return nil
        }
        return info.st_uid
    }

    private func readSafeRegularFile(
        path: String,
        requiredOwnerUID: uid_t?
    ) throws -> Data? {
        let descriptor = open(rootedPath(path), O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else {
            throw NetworkingAuthorizationApplyError.unsafeRequest(path)
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1,
              info.st_size > 0,
              info.st_size <= Self.maximumManagedFileBytes else {
            throw NetworkingAuthorizationApplyError.unsafeRequest(path)
        }
        if let requiredOwnerUID, info.st_uid != requiredOwnerUID {
            throw NetworkingAuthorizationApplyError.ownerMismatch(
                expected: requiredOwnerUID,
                actual: info.st_uid
            )
        }
        return try readAll(
            descriptor: descriptor,
            expectedBytes: Int(info.st_size),
            maximumBytes: Self.maximumManagedFileBytes,
            requestID: path
        )
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
        try ensureOwnedDirectory(directory, requestID: Self.pfTokenPath)
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

    @discardableResult
    private func releaseOwnedPFToken() throws -> Bool {
        guard let token = try readPFToken() else { return false }
        _ = try runOutput(
            ["/sbin/pfctl", "-X", token],
            requestID: "pf.dev.dory.disable"
        )
        try removeManagedFile(path: Self.pfTokenPath)
        return true
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

private struct NetworkingAuthorizationState: Codable {
    var version = 1
    var ownerUID: uid_t
    var plan: NetworkingAuthorizationPlan
}
