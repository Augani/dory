@testable import DorydKit
import XCTest

final class DorydConfigurationTests: XCTestCase {
    func testBuildsDockerTierWithDoryHvForwardArguments() throws {
        let directory = "/tmp/doryd-config-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }

        let helper = try executableFixture(at: directory + "/dory-hv")
        let gvproxy = try executableFixture(at: directory + "/gvproxy")
        let kernel = directory + "/kernel"
        let rootfs = directory + "/rootfs.ext4"
        FileManager.default.createFile(atPath: kernel, contents: Data())
        FileManager.default.createFile(atPath: rootfs, contents: Data())

        let env = DorydEnvironment(values: [
            "DORYD_HOME": directory + "/home",
            "DORYD_HV_HELPER": helper,
            "DORYD_HV_KERNEL": kernel,
            "DORYD_GVPROXY": gvproxy,
            "DORYD_ENGINE_ROOTFS": rootfs,
            "DORYD_STATE_DIR": directory + "/state",
            "DORYD_MEMORY_MB": "4096",
            "DORYD_CPUS": "6",
            "DORYD_GPU": "venus",
            "DORYD_AMD64": "1",
            "DORYD_PUBLISH_HOST": "0.0.0.0",
            "DORYD_SHARES": "src=/tmp/src:rw;cache=/tmp/cache:ro",
            "DORYD_HV_RESTART_LIMIT": "5",
            "DORYD_HV_RESTART_DELAY": "0.1",
        ], cwd: directory)

        let config = try XCTUnwrap(env.dockerTierConfiguration())
        XCTAssertEqual(config.home, directory + "/home")
        XCTAssertEqual(config.forwardSocketPath, directory + "/state/agent-vsock-forward.sock")
        XCTAssertEqual(config.agentControl, AgentControlConfiguration(
            forwardSocketPath: directory + "/state/agent-vsock-forward.sock",
            cid: 3
        ))
        XCTAssertTrue(config.gpuSupported)

        let hv = try XCTUnwrap(config.hvProcess)
        XCTAssertEqual(hv.executablePath, helper)
        XCTAssertEqual(hv.restartPolicy, HvRestartPolicy(maxRestarts: 5, delaySeconds: 0.1))
        XCTAssertEqual(hv.logPath, directory + "/state/dory-hv.log")
        XCTAssertEqual(hv.arguments.prefix(2), ["engine", "--engine-sock"])
        XCTAssertArgumentPair(hv.arguments, "--agent-vsock-forward", directory + "/state/agent-vsock-forward.sock")
        XCTAssertArgumentPair(hv.arguments, "--kernel", kernel)
        XCTAssertArgumentPair(hv.arguments, "--gvproxy", gvproxy)
        XCTAssertArgumentPair(hv.arguments, "--state-dir", directory + "/state")
        XCTAssertArgumentPair(hv.arguments, "--mem-mb", "4096")
        XCTAssertArgumentPair(hv.arguments, "--cpus", "6")
        XCTAssertArgumentPair(hv.arguments, "--rootfs", rootfs)
        XCTAssertArgumentPair(hv.arguments, "--gpu", "venus")
        XCTAssertArgumentPair(hv.arguments, "--publish-host", "0.0.0.0")
        XCTAssertTrue(hv.arguments.contains("--direct-ip"))
        XCTAssertTrue(hv.arguments.contains("--amd64"))
        XCTAssertArgumentPair(hv.arguments, "--share", "src=/tmp/src:rw")
        XCTAssertArgumentPair(hv.arguments, "--share", "cache=/tmp/cache:ro")
    }

    func testReturnsForwardOnlyTierWhenExternalForwardSocketIsProvided() throws {
        let env = DorydEnvironment(values: [
            "DORYD_HOME": "/tmp/doryd-home",
            "DORYD_AGENT_VSOCK_FORWARD": "/tmp/forward.sock",
        ], cwd: "/tmp")

        let config = try XCTUnwrap(env.dockerTierConfiguration())
        XCTAssertEqual(config.forwardSocketPath, "/tmp/forward.sock")
        XCTAssertEqual(config.agentControl, AgentControlConfiguration(forwardSocketPath: "/tmp/forward.sock"))
        XCTAssertNil(config.hvProcess)
    }

    func testDockerTierIsUnconfiguredWhenConfiguredKernelIsMissing() throws {
        let directory = "/tmp/doryd-config-missing-kernel-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }

        let helper = try executableFixture(at: directory + "/dory-hv")
        let gvproxy = try executableFixture(at: directory + "/gvproxy")

        let env = DorydEnvironment(values: [
            "DORYD_HOME": directory + "/home",
            "DORYD_HV_HELPER": helper,
            "DORYD_HV_KERNEL": directory + "/missing-kernel",
            "DORYD_GVPROXY": gvproxy,
        ], cwd: directory)

        XCTAssertNil(env.dockerTierConfiguration())
    }

    func testDockerTierFindsBundledRuntimeResourcesByHostArchitecture() throws {
        let directory = "/tmp/doryd-config-bundle-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let helpers = directory + "/Dory.app/Contents/Helpers"
        let resources = directory + "/Dory.app/Contents/Resources"
        try FileManager.default.createDirectory(atPath: helpers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }

        let doryd = try executableFixture(at: helpers + "/doryd")
        let helper = try executableFixture(at: helpers + "/dory-hv")
        let gvproxy = try executableFixture(at: helpers + "/gvproxy")
        _ = helper
        _ = gvproxy

        #if arch(x86_64)
        let guestArch = "amd64"
        let expectsAMD64Emulation = false
        #else
        let guestArch = "arm64"
        let expectsAMD64Emulation = true
        #endif

        let kernel = resources + "/dory-hv-kernel-\(guestArch)"
        FileManager.default.createFile(atPath: kernel, contents: Data())

        let env = DorydEnvironment(values: [
            "DORYD_HOME": directory + "/home",
        ], cwd: directory, executablePath: doryd)

        let hv = try XCTUnwrap(env.dockerTierConfiguration()?.hvProcess)
        XCTAssertArgumentPair(hv.arguments, "--kernel", kernel)
        XCTAssertArgumentPair(hv.arguments, "--gvproxy", helpers + "/gvproxy")
        XCTAssertEqual(hv.arguments.contains("--amd64"), expectsAMD64Emulation)
    }

    func testDockerTierPreparesBundledEngineRootfs() throws {
        let directory = "/tmp/doryd-config-rootfs-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let helpers = directory + "/Dory.app/Contents/Helpers"
        let resources = directory + "/Dory.app/Contents/Resources"
        let state = directory + "/state"
        try FileManager.default.createDirectory(atPath: helpers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }

        let doryd = try executableFixture(at: helpers + "/doryd")
        _ = try executableFixture(at: helpers + "/dory-hv")
        _ = try executableFixture(at: helpers + "/gvproxy")

        #if arch(x86_64)
        let guestArch = "amd64"
        #else
        let guestArch = "arm64"
        #endif

        FileManager.default.createFile(atPath: resources + "/dory-hv-kernel-\(guestArch)", contents: Data())
        let rootfs = directory + "/fixture-rootfs.ext4"
        let compressedRootfs = resources + "/dory-engine-rootfs.ext4.lzfse"
        try Data("rootfs-fixture".utf8).write(to: URL(fileURLWithPath: rootfs))
        try DorydLZFSE.compress(source: rootfs, destination: compressedRootfs)

        let env = DorydEnvironment(values: [
            "DORYD_HOME": directory + "/home",
            "DORYD_STATE_DIR": state,
        ], cwd: directory, executablePath: doryd)

        let hv = try XCTUnwrap(env.dockerTierConfiguration()?.hvProcess)
        let preparedRootfs = state + "/assets/dory-engine-rootfs.ext4"
        XCTAssertArgumentPair(hv.arguments, "--rootfs", preparedRootfs)
        XCTAssertEqual(FileManager.default.contents(atPath: preparedRootfs), Data("rootfs-fixture".utf8))
    }

    func testCanDisableAgentControl() throws {
        let env = DorydEnvironment(values: [
            "DORYD_HOME": "/tmp/doryd-home",
            "DORYD_AGENT_VSOCK_FORWARD": "/tmp/forward.sock",
            "DORYD_AGENT_CONTROL": "0",
        ], cwd: "/tmp")

        let config = try XCTUnwrap(env.dockerTierConfiguration())
        XCTAssertNil(config.agentControl)
    }

    func testHostCLIRepairDefaultsOnAndCanBeDisabled() {
        XCTAssertTrue(DorydEnvironment(values: [:], home: "/tmp/doryd-home").hostCLIEnabled)
        XCTAssertFalse(DorydEnvironment(values: ["DORYD_HOST_CLI": "0"], home: "/tmp/doryd-home").hostCLIEnabled)
    }

    func testNetworkingConfigurationIsOptInAndHighPortOnly() throws {
        XCTAssertNil(DorydEnvironment(values: [:], home: "/tmp/doryd-home", cwd: "/tmp").networkingConfiguration())

        let env = DorydEnvironment(values: [
            "DORYD_NETWORKING": "1",
            "DORYD_DOMAIN_SUFFIX": "dev.dory.local",
            "DORYD_DNS_BIND": "127.0.0.1",
            "DORYD_DNS_PORT": "15353",
            "DORYD_HTTP_PROXY_PORT": "18080",
            "DORYD_HTTPS_PROXY_PORT": "18443",
            "DORYD_PRIVILEGED_TCP_FORWARDS": "25:1025, 110:1110",
            "DORYD_CA_CERT": "/tmp/doryd-ca.crt",
        ], home: "/tmp/doryd-home", cwd: "/tmp")

        XCTAssertEqual(env.networkingConfiguration(), NetworkingConfiguration(
            suffix: "dev.dory.local",
            dnsBindAddress: "127.0.0.1",
            dnsPort: 15353,
            httpProxyPort: 18080,
            httpsProxyPort: 18443,
            privilegedTCPForwards: [
                PrivilegedTCPForward(listenPort: 25, targetPort: 1025),
                PrivilegedTCPForward(listenPort: 110, targetPort: 1110),
            ],
            localCACertificatePath: "/tmp/doryd-ca.crt"
        ))
    }

    func testMachineManagerConfigurationUsesExplicitHelper() throws {
        let directory = "/tmp/doryd-machine-config-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let helper = try executableFixture(at: directory + "/dory-vmm")

        let env = DorydEnvironment(values: [
            "DORYD_VMM_HELPER": helper,
            "DORYD_MACHINE_STATE_DIR": directory + "/machines",
            "DORYD_MACHINE_LOG_DIR": directory + "/logs",
            "DORYD_VMM_ARGS": "--foreground --verbose",
            "DORYD_VMM_PASS_MACHINE_ARGS": "0",
            "DORYD_VMM_READY_HANDOFF": "0",
        ], home: directory + "/home", cwd: directory)

        XCTAssertEqual(env.machineManagerConfiguration(), MachineManagerConfiguration(
            vmmExecutablePath: helper,
            stateDirectory: directory + "/machines",
            baseArguments: ["--foreground", "--verbose"],
            passMachineArguments: false,
            logDirectory: directory + "/logs",
            requiresReadyHandoff: false
        ))
    }

    func testMachineManagerConfigurationFindsSwiftPMBuiltDoryVMM() throws {
        let directory = "/tmp/doryd-machine-config-spm-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: directory + "/.build/debug", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let helper = try executableFixture(at: directory + "/.build/debug/dory-vmm")

        let env = DorydEnvironment(values: [
            "DORYD_HOME": directory + "/home",
        ], cwd: directory)

        let config = try XCTUnwrap(env.machineManagerConfiguration())
        XCTAssertEqual(config.vmmExecutablePath, helper)
        XCTAssertEqual(config.stateDirectory, directory + "/home/.dory/machines")
        XCTAssertTrue(config.requiresReadyHandoff)
    }

    private func executableFixture(at path: String) throws -> String {
        try "#!/bin/sh\nexit 0\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }
}

private func XCTAssertArgumentPair(
    _ arguments: [String],
    _ flag: String,
    _ value: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    var index = arguments.startIndex
    while index < arguments.endIndex {
        defer { index = arguments.index(after: index) }
        guard arguments[index] == flag else { continue }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else { break }
        if arguments[valueIndex] == value {
            return
        }
    }
    guard let index = arguments.firstIndex(of: flag), arguments.index(after: index) < arguments.endIndex else {
        XCTFail("missing \(flag) \(value) in \(arguments)", file: file, line: line)
        return
    }
    XCTFail("missing \(flag) \(value); first \(flag) is \(arguments[arguments.index(after: index)]) in \(arguments)", file: file, line: line)
}
