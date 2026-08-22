public enum DoryDesktopClipboardPolicy: String, CaseIterable, Sendable {
    case off
    case hostToGuest = "host-to-guest"
    case guestToHost = "guest-to-host"
    case bidirectional

    public static let environmentKey = "DORY_CLIPBOARD_POLICY"

    public init(environment: [String: String]) {
        guard let rawValue = environment[Self.environmentKey] else {
            self = .bidirectional
            return
        }
        self = Self(rawValue: rawValue) ?? .off
    }

    public var allowsHostToGuest: Bool {
        self == .hostToGuest || self == .bidirectional
    }

    public var allowsGuestToHost: Bool {
        self == .guestToHost || self == .bidirectional
    }

    public var displayName: String {
        switch self {
        case .off: "Off"
        case .hostToGuest: "Mac to Linux"
        case .guestToHost: "Linux to Mac"
        case .bidirectional: "Bidirectional"
        }
    }

    public var virtualMachinePolicy: DoryVMClipboardPolicy {
        let direction = DoryVMClipboardDirection(rawValue: rawValue) ?? .off
        return .legacyDesktop(direction)
    }
}
