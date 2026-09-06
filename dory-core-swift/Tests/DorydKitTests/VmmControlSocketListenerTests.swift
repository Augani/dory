import Darwin
import Foundation
import Testing
@testable import DorydKit

@Suite struct VmmControlSocketListenerTests {
    @Test func ownedSocketHasPrivatePermissionsAndIdempotentStop() throws {
        try withPath { path in
            let listener = try VmmControlSocketListener(path: path)
            defer { listener.stop() }
            let info = try attributes(path)
            #expect(info.st_mode & S_IFMT == S_IFSOCK)
            #expect(info.st_mode & 0o777 == 0o600)
            #expect(fcntl(listener.descriptor, F_GETFD) & FD_CLOEXEC != 0)
            listener.stop()
            listener.stop()
            #expect(!FileManager.default.fileExists(atPath: path))
        }
    }

    @Test(arguments: [false, true])
    func existingFileOrSymlinkIsPreserved(symlink: Bool) throws {
        try withPath { path in
            let target = symlink ? path + ".target" : path
            try Data("retain me".utf8).write(to: URL(fileURLWithPath: target))
            if symlink { try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target) }
            #expect(throws: (any Error).self) { _ = try VmmControlSocketListener(path: path) }
            #expect(try Data(contentsOf: URL(fileURLWithPath: target)) == Data("retain me".utf8))
            #expect(try attributes(path).st_mode & S_IFMT == (symlink ? S_IFLNK : S_IFREG))
        }
    }

    @Test func activeListenerIsNotReplaced() throws {
        try withPath { path in
            let first = try VmmControlSocketListener(path: path)
            defer { first.stop() }
            let before = try attributes(path)
            #expect(throws: (any Error).self) { _ = try VmmControlSocketListener(path: path) }
            let after = try attributes(path)
            #expect(after.st_ino == before.st_ino && after.st_dev == before.st_dev)
        }
    }

    @Test func oldOwnerCannotUnlinkReplacementSocket() throws {
        try withPath { path in
            let first = try VmmControlSocketListener(path: path)
            defer { first.stop() }
            try FileManager.default.moveItem(atPath: path, toPath: path + ".old")
            let replacement = try VmmControlSocketListener(path: path)
            defer { replacement.stop() }
            let expected = try attributes(path)
            first.stop()
            #expect(try attributes(path).st_ino == expected.st_ino)
        }
    }

    @Test func abandonedSocketCanBeRebound() throws {
        try withPath { path in
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw VmmControlError.syscall("socket", errno) }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            close(fd) // Simulate a dead owner leaving its socket path behind.
            #expect(result == 0)
            let replacement = try VmmControlSocketListener(path: path)
            replacement.stop()
            #expect(!FileManager.default.fileExists(atPath: path))
        }
    }

    @Test func stoppedOwnerCannotAcceptReplacementTraffic() throws {
        try withPath { path in
            let old = try VmmControlSocketListener(path: path)
            old.stop()
            let replacement = try VmmControlSocketListener(path: path)
            defer { replacement.stop() }
            let client = socket(AF_UNIX, SOCK_STREAM, 0)
            guard client >= 0 else { throw VmmControlError.syscall("socket", errno) }
            defer { close(client) }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(client, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            #expect(result == 0)
            guard case .stopped = try old.acceptClient() else {
                Issue.record("stopped owner accepted replacement traffic")
                return
            }
            guard case .client(let accepted) = try replacement.acceptClient() else {
                Issue.record("replacement lost its pending connection")
                return
            }
            close(accepted)
        }
    }

    private func attributes(_ path: String) throws -> stat {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw VmmControlError.syscall("lstat", errno) }
        return info
    }

    private func withPath(_ body: (String) throws -> Void) throws {
        let directory = "/private/tmp/dory-ctl-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try body(directory + "/control.sock")
    }
}
