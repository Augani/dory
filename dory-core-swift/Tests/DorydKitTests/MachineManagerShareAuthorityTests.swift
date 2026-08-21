import Darwin
import Foundation
@testable import DorydKit
import XCTest

final class MachineManagerShareAuthorityTests: XCTestCase {
    func testShareRootReplacementBeforeSpawnIsRejected() throws {
        let base = temporaryRoot("replacement")
        let share = base + "/share"
        let displaced = base + "/captured-share"
        try FileManager.default.createDirectory(
            atPath: share,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(atPath: base) }

        let starter = LockedCounter()
        let manager = MachineManager(
            configuration: MachineManagerConfiguration(
                vmmExecutablePath: "/bin/sleep",
                stateDirectory: base + "/state",
                baseArguments: ["30"],
                passMachineArguments: false,
                requiresReadyHandoff: false
            ),
            processStarter: { _ in starter.increment() }
        )
        _ = try manager.create(DoryMachineConfiguration(
            id: "dev",
            kernelPath: doryTestKernelPath,
            rootfsPath: doryTestRootfsPath,
            shares: [DoryMachineShareConfiguration(
                tag: "src",
                hostPath: share,
                guestPath: "/workspace"
            )]
        ))
        manager.installShareAuthorityPreSpawnHookForTesting {
            try FileManager.default.moveItem(atPath: share, toPath: displaced)
            try FileManager.default.createDirectory(atPath: share, withIntermediateDirectories: false)
        }

        XCTAssertThrowsError(try manager.start(id: "dev")) { error in
            XCTAssertEqual(error as? MachineManagerError, .invalidShare(share))
        }
        XCTAssertEqual(starter.value, 0)
        XCTAssertNil(manager.status(id: "dev")?.pid)
    }

    func testHelperReceivesCapturedCanonicalShareRoot() throws {
        let base = temporaryRoot("canonical")
        let realShare = base + "/real-share"
        let aliasShare = base + "/share-alias"
        let argumentsPath = base + "/arguments"
        let helperPath = base + "/helper.sh"
        try FileManager.default.createDirectory(
            atPath: realShare,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: aliasShare,
            withDestinationPath: realShare
        )
        try """
        #!/bin/sh
        printf '%s\n' "$@" > "\(argumentsPath).tmp"
        mv "\(argumentsPath).tmp" "\(argumentsPath)"
        sleep 30
        """.write(toFile: helperPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: helperPath
        )
        defer { try? FileManager.default.removeItem(atPath: base) }

        let manager = MachineManager(configuration: MachineManagerConfiguration(
            vmmExecutablePath: helperPath,
            stateDirectory: base + "/state",
            requiresReadyHandoff: false
        ))
        defer { try? manager.delete(id: "dev") }
        _ = try manager.create(DoryMachineConfiguration(
            id: "dev",
            kernelPath: doryTestKernelPath,
            rootfsPath: doryTestRootfsPath,
            shares: [DoryMachineShareConfiguration(
                tag: "src",
                hostPath: aliasShare,
                guestPath: "/workspace",
                readOnly: true
            )]
        ))

        _ = try manager.start(id: "dev")
        let rows = try waitForLines(at: argumentsPath)
        let shareFlag = try XCTUnwrap(rows.firstIndex(of: "--share"))
        let decoded = try DoryMachineShareConfiguration(argument: rows[shareFlag + 1])
        XCTAssertEqual(
            decoded.hostPath,
            try canonicalPath(realShare)
        )
        XCTAssertEqual(decoded.guestPath, "/workspace")
        XCTAssertTrue(decoded.readOnly)
    }

    func testFilesystemRootCannotBeShared() {
        let state = temporaryRoot("root")
        defer { try? FileManager.default.removeItem(atPath: state) }
        let manager = MachineManager(configuration: MachineManagerConfiguration(
            vmmExecutablePath: "/bin/sleep",
            stateDirectory: state
        ))
        XCTAssertThrowsError(try manager.create(DoryMachineConfiguration(
            id: "dev",
            kernelPath: doryTestKernelPath,
            rootfsPath: doryTestRootfsPath,
            shares: [DoryMachineShareConfiguration(
                tag: "root",
                hostPath: "/",
                guestPath: "/host"
            )]
        ))) { error in
            XCTAssertEqual(error as? MachineManagerError, .invalidShare("/"))
        }
    }

    private func temporaryRoot(_ suffix: String) -> String {
        "/tmp/dory-share-authority-\(suffix)-\(getpid())-\(UUID().uuidString)"
    }

    private func canonicalPath(_ path: String) throws -> String {
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &resolved) != nil else {
            throw POSIXError(.ENOENT)
        }
        let bytes = resolved.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func waitForLines(at path: String) throws -> [String] {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let text = try? String(contentsOfFile: path, encoding: .utf8),
               !text.isEmpty {
                return text.split(separator: "\n").map(String.init)
            }
            usleep(10_000)
        }
        throw NSError(
            domain: "MachineManagerShareAuthorityTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "helper arguments were not recorded"]
        )
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}
