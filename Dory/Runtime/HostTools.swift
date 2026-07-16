import DoryOperations
import Foundation

/// Resolves host-side CLI tools that Dory shells out to. Core tools come from the app, optional
/// tools can come from a verified component, and development builds may fall back to a system
/// install. Dory's engine and GUI otherwise use the in-process Docker client.
enum HostTools {
    static func kubectl() -> String? { resolve("kubectl", systemCandidates: [
        "/usr/local/bin/kubectl", "/opt/homebrew/bin/kubectl",
    ]) }

    static func docker() -> String? { resolve("docker", systemCandidates: [
        "/opt/homebrew/bin/docker", "/usr/local/bin/docker", "/usr/bin/docker",
    ]) }

    static func dorydctl() -> String? { resolve("dorydctl", systemCandidates: [
        "\(NSHomeDirectory())/.dory/bin/dorydctl", "/opt/homebrew/bin/dorydctl", "/usr/local/bin/dorydctl",
    ]) }

    /// Public terminal affordances must go through the stable user command, not bundle-private helpers.
    static func userFacingDoryCommand(
        home: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> String? {
        Shell.find("dory", candidates: [
            "\(home)/.dory/bin/dory",
            "/opt/homebrew/bin/dory",
            "/usr/local/bin/dory",
        ], environment: environment, fileManager: fileManager)
    }

    private static func resolve(_ name: String, systemCandidates: [String]) -> String? {
        if let bundled = bundledPath(named: name) { return bundled }
        if name == "kubectl",
           let installed = DoryComponentStore.activeAssetPath(component: .kubernetes, path: "kubectl"),
           FileManager.default.isExecutableFile(atPath: installed) {
            return installed
        }
        return Shell.find(name, candidates: systemCandidates)
    }

    private static func bundledPath(named name: String) -> String? {
        if let auxiliary = Bundle.main.url(forAuxiliaryExecutable: name)?.path,
           FileManager.default.isExecutableFile(atPath: auxiliary) {
            return auxiliary
        }
        let bundleURL = Bundle.main.bundleURL
        let candidates = [
            bundleURL.appendingPathComponent("Contents/Helpers/\(name)").path,
            bundleURL.appendingPathComponent("Helpers/\(name)").path,
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
