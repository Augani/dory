import CryptoKit
import Darwin
import DoryCore
import Foundation

struct DorydHostPlatform: Sendable, Equatable {
    enum Architecture: Sendable, Equatable {
        case arm64
        case x86_64
        case unsupported(String)

        init(machineHardwareName: String) {
            switch machineHardwareName {
            case "arm64", "arm64e": self = .arm64
            case "x86_64": self = .x86_64
            default: self = .unsupported(machineHardwareName)
            }
        }

        var darwinName: String {
            switch self {
            case .arm64: "arm64"
            case .x86_64: "x86_64"
            case let .unsupported(name): name
            }
        }

        var supportsRawHV: Bool {
            switch self {
            case .arm64, .x86_64: true
            case .unsupported: false
            }
        }
    }

    var architecture: Architecture
    var macOSMajorVersion: Int
    var macOSMinorVersion: Int

    init(
        architecture: Architecture,
        macOSMajorVersion: Int,
        macOSMinorVersion: Int = 0
    ) {
        self.architecture = architecture
        self.macOSMajorVersion = macOSMajorVersion
        self.macOSMinorVersion = macOSMinorVersion
    }

    static var current: DorydHostPlatform {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return DorydHostPlatform(
            architecture: Architecture(machineHardwareName: ProcessInfo.processInfo.machineHardwareName),
            macOSMajorVersion: version.majorVersion,
            macOSMinorVersion: version.minorVersion
        )
    }

    /// The shipped dory-hv slices declare macOS 15.0 in LC_BUILD_VERSION. Keep the runtime gate
    /// at least as strict so a Sonoma host always selects the macOS 14 dory-vmm fallback.
    var supportsRawHV: Bool {
        architecture.supportsRawHV && macOSMajorVersion >= 15
    }
}

public struct DorydEnvironment: Sendable {
    public var values: [String: String]
    public var home: String
    public var cwd: String
    public var executablePath: String
    private var hostPlatform: DorydHostPlatform

    public init(
        values: [String: String] = ProcessInfo.processInfo.environment,
        home: String? = nil,
        cwd: String = FileManager.default.currentDirectoryPath,
        executablePath: String = ProcessInfo.processInfo.arguments.first ?? ""
    ) {
        self.init(
            values: values,
            home: home,
            cwd: cwd,
            executablePath: executablePath,
            hostPlatform: .current
        )
    }

    init(
        values: [String: String],
        home: String? = nil,
        cwd: String = FileManager.default.currentDirectoryPath,
        executablePath: String = ProcessInfo.processInfo.arguments.first ?? "",
        hostPlatform: DorydHostPlatform
    ) {
        self.values = values
        self.home = home ?? values["DORYD_HOME"] ?? NSHomeDirectory()
        self.cwd = cwd
        self.executablePath = executablePath
        self.hostPlatform = hostPlatform
    }

    public func dockerTierConfiguration() -> DockerTierConfiguration? {
        guard bool("DORYD_DOCKER_TIER", default: true) else { return nil }

        let stateDirectory = string("DORYD_STATE_DIR") ?? "\(home)/.dory/hv"
        let forwardSocket = string("DORYD_AGENT_VSOCK_FORWARD")
            ?? string("DORY_AGENT_VSOCK_FORWARD")
            ?? "\(stateDirectory)/agent-vsock-forward.sock"
        let cid = uint32("DORYD_GUEST_CID") ?? 3

        let explicitForward = string("DORYD_AGENT_VSOCK_FORWARD") != nil
            || string("DORY_AGENT_VSOCK_FORWARD") != nil
        let gpuRequested = venusRequested
        if gpuRequested, explicitForward {
            reportEngineConfigurationError(
                "DORYD_GPU=venus requires doryd's local dory-hv engine; external forwards must prove capability with DORYD_GPU_SUPPORTED"
            )
            return nil
        }
        if gpuRequested {
            guard rawHVSupported, hostGuestArch == "arm64" else {
                reportEngineConfigurationError(
                    "Venus GPU mode is release-verified only with the arm64 dory-hv engine"
                )
                return nil
            }
        }
        let hvProcess = rawHVSupported ? hvProcessConfiguration(
            stateDirectory: stateDirectory,
            forwardSocket: forwardSocket
        ) : nil

        // A requested Venus device must never degrade to the headless dory-vmm fallback. Missing or
        // unusable GPU assets make the engine unavailable so the app can restore the prior setting.
        if gpuRequested, hvProcess == nil {
            return nil
        }

        // On a host that supports the release raw-HV engine, its helper set is authoritative.
        // Falling through to a development-tree or VZ executable when one of those exact helpers
        // is missing can run a different implementation than the signed app selected.
        if rawHVSupported, hvProcess == nil, !explicitForward {
            return nil
        }

        if hvProcess == nil, !explicitForward,
           let vmmProcess = vmmDockerProcessConfiguration(stateDirectory: stateDirectory) {
            let dockerdSocket = "\(stateDirectory)/dockerd.sock"
            let agentSocket = "\(stateDirectory)/agent.sock"
            return DockerTierConfiguration(
                home: home,
                forwardSocketPath: forwardSocket,
                dockerdSocketPath: dockerdSocket,
                cid: cid,
                dockerPort: clampedDockerPort(),
                gpuSupported: false,
                activitySocketPath: string("DORYD_ACTIVITY_SOCK")
                    ?? "\(stateDirectory)/dataplane-activity.sock",
                vmmProcess: vmmProcess,
                agentControl: bool("DORYD_AGENT_CONTROL", default: true)
                    ? AgentControlConfiguration(directSocketPath: agentSocket)
                    : nil
            )
        }

        if hvProcess == nil, !explicitForward {
            return nil
        }

        return DockerTierConfiguration(
            home: home,
            forwardSocketPath: forwardSocket,
            cid: cid,
            dockerPort: clampedDockerPort(),
            gpuSupported: bool("DORYD_GPU_SUPPORTED", default: false)
                || gpuRequested,
            activitySocketPath: string("DORYD_ACTIVITY_SOCK")
                ?? "\(stateDirectory)/dataplane-activity.sock",
            hvProcess: hvProcess,
            agentControl: bool("DORYD_AGENT_CONTROL", default: true)
                ? AgentControlConfiguration(forwardSocketPath: forwardSocket, cid: cid)
                : nil
        )
    }

    public func networkingConfiguration() -> NetworkingConfiguration? {
        guard bool("DORYD_NETWORKING", default: false) || string("DORYD_DNS_PORT") != nil else {
            return nil
        }
        return NetworkingConfiguration(
            suffix: string("DORYD_DOMAIN_SUFFIX") ?? "dory.local",
            dnsBindAddress: string("DORYD_DNS_BIND") ?? "127.0.0.1",
            dnsPort: uint16("DORYD_DNS_PORT") ?? 1053,
            httpProxyPort: uint16("DORYD_HTTP_PROXY_PORT") ?? 8080,
            httpsProxyPort: uint16("DORYD_HTTPS_PROXY_PORT") ?? 8443,
            privilegedTCPForwards: privilegedTCPForwards(),
            localCACertificatePath: string("DORYD_CA_CERT") ?? "\(home)/.dory/ca/ca.crt"
        )
    }

    public func idleSleepConfiguration() -> IdleSleepConfiguration? {
        guard bool("DORYD_IDLE_SLEEP", default: true) else { return nil }
        let idleAfter = double("DORYD_IDLE_SLEEP_AFTER_SECONDS")
            ?? double("DORYD_IDLE_AFTER_SECONDS")
            ?? 300
        guard idleAfter > 0 else { return nil }
        let checkInterval = double("DORYD_IDLE_CHECK_INTERVAL_SECONDS")
            ?? min(30, max(5, idleAfter / 5))
        return IdleSleepConfiguration(
            enabled: true,
            idleAfterSeconds: idleAfter,
            checkIntervalSeconds: checkInterval
        )
    }

    public var hostCLIEnabled: Bool {
        bool("DORYD_HOST_CLI", default: true)
    }

    public var hostCLIReconcileIntervalSeconds: TimeInterval {
        max(30, double("DORYD_HOST_CLI_RECONCILE_SECONDS") ?? 300)
    }

    public var networkRouteReconcileIntervalSeconds: TimeInterval {
        max(1, double("DORYD_NETWORK_ROUTE_RECONCILE_SECONDS") ?? 5)
    }

    public func kubernetesServiceRouteProviderConfiguration() -> KubernetesServiceRouteProviderConfiguration {
        KubernetesServiceRouteProviderConfiguration(
            home: home,
            kubectlPath: hostToolPath(named: "kubectl"),
            kubeconfigPath: string("DORYD_KUBECONFIG")
                ?? string("DORY_KUBECONFIG")
                ?? "\(home)/.kube/dory-config",
            proxyPort: uint16("DORYD_KUBE_PROXY_PORT") ?? 18_001
        )
    }

    public func hostToolPath(named name: String) -> String? {
        let envName = name.uppercased().replacingOccurrences(of: "-", with: "_")
        let explicitKeys = ["DORYD_\(envName)_BIN", "DORY_\(envName)_BIN"]
        if let explicit = executablePath(firstOf: explicitKeys, fallbackCandidates: []) {
            return explicit
        }
        let candidates = ["\(home)/.dory/bin/\(name)"] + helperCandidates(named: name)
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public func machineManagerConfiguration() -> MachineManagerConfiguration? {
        guard let helper = executablePath(firstOf: ["DORYD_VMM_HELPER", "DORY_VMM_HELPER"], fallbackCandidates: helperCandidates(named: "dory-vmm")) else {
            return nil
        }
        let stateDirectory: String
        if let explicit = string("DORYD_MACHINE_STATE_DIR") {
            stateDirectory = explicit
        } else {
            guard let drive = dataDrive() else { return nil }
            stateDirectory = drive.machinesDirectory
        }
        return MachineManagerConfiguration(
            vmmExecutablePath: helper,
            stateDirectory: stateDirectory,
            runtimeDirectory: string("DORYD_MACHINE_RUNTIME_DIR") ?? "\(home)/.dory/machines",
            baseArguments: splitArguments(string("DORYD_VMM_ARGS") ?? ""),
            passMachineArguments: bool("DORYD_VMM_PASS_MACHINE_ARGS", default: true),
            logDirectory: string("DORYD_MACHINE_LOG_DIR") ?? "\(stateDirectory)/logs",
            requiresReadyHandoff: bool("DORYD_VMM_READY_HANDOFF", default: true)
        )
    }

    public func dataDriveConfiguration() throws -> DoryDataDrive {
        let explicit = string("DORYD_DATA_DRIVE") ?? string("DORY_DATA_DRIVE")
        let selected = explicit == nil
            ? try DoryDataDriveSelectionStore(home: home).selectedPath()
            : nil
        return try DoryDataDrive(
            home: home,
            overrideRoot: explicit ?? selected
        )
    }

    private func hvProcessConfiguration(
        stateDirectory: String,
        forwardSocket: String
    ) -> HvProcessConfiguration? {
        guard let helper = executablePath(firstOf: ["DORYD_HV_HELPER", "DORY_HV_HELPER"], fallbackCandidates: helperCandidates(named: "dory-hv")),
              let kernel = hvKernelPath(stateDirectory: stateDirectory),
              let gvproxy = executablePath(firstOf: ["DORYD_GVPROXY", "DORY_GVPROXY"], fallbackCandidates: gvproxyCandidates()) else {
            return nil
        }

        let legacyEngineSocket = string("DORYD_HV_ENGINE_SOCK") ?? "\(stateDirectory)/engine.sock"
        var arguments = [
            "engine",
            "--engine-sock", legacyEngineSocket,
            "--agent-vsock-forward", forwardSocket,
            "--kernel", kernel,
            "--gvproxy", gvproxy,
            "--state-dir", stateDirectory,
            "--mem-mb", String(clampedMemoryMB()),
            "--cpus", String(clampedCPUs()),
        ]
        guard let drive = dataDrive() else { return nil }
        arguments.append(contentsOf: ["--data-drive", drive.root])
        if let sshAuthSock = string("DORYD_SSH_AUTH_SOCK"), sshAuthSock.hasPrefix("/") {
            arguments.append(contentsOf: ["--ssh-agent-socket", sshAuthSock])
        }

        if bool("DORYD_DIRECT_IP", default: string("DORYD_PUBLISH_HOST") == "0.0.0.0") {
            arguments.append("--direct-ip")
        }
        if bool("DORYD_NATIVE_IPV6", default: true) {
            arguments.append("--direct-ipv6")
        }
        let engineRootfsNames = ["dory-engine-rootfs-\(hostGuestArch).ext4", "dory-engine-rootfs.ext4"]
        let engineRootfs = existingPath(firstOf: ["DORYD_ENGINE_ROOTFS", "DORY_ENGINE_ROOTFS"])
            ?? preparedBundledCompressedResource(
                named: engineRootfsNames,
                outputName: "dory-engine-rootfs-\(hostGuestArch).ext4",
                stateDirectory: stateDirectory
            )
        if let rootfs = engineRootfs {
            arguments.append(contentsOf: ["--rootfs", rootfs])
        } else if compressedResourceSourceExists(named: engineRootfsNames) {
            // A rootfs image was bundled but could not be prepared (e.g. decompression
            // failed). Launching without a rootfs would produce a broken engine, so refuse
            // to start rather than proceed silently.
            FileHandle.standardError.write(Data(
                "doryd: engine rootfs present but could not be prepared; not starting engine\n".utf8
            ))
            return nil
        } else if bool("DORYD_REQUIRE_ENGINE_ROOTFS", default: false) {
            return nil
        }
        if let guestAgent = guestAgentPath() {
            arguments.append(contentsOf: ["--guest-agent", guestAgent])
        }
        if venusRequested {
            arguments.append(contentsOf: ["--gpu", "venus"])
        }
        if hostGuestArch == "arm64", bool("DORYD_AMD64", default: false) {
            arguments.append("--amd64")
        }
        if string("DORYD_PUBLISH_HOST") == "0.0.0.0" {
            arguments.append(contentsOf: ["--publish-host", "0.0.0.0"])
        }
        for share in shares() {
            arguments.append(contentsOf: ["--share", share])
        }

        return HvProcessConfiguration(
            executablePath: helper,
            arguments: arguments,
            logPath: string("DORYD_HV_LOG") ?? "\(stateDirectory)/dory-hv.log",
            restartPolicy: HvRestartPolicy(
                maxRestarts: int("DORYD_HV_RESTART_LIMIT") ?? 3,
                delaySeconds: double("DORYD_HV_RESTART_DELAY") ?? 0.5,
                maximumDelaySeconds: double("DORYD_HV_RESTART_MAX_DELAY") ?? 5,
                stableRunSeconds: double("DORYD_HV_RESTART_STABLE_SECONDS") ?? 30
            )
        )
    }

    private func vmmDockerProcessConfiguration(stateDirectory: String) -> VmmDockerProcessConfiguration? {
        guard let helper = executablePath(firstOf: ["DORYD_VMM_HELPER", "DORY_VMM_HELPER"], fallbackCandidates: helperCandidates(named: "dory-vmm")),
              let gvproxy = executablePath(firstOf: ["DORYD_GVPROXY", "DORY_GVPROXY"], fallbackCandidates: gvproxyCandidates()),
              let kernel = existingPath(firstOf: ["DORYD_VMM_KERNEL", "DORY_VMM_KERNEL"])
                ?? preparedBundledCompressedResource(
                    named: ["dory-vm-kernel-\(hostGuestArch)", "dory-vm-kernel"],
                    outputName: "dory-vm-kernel-\(hostGuestArch)",
                    stateDirectory: stateDirectory
                ),
              let rootfs = existingPath(firstOf: ["DORYD_VMM_ROOTFS", "DORYD_ENGINE_ROOTFS", "DORY_ENGINE_ROOTFS"])
                ?? preparedBundledCompressedResource(
                    named: ["dory-engine-rootfs-\(hostGuestArch).ext4", "dory-engine-rootfs.ext4", "dory-vm-initfs-\(hostGuestArch).ext4"],
                    outputName: "dory-vz-engine-rootfs-\(hostGuestArch).ext4",
                    stateDirectory: stateDirectory
                )
                ?? preparedPersistentBundledResource(
                    named: ["dory-machine-rootfs-\(hostGuestArch).ext4", "dory-machine-rootfs.ext4"],
                    outputName: "dory-vz-engine-rootfs-\(hostGuestArch).ext4",
                    stateDirectory: stateDirectory
                ) else {
            return nil
        }

        let handoffSocket = "\(stateDirectory)/dory-vmm-docker-handoff.sock"
        let cmdline = "console=hvc0 root=/dev/vda rw rootwait panic=1 dory.machine_id=docker dory.home=\(home)"
        var arguments = [
            "--machine-id", "docker",
            "--state-dir", stateDirectory,
            "--kernel", kernel,
            "--rootfs", rootfs,
            "--gvproxy", gvproxy,
            "--handoff-sock", handoffSocket,
            "--memory-mb", String(clampedMemoryMB()),
            "--cpus", String(clampedCPUs()),
            "--cmdline", cmdline,
        ]
        guard let drive = dataDrive() else { return nil }
        arguments.append(contentsOf: ["--data-drive", drive.root])
        if let sshAuthSock = string("DORYD_SSH_AUTH_SOCK"), sshAuthSock.hasPrefix("/") {
            arguments.append(contentsOf: ["--ssh-agent-socket", sshAuthSock])
        }
        if bool("DORYD_SHARE_HOME", default: true) {
            arguments.append(contentsOf: ["--share", "home=\(home):\(home):rw"])
        }
        if string("DORYD_PUBLISH_HOST") == "0.0.0.0" {
            arguments.append(contentsOf: ["--publish-host", "0.0.0.0"])
        }

        return VmmDockerProcessConfiguration(
            executablePath: helper,
            arguments: arguments,
            stateDirectory: stateDirectory,
            handoffSocketPath: handoffSocket,
            logPath: string("DORYD_VMM_DOCKER_LOG") ?? "\(stateDirectory)/dory-vmm-docker.log",
            readyTimeoutSeconds: double("DORYD_VMM_DOCKER_READY_TIMEOUT") ?? 90,
            restartPolicy: HvRestartPolicy(
                maxRestarts: int("DORYD_HV_RESTART_LIMIT") ?? 3,
                delaySeconds: double("DORYD_HV_RESTART_DELAY") ?? 0.5,
                maximumDelaySeconds: double("DORYD_HV_RESTART_MAX_DELAY") ?? 5,
                stableRunSeconds: double("DORYD_HV_RESTART_STABLE_SECONDS") ?? 30
            )
        )
    }

    private func dataDrive() -> DoryDataDrive? {
        do {
            return try dataDriveConfiguration()
        } catch {
            FileHandle.standardError.write(Data("doryd: invalid data drive: \(error)\n".utf8))
            return nil
        }
    }

    private func shares() -> [String] {
        if let explicit = string("DORYD_SHARES") {
            return explicit.split(separator: ";").map(String.init).filter { !$0.isEmpty }
        }
        guard bool("DORYD_SHARE_HOME", default: true) else { return [] }
        return ["home=\(home):rw:at=\(home):safe"]
    }

    /// DORYD_GPU is authoritative when the app supplies it, including the explicit `off` value.
    /// The legacy variable remains a development fallback only when no daemon-owned choice exists.
    private var venusRequested: Bool {
        if let configured = string("DORYD_GPU") {
            return configured.lowercased() == "venus"
        }
        return string("DORY_EXPERIMENTAL_GPU")?.lowercased() == "venus"
    }

    /// Selects the kernel that matches the requested device contract. GPU mode accepts only a
    /// GPU-specific override or the architecture-suffixed GPU resource and prepares the compressed
    /// release asset into doryd's state directory. It intentionally has no headless fallback.
    private func hvKernelPath(stateDirectory: String) -> String? {
        guard venusRequested else {
            return existingPath(firstOf: ["DORYD_HV_KERNEL", "DORY_HV_KERNEL"])
                ?? bundledResource(named: ["dory-hv-kernel-\(hostGuestArch)", "dory-hv-kernel"])
        }

        guard hostGuestArch == "arm64" else {
            reportEngineConfigurationError("no release-verified Venus GPU kernel exists for \(hostGuestArch)")
            return nil
        }
        let resourceName = "dory-hv-kernel-gpu-\(hostGuestArch)"
        if let explicit = existingPath(firstOf: [
            "DORYD_HV_GPU_KERNEL_ARM64",
            "DORYD_HV_GPU_KERNEL",
            "DORY_HV_GPU_KERNEL_ARM64",
            "DORY_HV_GPU_KERNEL",
        ]) {
            return explicit
        }
        if let raw = bundledResource(named: [resourceName]) {
            return raw
        }
        if let prepared = preparedBundledCompressedResource(
            named: [resourceName],
            outputName: resourceName,
            stateDirectory: stateDirectory
        ) {
            return prepared
        }
        reportEngineConfigurationError(
            "Venus GPU mode requested but \(resourceName).lzfse is missing or could not be prepared"
        )
        return nil
    }

    private func reportEngineConfigurationError(_ message: String) {
        FileHandle.standardError.write(Data("doryd: \(message)\n".utf8))
    }

    private func helperCandidates(named name: String) -> [String] {
        let arch = hostDarwinArch
        let doryCorePackageRoot = "\(cwd)/dory-core-swift"
        let packageRoot = "\(cwd)/Packages/ContainerizationEngine"
        return [
            bundleHelpersDirectory.map { "\($0)/\(name)" },
            "\(cwd)/.build/debug/\(name)",
            "\(cwd)/.build/release/\(name)",
            "\(cwd)/.build/\(arch)-apple-macosx/debug/\(name)",
            "\(cwd)/.build/\(arch)-apple-macosx/release/\(name)",
            "\(doryCorePackageRoot)/.build/debug/\(name)",
            "\(doryCorePackageRoot)/.build/release/\(name)",
            "\(doryCorePackageRoot)/.build/\(arch)-apple-macosx/debug/\(name)",
            "\(doryCorePackageRoot)/.build/\(arch)-apple-macosx/release/\(name)",
            "\(cwd)/Helpers/\(name)",
            "\(cwd)/../Helpers/\(name)",
            "\(packageRoot)/.build/out/Products/Release/\(name)",
            "\(packageRoot)/.build/out/Products/Debug/\(name)",
            "\(packageRoot)/.build/apple/Products/Release/\(name)",
            "\(packageRoot)/.build/apple/Products/Debug/\(name)",
            "\(packageRoot)/.build/\(arch)-apple-macosx/release/\(name)",
            "\(packageRoot)/.build/\(arch)-apple-macosx/debug/\(name)",
        ].compactMap { $0 }
    }

    private func gvproxyCandidates() -> [String] {
        [
            bundleHelpersDirectory.map { "\($0)/gvproxy" },
            "\(cwd)/Helpers/gvproxy",
            "\(cwd)/../Helpers/gvproxy",
            "/opt/homebrew/opt/podman/libexec/podman/gvproxy",
            "/usr/local/opt/podman/libexec/podman/gvproxy",
            "/opt/homebrew/bin/gvproxy",
            "/usr/local/bin/gvproxy",
        ].compactMap { $0 }
    }

    private func executablePath(firstOf keys: [String], fallbackCandidates: [String]) -> String? {
        if let explicit = path(firstOf: keys) {
            return FileManager.default.isExecutableFile(atPath: explicit) ? explicit : nil
        }
        return fallbackCandidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func path(firstOf keys: [String]) -> String? {
        for key in keys {
            if let value = string(key), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func existingPath(firstOf keys: [String]) -> String? {
        guard let value = path(firstOf: keys),
              FileManager.default.fileExists(atPath: value) else {
            return nil
        }
        return value
    }

    private var hostDarwinArch: String {
        hostPlatform.architecture.darwinName
    }

    private var hostGuestArch: String {
        hostDarwinArch == "x86_64" ? "amd64" : "arm64"
    }

    private var rawHVSupported: Bool {
        guard hostPlatform.supportsRawHV else { return false }
        if string("DORYD_RAW_HV_SUPPORTED") != nil {
            return bool("DORYD_RAW_HV_SUPPORTED", default: true)
        }
        return true
    }

    private var bundleContentsDirectory: String? {
        guard !executablePath.isEmpty else { return nil }
        let executableURL = URL(fileURLWithPath: executablePath)
        let contentsURL = executableURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: contentsURL.path) else {
            return nil
        }
        return contentsURL.path
    }

    private var bundleResourcesDirectory: String? {
        guard let bundleContentsDirectory else { return nil }
        let resources = URL(fileURLWithPath: bundleContentsDirectory)
            .appendingPathComponent("Resources")
            .path
        return FileManager.default.fileExists(atPath: resources) ? resources : nil
    }

    private var bundleHelpersDirectory: String? {
        guard let bundleContentsDirectory else { return nil }
        let helpers = URL(fileURLWithPath: bundleContentsDirectory)
            .appendingPathComponent("Helpers")
            .path
        return FileManager.default.fileExists(atPath: helpers) ? helpers : nil
    }

    private func clampedCPUs() -> Int {
        max(1, int("DORYD_CPUS") ?? Self.hostScaledCPUCount())
    }

    private func clampedMemoryMB() -> Int {
        max(256, int("DORYD_MEMORY_MB") ?? Self.hostScaledMemoryMB())
    }

    /// Keep standalone doryd launches on the same elastic host-scaled defaults as Dory.app's
    /// LaunchAgent. Explicit DORYD_CPUS / DORYD_MEMORY_MB values always win.
    ///
    /// The vCPU count is capped at 6: measured bind-mount npm medians on an M2 Pro were 2.52 s at
    /// 2 vCPUs, 2.38 s at 4, 2.38 s at 6, and 3.34 s at 10 (with the completion-polling guest
    /// kernel; worse before it). Guest I/O parallelism saturates at the workload's own
    /// concurrency, while extra vCPUs add IPI/timer load and spill onto efficiency cores.
    public static func hostScaledCPUCount(activeProcessorCount: Int = ProcessInfo.processInfo.activeProcessorCount) -> Int {
        let available = max(1, activeProcessorCount)
        return min(6, min(available, max(4, available - 2)))
    }

    public static func hostScaledMemoryMB(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Int {
        let hostMB = Int(clamping: physicalMemory / (1024 * 1024))
        return max(2048, min(hostMB / 2, hostMB - 4096))
    }

    private func clampedDockerPort() -> UInt32 {
        min(65_535, uint32("DORYD_DOCKER_PORT") ?? 1026)
    }

    private func compressedResourceSourceExists(named names: [String]) -> Bool {
        for directory in resourceDirectories {
            for name in names {
                let source = URL(fileURLWithPath: directory)
                    .appendingPathComponent(name)
                    .appendingPathExtension("lzfse")
                if FileManager.default.fileExists(atPath: source.path) {
                    return true
                }
            }
        }
        return false
    }

    private func guestAgentPath() -> String? {
        if let explicit = existingPath(firstOf: ["DORYD_GUEST_AGENT", "DORY_GUEST_AGENT"]) {
            return explicit
        }
        if let bundled = bundledResource(named: ["dory-agent-linux-\(hostGuestArch)", "dory-agent-linux"]) {
            return bundled
        }
        let candidates = [
            bundleHelpersDirectory.map { "\($0)/dory-agent-linux-\(hostGuestArch)" },
            bundleHelpersDirectory.map { "\($0)/dory-agent-linux" },
            "\(cwd)/guest/out/dory-agent-\(hostGuestArch)",
            "\(cwd)/guest/out/dory-agent",
            "\(cwd)/dory-core/target/\(hostGuestArch == "arm64" ? "aarch64" : "x86_64")-unknown-linux-musl/release/dory-agent",
        ].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    private func bundledResource(named names: [String]) -> String? {
        for directory in resourceDirectories {
            for name in names {
                let path = URL(fileURLWithPath: directory).appendingPathComponent(name).path
                if FileManager.default.fileExists(atPath: path) {
                    return path
                }
            }
        }
        return nil
    }

    private func preparedBundledCompressedResource(
        named names: [String],
        outputName: String,
        stateDirectory: String
    ) -> String? {
        for directory in resourceDirectories {
            for name in names {
                let source = URL(fileURLWithPath: directory)
                    .appendingPathComponent(name)
                    .appendingPathExtension("lzfse")
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                return prepareCompressedResource(
                    source: source,
                    outputName: outputName,
                    stateDirectory: stateDirectory
                )
            }
        }
        return nil
    }

    private var resourceDirectories: [String] {
        if let explicit = string("DORYD_RESOURCES_DIR"), !explicit.isEmpty {
            return [explicit]
        }
        return [
            bundleResourcesDirectory,
            "\(cwd)/Resources",
            "\(cwd)/../Resources",
        ].compactMap { $0 }.filter { !$0.isEmpty }
    }

    private func preparedPersistentBundledResource(
        named names: [String],
        outputName: String,
        stateDirectory: String
    ) -> String? {
        guard let sourcePath = bundledResource(named: names) else { return nil }
        let directory = URL(fileURLWithPath: stateDirectory)
            .appendingPathComponent("assets", isDirectory: true)
        let output = directory.appendingPathComponent(outputName)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: output.path) {
                try FileManager.default.copyItem(atPath: sourcePath, toPath: output.path)
            }
            return FileManager.default.fileExists(atPath: output.path) ? output.path : nil
        } catch {
            return nil
        }
    }

    private func prepareCompressedResource(
        source: URL,
        outputName: String,
        stateDirectory: String
    ) -> String? {
        let directory = URL(fileURLWithPath: stateDirectory)
            .appendingPathComponent("assets", isDirectory: true)
        let output = directory.appendingPathComponent(outputName)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return try withAssetPreparationLock(directory: directory, outputName: outputName) {
                try removeAbandonedAssetPartials(directory: directory, outputName: outputName)
                let identity = try compressedResourceIdentity(source: source)
                let identityPath = output.appendingPathExtension("source-identity")
                let recordedIdentity = try? String(contentsOf: identityPath, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !preparedAssetExists(at: output) || recordedIdentity != identity {
                    let temporary = directory.appendingPathComponent("\(outputName).partial-\(UUID().uuidString)")
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    try DorydLZFSE.decompress(source: source.path, destination: temporary.path)
                    guard Darwin.rename(temporary.path, output.path) == 0 else {
                        throw posixError(path: output.path, code: errno)
                    }
                    // Publish identity last. A crash after the rootfs rename but before this write
                    // causes one safe repeat on the next run instead of trusting an unbound cache.
                    try Data((identity + "\n").utf8).write(to: identityPath, options: .atomic)
                }
                return preparedAssetExists(at: output) ? output.path : nil
            }
        } catch {
            FileHandle.standardError.write(Data(
                "doryd: failed to prepare \(source.lastPathComponent): \(error)\n".utf8
            ))
            return nil
        }
    }

    /// Serializes preparation across duplicate daemon/configuration processes. The lock is stable
    /// while per-attempt files are unique, so a process killed during decompression leaves a file
    /// that the next lock owner can identify and unlink without racing an active writer.
    private func withAssetPreparationLock<T>(
        directory: URL,
        outputName: String,
        operation: () throws -> T
    ) throws -> T {
        let lock = directory.appendingPathComponent(".\(outputName).prepare.lock")
        let descriptor = lock.path.withCString {
            Darwin.open($0, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        }
        guard descriptor >= 0 else { throw posixError(path: lock.path, code: errno) }
        defer { Darwin.close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == getuid(),
              status.st_nlink == 1 else {
            throw posixError(path: lock.path, code: EINVAL)
        }
        _ = Darwin.fchmod(descriptor, mode_t(0o600))
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else { throw posixError(path: lock.path, code: errno) }
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try operation()
    }

    private func removeAbandonedAssetPartials(directory: URL, outputName: String) throws {
        let prefix = "\(outputName).partial-"
        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        for entry in entries where entry.lastPathComponent.hasPrefix(prefix) {
            var status = stat()
            guard lstat(entry.path, &status) == 0 else {
                if errno == ENOENT { continue }
                throw posixError(path: entry.path, code: errno)
            }
            let kind = status.st_mode & S_IFMT
            guard kind == S_IFREG || kind == S_IFLNK else { continue }
            guard Darwin.unlink(entry.path) == 0 || errno == ENOENT else {
                throw posixError(path: entry.path, code: errno)
            }
        }
    }

    private func preparedAssetExists(at url: URL) -> Bool {
        var status = stat()
        return lstat(url.path, &status) == 0
            && status.st_mode & S_IFMT == S_IFREG
            && status.st_uid == getuid()
            && status.st_nlink == 1
    }

    /// Bind the cache to content rather than comparing unrelated mtimes (compressed bundle source
    /// versus locally decompressed output). Public bundles already contain the signed payload
    /// manifest, so their identity lookup is O(1); source/development layouts hash the compressed
    /// input directly and retain the same correctness contract.
    private func compressedResourceIdentity(source: URL) throws -> String {
        let payload = source.deletingLastPathComponent().appendingPathComponent("dory-payload-sha256.txt")
        if let text = try? String(contentsOf: payload, encoding: .utf8) {
            let suffix = "  Contents/Resources/\(source.lastPathComponent)"
            for line in text.split(whereSeparator: \.isNewline).map(String.init)
            where line.count == 64 + suffix.count && line.hasSuffix(suffix) {
                let digest = String(line.prefix(64))
                if digest.allSatisfy(\.isHexDigit), digest == digest.lowercased() {
                    return "sha256:\(digest)"
                }
            }
        }

        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return "sha256:\(digest)"
    }

    private func posixError(path: String, code: Int32) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSFilePathErrorKey: path]
        )
    }

    private func string(_ key: String) -> String? {
        values[key].flatMap { $0.isEmpty ? nil : $0 }
    }

    private func int(_ key: String) -> Int? {
        string(key).flatMap(Int.init)
    }

    private func uint32(_ key: String) -> UInt32? {
        string(key).flatMap(UInt32.init)
    }

    private func uint16(_ key: String) -> UInt16? {
        string(key).flatMap(UInt16.init)
    }

    private func double(_ key: String) -> TimeInterval? {
        string(key).flatMap(TimeInterval.init)
    }

    private func bool(_ key: String, default defaultValue: Bool) -> Bool {
        guard let value = string(key)?.lowercased() else { return defaultValue }
        if ["1", "true", "yes", "on"].contains(value) { return true }
        if ["0", "false", "no", "off"].contains(value) { return false }
        return defaultValue
    }

    private func splitArguments(_ raw: String) -> [String] {
        raw.split(separator: " ").map(String.init).filter { !$0.isEmpty }
    }

    private func privilegedTCPForwards() -> [PrivilegedTCPForward] {
        let raw = string("DORYD_PRIVILEGED_TCP_FORWARDS")
            ?? string("DORYD_PRIVILEGED_PORT_FORWARDS")
            ?? ""
        var forwards: [UInt16: PrivilegedTCPForward] = [:]
        for entry in raw.split(separator: ",") {
            let parts = entry.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  let listen = UInt16(String(parts[0]).trimmingCharacters(in: .whitespaces)),
                  let target = UInt16(String(parts[1]).trimmingCharacters(in: .whitespaces)) else {
                continue
            }
            forwards[listen] = PrivilegedTCPForward(listenPort: listen, targetPort: target)
        }
        return forwards.values.sorted { $0.listenPort < $1.listenPort }
    }
}

private extension ProcessInfo {
    var machineHardwareName: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }
}
