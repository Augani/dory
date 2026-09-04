import CryptoKit
import Darwin
import DoryOperations
import Foundation

/// A private, inherited descriptor carries this launch secret to the helper. Keeping it out of
/// argv and the environment prevents ordinary process listings from becoming reconnect authority.
public enum DoryRuntimeReconnectContract {
    public static let authorityName = "runtime-reconnect-identity"
    public static let fileDescriptorArgument = "--runtime-reconnect-fd"
    public static let childFileDescriptor: Int32 = 20
    public static let maximumIdentityBytes = 16 * 1_024
}

public struct DoryRuntimeReconnectLaunchIdentity: Codable, Sendable, Equatable {
    public static let currentSchemaVersion: UInt16 = 1

    public var schemaVersion: UInt16
    public var machineID: String
    public var operationID: String
    public var resolvedPlanSHA256: String
    public var planRevision: UInt64
    public var secret: String

    public init(
        schemaVersion: UInt16 = Self.currentSchemaVersion,
        machineID: String,
        operationID: UUID,
        resolvedPlanSHA256: String,
        planRevision: UInt64,
        secret: String
    ) {
        self.schemaVersion = schemaVersion
        self.machineID = machineID
        self.operationID = DoryOperationIdentity.canonical(operationID)
        self.resolvedPlanSHA256 = resolvedPlanSHA256.lowercased()
        self.planRevision = planRevision
        self.secret = secret.lowercased()
    }

    public static func make(
        machineID: String,
        operationID: UUID,
        resolvedPlanSHA256: String,
        planRevision: UInt64
    ) -> Self {
        var bytes = [UInt8](repeating: 0, count: 32)
        var generator = SystemRandomNumberGenerator()
        for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max, using: &generator) }
        return Self(
            machineID: machineID,
            operationID: operationID,
            resolvedPlanSHA256: resolvedPlanSHA256,
            planRevision: planRevision,
            secret: bytes.map { String(format: "%02x", $0) }.joined()
        )
    }

    public var isValid: Bool {
        schemaVersion == Self.currentSchemaVersion
            && machineID.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9_.-]{0,62}/) != nil
            && !machineID.hasPrefix(".")
            && DoryOperationIdentity.parseCanonical(operationID) != nil
            && Self.isLowercaseHex(resolvedPlanSHA256, count: 64)
            && planRevision > 0
            && Self.isLowercaseHex(secret, count: 64)
    }

    public func encodedData() throws -> Data {
        guard isValid else { throw DoryRuntimeReconnectError.invalidIdentity }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func decode(fileDescriptor: Int32) throws -> Self {
        guard fileDescriptor >= 0 else { throw DoryRuntimeReconnectError.invalidDescriptor }
        var status = stat()
        guard fstat(fileDescriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == getuid(),
              status.st_nlink == 0,
              status.st_size > 0,
              status.st_size <= Self.maximumEncodedBytes else {
            throw DoryRuntimeReconnectError.invalidDescriptor
        }
        var data = Data(count: Int(status.st_size))
        let count = data.withUnsafeMutableBytes { raw in
            pread(fileDescriptor, raw.baseAddress, raw.count, 0)
        }
        guard count == data.count else { throw DoryRuntimeReconnectError.invalidDescriptor }
        let decoder = JSONDecoder()
        let identity = try decoder.decode(Self.self, from: data)
        guard identity.isValid, try identity.encodedData() == data else {
            throw DoryRuntimeReconnectError.invalidIdentity
        }
        return identity
    }

    public func proof(
        challenge: String,
        processIdentity: DoryHostProcessIdentity,
        runtimeState: DoryVirtualMachineState = .running
    ) throws -> String {
        guard isValid,
              Self.isLowercaseHex(challenge, count: 64),
              processIdentity.isValid else {
            throw DoryRuntimeReconnectError.invalidChallenge
        }
        let input = authenticationInput(
            challenge: challenge,
            processIdentity: processIdentity,
            runtimeState: runtimeState
        )
        let key = SymmetricKey(data: Data(Self.hexBytes(secret)))
        return HMAC<SHA256>.authenticationCode(
            for: Data(input.utf8), using: key
        ).map { String(format: "%02x", $0) }.joined()
    }

    public func verifies(
        proof: String,
        challenge: String,
        processIdentity: DoryHostProcessIdentity,
        runtimeState: DoryVirtualMachineState = .running
    ) -> Bool {
        guard isValid,
              Self.isLowercaseHex(challenge, count: 64),
              Self.isLowercaseHex(proof, count: 64),
              processIdentity.isValid else { return false }
        let key = SymmetricKey(data: Data(Self.hexBytes(secret)))
        return HMAC<SHA256>.isValidAuthenticationCode(
            Data(Self.hexBytes(proof)),
            authenticating: Data(authenticationInput(
                challenge: challenge,
                processIdentity: processIdentity,
                runtimeState: runtimeState
            ).utf8),
            using: key
        )
    }

    private func authenticationInput(
        challenge: String,
        processIdentity: DoryHostProcessIdentity,
        runtimeState: DoryVirtualMachineState
    ) -> String {
        [
            "dory-runtime-reconnect-v2",
            challenge,
            machineID,
            operationID,
            resolvedPlanSHA256,
            String(planRevision),
            String(processIdentity.processIdentifier),
            String(processIdentity.startTimeSeconds),
            String(processIdentity.startTimeMicroseconds),
            runtimeState.rawValue,
        ].joined(separator: "\n")
    }

    private static let maximumEncodedBytes = 16 * 1_024

    private static func isLowercaseHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private static func hexBytes(_ value: String) -> [UInt8] {
        guard value.utf8.count.isMultiple(of: 2) else { return [] }
        let bytes = Array(value.utf8)
        return stride(from: 0, to: bytes.count, by: 2).compactMap { index in
            func nibble(_ byte: UInt8) -> UInt8? {
                switch byte {
                case 48...57: byte - 48
                case 97...102: byte - 87
                default: nil
                }
            }
            guard let high = nibble(bytes[index]), let low = nibble(bytes[index + 1]) else {
                return nil
            }
            return high << 4 | low
        }
    }
}

public struct DoryHostProcessIdentity: Codable, Sendable, Equatable {
    public var processIdentifier: Int32
    public var startTimeSeconds: UInt64
    public var startTimeMicroseconds: UInt64

    public init(
        processIdentifier: Int32,
        startTimeSeconds: UInt64,
        startTimeMicroseconds: UInt64
    ) {
        self.processIdentifier = processIdentifier
        self.startTimeSeconds = startTimeSeconds
        self.startTimeMicroseconds = startTimeMicroseconds
    }

    public var isValid: Bool {
        processIdentifier > 1 && (startTimeSeconds > 0 || startTimeMicroseconds > 0)
    }

    public static func capture(processIdentifier: Int32 = getpid()) throws -> Self {
        guard processIdentifier > 1 else { throw DoryRuntimeReconnectError.invalidProcess }
        var info = proc_bsdinfo()
        let expected = Int32(MemoryLayout<proc_bsdinfo>.size)
        let bytes = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(processIdentifier, PROC_PIDTBSDINFO, 0, $0, expected)
        }
        guard bytes == expected else { throw DoryRuntimeReconnectError.invalidProcess }
        let identity = Self(
            processIdentifier: processIdentifier,
            startTimeSeconds: UInt64(info.pbi_start_tvsec),
            startTimeMicroseconds: UInt64(info.pbi_start_tvusec)
        )
        guard identity.isValid else { throw DoryRuntimeReconnectError.invalidProcess }
        return identity
    }

    public func matchesCurrentProcess() -> Bool {
        (try? Self.capture(processIdentifier: processIdentifier)) == self
    }
}

public struct DoryRuntimeReconnectResponse: Codable, Sendable, Equatable {
    public var identity: DoryHostProcessIdentity
    public var runtimeState: DoryVirtualMachineState
    public var machineID: String
    public var operationID: String
    public var resolvedPlanSHA256: String
    public var planRevision: UInt64
    public var proof: String

    public init(
        launchIdentity: DoryRuntimeReconnectLaunchIdentity,
        challenge: String,
        processIdentity: DoryHostProcessIdentity,
        runtimeState: DoryVirtualMachineState = .running
    ) throws {
        identity = processIdentity
        self.runtimeState = runtimeState
        machineID = launchIdentity.machineID
        operationID = launchIdentity.operationID
        resolvedPlanSHA256 = launchIdentity.resolvedPlanSHA256
        planRevision = launchIdentity.planRevision
        proof = try launchIdentity.proof(
            challenge: challenge,
            processIdentity: processIdentity,
            runtimeState: runtimeState
        )
    }

    public func matches(
        _ launchIdentity: DoryRuntimeReconnectLaunchIdentity,
        challenge: String
    ) -> Bool {
        identity.matchesCurrentProcess()
            && machineID == launchIdentity.machineID
            && operationID == launchIdentity.operationID
            && resolvedPlanSHA256 == launchIdentity.resolvedPlanSHA256
            && planRevision == launchIdentity.planRevision
            && launchIdentity.verifies(
                proof: proof,
                challenge: challenge,
                processIdentity: identity,
                runtimeState: runtimeState
            )
    }
}

public enum DoryRuntimeReconnectError: Error, CustomStringConvertible {
    case invalidDescriptor
    case invalidIdentity
    case invalidChallenge
    case invalidProcess
    case persistence(String)

    public var description: String {
        switch self {
        case .invalidDescriptor: "invalid runtime reconnect identity descriptor"
        case .invalidIdentity: "invalid runtime reconnect launch identity"
        case .invalidChallenge: "invalid runtime reconnect challenge"
        case .invalidProcess: "invalid runtime process generation"
        case .persistence(let detail): detail
        }
    }
}

public enum DoryRuntimeReconnectRecordState: String, Codable, Sendable {
    case pending
    case live
}

public struct DoryRuntimeReconnectRecord: Codable, Sendable, Equatable {
    public static let currentSchemaVersion: UInt16 = 1

    public var schemaVersion: UInt16
    public var state: DoryRuntimeReconnectRecordState
    public var launchIdentity: DoryRuntimeReconnectLaunchIdentity
    public var backend: DoryVirtualizationBackendIdentity
    public var executablePath: String
    public var processIdentity: DoryHostProcessIdentity?
    public var readiness: VmmReadyMessage?

    public var isValid: Bool {
        guard schemaVersion == Self.currentSchemaVersion,
              launchIdentity.isValid,
              executablePath.hasPrefix("/"), !executablePath.contains("\0") else { return false }
        switch state {
        case .pending:
            return processIdentity == nil && readiness == nil
        case .live:
            return processIdentity?.isValid == true
                && readiness?.machineID == launchIdentity.machineID
                && readiness?.operationID == launchIdentity.operationID
                && readiness?.controlSocketPath?.hasPrefix("/") == true
                && readiness?.hasValidOperationIdentity == true
        }
    }
}

/// Durable private authority used only to reconnect to an already-running helper after doryd
/// restarts. A record never authorizes launch, planning, or adoption without a live HMAC response.
public final class DoryRuntimeReconnectRecordStore: @unchecked Sendable {
    private let root: String
    private let lock = NSLock()

    public init(root stateDirectory: String) {
        root = URL(fileURLWithPath: stateDirectory, isDirectory: true)
            .appendingPathComponent(".runtime-reconnect", isDirectory: true).path
    }

    public func publishPending(
        identity: DoryRuntimeReconnectLaunchIdentity,
        backend: DoryVirtualizationBackendIdentity,
        executablePath: String
    ) throws {
        try write(DoryRuntimeReconnectRecord(
            schemaVersion: DoryRuntimeReconnectRecord.currentSchemaVersion,
            state: .pending,
            launchIdentity: identity,
            backend: backend,
            executablePath: URL(fileURLWithPath: executablePath).standardizedFileURL.path,
            processIdentity: nil,
            readiness: nil
        ))
    }

    public func publishLive(
        machineID: String,
        operationID: UUID,
        processIdentifier: Int32,
        readiness: VmmReadyMessage
    ) throws -> DoryRuntimeReconnectRecord {
        try lock.withLock {
            var record = try readUnlocked(machineID: machineID)
            guard record.state == .pending,
                  record.launchIdentity.operationID == DoryOperationIdentity.canonical(operationID),
                  readiness.operationID == record.launchIdentity.operationID else {
                throw DoryRuntimeReconnectError.persistence("runtime reconnect generation changed")
            }
            record.state = .live
            record.processIdentity = try DoryHostProcessIdentity.capture(
                processIdentifier: processIdentifier
            )
            record.readiness = readiness
            try writeUnlocked(record)
            return record
        }
    }

    public func read(machineID: String) throws -> DoryRuntimeReconnectRecord {
        try lock.withLock { try readUnlocked(machineID: machineID) }
    }

    public func liveRecords() throws -> [DoryRuntimeReconnectRecord] {
        try lock.withLock {
            guard FileManager.default.fileExists(atPath: root) else { return [] }
            let names = try FileManager.default.contentsOfDirectory(atPath: root)
                .filter { $0.hasSuffix(".json") }.sorted()
            return try names.map { name in
                try readUnlocked(machineID: String(name.dropLast(5)))
            }.filter { $0.state == .live }
        }
    }

    public func remove(machineID: String, operationID: UUID? = nil) throws {
        try lock.withLock {
            if let operationID {
                let current: DoryRuntimeReconnectRecord
                do { current = try readUnlocked(machineID: machineID) }
                catch let error as DoryRuntimeReconnectError {
                    if case .persistence(let detail) = error, detail == "runtime reconnect record is missing" {
                        return
                    }
                    throw error
                }
                guard current.launchIdentity.operationID
                        == DoryOperationIdentity.canonical(operationID) else { return }
            }
            let path = recordPath(machineID: machineID)
            if unlink(path) != 0, errno != ENOENT {
                throw DoryRuntimeReconnectError.persistence("could not remove runtime reconnect record")
            }
            if FileManager.default.fileExists(atPath: root) { try syncRoot() }
        }
    }

    private func write(_ record: DoryRuntimeReconnectRecord) throws {
        try lock.withLock { try writeUnlocked(record) }
    }

    private func writeUnlocked(_ record: DoryRuntimeReconnectRecord) throws {
        guard record.isValid else { throw DoryRuntimeReconnectError.invalidIdentity }
        try prepareRoot()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(record)
        let path = recordPath(machineID: record.launchIdentity.machineID)
        let temporary = path + ".tmp-" + UUID().uuidString.lowercased()
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw DoryRuntimeReconnectError.persistence("could not create runtime reconnect record")
        }
        var descriptorIsOpen = true
        defer {
            if descriptorIsOpen { Darwin.close(descriptor) }
        }
        do {
            try data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let count = Darwin.write(
                        descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset
                    )
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else {
                        throw DoryRuntimeReconnectError.persistence("could not write runtime reconnect record")
                    }
                    offset += count
                }
            }
            guard fsync(descriptor) == 0, Darwin.close(descriptor) == 0 else {
                throw DoryRuntimeReconnectError.persistence("could not publish runtime reconnect record")
            }
            descriptorIsOpen = false
            guard rename(temporary, path) == 0 else {
                throw DoryRuntimeReconnectError.persistence("could not publish runtime reconnect record")
            }
            try syncRoot()
        } catch {
            unlink(temporary)
            throw error
        }
    }

    private func readUnlocked(machineID: String) throws -> DoryRuntimeReconnectRecord {
        let path = recordPath(machineID: machineID)
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT {
                throw DoryRuntimeReconnectError.persistence("runtime reconnect record is missing")
            }
            throw DoryRuntimeReconnectError.persistence("could not open runtime reconnect record")
        }
        defer { Darwin.close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == getuid(), status.st_mode & 0o077 == 0,
              status.st_nlink == 1, status.st_size > 0, status.st_size <= 128 * 1_024 else {
            throw DoryRuntimeReconnectError.persistence("invalid runtime reconnect record authority")
        }
        var data = Data(count: Int(status.st_size))
        let wasRead = data.withUnsafeMutableBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.read(
                    descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        guard wasRead,
              let record = try? JSONDecoder().decode(DoryRuntimeReconnectRecord.self, from: data),
              record.isValid,
              record.launchIdentity.machineID == machineID else {
            throw DoryRuntimeReconnectError.persistence("invalid runtime reconnect record")
        }
        return record
    }

    private func prepareRoot() throws {
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        var status = stat()
        guard lstat(root, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == getuid(),
              status.st_nlink >= 2,
              chmod(root, 0o700) == 0 else {
            throw DoryRuntimeReconnectError.persistence("could not protect runtime reconnect directory")
        }
    }

    private func syncRoot() throws {
        let descriptor = open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw DoryRuntimeReconnectError.persistence("could not open runtime reconnect directory")
        }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw DoryRuntimeReconnectError.persistence("could not sync runtime reconnect directory")
        }
    }

    private func recordPath(machineID: String) -> String {
        root + "/" + machineID + ".json"
    }
}

public func makeRuntimeReconnectIdentityDescriptor(
    _ identity: DoryRuntimeReconnectLaunchIdentity
) throws -> HvProcessInheritedFileDescriptor {
    let data = try identity.encodedData()
    var template = Array((NSTemporaryDirectory() + "/dory-reconnect.XXXXXX").utf8CString)
    let writable = mkstemp(&template)
    guard writable >= 0 else { throw DoryRuntimeReconnectError.invalidDescriptor }
    let terminator = template.firstIndex(of: 0) ?? template.endIndex
    let path = String(decoding: template[..<terminator].map(UInt8.init(bitPattern:)), as: UTF8.self)
    defer { unlink(path) }
    var writableIsOpen = true
    defer {
        if writableIsOpen { Darwin.close(writable) }
    }
    do {
        guard fchmod(writable, 0o600) == 0 else {
            throw DoryRuntimeReconnectError.invalidDescriptor
        }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(
                    writable, raw.baseAddress!.advanced(by: offset), raw.count - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw DoryRuntimeReconnectError.invalidDescriptor }
                offset += count
            }
        }
        guard fsync(writable) == 0 else { throw DoryRuntimeReconnectError.invalidDescriptor }
        guard Darwin.close(writable) == 0 else {
            throw DoryRuntimeReconnectError.invalidDescriptor
        }
        writableIsOpen = false
        let readable = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard readable >= 0 else { throw DoryRuntimeReconnectError.invalidDescriptor }
        return HvProcessInheritedFileDescriptor(
            name: DoryRuntimeReconnectContract.authorityName,
            takingOwnershipOf: readable,
            childDescriptor: DoryRuntimeReconnectContract.childFileDescriptor
        )
    } catch {
        throw error
    }
}
