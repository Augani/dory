import DoryHostCamera
import DoryMacGuestIntegrationWire
import DoryVZMacCameraBridge
import CryptoKit
import Darwin
import Foundation
import Virtualization

public enum DoryVZMacConfigurationError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidMACAddress(String)
    case missingHostOnlyNetworkAttachment
    case cameraSocketUnavailable
    case metalProbeSocketUnavailable
    case guestIntegrationSocketUnavailable
    case integrationDisabled(String)
    case invalidClipboardPolicy
    case invalidCameraSelection
    case machineBundleChangedBeforeRuntimeAdmission

    public var description: String {
        switch self {
        case .invalidMACAddress(let address):
            "VZMac network address is invalid: \(address)"
        case .missingHostOnlyNetworkAttachment:
            "VZMac host-only networking requires its gvproxy-backed attachment"
        case .cameraSocketUnavailable:
            "VZMac did not expose the configured VirtIO socket device"
        case .metalProbeSocketUnavailable:
            "VZMac did not expose the VirtIO socket device required for Metal probe collection"
        case .guestIntegrationSocketUnavailable:
            "VZMac did not expose the VirtIO socket device required for Guest Tools integration"
        case .integrationDisabled(let name):
            "VZMac \(name) integration is disabled by the effective device policy"
        case .invalidClipboardPolicy:
            "VZMac clipboard transport and directional grants disagree"
        case .invalidCameraSelection:
            "VZMac camera selection is invalid or the camera bridge is disabled"
        case .machineBundleChangedBeforeRuntimeAdmission:
            "VZMac machine bundle changed before runtime admission; reopen its current state"
        }
    }
}

public enum DoryVZMacNetworkPolicy: String, Codable, Sendable, Equatable {
    case disconnected
    case sharedNAT = "shared-nat"
    case isolated = "host-only"
}

public struct DoryVZMacAudioPolicy: Codable, Sendable, Equatable {
    public var inputEnabled: Bool
    public var outputEnabled: Bool

    public init(inputEnabled: Bool = true, outputEnabled: Bool = true) {
        self.inputEnabled = inputEnabled
        self.outputEnabled = outputEnabled
    }
}

public struct DoryVZMacDevicePolicy: Codable, Sendable, Equatable {
    public var network: DoryVZMacNetworkPolicy
    public var audio: DoryVZMacAudioPolicy
    public var clipboardEnabled: Bool
    public var spiceClipboardEnabled: Bool
    public var clipboardTextReadEnabled: Bool
    public var clipboardTextWriteEnabled: Bool
    public var clipboardImageReadEnabled: Bool
    public var clipboardImageWriteEnabled: Bool
    public var directorySharingEnabled: Bool
    public var cameraBridgeEnabled: Bool

    private enum CodingKeys: String, CodingKey {
        case network
        case audio
        case clipboardEnabled
        case spiceClipboardEnabled
        case clipboardTextReadEnabled
        case clipboardTextWriteEnabled
        case clipboardImageReadEnabled
        case clipboardImageWriteEnabled
        case directorySharingEnabled
        case cameraBridgeEnabled
    }

    public init(
        network: DoryVZMacNetworkPolicy = .sharedNAT,
        audio: DoryVZMacAudioPolicy = DoryVZMacAudioPolicy(),
        clipboardEnabled: Bool = true,
        spiceClipboardEnabled: Bool? = nil,
        clipboardTextReadEnabled: Bool? = nil,
        clipboardTextWriteEnabled: Bool? = nil,
        clipboardImageReadEnabled: Bool? = nil,
        clipboardImageWriteEnabled: Bool? = nil,
        directorySharingEnabled: Bool = true,
        cameraBridgeEnabled: Bool = true
    ) {
        self.network = network
        self.audio = audio
        self.clipboardEnabled = clipboardEnabled
        self.spiceClipboardEnabled = spiceClipboardEnabled ?? clipboardEnabled
        self.clipboardTextReadEnabled = clipboardTextReadEnabled ?? clipboardEnabled
        self.clipboardTextWriteEnabled = clipboardTextWriteEnabled ?? clipboardEnabled
        self.clipboardImageReadEnabled = clipboardImageReadEnabled ?? self.spiceClipboardEnabled
        self.clipboardImageWriteEnabled = clipboardImageWriteEnabled ?? self.spiceClipboardEnabled
        self.directorySharingEnabled = directorySharingEnabled
        self.cameraBridgeEnabled = cameraBridgeEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        network = try container.decode(DoryVZMacNetworkPolicy.self, forKey: .network)
        audio = try container.decode(DoryVZMacAudioPolicy.self, forKey: .audio)
        clipboardEnabled = try container.decode(Bool.self, forKey: .clipboardEnabled)
        spiceClipboardEnabled = try container.decodeIfPresent(
            Bool.self, forKey: .spiceClipboardEnabled
        ) ?? clipboardEnabled
        clipboardTextReadEnabled = try container.decodeIfPresent(
            Bool.self, forKey: .clipboardTextReadEnabled
        ) ?? clipboardEnabled
        clipboardTextWriteEnabled = try container.decodeIfPresent(
            Bool.self, forKey: .clipboardTextWriteEnabled
        ) ?? clipboardEnabled
        clipboardImageReadEnabled = try container.decodeIfPresent(
            Bool.self, forKey: .clipboardImageReadEnabled
        ) ?? spiceClipboardEnabled
        clipboardImageWriteEnabled = try container.decodeIfPresent(
            Bool.self, forKey: .clipboardImageWriteEnabled
        ) ?? spiceClipboardEnabled
        directorySharingEnabled = try container.decode(Bool.self, forKey: .directorySharingEnabled)
        cameraBridgeEnabled = try container.decodeIfPresent(Bool.self, forKey: .cameraBridgeEnabled) ?? true
    }

    public static let legacyDefault = DoryVZMacDevicePolicy()
}

public struct DoryVZMacEffectiveSharedDirectory: Sendable, Equatable, Hashable {
    /// VZ's guest-visible multiple-directory-share name. Host paths deliberately do not appear
    /// in the report because callers may persist or expose it as ordinary diagnostics.
    public var name: String
    public var readOnly: Bool

    public init(name: String, readOnly: Bool) {
        self.name = name
        self.readOnly = readOnly
    }
}

public struct DoryVZMacEffectiveDeviceReport: Sendable, Equatable {
    public var networkDeviceCount: Int
    public var usesNATNetworkAttachment: Bool
    public var audioDeviceCount: Int
    public var audioInputStreamCount: Int
    public var audioOutputStreamCount: Int
    public var directorySharingDeviceCount: Int
    public var sharedDirectoryCount: Int
    /// Exact guest-visible share names and access modes, sorted by name.
    public var sharedDirectories: [DoryVZMacEffectiveSharedDirectory]
    public var consoleDeviceCount: Int
    public var spiceClipboardEnabled: Bool

    public var hasNetwork: Bool { networkDeviceCount > 0 }
    public var hasAudioInput: Bool { audioInputStreamCount > 0 }
    public var hasAudioOutput: Bool { audioOutputStreamCount > 0 }
    public var hasDirectorySharing: Bool { directorySharingDeviceCount > 0 }
    public var hasClipboard: Bool { spiceClipboardEnabled }
}

public enum DoryVZMacConfigurationBuilder {
    public static func fingerprint(
        sharedDirectories: [DoryVZMacSharedDirectory] = [],
        usbMassStorage: DoryVZMacUSBMassStorage? = nil,
        devicePolicy: DoryVZMacDevicePolicy = .legacyDefault,
        cameraDeviceUniqueID: String? = nil,
        displays: [DoryVZMacDisplay]? = nil,
        dataDisks: [DoryVZMacDataDisk] = []
    ) throws -> String {
        struct SharedDirectory: Codable {
            let name: String
            let path: String
            let readOnly: Bool
        }
        struct LegacyDescriptor: Codable {
            let schema: String
            let display: String
            let network: String
            let audio: String
            let input: String
            let entropy: String
            let cameraSocketPort: UInt32
            let clipboard: String
            let xhciEnabled: Bool
            let sharedDirectories: [SharedDirectory]
        }
        struct Descriptor: Codable {
            let schema: String
            let display: String
            let network: String
            let audio: String
            let input: String
            let entropy: String
            let cameraSocketPort: UInt32
            let clipboard: String
            let xhciEnabled: Bool
            let sharedDirectories: [SharedDirectory]
            let usbMassStorage: USBMassStorage
        }
        struct PolicyDescriptor: Codable {
            let schema: String
            let display: String
            let network: String
            let audioInput: Bool
            let audioOutput: Bool
            let input: String
            let entropy: String
            let cameraSocketPort: UInt32?
            let clipboard: Bool
            let xhciEnabled: Bool
            let directorySharing: Bool
            let sharedDirectories: [SharedDirectory]
            let usbMassStorage: USBMassStorage?
        }
        struct USBMassStorage: Codable {
            let path: String
            let readOnly: Bool
            let byteCount: UInt64
        }
        struct DataDisk: Codable {
            let fileName: String
            let byteCount: UInt64
        }
        struct DataDiskDescriptor: Codable {
            let schema: String
            let display: String
            let network: String
            let audio: String
            let input: String
            let entropy: String
            let cameraSocketPort: UInt32
            let clipboard: String
            let xhciEnabled: Bool
            let sharedDirectories: [SharedDirectory]
            let usbMassStorage: USBMassStorage?
            let dataDisks: [DataDisk]
        }
        struct PolicyDataDiskDescriptor: Codable {
            let schema: String
            let display: String
            let network: String
            let audioInput: Bool
            let audioOutput: Bool
            let input: String
            let entropy: String
            let cameraSocketPort: UInt32?
            let clipboard: Bool
            let xhciEnabled: Bool
            let directorySharing: Bool
            let sharedDirectories: [SharedDirectory]
            let usbMassStorage: USBMassStorage?
            let dataDisks: [DataDisk]
        }
        try validatePolicy(devicePolicy, sharedDirectories: sharedDirectories)
        if let cameraDeviceUniqueID,
            !devicePolicy.cameraBridgeEnabled || cameraDeviceUniqueID.isEmpty
                || cameraDeviceUniqueID.utf8.count > 512
                || !cameraDeviceUniqueID.utf8.allSatisfy({ $0 >= 0x20 && $0 != 0x7f }) {
            throw DoryVZMacConfigurationError.invalidCameraSelection
        }
        let mappedShares = sharedDirectories
            .sorted { $0.name < $1.name }
            .map {
                SharedDirectory(name: $0.name, path: $0.url.path, readOnly: $0.readOnly)
            }
        let xhciEnabled = ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let effectiveDisplays = displays ?? [DoryVZMacResourcePlan.defaultDisplay]
        let displayString = effectiveDisplays
            .map { "\($0.widthInPixels)x\($0.heightInPixels)@\($0.pixelsPerInch)ppi" }
            .joined(separator: "+")
            + "-auto-resize"
        let encoded: Data
        let mappedUSBMassStorage = usbMassStorage.map {
            USBMassStorage(path: $0.url.path, readOnly: $0.readOnly, byteCount: $0.byteCount)
        }
        let mappedDataDisks = dataDisks.map {
            DataDisk(fileName: $0.fileName, byteCount: $0.byteCount)
        }
        if !mappedDataDisks.isEmpty, devicePolicy != .legacyDefault {
            encoded = try encoder.encode(PolicyDataDiskDescriptor(
                schema: "dory.vzmac-configuration@5",
                display: displayString,
                network: devicePolicy.network.rawValue,
                audioInput: devicePolicy.audio.inputEnabled,
                audioOutput: devicePolicy.audio.outputEnabled,
                input: "mac-keyboard-trackpad",
                entropy: "virtio",
                cameraSocketPort: devicePolicy.cameraBridgeEnabled ? 1_030 : nil,
                clipboard: devicePolicy.clipboardEnabled,
                xhciEnabled: xhciEnabled,
                directorySharing: devicePolicy.directorySharingEnabled,
                sharedDirectories: mappedShares,
                usbMassStorage: mappedUSBMassStorage,
                dataDisks: mappedDataDisks
            ))
        } else if !mappedDataDisks.isEmpty {
            encoded = try encoder.encode(DataDiskDescriptor(
                schema: "dory.vzmac-configuration@5",
                display: displayString,
                network: "virtio-nat",
                audio: "virtio-host-input-output",
                input: "mac-keyboard-trackpad",
                entropy: "virtio",
                cameraSocketPort: 1_030,
                clipboard: "spice-bidirectional",
                xhciEnabled: xhciEnabled,
                sharedDirectories: mappedShares,
                usbMassStorage: mappedUSBMassStorage,
                dataDisks: mappedDataDisks
            ))
        } else if devicePolicy != .legacyDefault {
            encoded = try encoder.encode(PolicyDescriptor(
                schema: "dory.vzmac-configuration@4",
                display: displayString,
                network: devicePolicy.network.rawValue,
                audioInput: devicePolicy.audio.inputEnabled,
                audioOutput: devicePolicy.audio.outputEnabled,
                input: "mac-keyboard-trackpad",
                entropy: "virtio",
                cameraSocketPort: devicePolicy.cameraBridgeEnabled ? 1_030 : nil,
                clipboard: devicePolicy.clipboardEnabled,
                xhciEnabled: xhciEnabled,
                directorySharing: devicePolicy.directorySharingEnabled,
                sharedDirectories: mappedShares,
                usbMassStorage: mappedUSBMassStorage
            ))
        } else if mappedUSBMassStorage != nil {
            encoded = try encoder.encode(Descriptor(
                schema: "dory.vzmac-configuration@2",
                display: displayString,
                network: "virtio-nat",
                audio: "virtio-host-input-output",
                input: "mac-keyboard-trackpad",
                entropy: "virtio",
                cameraSocketPort: 1_030,
                clipboard: "spice-bidirectional",
                xhciEnabled: xhciEnabled,
                sharedDirectories: mappedShares,
                usbMassStorage: mappedUSBMassStorage!
            ))
        } else {
            // Adding an optional device must not invalidate a saved state whose effective device
            // configuration did not change. Preserve the exact pre-USB descriptor in that case.
            encoded = try encoder.encode(LegacyDescriptor(
                schema: "dory.vzmac-configuration@1",
                display: displayString,
                network: "virtio-nat",
                audio: "virtio-host-input-output",
                input: "mac-keyboard-trackpad",
                entropy: "virtio",
                cameraSocketPort: 1_030,
                clipboard: "spice-bidirectional",
                xhciEnabled: xhciEnabled,
                sharedDirectories: mappedShares
            ))
        }
        // Preserve historical fingerprints for configurations that still use the same SPICE
        // device. The separately granted text-only channel is a new effective configuration:
        // different directions must not reuse one another's saved-state compatibility digest.
        var fingerprintInput = encoded
        if devicePolicy.clipboardEnabled && !devicePolicy.spiceClipboardEnabled {
            fingerprintInput.append(0)
            fingerprintInput.append(contentsOf: Data(
                "dory.vzmac-tools-clipboard@1:read=\(devicePolicy.clipboardTextReadEnabled):write=\(devicePolicy.clipboardTextWriteEnabled)".utf8
            ))
            if devicePolicy.clipboardImageReadEnabled || devicePolicy.clipboardImageWriteEnabled {
                fingerprintInput.append(contentsOf: Data(
                    ":imageRead=\(devicePolicy.clipboardImageReadEnabled):imageWrite=\(devicePolicy.clipboardImageWriteEnabled)".utf8
                ))
            }
        }
        if let cameraDeviceUniqueID {
            fingerprintInput.append(0)
            fingerprintInput.append(contentsOf: Data(
                "dory.vzmac-host-camera@1:\(cameraDeviceUniqueID)".utf8
            ))
        }
        return SHA256.hash(data: fingerprintInput)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    public static func makeConfiguration(
        for bundle: DoryVZMacMachineBundle,
        sharedDirectories: [DoryVZMacSharedDirectory] = [],
        usbMassStorage: DoryVZMacUSBMassStorage? = nil,
        devicePolicy: DoryVZMacDevicePolicy = .legacyDefault,
        networkAttachment: VZNetworkDeviceAttachment? = nil
    ) throws -> VZVirtualMachineConfiguration {
        try validatePolicy(devicePolicy, sharedDirectories: sharedDirectories)
        let configuration = VZVirtualMachineConfiguration()
        configuration.bootLoader = VZMacOSBootLoader()
        configuration.cpuCount = bundle.manifest.resources.cpuCount
        configuration.memorySize = bundle.manifest.resources.memoryBytes

        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = try bundle.hardwareModel()
        platform.machineIdentifier = try bundle.machineIdentifier()
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(contentsOf: bundle.auxiliaryStorageURL)
        configuration.platform = platform

        let diskAttachment = try VZDiskImageStorageDeviceAttachment(
            url: bundle.diskURL,
            readOnly: false,
            cachingMode: .automatic,
            synchronizationMode: .full
        )
        var storageDevices: [VZStorageDeviceConfiguration] = [
            VZVirtioBlockDeviceConfiguration(attachment: diskAttachment),
        ]
        for dataDiskURL in bundle.dataDiskURLs {
            let attachment = try VZDiskImageStorageDeviceAttachment(
                url: dataDiskURL,
                readOnly: false,
                cachingMode: .automatic,
                synchronizationMode: .full
            )
            storageDevices.append(VZVirtioBlockDeviceConfiguration(attachment: attachment))
        }
        if let usbMassStorage {
            guard #available(macOS 15.0, *) else {
                throw DoryVZMacUSBMassStorageError.requiresMacOS15
            }
            let attachment = try VZDiskImageStorageDeviceAttachment(
                url: usbMassStorage.url,
                readOnly: usbMassStorage.readOnly,
                cachingMode: .automatic,
                synchronizationMode: usbMassStorage.readOnly ? .none : .full
            )
            storageDevices.append(VZUSBMassStorageDeviceConfiguration(attachment: attachment))
        }
        configuration.storageDevices = storageDevices

        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = bundle.manifest.resources.displays.map { display in
            VZMacGraphicsDisplayConfiguration(
                widthInPixels: display.widthInPixels,
                heightInPixels: display.heightInPixels,
                pixelsPerInch: display.pixelsPerInch
            )
        }
        configuration.graphicsDevices = [graphics]
        configuration.keyboards = [VZMacKeyboardConfiguration()]
        configuration.pointingDevices = [VZMacTrackpadConfiguration()]

        try applyDevicePolicy(
            to: configuration,
            macAddress: bundle.manifest.macAddress,
            sharedDirectories: sharedDirectories,
            devicePolicy: devicePolicy,
            networkAttachment: networkAttachment
        )
        if #available(macOS 15.0, *) {
            configuration.usbControllers = [VZXHCIControllerConfiguration()]
        }
        try configuration.validate()
        return configuration
    }

    static func applyDevicePolicy(
        to configuration: VZVirtualMachineConfiguration,
        macAddress: String,
        sharedDirectories: [DoryVZMacSharedDirectory],
        devicePolicy: DoryVZMacDevicePolicy,
        networkAttachment: VZNetworkDeviceAttachment? = nil
    ) throws {
        try validatePolicy(devicePolicy, sharedDirectories: sharedDirectories)
        switch devicePolicy.network {
        case .sharedNAT:
            let network = VZVirtioNetworkDeviceConfiguration()
            guard let macAddress = VZMACAddress(string: macAddress) else {
                throw DoryVZMacConfigurationError.invalidMACAddress(macAddress)
            }
            network.macAddress = macAddress
            network.attachment = VZNATNetworkDeviceAttachment()
            configuration.networkDevices = [network]
        case .isolated:
            guard let networkAttachment,
                  networkAttachment is VZFileHandleNetworkDeviceAttachment else {
                throw DoryVZMacConfigurationError.missingHostOnlyNetworkAttachment
            }
            let network = VZVirtioNetworkDeviceConfiguration()
            guard let macAddress = VZMACAddress(string: macAddress) else {
                throw DoryVZMacConfigurationError.invalidMACAddress(macAddress)
            }
            network.macAddress = macAddress
            network.attachment = networkAttachment
            configuration.networkDevices = [network]
        case .disconnected:
            configuration.networkDevices = []
        }

        var audioStreams = [VZVirtioSoundDeviceStreamConfiguration]()
        if devicePolicy.audio.inputEnabled {
            let audioInput = VZVirtioSoundDeviceInputStreamConfiguration()
            audioInput.source = VZHostAudioInputStreamSource()
            audioStreams.append(audioInput)
        }
        if devicePolicy.audio.outputEnabled {
            let audioOutput = VZVirtioSoundDeviceOutputStreamConfiguration()
            audioOutput.sink = VZHostAudioOutputStreamSink()
            audioStreams.append(audioOutput)
        }
        if !audioStreams.isEmpty {
            let sound = VZVirtioSoundDeviceConfiguration()
            sound.streams = audioStreams
            configuration.audioDevices = [sound]
        } else {
            configuration.audioDevices = []
        }

        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        // Auto-enable directory sharing when shares are provided. The
        // directorySharingEnabled flag only controls whether the device is created
        // when no shares are provided — providing shares implicitly enables it.
        if !sharedDirectories.isEmpty {
            var directories = [String: VZSharedDirectory]()
            for share in sharedDirectories {
                guard directories[share.name] == nil else {
                    throw DoryVZMacSharedDirectoryError.duplicateName(share.name)
                }
                directories[share.name] = VZSharedDirectory(
                    url: share.url,
                    readOnly: share.readOnly
                )
            }
            let fileSystem = VZVirtioFileSystemDeviceConfiguration(
                tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag
            )
            fileSystem.share = VZMultipleDirectoryShare(directories: directories)
            configuration.directorySharingDevices = [fileSystem]
        }
        if devicePolicy.spiceClipboardEnabled {
            let spiceAttachment = VZSpiceAgentPortAttachment()
            spiceAttachment.sharesClipboard = true
            let spicePort = VZVirtioConsolePortConfiguration()
            spicePort.name = VZSpiceAgentPortAttachment.spiceAgentPortName
            spicePort.attachment = spiceAttachment
            let console = VZVirtioConsoleDeviceConfiguration()
            console.ports[0] = spicePort
            configuration.consoleDevices = [console]
        } else {
            configuration.consoleDevices = []
        }
    }

    public static func inspectEffectiveDevices(
        _ configuration: VZVirtualMachineConfiguration
    ) -> DoryVZMacEffectiveDeviceReport {
        let audioStreams = configuration.audioDevices
            .compactMap { $0 as? VZVirtioSoundDeviceConfiguration }
            .flatMap(\.streams)
        let fileSystems = configuration.directorySharingDevices
            .compactMap { $0 as? VZVirtioFileSystemDeviceConfiguration }
        let sharedDirectories: [DoryVZMacEffectiveSharedDirectory] = fileSystems.flatMap {
            fileSystem -> [DoryVZMacEffectiveSharedDirectory] in
            guard let share = fileSystem.share as? VZMultipleDirectoryShare else { return [] }
            return share.directories.map { name, directory in
                DoryVZMacEffectiveSharedDirectory(name: name, readOnly: directory.isReadOnly)
            }
        }.sorted(by: { $0.name < $1.name })
        var spiceClipboard = false
        for consoleDevice in configuration.consoleDevices {
            guard let console = consoleDevice as? VZVirtioConsoleDeviceConfiguration else {
                continue
            }
            if let port = console.ports[0],
               let attachment = port.attachment as? VZSpiceAgentPortAttachment,
               attachment.sharesClipboard {
                spiceClipboard = true
            }
        }
        return DoryVZMacEffectiveDeviceReport(
            networkDeviceCount: configuration.networkDevices.count,
            usesNATNetworkAttachment: configuration.networkDevices.contains {
                ($0 as? VZVirtioNetworkDeviceConfiguration)?.attachment
                    is VZNATNetworkDeviceAttachment
            },
            audioDeviceCount: configuration.audioDevices.count,
            audioInputStreamCount: audioStreams
                .filter { $0 is VZVirtioSoundDeviceInputStreamConfiguration }
                .count,
            audioOutputStreamCount: audioStreams
                .filter { $0 is VZVirtioSoundDeviceOutputStreamConfiguration }
                .count,
            directorySharingDeviceCount: fileSystems.count,
            sharedDirectoryCount: sharedDirectories.count,
            sharedDirectories: sharedDirectories,
            consoleDeviceCount: configuration.consoleDevices.count,
            spiceClipboardEnabled: spiceClipboard
        )
    }

    private static func validatePolicy(
        _ devicePolicy: DoryVZMacDevicePolicy,
        sharedDirectories: [DoryVZMacSharedDirectory]
    ) throws {
        let anyClipboardDirection = devicePolicy.spiceClipboardEnabled
            || devicePolicy.clipboardTextReadEnabled
            || devicePolicy.clipboardTextWriteEnabled
            || devicePolicy.clipboardImageReadEnabled
            || devicePolicy.clipboardImageWriteEnabled
        guard devicePolicy.clipboardEnabled == anyClipboardDirection,
            !devicePolicy.spiceClipboardEnabled
                || (devicePolicy.clipboardTextReadEnabled
                    && devicePolicy.clipboardTextWriteEnabled
                    && devicePolicy.clipboardImageReadEnabled
                    && devicePolicy.clipboardImageWriteEnabled)
        else { throw DoryVZMacConfigurationError.invalidClipboardPolicy }
        // §4.3: The admission rejection is removed. When shares are provided via
        // --share, directory sharing is auto-enabled (see applyDevicePolicy). The
        // directorySharingEnabled flag now only controls whether the sharing device
        // is created when no shares are provided — it no longer rejects shares.
    }
}

/// Lease acquisition is the runtime admission boundary, not the caller's earlier bundle
/// read. Never silently adopt a successor manifest: its state/resources may no longer match
/// the caller's authorized launch, and a stale stopped value must not bypass suspended RAM.
struct DoryVZMacRuntimeAdmission {
    let bundle: DoryVZMacMachineBundle
    let lease: DoryVZMacMachineLease
    let claim: DoryVZMacRuntimeLeaseClaim

    static func acquire(
        for requested: DoryVZMacMachineBundle,
        holding existingLease: DoryVZMacMachineLease? = nil,
        loadBundle: (URL) throws -> DoryVZMacMachineBundle = {
            try DoryVZMacMachineBundle.load(from: $0)
        }
    ) throws -> Self {
        let lease = try existingLease ?? DoryVZMacMachineLease(rootURL: requested.rootURL)
        defer { withExtendedLifetime(lease) {} }
        guard lease.ownsRoot(requested.rootURL) else {
            throw DoryVZMacConfigurationError.machineBundleChangedBeforeRuntimeAdmission
        }
        let claim = try lease.claimRuntime()
        defer { withExtendedLifetime(claim) {} }
        let current = try loadBundle(requested.rootURL)
        guard lease.ownsRoot(requested.rootURL),
              current.rootURL.standardizedFileURL == requested.rootURL.standardizedFileURL,
              current.manifest == requested.manifest else {
            throw DoryVZMacConfigurationError.machineBundleChangedBeforeRuntimeAdmission
        }
        return Self(bundle: current, lease: lease, claim: claim)
    }
}

@MainActor
public final class DoryVZMacRuntime {
    public private(set) var bundle: DoryVZMacMachineBundle
    private let machineLease: DoryVZMacMachineLease
    private let runtimeLeaseClaim: DoryVZMacRuntimeLeaseClaim
    public let configuration: VZVirtualMachineConfiguration
    public let virtualMachine: VZVirtualMachine
    public let cameraBridge: DoryVZMacCameraBridge?
    public let metalProbeCollector: DoryVZMacMetalProbeCollector?
    public let guestIntegrationService: DoryVZMacGuestIntegrationService
    public let configurationSHA256: String

    public init(
        bundle requestedBundle: DoryVZMacMachineBundle,
        holdingMachineLease existingMachineLease: DoryVZMacMachineLease? = nil,
        sharedDirectories: [DoryVZMacSharedDirectory] = [],
        usbMassStorage: DoryVZMacUSBMassStorage? = nil,
        devicePolicy: DoryVZMacDevicePolicy = .legacyDefault,
        networkAttachment: VZNetworkDeviceAttachment? = nil,
        cameraDeviceUniqueID: String? = nil,
        camera: DoryMacCameraBackend? = nil,
        metalProbeCollector: DoryVZMacMetalProbeCollector? = nil,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) throws {
        let admission = try DoryVZMacRuntimeAdmission.acquire(
            for: requestedBundle, holding: existingMachineLease
        )
        let bundle = admission.bundle
        self.bundle = bundle
        machineLease = admission.lease
        runtimeLeaseClaim = admission.claim
        let configuration = try DoryVZMacConfigurationBuilder.makeConfiguration(
            for: bundle,
            sharedDirectories: sharedDirectories,
            usbMassStorage: usbMassStorage,
            devicePolicy: devicePolicy,
            networkAttachment: networkAttachment
        )
        self.configuration = configuration
        configurationSHA256 = try DoryVZMacConfigurationBuilder.fingerprint(
            sharedDirectories: sharedDirectories,
            usbMassStorage: usbMassStorage,
            devicePolicy: devicePolicy,
            cameraDeviceUniqueID: cameraDeviceUniqueID,
            displays: bundle.manifest.resources.displays,
            dataDisks: bundle.manifest.resources.dataDisks
        )
        virtualMachine = VZVirtualMachine(configuration: configuration)
        if let metalProbeCollector {
            guard let socket = virtualMachine.socketDevices.first as? VZVirtioSocketDevice else {
                throw DoryVZMacConfigurationError.metalProbeSocketUnavailable
            }
            try metalProbeCollector.install(on: socket)
        }
        self.metalProbeCollector = metalProbeCollector
        guard let guestSocket = virtualMachine.socketDevices.first as? VZVirtioSocketDevice else {
            throw DoryVZMacConfigurationError.guestIntegrationSocketUnavailable
        }
        let guestIntegrationService = try DoryVZMacGuestIntegrationService(
            machineID: bundle.manifest.machineIdentifierSHA256,
            allowClipboardTextRead: devicePolicy.clipboardTextReadEnabled,
            allowClipboardTextWrite: devicePolicy.clipboardTextWriteEnabled,
            allowClipboardImageRead: devicePolicy.clipboardImageReadEnabled,
            allowClipboardImageWrite: devicePolicy.clipboardImageWriteEnabled,
            log: log
        )
        try guestIntegrationService.install(on: guestSocket)
        self.guestIntegrationService = guestIntegrationService
        if devicePolicy.cameraBridgeEnabled {
            let backend = camera ?? DoryMacCameraBackend(
                selectedDeviceUniqueID: cameraDeviceUniqueID,
                log: log
            )
            if let cameraDeviceUniqueID {
                guard backend.selectedDeviceUniqueID == cameraDeviceUniqueID else {
                    throw DoryVZMacConfigurationError.invalidCameraSelection
                }
                try backend.reserveSelectedDevice()
            }
            let bridge = DoryVZMacCameraBridge(
                camera: backend,
                log: log
            )
            guard let socket = virtualMachine.socketDevices.first as? VZVirtioSocketDevice else {
                throw DoryVZMacConfigurationError.cameraSocketUnavailable
            }
            try bridge.install(on: socket)
            cameraBridge = bridge
        } else {
            cameraBridge = nil
        }
    }

    public func install(
        from restoreImageURL: URL,
        operationID: UUID,
        progress: @escaping @MainActor @Sendable (Double) -> Void = { _ in }
    ) async throws {
        try Task.checkCancellation()
        if [.installing, .installFailed].contains(bundle.manifest.installationState) {
            bundle = try DoryVZMacRecovery.recoverInterruptedOperation(in: bundle, holding: machineLease)
            if bundle.manifest.installationState == .stopped {
                progress(1)
                return
            }
        }
        try Task.checkCancellation()
        guard bundle.manifest.installationState == .prepared
                || bundle.manifest.installationState == .installFailed else {
            throw DoryVZMacMachineBundleError.invalidBundle(
                "installation requires a prepared or failed-install machine"
            )
        }
        let startedAt = ISO8601DateFormatter().string(from: Date())
        var journal = DoryVZMacInstallJournal(
            operationID: operationID,
            startedAt: startedAt,
            updatedAt: startedAt,
            phase: .validatingRestore,
            progress: 0,
            restoreImageSHA256: bundle.manifest.restoreImageSHA256,
            machineIdentifierSHA256: bundle.manifest.machineIdentifierSHA256,
            error: nil
        )
        bundle = try DoryVZMacRecovery.beginInstallation(journal, in: bundle, holding: machineLease)
        do {
            try await bundle.validateRestoreImage(at: restoreImageURL)
            try Task.checkCancellation()
            bundle = try bundle.updatingInstallationState(.installing)
            journal = journal.updating(phase: .installing, progress: 0)
            try journal.write(to: bundle.installJournalURL)
            let installer = VZMacOSInstaller(
                virtualMachine: virtualMachine,
                restoringFromImageAt: restoreImageURL
            )
            let session = DoryVZMacInstallSession {
                installer.install(completionHandler: $0)
            } cancel: {
                installer.progress.cancel()
            }
            let progressMonitor = Task { @MainActor in
                var lastWrittenPercent = -1
                while !Task.isCancelled {
                    if session.isFinished { return }
                    if !session.isInstalling {
                        // The monitor may be scheduled before the actor enters session.run().
                        try? await Task.sleep(for: .milliseconds(20))
                        continue
                    }
                    let fraction = installer.progress.fractionCompleted
                    guard fraction.isFinite, (0...1).contains(fraction) else {
                        session.cancel(error: DoryVZMacInstallJournalError.invalid(
                            "Apple installer reported invalid progress"
                        ))
                        return
                    }
                    progress(fraction)
                    let percent = Int(fraction * 100)
                    if percent != lastWrittenPercent {
                        lastWrittenPercent = percent
                        let update = journal.updating(
                            phase: .installing,
                            progress: fraction
                        )
                        do {
                            try update.write(to: bundle.installJournalURL)
                        } catch {
                            session.cancel(error: error)
                            return
                        }
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            defer { progressMonitor.cancel() }
            try await session.run()
        } catch {
            let installationError = error
            let detail = String(String(describing: installationError).prefix(
                DoryVZMacInstallJournal.maximumErrorUTF8Bytes / 4
            ))
            journal = journal.updating(
                phase: .failed,
                progress: lastObservedInstallProgress(from: bundle.installJournalURL),
                error: detail.isEmpty ? "unknown VZMac installation failure" : detail
            )
            do {
                bundle = try DoryVZMacRecovery.commitInstallationOutcome(journal, in: bundle, holding: machineLease)
            } catch {
                throw DoryVZMacInstallJournalError.failureRecording(
                    installation: String(describing: installationError), metadata: String(describing: error)
                )
            }
            throw installationError
        }
        // Keep completion publication outside the installer-failure catch. If its flush
        // fails, retain successful-install evidence and let recovery finish the commit.
        journal = journal.updating(phase: .completed, progress: 1)
        bundle = try DoryVZMacRecovery.commitInstallationOutcome(journal, in: bundle, holding: machineLease)
        progress(1)
    }

    public func start() async throws {
        guard bundle.manifest.installationState == .stopped else {
            throw DoryVZMacMachineBundleError.invalidBundle(
                "only an installed, stopped VZMac machine can start"
            )
        }
        try await virtualMachine.start()
    }

    public func suspend(to managedStateURL: URL? = nil) async throws {
        guard virtualMachine.state == .running else {
            throw DoryVZMacSavedStateError.invalidVirtualMachineState(
                "VZMac must be running before suspension"
            )
        }
        try Task.checkCancellation()
        do {
            try configuration.validateSaveRestoreSupport()
        } catch {
            throw DoryVZMacSavedStateError.saveRestoreUnsupported(String(describing: error))
        }
        if let managedStateURL {
            try await suspendToManagedState(managedStateURL.standardizedFileURL)
        } else {
            try await suspendToBundleArtifact()
        }
    }

    private func suspendToBundleArtifact() async throws {
        let artifactEntryURL = bundle.rootURL.appendingPathComponent(
            DoryVZMacMachineBundle.suspendedStateDirectoryName, isDirectory: false
        )
        if try DoryVZMacMetadataFile.entryExists(at: artifactEntryURL),
           bundle.manifest.installationState == .stopped {
            // A prior successful restore may have crashed during wrapper cleanup. Retire
            // only consumed/incomplete, known-format artifacts; a valid unconsumed snapshot
            // or unknown files still block suspension instead of being silently overwritten.
            try DoryVZMacSavedStateArtifact.retireConsumedArtifact(
                at: bundle.suspendedStateURL, barrierFileURL: bundle.manifestURL
            )
        }
        guard try !DoryVZMacMetadataFile.entryExists(at: artifactEntryURL) else {
            throw DoryVZMacSavedStateError.destinationExists(bundle.suspendedStateURL.path)
        }
        bundle = try bundle.updatingInstallationState(.suspending)
        let staging = bundle.rootURL.appendingPathComponent(
            ".\(DoryVZMacMachineBundle.suspendedStateDirectoryName).creating-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try await virtualMachine.pause()
            try Task.checkCancellation()
            try FileManager.default.createDirectory(
                at: staging,
                withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
            )
            let stateURL = staging.appendingPathComponent(DoryVZMacSavedStateArtifact.stateName)
            try await virtualMachine.saveMachineStateTo(url: stateURL)
            try secureManagedSavedStateFile(stateURL)
            try Task.checkCancellation()
            let receipt = try makeSavedStateReceipt(
                stateURL: stateURL,
                bundle: bundle,
                configurationSHA256: configurationSHA256
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try DoryVZMacMetadataFile.write(
                encoder.encode(receipt),
                to: staging.appendingPathComponent(DoryVZMacSavedStateArtifact.receiptName)
            )
            try Task.checkCancellation()
            try DoryVZMacBundlePublication.publish(
                staging: staging, to: bundle.suspendedStateURL,
                relativeFiles: [DoryVZMacSavedStateArtifact.stateName, DoryVZMacSavedStateArtifact.receiptName],
                barrierFile: DoryVZMacSavedStateArtifact.receiptName
            )
            bundle = try bundle.updatingInstallationState(.suspended)
        } catch {
            let suspensionError = error
            do {
                // A late publication error may have renamed RAM even though publish did not
                // return. Retire both owned locations before allowing the original live RAM
                // to advance disks; failure leaves the VM paused and the manifest interrupted.
                try DoryVZMacSavedStateRetirement.retireFailedSuspension(
                    staging: staging, published: bundle.suspendedStateURL, barrierFileURL: bundle.manifestURL
                )
            } catch {
                throw DoryVZMacSavedStateError.invalidVirtualMachineState(
                    "suspension failed (\(suspensionError)); RAM retirement failed (\(error)); cold recovery is required"
                )
            }
            await recoverStandaloneSuspendFailure()
            throw suspensionError
        }
    }

    private func suspendToManagedState(_ stateURL: URL) async throws {
        guard !FileManager.default.fileExists(atPath: stateURL.path) else {
            throw DoryVZMacSavedStateError.destinationExists(stateURL.path)
        }
        let parent = stateURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw DoryVZMacSavedStateError.invalidArtifact("managed saved-state directory is missing")
        }
        try await DoryVZMacManagedSavedStateOperation.suspend(
            to: stateURL,
            hooks: managedSavedStateHooks()
        )
    }

    public func restoreSuspendedState(from managedStateURL: URL? = nil) async throws {
        guard bundle.manifest.installationState == .suspended,
              virtualMachine.state == .stopped else {
            throw DoryVZMacSavedStateError.invalidVirtualMachineState(
                "VZMac must be stopped with a suspended-state manifest before restore"
            )
        }
        do {
            try configuration.validateSaveRestoreSupport()
        } catch {
            throw DoryVZMacSavedStateError.saveRestoreUnsupported(String(describing: error))
        }
        let stateURL: URL
        let bundleArtifactRootURL: URL?
        if let managedStateURL {
            stateURL = managedStateURL.standardizedFileURL
            bundleArtifactRootURL = nil
        } else {
            let artifact = try DoryVZMacSavedStateArtifact.load(
                from: bundle.suspendedStateURL,
                for: bundle,
                expectedConfigurationSHA256: configurationSHA256
            )
            stateURL = artifact.stateURL
            bundleArtifactRootURL = artifact.rootURL
        }
        try await DoryVZMacManagedSavedStateOperation.restore(
            from: stateURL,
            hooks: managedSavedStateHooks()
        )
        if let bundleArtifactRootURL {
            // Cleanup is after execution and is not the consumption fence. If interrupted,
            // the retained marker still rejects replay; never revert the stopped manifest.
            try DoryVZMacSavedStateArtifact.retireConsumedArtifact(
                at: bundleArtifactRootURL, barrierFileURL: bundle.manifestURL
            )
        }
    }

    private func recoverStandaloneSuspendFailure() async {
        switch virtualMachine.state {
        case .paused:
            do {
                try await virtualMachine.resume()
                bundle = try bundle.updatingInstallationState(.stopped)
            } catch {
                return
            }
        case .running, .stopped:
            bundle = (try? bundle.updatingInstallationState(.stopped)) ?? bundle
        default:
            break
        }
    }

    private func managedSavedStateHooks() -> DoryVZMacManagedSavedStateHooks {
        DoryVZMacManagedSavedStateHooks(
            runtimeState: { [weak self] in
                guard let self else { return .other }
                switch self.virtualMachine.state {
                case .running: return .running
                case .paused: return .paused
                case .stopped: return .stopped
                default: return .other
                }
            },
            updateInstallationState: { [weak self] state in
                guard let self else { return }
                self.bundle = try self.bundle.updatingInstallationState(state)
            },
            pause: { [weak self] in try await self?.virtualMachine.pause() },
            resume: { [weak self] in try await self?.virtualMachine.resume() },
            save: { [weak self] url in try await self?.virtualMachine.saveMachineStateTo(url: url) },
            restore: { [weak self] url in try await self?.virtualMachine.restoreMachineStateFrom(url: url) },
            secureSavedState: { [weak self] url in try self?.secureManagedSavedStateFile(url) },
            removeSavedState: { url in
                if try DoryVZMacMetadataFile.entryExists(at: url) {
                    try DoryVZMacMetadataFile.remove(at: url)
                }
            },
            isSavedStateConsumed: { try DoryVZSavedStateConsumption.isConsumed(stateURL: $0) },
            consumeSavedState: { try DoryVZSavedStateConsumption.consume(stateURL: $0) }
        )
    }

    public func requestStop() throws {
        try virtualMachine.requestStop()
    }

    public func openURLInGuest(_ url: URL) async throws {
        try await guestIntegrationService.openURL(url)
    }

    public func sendFileToGuest(at url: URL) async throws {
        try await guestIntegrationService.sendFileToGuest(at: url)
    }

    public func fileOfferedByGuest() async throws -> DoryMacGuestIntegrationWire.FilePullOffer {
        try await guestIntegrationService.fileOfferedByGuest()
    }

    public func receiveFileFromGuest(
        _ offer: DoryMacGuestIntegrationWire.FilePullOffer, to destination: URL
    ) async throws {
        try await guestIntegrationService.receiveFileFromGuest(offer, to: destination)
    }

    public func readClipboardTextFromGuest() async throws -> String {
        try await guestIntegrationService.readClipboardText()
    }

    public func writeClipboardTextToGuest(_ text: String) async throws {
        try await guestIntegrationService.writeClipboardText(text)
    }

    public func readClipboardPNGFromGuest() async throws -> Data {
        try await guestIntegrationService.readClipboardPNG()
    }

    public func writeClipboardPNGToGuest(_ png: Data) async throws {
        try await guestIntegrationService.writeClipboardPNG(png)
    }

    public func pause() async throws {
        try await virtualMachine.pause()
    }

    public func resume() async throws {
        try Self.validateResumeInstallationState(bundle.manifest.installationState)
        try await virtualMachine.resume()
    }

    nonisolated static func validateResumeInstallationState(_ state: DoryVZMacMachineInstallationState) throws {
        guard state == .stopped else {
            throw DoryVZMacSavedStateError.invalidVirtualMachineState(
                "cannot resume a VZMac VM with an uncommitted \(state.rawValue) manifest"
            )
        }
    }

    private func secureManagedSavedStateFile(_ url: URL) throws {
        let descriptor = try openManagedSavedStateFile(url, requirePrivateMode: false)
        defer { close(descriptor) }
        guard fchmod(descriptor, 0o600) == 0 else {
            throw DoryVZMacSavedStateError.filesystem("fchmod saved state", errno)
        }
        try validateManagedSavedStateDescriptor(descriptor, requirePrivateMode: true)
        try DoryVZMacMetadataFile.synchronizeFileDescriptor(descriptor)
    }

    private func openManagedSavedStateFile(
        _ url: URL,
        requirePrivateMode: Bool
    ) throws -> Int32 {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw DoryVZMacSavedStateError.filesystem("open saved state", errno)
        }
        do {
            try validateManagedSavedStateDescriptor(
                descriptor,
                requirePrivateMode: requirePrivateMode
            )
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private func validateManagedSavedStateDescriptor(
        _ descriptor: Int32,
        requirePrivateMode: Bool
    ) throws {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw DoryVZMacSavedStateError.filesystem("fstat saved state", errno)
        }
        guard (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == geteuid(),
              status.st_nlink == 1 else {
            throw DoryVZMacSavedStateError.invalidArtifact("managed state is not a private owned regular file")
        }
        if requirePrivateMode, (status.st_mode & 0o077) != 0 {
            throw DoryVZMacSavedStateError.invalidArtifact("managed state is not private")
        }
        guard status.st_size > 0 else {
            throw DoryVZMacSavedStateError.invalidArtifact("managed state is empty")
        }
    }

    deinit {
        guestIntegrationService.remove()
        cameraBridge?.remove()
    }
}
