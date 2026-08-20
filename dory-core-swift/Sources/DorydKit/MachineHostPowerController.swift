import Darwin
import Foundation

/// Pauses running workspaces before host sleep and resumes only the workspaces paused by this
/// controller. The intent is durable so recreating doryd between the sleep and wake callbacks does
/// not turn a manually paused workspace into a running one or lose an automatic resume.
public final class MachineHostPowerController: HostSleepHandling, HostWakeHandling, @unchecked Sendable {
    private struct Record: Codable, Equatable {
        var schemaVersion: Int
        var machineIDs: [String]
    }

    private static let schemaVersion = 1
    private static let recordName = ".host-sleep-paused-v1.json"
    private let manager: MachineManager
    private let stateDirectory: String
    private let lock = NSLock()

    public init(manager: MachineManager, stateDirectory: String? = nil) {
        self.manager = manager
        self.stateDirectory = stateDirectory ?? manager.managedStateDirectory
    }

    public func prepareForHostSleep(now: Date) -> HostSleepActionResult {
        _ = now
        lock.lock()
        defer { lock.unlock() }

        let previous: Set<String>
        do {
            previous = Set(try readRecord()?.machineIDs ?? [])
        } catch {
            return HostSleepActionResult(
                name: "machines",
                attempted: true,
                slept: false,
                detail: "could not read durable host-sleep authority: \(error)"
            )
        }

        let newlyRunning = Set(manager.list().filter { $0.state == .running }.map(\.id))
        var pending = previous.union(newlyRunning)
        guard !pending.isEmpty else {
            return HostSleepActionResult(
                name: "machines",
                attempted: false,
                slept: false,
                detail: "no running machines"
            )
        }

        // Publish intent before sending SIGSTOP. A crash after this point may leave an ID whose
        // process is still running; wake recovery treats that as already recovered and never starts
        // a stopped workspace.
        do {
            try writeRecord(machineIDs: pending)
        } catch {
            return HostSleepActionResult(
                name: "machines",
                attempted: true,
                slept: false,
                detail: "could not persist host-sleep intent: \(error)"
            )
        }

        var failures: [String] = []
        for id in pending.sorted() {
            guard let status = manager.status(id: id) else {
                pending.remove(id)
                continue
            }
            if status.state == .paused {
                continue
            }
            guard status.state == .running else {
                pending.remove(id)
                continue
            }
            do {
                guard try manager.pause(id: id).state == .paused else {
                    failures.append("\(id): pause returned a non-paused state")
                    pending.remove(id)
                    continue
                }
            } catch {
                failures.append("\(id): \(error)")
                pending.remove(id)
            }
        }

        do {
            try writeRecord(machineIDs: pending)
        } catch {
            failures.append("could not commit paused-machine authority: \(error)")
        }
        return HostSleepActionResult(
            name: "machines",
            attempted: true,
            slept: failures.isEmpty,
            detail: "paused=\(pending.count)/\(newlyRunning.count)"
                + (failures.isEmpty ? "" : " errors=\(failures.joined(separator: "; "))")
        )
    }

    public func recoverAfterHostWake(now: Date) -> HostWakeActionResult {
        _ = now
        lock.lock()
        defer { lock.unlock() }

        var pending: Set<String>
        do {
            pending = Set(try readRecord()?.machineIDs ?? [])
        } catch {
            return HostWakeActionResult(
                name: "machines",
                attempted: true,
                recovered: false,
                detail: "could not read durable host-sleep authority: \(error)"
            )
        }
        guard !pending.isEmpty else {
            return HostWakeActionResult(
                name: "machines",
                attempted: false,
                recovered: true,
                detail: "no host-paused machines"
            )
        }

        let attemptedCount = pending.count
        var failures: [String] = []
        for id in pending.sorted() {
            guard let status = manager.status(id: id) else {
                pending.remove(id)
                continue
            }
            if status.state == .running {
                pending.remove(id)
                continue
            }
            guard status.state == .paused else {
                // Never start a stopped, failed, or otherwise non-resident workspace merely because
                // it was running before the host went to sleep.
                pending.remove(id)
                continue
            }
            do {
                guard try manager.resume(id: id).state == .running else {
                    failures.append("\(id): resume returned a non-running state")
                    continue
                }
                pending.remove(id)
            } catch {
                failures.append("\(id): \(error)")
            }
        }

        do {
            try writeRecord(machineIDs: pending)
        } catch {
            failures.append("could not retire host-sleep authority: \(error)")
        }
        return HostWakeActionResult(
            name: "machines",
            attempted: true,
            recovered: failures.isEmpty && pending.isEmpty,
            detail: "resumed=\(attemptedCount - pending.count)/\(attemptedCount)"
                + (failures.isEmpty ? "" : " errors=\(failures.joined(separator: "; "))")
        )
    }

    private var recordPath: String { stateDirectory + "/" + Self.recordName }

    private func readRecord() throws -> Record? {
        var statBuffer = stat()
        if lstat(recordPath, &statBuffer) != 0 {
            if errno == ENOENT { return nil }
            throw filesystem("inspect host-sleep record")
        }
        guard (statBuffer.st_mode & S_IFMT) == S_IFREG,
              statBuffer.st_uid == geteuid(),
              statBuffer.st_nlink == 1,
              statBuffer.st_mode & 0o077 == 0 else {
            throw filesystem("reject unsafe host-sleep record")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: recordPath), options: .mappedIfSafe)
        let record = try JSONDecoder().decode(Record.self, from: data)
        guard record.schemaVersion == Self.schemaVersion,
              record.machineIDs == Array(Set(record.machineIDs)).sorted(),
              record.machineIDs.allSatisfy(Self.isValidMachineID) else {
            throw filesystem("reject invalid host-sleep record")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard try encoder.encode(record) == data else {
            throw filesystem("reject non-canonical host-sleep record")
        }
        return record
    }

    private func writeRecord(machineIDs: Set<String>) throws {
        let sortedIDs = machineIDs.sorted()
        guard sortedIDs.allSatisfy(Self.isValidMachineID) else {
            throw filesystem("refuse invalid machine identifier")
        }
        if sortedIDs.isEmpty {
            if unlink(recordPath) != 0, errno != ENOENT {
                throw filesystem("remove host-sleep record")
            }
            try synchronizeDirectory()
            return
        }

        try FileManager.default.createDirectory(
            atPath: stateDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Record(
            schemaVersion: Self.schemaVersion,
            machineIDs: sortedIDs
        ))
        let temporaryPath = stateDirectory + "/.host-sleep-paused-v1.tmp-" + UUID().uuidString
        let descriptor = open(temporaryPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw filesystem("create host-sleep temporary record") }
        var shouldRemoveTemporary = true
        defer {
            _ = close(descriptor)
            if shouldRemoveTemporary { _ = unlink(temporaryPath) }
        }
        let wrote = data.withUnsafeBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return data.isEmpty }
            var offset = 0
            while offset < bytes.count {
                let result = write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if result < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += result
            }
            return true
        }
        guard wrote, fsync(descriptor) == 0 else {
            throw filesystem("write host-sleep record")
        }
        guard rename(temporaryPath, recordPath) == 0 else {
            throw filesystem("publish host-sleep record")
        }
        shouldRemoveTemporary = false
        try synchronizeDirectory()
    }

    private func synchronizeDirectory() throws {
        let descriptor = open(stateDirectory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw filesystem("open host-sleep record directory") }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else { throw filesystem("sync host-sleep record directory") }
    }

    private static func isValidMachineID(_ id: String) -> Bool {
        id.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9_.-]{0,62}/) != nil
    }

    private func filesystem(_ action: String) -> NSError {
        NSError(
            domain: "DoryMachineHostPowerController",
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: action + ": " + String(cString: strerror(errno))]
        )
    }
}
