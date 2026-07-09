import Foundation
import Testing
@testable import Dory

struct RuntimeSupportTests {
    // Dory's native dory-hv tier runs on Apple silicon and is preferred on Intel when raw PVH assets
    // are present. Intel falls back to the VZ shared tier when only amd64 VZ assets are available.
    @Test func engineSupportsMacOS14AppleSilicon() {
        let sonoma = MacHostPlatform(major: 14, minor: 0, patch: 0, architecture: "arm64")
        let evaluation = SharedVMProvisioner.engineSupport(
            platform: sonoma,
            hvNativeAvailable: true,
            vzSharedAvailable: false,
            hypervisorSupported: true
        )
        #expect(evaluation.tier == .hvNative)
        #expect(evaluation.support.isSupported)
        #expect(evaluation.support.issue == RuntimeSupport.Issue.none)
    }

    @Test func engineSupportsCurrentMacOSAppleSilicon() {
        let tahoe = MacHostPlatform(major: 26, minor: 1, patch: 0, architecture: "arm64")
        #expect(SharedVMProvisioner.hostSupport(
            platform: tahoe,
            engineAvailable: true,
            vzEngineAvailable: false,
            hypervisorSupported: true
        ).isSupported)
    }

    @Test func intelUsesVZSharedTierWhenAssetsExist() {
        let intel = MacHostPlatform(major: 14, minor: 7, patch: 0, architecture: "x86_64")
        let evaluation = SharedVMProvisioner.engineSupport(
            platform: intel,
            hvNativeAvailable: false,
            vzSharedAvailable: true,
            hypervisorSupported: true
        )
        #expect(evaluation.tier == .vzShared)
        #expect(evaluation.support.isSupported)
    }

    @Test func intelPrefersNativeHVTierWhenRawEngineAssetsExist() {
        let intel = MacHostPlatform(major: 14, minor: 7, patch: 0, architecture: "x86_64")
        let evaluation = SharedVMProvisioner.engineSupport(
            platform: intel,
            hvNativeAvailable: true,
            vzSharedAvailable: true,
            hypervisorSupported: true
        )
        #expect(evaluation.tier == .hvNative)
        #expect(evaluation.support.isSupported)
    }

    @Test func intelFallsBackToProxyOnlyWhenAssetsAreMissing() {
        let intel = MacHostPlatform(major: 14, minor: 7, patch: 0, architecture: "x86_64")
        let evaluation = SharedVMProvisioner.engineSupport(
            platform: intel,
            hvNativeAvailable: false,
            vzSharedAvailable: false,
            hypervisorSupported: true
        )
        #expect(evaluation.tier == .proxyOnly)
        #expect(!evaluation.support.isSupported)
        #expect(evaluation.support.issue == .missingToolchain)
    }

    @Test func engineRejectsMacOSOlderThan14() {
        let ventura = MacHostPlatform(major: 13, minor: 6, patch: 0, architecture: "arm64")
        let support = SharedVMProvisioner.hostSupport(
            platform: ventura,
            engineAvailable: true,
            vzEngineAvailable: true,
            hypervisorSupported: true
        )
        #expect(!support.isSupported)
        #expect(support.issue == .osVersion)
    }

    @Test func capableHardwareIsUnsupportedWhenEngineUnavailable() {
        // Right Mac, but the engine's binaries/kernel are missing or the user opted out
        // (DORY_HV_ENGINE=0): report unavailable so the app falls back to a Docker-compatible
        // engine rather than showing a misleading boot failure.
        let sequoia = MacHostPlatform(major: 15, minor: 4, patch: 0, architecture: "arm64")
        let support = SharedVMProvisioner.hostSupport(
            platform: sequoia,
            engineAvailable: false,
            vzEngineAvailable: true,
            hypervisorSupported: true
        )
        #expect(!support.isSupported)
        #expect(support.issue == .missingToolchain)
    }

    @Test func engineSupportEvaluatesOSVersionBeforeTierAssets() {
        let oldIntel = MacHostPlatform(major: 13, minor: 0, patch: 0, architecture: "x86_64")
        let evaluation = SharedVMProvisioner.engineSupport(
            platform: oldIntel,
            hvNativeAvailable: false,
            vzSharedAvailable: true,
            hypervisorSupported: true
        )
        #expect(evaluation.tier == .proxyOnly)
        #expect(evaluation.support.issue == .osVersion)
    }

    @Test func engineSupportRequiresHypervisorFramework() {
        let intel = MacHostPlatform(major: 14, minor: 7, patch: 0, architecture: "x86_64")
        let evaluation = SharedVMProvisioner.engineSupport(
            platform: intel,
            hvNativeAvailable: false,
            vzSharedAvailable: true,
            hypervisorSupported: false
        )
        #expect(evaluation.tier == .proxyOnly)
        #expect(evaluation.support.issue == .hypervisor)
    }

    @Test func nativeHVPlatformSupportIncludesIntelMacsAtTheMacOS14Floor() {
        let intel = MacHostPlatform(major: 14, minor: 7, patch: 0, architecture: "x86_64")
        #expect(DoryHVSupport.evaluate(platform: intel).isSupported)
    }

    @Test func hvEngineDisabledByOptOutFlag() {
        // DORY_HV_ENGINE=0 force-disables the engine even when binaries are present.
        #expect(!SharedVMProvisioner.hvEngineAvailable(environment: ["DORY_HV_ENGINE": "0"]))
    }

    @Test func sharedVMDefaultMemoryPolicyIsBelowLegacyFourGiB() {
        let config = SharedVMProvisioner.Config()
        #expect(config.memory == "2048M")
        #expect(config.memoryMB == 2048)
        #expect(config.headroomMB == 512)
    }

    @Test func sharedVMMemoryParserHandlesDockerStyleUnits() {
        #expect(SharedVMProvisioner.memoryStringToMB("2G") == 2048)
        #expect(SharedVMProvisioner.memoryStringToMB("1536M") == 1536)
        #expect(SharedVMProvisioner.memoryStringToMB("1073741824") == 1024)
    }

    @Test func sharedVMEngineArgumentsStartDirectIPBridge() {
        let arguments = SharedVMProvisioner.engineArguments(
            config: SharedVMProvisioner.Config(cpus: 6, memory: "3G"),
            kernel: "/tmp/kernel",
            gvproxy: "/tmp/gvproxy",
            rootfs: "/tmp/rootfs.ext4",
            guestAgent: "/tmp/dory-agent"
        )

        #expect(arguments.contains("--direct-ip"))
        #expect(argumentValue(after: "--kernel", in: arguments) == "/tmp/kernel")
        #expect(argumentValue(after: "--gvproxy", in: arguments) == "/tmp/gvproxy")
        #expect(argumentValue(after: "--rootfs", in: arguments) == "/tmp/rootfs.ext4")
        #expect(argumentValue(after: "--guest-agent", in: arguments) == "/tmp/dory-agent")
        #expect(argumentValue(after: "--mem-mb", in: arguments) == "3072")
        #expect(argumentValue(after: "--cpus", in: arguments) == "6")
    }

    @Test func sharedVMEngineArgumentsShareHomeAtItsRealPath() {
        let arguments = SharedVMProvisioner.engineArguments(
            config: SharedVMProvisioner.Config(cpus: 4, memory: "2G"),
            kernel: "/tmp/kernel",
            gvproxy: "/tmp/gvproxy",
            rootfs: nil
        )

        let home = NSHomeDirectory()
        #expect(argumentValue(after: "--share", in: arguments) == "home=\(home):rw:at=\(home):safe")
    }

    @Test func sharedVMEngineArgumentsAppendValidDaxDataSharesOnly() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dory-dax-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.standardizedFileURL.path

        let arguments = SharedVMProvisioner.engineArguments(
            config: SharedVMProvisioner.Config(cpus: 4, memory: "2G", daxDataShares: [path, "/no/such/dax/dir", path]),
            kernel: "/tmp/kernel",
            gvproxy: "/tmp/gvproxy",
            rootfs: nil
        )

        let home = NSHomeDirectory()
        #expect(arguments.contains("home=\(home):rw:at=\(home):safe"))       // home stays non-DAX
        #expect(arguments.contains("daxdata0=\(path):rw:dax:at=\(path):safe")) // existing dir -> DAX share
        #expect(!arguments.contains { $0.contains("/no/such/dax/dir") })      // missing path dropped
        #expect(arguments.filter { $0.hasPrefix("daxdata") }.count == 1)      // de-duplicated
    }

    @Test func sharedVMResourceNamesAreArchSuffixed() {
        #expect(SharedVMProvisioner.hvKernelResourceName(arch: "arm64") == "dory-hv-kernel-arm64")
        #expect(SharedVMProvisioner.hvKernelResourceName(arch: "amd64") == "dory-hv-kernel-amd64")
        #expect(SharedVMProvisioner.vmKernelResourceName(arch: "arm64") == "dory-vm-kernel-arm64")
        #expect(SharedVMProvisioner.vmKernelResourceName(arch: "amd64") == "dory-vm-kernel-amd64")
        #expect(SharedVMProvisioner.vmInitfsResourceName(arch: "arm64") == "dory-vm-initfs-arm64.ext4")
        #expect(SharedVMProvisioner.vmInitfsResourceName(arch: "amd64") == "dory-vm-initfs-amd64.ext4")
    }

    @Test func sharedVMHelperDevCandidatesCoverUniversalOutAndHostArchBuilds() {
        let arm64 = SharedVMProvisioner.helperDevCandidates(named: "dory-hv", cwd: "/repo", hostArch: "arm64")
        let amd64 = SharedVMProvisioner.helperDevCandidates(named: "dory-hv", cwd: "/repo", hostArch: "amd64")

        #expect(arm64.contains("/repo/Packages/ContainerizationEngine/.build/out/Products/Debug/dory-hv"))
        #expect(arm64.contains("/repo/Packages/ContainerizationEngine/.build/apple/Products/Debug/dory-hv"))
        #expect(arm64.contains("/repo/Packages/ContainerizationEngine/.build/arm64-apple-macosx/debug/dory-hv"))

        #expect(amd64.contains("/repo/Packages/ContainerizationEngine/.build/out/Products/Debug/dory-hv"))
        #expect(amd64.contains("/repo/Packages/ContainerizationEngine/.build/apple/Products/Debug/dory-hv"))
        #expect(amd64.contains("/repo/Packages/ContainerizationEngine/.build/x86_64-apple-macosx/debug/dory-hv"))
        #expect(!amd64.contains("/repo/Packages/ContainerizationEngine/.build/arm64-apple-macosx/debug/dory-hv"))
    }

    @Test func sharedVMEmulationInstallerTargetsRequestedArch() throws {
        let arm64 = try JSONSerialization.jsonObject(with: SharedVMProvisioner.binfmtInstallBody(for: .arm64)) as? [String: Any]
        let amd64 = try JSONSerialization.jsonObject(with: SharedVMProvisioner.binfmtInstallBody(for: .amd64)) as? [String: Any]

        #expect(arm64?["Image"] as? String == "tonistiigi/binfmt")
        #expect(arm64?["Cmd"] as? [String] == ["--install", "arm64"])
        #expect(amd64?["Cmd"] as? [String] == ["--install", "amd64"])
        let hostConfig = arm64?["HostConfig"] as? [String: Any]
        #expect(hostConfig?["Privileged"] as? Bool == true)
        #expect(hostConfig?["AutoRemove"] as? Bool == true)
    }

    @Test func wakeClockResyncSignalsLiveHelperOnly() {
        var sent: [(pid_t, Int32)] = []
        let signaler: (pid_t, Int32) -> Int32 = { pid, signal in
            sent.append((pid, signal))
            return 0
        }

        #expect(SharedVMProvisioner.resyncClockAfterWake(
            pid: 1234,
            isAlive: { $0 == 1234 },
            signalSender: signaler
        ))
        #expect(sent.count == 1)
        #expect(sent[0].0 == 1234)
        #expect(sent[0].1 == SIGUSR1)

        sent.removeAll()
        #expect(!SharedVMProvisioner.resyncClockAfterWake(
            pid: 1234,
            isAlive: { _ in false },
            signalSender: signaler
        ))
        #expect(sent.isEmpty)
        #expect(!SharedVMProvisioner.resyncClockAfterWake(
            pid: nil,
            isAlive: { _ in true },
            signalSender: signaler
        ))
    }

    @Test func dockerCompatibleRequirementNamesOlderMacFallbacks() {
        let message = AppStore.dockerCompatibleEngineRequired("Linux machines")
        #expect(message.contains("Dory's shared VM or a Docker-compatible engine"))
        #expect(message.contains("Docker Desktop"))
        #expect(message.contains("Colima"))
        #expect(message.contains("Podman"))
        #expect(!message.contains("Switch engines in Settings"))
    }

    @Test func sharedVMUnavailableStatusPointsOlderMacsToDockerCompatibleFallbacks() {
        let support = RuntimeSupport.unsupported("Dory's engine requires Apple silicon")
        let message = AppStore.sharedVMUnavailableStatus(support)
        #expect(message.contains("Dory's shared VM is unavailable"))
        #expect(message.contains("Docker-compatible engine"))
        #expect(message.contains("Docker Desktop"))
        #expect(message.contains("Colima"))
        #expect(message.contains("Podman"))
    }

    private func argumentValue(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(arguments.index(after: index)) else {
            return nil
        }
        return arguments[arguments.index(after: index)]
    }
}
