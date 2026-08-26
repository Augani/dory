import Darwin
@testable import DoryHV
import Foundation
import Testing

@Suite struct GuestVsockSocketBridgeLifecycleTests {
    @Test func stopClosesListenerUnlinksPathAndIsIdempotent() throws {
        let fixture = try socketFixture(prefix: "dory-vsock-bridge-stop")
        defer { try? FileManager.default.removeItem(atPath: fixture.directory) }

        let first = GuestVsockSocketBridge(
            socketPath: fixture.path,
            guestPort: 1_027,
            service: .shell
        )
        try first.attach(to: VirtioVsock(guestCID: 3))
        #expect(socketExists(fixture.path))
        first.stop(timeout: 2)
        first.stop(timeout: 2)
        #expect(!socketExists(fixture.path))

        // stop() returns only after the old path cleanup completed, so immediate rebinding is safe.
        let second = GuestVsockSocketBridge(
            socketPath: fixture.path,
            guestPort: 1_027,
            service: .shell
        )
        try second.attach(to: VirtioVsock(guestCID: 4))
        #expect(socketExists(fixture.path))
        second.stop(timeout: 2)
        #expect(!socketExists(fixture.path))
    }

    @Test func repeatedAndConcurrentAttachRejectBeforeMutatingPublishedPath() throws {
        let fixture = try socketFixture(prefix: "dory-vsock-bridge-double-attach")
        defer { try? FileManager.default.removeItem(atPath: fixture.directory) }
        let bridge = GuestVsockSocketBridge(
            socketPath: fixture.path,
            guestPort: 1_027,
            service: .shell
        )
        try bridge.attach(to: VirtioVsock(guestCID: 5))
        let publishedIdentity = try #require(pathIdentity(fixture.path))

        #expect(throws: (any Error).self) {
            try bridge.attach(to: VirtioVsock(guestCID: 6))
        }
        #expect(pathIdentity(fixture.path) == publishedIdentity)
        let probe = try connectUnixSocket(fixture.path)
        close(probe)
        bridge.stop(timeout: 2)

        let concurrentFixture = try socketFixture(
            prefix: "dory-vsock-bridge-concurrent-attach"
        )
        defer {
            try? FileManager.default.removeItem(atPath: concurrentFixture.directory)
        }
        let concurrent = GuestVsockSocketBridge(
            socketPath: concurrentFixture.path,
            guestPort: 1_027,
            service: .shell
        )
        let results = LockedAttachResults()
        let gate = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        for cid in [UInt32(7), UInt32(8)] {
            group.enter()
            DispatchQueue.global().async {
                gate.wait()
                do {
                    try concurrent.attach(to: VirtioVsock(guestCID: cid))
                    results.recordSuccess()
                } catch {
                    results.recordFailure()
                }
                group.leave()
            }
        }
        gate.signal()
        gate.signal()
        #expect(group.wait(timeout: .now() + 2) == .success)
        #expect(results.snapshot == (successes: 1, failures: 1))
        #expect(socketExists(concurrentFixture.path))
        concurrent.stop(timeout: 2)
    }

    @Test func stopDoesNotUnlinkReplacementSocketIdentity() throws {
        let fixture = try socketFixture(prefix: "dory-vsock-bridge-owned-path")
        defer { try? FileManager.default.removeItem(atPath: fixture.directory) }
        let bridge = GuestVsockSocketBridge(
            socketPath: fixture.path,
            guestPort: 1_027,
            service: .shell
        )
        try bridge.attach(to: VirtioVsock(guestCID: 9))
        let originalIdentity = try #require(pathIdentity(fixture.path))

        #expect(unlink(fixture.path) == 0)
        let replacement = try VsockUnixRelay.makeOwnedListener(
            socketPath: fixture.path,
            mode: 0o600
        )
        defer {
            VsockUnixRelay.retireOwnedListener(
                replacement,
                socketPath: fixture.path
            )
        }
        let replacementIdentity = try #require(pathIdentity(fixture.path))
        #expect(replacementIdentity != originalIdentity)

        bridge.stop(timeout: 2)
        #expect(pathIdentity(fixture.path) == replacementIdentity)
        let probe = try connectUnixSocket(fixture.path)
        close(probe)
    }

    @Test func concurrentSessionBoundRejectsExcessAndStopDrainsAdmittedRelay() throws {
        let fixture = try socketFixture(prefix: "dory-vsock-bridge-admission")
        defer { try? FileManager.default.removeItem(atPath: fixture.directory) }
        let bridge = GuestVsockSocketBridge(
            socketPath: fixture.path,
            guestPort: 1_027,
            service: .shell
        )
        let admissionLimits = try VirtioVsockServiceAdmissionLimits(
            maximumSessionsTotal: 4,
            defaultMaximumSessionsPerService: 4,
            serviceOverrides: [.shell: 1]
        )
        let device = VirtioVsock(
            guestCID: 10,
            serviceAdmissionLimits: admissionLimits
        )
        try bridge.attach(to: device)

        let admitted = try connectUnixSocket(fixture.path)
        defer { close(admitted) }
        #expect(waitUntil { bridge.activeSessionCount == 1 })

        let excess = try connectUnixSocket(fixture.path)
        defer { close(excess) }
        #expect(waitUntil {
            bridge.serviceAdmissionSnapshot?.serviceCapacityRejections[.shell] == 1
        })
        #expect(waitUntil { peerWasClosed(excess) })
        #expect(bridge.activeSessionCount == 1)

        bridge.stop(timeout: 2)
        #expect(bridge.activeSessionCount == 0)
        #expect(waitUntil { peerWasClosed(admitted) })
        #expect(!socketExists(fixture.path))
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

    private func connectUnixSocket(_ path: String) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        var transferred = false
        defer {
            if !transferred { close(descriptor) }
        }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        var noSigpipe: Int32 = 1
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigpipe,
            socklen_t(MemoryLayout<Int32>.size)
        )
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
        var readiness = pollfd(
            fd: descriptor,
            events: Int16(POLLIN),
            revents: 0
        )
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

    private func socketExists(_ path: String) -> Bool {
        pathIdentity(path) != nil
    }

    private func pathIdentity(_ path: String) -> PathIdentity? {
        var info = stat()
        guard lstat(path, &info) == 0,
              info.st_mode & S_IFMT == S_IFSOCK else {
            return nil
        }
        return PathIdentity(device: info.st_dev, inode: info.st_ino)
    }
}

private struct PathIdentity: Equatable {
    var device: dev_t
    var inode: ino_t
}

private final class LockedAttachResults: @unchecked Sendable {
    private let lock = NSLock()
    private var successes = 0
    private var failures = 0

    var snapshot: (successes: Int, failures: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (successes, failures)
    }

    func recordSuccess() {
        lock.lock()
        successes += 1
        lock.unlock()
    }

    func recordFailure() {
        lock.lock()
        failures += 1
        lock.unlock()
    }
}
