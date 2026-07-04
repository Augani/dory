import Foundation
import Testing
@testable import Dory

struct RuntimeSupportTests {
    // Dory's own engine (dory-hv) runs on Hypervisor.framework's GICv3 — macOS 15+ Apple silicon,
    // no Apple `container` toolchain. That is the sole shared-VM engine and its host requirement.
    @Test func engineSupportsMacOS15AppleSilicon() {
        let sequoia = MacHostPlatform(major: 15, minor: 0, patch: 0, architecture: "arm64")
        let support = SharedVMProvisioner.hostSupport(platform: sequoia, engineAvailable: true)
        #expect(support.isSupported)
        #expect(support.issue == RuntimeSupport.Issue.none)
    }

    @Test func engineSupportsCurrentMacOSAppleSilicon() {
        let tahoe = MacHostPlatform(major: 26, minor: 1, patch: 0, architecture: "arm64")
        #expect(SharedVMProvisioner.hostSupport(platform: tahoe, engineAvailable: true).isSupported)
    }

    @Test func engineRequiresAppleSilicon() {
        // Architecture is unfixable, so it is reported before the engine-availability check.
        let intel = MacHostPlatform(major: 26, minor: 0, patch: 0, architecture: "x86_64")
        let support = SharedVMProvisioner.hostSupport(platform: intel, engineAvailable: true)
        #expect(!support.isSupported)
        #expect(support.issue == .architecture)
    }

    @Test func engineRejectsMacOSOlderThan15() {
        let ventura = MacHostPlatform(major: 14, minor: 5, patch: 0, architecture: "arm64")
        let support = SharedVMProvisioner.hostSupport(platform: ventura, engineAvailable: true)
        #expect(!support.isSupported)
        #expect(support.issue == .osVersion)
    }

    @Test func capableHardwareIsUnsupportedWhenEngineUnavailable() {
        // Right Mac, but the engine's binaries/kernel are missing or the user opted out
        // (DORY_HV_ENGINE=0): report unavailable so the app falls back to a Docker-compatible
        // engine rather than showing a misleading boot failure.
        let sequoia = MacHostPlatform(major: 15, minor: 4, patch: 0, architecture: "arm64")
        let support = SharedVMProvisioner.hostSupport(platform: sequoia, engineAvailable: false)
        #expect(!support.isSupported)
        #expect(support.issue == .missingToolchain)
    }

    @Test func doryHVSupportEvaluatesArchitectureBeforeOSVersion() {
        // An Intel Mac on an old macOS reports the architecture (the unfixable requirement) first.
        let oldIntel = MacHostPlatform(major: 13, minor: 0, patch: 0, architecture: "x86_64")
        #expect(DoryHVSupport.evaluate(platform: oldIntel).issue == .architecture)
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
            rootfs: "/tmp/rootfs.ext4"
        )

        #expect(arguments.contains("--direct-ip"))
        #expect(argumentValue(after: "--kernel", in: arguments) == "/tmp/kernel")
        #expect(argumentValue(after: "--gvproxy", in: arguments) == "/tmp/gvproxy")
        #expect(argumentValue(after: "--rootfs", in: arguments) == "/tmp/rootfs.ext4")
        #expect(argumentValue(after: "--mem-mb", in: arguments) == "3072")
        #expect(argumentValue(after: "--cpus", in: arguments) == "6")
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
