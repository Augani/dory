import Darwin
import DoryHV
import Foundation
import Testing
@testable import dory_hv

@Suite(.serialized)
struct RawHVSerialConsoleInputTests {
    @Test func acceptsOnlyACompleteBoundedFrameAndPublishesOwnerPrivateSocket() throws {
        let fixture = try SerialConsoleFixture()
        defer { fixture.cleanup() }
        let server = try fixture.makeServer()
        defer { server.stop() }

        var published = stat()
        #expect(lstat(fixture.socketPath, &published) == 0)
        #expect(published.st_mode & S_IFMT == S_IFSOCK)
        #expect(published.st_mode & 0o777 == 0o600)
        #expect(published.st_uid == geteuid())

        let payload = Array("recovery\n".utf8)
        let client = try connectUnixSocket(fixture.socketPath)
        try writeAll(payload, to: client)
        #expect(shutdown(client, SHUT_WR) == 0)
        close(client)

        #expect(
            eventually { server.metrics.acceptedFrameCount == 1 },
            "metrics: \(server.metrics)"
        )
        #expect(server.metrics.acceptedByteCount == UInt64(payload.count))
        #expect(drainUART(fixture.uart) == payload)

        server.stop()
        #expect(lstat(fixture.socketPath, &published) != 0)
        #expect(errno == ENOENT)
    }

    @Test func slowClientCannotResetWholeFrameDeadlineOrBlockAdmissionForever() throws {
        let fixture = try SerialConsoleFixture()
        defer { fixture.cleanup() }
        let diagnostics = LockedDiagnostics()
        let server = try fixture.makeServer(
            maximumConcurrentClients: 1,
            maximumFrameBytes: 16,
            frameTimeout: 0.15,
            log: { diagnostics.append($0) }
        )
        defer { server.stop() }

        let slow = try connectUnixSocket(fixture.socketPath)
        defer { close(slow) }
        try writeAll([0x61], to: slow)
        #expect(eventually { server.metrics.activeClientCount == 1 })

        let overflow = try connectUnixSocket(fixture.socketPath)
        defer { close(overflow) }
        #expect(eventually { server.metrics.rejectedCapacityCount == 1 })

        usleep(80_000)
        _ = try? writeAll([0x62], to: slow)
        #expect(eventually(timeout: 0.5) { server.metrics.timedOutFrameCount == 1 })
        #expect(server.metrics.activeClientCount == 0)
        #expect(drainUART(fixture.uart).isEmpty)
        #expect(diagnostics.values.contains { $0.contains("whole-frame deadline") })

        let healthy = try connectUnixSocket(fixture.socketPath)
        try writeAll([0x63], to: healthy)
        _ = shutdown(healthy, SHUT_WR)
        close(healthy)
        #expect(eventually { server.metrics.acceptedFrameCount == 1 })
        #expect(drainUART(fixture.uart) == [0x63])
    }

    @Test func oversizedAndEmptyFramesAreRejectedAtomically() throws {
        let fixture = try SerialConsoleFixture()
        defer { fixture.cleanup() }
        let server = try fixture.makeServer(maximumFrameBytes: 8)
        defer { server.stop() }

        let oversized = try connectUnixSocket(fixture.socketPath)
        try writeAll([UInt8](repeating: 0x41, count: 9), to: oversized)
        _ = shutdown(oversized, SHUT_WR)
        close(oversized)
        #expect(eventually { server.metrics.rejectedOversizedFrameCount == 1 })
        #expect(drainUART(fixture.uart).isEmpty)

        let empty = try connectUnixSocket(fixture.socketPath)
        _ = shutdown(empty, SHUT_WR)
        close(empty)
        #expect(eventually { server.metrics.rejectedEmptyFrameCount == 1 })
        #expect(server.metrics.acceptedFrameCount == 0)
        #expect(drainUART(fixture.uart).isEmpty)
    }

    @Test func stopWakesAcceptAndReadThenAllowsCleanRestart() throws {
        let fixture = try SerialConsoleFixture()
        defer { fixture.cleanup() }

        let accepting = try fixture.makeServer()
        let acceptStopStarted = ProcessInfo.processInfo.systemUptime
        accepting.stop(timeout: 1)
        accepting.stop(timeout: 1)
        #expect(ProcessInfo.processInfo.systemUptime - acceptStopStarted < 1)

        let reading = try fixture.makeServer(frameTimeout: 5)
        let client = try connectUnixSocket(fixture.socketPath)
        try writeAll([0x78], to: client)
        #expect(eventually { reading.metrics.activeClientCount == 1 })
        let readStopStarted = ProcessInfo.processInfo.systemUptime
        reading.stop(timeout: 1)
        reading.stop(timeout: 1)
        #expect(ProcessInfo.processInfo.systemUptime - readStopStarted < 1)
        #expect(reading.metrics.activeClientCount == 0)
        close(client)
        #expect(drainUART(fixture.uart).isEmpty)

        let restarted = try fixture.makeServer()
        defer { restarted.stop() }
        let replacement = try connectUnixSocket(fixture.socketPath)
        try writeAll([0x79], to: replacement)
        _ = shutdown(replacement, SHUT_WR)
        close(replacement)
        #expect(eventually { restarted.metrics.acceptedFrameCount == 1 })
        #expect(drainUART(fixture.uart) == [0x79])
    }

    @Test func pathValidationRejectsTraversalEmbeddedNullAndUntrustedNodes() throws {
        let fixture = try SerialConsoleFixture()
        defer { fixture.cleanup() }

        #expect(throws: RawHVSerialConsoleInputError.self) {
            _ = try RawHVSerialConsoleInput(socketPath: "relative.sock", uart: fixture.uart)
        }
        #expect(throws: RawHVSerialConsoleInputError.self) {
            _ = try RawHVSerialConsoleInput(
                socketPath: fixture.root + "/bad\0tail.sock",
                uart: fixture.uart
            )
        }
        #expect(throws: RawHVSerialConsoleInputError.self) {
            _ = try RawHVSerialConsoleInput(
                socketPath: "/tmp/" + String(repeating: "é", count: 80),
                uart: fixture.uart
            )
        }
        #expect(throws: RawHVSerialConsoleInputError.self) {
            _ = try RawHVSerialConsoleInput(
                socketPath: fixture.root + "/sub/../console.sock",
                uart: fixture.uart
            )
        }

        guard chmod(fixture.root, 0o722) == 0 else { throw POSIXError(.EIO) }
        #expect(throws: RawHVSerialConsoleInputError.self) {
            _ = try fixture.makeServer()
        }
        guard chmod(fixture.root, 0o700) == 0 else { throw POSIXError(.EIO) }

        let original = Data("preserve".utf8)
        try original.write(to: URL(fileURLWithPath: fixture.socketPath))
        #expect(throws: RawHVSerialConsoleInputError.self) {
            _ = try fixture.makeServer()
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.socketPath)) == original)
        try FileManager.default.removeItem(atPath: fixture.socketPath)

        let target = fixture.root + "/target"
        try original.write(to: URL(fileURLWithPath: target))
        #expect(symlink(target, fixture.socketPath) == 0)
        #expect(throws: RawHVSerialConsoleInputError.self) {
            _ = try fixture.makeServer()
        }
        var linkInfo = stat()
        #expect(lstat(fixture.socketPath, &linkInfo) == 0)
        #expect(linkInfo.st_mode & S_IFMT == S_IFLNK)
        #expect(try Data(contentsOf: URL(fileURLWithPath: target)) == original)
        #expect(unlink(fixture.socketPath) == 0)

        let actualParent = fixture.root + "/actual"
        try makePrivateDirectory(actualParent)
        let linkedParent = fixture.root + "/linked"
        #expect(symlink(actualParent, linkedParent) == 0)
        #expect(throws: RawHVSerialConsoleInputError.self) {
            _ = try RawHVSerialConsoleInput(
                socketPath: linkedParent + "/console.sock",
                uart: fixture.uart
            )
        }
    }

    @Test func trustedStaleSocketIsReplacedOnlyAfterDescriptorSetup() throws {
        let fixture = try SerialConsoleFixture()
        defer { fixture.cleanup() }
        let stale = try makeUnixListener(fixture.socketPath)
        let staleIdentity = try socketIdentity(fixture.socketPath)
        close(stale)

        let server = try fixture.makeServer()
        defer { server.stop() }
        let replacementIdentity = try socketIdentity(fixture.socketPath)
        #expect(replacementIdentity.inode != staleIdentity.inode
            || replacementIdentity.generation != staleIdentity.generation)

        let client = try connectUnixSocket(fixture.socketPath)
        try writeAll([0x7a], to: client)
        _ = shutdown(client, SHUT_WR)
        close(client)
        #expect(eventually { server.metrics.acceptedFrameCount == 1 })
        #expect(drainUART(fixture.uart) == [0x7a])
    }

    @Test func secondServerRefusesAndPreservesLiveListener() throws {
        let fixture = try SerialConsoleFixture()
        defer { fixture.cleanup() }
        let first = try fixture.makeServer()
        defer { first.stop() }
        let before = try socketIdentity(fixture.socketPath)

        #expect(throws: RawHVSerialConsoleInputError.self) {
            _ = try fixture.makeServer()
        }

        let after = try socketIdentity(fixture.socketPath)
        #expect(after.device == before.device)
        #expect(after.inode == before.inode)
        #expect(after.generation == before.generation)

        let client = try connectUnixSocket(fixture.socketPath)
        try writeAll([0x71], to: client)
        _ = shutdown(client, SHUT_WR)
        close(client)
        #expect(eventually { first.metrics.acceptedFrameCount == 1 })
        #expect(first.metrics.listenerFailureCount == 0)
        #expect(drainUART(fixture.uart) == [0x71])
    }

    @Test func listenerRetirementCannotOvertakeBorrowedShutdownDescriptor() throws {
        let fixture = try SerialConsoleFixture()
        defer { fixture.cleanup() }
        let shutdownEntered = DispatchSemaphore(value: 0)
        let allowShutdown = DispatchSemaphore(value: 0)
        let retireEntered = DispatchSemaphore(value: 0)
        let stopFinished = DispatchSemaphore(value: 0)
        let server = try fixture.makeServer(lifecycleHooks: .init(
            beforeListenerShutdown: {
                shutdownEntered.signal()
                _ = allowShutdown.wait(timeout: .now() + 1)
            },
            beforeListenerRetire: {
                retireEntered.signal()
            }
        ))
        defer {
            allowShutdown.signal()
            server.stop(timeout: 1)
        }

        DispatchQueue.global().async {
            server.stop(timeout: 2)
            stopFinished.signal()
        }
        let entered = shutdownEntered.wait(timeout: .now() + 1)
        #expect(entered == .success)
        guard entered == .success else { return }

        // finishListener must acquire the lock still held by the shutdown borrow. Even after the
        // listener poll interval elapses, it cannot reach retirement or close/reuse the descriptor.
        #expect(retireEntered.wait(timeout: .now() + 0.2) == .timedOut)
        allowShutdown.signal()
        #expect(retireEntered.wait(timeout: .now() + 1) == .success)
        #expect(stopFinished.wait(timeout: .now() + 1) == .success)
        var info = stat()
        #expect(lstat(fixture.socketPath, &info) != 0)
        #expect(errno == ENOENT)
    }

    @Test func peerEffectiveUIDIsVerifiedBeforeAdmission() throws {
        let fixture = try SerialConsoleFixture()
        defer { fixture.cleanup() }
        let differentUID = geteuid() == uid_t.max ? uid_t(0) : geteuid() + 1
        let server = try fixture.makeServer(expectedPeerUID: differentUID)
        defer { server.stop() }

        let client = try connectUnixSocket(fixture.socketPath)
        _ = try? writeAll([0x61], to: client)
        _ = shutdown(client, SHUT_WR)
        close(client)

        #expect(eventually { server.metrics.rejectedPeerCount == 1 })
        #expect(server.metrics.activeClientCount == 0)
        #expect(drainUART(fixture.uart).isEmpty)
    }

    @Test func stopDoesNotUnlinkAReplacementSocketIdentity() throws {
        let fixture = try SerialConsoleFixture()
        defer { fixture.cleanup() }
        let server = try fixture.makeServer()

        #expect(unlink(fixture.socketPath) == 0)
        let replacement = try makeUnixListener(fixture.socketPath)
        defer {
            close(replacement)
            _ = unlink(fixture.socketPath)
        }
        let before = try socketIdentity(fixture.socketPath)

        server.stop(timeout: 1)

        let after = try socketIdentity(fixture.socketPath)
        #expect(after.device == before.device)
        #expect(after.inode == before.inode)
        #expect(after.generation == before.generation)
    }
}

private final class SerialConsoleFixture {
    let root: String
    let socketPath: String
    let uart = PL011(baseAddress: 0x1000, sink: { _ in })

    init() throws {
        root = "/tmp/dory-raw-console-\(UUID().uuidString.prefix(12).lowercased())"
        socketPath = root + "/console.sock"
        try makePrivateDirectory(root)
    }

    func makeServer(
        maximumConcurrentClients: Int = RawHVSerialConsoleInput.productionMaximumConcurrentClients,
        maximumFrameBytes: Int = RawHVSerialConsoleInput.productionMaximumFrameBytes,
        frameTimeout: TimeInterval = RawHVSerialConsoleInput.productionFrameTimeout,
        expectedPeerUID: uid_t = geteuid(),
        lifecycleHooks: RawHVSerialConsoleInput.LifecycleHooks = .init(),
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) throws -> RawHVSerialConsoleInput {
        try RawHVSerialConsoleInput(
            socketPath: socketPath,
            uart: uart,
            maximumConcurrentClients: maximumConcurrentClients,
            maximumFrameBytes: maximumFrameBytes,
            frameTimeout: frameTimeout,
            expectedPeerUID: expectedPeerUID,
            lifecycleHooks: lifecycleHooks,
            log: log
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(atPath: root)
    }
}

private final class LockedDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = [String]()

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func append(_ value: String) {
        lock.lock()
        stored.append(value)
        lock.unlock()
    }
}

private struct TestSocketIdentity {
    var device: dev_t
    var inode: ino_t
    var generation: UInt32
}

private func socketIdentity(_ path: String) throws -> TestSocketIdentity {
    var info = stat()
    guard lstat(path, &info) == 0,
          info.st_mode & S_IFMT == S_IFSOCK else {
        throw POSIXError(.EIO)
    }
    return TestSocketIdentity(
        device: info.st_dev,
        inode: info.st_ino,
        generation: info.st_gen
    )
}

private func makePrivateDirectory(_ path: String) throws {
    try FileManager.default.createDirectory(
        atPath: path,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    guard chmod(path, 0o700) == 0 else { throw POSIXError(.EIO) }
}

private func connectUnixSocket(_ path: String) throws -> Int32 {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw POSIXError(.EIO) }
    do {
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
        var address = unixAddress(path)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return descriptor
    } catch {
        close(descriptor)
        throw error
    }
}

@discardableResult
private func writeAll(_ bytes: [UInt8], to descriptor: Int32) throws -> Int {
    var offset = 0
    while offset < bytes.count {
        let sent = bytes.withUnsafeBytes {
            Darwin.send(
                descriptor,
                $0.baseAddress!.advanced(by: offset),
                bytes.count - offset,
                MSG_NOSIGNAL
            )
        }
        if sent > 0 {
            offset += sent
        } else if sent < 0, errno == EINTR {
            continue
        } else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
    return offset
}

private func makeUnixListener(_ path: String) throws -> Int32 {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw POSIXError(.EIO) }
    do {
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var address = unixAddress(path)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard result == 0,
              chmod(path, 0o600) == 0,
              listen(descriptor, 1) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return descriptor
    } catch {
        close(descriptor)
        throw error
    }
}

private func unixAddress(_ path: String) -> sockaddr_un {
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
    return address
}

private func eventually(
    timeout: TimeInterval = 2,
    _ predicate: () -> Bool
) -> Bool {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while ProcessInfo.processInfo.systemUptime < deadline {
        if predicate() { return true }
        usleep(5_000)
    }
    return predicate()
}

private func drainUART(_ uart: PL011) -> [UInt8] {
    var result = [UInt8]()
    while uart.read(offset: 0x18, width: 4) & 0x10 == 0 {
        result.append(UInt8(truncatingIfNeeded: uart.read(offset: 0, width: 4)))
    }
    return result
}
