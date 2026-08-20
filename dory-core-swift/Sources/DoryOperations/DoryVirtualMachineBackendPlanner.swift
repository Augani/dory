public enum DoryVirtualMachineBackendPreferencePolicy: String, Codable, Sendable, CaseIterable, Hashable {
    /// Try the listed backends in order, then append Dory's automatic fallbacks.
    case preferred
    /// Evaluate only the listed backends, in the exact order supplied.
    case required
}

public struct DoryVirtualMachineBackendPlanRequest: Codable, Sendable, Equatable, Hashable {
    public var guest: DoryGuestPlatform
    public var bootMedia: DoryBootMedia
    /// Ordered graphics contracts the caller is willing to accept. A lower level is only a
    /// fallback when the caller includes it here explicitly.
    public var acceptableGraphics: [DoryGraphicsAccelerationLevel]
    public var devices: DoryVirtualMachineDeviceCapabilityRequest
    public var virtualHardwareABIVersion: UInt16
    /// An ordered backend preference. `nil` asks the planner to use guest/media defaults.
    public var backendPreferences: [DoryVirtualizationBackendIdentity]?
    public var backendPreferencePolicy: DoryVirtualMachineBackendPreferencePolicy
    public var allowsExperimentalBackends: Bool

    public init(
        guest: DoryGuestPlatform,
        bootMedia: DoryBootMedia,
        acceptableGraphics: [DoryGraphicsAccelerationLevel],
        devices: DoryVirtualMachineDeviceCapabilityRequest = .minimumBootable,
        virtualHardwareABIVersion: UInt16 = 1,
        backendPreferences: [DoryVirtualizationBackendIdentity]? = nil,
        backendPreferencePolicy: DoryVirtualMachineBackendPreferencePolicy = .preferred,
        allowsExperimentalBackends: Bool = false
    ) {
        self.guest = guest
        self.bootMedia = bootMedia
        self.acceptableGraphics = acceptableGraphics
        self.devices = devices
        self.virtualHardwareABIVersion = virtualHardwareABIVersion
        self.backendPreferences = backendPreferences
        self.backendPreferencePolicy = backendPreferencePolicy
        self.allowsExperimentalBackends = allowsExperimentalBackends
    }

    private enum CodingKeys: String, CodingKey {
        case guest
        case bootMedia
        case acceptableGraphics
        case devices
        case virtualHardwareABIVersion
        case backendPreferences
        case backendPreferencePolicy
        case allowsExperimentalBackends
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guest = try container.decode(DoryGuestPlatform.self, forKey: .guest)
        bootMedia = try container.decode(DoryBootMedia.self, forKey: .bootMedia)
        acceptableGraphics = try container.decode(
            [DoryGraphicsAccelerationLevel].self,
            forKey: .acceptableGraphics
        )
        devices = try container.decodeIfPresent(
            DoryVirtualMachineDeviceCapabilityRequest.self,
            forKey: .devices
        ) ?? .minimumBootable
        virtualHardwareABIVersion = try container.decodeIfPresent(
            UInt16.self,
            forKey: .virtualHardwareABIVersion
        ) ?? 1
        backendPreferences = try container.decodeIfPresent(
            [DoryVirtualizationBackendIdentity].self,
            forKey: .backendPreferences
        )
        backendPreferencePolicy = try container.decodeIfPresent(
            DoryVirtualMachineBackendPreferencePolicy.self,
            forKey: .backendPreferencePolicy
        ) ?? .preferred
        allowsExperimentalBackends = try container.decodeIfPresent(
            Bool.self,
            forKey: .allowsExperimentalBackends
        ) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(guest, forKey: .guest)
        try container.encode(bootMedia, forKey: .bootMedia)
        try container.encode(acceptableGraphics, forKey: .acceptableGraphics)
        try container.encode(devices, forKey: .devices)
        try container.encode(virtualHardwareABIVersion, forKey: .virtualHardwareABIVersion)
        try container.encodeIfPresent(backendPreferences, forKey: .backendPreferences)
        try container.encode(backendPreferencePolicy, forKey: .backendPreferencePolicy)
        try container.encode(allowsExperimentalBackends, forKey: .allowsExperimentalBackends)
    }
}

public enum DoryVirtualMachineBackendPlanningFailureCode: String, Codable, Sendable, Hashable {
    case invalidPreference = "invalid-preference"
    case noCandidate = "no-candidate"
}

public enum DoryVirtualMachineBackendPreferenceField: String, Codable, Sendable, Hashable {
    case graphics
    case backend
}

public enum DoryVirtualMachineBackendPreferenceIssue: String, Codable, Sendable, Hashable {
    case empty
    case duplicate
    case missing
}

public struct DoryVirtualMachineBackendPlanningFailure: Codable, Sendable, Equatable, Hashable {
    public var code: DoryVirtualMachineBackendPlanningFailureCode
    public var preferenceField: DoryVirtualMachineBackendPreferenceField?
    public var preferenceIssue: DoryVirtualMachineBackendPreferenceIssue?
    public var message: String

    public init(
        code: DoryVirtualMachineBackendPlanningFailureCode,
        preferenceField: DoryVirtualMachineBackendPreferenceField? = nil,
        preferenceIssue: DoryVirtualMachineBackendPreferenceIssue? = nil,
        message: String
    ) {
        self.code = code
        self.preferenceField = preferenceField
        self.preferenceIssue = preferenceIssue
        self.message = message
    }
}

/// A complete planning result. Failed plans retain every descriptor the evaluator considered so
/// callers can explain missing components and unsupported combinations without re-running policy.
public struct DoryVirtualMachineBackendPlanResult: Codable, Sendable, Equatable, Hashable {
    public var selectedDescriptor: DoryVirtualMachineCapabilityDescriptor?
    public var evaluatedDescriptors: [DoryVirtualMachineCapabilityDescriptor]
    public var failure: DoryVirtualMachineBackendPlanningFailure?

    public var isSuccess: Bool {
        selectedDescriptor != nil && failure == nil
    }

    public init(
        selectedDescriptor: DoryVirtualMachineCapabilityDescriptor?,
        evaluatedDescriptors: [DoryVirtualMachineCapabilityDescriptor],
        failure: DoryVirtualMachineBackendPlanningFailure?
    ) {
        self.selectedDescriptor = selectedDescriptor
        self.evaluatedDescriptors = evaluatedDescriptors
        self.failure = failure
    }
}

/// Pure backend selection for Apple Silicon. Host discovery belongs to the daemon; this planner
/// consumes its immutable facts and performs no I/O or framework probing.
public enum DoryAppleSiliconVirtualMachineBackendPlanner {
    public static func plan(
        _ request: DoryVirtualMachineBackendPlanRequest,
        host: DoryAppleSiliconHostFacts,
        trustedGuestImageGraphicsQualification: DoryTrustedGuestImageGraphicsQualification? = nil,
        trustedBootMediaInspection: DoryTrustedBootMediaInspection? = nil,
        trustedMutableBootMediaProvenance: DoryTrustedMutableBootMediaProvenance? = nil,
        trustedRuntimeQualifications: [DoryTrustedVirtualMachineRuntimeQualification] = [],
        trustedCapabilityQualifications:
            [DoryTrustedVirtualMachineCapabilityQualification] = []
    ) -> DoryVirtualMachineBackendPlanResult {
        if request.acceptableGraphics.isEmpty {
            return invalidPreference(
                field: .graphics,
                issue: .empty,
                message: "At least one acceptable graphics level is required."
            )
        }
        if hasDuplicates(request.acceptableGraphics) {
            return invalidPreference(
                field: .graphics,
                issue: .duplicate,
                message: "Acceptable graphics levels must not contain duplicates."
            )
        }
        if let backendPreferences = request.backendPreferences {
            if backendPreferences.isEmpty {
                return invalidPreference(
                    field: .backend,
                    issue: .empty,
                    message: "An explicit backend preference list must not be empty."
                )
            }
            if hasDuplicates(backendPreferences) {
                return invalidPreference(
                    field: .backend,
                    issue: .duplicate,
                    message: "Backend preferences must not contain duplicates."
                )
            }
        } else if request.backendPreferencePolicy == .required {
            return invalidPreference(
                field: .backend,
                issue: .missing,
                message: "Required backend policy needs at least one backend."
            )
        }

        let defaults = defaultBackends(for: request.guest, bootMedia: request.bootMedia.kind)
        let backends: [DoryVirtualizationBackendIdentity]
        if let preferences = request.backendPreferences {
            switch request.backendPreferencePolicy {
            case .preferred:
                backends = orderedUnique(preferences + defaults)
            case .required:
                backends = preferences
            }
        } else {
            backends = defaults
        }
        var evaluated: [DoryVirtualMachineCapabilityDescriptor] = []
        evaluated.reserveCapacity(request.acceptableGraphics.count * backends.count)

        for graphics in request.acceptableGraphics {
            for backend in backends {
                let capabilityRequest = DoryVirtualMachineCapabilityRequest(
                    guest: request.guest,
                    bootMedia: request.bootMedia,
                    backend: backend,
                    graphics: graphics,
                    devices: request.devices,
                    virtualHardwareABIVersion: request.virtualHardwareABIVersion
                )
                let exactQualification = matchingCapabilityQualification(
                    for: capabilityRequest,
                    host: host,
                    in: trustedCapabilityQualifications
                )
                evaluated.append(DoryAppleSiliconCapabilityEvaluator.evaluate(
                    capabilityRequest,
                    host: host,
                    trustedGuestImageGraphicsQualification:
                        exactQualification?.graphics
                            ?? (trustedCapabilityQualifications.isEmpty
                                ? trustedGuestImageGraphicsQualification : nil),
                    trustedBootMediaInspection: trustedBootMediaInspection,
                    trustedMutableBootMediaProvenance: trustedMutableBootMediaProvenance,
                    trustedRuntimeQualification: exactQualification?.runtime
                        ?? (trustedCapabilityQualifications.isEmpty
                            ? matchingRuntimeQualification(
                                for: capabilityRequest,
                                host: host,
                                in: trustedRuntimeQualifications
                            ) : nil)
                ))
            }
        }

        let selected = evaluated.first { descriptor in
            guard descriptor.availability.isUsable else { return false }
            return descriptor.availability.supportTier == .supported
                || (request.allowsExperimentalBackends
                    && descriptor.availability.supportTier == .experimental)
        }

        if let selected {
            return DoryVirtualMachineBackendPlanResult(
                selectedDescriptor: selected,
                evaluatedDescriptors: evaluated,
                failure: nil
            )
        }

        return DoryVirtualMachineBackendPlanResult(
            selectedDescriptor: nil,
            evaluatedDescriptors: evaluated,
            failure: DoryVirtualMachineBackendPlanningFailure(
                code: .noCandidate,
                message: request.allowsExperimentalBackends
                    ? "No evaluated configuration satisfies the requested guest, media, and graphics contracts."
                    : "No supported configuration satisfies the request; experimental backends were not allowed."
            )
        )
    }

    public static func defaultBackends(
        for guest: DoryGuestPlatform,
        bootMedia: DoryBootMediaKind
    ) -> [DoryVirtualizationBackendIdentity] {
        switch (guest.family, bootMedia) {
        case (.linux, .installedLinuxBootBundle):
            return [.doryHypervisor]
        case (.linux, _):
            return [.appleVirtualizationFramework, .qemuHypervisorFramework]
        case (.macOS, _):
            return [.appleVirtualizationFramework]
        case (.windows, _):
            return [.qemuHypervisorFramework]
        }
    }

    private static func hasDuplicates<Value: Hashable>(_ values: [Value]) -> Bool {
        Set(values).count != values.count
    }

    private static func orderedUnique<Value: Hashable>(_ values: [Value]) -> [Value] {
        var seen: Set<Value> = []
        return values.filter { seen.insert($0).inserted }
    }

    private static func matchingRuntimeQualification(
        for request: DoryVirtualMachineCapabilityRequest,
        host: DoryAppleSiliconHostFacts,
        in qualifications: [DoryTrustedVirtualMachineRuntimeQualification]
    ) -> DoryTrustedVirtualMachineRuntimeQualification? {
        guard let hostContext = host.runtimeQualificationContext else { return nil }
        return qualifications.first { qualification in
            let evidence = qualification.auditEvidence
            guard evidence.guest == request.guest
                && evidence.bootMediaKind == request.bootMedia.kind
                && evidence.backend == request.backend
                && evidence.backendRuntimeBuildID == hostContext.runtimeBuildID(for: request.backend)
                && evidence.graphics == request.graphics
                && evidence.devices == request.devices
                && evidence.virtualHardwareABIVersion == request.virtualHardwareABIVersion
                && evidence.virtualHardwareABIVersion == hostContext.virtualHardwareABIVersion else {
                return false
            }
            if request.bootMedia.kind == .virtualDisk {
                return evidence.immutableArtifactSHA256 == nil
                    && evidence.mutableProvenance == request.bootMedia.mutableProvenance
            }
            guard let requestDigest = request.bootMedia.artifactSHA256,
                  let evidenceDigest = evidence.immutableArtifactSHA256 else {
                return false
            }
            return evidence.mutableProvenance == nil
                && evidenceDigest.lowercased() == requestDigest.lowercased()
        }
    }

    private static func matchingCapabilityQualification(
        for request: DoryVirtualMachineCapabilityRequest,
        host: DoryAppleSiliconHostFacts,
        in qualifications: [DoryTrustedVirtualMachineCapabilityQualification]
    ) -> DoryTrustedVirtualMachineCapabilityQualification? {
        guard let hostContext = host.runtimeQualificationContext else { return nil }
        let matches = qualifications.filter { qualification in
            guard qualification.request == request else { return false }
            let evidence = qualification.runtime.auditEvidence
            return evidence.backendRuntimeBuildID
                == hostContext.runtimeBuildID(for: request.backend)
                && evidence.virtualHardwareABIVersion
                    == hostContext.virtualHardwareABIVersion
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func invalidPreference(
        field: DoryVirtualMachineBackendPreferenceField,
        issue: DoryVirtualMachineBackendPreferenceIssue,
        message: String
    ) -> DoryVirtualMachineBackendPlanResult {
        DoryVirtualMachineBackendPlanResult(
            selectedDescriptor: nil,
            evaluatedDescriptors: [],
            failure: DoryVirtualMachineBackendPlanningFailure(
                code: .invalidPreference,
                preferenceField: field,
                preferenceIssue: issue,
                message: message
            )
        )
    }
}
