import Darwin
import Foundation

/// Exact renderer generation whose runtime health may influence a later automatic plan.
///
/// Suppression never keys on a path or on the source-tuple name alone. A rebuilt runner, changed
/// inventory, or changed worker executable is a new candidate and therefore receives a fresh
/// qualification opportunity.
struct DoryRendererCrashSuppressionCandidate: Codable, Hashable, Sendable {
    let runtimeBuildIdentifier: String
    let candidateInventorySHA256: String
    let rendererWorkerExecutableSHA256: String

    init(admission: DoryDaemonRendererAccelerationAdmission) {
        runtimeBuildIdentifier = admission.runtimeBuildIdentifier
        candidateInventorySHA256 = admission.candidateInventory.lowercaseSHA256
        rendererWorkerExecutableSHA256 =
            admission.rendererWorkerExecutable.lowercaseSHA256
    }

    init?(plan: DoryResolvedMachinePlan) throws {
        guard plan.backend == .doryHypervisor,
              plan.graphics == .hardwareAccelerated3D else { return nil }
        self.init(admission: try DoryDaemonRendererAccelerationAdmission.recovering(
            runtimeBuildIdentifier: plan.backendRuntimeBuildIdentifier,
            components: plan.components
        ))
    }

    var isValid: Bool {
        guard runtimeBuildIdentifier.hasPrefix("sha256:") else { return false }
        let runtimeDigest = String(runtimeBuildIdentifier.dropFirst("sha256:".count))
        return Self.isLowercaseSHA256(runtimeDigest)
            && Self.isLowercaseSHA256(candidateInventorySHA256)
            && Self.isLowercaseSHA256(rendererWorkerExecutableSHA256)
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
            && value.contains(where: { $0 != "0" })
    }
}

/// Durable, candidate-bound circuit breaker for renderer failures classified by dory-hv.
///
/// A renderer crash suppresses the exact candidate for a bounded interval. Production planning
/// then sees acceleration as unavailable: an automatic graphics policy can select its declared
/// software recovery candidate, while a hardware-only policy receives a normal unsupported-plan
/// error. Corrupt health state fails acceleration closed but never prevents software Linux.
final class DoryRendererCrashSuppressionStore: @unchecked Sendable {
    static let defaultSuppressionInterval: TimeInterval = 6 * 60 * 60

    private static let fileName = ".renderer-runtime-health-v1.json"
    private static let maximumEncodedBytes = 64 * 1_024
    private static let maximumFailureCount: UInt32 = 1_000_000

    private struct Record: Codable, Equatable {
        var candidate: DoryRendererCrashSuppressionCandidate
        var failureCount: UInt32
        var lastFailureUnixMilliseconds: Int64
        var suppressedUntilUnixMilliseconds: Int64
    }

    private struct Snapshot: Codable, Equatable {
        static let schemaVersion: UInt16 = 1

        var schemaVersion: UInt16 = Self.schemaVersion
        var records: [Record]

        func isValid() -> Bool {
            guard schemaVersion == Self.schemaVersion,
                  records.count <= 128,
                  Set(records.map(\.candidate)).count == records.count else {
                return false
            }
            return records.allSatisfy {
                $0.candidate.isValid
                    && $0.failureCount > 0
                    && $0.failureCount <= DoryRendererCrashSuppressionStore.maximumFailureCount
                    && $0.suppressedUntilUnixMilliseconds > $0.lastFailureUnixMilliseconds
            }
        }
    }

    private let root: String
    private let path: String
    private let suppressionInterval: TimeInterval
    private let now: @Sendable () -> Date
    private let lock = NSLock()

    init(
        stateDirectory: String,
        suppressionInterval: TimeInterval = defaultSuppressionInterval,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        let canonical = URL(fileURLWithPath: stateDirectory).standardizedFileURL.path
        root = canonical
        path = canonical + "/" + Self.fileName
        self.suppressionInterval = max(60, suppressionInterval)
        self.now = now
    }

    func isSuppressed(_ admission: DoryDaemonRendererAccelerationAdmission) -> Bool {
        isSuppressed(DoryRendererCrashSuppressionCandidate(admission: admission))
    }

    func isSuppressed(_ candidate: DoryRendererCrashSuppressionCandidate) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard candidate.isValid else { return true }
        do {
            let snapshot = try loadLocked()
            let timestamp = Self.unixMilliseconds(now())
            return snapshot.records.contains {
                $0.candidate == candidate
                    && $0.suppressedUntilUnixMilliseconds > timestamp
            }
        } catch {
            // Health evidence is never positive acceleration authority. If it cannot be decoded,
            // retain the software baseline and require repair before this candidate is retried.
            return true
        }
    }

    func recordFailure(_ candidate: DoryRendererCrashSuppressionCandidate) throws {
        guard candidate.isValid else {
            throw DoryRendererCrashSuppressionError.invalidCandidate
        }
        lock.lock()
        defer { lock.unlock() }

        let failureTime = Self.unixMilliseconds(now())
        let intervalMilliseconds = Int64(
            min(suppressionInterval * 1_000, Double(Int64.max))
        )
        let suppressionEnd = failureTime.addingReportingOverflow(intervalMilliseconds)
        guard !suppressionEnd.overflow else {
            throw DoryRendererCrashSuppressionError.invalidClock
        }

        // A corrupt prior snapshot is already fail-closed. Replace it only while recording a new
        // observed renderer failure, which preserves the safety decision and restores canonical
        // state for later planning.
        var snapshot = (try? loadLocked()) ?? Snapshot(records: [])
        snapshot.records.removeAll {
            $0.suppressedUntilUnixMilliseconds <= failureTime
                && $0.candidate != candidate
        }
        if let index = snapshot.records.firstIndex(where: { $0.candidate == candidate }) {
            snapshot.records[index].failureCount = min(
                Self.maximumFailureCount,
                snapshot.records[index].failureCount &+ 1
            )
            snapshot.records[index].lastFailureUnixMilliseconds = failureTime
            snapshot.records[index].suppressedUntilUnixMilliseconds = suppressionEnd.partialValue
        } else {
            snapshot.records.append(Record(
                candidate: candidate,
                failureCount: 1,
                lastFailureUnixMilliseconds: failureTime,
                suppressedUntilUnixMilliseconds: suppressionEnd.partialValue
            ))
        }
        snapshot.records.sort {
            if $0.candidate.runtimeBuildIdentifier != $1.candidate.runtimeBuildIdentifier {
                return $0.candidate.runtimeBuildIdentifier
                    < $1.candidate.runtimeBuildIdentifier
            }
            if $0.candidate.candidateInventorySHA256
                != $1.candidate.candidateInventorySHA256 {
                return $0.candidate.candidateInventorySHA256
                    < $1.candidate.candidateInventorySHA256
            }
            return $0.candidate.rendererWorkerExecutableSHA256
                < $1.candidate.rendererWorkerExecutableSHA256
        }
        guard snapshot.isValid() else {
            throw DoryRendererCrashSuppressionError.invalidSnapshot
        }
        try writeLocked(snapshot)
    }

    /// Clears stale failure history only after the same exact candidate has reached the accepted
    /// VM readiness boundary. This lets a deliberate retry recover without weakening a pending
    /// suppression before a real synchronized frame exists.
    func recordSuccessfulReadiness(
        _ candidate: DoryRendererCrashSuppressionCandidate
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        var snapshot = try loadLocked()
        let originalCount = snapshot.records.count
        snapshot.records.removeAll { $0.candidate == candidate }
        guard snapshot.records.count != originalCount else { return }
        try writeLocked(snapshot)
    }

    private func loadLocked() throws -> Snapshot {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        if descriptor < 0, errno == ENOENT {
            return Snapshot(records: [])
        }
        guard descriptor >= 0 else {
            throw DoryRendererCrashSuppressionError.readFailed
        }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == geteuid(),
              status.st_nlink == 1,
              status.st_mode & (S_IWGRP | S_IWOTH) == 0,
              status.st_size > 0,
              status.st_size <= Self.maximumEncodedBytes else {
            throw DoryRendererCrashSuppressionError.readFailed
        }
        var data = Data(count: Int(status.st_size))
        try data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else {
                throw DoryRendererCrashSuppressionError.readFailed
            }
            var offset = 0
            while offset < raw.count {
                let count = pread(
                    descriptor,
                    base.advanced(by: offset),
                    raw.count - offset,
                    off_t(offset)
                )
                if count > 0 { offset += count }
                else if count < 0, errno == EINTR { continue }
                else { throw DoryRendererCrashSuppressionError.readFailed }
            }
        }
        let decoder = JSONDecoder()
        guard let snapshot = try? decoder.decode(Snapshot.self, from: data),
              snapshot.isValid(),
              data == (try? Self.canonicalData(snapshot)) else {
            throw DoryRendererCrashSuppressionError.invalidSnapshot
        }
        return snapshot
    }

    private func writeLocked(_ snapshot: Snapshot) throws {
        let data = try Self.canonicalData(snapshot)
        guard data.count <= Self.maximumEncodedBytes else {
            throw DoryRendererCrashSuppressionError.invalidSnapshot
        }
        try FileManager.default.createDirectory(
            atPath: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let temporary = root + "/." + Self.fileName + "." + UUID().uuidString + ".tmp"
        let descriptor = open(
            temporary,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw DoryRendererCrashSuppressionError.writeFailed
        }
        var shouldRemove = true
        defer {
            close(descriptor)
            if shouldRemove { unlink(temporary) }
        }
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else {
                throw DoryRendererCrashSuppressionError.writeFailed
            }
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    raw.count - offset
                )
                if count > 0 { offset += count }
                else if count < 0, errno == EINTR { continue }
                else { throw DoryRendererCrashSuppressionError.writeFailed }
            }
        }
        guard fsync(descriptor) == 0,
              rename(temporary, path) == 0 else {
            throw DoryRendererCrashSuppressionError.writeFailed
        }
        shouldRemove = false
        let directory = open(root, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directory >= 0 else {
            throw DoryRendererCrashSuppressionError.writeFailed
        }
        defer { close(directory) }
        guard fsync(directory) == 0 else {
            throw DoryRendererCrashSuppressionError.writeFailed
        }
    }

    private static func canonicalData(_ snapshot: Snapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(snapshot) + Data("\n".utf8)
    }

    private static func unixMilliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded(.towardZero))
    }
}

enum DoryRendererCrashSuppressionError: Error, Equatable {
    case invalidCandidate
    case invalidClock
    case invalidSnapshot
    case readFailed
    case writeFailed
}
