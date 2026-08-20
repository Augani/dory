import Foundation

/// Direction in which one clipboard content class may cross the host/guest boundary.
public enum DoryVMClipboardDirection: String, Codable, Sendable, Equatable, CaseIterable {
    case off
    case hostToGuest = "host-to-guest"
    case guestToHost = "guest-to-host"
    case bidirectional

    public var allowsHostToGuest: Bool {
        self == .hostToGuest || self == .bidirectional
    }

    public var allowsGuestToHost: Bool {
        self == .guestToHost || self == .bidirectional
    }
}

/// Clipboard intent is persisted per content class. Runtime negotiation may select only a
/// capability that preserves these directions; it must not silently widen them.
public struct DoryVMClipboardPolicy: Codable, Sendable, Equatable {
    public var text: DoryVMClipboardDirection
    public var image: DoryVMClipboardDirection
    public var files: DoryVMClipboardDirection

    public init(
        text: DoryVMClipboardDirection,
        image: DoryVMClipboardDirection,
        files: DoryVMClipboardDirection
    ) {
        self.text = text
        self.image = image
        self.files = files
    }

    public static let disabled = DoryVMClipboardPolicy(text: .off, image: .off, files: .off)

    /// Current Linux compatibility runtimes apply one direction to text and images and do not
    /// provide clipboard-backed file transfer.
    public static func legacyDesktop(_ direction: DoryVMClipboardDirection) -> Self {
        Self(text: direction, image: direction, files: .off)
    }

    public var isEnabled: Bool {
        text != .off || image != .off || files != .off
    }
}

/// Non-secret account provisioning intent. This is not a credential and never contains a
/// password, token, home-directory path, or host identity.
public struct DoryVMGuestAccountIntent: Codable, Sendable, Equatable {
    public static let legacyUsernameEnvironmentKey = "DORY_GUEST_USER"
    public static let legacyNumericUserIDEnvironmentKey = "DORY_GUEST_UID"

    public var username: String?
    public var numericUserID: UInt32?

    public init(username: String? = nil, numericUserID: UInt32? = nil) {
        self.username = username
        self.numericUserID = numericUserID
    }

    public var isEmpty: Bool { username == nil && numericUserID == nil }

    public var isValidForPersistence: Bool {
        !isEmpty
            && (username.map(Self.isValidUsername) ?? true)
            && (numericUserID.map(Self.isValidNumericUserID) ?? true)
    }

    public static func isValidUsername(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...32).contains(bytes.count),
              (bytes[0] >= 97 && bytes[0] <= 122) || bytes[0] == 95 else {
            return false
        }
        return bytes.dropFirst().allSatisfy { byte in
            (byte >= 97 && byte <= 122)
                || (byte >= 48 && byte <= 57)
                || byte == 95
                || byte == 45
        }
    }

    public static func isValidNumericUserID(_ value: UInt32) -> Bool {
        (100...60_000).contains(value)
    }
}

/// Display metadata for a provisioned guest desktop. Exact boot media and component provenance
/// remain separately bound by their artifact references and resolved launch evidence.
public struct DoryVMDesktopIdentityIntent: Codable, Sendable, Equatable {
    public static let legacyDistributionEnvironmentKey = "DORY_DESKTOP_DISTRO"
    public static let legacyDisplayNameEnvironmentKey = "DORY_DESKTOP_NAME"
    public static let legacyVersionEnvironmentKey = "DORY_DESKTOP_VERSION"
    public static let legacyDesktopEnvironmentKey = "DORY_DESKTOP_ENVIRONMENT"

    public var distributionIdentifier: String?
    public var displayName: String?
    public var version: String?
    public var desktopEnvironment: String?

    public init(
        distributionIdentifier: String? = nil,
        displayName: String? = nil,
        version: String? = nil,
        desktopEnvironment: String? = nil
    ) {
        self.distributionIdentifier = distributionIdentifier
        self.displayName = displayName
        self.version = version
        self.desktopEnvironment = desktopEnvironment
    }

    public var isEmpty: Bool {
        distributionIdentifier == nil
            && displayName == nil
            && version == nil
            && desktopEnvironment == nil
    }

    public var isValidForPersistence: Bool {
        !isEmpty
            && (distributionIdentifier.map(Self.isValidDistributionIdentifier) ?? true)
            && (displayName.map(Self.isValidLabel) ?? true)
            && (version.map(Self.isValidLabel) ?? true)
            && (desktopEnvironment.map(Self.isValidLabel) ?? true)
    }

    public static func isValidDistributionIdentifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...64).contains(bytes.count),
              (bytes[0] >= 97 && bytes[0] <= 122) || (bytes[0] >= 48 && bytes[0] <= 57) else {
            return false
        }
        return bytes.dropFirst().allSatisfy { byte in
            (byte >= 97 && byte <= 122)
                || (byte >= 48 && byte <= 57)
                || byte == 95
                || byte == 46
                || byte == 45
        }
    }

    public static func isValidLabel(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 128
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.hasPrefix("/")
            && !value.hasPrefix("~")
            && !value.contains("://")
            && !value.contains("/")
            && !value.contains("\\")
            && !value.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
    }
}

/// Guest-visible identity intent owned by the workspace definition rather than an opaque
/// environment dictionary.
public struct DoryVMGuestIdentityIntent: Codable, Sendable, Equatable {
    public var account: DoryVMGuestAccountIntent?
    public var desktop: DoryVMDesktopIdentityIntent?

    public init(
        account: DoryVMGuestAccountIntent? = nil,
        desktop: DoryVMDesktopIdentityIntent? = nil
    ) {
        self.account = account
        self.desktop = desktop
    }

    public static let unspecified = DoryVMGuestIdentityIntent()

    public var isEmpty: Bool {
        (account?.isEmpty ?? true) && (desktop?.isEmpty ?? true)
    }
}
