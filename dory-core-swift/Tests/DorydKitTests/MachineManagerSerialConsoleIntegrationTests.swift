import CryptoKit
import Darwin
import Foundation
@testable import DorydKit
import XCTest

final class MachineManagerSerialConsoleIntegrationTests: XCTestCase {
    func testSerialConsolePersistsAcrossStopAndUsesExactCursor() throws {
        let fixture = try ManagerFixture()
        defer { fixture.cleanup() }
        try fixture.writeSerialLog("firmware\nlinux\n")

        let initial = try fixture.manager.serialConsole(
            id: fixture.machineID,
            limit: 6
        )
        XCTAssertTrue(initial.snapshotRequired)
        XCTAssertEqual(initial.bytes, Data("linux\n".utf8))
        XCTAssertFalse(initial.inputAvailable)

        try fixture.appendSerialLog("ready\n")
        let incremental = try fixture.manager.serialConsole(
            id: fixture.machineID,
            cursor: initial.cursor,
            limit: 64
        )
        XCTAssertFalse(incremental.snapshotRequired)
        XCTAssertEqual(incremental.bytes, Data("ready\n".utf8))
        XCTAssertEqual(incremental.nextOffset, incremental.totalBytes)

        _ = try fixture.manager.start(id: fixture.machineID)
        _ = try fixture.manager.stop(id: fixture.machineID)
        let stopped = try fixture.manager.serialConsole(
            id: fixture.machineID,
            cursor: incremental.cursor,
            limit: 64
        )
        XCTAssertFalse(stopped.inputAvailable)
        XCTAssertEqual(stopped.generation, incremental.generation)
    }

    func testSerialInputRequiresActiveMachineAndPrivateHelperSocket() throws {
        let fixture = try ManagerFixture()
        defer { fixture.cleanup() }
        XCTAssertThrowsError(
            try fixture.manager.writeSerialConsole(
                id: fixture.machineID,
                data: Data("x".utf8)
            )
        )

        _ = try fixture.manager.start(id: fixture.machineID)
        let listener = try fixture.makeConsoleListener()
        defer {
            _ = close(listener)
            _ = unlink(fixture.consoleSocketPath)
        }
        let status = try fixture.manager.serialConsole(id: fixture.machineID, limit: 64)
        XCTAssertTrue(status.inputAvailable)

        let payload = Data("recovery\n".utf8)
        try fixture.manager.writeSerialConsole(id: fixture.machineID, data: payload)
        let accepted = accept(listener, nil, nil)
        XCTAssertGreaterThanOrEqual(accepted, 0)
        guard accepted >= 0 else { return }
        defer { _ = close(accepted) }
        var buffer = [UInt8](repeating: 0, count: 64)
        let count = Darwin.read(accepted, &buffer, buffer.count)
        XCTAssertEqual(count, payload.count)
        XCTAssertEqual(Data(buffer.prefix(max(0, count))), payload)
    }

    private final class ManagerFixture {
        let machineID = "dev"
        let stateRoot: String
        let runtimeRoot: String
        let manager: MachineManager

        var machineDirectory: String { stateRoot + "/" + machineID }
        var serialLogPath: String { machineDirectory + "/serial.log" }
        var consoleSocketPath: String {
            let material = Data("\(stateRoot)\0\(machineID)".utf8)
            let token = SHA256.hash(data: material).prefix(12).map {
                String(format: "%02x", $0)
            }.joined()
            return runtimeRoot + "/" + token + "/console.sock"
        }

        init() throws {
            let suffix = "\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
            stateRoot = "/tmp/dory-console-manager-\(suffix)"
            runtimeRoot = "/tmp/dory-console-runtime-\(suffix)"
            manager = MachineManager(configuration: MachineManagerConfiguration(
                vmmExecutablePath: "/bin/sleep",
                stateDirectory: stateRoot,
                runtimeDirectory: runtimeRoot,
                baseArguments: ["30"],
                passMachineArguments: false,
                requiresReadyHandoff: false
            ))
            _ = try manager.create(DoryMachineConfiguration(
                id: machineID,
                kernelPath: doryTestKernelPath,
                rootfsPath: doryTestRootfsPath,
                displayMode: .headless
            ))
        }

        func cleanup() {
            if manager.status(id: machineID)?.state == .running {
                _ = try? manager.stop(id: machineID)
            }
            try? manager.delete(id: machineID)
            try? FileManager.default.removeItem(atPath: stateRoot)
            try? FileManager.default.removeItem(atPath: runtimeRoot)
        }

        func writeSerialLog(_ value: String) throws {
            FileManager.default.createFile(
                atPath: serialLogPath,
                contents: Data(value.utf8),
                attributes: [.posixPermissions: 0o600]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: serialLogPath
            )
        }

        func appendSerialLog(_ value: String) throws {
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: serialLogPath))
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(value.utf8))
            try handle.synchronize()
        }

        func makeConsoleListener() throws -> Int32 {
            let directory = (consoleSocketPath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory
            )
            let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw POSIXError(.EIO) }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(consoleSocketPath.utf8CString)
            guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
                _ = close(descriptor)
                throw POSIXError(.ENAMETOOLONG)
            }
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
