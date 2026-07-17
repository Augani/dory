import Foundation
import Security
import Darwin

nonisolated protocol LocalCATrustManaging {
    /// Returns true when this call added trust that should be rolled back if the
    /// surrounding networking transaction fails.
    func install(certificateAt path: String) throws -> Bool

    /// Returns true when trust or a matching certificate was removed.
    func remove(certificateAt path: String) throws -> Bool
}

nonisolated enum LocalCATrustError: LocalizedError, Equatable {
    case unreadableCertificate(String)
    case invalidCertificate
    case unexpectedCertificate(String)
    case keychainOperation(String, OSStatus)
    case trustOperation(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .unreadableCertificate(let path):
            return "Dory could not read its local CA certificate at \(path)."
        case .invalidCertificate:
            return "Dory's local CA certificate is not a valid X.509 certificate."
        case .unexpectedCertificate(let name):
            return "Dory refused to trust an unexpected certificate named \(name)."
        case .keychainOperation(let action, let status):
            return "Dory could not \(action) its local CA certificate: \(Self.message(for: status))."
        case .trustOperation(let action, let status):
            return "Dory could not \(action) local HTTPS trust: \(Self.message(for: status))."
        }
    }

    private static func message(for status: OSStatus) -> String {
        SecCopyErrorMessageString(status, nil) as String? ?? "Security error \(status)"
    }
}

nonisolated struct LocalCATrustManager: LocalCATrustManaging {
    private static let expectedSubject = "Dory Local CA"

    func install(certificateAt path: String) throws -> Bool {
        let loaded = try loadCertificate(at: path)
        if try isTrusted(loaded.certificate) { return false }

        let addQuery: [CFString: Any] = [
            kSecClass: kSecClassCertificate,
            kSecValueRef: loaded.certificate,
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        let addedCertificate = addStatus == errSecSuccess
        guard addedCertificate || addStatus == errSecDuplicateItem else {
            throw LocalCATrustError.keychainOperation("store", addStatus)
        }

        let trustStatus = SecTrustSettingsSetTrustSettings(loaded.certificate, .user, nil)
        guard trustStatus == errSecSuccess else {
            if addedCertificate {
                _ = try? deleteMatchingCertificate(der: loaded.der)
            }
            throw LocalCATrustError.trustOperation("enable", trustStatus)
        }
        return true
    }

    func remove(certificateAt path: String) throws -> Bool {
        let loaded = try loadCertificate(at: path)
        let trusted = try isTrusted(loaded.certificate)
        if trusted {
            let status = SecTrustSettingsRemoveTrustSettings(loaded.certificate, .user)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw LocalCATrustError.trustOperation("remove", status)
            }
        }

        let removedCertificate = try deleteMatchingCertificate(der: loaded.der)
        return trusted || removedCertificate
    }

    private func isTrusted(_ certificate: SecCertificate) throws -> Bool {
        var settings: CFArray?
        let status = SecTrustSettingsCopyTrustSettings(certificate, .user, &settings)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else {
            throw LocalCATrustError.trustOperation("inspect", status)
        }
        return true
    }

    private func loadCertificate(at path: String) throws -> (certificate: SecCertificate, der: Data) {
        let raw = try readCertificateFile(at: path)
        return try Self.validatedCertificate(from: raw)
    }

    static func validatedCertificate(from raw: Data) throws -> (certificate: SecCertificate, der: Data) {
        let der: Data
        if let pem = String(data: raw, encoding: .utf8), pem.contains("-----BEGIN CERTIFICATE-----") {
            let body = pem
                .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
                .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
                .components(separatedBy: .whitespacesAndNewlines)
                .joined()
            guard let decoded = Data(base64Encoded: body), !decoded.isEmpty else {
                throw LocalCATrustError.invalidCertificate
            }
            der = decoded
        } else {
            der = raw
        }

        guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
            throw LocalCATrustError.invalidCertificate
        }
        let subject = SecCertificateCopySubjectSummary(certificate) as String? ?? "unknown"
        guard subject == Self.expectedSubject else {
            throw LocalCATrustError.unexpectedCertificate(subject)
        }
        return (certificate, der)
    }

    private func readCertificateFile(at path: String) throws -> Data {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw LocalCATrustError.unreadableCertificate(path)
        }
        defer { close(descriptor) }

        var info = stat()
        let maximumBytes = 1 << 20
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(),
              info.st_nlink == 1,
              info.st_size > 0,
              info.st_size <= maximumBytes else {
            throw LocalCATrustError.unreadableCertificate(path)
        }

        var data = Data(count: Int(info.st_size))
        var offset = 0
        let count = data.count
        let readSucceeded = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            while offset < count {
                let amount = read(descriptor, base.advanced(by: offset), count - offset)
                if amount > 0 {
                    offset += amount
                } else if amount < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
        guard readSucceeded else {
            throw LocalCATrustError.unreadableCertificate(path)
        }
        return data
    }

    private func deleteMatchingCertificate(der: Data) throws -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassCertificate,
            kSecMatchLimit: kSecMatchLimitAll,
            kSecReturnRef: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else {
            throw LocalCATrustError.keychainOperation("find", status)
        }

        let certificates = result as? [SecCertificate] ?? []
        var removed = false
        for certificate in certificates where SecCertificateCopyData(certificate) as Data == der {
            // Trust removal invalidates detached certificate references. Delete the fresh
            // keychain-backed item returned above instead of reusing the parsed certificate.
            let deleteStatus = SecItemDelete([
                kSecClass: kSecClassCertificate,
                kSecValueRef: certificate,
            ] as CFDictionary)
            guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
                throw LocalCATrustError.keychainOperation("remove", deleteStatus)
            }
            removed = removed || deleteStatus == errSecSuccess
        }
        return removed
    }
}
