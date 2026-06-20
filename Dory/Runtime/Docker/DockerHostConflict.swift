import Foundation

/// Detects, and with explicit user consent neutralizes, a `DOCKER_HOST` pinned in the user's shell
/// startup files. Docker's CLI precedence places an exported `DOCKER_HOST` ABOVE the active
/// `docker context`, so a leftover `export DOCKER_HOST=…` (planted by OrbStack, Docker Desktop or
/// Harbor) silently overrides Dory's context — see [DockerContext]. The fix is a one-time,
/// reversible cleanup: back the file up, then comment the offending lines out so the context wins.
enum DockerHostConflict {
    struct Site: Sendable, Equatable {
        let path: String
        let displayPath: String
        let lines: [Int]
    }

    struct Conflict: Sendable, Equatable {
        let effectiveHost: String
        let sites: [Site]
        var isFixable: Bool { !sites.isEmpty }
    }

    static let marker = "# dory-disabled (this DOCKER_HOST overrides Dory): "
    private static let cleanedFilesKey = "dory.dockerHostCleanedFiles"
    private static let dorySocketMarker = ".dory/dory.sock"

    private static let candidateFiles = [
        ".zshrc", ".zprofile", ".zshenv", ".zlogin",
        ".bashrc", ".bash_profile", ".profile",
    ]

    static var hasCleaned: Bool {
        !(UserDefaults.standard.stringArray(forKey: cleanedFilesKey) ?? []).isEmpty
    }

    static func detect(dorySocketPath: String) async -> Conflict? {
        guard let effective = await effectiveDockerHost(), !effective.isEmpty else { return nil }
        if pointsAtDory(effective, dorySocketPath: dorySocketPath) { return nil }
        return Conflict(effectiveHost: effective, sites: locateSites())
    }

    static func resolve(_ conflict: Conflict) -> Bool {
        var cleaned: [String] = []
        for site in conflict.sites where commentOut(path: site.path) { cleaned.append(site.path) }
        guard !cleaned.isEmpty else { return false }
        let existing = UserDefaults.standard.stringArray(forKey: cleanedFilesKey) ?? []
        UserDefaults.standard.set(Array(Set(existing + cleaned)).sorted(), forKey: cleanedFilesKey)
        return true
    }

    @discardableResult
    static func undo() -> Bool {
        let files = UserDefaults.standard.stringArray(forKey: cleanedFilesKey) ?? []
        var restoredAny = false
        for path in files where uncomment(path: path) { restoredAny = true }
        UserDefaults.standard.removeObject(forKey: cleanedFilesKey)
        return restoredAny
    }

    private static func effectiveDockerHost() async -> String? {
        let sentinel = "@@DORYDH@@"
        let command = "printf '\(sentinel)%s\(sentinel)' \"${DOCKER_HOST:-}\""
        let result = await withTimeout(seconds: 6) {
            await Shell.runAsyncResult(loginShell(), ["-lic", command])
        }
        guard let output = result?.output else { return nil }
        let parts = output.components(separatedBy: sentinel)
        guard parts.count >= 3 else { return nil }
        return parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func loginShell() -> String {
        if let shell = ProcessInfo.processInfo.environment["SHELL"],
           FileManager.default.isExecutableFile(atPath: shell) { return shell }
        return Shell.find("zsh", candidates: ["/bin/zsh", "/opt/homebrew/bin/zsh", "/usr/local/bin/zsh"]) ?? "/bin/zsh"
    }

    private static func pointsAtDory(_ host: String, dorySocketPath: String) -> Bool {
        host.contains(dorySocketMarker) || host.contains(dorySocketPath)
    }

    private static func locateSites() -> [Site] {
        let home = NSHomeDirectory()
        var sites: [Site] = []
        for name in candidateFiles {
            let path = "\(home)/\(name)"
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            let lines = content.components(separatedBy: "\n").enumerated()
                .filter { isConflictingAssignment($0.element) }
                .map { $0.offset + 1 }
            if !lines.isEmpty { sites.append(Site(path: path, displayPath: "~/\(name)", lines: lines)) }
        }
        return sites
    }

    private static func isConflictingAssignment(_ raw: String) -> Bool {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.hasPrefix("#") else { return false }
        let body = line.hasPrefix("export ")
            ? String(line.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces)
            : line
        guard body.hasPrefix("DOCKER_HOST=") else { return false }
        return !body.contains(dorySocketMarker)
    }

    private static func commentOut(path: String) -> Bool {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        var changed = false
        let lines = content.components(separatedBy: "\n").map { raw -> String in
            guard isConflictingAssignment(raw), !raw.hasPrefix(marker) else { return raw }
            changed = true
            return marker + raw
        }
        guard changed else { return false }
        backup(path: path, content: content)
        return write(lines, to: path)
    }

    private static func uncomment(path: String) -> Bool {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        var changed = false
        let lines = content.components(separatedBy: "\n").map { raw -> String in
            guard raw.hasPrefix(marker) else { return raw }
            changed = true
            return String(raw.dropFirst(marker.count))
        }
        guard changed else { return false }
        return write(lines, to: path)
    }

    private static func backup(path: String, content: String) {
        let backupPath = path + ".dory.bak"
        guard !FileManager.default.fileExists(atPath: backupPath) else { return }
        try? content.write(toFile: backupPath, atomically: true, encoding: .utf8)
    }

    private static func write(_ lines: [String], to path: String) -> Bool {
        do {
            try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    private static func withTimeout<T: Sendable>(seconds: Double, _ operation: @escaping @Sendable () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
