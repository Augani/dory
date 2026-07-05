import Darwin
import Foundation

/// Brings up Dory's single shared Linux VM — `dory-hv`, our own VMM on Hypervisor.framework — which
/// hosts one Docker engine for ALL of Dory's workloads, the way OrbStack does. This is the sole
/// engine: it ships its own kernel, userspace networking (gvproxy), and a journaled data disk, so
/// it needs no Apple `container` toolchain and gives every user the same performance. Dory's Docker
/// runtime then drives the published socket.
enum SharedVMProvisioner {
    static var socketPath: String { "\(NSHomeDirectory())/.dory/engine.sock" }
    static var engineIPPath: String { "\(NSHomeDirectory())/.dory/engine.ip" }

    private static let zstdCandidates = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"]
    nonisolated private static let helperPIDPath = "\(NSHomeDirectory())/.dory/engine.pid"
    nonisolated private static let helperLogPath = "\(NSHomeDirectory())/.dory/engine.log"
    nonisolated static let defaultEngineMemoryMB = 2048
    nonisolated static let defaultEngineHeadroomMB = 512

    struct Config: Sendable {
        var cpus: Int
        /// Guest RAM ceiling. The engine reclaims below the ceiling via free page reporting, so a
        /// generous cap costs nothing until workloads actually use it; env vars can raise it.
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
        case engineUnavailable
        case engineStartFailed(String)
        case engineUnreachable
    }

    static func hostSupport(
        platform: MacHostPlatform = .current(),
        engineAvailable: Bool = hvEngineAvailable()
    ) -> RuntimeSupport {
        let base = DoryHVSupport.evaluate(platform: platform)
        guard base.isSupported else { return base }
        // The hardware is capable, but the engine's own binaries/kernel must be present and the
        // user must not have opted out (DORY_HV_ENGINE=0). Otherwise report it honestly so the app
        // falls back to a Docker-compatible engine instead of showing a misleading boot failure.
        guard engineAvailable else {
            return .unsupported("Dory's engine is unavailable on this install", issue: .missingToolchain)
        }
        return .supported
    }

    /// Whether the dory-hv engine can run here: the signed helper, gvproxy, and a resolvable kernel
    /// (bundled compressed resource, or an installed kernel) are all present. Default on; set
    /// DORY_HV_ENGINE=0 to force-disable for debugging. Synchronous, so host-support can call it.
    static func hvEngineAvailable(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard environment["DORY_HV_ENGINE"] != "0" else { return false }
        guard hvHelperBinary() != nil, gvproxyBinary() != nil else { return false }
        if Bundle.main.url(forResource: "dory-vm-kernel", withExtension: "zst") != nil { return true }
        return installedKernelPath() != nil
    }

    static func provision(config: Config = Config()) async throws -> String {
        let support = hostSupport()
        guard support.isSupported else {
            throw ProvisionError.unsupportedHost(support.reason)
        }
        guard let socket = try await provisionWithHVEngine(config: config) else {
            throw ProvisionError.engineUnavailable
        }
        return socket
    }

    static func runtime(config: Config = Config()) async -> DockerEngineRuntime? {
        guard let socket = try? await provision(config: config) else { return nil }
        return DockerEngineRuntime(socketPath: socket, kind: .sharedVM)
    }

    /// Dory's own VMM (dory-hv on Hypervisor.framework): elastic memory via free page reporting,
    /// SMP, and a persistent journaled data disk. Reuses a live engine; otherwise spawns the helper
    /// and waits for the docker socket.
    private static func provisionWithHVEngine(config: Config) async throws -> String? {
        guard let helper = hvHelperBinary(), let gvproxy = gvproxyBinary() else { return nil }
        guard let kernel = await hvKernelPath() else { return nil }

        if await isReachable(), helperProcessIsAlive() {
            return socketPath
        }
        stopHelper()

        let directory = (socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(atPath: socketPath)

        var arguments = engineArguments(config: config, kernel: kernel, gvproxy: gvproxy, rootfs: nil)
        // Offline builds ship the engine image; hand it to the helper so first launch needs no
        // network. Online builds omit it and the engine fetches the image once.
        if let rootfs = await hvRootfsPath() {
            arguments = engineArguments(config: config, kernel: kernel, gvproxy: gvproxy, rootfs: rootfs)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: helper)
        process.arguments = arguments

        FileManager.default.createFile(atPath: helperLogPath, contents: nil)
        let log = try? FileHandle(forWritingTo: URL(fileURLWithPath: helperLogPath))
        _ = try? log?.seekToEnd()
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
            throw ProvisionError.engineUnreachable
        }
        return socketPath
    }

    static func engineArguments(config: Config, kernel: String, gvproxy: String, rootfs: String?) -> [String] {
        var arguments = [
            "engine",
            "--engine-sock", socketPath,
            "--kernel", kernel,
            "--gvproxy", gvproxy,
            "--mem-mb", String(config.memoryMB),
            "--cpus", String(config.cpus),
            "--direct-ip",
        ]
        if let rootfs {
            arguments.append(contentsOf: ["--rootfs", rootfs])
        }
        // Share the user's home at its identical guest path so `-v ~/project:/app` bind mounts
        // resolve with no configuration — the OrbStack "just works" default. Plain virtio-fs (no
        // DAX): it matches OrbStack on realistic cache-resident workloads and, unlike DAX, has no
        // window-thrashing or read-only-file caveats, so it is the safe default for the whole home.
        let home = NSHomeDirectory()
        arguments.append(contentsOf: ["--share", "home=\(home):rw:at=\(home)"])
        return arguments
    }

    private static func hvKernelPath() async -> String? {
        if let bundled = await prepareCompressedResource(resource: "dory-vm-kernel", outputName: "dory-vm-kernel") {
            return bundled
        }
        return installedKernelPath()
    }

    /// The bundled, decompressed engine rootfs for OFFLINE builds. Online builds omit the resource
    /// and this returns nil, so the engine fetches the image once on first launch instead.
    private static func hvRootfsPath() async -> String? {
        await prepareCompressedResource(resource: "dory-engine-rootfs.ext4", outputName: "dory-engine-rootfs.ext4")
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

    /// Register x86/amd64 emulation in the shared VM so Intel images run on Apple silicon, the way
    /// OrbStack does. Idempotent: the binfmt installer is a no-op if amd64 is already registered.
    static func ensureEmulation() async {
        let runtime = DockerEngineRuntime(socketPath: socketPath, kind: .sharedVM)
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
    }

    static func stopEngineDetached() {
        stopHelper()
    }

    @discardableResult
    nonisolated static func resyncClockAfterWake(
        pid: pid_t? = helperPID(),
        isAlive: (pid_t) -> Bool = helperProcessIsAlive(pid:),
        signalSender: (pid_t, Int32) -> Int32 = Darwin.kill
    ) -> Bool {
        guard let pid, pid > 0 else { return false }
        guard isAlive(pid) else { return false }
        return signalSender(pid, SIGUSR1) == 0
    }

    /// The shared VM's host-reachable IPv4 address, written by the engine to `engine.ip`, used to
    /// forward published container ports to `localhost`.
    static func engineIP() async -> String? {
        engineIPFromFile()
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

    /// A vmlinux left by a prior Apple `container` install, used only as a dev convenience so the
    /// engine boots without the bundled kernel asset. Ships with the compressed kernel bundled.
    private static func installedKernelPath() -> String? {
        let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/com.apple.container/kernels")
        guard let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return nil }
        return entries
            .filter { $0.lastPathComponent.hasPrefix("vmlinux-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .last?
            .path
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
        return helperProcessIsAlive(pid: pid)
    }

    nonisolated private static func helperProcessIsAlive(pid: pid_t) -> Bool {
        return kill(pid, 0) == 0 || errno == EPERM
    }

    nonisolated private static func helperPID() -> pid_t? {
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
