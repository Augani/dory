public extension DoryVMResolverReference {
    /// Persistence-safe resolver key shared by WorkspaceSpec and daemon-private authorities.
    /// Host paths, URLs, controls, and common credential/token shapes are intentionally excluded.
    var isValidForPersistence: Bool {
        let namespaceBytes = Array(namespace.utf8)
        let identifierBytes = Array(identifier.utf8)
        guard (1...32).contains(namespaceBytes.count),
              let firstNamespaceByte = namespaceBytes.first,
              firstNamespaceByte >= 97,
              firstNamespaceByte <= 122,
              namespaceBytes.dropFirst().allSatisfy({ byte in
                  (byte >= 97 && byte <= 122)
                      || (byte >= 48 && byte <= 57)
                      || byte == 45
              }),
              (1...64).contains(identifierBytes.count),
              let firstIdentifierByte = identifierBytes.first,
              Self.isASCIIAlphaNumeric(firstIdentifierByte),
              identifierBytes.dropFirst().allSatisfy({ byte in
                  Self.isASCIIAlphaNumeric(byte) || byte == 95 || byte == 46 || byte == 45
              }) else {
            return false
        }
        let lowercase = identifier.lowercased()
        let secretPrefixes = [
            "sk-", "ghp_", "github_pat_", "xoxb-", "xoxp-", "xoxa-", "xoxr-",
            "bearer-", "password-", "secret-", "token-", "akia",
        ]
        return !secretPrefixes.contains(where: lowercase.hasPrefix)
            && !lowercase.hasPrefix("eyj")
    }

    private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        (byte >= 48 && byte <= 57)
            || (byte >= 65 && byte <= 90)
            || (byte >= 97 && byte <= 122)
    }
}
