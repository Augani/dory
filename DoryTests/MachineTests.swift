import Testing
import Foundation
@testable import Dory

struct MachineDistroTests {
    @Test func catalogHasFourDistros() {
        #expect(MachineDistro.all.count == 4)
        #expect(MachineDistro.all.map(\.id) == ["ubuntu", "debian", "fedora", "alpine"])
    }

    @Test func mapsImageToDistro() {
        #expect(MachineDistro.forImage("ubuntu:24.04")?.display == "Ubuntu")
        #expect(MachineDistro.forImage("alpine:3.20")?.boot == .shell)
        #expect(MachineDistro.forImage("debian:12")?.boot == .systemd)
        #expect(MachineDistro.forImage("nope:1")  == nil)
    }

    @Test func mapsIDToDistro() {
        #expect(MachineDistro.forID("fedora")?.baseImage == "fedora:40")
        #expect(MachineDistro.forID("ubuntu")?.letter == "U")
    }

    @Test func derivesMachineImageTag() {
        #expect(MachineDistro.forImage("ubuntu:24.04")?.machineImageTag == "dory-machine/ubuntu:24.04")
    }
}
