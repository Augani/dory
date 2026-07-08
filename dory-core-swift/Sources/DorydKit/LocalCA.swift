import Foundation

public enum DoryShellError: Error, Sendable, Equatable, CustomStringConvertible {
    case launchFailed(String)
    case nonZeroExit(Int32, String)
    case toolNotFound(String)

    public var description: String {
        switch self {
        case let .launchFailed(message):
            return "launch failed: \(message)"
        case let .nonZeroExit(code, output):
            return "process exited \(code): \(output)"
        case let .toolNotFound(tool):
            return "tool not found: \(tool)"
        }
    }
}

public struct DoryCertificatePair: Sendable, Equatable {
    public var certificate: URL
    public var privateKey: URL

    public init(certificate: URL, privateKey: URL) {
        self.certificate = certificate
        self.privateKey = privateKey
    }
}

public struct DoryLocalCA {
    public var directory: URL
    public var fileManager: FileManager
    public var environment: [String: String]

    public init(
        directory: URL,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.directory = directory
        self.fileManager = fileManager
        self.environment = environment
    }

    public var caCertificate: URL {
        directory.appendingPathComponent("ca.crt")
    }

    public var caKey: URL {
        directory.appendingPathComponent("ca.key")
    }

    public var opensslPath: String? {
        DoryShell.find(
            "openssl",
            candidates: ["/opt/homebrew/bin/openssl", "/usr/bin/openssl", "/usr/local/bin/openssl"],
            environment: environment,
            fileManager: fileManager
        )
    }

    public var caExists: Bool {
        fileManager.fileExists(atPath: caCertificate.path) && fileManager.fileExists(atPath: caKey.path)
    }

    public func ensureCA() throws {
        guard let openssl = opensslPath else { throw DoryShellError.toolNotFound("openssl") }
        if caExists { return }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try DoryShell.run(openssl, [
            "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes",
            "-keyout", caKey.path, "-out", caCertificate.path, "-days", "3650",
            "-subj", "/CN=Dory Local CA/O=Dory",
            "-addext", "basicConstraints=critical,CA:TRUE",
            "-addext", "keyUsage=critical,keyCertSign,cRLSign",
        ])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: caKey.path)
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: caCertificate.path)
    }

    @discardableResult
    public func issue(domain: String, extraSANs: [String] = []) throws -> DoryCertificatePair {
        guard let openssl = opensslPath else { throw DoryShellError.toolNotFound("openssl") }
        try ensureCA()
        let safeName = domain.replacingOccurrences(of: "/", with: "_")
        let certificate = directory.appendingPathComponent("\(safeName).crt")
        let key = directory.appendingPathComponent("\(safeName).key")
        let csr = directory.appendingPathComponent("\(safeName).csr")
        defer { try? fileManager.removeItem(at: csr) }

        var san = "subjectAltName=DNS:\(domain),DNS:*.\(domain)"
        for name in extraSANs where !name.isEmpty {
            san += ",DNS:\(name)"
        }
        try DoryShell.run(openssl, [
            "req", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes",
            "-keyout", key.path, "-out", csr.path, "-subj", "/CN=\(domain)",
            "-addext", san,
        ])
        try DoryShell.run(openssl, [
            "x509", "-req", "-in", csr.path, "-CA", caCertificate.path, "-CAkey", caKey.path,
            "-CAcreateserial", "-out", certificate.path, "-days", "825", "-copy_extensions", "copyall",
        ])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.path)
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: certificate.path)
        return DoryCertificatePair(certificate: certificate, privateKey: key)
    }

    @discardableResult
    public func issuePKCS12(domain: String, password: String, extraSANs: [String] = []) throws -> URL {
        guard let openssl = opensslPath else { throw DoryShellError.toolNotFound("openssl") }
        let pair = try issue(domain: domain, extraSANs: extraSANs)
        let safeName = domain.replacingOccurrences(of: "/", with: "_")
        let p12 = directory.appendingPathComponent("\(safeName).p12")
        try DoryShell.run(openssl, [
            "pkcs12", "-export", "-inkey", pair.privateKey.path, "-in", pair.certificate.path,
            "-certfile", caCertificate.path, "-out", p12.path,
            "-passout", "pass:\(password)", "-legacy",
        ])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: p12.path)
        return p12
    }

    public func verify(certificate: URL) -> Bool {
        guard let openssl = opensslPath,
              let output = try? DoryShell.run(openssl, ["verify", "-CAfile", caCertificate.path, certificate.path]) else {
            return false
        }
        return output.contains(": OK")
    }

    public func certificateText(_ certificate: URL) throws -> String {
        guard let openssl = opensslPath else { throw DoryShellError.toolNotFound("openssl") }
        return try DoryShell.run(openssl, ["x509", "-in", certificate.path, "-noout", "-text"])
    }

    public func systemTrustInstallCommand() -> [String] {
        [
            "/usr/bin/security", "add-trusted-cert", "-d", "-r", "trustRoot",
            "-k", "/Library/Keychains/System.keychain", caCertificate.path,
        ]
    }
}

public enum DoryShell {
    public static func find(
        _ tool: String,
        candidates: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> String? {
        for path in candidates where fileManager.isExecutableFile(atPath: path) {
            return path
        }
        for directory in (environment["PATH"] ?? "").split(separator: ":", omittingEmptySubsequences: true) {
            let path = URL(fileURLWithPath: String(directory)).appendingPathComponent(tool).path
            if fileManager.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    @discardableResult
    public static func run(_ launchPath: String, _ arguments: [String], cwd: URL? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        if let cwd {
            process.currentDirectoryURL = cwd
        }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            throw DoryShellError.launchFailed("\(error)")
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw DoryShellError.nonZeroExit(process.terminationStatus, text)
        }
        return text
    }
}
