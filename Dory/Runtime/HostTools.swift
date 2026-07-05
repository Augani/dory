import Foundation

/// Resolves host-side CLI tools (kubectl, docker) that Dory shells out to. Prefers a copy bundled
/// inside the app so a fresh download needs nothing installed; falls back to a system install for
/// development builds. Everything Dory's engine and GUI do runs through the in-process Docker
/// client — these tools are only for the Kubernetes shell-out and the optional docker-CLI context.
enum HostTools {
    static func kubectl() -> String? { resolve("kubectl", systemCandidates: [
        "/usr/local/bin/kubectl", "/opt/homebrew/bin/kubectl",
    ]) }

    static func docker() -> String? { resolve("docker", systemCandidates: [
        "/opt/homebrew/bin/docker", "/usr/local/bin/docker", "/usr/bin/docker",
    ]) }

    private static func resolve(_ name: String, systemCandidates: [String]) -> String? {
        if let bundled = bundledPath(named: name) { return bundled }
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
