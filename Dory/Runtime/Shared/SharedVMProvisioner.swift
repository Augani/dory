import Foundation

/// Brings up a single shared Linux VM that hosts a Docker engine for ALL of Dory's workloads,
/// the way OrbStack and Docker Desktop do — instead of Apple `container`'s one-VM-per-container
/// model. One persistent micro-VM (via Apple's `container` engine) runs `dockerd`; its socket is
/// published to the host; Dory's existing, fully-verified `DockerEngineRuntime` drives it. Every
/// `docker run` then lands inside the one shared VM, sharing a single kernel and memory pool.
enum SharedVMProvisioner {
    static let engineName = "dory-engine"
    static let dataVolume = "dory-engine-data"
    static let image = "docker.io/library/docker:dind"
    static let versionLabel = "dory.engine.spec"
    /// Bump when the engine's `container run` spec changes (mounts, flags) so existing engines are
    /// recreated on the next launch. Persistent images survive via the data volume.
    static let engineSpecVersion = "v2-homeshare"
    static var socketPath: String { "\(NSHomeDirectory())/.dory/engine.sock" }

    private static let binaryCandidates = ["/opt/homebrew/bin/container", "/usr/local/bin/container"]

    struct Config: Sendable {
        var cpus: Int
        /// Guest RAM ceiling. Apple's Virtualization.framework backs guest pages lazily, so a
        /// generous cap costs nothing until workloads actually use it.
        var memory: String

        init(cpus: Int = 4, memory: String = "4096M") {
            self.cpus = cpus
            self.memory = memory
        }
    }

    enum ProvisionError: Error, Sendable {
        case containerCLINotFound
        case systemUnavailable
        case engineStartFailed(String)
        case engineUnreachable
    }

    /// Prefers a `container` toolchain bundled inside the app (so a downloaded Dory.app is fully
    /// self-contained) and falls back to a system install. The full toolchain (binaries + Linux
    /// kernel + plugins) is copied into `Dory.app/Contents/Helpers/container` by the release
    /// pipeline; until then this resolves the Homebrew/system install.
    static func containerBinary() -> String? {
        if let helpers = Bundle.main.url(forResource: "container", withExtension: nil, subdirectory: "Helpers")?.path,
           FileManager.default.isExecutableFile(atPath: helpers) {
            return helpers
        }
        return Shell.find("container", candidates: binaryCandidates)
    }

    /// Path to the engine image (`docker:dind`) tar bundled in the app's Resources, if present.
    /// When bundled, the engine is loaded offline — no Docker Hub round-trip on first launch.
    static func bundledImageTar() -> String? {
        for ext in ["tar", "tar.gz"] {
            if let url = Bundle.main.url(forResource: "dory-engine-image", withExtension: ext),
               FileManager.default.fileExists(atPath: url.path) {
                return url.path
            }
        }
        return nil
    }

    private static func ensureImage(binary: String) async {
        let present = await Shell.runAsyncResult(binary, ["image", "inspect", image])
        if present.exit == 0 { return }
        if let tar = bundledImageTar() {
            let load = await Shell.runAsyncResult(binary, ["image", "load", "-i", tar])
            if load.exit == 0 { return }
        }
        _ = await Shell.runAsyncResult(binary, ["image", "pull", image])
    }

    static func provision(config: Config = Config()) async throws -> String {
        guard let binary = containerBinary() else {
            throw ProvisionError.containerCLINotFound
        }

        let status = await Shell.runAsyncResult(binary, ["system", "status"])
        if status.exit != 0 {
            let start = await Shell.runAsyncResult(binary, ["system", "start"])
            guard start.exit == 0 else { throw ProvisionError.systemUnavailable }
        }

        // Reuse a healthy engine if one is already serving the current spec — but recreate it if it
        // predates a spec change (e.g. host file sharing was added), so upgrades take effect. The
        // persistent data volume keeps images across the recreate.
        if await isReachable(), await engineIsCurrent(binary: binary) { return socketPath }

        let directory = (socketPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

        // Restart an existing-but-stopped engine first (keeps the cache warm) unless it's outdated.
        if await engineIsCurrent(binary: binary) {
            let restart = await Shell.runAsyncResult(binary, ["start", engineName])
            if restart.exit == 0, await waitForReachable() { return socketPath }
        }

        _ = await Shell.runAsyncResult(binary, ["rm", "-f", engineName])
        try? FileManager.default.removeItem(atPath: socketPath)
        _ = await Shell.runAsyncResult(binary, ["volume", "create", dataVolume])
        await ensureImage(binary: binary)

        // Share the user's home directory into the VM at the same path, so host bind mounts
        // (`docker run -v ~/project:/app`) resolve transparently — OrbStack's file-sharing model.
        let home = NSHomeDirectory()
        let run = await Shell.runAsyncResult(binary, [
            "run", "-d", "--name", engineName,
            "--cpus", String(config.cpus), "--memory", config.memory,
            "--cap-add", "ALL",
            "--label", "\(versionLabel)=\(engineSpecVersion)",
            "--volume", "\(dataVolume):/var/lib/docker",
            "--mount", "type=virtiofs,source=\(home),target=\(home)",
            "--publish-socket", "\(socketPath):/var/run/docker.sock",
            "-e", "DOCKER_TLS_CERTDIR=",
            image,
            "dockerd", "--host=unix:///var/run/docker.sock",
        ])
        guard run.exit == 0 else { throw ProvisionError.engineStartFailed(run.output) }
        guard await waitForReachable() else { throw ProvisionError.engineUnreachable }
        return socketPath
    }

    static func runtime(config: Config = Config()) async -> DockerEngineRuntime? {
        guard let socket = try? await provision(config: config) else { return nil }
        return DockerEngineRuntime(socketPath: socket, kind: .sharedVM)
    }

    /// True if an engine container exists with the current spec version (so it can be reused),
    /// false if it's absent or predates the current spec (so it must be recreated).
    private static func engineIsCurrent(binary: String) async -> Bool {
        let result = await Shell.runAsyncResult(binary, ["inspect", engineName])
        return result.exit == 0 && result.output.contains(engineSpecVersion)
    }

    /// Register x86/amd64 emulation in the shared VM so Intel images run on Apple silicon — the
    /// way OrbStack does (OrbStack uses Rosetta; this installs the reliable qemu binfmt handler).
    /// Idempotent: skips if amd64 is already registered.
    static func ensureEmulation() async {
        let runtime = DockerEngineRuntime(socketPath: socketPath, kind: .sharedVM)
        if let check = try? await runtime.exec(containerID: engineName,
            command: ["sh", "-c", "ls /proc/sys/fs/binfmt_misc/ 2>/dev/null | grep -q qemu-x86_64 && echo ok"]),
           check.output.contains("ok") { return }
        try? await runtime.pull(image: "tonistiigi/binfmt")
        let body = Data(#"{"Image":"tonistiigi/binfmt","Cmd":["--install","amd64"],"HostConfig":{"Privileged":true,"AutoRemove":true}}"#.utf8)
        guard let create = await runtime.proxyRequest(method: "POST", path: "/containers/create?name=dory-binfmt",
            headers: [(name: "Content-Type", value: "application/json")], body: body),
            let id = decodeId(create.body) else { return }
        _ = await runtime.proxyRequest(method: "POST", path: "/containers/\(id)/start", headers: [], body: Data())
    }

    private static func decodeId(_ data: Data) -> String? {
        struct Out: Decodable { let Id: String }
        return (try? JSONDecoder().decode(Out.self, from: data))?.Id
    }

    static func stop() async {
        guard let binary = containerBinary() else { return }
        _ = await Shell.runAsyncResult(binary, ["stop", engineName])
    }

    /// The shared VM's host-reachable IPv4 address (e.g. 192.168.64.x), used to forward published
    /// container ports to `localhost`.
    static func engineIP() async -> String? {
        guard let binary = containerBinary() else { return nil }
        let result = await Shell.runAsyncResult(binary, ["ls"])
        for line in result.output.split(separator: "\n") where line.contains(engineName) {
            for token in line.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
                let candidate = token.split(separator: "/").first.map(String.init) ?? String(token)
                if isIPv4(candidate) { return candidate }
            }
        }
        return nil
    }

    private static func isIPv4(_ string: String) -> Bool {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
    }

    private static func waitForReachable(attempts: Int = 60) async -> Bool {
        for _ in 0..<attempts {
            if await isReachable() { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    private static func isReachable() async -> Bool {
        guard FileManager.default.fileExists(atPath: socketPath) else { return false }
        let runtime = DockerEngineRuntime(socketPath: socketPath, kind: .sharedVM)
        let response = await runtime.proxyRequest(method: "GET", path: "/version", headers: [], body: Data())
        return response?.isSuccess ?? false
    }
}
