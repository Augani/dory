import Foundation

/// Makes `docker` and `docker compose` work in the user's own terminal with zero prerequisites.
/// Symlinks Dory's bundled CLIs into `~/.dory/bin`, adds that directory to PATH through a
/// sentinel-guarded block in the login-shell profiles, and installs the compose plugin into
/// `~/.docker/cli-plugins`. Everything is per-user, needs no admin, and is fully reversible.
enum HostDockerCLI {
    static let binDir = NSHomeDirectory() + "/.dory/bin"
    private static let composePluginDir = NSHomeDirectory() + "/.docker/cli-plugins"
    private static let beginSentinel = "# >>> dory cli >>>"
    private static let endSentinel = "# <<< dory cli <<<"
    private static let restoreNoTrailingNewline = "# dory:restore-no-trailing-newline"
    private static let removeEmptyProfile = "# dory:remove-empty-profile"
    private static let profiles = [".zprofile", ".zshrc", ".bash_profile", ".bashrc", ".profile"]
    static let linkedTools = ["docker", "docker-buildx", "docker-compose", "kubectl", "dory", "dory-doctor", "dorydctl"]

    struct Status: Equatable {
        var dockerLinked: Bool
        var onPath: Bool
        var composeInstalled: Bool
        var buildxInstalled: Bool
    }

    @discardableResult
    static func install() -> Bool {
        guard helper("docker") != nil else { return false }
        try? FileManager.default.createDirectory(atPath: binDir, withIntermediateDirectories: true)
        for tool in linkedTools {
            if let source = helper(tool) {
                symlink(source, to: binDir + "/\(tool)")
            }
        }
        _ = installComposePlugin()
        _ = installBuildxPlugin()
        addToPath()
        return true
    }

    @discardableResult
    static func installComposePlugin() -> Bool {
        guard let compose = helper("docker-compose") else { return false }
        try? FileManager.default.createDirectory(atPath: composePluginDir, withIntermediateDirectories: true)
        return installOwnedComposeSymlink(compose, to: composePluginDir + "/docker-compose")
    }

    @discardableResult
    static func installBuildxPlugin() -> Bool {
        guard let buildx = helper("docker-buildx") else { return false }
        try? FileManager.default.createDirectory(atPath: composePluginDir, withIntermediateDirectories: true)
        return installOwnedComposeSymlink(buildx, to: composePluginDir + "/docker-buildx")
    }

    static func remove() {
        let fileManager = FileManager.default
        for tool in linkedTools {
            try? fileManager.removeItem(atPath: binDir + "/\(tool)")
        }
        removeOwnedComposeSymlink(at: composePluginDir + "/docker-compose")
        removeOwnedComposeSymlink(at: composePluginDir + "/docker-buildx")
        removeFromPath()
    }

    static func status() -> Status {
        let fileManager = FileManager.default
        var onPath = false
        for name in profiles {
            let path = NSHomeDirectory() + "/" + name
            if let content = try? String(contentsOfFile: path, encoding: .utf8), content.contains(beginSentinel) {
                onPath = true
                break
            }
        }
        return Status(
            dockerLinked: fileManager.fileExists(atPath: binDir + "/docker"),
            onPath: onPath,
            composeInstalled: fileManager.fileExists(atPath: composePluginDir + "/docker-compose"),
            buildxInstalled: fileManager.fileExists(atPath: composePluginDir + "/docker-buildx")
        )
    }

    private static func helper(_ name: String) -> String? {
        let bundleURL = Bundle.main.bundleURL
        let candidates = [
            bundleURL.appendingPathComponent("Contents/Helpers/\(name)").path,
            bundleURL.appendingPathComponent("Helpers/\(name)").path,
        ]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        if let auxiliary = Bundle.main.url(forAuxiliaryExecutable: name)?.path,
           FileManager.default.isExecutableFile(atPath: auxiliary) {
            return auxiliary
        }
        return nil
    }

    private static func symlink(_ source: String, to destination: String) {
        guard source != destination else { return }
        let fileManager = FileManager.default
        if let existing = try? fileManager.destinationOfSymbolicLink(atPath: destination), existing == source {
            return
        }
        try? fileManager.removeItem(atPath: destination)
        try? fileManager.createSymbolicLink(atPath: destination, withDestinationPath: source)
    }

    /// Installs Compose only when the destination is empty or is a symlink Dory already owns.
    /// A user's regular file, directory, or third-party symlink is deliberately left untouched.
    @discardableResult
    static func installOwnedComposeSymlink(
        _ source: String,
        to destination: String,
        home: String = NSHomeDirectory(),
        bundleRoot: String = Bundle.main.bundleURL.path,
        fileManager: FileManager = .default
    ) -> Bool {
        if let rawTarget = try? fileManager.destinationOfSymbolicLink(atPath: destination) {
            let target = resolvedSymlinkTarget(rawTarget, at: destination)
            if standardized(target) == standardized(source) { return true }
            guard isDoryOwnedComposeTarget(target, desiredSource: source, home: home, bundleRoot: bundleRoot) else {
                return false
            }
            do { try fileManager.removeItem(atPath: destination) } catch { return false }
        } else if fileManager.fileExists(atPath: destination) {
            return false
        }
        do {
            try fileManager.createSymbolicLink(atPath: destination, withDestinationPath: source)
            return true
        } catch {
            return false
        }
    }

    static func removeOwnedComposeSymlink(
        at destination: String,
        home: String = NSHomeDirectory(),
        bundleRoot: String = Bundle.main.bundleURL.path,
        fileManager: FileManager = .default
    ) {
        guard let rawTarget = try? fileManager.destinationOfSymbolicLink(atPath: destination) else { return }
        let target = resolvedSymlinkTarget(rawTarget, at: destination)
        guard isDoryOwnedComposeTarget(target, desiredSource: helper("docker-compose"), home: home, bundleRoot: bundleRoot) else {
            return
        }
        try? fileManager.removeItem(atPath: destination)
    }

    static func isDoryOwnedComposeTarget(
        _ target: String,
        desiredSource: String?,
        home: String,
        bundleRoot: String
    ) -> Bool {
        let candidate = standardized(target)
        if let desiredSource, candidate == standardized(desiredSource) { return true }
        return isInside(candidate, root: standardized(home + "/.dory"))
            || isInside(candidate, root: standardized(bundleRoot))
    }

    private static func resolvedSymlinkTarget(_ target: String, at destination: String) -> String {
        guard !target.hasPrefix("/") else { return target }
        return URL(fileURLWithPath: destination).deletingLastPathComponent()
            .appendingPathComponent(target).standardizedFileURL.path
    }

    private static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func isInside(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    static func pathBlock(
        binDir: String = binDir,
        restoreTrailingNewline: Bool = false,
        removeProfileWhenEmpty: Bool = false
    ) -> String {
        var metadata = ""
        if restoreTrailingNewline { metadata += "\(restoreNoTrailingNewline)\n" }
        if removeProfileWhenEmpty { metadata += "\(removeEmptyProfile)\n" }
        return "\(beginSentinel)\n\(metadata)export PATH=\"\(binDir):$PATH\"\n\(endSentinel)\n"
    }

    /// Appends the PATH block to profile content, or returns nil when it is already present so the
    /// caller can skip the write. Pure so it can be unit-tested without touching real profiles.
    static func appendingPathBlock(to content: String, binDir: String = binDir) -> String? {
        guard !content.contains(beginSentinel) else { return nil }
        let restoreTrailingNewline = !content.isEmpty && !content.hasSuffix("\n")
        let separator = restoreTrailingNewline ? "\n" : ""
        return content + separator + pathBlock(
            binDir: binDir,
            restoreTrailingNewline: restoreTrailingNewline
        )
    }

    /// Strips a complete Dory PATH block and rejects damaged marker pairs.
    static func removingPathBlock(from content: String) -> String? {
        guard content.contains(beginSentinel) else { return content }
        var out: [String] = []
        var skipping = false
        var restoreTrailingNewline = false
        var trimFinalSeparator = false
        let lines = content.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            if line == beginSentinel {
                guard !skipping else { return nil }
                skipping = true
                restoreTrailingNewline = false
                continue
            }
            if line == endSentinel {
                guard skipping else { return nil }
                skipping = false
                trimFinalSeparator = restoreTrailingNewline
                    && (index == lines.count - 1 || (index == lines.count - 2 && lines.last == ""))
                continue
            }
            if skipping, line == restoreNoTrailingNewline {
                restoreTrailingNewline = true
            }
            if !skipping { out.append(line) }
        }
        guard !skipping else { return nil }
        var result = out.joined(separator: "\n")
        if trimFinalSeparator, result.hasSuffix("\n") { result.removeLast() }
        return result
    }

    private static func addToPath() {
        let fileManager = FileManager.default
        var wroteAny = false
        for name in profiles {
            let profileURL = URL(fileURLWithPath: NSHomeDirectory() + "/" + name)
            guard fileManager.fileExists(atPath: profileURL.path) else { continue }
            let targetURL = profileURL.resolvingSymlinksInPath()
            guard let content = try? String(contentsOf: targetURL, encoding: .utf8) else { continue }
            wroteAny = true
            guard let updated = appendingPathBlock(to: content) else { continue }
            try? updated.write(to: targetURL, atomically: true, encoding: .utf8)
        }
        if !wroteAny {
            try? pathBlock(removeProfileWhenEmpty: true)
                .write(toFile: NSHomeDirectory() + "/.zprofile", atomically: true, encoding: .utf8)
        }
    }

    private static func removeFromPath() {
        for name in profiles {
            let profileURL = URL(fileURLWithPath: NSHomeDirectory() + "/" + name)
            let targetURL = profileURL.resolvingSymlinksInPath()
            guard let content = try? String(contentsOf: targetURL, encoding: .utf8),
                  content.contains(beginSentinel) else { continue }
            guard let stripped = removingPathBlock(from: content) else { continue }
            if content.contains(removeEmptyProfile), stripped.isEmpty,
               (try? FileManager.default.destinationOfSymbolicLink(atPath: profileURL.path)) == nil {
                try? FileManager.default.removeItem(at: targetURL)
            } else {
                try? stripped.write(to: targetURL, atomically: true, encoding: .utf8)
            }
        }
    }
}
