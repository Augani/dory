import Darwin
import Foundation

public enum HelperProcessJanitor {
    public static func terminateStaleHelpers(
        executablePath: String,
        stateDirectory: String,
        includeDescendants: Bool = false,
        timeout: TimeInterval = 2,
        psOutputProvider: (() -> String?)? = nil
    ) -> [Int32] {
        guard let output = (psOutputProvider ?? processList)() else { return [] }
        let pids = staleHelperPIDs(
            executablePath: executablePath,
            stateDirectory: stateDirectory,
            includeDescendants: includeDescendants,
            psOutput: output
        )
        guard !pids.isEmpty else { return [] }

        for pid in pids {
            _ = kill(pid, SIGTERM)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, pids.contains(where: isProcessAlive) {
            Thread.sleep(forTimeInterval: 0.02)
        }

        // Re-scan and re-match immediately before SIGKILL: a PID that survived the grace could
        // have exited and been recycled by an unrelated process. Only kill pids that still match
        // the same executable + --state-dir; if we cannot refresh the scan, kill nothing.
        let survivors = pids.filter(isProcessAlive)
        guard !survivors.isEmpty else { return pids }
        guard let refreshed = (psOutputProvider ?? processList)() else { return pids }
        let stillStale = Set(staleHelperPIDs(
            executablePath: executablePath,
            stateDirectory: stateDirectory,
            includeDescendants: includeDescendants,
            psOutput: refreshed
        ))
        for pid in survivors where stillStale.contains(pid) {
            _ = kill(pid, SIGKILL)
        }
        return pids
    }

    /// Locate a unique candidate by command line. This is a liveness hint, not identity or
    /// machine-generation authority, and must never authorize adoption or resource reclamation.
    public static func liveHelperPID(
        executablePath: String,
        stateDirectory: String,
        machineID: String,
        psOutput: String,
        currentPID: Int32 = getpid()
    ) -> Int32? {
        let executable = normalizedPath(executablePath)
        let stateRoot = normalizedPath(stateDirectory)
        guard !executable.isEmpty, !stateRoot.isEmpty, !machineID.isEmpty else { return nil }
        let matches = psOutput
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> Int32? in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let separator = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
                    return nil
                }
                let pidText = trimmed[..<separator]
                guard let pid = Int32(pidText), pid > 0, pid != currentPID else { return nil }
                let commandStart = trimmed[separator...].firstIndex(where: { $0 != " " && $0 != "\t" })
                guard let commandStart else { return nil }
                let command = String(trimmed[commandStart...])
                guard command == executable || command.hasPrefix(executable + " ") else { return nil }
                guard let processStateDirectory = stateDirectoryArgument(in: command) else { return nil }
                guard normalizedPath(processStateDirectory) == stateRoot else { return nil }
                guard let processMachineID = machineIDArgument(in: command),
                      processMachineID == machineID else {
                    return nil
                }
                return pid
            }
        return matches.count == 1 ? matches[0] : nil
    }

    public static func staleHelperPIDs(
        executablePath: String,
        stateDirectory: String,
        includeDescendants: Bool = false,
        psOutput: String,
        currentPID: Int32 = getpid()
    ) -> [Int32] {
        let executable = normalizedPath(executablePath)
        let stateRoot = normalizedPath(stateDirectory)
        guard !executable.isEmpty, !stateRoot.isEmpty else { return [] }

        return psOutput
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> Int32? in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let separator = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
                    return nil
                }
                let pidText = trimmed[..<separator]
                guard let pid = Int32(pidText), pid > 0, pid != currentPID else { return nil }

                let commandStart = trimmed[separator...].firstIndex(where: { $0 != " " && $0 != "\t" })
                guard let commandStart else { return nil }
                let command = String(trimmed[commandStart...])
                guard command == executable || command.hasPrefix(executable + " ") else { return nil }

                guard let processStateDirectory = stateDirectoryArgument(in: command) else { return nil }
                let processState = normalizedPath(processStateDirectory)
                if includeDescendants {
                    return processState == stateRoot || processState.hasPrefix(stateRoot + "/") ? pid : nil
                }
                return processState == stateRoot ? pid : nil
            }
    }

    public static func stateDirectoryArgument(in commandLine: String) -> String? {
        let parts = commandLine.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        for index in parts.indices {
            let part = parts[index]
            if part == "--state-dir", parts.indices.contains(index + 1) {
                return parts[index + 1]
            }
            if part.hasPrefix("--state-dir=") {
                return String(part.dropFirst("--state-dir=".count))
            }
        }
        return nil
    }

    public static func machineIDArgument(in commandLine: String) -> String? {
        let parts = commandLine.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        for index in parts.indices {
            let part = parts[index]
            if part == "--machine-id", parts.indices.contains(index + 1) {
                return parts[index + 1]
            }
            if part.hasPrefix("--machine-id=") {
                return String(part.dropFirst("--machine-id=".count))
            }
        }
        return nil
    }

    private static func processList() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func normalizedPath(_ path: String) -> String {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard normalized.count > 1 else { return normalized }
        return normalized.hasSuffix("/") ? String(normalized.dropLast()) : normalized
    }

    private static func isProcessAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}
