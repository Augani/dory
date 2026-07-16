@testable import DorydKit
import Darwin
import DoryCore
import XCTest

final class SourcePreservingLANPrivilegedControllerTests: XCTestCase {
    func testPFEnableTokenParsesExactMacOSUnsignedDecimalFormat() {
        XCTAssertEqual(
            SourcePreservingLANPrivilegedController.pfEnableToken(
                from: "pf enabled\nToken : 18446744073709551615\n"
            ),
            "18446744073709551615"
        )
        XCTAssertEqual(
            SourcePreservingLANPrivilegedController.pfEnableToken(
                from: "warning on stderr\n  Token : 42  \n"
            ),
            "42"
        )
    }

    func testPFEnableTokenRejectsMissingMalformedSignedOrHexTokens() {
        XCTAssertNil(SourcePreservingLANPrivilegedController.pfEnableToken(from: "pf enabled\n"))
        XCTAssertNil(SourcePreservingLANPrivilegedController.pfEnableToken(from: "Token : -1\n"))
        XCTAssertNil(SourcePreservingLANPrivilegedController.pfEnableToken(from: "Token : 0x2a\n"))
        XCTAssertNil(SourcePreservingLANPrivilegedController.pfEnableToken(from: "Token: 42\n"))
    }

    func testActivationConfiguresOwnedTunnelRouteAndDestinationOnlyPF() throws {
        let socketPath = try makeDatagramSocket()
        defer { unlink(socketPath) }
        let recorder = Recorder()
        let bridge = FakeBridge(interfaceName: "utun42")
        let controller = SourcePreservingLANPrivilegedController(
            enforceRoot: false,
            runtimeDirectory: "/tmp/dory-source-lan-runtime-\(getpid())-a",
            bridgeFactory: { configuration in
                recorder.configuration = configuration
                return bridge
            },
            runCommand: { command in try recorder.run(command) },
            writeAnchor: { recorder.anchors.append($0) }
        )
        let request = SourcePreservingLANRequest(
            operation: .activate,
            sessionID: "engine-1",
            gvproxySocketPath: socketPath,
            bindings: [
                PublishedPortBinding(protocol: .tcp, port: 8080),
                PublishedPortBinding(protocol: .tcp, port: 9000, hostIP: "127.0.0.1"),
            ],
            mtu: 1_400
        )

        let response = try controller.apply(request, clientUID: getuid())

        XCTAssertEqual(response.status, "active")
        XCTAssertEqual(response.interfaceName, "utun42")
        XCTAssertEqual(response.lanBindingCount, 1)
        XCTAssertEqual(recorder.configuration?.subnetCIDR, "192.168.215.254/32")
        XCTAssertEqual(recorder.configuration?.gateway, "192.168.215.253")
        XCTAssertEqual(recorder.configuration?.gvproxySocketPath, socketPath)
        XCTAssertTrue(bridge.started)
        XCTAssertTrue(recorder.commands.contains([
            "/sbin/ifconfig", "utun42", "inet", "192.168.215.253", "192.168.215.254",
            "netmask", "255.255.255.255", "mtu", "1400", "up",
        ]))
        XCTAssertTrue(recorder.commands.contains([
            "/sbin/route", "-n", "add", "-host", "192.168.215.254", "-interface", "utun42",
        ]))
        XCTAssertTrue(recorder.commands.contains([
            "/usr/sbin/sysctl", "-w", "net.inet.ip.forwarding=1",
        ]))
        XCTAssertEqual(recorder.commands.suffix(2).first, [
            "/sbin/pfctl", "-a", "com.apple/dev.dory.lan", "-f", "/etc/pf.anchors/dev.dory.lan",
        ])
        XCTAssertEqual(recorder.commands.last, ["/sbin/pfctl", "-E"])
        XCTAssertTrue(recorder.anchors.last?.contains("to self port 8080 -> 192.168.215.254 port 8080") == true)
        XCTAssertFalse(recorder.anchors.last?.contains("9000") == true)
    }

    func testActivationDerivesTunnelAndPFStateFromCustomBridgeSubnet() throws {
        let socketPath = try makeDatagramSocket()
        defer { unlink(socketPath) }
        let recorder = Recorder()
        let bridge = FakeBridge(interfaceName: "utun44")
        let controller = SourcePreservingLANPrivilegedController(
            enforceRoot: false,
            runtimeDirectory: "/tmp/dory-source-lan-runtime-\(getpid())-custom",
            bridgeFactory: { configuration in
                recorder.configuration = configuration
                return bridge
            },
            runCommand: { command in try recorder.run(command) },
            writeAnchor: { recorder.anchors.append($0) }
        )

        let response = try controller.apply(SourcePreservingLANRequest(
            operation: .activate,
            sessionID: "engine-custom",
            gvproxySocketPath: socketPath,
            bindings: [PublishedPortBinding(protocol: .tcp, port: 8080)],
            mtu: 1_400,
            bridgeSubnetCIDR: "10.44.16.0/20"
        ), clientUID: getuid())

        XCTAssertEqual(response.status, "active")
        XCTAssertEqual(recorder.configuration?.subnetCIDR, "10.44.31.254/32")
        XCTAssertEqual(recorder.configuration?.gateway, "10.44.31.253")
        XCTAssertTrue(recorder.commands.contains([
            "/sbin/ifconfig", "utun44", "inet", "10.44.31.253", "10.44.31.254",
            "netmask", "255.255.255.255", "mtu", "1400", "up",
        ]))
        XCTAssertTrue(recorder.commands.contains([
            "/sbin/route", "-n", "add", "-host", "10.44.31.254", "-interface", "utun44",
        ]))
        XCTAssertTrue(recorder.anchors.last?.contains(
            "to self port 8080 -> 10.44.31.254 port 8080"
        ) == true)
    }

    func testRejectsMTUOutsideTheGuestAndGVProxyContract() throws {
        let controller = SourcePreservingLANPrivilegedController(enforceRoot: false)

        for mtu in [1_279, 9_001] {
            XCTAssertThrowsError(try controller.apply(SourcePreservingLANRequest(
                operation: .activate,
                sessionID: "invalid-mtu",
                mtu: mtu
            ), clientUID: getuid())) { error in
                XCTAssertEqual(error as? SourcePreservingLANPrivilegedError, .invalidMTU(mtu))
            }
        }
    }

    func testRefreshAndDeactivateAreBoundToTheActiveSession() throws {
        let socketPath = try makeDatagramSocket()
        defer { unlink(socketPath) }
        let recorder = Recorder()
        let bridge = FakeBridge(interfaceName: "utun7")
        let controller = SourcePreservingLANPrivilegedController(
            enforceRoot: false,
            runtimeDirectory: "/tmp/dory-source-lan-runtime-\(getpid())-b",
            bridgeFactory: { _ in bridge },
            runCommand: { command in try recorder.run(command) },
            writeAnchor: { recorder.anchors.append($0) }
        )
        _ = try controller.apply(SourcePreservingLANRequest(
            operation: .activate,
            sessionID: "engine-a",
            gvproxySocketPath: socketPath
        ), clientUID: getuid())

        XCTAssertThrowsError(try controller.apply(SourcePreservingLANRequest(
            operation: .refresh,
            sessionID: "engine-b"
        ), clientUID: getuid())) { error in
            XCTAssertEqual(error as? SourcePreservingLANPrivilegedError, .noActiveSession)
        }

        let refreshed = try controller.apply(SourcePreservingLANRequest(
            operation: .refresh,
            sessionID: "engine-a",
            bindings: [PublishedPortBinding(protocol: .udp, port: 5353)]
        ), clientUID: getuid())
        XCTAssertEqual(refreshed.lanBindingCount, 1)
        XCTAssertTrue(recorder.anchors.last?.contains("proto udp") == true)

        let stopped = try controller.apply(SourcePreservingLANRequest(
            operation: .deactivate,
            sessionID: "engine-a"
        ), clientUID: getuid())
        XCTAssertEqual(stopped.status, "stopped")
        XCTAssertTrue(bridge.stopped)
        XCTAssertEqual(recorder.anchors.last, "# Managed by Dory. Do not edit.\n")
        XCTAssertTrue(recorder.commands.contains([
            "/sbin/pfctl", "-a", "com.apple/dev.dory.lan", "-F", "all",
        ]))
        XCTAssertTrue(recorder.commands.contains(["/sbin/pfctl", "-X", "424242"]))
        XCTAssertEqual(recorder.commands.last, [
            "/usr/sbin/sysctl", "-w", "net.inet.ip.forwarding=0",
        ])
    }

    func testRepeatedActivationForSameSessionIsIdempotentAndRefreshesBindings() throws {
        let socketPath = try makeDatagramSocket()
        defer { unlink(socketPath) }
        let recorder = Recorder()
        let bridge = FakeBridge(interfaceName: "utun9")
        let controller = SourcePreservingLANPrivilegedController(
            enforceRoot: false,
            runtimeDirectory: "/tmp/dory-source-lan-runtime-\(getpid())-idempotent",
            bridgeFactory: { _ in
                recorder.bridgeCreations += 1
                return bridge
            },
            runCommand: { command in try recorder.run(command) },
            writeAnchor: { recorder.anchors.append($0) }
        )
        _ = try controller.apply(SourcePreservingLANRequest(
            operation: .activate,
            sessionID: "engine-recovery",
            gvproxySocketPath: socketPath
        ), clientUID: getuid())

        let recovered = try controller.apply(SourcePreservingLANRequest(
            operation: .activate,
            sessionID: "engine-recovery",
            gvproxySocketPath: socketPath,
            bindings: [PublishedPortBinding(protocol: .tcp, port: 8088)]
        ), clientUID: getuid())

        XCTAssertEqual(recorder.bridgeCreations, 1)
        XCTAssertEqual(recovered.status, "active")
        XCTAssertEqual(recovered.interfaceName, "utun9")
        XCTAssertEqual(recovered.lanBindingCount, 1)
        XCTAssertTrue(recorder.anchors.last?.contains("port 8088") == true)
    }

    func testRejectsForeignOwnedOrNonSocketGVProxyPath() throws {
        let path = "/tmp/dory-source-lan-regular-\(getpid())-\(UUID().uuidString)"
        FileManager.default.createFile(atPath: path, contents: Data())
        defer { unlink(path) }
        let controller = SourcePreservingLANPrivilegedController(
            enforceRoot: false,
            runtimeDirectory: "/tmp/dory-source-lan-runtime-\(getpid())-c",
            bridgeFactory: { _ in FakeBridge(interfaceName: "utun1") },
            runCommand: { _ in "" },
            writeAnchor: { _ in }
        )
        XCTAssertThrowsError(try controller.apply(SourcePreservingLANRequest(
            operation: .activate,
            sessionID: "engine",
            gvproxySocketPath: path
        ), clientUID: getuid())) { error in
            XCTAssertEqual(error as? SourcePreservingLANPrivilegedError, .socketUnavailable(path))
        }
    }

    func testBridgeFailureFlushesPFAndAllowsSessionRecovery() throws {
        let socketPath = try makeDatagramSocket()
        defer { unlink(socketPath) }
        let recorder = Recorder()
        let first = FakeBridge(interfaceName: "utun11")
        let second = FakeBridge(interfaceName: "utun12")
        let bridges = [first, second]
        let controller = SourcePreservingLANPrivilegedController(
            enforceRoot: false,
            runtimeDirectory: "/tmp/dory-source-lan-runtime-\(getpid())-failure",
            bridgeFactory: { _ in
                let bridge = bridges[recorder.bridgeCreations]
                recorder.bridgeCreations += 1
                return bridge
            },
            runCommand: { command in try recorder.run(command) },
            writeAnchor: { recorder.anchors.append($0) }
        )
        let activation = SourcePreservingLANRequest(
            operation: .activate,
            sessionID: "engine-failure",
            gvproxySocketPath: socketPath,
            bindings: [PublishedPortBinding(protocol: .tcp, port: 8080)]
        )
        _ = try controller.apply(activation, clientUID: getuid())

        first.fail("fixture disconnect")

        XCTAssertTrue(first.stopped)
        XCTAssertEqual(recorder.anchors.last, "# Managed by Dory. Do not edit.\n")
        XCTAssertTrue(recorder.commands.contains([
            "/sbin/pfctl", "-a", "com.apple/dev.dory.lan", "-F", "all",
        ]))
        XCTAssertTrue(recorder.commands.contains(["/sbin/pfctl", "-X", "424242"]))
        XCTAssertEqual(recorder.commands.last, [
            "/usr/sbin/sysctl", "-w", "net.inet.ip.forwarding=0",
        ])
        XCTAssertThrowsError(try controller.apply(SourcePreservingLANRequest(
            operation: .refresh,
            sessionID: "engine-failure"
        ), clientUID: getuid()))

        let recovered = try controller.apply(activation, clientUID: getuid())
        XCTAssertEqual(recovered.interfaceName, "utun12")
        XCTAssertEqual(recorder.bridgeCreations, 2)
    }

    func testDaemonRestartReleasesPersistedPFReferenceAndFlushesStaleRules() throws {
        let runtime = "/tmp/dory-source-lan-runtime-\(getpid())-stale-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: runtime, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: runtime) }
        try "777777\n".write(
            toFile: runtime + "/pf-enable-token",
            atomically: true,
            encoding: .utf8
        )
        try "restore=0\n".write(
            toFile: runtime + "/ipv4-forwarding-owner",
            atomically: true,
            encoding: .utf8
        )
        XCTAssertEqual(chmod(runtime + "/pf-enable-token", 0o600), 0)
        XCTAssertEqual(chmod(runtime + "/ipv4-forwarding-owner", 0o600), 0)
        let recorder = Recorder()
        let controller = SourcePreservingLANPrivilegedController(
            enforceRoot: false,
            runtimeDirectory: runtime,
            bridgeFactory: { _ in FakeBridge(interfaceName: "utun1") },
            runCommand: { command in try recorder.run(command) },
            writeAnchor: { recorder.anchors.append($0) }
        )

        try controller.clearStaleAnchor()

        XCTAssertEqual(recorder.anchors.last, "# Managed by Dory. Do not edit.\n")
        XCTAssertTrue(recorder.commands.contains([
            "/sbin/pfctl", "-a", "com.apple/dev.dory.lan", "-F", "all",
        ]))
        XCTAssertTrue(recorder.commands.contains(["/sbin/pfctl", "-X", "777777"]))
        XCTAssertEqual(recorder.commands.last, [
            "/usr/sbin/sysctl", "-w", "net.inet.ip.forwarding=0",
        ])
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtime + "/pf-enable-token"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtime + "/ipv4-forwarding-owner"))
    }

    func testPreEnabledIPv4ForwardingIsNotClaimedOrDisabled() throws {
        let socketPath = try makeDatagramSocket()
        defer { unlink(socketPath) }
        let runtime = "/tmp/dory-source-lan-runtime-\(getpid())-preenabled-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: runtime) }
        let recorder = Recorder()
        recorder.forwardingValue = "1"
        let bridge = FakeBridge(interfaceName: "utun18")
        let controller = SourcePreservingLANPrivilegedController(
            enforceRoot: false,
            runtimeDirectory: runtime,
            bridgeFactory: { _ in bridge },
            runCommand: { command in try recorder.run(command) },
            writeAnchor: { recorder.anchors.append($0) }
        )
        _ = try controller.apply(SourcePreservingLANRequest(
            operation: .activate,
            sessionID: "engine-forwarding",
            gvproxySocketPath: socketPath
        ), clientUID: getuid())
        _ = try controller.apply(SourcePreservingLANRequest(
            operation: .deactivate,
            sessionID: "engine-forwarding"
        ), clientUID: getuid())

        XCTAssertFalse(recorder.commands.contains([
            "/usr/sbin/sysctl", "-w", "net.inet.ip.forwarding=1",
        ]))
        XCTAssertFalse(recorder.commands.contains([
            "/usr/sbin/sysctl", "-w", "net.inet.ip.forwarding=0",
        ]))
        XCTAssertEqual(recorder.forwardingValue, "1")
    }

    func testDeactivationFailureRetainsOwnershipForACompleteRetry() throws {
        let socketPath = try makeDatagramSocket()
        defer { unlink(socketPath) }
        let runtime = temporaryRuntime("retry-cleanup")
        defer { try? FileManager.default.removeItem(atPath: runtime) }
        let recorder = Recorder()
        let bridge = FakeBridge(interfaceName: "utun31")
        let controller = SourcePreservingLANPrivilegedController(
            enforceRoot: false,
            runtimeDirectory: runtime,
            bridgeFactory: { _ in bridge },
            runCommand: { command in try recorder.run(command) },
            writeAnchor: { recorder.anchors.append($0) }
        )
        let activation = SourcePreservingLANRequest(
            operation: .activate,
            sessionID: "retry-cleanup",
            gvproxySocketPath: socketPath
        )
        let deactivation = SourcePreservingLANRequest(
            operation: .deactivate,
            sessionID: "retry-cleanup"
        )
        _ = try controller.apply(activation, clientUID: getuid())
        recorder.failNext([
            "/sbin/pfctl", "-a", "com.apple/dev.dory.lan", "-F", "all",
        ])

        XCTAssertThrowsError(try controller.apply(deactivation, clientUID: getuid()))
        XCTAssertTrue(bridge.stopped)
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtime + "/pf-enable-token"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtime + "/ipv4-forwarding-owner"))

        let stopped = try controller.apply(deactivation, clientUID: getuid())
        XCTAssertEqual(stopped.status, "stopped")
        XCTAssertEqual(recorder.commands.filter { $0 == ["/sbin/pfctl", "-E"] }.count, 1)
        XCTAssertEqual(
            recorder.commands.filter { $0 == ["/sbin/pfctl", "-X", "424242"] }.count,
            1
        )
        XCTAssertEqual(
            recorder.commands.filter {
                $0 == ["/usr/sbin/sysctl", "-w", "net.inet.ip.forwarding=0"]
            }.count,
            1
        )
    }

    func testDelayedFailureFromOldBridgeCannotTearDownReplacement() throws {
        let socketPath = try makeDatagramSocket()
        defer { unlink(socketPath) }
        let runtime = temporaryRuntime("bridge-identity")
        defer { try? FileManager.default.removeItem(atPath: runtime) }
        let recorder = Recorder()
        let first = FakeBridge(interfaceName: "utun41")
        let second = FakeBridge(interfaceName: "utun42")
        let bridges = [first, second]
        let controller = SourcePreservingLANPrivilegedController(
            enforceRoot: false,
            runtimeDirectory: runtime,
            bridgeFactory: { _ in
                defer { recorder.bridgeCreations += 1 }
                return bridges[recorder.bridgeCreations]
            },
            runCommand: { command in try recorder.run(command) },
            writeAnchor: { recorder.anchors.append($0) }
        )
        let activation = SourcePreservingLANRequest(
            operation: .activate,
            sessionID: "stable-session",
            gvproxySocketPath: socketPath
        )
        _ = try controller.apply(activation, clientUID: getuid())
        _ = try controller.apply(SourcePreservingLANRequest(
            operation: .deactivate,
            sessionID: "stable-session"
        ), clientUID: getuid())
        _ = try controller.apply(activation, clientUID: getuid())

        first.fail("delayed callback")

        let refreshed = try controller.apply(SourcePreservingLANRequest(
            operation: .refresh,
            sessionID: "stable-session",
            bindings: [PublishedPortBinding(protocol: .tcp, port: 8080)]
        ), clientUID: getuid())
        XCTAssertEqual(refreshed.interfaceName, "utun42")
        XCTAssertFalse(second.stopped)
    }

    func testSessionMutationAndUninstallCleanupCannotCrossUsers() throws {
        let socketPath = try makeDatagramSocket()
        defer { unlink(socketPath) }
        let runtime = temporaryRuntime("owner-bound")
        defer { try? FileManager.default.removeItem(atPath: runtime) }
        let recorder = Recorder()
        let bridge = FakeBridge(interfaceName: "utun46")
        let controller = SourcePreservingLANPrivilegedController(
            enforceRoot: false,
            runtimeDirectory: runtime,
            bridgeFactory: { _ in bridge },
            runCommand: { command in try recorder.run(command) },
            writeAnchor: { recorder.anchors.append($0) },
            removeAnchor: { recorder.anchorRemoved = true }
        )
        let owner = getuid()
        let other = owner + 1
        _ = try controller.apply(SourcePreservingLANRequest(
            operation: .activate,
            sessionID: "owner-bound",
            gvproxySocketPath: socketPath
        ), clientUID: owner)

        XCTAssertThrowsError(try controller.apply(SourcePreservingLANRequest(
            operation: .refresh,
            sessionID: "owner-bound"
        ), clientUID: other)) { error in
            XCTAssertEqual(
                error as? SourcePreservingLANPrivilegedError,
                .sessionOwnerMismatch(expected: owner, actual: other)
            )
        }
        XCTAssertThrowsError(try controller.removeOwnedState(clientUID: other))
        XCTAssertFalse(bridge.stopped)

        try controller.removeOwnedState(clientUID: owner)
        XCTAssertTrue(bridge.stopped)
        XCTAssertTrue(recorder.anchorRemoved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtime + "/pf-enable-token"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtime + "/ipv4-forwarding-owner"))
        XCTAssertThrowsError(try controller.apply(SourcePreservingLANRequest(
            operation: .activate,
            sessionID: "owner-bound-next",
            gvproxySocketPath: socketPath
        ), clientUID: owner)) { error in
            XCTAssertEqual(error as? SourcePreservingLANPrivilegedError, .decommissioned)
        }
    }

    func testForwardingEnableFailureUsesPersistedOwnershipToRestoreHost() throws {
        let socketPath = try makeDatagramSocket()
        defer { unlink(socketPath) }
        let runtime = temporaryRuntime("forwarding-failure")
        defer { try? FileManager.default.removeItem(atPath: runtime) }
        let recorder = Recorder()
        recorder.failNext([
            "/usr/sbin/sysctl", "-w", "net.inet.ip.forwarding=1",
        ])
        let bridge = FakeBridge(interfaceName: "utun51")
        let controller = SourcePreservingLANPrivilegedController(
            enforceRoot: false,
            runtimeDirectory: runtime,
            bridgeFactory: { _ in bridge },
            runCommand: { command in try recorder.run(command) },
            writeAnchor: { recorder.anchors.append($0) }
        )

        XCTAssertThrowsError(try controller.apply(SourcePreservingLANRequest(
            operation: .activate,
            sessionID: "forwarding-failure",
            gvproxySocketPath: socketPath
        ), clientUID: getuid()))

        XCTAssertTrue(bridge.stopped)
        XCTAssertEqual(recorder.forwardingValue, "0")
        XCTAssertTrue(recorder.commands.contains([
            "/usr/sbin/sysctl", "-w", "net.inet.ip.forwarding=0",
        ]))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: runtime + "/ipv4-forwarding-owner"
        ))
    }

    func testRejectsSymlinkRuntimeBeforeCreatingPrivilegedBridge() throws {
        let socketPath = try makeDatagramSocket()
        defer { unlink(socketPath) }
        let target = temporaryRuntime("runtime-target")
        let runtime = temporaryRuntime("runtime-link")
        try? FileManager.default.removeItem(atPath: runtime)
        try FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: runtime, withDestinationPath: target)
        defer {
            try? FileManager.default.removeItem(atPath: runtime)
            try? FileManager.default.removeItem(atPath: target)
        }
        let recorder = Recorder()
        let controller = SourcePreservingLANPrivilegedController(
            enforceRoot: false,
            runtimeDirectory: runtime,
            bridgeFactory: { _ in
                recorder.bridgeCreations += 1
                return FakeBridge(interfaceName: "utun61")
            },
            runCommand: { command in try recorder.run(command) },
            writeAnchor: { recorder.anchors.append($0) }
        )

        XCTAssertThrowsError(try controller.apply(SourcePreservingLANRequest(
            operation: .activate,
            sessionID: "unsafe-runtime",
            gvproxySocketPath: socketPath
        ), clientUID: getuid()))
        XCTAssertEqual(recorder.bridgeCreations, 0)
    }

    func testStartupCleanupFailureIsReportedInsteadOfStartingDirty() throws {
        let runtime = temporaryRuntime("startup-failure")
        try FileManager.default.createDirectory(atPath: runtime, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: runtime) }
        let recorder = Recorder()
        recorder.failNext([
            "/sbin/pfctl", "-a", "com.apple/dev.dory.lan", "-F", "all",
        ])
        let controller = SourcePreservingLANPrivilegedController(
            enforceRoot: false,
            runtimeDirectory: runtime,
            bridgeFactory: { _ in FakeBridge(interfaceName: "utun71") },
            runCommand: { command in try recorder.run(command) },
            writeAnchor: { recorder.anchors.append($0) }
        )

        XCTAssertThrowsError(try controller.clearStaleAnchor())
    }

    private func makeDatagramSocket() throws -> String {
        let path = "/tmp/dory-source-lan-\(getpid())-\(UUID().uuidString).sock"
        let descriptor = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.ENOTSOCK) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        close(descriptor)
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL) }
        return path
    }

    private func temporaryRuntime(_ label: String) -> String {
        "/tmp/dory-source-lan-runtime-\(getpid())-\(label)-\(UUID().uuidString)"
    }
}

private final class Recorder: @unchecked Sendable {
    var configuration: DirectIPBridgeConfiguration?
    var commands = [[String]]()
    var anchors = [String]()
    var anchorRemoved = false
    var bridgeCreations = 0
    var forwardingValue = "0"
    private var failingCommand: [String]?

    func failNext(_ command: [String]) {
        failingCommand = command
    }

    func run(_ command: [String]) throws -> String {
        commands.append(command)
        if failingCommand == command {
            failingCommand = nil
            throw RecorderError.injectedFailure
        }
        if command == ["/sbin/pfctl", "-E"] { return "pf enabled\nToken : 424242\n" }
        if command == ["/usr/sbin/sysctl", "-n", "net.inet.ip.forwarding"] {
            return forwardingValue + "\n"
        }
        if command == ["/usr/sbin/sysctl", "-w", "net.inet.ip.forwarding=1"] {
            forwardingValue = "1"
        } else if command == ["/usr/sbin/sysctl", "-w", "net.inet.ip.forwarding=0"] {
            forwardingValue = "0"
        }
        return ""
    }
}

private enum RecorderError: Error {
    case injectedFailure
}

private final class FakeBridge: SourcePreservingLANBridgeSession, @unchecked Sendable {
    let activeInterfaceName: String?
    var started = false
    var stopped = false
    var isHealthy = true
    private var failureHandler: (@Sendable (String) -> Void)?

    init(interfaceName: String?) { self.activeInterfaceName = interfaceName }
    func start() throws { started = true }
    func stop() { stopped = true; isHealthy = false }
    func setFailureHandler(_ handler: @escaping @Sendable (String) -> Void) {
        failureHandler = handler
    }
    func fail(_ detail: String) {
        isHealthy = false
        failureHandler?(detail)
    }
}
