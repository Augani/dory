import Darwin
@testable import DorydKit
import XCTest

final class IncidentWriterTests: XCTestCase {
    func testRecordsIncidentJsonLinesAt0600NewestFirst() throws {
        let base = "/tmp/dory-incidents-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let path = base + "/incidents.jsonl"
        let writer = IncidentWriter(path: path)

        writer.record(type: "start", detail: "boot", at: Date(timeIntervalSince1970: 1))
        writer.record(type: "wake", detail: "docker request", at: Date(timeIntervalSince1970: 2))

        let incidents = writer.read(limit: 10)
        XCTAssertEqual(incidents.map(\.type), ["wake", "start"])
        XCTAssertEqual(incidents.first?.detail, "docker request")

        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let permissions = (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        XCTAssertEqual(permissions & 0o777, 0o600)
    }

    func testConcurrentRecordsRemainWholeJsonLines() throws {
        let base = "/tmp/dory-incidents-concurrent-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }
        let path = base + "/incidents.jsonl"
        let writer = IncidentWriter(path: path)
        let group = DispatchGroup()

        for index in 0..<40 {
            group.enter()
            DispatchQueue.global().async {
                writer.record(type: "test", detail: "line-\(index)")
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)

        let content = try String(contentsOfFile: path, encoding: .utf8)
        let lines = content.split(separator: "\n")
        XCTAssertEqual(lines.count, 40)
        for line in lines {
            let data = try XCTUnwrap(String(line).data(using: .utf8))
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertEqual(object?["type"] as? String, "test")
        }
    }
}
