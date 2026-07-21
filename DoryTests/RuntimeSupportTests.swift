import Foundation
import Testing
@testable import Dory

struct RuntimeSupportTests {
    // Dory.app remains a macOS 14 app, but the shipped dory-hv helper starts at macOS 15. Sonoma
    // therefore uses the dory-vmm shared tier on both supported host architectures.
    @Test func appleSiliconSonomaUsesVZSharedTierEvenWhenRawHVAssetsExist() {
        let sonoma = MacHostPlatform(major: 14, minor: 0, patch: 0, architecture: "arm64")
        let evaluation = SharedVMProvisioner.engineSupport(
            platform: sonoma,
            hvNativeAvailable: true,
            vzSharedAvailable: true,
            hypervisorSupported: true
        )
        #expect(evaluation.tier == .vzShared)
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

    @Test func intelSonomaNeverSelectsNativeHVEvenWhenRawEngineAssetsExist() {
        let intel = MacHostPlatform(major: 14, minor: 7, patch: 0, architecture: "x86_64")
        let evaluation = SharedVMProvisioner.engineSupport(
            platform: intel,
            hvNativeAvailable: true,
            vzSharedAvailable: true,
            hypervisorSupported: true
        )
        #expect(evaluation.tier == .vzShared)
        #expect(evaluation.support.isSupported)
    }

    @Test func intelMacOS15PrefersNativeHVTierWhenRawEngineAssetsExist() {
        let intel = MacHostPlatform(major: 15, minor: 0, patch: 0, architecture: "x86_64")
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

    @Test func appleSiliconMacOS15FallsBackToVZWhenRawHVIsUnavailable() {
        let sequoia = MacHostPlatform(major: 15, minor: 4, patch: 0, architecture: "arm64")
        let evaluation = SharedVMProvisioner.engineSupport(
            platform: sequoia,
            hvNativeAvailable: false,
            vzSharedAvailable: true,
            hypervisorSupported: true
        )
        #expect(evaluation.tier == .vzShared)
        #expect(evaluation.support.isSupported)
    }

    @Test func capableHardwareIsUnsupportedWhenAllEngineAssetsAreUnavailable() {
        let sequoia = MacHostPlatform(major: 15, minor: 4, patch: 0, architecture: "arm64")
        let support = SharedVMProvisioner.hostSupport(
            platform: sequoia,
            engineAvailable: false,
            vzEngineAvailable: false,
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

    @Test func nativeHVPlatformSupportStartsAtMacOS15OnBothArchitectures() {
        let intelSonoma = MacHostPlatform(major: 14, minor: 7, patch: 0, architecture: "x86_64")
        let armSonoma = MacHostPlatform(major: 14, minor: 7, patch: 0, architecture: "arm64")
        let intelMacOS15 = MacHostPlatform(major: 15, minor: 0, patch: 0, architecture: "x86_64")
        let armMacOS15 = MacHostPlatform(major: 15, minor: 0, patch: 0, architecture: "arm64")
        #expect(!DoryHVSupport.evaluate(platform: intelSonoma).isSupported)
        #expect(!DoryHVSupport.evaluate(platform: armSonoma).isSupported)
        #expect(DoryHVSupport.evaluate(platform: intelMacOS15).isSupported)
        #expect(DoryHVSupport.evaluate(platform: armMacOS15).isSupported)
    }

    @Test func hvEngineAvailabilityRejectsSonomaBeforeConsideringAssets() {
        let intel = MacHostPlatform(major: 14, minor: 7, patch: 0, architecture: "x86_64")
        let arm = MacHostPlatform(major: 14, minor: 7, patch: 0, architecture: "arm64")
        #expect(!SharedVMProvisioner.hvEngineAvailable(platform: intel, environment: [:]))
        #expect(!SharedVMProvisioner.hvEngineAvailable(platform: arm, environment: [:]))
    }

    @Test func hvEngineDisabledByOptOutFlag() {
        // DORY_HV_ENGINE=0 force-disables the engine even when binaries are present.
        #expect(!SharedVMProvisioner.hvEngineAvailable(environment: ["DORY_HV_ENGINE": "0"]))
    }

    @Test func vmEngineAvailabilityRequiresArchitectureMatchedBundledAssets() {
        var assets: Set<String> = [
            "dory-vm-kernel-amd64.lzfse",
            "dory-engine-rootfs-amd64.ext4.lzfse",
        ]
        let available = {
            SharedVMProvisioner.vmEngineAssetsAvailable(
                arch: "amd64",
                helperAvailable: true,
                resourceAvailable: { assets.contains("\($0).\($1)") }
            )
        }

        #expect(available())
        assets.remove("dory-vm-kernel-amd64.lzfse")
        assets.insert("dory-vm-kernel-arm64.lzfse")
        #expect(!available())
        assets.remove("dory-engine-rootfs-amd64.ext4.lzfse")
        assets.insert("dory-machine-rootfs-amd64.ext4")
        #expect(!available())
        assets.insert("dory-vm-kernel-amd64.lzfse")
        #expect(available())
        #expect(!SharedVMProvisioner.vmEngineAssetsAvailable(
            arch: "amd64",
            helperAvailable: false,
            resourceAvailable: { assets.contains("\($0).\($1)") }
        ))
    }

    @Test func vmEngineAvailabilityAcceptsCompleteExplicitFallbackFixture() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dory-vmm-assets-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let helper = directory.appendingPathComponent("dory-vmm")
        let kernel = directory.appendingPathComponent("kernel")
        let rootfs = directory.appendingPathComponent("rootfs.ext4")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
        try Data("kernel".utf8).write(to: kernel)
        try Data("rootfs".utf8).write(to: rootfs)

        var environment = [
            "DORYD_VMM_HELPER": helper.path,
            "DORYD_VMM_KERNEL": kernel.path,
            "DORYD_VMM_ROOTFS": rootfs.path,
        ]
        #expect(SharedVMProvisioner.vmEngineAvailable(environment: environment, arch: "amd64"))
        environment["DORYD_VMM_ROOTFS"] = directory.appendingPathComponent("missing-rootfs").path
        #expect(!SharedVMProvisioner.vmEngineAvailable(environment: environment, arch: "amd64"))
    }

    @Test func sharedVMDefaultMemoryPolicyIsBelowLegacyFourGiB() {
        let config = SharedVMProvisioner.Config()
        #expect(config.memory == "2048M")
        #expect(config.memoryMB == 2048)
        #expect(config.headroomMB == 512)
    }

    @Test func appleSiliconDefaultsAmd64TranslationOnButPreservesExplicitOptOut() throws {
        let suiteName = "DoryTests.amd64-default.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let appleSilicon = MacHostPlatform(major: 26, minor: 0, patch: 0, architecture: "arm64")
        let intel = MacHostPlatform(major: 26, minor: 0, patch: 0, architecture: "x86_64")

        #expect(SharedVMProvisioner.Config.amd64EmulationEnabled(
            defaults: defaults,
            platform: appleSilicon
        ))
        defaults.set(false, forKey: SharedVMProvisioner.Config.rosettaX86Key)
        #expect(!SharedVMProvisioner.Config.amd64EmulationEnabled(
            defaults: defaults,
            platform: appleSilicon
        ))
        defaults.set(true, forKey: SharedVMProvisioner.Config.rosettaX86Key)
        #expect(!SharedVMProvisioner.Config.amd64EmulationEnabled(
            defaults: defaults,
            platform: intel
        ))
    }

    @Test func sharedVMMemoryParserHandlesDockerStyleUnits() {
        #expect(SharedVMProvisioner.memoryStringToMB("2G") == 2048)
        #expect(SharedVMProvisioner.memoryStringToMB("1536M") == 1536)
        #expect(SharedVMProvisioner.memoryStringToMB("1073741824") == 1024)
    }

    @Test func sharedVMEngineArgumentsStartDirectIPBridge() throws {
        let arguments = try SharedVMProvisioner.engineArguments(
            config: SharedVMProvisioner.Config(cpus: 6, memory: "3G", daxDataShares: []),
            kernel: "/tmp/kernel",
            gvproxy: "/tmp/gvproxy",
            rootfs: "/tmp/rootfs.ext4",
            guestAgent: "/tmp/dory-agent"
        )

        #expect(arguments.contains("--direct-ip"))
        #expect(arguments.contains("--direct-ipv6"))
        #expect(argumentValue(after: "--kernel", in: arguments) == "/tmp/kernel")
        #expect(argumentValue(after: "--gvproxy", in: arguments) == "/tmp/gvproxy")
        #expect(argumentValue(after: "--rootfs", in: arguments) == "/tmp/rootfs.ext4")
        #expect(argumentValue(after: "--guest-agent", in: arguments) == "/tmp/dory-agent")
        #expect(argumentValue(after: "--mem-mb", in: arguments) == "3072")
        #expect(argumentValue(after: "--cpus", in: arguments) == "6")
    }

    @Test func sharedVMConfigurationPrefersAMD64OverAnIncompatibleGPUPreference() throws {
        let config = SharedVMProvisioner.Config(
            cpus: 4,
            memory: "3G",
            rosettaX86: true,
            gpuVenus: true,
            daxDataShares: []
        )
        let arguments = try SharedVMProvisioner.engineArguments(
            config: config,
            kernel: "/tmp/kernel",
            gvproxy: "/tmp/gvproxy",
            rootfs: nil
        )

        #expect(config.rosettaX86)
        #expect(!config.gpuVenus)
        #expect(arguments.contains("--amd64"))
        #expect(!arguments.contains("--gpu"))
    }

    @Test func sharedVMEngineArgumentsShareHomeAtItsRealPath() throws {
        let arguments = try SharedVMProvisioner.engineArguments(
            config: SharedVMProvisioner.Config(cpus: 4, memory: "2G", daxDataShares: []),
            kernel: "/tmp/kernel",
            gvproxy: "/tmp/gvproxy",
            rootfs: nil
        )

        let home = NSHomeDirectory()
        #expect(argumentValue(after: "--share", in: arguments) == "home=\(home):rw:at=\(home):safe")
        #expect(arguments.contains("volumes=/Volumes:rw:at=/Volumes:safe"))
    }

    @Test func sharedVMEngineArgumentsRejectLegacyDaxPreferenceExplicitly() {
        do {
            _ = try SharedVMProvisioner.engineArguments(
                config: SharedVMProvisioner.Config(cpus: 4, memory: "2G", daxDataShares: ["/tmp/data"]),
                kernel: "/tmp/kernel",
                gvproxy: "/tmp/gvproxy",
                rootfs: nil
            )
            Issue.record("legacy DAX preference unexpectedly entered production arguments")
        } catch SharedVMProvisioner.ProvisionError.unsafeConfiguration(let reason) {
            #expect(reason.contains("DAX host shares are disabled"))
            #expect(reason.contains("fail-stop boundary"))
            #expect(reason.contains("remove the dory.daxDataShares preference"))
        } catch {
            Issue.record("unexpected DAX rejection error: \(error)")
        }
    }

    @Test func sharedVMRejectsLegacyDaxPreferenceBeforeLiveEngineReuseProbes() async {
        do {
            _ = try await SharedVMProvisioner.shouldReuseHVEngine(
                config: SharedVMProvisioner.Config(
                    cpus: 4,
                    memory: "2G",
                    daxDataShares: ["/tmp/data"]
                ),
                reachability: {
                    Issue.record("reachability probe ran before rejecting the legacy DAX preference")
                    return true
                },
                liveness: {
                    Issue.record("liveness probe ran before rejecting the legacy DAX preference")
                    return true
                }
            )
            Issue.record("live engine reuse unexpectedly bypassed the legacy DAX rejection")
        } catch SharedVMProvisioner.ProvisionError.unsafeConfiguration(let reason) {
            #expect(reason.contains("DAX host shares are disabled"))
            #expect(reason.contains("remove the dory.daxDataShares preference"))
        } catch {
            Issue.record("unexpected DAX reuse rejection error: \(error)")
        }
    }

    @Test func sharedVMStopsLegacyDaxEngineBeforeSurfacingMigrationError() {
        var stopped = false
        do {
            try SharedVMProvisioner.stopUnsafeLegacyDaxEngineIfNeeded(
                config: SharedVMProvisioner.Config(
                    cpus: 4,
                    memory: "2G",
                    daxDataShares: ["/tmp/data"]
                ),
                stopEngine: { stopped = true }
            )
            Issue.record("legacy DAX engine migration unexpectedly succeeded")
        } catch SharedVMProvisioner.ProvisionError.unsafeConfiguration(let reason) {
            #expect(stopped)
            #expect(reason.contains("DAX host shares are disabled"))
        } catch {
            Issue.record("unexpected DAX migration error: \(error)")
        }
    }

    @Test func sharedVMResourceNamesAreArchSuffixed() {
        #expect(SharedVMProvisioner.hvKernelResourceName(arch: "arm64") == "dory-hv-kernel-arm64")
        #expect(SharedVMProvisioner.hvKernelResourceName(arch: "amd64") == "dory-hv-kernel-amd64")
        #expect(SharedVMProvisioner.vmKernelResourceName(arch: "arm64") == "dory-vm-kernel-arm64")
        #expect(SharedVMProvisioner.vmKernelResourceName(arch: "amd64") == "dory-vm-kernel-amd64")
        #expect(SharedVMProvisioner.vmInitfsResourceName(arch: "arm64") == "dory-vm-initfs-arm64.ext4")
        #expect(SharedVMProvisioner.vmInitfsResourceName(arch: "amd64") == "dory-vm-initfs-amd64.ext4")
    }

    @Test func venusGPUIsExplicitlyAppleSiliconOnly() {
        #expect(SharedVMProvisioner.venusArchitectureSupported(arch: "arm64"))
        #expect(!SharedVMProvisioner.venusArchitectureSupported(arch: "amd64"))
        #expect(!SharedVMProvisioner.venusRuntimeAvailable(environment: [:], arch: "amd64"))
        #expect(!SharedVMProvisioner.venusRuntimeAvailable(
            environment: [:],
            arch: "arm64",
            platform: MacHostPlatform(major: 14, minor: 7, patch: 0, architecture: "arm64")
        ))
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

        #expect(arm64?["Image"] as? String == SharedVMProvisioner.pinnedBinfmtImage)
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
