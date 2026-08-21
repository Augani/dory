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

public struct DoryMachineTypedSettingsSnapshot: Codable, Sendable, Equatable, Hashable {
    public var guestIdentityIntent: DoryVMGuestIdentityIntent
    public var clipboardPolicy: DoryVMClipboardPolicy?
    public var runtimePreference: DoryDesktopVMMPreference?
    public var graphicsPreference: DoryDesktopGraphicsPreference?
    public var networkMode: DoryVMNetworkMode

    private enum CodingKeys: String, CodingKey {
        case guestIdentityIntent
        case clipboardPolicy
        case runtimePreference
        case graphicsPreference
        case networkMode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guestIdentityIntent = try container.decode(
            DoryVMGuestIdentityIntent.self,
            forKey: .guestIdentityIntent
        )
        clipboardPolicy = try container.decodeIfPresent(
            DoryVMClipboardPolicy.self,
            forKey: .clipboardPolicy
        )
        runtimePreference = try container.decodeIfPresent(
            DoryDesktopVMMPreference.self,
            forKey: .runtimePreference
        )
        graphicsPreference = try container.decodeIfPresent(
            DoryDesktopGraphicsPreference.self,
            forKey: .graphicsPreference
        )
        networkMode = try container.decodeIfPresent(
            DoryVMNetworkMode.self,
            forKey: .networkMode
        ) ?? .sharedNAT
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(guestIdentityIntent, forKey: .guestIdentityIntent)
        try container.encodeIfPresent(clipboardPolicy, forKey: .clipboardPolicy)
        try container.encodeIfPresent(runtimePreference, forKey: .runtimePreference)
        try container.encodeIfPresent(graphicsPreference, forKey: .graphicsPreference)
        try container.encode(networkMode, forKey: .networkMode)
    }

    public init(definition: DoryVirtualMachineDefinition) throws {
        guestIdentityIntent = definition.guestIdentityIntent
        networkMode = definition.networkMode
        guard definition.display.enabled else {
            clipboardPolicy = nil
            runtimePreference = nil
            graphicsPreference = nil
            return
        }
        clipboardPolicy = definition.clipboardPolicy
        switch (definition.backendPreference.mode, definition.backendPreference.backend) {
        case (.automatic, nil):
            runtimePreference = .automatic
        case (.preferred, .doryHypervisor?):
            runtimePreference = .accelerated
        case (.preferred, .appleVirtualizationFramework?):
            runtimePreference = .compatible
        default:
            throw DoryMachineTypedWriteAuthorityError.unsupportedByLegacyRuntime(
                "desktopRuntimePreference"
            )
        }
        switch definition.graphics.acceptableLevels {
        case [.hardwareAccelerated3D, .hostAcceleratedDisplay, .software]:
            graphicsPreference = .automatic
        case [.hardwareAccelerated3D]:
            graphicsPreference = .virglVenus
        case [.hostAcceleratedDisplay]:
            graphicsPreference = .virgl
        case [.software]:
            graphicsPreference = .software
        default:
            throw DoryMachineTypedWriteAuthorityError.unsupportedByLegacyRuntime(
                "desktopGraphicsPreference"
            )
        }
    }

    /// Projects only the bounded, non-secret compatibility fields understood by the typed
    /// machine-settings contract. Opaque legacy environment entries remain daemon-private and
    /// are never copied into status/XPC diagnostics.
    public init(
        legacyEnvironment: [String: String],
        displayMode: DoryMachineDisplayMode
    ) {
        let username = legacyEnvironment[
            DoryVMGuestAccountIntent.legacyUsernameEnvironmentKey
        ].flatMap { DoryVMGuestAccountIntent.isValidUsername($0) ? $0 : nil }
        let numericUserID = legacyEnvironment[
            DoryVMGuestAccountIntent.legacyNumericUserIDEnvironmentKey
        ].flatMap(UInt32.init).flatMap {
            DoryVMGuestAccountIntent.isValidNumericUserID($0) ? $0 : nil
        }
        let account = DoryVMGuestAccountIntent(
            username: username,
            numericUserID: numericUserID
        )
        let desktop: DoryVMDesktopIdentityIntent?
        if displayMode == .desktop {
            func safeLabel(_ key: String) -> String? {
                legacyEnvironment[key].flatMap {
                    DoryVMDesktopIdentityIntent.isValidLabel($0) ? $0 : nil
                }
            }
            let distributionIdentifier = legacyEnvironment[
                DoryVMDesktopIdentityIntent.legacyDistributionEnvironmentKey
            ].flatMap {
                DoryVMDesktopIdentityIntent.isValidDistributionIdentifier($0) ? $0 : nil
            }
            let candidate = DoryVMDesktopIdentityIntent(
                distributionIdentifier: distributionIdentifier,
                displayName: safeLabel(
                    DoryVMDesktopIdentityIntent.legacyDisplayNameEnvironmentKey
                ),
                version: safeLabel(
                    DoryVMDesktopIdentityIntent.legacyVersionEnvironmentKey
                ),
                desktopEnvironment: safeLabel(
                    DoryVMDesktopIdentityIntent.legacyDesktopEnvironmentKey
                )
            )
            desktop = candidate.isValidForPersistence ? candidate : nil
        } else {
            desktop = nil
        }
        guestIdentityIntent = DoryVMGuestIdentityIntent(
            account: account.isValidForPersistence ? account : nil,
            desktop: desktop
        )
        networkMode = .sharedNAT
        if displayMode == .desktop {
            let clipboard = DoryDesktopClipboardPolicy(environment: legacyEnvironment)
            clipboardPolicy = DoryVMClipboardDirection(rawValue: clipboard.rawValue)
                .map(DoryVMClipboardPolicy.legacyDesktop)
            runtimePreference = (try? DoryDesktopVMMPreference(
                environment: legacyEnvironment
            )) ?? .automatic
            graphicsPreference = (try? DoryDesktopGraphicsPreference(
                environment: legacyEnvironment
            )) ?? .automatic
        } else {
            clipboardPolicy = nil
            runtimePreference = nil
            graphicsPreference = nil
        }
    }

    public var xpcDictionary: NSDictionary {
        DoryMachineTypedSettingsPatch(
            guestUsername: update(guestIdentityIntent.account?.username),
            guestNumericUserID: update(guestIdentityIntent.account?.numericUserID),
            desktopDistributionIdentifier: update(
                guestIdentityIntent.desktop?.distributionIdentifier
            ),
            desktopDisplayName: update(guestIdentityIntent.desktop?.displayName),
            desktopVersion: update(guestIdentityIntent.desktop?.version),
            desktopEnvironment: update(
                guestIdentityIntent.desktop?.desktopEnvironment
            ),
            clipboardPolicy: update(clipboardPolicy),
            runtimePreference: update(runtimePreference),
            graphicsPreference: update(graphicsPreference),
            networkMode: .set(networkMode)
        ).xpcDictionary
    }

    public func applyingAsReplacement(
        to definition: DoryVirtualMachineDefinition,
        displayMode: DoryMachineDisplayMode
    ) throws -> DoryVirtualMachineDefinition {
        try replacementPatch.applying(to: definition, displayMode: displayMode)
    }

    public var replacementPatch: DoryMachineTypedSettingsPatch {
        DoryMachineTypedSettingsPatch(
            guestUsername: replacement(guestIdentityIntent.account?.username),
            guestNumericUserID: replacement(guestIdentityIntent.account?.numericUserID),
            desktopDistributionIdentifier: replacement(
                guestIdentityIntent.desktop?.distributionIdentifier
            ),
            desktopDisplayName: replacement(guestIdentityIntent.desktop?.displayName),
            desktopVersion: replacement(guestIdentityIntent.desktop?.version),
            desktopEnvironment: replacement(
                guestIdentityIntent.desktop?.desktopEnvironment
            ),
            // Headless snapshots intentionally omit desktop-only values. Absence therefore
            // means “not represented by this display contract,” not “reset the backend and
            // graphics policy to desktop defaults.”
            clipboardPolicy: update(clipboardPolicy),
            runtimePreference: update(runtimePreference),
            graphicsPreference: update(graphicsPreference),
            networkMode: .set(networkMode)
        )
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(guestIdentityIntent.account?.username)
        hasher.combine(guestIdentityIntent.account?.numericUserID)
        hasher.combine(guestIdentityIntent.desktop?.distributionIdentifier)
        hasher.combine(guestIdentityIntent.desktop?.displayName)
        hasher.combine(guestIdentityIntent.desktop?.version)
        hasher.combine(guestIdentityIntent.desktop?.desktopEnvironment)
        hasher.combine(clipboardPolicy?.text.rawValue)
        hasher.combine(clipboardPolicy?.image.rawValue)
        hasher.combine(clipboardPolicy?.files.rawValue)
        hasher.combine(runtimePreference?.rawValue)
        hasher.combine(graphicsPreference?.rawValue)
        hasher.combine(networkMode.rawValue)
    }

    private func update<Value: Sendable & Equatable>(
        _ value: Value?
    ) -> DoryMachineTypedSettingUpdate<Value> {
        value.map(DoryMachineTypedSettingUpdate.set) ?? .unchanged
    }

    private func replacement<Value: Sendable & Equatable>(
        _ value: Value?
    ) -> DoryMachineTypedSettingUpdate<Value> {
        value.map(DoryMachineTypedSettingUpdate.set) ?? .clear
    }
}

/// Typed public write authority shared by native workspace records and the legacy bridge.
///
/// Native workspaces apply this patch directly to their versioned definition. Legacy workspaces
/// back-project only the explicitly owned compatibility keys. Public callers never provide the
/// persisted environment dictionary, and unchanged legacy fields retain their exact bytes.
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
    public var networkMode: DoryMachineTypedSettingUpdate<DoryVMNetworkMode>

    public init(
        guestUsername: DoryMachineTypedSettingUpdate<String> = .unchanged,
        guestNumericUserID: DoryMachineTypedSettingUpdate<UInt32> = .unchanged,
        desktopDistributionIdentifier: DoryMachineTypedSettingUpdate<String> = .unchanged,
        desktopDisplayName: DoryMachineTypedSettingUpdate<String> = .unchanged,
        desktopVersion: DoryMachineTypedSettingUpdate<String> = .unchanged,
        desktopEnvironment: DoryMachineTypedSettingUpdate<String> = .unchanged,
        clipboardPolicy: DoryMachineTypedSettingUpdate<DoryVMClipboardPolicy> = .unchanged,
        runtimePreference: DoryMachineTypedSettingUpdate<DoryDesktopVMMPreference> = .unchanged,
        graphicsPreference: DoryMachineTypedSettingUpdate<DoryDesktopGraphicsPreference> = .unchanged,
        networkMode: DoryMachineTypedSettingUpdate<DoryVMNetworkMode> = .unchanged
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
        self.networkMode = networkMode
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
            && !networkMode.isChanged
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
        if let raw = try takeOption("--network", from: &arguments) {
            guard let mode = DoryVMNetworkMode(rawValue: raw) else {
                throw DoryMachineTypedWriteAuthorityError.invalidField("--network")
            }
            patch.networkMode = .set(mode)
        }

        let clearsAccount = takeFlag("--clear-guest-account", from: &arguments)
        let clearsDesktop = takeFlag("--clear-desktop-identity", from: &arguments)
        let clearsClipboard = takeFlag("--clear-clipboard", from: &arguments)
        let clearsRuntime = takeFlag("--clear-runtime", from: &arguments)
        let clearsGraphics = takeFlag("--clear-graphics", from: &arguments)
        let clearsNetwork = takeFlag("--clear-network", from: &arguments)
        guard allowsClears || (!clearsAccount && !clearsDesktop && !clearsClipboard
            && !clearsRuntime && !clearsGraphics && !clearsNetwork) else {
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
        if clearsNetwork {
            guard !patch.networkMode.isChanged else {
                throw DoryMachineTypedWriteAuthorityError.invalidField("--clear-network")
            }
            patch.networkMode = .clear
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
        networkMode = try Self.decodeEnum(
            dictionary["networkMode"],
            field: "networkMode",
            allowsClears: allowsClears,
            type: DoryVMNetworkMode.self
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
        Self.encodeEnum(networkMode, key: "networkMode", into: &result)
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
        switch networkMode {
        case .unchanged, .clear, .set(.sharedNAT):
            break
        case .set:
            throw DoryMachineTypedWriteAuthorityError.unsupportedByLegacyRuntime(
                "networkMode"
            )
        }
        return environment
    }

    public func applying(
        to source: DoryVirtualMachineDefinition,
        displayMode: DoryMachineDisplayMode
    ) throws -> DoryVirtualMachineDefinition {
        try validate(displayMode: displayMode)
        var definition = source
        var account = definition.guestIdentityIntent.account ?? DoryVMGuestAccountIntent()
        Self.apply(guestUsername, to: &account.username)
        Self.apply(guestNumericUserID, to: &account.numericUserID)
        definition.guestIdentityIntent.account = account.isEmpty ? nil : account

        var desktop = definition.guestIdentityIntent.desktop
            ?? DoryVMDesktopIdentityIntent()
        Self.apply(
            desktopDistributionIdentifier,
            to: &desktop.distributionIdentifier
        )
        Self.apply(desktopDisplayName, to: &desktop.displayName)
        Self.apply(desktopVersion, to: &desktop.version)
        Self.apply(desktopEnvironment, to: &desktop.desktopEnvironment)
        definition.guestIdentityIntent.desktop = desktop.isEmpty ? nil : desktop

        switch clipboardPolicy {
        case .unchanged:
            break
        case .clear:
            definition.clipboardPolicy = displayMode == .desktop
                ? .legacyDesktop(.bidirectional) : .disabled
        case let .set(policy):
            definition.clipboardPolicy = policy
        }
        switch runtimePreference {
        case .unchanged:
            break
        case .clear, .set(.automatic):
            definition.backendPreference = DoryVMBackendPreference()
        case .set(.accelerated):
            definition.backendPreference = DoryVMBackendPreference(
                mode: .preferred,
                backend: .doryHypervisor
            )
        case .set(.compatible):
            definition.backendPreference = DoryVMBackendPreference(
                mode: .preferred,
                backend: .appleVirtualizationFramework
            )
        }
        switch graphicsPreference {
        case .unchanged:
            break
        case .clear, .set(.automatic):
            definition.graphics = DoryVMGraphicsPolicy(
                acceptableLevels: [
                    .hardwareAccelerated3D,
                    .hostAcceleratedDisplay,
                    .software,
                ]
            )
        case .set(.virgl):
            definition.graphics = DoryVMGraphicsPolicy(
                acceptableLevels: [.hostAcceleratedDisplay]
            )
        case .set(.virglVenus):
            definition.graphics = DoryVMGraphicsPolicy(
                acceptableLevels: [.hardwareAccelerated3D]
            )
        case .set(.software):
            definition.graphics = DoryVMGraphicsPolicy(acceptableLevels: [.software])
        }
        switch networkMode {
        case .unchanged:
            break
        case .clear:
            definition.networkMode = .sharedNAT
        case let .set(mode):
            definition.networkMode = mode
        }
        let issues = definition.validate()
        guard issues.isEmpty else {
            throw DoryMachineTypedWriteAuthorityError.invalidField(
                issues.first?.field ?? "definition"
            )
        }
        return definition
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

    private static func apply<Value: Sendable & Equatable>(
        _ update: DoryMachineTypedSettingUpdate<Value>,
        to value: inout Value?
    ) {
        switch update {
        case .unchanged:
            break
        case let .set(replacement):
            value = replacement
        case .clear:
            value = nil
        }
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
