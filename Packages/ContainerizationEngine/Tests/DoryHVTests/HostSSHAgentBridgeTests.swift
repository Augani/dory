import Darwin
import Foundation
import Testing
@testable import DoryHV

struct HostSSHAgentBridgeTests {
    @Test func configurationRequiresAbsoluteBoundedUnixPath() throws {
        #expect(throws: HostSSHAgentBridge.ConfigurationError.relativePath("agent.sock")) {
            try HostSSHAgentBridge.validate(socketPath: "agent.sock")
        }
        #expect(throws: HostSSHAgentBridge.ConfigurationError.embeddedNull("/tmp/a\0b")) {
            try HostSSHAgentBridge.validate(socketPath: "/tmp/a\0b")
        }
        let long = "/" + String(repeating: "x", count: VsockUnixRelay.maximumSocketPathByteCount)
        #expect(throws: HostSSHAgentBridge.ConfigurationError.pathTooLong(
            path: long,
            utf8ByteCount: long.utf8.count,
            maximumUTF8ByteCount: VsockUnixRelay.maximumSocketPathByteCount
        )) {
            try HostSSHAgentBridge.validate(socketPath: long)
        }
    }

    @Test func connectsOnlyToSameUserUnixSocketWithoutFollowingSymlinks() throws {
        let root = URL(fileURLWithPath: "/tmp/dory-sa-\(getpid())-\(UInt32.random(in: 0...UInt32.max))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let socketPath = root.appendingPathComponent("agent.sock").path
        let listener = try VsockUnixRelay.makeOwnedListener(
            socketPath: socketPath,
            mode: 0o600
        )
        defer {
            VsockUnixRelay.retireOwnedListener(listener, socketPath: socketPath)
        }

        let client = try #require(HostSSHAgentBridge.connectSameUserSocket(
            path: socketPath,
            expectedUID: getuid()
        ))
        defer { close(client) }
        #expect(fcntl(client, F_GETFL, 0) & O_NONBLOCK == 0)
        #expect(fcntl(client, F_GETFD, 0) & FD_CLOEXEC != 0)
        var noSigpipe: Int32 = 0
        var noSigpipeLength = socklen_t(MemoryLayout<Int32>.size)
        #expect(getsockopt(
            client,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigpipe,
            &noSigpipeLength
        ) == 0)
        #expect(noSigpipe == 1)
        #expect(HostSSHAgentBridge.peerUIDMatches(
            descriptor: client,
            expectedUID: geteuid()
        ))
        #expect(!HostSSHAgentBridge.peerUIDMatches(
            descriptor: client,
            expectedUID: geteuid() &+ 1
        ))
        let accepted = accept(listener.descriptor, nil, nil)
        #expect(accepted >= 0)
        defer { if accepted >= 0 { close(accepted) } }
        #expect(write(client, "x", 1) == 1)
        var byte: UInt8 = 0
        #expect(read(accepted, &byte, 1) == 1)
        #expect(byte == 120)

        #expect(HostSSHAgentBridge.connectSameUserSocket(
            path: socketPath,
            expectedUID: getuid() &+ 1
        ) == nil)
        let symlinkPath = root.appendingPathComponent("symlink.sock").path
        try FileManager.default.createSymbolicLink(atPath: symlinkPath, withDestinationPath: socketPath)
        #expect(HostSSHAgentBridge.connectSameUserSocket(
            path: symlinkPath,
            expectedUID: getuid()
        ) == nil)
    }
}
