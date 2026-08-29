import Darwin
import DoryOperations
import Testing
@testable import Dory

struct NewMachineSettingsTests {
    @Test func portForwardDraftsRequireExactConflictFreeBindings() throws {
        let rows = [
            MachinePortForwardDraft(
                name: "web",
                hostPort: "8080",
                guestPort: "80"
            ),
            MachinePortForwardDraft(
                name: "dns",
                transport: .udp,
                hostPort: "5353",
                guestPort: "53",
                exposure: .lan
            ),
        ]
        let resolved = try #require(
            MachinePortForwardDraft.resolved(rows, networkMode: .sharedNAT)
        )
        #expect(resolved.map(\.id) == ["web", "dns"])
        #expect(resolved[1].transport == .udp)
        #expect(MachinePortForwardDraft.resolved(rows, networkMode: .isolated) == nil)

        var duplicate = rows
        duplicate[1].transport = .tcp
        duplicate[1].hostPort = "8080"
        duplicate[1].exposure = .loopback
        #expect(MachinePortForwardDraft.resolved(duplicate, networkMode: .sharedNAT) == nil)

        var privileged = rows
        privileged[0].hostPort = "443"
        #expect(MachinePortForwardDraft.resolved(privileged, networkMode: .sharedNAT) == nil)
    }

    @Test func desktopDefaultsScaleForBrowserWorkloadsWithoutConsumingTheHost() {
        let eightGB = NewMachineSheet.recommendedDesktopResources(
            activeProcessorCount: 8,
            physicalMemory: 8 * 1_073_741_824
        )
        #expect(eightGB.cpus == 4)
        #expect(eightGB.memoryGB == 4)

        let sixteenGB = NewMachineSheet.recommendedDesktopResources(
            activeProcessorCount: 12,
            physicalMemory: 16 * 1_073_741_824
        )
        #expect(sixteenGB.cpus == 6)
        #expect(sixteenGB.memoryGB == 6)

        let largerHost = NewMachineSheet.recommendedDesktopResources(
            activeProcessorCount: 32,
            physicalMemory: 64 * 1_073_741_824
        )
        #expect(largerHost.cpus == 8)
        #expect(largerHost.memoryGB == 8)
    }

    @Test func customISOInstallationUsesABalancedResourceDefault() {
        #expect(DoryInstallerMachinePolicy.defaultCPUCount == 4)
        #expect(DoryInstallerMachinePolicy.defaultMemoryMB == 4_096)
    }

    @Test func customISOHomeShareUsesAnExplicitManualVirtioFSTag() {
        let mount = NewMachineSheet.sharedHomeMount(
            home: "/Users/tester",
            displayMode: .desktop,
            customISOInstall: true,
            guestUsername: "installer-user"
        )

        #expect(mount.host == "/Users/tester")
        #expect(mount.guest == "/mnt/dory-mac-home")
        #expect(mount.shareTag == "mac-home")
    }

    @Test func managedDesktopHomeShareKeepsTheProvisionedUserPath() {
        let mount = NewMachineSheet.sharedHomeMount(
            home: "/Users/tester",
            displayMode: .desktop,
            customISOInstall: false,
            guestUsername: "dory-user"
        )

        #expect(mount.guest == "/home/dory-user/Mac")
        #expect(mount.shareTag == nil)
    }

    @Test func collectsResourcesRegardlessOfDisclosure() {
        let s = NewMachineSheet.buildSettings(cpus: 4, memoryGB: 8,
            mounts: [MountPair(host: "/Users/u/p", guest: "/Users/u/p")],
            address: "192.168.215.40",
            portForwards: [
                DoryVMPortForward(id: "web", hostPort: 8_080, guestPort: 80),
            ])
        #expect(s.cpus == 4)
        #expect(s.memoryMB == 8 * 1024)
        #expect(s.mounts.count == 1)
        #expect(s.address == "192.168.215.40")
        #expect(s.displayMode == .desktop)
        #expect(s.env.isEmpty)
        #expect(s.virtualMachineSettings?.guestIdentityIntent.account?.username == "dory")
        #expect(s.virtualMachineSettings?.guestIdentityIntent.account?.numericUserID == UInt32(getuid()))
        #expect(s.virtualMachineSettings?.guestIdentityIntent.desktop?.distributionIdentifier == "debian")
        #expect(s.virtualMachineSettings?.guestIdentityIntent.desktop?.version == "13")
        #expect(s.virtualMachineSettings?.clipboardPolicy == .legacyDesktop(.bidirectional))
        #expect(s.virtualMachineSettings?.runtimePreference == .accelerated)
        #expect(s.virtualMachineSettings?.graphicsPreference == .virglVenus)
        #expect(s.virtualMachineSettings?.networkMode == .sharedNAT)
        #expect(s.virtualMachineSettings?.portForwards == [
            DoryVMPortForward(id: "web", hostPort: 8_080, guestPort: 80),
        ])
        #expect(s.virtualMachineSettings?.audioConfiguration == DoryVMAudioConfiguration(
            inputEnabled: true,
            outputEnabled: true
        ))
        #expect(s.virtualMachineSettings?.cameraConfiguration
            == DoryVMCameraConfiguration(enabled: true))
        #expect(s.virtualMachineSettings?.intelApplicationTranslationEnabled == nil)
        #expect(s.ports.isEmpty)
    }

    @Test func recordsTheSelectedDesktopDistribution() {
        let settings = NewMachineSheet.buildSettings(
            cpus: 4,
            memoryGB: 8,
            mounts: [],
            displayMode: .desktop,
            desktopDistro: .kali,
            guestUsername: "analyst",
            guestUID: 1_001
        )

        #expect(settings.env.isEmpty)
        #expect(settings.virtualMachineSettings?.guestIdentityIntent.desktop?.distributionIdentifier == "kali")
        #expect(settings.virtualMachineSettings?.guestIdentityIntent.desktop?.displayName == "Kali Linux")
        #expect(settings.virtualMachineSettings?.guestIdentityIntent.desktop?.version == "Rolling")
        #expect(settings.virtualMachineSettings?.guestIdentityIntent.desktop?.desktopEnvironment == "Xfce")
        #expect(settings.virtualMachineSettings?.guestIdentityIntent.account?.username == "analyst")
        #expect(settings.virtualMachineSettings?.guestIdentityIntent.account?.numericUserID == 1_001)
    }

    @Test func recordsUbuntuAsTheCanonicalGnomeDesktop() {
        let settings = NewMachineSheet.buildSettings(
            cpus: 4,
            memoryGB: 8,
            mounts: [],
            displayMode: .desktop,
            desktopDistro: .ubuntu,
            guestUsername: "developer",
            guestUID: 1_002
        )

        #expect(settings.env.isEmpty)
        #expect(settings.virtualMachineSettings?.guestIdentityIntent.desktop?.distributionIdentifier == "ubuntu")
        #expect(settings.virtualMachineSettings?.guestIdentityIntent.desktop?.displayName == "Ubuntu")
        #expect(settings.virtualMachineSettings?.guestIdentityIntent.desktop?.version == "24.04 LTS")
        #expect(settings.virtualMachineSettings?.guestIdentityIntent.desktop?.desktopEnvironment == "GNOME")
    }

    @Test func headlessServersCarryOnlyTypedNetworkIntent() {
        let settings = NewMachineSheet.buildSettings(
            cpus: 2,
            memoryGB: 2,
            mounts: [],
            displayMode: .headless,
            networkMode: .disconnected
        )

        #expect(settings.env.isEmpty)
        #expect(settings.virtualMachineSettings?.guestIdentityIntent == .unspecified)
        #expect(settings.virtualMachineSettings?.clipboardPolicy == nil)
        #expect(settings.virtualMachineSettings?.runtimePreference == nil)
        #expect(settings.virtualMachineSettings?.graphicsPreference == nil)
        #expect(settings.virtualMachineSettings?.networkMode == .disconnected)
        #expect(settings.virtualMachineSettings?.audioConfiguration == nil)
        #expect(settings.virtualMachineSettings?.cameraConfiguration == nil)
    }

    @Test func desktopAudioDirectionsAreCollectedIndependently() {
        let settings = NewMachineSheet.buildSettings(
            cpus: 4,
            memoryGB: 4,
            mounts: [],
            audioInputEnabled: false,
            audioOutputEnabled: true
        )

        #expect(settings.virtualMachineSettings?.audioConfiguration == DoryVMAudioConfiguration(
            inputEnabled: false,
            outputEnabled: true
        ))
    }

    @Test func desktopCameraChoiceIsExplicit() {
        let settings = NewMachineSheet.buildSettings(
            cpus: 4,
            memoryGB: 4,
            mounts: [],
            cameraEnabled: false
        )

        #expect(settings.virtualMachineSettings?.cameraConfiguration
            == DoryVMCameraConfiguration(enabled: false))
    }

    @Test func desktopGPUChoiceIsExplicitAndNeverSilentlyFallsBack() {
        let accelerated = NewMachineSheet.buildSettings(
            cpus: 4,
            memoryGB: 4,
            mounts: []
        )
        #expect(accelerated.virtualMachineSettings?.runtimePreference == .accelerated)
        #expect(accelerated.virtualMachineSettings?.graphicsPreference == .virglVenus)

        let compatible = NewMachineSheet.buildSettings(
            cpus: 4,
            memoryGB: 4,
            mounts: [],
            gpuAccelerationEnabled: false
        )
        #expect(compatible.virtualMachineSettings?.runtimePreference == .compatible)
        #expect(compatible.virtualMachineSettings?.graphicsPreference == .software)
    }

    @Test func newMachinesDoNotRequestUnsupportedIntelApplicationTranslation() {
        let desktop = NewMachineSheet.buildSettings(
            cpus: 4,
            memoryGB: 4,
            mounts: []
        )
        #expect(desktop.env.isEmpty)
        #expect(desktop.virtualMachineSettings?.intelApplicationTranslationEnabled == nil)

        let headless = NewMachineSheet.buildSettings(
            cpus: 2,
            memoryGB: 2,
            mounts: [],
            displayMode: .headless
        )
        #expect(headless.virtualMachineSettings?.intelApplicationTranslationEnabled == nil)
    }

    @Test func editingPreservesAnOlderDaemonsAbsentAudioClaimUntilTheUserChangesIt() {
        #expect(MachineAudioSettingsPolicy.editedConfiguration(
            existing: nil,
            inputEnabled: true,
            outputEnabled: true
        ) == nil)
        #expect(MachineAudioSettingsPolicy.editedConfiguration(
            existing: nil,
            inputEnabled: false,
            outputEnabled: true
        ) == DoryVMAudioConfiguration(inputEnabled: false, outputEnabled: true))
        #expect(MachineAudioSettingsPolicy.editedConfiguration(
            existing: DoryVMAudioConfiguration(inputEnabled: false, outputEnabled: true),
            inputEnabled: true,
            outputEnabled: true
        ) == DoryVMAudioConfiguration(inputEnabled: true, outputEnabled: true))
    }
}
