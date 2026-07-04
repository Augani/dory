import Foundation
import Testing
@testable import Dory

struct RuntimeSupportTests {
    // Dory's own engine (dory-hv) runs on Hypervisor.framework's GICv3 — macOS 15+ Apple silicon,
    // no Apple `container` toolchain. That is the sole shared-VM engine and its host requirement.
    @Test func engineSupportsMacOS15AppleSilicon() {
        let sequoia = MacHostPlatform(major: 15, minor: 0, patch: 0, architecture: "arm64")
        let support = SharedVMProvisioner.hostSupport(platform: sequoia)
        #expect(support.isSupported)
        #expect(support.issue == RuntimeSupport.Issue.none)
    }

    @Test func engineSupportsCurrentMacOSAppleSilicon() {
        let tahoe = MacHostPlatform(major: 26, minor: 1, patch: 0, architecture: "arm64")
        #expect(SharedVMProvisioner.hostSupport(platform: tahoe).isSupported)
    }

    @Test func engineRequiresAppleSilicon() {
        let intel = MacHostPlatform(major: 26, minor: 0, patch: 0, architecture: "x86_64")
        let support = SharedVMProvisioner.hostSupport(platform: intel)
        #expect(!support.isSupported)
        #expect(support.issue == .architecture)
    }

    @Test func engineRejectsMacOSOlderThan15() {
        let ventura = MacHostPlatform(major: 14, minor: 5, patch: 0, architecture: "arm64")
        let support = SharedVMProvisioner.hostSupport(platform: ventura)
        #expect(!support.isSupported)
        #expect(support.issue == .osVersion)
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
}
