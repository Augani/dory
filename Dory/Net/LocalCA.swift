import Foundation

nonisolated enum ShellError: Error, Sendable {
    case launchFailed(String)
    case nonZeroExit(Int32, String)
    case toolNotFound(String)
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
    static func run(_ launchPath: String, _ arguments: [String], cwd: URL? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = cwd }
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
/// `*.dory.local` development domains. Installing the CA into the system trust store is a
/// privileged, security-sensitive action and is performed ONLY via `installInSystemTrust`,
/// which must be invoked from an explicit, consented user action — never automatically.
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
        try Shell.run(openssl, [
            "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes",
            "-keyout", caKey.path, "-out", caCertificate.path, "-days", "3650",
            "-subj", "/CN=Dory Local CA/O=Dory",
            "-addext", "basicConstraints=critical,CA:TRUE",
            "-addext", "keyUsage=critical,keyCertSign,cRLSign",
        ])
    }

    @discardableResult
    func issue(domain: String, extraSANs: [String] = []) throws -> CertificatePair {
        guard let openssl = opensslPath else { throw ShellError.toolNotFound("openssl") }
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
        return CertificatePair(certificate: certificate, privateKey: key)
    }

    /// Issue (if needed) a cert for `domain` and bundle it with its key into a PKCS#12 identity,
    /// which Network.framework needs to terminate TLS for Dory's automatic local HTTPS.
    @discardableResult
    func issuePKCS12(domain: String, password: String, extraSANs: [String] = []) throws -> URL {
        guard let openssl = opensslPath else { throw ShellError.toolNotFound("openssl") }
        let pair = try issue(domain: domain, extraSANs: extraSANs)
        let p12 = directory.appendingPathComponent("\(domain).p12")
        try Shell.run(openssl, [
            "pkcs12", "-export", "-inkey", pair.privateKey.path, "-in", pair.certificate.path,
            "-certfile", caCertificate.path, "-out", p12.path,
            "-passout", "pass:\(password)", "-legacy",
        ])
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

    // MARK: Gated system-trust install (requires explicit user consent + admin privileges)

    /// The command a consented install would run. Surfaced to the user; NOT executed automatically.
    func systemTrustInstallCommand() -> [String] {
        ["security", "add-trusted-cert", "-d", "-r", "trustRoot",
         "-k", "/Library/Keychains/System.keychain", caCertificate.path]
    }
}
