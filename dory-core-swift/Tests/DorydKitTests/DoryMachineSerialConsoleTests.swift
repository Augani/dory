import Darwin
import Foundation
import Testing
@testable import DorydKit

@Suite("Machine serial console authority")
struct DoryMachineSerialConsoleTests {
    @Test("bounded cursor reads survive append and force snapshots after truncation")
    func cursorReads() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeLog(Data("boot-one\nboot-two\n".utf8))

        let initial = try fixture.read(limit: 9)
        #expect(initial.snapshotRequired)
        #expect(initial.bytes == Data("boot-two\n".utf8))
        #expect(initial.startOffset == 9)
        #expect(initial.nextOffset == 18)
        #expect(initial.totalBytes == 18)
        #expect(initial.isValid)

        try fixture.appendLog(Data("ready\n".utf8))
        let appended = try fixture.read(cursor: initial.cursor, limit: 64)
        #expect(!appended.snapshotRequired)
        #expect(appended.bytes == Data("ready\n".utf8))
        #expect(appended.startOffset == initial.nextOffset)
        #expect(appended.nextOffset == appended.totalBytes)

        try fixture.writeLog(Data("reset\n".utf8))
        let reset = try fixture.read(cursor: appended.cursor, limit: 64)
        #expect(reset.snapshotRequired)
        #expect(reset.bytes == Data("reset\n".utf8))
        #expect(reset.startOffset == 0)
        #expect(reset.nextOffset == 6)
    }

    @Test("missing log is an empty authority and replacement changes generation")
    func missingAndReplacement() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        let missing = try fixture.read(limit: 64)
        #expect(missing.generation == nil)
        #expect(missing.bytes.isEmpty)
        #expect(!missing.snapshotRequired)

        try fixture.writeLog(Data("first".utf8))
        let first = try fixture.read(limit: 64)
        #expect(first.snapshotRequired)
        try FileManager.default.removeItem(atPath: fixture.logPath)
        try fixture.writeLog(Data("second".utf8))
        let second = try fixture.read(cursor: first.cursor, limit: 64)
        #expect(second.snapshotRequired)
        #expect(second.generation != first.generation)
        #expect(second.bytes == Data("second".utf8))
    }

    @Test("symlink hard-link and public log substitutions fail closed")
    func rejectsUnsafeLogAuthority() throws {
        for mode in UnsafeLogMode.allCases {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            let outside = fixture.root + "/outside"
            FileManager.default.createFile(atPath: outside, contents: Data("secret".utf8))
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: outside
            )
            switch mode {
            case .symlink:
                try FileManager.default.createSymbolicLink(
                    atPath: fixture.logPath,
                    withDestinationPath: outside
                )
            case .hardLink:
                try FileManager.default.linkItem(atPath: outside, toPath: fixture.logPath)
            case .publicFile:
                try fixture.writeLog(Data("public".utf8))
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o644],
                    ofItemAtPath: fixture.logPath
                )
            }
            #expect(throws: DoryMachineSerialConsoleError.self) {
                _ = try fixture.read(limit: 64)
            }
        }
    }

    @Test("input is bounded and reaches only the private console socket")
    func privateConsoleInput() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let listener = try fixture.makeConsoleListener()
        defer {
            _ = close(listener)
            _ = unlink(fixture.consoleSocketPath)
        }

        let before = try fixture.read(limit: 64)
        #expect(before.inputAvailable)
        let payload = Data("recovery\n".utf8)
        try DoryMachineSerialConsoleAuthority.write(
            payload,
            consoleSocketPath: fixture.consoleSocketPath
        )
        let accepted = accept(listener, nil, nil)
        #expect(accepted >= 0)
        guard accepted >= 0 else { return }
        defer { _ = close(accepted) }
        var bytes = [UInt8](repeating: 0, count: 64)
        let count = Darwin.read(accepted, &bytes, bytes.count)
        #expect(count == payload.count)
        #expect(Data(bytes.prefix(max(0, count))) == payload)

        #expect(throws: DoryMachineSerialConsoleError.self) {
            try DoryMachineSerialConsoleAuthority.write(
                Data(repeating: 1, count: DoryMachineSerialConsoleAuthority.maximumWriteBytes + 1),
                consoleSocketPath: fixture.consoleSocketPath
            )
        }
    }

    @Test("invalid cursors limits and absent input fail closed")
    func rejectsInvalidRequests() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.writeLog(Data("boot".utf8))
        #expect(throws: DoryMachineSerialConsoleError.self) {
            _ = try fixture.read(
                cursor: DoryMachineSerialConsoleCursor(generation: "not-a-digest", offset: 1),
                limit: 64
            )
        }
        #expect(throws: DoryMachineSerialConsoleError.self) {
            _ = try fixture.read(limit: DoryMachineSerialConsoleAuthority.maximumReadBytes + 1)
        }
        #expect(throws: DoryMachineSerialConsoleError.self) {
            try DoryMachineSerialConsoleAuthority.write(
                Data("x".utf8),
                consoleSocketPath: fixture.consoleSocketPath
            )
        }
    }

    private enum UnsafeLogMode: CaseIterable {
        case symlink
        case hardLink
        case publicFile
    }

    private final class Fixture {
        let root: String
        let machineID = "console-machine"
        let machineDirectory: String
        let runtimeDirectory: String
        let logPath: String
        let consoleSocketPath: String

        init() throws {
            // Keep the Unix-socket path below Darwin's sockaddr_un limit.
            root = "/tmp/dory-console-\(UUID().uuidString.prefix(12).lowercased())"
            machineDirectory = root + "/machine"
            runtimeDirectory = root + "/runtime"
            logPath = machineDirectory + "/serial.log"
            consoleSocketPath = runtimeDirectory + "/console.sock"
            try FileManager.default.createDirectory(
                atPath: machineDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.createDirectory(
                atPath: runtimeDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: root
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: machineDirectory
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: runtimeDirectory
            )
        }

        func cleanup() {
            try? FileManager.default.removeItem(atPath: root)
        }

        func writeLog(_ data: Data) throws {
            guard FileManager.default.createFile(atPath: logPath, contents: data) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: logPath
            )
        }

        func appendLog(_ data: Data) throws {
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: logPath))
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
        }

        func read(
            cursor: DoryMachineSerialConsoleCursor = .init(),
            limit: Int
        ) throws -> DoryMachineSerialConsoleBatch {
            try DoryMachineSerialConsoleAuthority.read(
                machineID: machineID,
                machineDirectory: machineDirectory,
                consoleSocketPath: consoleSocketPath,
                cursor: cursor,
                limit: limit
            )
        }

        func makeConsoleListener() throws -> Int32 {
            let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw POSIXError(.EIO) }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(consoleSocketPath.utf8CString)
            withUnsafeMutableBytes(of: &address.sun_path) { destination in
                bytes.withUnsafeBytes { source in destination.copyBytes(from: source) }
            }
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                    Darwin.bind(descriptor, raw, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0, chmod(consoleSocketPath, 0o600) == 0,
                  listen(descriptor, 1) == 0 else {
                _ = close(descriptor)
                throw POSIXError(.EIO)
            }
            return descriptor
        }
    }
}
