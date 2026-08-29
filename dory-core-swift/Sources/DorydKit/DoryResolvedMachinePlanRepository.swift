import CryptoKit
import Darwin
import Foundation

public enum DoryResolvedMachinePlanRepositoryError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidMachineIdentifier(String)
    case invalidPlan([DoryResolvedMachinePlanValidationIssue])
    case planExists(String)
    case planNotFound(String)
    case stalePlanRevision(expected: UInt64, actual: UInt64)
    case invalidPlanRevision(expected: UInt64, actual: UInt64)
    case machineIdentityChanged(String)
    case invalidRecord(String)
    case filesystem(String)

    public var description: String {
        switch self {
        case let .invalidMachineIdentifier(id):
            "invalid resolved-plan machine identifier: \(id)"
        case let .invalidPlan(issues):
            "invalid resolved plan: "
                + issues.map { "\($0.code.rawValue) at \($0.field)" }.joined(separator: ", ")
        case let .planExists(id):
            "resolved plan already exists: \(id)"
        case let .planNotFound(id):
            "resolved plan does not exist: \(id)"
        case let .stalePlanRevision(expected, actual):
            "stale resolved-plan revision: expected \(expected), found \(actual)"
        case let .invalidPlanRevision(expected, actual):
            "invalid replacement plan revision: expected \(expected), found \(actual)"
        case let .machineIdentityChanged(id):
            "resolved-plan machine identity cannot change: \(id)"
        case let .invalidRecord(path):
            "invalid resolved-plan repository record: \(path)"
        case let .filesystem(message):
            message
        }
    }
}

private struct DoryResolvedMachinePlanRepositoryCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) { nil }
}

/// Integrity envelope for a resolved plan.
///
/// Record schema v1 has no integrity digest. Record schema v2 is the historical, pretty-printed
/// integrity envelope and is accepted only for pre-schema-v5 plans that require replanning.
/// Record schema v3 is the canonical, compact JSON authority used for current plans.
public struct DoryResolvedMachinePlanRepositoryRecord: Codable, Sendable, Equatable {
    public static let oldestSupportedSchemaVersion: UInt16 = 1
    public static let legacyIntegritySchemaVersion: UInt16 = 2
    public static let currentSchemaVersion: UInt16 = 3

    public var schemaVersion: UInt16
    public var planSHA256: String?
    public var plan: DoryResolvedMachinePlan

    public init(planSHA256: String, plan: DoryResolvedMachinePlan) {
        schemaVersion = Self.currentSchemaVersion
        self.planSHA256 = planSHA256
        self.plan = plan
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case planSHA256
        case plan
    }

    public init(from decoder: Decoder) throws {
        let rawContainer = try decoder.container(
            keyedBy: DoryResolvedMachinePlanRepositoryCodingKey.self
        )
        let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))
        guard rawContainer.allKeys.allSatisfy({ knownKeys.contains($0.stringValue) }) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unknown resolved-plan repository record field."
                )
            )
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(UInt16.self, forKey: .schemaVersion)
        guard schemaVersion == Self.oldestSupportedSchemaVersion
                || schemaVersion == Self.legacyIntegritySchemaVersion
                || schemaVersion == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported resolved-plan record schema \(schemaVersion)."
            )
        }
        planSHA256 = try container.decodeIfPresent(String.self, forKey: .planSHA256)
        plan = try container.decode(DoryResolvedMachinePlan.self, forKey: .plan)
    }
}

/// Crash-safe, owner-only persistence for daemon-resolved runtime plans.
public final class DoryResolvedMachinePlanRepository: @unchecked Sendable {
    public static let recordFileName = "resolved-plan.json"

    private static let temporaryPrefix = ".resolved-plan."
    private static let maximumRecordBytes = 4 * 1_024 * 1_024

    public let root: String
    private let lock = NSLock()

    public init(root: String) {
        self.root = URL(fileURLWithPath: root).standardizedFileURL.path
    }

    public func create(_ plan: DoryResolvedMachinePlan) throws {
        lock.lock()
        defer { lock.unlock() }
        try Self.validateCurrentPlan(plan)
        guard plan.planRevision == 1 else {
            throw DoryResolvedMachinePlanRepositoryError.invalidPlanRevision(
                expected: 1,
                actual: plan.planRevision
            )
        }
        let path = try prepareMachineDirectory(id: plan.machineID)
            + "/\(Self.recordFileName)"
        guard !Self.pathExists(path) else {
            throw DoryResolvedMachinePlanRepositoryError.planExists(plan.machineID)
        }
        try publish(plan, path: path, replacing: false)
    }

    public func replace(
        _ plan: DoryResolvedMachinePlan,
        expectedPlanRevision: UInt64
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        try Self.validateCurrentPlan(plan)
        let current = try readRecordUnlocked(id: plan.machineID).plan
        guard current.planRevision == expectedPlanRevision else {
            throw DoryResolvedMachinePlanRepositoryError.stalePlanRevision(
                expected: expectedPlanRevision,
                actual: current.planRevision
            )
        }
        guard expectedPlanRevision < UInt64.max,
              plan.planRevision == expectedPlanRevision + 1 else {
            throw DoryResolvedMachinePlanRepositoryError.invalidPlanRevision(
                expected: expectedPlanRevision == UInt64.max
                    ? UInt64.max
                    : expectedPlanRevision + 1,
                actual: plan.planRevision
            )
        }
        guard plan.machineID == current.machineID,
              plan.createdAtUnixMilliseconds == current.createdAtUnixMilliseconds else {
            throw DoryResolvedMachinePlanRepositoryError.machineIdentityChanged(plan.machineID)
        }
        try publish(plan, path: recordPath(id: plan.machineID), replacing: true)
    }

    public func read(id: String) throws -> DoryResolvedMachinePlan {
        lock.lock()
        defer { lock.unlock() }
        return try readRecordUnlocked(id: id).plan
    }

    public func remove(id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try Self.validateMachineIdentifier(id)
        let path = recordPath(id: id)
        guard Self.pathExists(path) else {
            throw DoryResolvedMachinePlanRepositoryError.planNotFound(id)
        }
        _ = try Self.secureRead(path: path)
        guard unlink(path) == 0 else {
            throw DoryResolvedMachinePlanRepositoryError.filesystem(
                "remove resolved plan at \(path): \(String(cString: strerror(errno)))"
            )
        }
        try Self.fsyncDirectory(machineDirectory(id: id))
    }

    private func readRecordUnlocked(id: String) throws -> DoryResolvedMachinePlanRepositoryRecord {
        try Self.validateMachineIdentifier(id)
        let path = recordPath(id: id)
        guard Self.pathExists(path) else {
            throw DoryResolvedMachinePlanRepositoryError.planNotFound(id)
        }
        let data = try Self.secureRead(path: path)
        guard let authority = Self.persistedAuthority(recordData: data) else {
            throw DoryResolvedMachinePlanRepositoryError.invalidRecord(path)
        }
        let record: DoryResolvedMachinePlanRepositoryRecord
        do {
            record = try JSONDecoder().decode(DoryResolvedMachinePlanRepositoryRecord.self, from: data)
        } catch {
            throw DoryResolvedMachinePlanRepositoryError.invalidRecord(path)
        }
        guard record.plan.machineID == id else {
            throw DoryResolvedMachinePlanRepositoryError.invalidRecord(path)
        }
        switch record.schemaVersion {
        case DoryResolvedMachinePlanRepositoryRecord.oldestSupportedSchemaVersion:
            guard authority.planSchemaVersion
                    == DoryResolvedMachinePlan.oldestSupportedSchemaVersion,
                  record.plan.sourceSchemaVersion
                    == DoryResolvedMachinePlan.oldestSupportedSchemaVersion,
                  record.plan.migrationDisposition == .requiresReplanning,
                  record.planSHA256 == nil else {
                throw DoryResolvedMachinePlanRepositoryError.invalidRecord(path)
            }
        case DoryResolvedMachinePlanRepositoryRecord.legacyIntegritySchemaVersion:
            guard let expected = record.planSHA256,
                  Self.isSHA256(expected),
                  expected == Self.sha256(authority.canonicalPlanData),
                  record.plan.sourceSchemaVersion == authority.planSchemaVersion,
                  record.plan.migrationDisposition == .requiresReplanning,
                  Self.isHistoricallyValidMigrationPlan(
                      record.plan,
                      persistedSchemaVersion: authority.planSchemaVersion
                  ) else {
                throw DoryResolvedMachinePlanRepositoryError.invalidRecord(path)
            }
        case DoryResolvedMachinePlanRepositoryRecord.currentSchemaVersion:
            guard authority.planSchemaVersion == DoryResolvedMachinePlan.currentSchemaVersion,
                  let expected = record.planSHA256,
                  Self.isSHA256(expected),
                  expected == Self.sha256(authority.canonicalPlanData),
                  let decodedCanonicalPlanData = try? Self.canonicalEncodedPlanData(record.plan),
                  decodedCanonicalPlanData == authority.canonicalPlanData,
                  record.plan.sourceSchemaVersion == DoryResolvedMachinePlan.currentSchemaVersion,
                  record.plan.migrationDisposition == .current,
                  record.plan.validate().isEmpty else {
                throw DoryResolvedMachinePlanRepositoryError.invalidRecord(path)
            }
        default:
            throw DoryResolvedMachinePlanRepositoryError.invalidRecord(path)
        }
        return record
    }

    private func prepareMachineDirectory(id: String) throws -> String {
        try Self.validateMachineIdentifier(id)
        try Self.preparePrivateDirectory(root)
        let directory = machineDirectory(id: id)
        try Self.preparePrivateDirectory(directory)
        return directory
    }

    private func machineDirectory(id: String) -> String { root + "/" + id }

    private func recordPath(id: String) -> String {
        machineDirectory(id: id) + "/" + Self.recordFileName
    }

    private func publish(
        _ plan: DoryResolvedMachinePlan,
        path: String,
        replacing: Bool
    ) throws {
        let data: Data
        do {
            let encodedPlan = try JSONEncoder().encode(plan)
            guard let planObject = try JSONSerialization.jsonObject(
                with: encodedPlan
            ) as? [String: Any] else {
                throw DoryResolvedMachinePlanRepositoryError.invalidRecord(path)
            }
            let canonicalPlanData = try Self.canonicalJSONData(planObject)
            data = try Self.canonicalJSONData([
                "plan": planObject,
                "planSHA256": Self.sha256(canonicalPlanData),
                "schemaVersion": Int(
                    DoryResolvedMachinePlanRepositoryRecord.currentSchemaVersion
                ),
            ])
        } catch let error as DoryResolvedMachinePlanRepositoryError {
            throw error
        } catch {
            throw DoryResolvedMachinePlanRepositoryError.filesystem(
                "encode resolved plan for \(plan.machineID): \(error)"
            )
        }
        guard !data.isEmpty, data.count <= Self.maximumRecordBytes else {
            throw DoryResolvedMachinePlanRepositoryError.invalidRecord(path)
        }

        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let temporaryPath = directory + "/\(Self.temporaryPrefix)\(UUID().uuidString.lowercased())"
        let descriptor = open(
            temporaryPath,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw DoryResolvedMachinePlanRepositoryError.filesystem(
                "create resolved-plan temporary record at \(temporaryPath): "
                    + String(cString: strerror(errno))
            )
        }
        var shouldRemoveTemporary = true
        defer {
            _ = close(descriptor)
            if shouldRemoveTemporary { _ = unlink(temporaryPath) }
        }
        do {
            try data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var written = 0
                while written < data.count {
                    let count = Darwin.write(
                        descriptor,
                        base.advanced(by: written),
                        data.count - written
                    )
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else {
                        throw DoryResolvedMachinePlanRepositoryError.filesystem(
                            "write resolved-plan temporary record at \(temporaryPath): "
                                + String(cString: strerror(errno))
                        )
                    }
                    written += count
                }
            }
            guard fsync(descriptor) == 0 else {
                throw DoryResolvedMachinePlanRepositoryError.filesystem(
                    "fsync resolved-plan temporary record at \(temporaryPath): "
                        + String(cString: strerror(errno))
                )
            }
            if replacing {
                guard rename(temporaryPath, path) == 0 else {
                    throw DoryResolvedMachinePlanRepositoryError.filesystem(
                        "publish resolved plan at \(path): \(String(cString: strerror(errno)))"
                    )
                }
            } else {
                guard link(temporaryPath, path) == 0 else {
                    if errno == EEXIST {
                        throw DoryResolvedMachinePlanRepositoryError.planExists(plan.machineID)
                    }
                    throw DoryResolvedMachinePlanRepositoryError.filesystem(
                        "publish resolved plan at \(path): \(String(cString: strerror(errno)))"
                    )
                }
                guard unlink(temporaryPath) == 0 else {
                    _ = unlink(path)
                    throw DoryResolvedMachinePlanRepositoryError.filesystem(
                        "remove resolved-plan temporary record at \(temporaryPath): "
                            + String(cString: strerror(errno))
                    )
                }
            }
            shouldRemoveTemporary = false
            try Self.fsyncDirectory(directory)
        } catch let error as DoryResolvedMachinePlanRepositoryError {
            throw error
        } catch {
            throw DoryResolvedMachinePlanRepositoryError.filesystem(
                "publish resolved plan at \(path): \(error)"
            )
        }
    }

    private static func validateCurrentPlan(_ plan: DoryResolvedMachinePlan) throws {
        let issues = plan.validate()
        guard issues.isEmpty else {
            throw DoryResolvedMachinePlanRepositoryError.invalidPlan(issues)
        }
    }

    private static func validateMachineIdentifier(_ id: String) throws {
        guard DoryResolvedMachinePlan.isSafeIdentifier(id) else {
            throw DoryResolvedMachinePlanRepositoryError.invalidMachineIdentifier(id)
        }
    }

    private static func preparePrivateDirectory(_ path: String) throws {
        if !pathExists(path) {
            do {
                try FileManager.default.createDirectory(
                    atPath: path,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw DoryResolvedMachinePlanRepositoryError.filesystem(
                    "create resolved-plan directory at \(path): \(error)"
                )
            }
            _ = chmod(path, mode_t(0o700))
        }
        var info = stat()
        guard lstat(path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(),
              (info.st_mode & 0o077) == 0 else {
            throw DoryResolvedMachinePlanRepositoryError.invalidRecord(path)
        }
    }

    private static func secureRead(path: String) throws -> Data {
        var before = stat()
        guard lstat(path, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFREG,
              before.st_uid == getuid(),
              before.st_nlink == 1,
              (before.st_mode & 0o077) == 0,
              before.st_size > 0,
              before.st_size <= maximumRecordBytes else {
            throw DoryResolvedMachinePlanRepositoryError.invalidRecord(path)
        }
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw DoryResolvedMachinePlanRepositoryError.invalidRecord(path)
        }
        defer { _ = close(descriptor) }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size else {
            throw DoryResolvedMachinePlanRepositoryError.invalidRecord(path)
        }
        do {
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            let data = try handle.read(upToCount: maximumRecordBytes + 1) ?? Data()
            guard !data.isEmpty,
                  data.count <= maximumRecordBytes,
                  data.count == Int(after.st_size) else {
                throw DoryResolvedMachinePlanRepositoryError.invalidRecord(path)
            }
            return data
        } catch let error as DoryResolvedMachinePlanRepositoryError {
            throw error
        } catch {
            throw DoryResolvedMachinePlanRepositoryError.filesystem(
                "read resolved plan at \(path): \(error)"
            )
        }
    }

    private static func fsyncDirectory(_ path: String) throws {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw DoryResolvedMachinePlanRepositoryError.filesystem(
                "open resolved-plan directory at \(path): \(String(cString: strerror(errno)))"
            )
        }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw DoryResolvedMachinePlanRepositoryError.filesystem(
                "fsync resolved-plan directory at \(path): \(String(cString: strerror(errno)))"
            )
        }
    }

    private struct PersistedAuthority {
        var planSchemaVersion: UInt16
        var canonicalPlanData: Data
    }

    /// Parses the untyped wire authority before `Codable` is allowed to synthesize migration
    /// state. Current records must be byte-for-byte canonical. The only noncanonical exception is
    /// the historical record wrapper, which is authenticated using its original compact/sorted
    /// nested-plan digest and can only produce a non-runnable migration value.
    private static func persistedAuthority(recordData: Data) -> PersistedAuthority? {
        guard let root = try? JSONSerialization.jsonObject(with: recordData) as? [String: Any],
              let recordSchemaVersion = exactUInt16(root["schemaVersion"]),
              let planObject = root["plan"] as? [String: Any],
              let planSchemaVersion = exactUInt16(planObject["schemaVersion"]),
              hasOnlyAllowedPlanKeys(planObject, schemaVersion: planSchemaVersion),
              let canonicalPlanData = try? canonicalJSONData(planObject) else {
            return nil
        }

        switch recordSchemaVersion {
        case DoryResolvedMachinePlanRepositoryRecord.oldestSupportedSchemaVersion:
            guard Set(root.keys) == ["plan", "schemaVersion"],
                  planSchemaVersion == DoryResolvedMachinePlan.oldestSupportedSchemaVersion else {
                return nil
            }
        case DoryResolvedMachinePlanRepositoryRecord.legacyIntegritySchemaVersion:
            guard Set(root.keys) == ["plan", "planSHA256", "schemaVersion"],
                  (2...4).contains(planSchemaVersion),
                  exactUInt16(planObject["sourceSchemaVersion"]) == planSchemaVersion,
                  planObject["migrationDisposition"] as? String
                    == DoryResolvedMachinePlanMigrationDisposition.current.rawValue else {
                return nil
            }
        case DoryResolvedMachinePlanRepositoryRecord.currentSchemaVersion:
            guard Set(root.keys) == ["plan", "planSHA256", "schemaVersion"],
                  planSchemaVersion == DoryResolvedMachinePlan.currentSchemaVersion,
                  exactUInt16(planObject["sourceSchemaVersion"])
                    == DoryResolvedMachinePlan.currentSchemaVersion,
                  planObject["migrationDisposition"] as? String
                    == DoryResolvedMachinePlanMigrationDisposition.current.rawValue,
                  let canonicalRecordData = try? canonicalJSONData(root),
                  canonicalRecordData == recordData else {
                return nil
            }
        default:
            return nil
        }
        return PersistedAuthority(
            planSchemaVersion: planSchemaVersion,
            canonicalPlanData: canonicalPlanData
        )
    }

    private static func canonicalJSONData(_ object: Any) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw CocoaError(.propertyListWriteInvalid)
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func canonicalEncodedPlanData(
        _ plan: DoryResolvedMachinePlan
    ) throws -> Data {
        let encoded = try JSONEncoder().encode(plan)
        let object = try JSONSerialization.jsonObject(with: encoded)
        return try canonicalJSONData(object)
    }

    private static func exactUInt16(_ value: Any?) -> UInt16? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              number.doubleValue.rounded(.towardZero) == number.doubleValue,
              number.doubleValue >= 0,
              number.doubleValue <= Double(UInt16.max) else {
            return nil
        }
        return UInt16(number.doubleValue)
    }

    private static func hasOnlyAllowedPlanKeys(
        _ plan: [String: Any],
        schemaVersion: UInt16
    ) -> Bool {
        let versionOne: Set<String> = [
            "schemaVersion", "machineID", "definitionRevision", "planRevision",
            "createdAtUnixMilliseconds", "updatedAtUnixMilliseconds", "guest", "backend",
            "backendRuntimeBuildID", "virtualHardwareABIVersion", "bootMedia",
            "componentDigests", "devices", "graphics",
        ]
        var modern: Set<String> = [
            "schemaVersion", "sourceSchemaVersion", "migrationDisposition", "machineID",
            "definitionRevision", "definitionSHA256", "planRevision",
            "createdAtUnixMilliseconds", "updatedAtUnixMilliseconds", "guest", "backend",
            "backendImplementationIdentifier", "backendRuntimeBuildIdentifier",
            "virtualHardwareABIVersion", "bootMedia", "components", "devices", "graphics",
            "supportTier", "selectionEvidence", "qualificationEvidence", "resourceAdmission",
            "hostQualification", "experimentalAuthorization",
        ]
        switch schemaVersion {
        case 1:
            return Set(plan.keys).isSubset(of: versionOne)
        case 2:
            break
        case 3:
            modern.insert("launchArtifacts")
        case 4:
            modern.formUnion(["launchArtifacts", "portForwards"])
        case DoryResolvedMachinePlan.currentSchemaVersion:
            modern.formUnion([
                "launchArtifacts", "portForwards", "rawHVVirtualHardwareTopology",
            ])
        default:
            return false
        }
        return Set(plan.keys).isSubset(of: modern)
    }

    private static func isHistoricallyValidMigrationPlan(
        _ plan: DoryResolvedMachinePlan,
        persistedSchemaVersion: UInt16
    ) -> Bool {
        guard (2...4).contains(persistedSchemaVersion),
              plan.sourceSchemaVersion == persistedSchemaVersion,
              plan.migrationDisposition == .requiresReplanning,
              plan.rawHVVirtualHardwareTopology == nil else {
            return false
        }
        var allowed: Set<DoryResolvedMachinePlanValidationCode> = [
            .legacyPlanRequiresReplanning,
            .invalidVirtualHardwareTopology,
        ]
        if persistedSchemaVersion < 4 {
            allowed.insert(.invalidLaunchArtifactEvidence)
        }
        let codes = Set(plan.validate().map(\.code))
        return codes.contains(.legacyPlanRequiresReplanning)
            && codes.isSubset(of: allowed)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isSHA256(_ value: String) -> Bool {
        DoryResolvedMachinePlan.isSHA256(value)
    }

    private static func pathExists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }
}
