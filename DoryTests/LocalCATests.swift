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

    @Test func caAndLeafPrivateKeysAreOwnerReadableOnly() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dory-ca-perms-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let ca = LocalCA(directory: directory)
        guard ca.opensslPath != nil else { return }

        try ca.ensureCA()
        let pair = try ca.issue(domain: "web.dory.local")
        let p12 = try ca.issuePKCS12(domain: "dory.local", password: AppStore.ephemeralIdentityPassword())

        for path in [ca.caKey.path, pair.privateKey.path, p12.path] {
            let mode = try #require(
                FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
            ).intValue
            #expect(mode & 0o077 == 0)
        }
    }

    @Test func certificateNamesThatCouldInjectSANEntriesOrPathsAreRejected() throws {
        for name in ["dory.local,DNS:evil.example.com", "../../etc/dory", "dory.local/../evil", "", "*.", "a..b"] {
            #expect(throws: (any Error).self) { try LocalCA.validateCertificateName(name) }
        }
        for name in ["dory.local", "*.dory.local", "*.default.k8s.dory.local", "my-project.local"] {
            try LocalCA.validateCertificateName(name)
        }
    }

    @Test func ephemeralIdentityPasswordIsRandomAndNotAConstant() {
        let first = AppStore.ephemeralIdentityPassword()
        let second = AppStore.ephemeralIdentityPassword()
        #expect(first.count == 48)
        #expect(first != second)
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
