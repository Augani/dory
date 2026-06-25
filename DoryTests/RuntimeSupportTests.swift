import Testing
@testable import Dory

struct RuntimeSupportTests {
    @Test func appleContainerRequiresMacOS26OrLater() {
        let platform = MacHostPlatform(major: 15, minor: 7, patch: 0, architecture: "arm64")
        let support = AppleContainerSupport.evaluate(platform: platform, hasContainerCLI: true)
        #expect(!support.isSupported)
        #expect(support.reason == "requires macOS 26 or later for Apple's container engine")
    }

    @Test func appleContainerRequiresAppleSilicon() {
        let platform = MacHostPlatform(major: 26, minor: 0, patch: 0, architecture: "x86_64")
        let support = AppleContainerSupport.evaluate(platform: platform, hasContainerCLI: true)
        #expect(!support.isSupported)
        #expect(support.reason == "requires Apple silicon for Apple's container engine")
    }

    @Test func appleContainerRequiresToolchain() {
        let platform = MacHostPlatform(major: 26, minor: 0, patch: 0, architecture: "arm64")
        let support = AppleContainerSupport.evaluate(platform: platform, hasContainerCLI: false)
        #expect(!support.isSupported)
        #expect(support.reason == "needs Apple's container toolchain")
    }

    @Test func appleContainerIsSupportedWhenAllRequirementsMatch() {
        let platform = MacHostPlatform(major: 26, minor: 0, patch: 0, architecture: "arm64")
        let support = AppleContainerSupport.evaluate(platform: platform, hasContainerCLI: true)
        #expect(support.isSupported)
        #expect(support.reason.isEmpty)
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
        let support = RuntimeSupport.unsupported("requires Apple silicon for Apple's container engine")
        let message = AppStore.sharedVMUnavailableStatus(support)
        #expect(message.contains("Dory's shared VM is unavailable"))
        #expect(message.contains("Docker-compatible engine"))
        #expect(message.contains("Docker Desktop"))
        #expect(message.contains("Colima"))
        #expect(message.contains("Podman"))
    }
}
