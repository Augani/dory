import Foundation

/// Stable identity persisted independently from a VM's runtime process identity.
public struct DoryVirtualMachineIdentity: Codable, Sendable, Equatable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public enum DoryVMBootMediaRole: String, Codable, Sendable, CaseIterable {
    case installer
    case system
    case recovery
}

/// Structured, non-secret key resolved by an artifact or share registry.
/// Both components are deliberately path/URL hostile and bounded for safe persistence.
public struct DoryVMResolverReference: Codable, Sendable, Equatable, Hashable {
    public var namespace: String
    public var identifier: String

    public init(namespace: String, identifier: String) {
        self.namespace = namespace
        self.identifier = identifier
    }
}

public enum DoryVMBootPhase: String, Codable, Sendable, CaseIterable {
    case install
    case normal
    case live
    case recovery
}

/// A non-secret reference to media resolved by an artifact store at launch time.
///
/// `artifact` is a structured catalog key. Credentials, signed URLs, access tokens, host paths,
/// and other secret material must remain in the resolver and are never persisted here.
public struct DoryVMBootMediaReference: Codable, Sendable, Equatable {
    public var id: String
    public var role: DoryVMBootMediaRole
    public var kind: DoryBootMediaKind
    public var source: DoryBootMediaSource
    public var artifact: DoryVMResolverReference
    public var removable: Bool

    public init(
        id: String,
        role: DoryVMBootMediaRole,
        kind: DoryBootMediaKind,
        source: DoryBootMediaSource,
        artifact: DoryVMResolverReference,
        removable: Bool
    ) {
        self.id = id
        self.role = role
        self.kind = kind
        self.source = source
        self.artifact = artifact
        self.removable = removable
    }

    public var capabilityMedia: DoryBootMedia {
        DoryBootMedia(kind: kind, source: source)
    }
}

/// Boot phase, attached boot media, and deterministic firmware/device priority.
public struct DoryVMBootConfiguration: Codable, Sendable, Equatable {
    public var phase: DoryVMBootPhase
    public var devices: [DoryVMBootMediaReference]
    public var order: [String]

    public init(
        phase: DoryVMBootPhase,
        devices: [DoryVMBootMediaReference],
        order: [String]
    ) {
        self.phase = phase
        self.devices = devices
        self.order = order
    }
}

public enum DoryVMBackendPreferenceMode: String, Codable, Sendable, CaseIterable {
    case automatic
    case preferred
    case required
}

/// Backend intent, not a backend selection or availability claim.
///
/// The daemon must still negotiate this preference through its capability evaluator.
public struct DoryVMBackendPreference: Codable, Sendable, Equatable {
    public var mode: DoryVMBackendPreferenceMode
    public var backend: DoryVirtualizationBackendIdentity?

    public init(
        mode: DoryVMBackendPreferenceMode = .automatic,
        backend: DoryVirtualizationBackendIdentity? = nil
    ) {
        self.mode = mode
        self.backend = backend
    }
}

/// Ordered graphics contracts acceptable to the user, from most to least preferred.
/// Runtime capability negotiation must select one exact entry or reject the definition.
public struct DoryVMGraphicsPolicy: Codable, Sendable, Equatable {
    public var acceptableLevels: [DoryGraphicsAccelerationLevel]

    public init(acceptableLevels: [DoryGraphicsAccelerationLevel]) {
        self.acceptableLevels = acceptableLevels
    }
}

public enum DoryVMStorageRole: String, Codable, Sendable, CaseIterable {
    case system
    case data
}

/// A disk artifact attached to the VM. Host paths and storage credentials are resolved outside
/// this persistence contract from its structured artifact reference.
public struct DoryVMStorageAttachment: Codable, Sendable, Equatable {
    public var id: String
    public var role: DoryVMStorageRole
    public var artifact: DoryVMResolverReference
    /// Provenance intent for the virtual disk. Storage kind is always `.virtualDisk`; writable
    /// attachments require mutable daemon provenance and read-only attachments are immutable.
    public var source: DoryBootMediaSource
    public var capacityBytes: UInt64
    public var readOnly: Bool

    public init(
        id: String,
        role: DoryVMStorageRole,
        artifact: DoryVMResolverReference,
        source: DoryBootMediaSource = .userProvided,
        capacityBytes: UInt64,
        readOnly: Bool = false
    ) {
        self.id = id
        self.role = role
        self.artifact = artifact
        self.source = source
        self.capacityBytes = capacityBytes
        self.readOnly = readOnly
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, artifact, source, capacityBytes, readOnly
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            role: try container.decode(DoryVMStorageRole.self, forKey: .role),
            artifact: try container.decode(DoryVMResolverReference.self, forKey: .artifact),
            // Schema 2 did not bind storage provenance. Conservatively migrate it as imported;
            // never manufacture Dory distribution/qualification authority.
            source: try container.decodeIfPresent(
                DoryBootMediaSource.self,
                forKey: .source
            ) ?? .userProvided,
            capacityBytes: try container.decode(UInt64.self, forKey: .capacityBytes),
            readOnly: try container.decode(Bool.self, forKey: .readOnly)
        )
    }
}

public enum DoryVMNetworkMode: String, Codable, Sendable, CaseIterable {
    case disconnected
    case sharedNAT = "shared-nat"
    case bridged
    /// Deterministic host-only connectivity. The historical wire value remains `isolated` so
    /// existing schema-v2/v3 definitions and canonical plan digests stay readable.
    case isolated
}

public enum DoryVMPortForwardTransport: String, Codable, Sendable, CaseIterable, Hashable {
    case tcp
    case udp
}

/// Host visibility is closed intent rather than a caller-supplied bind address. Loopback is the
/// safe default; LAN exposure remains an explicit choice that policy and runtime authorization can
/// reject without rewriting it to a broader address.
public enum DoryVMPortForwardExposure: String, Codable, Sendable, CaseIterable, Hashable {
    case loopback
    case lan
}

/// One stable inbound mapping for a userspace-networked guest. Runtime endpoints and gvproxy
/// process details are deliberately absent from desired state.
public struct DoryVMPortForward: Codable, Sendable, Equatable, Hashable {
    public static let maximumCount = 64

    public var id: String
    public var transport: DoryVMPortForwardTransport
    public var hostPort: UInt16
    public var guestPort: UInt16
    public var exposure: DoryVMPortForwardExposure

    public init(
        id: String,
        transport: DoryVMPortForwardTransport = .tcp,
        hostPort: UInt16,
        guestPort: UInt16,
        exposure: DoryVMPortForwardExposure = .loopback
    ) {
        self.id = id
        self.transport = transport
        self.hostPort = hostPort
        self.guestPort = guestPort
        self.exposure = exposure
    }
}

public struct DoryVMDisplayConfiguration: Codable, Sendable, Equatable {
    public static let maximumCount = 16
    public static let maximumDimensionPixels: UInt32 = 16_384

    /// Stable virtual connector identity. It survives host monitor changes and window movement.
    public var id: String
    public var enabled: Bool
    public var widthPixels: UInt32
    public var heightPixels: UInt32
    public var pixelsPerInch: UInt16
    /// Guest framebuffer pixels per host window point. This is independent of desktop UI scale.
    public var backingScaleFactor: UInt8
    /// Guest toolkit/UI scale. This does not change framebuffer pixel dimensions.
    public var guestUIScaleFactor: UInt8

    public init(
        id: String = "display-0",
        enabled: Bool = true,
        widthPixels: UInt32 = 1_920,
        heightPixels: UInt32 = 1_080,
        pixelsPerInch: UInt16 = 110,
        backingScaleFactor: UInt8 = 2,
        guestUIScaleFactor: UInt8 = 2
    ) {
        self.id = id
        self.enabled = enabled
        self.widthPixels = widthPixels
        self.heightPixels = heightPixels
        self.pixelsPerInch = pixelsPerInch
        self.backingScaleFactor = backingScaleFactor
        self.guestUIScaleFactor = guestUIScaleFactor
    }

    public static let disabled = DoryVMDisplayConfiguration(
        enabled: false,
        widthPixels: 0,
        heightPixels: 0,
        pixelsPerInch: 0,
        backingScaleFactor: 0,
        guestUIScaleFactor: 0
    )

    public static func isValidIdentifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...63).contains(bytes.count), let first = bytes.first,
              isASCIIAlphaNumeric(first) else { return false }
        return bytes.dropFirst().allSatisfy { byte in
            isASCIIAlphaNumeric(byte) || byte == 45 || byte == 46 || byte == 95
        }
    }

    private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        (byte >= 48 && byte <= 57)
            || (byte >= 65 && byte <= 90)
            || (byte >= 97 && byte <= 122)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case enabled
        case widthPixels
        case heightPixels
        case pixelsPerInch
        case backingScaleFactor
        case guestUIScaleFactor
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? "display-0"
        enabled = try container.decode(Bool.self, forKey: .enabled)
        widthPixels = try container.decode(UInt32.self, forKey: .widthPixels)
        heightPixels = try container.decode(UInt32.self, forKey: .heightPixels)
        pixelsPerInch = try container.decode(UInt16.self, forKey: .pixelsPerInch)
        // Historical definitions implemented the same 2x/2x behavior but did not name the two
        // independent scales. Preserve those exact bytes as the established compatibility default.
        backingScaleFactor = try container.decodeIfPresent(UInt8.self, forKey: .backingScaleFactor)
            ?? (enabled ? 2 : 0)
        guestUIScaleFactor = try container.decodeIfPresent(UInt8.self, forKey: .guestUIScaleFactor)
            ?? (enabled ? 2 : 0)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(widthPixels, forKey: .widthPixels)
        try container.encode(heightPixels, forKey: .heightPixels)
        try container.encode(pixelsPerInch, forKey: .pixelsPerInch)
        try container.encode(backingScaleFactor, forKey: .backingScaleFactor)
        try container.encode(guestUIScaleFactor, forKey: .guestUIScaleFactor)
    }
}

public struct DoryVMAudioConfiguration: Codable, Sendable, Equatable {
    public var inputEnabled: Bool
    public var outputEnabled: Bool

    public init(inputEnabled: Bool = false, outputEnabled: Bool = true) {
        self.inputEnabled = inputEnabled
        self.outputEnabled = outputEnabled
    }
}

/// Host-camera sharing policy. The runtime exposes an enabled camera as a standard UVC device, so
/// Linux applications use the normal `uvcvideo`/V4L2 stack instead of a Dory-specific API.
public struct DoryVMCameraConfiguration: Codable, Sendable, Equatable {
    public static let legacyEnabledEnvironmentKey = "DORY_DESKTOP_CAMERA"
    public var enabled: Bool

    public init(enabled: Bool = false) {
        self.enabled = enabled
    }
}

public struct DoryVMInputConfiguration: Codable, Sendable, Equatable {
    public var keyboardEnabled: Bool
    public var pointerEnabled: Bool

    public init(keyboardEnabled: Bool = true, pointerEnabled: Bool = true) {
        self.keyboardEnabled = keyboardEnabled
        self.pointerEnabled = pointerEnabled
    }
}

/// A host location shared into the guest. The host location is resolved from a non-secret opaque
/// identity so bookmarks, paths, and authorization material can be managed separately.
public struct DoryVMShare: Codable, Sendable, Equatable {
    public var id: String
    public var hostLocation: DoryVMResolverReference
    public var guestMountPath: String
    public var readOnly: Bool

    public init(
        id: String,
        hostLocation: DoryVMResolverReference,
        guestMountPath: String,
        readOnly: Bool = false
    ) {
        self.id = id
        self.hostLocation = hostLocation
        self.guestMountPath = guestMountPath
        self.readOnly = readOnly
    }
}

public enum DoryVMGuestIntegration: String, Codable, Sendable, CaseIterable {
    case clipboard
    case clockSynchronization = "clock-synchronization"
    case dynamicDisplay = "dynamic-display"
    case gracefulShutdown = "graceful-shutdown"
    /// Exposes Apple's Rosetta runtime to an ARM64 Linux guest so it can execute Intel Linux
    /// applications. Installation remains an explicit host-side user action.
    case intelApplicationTranslation = "intel-application-translation"
    /// Authorizes user-approved USB hotplug through the guest's versioned USB/IP integration.
    /// Host device identities remain runtime-only and are never persisted in desired state.
    case removableUSBHotplug = "removable-usb-hotplug"
}

/// Minimal metadata needed for optimistic persistence and ordering.
public struct DoryVMLifecycleMetadata: Codable, Sendable, Equatable {
    public var revision: UInt64
    /// Unix epoch milliseconds, encoded as an integer for stable cross-language persistence.
    public var createdAtUnixMilliseconds: Int64
    /// Unix epoch milliseconds, encoded as an integer for stable cross-language persistence.
    public var updatedAtUnixMilliseconds: Int64

    public init(
        revision: UInt64 = 1,
        createdAtUnixMilliseconds: Int64,
        updatedAtUnixMilliseconds: Int64
    ) {
        self.revision = revision
        self.createdAtUnixMilliseconds = createdAtUnixMilliseconds
        self.updatedAtUnixMilliseconds = updatedAtUnixMilliseconds
    }

    /// Source-compatible construction bridge. Persistence always uses integer epoch milliseconds.
    public init(revision: UInt64 = 1, createdAt: Date, updatedAt: Date) {
        self.init(
            revision: revision,
            createdAtUnixMilliseconds: Self.unixMilliseconds(createdAt),
            updatedAtUnixMilliseconds: Self.unixMilliseconds(updatedAt)
        )
    }

    private static func unixMilliseconds(_ date: Date) -> Int64 {
        let value = date.timeIntervalSince1970 * 1_000
        guard value.isFinite else { return 0 }
        if value >= Double(Int64.max) { return .max }
        if value <= Double(Int64.min) { return .min }
        return Int64(value.rounded(.towardZero))
    }
}

public enum DoryVMDefinitionValidationCode: String, Codable, Sendable, CaseIterable {
    case unsupportedSchemaVersion = "unsupported-schema-version"
    case unsupportedVirtualHardwareABIVersion = "unsupported-virtual-hardware-abi-version"
    case emptyIdentifier = "empty-identifier"
    case invalidIdentifier = "invalid-identifier"
    case emptyName = "empty-name"
    case invalidResolverReference = "invalid-resolver-reference"
    case duplicateBootDeviceIdentifier = "duplicate-boot-device-identifier"
    case invalidBootOrder = "invalid-boot-order"
    case invalidBootPhase = "invalid-boot-phase"
    case invalidBootAttachment = "invalid-boot-attachment"
    case bootMediaRoleMismatch = "boot-media-role-mismatch"
    case multipleSystemBootDevices = "multiple-system-boot-devices"
    case bootMediaIncompatibleWithGuest = "boot-media-incompatible-with-guest"
    case guestMediaCannotBeBundled = "guest-media-cannot-be-bundled"
    case backendPreferenceMalformed = "backend-preference-malformed"
    case emptyGraphicsPolicy = "empty-graphics-policy"
    case duplicateGraphicsLevel = "duplicate-graphics-level"
    case nonPositiveResource = "non-positive-resource"
    case emptyAttachmentIdentifier = "empty-attachment-identifier"
    case duplicateAttachmentIdentifier = "duplicate-attachment-identifier"
    case duplicateWritableStorageArtifactIdentity = "duplicate-writable-storage-artifact-identity"
    case nonPositiveAttachmentCapacity = "non-positive-attachment-capacity"
    case missingSystemDisk = "missing-system-disk"
    case multipleSystemDisks = "multiple-system-disks"
    case readOnlySystemDisk = "read-only-system-disk"
    case systemDiskCapacityMismatch = "system-disk-capacity-mismatch"
    case bootDiskArtifactMismatch = "boot-disk-artifact-mismatch"
    case invalidDisplayConfiguration = "invalid-display-configuration"
    case invalidDisplayIdentifier = "invalid-display-identifier"
    case duplicateDisplayIdentifier = "duplicate-display-identifier"
    case tooManyDisplays = "too-many-displays"
    case tooManyPortForwards = "too-many-port-forwards"
    case invalidPortForwardIdentifier = "invalid-port-forward-identifier"
    case duplicatePortForwardIdentifier = "duplicate-port-forward-identifier"
    case invalidPortForwardPort = "invalid-port-forward-port"
    case duplicatePortForwardBinding = "duplicate-port-forward-binding"
    case portForwardNetworkModeUnsupported = "port-forward-network-mode-unsupported"
    case lanPortForwardRequiresSharedNAT = "lan-port-forward-requires-shared-nat"
    case emptyShareIdentifier = "empty-share-identifier"
    case duplicateShareIdentifier = "duplicate-share-identifier"
    case duplicateGuestMountPath = "duplicate-guest-mount-path"
    case unsafeGuestMountPath = "unsafe-guest-mount-path"
    case duplicateIntegration = "duplicate-integration"
    case integrationRequiresDisplay = "integration-requires-display"
    case invalidGuestIdentityIntent = "invalid-guest-identity-intent"
    case guestIdentityIncompatibleWithGuest = "guest-identity-incompatible-with-guest"
    case clipboardPolicyRequiresIntegration = "clipboard-policy-requires-integration"
    case invalidSandboxPolicy = "invalid-sandbox-policy"
    case sandboxPolicyIncompatibleWithGuest = "sandbox-policy-incompatible-with-guest"
    case legacyInstallerWorkload = "legacy-installer-workload"
    case invalidLifecycleMetadata = "invalid-lifecycle-metadata"
}

/// Machine-readable validation output. `field` uses stable dotted/indexed paths so clients can
/// associate an issue with a form control without parsing localized prose.
public struct DoryVMDefinitionValidationIssue: Codable, Sendable, Equatable {
    public var code: DoryVMDefinitionValidationCode
    public var field: String

    public init(code: DoryVMDefinitionValidationCode, field: String) {
        self.code = code
        self.field = field
    }
}

/// Versioned, persistence-safe VM intent shared by the app, daemon, and external API.
///
/// This definition deliberately contains no runtime capability result, selected backend,
/// passwords, tokens, host filesystem paths, or volatile process state.
public struct DoryVirtualMachineDefinition: Codable, Sendable, Equatable {
    public static let oldestSupportedSchemaVersion: UInt16 = 1
    public static let currentSchemaVersion: UInt16 = 5
    public static let currentVirtualHardwareABIVersion: UInt16 = 1

    public var schemaVersion: UInt16
    public var virtualHardwareABIVersion: UInt16
    public var identity: DoryVirtualMachineIdentity
    public var guest: DoryGuestPlatform
    public var workload: DoryVMWorkloadProfile
    public var boot: DoryVMBootConfiguration
    public var backendPreference: DoryVMBackendPreference
    public var graphics: DoryVMGraphicsPolicy
    public var resources: DoryVMResourceRequest
    public var storage: [DoryVMStorageAttachment]
    public var networkMode: DoryVMNetworkMode
    public var portForwards: [DoryVMPortForward]
    /// Ordered stable display topology. An empty array is a headless workspace.
    public var displays: [DoryVMDisplayConfiguration]
    /// Source-compatible primary-display bridge for schema-v1...v4 callers.
    public var display: DoryVMDisplayConfiguration {
        get { displays.first ?? .disabled }
        set {
            if newValue.enabled {
                if displays.isEmpty {
                    displays = [newValue]
                } else {
                    displays[0] = newValue
                }
            } else {
                displays.removeAll()
            }
        }
    }
    public var audio: DoryVMAudioConfiguration
    public var camera: DoryVMCameraConfiguration
    public var input: DoryVMInputConfiguration
    public var shares: [DoryVMShare]
    public var integrations: [DoryVMGuestIntegration]
    public var guestIdentityIntent: DoryVMGuestIdentityIntent
    public var clipboardPolicy: DoryVMClipboardPolicy
    public var sandboxPolicy: DoryVMSandboxPolicy?
    public var lifecycle: DoryVMLifecycleMetadata

    public init(
        schemaVersion: UInt16 = Self.currentSchemaVersion,
        virtualHardwareABIVersion: UInt16 = Self.currentVirtualHardwareABIVersion,
        identity: DoryVirtualMachineIdentity,
        guest: DoryGuestPlatform,
        workload: DoryVMWorkloadProfile,
        boot: DoryVMBootConfiguration,
        backendPreference: DoryVMBackendPreference = DoryVMBackendPreference(),
        graphics: DoryVMGraphicsPolicy,
        resources: DoryVMResourceRequest,
        storage: [DoryVMStorageAttachment],
        networkMode: DoryVMNetworkMode = .sharedNAT,
        portForwards: [DoryVMPortForward] = [],
        display: DoryVMDisplayConfiguration = DoryVMDisplayConfiguration(),
        displays: [DoryVMDisplayConfiguration]? = nil,
        audio: DoryVMAudioConfiguration = DoryVMAudioConfiguration(),
        camera: DoryVMCameraConfiguration = DoryVMCameraConfiguration(),
        input: DoryVMInputConfiguration = DoryVMInputConfiguration(),
        shares: [DoryVMShare] = [],
        integrations: [DoryVMGuestIntegration] = [],
        guestIdentityIntent: DoryVMGuestIdentityIntent = .unspecified,
        clipboardPolicy: DoryVMClipboardPolicy? = nil,
        sandboxPolicy: DoryVMSandboxPolicy? = nil,
        lifecycle: DoryVMLifecycleMetadata
    ) {
        self.schemaVersion = schemaVersion
        self.virtualHardwareABIVersion = virtualHardwareABIVersion
        self.identity = identity
        self.guest = guest
        self.workload = workload
        self.boot = boot
        self.backendPreference = backendPreference
        self.graphics = graphics
        self.resources = resources
        self.storage = storage
        self.networkMode = networkMode
        self.portForwards = portForwards
        self.displays = displays ?? (display.enabled ? [display] : [])
        self.audio = audio
        self.camera = camera
        self.input = input
        self.shares = shares
        self.integrations = integrations
        self.guestIdentityIntent = guestIdentityIntent
        self.clipboardPolicy = clipboardPolicy
            ?? (integrations.contains(.clipboard)
                ? .legacyDesktop(.bidirectional) : .disabled)
        self.sandboxPolicy = sandboxPolicy
        self.lifecycle = lifecycle
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case virtualHardwareABIVersion
        case identity
        case guest
        case workload
        case boot
        case bootMedia
        case backendPreference
        case graphics
        case resources
        case storage
        case networkMode
        case portForwards
        case display
        case displays
        case audio
        case camera
        case input
        case shares
        case integrations
        case guestIdentityIntent
        case clipboardPolicy
        case sandboxPolicy
        case lifecycle
    }

    private struct LegacyBootMedia: Codable {
        var role: DoryVMBootMediaRole
        var kind: DoryBootMediaKind
        var source: DoryBootMediaSource
        var artifactID: String
    }

    private struct LegacyGraphics: Codable {
        var desiredLevel: DoryGraphicsAccelerationLevel
        var allowsFallback: Bool
    }

    private struct LegacyStorage: Codable {
        var id: String
        var role: DoryVMStorageRole
        var artifactID: String
        var capacityBytes: UInt64
        var readOnly: Bool
    }

    private struct LegacyShare: Codable {
        var id: String
        var hostLocationID: String
        var guestMountPath: String
        var readOnly: Bool
    }

    private struct LegacyLifecycle: Codable {
        var revision: UInt64
        var createdAt: Date
        var updatedAt: Date
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let persistedSchema = try container.decode(UInt16.self, forKey: .schemaVersion)
        if persistedSchema == Self.oldestSupportedSchemaVersion {
            let legacyBoot = try container.decode(LegacyBootMedia.self, forKey: .bootMedia)
            let legacyGraphics = try container.decode(LegacyGraphics.self, forKey: .graphics)
            let legacyStorage = try container.decode([LegacyStorage].self, forKey: .storage)
            let legacyShares = try container.decode([LegacyShare].self, forKey: .shares)
            let legacyLifecycle = try container.decode(LegacyLifecycle.self, forKey: .lifecycle)
            let legacyWorkload = try container.decode(DoryVMWorkloadProfile.self, forKey: .workload)

            schemaVersion = Self.currentSchemaVersion
            virtualHardwareABIVersion = try container.decodeIfPresent(
                UInt16.self,
                forKey: .virtualHardwareABIVersion
            ) ?? Self.currentVirtualHardwareABIVersion
            identity = try container.decode(DoryVirtualMachineIdentity.self, forKey: .identity)
            guest = try container.decode(DoryGuestPlatform.self, forKey: .guest)
            workload = legacyWorkload == .installer ? .desktop : legacyWorkload
            let deviceID = legacyBoot.role == .system ? "system" : "installer"
            boot = DoryVMBootConfiguration(
                phase: legacyBoot.role == .system ? .normal : .install,
                devices: [DoryVMBootMediaReference(
                    id: deviceID,
                    role: legacyBoot.role,
                    kind: legacyBoot.kind,
                    source: legacyBoot.source,
                    artifact: Self.migrateLegacyReference(
                        legacyBoot.artifactID,
                        defaultNamespace: "artifact"
                    ),
                    removable: legacyBoot.role != .system
                )],
                order: [deviceID]
            )
            backendPreference = try container.decode(
                DoryVMBackendPreference.self,
                forKey: .backendPreference
            )
            var levels = [legacyGraphics.desiredLevel]
            if legacyGraphics.allowsFallback,
               legacyGraphics.desiredLevel != .software,
               legacyGraphics.desiredLevel != .none {
                levels.append(.software)
            }
            graphics = DoryVMGraphicsPolicy(acceptableLevels: levels)
            resources = try container.decode(DoryVMResourceRequest.self, forKey: .resources)
            storage = legacyStorage.map { attachment in
                DoryVMStorageAttachment(
                    id: attachment.id,
                    role: attachment.role,
                    artifact: Self.migrateLegacyReference(
                        attachment.artifactID,
                        defaultNamespace: "artifact"
                    ),
                    capacityBytes: attachment.capacityBytes,
                    readOnly: attachment.readOnly
                )
            }
            networkMode = try container.decode(DoryVMNetworkMode.self, forKey: .networkMode)
            portForwards = []
            let legacyDisplay = try container.decode(
                DoryVMDisplayConfiguration.self,
                forKey: .display
            )
            displays = legacyDisplay.enabled ? [legacyDisplay] : []
            audio = try container.decode(DoryVMAudioConfiguration.self, forKey: .audio)
            camera = try container.decodeIfPresent(
                DoryVMCameraConfiguration.self,
                forKey: .camera
            ) ?? DoryVMCameraConfiguration()
            input = try container.decode(DoryVMInputConfiguration.self, forKey: .input)
            shares = legacyShares.map { share in
                DoryVMShare(
                    id: share.id,
                    hostLocation: Self.migrateLegacyReference(
                        share.hostLocationID,
                        defaultNamespace: "host-location"
                    ),
                    guestMountPath: share.guestMountPath,
                    readOnly: share.readOnly
                )
            }
            integrations = try container.decode(
                [DoryVMGuestIntegration].self,
                forKey: .integrations
            )
            guestIdentityIntent = .unspecified
            clipboardPolicy = integrations.contains(.clipboard)
                ? .legacyDesktop(.bidirectional) : .disabled
            sandboxPolicy = nil
            lifecycle = DoryVMLifecycleMetadata(
                revision: legacyLifecycle.revision,
                createdAt: legacyLifecycle.createdAt,
                updatedAt: legacyLifecycle.updatedAt
            )
            return
        }

        guard (2...Self.currentSchemaVersion).contains(persistedSchema) else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported VM definition schema \(persistedSchema)."
            )
        }
        // Schema 2 is structurally migrated by the attachment decoder above. Its missing storage
        // source becomes `.userProvided`. Sandbox policy is an optional schema-3 extension and
        // explicit port forwards are an additive schema-4 extension. Schema 5 replaces the
        // singular display field with an ordered, stable topology.
        schemaVersion = Self.currentSchemaVersion
        virtualHardwareABIVersion = try container.decode(
            UInt16.self,
            forKey: .virtualHardwareABIVersion
        )
        identity = try container.decode(DoryVirtualMachineIdentity.self, forKey: .identity)
        guest = try container.decode(DoryGuestPlatform.self, forKey: .guest)
        workload = try container.decode(DoryVMWorkloadProfile.self, forKey: .workload)
        boot = try container.decode(DoryVMBootConfiguration.self, forKey: .boot)
        backendPreference = try container.decode(DoryVMBackendPreference.self, forKey: .backendPreference)
        graphics = try container.decode(DoryVMGraphicsPolicy.self, forKey: .graphics)
        resources = try container.decode(DoryVMResourceRequest.self, forKey: .resources)
        storage = try container.decode([DoryVMStorageAttachment].self, forKey: .storage)
        networkMode = try container.decode(DoryVMNetworkMode.self, forKey: .networkMode)
        portForwards = try container.decodeIfPresent(
            [DoryVMPortForward].self,
            forKey: .portForwards
        ) ?? []
        if persistedSchema >= 5 {
            displays = try container.decode(
                [DoryVMDisplayConfiguration].self,
                forKey: .displays
            )
        } else {
            let legacyDisplay = try container.decode(
                DoryVMDisplayConfiguration.self,
                forKey: .display
            )
            displays = legacyDisplay.enabled ? [legacyDisplay] : []
        }
        audio = try container.decode(DoryVMAudioConfiguration.self, forKey: .audio)
        camera = try container.decodeIfPresent(
            DoryVMCameraConfiguration.self,
            forKey: .camera
        ) ?? DoryVMCameraConfiguration()
        input = try container.decode(DoryVMInputConfiguration.self, forKey: .input)
        shares = try container.decode([DoryVMShare].self, forKey: .shares)
        integrations = try container.decode([DoryVMGuestIntegration].self, forKey: .integrations)
        guestIdentityIntent = try container.decodeIfPresent(
            DoryVMGuestIdentityIntent.self,
            forKey: .guestIdentityIntent
        ) ?? .unspecified
        clipboardPolicy = try container.decodeIfPresent(
            DoryVMClipboardPolicy.self,
            forKey: .clipboardPolicy
        ) ?? (integrations.contains(.clipboard)
            ? .legacyDesktop(.bidirectional) : .disabled)
        sandboxPolicy = try container.decodeIfPresent(
            DoryVMSandboxPolicy.self,
            forKey: .sandboxPolicy
        )
        lifecycle = try container.decode(DoryVMLifecycleMetadata.self, forKey: .lifecycle)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(virtualHardwareABIVersion, forKey: .virtualHardwareABIVersion)
        try container.encode(identity, forKey: .identity)
        try container.encode(guest, forKey: .guest)
        try container.encode(workload, forKey: .workload)
        try container.encode(boot, forKey: .boot)
        try container.encode(backendPreference, forKey: .backendPreference)
        try container.encode(graphics, forKey: .graphics)
        try container.encode(resources, forKey: .resources)
        try container.encode(storage, forKey: .storage)
        try container.encode(networkMode, forKey: .networkMode)
        try container.encode(portForwards, forKey: .portForwards)
        try container.encode(displays, forKey: .displays)
        try container.encode(audio, forKey: .audio)
        if camera.enabled {
            try container.encode(camera, forKey: .camera)
        }
        try container.encode(input, forKey: .input)
        try container.encode(shares, forKey: .shares)
        try container.encode(integrations, forKey: .integrations)
        try container.encode(guestIdentityIntent, forKey: .guestIdentityIntent)
        try container.encode(clipboardPolicy, forKey: .clipboardPolicy)
        try container.encodeIfPresent(sandboxPolicy, forKey: .sandboxPolicy)
        try container.encode(lifecycle, forKey: .lifecycle)
    }

    private static func migrateLegacyReference(
        _ value: String,
        defaultNamespace: String
    ) -> DoryVMResolverReference {
        let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2 {
            let candidate = DoryVMResolverReference(
                namespace: String(parts[0]).lowercased(),
                identifier: String(parts[1])
            )
            if isSafeResolverReference(candidate) {
                return candidate
            }
        }
        return DoryVMResolverReference(namespace: defaultNamespace, identifier: value)
    }

    /// Returns deterministic issues in field order. Backend availability is intentionally absent;
    /// pass the resulting intent through capability negotiation before launch.
    public func validate() -> [DoryVMDefinitionValidationIssue] {
        var issues: [DoryVMDefinitionValidationIssue] = []

        if schemaVersion != Self.currentSchemaVersion {
            issues.append(issue(.unsupportedSchemaVersion, "schemaVersion"))
        }
        if virtualHardwareABIVersion != Self.currentVirtualHardwareABIVersion {
            issues.append(issue(
                .unsupportedVirtualHardwareABIVersion,
                "virtualHardwareABIVersion"
            ))
        }
        if !Self.hasContent(identity.id) {
            issues.append(issue(.emptyIdentifier, "identity.id"))
        } else if !Self.isSafeMachineIdentifier(identity.id) {
            issues.append(issue(.invalidIdentifier, "identity.id"))
        }
        if !Self.hasContent(identity.name) {
            issues.append(issue(.emptyName, "identity.name"))
        }

        validateBootMedia(into: &issues)
        validateBackendPreference(into: &issues)
        validateGraphics(into: &issues)
        validateResources(into: &issues)
        validateStorage(into: &issues)
        validatePortForwards(into: &issues)
        validateDisplay(into: &issues)
        validateShares(into: &issues)
        validateIntegrations(into: &issues)
        validateGuestIdentityIntent(into: &issues)
        validateClipboardPolicy(into: &issues)
        validateSandboxPolicy(into: &issues)
        validateLifecycle(into: &issues)
        return issues
    }

    public var isValid: Bool {
        validate().isEmpty
    }

    private func validateBootMedia(into issues: inout [DoryVMDefinitionValidationIssue]) {
        if workload == .installer {
            issues.append(issue(.legacyInstallerWorkload, "workload"))
        }

        var deviceIDs: Set<String> = []
        for (index, device) in boot.devices.enumerated() {
            let field = "boot.devices[\(index)]"
            if !Self.isSafeMachineIdentifier(device.id) {
                issues.append(issue(.invalidIdentifier, "\(field).id"))
            } else if !deviceIDs.insert(device.id).inserted {
                issues.append(issue(.duplicateBootDeviceIdentifier, "\(field).id"))
            }
            if !Self.isSafeResolverReference(device.artifact) {
                issues.append(issue(.invalidResolverReference, "\(field).artifact"))
            }

            let roleMatchesKind: Bool
            switch device.kind {
            case .linuxKernel, .virtualDisk, .installedLinuxBootBundle:
                roleMatchesKind = device.role == .system
            case .installerISO, .macOSRestoreImage:
                roleMatchesKind = device.role == .installer || device.role == .recovery
            }
            if !roleMatchesKind {
                issues.append(issue(.bootMediaRoleMismatch, "\(field).role"))
            }

            let shouldBeRemovable = device.role != .system
            if device.removable != shouldBeRemovable {
                issues.append(issue(.invalidBootAttachment, "\(field).removable"))
            }
            if !Self.bootMediaIsCompatible(device.kind, with: guest.family) {
                issues.append(issue(.bootMediaIncompatibleWithGuest, "\(field).kind"))
            }
            if (guest.family == .windows || guest.family == .macOS),
               device.source == .bundledByDory {
                issues.append(issue(.guestMediaCannotBeBundled, "\(field).source"))
            }
        }

        if boot.devices.filter({ $0.role == .system }).count > 1 {
            issues.append(issue(.multipleSystemBootDevices, "boot.devices"))
        }

        let orderIsPermutation = !boot.order.isEmpty
            && boot.order.count == boot.devices.count
            && Set(boot.order).count == boot.order.count
            && Set(boot.order) == Set(boot.devices.map(\.id))
        if !orderIsPermutation {
            issues.append(issue(.invalidBootOrder, "boot.order"))
        }

        let primary = orderedBootDevices().first
        let primaryIsValid: Bool
        switch boot.phase {
        case .normal:
            primaryIsValid = primary?.role == .system
        case .install, .live:
            primaryIsValid = primary?.role == .installer
        case .recovery:
            primaryIsValid = primary?.role == .recovery
        }
        if !primaryIsValid {
            issues.append(issue(.invalidBootPhase, "boot.phase"))
        }
    }

    private func validateBackendPreference(into issues: inout [DoryVMDefinitionValidationIssue]) {
        let isWellFormed = switch backendPreference.mode {
        case .automatic:
            backendPreference.backend == nil
        case .preferred, .required:
            backendPreference.backend != nil
        }
        if !isWellFormed {
            issues.append(issue(.backendPreferenceMalformed, "backendPreference"))
        }
    }

    private func validateGraphics(into issues: inout [DoryVMDefinitionValidationIssue]) {
        if graphics.acceptableLevels.isEmpty {
            issues.append(issue(.emptyGraphicsPolicy, "graphics.acceptableLevels"))
            return
        }
        var seen: Set<String> = []
        for (index, level) in graphics.acceptableLevels.enumerated()
        where !seen.insert(level.rawValue).inserted {
            issues.append(issue(.duplicateGraphicsLevel, "graphics.acceptableLevels[\(index)]"))
        }
    }

    private func validateResources(into issues: inout [DoryVMDefinitionValidationIssue]) {
        if resources.virtualCPUCount == 0 {
            issues.append(issue(.nonPositiveResource, "resources.virtualCPUCount"))
        }
        if resources.memoryBytes == 0 {
            issues.append(issue(.nonPositiveResource, "resources.memoryBytes"))
        }
        if resources.diskBytes == 0 {
            issues.append(issue(.nonPositiveResource, "resources.diskBytes"))
        }
    }

    private func validateStorage(into issues: inout [DoryVMDefinitionValidationIssue]) {
        var attachmentIDs: Set<String> = []
        var artifactAccess: [DoryVMResolverReference: Bool] = [:]
        for (index, attachment) in storage.enumerated() {
            let field = "storage[\(index)]"
            if !Self.hasContent(attachment.id) {
                issues.append(issue(.emptyAttachmentIdentifier, "\(field).id"))
            } else if !attachmentIDs.insert(attachment.id).inserted {
                issues.append(issue(.duplicateAttachmentIdentifier, "\(field).id"))
            }
            if !Self.isSafeResolverReference(attachment.artifact) {
                issues.append(issue(.invalidResolverReference, "\(field).artifact"))
            } else if let allPreviousReadOnly = artifactAccess[attachment.artifact] {
                if !allPreviousReadOnly || !attachment.readOnly {
                    issues.append(issue(
                        .duplicateWritableStorageArtifactIdentity,
                        "\(field).artifact"
                    ))
                }
                artifactAccess[attachment.artifact] = allPreviousReadOnly && attachment.readOnly
            } else {
                artifactAccess[attachment.artifact] = attachment.readOnly
            }
            if attachment.capacityBytes == 0 {
                issues.append(issue(.nonPositiveAttachmentCapacity, "\(field).capacityBytes"))
            }
        }

        let systemDisks = storage.enumerated().filter { $0.element.role == .system }
        if systemDisks.isEmpty, boot.phase != .live {
            issues.append(issue(.missingSystemDisk, "storage"))
        } else if systemDisks.count > 1 {
            issues.append(issue(.multipleSystemDisks, "storage"))
        } else if let (index, systemDisk) = systemDisks.first {
            if systemDisk.readOnly {
                issues.append(issue(.readOnlySystemDisk, "storage[\(index)].readOnly"))
            }
            if systemDisk.capacityBytes != resources.diskBytes {
                issues.append(issue(.systemDiskCapacityMismatch, "storage[\(index)].capacityBytes"))
            }
            if let bootDisk = orderedBootDevices().first(where: {
                $0.role == .system && $0.kind == .virtualDisk
            }), bootDisk.artifact != systemDisk.artifact {
                issues.append(issue(.bootDiskArtifactMismatch, "boot.devices"))
            }
        }
    }

    private func validatePortForwards(into issues: inout [DoryVMDefinitionValidationIssue]) {
        if portForwards.count > DoryVMPortForward.maximumCount {
            issues.append(issue(.tooManyPortForwards, "portForwards"))
        }
        if !portForwards.isEmpty,
           networkMode != .sharedNAT,
           networkMode != .isolated {
            issues.append(issue(.portForwardNetworkModeUnsupported, "portForwards"))
        }

        var identifiers: Set<String> = []
        var hostBindings: Set<String> = []
        for (index, forward) in portForwards.enumerated() {
            let field = "portForwards[\(index)]"
            if !Self.isSafeMachineIdentifier(forward.id) {
                issues.append(issue(.invalidPortForwardIdentifier, "\(field).id"))
            } else if !identifiers.insert(forward.id).inserted {
                issues.append(issue(.duplicatePortForwardIdentifier, "\(field).id"))
            }
            if forward.hostPort < 1_024 {
                issues.append(issue(.invalidPortForwardPort, "\(field).hostPort"))
            }
            if forward.guestPort == 0 {
                issues.append(issue(.invalidPortForwardPort, "\(field).guestPort"))
            }
            let binding = "\(forward.transport.rawValue):\(forward.hostPort)"
            if !hostBindings.insert(binding).inserted {
                issues.append(issue(.duplicatePortForwardBinding, "\(field).hostPort"))
            }
            if forward.exposure == .lan, networkMode != .sharedNAT {
                issues.append(issue(.lanPortForwardRequiresSharedNAT, "\(field).exposure"))
            }
        }
    }

    private func validateDisplay(into issues: inout [DoryVMDefinitionValidationIssue]) {
        if displays.count > DoryVMDisplayConfiguration.maximumCount {
            issues.append(issue(.tooManyDisplays, "displays"))
        }
        var identifiers = Set<String>()
        for (index, display) in displays.enumerated() {
            let field = "displays[\(index)]"
            if !DoryVMDisplayConfiguration.isValidIdentifier(display.id) {
                issues.append(issue(.invalidDisplayIdentifier, "\(field).id"))
            } else if !identifiers.insert(display.id).inserted {
                issues.append(issue(.duplicateDisplayIdentifier, "\(field).id"))
            }
            let dimensionsArePositive = display.widthPixels > 0
                && display.widthPixels <= DoryVMDisplayConfiguration.maximumDimensionPixels
                && display.heightPixels > 0
                && display.heightPixels <= DoryVMDisplayConfiguration.maximumDimensionPixels
                && display.pixelsPerInch > 0
                && (1...4).contains(display.backingScaleFactor)
                && (1...2).contains(display.guestUIScaleFactor)
            if !display.enabled || !dimensionsArePositive {
                issues.append(issue(.invalidDisplayConfiguration, field))
            }
        }
    }

    private func validateShares(into issues: inout [DoryVMDefinitionValidationIssue]) {
        var shareIDs: Set<String> = []
        var guestMountPaths: Set<String> = []
        for (index, share) in shares.enumerated() {
            let field = "shares[\(index)]"
            if !Self.hasContent(share.id) {
                issues.append(issue(.emptyShareIdentifier, "\(field).id"))
            } else if !shareIDs.insert(share.id).inserted {
                issues.append(issue(.duplicateShareIdentifier, "\(field).id"))
            }
            if !Self.isSafeResolverReference(share.hostLocation) {
                issues.append(issue(.invalidResolverReference, "\(field).hostLocation"))
            }
            if let canonicalPath = Self.canonicalGuestMountPath(
                share.guestMountPath,
                family: guest.family
            ) {
                if !guestMountPaths.insert(canonicalPath).inserted {
                    issues.append(issue(.duplicateGuestMountPath, "\(field).guestMountPath"))
                }
            } else {
                issues.append(issue(.unsafeGuestMountPath, "\(field).guestMountPath"))
            }
        }
    }

    private func validateIntegrations(into issues: inout [DoryVMDefinitionValidationIssue]) {
        var seen: Set<String> = []
        for (index, integration) in integrations.enumerated()
        where !seen.insert(integration.rawValue).inserted {
            issues.append(issue(.duplicateIntegration, "integrations[\(index)]"))
        }
        if !display.enabled, integrations.contains(.dynamicDisplay) {
            issues.append(issue(.integrationRequiresDisplay, "integrations"))
        }
        if !display.enabled, camera.enabled {
            issues.append(issue(.integrationRequiresDisplay, "camera.enabled"))
        }
    }

    private func validateGuestIdentityIntent(
        into issues: inout [DoryVMDefinitionValidationIssue]
    ) {
        if !guestIdentityIntent.isEmpty, guest.family != .linux {
            issues.append(issue(
                .guestIdentityIncompatibleWithGuest,
                "guestIdentityIntent"
            ))
        }
        if let account = guestIdentityIntent.account, !account.isValidForPersistence {
            issues.append(issue(.invalidGuestIdentityIntent, "guestIdentityIntent.account"))
        }
        if let username = guestIdentityIntent.account?.username,
           !DoryVMGuestAccountIntent.isValidUsername(username) {
            issues.append(issue(
                .invalidGuestIdentityIntent,
                "guestIdentityIntent.account.username"
            ))
        }
        if let numericUserID = guestIdentityIntent.account?.numericUserID,
           !DoryVMGuestAccountIntent.isValidNumericUserID(numericUserID) {
            issues.append(issue(
                .invalidGuestIdentityIntent,
                "guestIdentityIntent.account.numericUserID"
            ))
        }
        if let desktop = guestIdentityIntent.desktop {
            if !desktop.isValidForPersistence {
                issues.append(issue(.invalidGuestIdentityIntent, "guestIdentityIntent.desktop"))
            }
            if let identifier = desktop.distributionIdentifier,
               !DoryVMDesktopIdentityIntent.isValidDistributionIdentifier(identifier) {
                issues.append(issue(
                    .invalidGuestIdentityIntent,
                    "guestIdentityIntent.desktop.distributionIdentifier"
                ))
            }
            for (field, value) in [
                ("displayName", desktop.displayName),
                ("version", desktop.version),
                ("desktopEnvironment", desktop.desktopEnvironment),
            ] where value.map(DoryVMDesktopIdentityIntent.isValidLabel) == false {
                issues.append(issue(
                    .invalidGuestIdentityIntent,
                    "guestIdentityIntent.desktop.\(field)"
                ))
            }
            if !desktop.isEmpty,
               (workload != .desktop || !display.enabled) {
                issues.append(issue(
                    .guestIdentityIncompatibleWithGuest,
                    "guestIdentityIntent.desktop"
                ))
            }
        }
    }

    private func validateClipboardPolicy(
        into issues: inout [DoryVMDefinitionValidationIssue]
    ) {
        if clipboardPolicy.isEnabled, !integrations.contains(.clipboard) {
            issues.append(issue(
                .clipboardPolicyRequiresIntegration,
                "clipboardPolicy"
            ))
        }
    }

    private func validateSandboxPolicy(
        into issues: inout [DoryVMDefinitionValidationIssue]
    ) {
        guard let sandboxPolicy else { return }
        if !sandboxPolicy.isValidForPersistence {
            issues.append(issue(.invalidSandboxPolicy, "sandboxPolicy"))
        }
        if guest.family != .linux || display.enabled {
            issues.append(issue(
                .sandboxPolicyIncompatibleWithGuest,
                "sandboxPolicy"
            ))
        }
    }

    private func validateLifecycle(into issues: inout [DoryVMDefinitionValidationIssue]) {
        if lifecycle.revision == 0
            || lifecycle.createdAtUnixMilliseconds <= 0
            || lifecycle.updatedAtUnixMilliseconds < lifecycle.createdAtUnixMilliseconds {
            issues.append(issue(.invalidLifecycleMetadata, "lifecycle"))
        }
    }

    private func issue(
        _ code: DoryVMDefinitionValidationCode,
        _ field: String
    ) -> DoryVMDefinitionValidationIssue {
        DoryVMDefinitionValidationIssue(code: code, field: field)
    }

    /// Resolve boot devices through the persisted order so validation never depends on array layout.
    private func orderedBootDevices() -> [DoryVMBootMediaReference] {
        boot.order.compactMap { deviceID in
            boot.devices.first { $0.id == deviceID }
        }
    }

    private static func hasContent(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func isSafeResolverReference(_ reference: DoryVMResolverReference) -> Bool {
        reference.isValidForPersistence
    }

    private static func bootMediaIsCompatible(
        _ kind: DoryBootMediaKind,
        with family: DoryGuestFamily
    ) -> Bool {
        switch family {
        case .linux:
            kind == .linuxKernel || kind == .installerISO || kind == .virtualDisk
                || kind == .installedLinuxBootBundle
        case .windows:
            kind == .installerISO || kind == .virtualDisk
        case .macOS:
            kind == .macOSRestoreImage || kind == .virtualDisk
        }
    }

    private static func isSafeMachineIdentifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...63).contains(bytes.count), isASCIIAlphaNumeric(bytes[0]) else {
            return false
        }
        return bytes.dropFirst().allSatisfy { byte in
            isASCIIAlphaNumeric(byte) || byte == 95 || byte == 46 || byte == 45
        }
    }

    private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        (byte >= 48 && byte <= 57)
            || (byte >= 65 && byte <= 90)
            || (byte >= 97 && byte <= 122)
    }

    private static func canonicalGuestMountPath(
        _ path: String,
        family: DoryGuestFamily
    ) -> String? {
        guard !path.isEmpty, !path.unicodeScalars.contains(where: { $0.value == 0 }) else {
            return nil
        }
        switch family {
        case .linux, .macOS:
            guard path.hasPrefix("/"), !path.hasPrefix("//"), path != "/", !path.contains("\\") else {
                return nil
            }
            let components = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
            guard !components.isEmpty, components.allSatisfy({ component in
                !component.isEmpty && component != "." && component != ".."
            }) else {
                return nil
            }
            return path
        case .windows:
            let bytes = Array(path.utf8)
            guard bytes.count >= 4,
                  (bytes[0] >= 65 && bytes[0] <= 90) || (bytes[0] >= 97 && bytes[0] <= 122),
                  bytes[1] == 58,
                  bytes[2] == 92,
                  !path.contains("/") else {
                return nil
            }
            let components = path.dropFirst(3).split(
                separator: "\\",
                omittingEmptySubsequences: false
            )
            let forbidden = "<>:|?*\""
            guard !components.isEmpty, components.allSatisfy({ component in
                isSafeWindowsPathComponent(component, forbidden: forbidden)
            }) else {
                return nil
            }
            return path.lowercased()
        }
    }

    private static func isSafeWindowsPathComponent(
        _ component: Substring,
        forbidden: String
    ) -> Bool {
        guard !component.isEmpty,
              component != ".",
              component != "..",
              component.last != ".",
              component.last != " ",
              !component.contains(where: forbidden.contains),
              !component.unicodeScalars.contains(where: { scalar in
                  scalar.value < 32 || scalar.value == 127
              }) else {
            return false
        }
        let rawBaseName = component.split(separator: ".", maxSplits: 1).first ?? ""
        let baseName = String(rawBaseName)
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
            .uppercased()
        if ["CON", "PRN", "AUX", "NUL"].contains(baseName) {
            return false
        }
        if baseName.count == 4,
           (baseName.hasPrefix("COM") || baseName.hasPrefix("LPT")),
           let suffix = baseName.last,
           suffix >= "1" && suffix <= "9" {
            return false
        }
        return true
    }
}
