import Darwin
@testable import DoryHV
import Foundation
import Testing

@Suite struct EngineVsockBridgeLifecycleTests {
    @Test func dockerRepeatAttachCannotMutatePathAndStopPreservesReplacement() throws {
        let fixture = try socketFixture(prefix: "dory-docker-bridge-owned")
        defer { try? FileManager.default.removeItem(atPath: fixture.directory) }
        let bridge = DockerSocketBridge(
            socketPath: fixture.path
        )
        try bridge.attach(to: VirtioVsock(guestCID: 3))
        let publishedIdentity = try #require(pathIdentity(fixture.path))

        #expect(throws: (any Error).self) {
            try bridge.attach(to: VirtioVsock(guestCID: 4))
        }
        #expect(pathIdentity(fixture.path) == publishedIdentity)

        #expect(unlink(fixture.path) == 0)
        let replacement = try VsockUnixRelay.makeOwnedListener(
            socketPath: fixture.path,
            mode: 0o600
        )
        defer {
            VsockUnixRelay.retireOwnedListener(replacement, socketPath: fixture.path)
        }
        let replacementIdentity = try #require(pathIdentity(fixture.path))
        #expect(replacementIdentity != publishedIdentity)

        bridge.stop(timeout: 2)
        #expect(pathIdentity(fixture.path) == replacementIdentity)
        let probe = try connectUnixSocket(fixture.path)
        close(probe)
    }

    @Test func dockerAdmissionBoundRejectsExcessAndStopDrainsRelay() throws {
        let fixture = try socketFixture(prefix: "dory-docker-bridge-admission")
        defer { try? FileManager.default.removeItem(atPath: fixture.directory) }
        let bridge = DockerSocketBridge(
            socketPath: fixture.path
        )
        let device = try serviceLimitedDevice(service: .docker)
        try bridge.attach(to: device)

        let admitted = try connectUnixSocket(fixture.path)
        defer { close(admitted) }
        #expect(waitUntil { bridge.activeSessionCount == 1 })

        let excess = try connectUnixSocket(fixture.path)
        defer { close(excess) }
        #expect(waitUntil {
            bridge.serviceAdmissionSnapshot?.serviceCapacityRejections[.docker] == 1
        })
        #expect(waitUntil { peerWasClosed(excess) })
        #expect(bridge.activeSessionCount == 1)

        bridge.stop(timeout: 2)
        #expect(bridge.activeSessionCount == 0)
        #expect(waitUntil { peerWasClosed(admitted) })
        #expect(pathIdentity(fixture.path) == nil)
    }

    @Test func stalledAgentPreambleConsumesCapacityAndStopCancelsIt() throws {
        let fixture = try socketFixture(prefix: "dory-agent-forward-preamble")
        defer { try? FileManager.default.removeItem(atPath: fixture.directory) }
        let forward = AgentVsockForward(
            socketPath: fixture.path,
            guestCID: 3
        )
        let device = try serviceLimitedDevice(service: .agentForward)
        try forward.attach(to: device)

        // Send no preamble: this connection must count against the same limit as an established
        // relay, and stop must wake its bounded blocking read rather than waiting ten seconds.
        let stalled = try connectUnixSocket(fixture.path)
        defer { close(stalled) }
        #expect(waitUntil { forward.activeSessionCount == 1 })

        let excess = try connectUnixSocket(fixture.path)
        defer { close(excess) }
        #expect(waitUntil {
            forward.serviceAdmissionSnapshot?
                .serviceCapacityRejections[.agentForward] == 1
        })
        #expect(waitUntil { peerWasClosed(excess) })

        let started = ProcessInfo.processInfo.systemUptime
        forward.stop(timeout: 2)
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        #expect(elapsed < 1.5)
        #expect(forward.activeSessionCount == 0)
        #expect(waitUntil { peerWasClosed(stalled) })
        #expect(pathIdentity(fixture.path) == nil)

        // The one-shot lifecycle rejects post-stop attach before a successor endpoint is touched.
        let replacement = try VsockUnixRelay.makeOwnedListener(
            socketPath: fixture.path,
            mode: 0o600
        )
        defer {
            VsockUnixRelay.retireOwnedListener(replacement, socketPath: fixture.path)
        }
        let replacementIdentity = try #require(pathIdentity(fixture.path))
        #expect(throws: (any Error).self) {
            try forward.attach(to: VirtioVsock(guestCID: 4))
        }
        #expect(pathIdentity(fixture.path) == replacementIdentity)
    }

    @Test func silentPreambleCannotBypassCrossServiceAggregateBudget() throws {
        let forwardFixture = try socketFixture(prefix: "dory-vsock-cross-forward")
        let dockerFixture = try socketFixture(prefix: "dory-vsock-cross-docker")
        defer {
            try? FileManager.default.removeItem(atPath: forwardFixture.directory)
            try? FileManager.default.removeItem(atPath: dockerFixture.directory)
        }
        let limits = try VirtioVsockServiceAdmissionLimits(
            maximumSessionsTotal: 1,
            defaultMaximumSessionsPerService: 1
        )
        let device = VirtioVsock(guestCID: 3, serviceAdmissionLimits: limits)
        let forward = AgentVsockForward(
            socketPath: forwardFixture.path,
            guestCID: 3
        )
        let docker = DockerSocketBridge(socketPath: dockerFixture.path)
        defer {
            docker.stop(timeout: 2)
            forward.stop(timeout: 2)
        }
        try forward.attach(to: device)
        try docker.attach(to: device)

        // No preamble is sent. The accepted descriptor is already an owned agentForward session,
        // so it consumes the one aggregate lease before any guest port can be selected.
        let stalled = try connectUnixSocket(forwardFixture.path)
        #expect(waitUntil {
            device.serviceAdmissionSnapshot.activeSessionsByService[.agentForward] == 1
        })

        let rejectedDocker = try connectUnixSocket(dockerFixture.path)
        defer { close(rejectedDocker) }
        #expect(waitUntil { peerWasClosed(rejectedDocker) })
        #expect(device.serviceAdmissionSnapshot.aggregateCapacityRejections == 1)
        #expect(docker.activeSessionCount == 0)

        close(stalled)
        #expect(waitUntil { device.serviceAdmissionSnapshot.activeSessionsTotal == 0 })

        // Releasing the exact stalled generation makes capacity immediately reusable by another
        // service without restarting either listener.
        let admittedDocker = try connectUnixSocket(dockerFixture.path)
        defer { close(admittedDocker) }
        #expect(waitUntil {
            device.serviceAdmissionSnapshot.activeSessionsByService[.docker] == 1
                && docker.activeSessionCount == 1
        })
    }

    private func socketFixture(prefix: String) throws -> (directory: String, path: String) {
        let directory = "/tmp/\(prefix)-\(getpid())-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: false
        )
        guard chmod(directory, 0o700) == 0 else { throw POSIXError(.EACCES) }
        return (directory, directory + "/bridge.sock")
    }

    private func serviceLimitedDevice(
        service: VirtioVsockService
    ) throws -> VirtioVsock {
        let limits = try VirtioVsockServiceAdmissionLimits(
            maximumSessionsTotal: 4,
            defaultMaximumSessionsPerService: 4,
            serviceOverrides: [service: 1]
        )
        return VirtioVsock(guestCID: 3, serviceAdmissionLimits: limits)
    }

    private func connectUnixSocket(_ path: String) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        var transferred = false
        defer { if !transferred { close(descriptor) } }
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var noSigpipe: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigpipe,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            bytes.withUnsafeBytes { source in
                destination.baseAddress!.copyMemory(
                    from: source.baseAddress!,
                    byteCount: bytes.count
                )
            }
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        transferred = true
        return descriptor
    }

    private func peerWasClosed(_ descriptor: Int32) -> Bool {
        var readiness = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&readiness, 1, 0) > 0 else { return false }
        if readiness.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
            return true
        }
        guard readiness.revents & Int16(POLLIN) != 0 else { return false }
        var byte: UInt8 = 0
        return recv(descriptor, &byte, 1, MSG_PEEK | MSG_DONTWAIT) == 0
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ predicate: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            usleep(1_000)
        }
        return predicate()
    }

    private func pathIdentity(_ path: String) -> EngineBridgePathIdentity? {
        var info = stat()
        guard lstat(path, &info) == 0,
              info.st_mode & S_IFMT == S_IFSOCK else {
            return nil
        }
        return EngineBridgePathIdentity(
            device: info.st_dev,
            inode: info.st_ino,
            generation: info.st_gen,
            birthTimeSeconds: Int64(info.st_birthtimespec.tv_sec),
            birthTimeNanoseconds: Int64(info.st_birthtimespec.tv_nsec)
        )
    }
}

private struct EngineBridgePathIdentity: Equatable {
    var device: dev_t
    var inode: ino_t
    var generation: UInt32
    var birthTimeSeconds: Int64
    var birthTimeNanoseconds: Int64
}
