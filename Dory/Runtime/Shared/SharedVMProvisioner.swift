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
    nonisolated private static let helperPIDPath = "\(NSHomeDirectory())/.dory/engine.pid"
    nonisolated private static let helperLogPath = "\(NSHomeDirectory())/.dory/engine.log"
    nonisolated static let defaultEngineMemoryMB = 2048
    nonisolated static let defaultEngineHeadroomMB = 512
    nonisolated static var engineArch: String { MachineArch.host.rawValue }

    struct Config: Sendable {
        var cpus: Int
        /// Guest RAM ceiling. The engine reclaims below the ceiling via free page reporting, so a
        /// generous cap costs nothing until workloads actually use it; env vars can raise it.
        var memory: String
        var headroomMB: Int
        /// Opt-in x86/amd64 via Rosetta: runs the Virtualization.framework engine (which supports
        /// Rosetta) instead of dory-hv, so heavy amd64 images like SQL Server run reliably (proven).
        /// Trades away dory-hv's memory advantage while on, so it is a manual Settings toggle.
        var rosettaX86: Bool
        /// Opt-in experimental GPU acceleration: attaches a virtio-gpu/Venus device backed by
        /// virglrenderer + MoltenVK so Vulkan and compute workloads inside containers reach Apple
        /// Metal. Fails closed to headless when the host Venus runtime is missing, so it is a manual
        /// Settings toggle and takes effect on the next engine start.
        var gpuVenus: Bool

        nonisolated static let rosettaX86Key = "dory.rosettaX86Enabled"
        nonisolated static let gpuVenusKey = "dory.experimentalGPU"
        static let rosettaEngineMemoryMB = 3072

        nonisolated init(
            cpus: Int = 4,
            memory: String = "\(SharedVMProvisioner.defaultEngineMemoryMB)M",
            headroomMB: Int = SharedVMProvisioner.defaultEngineHeadroomMB,
            rosettaX86: Bool = UserDefaults.standard.bool(forKey: Config.rosettaX86Key),
            gpuVenus: Bool = UserDefaults.standard.bool(forKey: Config.gpuVenusKey)
        ) {
            self.cpus = cpus
            self.memory = memory
            self.headroomMB = headroomMB
            self.rosettaX86 = rosettaX86
            self.gpuVenus = gpuVenus
        }

        var memoryMB: Int {
            SharedVMProvisioner.memoryStringToMB(memory) ?? SharedVMProvisioner.defaultEngineMemoryMB
        }
    }

    enum ProvisionError: Error, Sendable {
        case unsupportedHost(String)
        case engineUnavailable
        case engineStartFailed(String)
        case engineUnreachable(String?)
    }

    /// The last meaningful line the engine logged before it failed, used to turn the generic
    /// "could not start" status into an actionable reason (an unknown flag, a stall after boot).
    nonisolated static func engineLogTail() -> String? {
        guard let raw = try? String(contentsOfFile: helperLogPath, encoding: .utf8) else { return nil }
        let lines = raw
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("---") }
        guard var last = lines.last else { return nil }
        for prefix in ["dory-engine: ", "dory-hv: "] where last.hasPrefix(prefix) {
            last = String(last.dropFirst(prefix.count))
        }
        // A booted-but-unreachable engine's last line is the VM IP; name that as a stall so the
        // status reads as a diagnosis rather than a stray address.
        if last.hasPrefix("vm ip ") {
            return "engine started but never became reachable (stalled after boot)"
        }
        return last
    }

    /// Whether the host Venus GPU runtime (a virglrenderer dylib plus a MoltenVK ICD) is present,
    /// bundled in the app or installed via Homebrew. Enabling GPU acceleration without it makes the
    /// engine fall back to headless, so the Settings toggle gates on this to stay honest.
    static func venusRuntimeAvailable(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        let fileManager = FileManager.default
        let rendererCandidates = [
            environment["DORY_VIRGLRENDERER_PATH"],
            environment["DORY_VIRGLRENDERER"],
            Bundle.main.privateFrameworksPath.map { "\($0)/libvirglrenderer.dylib" },
            Bundle.main.resourcePath.map { "\($0)/libvirglrenderer.dylib" },
            "/opt/homebrew/lib/libvirglrenderer.dylib",
            "/usr/local/lib/libvirglrenderer.dylib",
        ].compactMap { $0 }
        let icdCandidates = [
            environment["DORY_MOLTENVK_ICD"],
            Bundle.main.resourcePath.map { "\($0)/vulkan/icd.d/MoltenVK_icd.json" },
            "/opt/homebrew/etc/vulkan/icd.d/MoltenVK_icd.json",
            "/opt/homebrew/share/vulkan/icd.d/MoltenVK_icd.json",
            "/usr/local/etc/vulkan/icd.d/MoltenVK_icd.json",
            "/usr/local/share/vulkan/icd.d/MoltenVK_icd.json",
        ].compactMap { $0 }
        guard icdCandidates.contains(where: { fileManager.fileExists(atPath: $0) }) else { return false }
        // The Venus path exposes host-visible blobs by hv_vm_mapping the pointer virglrenderer returns
        // from virgl_renderer_resource_map (the libkrun/krunkit model), so probe the renderer actually
        // exports a blob-map entrypoint before enabling the toggle.
        for path in rendererCandidates where fileManager.fileExists(atPath: path) {
            guard let handle = dlopen(path, RTLD_LAZY | RTLD_LOCAL) else { continue }
            let hasBlobMap = dlsym(handle, "virgl_renderer_resource_map") != nil
                || dlsym(handle, "virgl_renderer_resource_get_map_ptr") != nil
            dlclose(handle)
            if hasBlobMap { return true }
        }
        return false
    }

    static func hostSupport(
        platform: MacHostPlatform = .current(),
        engineAvailable: Bool = hvEngineAvailable(),
        vzEngineAvailable: Bool = vmEngineAvailable(),
        hypervisorSupported: Bool = hostHypervisorSupported()
    ) -> RuntimeSupport {
        engineSupport(
            platform: platform,
            hvNativeAvailable: engineAvailable,
            vzSharedAvailable: vzEngineAvailable,
            hypervisorSupported: hypervisorSupported
        ).support
    }

    static func engineSupport(
        platform: MacHostPlatform = .current(),
        hvNativeAvailable: Bool = hvEngineAvailable(),
        vzSharedAvailable: Bool = vmEngineAvailable(),
        hypervisorSupported: Bool = hostHypervisorSupported()
    ) -> EngineSupportEvaluation {
        EngineSupport.evaluate(
            platform: platform,
            hvNativeAvailable: hvNativeAvailable,
            vzSharedAvailable: vzSharedAvailable,
            hypervisorSupported: hypervisorSupported
        )
    }

    /// Whether the dory-hv engine can run here: the signed helper, gvproxy, and a resolvable kernel
    /// (bundled compressed resource, or an installed kernel) are all present. Default on; set
    /// DORY_HV_ENGINE=0 to force-disable for debugging. Synchronous, so host-support can call it.
    static func hvEngineAvailable(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard environment["DORY_HV_ENGINE"] != "0" else { return false }
        guard hvHelperBinary() != nil, gvproxyBinary() != nil else { return false }
        if Bundle.main.url(forResource: hvKernelResourceName(), withExtension: "lzfse") != nil { return true }
        if engineArch == "arm64", Bundle.main.url(forResource: "dory-hv-kernel", withExtension: "lzfse") != nil { return true }
        if engineArch == "arm64", Bundle.main.url(forResource: vmKernelResourceName(), withExtension: "lzfse") != nil { return true }
        if engineArch == "arm64", Bundle.main.url(forResource: "dory-vm-kernel", withExtension: "lzfse") != nil { return true }
        guard engineArch == "arm64" else { return false }
        return installedKernelPath() != nil
    }

    static func vmEngineAvailable(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard environment["DORY_VM_ENGINE"] != "0" else { return false }
        guard vmHelperBinary() != nil else { return false }
        let hasKernel = Bundle.main.url(forResource: vmKernelResourceName(), withExtension: "lzfse") != nil
            || (engineArch == "arm64" && Bundle.main.url(forResource: "dory-vm-kernel", withExtension: "lzfse") != nil)
            || (engineArch == "arm64" && installedKernelPath() != nil)
        let hasInitfs = Bundle.main.url(forResource: vmInitfsResourceName(), withExtension: "lzfse") != nil
            || (engineArch == "arm64" && Bundle.main.url(forResource: "dory-vm-initfs.ext4", withExtension: "lzfse") != nil)
        return hasKernel && hasInitfs
    }

    static func hostHypervisorSupported() -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("kern.hv_support", &value, &size, nil, 0)
        return result == 0 && value == 1
    }

    static func provision(config: Config = Config()) async throws -> String {
        let evaluation = engineSupport()
        guard evaluation.support.isSupported else {
            throw ProvisionError.unsupportedHost(evaluation.support.reason)
        }
        // The Apple-Virtualization (VZ) engine is retired as an x86 path: it drives Apple's
        // ContainerManager, whose guest handshake never completes against Dory's own guest, so it only
        // stalls. x86/amd64 images now run on our own dory-hv engine via qemu binfmt (config.rosettaX86).
        // The VZ tier survives solely for Intel hosts that ship without the dory-hv assets.
        if evaluation.tier == .vzShared {
            guard let socket = try await provisionWithVZEngine(config: config, rosetta: false) else {
                throw ProvisionError.engineUnavailable
            }
            return socket
        }
        guard let socket = try await provisionWithHVEngine(config: config) else {
            throw ProvisionError.engineUnavailable
        }
        return socket
    }

    /// The Virtualization.framework engine. On Apple silicon it can opt into Rosetta x86
    /// translation; on Intel it runs the amd64 guest natively as the first shared-engine tier.
    /// Publishes to the same `engine.sock`, so the shim and docker context are unchanged.
    private static func provisionWithVZEngine(config: Config, rosetta: Bool, attempts: Int = 240) async throws -> String? {
        guard let helper = vmHelperBinary(),
              let kernel = await vmKernelPath(),
              let initfs = await vmInitfsPath() else { return nil }

        if await isReachable(), helperProcessIsAlive() {
            return socketPath
        }
        stopHelper()

        let directory = (socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(atPath: socketPath)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: helper)
        process.arguments = ["--shared-engine", socketPath, "--kernel", kernel, "--initfs", initfs]
        var environment = ProcessInfo.processInfo.environment
        if rosetta {
            environment["DORY_ENGINE_ROSETTA"] = "1"
        }
        // SQL Server refuses to start below 2 GB; default Rosetta launches to 3 GB headroom.
        if rosetta && environment["DORY_ENGINE_MEM_MB"] == nil {
            environment["DORY_ENGINE_MEM_MB"] = String(max(Config.rosettaEngineMemoryMB, config.memoryMB))
        }
        process.environment = environment

        FileManager.default.createFile(atPath: helperLogPath, contents: nil)
        let log = try? FileHandle(forWritingTo: URL(fileURLWithPath: helperLogPath))
        _ = try? log?.seekToEnd()
        let label = rosetta ? "VZ+Rosetta" : "VZ"
        log?.write(Data("\n--- starting \(label) engine \(Date()) mem=\(environment["DORY_ENGINE_MEM_MB"] ?? config.memory) ---\n".utf8))
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

        guard await waitForReachable(attempts: attempts, process: process) else {
            if process.isRunning { process.terminate() }
            throw ProvisionError.engineUnreachable(engineLogTail())
        }
        return socketPath
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
        guard let kernel = await hvKernelPath(gpu: config.gpuVenus || ProcessInfo.processInfo.environment["DORY_EXPERIMENTAL_GPU"] == "venus") else { return nil }
        installGuestAgentForHVEngine()

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

        guard await waitForReachable(attempts: 240, process: process) else {
            if process.isRunning { process.terminate() }
            throw ProvisionError.engineUnreachable(engineLogTail())
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
        if config.gpuVenus || ProcessInfo.processInfo.environment["DORY_EXPERIMENTAL_GPU"] == "venus" {
            arguments.append(contentsOf: ["--gpu", "venus"])
        }
        // Opt-in x86/amd64 emulation: the guest registers a qemu binfmt handler so `--platform
        // linux/amd64` images run on the arm64 dory-hv engine. Off by default to keep the guest lean.
        if config.rosettaX86 {
            arguments.append("--amd64")
        }
        // Share the user's home at its identical guest path so `-v ~/project:/app` bind mounts
        // resolve with no configuration — the OrbStack "just works" default. Plain virtio-fs (no
        // DAX): matches OrbStack on realistic workloads with none of DAX's caveats. `:safe` hides
        // credential stores and shell rc files (`~/.ssh`, `~/.aws`, `Library`, …) from every
        // container as defense-in-depth; per-bind-mount on-demand sharing is the stronger follow-up.
        let home = NSHomeDirectory()
        arguments.append(contentsOf: ["--share", "home=\(home):rw:at=\(home):safe"])
        return arguments
    }

    private static func hvKernelPath(gpu: Bool = false) async -> String? {
        if let override = ProcessInfo.processInfo.environment["DORY_HV_KERNEL"],
           !override.isEmpty, FileManager.default.fileExists(atPath: override) {
            return override
        }
        if gpu,
           let bundled = await prepareCompressedResource(resource: hvGPUKernelResourceName(), outputName: hvGPUKernelOutputName()) {
            return bundled
        }
        if let bundled = await prepareCompressedResource(resource: hvKernelResourceName(), outputName: hvKernelOutputName()) {
            return bundled
        }
        if engineArch == "arm64",
           let bundled = await prepareCompressedResource(resource: "dory-hv-kernel", outputName: "dory-hv-kernel") {
            return bundled
        }
        if engineArch == "arm64",
           let bundled = await prepareCompressedResource(resource: vmKernelResourceName(), outputName: vmKernelOutputName()) {
            return bundled
        }
        if engineArch == "arm64",
           let bundled = await prepareCompressedResource(resource: "dory-vm-kernel", outputName: "dory-vm-kernel") {
            return bundled
        }
        guard engineArch == "arm64" else { return nil }
        return installedKernelPath()
    }

    private static func vmKernelPath() async -> String? {
        if let bundled = await prepareCompressedResource(resource: vmKernelResourceName(), outputName: vmKernelOutputName()) {
            return bundled
        }
        guard engineArch == "arm64" else { return nil }
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
        return helperDevCandidates(named: "dory-hv", cwd: cwd).first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func vmHelperBinary() -> String? {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["DORY_VM_HELPER"],
           !override.isEmpty,
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        if let helper = bundledHelperPath(named: "dory-vm"),
           FileManager.default.isExecutableFile(atPath: helper) {
            return helper
        }
        let cwd = FileManager.default.currentDirectoryPath
        return helperDevCandidates(named: "dory-vmboot", cwd: cwd).first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    nonisolated static func helperDevCandidates(
        named helperName: String,
        cwd: String,
        hostArch: String = engineArch
    ) -> [String] {
        let swiftPMArch = hostArch == "amd64" ? "x86_64" : hostArch
        let packageRoot = "\(cwd)/Packages/ContainerizationEngine"
        return [
            "\(packageRoot)/.build/out/Products/Release/\(helperName)",
            "\(packageRoot)/.build/out/Products/Debug/\(helperName)",
            "\(packageRoot)/.build/apple/Products/Release/\(helperName)",
            "\(packageRoot)/.build/apple/Products/Debug/\(helperName)",
            "\(packageRoot)/.build/\(swiftPMArch)-apple-macosx/release/\(helperName)",
            "\(packageRoot)/.build/\(swiftPMArch)-apple-macosx/debug/\(helperName)",
        ]
    }

    private static func vmInitfsPath() async -> String? {
        if let bundled = await prepareCompressedResource(resource: vmInitfsResourceName(), outputName: vmInitfsOutputName()) {
            return bundled
        }
        guard engineArch == "arm64" else { return nil }
        return await prepareCompressedResource(resource: "dory-vm-initfs.ext4", outputName: "dory-vm-initfs.ext4")
    }

    nonisolated static func vmKernelResourceName(arch: String = engineArch) -> String {
        "dory-vm-kernel-\(arch)"
    }

    nonisolated static func vmKernelOutputName(arch: String = engineArch) -> String {
        "dory-vm-kernel-\(arch)"
    }

    nonisolated static func hvKernelResourceName(arch: String = engineArch) -> String {
        "dory-hv-kernel-\(arch)"
    }

    nonisolated static func hvKernelOutputName(arch: String = engineArch) -> String {
        "dory-hv-kernel-\(arch)"
    }

    nonisolated static func hvGPUKernelResourceName(arch: String = engineArch) -> String {
        "dory-hv-kernel-gpu-\(arch)"
    }

    nonisolated static func hvGPUKernelOutputName(arch: String = engineArch) -> String {
        "dory-hv-kernel-gpu-\(arch)"
    }

    nonisolated static func vmInitfsResourceName(arch: String = engineArch) -> String {
        "dory-vm-initfs-\(arch).ext4"
    }

    nonisolated static func vmInitfsOutputName(arch: String = engineArch) -> String {
        "dory-vm-initfs-\(arch).ext4"
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

    private static func installGuestAgentForHVEngine() {
        guard let source = guestAgentSourceBinary() else { return }
        let directory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".dory/bin")
        let destination = directory.appendingPathComponent(guestAgentInstallName())
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if shouldRefreshAsset(source: URL(fileURLWithPath: source), output: destination) {
                let temporary = destination.appendingPathExtension("partial")
                try? FileManager.default.removeItem(at: temporary)
                try FileManager.default.copyItem(atPath: source, toPath: temporary.path)
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.path)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
        } catch {
            try? FileManager.default.removeItem(at: destination.appendingPathExtension("partial"))
        }
    }

    nonisolated static func guestAgentInstallName(arch: String = engineArch) -> String {
        "dory-agent-linux-\(arch)"
    }

    private static func guestAgentSourceBinary() -> String? {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["DORY_GUEST_AGENT"],
           !override.isEmpty,
           FileManager.default.fileExists(atPath: override) {
            return override
        }
        let installName = guestAgentInstallName()
        if let resource = Bundle.main.url(forResource: installName, withExtension: nil),
           FileManager.default.fileExists(atPath: resource.path) {
            return resource.path
        }
        if let helper = bundledHelperPath(named: installName),
           FileManager.default.fileExists(atPath: helper) {
            return helper
        }
        let cwd = FileManager.default.currentDirectoryPath
        let candidates = [
            "\(cwd)/guest/out/dory-agent-\(engineArch)",
            "\(cwd)/guest/out/dory-agent",
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Register the non-native CPU architecture in the shared VM. On Apple silicon this installs
    /// amd64; on Intel it installs arm64. Idempotent when the handler is already registered.
    static func ensureEmulation(for arch: MachineArch = .nonNativeHost) async {
        guard !arch.isNative else { return }
        let runtime = DockerEngineRuntime(socketPath: socketPath, kind: .sharedVM)
        try? await runtime.pull(image: "tonistiigi/binfmt")
        let body = binfmtInstallBody(for: arch)
        let encodedName = DockerImageOps.queryValue("dory-binfmt")
        guard let create = await runtime.proxyRequest(method: "POST", path: "/containers/create?name=\(encodedName)",
            headers: [(name: "Content-Type", value: "application/json")], body: body),
            let id = decodeId(create.body) else { return }
        let encodedID = DockerImageOps.pathComponent(id)
        _ = await runtime.proxyRequest(method: "POST", path: "/containers/\(encodedID)/start", headers: [], body: Data())
    }

    nonisolated static func binfmtInstallBody(for arch: MachineArch) -> Data {
        Data(#"{"Image":"tonistiigi/binfmt","Cmd":["--install","\#(arch.rawValue)"],"HostConfig":{"Privileged":true,"AutoRemove":true}}"#.utf8)
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

    /// Polls the engine's docker socket until it answers, giving up after `attempts` half-second
    /// ticks. When a `process` is supplied, a dead engine short-circuits the wait: if the helper
    /// exits (a rejected flag, a crash, an AMFI SIGKILL) there is no socket to wait for, so we fail
    /// in a tick instead of polling a dead socket for the full timeout window.
    private static func waitForReachable(attempts: Int = 60, process: Process? = nil) async -> Bool {
        for _ in 0..<attempts {
            if await isReachable() { return true }
            if let process, !process.isRunning {
                return await isReachable()
            }
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
        guard let source = Bundle.main.url(forResource: resource, withExtension: "lzfse") else { return nil }
        let directory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".dory/vm")
        let output = directory.appendingPathComponent(outputName)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if shouldRefreshAsset(source: source, output: output) {
            let temporary = output.appendingPathExtension("partial")
            do {
                try LZFSE.decompress(source: source.path, destination: temporary.path)
                _ = try? FileManager.default.removeItem(at: output)
                try FileManager.default.moveItem(at: temporary, to: output)
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                return nil
            }
        }
        return FileManager.default.fileExists(atPath: output.path) ? output.path : nil
    }

    private static func shouldRefreshAsset(source: URL, output: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: output.path) else { return true }
        let sourceValues = try? source.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let outputValues = try? output.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        if let sourceSize = sourceValues?.fileSize, let outputSize = outputValues?.fileSize,
           sourceSize != outputSize {
            return true
        }
        if let sourceDate = sourceValues?.contentModificationDate,
           let outputDate = outputValues?.contentModificationDate {
            return outputDate < sourceDate
        }
        return false
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
