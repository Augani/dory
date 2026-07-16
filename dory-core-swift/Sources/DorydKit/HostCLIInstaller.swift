import DoryCore
import Foundation

public struct HostCLIInstallResult: Sendable, Equatable {
    public var linked: [String]
    public var missing: [String]
    public var pathProfileChanged: Bool
    public var composePluginInstalled: Bool
    public var buildxPluginInstalled: Bool
    public var dockerContextReconciled: Bool
    public var dockerContextError: String?

    public var dockerLinked: Bool {
        linked.contains("docker")
    }
}

public struct HostCLIRemoveResult: Sendable, Equatable {
    public var removed: [String]
    public var pathProfileChanged: Bool
    public var composePluginRemoved: Bool
    public var buildxPluginRemoved: Bool
    public var dockerContextRemoved: Bool
    public var dockerContextError: String?
}

/// Per-user terminal integration owned by doryd. When the daemon is running from the app bundle,
/// fresh terminals should already have Dory's docker, Compose, kubectl, dory, and support tools.
public struct HostCLIInstaller: Sendable {
    private static let beginSentinel = "# >>> dory cli >>>"
    private static let endSentinel = "# <<< dory cli <<<"
    private static let restoreNoTrailingNewline = "# dory:restore-no-trailing-newline"
    private static let removeEmptyProfile = "# dory:remove-empty-profile"
    private static let tools = ["docker", "docker-buildx", "docker-compose", "kubectl", "dory", "dory-doctor", "dorydctl"]
    private static let profiles = [".zprofile", ".zshrc", ".bash_profile", ".bashrc", ".profile"]
    private static let defaultProfiles = [".zprofile", ".zshrc"]

    public var home: String
    public var helpersDirectory: String?
    public var dockerSocketPath: String
    public var commandRunner: HostCLICommandRunner

    public init(
        home: String,
        helpersDirectory: String?,
        dockerSocketPath: String? = nil,
        commandRunner: HostCLICommandRunner? = nil
    ) {
        self.home = home
        self.helpersDirectory = helpersDirectory
        self.dockerSocketPath = dockerSocketPath ?? "\(home)/.dory/dory.sock"
        self.commandRunner = commandRunner ?? runHostCLICommand
    }

    public init(
        environment: DorydEnvironment,
        dockerSocketPath: String? = nil,
        commandRunner: HostCLICommandRunner? = nil
    ) {
        self.home = environment.home
        self.helpersDirectory = Self.helpersDirectory(environment: environment)
        self.dockerSocketPath = dockerSocketPath ?? "\(environment.home)/.dory/dory.sock"
        self.commandRunner = commandRunner ?? runHostCLICommand
    }

    @discardableResult
    public func install() -> HostCLIInstallResult {
        let fileManager = FileManager.default
        let binDir = "\(home)/.dory/bin"
        let composePluginDir = "\(home)/.docker/cli-plugins"
        var linked: [String] = []
        var missing: [String] = []
        var composePluginInstalled = false
        var buildxPluginInstalled = false

        try? fileManager.createDirectory(atPath: binDir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(atPath: composePluginDir, withIntermediateDirectories: true)

        for tool in Self.tools {
            guard let source = sourcePath(for: tool) else {
                missing.append(tool)
                continue
            }
            // Only count a tool as linked once the symlink actually resolves to it, so a
            // broken/failed link is reported missing and self-heal can retry it.
            if symlink(source, to: "\(binDir)/\(tool)") {
                linked.append(tool)
            } else {
                missing.append(tool)
            }
            if tool == "docker-compose" {
                composePluginInstalled = installOwnedPluginSymlink(source, to: "\(composePluginDir)/docker-compose")
            } else if tool == "docker-buildx" {
                buildxPluginInstalled = installOwnedPluginSymlink(source, to: "\(composePluginDir)/docker-buildx")
            }
        }
        let dockerContext = dockerContextManager()?.reconcile()
            ?? HostDockerContextResult(succeeded: false, error: "docker helper is missing")

        return HostCLIInstallResult(
            linked: linked,
            missing: missing,
            pathProfileChanged: addToPath(),
            composePluginInstalled: composePluginInstalled,
            buildxPluginInstalled: buildxPluginInstalled,
            dockerContextReconciled: dockerContext.succeeded,
            dockerContextError: dockerContext.error
        )
    }

    @discardableResult
    public func remove() -> HostCLIRemoveResult {
        let fileManager = FileManager.default
        let binDir = "\(home)/.dory/bin"
        let composePlugin = "\(home)/.docker/cli-plugins/docker-compose"
        let buildxPlugin = "\(home)/.docker/cli-plugins/docker-buildx"
        var removed: [String] = []
        let dockerContext = dockerContextManager()?.remove()
            ?? HostDockerContextResult(succeeded: false, error: "docker helper is missing")

        for tool in Self.tools {
            let path = "\(binDir)/\(tool)"
            if fileManager.fileExists(atPath: path) || (try? fileManager.destinationOfSymbolicLink(atPath: path)) != nil {
                try? fileManager.removeItem(atPath: path)
                removed.append(tool)
            }
        }

        let hadComposePlugin = removeOwnedPluginSymlink(at: composePlugin, desiredSource: sourcePath(for: "docker-compose"))
        let hadBuildxPlugin = removeOwnedPluginSymlink(at: buildxPlugin, desiredSource: sourcePath(for: "docker-buildx"))

        return HostCLIRemoveResult(
            removed: removed,
            pathProfileChanged: removeFromPath(),
            composePluginRemoved: hadComposePlugin,
            buildxPluginRemoved: hadBuildxPlugin,
            dockerContextRemoved: dockerContext.succeeded,
            dockerContextError: dockerContext.error
        )
    }

    public static func pathBlock(
        binDir: String,
        restoreTrailingNewline: Bool = false,
        removeProfileWhenEmpty: Bool = false
    ) -> String {
        var metadata = ""
        if restoreTrailingNewline { metadata += "\(restoreNoTrailingNewline)\n" }
        if removeProfileWhenEmpty { metadata += "\(removeEmptyProfile)\n" }
        return "\(beginSentinel)\n\(metadata)DORY_CLI_BIN=\"\(binDir)\"\ncase \":$PATH:\" in\n  *\":$DORY_CLI_BIN:\"*) ;;\n  *) export PATH=\"$DORY_CLI_BIN:$PATH\" ;;\nesac\n\(endSentinel)\n"
    }

    public static func appendingPathBlock(to content: String, binDir: String) -> String? {
        guard !content.contains(beginSentinel) else { return nil }
        let restoreTrailingNewline = !content.isEmpty && !content.hasSuffix("\n")
        let separator = restoreTrailingNewline ? "\n" : ""
        return content + separator + pathBlock(
            binDir: binDir,
            restoreTrailingNewline: restoreTrailingNewline
        )
    }

    public static func removingPathBlock(from content: String) -> String? {
        guard content.contains(beginSentinel) else { return content }
        var output: [String] = []
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
            if !skipping {
                output.append(line)
            }
        }
        guard !skipping else { return nil }
        var result = output.joined(separator: "\n")
        if trimFinalSeparator, result.hasSuffix("\n") { result.removeLast() }
        return result
    }

    private static func helpersDirectory(environment: DorydEnvironment) -> String? {
        let fileManager = FileManager.default
        if let explicit = environment.values["DORYD_HELPERS_DIR"], fileManager.fileExists(atPath: explicit) {
            return explicit
        }
        if let explicit = environment.values["DORY_HELPERS_DIR"], fileManager.fileExists(atPath: explicit) {
            return explicit
        }
        if !environment.executablePath.isEmpty {
            let executableURL = URL(fileURLWithPath: environment.executablePath)
            let directory = executableURL.deletingLastPathComponent().path
            if fileManager.fileExists(atPath: directory) {
                return directory
            }
            let bundleHelpers = executableURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Helpers", isDirectory: true)
                .path
            if fileManager.fileExists(atPath: bundleHelpers) {
                return bundleHelpers
            }
        }
        for candidate in ["\(environment.cwd)/Helpers", "\(environment.cwd)/../Helpers"] where fileManager.fileExists(atPath: candidate) {
            return candidate
        }
        return nil
    }

    private func sourcePath(for tool: String) -> String? {
        if tool == "kubectl",
           let installed = DoryComponentStore.activeAssetPath(
            component: .kubernetes,
            path: "kubectl",
            home: home
           ),
           FileManager.default.isExecutableFile(atPath: installed) {
            return installed
        }
        guard let helpersDirectory else { return nil }
        let path = "\(helpersDirectory)/\(tool)"
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    private func installOwnedPluginSymlink(_ source: String, to destination: String) -> Bool {
        let fileManager = FileManager.default
        if let rawTarget = try? fileManager.destinationOfSymbolicLink(atPath: destination) {
            let target = resolvedSymlinkTarget(rawTarget, at: destination)
            if standardized(target) == standardized(source) { return true }
            guard isDoryOwnedPluginTarget(target, desiredSource: source) else { return false }
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

    @discardableResult
    private func removeOwnedPluginSymlink(at destination: String, desiredSource: String?) -> Bool {
        let fileManager = FileManager.default
        guard let rawTarget = try? fileManager.destinationOfSymbolicLink(atPath: destination) else { return false }
        let target = resolvedSymlinkTarget(rawTarget, at: destination)
        guard isDoryOwnedPluginTarget(target, desiredSource: desiredSource) else { return false }
        do {
            try fileManager.removeItem(atPath: destination)
            return true
        } catch {
            return false
        }
    }

    private func isDoryOwnedPluginTarget(_ target: String, desiredSource: String?) -> Bool {
        let candidate = standardized(target)
        if let desiredSource, candidate == standardized(desiredSource) { return true }
        if isInside(candidate, root: standardized("\(home)/.dory")) { return true }
        if let helpersDirectory, isInside(candidate, root: standardized(helpersDirectory)) { return true }
        return false
    }

    private func resolvedSymlinkTarget(_ target: String, at destination: String) -> String {
        guard !target.hasPrefix("/") else { return target }
        return URL(fileURLWithPath: destination).deletingLastPathComponent()
            .appendingPathComponent(target).standardizedFileURL.path
    }

    private func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private func isInside(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root + "/")
    }

    private func dockerContextManager() -> HostDockerContextManager? {
        guard let docker = sourcePath(for: "docker") else { return nil }
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home
        return HostDockerContextManager(
            docker: docker,
            socketPath: dockerSocketPath,
            environment: environment,
            commandRunner: commandRunner
        )
    }

    @discardableResult
    private func symlink(_ source: String, to destination: String) -> Bool {
        guard source != destination else { return true }
        let fileManager = FileManager.default
        if let existing = try? fileManager.destinationOfSymbolicLink(atPath: destination), existing == source {
            return true
        }
        try? fileManager.removeItem(atPath: destination)
        do {
            try fileManager.createSymbolicLink(atPath: destination, withDestinationPath: source)
        } catch {
            return false
        }
        return (try? fileManager.destinationOfSymbolicLink(atPath: destination)) == source
    }

    private func addToPath() -> Bool {
        let fileManager = FileManager.default
        let binDir = "\(home)/.dory/bin"
        var changed = false
        for name in Self.profiles {
            let profileURL = URL(fileURLWithPath: "\(home)/\(name)")
            guard fileManager.fileExists(atPath: profileURL.path) else { continue }
            let targetURL = profileURL.resolvingSymlinksInPath()
            guard let content = try? String(contentsOf: targetURL, encoding: .utf8) else { continue }
            guard let updated = Self.appendingPathBlock(to: content, binDir: binDir) else { continue }
            if (try? updated.write(to: targetURL, atomically: true, encoding: .utf8)) != nil {
                changed = true
            }
        }
        for name in Self.defaultProfiles where !fileManager.fileExists(atPath: "\(home)/\(name)") {
            if (try? Self.pathBlock(binDir: binDir, removeProfileWhenEmpty: true)
                .write(toFile: "\(home)/\(name)", atomically: true, encoding: .utf8)) != nil {
                changed = true
            }
        }
        return changed
    }

    private func removeFromPath() -> Bool {
        var changed = false
        for name in Self.profiles {
            let profileURL = URL(fileURLWithPath: "\(home)/\(name)")
            let targetURL = profileURL.resolvingSymlinksInPath()
            guard let content = try? String(contentsOf: targetURL, encoding: .utf8),
                  content.contains(Self.beginSentinel) else { continue }
            guard let stripped = Self.removingPathBlock(from: content) else { continue }
            let removeProfile = content.contains(Self.removeEmptyProfile) && stripped.isEmpty
                && (try? FileManager.default.destinationOfSymbolicLink(atPath: profileURL.path)) == nil
            let updated: Bool
            if removeProfile {
                updated = (try? FileManager.default.removeItem(at: targetURL)) != nil
            } else {
                updated = (try? stripped.write(to: targetURL, atomically: true, encoding: .utf8)) != nil
            }
            if updated {
                changed = true
            }
        }
        return changed
    }
}
