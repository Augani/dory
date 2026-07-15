import Darwin
import Foundation

public enum DoryShellError: Error, Sendable, Equatable, CustomStringConvertible {
    case launchFailed(String)
    case nonZeroExit(Int32, String)
    case timedOut(TimeInterval, String)
    case toolNotFound(String)
    case invalidArgument(String)

    public var description: String {
        switch self {
        case let .launchFailed(message):
            return "launch failed: \(message)"
        case let .nonZeroExit(code, output):
            return "process exited \(code): \(output)"
        case let .timedOut(timeout, output):
            return "process timed out after \(timeout) seconds: \(output)"
        case let .toolNotFound(tool):
            return "tool not found: \(tool)"
        case let .invalidArgument(message):
            return "invalid argument: \(message)"
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
        guard fileManager.fileExists(atPath: caCertificate.path),
              fileManager.fileExists(atPath: caKey.path) else {
            return false
        }
        // A crash mid-generation can leave a truncated cert; require it to actually parse
        // so ensureCA regenerates instead of leaving TLS permanently broken.
        guard let openssl = opensslPath else { return true }
        return (try? DoryShell.run(openssl, ["x509", "-in", caCertificate.path, "-noout"])) != nil
    }

    public func ensureCA() throws {
        guard let openssl = opensslPath else { throw DoryShellError.toolNotFound("openssl") }
        if caExists { return }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let temporaryKey = directory.appendingPathComponent("ca.key.tmp-\(UUID().uuidString)")
        let temporaryCert = directory.appendingPathComponent("ca.crt.tmp-\(UUID().uuidString)")
        defer {
            try? fileManager.removeItem(at: temporaryKey)
            try? fileManager.removeItem(at: temporaryCert)
        }

        // Create the private key 0600 from the outset via umask, not chmod-after, so it is
        // never briefly group/world-readable.
        let previousMask = umask(0o177)
        do {
            try DoryShell.run(openssl, [
                "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes",
                "-keyout", temporaryKey.path, "-out", temporaryCert.path, "-days", "3650",
                "-subj", "/CN=Dory Local CA/O=Dory",
                "-addext", "basicConstraints=critical,CA:TRUE",
                "-addext", "keyUsage=critical,keyCertSign,cRLSign",
            ])
            umask(previousMask)
        } catch {
            umask(previousMask)
            throw error
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryKey.path)
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: temporaryCert.path)

        // Publish atomically so a crash mid-write can never leave a half-written CA.
        try atomicPublish(from: temporaryKey, to: caKey)
        try atomicPublish(from: temporaryCert, to: caCertificate)
    }

    private func atomicPublish(from source: URL, to destination: URL) throws {
        guard rename(source.path, destination.path) == 0 else {
            throw DoryShellError.launchFailed(
                "rename \(source.path) -> \(destination.path): \(String(cString: strerror(errno)))"
            )
        }
    }

    @discardableResult
    public func issue(domain: String, extraSANs: [String] = []) throws -> DoryCertificatePair {
        guard let openssl = opensslPath else { throw DoryShellError.toolNotFound("openssl") }
        // Validate every name before it lands in the openssl SAN string: a comma or
        // other metacharacter would otherwise let a caller inject extra SAN entries.
        try Self.validateCertificateName(domain)
        for name in extraSANs where !name.isEmpty {
            try Self.validateCertificateName(name)
        }
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
        // Pass the export passphrase via the environment (env:) rather than argv, so it is
        // not visible to `ps` while openssl runs.
        let passphraseVariable = "DORY_LOCALCA_P12_PASS"
        var childEnvironment = environment
        childEnvironment[passphraseVariable] = password
        try DoryShell.run(openssl, [
            "pkcs12", "-export", "-inkey", pair.privateKey.path, "-in", pair.certificate.path,
            "-certfile", caCertificate.path, "-out", p12.path,
            "-passout", "env:\(passphraseVariable)", "-legacy",
        ], environment: childEnvironment)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: p12.path)
        return p12
    }

    private static func validateCertificateName(_ name: String) throws {
        var value = name
        if value.hasPrefix("*.") {
            value = String(value.dropFirst(2))
        }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { throw DoryShellError.invalidArgument("certificate name: \(name)") }
        for label in labels {
            guard !label.isEmpty,
                  label.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
                throw DoryShellError.invalidArgument("certificate name: \(name)")
            }
        }
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
    public static func run(
        _ launchPath: String,
        _ arguments: [String],
        cwd: URL? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval = 30
    ) throws -> String {
        guard timeout.isFinite, timeout > 0 else {
            throw DoryShellError.invalidArgument("process timeout")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        if let cwd {
            process.currentDirectoryURL = cwd
        }
        if let environment {
            process.environment = environment
        }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            throw DoryShellError.launchFailed("\(error)")
        }

        let capturedOutput = DoryShellOutputBuffer(maximumBytes: 1_048_576)
        let reader = DispatchGroup()
        reader.enter()
        DispatchQueue.global(qos: .utility).async {
            capturedOutput.drain(output.fileHandleForReading)
            reader.leave()
        }

        let didTimeOut = exited.wait(timeout: .now() + timeout) == .timedOut
        if didTimeOut, process.isRunning {
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
        }
        process.waitUntilExit()
        reader.wait()
        process.terminationHandler = nil
        let text = capturedOutput.text
        if didTimeOut {
            throw DoryShellError.timedOut(timeout, text)
        }
        guard process.terminationStatus == 0 else {
            throw DoryShellError.nonZeroExit(process.terminationStatus, text)
        }
        return text
    }
}

private final class DoryShellOutputBuffer: @unchecked Sendable {
    private let maximumBytes: Int
    private let lock = NSLock()
    private var data = Data()

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }

    func drain(_ handle: FileHandle) {
        while true {
            let chunk = handle.readData(ofLength: 65_536)
            guard !chunk.isEmpty else { return }
            lock.lock()
            if chunk.count >= maximumBytes {
                data = Data(chunk.suffix(maximumBytes))
            } else {
                let overflow = data.count + chunk.count - maximumBytes
                if overflow > 0 {
                    data.removeFirst(overflow)
                }
                data.append(chunk)
            }
            lock.unlock()
        }
    }
}
