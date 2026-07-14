@testable import DorydKit
import DoryCore
import XCTest

final class DorydConfigurationTests: XCTestCase {
    func testRawHVPlatformContractMatchesShippedHelperMinimumOS() {
        XCTAssertEqual(DorydHostPlatform.Architecture(machineHardwareName: "arm64e"), .arm64)
        XCTAssertFalse(DorydHostPlatform(architecture: .x86_64, macOSMajorVersion: 14).supportsRawHV)
        XCTAssertFalse(DorydHostPlatform(architecture: .arm64, macOSMajorVersion: 14).supportsRawHV)
        XCTAssertTrue(DorydHostPlatform(architecture: .x86_64, macOSMajorVersion: 15).supportsRawHV)
        XCTAssertTrue(DorydHostPlatform(architecture: .arm64, macOSMajorVersion: 15).supportsRawHV)
        XCTAssertFalse(
            DorydHostPlatform(
                architecture: .unsupported("powerpc"),
                macOSMajorVersion: 27
            ).supportsRawHV
        )
    }

    func testIntelSonomaForcesVmmFallbackEvenWhenRawHVIsExplicitlyEnabled() throws {
        try assertEngineSelection(
            platform: DorydHostPlatform(architecture: .x86_64, macOSMajorVersion: 14),
            expectedRawHV: false
        )
    }

    func testArm64SonomaForcesVmmFallbackEvenWhenRawHVIsExplicitlyEnabled() throws {
        try assertEngineSelection(
            platform: DorydHostPlatform(architecture: .arm64, macOSMajorVersion: 14),
            expectedRawHV: false
        )
    }

    func testArm64MacOS15SelectsRawHV() throws {
        try assertEngineSelection(
            platform: DorydHostPlatform(architecture: .arm64, macOSMajorVersion: 15),
            expectedRawHV: true
        )
    }

    func testHostScaledDockerDefaultsLeaveRoomForMacOS() {
        XCTAssertEqual(DorydEnvironment.hostScaledCPUCount(activeProcessorCount: 12), 6)
        XCTAssertEqual(DorydEnvironment.hostScaledCPUCount(activeProcessorCount: 8), 6)
        XCTAssertEqual(DorydEnvironment.hostScaledCPUCount(activeProcessorCount: 4), 4)
        XCTAssertEqual(DorydEnvironment.hostScaledCPUCount(activeProcessorCount: 2), 2)
        XCTAssertEqual(DorydEnvironment.hostScaledMemoryMB(physicalMemory: 16 * 1024 * 1024 * 1024), 8192)
        XCTAssertEqual(DorydEnvironment.hostScaledMemoryMB(physicalMemory: 8 * 1024 * 1024 * 1024), 4096)
    }

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
            "DORYD_HV_GPU_KERNEL": kernel,
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
            "DORYD_SSH_AUTH_SOCK": "/private/tmp/com.apple.launchd.fixture/Listeners",
        ], cwd: directory, hostPlatform: DorydHostPlatform(architecture: .arm64, macOSMajorVersion: 15))

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
        XCTAssertArgumentPair(
            hv.arguments,
            "--data-drive",
            directory + "/home/Library/Application Support/Dory/Dory.dorydrive"
        )
        XCTAssertArgumentPair(hv.arguments, "--mem-mb", "4096")
        XCTAssertArgumentPair(hv.arguments, "--cpus", "6")
        XCTAssertArgumentPair(
            hv.arguments,
            "--ssh-agent-socket",
            "/private/tmp/com.apple.launchd.fixture/Listeners"
        )
        XCTAssertArgumentPair(hv.arguments, "--rootfs", rootfs)
        XCTAssertArgumentPair(hv.arguments, "--gpu", "venus")
        XCTAssertArgumentPair(hv.arguments, "--publish-host", "0.0.0.0")
        XCTAssertTrue(hv.arguments.contains("--direct-ip"))
        XCTAssertTrue(hv.arguments.contains("--direct-ipv6"))
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

    func testVenusCannotClaimAnUnverifiedExternalForward() {
        let env = DorydEnvironment(values: [
            "DORYD_HOME": "/tmp/doryd-home",
            "DORYD_AGENT_VSOCK_FORWARD": "/tmp/forward.sock",
            "DORYD_GPU": "venus",
        ], cwd: "/tmp", hostPlatform: DorydHostPlatform(architecture: .arm64, macOSMajorVersion: 15))

        XCTAssertNil(env.dockerTierConfiguration())
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
        ], cwd: directory, hostPlatform: supportedRawHVPlatform())

        XCTAssertNil(env.dockerTierConfiguration())
    }

    func testSupportedRawHVHostDoesNotReplaceMissingExplicitHelperWithBundledFallback() throws {
        let directory = "/tmp/doryd-config-missing-explicit-hv-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let helpers = directory + "/Dory.app/Contents/Helpers"
        let resources = directory + "/Dory.app/Contents/Resources"
        try FileManager.default.createDirectory(atPath: helpers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }

        let doryd = try executableFixture(at: helpers + "/doryd")
        _ = try executableFixture(at: helpers + "/dory-hv")
        _ = try executableFixture(at: helpers + "/dory-vmm")
        _ = try executableFixture(at: helpers + "/gvproxy")
        FileManager.default.createFile(
            atPath: resources + "/dory-hv-kernel-\(supportedRawHVGuestArch())",
            contents: Data()
        )

        let environment = DorydEnvironment(values: [
            "DORYD_HOME": directory + "/home",
            "DORYD_HV_HELPER": helpers + "/missing-dory-hv",
        ], cwd: directory, executablePath: doryd, hostPlatform: supportedRawHVPlatform())

        XCTAssertNil(environment.dockerTierConfiguration())
    }

    func testSupportedRawHVHostDoesNotReplaceMissingExplicitGVProxyWithBundledFallback() throws {
        let directory = "/tmp/doryd-config-missing-explicit-gvproxy-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let helpers = directory + "/Dory.app/Contents/Helpers"
        let resources = directory + "/Dory.app/Contents/Resources"
        try FileManager.default.createDirectory(atPath: helpers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }

        let doryd = try executableFixture(at: helpers + "/doryd")
        let helper = try executableFixture(at: helpers + "/dory-hv")
        _ = try executableFixture(at: helpers + "/gvproxy")
        FileManager.default.createFile(
            atPath: resources + "/dory-hv-kernel-\(supportedRawHVGuestArch())",
            contents: Data()
        )

        let environment = DorydEnvironment(values: [
            "DORYD_HOME": directory + "/home",
            "DORYD_HV_HELPER": helper,
            "DORYD_GVPROXY": helpers + "/missing-gvproxy",
        ], cwd: directory, executablePath: doryd, hostPlatform: supportedRawHVPlatform())

        XCTAssertNil(environment.dockerTierConfiguration())
    }

    func testExplicitResourceDirectoryDoesNotFallBackToAnotherBundleDirectory() throws {
        let directory = "/tmp/doryd-config-explicit-resources-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let helpers = directory + "/Dory.app/Contents/Helpers"
        let resources = directory + "/Dory.app/Contents/Resources"
        let selectedResources = directory + "/selected-resources"
        try FileManager.default.createDirectory(atPath: helpers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: resources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: selectedResources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }

        let doryd = try executableFixture(at: helpers + "/doryd")
        let helper = try executableFixture(at: helpers + "/dory-hv")
        let gvproxy = try executableFixture(at: helpers + "/gvproxy")
        FileManager.default.createFile(
            atPath: resources + "/dory-hv-kernel-\(supportedRawHVGuestArch())",
            contents: Data()
        )

        let environment = DorydEnvironment(values: [
            "DORYD_HOME": directory + "/home",
            "DORYD_HV_HELPER": helper,
            "DORYD_GVPROXY": gvproxy,
            "DORYD_RESOURCES_DIR": selectedResources,
        ], cwd: directory, executablePath: doryd, hostPlatform: supportedRawHVPlatform())

        XCTAssertNil(environment.dockerTierConfiguration())
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
        #else
        let guestArch = "arm64"
        #endif

        let kernel = resources + "/dory-hv-kernel-\(guestArch)"
        FileManager.default.createFile(atPath: kernel, contents: Data())
        let guestAgent = resources + "/dory-agent-linux-\(guestArch)"
        FileManager.default.createFile(atPath: guestAgent, contents: Data())

        let env = DorydEnvironment(values: [
            "DORYD_HOME": directory + "/home",
        ], cwd: directory, executablePath: doryd, hostPlatform: supportedRawHVPlatform())

        let hv = try XCTUnwrap(env.dockerTierConfiguration()?.hvProcess)
        XCTAssertArgumentPair(hv.arguments, "--kernel", kernel)
        XCTAssertArgumentPair(hv.arguments, "--gvproxy", helpers + "/gvproxy")
        XCTAssertArgumentPair(hv.arguments, "--guest-agent", guestAgent)
        XCTAssertFalse(hv.arguments.contains("--amd64"), "amd64 emulation must remain an explicit Settings opt-in")
    }

    func testVenusPreparesAndSelectsArchitectureMatchedCompressedGPUKernel() throws {
        let directory = "/tmp/doryd-config-gpu-kernel-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let helpers = directory + "/Helpers"
        let resources = directory + "/Resources"
        let state = directory + "/state"
        try FileManager.default.createDirectory(atPath: helpers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }

        let helper = try executableFixture(at: helpers + "/dory-hv")
        let gvproxy = try executableFixture(at: helpers + "/gvproxy")
        let headlessKernel = resources + "/dory-hv-kernel-arm64"
        try Data("headless-kernel".utf8).write(to: URL(fileURLWithPath: headlessKernel))
        let gpuKernel = directory + "/gpu-kernel"
        try Data("gpu-kernel".utf8).write(to: URL(fileURLWithPath: gpuKernel))
        try DorydLZFSE.compress(
            source: gpuKernel,
            destination: resources + "/dory-hv-kernel-gpu-arm64.lzfse"
        )

        let environment = DorydEnvironment(values: [
            "DORYD_HOME": directory + "/home",
            "DORYD_STATE_DIR": state,
            "DORYD_HV_HELPER": helper,
            "DORYD_GVPROXY": gvproxy,
            "DORYD_RESOURCES_DIR": resources,
            "DORYD_GPU": "venus",
        ], cwd: directory, hostPlatform: DorydHostPlatform(architecture: .arm64, macOSMajorVersion: 15))

        let configuration = try XCTUnwrap(environment.dockerTierConfiguration())
        let hv = try XCTUnwrap(configuration.hvProcess)
        let prepared = state + "/assets/dory-hv-kernel-gpu-arm64"
        XCTAssertArgumentPair(hv.arguments, "--kernel", prepared)
        XCTAssertArgumentPair(hv.arguments, "--gpu", "venus")
        XCTAssertTrue(configuration.gpuSupported)
        XCTAssertEqual(FileManager.default.contents(atPath: prepared), Data("gpu-kernel".utf8))
    }

    func testVenusIsRejectedOnIntelEvenWithAnExplicitGPUKernel() throws {
        let directory = "/tmp/doryd-config-gpu-intel-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let gpuKernel = directory + "/gpu-kernel"
        FileManager.default.createFile(atPath: gpuKernel, contents: Data())

        let environment = DorydEnvironment(values: [
            "DORYD_HOME": directory + "/home",
            "DORYD_GPU": "venus",
            "DORYD_HV_GPU_KERNEL": gpuKernel,
        ], cwd: directory, hostPlatform: DorydHostPlatform(architecture: .x86_64, macOSMajorVersion: 15))

        XCTAssertNil(environment.dockerTierConfiguration())
    }

    func testVenusNeverFallsBackToHeadlessKernelOrVmm() throws {
        let directory = "/tmp/doryd-config-gpu-missing-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }

        let hvHelper = try executableFixture(at: directory + "/dory-hv")
        let vmmHelper = try executableFixture(at: directory + "/dory-vmm")
        let gvproxy = try executableFixture(at: directory + "/gvproxy")
        let headlessKernel = directory + "/headless-kernel"
        let rootfs = directory + "/rootfs.ext4"
        FileManager.default.createFile(atPath: headlessKernel, contents: Data())
        FileManager.default.createFile(atPath: rootfs, contents: Data())

        let environment = DorydEnvironment(values: [
            "DORYD_HOME": directory + "/home",
            "DORYD_HV_HELPER": hvHelper,
            "DORYD_HV_KERNEL": headlessKernel,
            "DORYD_GVPROXY": gvproxy,
            "DORYD_VMM_HELPER": vmmHelper,
            "DORYD_VMM_KERNEL": headlessKernel,
            "DORYD_VMM_ROOTFS": rootfs,
            "DORYD_GPU": "venus",
        ], cwd: directory, hostPlatform: DorydHostPlatform(architecture: .arm64, macOSMajorVersion: 15))

        XCTAssertNil(environment.dockerTierConfiguration())
    }

    func testExplicitGPUOffOverridesLegacyDevelopmentVariable() throws {
        let directory = "/tmp/doryd-config-gpu-off-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }

        let helper = try executableFixture(at: directory + "/dory-hv")
        let gvproxy = try executableFixture(at: directory + "/gvproxy")
        let headlessKernel = directory + "/headless-kernel"
        FileManager.default.createFile(atPath: headlessKernel, contents: Data())
        let environment = DorydEnvironment(values: [
            "DORYD_HOME": directory + "/home",
            "DORYD_HV_HELPER": helper,
            "DORYD_HV_KERNEL": headlessKernel,
            "DORYD_GVPROXY": gvproxy,
            "DORYD_GPU": "off",
            "DORY_EXPERIMENTAL_GPU": "venus",
        ], cwd: directory, hostPlatform: DorydHostPlatform(architecture: .arm64, macOSMajorVersion: 15))

        let configuration = try XCTUnwrap(environment.dockerTierConfiguration())
        let hv = try XCTUnwrap(configuration.hvProcess)
        XCTAssertArgumentPair(hv.arguments, "--kernel", headlessKernel)
        XCTAssertFalse(hv.arguments.contains("--gpu"))
        XCTAssertFalse(configuration.gpuSupported)
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
        let compressedRootfs = resources + "/dory-engine-rootfs-\(guestArch).ext4.lzfse"
        try Data("rootfs-fixture".utf8).write(to: URL(fileURLWithPath: rootfs))
        try DorydLZFSE.compress(source: rootfs, destination: compressedRootfs)
        let manifestDigest = String(repeating: "a", count: 64)
        try Data(
            "\(manifestDigest)  Contents/Resources/dory-engine-rootfs-\(guestArch).ext4.lzfse\n".utf8
        ).write(to: URL(fileURLWithPath: resources + "/dory-payload-sha256.txt"))

        let env = DorydEnvironment(values: [
            "DORYD_HOME": directory + "/home",
            "DORYD_STATE_DIR": state,
        ], cwd: directory, executablePath: doryd, hostPlatform: supportedRawHVPlatform())

        let hv = try XCTUnwrap(env.dockerTierConfiguration()?.hvProcess)
        let preparedRootfs = state + "/assets/dory-engine-rootfs-\(guestArch).ext4"
        XCTAssertArgumentPair(hv.arguments, "--rootfs", preparedRootfs)
        XCTAssertEqual(FileManager.default.contents(atPath: preparedRootfs), Data("rootfs-fixture".utf8))
        XCTAssertEqual(
            try String(contentsOfFile: preparedRootfs + ".source-identity", encoding: .utf8),
            "sha256:\(manifestDigest)\n"
        )
    }

    func testDockerTierRemovesOnlyAbandonedPartialsForItsPreparedRootfs() throws {
        let directory = "/tmp/doryd-config-rootfs-cleanup-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let helpers = directory + "/Dory.app/Contents/Helpers"
        let resources = directory + "/Dory.app/Contents/Resources"
        let state = directory + "/state"
        let assets = state + "/assets"
        try FileManager.default.createDirectory(atPath: helpers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: resources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: assets, withIntermediateDirectories: true)
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
        let source = directory + "/fixture-rootfs.ext4"
        try Data("bundled-rootfs".utf8).write(to: URL(fileURLWithPath: source))
        try DorydLZFSE.compress(
            source: source,
            destination: resources + "/dory-engine-rootfs-\(guestArch).ext4.lzfse"
        )

        let output = assets + "/dory-engine-rootfs-\(guestArch).ext4"
        let environment = DorydEnvironment(values: [
            "DORYD_HOME": directory + "/home",
            "DORYD_STATE_DIR": state,
        ], cwd: directory, executablePath: doryd, hostPlatform: supportedRawHVPlatform())
        _ = try XCTUnwrap(environment.dockerTierConfiguration()?.hvProcess)
        XCTAssertEqual(FileManager.default.contents(atPath: output), Data("bundled-rootfs".utf8))

        // The VZ backend may mutate its writable system rootfs during the current app version.
        // A matching source identity preserves those changes while cleanup removes crash residue.
        try Data("already-prepared".utf8).write(to: URL(fileURLWithPath: output))
        let abandoned = output + ".partial-crashed"
        let abandonedLink = output + ".partial-symlink"
        let reservedDirectory = output + ".partial-directory"
        let unrelated = assets + "/other-rootfs.ext4.partial-crashed"
        try Data(repeating: 0xA5, count: 1_024 * 1_024).write(to: URL(fileURLWithPath: abandoned))
        try FileManager.default.createSymbolicLink(atPath: abandonedLink, withDestinationPath: output)
        try FileManager.default.createDirectory(atPath: reservedDirectory, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: URL(fileURLWithPath: unrelated))

        let hv = try XCTUnwrap(environment.dockerTierConfiguration()?.hvProcess)

        XCTAssertArgumentPair(hv.arguments, "--rootfs", output)
        XCTAssertEqual(FileManager.default.contents(atPath: output), Data("already-prepared".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned))
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandonedLink))
        XCTAssertTrue(FileManager.default.fileExists(atPath: reservedDirectory))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated))
    }

    func testDockerTierRefreshesPreparedRootfsWhenCompressedContentChangesWithoutNewerMtime() throws {
        let directory = "/tmp/doryd-config-rootfs-identity-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
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
        let source = directory + "/fixture-rootfs.ext4"
        let compressed = resources + "/dory-engine-rootfs-\(guestArch).ext4.lzfse"
        let first = Data("rootfs-version-0001".utf8)
        let second = Data("rootfs-version-0002".utf8)
        try first.write(to: URL(fileURLWithPath: source))
        try DorydLZFSE.compress(source: source, destination: compressed)

        let environment = DorydEnvironment(values: [
            "DORYD_HOME": directory + "/home",
            "DORYD_STATE_DIR": state,
        ], cwd: directory, executablePath: doryd, hostPlatform: supportedRawHVPlatform())
        let output = state + "/assets/dory-engine-rootfs-\(guestArch).ext4"
        _ = try XCTUnwrap(environment.dockerTierConfiguration()?.hvProcess)
        XCTAssertEqual(FileManager.default.contents(atPath: output), first)

        try second.write(to: URL(fileURLWithPath: source))
        try DorydLZFSE.compress(source: source, destination: compressed)
        let deliberatelyOldDate = Date(timeIntervalSince1970: 946_684_800)
        try FileManager.default.setAttributes([.modificationDate: deliberatelyOldDate], ofItemAtPath: compressed)
        let sourceDate = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: compressed)[.modificationDate] as? Date
        )
        let preparedDate = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: output)[.modificationDate] as? Date
        )
        XCTAssertLessThan(sourceDate, preparedDate)

        _ = try XCTUnwrap(environment.dockerTierConfiguration()?.hvProcess)
        XCTAssertEqual(FileManager.default.contents(atPath: output), second)
        let identity = try XCTUnwrap(
            String(contentsOfFile: output + ".source-identity", encoding: .utf8)
        )
        XCTAssertTrue(identity.hasPrefix("sha256:"))
    }

    func testConcurrentDockerTierPreparationPublishesOneCompleteRootfsAndNoPartials() async throws {
        let directory = "/tmp/doryd-config-rootfs-concurrent-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
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
        let expected = Data(repeating: 0x5A, count: 4 * 1_024 * 1_024)
        let source = directory + "/fixture-rootfs.ext4"
        try expected.write(to: URL(fileURLWithPath: source))
        try DorydLZFSE.compress(
            source: source,
            destination: resources + "/dory-engine-rootfs-\(guestArch).ext4.lzfse"
        )
        let environment = DorydEnvironment(values: [
            "DORYD_HOME": directory + "/home",
            "DORYD_STATE_DIR": state,
        ], cwd: directory, executablePath: doryd, hostPlatform: supportedRawHVPlatform())
        let expectedPath = state + "/assets/dory-engine-rootfs-\(guestArch).ext4"

        let preparedPaths = await withTaskGroup(of: String?.self, returning: [String?].self) { group in
            for _ in 0..<8 {
                group.addTask {
                    guard let arguments = environment.dockerTierConfiguration()?.hvProcess?.arguments,
                          let index = arguments.firstIndex(of: "--rootfs"),
                          arguments.indices.contains(index + 1) else { return nil }
                    return arguments[index + 1]
                }
            }
            var paths: [String?] = []
            for await path in group { paths.append(path) }
            return paths
        }

        XCTAssertEqual(preparedPaths.compactMap { $0 }, Array(repeating: expectedPath, count: 8))
        XCTAssertEqual(FileManager.default.contents(atPath: expectedPath), expected)
        let entries = try FileManager.default.contentsOfDirectory(atPath: state + "/assets")
        XCTAssertFalse(entries.contains { $0.hasPrefix("dory-engine-rootfs-\(guestArch).ext4.partial-") })
    }

    func testDockerTierFindsResourcesFromLaunchAgentResourceDirectory() throws {
        let directory = "/tmp/doryd-config-launchagent-resources-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let helpers = directory + "/Helpers"
        let resources = directory + "/Resources"
        let state = directory + "/state"
        try FileManager.default.createDirectory(atPath: helpers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }

        let helper = try executableFixture(at: helpers + "/dory-hv")
        let gvproxy = try executableFixture(at: helpers + "/gvproxy")

        #if arch(x86_64)
        let guestArch = "amd64"
        #else
        let guestArch = "arm64"
        #endif

        let kernel = resources + "/dory-hv-kernel-\(guestArch)"
        FileManager.default.createFile(atPath: kernel, contents: Data())
        let guestAgent = resources + "/dory-agent-linux-\(guestArch)"
        FileManager.default.createFile(atPath: guestAgent, contents: Data())
        let rootfs = directory + "/fixture-rootfs.ext4"
        let compressedRootfs = resources + "/dory-engine-rootfs-\(guestArch).ext4.lzfse"
        try Data("rootfs-fixture".utf8).write(to: URL(fileURLWithPath: rootfs))
        try DorydLZFSE.compress(source: rootfs, destination: compressedRootfs)

        let env = DorydEnvironment(values: [
            "DORYD_HOME": directory + "/home",
            "DORYD_HV_HELPER": helper,
            "DORYD_GVPROXY": gvproxy,
            "DORYD_RESOURCES_DIR": resources,
            "DORYD_STATE_DIR": state,
            "DORYD_RAW_HV_SUPPORTED": "1",
        ], cwd: directory, executablePath: "doryd", hostPlatform: supportedRawHVPlatform())

        let hv = try XCTUnwrap(env.dockerTierConfiguration()?.hvProcess)
        let preparedRootfs = state + "/assets/dory-engine-rootfs-\(guestArch).ext4"
        XCTAssertArgumentPair(hv.arguments, "--kernel", kernel)
        XCTAssertArgumentPair(hv.arguments, "--gvproxy", gvproxy)
        XCTAssertArgumentPair(hv.arguments, "--guest-agent", guestAgent)
        XCTAssertArgumentPair(hv.arguments, "--rootfs", preparedRootfs)
        XCTAssertEqual(FileManager.default.contents(atPath: preparedRootfs), Data("rootfs-fixture".utf8))
    }

    func testDockerTierUsesVmmFallbackWhenRawHvIsUnavailable() throws {
        let directory = "/tmp/doryd-config-vmm-docker-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        let helpers = directory + "/Dory.app/Contents/Helpers"
        let resources = directory + "/Dory.app/Contents/Resources"
        let state = directory + "/state"
        try FileManager.default.createDirectory(atPath: helpers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }

        let doryd = try executableFixture(at: helpers + "/doryd")
        let helper = try executableFixture(at: helpers + "/dory-vmm")
        let gvproxy = try executableFixture(at: helpers + "/gvproxy")

        #if arch(x86_64)
        let guestArch = "amd64"
        #else
        let guestArch = "arm64"
        #endif

        let kernel = directory + "/fixture-kernel"
        let rootfs = directory + "/fixture-rootfs.ext4"
        try Data("kernel-fixture".utf8).write(to: URL(fileURLWithPath: kernel))
        try Data("vmm-rootfs-fixture".utf8).write(to: URL(fileURLWithPath: rootfs))
        try DorydLZFSE.compress(
            source: kernel,
            destination: resources + "/dory-vm-kernel-\(guestArch).lzfse"
        )
        try DorydLZFSE.compress(
            source: rootfs,
            destination: resources + "/dory-engine-rootfs-\(guestArch).ext4.lzfse"
        )

        let env = DorydEnvironment(values: [
            "DORYD_HOME": directory + "/home",
            "DORYD_STATE_DIR": state,
            "DORYD_RAW_HV_SUPPORTED": "0",
            "DORYD_PUBLISH_HOST": "0.0.0.0",
            "DORYD_SSH_AUTH_SOCK": "/private/tmp/com.apple.launchd.fixture/Listeners",
        ], cwd: directory, executablePath: doryd)

        let config = try XCTUnwrap(env.dockerTierConfiguration())
        XCTAssertNil(config.hvProcess)
        XCTAssertEqual(config.dockerdSocketPath, state + "/dockerd.sock")
        XCTAssertEqual(config.agentControl, AgentControlConfiguration(directSocketPath: state + "/agent.sock"))

        let vmm = try XCTUnwrap(config.vmmProcess)
        XCTAssertEqual(vmm.executablePath, helper)
        XCTAssertEqual(vmm.handoffSocketPath, state + "/dory-vmm-docker-handoff.sock")
        XCTAssertArgumentPair(vmm.arguments, "--kernel", state + "/assets/dory-vm-kernel-\(guestArch)")
        let preparedRootfs = state + "/assets/dory-vz-engine-rootfs-\(guestArch).ext4"
        XCTAssertArgumentPair(vmm.arguments, "--rootfs", preparedRootfs)
        XCTAssertArgumentPair(vmm.arguments, "--gvproxy", gvproxy)
        XCTAssertArgumentPair(vmm.arguments, "--publish-host", "0.0.0.0")
        XCTAssertArgumentPair(
            vmm.arguments,
            "--ssh-agent-socket",
            "/private/tmp/com.apple.launchd.fixture/Listeners"
        )
        XCTAssertArgumentPair(vmm.arguments, "--cmdline", "console=hvc0 root=/dev/vda rw rootwait panic=1 dory.machine_id=docker dory.home=\(directory)/home")
        XCTAssertEqual(FileManager.default.contents(atPath: preparedRootfs), Data("vmm-rootfs-fixture".utf8))

        // Sonoma uses this writable VZ rootfs path. A new bundle identity must replace the old
        // system image while the same identity remains persistent between launches.
        try Data("vmm-rootfs-upgrade".utf8).write(to: URL(fileURLWithPath: rootfs))
        try DorydLZFSE.compress(
            source: rootfs,
            destination: resources + "/dory-engine-rootfs-\(guestArch).ext4.lzfse"
        )
        let upgradedVmm = try XCTUnwrap(env.dockerTierConfiguration()?.vmmProcess)
        XCTAssertArgumentPair(upgradedVmm.arguments, "--rootfs", preparedRootfs)
        XCTAssertEqual(FileManager.default.contents(atPath: preparedRootfs), Data("vmm-rootfs-upgrade".utf8))
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
        XCTAssertEqual(DorydEnvironment(values: [:], home: "/tmp/doryd-home").hostCLIReconcileIntervalSeconds, 300)
        XCTAssertEqual(
            DorydEnvironment(values: ["DORYD_HOST_CLI_RECONCILE_SECONDS": "5"], home: "/tmp/doryd-home").hostCLIReconcileIntervalSeconds,
            30
        )
        XCTAssertEqual(
            DorydEnvironment(values: ["DORYD_HOST_CLI_RECONCILE_SECONDS": "120"], home: "/tmp/doryd-home").hostCLIReconcileIntervalSeconds,
            120
        )
    }

    func testNetworkRouteReconcileIntervalDefaultsToFiveSecondsAndClamps() {
        XCTAssertEqual(
            DorydEnvironment(values: [:], home: "/tmp/doryd-home").networkRouteReconcileIntervalSeconds,
            5
        )
        XCTAssertEqual(
            DorydEnvironment(values: ["DORYD_NETWORK_ROUTE_RECONCILE_SECONDS": "0.5"], home: "/tmp/doryd-home")
                .networkRouteReconcileIntervalSeconds,
            1
        )
        XCTAssertEqual(
            DorydEnvironment(values: ["DORYD_NETWORK_ROUTE_RECONCILE_SECONDS": "2"], home: "/tmp/doryd-home")
                .networkRouteReconcileIntervalSeconds,
            2
        )
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
            runtimeDirectory: directory + "/home/.dory/machines",
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
        XCTAssertEqual(config.runtimeDirectory, directory + "/home/.dory/machines")
        XCTAssertEqual(
            config.stateDirectory,
            directory + "/home/Library/Application Support/Dory/Dory.dorydrive/machines"
        )
        XCTAssertTrue(config.requiresReadyHandoff)
    }

    func testDataDriveOverrideRoutesDockerAndMachinePersistenceTogether() throws {
        let directory = "/tmp/doryd-data-drive-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let helper = try executableFixture(at: directory + "/dory-hv")
        let vmm = try executableFixture(at: directory + "/dory-vmm")
        let gvproxy = try executableFixture(at: directory + "/gvproxy")
        let kernel = directory + "/kernel"
        FileManager.default.createFile(atPath: kernel, contents: Data())
        let home = directory + "/home"
        let drive = home + "/Library/Application Support/Dory/External.dorydrive"
        let env = DorydEnvironment(values: [
            "DORYD_HOME": home,
            "DORYD_DATA_DRIVE": drive,
            "DORYD_HV_HELPER": helper,
            "DORYD_VMM_HELPER": vmm,
            "DORYD_HV_KERNEL": kernel,
            "DORYD_GVPROXY": gvproxy,
        ], cwd: directory, hostPlatform: supportedRawHVPlatform())

        let hv = try XCTUnwrap(env.dockerTierConfiguration()?.hvProcess)
        XCTAssertArgumentPair(hv.arguments, "--data-drive", drive)
        XCTAssertEqual(env.machineManagerConfiguration()?.stateDirectory, drive + "/machines")
    }

    func testRememberedDataDriveRoutesDockerAndMachinePersistenceWithoutEnvironmentOverride() throws {
        let directory = "/tmp/doryd-selected-drive-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let helper = try executableFixture(at: directory + "/dory-hv")
        let vmm = try executableFixture(at: directory + "/dory-vmm")
        let gvproxy = try executableFixture(at: directory + "/gvproxy")
        let kernel = directory + "/kernel"
        FileManager.default.createFile(atPath: kernel, contents: Data())
        let home = directory + "/home"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let drive = home + "/Library/Application Support/Dory/Selected.dorydrive"
        let store = try DoryDataDriveSelectionStore(home: home)
        _ = try store.prepareSelection(requestedRoot: drive)
        let env = DorydEnvironment(values: [
            "DORYD_HOME": home,
            "DORYD_HV_HELPER": helper,
            "DORYD_VMM_HELPER": vmm,
            "DORYD_HV_KERNEL": kernel,
            "DORYD_GVPROXY": gvproxy,
        ], cwd: directory, hostPlatform: supportedRawHVPlatform())

        let hv = try XCTUnwrap(env.dockerTierConfiguration()?.hvProcess)
        XCTAssertArgumentPair(hv.arguments, "--data-drive", drive)
        XCTAssertEqual(env.machineManagerConfiguration()?.stateDirectory, drive + "/machines")
    }

    private func executableFixture(at path: String) throws -> String {
        try "#!/bin/sh\nexit 0\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    private func supportedRawHVPlatform() -> DorydHostPlatform {
        #if arch(x86_64)
        DorydHostPlatform(architecture: .x86_64, macOSMajorVersion: 15)
        #else
        DorydHostPlatform(architecture: .arm64, macOSMajorVersion: 15)
        #endif
    }

    private func supportedRawHVGuestArch() -> String {
        #if arch(x86_64)
        "amd64"
        #else
        "arm64"
        #endif
    }

    private func assertEngineSelection(
        platform: DorydHostPlatform,
        expectedRawHV: Bool
    ) throws {
        let directory = "/tmp/doryd-platform-config-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: directory) }

        let hvHelper = try executableFixture(at: directory + "/dory-hv")
        let vmmHelper = try executableFixture(at: directory + "/dory-vmm")
        let gvproxy = try executableFixture(at: directory + "/gvproxy")
        let kernel = directory + "/kernel"
        let rootfs = directory + "/rootfs.ext4"
        FileManager.default.createFile(atPath: kernel, contents: Data())
        FileManager.default.createFile(atPath: rootfs, contents: Data())

        let environment = DorydEnvironment(values: [
            "DORYD_HOME": directory + "/home",
            "DORYD_STATE_DIR": directory + "/state",
            "DORYD_HV_HELPER": hvHelper,
            "DORYD_HV_KERNEL": kernel,
            "DORYD_GVPROXY": gvproxy,
            "DORYD_ENGINE_ROOTFS": rootfs,
            "DORYD_VMM_HELPER": vmmHelper,
            "DORYD_VMM_KERNEL": kernel,
            "DORYD_VMM_ROOTFS": rootfs,
            // This remains a debug enable/disable switch, not a way to bypass binary compatibility.
            "DORYD_RAW_HV_SUPPORTED": "1",
        ], cwd: directory, hostPlatform: platform)

        let configuration = try XCTUnwrap(environment.dockerTierConfiguration())
        if expectedRawHV {
            XCTAssertEqual(configuration.hvProcess?.executablePath, hvHelper)
            XCTAssertNil(configuration.vmmProcess)
        } else {
            XCTAssertNil(configuration.hvProcess)
            XCTAssertEqual(configuration.vmmProcess?.executablePath, vmmHelper)
        }
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
