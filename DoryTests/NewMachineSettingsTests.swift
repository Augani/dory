import Darwin
import Testing
@testable import Dory

struct NewMachineSettingsTests {
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

    @Test func headlessServersDoNotCarryDesktopMetadata() {
        let settings = NewMachineSheet.buildSettings(
            cpus: 2,
            memoryGB: 2,
            mounts: [],
            displayMode: .headless
        )

        #expect(settings.env["DORY_DESKTOP_DISTRO"] == nil)
        #expect(settings.env["DORY_GUEST_USER"] == nil)
    }
}
