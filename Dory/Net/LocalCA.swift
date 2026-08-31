import Darwin
import Foundation

nonisolated enum ShellError: Error, Sendable {
    case launchFailed(String)
    case nonZeroExit(Int32, String)
    case toolNotFound(String)
    case invalidArgument(String)
}

nonisolated enum Shell {
    static func find(
        _ tool: String,
        candidates: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> String? {
        for path in candidates where fileManager.isExecutableFile(atPath: path) { return path }
        for directory in (environment["PATH"] ?? "").split(separator: ":", omittingEmptySubsequences: true) {
            let path = URL(fileURLWithPath: String(directory)).appendingPathComponent(tool).path
            if fileManager.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    private static let queue = DispatchQueue(label: "com.pythonxi.Dory.shell", attributes: .concurrent)

    static func runAsync(_ launchPath: String, _ arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try run(launchPath, arguments)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// Runs a command without throwing on non-zero exit; returns the captured output and exit code.
    static func runAsyncResult(_ launchPath: String, _ arguments: [String]) async -> (output: String, exit: Int32) {
        await withCheckedContinuation { continuation in
            queue.async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: launchPath)
                process.arguments = arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do { try process.run() } catch { continuation.resume(returning: ("\(error)", -1)); return }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: (String(data: data, encoding: .utf8) ?? "", process.terminationStatus))
            }
        }
    }

    @discardableResult
    static func run(
        _ launchPath: String,
        _ arguments: [String],
        cwd: URL? = nil,
        environment: [String: String]? = nil
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = cwd }
        if let environment { process.environment = environment }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do { try process.run() } catch { throw ShellError.launchFailed("\(error)") }
        // Drain the pipe BEFORE waiting: large output exceeding the 64KB pipe buffer would block
        // the child (and deadlock) if we waited for exit first.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        if process.terminationStatus != 0 { throw ShellError.nonZeroExit(process.terminationStatus, text) }
        return text
    }
}

nonisolated struct CertificatePair: Sendable {
    var certificate: URL
    var privateKey: URL
}

/// Generates a local certificate authority and issues per-domain TLS certificates for
/// `*.dory.local` development domains. LocalCATrustManager handles the separate,
/// explicitly consented login-keychain trust step.
nonisolated struct LocalCA: Sendable {
    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".dory/ca")
    }

    var caCertificate: URL { directory.appendingPathComponent("ca.crt") }
    var caKey: URL { directory.appendingPathComponent("ca.key") }

    var opensslPath: String? {
        Shell.find("openssl", candidates: ["/opt/homebrew/bin/openssl", "/usr/bin/openssl", "/usr/local/bin/openssl"])
    }

    var caExists: Bool {
        FileManager.default.fileExists(atPath: caCertificate.path) && FileManager.default.fileExists(atPath: caKey.path)
    }

    func ensureCA() throws {
        guard let openssl = opensslPath else { throw ShellError.toolNotFound("openssl") }
        if caExists { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        // This key signs certificates the user is asked to trust in their login keychain, so it is
        // created 0600 via umask rather than chmod-after: it is never briefly world-readable.
        let previousMask = umask(0o177)
        do {
            try Shell.run(openssl, [
                "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes",
                "-keyout", caKey.path, "-out", caCertificate.path, "-days", "3650",
                "-subj", "/CN=Dory Local CA/O=Dory",
                "-addext", "basicConstraints=critical,CA:TRUE",
                "-addext", "keyUsage=critical,keyCertSign,cRLSign",
            ])
            umask(previousMask)
        } catch {
            umask(previousMask)
            throw error
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: caKey.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: caCertificate.path)
    }

    /// Certificate names reach openssl inside a comma-separated SAN string and a file path, so a
    /// name carrying a comma or a path separator could inject extra SAN entries or redirect the
    /// written key. Domains come from user settings and container labels; validate them all.
    static func validateCertificateName(_ name: String) throws {
        var value = name
        if value.hasPrefix("*.") { value = String(value.dropFirst(2)) }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { throw ShellError.invalidArgument("certificate name: \(name)") }
        for label in labels {
            guard !label.isEmpty,
                  label.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
                throw ShellError.invalidArgument("certificate name: \(name)")
            }
        }
    }

    @discardableResult
    func issue(domain: String, extraSANs: [String] = []) throws -> CertificatePair {
        guard let openssl = opensslPath else { throw ShellError.toolNotFound("openssl") }
        try Self.validateCertificateName(domain)
        for name in extraSANs where !name.isEmpty { try Self.validateCertificateName(name) }
        try ensureCA()
        let certificate = directory.appendingPathComponent("\(domain).crt")
        let key = directory.appendingPathComponent("\(domain).key")
        let csr = directory.appendingPathComponent("\(domain).csr")
        defer { try? FileManager.default.removeItem(at: csr) }

        // TLS wildcards match a single label, so a `*.dory.local` cert does NOT cover multi-level
        // names like `web.default.k8s.dory.local`. Callers pass those explicitly as extra SANs.
        var san = "subjectAltName=DNS:\(domain),DNS:*.\(domain)"
        for name in extraSANs where !name.isEmpty { san += ",DNS:\(name)" }
        try Shell.run(openssl, [
            "req", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes",
            "-keyout", key.path, "-out", csr.path, "-subj", "/CN=\(domain)",
            "-addext", san,
        ])
        try Shell.run(openssl, [
            "x509", "-req", "-in", csr.path, "-CA", caCertificate.path, "-CAkey", caKey.path,
            "-CAcreateserial", "-out", certificate.path, "-days", "825", "-copy_extensions", "copyall",
        ])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: certificate.path)
        return CertificatePair(certificate: certificate, privateKey: key)
    }

    /// Issue (if needed) a cert for `domain` and bundle it with its key into a PKCS#12 identity,
    /// which Network.framework needs to terminate TLS for Dory's automatic local HTTPS.
    @discardableResult
    func issuePKCS12(domain: String, password: String, extraSANs: [String] = []) throws -> URL {
        guard let openssl = opensslPath else { throw ShellError.toolNotFound("openssl") }
        let pair = try issue(domain: domain, extraSANs: extraSANs)
        let p12 = directory.appendingPathComponent("\(domain).p12")
        // Pass the export passphrase through the environment rather than argv, so it is not
        // visible in `ps` output while openssl runs.
        let passphraseVariable = "DORY_LOCALCA_P12_PASS"
        var childEnvironment = ProcessInfo.processInfo.environment
        childEnvironment[passphraseVariable] = password
        try Shell.run(openssl, [
            "pkcs12", "-export", "-inkey", pair.privateKey.path, "-in", pair.certificate.path,
            "-certfile", caCertificate.path, "-out", p12.path,
            "-passout", "env:\(passphraseVariable)", "-legacy",
        ], environment: childEnvironment)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: p12.path)
        return p12
    }

    func verify(certificate: URL) -> Bool {
        guard let openssl = opensslPath else { return false }
        guard let output = try? Shell.run(openssl, ["verify", "-CAfile", caCertificate.path, certificate.path]) else { return false }
        return output.contains(": OK")
    }

    func certificateText(_ certificate: URL) throws -> String {
        guard let openssl = opensslPath else { throw ShellError.toolNotFound("openssl") }
        return try Shell.run(openssl, ["x509", "-in", certificate.path, "-noout", "-text"])
    }

}
