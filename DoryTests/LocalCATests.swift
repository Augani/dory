import Testing
import Foundation
import Security
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

    @Test func localTrustParserAcceptsOnlyAValidDoryCA() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dory-trust-parser-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let ca = LocalCA(directory: directory)
        guard ca.opensslPath != nil else { return }
        try ca.ensureCA()

        let raw = try Data(contentsOf: ca.caCertificate)
        let parsed = try LocalCATrustManager.validatedCertificate(from: raw)
        #expect(!parsed.der.isEmpty)
        #expect(SecCertificateCopySubjectSummary(parsed.certificate) as String? == "Dory Local CA")

        #expect(throws: LocalCATrustError.invalidCertificate) {
            try LocalCATrustManager.validatedCertificate(from: Data("not a certificate".utf8))
        }
    }

    @Test func localTrustManagerRefusesCertificateSymlinksBeforeKeychainAccess() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dory-trust-symlink-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("target.crt")
        let link = directory.appendingPathComponent("ca.crt")
        try Data("not a certificate".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(throws: LocalCATrustError.unreadableCertificate(link.path)) {
            try LocalCATrustManager().install(certificateAt: link.path)
        }
    }

}
