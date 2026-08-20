import DoryOperations
import Foundation

public enum DoryMachineTypedWriteAuthorityError: Error, Sendable, Equatable, CustomStringConvertible {
    case rawEnvironmentForbidden
    case invalidField(String)
    case unsupportedForDisplay(String)
    case unsupportedByLegacyRuntime(String)

    public var description: String {
        switch self {
        case .rawEnvironmentForbidden:
            "raw machine environment input is not accepted; use typed machine settings"
        case let .invalidField(field):
            "invalid typed machine setting: \(field)"
        case let .unsupportedForDisplay(field):
            "typed machine setting \(field) is not supported by this display mode"
        case let .unsupportedByLegacyRuntime(field):
            "typed machine setting \(field) cannot be represented by the current compatibility runtime"
        }
    }
}

public enum DoryMachineTypedSettingUpdate<Value: Sendable & Equatable>: Sendable, Equatable {
    case unchanged
    case set(Value)
    case clear

    public var isChanged: Bool {
        if case .unchanged = self { return false }
        return true
    }
}

/// Typed public write authority for the compatibility MachineManager.
///
/// MachineManager still reads legacy `machine.json` environment values while M0 migration is in
/// progress. Public callers never provide that dictionary: this patch accepts only non-secret,
/// bounded intent and back-projects the seven explicitly owned compatibility keys. Unchanged
/// fields preserve their exact legacy bytes, including values too old or unsafe to migrate.
public struct DoryMachineTypedSettingsPatch: Sendable, Equatable {
    public var guestUsername: DoryMachineTypedSettingUpdate<String>
    public var guestNumericUserID: DoryMachineTypedSettingUpdate<UInt32>
    public var desktopDistributionIdentifier: DoryMachineTypedSettingUpdate<String>
    public var desktopDisplayName: DoryMachineTypedSettingUpdate<String>
    public var desktopVersion: DoryMachineTypedSettingUpdate<String>
    public var desktopEnvironment: DoryMachineTypedSettingUpdate<String>
    public var clipboardPolicy: DoryMachineTypedSettingUpdate<DoryVMClipboardPolicy>
    public var runtimePreference: DoryMachineTypedSettingUpdate<DoryDesktopVMMPreference>
    public var graphicsPreference: DoryMachineTypedSettingUpdate<DoryDesktopGraphicsPreference>

    public init(
        guestUsername: DoryMachineTypedSettingUpdate<String> = .unchanged,
        guestNumericUserID: DoryMachineTypedSettingUpdate<UInt32> = .unchanged,
        desktopDistributionIdentifier: DoryMachineTypedSettingUpdate<String> = .unchanged,
        desktopDisplayName: DoryMachineTypedSettingUpdate<String> = .unchanged,
        desktopVersion: DoryMachineTypedSettingUpdate<String> = .unchanged,
        desktopEnvironment: DoryMachineTypedSettingUpdate<String> = .unchanged,
        clipboardPolicy: DoryMachineTypedSettingUpdate<DoryVMClipboardPolicy> = .unchanged,
        runtimePreference: DoryMachineTypedSettingUpdate<DoryDesktopVMMPreference> = .unchanged,
        graphicsPreference: DoryMachineTypedSettingUpdate<DoryDesktopGraphicsPreference> = .unchanged
    ) {
        self.guestUsername = guestUsername
        self.guestNumericUserID = guestNumericUserID
        self.desktopDistributionIdentifier = desktopDistributionIdentifier
        self.desktopDisplayName = desktopDisplayName
        self.desktopVersion = desktopVersion
        self.desktopEnvironment = desktopEnvironment
        self.clipboardPolicy = clipboardPolicy
        self.runtimePreference = runtimePreference
        self.graphicsPreference = graphicsPreference
    }

    public var isEmpty: Bool {
        !guestUsername.isChanged
            && !guestNumericUserID.isChanged
            && !desktopDistributionIdentifier.isChanged
            && !desktopDisplayName.isChanged
            && !desktopVersion.isChanged
            && !desktopEnvironment.isChanged
            && !clipboardPolicy.isChanged
            && !runtimePreference.isChanged
            && !graphicsPreference.isChanged
    }

    /// Consume the typed persistent-machine options shared by dorydctl create and update. Other
    /// arguments remain in place for the command parser. This intentionally has no `--env`
    /// escape hatch; execution-scoped command environments use a separate API.
    public static func consumeCLIArguments(
        _ arguments: inout [String],
        allowsClears: Bool
    ) throws -> Self {
        var patch = Self()
        if let value = try takeOption("--guest-user", from: &arguments) {
            guard DoryVMGuestAccountIntent.isValidUsername(value) else {
                throw DoryMachineTypedWriteAuthorityError.invalidField("--guest-user")
            }
            patch.guestUsername = .set(value)
        }
        if let raw = try takeOption("--guest-uid", from: &arguments) {
            guard let value = UInt32(raw),
                  DoryVMGuestAccountIntent.isValidNumericUserID(value) else {
                throw DoryMachineTypedWriteAuthorityError.invalidField("--guest-uid")
            }
            patch.guestNumericUserID = .set(value)
        }
        if let value = try takeOption("--desktop-distro", from: &arguments) {
            guard DoryVMDesktopIdentityIntent.isValidDistributionIdentifier(value) else {
                throw DoryMachineTypedWriteAuthorityError.invalidField("--desktop-distro")
            }
            patch.desktopDistributionIdentifier = .set(value)
        }
        let labelOptions: [(String, WritableKeyPath<Self, DoryMachineTypedSettingUpdate<String>>)] = [
            ("--desktop-name", \Self.desktopDisplayName),
            ("--desktop-version", \Self.desktopVersion),
            ("--desktop-environment", \Self.desktopEnvironment),
        ]
        for (option, keyPath) in labelOptions {
            if let value = try takeOption(option, from: &arguments) {
                guard DoryVMDesktopIdentityIntent.isValidLabel(value) else {
                    throw DoryMachineTypedWriteAuthorityError.invalidField(option)
                }
                patch[keyPath: keyPath] = .set(value)
            }
        }
        if let raw = try takeOption("--clipboard", from: &arguments) {
            guard let direction = DoryVMClipboardDirection(rawValue: raw) else {
                throw DoryMachineTypedWriteAuthorityError.invalidField("--clipboard")
            }
            patch.clipboardPolicy = .set(.legacyDesktop(direction))
        }
        if let raw = try takeOption("--runtime", from: &arguments) {
            guard let preference = DoryDesktopVMMPreference(rawValue: raw) else {
                throw DoryMachineTypedWriteAuthorityError.invalidField("--runtime")
            }
            patch.runtimePreference = .set(preference)
        }
        if let raw = try takeOption("--graphics", from: &arguments) {
            guard let preference = DoryDesktopGraphicsPreference(rawValue: raw) else {
                throw DoryMachineTypedWriteAuthorityError.invalidField("--graphics")
            }
            patch.graphicsPreference = .set(preference)
        }

        let clearsAccount = takeFlag("--clear-guest-account", from: &arguments)
        let clearsDesktop = takeFlag("--clear-desktop-identity", from: &arguments)
        let clearsClipboard = takeFlag("--clear-clipboard", from: &arguments)
        let clearsRuntime = takeFlag("--clear-runtime", from: &arguments)
        let clearsGraphics = takeFlag("--clear-graphics", from: &arguments)
        guard allowsClears || (!clearsAccount && !clearsDesktop && !clearsClipboard
            && !clearsRuntime && !clearsGraphics) else {
            throw DoryMachineTypedWriteAuthorityError.invalidField("clear options")
        }
        if clearsAccount {
            guard !patch.guestUsername.isChanged, !patch.guestNumericUserID.isChanged else {
                throw DoryMachineTypedWriteAuthorityError.invalidField(
                    "--clear-guest-account"
                )
            }
            patch.guestUsername = .clear
            patch.guestNumericUserID = .clear
        }
        if clearsDesktop {
            guard !patch.desktopDistributionIdentifier.isChanged,
                  !patch.desktopDisplayName.isChanged,
                  !patch.desktopVersion.isChanged,
                  !patch.desktopEnvironment.isChanged else {
                throw DoryMachineTypedWriteAuthorityError.invalidField(
                    "--clear-desktop-identity"
                )
            }
            patch.desktopDistributionIdentifier = .clear
            patch.desktopDisplayName = .clear
            patch.desktopVersion = .clear
            patch.desktopEnvironment = .clear
        }
        if clearsClipboard {
            guard !patch.clipboardPolicy.isChanged else {
                throw DoryMachineTypedWriteAuthorityError.invalidField("--clear-clipboard")
            }
            patch.clipboardPolicy = .clear
        }
        if clearsRuntime {
            guard !patch.runtimePreference.isChanged else {
                throw DoryMachineTypedWriteAuthorityError.invalidField("--clear-runtime")
            }
            patch.runtimePreference = .clear
        }
        if clearsGraphics {
            guard !patch.graphicsPreference.isChanged else {
                throw DoryMachineTypedWriteAuthorityError.invalidField("--clear-graphics")
            }
            patch.graphicsPreference = .clear
        }
        return patch
    }

    /// Decode the exact XPC write shape. Create requests disallow clears; update requests encode
    /// a deliberate clear as `NSNull`. Unknown nested keys are rejected rather than ignored.
    public init(xpcDictionary dictionary: NSDictionary, allowsClears: Bool) throws {
        guard dictionary["env"] == nil else {
            throw DoryMachineTypedWriteAuthorityError.rawEnvironmentForbidden
        }
        self.init()
        if let rawGuestIdentity = dictionary["guestIdentityIntent"] {
            try decodeGuestIdentity(rawGuestIdentity, allowsClears: allowsClears)
        }
        if let rawClipboard = dictionary["clipboardPolicy"] {
            clipboardPolicy = try Self.decodeClipboardPolicy(
                rawClipboard,
                allowsClears: allowsClears
            )
        }
        runtimePreference = try Self.decodeEnum(
            dictionary["desktopRuntimePreference"],
            field: "desktopRuntimePreference",
            allowsClears: allowsClears,
            type: DoryDesktopVMMPreference.self
        )
        graphicsPreference = try Self.decodeEnum(
            dictionary["desktopGraphicsPreference"],
            field: "desktopGraphicsPreference",
            allowsClears: allowsClears,
            type: DoryDesktopGraphicsPreference.self
        )
    }

    /// Canonical XPC representation used by dorydctl and future typed clients.
    public var xpcDictionary: NSDictionary {
        var result: [String: Any] = [:]
        var account: [String: Any] = [:]
        Self.encode(guestUsername, key: "username", into: &account)
        Self.encode(guestNumericUserID, key: "numericUserID", into: &account)
        var desktop: [String: Any] = [:]
        Self.encode(
            desktopDistributionIdentifier,
            key: "distributionIdentifier",
            into: &desktop
        )
        Self.encode(desktopDisplayName, key: "displayName", into: &desktop)
        Self.encode(desktopVersion, key: "version", into: &desktop)
        Self.encode(desktopEnvironment, key: "desktopEnvironment", into: &desktop)
        if !account.isEmpty || !desktop.isEmpty {
            var identity: [String: Any] = [:]
            if !account.isEmpty { identity["account"] = account as NSDictionary }
            if !desktop.isEmpty { identity["desktop"] = desktop as NSDictionary }
            result["guestIdentityIntent"] = identity as NSDictionary
        }
        switch clipboardPolicy {
        case .unchanged:
            break
        case .clear:
            result["clipboardPolicy"] = NSNull()
        case let .set(policy):
            result["clipboardPolicy"] = [
                "text": policy.text.rawValue,
                "image": policy.image.rawValue,
                "files": policy.files.rawValue,
            ] as NSDictionary
        }
        Self.encodeEnum(
            runtimePreference,
            key: "desktopRuntimePreference",
            into: &result
        )
        Self.encodeEnum(
            graphicsPreference,
            key: "desktopGraphicsPreference",
            into: &result
        )
        return result as NSDictionary
    }

    public func applying(
        to legacyEnvironment: [String: String],
        displayMode: DoryMachineDisplayMode
    ) throws -> [String: String] {
        try validate(displayMode: displayMode)
        var environment = legacyEnvironment
        Self.apply(
            guestUsername,
            key: DoryVMGuestAccountIntent.legacyUsernameEnvironmentKey,
            to: &environment
        )
        Self.apply(
            guestNumericUserID.map(String.init),
            key: DoryVMGuestAccountIntent.legacyNumericUserIDEnvironmentKey,
            to: &environment
        )
        Self.apply(
            desktopDistributionIdentifier,
            key: DoryVMDesktopIdentityIntent.legacyDistributionEnvironmentKey,
            to: &environment
        )
        Self.apply(
            desktopDisplayName,
            key: DoryVMDesktopIdentityIntent.legacyDisplayNameEnvironmentKey,
            to: &environment
        )
        Self.apply(
            desktopVersion,
            key: DoryVMDesktopIdentityIntent.legacyVersionEnvironmentKey,
            to: &environment
        )
        Self.apply(
            desktopEnvironment,
            key: DoryVMDesktopIdentityIntent.legacyDesktopEnvironmentKey,
            to: &environment
        )
        switch clipboardPolicy {
        case .unchanged:
            break
        case .clear:
            environment.removeValue(forKey: DoryDesktopClipboardPolicy.environmentKey)
        case let .set(policy):
            environment[DoryDesktopClipboardPolicy.environmentKey] = policy.text.rawValue
        }
        Self.apply(
            runtimePreference.map(\.rawValue),
            key: DoryDesktopVMMPreference.environmentKey,
            to: &environment
        )
        Self.apply(
            graphicsPreference.map(\.rawValue),
            key: DoryDesktopGraphicsPreference.environmentKey,
            to: &environment
        )
        if graphicsPreference.isChanged {
            environment.removeValue(
                forKey: DoryDesktopGraphicsPreference.legacyClassicOnlyEnvironmentKey
            )
        }
        return environment
    }

    private mutating func decodeGuestIdentity(_ raw: Any, allowsClears: Bool) throws {
        if raw is NSNull {
            guard allowsClears else {
                throw DoryMachineTypedWriteAuthorityError.invalidField("guestIdentityIntent")
            }
            guestUsername = .clear
            guestNumericUserID = .clear
            desktopDistributionIdentifier = .clear
            desktopDisplayName = .clear
            desktopVersion = .clear
            desktopEnvironment = .clear
            return
        }
        guard let identity = Self.dictionary(raw),
              Self.hasOnlyKeys(identity, allowed: ["account", "desktop"]),
              identity.count > 0 else {
            throw DoryMachineTypedWriteAuthorityError.invalidField("guestIdentityIntent")
        }
        if let rawAccount = identity["account"] {
            if rawAccount is NSNull {
                guard allowsClears else {
                    throw DoryMachineTypedWriteAuthorityError.invalidField(
                        "guestIdentityIntent.account"
                    )
                }
                guestUsername = .clear
                guestNumericUserID = .clear
            } else {
                guard let account = Self.dictionary(rawAccount),
                      Self.hasOnlyKeys(account, allowed: ["username", "numericUserID"]),
                      account.count > 0 else {
                    throw DoryMachineTypedWriteAuthorityError.invalidField(
                        "guestIdentityIntent.account"
                    )
                }
                guestUsername = try Self.decodeString(
                    account,
                    key: "username",
                    field: "guestIdentityIntent.account.username",
                    allowsClears: allowsClears,
                    validator: DoryVMGuestAccountIntent.isValidUsername
                )
                guestNumericUserID = try Self.decodeUInt32(
                    account,
                    key: "numericUserID",
                    field: "guestIdentityIntent.account.numericUserID",
                    allowsClears: allowsClears
                )
            }
        }
        if let rawDesktop = identity["desktop"] {
            if rawDesktop is NSNull {
                guard allowsClears else {
                    throw DoryMachineTypedWriteAuthorityError.invalidField(
                        "guestIdentityIntent.desktop"
                    )
                }
                desktopDistributionIdentifier = .clear
                desktopDisplayName = .clear
                desktopVersion = .clear
                desktopEnvironment = .clear
            } else {
                guard let desktop = Self.dictionary(rawDesktop),
                      Self.hasOnlyKeys(
                        desktop,
                        allowed: [
                            "distributionIdentifier",
                            "displayName",
                            "version",
                            "desktopEnvironment",
                        ]
                      ),
                      desktop.count > 0 else {
                    throw DoryMachineTypedWriteAuthorityError.invalidField(
                        "guestIdentityIntent.desktop"
                    )
                }
                desktopDistributionIdentifier = try Self.decodeString(
                    desktop,
                    key: "distributionIdentifier",
                    field: "guestIdentityIntent.desktop.distributionIdentifier",
                    allowsClears: allowsClears,
                    validator: DoryVMDesktopIdentityIntent.isValidDistributionIdentifier
                )
                desktopDisplayName = try Self.decodeString(
                    desktop,
                    key: "displayName",
                    field: "guestIdentityIntent.desktop.displayName",
                    allowsClears: allowsClears,
                    validator: DoryVMDesktopIdentityIntent.isValidLabel
                )
                desktopVersion = try Self.decodeString(
                    desktop,
                    key: "version",
                    field: "guestIdentityIntent.desktop.version",
                    allowsClears: allowsClears,
                    validator: DoryVMDesktopIdentityIntent.isValidLabel
                )
                desktopEnvironment = try Self.decodeString(
                    desktop,
                    key: "desktopEnvironment",
                    field: "guestIdentityIntent.desktop.desktopEnvironment",
                    allowsClears: allowsClears,
                    validator: DoryVMDesktopIdentityIntent.isValidLabel
                )
            }
        }
    }

    private static func decodeClipboardPolicy(
        _ raw: Any,
        allowsClears: Bool
    ) throws -> DoryMachineTypedSettingUpdate<DoryVMClipboardPolicy> {
        if raw is NSNull {
            guard allowsClears else {
                throw DoryMachineTypedWriteAuthorityError.invalidField("clipboardPolicy")
            }
            return .clear
        }
        guard let dictionary = dictionary(raw),
              hasOnlyKeys(dictionary, allowed: ["text", "image", "files"]),
              dictionary.count == 3,
              let text = direction(dictionary["text"]),
              let image = direction(dictionary["image"]),
              let files = direction(dictionary["files"]) else {
            throw DoryMachineTypedWriteAuthorityError.invalidField("clipboardPolicy")
        }
        return .set(DoryVMClipboardPolicy(text: text, image: image, files: files))
    }

    private func validate(displayMode: DoryMachineDisplayMode) throws {
        if case let .set(value) = guestUsername,
           !DoryVMGuestAccountIntent.isValidUsername(value) {
            throw DoryMachineTypedWriteAuthorityError.invalidField(
                "guestIdentityIntent.account.username"
            )
        }
        if case let .set(value) = guestNumericUserID,
           !DoryVMGuestAccountIntent.isValidNumericUserID(value) {
            throw DoryMachineTypedWriteAuthorityError.invalidField(
                "guestIdentityIntent.account.numericUserID"
            )
        }
        let desktopFields: [(String, DoryMachineTypedSettingUpdate<String>, (String) -> Bool)] = [
            (
                "distributionIdentifier",
                desktopDistributionIdentifier,
                DoryVMDesktopIdentityIntent.isValidDistributionIdentifier
            ),
            ("displayName", desktopDisplayName, DoryVMDesktopIdentityIntent.isValidLabel),
            ("version", desktopVersion, DoryVMDesktopIdentityIntent.isValidLabel),
            (
                "desktopEnvironment",
                desktopEnvironment,
                DoryVMDesktopIdentityIntent.isValidLabel
            ),
        ]
        for (field, update, validator) in desktopFields {
            if case let .set(value) = update, !validator(value) {
                throw DoryMachineTypedWriteAuthorityError.invalidField(
                    "guestIdentityIntent.desktop.\(field)"
                )
            }
        }
        let setsDesktopValue = desktopFields.contains { _, update, _ in
            if case .set = update { return true }
            return false
        }
        if setsDesktopValue, displayMode != .desktop {
            throw DoryMachineTypedWriteAuthorityError.unsupportedForDisplay(
                "guestIdentityIntent.desktop"
            )
        }
        if case let .set(policy) = clipboardPolicy {
            guard policy.text == policy.image, policy.files == .off else {
                throw DoryMachineTypedWriteAuthorityError.unsupportedByLegacyRuntime(
                    "clipboardPolicy"
                )
            }
            if policy.isEnabled, displayMode != .desktop {
                throw DoryMachineTypedWriteAuthorityError.unsupportedForDisplay(
                    "clipboardPolicy"
                )
            }
        }
        if (runtimePreference.isSet || graphicsPreference.isSet), displayMode != .desktop {
            throw DoryMachineTypedWriteAuthorityError.unsupportedForDisplay(
                "desktopRuntimePreference"
            )
        }
    }

    private static func dictionary(_ raw: Any) -> NSDictionary? {
        if let dictionary = raw as? NSDictionary { return dictionary }
        if let dictionary = raw as? [String: Any] { return dictionary as NSDictionary }
        return nil
    }

    private static func hasOnlyKeys(_ dictionary: NSDictionary, allowed: Set<String>) -> Bool {
        dictionary.allKeys.allSatisfy { key in
            guard let key = key as? String else { return false }
            return allowed.contains(key)
        }
    }

    private static func decodeString(
        _ dictionary: NSDictionary,
        key: String,
        field: String,
        allowsClears: Bool,
        validator: (String) -> Bool
    ) throws -> DoryMachineTypedSettingUpdate<String> {
        guard let raw = dictionary[key] else { return .unchanged }
        if raw is NSNull {
            guard allowsClears else {
                throw DoryMachineTypedWriteAuthorityError.invalidField(field)
            }
            return .clear
        }
        guard let value = raw as? String, validator(value) else {
            throw DoryMachineTypedWriteAuthorityError.invalidField(field)
        }
        return .set(value)
    }

    private static func decodeUInt32(
        _ dictionary: NSDictionary,
        key: String,
        field: String,
        allowsClears: Bool
    ) throws -> DoryMachineTypedSettingUpdate<UInt32> {
        guard let raw = dictionary[key] else { return .unchanged }
        if raw is NSNull {
            guard allowsClears else {
                throw DoryMachineTypedWriteAuthorityError.invalidField(field)
            }
            return .clear
        }
        guard !(raw is Bool),
              let number = raw as? NSNumber,
              number.doubleValue.rounded(.towardZero) == number.doubleValue,
              number.doubleValue >= 0,
              number.doubleValue <= Double(UInt32.max) else {
            throw DoryMachineTypedWriteAuthorityError.invalidField(field)
        }
        let value = UInt32(number.uint64Value)
        guard DoryVMGuestAccountIntent.isValidNumericUserID(value) else {
            throw DoryMachineTypedWriteAuthorityError.invalidField(field)
        }
        return .set(value)
    }

    private static func direction(_ raw: Any?) -> DoryVMClipboardDirection? {
        guard let raw = raw as? String else { return nil }
        return DoryVMClipboardDirection(rawValue: raw)
    }

    private static func decodeEnum<Value: RawRepresentable & Sendable & Equatable>(
        _ raw: Any?,
        field: String,
        allowsClears: Bool,
        type: Value.Type
    ) throws -> DoryMachineTypedSettingUpdate<Value> where Value.RawValue == String {
        guard let raw else { return .unchanged }
        if raw is NSNull {
            guard allowsClears else {
                throw DoryMachineTypedWriteAuthorityError.invalidField(field)
            }
            return .clear
        }
        guard let raw = raw as? String, let value = Value(rawValue: raw) else {
            throw DoryMachineTypedWriteAuthorityError.invalidField(field)
        }
        return .set(value)
    }

    private static func encodeEnum<Value: RawRepresentable & Sendable & Equatable>(
        _ update: DoryMachineTypedSettingUpdate<Value>,
        key: String,
        into dictionary: inout [String: Any]
    ) where Value.RawValue == String {
        switch update {
        case .unchanged: break
        case .clear: dictionary[key] = NSNull()
        case let .set(value): dictionary[key] = value.rawValue
        }
    }

    private static func takeOption(
        _ name: String,
        from arguments: inout [String]
    ) throws -> String? {
        guard let index = arguments.firstIndex(of: name) else { return nil }
        guard index + 1 < arguments.count else {
            throw DoryMachineTypedWriteAuthorityError.invalidField(name)
        }
        let value = arguments[index + 1]
        arguments.removeSubrange(index...(index + 1))
        return value
    }

    private static func takeFlag(_ name: String, from arguments: inout [String]) -> Bool {
        guard let index = arguments.firstIndex(of: name) else { return false }
        arguments.remove(at: index)
        return true
    }

    private static func encode<Value>(
        _ update: DoryMachineTypedSettingUpdate<Value>,
        key: String,
        into dictionary: inout [String: Any]
    ) {
        switch update {
        case .unchanged:
            break
        case .clear:
            dictionary[key] = NSNull()
        case let .set(value):
            dictionary[key] = value
        }
    }

    private static func apply(
        _ update: DoryMachineTypedSettingUpdate<String>,
        key: String,
        to environment: inout [String: String]
    ) {
        switch update {
        case .unchanged:
            break
        case .clear:
            environment.removeValue(forKey: key)
        case let .set(value):
            environment[key] = value
        }
    }
}

private extension DoryMachineTypedSettingUpdate {
    var isSet: Bool {
        if case .set = self { return true }
        return false
    }

    func map<Mapped: Sendable & Equatable>(
        _ transform: (Value) -> Mapped
    ) -> DoryMachineTypedSettingUpdate<Mapped> {
        switch self {
        case .unchanged: .unchanged
        case .clear: .clear
        case let .set(value): .set(transform(value))
        }
    }
}
