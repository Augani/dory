import Foundation
import Testing
@testable import Dory

struct RuntimeSupportTests {
    @Test func appleContainerRequiresMacOS26OrLater() {
        let platform = MacHostPlatform(major: 15, minor: 7, patch: 0, architecture: "arm64")
        let support = AppleContainerSupport.evaluate(platform: platform, hasContainerCLI: true)
        #expect(!support.isSupported)
        #expect(support.reason == "requires macOS 26 or later for Apple's container engine")
        #expect(support.issue == .osVersion)
    }

    @Test func missingToolchainIsReportedAsTypedIssue() {
        let platform = MacHostPlatform(major: 26, minor: 0, patch: 0, architecture: "arm64")
        let support = AppleContainerSupport.evaluate(platform: platform, hasContainerCLI: false)
        #expect(support.issue == .missingToolchain)
    }

    @Test func architectureIssueIsTypedAndNotFixableByInstall() {
        let platform = MacHostPlatform(major: 26, minor: 0, patch: 0, architecture: "x86_64")
        let support = AppleContainerSupport.evaluate(platform: platform, hasContainerCLI: false)
        #expect(support.issue == .architecture)
    }

    @Test func supportedHostReportsNoIssue() {
        let platform = MacHostPlatform(major: 26, minor: 0, patch: 0, architecture: "arm64")
        let support = AppleContainerSupport.evaluate(platform: platform, hasContainerCLI: true)
        #expect(support.issue == RuntimeSupport.Issue.none)
    }

    @Test func sharedVMCanUseBundledEngineWithoutContainerCLI() {
        let platform = MacHostPlatform(major: 26, minor: 0, patch: 0, architecture: "arm64")
        let support = SharedVMProvisioner.hostSupport(
            platform: platform,
            containerBinaryPath: nil,
            inProcessEngineAvailable: true
        )
        #expect(support.isSupported)
        #expect(support.issue == RuntimeSupport.Issue.none)
    }

    @Test func sharedVMReportsMissingEngineWhenNoCLIOrBundledHelper() {
        let platform = MacHostPlatform(major: 26, minor: 0, patch: 0, architecture: "arm64")
        let support = SharedVMProvisioner.hostSupport(
            platform: platform,
            containerBinaryPath: nil,
            inProcessEngineAvailable: false
        )
        #expect(!support.isSupported)
        #expect(support.issue == .missingToolchain)
        #expect(support.reason.contains("bundled engine"))
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

    @Test func toolchainInstallCommandTargetsHomebrewFormula() {
        #expect(AppStore.toolchainInstallCommand == "brew install container")
    }

    @Test func toolchainReleasesURLIsValid() {
        let url = URL(string: AppStore.toolchainReleasesURL)
        #expect(url != nil)
        #expect(url?.host == "github.com")
    }

    @Test func toolchainInstallPhaseBusyStates() {
        #expect(ToolchainInstallPhase.installing.isBusy)
        #expect(ToolchainInstallPhase.startingEngine.isBusy)
        #expect(!ToolchainInstallPhase.idle.isBusy)
        #expect(!ToolchainInstallPhase.failed("x").isBusy)
    }

    @Test @MainActor func needsContainerToolchainOnlyWhenEngineOffWithMissingToolchain() {
        let store = AppStore()
        store.sharedVMSupport = .unsupported("needs Apple's container toolchain", issue: .missingToolchain)
        store.loadState = .engineOff
        #expect(store.needsContainerToolchain)

        store.loadState = .ready
        #expect(!store.needsContainerToolchain)

        store.loadState = .engineOff
        store.sharedVMSupport = .unsupported("requires Apple silicon for Apple's container engine", issue: .architecture)
        #expect(!store.needsContainerToolchain)

        store.sharedVMSupport = .supported
        #expect(!store.needsContainerToolchain)
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
