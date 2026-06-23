import Testing
@testable import Dory

struct MachineImageSSHTests {
    private func df(_ image: String) -> String { MachineImageBuilder.dockerfile(for: MachineDistro.forImage(image)!) }

    @Test func aptInstallsOpensshServer() { #expect(df("ubuntu:24.04").contains("openssh-server")) }
    @Test func dnfInstallsOpensshServer() { #expect(df("fedora:41").contains("openssh-server")) }
    @Test func zypperInstallsOpenssh() { #expect(df("opensuse/leap:15.6").contains("openssh")) }
    @Test func apkInstallsOpenssh() { #expect(df("alpine:3.21").contains("openssh")) }
    @Test func pacmanInstallsOpenssh() { #expect(df("archlinux:latest").contains("openssh")) }
}
