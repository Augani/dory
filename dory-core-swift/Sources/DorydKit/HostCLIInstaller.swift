import Foundation

public struct HostCLIInstallResult: Sendable, Equatable {
    public var linked: [String]
    public var missing: [String]
    public var pathProfileChanged: Bool
    public var composePluginInstalled: Bool

    public var dockerLinked: Bool {
        linked.contains("docker")
    }
}

/// Per-user terminal integration owned by doryd. When the daemon is running from the app bundle,
/// fresh terminals should already have Dory's docker, Compose, kubectl, dory, and support tools.
public struct HostCLIInstaller: Sendable {
    private static let beginSentinel = "# >>> dory cli >>>"
    private static let endSentinel = "# <<< dory cli <<<"
    private static let tools = ["docker", "docker-compose", "kubectl", "dory", "dory-doctor", "dory-idle-proxy", "dorydctl"]
    private static let profiles = [".zprofile", ".zshrc", ".bash_profile", ".profile"]

    public var home: String
    public var helpersDirectory: String?

    public init(home: String, helpersDirectory: String?) {
        self.home = home
        self.helpersDirectory = helpersDirectory
    }

    public init(environment: DorydEnvironment) {
        self.home = environment.home
        self.helpersDirectory = Self.helpersDirectory(environment: environment)
    }

    @discardableResult
    public func install() -> HostCLIInstallResult {
        let fileManager = FileManager.default
        let binDir = "\(home)/.dory/bin"
        let composePluginDir = "\(home)/.docker/cli-plugins"
        var linked: [String] = []
        var missing: [String] = []
        var composePluginInstalled = false

        try? fileManager.createDirectory(atPath: binDir, withIntermediateDirectories: true)
        try? fileManager.createDirectory(atPath: composePluginDir, withIntermediateDirectories: true)

        for tool in Self.tools {
            guard let source = sourcePath(for: tool) else {
                missing.append(tool)
                continue
            }
            linked.append(tool)
            symlink(source, to: "\(binDir)/\(tool)")
            if tool == "docker-compose" {
                symlink(source, to: "\(composePluginDir)/docker-compose")
                composePluginInstalled = fileManager.fileExists(atPath: "\(composePluginDir)/docker-compose")
            }
        }

        return HostCLIInstallResult(
            linked: linked,
            missing: missing,
            pathProfileChanged: addToPath(),
            composePluginInstalled: composePluginInstalled
        )
    }

    public static func pathBlock(binDir: String) -> String {
        "\(beginSentinel)\nexport PATH=\"\(binDir):$PATH\"\n\(endSentinel)\n"
    }

    public static func appendingPathBlock(to content: String, binDir: String) -> String? {
        guard !content.contains(beginSentinel) else { return nil }
        let separator = content.isEmpty || content.hasSuffix("\n") ? "\n" : "\n\n"
        return content + separator + pathBlock(binDir: binDir)
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
        guard let helpersDirectory else { return nil }
        let path = "\(helpersDirectory)/\(tool)"
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    private func symlink(_ source: String, to destination: String) {
        guard source != destination else { return }
        let fileManager = FileManager.default
        if let existing = try? fileManager.destinationOfSymbolicLink(atPath: destination), existing == source {
            return
        }
        try? fileManager.removeItem(atPath: destination)
        try? fileManager.createSymbolicLink(atPath: destination, withDestinationPath: source)
    }

    private func addToPath() -> Bool {
        let fileManager = FileManager.default
        let binDir = "\(home)/.dory/bin"
        var sawProfile = false
        var changed = false
        for name in Self.profiles {
            let path = "\(home)/\(name)"
            guard fileManager.fileExists(atPath: path),
                  let content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            sawProfile = true
            guard let updated = Self.appendingPathBlock(to: content, binDir: binDir) else { continue }
            if (try? updated.write(toFile: path, atomically: true, encoding: .utf8)) != nil {
                changed = true
            }
        }
        if !sawProfile {
            let path = "\(home)/.zprofile"
            if (try? Self.pathBlock(binDir: binDir).write(toFile: path, atomically: true, encoding: .utf8)) != nil {
                changed = true
            }
        }
        return changed
    }
}
