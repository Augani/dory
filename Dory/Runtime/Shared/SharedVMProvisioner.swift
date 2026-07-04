import Darwin
import Foundation

/// Brings up a single shared Linux VM that hosts a Docker engine for ALL of Dory's workloads,
/// the way OrbStack and Docker Desktop do instead of Apple `container`'s one-VM-per-container
/// model. Prefer Dory's in-process VM helper when it is bundled; fall back to Apple's CLI only for
/// development and older installs. Dory's existing Docker runtime then drives the published socket.
enum SharedVMProvisioner {
    static let engineName = "dory-engine"
    static let dataVolume = "dory-engine-data"
    static let image = "docker.io/library/docker:dind"
    static let versionLabel = "dory.engine.spec"
    /// Bump when the engine's `container run` spec changes (mounts, flags) so existing engines are
    /// recreated on the next launch. Persistent images survive via the data volume.
    static let engineSpecVersion = "v3-lowmem-helper"
    static var socketPath: String { "\(NSHomeDirectory())/.dory/engine.sock" }
    static var engineIPPath: String { "\(NSHomeDirectory())/.dory/engine.ip" }

    private static let binaryCandidates = ["/opt/homebrew/bin/container", "/usr/local/bin/container"]
    private static let zstdCandidates = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"]
    private static let helperName = "dory-vm"
    private static let helperPIDPath = "\(NSHomeDirectory())/.dory/engine.pid"
    private static let helperLogPath = "\(NSHomeDirectory())/.dory/engine.log"
    nonisolated static let defaultEngineMemoryMB = 2048
    nonisolated static let defaultEngineHeadroomMB = 512

    struct Config: Sendable {
        var cpus: Int
        /// Guest RAM ceiling. Keep this materially below the old 4 GiB cap; the helper can still
        /// reclaim below the ceiling via the virtio balloon, and env vars can raise it for heavy jobs.
        var memory: String
        var headroomMB: Int

        nonisolated init(
            cpus: Int = 4,
            memory: String = "\(SharedVMProvisioner.defaultEngineMemoryMB)M",
            headroomMB: Int = SharedVMProvisioner.defaultEngineHeadroomMB
        ) {
            self.cpus = cpus
            self.memory = memory
            self.headroomMB = headroomMB
        }

        var memoryMB: Int {
            SharedVMProvisioner.memoryStringToMB(memory) ?? SharedVMProvisioner.defaultEngineMemoryMB
        }
    }

    enum ProvisionError: Error, Sendable {
        case unsupportedHost(String)
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
        // QA hook: simulate a fresh Mac with no toolchain, to exercise the first-run setup flow.
        if ProcessInfo.processInfo.environment["DORY_NO_TOOLCHAIN"] == "1" { return nil }
        if let helpers = bundledHelperPath(named: "container"),
           FileManager.default.isExecutableFile(atPath: helpers) {
            return helpers
        }
        return Shell.find("container", candidates: binaryCandidates)
    }

    static func hostSupport(
        platform: MacHostPlatform = .current(),
        containerBinaryPath: String? = containerBinary(),
        inProcessEngineAvailable: Bool = inProcessEngineAvailable()
    ) -> RuntimeSupport {
        let base = AppleContainerSupport.evaluate(platform: platform, hasContainerCLI: true)
        guard base.isSupported else { return base }
        guard containerBinaryPath != nil || inProcessEngineAvailable else {
            return .unsupported("needs Dory's bundled engine or Apple's container toolchain", issue: .missingToolchain)
        }
        return .supported
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
        let binaryPath = containerBinary()
        let support = hostSupport(containerBinaryPath: binaryPath)
        guard support.isSupported else {
            throw ProvisionError.unsupportedHost(support.reason)
        }

        if let socket = try await provisionWithHVEngine(config: config) {
            return socket
        }

        if let socket = try await provisionInProcess(config: config) {
            return socket
        }

        guard let binary = binaryPath else {
            throw ProvisionError.containerCLINotFound
        }
        return try await provisionWithContainerCLI(binary: binary, config: config)
    }

    /// Dory's own VMM (dory-hv on Hypervisor.framework): elastic memory via free page reporting
    /// and a persistent engine disk. Opt-in during soak via DORY_HV_ENGINE=1; graduates to the
    /// default rung once burn-in completes.
    private static func provisionWithHVEngine(config: Config) async throws -> String? {
        let environment = ProcessInfo.processInfo.environment
        guard environment["DORY_HV_ENGINE"] == "1",
              let helper = hvHelperBinary(),
              let gvproxy = gvproxyBinary() else { return nil }
        // Prefer a kernel from an installed toolchain; fall back to the compressed kernel bundled
        // in the app so a self-contained install with no `container` toolchain still boots.
        guard let kernel = await hvKernelPath() else { return nil }

        if await isReachable(), helperProcessIsAlive() {
            return socketPath
        }
        stopHelper()

        let directory = (socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(atPath: socketPath)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: helper)
        process.arguments = [
            "engine",
            "--engine-sock", socketPath,
            "--kernel", kernel,
            "--gvproxy", gvproxy,
            "--mem-mb", String(config.memoryMB),
            "--cpus", String(config.cpus),
        ]

        FileManager.default.createFile(atPath: helperLogPath, contents: nil)
        let log = try? FileHandle(forWritingTo: URL(fileURLWithPath: helperLogPath))
        try? log?.seekToEnd()
        log?.write(Data("\n--- starting dory-hv engine \(Date()) mem=\(config.memoryMB)MiB ---\n".utf8))
        process.standardOutput = log ?? FileHandle.nullDevice
        process.standardError = log ?? FileHandle.nullDevice

        do {
            try process.run()
            try? "\(process.processIdentifier)\n".write(toFile: helperPIDPath, atomically: true, encoding: .utf8)
            try? log?.close()
        } catch {
            try? log?.close()
            throw ProvisionError.engineStartFailed("\(error)")
        }

        guard await waitForReachable(attempts: 240) else {
            if process.isRunning { process.terminate() }
            return nil  // fall through to the VZ helper or container CLI
        }
        return socketPath
    }

    private static func hvKernelPath() async -> String? {
        if let installed = defaultKernelPath() { return installed }
        return await prepareCompressedResource(resource: "dory-vm-kernel", outputName: "dory-vm-kernel")
    }

    private static func hvHelperBinary() -> String? {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["DORY_HV_HELPER"],
           !override.isEmpty,
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        if let helper = bundledHelperPath(named: "dory-hv"),
           FileManager.default.isExecutableFile(atPath: helper) {
            return helper
        }
        let cwd = FileManager.default.currentDirectoryPath
        let devCandidates = [
            "\(cwd)/Packages/ContainerizationEngine/.build/out/Products/Release/dory-hv",
            "\(cwd)/Packages/ContainerizationEngine/.build/out/Products/Debug/dory-hv",
        ]
        return devCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func gvproxyBinary() -> String? {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["DORY_GVPROXY"],
           !override.isEmpty,
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        if let bundled = bundledHelperPath(named: "gvproxy"),
           FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        let candidates = [
            "/opt/homebrew/opt/podman/libexec/podman/gvproxy",
            "/usr/local/opt/podman/libexec/podman/gvproxy",
            "/opt/homebrew/bin/gvproxy",
            "/usr/local/bin/gvproxy",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func provisionWithContainerCLI(binary: String, config: Config) async throws -> String {
        try? FileManager.default.removeItem(atPath: engineIPPath)
        let support = hostSupport(containerBinaryPath: binary, inProcessEngineAvailable: false)
        guard support.isSupported else {
            throw ProvisionError.unsupportedHost(support.reason)
        }

        let status = await Shell.runAsyncResult(binary, ["system", "status"])
        if status.exit != 0 {
            // A fresh toolchain has no Linux kernel yet, and `system start` prompts interactively
            // for one — which would hang this non-interactive launch. Opt in explicitly; older
            // CLIs without the flag reject it, so fall back to the plain form for them.
            var start = await Shell.runAsyncResult(binary, ["system", "start", "--enable-kernel-install"])
            if start.exit != 0 {
                start = await Shell.runAsyncResult(binary, ["system", "start"])
            }
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
        let encodedName = DockerImageOps.queryValue("dory-binfmt")
        guard let create = await runtime.proxyRequest(method: "POST", path: "/containers/create?name=\(encodedName)",
            headers: [(name: "Content-Type", value: "application/json")], body: body),
            let id = decodeId(create.body) else { return }
        let encodedID = DockerImageOps.pathComponent(id)
        _ = await runtime.proxyRequest(method: "POST", path: "/containers/\(encodedID)/start", headers: [], body: Data())
    }

    private static func decodeId(_ data: Data) -> String? {
        struct Out: Decodable { let Id: String }
        return (try? JSONDecoder().decode(Out.self, from: data))?.Id
    }

    static func stop() async {
        stopHelper()
        guard let binary = containerBinary() else { return }
        _ = await Shell.runAsyncResult(binary, ["stop", engineName])
    }

    static func stopEngineCommand() -> (binary: String, arguments: [String])? {
        guard let binary = containerBinary() else { return nil }
        return (binary, ["stop", engineName])
    }

    static func stopEngineDetached() {
        stopHelper()
        if let command = stopEngineCommand() {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: command.binary)
            process.arguments = command.arguments
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try? process.run()
        }
    }

    /// The shared VM's host-reachable IPv4 address (e.g. 192.168.64.x), used to forward published
    /// container ports to `localhost`.
    static func engineIP() async -> String? {
        if let binary = containerBinary() {
            let result = await Shell.runAsyncResult(binary, ["ls"])
            for line in result.output.split(separator: "\n") where line.contains(engineName) {
                for token in line.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
                    let candidate = token.split(separator: "/").first.map(String.init) ?? String(token)
                    if isIPv4(candidate) { return candidate }
                }
            }
        }
        return engineIPFromFile()
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

    private struct VMAssets {
        var kernel: String
        var initfs: String
    }

    private static func provisionInProcess(config: Config) async throws -> String? {
        guard ProcessInfo.processInfo.environment["DORY_DISABLE_INPROCESS_ENGINE"] != "1",
              let helper = helperBinary() else { return nil }
        guard let assets = await preparedVMAssets() else { return nil }

        if await isReachable() {
            if helperProcessIsAlive() { return socketPath }
            if let binary = containerBinary(), await engineIsCurrent(binary: binary) {
                _ = await Shell.runAsyncResult(binary, ["rm", "-f", engineName])
            } else {
                return socketPath
            }
        }

        let directory = (socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(atPath: socketPath)
        try? FileManager.default.removeItem(atPath: engineIPPath)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: helper)
        process.arguments = [
            "--shared-engine", socketPath,
            "--kernel", assets.kernel,
            "--initfs", assets.initfs,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["DORY_ENGINE_MEM_MB"] = environment["DORY_ENGINE_MEM_MB"] ?? String(config.memoryMB)
        environment["DORY_ENGINE_HEADROOM_MB"] = environment["DORY_ENGINE_HEADROOM_MB"] ?? String(config.headroomMB)
        environment["DORY_ENGINE_RECLAIM_SEC"] = environment["DORY_ENGINE_RECLAIM_SEC"] ?? "5"
        process.environment = environment

        FileManager.default.createFile(atPath: helperLogPath, contents: nil)
        let log = try? FileHandle(forWritingTo: URL(fileURLWithPath: helperLogPath))
        try? log?.seekToEnd()
        log?.write(Data("\n--- starting dory-vm \(Date()) mem=\(environment["DORY_ENGINE_MEM_MB"] ?? "?")MiB ---\n".utf8))
        process.standardOutput = log ?? FileHandle.nullDevice
        process.standardError = log ?? FileHandle.nullDevice

        do {
            try process.run()
            try? "\(process.processIdentifier)\n".write(toFile: helperPIDPath, atomically: true, encoding: .utf8)
            try? log?.close()
        } catch {
            try? log?.close()
            throw ProvisionError.engineStartFailed("\(error)")
        }

        guard await waitForReachable(attempts: 240) else {
            if process.isRunning { process.terminate() }
            throw ProvisionError.engineUnreachable
        }
        return socketPath
    }

    private static func preparedVMAssets() async -> VMAssets? {
        if let bundled = await prepareBundledVMAssets() { return bundled }
        return defaultVMAssets()
    }

    private static func prepareBundledVMAssets() async -> VMAssets? {
        guard let kernel = await prepareCompressedResource(
            resource: "dory-vm-kernel",
            outputName: "dory-vm-kernel"
        ),
        let initfs = await prepareCompressedResource(
            resource: "dory-vm-initfs.ext4",
            outputName: "dory-vm-initfs.ext4"
        ) else { return nil }
        return VMAssets(kernel: kernel, initfs: initfs)
    }

    private static func prepareCompressedResource(resource: String, outputName: String) async -> String? {
        guard let source = Bundle.main.url(forResource: resource, withExtension: "zst"),
              let zstd = zstdBinary() else { return nil }
        let directory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".dory/vm")
        let output = directory.appendingPathComponent(outputName)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if shouldRefreshAsset(source: source, output: output) {
            let result = await Shell.runAsyncResult(zstd, ["-d", "-q", "-f", source.path, "-o", output.path])
            guard result.exit == 0 else { return nil }
        }
        return FileManager.default.fileExists(atPath: output.path) ? output.path : nil
    }

    private static func shouldRefreshAsset(source: URL, output: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: output.path) else { return true }
        let sourceDate = try? source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let outputDate = try? output.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        guard let sourceDate, let outputDate else { return false }
        return outputDate < sourceDate
    }

    private static func defaultVMAssets() -> VMAssets? {
        guard let kernel = defaultKernelPath(),
              let initfs = defaultInitfsPath() else { return nil }
        return VMAssets(kernel: kernel, initfs: initfs)
    }

    private static func defaultKernelPath() -> String? {
        let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/com.apple.container/kernels")
        guard let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return nil }
        return entries
            .filter { $0.lastPathComponent.hasPrefix("vmlinux-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .last?
            .path
    }

    private static func defaultInitfsPath() -> String? {
        let support = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/com.apple.container")
        let preferred = support.appendingPathComponent("containers/dory-engine/initfs.ext4")
        if FileManager.default.fileExists(atPath: preferred.path) { return preferred.path }
        let containers = support.appendingPathComponent("containers")
        guard let entries = try? FileManager.default.contentsOfDirectory(at: containers, includingPropertiesForKeys: nil) else { return nil }
        return entries
            .map { $0.appendingPathComponent("initfs.ext4") }
            .first { FileManager.default.fileExists(atPath: $0.path) }?
            .path
    }

    private static func inProcessEngineAvailable() -> Bool {
        guard helperBinary() != nil else { return false }
        if Bundle.main.url(forResource: "dory-vm-kernel", withExtension: "zst") != nil,
           Bundle.main.url(forResource: "dory-vm-initfs.ext4", withExtension: "zst") != nil,
           zstdBinary() != nil {
            return true
        }
        return defaultVMAssets() != nil
    }

    private static func helperBinary() -> String? {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["DORY_VM_HELPER"],
           !override.isEmpty,
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        if let helper = bundledHelperPath(named: helperName),
           FileManager.default.isExecutableFile(atPath: helper) {
            return helper
        }

        let cwd = FileManager.default.currentDirectoryPath
        let devCandidates = [
            "\(cwd)/Packages/ContainerizationEngine/.build/out/Products/Debug/dory-vmboot",
            "\(cwd)/Packages/ContainerizationEngine/.build/out/Products/Release/dory-vmboot",
            "\(cwd)/Packages/ContainerizationEngine/.build/arm64-apple-macosx/debug/dory-vmboot",
            "\(cwd)/Packages/ContainerizationEngine/.build/arm64-apple-macosx/release/dory-vmboot",
        ]
        return devCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func zstdBinary() -> String? {
        if let helper = bundledHelperPath(named: "zstd"),
           FileManager.default.isExecutableFile(atPath: helper) {
            return helper
        }
        return Shell.find("zstd", candidates: zstdCandidates)
    }

    private static func bundledHelperPath(named name: String) -> String? {
        if let auxiliary = Bundle.main.url(forAuxiliaryExecutable: name)?.path {
            return auxiliary
        }
        let bundleURL = Bundle.main.bundleURL
        let candidates = [
            bundleURL.appendingPathComponent("Contents/Helpers/\(name)").path,
            bundleURL.appendingPathComponent("Helpers/\(name)").path,
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func engineIPFromFile() -> String? {
        guard let raw = try? String(contentsOfFile: engineIPPath, encoding: .utf8) else { return nil }
        let ip = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return isIPv4(ip) ? ip : nil
    }

    private static func helperProcessIsAlive() -> Bool {
        guard let pid = helperPID(), pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    private static func helperPID() -> pid_t? {
        guard let raw = try? String(contentsOfFile: helperPIDPath, encoding: .utf8),
              let value = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return pid_t(value)
    }

    private static func stopHelper() {
        guard let pid = helperPID(), pid > 0 else {
            try? FileManager.default.removeItem(atPath: helperPIDPath)
            return
        }
        if kill(pid, SIGTERM) == 0 {
            for _ in 0..<20 {
                if kill(pid, 0) != 0 { break }
                usleep(100_000)
            }
            if kill(pid, 0) == 0 { _ = kill(pid, SIGKILL) }
        }
        try? FileManager.default.removeItem(atPath: helperPIDPath)
        try? FileManager.default.removeItem(atPath: engineIPPath)
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    nonisolated static func memoryStringToMB(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        let suffix = trimmed.last
        let numberText: Substring
        let multiplier: Double
        switch suffix {
        case "g":
            numberText = trimmed.dropLast()
            multiplier = 1024
        case "m":
            numberText = trimmed.dropLast()
            multiplier = 1
        case "k":
            numberText = trimmed.dropLast()
            multiplier = 1.0 / 1024.0
        default:
            numberText = Substring(trimmed)
            multiplier = 1.0 / (1024.0 * 1024.0)
        }
        guard let value = Double(numberText), value > 0 else { return nil }
        return max(1, Int((value * multiplier).rounded(.up)))
    }
}
