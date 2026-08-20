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
        #expect(s.env["DORY_GUEST_USER"] == "dory")
        #expect(s.env["DORY_GUEST_UID"] == String(getuid()))
        #expect(s.env["DORY_DESKTOP_DISTRO"] == "debian")
        #expect(s.env["DORY_DESKTOP_VERSION"] == "13")
        #expect(s.env[DoryDesktopClipboardPolicy.environmentKey] == "bidirectional")
        #expect(s.env[DoryDesktopVMMPreference.environmentKey] == "auto")
        #expect(s.env[DoryDesktopGraphicsPreference.environmentKey] == "auto")
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

        #expect(settings.env["DORY_DESKTOP_DISTRO"] == "kali")
        #expect(settings.env["DORY_DESKTOP_NAME"] == "Kali Linux")
        #expect(settings.env["DORY_DESKTOP_VERSION"] == "Rolling")
        #expect(settings.env["DORY_DESKTOP_ENVIRONMENT"] == "Xfce")
        #expect(settings.env["DORY_GUEST_USER"] == "analyst")
        #expect(settings.env["DORY_GUEST_UID"] == "1001")
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

        #expect(settings.env["DORY_DESKTOP_DISTRO"] == "ubuntu")
        #expect(settings.env["DORY_DESKTOP_NAME"] == "Ubuntu")
        #expect(settings.env["DORY_DESKTOP_VERSION"] == "24.04 LTS")
        #expect(settings.env["DORY_DESKTOP_ENVIRONMENT"] == "GNOME")
    }

    @Test func headlessServersDoNotCarryDesktopMetadata() {
        let settings = NewMachineSheet.buildSettings(
            cpus: 2,
            memoryGB: 2,
            mounts: [],
            displayMode: .headless
        )

        #expect(settings.env["DORY_DESKTOP_DISTRO"] == nil)
        #expect(settings.env["DORY_GUEST_USER"] == nil)
        #expect(settings.env[DoryDesktopClipboardPolicy.environmentKey] == nil)
        #expect(settings.env[DoryDesktopVMMPreference.environmentKey] == nil)
        #expect(settings.env[DoryDesktopGraphicsPreference.environmentKey] == nil)
    }
}
