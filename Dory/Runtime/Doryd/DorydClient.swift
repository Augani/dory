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
    func machineStart(_ machineID: String, operationID: String, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func machineStop(_ machineID: String, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func machineStop(_ machineID: String, operationID: String, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func machinePause(_ machineID: String, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func machinePause(_ machineID: String, operationID: String, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func machineSuspend(_ machineID: String, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func machineResume(_ machineID: String, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func machineResume(_ machineID: String, operationID: String, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func machineRestart(_ machineID: String, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func machineUpdate(_ machineID: String, config: NSDictionary, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func machineDelete(_ machineID: String, reply: @escaping (Bool, String) -> Void)
    func machineList(reply: @escaping (NSArray, String) -> Void)
    func machineEvents(_ afterSequence: UInt64, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func machineFlightRecorder(_ machineID: String, afterSequence: UInt64, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func machineSerialConsoleRead(_ machineID: String, cursor: NSDictionary, limit: UInt32, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func machineSerialConsoleWrite(_ machineID: String, data: NSData, reply: @escaping (Bool, String) -> Void)
    func machineStats(_ machineID: String, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func machineDeviceTelemetry(_ machineID: String, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func hostUSBDevices(reply: @escaping (Bool, NSArray, String) -> Void)
    func machineUSBAttach(_ machineID: String, busID: String, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func machineUSBDetach(_ machineID: String, busID: String, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func machineExec(_ machineID: String, request: NSDictionary, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func machineTransfer(_ machineID: String, request: NSDictionary, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func machineTransferStart(_ machineID: String, request: NSDictionary, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func machineTransferCurrent(_ machineID: String, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func machineTransferStatus(_ machineID: String, operationID: String, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func machineTransferCancel(_ machineID: String, operationID: String, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func machineGuestExportStart(_ machineID: String, request: NSDictionary, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func machineGuestExportCurrent(_ machineID: String, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func machineGuestExportStatus(_ machineID: String, operationID: String, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func machineGuestExportCancel(_ machineID: String, operationID: String, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func machineGuestExportDiscard(_ machineID: String, operationID: String, reply: @escaping (Bool, String) -> Void)
    func machineProvision(_ machineID: String, request: NSDictionary, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func machineDesktopUpdate(_ machineID: String, request: NSDictionary, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func machineSnapshot(_ machineID: String, request: NSDictionary, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func machineSnapshots(_ machineID: String, reply: @escaping (NSArray, String) -> Void)
    func machineCloneSnapshot(_ machineID: String, snapshotID: String, newID: String, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func machineRestoreSnapshot(_ machineID: String, snapshotID: String, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func machineDeleteSnapshot(_ machineID: String, snapshotID: String, reply: @escaping (Bool, String) -> Void)
    func machineExportSnapshot(_ machineID: String, snapshotID: String, path: String, reply: @escaping (Bool, String) -> Void)
    func machineAssessSnapshotImport(_ path: String, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func machineImportSnapshot(_ path: String, reply: @escaping (Bool, NSDictionary, String) -> Void)
    func machineImportSnapshot(_ path: String, expectedContentID: String, reply: @escaping (Bool, NSDictionary, String) -> Void)
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
    var authorizationBookmark: Data? = nil

    var xpcDictionary: NSDictionary {
        let dictionary = NSMutableDictionary(dictionary: [
            "tag": tag,
            "hostPath": hostPath,
            "guestPath": guestPath,
            "readOnly": readOnly,
        ])
        if let authorizationBookmark {
            dictionary["authorizationBookmark"] = authorizationBookmark as NSData
        }
        return dictionary
    }
}

nonisolated struct DorydMachineTypedSettings: Sendable, Equatable, Hashable {
    var guestIdentityIntent: DoryVMGuestIdentityIntent = .unspecified
    var clipboardPolicy: DoryVMClipboardPolicy? = nil
    var runtimePreference: DoryDesktopVMMPreference? = nil
    var graphicsPreference: DoryDesktopGraphicsPreference? = nil
    var networkMode: DoryVMNetworkMode? = nil
    var portForwards: [DoryVMPortForward] = []
    var audioConfiguration: DoryVMAudioConfiguration? = nil

    init(
        guestIdentityIntent: DoryVMGuestIdentityIntent = .unspecified,
        clipboardPolicy: DoryVMClipboardPolicy? = nil,
        runtimePreference: DoryDesktopVMMPreference? = nil,
        graphicsPreference: DoryDesktopGraphicsPreference? = nil,
        networkMode: DoryVMNetworkMode? = nil,
        portForwards: [DoryVMPortForward] = [],
        audioConfiguration: DoryVMAudioConfiguration? = nil
    ) {
        self.guestIdentityIntent = guestIdentityIntent
        self.clipboardPolicy = clipboardPolicy
        self.runtimePreference = runtimePreference
        self.graphicsPreference = graphicsPreference
        self.networkMode = networkMode
        self.portForwards = portForwards
        self.audioConfiguration = audioConfiguration
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
        networkMode = .sharedNAT
        portForwards = []
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
            audioConfiguration = DoryVMAudioConfiguration(
                inputEnabled: true,
                outputEnabled: true
            )
        } else {
            clipboardPolicy = nil
            runtimePreference = nil
            graphicsPreference = nil
            audioConfiguration = nil
        }
    }

    var isEmpty: Bool {
        guestIdentityIntent.isEmpty
            && clipboardPolicy == nil
            && runtimePreference == nil
            && graphicsPreference == nil
            && networkMode == nil
            && portForwards.isEmpty
            && audioConfiguration == nil
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
        if let networkMode {
            result["networkMode"] = networkMode.rawValue
        }
        if !portForwards.isEmpty {
            result["portForwards"] = Self.xpcPortForwards(portForwards)
        }
        if let audioConfiguration {
            result["audio"] = [
                "inputEnabled": audioConfiguration.inputEnabled,
                "outputEnabled": audioConfiguration.outputEnabled,
            ] as NSDictionary
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
        hasher.combine(networkMode?.rawValue)
        hasher.combine(portForwards)
        hasher.combine(audioConfiguration?.inputEnabled)
        hasher.combine(audioConfiguration?.outputEnabled)
    }

    fileprivate static func xpcPortForwards(_ forwards: [DoryVMPortForward]) -> NSArray {
        forwards.map { forward in
            [
                "id": forward.id,
                "transport": forward.transport.rawValue,
                "hostPort": NSNumber(value: forward.hostPort),
                "guestPort": NSNumber(value: forward.guestPort),
                "exposure": forward.exposure.rawValue,
            ] as NSDictionary
        } as NSArray
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
        Self.encodeEnum(
            baseline.networkMode,
            desired.networkMode,
            key: "networkMode",
            into: &result
        )
        if baseline.portForwards != desired.portForwards {
            result["portForwards"] = DorydMachineTypedSettings.xpcPortForwards(
                desired.portForwards
            )
        }
        Self.encodeAudio(
            baseline.audioConfiguration,
            desired.audioConfiguration,
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

    private static func encodeAudio(
        _ baseline: DoryVMAudioConfiguration?,
        _ desired: DoryVMAudioConfiguration?,
        into dictionary: inout [String: Any]
    ) {
        guard baseline != desired else { return }
        guard let desired else {
            dictionary["audio"] = NSNull()
            return
        }
        var audio: [String: Any] = [:]
        if baseline?.inputEnabled != desired.inputEnabled {
            audio["inputEnabled"] = desired.inputEnabled
        }
        if baseline?.outputEnabled != desired.outputEnabled {
            audio["outputEnabled"] = desired.outputEnabled
        }
        dictionary["audio"] = audio as NSDictionary
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
    var removableUSBHotplug: Bool? = nil
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
            && removableUSBHotplug == nil
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

    var authorizesRemovableUSBHotplug: Bool {
        mode == "resolved-plan" && removableUSBHotplug == true && isValid
    }
}

nonisolated struct DorydMachineUSBAttachment: Sendable, Equatable {
    var machineID: String
    var busID: String
    var port: Int
    var vsockPort: UInt32
    var deviceID: UInt32
    var speed: UInt32
}

nonisolated struct DorydHostUSBDevice: Sendable, Equatable, Identifiable {
    var busID: String
    var vendorID: UInt16
    var productID: UInt16
    var vendorName: String
    var productName: String
    var deviceClass: UInt8
    var speed: UInt32

    var id: String { busID }

    var displayName: String {
        if !productName.isEmpty { return productName }
        if !vendorName.isEmpty { return vendorName }
        return String(format: "%04x:%04x", vendorID, productID)
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

    var isSafeMachineIdentifier: Bool {
        let bytes = Array(utf8)
        guard (1...63).contains(bytes.count) else { return false }
        return bytes.allSatisfy { byte in
            (byte >= 48 && byte <= 57)
                || (byte >= 65 && byte <= 90)
                || (byte >= 97 && byte <= 122)
                || byte == 45 || byte == 46 || byte == 95
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

nonisolated enum DorydMachineFailureCode: String, Sendable, Equatable, Hashable {
    case lifecycleOperationFailed = "lifecycle-operation-failed"
    case lifecycleRecoveryRequired = "lifecycle-recovery-required"
    case workspaceAuthorityInvalid = "workspace-authority-invalid"
    case backendLaunchFailed = "backend-launch-failed"
    case readinessHandoffFailed = "readiness-handoff-failed"
    case readinessTimedOut = "readiness-timed-out"
    case helperExited = "helper-exited"
    case savedStateInvalid = "saved-state-invalid"
    case resourceAdmissionRejected = "resource-admission-rejected"
    case desktopUpdateRecoveryRequired = "desktop-update-recovery-required"
    case desktopUpdateRolledBack = "desktop-update-rolled-back"
    case deletionFailed = "deletion-failed"
    case diagnosticPersistenceFailed = "diagnostic-persistence-failed"
    case unclassified
}

nonisolated enum DorydMachineFailureCauseCode: String, Sendable, Equatable, Hashable {
    case configurationAuthority = "configuration-authority"
    case runtimeAuthority = "runtime-authority"
    case artifactAuthority = "artifact-authority"
    case componentAuthority = "component-authority"
    case hostQualification = "host-qualification"
    case resourceAdmission = "resource-admission"
    case processExit = "process-exit"
    case readinessGate = "readiness-gate"
    case journal
    case filesystem
    case guestAgent = "guest-agent"
    case unknown
}

nonisolated enum DorydMachineRecoveryDisposition: String, Sendable, Equatable, Hashable {
    case retry
    case replan
    case repair
    case rollbackCompleted = "rollback-completed"
    case deleteWorkspace = "delete-workspace"
    case inspectDiagnostics = "inspect-diagnostics"
}

nonisolated enum DorydMachineFailureEvidenceKind: String, Sendable, Equatable, Hashable {
    case operation
    case plan
    case backend
    case component
    case media
    case snapshot
    case savedState = "saved-state"
    case journal
    case hostQualification = "host-qualification"
}

nonisolated struct DorydMachineFailureEvidenceReference: Sendable, Equatable, Hashable {
    var kind: DorydMachineFailureEvidenceKind
    var identifier: String
}

nonisolated struct DorydMachineFailure: Sendable, Equatable, Hashable {
    var schemaVersion: UInt16
    var code: DorydMachineFailureCode
    var occurredAtUnixMilliseconds: Int64
    var operationID: String?
    var causalChain: [DorydMachineFailureCauseCode]
    var recoveryDisposition: DorydMachineRecoveryDisposition
    var evidenceReferences: [DorydMachineFailureEvidenceReference]
}

nonisolated enum DorydMachineOperationKind: String, Sendable, Equatable, Hashable {
    case importing
    case provisioning
    case resolving
    case starting
    case stopping
    case pausing
    case resuming
    case suspending
    case restoring
    case snapshotting
    case cloning
    case updating
    case repairing
    case deleting
}

nonisolated struct DorydMachineOperationSummary: Sendable, Equatable, Hashable {
    var operationID: String
    var kind: DorydMachineOperationKind
}

nonisolated struct DorydMachineStatus: Sendable, Equatable {
    var id: String
    var state: String
    var pid: Int32?
    var lastError: String?
    var failure: DorydMachineFailure? = nil
    var activeOperation: DorydMachineOperationSummary? = nil
    var flightRecorderHeadSequence: UInt64 = 0
    var flightRecorderAvailable: Bool = false
    var handoffSocketPath: String?
    var agentBuild: String?
    var agentProtocolVersion: UInt32? = nil
    var agentCapabilities: [DorydAgentCapability] = []
    var integrationHealth: DoryGuestIntegrationHealth? = nil
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
    var cloneReceipt: DorydMachineCloneReceipt? = nil
    var savedState: DorydMachineSavedStateSummary? = nil
}

nonisolated struct DorydMachineCloneReceipt: Sendable, Equatable, Hashable {
    var sourceMachineID: String
    var sourceSnapshotID: String
    var sourceRootfsSHA256: String
    var sourceRootfsByteCount: UInt64
    var storageMode: String
    var createdAtUnixMilliseconds: Int64
}

nonisolated struct DorydMachineSavedStateSummary: Sendable, Equatable {
    var stateFileSHA256: String
    var stateFileByteCount: UInt64
    var hostHardwareModel: String
    var hostOperatingSystemBuild: String
    var createdAtUnixMilliseconds: Int64
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

nonisolated enum DorydDeviceTelemetryKind: String, Sendable, Equatable, CaseIterable {
    case platform, storage, network, graphics, display, audio, balloon, entropy, input, socket
    case sharedDirectory = "shared-directory"
}

nonisolated enum DorydDeviceTelemetryHealth: String, Sendable, Equatable {
    case healthy, degraded, failed, unavailable
}

nonisolated enum DorydDeviceTelemetryMetricAvailability: String, Sendable, Equatable {
    case measured, unavailable
}

nonisolated struct DorydDeviceTelemetryMetric: Sendable, Equatable {
    var kind: String
    var unit: String
    var availability: DorydDeviceTelemetryMetricAvailability
    var value: UInt64?
    var unavailableReason: String?
}

nonisolated struct DorydDeviceTelemetryDevice: Sendable, Equatable {
    var id: String
    var kind: DorydDeviceTelemetryKind
    var health: DorydDeviceTelemetryHealth
    var metrics: [DorydDeviceTelemetryMetric]
}

nonisolated struct DorydDeviceTelemetryEvent: Sendable, Equatable {
    var sequence: UInt64
    var monotonicNanoseconds: UInt64
    var deviceID: String
    var kind: String
    var occurrences: UInt64
}

nonisolated struct DorydDeviceTelemetrySnapshot: Sendable, Equatable {
    var machineID: String
    var operationID: String
    var backend: DoryVirtualizationBackendIdentity
    var sampleSequence: UInt64
    var sampledAtUnixMilliseconds: UInt64
    var monotonicNanoseconds: UInt64
    var devices: [DorydDeviceTelemetryDevice]
    var events: [DorydDeviceTelemetryEvent]
}

nonisolated struct DorydMachineProvisionResult: Sendable, Equatable {
    var recipeID: String
    var install: DorydMachineExecResult
    var verify: DorydMachineExecResult
}

nonisolated struct DorydDesktopUpdateResult: Sendable, Equatable {
    var operationID: String?
    var machineID: String
    var distro: String
    var version: String
    var inputSHA256: String
    var bundleSHA256: String
    var snapshotID: String
    var status: DorydMachineStatus
    var restoredRunningState: Bool
}

nonisolated enum DorydMachineEventKind: String, Sendable, Equatable {
    case updated
    case removed
}

nonisolated struct DorydMachineEventStatus: Sendable, Equatable {
    var machineID: String
    var configurationRevision: String
    var observedRevision: String
    var state: String
    var hasFailure: Bool
    var failureCode: DorydMachineFailureCode?
    var recoveryDisposition: DorydMachineRecoveryDisposition?
    var operationID: String?
    var operationKind: DorydMachineOperationKind?
    var memoryMB: UInt64
    var cpuCount: Int
    var displayMode: String
    var bootMode: String
    var installerMediaAttached: Bool
    var shareCount: Int
    var integrationHealth: String
    var runtimeMode: String
    var virtualHardwareABIVersion: UInt16
    var planRevision: UInt64?
    var planSHA256: String?
    var backend: DoryVirtualizationBackendIdentity?
    var savedStateSHA256: String?
}

nonisolated struct DorydMachineEvent: Sendable, Equatable {
    var sequence: UInt64
    var observedAtUnixMilliseconds: Int64
    var machineID: String
    var kind: DorydMachineEventKind
    var status: DorydMachineEventStatus?
}

nonisolated struct DorydMachineEventBatch: Sendable, Equatable {
    var headSequence: UInt64
    var snapshotRequired: Bool
    var events: [DorydMachineEvent]
}

nonisolated enum DorydMachineFlightEventKind: String, Sendable, Equatable {
    case workspaceCreated = "workspace-created"
    case operationStarted = "operation-started"
    case operationPhase = "operation-phase"
    case backendSpawned = "backend-spawned"
    case readinessAccepted = "readiness-accepted"
    case readinessRejected = "readiness-rejected"
    case resourceTransition = "resource-transition"
    case deviceHealthEvent = "device-health-event"
    case processExited = "process-exited"
    case failureRecorded = "failure-recorded"
    case operationCompleted = "operation-completed"
    case operationFailed = "operation-failed"
    case recoveryRequired = "recovery-required"
    case workspaceDeleted = "workspace-deleted"
}

nonisolated struct DorydMachineFlightEvent: Sendable, Equatable {
    var sequence: UInt64
    var occurredAtUnixMilliseconds: Int64
    var machineID: String
    var operationID: String?
    var operationKind: DorydMachineOperationKind?
    var kind: DorydMachineFlightEventKind
    var phase: String?
    var machineState: String?
    var failureCode: DorydMachineFailureCode?
    var recoveryDisposition: DorydMachineRecoveryDisposition?
    var backend: DoryVirtualizationBackendIdentity?
    var virtualHardwareABIVersion: UInt16?
    var planSHA256: String?
    var durationMilliseconds: UInt64?
    var deadlineUnixMilliseconds: Int64?
    var deviceID: String?
    var deviceEventKind: String?
    var deviceEventSequence: UInt64?
    var deviceEventOccurrences: UInt64?
    var evidenceReferences: [DorydMachineFailureEvidenceReference]
}

nonisolated struct DorydMachineFlightRecorderBatch: Sendable, Equatable {
    var machineID: String
    var headSequence: UInt64
    var snapshotRequired: Bool
    var events: [DorydMachineFlightEvent]
}

nonisolated struct DorydMachineSerialConsoleCursor: Sendable, Equatable, Hashable {
    var generation: String? = nil
    var offset: UInt64 = 0

    var xpcDictionary: NSDictionary {
        var dictionary: [String: Any] = [
            "schemaVersion": UInt16(1),
            "offset": offset,
        ]
        if let generation { dictionary["generation"] = generation }
        return dictionary as NSDictionary
    }
}

nonisolated struct DorydMachineSerialConsoleBatch: Sendable, Equatable {
    var machineID: String
    var generation: String?
    var startOffset: UInt64
    var nextOffset: UInt64
    var totalBytes: UInt64
    var snapshotRequired: Bool
    var inputAvailable: Bool
    var bytes: Data

    var cursor: DorydMachineSerialConsoleCursor {
        DorydMachineSerialConsoleCursor(generation: generation, offset: nextOffset)
    }
}

nonisolated enum DorydMachineImportDisposition: String, Sendable, Equatable {
    case ready
    case requiresComponents = "requires-components"
    case requiresReplanning = "requires-replanning"
    case unavailable
}

nonisolated enum DorydMachineImportComponentAvailability: String, Sendable, Equatable {
    case available
    case mismatched
    case missing
}

nonisolated struct DorydMachineImportComponentAssessment: Sendable, Equatable {
    var componentIdentifier: String
    var buildIdentifier: String
    var artifactSHA256: String
    var availability: DorydMachineImportComponentAvailability
}

nonisolated struct DorydMachineImportAssessment: Sendable, Equatable {
    var schemaVersion: UInt16
    var contentID: String
    var sourceMachineID: String
    var sourceSnapshotID: String
    var architecture: String
    var bootMode: String
    var diskSizeBytes: UInt64
    var virtualHardwareABIVersion: UInt16
    var sourceRuntimeMode: String
    var sourceBackend: DoryVirtualizationBackendIdentity?
    var portable: Bool
    var disposition: DorydMachineImportDisposition
    var issues: [String]
    var components: [DorydMachineImportComponentAssessment]
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

nonisolated struct DorydMachineFileTransferResult: Sendable, Equatable {
    var transferID: String
    var guestDestination: String
    var filesSent: UInt64
    var bytesSent: UInt64
}

nonisolated enum DorydMachineFileTransferPhase: String, Sendable, Equatable {
    case preparing
    case transferring
    case finalizing
    case cancelling
    case completed
    case cancelled
    case failed

    var isTerminal: Bool {
        switch self {
        case .completed, .cancelled, .failed:
            true
        case .preparing, .transferring, .finalizing, .cancelling:
            false
        }
    }
}

nonisolated enum DorydMachineFileTransferFailureCode: String, Sendable, Equatable {
    case guestUnavailable = "guest-unavailable"
    case guestPreparationFailed = "guest-preparation-failed"
    case transferFailed = "transfer-failed"
    case guestFinalizationFailed = "guest-finalization-failed"
}

nonisolated struct DorydMachineFileTransferFailure: Sendable, Equatable {
    var code: DorydMachineFileTransferFailureCode
    var message: String
}

nonisolated struct DorydMachineFileTransferOperation: Sendable, Equatable {
    var operationID: String
    var machineID: String
    var phase: DorydMachineFileTransferPhase
    var filesTotal: UInt64
    var filesCompleted: UInt64
    var bytesTotal: UInt64
    var bytesCompleted: UInt64
    var currentPath: String?
    var guestDestination: String?
    var result: DorydMachineFileTransferResult?
    var failure: DorydMachineFileTransferFailure?

    var fractionCompleted: Double {
        if phase == .completed {
            return 1
        }
        if bytesTotal > 0 {
            return min(1, Double(bytesCompleted) / Double(bytesTotal))
        }
        if filesTotal > 0 {
            return min(1, Double(filesCompleted) / Double(filesTotal))
        }
        return 0
    }
}

nonisolated private struct DorydMachineFileTransferCurrent: Sendable {
    var operation: DorydMachineFileTransferOperation?
}

/// A daemon-owned, short-lived handoff containing bytes verified by the guest pull protocol.
/// The private root is available only on an exact completed operation and must be discarded after
/// the app materializes it into a user-selected destination.
nonisolated struct DorydMachineGuestFileExportResult: Sendable, Equatable {
    var exportID: String
    var privateStagingRoot: String
    var filesReceived: UInt64
    var directoriesReceived: UInt64
    var bytesReceived: UInt64
}

nonisolated struct DorydMachineGuestFileExportOperation: Sendable, Equatable {
    var operationID: String
    var machineID: String
    var phase: DorydMachineFileTransferPhase
    var filesTotal: UInt64
    var filesCompleted: UInt64
    var bytesTotal: UInt64
    var bytesCompleted: UInt64
    var currentPath: String?
    var result: DorydMachineGuestFileExportResult?
    var failure: DorydMachineFileTransferFailure?

    var fractionCompleted: Double {
        if phase == .completed {
            return 1
        }
        if bytesTotal > 0 {
            return min(1, Double(bytesCompleted) / Double(bytesTotal))
        }
        if filesTotal > 0 {
            return min(1, Double(filesCompleted) / Double(filesTotal))
        }
        return 0
    }
}

nonisolated private struct DorydMachineGuestFileExportCurrent: Sendable {
    var operation: DorydMachineGuestFileExportOperation?
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

    func machineStart(
        _ machineID: String,
        operationID: UUID = UUID()
    ) async throws -> DorydMachineStatus {
        try await withTimeout(atLeast: 120).statusCommand { proxy, reply in
            proxy.machineStart(
                machineID,
                operationID: operationID.uuidString.lowercased(),
                reply: reply
            )
        } decode: {
            Self.machineStatus(from: $0)
        }
    }

    func machineStop(
        _ machineID: String,
        operationID: UUID = UUID()
    ) async throws -> DorydMachineStatus {
        try await withTimeout(atLeast: 30).statusCommand { proxy, reply in
            proxy.machineStop(
                machineID,
                operationID: operationID.uuidString.lowercased(),
                reply: reply
            )
        } decode: {
            Self.machineStatus(from: $0)
        }
    }

    func machinePause(
        _ machineID: String,
        operationID: UUID = UUID()
    ) async throws -> DorydMachineStatus {
        try await withTimeout(atLeast: 30).statusCommand { proxy, reply in
            proxy.machinePause(
                machineID,
                operationID: operationID.uuidString.lowercased(),
                reply: reply
            )
        } decode: {
            Self.machineStatus(from: $0)
        }
    }

    func machineSuspend(_ machineID: String) async throws -> DorydMachineStatus {
        try await withTimeout(atLeast: 15 * 60).statusCommand { proxy, reply in
            proxy.machineSuspend(machineID, reply: reply)
        } decode: {
            Self.machineStatus(from: $0)
        }
    }

    func machineResume(
        _ machineID: String,
        operationID: UUID = UUID()
    ) async throws -> DorydMachineStatus {
        try await withTimeout(atLeast: 30).statusCommand { proxy, reply in
            proxy.machineResume(
                machineID,
                operationID: operationID.uuidString.lowercased(),
                reply: reply
            )
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

    func machineTransfer(
        _ machineID: String,
        staged: DoryStagedMachineFileTransfer
    ) async throws -> DorydMachineFileTransferResult {
        let request: NSDictionary = [
            "schema": UInt16(1),
            "privateStagingRoot": staged.rootPath,
        ]
        return try await withTimeout(
            atLeast: Self.machineTransferControlTimeout(byteCount: staged.byteCount)
        ).statusCommand { proxy, reply in
            proxy.machineTransfer(machineID, request: request, reply: reply)
        } decode: { dictionary in
            guard let result = Self.machineFileTransferResult(from: dictionary),
                  result.filesSent == staged.fileCount,
                  result.bytesSent == staged.byteCount else {
                return nil
            }
            return result
        }
    }

    func machineTransferStart(
        _ machineID: String,
        staged: DoryStagedMachineFileTransfer
    ) async throws -> DorydMachineFileTransferOperation {
        let request: NSDictionary = [
            "schema": UInt16(2),
            "privateStagingRoot": staged.rootPath,
        ]
        return try await withTimeout(atLeast: 10).statusCommand { proxy, reply in
            proxy.machineTransferStart(machineID, request: request, reply: reply)
        } decode: { dictionary in
            guard let operation = Self.machineFileTransferOperation(from: dictionary),
                  operation.machineID == machineID else {
                return nil
            }
            return operation
        }
    }

    func machineTransferStatus(
        _ machineID: String,
        operationID: String
    ) async throws -> DorydMachineFileTransferOperation {
        try await withTimeout(atLeast: 10).statusCommand { proxy, reply in
            proxy.machineTransferStatus(machineID, operationID: operationID, reply: reply)
        } decode: { dictionary in
            guard let operation = Self.machineFileTransferOperation(from: dictionary),
                  operation.machineID == machineID,
                  operation.operationID == operationID else {
                return nil
            }
            return operation
        }
    }

    func machineTransferCurrent(
        _ machineID: String
    ) async throws -> DorydMachineFileTransferOperation? {
        let current: DorydMachineFileTransferCurrent = try await withTimeout(
            atLeast: 10
        ).statusCommand { proxy, reply in
            proxy.machineTransferCurrent(machineID, reply: reply)
        } decode: { dictionary in
            Self.machineFileTransferCurrent(from: dictionary, machineID: machineID)
        }
        return current.operation
    }

    func machineTransferCancel(
        _ machineID: String,
        operationID: String
    ) async throws -> DorydMachineFileTransferOperation {
        try await withTimeout(atLeast: 10).statusCommand { proxy, reply in
            proxy.machineTransferCancel(machineID, operationID: operationID, reply: reply)
        } decode: { dictionary in
            guard let operation = Self.machineFileTransferOperation(from: dictionary),
                  operation.machineID == machineID,
                  operation.operationID == operationID else {
                return nil
            }
            return operation
        }
    }

    func machineGuestExportStart(
        _ machineID: String,
        guestSource: String
    ) async throws -> DorydMachineGuestFileExportOperation {
        let request: NSDictionary = [
            "schema": UInt16(1),
            "guestSource": guestSource,
        ]
        let accepted: DorydMachineGuestFileExportOperation = try await withTimeout(
            atLeast: 10
        ).statusCommand { proxy, reply in
            proxy.machineGuestExportStart(machineID, request: request, reply: reply)
        } decode: { dictionary in
            guard let operation = Self.machineGuestFileExportOperation(
                from: dictionary,
                allowsOmittedCompletedResult: true
            ), operation.machineID == machineID else {
                return nil
            }
            return operation
        }
        if accepted.phase == .completed, accepted.result == nil {
            return try await machineGuestExportStatus(
                machineID,
                operationID: accepted.operationID
            )
        }
        return accepted
    }

    func machineGuestExportStatus(
        _ machineID: String,
        operationID: String
    ) async throws -> DorydMachineGuestFileExportOperation {
        try await withTimeout(atLeast: 10).statusCommand { proxy, reply in
            proxy.machineGuestExportStatus(machineID, operationID: operationID, reply: reply)
        } decode: { dictionary in
            guard let operation = Self.machineGuestFileExportOperation(from: dictionary),
                  operation.machineID == machineID,
                  operation.operationID == operationID else {
                return nil
            }
            return operation
        }
    }

    func machineGuestExportCurrent(
        _ machineID: String
    ) async throws -> DorydMachineGuestFileExportOperation? {
        let current: DorydMachineGuestFileExportCurrent = try await withTimeout(
            atLeast: 10
        ).statusCommand { proxy, reply in
            proxy.machineGuestExportCurrent(machineID, reply: reply)
        } decode: { dictionary in
            Self.machineGuestFileExportCurrent(from: dictionary, machineID: machineID)
        }
        return current.operation
    }

    func machineGuestExportCancel(
        _ machineID: String,
        operationID: String
    ) async throws -> DorydMachineGuestFileExportOperation {
        try await withTimeout(atLeast: 10).statusCommand { proxy, reply in
            proxy.machineGuestExportCancel(machineID, operationID: operationID, reply: reply)
        } decode: { dictionary in
            guard let operation = Self.machineGuestFileExportOperation(from: dictionary),
                  operation.machineID == machineID,
                  operation.operationID == operationID else {
                return nil
            }
            return operation
        }
    }

    func machineGuestExportDiscard(
        _ machineID: String,
        operationID: String
    ) async throws -> DorydCommandResult {
        try await command { proxy, reply in
            proxy.machineGuestExportDiscard(
                machineID,
                operationID: operationID,
                reply: reply
            )
        }
    }

    func machineStats(_ machineID: String) async throws -> DorydMachineStats {
        try await withTimeout(atLeast: 10).statusCommand { proxy, reply in
            proxy.machineStats(machineID, reply: reply)
        } decode: {
            Self.machineStats(from: $0)
        }
    }

    func machineDeviceTelemetry(_ machineID: String) async throws
        -> DorydDeviceTelemetrySnapshot {
        try await withTimeout(atLeast: 10).statusCommand { proxy, reply in
            proxy.machineDeviceTelemetry(machineID, reply: reply)
        } decode: {
            Self.machineDeviceTelemetry(from: $0, machineID: machineID)
        }
    }

    func machineUSBAttach(
        _ machineID: String,
        busID: String
    ) async throws -> DorydMachineUSBAttachment {
        try await withTimeout(atLeast: 30).statusCommand { proxy, reply in
            proxy.machineUSBAttach(machineID, busID: busID, reply: reply)
        } decode: {
            Self.machineUSBAttachment(
                from: $0,
                expectedMachineID: machineID,
                expectedBusID: busID
            )
        }
    }

    func hostUSBDevices() async throws -> [DorydHostUSBDevice] {
        try await call { proxy, finish in
            proxy.hostUSBDevices { ok, rows, message in
                guard ok else {
                    finish(.failure(DorydClientError.daemon(message)))
                    return
                }
                guard let devices = Self.hostUSBDevices(from: rows) else {
                    finish(.failure(DorydClientError.daemon(
                        message.isEmpty ? "invalid host USB device list" : message
                    )))
                    return
                }
                finish(.success(devices))
            }
        }
    }

    func machineUSBDetach(_ machineID: String, busID: String) async throws {
        _ = try await withTimeout(atLeast: 30).statusCommand { proxy, reply in
            proxy.machineUSBDetach(machineID, busID: busID, reply: reply)
        } decode: { response -> Bool? in
            guard let keys = response.allKeys as? [String],
                  Set(keys) == ["machineID", "busID"],
                  response["machineID"] as? String == machineID,
                  response["busID"] as? String == busID else {
                return nil
            }
            return true
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
        operationID: UUID = UUID(),
        distro: String,
        version: String,
        distributionInstallationName: String,
        runtimeInstallationName: String
    ) async throws -> DorydDesktopUpdateResult {
        let request: NSDictionary = [
            "operationID": operationID.uuidString.lowercased(),
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

    func machineAssessSnapshotImport(
        from path: String
    ) async throws -> DorydMachineImportAssessment {
        try await withTimeout(atLeast: 120).statusCommand { proxy, reply in
            proxy.machineAssessSnapshotImport(path, reply: reply)
        } decode: {
            Self.machineImportAssessment(from: $0)
        }
    }

    func machineImportSnapshot(
        from path: String,
        expectedContentID: String
    ) async throws -> DorydMachineSnapshot {
        try await withTimeout(atLeast: 120).statusCommand { proxy, reply in
            proxy.machineImportSnapshot(
                path,
                expectedContentID: expectedContentID,
                reply: reply
            )
        } decode: {
            Self.machineSnapshot(from: $0)
        }
    }

    /// Compatibility entry for older call sites. New product flows assess first and use the
    /// content-bound overload above.
    func machineImportSnapshot(from path: String) async throws -> DorydMachineSnapshot {
        let assessment = try await machineAssessSnapshotImport(from: path)
        return try await machineImportSnapshot(
            from: path,
            expectedContentID: assessment.contentID
        )
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

    func machineEvents(afterSequence: UInt64) async throws -> DorydMachineEventBatch {
        try await statusCommand { proxy, reply in
            proxy.machineEvents(afterSequence, reply: reply)
        } decode: {
            Self.machineEventBatch(from: $0, afterSequence: afterSequence)
        }
    }

    func machineFlightRecorder(
        machineID: String,
        afterSequence: UInt64
    ) async throws -> DorydMachineFlightRecorderBatch {
        try await statusCommand { proxy, reply in
            proxy.machineFlightRecorder(
                machineID,
                afterSequence: afterSequence,
                reply: reply
            )
        } decode: {
            Self.machineFlightRecorderBatch(
                from: $0,
                machineID: machineID,
                afterSequence: afterSequence
            )
        }
    }

    func machineSerialConsole(
        machineID: String,
        cursor: DorydMachineSerialConsoleCursor = .init(),
        limit: UInt32 = 64 * 1_024
    ) async throws -> DorydMachineSerialConsoleBatch {
        try await statusCommand { proxy, reply in
            proxy.machineSerialConsoleRead(
                machineID,
                cursor: cursor.xpcDictionary,
                limit: limit,
                reply: reply
            )
        } decode: {
            Self.machineSerialConsoleBatch(
                from: $0,
                machineID: machineID,
                cursor: cursor,
                limit: limit
            )
        }
    }

    func writeMachineSerialConsole(
        machineID: String,
        data: Data
    ) async throws -> DorydCommandResult {
        guard !data.isEmpty, data.count <= 4 * 1_024 else {
            throw DorydClientError.daemon("machine serial console input is invalid")
        }
        return try await command { proxy, reply in
            proxy.machineSerialConsoleWrite(machineID, data: data as NSData, reply: reply)
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
        guard let cloneReceipt = machineCloneReceipt(from: dictionary["cloneReceipt"]) else {
            return nil
        }
        guard let agentHandshake = machineAgentHandshake(from: dictionary) else {
            return nil
        }
        guard let shares = machineShares(from: dictionary["shares"]) else {
            return nil
        }
        guard let savedState = machineSavedState(from: dictionary["savedState"]),
              state != "suspended" || savedState.value != nil,
              savedState.value == nil || ["suspended", "starting", "running"].contains(state) else {
            return nil
        }
        guard let failure = machineFailure(from: dictionary["failure"]),
              let activeOperation = machineActiveOperation(
                  from: dictionary["activeOperation"]
              ),
              let flightRecorder = machineFlightRecorderSummary(
                  from: dictionary["flightRecorder"]
              ) else {
            return nil
        }
        let displayMode = (dictionary["displayMode"] as? String)
            .flatMap(MachineDisplayMode.init(rawValue:)) ?? .headless
        let agentBuild = nonEmptyString(dictionary["agentBuild"])
        let clipboardPolicy = typedSettings.value?.clipboardPolicy
            ?? (displayMode == .desktop
                ? DoryVMClipboardPolicy.legacyDesktop(.bidirectional)
                : .disabled)
        guard let integrationHealth = machineIntegrationHealth(
            from: dictionary,
            machineIsRunning: state == "running",
            desktopIntegrationsExpected: displayMode == .desktop,
            clipboardTextExpected: clipboardPolicy.text != .off,
            clipboardImageExpected: clipboardPolicy.image != .off,
            sharedFoldersExpected: !shares.isEmpty,
            expectedRuntimeIdentityMode: runtimeIdentity.mode,
            expectedAgentBuild: state == "running" ? agentBuild : nil,
            expectedAgentProtocolVersion: state == "running"
                ? agentHandshake.protocolVersion : nil
        ) else {
            return nil
        }
        return DorydMachineStatus(
            id: id,
            state: state,
            pid: int32(dictionary["pid"]),
            lastError: nonEmptyString(dictionary["lastError"]),
            failure: failure.value,
            activeOperation: activeOperation.value,
            flightRecorderHeadSequence: flightRecorder.headSequence,
            flightRecorderAvailable: flightRecorder.available,
            handoffSocketPath: nonEmptyString(dictionary["handoffSocketPath"]),
            agentBuild: agentBuild,
            agentProtocolVersion: agentHandshake.protocolVersion,
            agentCapabilities: agentHandshake.capabilities,
            integrationHealth: integrationHealth.value,
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
            displayMode: displayMode,
            bootMode: (dictionary["bootMode"] as? String).flatMap(MachineBootMode.init(rawValue:)) ?? .linuxKernel,
            installerMediaAttached: (dictionary["installerMediaAttached"] as? Bool)
                ?? (dictionary["installerMediaAttached"] as? NSNumber)?.boolValue
                ?? false,
            shares: shares,
            environment: environment,
            typedSettings: typedSettings.value,
            runtimeIdentity: runtimeIdentity,
            installedDesktopPayloadReceipt: installedDesktopPayloadReceipt.value,
            cloneReceipt: cloneReceipt.value,
            savedState: savedState.value
        )
    }

    private struct ParsedMachineCloneReceipt {
        var value: DorydMachineCloneReceipt?
    }

    nonisolated private static func machineCloneReceipt(
        from encoded: Any?
    ) -> ParsedMachineCloneReceipt? {
        guard let encoded else { return ParsedMachineCloneReceipt(value: nil) }
        guard let value = encoded as? NSDictionary,
              let keys = value.allKeys as? [String],
              keys.count == 7,
              Set(keys) == [
                  "schemaVersion", "sourceMachineID", "sourceSnapshotID",
                  "sourceRootfsSHA256", "sourceRootfsByteCount", "storageMode",
                  "createdAtUnixMilliseconds",
              ],
              strictUInt64(value["schemaVersion"]) == 1,
              let sourceMachineID = value["sourceMachineID"] as? String,
              sourceMachineID.isSafeMachineIdentifier,
              let sourceSnapshotID = value["sourceSnapshotID"] as? String,
              sourceSnapshotID.isSafeMachineIdentifier,
              let sourceRootfsSHA256 = value["sourceRootfsSHA256"] as? String,
              sourceRootfsSHA256.isLowercaseSHA256,
              let sourceRootfsByteCount = strictUInt64(value["sourceRootfsByteCount"]),
              sourceRootfsByteCount > 0,
              value["storageMode"] as? String == "apfs-copy-on-write",
              let createdAtUnixMilliseconds = int64(value["createdAtUnixMilliseconds"]),
              createdAtUnixMilliseconds > 0 else {
            return nil
        }
        return ParsedMachineCloneReceipt(value: DorydMachineCloneReceipt(
            sourceMachineID: sourceMachineID,
            sourceSnapshotID: sourceSnapshotID,
            sourceRootfsSHA256: sourceRootfsSHA256,
            sourceRootfsByteCount: sourceRootfsByteCount,
            storageMode: "apfs-copy-on-write",
            createdAtUnixMilliseconds: createdAtUnixMilliseconds
        ))
    }

    nonisolated private static func machineUSBAttachment(
        from dictionary: NSDictionary,
        expectedMachineID: String,
        expectedBusID: String
    ) -> DorydMachineUSBAttachment? {
        let expectedKeys: Set<String> = [
            "machineID", "busID", "port", "vsockPort", "deviceID", "speed",
        ]
        guard let keys = dictionary.allKeys as? [String],
              Set(keys) == expectedKeys,
              keys.count == expectedKeys.count,
              dictionary["machineID"] as? String == expectedMachineID,
              dictionary["busID"] as? String == expectedBusID,
              let port = exactUnsignedInteger(dictionary["port"], maximum: 65_535),
              let vsockPort = exactUnsignedInteger(
                  dictionary["vsockPort"], maximum: UInt64(UInt32.max)
              ), vsockPort == 1_025,
              let deviceID = exactUnsignedInteger(
                  dictionary["deviceID"], maximum: UInt64(UInt32.max)
              ), deviceID > 0,
              let speed = exactUnsignedInteger(
                  dictionary["speed"], maximum: UInt64(UInt32.max)
              ), speed > 0 else {
            return nil
        }
        return DorydMachineUSBAttachment(
            machineID: expectedMachineID,
            busID: expectedBusID,
            port: Int(port),
            vsockPort: UInt32(vsockPort),
            deviceID: UInt32(deviceID),
            speed: UInt32(speed)
        )
    }

    nonisolated private static func hostUSBDevices(
        from rows: NSArray
    ) -> [DorydHostUSBDevice]? {
        guard rows.count <= 256 else { return nil }
        var devices: [DorydHostUSBDevice] = []
        var busIDs = Set<String>()
        for raw in rows {
            guard let dictionary = raw as? NSDictionary,
                  let device = hostUSBDevice(from: dictionary),
                  busIDs.insert(device.busID).inserted else {
                return nil
            }
            devices.append(device)
        }
        guard devices == devices.sorted(by: { $0.busID < $1.busID }) else { return nil }
        return devices
    }

    nonisolated private static func hostUSBDevice(
        from dictionary: NSDictionary
    ) -> DorydHostUSBDevice? {
        let expectedKeys: Set<String> = [
            "busID", "vendorID", "productID", "vendorName", "productName", "deviceClass", "speed",
        ]
        guard let keys = dictionary.allKeys as? [String],
              Set(keys) == expectedKeys,
              keys.count == expectedKeys.count,
              let busID = dictionary["busID"] as? String,
              isValidUSBBusID(busID),
              let vendorID = exactUnsignedInteger(dictionary["vendorID"], maximum: UInt64(UInt16.max)),
              let productID = exactUnsignedInteger(dictionary["productID"], maximum: UInt64(UInt16.max)),
              let vendorName = dictionary["vendorName"] as? String,
              isValidUSBDisplayName(vendorName),
              let productName = dictionary["productName"] as? String,
              isValidUSBDisplayName(productName),
              let deviceClass = exactUnsignedInteger(dictionary["deviceClass"], maximum: UInt64(UInt8.max)),
              let speed = exactUnsignedInteger(dictionary["speed"], maximum: UInt64(UInt32.max)) else {
            return nil
        }
        return DorydHostUSBDevice(
            busID: busID,
            vendorID: UInt16(vendorID),
            productID: UInt16(productID),
            vendorName: vendorName,
            productName: productName,
            deviceClass: UInt8(deviceClass),
            speed: UInt32(speed)
        )
    }

    nonisolated private static func isValidUSBBusID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1..<32).contains(bytes.count),
              bytes.first.map({ (48...57).contains($0) }) == true,
              bytes.last.map({ (48...57).contains($0) }) == true else {
            return false
        }
        return bytes.allSatisfy { (48...57).contains($0) || $0 == 45 || $0 == 46 }
    }

    nonisolated private static func isValidUSBDisplayName(_ value: String) -> Bool {
        value.utf8.count <= 128
            && value.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }
    }

    nonisolated private static func exactUnsignedInteger(
        _ raw: Any?,
        maximum: UInt64
    ) -> UInt64? {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              number.doubleValue >= 0,
              number.doubleValue.rounded(.towardZero) == number.doubleValue,
              number.doubleValue <= Double(maximum) else {
            return nil
        }
        let value = number.uint64Value
        return value <= maximum && Double(value) == number.doubleValue ? value : nil
    }

    private struct ParsedMachineFailure {
        var value: DorydMachineFailure?
    }

    nonisolated private static func machineFailure(
        from raw: Any?
    ) -> ParsedMachineFailure? {
        guard let raw else { return ParsedMachineFailure(value: nil) }
        guard let dictionary = raw as? NSDictionary,
              let rawKeys = dictionary.allKeys as? [String],
              rawKeys.count == dictionary.allKeys.count else {
            return nil
        }
        let requiredKeys: Set<String> = [
            "schemaVersion", "code", "occurredAtUnixMilliseconds", "causalChain",
            "recoveryDisposition", "evidenceReferences",
        ]
        let keys = Set(rawKeys)
        guard keys == requiredKeys || keys == requiredKeys.union(["operationID"]),
              strictUInt64(dictionary["schemaVersion"]) == 1,
              let rawCode = dictionary["code"] as? String,
              let code = DorydMachineFailureCode(rawValue: rawCode),
              let occurred = strictInt64(dictionary["occurredAtUnixMilliseconds"]),
              occurred > 0,
              let rawCauses = dictionary["causalChain"] as? [String],
              !rawCauses.isEmpty, rawCauses.count <= 8,
              rawCauses.count == (dictionary["causalChain"] as? NSArray)?.count,
              let causes = Optional(rawCauses.compactMap(
                  DorydMachineFailureCauseCode.init(rawValue:)
              )), causes.count == rawCauses.count,
              let rawRecovery = dictionary["recoveryDisposition"] as? String,
              let recovery = DorydMachineRecoveryDisposition(rawValue: rawRecovery),
              let rawEvidence = dictionary["evidenceReferences"] as? NSArray,
              rawEvidence.count <= 16 else {
            return nil
        }
        var evidence: [DorydMachineFailureEvidenceReference] = []
        for row in rawEvidence {
            guard let row = row as? NSDictionary,
                  let evidenceKeys = row.allKeys as? [String],
                  evidenceKeys.count == row.allKeys.count,
                  Set(evidenceKeys) == ["kind", "identifier"],
                  let rawKind = row["kind"] as? String,
                  let kind = DorydMachineFailureEvidenceKind(rawValue: rawKind),
                  let identifier = row["identifier"] as? String,
                  identifier.utf8.count <= 256,
                  identifier.wholeMatch(
                      of: /[A-Za-z0-9][A-Za-z0-9._:@+-]{0,255}/
                  ) != nil else {
                return nil
            }
            evidence.append(.init(kind: kind, identifier: identifier))
        }
        guard Set(evidence).count == evidence.count else { return nil }
        let operationID = dictionary["operationID"] as? String
        guard dictionary["operationID"] == nil || operationID != nil,
              operationID.map(isMachineOperationID) ?? true else {
            return nil
        }
        return ParsedMachineFailure(value: DorydMachineFailure(
            schemaVersion: 1,
            code: code,
            occurredAtUnixMilliseconds: occurred,
            operationID: operationID,
            causalChain: causes,
            recoveryDisposition: recovery,
            evidenceReferences: evidence
        ))
    }

    private struct ParsedMachineActiveOperation {
        var value: DorydMachineOperationSummary?
    }

    private struct ParsedMachineFlightRecorderSummary {
        var headSequence: UInt64
        var available: Bool
    }

    nonisolated private static func machineFlightRecorderSummary(
        from raw: Any?
    ) -> ParsedMachineFlightRecorderSummary? {
        // Absence means an older daemon; never claim recorder availability without evidence.
        guard let raw else {
            return ParsedMachineFlightRecorderSummary(
                headSequence: 0,
                available: false
            )
        }
        guard let dictionary = raw as? NSDictionary,
              let rawKeys = dictionary.allKeys as? [String],
              rawKeys.count == dictionary.allKeys.count,
              Set(rawKeys) == ["headSequence", "available"],
              let headSequence = strictUInt64(dictionary["headSequence"]),
              let available = dictionary["available"] as? NSNumber,
              CFGetTypeID(available) == CFBooleanGetTypeID() else {
            return nil
        }
        return ParsedMachineFlightRecorderSummary(
            headSequence: headSequence,
            available: available.boolValue
        )
    }

    nonisolated private static func machineActiveOperation(
        from raw: Any?
    ) -> ParsedMachineActiveOperation? {
        guard let raw else { return ParsedMachineActiveOperation(value: nil) }
        guard let dictionary = raw as? NSDictionary,
              let rawKeys = dictionary.allKeys as? [String],
              rawKeys.count == dictionary.allKeys.count,
              Set(rawKeys) == ["operationID", "kind"],
              let operationID = dictionary["operationID"] as? String,
              isMachineOperationID(operationID),
              let rawKind = dictionary["kind"] as? String,
              let kind = DorydMachineOperationKind(rawValue: rawKind) else {
            return nil
        }
        return ParsedMachineActiveOperation(value: .init(
            operationID: operationID,
            kind: kind
        ))
    }

    nonisolated private static func isMachineOperationID(_ value: String) -> Bool {
        value.wholeMatch(
            of: /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/
        ) != nil
    }

    private struct ParsedMachineSavedState {
        var value: DorydMachineSavedStateSummary?
    }

    nonisolated private static func machineSavedState(
        from raw: Any?
    ) -> ParsedMachineSavedState? {
        guard let raw else { return ParsedMachineSavedState(value: nil) }
        let expectedKeys: Set<String> = Set([
            "schemaVersion", "backend", "stateFileSHA256", "stateFileByteCount",
            "hostHardwareModel", "hostOperatingSystemBuild",
            "createdAtUnixMilliseconds", "portable",
        ])
        guard let dictionary = raw as? NSDictionary,
              let rawKeys = dictionary.allKeys as? [String],
              rawKeys.count == dictionary.allKeys.count,
              Set(rawKeys) == expectedKeys,
              strictUInt64(dictionary["schemaVersion"]) == 1,
              dictionary["backend"] as? String == "apple-virtualization-framework",
              let digest = dictionary["stateFileSHA256"] as? String,
              digest.count == 64,
              digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let byteCount = strictUInt64(dictionary["stateFileByteCount"]), byteCount > 0,
              let hostModel = nonEmptyString(dictionary["hostHardwareModel"]),
              hostModel.utf8.count <= 256, !hostModel.contains("\0"),
              let hostBuild = nonEmptyString(dictionary["hostOperatingSystemBuild"]),
              hostBuild.utf8.count <= 256, !hostBuild.contains("\0"),
              let created = strictInt64(dictionary["createdAtUnixMilliseconds"]), created > 0,
              let portable = dictionary["portable"] as? Bool, portable == false else {
            return nil
        }
        return ParsedMachineSavedState(value: DorydMachineSavedStateSummary(
            stateFileSHA256: digest,
            stateFileByteCount: byteCount,
            hostHardwareModel: hostModel,
            hostOperatingSystemBuild: hostBuild,
            createdAtUnixMilliseconds: created
        ))
    }

    private struct ParsedMachineAgentHandshake {
        var protocolVersion: UInt32?
        var capabilities: [DorydAgentCapability]
    }

    private struct ParsedMachineIntegrationHealth {
        var value: DoryGuestIntegrationHealth?
    }

    /// Older daemons may omit the projection. Once present, this is a capability claim used for
    /// repair and product support decisions, so malformed/future shapes reject the machine row.
    nonisolated private static func machineIntegrationHealth(
        from dictionary: NSDictionary,
        machineIsRunning: Bool,
        desktopIntegrationsExpected: Bool,
        clipboardTextExpected: Bool,
        clipboardImageExpected: Bool,
        sharedFoldersExpected: Bool,
        expectedRuntimeIdentityMode: String,
        expectedAgentBuild: String?,
        expectedAgentProtocolVersion: UInt32?
    ) -> ParsedMachineIntegrationHealth? {
        guard let encoded = dictionary["integrationHealth"] else {
            return ParsedMachineIntegrationHealth(value: nil)
        }
        guard let value = encoded as? NSDictionary,
              let rawKeys = value.allKeys as? [String],
              rawKeys.count == Set(rawKeys).count,
              Set(rawKeys).isSuperset(of: [
                "schemaVersion", "state", "runtimeAuthority", "features",
              ]),
              Set(rawKeys).isSubset(of: [
                "schemaVersion", "state", "runtimeAuthority", "agentBuild",
                "agentProtocolVersion", "features",
              ]),
              let schema = strictUInt64(value["schemaVersion"]),
              schema <= UInt16.max,
              let rawState = value["state"] as? String,
              let state = DoryGuestIntegrationHealthState(rawValue: rawState),
              let rawAuthority = value["runtimeAuthority"] as? String,
              let authority = DoryGuestIntegrationRuntimeAuthority(rawValue: rawAuthority),
              let rawFeatures = value["features"] as? NSArray else {
            return nil
        }
        let agentBuild: String?
        if let encodedBuild = value["agentBuild"] {
            guard let build = encodedBuild as? String else { return nil }
            agentBuild = build
        } else {
            agentBuild = nil
        }
        let agentProtocolVersion: UInt32?
        if let encodedProtocol = value["agentProtocolVersion"] {
            guard let version = strictUInt64(encodedProtocol),
                  version <= UInt32.max else { return nil }
            agentProtocolVersion = UInt32(version)
        } else {
            agentProtocolVersion = nil
        }

        var features: [DoryGuestIntegrationFeatureHealth] = []
        features.reserveCapacity(rawFeatures.count)
        for rawFeature in rawFeatures {
            guard let feature = rawFeature as? NSDictionary,
                  let keys = feature.allKeys as? [String],
                  keys.count == Set(keys).count,
                  Set(keys).isSuperset(of: ["id", "provider", "required", "state"]),
                  Set(keys).isSubset(of: [
                    "id", "provider", "required", "minimumVersion",
                    "negotiatedVersion", "state",
                  ]),
                  let rawID = feature["id"] as? String,
                  let id = DoryGuestIntegrationCapabilityID(rawValue: rawID),
                  let rawProvider = feature["provider"] as? String,
                  let provider = DoryGuestIntegrationFeatureProvider(rawValue: rawProvider),
                  let requiredNumber = feature["required"] as? NSNumber,
                  CFGetTypeID(requiredNumber) == CFBooleanGetTypeID(),
                  let rawFeatureState = feature["state"] as? String,
                  let featureState = DoryGuestIntegrationFeatureState(
                    rawValue: rawFeatureState
                  ) else {
                return nil
            }
            func version(_ key: String) -> UInt32? {
                guard let encoded = feature[key],
                      let value = strictUInt64(encoded),
                      value <= UInt32.max else { return nil }
                return UInt32(value)
            }
            let minimumVersion = feature["minimumVersion"] == nil
                ? nil : version("minimumVersion")
            let negotiatedVersion = feature["negotiatedVersion"] == nil
                ? nil : version("negotiatedVersion")
            if feature["minimumVersion"] != nil && minimumVersion == nil { return nil }
            if feature["negotiatedVersion"] != nil && negotiatedVersion == nil { return nil }
            features.append(DoryGuestIntegrationFeatureHealth(
                id: id,
                provider: provider,
                required: requiredNumber.boolValue,
                minimumVersion: minimumVersion,
                negotiatedVersion: negotiatedVersion,
                state: featureState
            ))
        }
        let health = DoryGuestIntegrationHealth(
            schemaVersion: UInt16(schema),
            state: state,
            runtimeAuthority: authority,
            agentBuild: agentBuild,
            agentProtocolVersion: agentProtocolVersion,
            features: features
        )
        let expectedAuthority: DoryGuestIntegrationRuntimeAuthority
        switch expectedRuntimeIdentityMode {
        case "resolved-plan": expectedAuthority = .resolvedPlan
        case "requires-replanning": expectedAuthority = .requiresReplanning
        case "legacy-compatibility": expectedAuthority = .legacyCompatibility
        default: return nil
        }
        guard health.isValid(
            desktopIntegrationsExpected: desktopIntegrationsExpected,
            clipboardTextExpected: clipboardTextExpected,
            clipboardImageExpected: clipboardImageExpected,
            sharedFoldersExpected: sharedFoldersExpected
        ),
        health.runtimeAuthority == expectedAuthority,
        health.agentBuild == expectedAgentBuild,
        health.agentProtocolVersion == expectedAgentProtocolVersion,
        machineIsRunning ? health.state != .inactive : health.state == .inactive else {
            return nil
        }
        return ParsedMachineIntegrationHealth(value: health)
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
                "desktopRuntimePreference", "desktopGraphicsPreference", "networkMode",
                "portForwards", "audio",
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
        let networkMode: DoryVMNetworkMode?
        if let encoded = value["networkMode"] {
            guard let raw = encoded as? String,
                  let parsed = DoryVMNetworkMode(rawValue: raw) else { return nil }
            networkMode = parsed
        } else { networkMode = nil }
        let portForwards: [DoryVMPortForward]
        if let encoded = value["portForwards"] {
            guard let rows = encoded as? NSArray,
                  rows.count <= DoryVMPortForward.maximumCount else { return nil }
            var parsed: [DoryVMPortForward] = []
            var identifiers: Set<String> = []
            var bindings: Set<String> = []
            for rawRow in rows {
                guard let row = rawRow as? NSDictionary,
                      let rowKeys = row.allKeys as? [String],
                      Set(rowKeys) == ["id", "transport", "hostPort", "guestPort", "exposure"],
                      rowKeys.count == 5,
                      let id = row["id"] as? String,
                      isSafePortForwardIdentifier(id),
                      identifiers.insert(id).inserted,
                      let transportRaw = row["transport"] as? String,
                      let transport = DoryVMPortForwardTransport(rawValue: transportRaw),
                      let hostPort = machinePort(row["hostPort"]), hostPort >= 1_024,
                      let guestPort = machinePort(row["guestPort"]), guestPort > 0,
                      let exposureRaw = row["exposure"] as? String,
                      let exposure = DoryVMPortForwardExposure(rawValue: exposureRaw),
                      bindings.insert("\(transport.rawValue):\(hostPort)").inserted else {
                    return nil
                }
                parsed.append(DoryVMPortForward(
                    id: id,
                    transport: transport,
                    hostPort: hostPort,
                    guestPort: guestPort,
                    exposure: exposure
                ))
            }
            portForwards = parsed
        } else { portForwards = [] }
        if !portForwards.isEmpty {
            guard networkMode == .sharedNAT || networkMode == .isolated,
                  !portForwards.contains(where: {
                      $0.exposure == .lan && networkMode != .sharedNAT
                  }) else { return nil }
        }
        let audioConfiguration: DoryVMAudioConfiguration?
        if let encoded = value["audio"] {
            guard let raw = encoded as? NSDictionary,
                  let rawKeys = raw.allKeys as? [String],
                  Set(rawKeys) == ["inputEnabled", "outputEnabled"],
                  rawKeys.count == 2,
                  let input = raw["inputEnabled"] as? NSNumber,
                  CFGetTypeID(input) == CFBooleanGetTypeID(),
                  let output = raw["outputEnabled"] as? NSNumber,
                  CFGetTypeID(output) == CFBooleanGetTypeID() else { return nil }
            audioConfiguration = DoryVMAudioConfiguration(
                inputEnabled: input.boolValue,
                outputEnabled: output.boolValue
            )
        } else { audioConfiguration = nil }
        return ParsedMachineTypedSettings(value: DorydMachineTypedSettings(
            guestIdentityIntent: identity,
            clipboardPolicy: clipboard,
            runtimePreference: runtime,
            graphicsPreference: graphics,
            networkMode: networkMode,
            portForwards: portForwards,
            audioConfiguration: audioConfiguration
        ))
    }

    nonisolated private static func machinePort(_ raw: Any?) -> UInt16? {
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.rounded(.towardZero) == number.doubleValue,
              (1...Double(UInt16.max)).contains(number.doubleValue) else {
            return nil
        }
        return UInt16(number.uint64Value)
    }

    nonisolated private static func isSafePortForwardIdentifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        func alphaNumeric(_ byte: UInt8) -> Bool {
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
        }
        guard (1...63).contains(bytes.count), alphaNumeric(bytes[0]) else { return false }
        return bytes.dropFirst().allSatisfy {
            alphaNumeric($0) || $0 == 95 || $0 == 46 || $0 == 45
        }
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

    /// An absent field is compatible with an older daemon. Once present, every row is a durable
    /// device-identity claim; silently dropping a malformed row could make the next app edit
    /// delete a share the user never removed.
    nonisolated private static func machineShares(
        from value: Any?
    ) -> [DorydMachineShareConfiguration]? {
        guard let value else { return [] }
        guard let rawRows = value as? NSArray else { return nil }
        var shares: [DorydMachineShareConfiguration] = []
        var tags: Set<String> = []
        shares.reserveCapacity(rawRows.count)
        for rawRow in rawRows {
            guard let row = rawRow as? NSDictionary,
                  let keys = row.allKeys as? [String],
                  Set(keys).isSubset(of: ["tag", "hostPath", "guestPath", "readOnly", "mode"]),
                  keys.count == Set(keys).count,
                  let tag = row["tag"] as? String,
                  !tag.isEmpty,
                  tag.utf8.count < 36,
                  tag.allSatisfy({
                      $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "."
                  }),
                  tags.insert(tag).inserted,
                  let hostPath = row["hostPath"] as? String,
                  hostPath.hasPrefix("/"),
                  !hostPath.contains("\0"),
                  let guestPath = row["guestPath"] as? String,
                  guestPath.hasPrefix("/"),
                  guestPath != "/",
                  !guestPath.contains("\0") else {
                return nil
            }
            let encodedMode = row["mode"]
            guard encodedMode == nil
                    || (encodedMode as? String).map({ $0 == "ro" || $0 == "rw" }) == true else {
                return nil
            }
            let readOnly: Bool
            if let encoded = row["readOnly"] {
                guard let number = encoded as? NSNumber,
                      CFGetTypeID(number) == CFBooleanGetTypeID() else {
                    return nil
                }
                readOnly = number.boolValue
            } else {
                readOnly = (encodedMode as? String) == "ro"
            }
            if let mode = encodedMode as? String,
               (mode == "ro") != readOnly {
                return nil
            }
            shares.append(DorydMachineShareConfiguration(
                tag: tag,
                hostPath: hostPath,
                guestPath: guestPath,
                readOnly: readOnly
            ))
        }
        return shares
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

    nonisolated private static func machineDeviceTelemetry(
        from dictionary: NSDictionary,
        machineID: String
    ) -> DorydDeviceTelemetrySnapshot? {
        guard machineID.isSafeMachineIdentifier,
              let rawKeys = dictionary.allKeys as? [String],
              rawKeys.count == dictionary.allKeys.count,
              Set(rawKeys) == [
                  "schemaVersion", "machineID", "operationID", "backend", "sampleSequence",
                  "sampledAtUnixMilliseconds", "monotonicNanoseconds", "devices", "events",
              ],
              strictUInt64(dictionary["schemaVersion"]) == 1,
              dictionary["machineID"] as? String == machineID,
              let operationID = dictionary["operationID"] as? String,
              isMachineOperationID(operationID),
              let rawBackend = dictionary["backend"] as? String,
              let backend = DoryVirtualizationBackendIdentity(rawValue: rawBackend),
              let sampleSequence = strictUInt64(dictionary["sampleSequence"]),
              sampleSequence > 0,
              let sampledAt = strictUInt64(dictionary["sampledAtUnixMilliseconds"]),
              sampledAt > 0,
              let monotonic = strictUInt64(dictionary["monotonicNanoseconds"]),
              monotonic > 0,
              let rawDevices = dictionary["devices"] as? NSArray,
              rawDevices.count > 0, rawDevices.count <= 64,
              let rawEvents = dictionary["events"] as? NSArray,
              rawEvents.count <= 256 else {
            return nil
        }
        let devices = rawDevices.compactMap { raw -> DorydDeviceTelemetryDevice? in
            guard let row = raw as? NSDictionary else { return nil }
            return machineDeviceTelemetryDevice(from: row)
        }
        let events = rawEvents.compactMap { raw -> DorydDeviceTelemetryEvent? in
            guard let row = raw as? NSDictionary else { return nil }
            return machineDeviceTelemetryEvent(from: row)
        }
        guard devices.count == rawDevices.count,
              events.count == rawEvents.count,
              Set(devices.map(\.id)).count == devices.count,
              events == events.sorted(by: { $0.sequence < $1.sequence }),
              Set(events.map(\.sequence)).count == events.count,
              events.allSatisfy({ event in devices.contains { $0.id == event.deviceID } }) else {
            return nil
        }
        return DorydDeviceTelemetrySnapshot(
            machineID: machineID,
            operationID: operationID,
            backend: backend,
            sampleSequence: sampleSequence,
            sampledAtUnixMilliseconds: sampledAt,
            monotonicNanoseconds: monotonic,
            devices: devices,
            events: events
        )
    }

    nonisolated private static func machineDeviceTelemetryDevice(
        from dictionary: NSDictionary
    ) -> DorydDeviceTelemetryDevice? {
        guard let rawKeys = dictionary.allKeys as? [String],
              rawKeys.count == dictionary.allKeys.count,
              Set(rawKeys) == ["id", "kind", "health", "metrics"],
              let id = dictionary["id"] as? String,
              !id.isEmpty, id.utf8.count <= 128,
              !id.contains("\0"), !id.contains("\n"), !id.contains("\r"),
              let rawKind = dictionary["kind"] as? String,
              let kind = DorydDeviceTelemetryKind(rawValue: rawKind),
              let rawHealth = dictionary["health"] as? String,
              let health = DorydDeviceTelemetryHealth(rawValue: rawHealth),
              let rawMetrics = dictionary["metrics"] as? NSArray,
              rawMetrics.count > 0,
              rawMetrics.count <= deviceTelemetryMetricKinds.count else {
            return nil
        }
        let metrics = rawMetrics.compactMap { raw -> DorydDeviceTelemetryMetric? in
            guard let row = raw as? NSDictionary else { return nil }
            return machineDeviceTelemetryMetric(from: row)
        }
        guard metrics.count == rawMetrics.count,
              Set(metrics.map(\.kind)).count == metrics.count,
              health != .unavailable
                ? metrics.contains(where: { $0.availability == .measured })
                : metrics.allSatisfy({ $0.availability == .unavailable }) else {
            return nil
        }
        return DorydDeviceTelemetryDevice(id: id, kind: kind, health: health, metrics: metrics)
    }

    nonisolated private static func machineDeviceTelemetryMetric(
        from dictionary: NSDictionary
    ) -> DorydDeviceTelemetryMetric? {
        guard let rawKeys = dictionary.allKeys as? [String],
              rawKeys.count == dictionary.allKeys.count,
              let kind = dictionary["kind"] as? String,
              deviceTelemetryMetricKinds.contains(kind),
              let unit = dictionary["unit"] as? String,
              unit == deviceTelemetryMetricUnit(for: kind),
              let rawAvailability = dictionary["availability"] as? String,
              let availability = DorydDeviceTelemetryMetricAvailability(
                  rawValue: rawAvailability
              ) else {
            return nil
        }
        switch availability {
        case .measured:
            guard Set(rawKeys) == ["kind", "unit", "availability", "value"],
                  let value = strictUInt64(dictionary["value"]) else { return nil }
            return DorydDeviceTelemetryMetric(
                kind: kind,
                unit: unit,
                availability: availability,
                value: value
            )
        case .unavailable:
            guard Set(rawKeys) == ["kind", "unit", "availability", "unavailableReason"],
                  let reason = dictionary["unavailableReason"] as? String,
                  !reason.isEmpty, reason.utf8.count <= 256,
                  !reason.contains("\0"), !reason.contains("\n"), !reason.contains("\r") else {
                return nil
            }
            return DorydDeviceTelemetryMetric(
                kind: kind,
                unit: unit,
                availability: availability,
                unavailableReason: reason
            )
        }
    }

    nonisolated private static func machineDeviceTelemetryEvent(
        from dictionary: NSDictionary
    ) -> DorydDeviceTelemetryEvent? {
        guard let rawKeys = dictionary.allKeys as? [String],
              rawKeys.count == dictionary.allKeys.count,
              Set(rawKeys) == [
                  "sequence", "monotonicNanoseconds", "deviceID", "kind", "occurrences",
              ],
              let sequence = strictUInt64(dictionary["sequence"]), sequence > 0,
              let monotonic = strictUInt64(dictionary["monotonicNanoseconds"]), monotonic > 0,
              let deviceID = dictionary["deviceID"] as? String,
              !deviceID.isEmpty, deviceID.utf8.count <= 128,
              let kind = dictionary["kind"] as? String,
              deviceTelemetryEventKinds.contains(kind),
              let occurrences = strictUInt64(dictionary["occurrences"]), occurrences > 0 else {
            return nil
        }
        return DorydDeviceTelemetryEvent(
            sequence: sequence,
            monotonicNanoseconds: monotonic,
            deviceID: deviceID,
            kind: kind,
            occurrences: occurrences
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
        let operationID: String?
        if let rawOperationID = dictionary["operationID"] {
            guard let value = rawOperationID as? String else { return nil }
            operationID = value
        } else {
            operationID = nil
        }
        if let operationID {
            guard let parsed = UUID(uuidString: operationID),
                  parsed != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
                  operationID == parsed.uuidString.lowercased() else {
                return nil
            }
        }
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
            operationID: operationID,
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

    nonisolated private static func machineEventBatch(
        from dictionary: NSDictionary,
        afterSequence: UInt64
    ) -> DorydMachineEventBatch? {
        guard let keys = dictionary.allKeys as? [String],
              keys.count == 4,
              Set(keys) == [
                  "schemaVersion", "headSequence", "snapshotRequired", "events",
              ],
              uint16(dictionary["schemaVersion"]) == 1,
              let headSequence = uint64(dictionary["headSequence"]),
              let snapshotNumber = dictionary["snapshotRequired"] as? NSNumber,
              CFGetTypeID(snapshotNumber) == CFBooleanGetTypeID(),
              let rows = dictionary["events"] as? NSArray else {
            return nil
        }
        var events: [DorydMachineEvent] = []
        for rawRow in rows {
            guard let row = rawRow as? NSDictionary,
                  let event = machineEvent(from: row) else { return nil }
            events.append(event)
        }
        let snapshotRequired = snapshotNumber.boolValue
        guard events == events.sorted(by: { $0.sequence < $1.sequence }),
              Set(events.map(\.sequence)).count == events.count else {
            return nil
        }
        if snapshotRequired {
            guard events.isEmpty else { return nil }
        } else if events.isEmpty {
            guard headSequence == afterSequence else { return nil }
        } else {
            guard afterSequence < UInt64.max,
                  events.first?.sequence == afterSequence + 1,
                  events.last?.sequence == headSequence,
                  zip(events, events.dropFirst()).allSatisfy({ lhs, rhs in
                      lhs.sequence < UInt64.max && lhs.sequence + 1 == rhs.sequence
                  }) else {
                return nil
            }
        }
        return DorydMachineEventBatch(
            headSequence: headSequence,
            snapshotRequired: snapshotRequired,
            events: events
        )
    }

    nonisolated private static func machineFlightRecorderBatch(
        from dictionary: NSDictionary,
        machineID: String,
        afterSequence: UInt64
    ) -> DorydMachineFlightRecorderBatch? {
        guard machineID.isSafeMachineIdentifier,
              let rawKeys = dictionary.allKeys as? [String],
              rawKeys.count == dictionary.allKeys.count,
              Set(rawKeys) == [
                  "schemaVersion", "machineID", "headSequence", "snapshotRequired", "events",
              ],
              strictUInt64(dictionary["schemaVersion"]) == 1,
              dictionary["machineID"] as? String == machineID,
              let headSequence = strictUInt64(dictionary["headSequence"]),
              let snapshot = dictionary["snapshotRequired"] as? NSNumber,
              CFGetTypeID(snapshot) == CFBooleanGetTypeID(),
              let rows = dictionary["events"] as? NSArray,
              rows.count <= 256 else {
            return nil
        }
        var events: [DorydMachineFlightEvent] = []
        for raw in rows {
            guard let row = raw as? NSDictionary,
                  let event = machineFlightEvent(from: row),
                  event.machineID == machineID else {
                return nil
            }
            events.append(event)
        }
        guard events == events.sorted(by: { $0.sequence < $1.sequence }),
              Set(events.map(\.sequence)).count == events.count,
              zip(events, events.dropFirst()).allSatisfy({ lhs, rhs in
                  lhs.sequence < UInt64.max && lhs.sequence + 1 == rhs.sequence
              }) else {
            return nil
        }
        if events.isEmpty {
            guard headSequence == 0 || (!snapshot.boolValue && headSequence == afterSequence) else {
                return nil
            }
        } else {
            guard events.last?.sequence == headSequence else { return nil }
            if !snapshot.boolValue {
                guard afterSequence < UInt64.max,
                      events.first?.sequence == afterSequence + 1 else { return nil }
            }
        }
        return DorydMachineFlightRecorderBatch(
            machineID: machineID,
            headSequence: headSequence,
            snapshotRequired: snapshot.boolValue,
            events: events
        )
    }

    nonisolated private static func machineSerialConsoleBatch(
        from dictionary: NSDictionary,
        machineID: String,
        cursor: DorydMachineSerialConsoleCursor,
        limit: UInt32
    ) -> DorydMachineSerialConsoleBatch? {
        let required: Set<String> = [
            "schemaVersion", "machineID", "startOffset", "nextOffset", "totalBytes",
            "snapshotRequired", "inputAvailable", "bytesBase64",
        ]
        let optional: Set<String> = ["generation"]
        guard machineID.isSafeMachineIdentifier,
              limit > 0, limit <= 64 * 1_024,
              let rawKeys = dictionary.allKeys as? [String] else { return nil }
        let keys = Set(rawKeys)
        guard rawKeys.count == keys.count,
              required.isSubset(of: keys),
              keys.subtracting(required).isSubset(of: optional),
              strictUInt64(dictionary["schemaVersion"]) == 1,
              dictionary["machineID"] as? String == machineID,
              let startOffset = strictUInt64(dictionary["startOffset"]),
              let nextOffset = strictUInt64(dictionary["nextOffset"]),
              let totalBytes = strictUInt64(dictionary["totalBytes"]),
              let snapshot = dictionary["snapshotRequired"] as? NSNumber,
              CFGetTypeID(snapshot) == CFBooleanGetTypeID(),
              let input = dictionary["inputAvailable"] as? NSNumber,
              CFGetTypeID(input) == CFBooleanGetTypeID(),
              let encoded = dictionary["bytesBase64"] as? String,
              let bytes = Data(base64Encoded: encoded),
              bytes.base64EncodedString() == encoded,
              bytes.count <= Int(limit),
              startOffset <= nextOffset,
              nextOffset <= totalBytes,
              nextOffset - startOffset == UInt64(bytes.count),
              dictionary["generation"] == nil
                || dictionary["generation"] is String else {
            return nil
        }
        let generation = dictionary["generation"] as? String
        guard generation.map(\.isLowercaseSHA256) ?? true else { return nil }
        if generation == nil {
            guard startOffset == 0, nextOffset == 0, totalBytes == 0, bytes.isEmpty else {
                return nil
            }
        }
        if !snapshot.boolValue {
            guard generation == cursor.generation, startOffset == cursor.offset else {
                return nil
            }
        }
        return DorydMachineSerialConsoleBatch(
            machineID: machineID,
            generation: generation,
            startOffset: startOffset,
            nextOffset: nextOffset,
            totalBytes: totalBytes,
            snapshotRequired: snapshot.boolValue,
            inputAvailable: input.boolValue,
            bytes: bytes
        )
    }

    nonisolated private static func machineFlightEvent(
        from dictionary: NSDictionary
    ) -> DorydMachineFlightEvent? {
        let required: Set<String> = [
            "schemaVersion", "sequence", "occurredAtUnixMilliseconds", "machineID",
            "kind", "evidenceReferences",
        ]
        let optional: Set<String> = [
            "operationID", "operationKind", "phase", "machineState", "failureCode",
            "recoveryDisposition", "backend", "virtualHardwareABIVersion", "planSHA256",
            "durationMilliseconds", "deadlineUnixMilliseconds", "deviceID",
            "deviceEventKind", "deviceEventSequence", "deviceEventOccurrences",
        ]
        guard let rawKeys = dictionary.allKeys as? [String] else { return nil }
        let keys = Set(rawKeys)
        guard rawKeys.count == keys.count,
              required.isSubset(of: keys),
              keys.subtracting(required).isSubset(of: optional),
              strictUInt64(dictionary["schemaVersion"]) == 1,
              let sequence = strictUInt64(dictionary["sequence"]), sequence > 0,
              let occurredAt = strictInt64(dictionary["occurredAtUnixMilliseconds"]),
              occurredAt > 0,
              let machineID = dictionary["machineID"] as? String,
              machineID.isSafeMachineIdentifier,
              let rawKind = dictionary["kind"] as? String,
              let kind = DorydMachineFlightEventKind(rawValue: rawKind),
              let rawEvidence = dictionary["evidenceReferences"] as? NSArray,
              rawEvidence.count <= 16 else {
            return nil
        }
        var evidence: [DorydMachineFailureEvidenceReference] = []
        for raw in rawEvidence {
            guard let row = raw as? NSDictionary,
                  let rowKeys = row.allKeys as? [String],
                  rowKeys.count == row.allKeys.count,
                  Set(rowKeys) == ["kind", "identifier"],
                  let rawEvidenceKind = row["kind"] as? String,
                  let evidenceKind = DorydMachineFailureEvidenceKind(
                      rawValue: rawEvidenceKind
                  ),
                  let identifier = row["identifier"] as? String,
                  identifier.utf8.count <= 256,
                  identifier.wholeMatch(
                      of: /[A-Za-z0-9][A-Za-z0-9._:@+-]{0,255}/
                  ) != nil else {
                return nil
            }
            evidence.append(.init(kind: evidenceKind, identifier: identifier))
        }
        guard Set(evidence).count == evidence.count else { return nil }

        let operationID = dictionary["operationID"] as? String
        let operationKind = (dictionary["operationKind"] as? String).flatMap(
            DorydMachineOperationKind.init(rawValue:)
        )
        let phase = dictionary["phase"] as? String
        let machineState = dictionary["machineState"] as? String
        let failureCode = (dictionary["failureCode"] as? String).flatMap(
            DorydMachineFailureCode.init(rawValue:)
        )
        let recovery = (dictionary["recoveryDisposition"] as? String).flatMap(
            DorydMachineRecoveryDisposition.init(rawValue:)
        )
        let backend = (dictionary["backend"] as? String).flatMap(
            DoryVirtualizationBackendIdentity.init(rawValue:)
        )
        let abi = dictionary["virtualHardwareABIVersion"]
            .flatMap { strictUInt64($0) }
            .flatMap { UInt16(exactly: $0) }
        let planSHA256 = dictionary["planSHA256"] as? String
        let duration = dictionary["durationMilliseconds"].flatMap(strictUInt64)
        let deadline = dictionary["deadlineUnixMilliseconds"].flatMap(strictInt64)
        let deviceID = dictionary["deviceID"] as? String
        let deviceEventKind = dictionary["deviceEventKind"] as? String
        let deviceEventSequence = dictionary["deviceEventSequence"].flatMap(strictUInt64)
        let deviceEventOccurrences = dictionary["deviceEventOccurrences"].flatMap(strictUInt64)
        guard (dictionary["operationID"] == nil) == (operationID == nil),
              (dictionary["operationKind"] == nil) == (operationKind == nil),
              (operationID == nil) == (operationKind == nil),
              operationID.map(isMachineOperationID) ?? true,
              (dictionary["phase"] == nil)
                || phase.map(machineFlightPhases.contains) == true,
              (dictionary["machineState"] == nil)
                || machineState.map(machineEventStates.contains) == true,
              (dictionary["failureCode"] == nil) == (failureCode == nil),
              (dictionary["recoveryDisposition"] == nil) == (recovery == nil),
              (failureCode == nil) == (recovery == nil),
              (dictionary["backend"] == nil) == (backend == nil),
              (dictionary["virtualHardwareABIVersion"] == nil) == (abi == nil),
              abi.map({ $0 > 0 }) ?? true,
              (dictionary["planSHA256"] == nil)
                || planSHA256?.isLowercaseSHA256 == true,
              (dictionary["durationMilliseconds"] == nil) == (duration == nil),
              duration.map({ $0 <= 31 * 24 * 60 * 60 * 1_000 }) ?? true,
              (dictionary["deadlineUnixMilliseconds"] == nil) == (deadline == nil),
              deadline.map({ $0 > 0 }) ?? true,
              (dictionary["deviceID"] == nil) == (deviceID == nil),
              deviceID.map({ !$0.isEmpty && $0.utf8.count <= 128 }) ?? true,
              (dictionary["deviceEventKind"] == nil) == (deviceEventKind == nil),
              deviceEventKind.map(deviceTelemetryEventKinds.contains) ?? true,
              (dictionary["deviceEventSequence"] == nil) == (deviceEventSequence == nil),
              deviceEventSequence.map({ $0 > 0 }) ?? true,
              (dictionary["deviceEventOccurrences"] == nil) == (deviceEventOccurrences == nil),
              deviceEventOccurrences.map({ $0 > 0 }) ?? true else {
            return nil
        }
        if [.failureRecorded, .readinessRejected, .operationFailed, .recoveryRequired]
            .contains(kind), failureCode == nil {
            return nil
        }
        let deviceFields = [
            deviceID != nil,
            deviceEventKind != nil,
            deviceEventSequence != nil,
            deviceEventOccurrences != nil,
        ]
        guard kind == .deviceHealthEvent
            ? deviceFields.allSatisfy({ $0 })
            : deviceFields.allSatisfy({ !$0 }) else {
            return nil
        }
        return DorydMachineFlightEvent(
            sequence: sequence,
            occurredAtUnixMilliseconds: occurredAt,
            machineID: machineID,
            operationID: operationID,
            operationKind: operationKind,
            kind: kind,
            phase: phase,
            machineState: machineState,
            failureCode: failureCode,
            recoveryDisposition: recovery,
            backend: backend,
            virtualHardwareABIVersion: abi,
            planSHA256: planSHA256,
            durationMilliseconds: duration,
            deadlineUnixMilliseconds: deadline,
            deviceID: deviceID,
            deviceEventKind: deviceEventKind,
            deviceEventSequence: deviceEventSequence,
            deviceEventOccurrences: deviceEventOccurrences,
            evidenceReferences: evidence
        )
    }

    nonisolated private static func machineEvent(
        from dictionary: NSDictionary
    ) -> DorydMachineEvent? {
        let requiredKeys: Set<String> = [
            "schemaVersion", "sequence", "observedAtUnixMilliseconds", "machineID",
            "kind",
        ]
        guard let rawKeys = dictionary.allKeys as? [String] else { return nil }
        let keys = Set(rawKeys)
        guard rawKeys.count == keys.count,
              requiredKeys.isSubset(of: keys),
              keys.subtracting(requiredKeys).isSubset(of: ["status"]),
              uint16(dictionary["schemaVersion"]) == 1,
              let sequence = uint64(dictionary["sequence"]), sequence > 0,
              let observedAt = int64(dictionary["observedAtUnixMilliseconds"]),
              observedAt > 0,
              let machineID = dictionary["machineID"] as? String,
              machineID.isSafeMachineIdentifier,
              let kindValue = dictionary["kind"] as? String,
              let kind = DorydMachineEventKind(rawValue: kindValue) else {
            return nil
        }
        let status = (dictionary["status"] as? NSDictionary).flatMap(
            machineEventStatus(from:)
        )
        guard (kind == .updated && status?.machineID == machineID)
                || (kind == .removed && dictionary["status"] == nil) else {
            return nil
        }
        return DorydMachineEvent(
            sequence: sequence,
            observedAtUnixMilliseconds: observedAt,
            machineID: machineID,
            kind: kind,
            status: status
        )
    }

    nonisolated private static func machineEventStatus(
        from dictionary: NSDictionary
    ) -> DorydMachineEventStatus? {
        let requiredKeys: Set<String> = [
            "schemaVersion", "machineID", "configurationRevision", "observedRevision",
            "state", "hasFailure", "memoryMB", "cpuCount", "displayMode", "bootMode",
            "installerMediaAttached", "shareCount", "integrationHealth", "runtimeMode",
            "virtualHardwareABIVersion",
        ]
        guard let rawKeys = dictionary.allKeys as? [String] else { return nil }
        let keys = Set(rawKeys)
        guard rawKeys.count == keys.count,
              requiredKeys.isSubset(of: keys),
              keys.subtracting(requiredKeys).isSubset(of: [
                  "failureCode", "recoveryDisposition", "operationID", "operationKind",
                  "planRevision", "planSHA256", "backend", "savedStateSHA256",
              ]),
              uint16(dictionary["schemaVersion"]) == 1,
              let machineID = dictionary["machineID"] as? String,
              machineID.isSafeMachineIdentifier,
              let configurationRevision = dictionary["configurationRevision"] as? String,
              configurationRevision.isLowercaseSHA256,
              let observedRevision = dictionary["observedRevision"] as? String,
              observedRevision.isLowercaseSHA256,
              let state = dictionary["state"] as? String,
              Self.machineEventStates.contains(state),
              let failureNumber = dictionary["hasFailure"] as? NSNumber,
              CFGetTypeID(failureNumber) == CFBooleanGetTypeID(),
              let memoryMB = uint64(dictionary["memoryMB"]), memoryMB > 0,
              let cpuCount = int(dictionary["cpuCount"]), cpuCount > 0,
              let displayMode = dictionary["displayMode"] as? String,
              ["headless", "desktop"].contains(displayMode),
              let bootMode = dictionary["bootMode"] as? String,
              ["linux-kernel", "efi"].contains(bootMode),
              let installerNumber = dictionary["installerMediaAttached"] as? NSNumber,
              CFGetTypeID(installerNumber) == CFBooleanGetTypeID(),
              let shareCount = int(dictionary["shareCount"]), shareCount >= 0,
              let integrationHealth = dictionary["integrationHealth"] as? String,
              Self.machineIntegrationHealthStates.contains(integrationHealth),
              let runtimeMode = dictionary["runtimeMode"] as? String,
              Self.machineRuntimeModes.contains(runtimeMode),
              let abi = uint16(dictionary["virtualHardwareABIVersion"]), abi > 0 else {
            return nil
        }
        let planRevision = dictionary["planRevision"].flatMap { uint64($0) }
        let failureCode = (dictionary["failureCode"] as? String).flatMap(
            DorydMachineFailureCode.init(rawValue:)
        )
        let recoveryDisposition = (dictionary["recoveryDisposition"] as? String).flatMap(
            DorydMachineRecoveryDisposition.init(rawValue:)
        )
        let operationID = dictionary["operationID"] as? String
        let operationKind = (dictionary["operationKind"] as? String).flatMap(
            DorydMachineOperationKind.init(rawValue:)
        )
        let planSHA256 = dictionary["planSHA256"] as? String
        let backend = (dictionary["backend"] as? String).flatMap(
            DoryVirtualizationBackendIdentity.init(rawValue:)
        )
        let savedStateSHA256 = dictionary["savedStateSHA256"] as? String
        guard (dictionary["planRevision"] == nil) == (planRevision == nil),
              (dictionary["planSHA256"] == nil)
                || planSHA256?.isLowercaseSHA256 == true,
              (dictionary["backend"] == nil) == (backend == nil),
              (dictionary["savedStateSHA256"] == nil)
                || savedStateSHA256?.isLowercaseSHA256 == true,
              (dictionary["failureCode"] == nil) == (failureCode == nil),
              (dictionary["recoveryDisposition"] == nil) == (recoveryDisposition == nil),
              (dictionary["operationID"] == nil) == (operationID == nil),
              (dictionary["operationKind"] == nil) == (operationKind == nil),
              operationID.map(isMachineOperationID) ?? true,
              (operationID == nil) == (operationKind == nil) else {
            return nil
        }
        if failureNumber.boolValue {
            guard failureCode != nil, recoveryDisposition != nil else { return nil }
        } else {
            guard failureCode == nil, recoveryDisposition == nil else { return nil }
        }
        if runtimeMode == "resolved-plan" {
            guard planRevision.map({ $0 > 0 }) == true,
                  planSHA256 != nil,
                  backend != nil else { return nil }
        } else {
            guard planRevision == nil, planSHA256 == nil, backend == nil else { return nil }
        }
        return DorydMachineEventStatus(
            machineID: machineID,
            configurationRevision: configurationRevision,
            observedRevision: observedRevision,
            state: state,
            hasFailure: failureNumber.boolValue,
            failureCode: failureCode,
            recoveryDisposition: recoveryDisposition,
            operationID: operationID,
            operationKind: operationKind,
            memoryMB: memoryMB,
            cpuCount: cpuCount,
            displayMode: displayMode,
            bootMode: bootMode,
            installerMediaAttached: installerNumber.boolValue,
            shareCount: shareCount,
            integrationHealth: integrationHealth,
            runtimeMode: runtimeMode,
            virtualHardwareABIVersion: abi,
            planRevision: planRevision,
            planSHA256: planSHA256,
            backend: backend,
            savedStateSHA256: savedStateSHA256
        )
    }

    nonisolated private static let machineEventStates: Set<String> = [
        "created", "starting", "running", "paused", "suspended", "stopped", "failed",
    ]
    nonisolated private static let machineFlightPhases: Set<String> = [
        "planned", "quiescing", "staging", "verifying", "readyToPublish",
        "publishing", "validating", "completed",
    ]
    nonisolated private static let machineIntegrationHealthStates: Set<String> = [
        "inactive", "missing-tools", "incompatible", "degraded", "compatibility", "healthy",
    ]
    nonisolated private static let machineRuntimeModes: Set<String> = [
        "legacy-compatibility", "resolved-plan", "requires-replanning",
    ]
    nonisolated private static let deviceTelemetryMetricKinds: Set<String> = [
        "queue-notifications", "queue-state-changes", "used-interrupts",
        "configuration-interrupts", "device-resets", "transmitted-frames",
        "transmitted-bytes", "transmit-drops", "received-frames", "received-bytes",
        "receive-deferred", "receive-drops", "receive-truncations", "reconnects",
        "configured-port-forwards", "active-port-forwards",
        "port-forward-reconciliation-failures",
        "display-frames", "display-drops", "audio-drops", "storage-flushes",
        "maximum-storage-flush-latency-nanoseconds", "graphics-fences",
        "graphics-device-losses", "share-invalidations", "share-invalidation-failures",
    ]
    nonisolated private static let deviceTelemetryEventKinds: Set<String> = [
        "queue-stall", "reset", "graphics-fence-timeout", "graphics-device-loss",
        "network-reconnect", "audio-drop", "storage-flush-slow",
        "share-invalidation-failure",
    ]

    nonisolated private static func deviceTelemetryMetricUnit(for kind: String) -> String {
        switch kind {
        case "transmitted-bytes", "received-bytes":
            "bytes"
        case "maximum-storage-flush-latency-nanoseconds":
            "nanoseconds"
        default:
            "count"
        }
    }

    nonisolated private static func machineImportAssessment(
        from dictionary: NSDictionary
    ) -> DorydMachineImportAssessment? {
        let requiredKeys: Set<String> = [
            "schemaVersion", "contentID", "sourceMachineID", "sourceSnapshotID",
            "architecture", "bootMode", "diskSizeBytes", "virtualHardwareABIVersion",
            "sourceRuntimeMode", "portable", "disposition", "issues", "components",
        ]
        guard let rawKeys = dictionary.allKeys as? [String] else { return nil }
        let keys = Set(rawKeys)
        guard rawKeys.count == keys.count,
              requiredKeys.isSubset(of: keys),
              keys.subtracting(requiredKeys).isSubset(of: ["sourceBackend"]),
              let schemaVersion = uint16(dictionary["schemaVersion"]),
              schemaVersion == 1,
              let contentID = dictionary["contentID"] as? String,
              contentID.isLowercaseSHA256,
              let sourceMachineID = dictionary["sourceMachineID"] as? String,
              sourceMachineID.isSafeMachineIdentifier,
              let sourceSnapshotID = dictionary["sourceSnapshotID"] as? String,
              sourceSnapshotID.isSafeMachineIdentifier,
              let architecture = dictionary["architecture"] as? String,
              ["arm64", "x86_64"].contains(architecture),
              let bootMode = dictionary["bootMode"] as? String,
              ["linux-kernel", "efi"].contains(bootMode),
              let diskSizeBytes = uint64(dictionary["diskSizeBytes"]), diskSizeBytes > 0,
              let virtualHardwareABIVersion = uint16(
                  dictionary["virtualHardwareABIVersion"]
              ), virtualHardwareABIVersion > 0,
              let sourceRuntimeMode = dictionary["sourceRuntimeMode"] as? String,
              ["legacy-compatibility", "resolved-plan", "requires-replanning"]
                .contains(sourceRuntimeMode),
              let portable = dictionary["portable"] as? Bool,
              let dispositionRaw = dictionary["disposition"] as? String,
              let disposition = DorydMachineImportDisposition(rawValue: dispositionRaw),
              let issueRows = dictionary["issues"] as? NSArray,
              let issues = issueRows as? [String],
              Set(issues).count == issues.count,
              issues.allSatisfy({ Self.machineImportIssueCodes.contains($0) }),
              let componentRows = dictionary["components"] as? NSArray else {
            return nil
        }
        let sourceBackend: DoryVirtualizationBackendIdentity?
        if let rawBackend = dictionary["sourceBackend"] {
            guard let encoded = rawBackend as? String,
                  let decoded = DoryVirtualizationBackendIdentity(rawValue: encoded) else {
                return nil
            }
            sourceBackend = decoded
        } else {
            sourceBackend = nil
        }
        var components: [DorydMachineImportComponentAssessment] = []
        for row in componentRows {
            guard let component = row as? NSDictionary,
                  let componentKeys = component.allKeys as? [String],
                  componentKeys.count == 4,
                  Set(componentKeys) == [
                      "componentIdentifier", "buildIdentifier", "artifactSHA256",
                      "availability",
                  ],
                  let componentIdentifier = component["componentIdentifier"] as? String,
                  componentIdentifier.isSafeEvidenceIdentifier,
                  let buildIdentifier = component["buildIdentifier"] as? String,
                  buildIdentifier.isSafeEvidenceIdentifier,
                  let artifactSHA256 = component["artifactSHA256"] as? String,
                  artifactSHA256.isLowercaseSHA256,
                  let availabilityRaw = component["availability"] as? String,
                  let availability = DorydMachineImportComponentAvailability(
                      rawValue: availabilityRaw
                  ) else {
                return nil
            }
            components.append(DorydMachineImportComponentAssessment(
                componentIdentifier: componentIdentifier,
                buildIdentifier: buildIdentifier,
                artifactSHA256: artifactSHA256,
                availability: availability
            ))
        }
        let hasUnavailableComponents = components.contains {
            $0.availability != .available
        }
        guard Set(components.map(\.componentIdentifier)).count == components.count,
              (sourceRuntimeMode == "resolved-plan") == (sourceBackend != nil),
              (sourceRuntimeMode == "resolved-plan") == !components.isEmpty,
              portable == (disposition != .unavailable),
              (disposition == .requiresComponents) == (portable && hasUnavailableComponents),
              disposition == .unavailable || !hasUnavailableComponents,
              disposition != .ready || sourceRuntimeMode == "legacy-compatibility" else {
            return nil
        }
        return DorydMachineImportAssessment(
            schemaVersion: schemaVersion,
            contentID: contentID,
            sourceMachineID: sourceMachineID,
            sourceSnapshotID: sourceSnapshotID,
            architecture: architecture,
            bootMode: bootMode,
            diskSizeBytes: diskSizeBytes,
            virtualHardwareABIVersion: virtualHardwareABIVersion,
            sourceRuntimeMode: sourceRuntimeMode,
            sourceBackend: sourceBackend,
            portable: portable,
            disposition: disposition,
            issues: issues,
            components: components
        )
    }

    nonisolated private static let machineImportIssueCodes: Set<String> = [
        "architecture-mismatch", "virtual-hardware-abi-mismatch",
        "backend-runtime-differs", "missing-components", "mismatched-components",
        "resolved-plan-requires-replanning", "source-requires-replanning",
        "legacy-requires-migration",
    ]

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

    nonisolated private static func machineFileTransferResult(
        from dictionary: NSDictionary
    ) -> DorydMachineFileTransferResult? {
        guard Set(dictionary.allKeys.compactMap { $0 as? String })
                == ["schema", "transferID", "guestDestination", "filesSent", "bytesSent"],
              dictionary.allKeys.count == 5,
              strictUInt64(dictionary["schema"]) == 1,
              let transferID = dictionary["transferID"] as? String,
              transferID.utf8.count == 32,
              transferID.utf8.allSatisfy({ byte in
                  (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
              }),
              let guestDestination = dictionary["guestDestination"] as? String,
              guestDestination.utf8.count <= 4_096,
              !guestDestination.contains("\0"),
              let filesSent = strictUInt64(dictionary["filesSent"]),
              let bytesSent = strictUInt64(dictionary["bytesSent"]) else {
            return nil
        }
        let suffix = "/Downloads/Dory Transfer " + transferID
        guard guestDestination.hasPrefix("/home/"),
              guestDestination.hasSuffix(suffix) else {
            return nil
        }
        let usernameStart = guestDestination.index(
            guestDestination.startIndex,
            offsetBy: "/home/".count
        )
        let usernameEnd = guestDestination.index(
            guestDestination.endIndex,
            offsetBy: -suffix.count
        )
        guard usernameStart < usernameEnd,
              DoryVMGuestAccountIntent.isValidUsername(
                  String(guestDestination[usernameStart..<usernameEnd])
              ) else {
            return nil
        }
        return DorydMachineFileTransferResult(
            transferID: transferID,
            guestDestination: guestDestination,
            filesSent: filesSent,
            bytesSent: bytesSent
        )
    }

    nonisolated private static func machineFileTransferOperation(
        from dictionary: NSDictionary
    ) -> DorydMachineFileTransferOperation? {
        let requiredKeys: Set<String> = [
            "schema", "operationID", "machineID", "phase", "filesTotal",
            "filesCompleted", "bytesTotal", "bytesCompleted",
        ]
        let optionalKeys: Set<String> = [
            "currentPath", "guestDestination", "result", "failure",
        ]
        guard let rawKeys = dictionary.allKeys as? [String],
              rawKeys.count == dictionary.allKeys.count,
              Set(rawKeys).isSuperset(of: requiredKeys),
              Set(rawKeys).isSubset(of: requiredKeys.union(optionalKeys)),
              strictUInt64(dictionary["schema"]) == 1,
              let operationID = dictionary["operationID"] as? String,
              isValidMachineTransferOperationID(operationID),
              let machineID = dictionary["machineID"] as? String,
              machineID.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9_.-]{0,62}/) != nil,
              let rawPhase = dictionary["phase"] as? String,
              let phase = DorydMachineFileTransferPhase(rawValue: rawPhase),
              let filesTotal = strictUInt64(dictionary["filesTotal"]),
              filesTotal <= UInt64(DoryMachineFileTransferStager.maximumFileCount),
              let filesCompleted = strictUInt64(dictionary["filesCompleted"]),
              filesCompleted <= filesTotal,
              let bytesTotal = strictUInt64(dictionary["bytesTotal"]),
              bytesTotal <= DoryMachineFileTransferStager.maximumTransferBytes,
              let bytesCompleted = strictUInt64(dictionary["bytesCompleted"]),
              bytesCompleted <= bytesTotal else {
            return nil
        }
        let currentPath: String?
        if let rawCurrentPath = dictionary["currentPath"] {
            guard let value = rawCurrentPath as? String,
                  isSafeMachineTransferRelativePath(value),
                  !phase.isTerminal else {
                return nil
            }
            currentPath = value
        } else {
            currentPath = nil
        }
        let guestDestination: String?
        if let rawGuestDestination = dictionary["guestDestination"] {
            guard let value = rawGuestDestination as? String,
                  isValidMachineTransferDestination(value, transferID: operationID) else {
                return nil
            }
            guestDestination = value
        } else {
            guestDestination = nil
        }
        let result: DorydMachineFileTransferResult?
        if let rawResult = dictionary["result"] {
            guard let row = rawResult as? NSDictionary,
                  let decoded = machineFileTransferResult(from: row),
                  decoded.transferID == operationID else {
                return nil
            }
            result = decoded
        } else {
            result = nil
        }
        let failure: DorydMachineFileTransferFailure?
        if let rawFailure = dictionary["failure"] {
            guard let row = rawFailure as? NSDictionary,
                  Set(row.allKeys.compactMap { $0 as? String })
                    == ["schema", "code", "message"],
                  row.allKeys.count == 3,
                  strictUInt64(row["schema"]) == 1,
                  let rawCode = row["code"] as? String,
                  let code = DorydMachineFileTransferFailureCode(rawValue: rawCode),
                  let message = row["message"] as? String,
                  !message.isEmpty,
                  message.utf8.count <= 1_024,
                  !message.contains("\0") else {
                return nil
            }
            failure = DorydMachineFileTransferFailure(code: code, message: message)
        } else {
            failure = nil
        }

        switch phase {
        case .completed:
            guard let result,
                  failure == nil,
                  guestDestination == result.guestDestination,
                  filesTotal == result.filesSent,
                  filesCompleted == result.filesSent,
                  bytesTotal == result.bytesSent,
                  bytesCompleted == result.bytesSent else {
                return nil
            }
        case .failed:
            guard failure != nil, result == nil else { return nil }
        case .cancelled:
            guard result == nil, failure == nil else { return nil }
        case .preparing, .transferring, .finalizing, .cancelling:
            guard result == nil, failure == nil else { return nil }
        }
        return DorydMachineFileTransferOperation(
            operationID: operationID,
            machineID: machineID,
            phase: phase,
            filesTotal: filesTotal,
            filesCompleted: filesCompleted,
            bytesTotal: bytesTotal,
            bytesCompleted: bytesCompleted,
            currentPath: currentPath,
            guestDestination: guestDestination,
            result: result,
            failure: failure
        )
    }

    nonisolated private static func machineFileTransferCurrent(
        from dictionary: NSDictionary,
        machineID: String
    ) -> DorydMachineFileTransferCurrent? {
        guard let keys = dictionary.allKeys as? [String],
              keys.count == dictionary.allKeys.count,
              strictUInt64(dictionary["schema"]) == 1,
              let activeNumber = dictionary["active"] as? NSNumber,
              CFGetTypeID(activeNumber) == CFBooleanGetTypeID() else {
            return nil
        }
        if activeNumber.boolValue {
            guard Set(keys) == ["schema", "active", "operation"],
                  let row = dictionary["operation"] as? NSDictionary,
                  let operation = machineFileTransferOperation(from: row),
                  operation.machineID == machineID,
                  !operation.phase.isTerminal else {
                return nil
            }
            return DorydMachineFileTransferCurrent(operation: operation)
        }
        guard Set(keys) == ["schema", "active"] else { return nil }
        return DorydMachineFileTransferCurrent(operation: nil)
    }

    nonisolated private static func machineGuestFileExportResult(
        from dictionary: NSDictionary
    ) -> DorydMachineGuestFileExportResult? {
        guard Set(dictionary.allKeys.compactMap { $0 as? String }) == [
            "schema", "exportID", "privateStagingRoot", "filesReceived",
            "directoriesReceived", "bytesReceived",
        ],
              dictionary.allKeys.count == 6,
              strictUInt64(dictionary["schema"]) == 1,
              let exportID = dictionary["exportID"] as? String,
              isValidMachineTransferOperationID(exportID),
              let privateStagingRoot = dictionary["privateStagingRoot"] as? String,
              isValidMachineGuestExportRoot(
                  privateStagingRoot,
                  exportID: exportID
              ),
              let filesReceived = strictUInt64(dictionary["filesReceived"]),
              filesReceived <= UInt64(DoryMachineFileTransferStager.maximumFileCount),
              let directoriesReceived = strictUInt64(dictionary["directoriesReceived"]),
              let bytesReceived = strictUInt64(dictionary["bytesReceived"]),
              bytesReceived <= DoryMachineFileTransferStager.maximumTransferBytes else {
            return nil
        }
        let (entriesReceived, overflow) = filesReceived.addingReportingOverflow(
            directoriesReceived
        )
        guard !overflow,
              entriesReceived <= UInt64(DoryMachineFileTransferStager.maximumEntryCount) else {
            return nil
        }
        return DorydMachineGuestFileExportResult(
            exportID: exportID,
            privateStagingRoot: privateStagingRoot,
            filesReceived: filesReceived,
            directoriesReceived: directoriesReceived,
            bytesReceived: bytesReceived
        )
    }

    nonisolated private static func machineGuestFileExportOperation(
        from dictionary: NSDictionary,
        allowsOmittedCompletedResult: Bool = false
    ) -> DorydMachineGuestFileExportOperation? {
        let requiredKeys: Set<String> = [
            "schema", "operationID", "machineID", "phase", "filesTotal",
            "filesCompleted", "bytesTotal", "bytesCompleted",
        ]
        let optionalKeys: Set<String> = ["currentPath", "result", "failure"]
        guard let rawKeys = dictionary.allKeys as? [String],
              rawKeys.count == dictionary.allKeys.count,
              Set(rawKeys).isSuperset(of: requiredKeys),
              Set(rawKeys).isSubset(of: requiredKeys.union(optionalKeys)),
              strictUInt64(dictionary["schema"]) == 1,
              let operationID = dictionary["operationID"] as? String,
              isValidMachineTransferOperationID(operationID),
              let machineID = dictionary["machineID"] as? String,
              machineID.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9_.-]{0,62}/) != nil,
              let rawPhase = dictionary["phase"] as? String,
              let phase = DorydMachineFileTransferPhase(rawValue: rawPhase),
              let filesTotal = strictUInt64(dictionary["filesTotal"]),
              filesTotal <= UInt64(DoryMachineFileTransferStager.maximumFileCount),
              let filesCompleted = strictUInt64(dictionary["filesCompleted"]),
              filesCompleted <= filesTotal,
              let bytesTotal = strictUInt64(dictionary["bytesTotal"]),
              bytesTotal <= DoryMachineFileTransferStager.maximumTransferBytes,
              let bytesCompleted = strictUInt64(dictionary["bytesCompleted"]),
              bytesCompleted <= bytesTotal else {
            return nil
        }
        let currentPath: String?
        if let rawCurrentPath = dictionary["currentPath"] {
            guard let value = rawCurrentPath as? String,
                  isSafeMachineTransferRelativePath(value),
                  !phase.isTerminal else {
                return nil
            }
            currentPath = value
        } else {
            currentPath = nil
        }
        let result: DorydMachineGuestFileExportResult?
        if let rawResult = dictionary["result"] {
            guard let row = rawResult as? NSDictionary,
                  let decoded = machineGuestFileExportResult(from: row),
                  decoded.exportID == operationID else {
                return nil
            }
            result = decoded
        } else {
            result = nil
        }
        let failure: DorydMachineFileTransferFailure?
        if let rawFailure = dictionary["failure"] {
            guard let row = rawFailure as? NSDictionary,
                  Set(row.allKeys.compactMap { $0 as? String })
                    == ["schema", "code", "message"],
                  row.allKeys.count == 3,
                  strictUInt64(row["schema"]) == 1,
                  let rawCode = row["code"] as? String,
                  let code = DorydMachineFileTransferFailureCode(rawValue: rawCode),
                  let message = row["message"] as? String,
                  !message.isEmpty,
                  message.utf8.count <= 1_024,
                  !message.contains("\0") else {
                return nil
            }
            failure = DorydMachineFileTransferFailure(code: code, message: message)
        } else {
            failure = nil
        }

        switch phase {
        case .completed:
            guard failure == nil,
                  filesCompleted == filesTotal,
                  bytesCompleted == bytesTotal else {
                return nil
            }
            if let result {
                guard filesTotal == result.filesReceived,
                      bytesTotal == result.bytesReceived else {
                    return nil
                }
            } else if !allowsOmittedCompletedResult {
                return nil
            }
        case .failed:
            guard failure != nil, result == nil else { return nil }
        case .cancelled:
            guard result == nil, failure == nil else { return nil }
        case .preparing, .transferring, .finalizing, .cancelling:
            guard result == nil, failure == nil else { return nil }
        }
        return DorydMachineGuestFileExportOperation(
            operationID: operationID,
            machineID: machineID,
            phase: phase,
            filesTotal: filesTotal,
            filesCompleted: filesCompleted,
            bytesTotal: bytesTotal,
            bytesCompleted: bytesCompleted,
            currentPath: currentPath,
            result: result,
            failure: failure
        )
    }

    nonisolated private static func machineGuestFileExportCurrent(
        from dictionary: NSDictionary,
        machineID: String
    ) -> DorydMachineGuestFileExportCurrent? {
        guard let keys = dictionary.allKeys as? [String],
              keys.count == dictionary.allKeys.count,
              strictUInt64(dictionary["schema"]) == 1,
              let activeNumber = dictionary["active"] as? NSNumber,
              CFGetTypeID(activeNumber) == CFBooleanGetTypeID() else {
            return nil
        }
        if activeNumber.boolValue {
            guard Set(keys) == ["schema", "active", "operation"],
                  let row = dictionary["operation"] as? NSDictionary,
                  let operation = machineGuestFileExportOperation(from: row),
                  operation.machineID == machineID,
                  !operation.phase.isTerminal || operation.phase == .completed else {
                return nil
            }
            return DorydMachineGuestFileExportCurrent(operation: operation)
        }
        guard Set(keys) == ["schema", "active"] else { return nil }
        return DorydMachineGuestFileExportCurrent(operation: nil)
    }

    nonisolated private static func isValidMachineGuestExportRoot(
        _ value: String,
        exportID: String
    ) -> Bool {
        guard value.hasPrefix("/"),
              value.utf8.count <= 4_096,
              !value.contains("\0") else {
            return false
        }
        let url = URL(fileURLWithPath: value, isDirectory: true)
        guard url.standardizedFileURL.path == value,
              url.deletingLastPathComponent().standardizedFileURL
                == DoryMachineFileTransferStager.defaultStagingDirectory.standardizedFileURL else {
            return false
        }
        let name = url.lastPathComponent
        let prefix = "export-"
        let suffix = "-" + exportID
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return false }
        let processStart = name.index(name.startIndex, offsetBy: prefix.count)
        let processEnd = name.index(name.endIndex, offsetBy: -suffix.count)
        guard processStart < processEnd,
              let processID = UInt64(name[processStart..<processEnd]),
              processID > 0 else {
            return false
        }
        return true
    }

    nonisolated private static func isValidMachineTransferOperationID(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }

    nonisolated private static func isSafeMachineTransferRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= 4_096,
              !value.hasPrefix("/"),
              !value.contains("\0") else {
            return false
        }
        return value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    nonisolated private static func isValidMachineTransferDestination(
        _ value: String,
        transferID: String
    ) -> Bool {
        guard value.utf8.count <= 4_096, !value.contains("\0") else { return false }
        let suffix = "/Downloads/Dory Transfer " + transferID
        guard value.hasPrefix("/home/"), value.hasSuffix(suffix) else { return false }
        let usernameStart = value.index(value.startIndex, offsetBy: "/home/".count)
        let usernameEnd = value.index(value.endIndex, offsetBy: -suffix.count)
        return usernameStart < usernameEnd
            && DoryVMGuestAccountIntent.isValidUsername(
                String(value[usernameStart..<usernameEnd])
            )
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

    nonisolated private static func machineTransferControlTimeout(
        byteCount: UInt64
    ) -> TimeInterval {
        // Allow two hours at the 64 GiB staging ceiling, with a two-minute fixed setup budget.
        let transferSeconds = Double(byteCount) / (10 * 1024 * 1024)
        return min(2 * 60 * 60, 120 + transferSeconds)
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

    nonisolated private static func strictUInt64(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let decoded = number.uint64Value
        guard number.stringValue == String(decoded) else { return nil }
        return decoded
    }

    nonisolated private static func strictInt64(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let decoded = number.int64Value
        guard number.stringValue == String(decoded) else { return nil }
        return decoded
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
