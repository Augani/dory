import Foundation
import XCTest
@testable import DorydKit
import DoryOperations

final class DoryMachineDisplayPresentationStoreTests: XCTestCase {
    func testRoundTripIsCanonicalAndAbsentDefaultsWindowed() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DoryMachineDisplayPresentationStore(root: root.path)
        XCTAssertEqual(try store.read(machineID: "machine"), .windowed)
        let presentation = DoryMachineDisplayPresentation(assignments: [
            .init(
                guestDisplayID: "display-0",
                mode: .dedicatedFullscreen,
                hostDisplayUUID: "00000000-0000-0000-0000-000000000001"
            ),
        ])
        try store.publish(presentation, machineID: "machine")
        XCTAssertEqual(try store.read(machineID: "machine"), presentation)
        try store.remove(machineID: "machine")
        XCTAssertEqual(try store.read(machineID: "machine"), .windowed)
    }

    func testMalformedRecordFailsClosed() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let records = root.appendingPathComponent(".display-presentation-v1", isDirectory: true)
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: records.appendingPathComponent("machine.json"))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: records.appendingPathComponent("machine.json").path
        )
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(
            try DoryMachineDisplayPresentationStore(root: root.path).read(machineID: "machine")
        )
    }

    func testXPCShapeRejectsUnknownKeysAndInvalidUUID() throws {
        let valid: NSDictionary = [
            "schemaVersion": 1,
            "assignments": [[
                "guestDisplayID": "display-0",
                "mode": "dedicated-fullscreen",
                "hostDisplayUUID": "00000000-0000-0000-0000-000000000001",
            ] as NSDictionary] as NSArray,
        ]
        XCTAssertEqual(
            try DoryMachineDisplayPresentation(xpcDictionary: valid).xpcDictionary,
            valid
        )
        let unknown = valid.mutableCopy() as! NSMutableDictionary
        unknown["path"] = "/tmp/secret"
        XCTAssertThrowsError(try DoryMachineDisplayPresentation(xpcDictionary: unknown))
    }
}
