@preconcurrency import Foundation
@preconcurrency import Security
import DoryOperations

@objc(DorydHealthControl)
nonisolated protocol DorydControlXPC {
    func protocolVersion(reply: @escaping (UInt32) -> Void)
    func dorySocketPath(reply: @escaping (String) -> Void)
    func engineStatus(reply: @escaping (String, String) -> Void)
    func engineStart(reply: @escaping (Bool, String) -> Void)
    func engineStop(reply: @escaping (Bool, String) -> Void)
    func engineSleep(reply: @escaping (Bool, String) -> Void)
    func engineWake(reply: @escaping (Bool, String) -> Void)
    func dockerAgentInfo(reply: @escaping (NSDictionary, String) -> Void)
    func dockerAgentPorts(reply: @escaping (NSDictionary, String) -> Void)
    func dockerAgentTelemetry(reply: @escaping (NSDictionary, String) -> Void)
    func machineCreate(_ config: NSDictionary, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func machineStart(_ machineID: String, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func machineStop(_ machineID: String, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func machinePause(_ machineID: String, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func machineResume(_ machineID: String, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func machineRestart(_ machineID: String, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func machineUpdate(_ machineID: String, config: NSDictionary, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func machineDelete(_ machineID: String, reply: @escaping (Bool, String) -> Void)
    func machineList(reply: @escaping (NSArray, String) -> Void)
    func machineStats(_ machineID: String, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func machineExec(_ machineID: String, request: NSDictionary, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func machineProvision(_ machineID: String, request: NSDictionary, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func machineDesktopUpdate(_ machineID: String, request: NSDictionary, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func machineSnapshot(_ machineID: String, request: NSDictionary, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func machineSnapshots(_ machineID: String, reply: @escaping (NSArray, String) -> Void)
    func machineCloneSnapshot(_ machineID: String, snapshotID: String, newID: String, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func machineRestoreSnapshot(_ machineID: String, snapshotID: String, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func machineDeleteSnapshot(_ machineID: String, snapshotID: String, reply: @escaping (Bool, String) -> Void)
    func machineExportSnapshot(_ machineID: String, snapshotID: String, path: String, reply: @escaping (Bool, String) -> Void)
    func machineImportSnapshot(_ path: String, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func machineBackupSchedules(reply: @escaping (NSArray, String) -> Void)
    func machineBackupSet(_ schedule: NSDictionary, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func machineBackupRemove(_ machineID: String, reply: @escaping (Bool, String) -> Void)
    func machineBackupRun(_ machineID: String, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func remoteConnect(_ config: NSDictionary, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func remotePush(_ machineID: String, localRoot: String, remoteRoot: String, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func remoteStatus(_ machineID: String, reply: @escaping (NSDictionary, String) -> Void)
    func networkReplaceRoutes(_ routes: NSArray, reply: @escaping (Bool, String) -> Void)
    func networkStatus(reply: @escaping (NSDictionary, String) -> Void)
    func networkAuthorizationPlan(reply: @escaping (NSDictionary, String) -> Void)
    func corporateConnectivityStatus(_ runProbes: Bool, reply: @escaping (String, String) -> Void)
    func corporateConnectivityApply(_ profileJSON: String, dryRun: Bool, reply: @escaping (String, String) -> Void)
    func corporateConnectivityDisable(reply: @escaping (String, String) -> Void)
    func repairSubsystem(_ target: String, reply: @escaping (Bool, String) -> Void)
    func balloonStatus(reply: @escaping (NSDictionary, String) -> Void)
    func balloonReconcile(reply: @escaping (NSDictionary, String) -> Void)
    func idleStatus(reply: @escaping (NSDictionary, String) -> Void)
    func idleHistory(_ limit: Int, reply: @escaping (NSArray, String) -> Void)
    func idleSetMode(_ mode: String, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func idleSetPolicy(_ key: String, value: String, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func health(reply: @escaping (NSDictionary, String) -> Void)
    func doctorJSON(reply: @escaping (String, String) -> Void)
    func incidents(_ limit: Int, reply: @escaping (NSArray, String) -> Void)
}

nonisolated struct DorydEngineStatus: Sendable, Equatable {
    var state: String
    var detail: String

    var isRunning: Bool { state == "running" }
}

nonisolated struct DorydCommandResult: Sendable, Equatable {
    var ok: Bool
    var message: String
}

nonisolated struct DorydMachineShareConfiguration: Sendable, Equatable {
    var tag: String
    var hostPath: String
    var guestPath: String
    var readOnly: Bool

    var xpcDictionary: NSDictionary {
        [
            "tag": tag,
            "hostPath": hostPath,
            "guestPath": guestPath,
            "readOnly": readOnly,
        ]
    }
}

nonisolated struct DorydMachineTypedSettings: Sendable, Equatable, Hashable {
    var guestIdentityIntent: DoryVMGuestIdentityIntent = .unspecified
    var clipboardPolicy: DoryVMClipboardPolicy? = nil
    var runtimePreference: DoryDesktopVMMPreference? = nil
    var graphicsPreference: DoryDesktopGraphicsPreference? = nil

    init(
        guestIdentityIntent: DoryVMGuestIdentityIntent = .unspecified,
        clipboardPolicy: DoryVMClipboardPolicy? = nil,
        runtimePreference: DoryDesktopVMMPreference? = nil,
        graphicsPreference: DoryDesktopGraphicsPreference? = nil
    ) {
        self.guestIdentityIntent = guestIdentityIntent
        self.clipboardPolicy = clipboardPolicy
        self.runtimePreference = runtimePreference
        self.graphicsPreference = graphicsPreference
    }

    init(legacyEnvironment: [String: String], displayMode: MachineDisplayMode) {
        let username = legacyEnvironment[DoryVMGuestAccountIntent.legacyUsernameEnvironmentKey]
            .flatMap { DoryVMGuestAccountIntent.isValidUsername($0) ? $0 : nil }
        let numericUserID = legacyEnvironment[
            DoryVMGuestAccountIntent.legacyNumericUserIDEnvironmentKey
        ].flatMap(UInt32.init).flatMap {
            DoryVMGuestAccountIntent.isValidNumericUserID($0) ? $0 : nil
        }
        let account = DoryVMGuestAccountIntent(username: username, numericUserID: numericUserID)
        let desktop: DoryVMDesktopIdentityIntent?
        if displayMode == .desktop {
            func safeLabel(_ key: String) -> String? {
                legacyEnvironment[key].flatMap {
                    DoryVMDesktopIdentityIntent.isValidLabel($0) ? $0 : nil
                }
            }
            let distribution = legacyEnvironment[
                DoryVMDesktopIdentityIntent.legacyDistributionEnvironmentKey
            ].flatMap {
                DoryVMDesktopIdentityIntent.isValidDistributionIdentifier($0) ? $0 : nil
            }
            let candidate = DoryVMDesktopIdentityIntent(
                distributionIdentifier: distribution,
                displayName: safeLabel(DoryVMDesktopIdentityIntent.legacyDisplayNameEnvironmentKey),
                version: safeLabel(DoryVMDesktopIdentityIntent.legacyVersionEnvironmentKey),
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
        if displayMode == .desktop {
            let effectiveClipboard = DoryDesktopClipboardPolicy(
                environment: legacyEnvironment
            )
            clipboardPolicy = DoryVMClipboardDirection(
                rawValue: effectiveClipboard.rawValue
            ).map(DoryVMClipboardPolicy.legacyDesktop)
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

    var isEmpty: Bool {
        guestIdentityIntent.isEmpty
            && clipboardPolicy == nil
            && runtimePreference == nil
            && graphicsPreference == nil
    }

    var xpcDictionary: NSDictionary {
        var result: [String: Any] = [:]
        var identity: [String: Any] = [:]
        if let account = guestIdentityIntent.account, !account.isEmpty {
            var value: [String: Any] = [:]
            if let username = account.username { value["username"] = username }
            if let numericUserID = account.numericUserID {
                value["numericUserID"] = numericUserID
            }
            identity["account"] = value as NSDictionary
        }
        if let desktop = guestIdentityIntent.desktop, !desktop.isEmpty {
            var value: [String: Any] = [:]
            if let distributionIdentifier = desktop.distributionIdentifier {
                value["distributionIdentifier"] = distributionIdentifier
            }
            if let displayName = desktop.displayName { value["displayName"] = displayName }
            if let version = desktop.version { value["version"] = version }
            if let desktopEnvironment = desktop.desktopEnvironment {
                value["desktopEnvironment"] = desktopEnvironment
            }
            identity["desktop"] = value as NSDictionary
        }
        if !identity.isEmpty { result["guestIdentityIntent"] = identity as NSDictionary }
        if let clipboardPolicy {
            result["clipboardPolicy"] = [
                "text": clipboardPolicy.text.rawValue,
                "image": clipboardPolicy.image.rawValue,
                "files": clipboardPolicy.files.rawValue,
            ] as NSDictionary
        }
        if let runtimePreference {
            result["desktopRuntimePreference"] = runtimePreference.rawValue
        }
        if let graphicsPreference {
            result["desktopGraphicsPreference"] = graphicsPreference.rawValue
        }
        return result as NSDictionary
    }

    func hash(into hasher: inout Hasher) {
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
    }
}

/// Leaf-level update authority. Comparing a safely migrated baseline to the desired typed state
/// means an unrelated edit never clears an opaque or invalid legacy value that was intentionally
/// omitted during migration.
nonisolated struct DorydMachineTypedSettingsPatch: Sendable, Equatable {
    var baseline: DorydMachineTypedSettings
    var desired: DorydMachineTypedSettings

    var isEmpty: Bool { xpcDictionary.count == 0 }

    var xpcDictionary: NSDictionary {
        var result: [String: Any] = [:]
        var account: [String: Any] = [:]
        Self.encode(
            baseline.guestIdentityIntent.account?.username,
            desired.guestIdentityIntent.account?.username,
            key: "username",
            into: &account
        )
        Self.encode(
            baseline.guestIdentityIntent.account?.numericUserID,
            desired.guestIdentityIntent.account?.numericUserID,
            key: "numericUserID",
            into: &account
        )
        var desktop: [String: Any] = [:]
        Self.encode(
            baseline.guestIdentityIntent.desktop?.distributionIdentifier,
            desired.guestIdentityIntent.desktop?.distributionIdentifier,
            key: "distributionIdentifier",
            into: &desktop
        )
        Self.encode(
            baseline.guestIdentityIntent.desktop?.displayName,
            desired.guestIdentityIntent.desktop?.displayName,
            key: "displayName",
            into: &desktop
        )
        Self.encode(
            baseline.guestIdentityIntent.desktop?.version,
            desired.guestIdentityIntent.desktop?.version,
            key: "version",
            into: &desktop
        )
        Self.encode(
            baseline.guestIdentityIntent.desktop?.desktopEnvironment,
            desired.guestIdentityIntent.desktop?.desktopEnvironment,
            key: "desktopEnvironment",
            into: &desktop
        )
        if !account.isEmpty || !desktop.isEmpty {
            var identity: [String: Any] = [:]
            if !account.isEmpty { identity["account"] = account as NSDictionary }
            if !desktop.isEmpty { identity["desktop"] = desktop as NSDictionary }
            result["guestIdentityIntent"] = identity as NSDictionary
        }
        Self.encodePolicy(
            baseline.clipboardPolicy,
            desired.clipboardPolicy,
            into: &result
        )
        Self.encodeEnum(
            baseline.runtimePreference,
            desired.runtimePreference,
            key: "desktopRuntimePreference",
            into: &result
        )
        Self.encodeEnum(
            baseline.graphicsPreference,
            desired.graphicsPreference,
            key: "desktopGraphicsPreference",
            into: &result
        )
        return result as NSDictionary
    }

    private static func encode<Value: Equatable>(
        _ baseline: Value?,
        _ desired: Value?,
        key: String,
        into dictionary: inout [String: Any]
    ) {
        guard baseline != desired else { return }
        dictionary[key] = desired ?? NSNull()
    }

    private static func encodePolicy(
        _ baseline: DoryVMClipboardPolicy?,
        _ desired: DoryVMClipboardPolicy?,
        into dictionary: inout [String: Any]
    ) {
        guard baseline != desired else { return }
        guard let desired else {
            dictionary["clipboardPolicy"] = NSNull()
            return
        }
        dictionary["clipboardPolicy"] = [
            "text": desired.text.rawValue,
            "image": desired.image.rawValue,
            "files": desired.files.rawValue,
        ] as NSDictionary
    }

    private static func encodeEnum<Value: RawRepresentable & Equatable>(
        _ baseline: Value?,
        _ desired: Value?,
        key: String,
        into dictionary: inout [String: Any]
    ) where Value.RawValue == String {
        guard baseline != desired else { return }
        dictionary[key] = desired?.rawValue ?? NSNull()
    }
}

nonisolated struct DorydMachineConfiguration: Sendable, Equatable {
    var id: String
    var kernelPath: String
    var rootfsPath: String
    var bootMode: MachineBootMode = .linuxKernel
    var installerISOPath: String? = nil
    var diskSizeBytes: UInt64? = nil
    var memoryMB: UInt64
    var cpuCount: Int
    var address: String? = nil
    var displayMode: MachineDisplayMode = .headless
    var shares: [DorydMachineShareConfiguration] = []
    var typedSettings: DorydMachineTypedSettings = DorydMachineTypedSettings()

    var xpcDictionary: NSDictionary {
        var dictionary: [String: Any] = [
            "id": id,
            "kernelPath": kernelPath,
            "rootfsPath": rootfsPath,
            "bootMode": bootMode.rawValue,
            "memoryMB": memoryMB,
            "cpuCount": cpuCount,
            "displayMode": displayMode.rawValue,
        ]
        if let address {
            dictionary["address"] = address
        }
        if let installerISOPath {
            dictionary["installerISOPath"] = installerISOPath
        }
        if let diskSizeBytes {
            dictionary["diskSizeBytes"] = diskSizeBytes
        }
        if !shares.isEmpty {
            dictionary["shares"] = shares.map(\.xpcDictionary)
        }
        for (rawKey, value) in typedSettings.xpcDictionary {
            if let key = rawKey as? String { dictionary[key] = value }
        }
        return dictionary as NSDictionary
    }
}

nonisolated struct DorydMachineRuntimeComponentIdentity: Codable, Sendable, Equatable, Hashable {
    var componentIdentifier: String
    var buildIdentifier: String
    var artifactSHA256: String
}

nonisolated struct DorydMachineRuntimeBootMediaIdentity: Codable, Sendable, Equatable, Hashable {
    var kind: String
    var source: String
    var artifactSHA256: String? = nil
    var resolverNamespace: String? = nil
    var resolverIdentifier: String? = nil
    var inspectionIdentity: String? = nil
    var inspectionReportSHA256: String? = nil
    var provenanceReceiptIdentity: String? = nil
    var provenanceReceiptSHA256: String? = nil
    var provenanceRevision: UInt64? = nil
}

nonisolated struct DorydMachineRuntimeQualificationReference: Codable, Sendable, Equatable, Hashable {
    var manifestIdentity: String? = nil
    var artifactSHA256: String? = nil
    var manifestSHA256: String? = nil
    var qualificationIdentity: String? = nil
    var qualificationReportSHA256: String? = nil
    var signingKeyID: String? = nil
    var qualifierIdentifier: String? = nil

    var isValidGraphicsReference: Bool {
        manifestIdentity?.isSafeEvidenceIdentifier == true
            && artifactSHA256?.isLowercaseSHA256 == true
            && manifestSHA256?.isLowercaseSHA256 == true
            && signingKeyID?.isSafeEvidenceIdentifier == true
            && qualificationIdentity == nil
            && qualificationReportSHA256 == nil
            && qualifierIdentifier == nil
    }

    var isValidRuntimeReference: Bool {
        qualificationIdentity?.isSafeEvidenceIdentifier == true
            && qualificationReportSHA256?.isLowercaseSHA256 == true
            && signingKeyID?.isSafeEvidenceIdentifier == true
            && manifestIdentity == nil
            && artifactSHA256 == nil
            && manifestSHA256 == nil
            && qualifierIdentifier == nil
    }

    var isValidHostReference: Bool {
        qualificationIdentity?.isSafeEvidenceIdentifier == true
            && qualificationReportSHA256?.isLowercaseSHA256 == true
            && qualifierIdentifier?.isSafeEvidenceIdentifier == true
            && manifestIdentity == nil
            && artifactSHA256 == nil
            && manifestSHA256 == nil
            && signingKeyID == nil
    }
}

nonisolated struct DorydMachineRuntimeIdentity: Codable, Sendable, Equatable, Hashable {
    static let currentSchemaVersion: UInt16 = 1
    var schemaVersion: UInt16
    var mode: String
    var virtualHardwareABIVersion: UInt16
    var invalidationReason: String? = nil
    var definitionRevision: UInt64? = nil
    var definitionSHA256: String? = nil
    var planRevision: UInt64? = nil
    var planSHA256: String? = nil
    var backend: String? = nil
    var backendImplementationIdentifier: String? = nil
    var backendRuntimeBuildIdentifier: String? = nil
    var supportTier: String? = nil
    var graphics: String? = nil
    var selectionDisposition: String? = nil
    var fallbackAuthorizationIdentity: String? = nil
    var experimentalAuthorizationIdentity: String? = nil
    var graphicsQualification: DorydMachineRuntimeQualificationReference? = nil
    var runtimeQualification: DorydMachineRuntimeQualificationReference? = nil
    var hostQualification: DorydMachineRuntimeQualificationReference? = nil
    var components: [DorydMachineRuntimeComponentIdentity]? = nil
    var bootMedia: DorydMachineRuntimeBootMediaIdentity? = nil

    static let legacyCompatibility = Self(
        schemaVersion: currentSchemaVersion,
        mode: "legacy-compatibility",
        virtualHardwareABIVersion: 1
    )

    var isValid: Bool {
        guard schemaVersion == Self.currentSchemaVersion,
              virtualHardwareABIVersion > 0 else {
            return false
        }
        switch mode {
        case "legacy-compatibility":
            return invalidationReason == nil && hasNoResolvedEvidence
        case "requires-replanning":
            return invalidationReason?.isSafeEvidenceIdentifier == true
                && hasNoResolvedEvidence
        case "resolved-plan":
            return isValidResolvedEvidence
        default:
            return false
        }
    }

    private var hasNoResolvedEvidence: Bool {
        definitionRevision == nil
            && definitionSHA256 == nil
            && planRevision == nil
            && planSHA256 == nil
            && backend == nil
            && backendImplementationIdentifier == nil
            && backendRuntimeBuildIdentifier == nil
            && supportTier == nil
            && graphics == nil
            && selectionDisposition == nil
            && fallbackAuthorizationIdentity == nil
            && experimentalAuthorizationIdentity == nil
            && graphicsQualification == nil
            && runtimeQualification == nil
            && hostQualification == nil
            && components == nil
            && bootMedia == nil
    }

    private var isValidResolvedEvidence: Bool {
        guard invalidationReason == nil,
              let definitionRevision, definitionRevision > 0,
              definitionSHA256?.isLowercaseSHA256 == true,
              let planRevision, planRevision > 0,
              planSHA256?.isLowercaseSHA256 == true,
              backend?.isSafeEvidenceIdentifier == true,
              backendImplementationIdentifier?.isSafeEvidenceIdentifier == true,
              backendRuntimeBuildIdentifier?.isSafeEvidenceIdentifier == true,
              let supportTier,
              let graphics,
              ["none", "software", "host-accelerated-display", "hardware-accelerated-3d"]
                .contains(graphics),
              let selectionDisposition,
              ["primary", "explicit-alternative", "approved-fallback"]
                .contains(selectionDisposition),
              let components, !components.isEmpty,
              Set(components.map(\.componentIdentifier)).count == components.count,
              components.allSatisfy({ component in
                  component.componentIdentifier.isSafeEvidenceIdentifier
                      && component.buildIdentifier.isSafeEvidenceIdentifier
                      && component.artifactSHA256.isLowercaseSHA256
              }),
              let bootMedia, bootMedia.isValid else {
            return false
        }
        if let graphicsQualification, !graphicsQualification.isValidGraphicsReference {
            return false
        }
        guard hostQualification?.isValidHostReference == true else { return false }
        switch supportTier {
        case "supported":
            guard runtimeQualification?.isValidRuntimeReference == true,
                  experimentalAuthorizationIdentity == nil else {
                return false
            }
        case "experimental":
            guard experimentalAuthorizationIdentity?.isSafeEvidenceIdentifier == true,
                  runtimeQualification.map(\.isValidRuntimeReference) ?? true else {
                return false
            }
        default:
            return false
        }
        switch selectionDisposition {
        case "approved-fallback":
            return fallbackAuthorizationIdentity?.isSafeEvidenceIdentifier == true
        case "primary", "explicit-alternative":
            return fallbackAuthorizationIdentity == nil
        default:
            return false
        }
    }
}

nonisolated private extension String {
    var isLowercaseSHA256: Bool {
        utf8.count == 64 && utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }

    var isSafeEvidenceIdentifier: Bool {
        let bytes = Array(utf8)
        guard (1...256).contains(bytes.count) else { return false }
        return bytes.allSatisfy { byte in
            (byte >= 48 && byte <= 57)
                || (byte >= 65 && byte <= 90)
                || (byte >= 97 && byte <= 122)
                || byte == 45 || byte == 46 || byte == 47
                || byte == 58 || byte == 64 || byte == 95
        }
    }

    var isSafeComponentInstallationName: Bool {
        let bytes = Array(utf8)
        guard (1...255).contains(bytes.count),
              let first = bytes.first,
              (first >= 48 && first <= 57)
                || (first >= 65 && first <= 90)
                || (first >= 97 && first <= 122) else {
            return false
        }
        return bytes.dropFirst().allSatisfy { byte in
            (byte >= 48 && byte <= 57)
                || (byte >= 65 && byte <= 90)
                || (byte >= 97 && byte <= 122)
                || byte == 43 || byte == 45 || byte == 46 || byte == 95
        }
    }
}

nonisolated struct DorydInstalledDesktopPayloadReceipt: Codable, Sendable, Equatable, Hashable {
    var schemaVersion: UInt16
    var provenance: String
    var distributionIdentifier: String
    var releaseVersion: String
    var inputSHA256: String
    var bundleSHA256: String?
    var distributionComponentIdentifier: String?
    var distributionInstallationName: String?
    var distributionCatalogSHA256: String?
    var bundleAssetIdentifier: String?
    var runtimeComponentIdentifier: String?
    var runtimeInstallationName: String?
    var runtimeCatalogSHA256: String?
    var kernelAssetIdentifier: String?
    var kernelSHA256: String?

    var isValid: Bool {
        guard schemaVersion == 1,
              ["debian", "kali", "ubuntu"].contains(distributionIdentifier),
              releaseVersion.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9._+-]{0,127}/) != nil,
              inputSHA256.isLowercaseSHA256 else {
            return false
        }
        switch provenance {
        case "legacy-environment":
            return verifiedAuthorityFieldsAreNil
        case "legacy-snapshot-migration":
            return verifiedAuthorityFieldsAreNil
        case "verified-update-bundle":
            return bundleSHA256?.isLowercaseSHA256 == true
                && kernelSHA256?.isLowercaseSHA256 == true
                && distributionComponentIdentifier == "desktop-" + distributionIdentifier
                && distributionInstallationName?.isSafeComponentInstallationName == true
                && distributionCatalogSHA256?.isLowercaseSHA256 == true
                && bundleAssetIdentifier
                    == "dory-desktop-" + distributionIdentifier + "-update-arm64.tar"
                && runtimeComponentIdentifier == "linux-desktop"
                && runtimeInstallationName?.isSafeComponentInstallationName == true
                && runtimeCatalogSHA256?.isLowercaseSHA256 == true
                && kernelAssetIdentifier == "dory-desktop-kernel-arm64.lzfse"
        default:
            return false
        }
    }

    private var verifiedAuthorityFieldsAreNil: Bool {
        bundleSHA256 == nil
            && distributionComponentIdentifier == nil
            && distributionInstallationName == nil
            && distributionCatalogSHA256 == nil
            && bundleAssetIdentifier == nil
            && runtimeComponentIdentifier == nil
            && runtimeInstallationName == nil
            && runtimeCatalogSHA256 == nil
            && kernelAssetIdentifier == nil
            && kernelSHA256 == nil
    }

    static func legacyEnvironment(_ environment: [String: String]) -> Self? {
        guard let distributionIdentifier = environment["DORY_DESKTOP_DISTRO"],
              let releaseVersion = environment["DORY_DESKTOP_RELEASE_VERSION"],
              let inputSHA256 = environment["DORY_DESKTOP_INPUT_SHA256"] else {
            return nil
        }
        let receipt = Self(
            schemaVersion: 1,
            provenance: "legacy-environment",
            distributionIdentifier: distributionIdentifier,
            releaseVersion: releaseVersion,
            inputSHA256: inputSHA256,
            bundleSHA256: nil,
            distributionComponentIdentifier: nil,
            distributionInstallationName: nil,
            distributionCatalogSHA256: nil,
            bundleAssetIdentifier: nil,
            runtimeComponentIdentifier: nil,
            runtimeInstallationName: nil,
            runtimeCatalogSHA256: nil,
            kernelAssetIdentifier: nil,
            kernelSHA256: nil
        )
        return receipt.isValid ? receipt : nil
    }
}

nonisolated private extension DorydMachineRuntimeBootMediaIdentity {
    var isValid: Bool {
        let immutableKinds = [
            "installer-iso",
            "installed-linux-boot-bundle",
            "macos-restore-image",
        ]
        guard immutableKinds.contains(kind) || kind == "virtual-disk",
              ["dory-bundled", "vendor-download", "user-provided"].contains(source) else {
            return false
        }
        let immutable = artifactSHA256?.isLowercaseSHA256 == true
        let mutable = provenanceReceiptIdentity?.isSafeEvidenceIdentifier == true
            && provenanceReceiptSHA256?.isLowercaseSHA256 == true
            && (provenanceRevision ?? 0) > 0
        let hasAnyMutableField = provenanceReceiptIdentity != nil
            || provenanceReceiptSHA256 != nil
            || provenanceRevision != nil
        guard immutable != mutable,
              hasAnyMutableField == mutable,
              (kind == "virtual-disk") == mutable else {
            return false
        }
        guard (resolverNamespace == nil) == (resolverIdentifier == nil),
              resolverNamespace.map(\.isSafeEvidenceIdentifier) ?? true,
              resolverIdentifier.map(\.isSafeEvidenceIdentifier) ?? true,
              (inspectionIdentity == nil) == (inspectionReportSHA256 == nil),
              inspectionIdentity.map(\.isSafeEvidenceIdentifier) ?? true,
              inspectionReportSHA256.map(\.isLowercaseSHA256) ?? true else {
            return false
        }
        if kind == "installer-iso" || kind == "macos-restore-image" {
            guard inspectionIdentity != nil else { return false }
        }
        return true
    }
}

nonisolated struct DorydMachineSnapshotArtifact: Codable, Sendable, Equatable, Hashable {
    var byteCount: UInt64
    var sha256: String

    var isValid: Bool { byteCount > 0 && sha256.isLowercaseSHA256 }
}

nonisolated struct DorydMachineSnapshotArtifactEvidence: Codable, Sendable, Equatable, Hashable {
    var schemaVersion: UInt16
    var rootfs: DorydMachineSnapshotArtifact
    var kernel: DorydMachineSnapshotArtifact
    var machineIdentifier: DorydMachineSnapshotArtifact?
    var nvram: DorydMachineSnapshotArtifact?

    var isValid: Bool {
        schemaVersion == 1
            && rootfs.isValid
            && kernel.isValid
            && (machineIdentifier?.isValid ?? true)
            && (nvram?.isValid ?? true)
            && ((machineIdentifier == nil) == (nvram == nil))
    }
}

nonisolated enum DorydMachineSnapshotConsistency: String, Sendable, Equatable, Hashable {
    case coldStopped = "cold-stopped"
    case guestQuiesced = "guest-quiesced"
}

nonisolated struct DorydMachineSnapshotQuiesceReceipt: Sendable, Equatable, Hashable {
    var schemaVersion: UInt16
    var receiptID: String
    var agentBuild: String
    var agentProtocolVersion: UInt32
    var capabilityVersion: UInt32

    var isValid: Bool {
        schemaVersion == 1
            && receiptID.utf8.count == 32
            && receiptID.utf8.allSatisfy {
                ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66)
            }
            && !agentBuild.isEmpty
            && agentBuild.utf8.count <= 128
            && agentBuild.utf8.allSatisfy { $0 >= 0x20 && $0 <= 0x7e }
            && agentProtocolVersion == 1
            && capabilityVersion >= 2
    }
}

nonisolated struct DorydAgentCapability: Sendable, Equatable, Hashable {
    var id: String
    var version: UInt32

    var isValid: Bool {
        version > 0 && id.utf8.count <= 63
            && id.wholeMatch(of: /[a-z][a-z0-9]*(?:-[a-z0-9]+)*/) != nil
    }
}

nonisolated struct DorydMachineStatus: Sendable, Equatable {
    var id: String
    var state: String
    var pid: Int32?
    var lastError: String?
    var handoffSocketPath: String?
    var agentBuild: String?
    var agentProtocolVersion: UInt32? = nil
    var agentCapabilities: [DorydAgentCapability] = []
    var agentSocketPath: String?
    var dockerdSocketPath: String?
    var shellSocketPath: String?
    var controlSocketPath: String? = nil
    var address: String? = nil
    var configuredAddress: String? = nil
    var runtimeAddress: String? = nil
    var handoffFDCount: Int
    var memoryMB: UInt64?
    var currentBalloonTargetMB: UInt64? = nil
    var cpuCount: Int?
    var displayMode: MachineDisplayMode = .headless
    var bootMode: MachineBootMode = .linuxKernel
    var installerMediaAttached: Bool = false
    var shares: [DorydMachineShareConfiguration] = []
    var environment: [String: String] = [:]
    var typedSettings: DorydMachineTypedSettings? = nil
    var runtimeIdentity: DorydMachineRuntimeIdentity = .legacyCompatibility
    var installedDesktopPayloadReceipt: DorydInstalledDesktopPayloadReceipt? = nil
}

nonisolated struct DorydMachineExecResult: Sendable, Equatable {
    var exitCode: Int32
    var stdout: String
    var stderr: String
    var timedOut: Bool
    var stdoutTruncated: Bool
    var stderrTruncated: Bool
}

nonisolated struct DorydMachineStats: Sendable, Equatable {
    var cpuPercent: Double
    var memoryUsedBytes: UInt64
    var memoryTotalBytes: UInt64
    var networkReceiveBytes: UInt64
    var networkTransmitBytes: UInt64
    var blockReadBytes: UInt64
    var blockWriteBytes: UInt64
    var processCount: UInt64
    var uptimeSeconds: Double
}

nonisolated struct DorydMachineProvisionResult: Sendable, Equatable {
    var recipeID: String
    var install: DorydMachineExecResult
    var verify: DorydMachineExecResult
}

nonisolated struct DorydDesktopUpdateResult: Sendable, Equatable {
    var machineID: String
    var distro: String
    var version: String
    var inputSHA256: String
    var bundleSHA256: String
    var snapshotID: String
    var status: DorydMachineStatus
    var restoredRunningState: Bool
}

nonisolated struct DorydMachineSnapshot: Sendable, Equatable {
    var id: String
    var machineID: String
    var note: String
    var createdISO: String
    var rootfsPath: String
    var sizeBytes: Int64
    var kernelPath: String
    var architecture: String
    var memoryMB: UInt64
    var cpuCount: Int
    var runtimeIdentity: DorydMachineRuntimeIdentity = .legacyCompatibility
    var artifactEvidence: DorydMachineSnapshotArtifactEvidence? = nil
    var installedDesktopPayloadReceipt: DorydInstalledDesktopPayloadReceipt? = nil
    var consistency: DorydMachineSnapshotConsistency = .coldStopped
    var guestQuiesceReceipt: DorydMachineSnapshotQuiesceReceipt? = nil
}

nonisolated enum DorydMachineBackupFrequency: String, Sendable, Equatable, CaseIterable {
    case hourly
    case daily
    case weekly
}

nonisolated struct DorydMachineBackupSchedule: Sendable, Equatable {
    var machineID: String
    var enabled: Bool
    var frequency: DorydMachineBackupFrequency
    var keepLocal: Int
    var verifyEveryRuns: Int

    var xpcDictionary: NSDictionary {
        [
            "machineID": machineID,
            "enabled": enabled,
            "frequency": frequency.rawValue,
            "keepLocal": keepLocal,
            "verifyEveryRuns": verifyEveryRuns,
        ]
    }
}

nonisolated struct DorydMachineBackupStatus: Sendable, Equatable {
    var schedule: DorydMachineBackupSchedule
    var inProgress: Bool
    var successfulRuns: Int
    var consecutiveFailures: Int
    var lastAttemptISO: String?
    var lastSuccessISO: String?
    var lastVerificationISO: String?
    var lastBootVerificationISO: String?
    var lastSnapshotID: String?
    var lastArchivePath: String?
    var nextRunISO: String?
    var lastError: String?
    var retainedSnapshots: Int
    var retainedArchives: Int
}

nonisolated struct DorydRemoteMachineConfiguration: Sendable, Equatable {
    var id: String
    var host: String
    var port: UInt16
    var user: String
    var privateKeyID: String
    var hostKeyType: String
    var hostKey: String?
    var knownHostsPath: String?
    var knownHostsHost: String?
    var knownHostsPort: UInt16?
    var endpointType: String
    var endpointPath: String?
    var endpointHost: String?
    var endpointPort: UInt16?
    var remoteRoot: String
    var build: String

    var xpcDictionary: NSDictionary {
        var dictionary: [String: Any] = [
            "id": id,
            "host": host,
            "port": port,
            "user": user,
            "privateKeyID": privateKeyID,
            "hostKeyType": hostKeyType,
            "endpointType": endpointType,
            "remoteRoot": remoteRoot,
            "build": build,
        ]
        if let hostKey { dictionary["hostKey"] = hostKey }
        if let knownHostsPath { dictionary["knownHostsPath"] = knownHostsPath }
        if let knownHostsHost { dictionary["knownHostsHost"] = knownHostsHost }
        if let knownHostsPort { dictionary["knownHostsPort"] = knownHostsPort }
        if let endpointPath { dictionary["endpointPath"] = endpointPath }
        if let endpointHost { dictionary["endpointHost"] = endpointHost }
        if let endpointPort { dictionary["endpointPort"] = endpointPort }
        return dictionary as NSDictionary
    }
}

nonisolated struct DorydAgentInfo: Sendable, Equatable {
    var protocolVersion: UInt32
    var kernel: String
    var agentBuild: String
    var uptimeSeconds: UInt64
    var capabilities: [DorydAgentCapability] = []
}

nonisolated struct DorydTelemetry: Sendable, Equatable {
    var memTotalKB: UInt64
    var memAvailableKB: UInt64
    var psiSomeAvg10: Double
    var psiFullAvg10: Double
}

nonisolated struct DorydListenPort: Sendable, Equatable, Hashable {
    var `protocol`: String
    var port: UInt32
}

nonisolated struct DorydDockerAgentPorts: Sendable, Equatable {
    var ports: [DorydListenPort]
    var added: [DorydListenPort]
    var removed: [DorydListenPort]
}

nonisolated struct DorydPushStats: Sendable, Equatable {
    var filesSent: UInt64
    var bytesSent: UInt64
    var filesDeleted: UInt64
}

nonisolated struct DorydRemoteMachineStatus: Sendable, Equatable {
    var id: String
    var state: String
    var lastError: String?
    var info: DorydAgentInfo?
    var telemetry: DorydTelemetry?
}

nonisolated struct DorydDomainRoute: Sendable, Equatable {
    var hostname: String
    var address: String
    var port: UInt16 = 80
    var pathPrefix: String = ""

    var xpcDictionary: NSDictionary {
        var dictionary: [String: Any] = [
            "hostname": hostname,
            "address": address,
            "port": port,
        ]
        if !pathPrefix.isEmpty {
            dictionary["pathPrefix"] = pathPrefix
        }
        return dictionary as NSDictionary
    }
}

nonisolated struct DorydNetworkingStatus: Sendable, Equatable {
    var mode: String
    var suffix: String
    var dnsBindAddress: String
    var dnsPort: UInt16
    var dnsRunning: Bool
    var httpProxyPort: UInt16?
    var httpProxyRunning: Bool
    var httpsProxyPort: UInt16?
    var httpsProxyRunning: Bool
    var routes: [DorydDomainRoute]
    var customRoutes: [DorydDomainRoute]
}

nonisolated struct DorydNetworkingAuthorizationRequest: Sendable, Equatable, Codable {
    var id: String
    var kind: String
    var title: String
    var reason: String
    var requiresAdmin: Bool
    var filePath: String?
    var fileContents: String?
    var command: [String]
}

nonisolated struct DorydPrivilegedTCPForward: Sendable, Equatable, Codable {
    var listenPort: UInt16
    var targetPort: UInt16
}

nonisolated struct DorydNetworkingAuthorizationPlan: Sendable, Equatable, Codable {
    private enum CodingKeys: String, CodingKey {
        case degradedMode
        case authorizedMode
        case suffix
        case dnsBindAddress
        case dnsPort
        case httpProxyPort
        case httpsProxyPort
        case privilegedTCPForwards
        case requests
    }

    var degradedMode: String
    var authorizedMode: String
    var suffix: String
    var dnsBindAddress: String
    var dnsPort: UInt16
    var httpProxyPort: UInt16
    var httpsProxyPort: UInt16
    var privilegedTCPForwards: [DorydPrivilegedTCPForward] = []
    var requests: [DorydNetworkingAuthorizationRequest]

    init(
        degradedMode: String,
        authorizedMode: String,
        suffix: String,
        dnsBindAddress: String,
        dnsPort: UInt16,
        httpProxyPort: UInt16,
        httpsProxyPort: UInt16,
        privilegedTCPForwards: [DorydPrivilegedTCPForward] = [],
        requests: [DorydNetworkingAuthorizationRequest]
    ) {
        self.degradedMode = degradedMode
        self.authorizedMode = authorizedMode
        self.suffix = suffix
        self.dnsBindAddress = dnsBindAddress
        self.dnsPort = dnsPort
        self.httpProxyPort = httpProxyPort
        self.httpsProxyPort = httpsProxyPort
        self.privilegedTCPForwards = privilegedTCPForwards
        self.requests = requests
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.degradedMode = try container.decode(String.self, forKey: .degradedMode)
        self.authorizedMode = try container.decode(String.self, forKey: .authorizedMode)
        self.suffix = try container.decode(String.self, forKey: .suffix)
        self.dnsBindAddress = try container.decode(String.self, forKey: .dnsBindAddress)
        self.dnsPort = try container.decode(UInt16.self, forKey: .dnsPort)
        self.httpProxyPort = try container.decode(UInt16.self, forKey: .httpProxyPort)
        self.httpsProxyPort = try container.decode(UInt16.self, forKey: .httpsProxyPort)
        self.privilegedTCPForwards = try container.decodeIfPresent(
            [DorydPrivilegedTCPForward].self,
            forKey: .privilegedTCPForwards
        ) ?? []
        self.requests = try container.decode([DorydNetworkingAuthorizationRequest].self, forKey: .requests)
    }
}

nonisolated struct DorydHostMemorySnapshot: Sendable, Equatable {
    var totalBytes: UInt64
    var availableBytes: UInt64
    var freeBytes: UInt64
    var availableRatio: Double
    var pressure: String
}

nonisolated struct DorydBalloonTarget: Sendable, Equatable {
    var id: String
    var kind: String
    var currentTargetMB: UInt64
    var targetMB: UInt64
    var reason: String
    var canApply: Bool
}

nonisolated struct DorydBalloonPlan: Sendable, Equatable {
    var host: DorydHostMemorySnapshot
    var targets: [DorydBalloonTarget]
    var applicableTargets: [DorydBalloonTarget]
}

enum DorydClientError: Error, Sendable, CustomStringConvertible {
    case connectionUnavailable
    case invalidProxy
    case daemon(String)
    case timedOut

    var description: String {
        switch self {
        case .connectionUnavailable:
            return "doryd connection is unavailable"
        case .invalidProxy:
            return "doryd XPC proxy has an unexpected type"
        case let .daemon(message):
            return message.isEmpty ? "doryd returned an error" : message
        case .timedOut:
            return "doryd request timed out"
        }
    }
}

nonisolated final class DorydClient: @unchecked Sendable {
    // The daemon owns a 240-second promotion deadline. Leave enough client-side margin for the
    // daemon to return its exact outcome instead of replacing it with a simultaneous UI timeout.
    private static let engineColdStartTimeout: TimeInterval = 250
    // doryd gives dockerd and dory-hv up to 30 seconds to quiesce before its final fallback.
    // Keep the UI connection alive past that bound so a safe stop is not reported as a timeout.
    private static let engineShutdownTimeout: TimeInterval = 45

    private enum Target {
        case machService(String)
        case endpoint(NSXPCListenerEndpoint)
    }

    private let target: Target
    private let timeout: TimeInterval

    init(
        machServiceName: String = ProcessInfo.processInfo.environment["DORYD_MACH_SERVICE"] ?? "dev.dory.doryd",
        timeout: TimeInterval = 2
    ) {
        self.target = .machService(machServiceName)
        self.timeout = timeout
    }

    init(endpoint: NSXPCListenerEndpoint, timeout: TimeInterval = 2) {
        self.target = .endpoint(endpoint)
        self.timeout = timeout
    }

    var usesMachService: Bool {
        if case .machService = target { return true }
        return false
    }

    private func withTimeout(atLeast minimumTimeout: TimeInterval) -> DorydClient {
        let effectiveTimeout = max(timeout, minimumTimeout)
        switch target {
        case let .machService(name):
            return DorydClient(machServiceName: name, timeout: effectiveTimeout)
        case let .endpoint(endpoint):
            return DorydClient(endpoint: endpoint, timeout: effectiveTimeout)
        }
    }

    func doctorJSON() async throws -> String {
        try await call { proxy, finish in
            proxy.doctorJSON { json, error in
                if error.isEmpty {
                    finish(.success(json))
                } else {
                    finish(.failure(DorydClientError.daemon(error)))
                }
            }
        }
    }

    func healthJSON() async throws -> String {
        try await call { proxy, finish in
            proxy.health { body, error in
                if !error.isEmpty {
                    finish(.failure(DorydClientError.daemon(error)))
                    return
                }
                do {
                    let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
                    finish(.success(String(decoding: data, as: UTF8.self)))
                } catch {
                    finish(.failure(error))
                }
            }
        }
    }

    func protocolVersion() async throws -> UInt32 {
        try await call { proxy, finish in
            proxy.protocolVersion { version in
                finish(.success(version))
            }
        }
    }

    func dorySocketPath() async throws -> String {
        try await call { proxy, finish in
            proxy.dorySocketPath { path in
                finish(.success(path))
            }
        }
    }

    func engineStatus() async throws -> DorydEngineStatus {
        try await call { proxy, finish in
            proxy.engineStatus { state, detail in
                finish(.success(DorydEngineStatus(state: state, detail: detail)))
            }
        }
    }

    func engineStart() async throws -> DorydCommandResult {
        try await withTimeout(atLeast: Self.engineColdStartTimeout).command { proxy, reply in
            proxy.engineStart(reply: reply)
        }
    }

    func engineStop() async throws -> DorydCommandResult {
        try await withTimeout(atLeast: Self.engineShutdownTimeout).command { proxy, reply in
            proxy.engineStop(reply: reply)
        }
    }

    func engineSleep() async throws -> DorydCommandResult {
        try await withTimeout(atLeast: Self.engineShutdownTimeout).command { proxy, reply in
            proxy.engineSleep(reply: reply)
        }
    }

    func engineWake() async throws -> DorydCommandResult {
        try await withTimeout(atLeast: Self.engineColdStartTimeout).command { proxy, reply in
            proxy.engineWake(reply: reply)
        }
    }

    func dockerAgentInfo() async throws -> DorydAgentInfo {
        try await dictionaryCall { proxy, reply in
            proxy.dockerAgentInfo(reply: reply)
        } decode: {
            Self.agentInfo(from: $0)
        }
    }

    func dockerAgentPorts() async throws -> DorydDockerAgentPorts {
        try await dictionaryCall { proxy, reply in
            proxy.dockerAgentPorts(reply: reply)
        } decode: {
            Self.dockerAgentPorts(from: $0)
        }
    }

    func dockerAgentTelemetry() async throws -> DorydTelemetry {
        try await dictionaryCall { proxy, reply in
            proxy.dockerAgentTelemetry(reply: reply)
        } decode: {
            Self.telemetry(from: $0)
        }
    }

    func machineCreate(_ config: DorydMachineConfiguration) async throws -> DorydMachineStatus {
        try await withTimeout(atLeast: 60).statusCommand { proxy, reply in
            proxy.machineCreate(config.xpcDictionary, reply: reply)
        } decode: {
            Self.machineStatus(from: $0)
        }
    }

    func machineStart(_ machineID: String) async throws -> DorydMachineStatus {
        try await withTimeout(atLeast: 120).statusCommand { proxy, reply in
            proxy.machineStart(machineID, reply: reply)
        } decode: {
            Self.machineStatus(from: $0)
        }
    }

    func machineStop(_ machineID: String) async throws -> DorydMachineStatus {
        try await withTimeout(atLeast: 30).statusCommand { proxy, reply in
            proxy.machineStop(machineID, reply: reply)
        } decode: {
            Self.machineStatus(from: $0)
        }
    }

    func machinePause(_ machineID: String) async throws -> DorydMachineStatus {
        try await withTimeout(atLeast: 30).statusCommand { proxy, reply in
            proxy.machinePause(machineID, reply: reply)
        } decode: {
            Self.machineStatus(from: $0)
        }
    }

    func machineResume(_ machineID: String) async throws -> DorydMachineStatus {
        try await withTimeout(atLeast: 30).statusCommand { proxy, reply in
            proxy.machineResume(machineID, reply: reply)
        } decode: {
            Self.machineStatus(from: $0)
        }
    }

    func machineRestart(_ machineID: String) async throws -> DorydMachineStatus {
        try await withTimeout(atLeast: 120).statusCommand { proxy, reply in
            proxy.machineRestart(machineID, reply: reply)
        } decode: {
            Self.machineStatus(from: $0)
        }
    }

    func machineUpdate(
        _ machineID: String,
        memoryMB: UInt64? = nil,
        cpuCount: Int? = nil,
        address: String? = nil,
        updatesAddress: Bool = false,
        shares: [DorydMachineShareConfiguration]? = nil,
        typedSettings: DorydMachineTypedSettings? = nil,
        typedSettingsPatch: DorydMachineTypedSettingsPatch? = nil,
        installerMediaAttached: Bool? = nil
    ) async throws -> DorydMachineStatus {
        var config: [String: Any] = [:]
        if let memoryMB {
            config["memoryMB"] = memoryMB
        }
        if let cpuCount {
            config["cpuCount"] = cpuCount
        }
        if updatesAddress {
            config["address"] = address ?? ""
        } else if let address {
            config["address"] = address
        }
        if let shares {
            config["shares"] = shares.map(\.xpcDictionary)
        }
        if let typedSettings {
            for (rawKey, value) in typedSettings.xpcDictionary {
                if let key = rawKey as? String { config[key] = value }
            }
        }
        if let typedSettingsPatch {
            precondition(typedSettings == nil, "use either full typed settings or a typed patch")
            for (rawKey, value) in typedSettingsPatch.xpcDictionary {
                if let key = rawKey as? String { config[key] = value }
            }
        }
        if let installerMediaAttached {
            config["installerMediaAttached"] = installerMediaAttached
        }
        return try await withTimeout(atLeast: 120).statusCommand { proxy, reply in
            proxy.machineUpdate(machineID, config: config as NSDictionary, reply: reply)
        } decode: {
            Self.machineStatus(from: $0)
        }
    }

    func machineDelete(_ machineID: String) async throws -> DorydCommandResult {
        try await command { proxy, reply in
            proxy.machineDelete(machineID, reply: reply)
        }
    }

    func machineExec(
        _ machineID: String,
        argv: [String],
        cwd: String = "",
        env: [String: String] = [:],
        timeoutMs: UInt64 = 30_000,
        outputLimitBytes: UInt64 = 1024 * 1024
    ) async throws -> DorydMachineExecResult {
        let request: NSDictionary = [
            "argv": argv,
            "cwd": cwd,
            "env": env.map { ["key": $0.key, "value": $0.value] as NSDictionary },
            "timeoutMs": timeoutMs,
            "outputLimitBytes": outputLimitBytes,
        ]
        return try await withTimeout(atLeast: Self.machineExecControlTimeout(timeoutMs: timeoutMs)).statusCommand { proxy, reply in
            proxy.machineExec(machineID, request: request, reply: reply)
        } decode: {
            Self.machineExecResult(from: $0)
        }
    }

    func machineStats(_ machineID: String) async throws -> DorydMachineStats {
        try await withTimeout(atLeast: 10).statusCommand { proxy, reply in
            proxy.machineStats(machineID, reply: reply)
        } decode: {
            Self.machineStats(from: $0)
        }
    }

    func machineProvision(_ machineID: String, recipe: String) async throws -> DorydMachineProvisionResult {
        try await withTimeout(atLeast: Self.machineProvisionControlTimeout).statusCommand { proxy, reply in
            proxy.machineProvision(machineID, request: ["recipe": recipe] as NSDictionary, reply: reply)
        } decode: {
            Self.machineProvisionResult(from: $0)
        }
    }

    func machineDesktopUpdate(
        _ machineID: String,
        distro: String,
        version: String,
        distributionInstallationName: String,
        runtimeInstallationName: String
    ) async throws -> DorydDesktopUpdateResult {
        let request: NSDictionary = [
            "distro": distro,
            "version": version,
            "distributionInstallationName": distributionInstallationName,
            "runtimeInstallationName": runtimeInstallationName,
        ]
        return try await withTimeout(atLeast: 3_900).statusCommand { proxy, reply in
            proxy.machineDesktopUpdate(machineID, request: request, reply: reply)
        } decode: {
            Self.desktopUpdateResult(from: $0)
        }
    }

    func machineSnapshot(
        _ machineID: String,
        note: String = "",
        createdISO: String,
        snapshotID: String? = nil
    ) async throws -> DorydMachineSnapshot {
        var request: [String: Any] = [
            "note": note,
            "createdISO": createdISO,
        ]
        if let snapshotID {
            request["snapshotID"] = snapshotID
        }
        return try await withTimeout(atLeast: 60).statusCommand { proxy, reply in
            proxy.machineSnapshot(machineID, request: request as NSDictionary, reply: reply)
        } decode: {
            Self.machineSnapshot(from: $0)
        }
    }

    func machineSnapshots(machineID: String? = nil) async throws -> [DorydMachineSnapshot] {
        try await call { proxy, finish in
            proxy.machineSnapshots(machineID ?? "") { rows, error in
                if !error.isEmpty {
                    finish(.failure(DorydClientError.daemon(error)))
                    return
                }
                guard let snapshots = Self.machineSnapshots(from: rows) else {
                    finish(.failure(DorydClientError.daemon("invalid machine snapshot list")))
                    return
                }
                finish(.success(snapshots))
            }
        }
    }

    func machineCloneSnapshot(machineID: String, snapshotID: String, newID: String) async throws -> DorydMachineStatus {
        try await withTimeout(atLeast: 120).statusCommand { proxy, reply in
            proxy.machineCloneSnapshot(machineID, snapshotID: snapshotID, newID: newID, reply: reply)
        } decode: {
            Self.machineStatus(from: $0)
        }
    }

    func machineRestoreSnapshot(machineID: String, snapshotID: String) async throws -> DorydMachineStatus {
        try await withTimeout(atLeast: 120).statusCommand { proxy, reply in
            proxy.machineRestoreSnapshot(machineID, snapshotID: snapshotID, reply: reply)
        } decode: {
            Self.machineStatus(from: $0)
        }
    }

    func machineDeleteSnapshot(machineID: String, snapshotID: String) async throws -> DorydCommandResult {
        try await command { proxy, reply in
            proxy.machineDeleteSnapshot(machineID, snapshotID: snapshotID, reply: reply)
        }
    }

    func machineExportSnapshot(machineID: String, snapshotID: String, to path: String) async throws -> DorydCommandResult {
        try await withTimeout(atLeast: 120).command { proxy, reply in
            proxy.machineExportSnapshot(machineID, snapshotID: snapshotID, path: path, reply: reply)
        }
    }

    func machineImportSnapshot(from path: String) async throws -> DorydMachineSnapshot {
        try await withTimeout(atLeast: 120).statusCommand { proxy, reply in
            proxy.machineImportSnapshot(path, reply: reply)
        } decode: {
            Self.machineSnapshot(from: $0)
        }
    }

    func machineBackupSchedules() async throws -> [DorydMachineBackupStatus] {
        try await call { proxy, finish in
            proxy.machineBackupSchedules { rows, error in
                if !error.isEmpty {
                    finish(.failure(DorydClientError.daemon(error)))
                    return
                }
                guard let statuses = Self.machineBackupStatuses(from: rows) else {
                    finish(.failure(DorydClientError.daemon("invalid machine backup schedule list")))
                    return
                }
                finish(.success(statuses))
            }
        }
    }

    func machineBackupSet(_ schedule: DorydMachineBackupSchedule) async throws -> DorydMachineBackupStatus {
        try await statusCommand { proxy, reply in
            proxy.machineBackupSet(schedule.xpcDictionary, reply: reply)
        } decode: {
            Self.machineBackupStatus(from: $0)
        }
    }

    func machineBackupRemove(machineID: String) async throws -> DorydCommandResult {
        try await command { proxy, reply in
            proxy.machineBackupRemove(machineID, reply: reply)
        }
    }

    func machineBackupRun(machineID: String) async throws -> DorydMachineBackupStatus {
        try await withTimeout(atLeast: 900).statusCommand { proxy, reply in
            proxy.machineBackupRun(machineID, reply: reply)
        } decode: {
            Self.machineBackupStatus(from: $0)
        }
    }

    func machineList() async throws -> [DorydMachineStatus] {
        try await call { proxy, finish in
            proxy.machineList { rows, error in
                if !error.isEmpty {
                    finish(.failure(DorydClientError.daemon(error)))
                    return
                }
                guard let statuses = Self.machineStatuses(from: rows) else {
                    finish(.failure(DorydClientError.daemon("invalid machine list")))
                    return
                }
                finish(.success(statuses))
            }
        }
    }

    func remoteConnect(_ config: DorydRemoteMachineConfiguration) async throws -> DorydAgentInfo {
        try await statusCommand { proxy, reply in
            proxy.remoteConnect(config.xpcDictionary, reply: reply)
        } decode: {
            Self.agentInfo(from: $0)
        }
    }

    func remotePush(machineID: String, localRoot: String, remoteRoot: String? = nil) async throws -> DorydPushStats {
        try await statusCommand { proxy, reply in
            proxy.remotePush(machineID, localRoot: localRoot, remoteRoot: remoteRoot ?? "", reply: reply)
        } decode: {
            Self.pushStats(from: $0)
        }
    }

    func remoteStatus(machineID: String) async throws -> DorydRemoteMachineStatus {
        try await call { proxy, finish in
            proxy.remoteStatus(machineID) { body, error in
                if !error.isEmpty {
                    finish(.failure(DorydClientError.daemon(error)))
                    return
                }
                guard let status = Self.remoteStatus(from: body) else {
                    finish(.failure(DorydClientError.daemon("invalid remote status")))
                    return
                }
                finish(.success(status))
            }
        }
    }

    func networkReplaceRoutes(_ routes: [DorydDomainRoute]) async throws -> DorydCommandResult {
        try await command { proxy, reply in
            proxy.networkReplaceRoutes(routes.map(\.xpcDictionary) as NSArray, reply: reply)
        }
    }

    func networkStatus() async throws -> DorydNetworkingStatus {
        try await call { proxy, finish in
            proxy.networkStatus { body, error in
                if !error.isEmpty {
                    finish(.failure(DorydClientError.daemon(error)))
                    return
                }
                guard let status = Self.networkStatus(from: body) else {
                    finish(.failure(DorydClientError.daemon("invalid network status")))
                    return
                }
                finish(.success(status))
            }
        }
    }

    func networkAuthorizationPlan() async throws -> DorydNetworkingAuthorizationPlan {
        try await call { proxy, finish in
            proxy.networkAuthorizationPlan { body, error in
                if error.isEmpty, let plan = Self.networkAuthorizationPlan(from: body) {
                    finish(.success(plan))
                } else {
                    finish(.failure(DorydClientError.daemon(error.isEmpty ? "invalid networking authorization plan" : error)))
                }
            }
        }
    }

    func corporateConnectivityStatus(runProbes: Bool = true) async throws -> String {
        try await call { proxy, finish in
            proxy.corporateConnectivityStatus(runProbes) { body, error in
                error.isEmpty
                    ? finish(.success(body))
                    : finish(.failure(DorydClientError.daemon(error)))
            }
        }
    }

    func corporateConnectivityApply(profileJSON: String, dryRun: Bool = false) async throws -> String {
        try await call { proxy, finish in
            proxy.corporateConnectivityApply(profileJSON, dryRun: dryRun) { body, error in
                error.isEmpty
                    ? finish(.success(body))
                    : finish(.failure(DorydClientError.daemon(error)))
            }
        }
    }

    func corporateConnectivityDisable() async throws -> String {
        try await call { proxy, finish in
            proxy.corporateConnectivityDisable { body, error in
                error.isEmpty
                    ? finish(.success(body))
                    : finish(.failure(DorydClientError.daemon(error)))
            }
        }
    }

    func repairSubsystem(_ target: String) async throws -> DorydCommandResult {
        try await command { proxy, reply in
            proxy.repairSubsystem(target, reply: reply)
        }
    }

    func balloonStatus() async throws -> DorydBalloonPlan {
        try await call { proxy, finish in
            proxy.balloonStatus { body, error in
                if !error.isEmpty {
                    finish(.failure(DorydClientError.daemon(error)))
                    return
                }
                guard let plan = Self.balloonPlan(from: body) else {
                    finish(.failure(DorydClientError.daemon("invalid balloon plan")))
                    return
                }
                finish(.success(plan))
            }
        }
    }

    func balloonReconcile() async throws -> DorydBalloonPlan {
        try await call { proxy, finish in
            proxy.balloonReconcile { body, error in
                if !error.isEmpty {
                    finish(.failure(DorydClientError.daemon(error)))
                    return
                }
                guard let plan = Self.balloonPlan(from: body) else {
                    finish(.failure(DorydClientError.daemon("invalid balloon plan")))
                    return
                }
                finish(.success(plan))
            }
        }
    }

    func idleStatus() async throws -> IdleStatus {
        try await dictionaryCall { proxy, reply in
            proxy.idleStatus(reply: reply)
        } decode: {
            Self.decoded(IdleStatus.self, from: $0)
        }
    }

    func idleHistory(limit: Int) async throws -> [IdleHistoryEntry] {
        try await call { proxy, finish in
            proxy.idleHistory(limit) { rows, error in
                if !error.isEmpty {
                    finish(.failure(DorydClientError.daemon(error)))
                    return
                }
                guard let history = Self.decoded([FailableDecodable<IdleHistoryEntry>].self, from: rows) else {
                    finish(.failure(DorydClientError.daemon("invalid idle history")))
                    return
                }
                finish(.success(history.compactMap(\.value)))
            }
        }
    }

    func idleSetMode(_ mode: String) async throws -> IdleStatus {
        try await withTimeout(atLeast: Self.engineColdStartTimeout).statusCommand { proxy, reply in
            proxy.idleSetMode(mode, reply: reply)
        } decode: {
            Self.decoded(IdleStatus.self, from: $0)
        }
    }

    func idleSetPolicy(key: String, value: String) async throws -> IdleStatus {
        try await statusCommand { proxy, reply in
            proxy.idleSetPolicy(key, value: value, reply: reply)
        } decode: {
            Self.decoded(IdleStatus.self, from: $0)
        }
    }

    func incidents(limit: Int) async throws -> [Incident] {
        try await call { proxy, finish in
            proxy.incidents(limit) { rows, error in
                if !error.isEmpty {
                    finish(.failure(DorydClientError.daemon(error)))
                    return
                }
                finish(.success(rows.compactMap(Self.incident(from:))))
            }
        }
    }

    private func command(
        _ body: @escaping (DorydControlXPC, @escaping (Bool, String) -> Void) -> Void
    ) async throws -> DorydCommandResult {
        try await call { proxy, finish in
            body(proxy) { ok, message in
                finish(.success(DorydCommandResult(ok: ok, message: message)))
            }
        }
    }

    private func statusCommand<T>(
        _ body: @escaping (DorydControlXPC, @escaping (Bool, NSDictionary, String) -> Void) -> Void,
        decode: @escaping (NSDictionary) -> T?
    ) async throws -> T {
        try await call { proxy, finish in
            body(proxy) { ok, response, message in
                if !ok {
                    finish(.failure(DorydClientError.daemon(message)))
                    return
                }
                guard let decoded = decode(response) else {
                    finish(.failure(DorydClientError.daemon(message.isEmpty ? "invalid doryd response" : message)))
                    return
                }
                finish(.success(decoded))
            }
        }
    }

    private func dictionaryCall<T>(
        _ body: @escaping (DorydControlXPC, @escaping (NSDictionary, String) -> Void) -> Void,
        decode: @escaping (NSDictionary) -> T?
    ) async throws -> T {
        try await call { proxy, finish in
            body(proxy) { response, message in
                if !message.isEmpty {
                    finish(.failure(DorydClientError.daemon(message)))
                    return
                }
                guard let decoded = decode(response) else {
                    finish(.failure(DorydClientError.daemon("invalid doryd response")))
                    return
                }
                finish(.success(decoded))
            }
        }
    }

    private func call<T>(
        _ body: @escaping (DorydControlXPC, @escaping @Sendable (Result<T, Error>) -> Void) -> Void
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let connection = makeConnection()
            let box = DorydContinuationBox(continuation: continuation, connection: connection)
            connection.remoteObjectInterface = NSXPCInterface(with: DorydControlXPC.self)
            connection.invalidationHandler = {
                box.resume(.failure(DorydClientError.connectionUnavailable))
            }
            connection.interruptionHandler = {
                box.resume(.failure(DorydClientError.connectionUnavailable))
            }
            connection.resume()

            let timeout = DispatchWorkItem {
                box.resume(.failure(DorydClientError.timedOut))
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + self.timeout, execute: timeout)

            let remote = connection.remoteObjectProxyWithErrorHandler { error in
                timeout.cancel()
                box.resume(.failure(error))
            }
            guard let proxy = remote as? DorydControlXPC else {
                timeout.cancel()
                box.resume(.failure(DorydClientError.invalidProxy))
                return
            }
            body(proxy) { result in
                timeout.cancel()
                box.resume(result)
            }
        }
    }

    private func makeConnection() -> NSXPCConnection {
        switch target {
        case let .machService(name):
            let connection = NSXPCConnection(machServiceName: name, options: [])
            if DorydDaemonSigningPolicy.isProductionClient {
                connection.setCodeSigningRequirement(DorydDaemonSigningPolicy.daemonRequirement)
            }
            return connection
        case let .endpoint(endpoint):
            return NSXPCConnection(listenerEndpoint: endpoint)
        }
    }

    nonisolated private static func incident(from row: Any) -> Incident? {
        guard let dictionary = row as? NSDictionary,
              let at = dictionary["at"] as? String,
              let type = dictionary["type"] as? String else {
            return nil
        }
        return Incident(at: at, type: type, detail: dictionary["detail"] as? String)
    }

    nonisolated private static func decoded<T: Decodable>(_ type: T.Type, from object: Any) -> T? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: []) else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: data)
    }

    nonisolated private static func machineStatus(from dictionary: NSDictionary) -> DorydMachineStatus? {
        guard let id = dictionary["id"] as? String,
              let state = dictionary["state"] as? String,
              let runtimeIdentity = machineRuntimeIdentity(from: dictionary) else {
            return nil
        }
        let environment = machineEnvironment(from: dictionary["env"])
        guard let typedSettings = machineTypedSettings(from: dictionary) else {
            return nil
        }
        guard let installedDesktopPayloadReceipt = machineInstalledDesktopPayloadReceipt(
            from: dictionary,
            legacyEnvironment: environment
        ) else {
            return nil
        }
        guard let agentHandshake = machineAgentHandshake(from: dictionary) else {
            return nil
        }
        return DorydMachineStatus(
            id: id,
            state: state,
            pid: int32(dictionary["pid"]),
            lastError: nonEmptyString(dictionary["lastError"]),
            handoffSocketPath: nonEmptyString(dictionary["handoffSocketPath"]),
            agentBuild: nonEmptyString(dictionary["agentBuild"]),
            agentProtocolVersion: agentHandshake.protocolVersion,
            agentCapabilities: agentHandshake.capabilities,
            agentSocketPath: nonEmptyString(dictionary["agentSocketPath"]),
            dockerdSocketPath: nonEmptyString(dictionary["dockerdSocketPath"]),
            shellSocketPath: nonEmptyString(dictionary["shellSocketPath"]),
            controlSocketPath: nonEmptyString(dictionary["controlSocketPath"]),
            address: nonEmptyString(dictionary["address"]),
            configuredAddress: nonEmptyString(dictionary["configuredAddress"]),
            runtimeAddress: nonEmptyString(dictionary["runtimeAddress"]),
            handoffFDCount: int(dictionary["handoffFDCount"]) ?? 0,
            memoryMB: uint64(dictionary["memoryMB"]),
            currentBalloonTargetMB: uint64(dictionary["currentBalloonTargetMB"]),
            cpuCount: int(dictionary["cpuCount"]),
            displayMode: (dictionary["displayMode"] as? String).flatMap(MachineDisplayMode.init(rawValue:)) ?? .headless,
            bootMode: (dictionary["bootMode"] as? String).flatMap(MachineBootMode.init(rawValue:)) ?? .linuxKernel,
            installerMediaAttached: (dictionary["installerMediaAttached"] as? Bool)
                ?? (dictionary["installerMediaAttached"] as? NSNumber)?.boolValue
                ?? false,
            shares: machineShares(from: dictionary["shares"]),
            environment: environment,
            typedSettings: typedSettings.value,
            runtimeIdentity: runtimeIdentity,
            installedDesktopPayloadReceipt: installedDesktopPayloadReceipt.value
        )
    }

    private struct ParsedMachineAgentHandshake {
        var protocolVersion: UInt32?
        var capabilities: [DorydAgentCapability]
    }

    nonisolated private static func machineAgentHandshake(
        from dictionary: NSDictionary
    ) -> ParsedMachineAgentHandshake? {
        let encodedProtocol = dictionary["agentProtocolVersion"]
        let encodedCapabilities = dictionary["agentCapabilities"]
        guard encodedProtocol != nil || encodedCapabilities != nil else {
            return ParsedMachineAgentHandshake(protocolVersion: nil, capabilities: [])
        }
        guard let encodedProtocol,
              dictionary["agentBuild"] is String,
              let number = encodedProtocol as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.rounded(.towardZero) == number.doubleValue,
              number.uint64Value > 0,
              number.uint64Value <= UInt64(UInt32.max) else {
            return nil
        }
        let protocolVersion = UInt32(number.uint64Value)
        guard let encodedCapabilities else {
            return ParsedMachineAgentHandshake(protocolVersion: protocolVersion, capabilities: [])
        }
        guard let capabilities = agentCapabilities(from: encodedCapabilities) else { return nil }
        return ParsedMachineAgentHandshake(
            protocolVersion: protocolVersion,
            capabilities: capabilities
        )
    }

    nonisolated private static func agentCapabilities(
        from encodedCapabilities: Any
    ) -> [DorydAgentCapability]? {
        guard let rawCapabilities = encodedCapabilities as? NSArray else { return nil }
        var capabilities: [DorydAgentCapability] = []
        capabilities.reserveCapacity(rawCapabilities.count)
        for encoded in rawCapabilities {
            guard let raw = encoded as? NSDictionary,
                  let keys = raw.allKeys as? [String],
                  Set(keys) == ["id", "version"],
                  keys.count == 2,
                  let id = raw["id"] as? String,
                  let versionNumber = raw["version"] as? NSNumber,
                  CFGetTypeID(versionNumber) != CFBooleanGetTypeID(),
                  versionNumber.doubleValue.rounded(.towardZero) == versionNumber.doubleValue,
                  versionNumber.uint64Value > 0,
                  versionNumber.uint64Value <= UInt64(UInt32.max) else {
                return nil
            }
            let capability = DorydAgentCapability(
                id: id,
                version: UInt32(versionNumber.uint64Value)
            )
            guard capability.isValid else { return nil }
            capabilities.append(capability)
        }
        guard capabilities == capabilities.sorted(by: { $0.id < $1.id }),
              Set(capabilities.map(\.id)).count == capabilities.count else {
            return nil
        }
        return capabilities
    }

    private struct ParsedMachineTypedSettings {
        var value: DorydMachineTypedSettings?
    }

    nonisolated private static func machineTypedSettings(
        from dictionary: NSDictionary
    ) -> ParsedMachineTypedSettings? {
        guard let encoded = dictionary["typedSettings"] else {
            return ParsedMachineTypedSettings(value: nil)
        }
        guard let value = encoded as? NSDictionary,
              let keys = value.allKeys as? [String],
              Set(keys).isSubset(of: [
                "guestIdentityIntent", "clipboardPolicy",
                "desktopRuntimePreference", "desktopGraphicsPreference",
              ]), keys.count == Set(keys).count else {
            return nil
        }

        var identity = DoryVMGuestIdentityIntent.unspecified
        if let encodedIdentity = value["guestIdentityIntent"] {
            guard let rawIdentity = encodedIdentity as? NSDictionary,
                  let identityKeys = rawIdentity.allKeys as? [String],
                  Set(identityKeys).isSubset(of: ["account", "desktop"]),
                  identityKeys.count == Set(identityKeys).count else { return nil }
            if let encodedAccount = rawIdentity["account"] {
                guard let raw = encodedAccount as? NSDictionary,
                      let rawKeys = raw.allKeys as? [String],
                      Set(rawKeys).isSubset(of: ["username", "numericUserID"]),
                      rawKeys.count == Set(rawKeys).count else { return nil }
                let username: String?
                if let encoded = raw["username"] {
                    guard let string = encoded as? String,
                          DoryVMGuestAccountIntent.isValidUsername(string) else { return nil }
                    username = string
                } else { username = nil }
                let numericUserID: UInt32?
                if let encoded = raw["numericUserID"] {
                    guard let number = encoded as? NSNumber,
                          CFGetTypeID(number) != CFBooleanGetTypeID(),
                          number.doubleValue == Double(number.uint32Value),
                          DoryVMGuestAccountIntent.isValidNumericUserID(number.uint32Value)
                    else { return nil }
                    numericUserID = number.uint32Value
                } else { numericUserID = nil }
                let account = DoryVMGuestAccountIntent(
                    username: username,
                    numericUserID: numericUserID
                )
                guard account.isValidForPersistence else { return nil }
                identity.account = account
            }
            if let encodedDesktop = rawIdentity["desktop"] {
                guard let raw = encodedDesktop as? NSDictionary,
                      let rawKeys = raw.allKeys as? [String],
                      Set(rawKeys).isSubset(of: [
                        "distributionIdentifier", "displayName", "version",
                        "desktopEnvironment",
                      ]), rawKeys.count == Set(rawKeys).count else { return nil }
                func string(_ key: String, validating: (String) -> Bool) -> String? {
                    guard let encoded = raw[key] else { return nil }
                    guard let value = encoded as? String, validating(value) else { return nil }
                    return value
                }
                let distribution = string(
                    "distributionIdentifier",
                    validating: DoryVMDesktopIdentityIntent.isValidDistributionIdentifier
                )
                if raw["distributionIdentifier"] != nil, distribution == nil { return nil }
                let displayName = string(
                    "displayName", validating: DoryVMDesktopIdentityIntent.isValidLabel
                )
                if raw["displayName"] != nil, displayName == nil { return nil }
                let version = string(
                    "version", validating: DoryVMDesktopIdentityIntent.isValidLabel
                )
                if raw["version"] != nil, version == nil { return nil }
                let desktopEnvironment = string(
                    "desktopEnvironment", validating: DoryVMDesktopIdentityIntent.isValidLabel
                )
                if raw["desktopEnvironment"] != nil, desktopEnvironment == nil { return nil }
                let desktop = DoryVMDesktopIdentityIntent(
                    distributionIdentifier: distribution,
                    displayName: displayName,
                    version: version,
                    desktopEnvironment: desktopEnvironment
                )
                guard desktop.isValidForPersistence else { return nil }
                identity.desktop = desktop
            }
        }

        let clipboard: DoryVMClipboardPolicy?
        if let encoded = value["clipboardPolicy"] {
            guard let raw = encoded as? NSDictionary,
                  let rawKeys = raw.allKeys as? [String],
                  Set(rawKeys) == ["text", "image", "files"],
                  let text = (raw["text"] as? String).flatMap(DoryVMClipboardDirection.init),
                  let image = (raw["image"] as? String).flatMap(DoryVMClipboardDirection.init),
                  let files = (raw["files"] as? String).flatMap(DoryVMClipboardDirection.init)
            else { return nil }
            clipboard = DoryVMClipboardPolicy(text: text, image: image, files: files)
        } else { clipboard = nil }
        let runtime: DoryDesktopVMMPreference?
        if let encoded = value["desktopRuntimePreference"] {
            guard let raw = encoded as? String,
                  let parsed = DoryDesktopVMMPreference(rawValue: raw) else { return nil }
            runtime = parsed
        } else { runtime = nil }
        let graphics: DoryDesktopGraphicsPreference?
        if let encoded = value["desktopGraphicsPreference"] {
            guard let raw = encoded as? String,
                  let parsed = DoryDesktopGraphicsPreference(rawValue: raw) else { return nil }
            graphics = parsed
        } else { graphics = nil }
        return ParsedMachineTypedSettings(value: DorydMachineTypedSettings(
            guestIdentityIntent: identity,
            clipboardPolicy: clipboard,
            runtimePreference: runtime,
            graphicsPreference: graphics
        ))
    }

    private struct ParsedInstalledDesktopPayloadReceipt {
        var value: DorydInstalledDesktopPayloadReceipt?
    }

    /// Only absence gets legacy compatibility. A present typed receipt is an evidence claim and
    /// malformed or future-schema values fail the entire row instead of downgrading to env.
    nonisolated private static func machineInstalledDesktopPayloadReceipt(
        from dictionary: NSDictionary,
        legacyEnvironment: [String: String]? = nil
    ) -> ParsedInstalledDesktopPayloadReceipt? {
        guard let encoded = dictionary["installedDesktopPayloadReceipt"] else {
            return ParsedInstalledDesktopPayloadReceipt(
                value: legacyEnvironment.flatMap(
                    DorydInstalledDesktopPayloadReceipt.legacyEnvironment
                )
            )
        }
        guard let receiptDictionary = encoded as? NSDictionary,
              let receipt = strictInstalledDesktopPayloadReceipt(from: receiptDictionary),
              receipt.isValid else {
            return nil
        }
        return ParsedInstalledDesktopPayloadReceipt(value: receipt)
    }

    nonisolated private static func strictInstalledDesktopPayloadReceipt(
        from dictionary: NSDictionary
    ) -> DorydInstalledDesktopPayloadReceipt? {
        let allowed: Set<String> = [
            "schemaVersion", "provenance", "distributionIdentifier", "releaseVersion",
            "inputSHA256", "bundleSHA256", "distributionComponentIdentifier",
            "distributionInstallationName", "distributionCatalogSHA256",
            "bundleAssetIdentifier", "runtimeComponentIdentifier", "runtimeInstallationName",
            "runtimeCatalogSHA256", "kernelAssetIdentifier", "kernelSHA256",
        ]
        guard let keys = dictionary.allKeys as? [String], Set(keys).isSubset(of: allowed),
              keys.count == Set(keys).count,
              let schemaNumber = dictionary["schemaVersion"] as? NSNumber,
              CFGetTypeID(schemaNumber) != CFBooleanGetTypeID(),
              schemaNumber.uint64Value == 1,
              schemaNumber.doubleValue == 1,
              let provenance = dictionary["provenance"] as? String,
              let distributionIdentifier = dictionary["distributionIdentifier"] as? String,
              let releaseVersion = dictionary["releaseVersion"] as? String,
              let inputSHA256 = dictionary["inputSHA256"] as? String else {
            return nil
        }
        let optionalKeys = allowed.subtracting([
            "schemaVersion", "provenance", "distributionIdentifier", "releaseVersion",
            "inputSHA256",
        ])
        for key in optionalKeys where dictionary[key] != nil {
            guard dictionary[key] is String else { return nil }
        }
        let receipt = DorydInstalledDesktopPayloadReceipt(
            schemaVersion: 1,
            provenance: provenance,
            distributionIdentifier: distributionIdentifier,
            releaseVersion: releaseVersion,
            inputSHA256: inputSHA256,
            bundleSHA256: dictionary["bundleSHA256"] as? String,
            distributionComponentIdentifier: dictionary["distributionComponentIdentifier"] as? String,
            distributionInstallationName: dictionary["distributionInstallationName"] as? String,
            distributionCatalogSHA256: dictionary["distributionCatalogSHA256"] as? String,
            bundleAssetIdentifier: dictionary["bundleAssetIdentifier"] as? String,
            runtimeComponentIdentifier: dictionary["runtimeComponentIdentifier"] as? String,
            runtimeInstallationName: dictionary["runtimeInstallationName"] as? String,
            runtimeCatalogSHA256: dictionary["runtimeCatalogSHA256"] as? String,
            kernelAssetIdentifier: dictionary["kernelAssetIdentifier"] as? String,
            kernelSHA256: dictionary["kernelSHA256"] as? String
        )
        return receipt.isValid ? receipt : nil
    }

    /// Only an absent key is compatible with an older daemon. A present identity is an evidence
    /// claim and must decode and validate exactly; malformed or future-schema claims fail closed.
    nonisolated private static func machineRuntimeIdentity(
        from dictionary: NSDictionary
    ) -> DorydMachineRuntimeIdentity? {
        guard let encoded = dictionary["runtimeIdentity"] else {
            return .legacyCompatibility
        }
        guard let identity = decoded(DorydMachineRuntimeIdentity.self, from: encoded),
              identity.isValid else {
            return nil
        }
        return identity
    }

    nonisolated private static func machineShares(from value: Any?) -> [DorydMachineShareConfiguration] {
        let rows: [NSDictionary]
        if let swiftRows = value as? [NSDictionary] {
            rows = swiftRows
        } else if let nsRows = value as? NSArray {
            rows = nsRows.compactMap { $0 as? NSDictionary }
        } else {
            return []
        }
        return rows.compactMap { row in
            guard let tag = row["tag"] as? String,
                  let hostPath = row["hostPath"] as? String,
                  let guestPath = row["guestPath"] as? String else {
                return nil
            }
            let readOnly = (row["readOnly"] as? Bool)
                ?? (row["readOnly"] as? NSNumber)?.boolValue
                ?? ((row["mode"] as? String) == "ro")
            return DorydMachineShareConfiguration(
                tag: tag,
                hostPath: hostPath,
                guestPath: guestPath,
                readOnly: readOnly
            )
        }
    }

    nonisolated private static func machineEnvironment(from value: Any?) -> [String: String] {
        let rows: [NSDictionary]
        if let swiftRows = value as? [NSDictionary] {
            rows = swiftRows
        } else if let nsRows = value as? NSArray {
            rows = nsRows.compactMap { $0 as? NSDictionary }
        } else {
            return [:]
        }
        var result: [String: String] = [:]
        for row in rows {
            guard let key = row["key"] as? String,
                  key.wholeMatch(of: /[A-Za-z_][A-Za-z0-9_]*/) != nil else {
                continue
            }
            result[key] = (row["value"] as? String) ?? ""
        }
        return result
    }

    nonisolated private static func machineStatuses(from rows: NSArray) -> [DorydMachineStatus]? {
        let dictionaries = rows.compactMap { $0 as? NSDictionary }
        guard dictionaries.count == rows.count else { return nil }
        let statuses = dictionaries.compactMap(machineStatus(from:))
        guard statuses.count == dictionaries.count else { return nil }
        return statuses
    }

    nonisolated private static func machineExecResult(from dictionary: NSDictionary) -> DorydMachineExecResult? {
        guard let exitCode = int32(dictionary["exitCode"]),
              let stdout = outputString(dictionary["stdout"]),
              let stderr = outputString(dictionary["stderr"]) else {
            return nil
        }
        return DorydMachineExecResult(
            exitCode: exitCode,
            stdout: stdout,
            stderr: stderr,
            timedOut: (dictionary["timedOut"] as? Bool) ?? false,
            stdoutTruncated: (dictionary["stdoutTruncated"] as? Bool) ?? false,
            stderrTruncated: (dictionary["stderrTruncated"] as? Bool) ?? false
        )
    }

    nonisolated private static func machineStats(from dictionary: NSDictionary) -> DorydMachineStats? {
        guard dictionary["schema"] as? String == "dev.dory.machine.stats",
              int(dictionary["version"]) == 1,
              let cpuPercent = double(dictionary["cpuPercent"]),
              let memoryUsedBytes = uint64(dictionary["memoryUsedBytes"]),
              let memoryTotalBytes = uint64(dictionary["memoryTotalBytes"]),
              let networkReceiveBytes = uint64(dictionary["networkReceiveBytes"]),
              let networkTransmitBytes = uint64(dictionary["networkTransmitBytes"]),
              let blockReadBytes = uint64(dictionary["blockReadBytes"]),
              let blockWriteBytes = uint64(dictionary["blockWriteBytes"]),
              let processCount = uint64(dictionary["processCount"]),
              let uptimeSeconds = double(dictionary["uptimeSeconds"]),
              cpuPercent >= 0, cpuPercent <= 100, memoryUsedBytes <= memoryTotalBytes else {
            return nil
        }
        return DorydMachineStats(
            cpuPercent: cpuPercent,
            memoryUsedBytes: memoryUsedBytes,
            memoryTotalBytes: memoryTotalBytes,
            networkReceiveBytes: networkReceiveBytes,
            networkTransmitBytes: networkTransmitBytes,
            blockReadBytes: blockReadBytes,
            blockWriteBytes: blockWriteBytes,
            processCount: processCount,
            uptimeSeconds: uptimeSeconds
        )
    }

    nonisolated private static func machineProvisionResult(from dictionary: NSDictionary) -> DorydMachineProvisionResult? {
        let decodedRecipeID = (dictionary["recipeID"] as? String) ?? (dictionary["recipe"] as? String)
        guard let recipeID = decodedRecipeID,
              let installDictionary = dictionary["install"] as? NSDictionary,
              let verifyDictionary = dictionary["verify"] as? NSDictionary,
              let install = machineExecResult(from: installDictionary),
              let verify = machineExecResult(from: verifyDictionary) else {
            return nil
        }
        return DorydMachineProvisionResult(recipeID: recipeID, install: install, verify: verify)
    }

    nonisolated private static func desktopUpdateResult(from dictionary: NSDictionary) -> DorydDesktopUpdateResult? {
        guard let machineID = dictionary["machineID"] as? String,
              let distro = dictionary["distro"] as? String,
              let version = dictionary["version"] as? String,
              let inputSHA256 = dictionary["inputSHA256"] as? String,
              let bundleSHA256 = dictionary["bundleSHA256"] as? String,
              let snapshotID = dictionary["snapshotID"] as? String,
              let statusDictionary = dictionary["status"] as? NSDictionary,
              let status = machineStatus(from: statusDictionary),
              let restoredRunningState = dictionary["restoredRunningState"] as? Bool else {
            return nil
        }
        return DorydDesktopUpdateResult(
            machineID: machineID,
            distro: distro,
            version: version,
            inputSHA256: inputSHA256,
            bundleSHA256: bundleSHA256,
            snapshotID: snapshotID,
            status: status,
            restoredRunningState: restoredRunningState
        )
    }

    nonisolated private static func machineSnapshot(from dictionary: NSDictionary) -> DorydMachineSnapshot? {
        guard let id = dictionary["id"] as? String,
              let machineID = dictionary["machineID"] as? String,
              let note = dictionary["note"] as? String,
              let createdISO = dictionary["createdISO"] as? String,
              let rootfsPath = dictionary["rootfsPath"] as? String,
              let sizeBytes = int64(dictionary["sizeBytes"]),
              let kernelPath = dictionary["kernelPath"] as? String,
              let architecture = dictionary["architecture"] as? String,
              let memoryMB = uint64(dictionary["memoryMB"]),
              let cpuCount = int(dictionary["cpuCount"]),
              let runtimeIdentity = machineRuntimeIdentity(from: dictionary),
              let installedDesktopPayloadReceipt = machineInstalledDesktopPayloadReceipt(
                  from: dictionary
              ),
              let consistency = machineSnapshotConsistency(from: dictionary),
              let guestQuiesceReceipt = machineSnapshotQuiesceReceipt(
                  from: dictionary,
                  consistency: consistency
              ),
              let artifactEvidence = machineSnapshotArtifactEvidence(
                  from: dictionary,
                  runtimeIdentity: runtimeIdentity
              ) else {
            return nil
        }
        return DorydMachineSnapshot(
            id: id,
            machineID: machineID,
            note: note,
            createdISO: createdISO,
            rootfsPath: rootfsPath,
            sizeBytes: sizeBytes,
            kernelPath: kernelPath,
            architecture: architecture,
            memoryMB: memoryMB,
            cpuCount: cpuCount,
            runtimeIdentity: runtimeIdentity,
            artifactEvidence: artifactEvidence.value,
            installedDesktopPayloadReceipt: installedDesktopPayloadReceipt.value,
            consistency: consistency,
            guestQuiesceReceipt: guestQuiesceReceipt.value
        )
    }

    /// Absence preserves compatibility with older daemons. Once the field is present, its type
    /// and value are closed so invented consistency claims cannot be displayed as trusted facts.
    nonisolated private static func machineSnapshotConsistency(
        from dictionary: NSDictionary
    ) -> DorydMachineSnapshotConsistency? {
        guard let encoded = dictionary["consistency"] else { return .coldStopped }
        guard let rawValue = encoded as? String else { return nil }
        return DorydMachineSnapshotConsistency(rawValue: rawValue)
    }

    private struct ParsedMachineSnapshotQuiesceReceipt {
        var value: DorydMachineSnapshotQuiesceReceipt?
    }

    nonisolated private static func machineSnapshotQuiesceReceipt(
        from dictionary: NSDictionary,
        consistency: DorydMachineSnapshotConsistency
    ) -> ParsedMachineSnapshotQuiesceReceipt? {
        guard let encoded = dictionary["guestQuiesceReceipt"] else {
            guard consistency == .coldStopped else { return nil }
            return ParsedMachineSnapshotQuiesceReceipt(value: nil)
        }
        guard consistency == .guestQuiesced,
              let raw = encoded as? NSDictionary,
              let keys = raw.allKeys as? [String],
              Set(keys) == [
                  "schemaVersion",
                  "receiptID",
                  "agentBuild",
                  "agentProtocolVersion",
                  "capabilityVersion",
              ],
              keys.count == 5,
              let schemaVersion = uint16(raw["schemaVersion"]),
              let receiptID = raw["receiptID"] as? String,
              let agentBuild = raw["agentBuild"] as? String,
              let agentProtocolVersion = uint32(raw["agentProtocolVersion"]),
              let capabilityVersion = uint32(raw["capabilityVersion"]) else {
            return nil
        }
        let receipt = DorydMachineSnapshotQuiesceReceipt(
            schemaVersion: schemaVersion,
            receiptID: receiptID,
            agentBuild: agentBuild,
            agentProtocolVersion: agentProtocolVersion,
            capabilityVersion: capabilityVersion
        )
        guard receipt.isValid else { return nil }
        return ParsedMachineSnapshotQuiesceReceipt(value: receipt)
    }

    private struct ParsedMachineSnapshotArtifactEvidence {
        var value: DorydMachineSnapshotArtifactEvidence?
    }

    /// Artifact evidence follows the same compatibility rule as runtime identity: absence is
    /// accepted only for snapshots from a legacy daemon. A present claim must be well formed,
    /// and every non-legacy identity requires evidence.
    nonisolated private static func machineSnapshotArtifactEvidence(
        from dictionary: NSDictionary,
        runtimeIdentity: DorydMachineRuntimeIdentity
    ) -> ParsedMachineSnapshotArtifactEvidence? {
        guard let encoded = dictionary["artifactEvidence"] else {
            guard runtimeIdentity.mode == "legacy-compatibility" else { return nil }
            return ParsedMachineSnapshotArtifactEvidence(value: nil)
        }
        guard let evidence = decoded(
            DorydMachineSnapshotArtifactEvidence.self,
            from: encoded
        ), evidence.isValid else {
            return nil
        }
        return ParsedMachineSnapshotArtifactEvidence(value: evidence)
    }

    nonisolated private static func machineSnapshots(from rows: NSArray) -> [DorydMachineSnapshot]? {
        let dictionaries = rows.compactMap { $0 as? NSDictionary }
        guard dictionaries.count == rows.count else { return nil }
        let snapshots = dictionaries.compactMap(machineSnapshot(from:))
        guard snapshots.count == dictionaries.count else { return nil }
        return snapshots
    }

    nonisolated private static func machineBackupStatus(from dictionary: NSDictionary) -> DorydMachineBackupStatus? {
        guard let machineID = dictionary["machineID"] as? String,
              let frequencyRaw = dictionary["frequency"] as? String,
              let frequency = DorydMachineBackupFrequency(rawValue: frequencyRaw),
              let enabled = dictionary["enabled"] as? Bool,
              let keepLocal = int(dictionary["keepLocal"]),
              let verifyEveryRuns = int(dictionary["verifyEveryRuns"]),
              let inProgress = dictionary["inProgress"] as? Bool,
              let successfulRuns = int(dictionary["successfulRuns"]),
              let consecutiveFailures = int(dictionary["consecutiveFailures"]),
              let retainedSnapshots = int(dictionary["retainedSnapshots"]),
              let retainedArchives = int(dictionary["retainedArchives"]) else {
            return nil
        }
        return DorydMachineBackupStatus(
            schedule: DorydMachineBackupSchedule(
                machineID: machineID,
                enabled: enabled,
                frequency: frequency,
                keepLocal: keepLocal,
                verifyEveryRuns: verifyEveryRuns
            ),
            inProgress: inProgress,
            successfulRuns: successfulRuns,
            consecutiveFailures: consecutiveFailures,
            lastAttemptISO: dictionary["lastAttemptISO"] as? String,
            lastSuccessISO: dictionary["lastSuccessISO"] as? String,
            lastVerificationISO: dictionary["lastVerificationISO"] as? String,
            lastBootVerificationISO: dictionary["lastBootVerificationISO"] as? String,
            lastSnapshotID: dictionary["lastSnapshotID"] as? String,
            lastArchivePath: dictionary["lastArchivePath"] as? String,
            nextRunISO: dictionary["nextRunISO"] as? String,
            lastError: dictionary["lastError"] as? String,
            retainedSnapshots: retainedSnapshots,
            retainedArchives: retainedArchives
        )
    }

    nonisolated private static func machineBackupStatuses(from rows: NSArray) -> [DorydMachineBackupStatus]? {
        let dictionaries = rows.compactMap { $0 as? NSDictionary }
        guard dictionaries.count == rows.count else { return nil }
        let statuses = dictionaries.compactMap(machineBackupStatus(from:))
        guard statuses.count == dictionaries.count else { return nil }
        return statuses
    }

    nonisolated private static func agentInfo(from dictionary: NSDictionary) -> DorydAgentInfo? {
        guard let protocolVersion = uint32(dictionary["protocolVersion"]),
              let kernel = dictionary["kernel"] as? String,
              let agentBuild = dictionary["agentBuild"] as? String,
              let uptimeSeconds = uint64(dictionary["uptimeSeconds"]) else {
            return nil
        }
        let capabilities: [DorydAgentCapability]
        if let encodedCapabilities = dictionary["capabilities"] {
            guard let parsed = agentCapabilities(from: encodedCapabilities) else { return nil }
            capabilities = parsed
        } else {
            capabilities = []
        }
        return DorydAgentInfo(
            protocolVersion: protocolVersion,
            kernel: kernel,
            agentBuild: agentBuild,
            uptimeSeconds: uptimeSeconds,
            capabilities: capabilities
        )
    }

    nonisolated private static func telemetry(from dictionary: NSDictionary) -> DorydTelemetry? {
        guard let memTotalKB = uint64(dictionary["memTotalKB"]),
              let memAvailableKB = uint64(dictionary["memAvailableKB"]),
              let psiSomeAvg10 = double(dictionary["psiSomeAvg10"]),
              let psiFullAvg10 = double(dictionary["psiFullAvg10"]) else {
            return nil
        }
        return DorydTelemetry(
            memTotalKB: memTotalKB,
            memAvailableKB: memAvailableKB,
            psiSomeAvg10: psiSomeAvg10,
            psiFullAvg10: psiFullAvg10
        )
    }

    nonisolated private static func listenPort(from dictionary: NSDictionary) -> DorydListenPort? {
        guard let proto = dictionary["protocol"] as? String,
              let port = uint32(dictionary["port"]) else {
            return nil
        }
        return DorydListenPort(protocol: proto, port: port)
    }

    nonisolated private static func dockerAgentPorts(from dictionary: NSDictionary) -> DorydDockerAgentPorts? {
        guard let rawPorts = dictionary["ports"] as? [NSDictionary],
              let rawAdded = dictionary["added"] as? [NSDictionary],
              let rawRemoved = dictionary["removed"] as? [NSDictionary] else {
            return nil
        }
        let ports = rawPorts.compactMap(listenPort(from:))
        let added = rawAdded.compactMap(listenPort(from:))
        let removed = rawRemoved.compactMap(listenPort(from:))
        guard ports.count == rawPorts.count,
              added.count == rawAdded.count,
              removed.count == rawRemoved.count else {
            return nil
        }
        return DorydDockerAgentPorts(ports: ports, added: added, removed: removed)
    }

    nonisolated private static func pushStats(from dictionary: NSDictionary) -> DorydPushStats? {
        guard let filesSent = uint64(dictionary["filesSent"]),
              let bytesSent = uint64(dictionary["bytesSent"]),
              let filesDeleted = uint64(dictionary["filesDeleted"]) else {
            return nil
        }
        return DorydPushStats(filesSent: filesSent, bytesSent: bytesSent, filesDeleted: filesDeleted)
    }

    nonisolated private static func remoteStatus(from dictionary: NSDictionary) -> DorydRemoteMachineStatus? {
        guard let id = dictionary["id"] as? String,
              let state = dictionary["state"] as? String else {
            return nil
        }
        return DorydRemoteMachineStatus(
            id: id,
            state: state,
            lastError: nonEmptyString(dictionary["lastError"]),
            info: (dictionary["info"] as? NSDictionary).flatMap(agentInfo(from:)),
            telemetry: (dictionary["telemetry"] as? NSDictionary).flatMap(telemetry(from:))
        )
    }

    nonisolated private static func domainRoute(from dictionary: NSDictionary) -> DorydDomainRoute? {
        guard let hostname = dictionary["hostname"] as? String,
              let address = dictionary["address"] as? String else {
            return nil
        }
        return DorydDomainRoute(
            hostname: hostname,
            address: address,
            port: uint16(dictionary["port"]) ?? 80,
            pathPrefix: nonEmptyString(dictionary["pathPrefix"]) ?? ""
        )
    }

    nonisolated private static func networkStatus(from dictionary: NSDictionary) -> DorydNetworkingStatus? {
        guard let mode = dictionary["mode"] as? String,
              let suffix = dictionary["suffix"] as? String,
              let dnsBindAddress = dictionary["dnsBindAddress"] as? String,
              let dnsPort = uint16(dictionary["dnsPort"]),
              let dnsRunning = dictionary["dnsRunning"] as? Bool,
              let rawRoutes = dictionary["routes"] as? [NSDictionary] else {
            return nil
        }
        let routes = rawRoutes.compactMap(domainRoute(from:))
        guard routes.count == rawRoutes.count else { return nil }
        let rawCustomRoutes = (dictionary["customRoutes"] as? [NSDictionary]) ?? []
        let customRoutes = rawCustomRoutes.compactMap(domainRoute(from:))
        guard customRoutes.count == rawCustomRoutes.count else { return nil }
        return DorydNetworkingStatus(
            mode: mode,
            suffix: suffix,
            dnsBindAddress: dnsBindAddress,
            dnsPort: dnsPort,
            dnsRunning: dnsRunning,
            httpProxyPort: uint16(dictionary["httpProxyPort"]),
            httpProxyRunning: (dictionary["httpProxyRunning"] as? Bool) ?? false,
            httpsProxyPort: uint16(dictionary["httpsProxyPort"]),
            httpsProxyRunning: (dictionary["httpsProxyRunning"] as? Bool) ?? false,
            routes: routes,
            customRoutes: customRoutes
        )
    }

    nonisolated private static func networkAuthorizationPlan(from dictionary: NSDictionary) -> DorydNetworkingAuthorizationPlan? {
        guard let degradedMode = dictionary["degradedMode"] as? String,
              let authorizedMode = dictionary["authorizedMode"] as? String,
              let suffix = dictionary["suffix"] as? String,
              let dnsBindAddress = dictionary["dnsBindAddress"] as? String,
              let dnsPort = uint16(dictionary["dnsPort"]),
              let httpProxyPort = uint16(dictionary["httpProxyPort"]),
              let httpsProxyPort = uint16(dictionary["httpsProxyPort"]),
              let rawRequests = dictionary["requests"] as? [NSDictionary] else {
            return nil
        }
        let requests = rawRequests.compactMap(networkAuthorizationRequest(from:))
        guard requests.count == rawRequests.count else { return nil }
        let rawForwards = dictionary["privilegedTCPForwards"] as? [NSDictionary] ?? []
        let privilegedTCPForwards = rawForwards.compactMap(privilegedTCPForward(from:))
        guard privilegedTCPForwards.count == rawForwards.count else { return nil }
        return DorydNetworkingAuthorizationPlan(
            degradedMode: degradedMode,
            authorizedMode: authorizedMode,
            suffix: suffix,
            dnsBindAddress: dnsBindAddress,
            dnsPort: dnsPort,
            httpProxyPort: httpProxyPort,
            httpsProxyPort: httpsProxyPort,
            privilegedTCPForwards: privilegedTCPForwards,
            requests: requests
        )
    }

    nonisolated private static func privilegedTCPForward(from dictionary: NSDictionary) -> DorydPrivilegedTCPForward? {
        guard let listenPort = uint16(dictionary["listenPort"]),
              let targetPort = uint16(dictionary["targetPort"]) else {
            return nil
        }
        return DorydPrivilegedTCPForward(listenPort: listenPort, targetPort: targetPort)
    }

    nonisolated private static func networkAuthorizationRequest(from dictionary: NSDictionary) -> DorydNetworkingAuthorizationRequest? {
        guard let id = dictionary["id"] as? String,
              let kind = dictionary["kind"] as? String,
              let title = dictionary["title"] as? String,
              let reason = dictionary["reason"] as? String,
              let requiresAdmin = dictionary["requiresAdmin"] as? Bool,
              let command = dictionary["command"] as? [String] else {
            return nil
        }
        return DorydNetworkingAuthorizationRequest(
            id: id,
            kind: kind,
            title: title,
            reason: reason,
            requiresAdmin: requiresAdmin,
            filePath: dictionary["filePath"] as? String,
            fileContents: dictionary["fileContents"] as? String,
            command: command
        )
    }

    nonisolated private static func hostMemorySnapshot(from dictionary: NSDictionary) -> DorydHostMemorySnapshot? {
        guard let totalBytes = uint64(dictionary["totalBytes"]),
              let availableBytes = uint64(dictionary["availableBytes"]),
              let freeBytes = uint64(dictionary["freeBytes"]),
              let availableRatio = double(dictionary["availableRatio"]),
              let pressure = dictionary["pressure"] as? String else {
            return nil
        }
        return DorydHostMemorySnapshot(
            totalBytes: totalBytes,
            availableBytes: availableBytes,
            freeBytes: freeBytes,
            availableRatio: availableRatio,
            pressure: pressure
        )
    }

    nonisolated private static func balloonTarget(from dictionary: NSDictionary) -> DorydBalloonTarget? {
        guard let id = dictionary["id"] as? String,
              let kind = dictionary["kind"] as? String,
              let currentTargetMB = uint64(dictionary["currentTargetMB"]),
              let targetMB = uint64(dictionary["targetMB"]),
              let reason = dictionary["reason"] as? String,
              let canApply = dictionary["canApply"] as? Bool else {
            return nil
        }
        return DorydBalloonTarget(
            id: id,
            kind: kind,
            currentTargetMB: currentTargetMB,
            targetMB: targetMB,
            reason: reason,
            canApply: canApply
        )
    }

    nonisolated private static func balloonPlan(from dictionary: NSDictionary) -> DorydBalloonPlan? {
        guard let hostDictionary = dictionary["host"] as? NSDictionary,
              let host = hostMemorySnapshot(from: hostDictionary),
              let rawTargets = dictionary["targets"] as? [NSDictionary],
              let rawApplicable = dictionary["applicableTargets"] as? [NSDictionary] else {
            return nil
        }
        let targets = rawTargets.compactMap(balloonTarget(from:))
        let applicableTargets = rawApplicable.compactMap(balloonTarget(from:))
        guard targets.count == rawTargets.count, applicableTargets.count == rawApplicable.count else {
            return nil
        }
        return DorydBalloonPlan(host: host, targets: targets, applicableTargets: applicableTargets)
    }

    nonisolated private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }

    nonisolated private static func outputString(_ value: Any?) -> String? {
        if let data = value as? Data {
            return String(decoding: data, as: UTF8.self)
        }
        return value as? String
    }

    nonisolated private static var machineProvisionControlTimeout: TimeInterval {
        machineExecControlTimeout(timeoutMs: 600_000) * 2
    }

    nonisolated private static func machineExecControlTimeout(timeoutMs: UInt64) -> TimeInterval {
        let effectiveTimeoutMs: UInt64 = timeoutMs == 0 ? 30_000 : min(timeoutMs, 600_000)
        return TimeInterval(effectiveTimeoutMs) / 1000 + 10
    }

    nonisolated private static func uint64(_ value: Any?) -> UInt64? {
        if let number = value as? NSNumber {
            return number.uint64Value
        }
        if let string = value as? String {
            return UInt64(string)
        }
        return value as? UInt64
    }

    nonisolated private static func uint32(_ value: Any?) -> UInt32? {
        if let number = value as? NSNumber {
            return number.uint32Value
        }
        if let string = value as? String {
            return UInt32(string)
        }
        return value as? UInt32
    }

    nonisolated private static func uint16(_ value: Any?) -> UInt16? {
        if let number = value as? NSNumber {
            let int = number.intValue
            guard int >= 0, int <= Int(UInt16.max) else { return nil }
            return UInt16(int)
        }
        if let string = value as? String {
            return UInt16(string)
        }
        return value as? UInt16
    }

    nonisolated private static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            return Int(string)
        }
        return value as? Int
    }

    nonisolated private static func int32(_ value: Any?) -> Int32? {
        if let number = value as? NSNumber {
            return number.int32Value
        }
        if let string = value as? String {
            return Int32(string)
        }
        return value as? Int32
    }

    nonisolated private static func int64(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber {
            return number.int64Value
        }
        if let string = value as? String {
            return Int64(string)
        }
        return value as? Int64
    }

    nonisolated private static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = value as? String {
            return Double(string)
        }
        return value as? Double
    }
}

nonisolated private enum DorydDaemonSigningPolicy {
    static let teamID = "864H636QW4"
    static let daemonRequirement =
        "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\" "
        + "and identifier \"doryd\""

    static var isProductionClient: Bool {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess,
              let code else {
            return false
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode else {
            return false
        }
        var signingInformation: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &signingInformation) == errSecSuccess,
              let values = signingInformation as? [CFString: Any] else {
            return false
        }
        return values[kSecCodeInfoTeamIdentifier] as? String == teamID
    }
}

nonisolated private final class DorydContinuationBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private let connection: NSXPCConnection

    init(continuation: CheckedContinuation<T, Error>, connection: NSXPCConnection) {
        self.continuation = continuation
        self.connection = connection
    }

    func resume(_ result: Result<T, Error>) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        connection.invalidate()
        continuation.resume(with: result)
    }
}
