import Testing
import Foundation
@testable import Dory

struct LocalCATests {
    @Test func generatesCAAndIssuesVerifiableDomainCertificate() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dory-ca-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let ca = LocalCA(directory: directory)
        guard ca.opensslPath != nil else { return } // openssl unavailable; skip

        try ca.ensureCA()
        #expect(ca.caExists)
        #expect(FileManager.default.fileExists(atPath: ca.caCertificate.path))

        let pair = try ca.issue(domain: "web.dory.local")
        #expect(FileManager.default.fileExists(atPath: pair.certificate.path))
        #expect(FileManager.default.fileExists(atPath: pair.privateKey.path))

        // The leaf certificate must chain to our CA.
        #expect(ca.verify(certificate: pair.certificate))

        // The SAN must include the requested domain.
        let text = try ca.certificateText(pair.certificate)
        #expect(text.contains("web.dory.local"))
        #expect(text.contains("Dory Local CA"))
    }

    @Test func installCommandIsGatedAndWellFormed() {
        let ca = LocalCA(directory: URL(fileURLWithPath: "/tmp/dory-ca-test"))
        let command = ca.systemTrustInstallCommand()
        #expect(command.first == "security")
        #expect(command.contains("add-trusted-cert"))
        #expect(command.contains("/Library/Keychains/System.keychain"))
    }
}
