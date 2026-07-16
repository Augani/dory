@testable import DorydKit
import XCTest

final class LocalCATests: XCTestCase {
    func testShellTimesOutAndTerminatesHungProcess() throws {
        let started = Date()
        XCTAssertThrowsError(try DoryShell.run("/bin/sleep", ["30"], timeout: 0.05)) { error in
            guard case let DoryShellError.timedOut(timeout, output) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(timeout, 0.05)
            XCTAssertTrue(output.isEmpty)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testGeneratesCAAndIssuesVerifiableDomainCertificate() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("doryd-ca-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let ca = DoryLocalCA(directory: directory)
        guard ca.opensslPath != nil else { throw XCTSkip("openssl unavailable") }

        try ca.ensureCA()
        XCTAssertTrue(ca.caExists)
        XCTAssertEqual(try permissions(at: directory), 0o700)
        XCTAssertEqual(try permissions(at: ca.caKey), 0o600)

        let pair = try ca.issue(domain: "web.dory.local", extraSANs: ["api.dory.local"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: pair.certificate.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pair.privateKey.path))
        XCTAssertEqual(try permissions(at: pair.privateKey), 0o600)
        XCTAssertTrue(ca.verify(certificate: pair.certificate))

        let text = try ca.certificateText(pair.certificate)
        XCTAssertTrue(text.contains("web.dory.local"))
        XCTAssertTrue(text.contains("api.dory.local"))
        XCTAssertTrue(text.contains("Dory Local CA"))
    }

    func testPKCS12IsCreatedWithPrivatePermissions() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("doryd-ca-p12-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let ca = DoryLocalCA(directory: directory)
        guard ca.opensslPath != nil else { throw XCTSkip("openssl unavailable") }

        let p12 = try ca.issuePKCS12(domain: "dory.local", password: "test-password")
        XCTAssertTrue(FileManager.default.fileExists(atPath: p12.path))
        XCTAssertEqual(try permissions(at: p12), 0o600)
    }
}

private func permissions(at url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
}
