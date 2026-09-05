import DoryHostCamera
import DoryVZMacCameraBridge
import CryptoKit
import Darwin
import Foundation
import Virtualization

public enum DoryVZMacConfigurationError: Error, Sendable, CustomStringConvertible {
    case invalidMACAddress(String)
    case cameraSocketUnavailable
    case integrationDisabled(String)

    public var description: String {
        switch self {
        case .invalidMACAddress(let address):
            "VZMac network address is invalid: \(address)"
        case .cameraSocketUnavailable:
            "VZMac did not expose the configured VirtIO socket device"
        case .integrationDisabled(let name):
            "VZMac \(name) integration is disabled by the effective device policy"
        }
    }
}

public enum DoryVZMacNetworkPolicy: String, Codable, Sendable, Equatable {
    case disconnected
    case sharedNAT = "shared-nat"
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
    public var directorySharingEnabled: Bool

    public init(
        network: DoryVZMacNetworkPolicy = .sharedNAT,
        audio: DoryVZMacAudioPolicy = DoryVZMacAudioPolicy(),
        clipboardEnabled: Bool = true,
        directorySharingEnabled: Bool = true
    ) {
        self.network = network
        self.audio = audio
        self.clipboardEnabled = clipboardEnabled
        self.directorySharingEnabled = directorySharingEnabled
    }

    public static let legacyDefault = DoryVZMacDevicePolicy()
}

public struct DoryVZMacEffectiveDeviceReport: Sendable, Equatable {
    public var networkDeviceCount: Int
    public var usesNATNetworkAttachment: Bool
    public var audioDeviceCount: Int
    public var audioInputStreamCount: Int
    public var audioOutputStreamCount: Int
    public var directorySharingDeviceCount: Int
    public var sharedDirectoryCount: Int
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
        devicePolicy: DoryVZMacDevicePolicy = .legacyDefault
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
            let cameraSocketPort: UInt32
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
        try validatePolicy(devicePolicy, sharedDirectories: sharedDirectories)
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
        let encoded: Data
        let mappedUSBMassStorage = usbMassStorage.map {
            USBMassStorage(path: $0.url.path, readOnly: $0.readOnly, byteCount: $0.byteCount)
        }
        if devicePolicy != .legacyDefault {
            encoded = try encoder.encode(PolicyDescriptor(
                schema: "dory.vzmac-configuration@3",
                display: "1920x1080@144ppi-auto-resize",
                network: devicePolicy.network.rawValue,
                audioInput: devicePolicy.audio.inputEnabled,
                audioOutput: devicePolicy.audio.outputEnabled,
                input: "mac-keyboard-trackpad",
                entropy: "virtio",
                cameraSocketPort: 1_030,
                clipboard: devicePolicy.clipboardEnabled,
                xhciEnabled: xhciEnabled,
                directorySharing: devicePolicy.directorySharingEnabled,
                sharedDirectories: mappedShares,
                usbMassStorage: mappedUSBMassStorage
            ))
        } else if mappedUSBMassStorage != nil {
            encoded = try encoder.encode(Descriptor(
                schema: "dory.vzmac-configuration@2",
                display: "1920x1080@144ppi-auto-resize",
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
                display: "1920x1080@144ppi-auto-resize",
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
        return SHA256.hash(data: encoded)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    public static func makeConfiguration(
        for bundle: DoryVZMacMachineBundle,
        sharedDirectories: [DoryVZMacSharedDirectory] = [],
        usbMassStorage: DoryVZMacUSBMassStorage? = nil,
        devicePolicy: DoryVZMacDevicePolicy = .legacyDefault
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

        let display = VZMacGraphicsDisplayConfiguration(
            widthInPixels: 1_920,
            heightInPixels: 1_080,
            pixelsPerInch: 144
        )
        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [display]
        configuration.graphicsDevices = [graphics]
        configuration.keyboards = [VZMacKeyboardConfiguration()]
        configuration.pointingDevices = [VZMacTrackpadConfiguration()]

        try applyDevicePolicy(
            to: configuration,
            macAddress: bundle.manifest.macAddress,
            sharedDirectories: sharedDirectories,
            devicePolicy: devicePolicy
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
        devicePolicy: DoryVZMacDevicePolicy
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
        if devicePolicy.directorySharingEnabled, !sharedDirectories.isEmpty {
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
        if devicePolicy.clipboardEnabled {
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
        let sharedDirectoryCount = fileSystems.reduce(0) { count, fileSystem in
            guard let share = fileSystem.share as? VZMultipleDirectoryShare else { return count }
            return count + share.directories.count
        }
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
            sharedDirectoryCount: sharedDirectoryCount,
            consoleDeviceCount: configuration.consoleDevices.count,
            spiceClipboardEnabled: spiceClipboard
        )
    }

    private static func validatePolicy(
        _ devicePolicy: DoryVZMacDevicePolicy,
        sharedDirectories: [DoryVZMacSharedDirectory]
    ) throws {
        if !devicePolicy.directorySharingEnabled, !sharedDirectories.isEmpty {
            throw DoryVZMacConfigurationError.integrationDisabled("directory sharing")
        }
    }
}

@MainActor
public final class DoryVZMacRuntime {
    public private(set) var bundle: DoryVZMacMachineBundle
    private let machineLease: DoryVZMacMachineLease
    public let configuration: VZVirtualMachineConfiguration
    public let virtualMachine: VZVirtualMachine
    public let cameraBridge: DoryVZMacCameraBridge
    public let configurationSHA256: String

    public init(
        bundle: DoryVZMacMachineBundle,
        sharedDirectories: [DoryVZMacSharedDirectory] = [],
        usbMassStorage: DoryVZMacUSBMassStorage? = nil,
        devicePolicy: DoryVZMacDevicePolicy = .legacyDefault,
        camera: DoryMacCameraBackend? = nil,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) throws {
        self.bundle = bundle
        machineLease = try DoryVZMacMachineLease(rootURL: bundle.rootURL)
        let configuration = try DoryVZMacConfigurationBuilder.makeConfiguration(
            for: bundle,
            sharedDirectories: sharedDirectories,
            usbMassStorage: usbMassStorage,
            devicePolicy: devicePolicy
        )
        self.configuration = configuration
        configurationSHA256 = try DoryVZMacConfigurationBuilder.fingerprint(
            sharedDirectories: sharedDirectories,
            usbMassStorage: usbMassStorage,
            devicePolicy: devicePolicy
        )
        virtualMachine = VZVirtualMachine(configuration: configuration)
        cameraBridge = DoryVZMacCameraBridge(
            camera: camera ?? DoryMacCameraBackend(log: log),
            log: log
        )
        guard let socket = virtualMachine.socketDevices.first as? VZVirtioSocketDevice else {
            throw DoryVZMacConfigurationError.cameraSocketUnavailable
        }
        try cameraBridge.install(on: socket)
    }

    public func install(
        from restoreImageURL: URL,
        operationID: UUID,
        progress: @escaping @MainActor @Sendable (Double) -> Void = { _ in }
    ) async throws {
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
        try journal.write(to: bundle.installJournalURL)
        do {
            try await bundle.validateRestoreImage(at: restoreImageURL)
            bundle = try bundle.updatingInstallationState(.installing)
            journal = journal.updating(phase: .installing, progress: 0)
            try journal.write(to: bundle.installJournalURL)
            let installer = VZMacOSInstaller(
                virtualMachine: virtualMachine,
                restoringFromImageAt: restoreImageURL
            )
            let progressMonitor = Task { @MainActor in
                var lastWrittenPercent = -1
                while !Task.isCancelled {
                    let fraction = installer.progress.fractionCompleted
                    progress(fraction)
                    let percent = Int(fraction * 100)
                    if percent != lastWrittenPercent {
                        lastWrittenPercent = percent
                        let update = journal.updating(
                            phase: .installing,
                            progress: fraction
                        )
                        try? update.write(to: bundle.installJournalURL)
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            defer { progressMonitor.cancel() }
            try await installer.install()
            progress(1)
            bundle = try bundle.updatingInstallationState(.stopped)
            journal = journal.updating(phase: .completed, progress: 1)
            try journal.write(to: bundle.installJournalURL)
        } catch {
            if bundle.manifest.installationState == .installing {
                bundle = try bundle.updatingInstallationState(.installFailed)
            }
            let detail = String(String(describing: error).prefix(
                DoryVZMacInstallJournal.maximumErrorUTF8Bytes / 4
            ))
            journal = journal.updating(
                phase: .failed,
                progress: lastObservedInstallProgress(from: bundle.installJournalURL),
                error: detail.isEmpty ? "unknown VZMac installation failure" : detail
            )
            try? journal.write(to: bundle.installJournalURL)
            throw error
        }
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
        guard !FileManager.default.fileExists(atPath: bundle.suspendedStateURL.path) else {
            throw DoryVZMacSavedStateError.destinationExists(bundle.suspendedStateURL.path)
        }
        bundle = try bundle.updatingInstallationState(.suspending)
        let staging = bundle.rootURL.appendingPathComponent(
            ".\(DoryVZMacMachineBundle.suspendedStateDirectoryName).creating-\(UUID().uuidString)",
            isDirectory: true
        )
        var committedArtifact = false
        do {
            try await virtualMachine.pause()
            try FileManager.default.createDirectory(
                at: staging,
                withIntermediateDirectories: false
            )
            let stateURL = staging.appendingPathComponent(DoryVZMacSavedStateArtifact.stateName)
            try await virtualMachine.saveMachineStateTo(url: stateURL)
            try secureManagedSavedStateFile(stateURL)
            let receipt = try makeSavedStateReceipt(
                stateURL: stateURL,
                bundle: bundle,
                configurationSHA256: configurationSHA256
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(receipt).write(
                to: staging.appendingPathComponent(DoryVZMacSavedStateArtifact.receiptName),
                options: [.atomic]
            )
            try FileManager.default.moveItem(at: staging, to: bundle.suspendedStateURL)
            committedArtifact = true
            bundle = try bundle.updatingInstallationState(.suspended)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            if committedArtifact {
                try? FileManager.default.removeItem(at: bundle.suspendedStateURL)
            }
            await recoverStandaloneSuspendFailure()
            throw error
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
        if let bundleArtifactRootURL {
            bundle = try bundle.updatingInstallationState(.restoring)
            do {
                try await virtualMachine.restoreMachineStateFrom(url: stateURL)
                try await virtualMachine.resume()
                try FileManager.default.removeItem(at: bundleArtifactRootURL)
                bundle = try bundle.updatingInstallationState(.stopped)
            } catch {
                if virtualMachine.state != .running {
                    bundle = (try? bundle.updatingInstallationState(.suspended)) ?? bundle
                }
                throw error
            }
        } else {
            try await DoryVZMacManagedSavedStateOperation.restore(
                from: stateURL,
                hooks: managedSavedStateHooks()
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
            removeSavedState: { url in try? FileManager.default.removeItem(at: url) }
        )
    }

    public func requestStop() throws {
        try virtualMachine.requestStop()
    }

    public func pause() async throws {
        try await virtualMachine.pause()
    }

    public func resume() async throws {
        try await virtualMachine.resume()
    }

    private func secureManagedSavedStateFile(_ url: URL) throws {
        let descriptor = try openManagedSavedStateFile(url, requirePrivateMode: false)
        defer { close(descriptor) }
        guard fchmod(descriptor, 0o600) == 0 else {
            throw DoryVZMacSavedStateError.filesystem("fchmod saved state", errno)
        }
        try validateManagedSavedStateDescriptor(descriptor, requirePrivateMode: true)
        guard fsync(descriptor) == 0 else {
            throw DoryVZMacSavedStateError.filesystem("fsync saved state", errno)
        }
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
        cameraBridge.remove()
    }
}
