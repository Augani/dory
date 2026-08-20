import Darwin
import DoryOperations
import Testing
@testable import Dory

struct NewMachineSettingsTests {
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

    @Test func collectsResourcesRegardlessOfDisclosure() {
        let s = NewMachineSheet.buildSettings(cpus: 4, memoryGB: 8,
            mounts: [MountPair(host: "/Users/u/p", guest: "/Users/u/p")],
            address: "192.168.215.40")
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
        #expect(s.virtualMachineSettings?.runtimePreference == .automatic)
        #expect(s.virtualMachineSettings?.graphicsPreference == .automatic)
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

    @Test func headlessServersDoNotCarryDesktopMetadata() {
        let settings = NewMachineSheet.buildSettings(
            cpus: 2,
            memoryGB: 2,
            mounts: [],
            displayMode: .headless
        )

        #expect(settings.env.isEmpty)
        #expect(settings.virtualMachineSettings == nil)
    }
}
