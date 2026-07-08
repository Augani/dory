import Foundation
import Testing
@testable import Dory

@MainActor
struct ManagedSettingsTests {
    @Test func profileCapturesFleetRolloutDefaults() throws {
        let store = AppStore(
            runtime: DisconnectedRuntime(),
            useDorydEngine: true,
            environment: ["XCTestConfigurationFilePath": "DoryTests.xctest"]
        )
        store.routeDockerCLI = false
        store.domainSuffix = "corp.dory.local"
        store.dnsPort = 15453
        store.httpProxyPort = 18080
        store.httpsProxyPort = 18443
        store.runtimeMode = "auto-idle"
        store.idlePolicy = IdlePolicy(
            sleepAfterMinutes: 30,
            keepPublishedPortsAwake: false,
            keepKubernetesAwake: true,
            keepPinnedProjectsAwake: false,
            showWakeNotifications: false
        )
        store.machineEnvAllowList = ["PATH", "GITHUB_TOKEN"]

        let profile = store.managedSettingsProfile()

        #expect(profile.schema == "dev.dory.managed-settings")
        #expect(profile.version == 1)
        #expect(profile.engine.preference == "dory")
        #expect(profile.engine.routeDockerCLI == false)
        #expect(profile.network.domainSuffix == "corp.dory.local")
        #expect(profile.network.dnsPort == 15453)
        #expect(profile.autoIdle.mode == "auto-idle")
        #expect(profile.autoIdle.sleepAfterMinutes == 30)
        #expect(profile.autoIdle.keepPublishedPortsAwake == false)
        #expect(profile.fileSharing.defaultPolicy == "safe-scoped")
        #expect(profile.fileSharing.scopedMountsRequiredForSandboxes)
        #expect(profile.fileSharing.credentialStoresHidden)
        #expect(profile.fileSharing.machineEnvAllowList == ["PATH", "GITHUB_TOKEN"])
        #expect(profile.telemetry.mode == "none")

        let json = store.managedSettingsJSON()
        #expect(json.contains(#""schema" : "dev.dory.managed-settings""#))
        #expect(json.contains(#""telemetry" : {"#))
        #expect(json.contains(#""mode" : "none""#))
    }
}
