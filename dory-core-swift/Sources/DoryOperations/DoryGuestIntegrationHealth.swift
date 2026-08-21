import Foundation

/// Durable launch authority available to the guest-integration health evaluator. The evaluator
/// deliberately distinguishes a qualified resolved plan from compatibility operation so the UI
/// never presents a legacy inference as a negotiated integration.
public enum DoryGuestIntegrationRuntimeAuthority: String, Codable, Sendable, Hashable {
    case legacyCompatibility = "legacy-compatibility"
    case resolvedPlan = "resolved-plan"
    case requiresReplanning = "requires-replanning"
}

public enum DoryGuestIntegrationHealthState: String, Codable, Sendable, Hashable {
    case inactive
    case missingTools = "missing-tools"
    case incompatible
    case degraded
    case compatibility
    case healthy
}

public enum DoryGuestIntegrationFeatureProvider: String, Codable, Sendable, Hashable {
    case guestAgent = "guest-agent"
    case resolvedRuntime = "resolved-runtime"
}

public enum DoryGuestIntegrationFeatureState: String, Codable, Sendable, Hashable {
    case inactive
    case active
    case unavailable
    case updateRequired = "update-required"
    case unqualified
}

public struct DoryGuestIntegrationNegotiatedCapability: Codable, Sendable, Equatable, Hashable {
    public var id: String
    public var version: UInt32

    public init(id: String, version: UInt32) {
        self.id = id
        self.version = version
    }

    public var isValid: Bool {
        version > 0 && id.utf8.count <= 63
            && id.wholeMatch(of: /[a-z][a-z0-9]*(?:-[a-z0-9]+)*/) != nil
    }
}

public struct DoryGuestIntegrationFeatureHealth: Codable, Sendable, Equatable, Hashable {
    public var id: DoryGuestIntegrationCapabilityID
    public var provider: DoryGuestIntegrationFeatureProvider
    public var required: Bool
    public var minimumVersion: UInt32?
    public var negotiatedVersion: UInt32?
    public var state: DoryGuestIntegrationFeatureState

    public init(
        id: DoryGuestIntegrationCapabilityID,
        provider: DoryGuestIntegrationFeatureProvider,
        required: Bool,
        minimumVersion: UInt32? = nil,
        negotiatedVersion: UInt32? = nil,
        state: DoryGuestIntegrationFeatureState
    ) {
        self.id = id
        self.provider = provider
        self.required = required
        self.minimumVersion = minimumVersion
        self.negotiatedVersion = negotiatedVersion
        self.state = state
    }

    public var isValid: Bool {
        switch provider {
        case .guestAgent:
            guard let minimumVersion, minimumVersion > 0 else { return false }
            switch state {
            case .active:
                guard let negotiatedVersion else { return false }
                return negotiatedVersion >= minimumVersion
            case .updateRequired:
                guard let negotiatedVersion else { return false }
                return negotiatedVersion > 0 && negotiatedVersion < minimumVersion
            case .inactive, .unavailable:
                return negotiatedVersion == nil
            case .unqualified:
                return false
            }
        case .resolvedRuntime:
            return minimumVersion == nil && negotiatedVersion == nil
        }
    }

}

/// Immutable, non-secret projection of the integrations negotiated for one workspace. It is
/// recomputed by the daemon from its exact runtime authority and live guest handshake; it is never
/// persisted as a second source of truth.
public struct DoryGuestIntegrationHealth: Codable, Sendable, Equatable, Hashable {
    public static let currentSchemaVersion: UInt16 = 1
    public static let supportedAgentProtocolVersion: UInt32 = 1

    public var schemaVersion: UInt16
    public var state: DoryGuestIntegrationHealthState
    public var runtimeAuthority: DoryGuestIntegrationRuntimeAuthority
    public var agentBuild: String?
    public var agentProtocolVersion: UInt32?
    public var features: [DoryGuestIntegrationFeatureHealth]

    public init(
        schemaVersion: UInt16 = Self.currentSchemaVersion,
        state: DoryGuestIntegrationHealthState,
        runtimeAuthority: DoryGuestIntegrationRuntimeAuthority,
        agentBuild: String?,
        agentProtocolVersion: UInt32?,
        features: [DoryGuestIntegrationFeatureHealth]
    ) {
        self.schemaVersion = schemaVersion
        self.state = state
        self.runtimeAuthority = runtimeAuthority
        self.agentBuild = agentBuild
        self.agentProtocolVersion = agentProtocolVersion
        self.features = features
    }

    public var isValid: Bool {
        guard schemaVersion == Self.currentSchemaVersion,
              features == features.sorted(by: { $0.id.rawValue < $1.id.rawValue }),
              Set(features.map(\.id)).count == features.count,
              features.allSatisfy(\.isValid),
              agentBuild.map(Self.isValidAgentBuild) ?? true else {
            return false
        }
        guard features.filter({ $0.provider == .resolvedRuntime }).allSatisfy({ feature in
            if state == .inactive { return feature.state == .inactive }
            switch runtimeAuthority {
            case .resolvedPlan:
                return feature.state == .active || feature.state == .unavailable
            case .requiresReplanning:
                return feature.state == .updateRequired
            case .legacyCompatibility:
                return feature.state == .unqualified
            }
        }) else {
            return false
        }
        let requiredAreActive = features
            .filter(\.required)
            .allSatisfy { $0.state == .active }
        let requiredAgentFeaturesAreActive = features
            .filter { $0.required && $0.provider == .guestAgent }
            .allSatisfy { $0.state == .active }
        switch state {
        case .inactive:
            return agentBuild == nil && agentProtocolVersion == nil
                && features.allSatisfy { $0.state == .inactive }
        case .missingTools:
            return agentBuild == nil && agentProtocolVersion == nil
        case .incompatible:
            return agentBuild != nil
                && agentProtocolVersion != nil
                && (agentProtocolVersion != Self.supportedAgentProtocolVersion
                    || features.filter { $0.provider == .guestAgent }
                        .allSatisfy { $0.state == .unavailable })
        case .degraded:
            return agentBuild != nil
                && agentProtocolVersion == Self.supportedAgentProtocolVersion
                && (!requiredAreActive || runtimeAuthority == .requiresReplanning)
        case .compatibility:
            return agentBuild != nil
                && agentProtocolVersion == Self.supportedAgentProtocolVersion
                && requiredAgentFeaturesAreActive
                && runtimeAuthority == .legacyCompatibility
        case .healthy:
            return agentBuild != nil
                && agentProtocolVersion == Self.supportedAgentProtocolVersion
                && requiredAreActive
                && runtimeAuthority == .resolvedPlan
        }
    }

    /// Validates the complete feature inventory for the workspace shape. This prevents a
    /// structurally valid but truncated projection from being interpreted as healthy.
    public func isValid(
        desktopIntegrationsExpected: Bool,
        clipboardTextExpected: Bool,
        clipboardImageExpected: Bool,
        sharedFoldersExpected: Bool
    ) -> Bool {
        isValid && features.map(\.id) == Self.featureRequirements(
            desktopIntegrationsExpected: desktopIntegrationsExpected,
            clipboardTextExpected: clipboardTextExpected,
            clipboardImageExpected: clipboardImageExpected,
            sharedFoldersExpected: sharedFoldersExpected
        ).map(\.id)
    }

    public static func evaluate(
        machineIsRunning: Bool,
        runtimeAuthority: DoryGuestIntegrationRuntimeAuthority,
        desktopIntegrationsExpected: Bool,
        clipboardTextExpected: Bool,
        clipboardImageExpected: Bool,
        sharedFoldersExpected: Bool,
        qualifiedRuntimeFeatures: Set<DoryGuestIntegrationCapabilityID>,
        agentBuild: String?,
        agentProtocolVersion: UInt32?,
        agentCapabilities: [DoryGuestIntegrationNegotiatedCapability]
    ) -> Self {
        let build = agentBuild.flatMap { isValidAgentBuild($0) ? $0 : nil }
        guard machineIsRunning else {
            let features = featureRequirements(
                desktopIntegrationsExpected: desktopIntegrationsExpected,
                clipboardTextExpected: clipboardTextExpected,
                clipboardImageExpected: clipboardImageExpected,
                sharedFoldersExpected: sharedFoldersExpected
            ).map { requirement in
                feature(
                    requirement,
                    runtimeAuthority: runtimeAuthority,
                    machineIsRunning: false,
                    qualifiedRuntimeFeatures: [],
                    supportedAgentProtocol: false,
                    capabilities: [:]
                )
            }
            return Self(
                state: .inactive,
                runtimeAuthority: runtimeAuthority,
                agentBuild: nil,
                agentProtocolVersion: nil,
                features: features
            )
        }

        let capabilitiesAreCanonical = agentCapabilities.allSatisfy(\.isValid)
            && agentCapabilities == agentCapabilities.sorted { $0.id < $1.id }
            && Set(agentCapabilities.map(\.id)).count == agentCapabilities.count
        let capabilityVersions = capabilitiesAreCanonical
            ? Dictionary(uniqueKeysWithValues: agentCapabilities.map { ($0.id, $0.version) })
            : [:]
        let protocolIsSupported = agentProtocolVersion == supportedAgentProtocolVersion
        let handshakeIsSupported = protocolIsSupported && capabilitiesAreCanonical
        let features = featureRequirements(
            desktopIntegrationsExpected: desktopIntegrationsExpected,
            clipboardTextExpected: clipboardTextExpected,
            clipboardImageExpected: clipboardImageExpected,
            sharedFoldersExpected: sharedFoldersExpected
        ).map { requirement in
            feature(
                requirement,
                runtimeAuthority: runtimeAuthority,
                machineIsRunning: true,
                qualifiedRuntimeFeatures: qualifiedRuntimeFeatures,
                supportedAgentProtocol: handshakeIsSupported,
                capabilities: capabilityVersions
            )
        }

        let state: DoryGuestIntegrationHealthState
        if build == nil || agentProtocolVersion == nil {
            state = .missingTools
        } else if !handshakeIsSupported {
            state = .incompatible
        } else {
            let requiredAgentFeaturesAreActive = features
                .filter { $0.required && $0.provider == .guestAgent }
                .allSatisfy { $0.state == .active }
            let requiredFeaturesAreActive = features
                .filter(\.required)
                .allSatisfy { $0.state == .active }
            if !requiredAgentFeaturesAreActive || runtimeAuthority == .requiresReplanning {
                state = .degraded
            } else if runtimeAuthority == .legacyCompatibility {
                state = .compatibility
            } else if !requiredFeaturesAreActive {
                state = .degraded
            } else {
                state = .healthy
            }
        }
        return Self(
            state: state,
            runtimeAuthority: runtimeAuthority,
            agentBuild: build,
            agentProtocolVersion: agentProtocolVersion,
            features: features
        )
    }

    private struct FeatureRequirement {
        var id: DoryGuestIntegrationCapabilityID
        var provider: DoryGuestIntegrationFeatureProvider
        var required: Bool
        var minimumVersion: UInt32?
        var agentCapabilityID: String?
    }

    private static func featureRequirements(
        desktopIntegrationsExpected: Bool,
        clipboardTextExpected: Bool,
        clipboardImageExpected: Bool,
        sharedFoldersExpected: Bool
    ) -> [FeatureRequirement] {
        var requirements: [FeatureRequirement] = [
            .init(id: .readiness, provider: .guestAgent, required: true,
                  minimumVersion: 1, agentCapabilityID: nil),
            .init(id: .clockSynchronization, provider: .guestAgent, required: true,
                  minimumVersion: 1, agentCapabilityID: "clock-sync"),
            .init(id: .processLaunch, provider: .guestAgent, required: true,
                  minimumVersion: 1, agentCapabilityID: "exec"),
            .init(id: .processInput, provider: .guestAgent, required: true,
                  minimumVersion: 1, agentCapabilityID: "exec-stdin"),
            .init(id: .listenPorts, provider: .guestAgent, required: true,
                  minimumVersion: 1, agentCapabilityID: "ports-watch"),
            .init(id: .telemetry, provider: .guestAgent, required: true,
                  minimumVersion: 1, agentCapabilityID: "telemetry"),
            .init(id: .fileTransferPull, provider: .guestAgent, required: false,
                  minimumVersion: 1, agentCapabilityID: "sync-pull"),
            .init(id: .fileTransferPush, provider: .guestAgent, required: false,
                  minimumVersion: 2, agentCapabilityID: "sync-push"),
            .init(id: .snapshotQuiesce, provider: .guestAgent, required: false,
                  minimumVersion: 2, agentCapabilityID: "snapshot-quiesce"),
            .init(id: .gracefulShutdown, provider: .resolvedRuntime, required: true,
                  minimumVersion: nil, agentCapabilityID: nil),
        ]
        if desktopIntegrationsExpected {
            requirements.append(.init(
                id: .displayResize, provider: .resolvedRuntime, required: true,
                minimumVersion: nil, agentCapabilityID: nil
            ))
        }
        if clipboardTextExpected {
            requirements.append(.init(
                id: .clipboardText, provider: .resolvedRuntime, required: true,
                minimumVersion: nil, agentCapabilityID: nil
            ))
        }
        if clipboardImageExpected {
            requirements.append(.init(
                id: .clipboardImage, provider: .resolvedRuntime, required: true,
                minimumVersion: nil, agentCapabilityID: nil
            ))
        }
        if sharedFoldersExpected {
            requirements.append(contentsOf: [
                .init(id: .sharedFolderDiscovery, provider: .resolvedRuntime, required: true,
                      minimumVersion: nil, agentCapabilityID: nil),
                .init(id: .sharedFolderMountStatus, provider: .resolvedRuntime, required: true,
                      minimumVersion: nil, agentCapabilityID: nil),
            ])
        }
        return requirements.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    private static func feature(
        _ requirement: FeatureRequirement,
        runtimeAuthority: DoryGuestIntegrationRuntimeAuthority,
        machineIsRunning: Bool,
        qualifiedRuntimeFeatures: Set<DoryGuestIntegrationCapabilityID>,
        supportedAgentProtocol: Bool,
        capabilities: [String: UInt32]
    ) -> DoryGuestIntegrationFeatureHealth {
        guard machineIsRunning else {
            return DoryGuestIntegrationFeatureHealth(
                id: requirement.id,
                provider: requirement.provider,
                required: requirement.required,
                minimumVersion: requirement.minimumVersion,
                state: .inactive
            )
        }
        switch requirement.provider {
        case .guestAgent:
            let negotiatedVersion: UInt32?
            if !supportedAgentProtocol {
                negotiatedVersion = nil
            } else if requirement.id == .readiness {
                negotiatedVersion = supportedAgentProtocol
                    ? supportedAgentProtocolVersion : nil
            } else {
                negotiatedVersion = requirement.agentCapabilityID.flatMap { capabilities[$0] }
            }
            let state: DoryGuestIntegrationFeatureState
            if !supportedAgentProtocol {
                state = .unavailable
            } else if let minimumVersion = requirement.minimumVersion,
                      let negotiatedVersion {
                state = negotiatedVersion >= minimumVersion ? .active : .updateRequired
            } else {
                state = .unavailable
            }
            return DoryGuestIntegrationFeatureHealth(
                id: requirement.id,
                provider: requirement.provider,
                required: requirement.required,
                minimumVersion: requirement.minimumVersion,
                negotiatedVersion: negotiatedVersion,
                state: state
            )
        case .resolvedRuntime:
            let state: DoryGuestIntegrationFeatureState
            switch runtimeAuthority {
            case .resolvedPlan:
                state = qualifiedRuntimeFeatures.contains(requirement.id)
                    ? .active : .unavailable
            case .requiresReplanning: state = .updateRequired
            case .legacyCompatibility: state = .unqualified
            }
            return DoryGuestIntegrationFeatureHealth(
                id: requirement.id,
                provider: requirement.provider,
                required: requirement.required,
                state: state
            )
        }
    }

    private static func isValidAgentBuild(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128
            && value.utf8.allSatisfy { $0 >= 0x20 && $0 <= 0x7e }
    }
}
