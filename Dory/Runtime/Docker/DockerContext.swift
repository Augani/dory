import Foundation

/// Points the `docker` CLI at Dory by creating and activating a `docker context` named "dory" — the
/// same mechanism OrbStack and Docker Desktop use, so a plain `docker ps` (no -H) goes through Dory.
/// Per-user, needs no admin, and is fully reversible (`docker context use default`). The previously
/// active context is remembered and restored when Dory stops.
enum DockerContext {
    static let name = "dory"
    private static let previousKey = "dory.previousDockerContext"

    private static func dockerBinary() -> String? {
        HostTools.docker()
    }

    static func activate(socketPath: String) async {
        guard let docker = dockerBinary() else { return }
        let host = "unix://\(socketPath)"
        if await Shell.runAsyncResult(docker, ["context", "inspect", name]).exit == 0 {
            _ = await Shell.runAsyncResult(docker, ["context", "update", name, "--docker", "host=\(host)"])
        } else {
            _ = await Shell.runAsyncResult(docker, ["context", "create", name, "--description", "Dory", "--docker", "host=\(host)"])
        }
        let current = await Shell.runAsyncResult(docker, ["context", "show"]).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty, current != name {
            UserDefaults.standard.set(current, forKey: previousKey)
        }
        _ = await Shell.runAsyncResult(docker, ["context", "use", name])
    }

    /// Restore the previously-active context. Synchronous so it can run during app termination.
    /// No-op unless `dory` is currently active (don't override a choice the user made by hand).
    static func deactivateSync() {
        guard let docker = dockerBinary() else { return }
        guard let current = try? Shell.run(docker, ["context", "show"]).trimmingCharacters(in: .whitespacesAndNewlines),
              current == name else { return }
        let previous = UserDefaults.standard.string(forKey: previousKey) ?? "default"
        _ = try? Shell.run(docker, ["context", "use", previous])
    }
}
