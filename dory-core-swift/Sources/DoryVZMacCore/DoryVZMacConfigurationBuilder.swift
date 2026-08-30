import DoryHostCamera
import DoryVZMacCameraBridge
import Foundation
import Virtualization

public enum DoryVZMacConfigurationError: Error, Sendable, CustomStringConvertible {
    case invalidMACAddress(String)
    case cameraSocketUnavailable

    public var description: String {
        switch self {
        case .invalidMACAddress(let address):
            "VZMac network address is invalid: \(address)"
        case .cameraSocketUnavailable:
            "VZMac did not expose the configured VirtIO socket device"
        }
    }
}

public enum DoryVZMacConfigurationBuilder {
    public static func makeConfiguration(
        for bundle: DoryVZMacMachineBundle
    ) throws -> VZVirtualMachineConfiguration {
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
        configuration.storageDevices = [
            VZVirtioBlockDeviceConfiguration(attachment: diskAttachment),
        ]

        let network = VZVirtioNetworkDeviceConfiguration()
        guard let macAddress = VZMACAddress(string: bundle.manifest.macAddress) else {
            throw DoryVZMacConfigurationError.invalidMACAddress(bundle.manifest.macAddress)
        }
        network.macAddress = macAddress
        network.attachment = VZNATNetworkDeviceAttachment()
        configuration.networkDevices = [network]

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

        let audioInput = VZVirtioSoundDeviceInputStreamConfiguration()
        audioInput.source = VZHostAudioInputStreamSource()
        let audioOutput = VZVirtioSoundDeviceOutputStreamConfiguration()
        audioOutput.sink = VZHostAudioOutputStreamSink()
        let sound = VZVirtioSoundDeviceConfiguration()
        sound.streams = [audioInput, audioOutput]
        configuration.audioDevices = [sound]

        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        if #available(macOS 15.0, *) {
            configuration.usbControllers = [VZXHCIControllerConfiguration()]
        }
        try configuration.validate()
        return configuration
    }
}

@MainActor
public final class DoryVZMacRuntime {
    public private(set) var bundle: DoryVZMacMachineBundle
    public let configuration: VZVirtualMachineConfiguration
    public let virtualMachine: VZVirtualMachine
    public let cameraBridge: DoryVZMacCameraBridge

    public init(
        bundle: DoryVZMacMachineBundle,
        camera: DoryMacCameraBackend? = nil,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) throws {
        self.bundle = bundle
        let configuration = try DoryVZMacConfigurationBuilder.makeConfiguration(for: bundle)
        self.configuration = configuration
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
        progress: @escaping @MainActor @Sendable (Double) -> Void = { _ in }
    ) async throws {
        guard bundle.manifest.installationState == .prepared
                || bundle.manifest.installationState == .installFailed else {
            throw DoryVZMacMachineBundleError.invalidBundle(
                "installation requires a prepared or failed-install machine"
            )
        }
        try await bundle.validateRestoreImage(at: restoreImageURL)
        bundle = try bundle.updatingInstallationState(.installing)
        let installer = VZMacOSInstaller(
            virtualMachine: virtualMachine,
            restoringFromImageAt: restoreImageURL
        )
        let progressMonitor = Task { @MainActor in
            while !Task.isCancelled {
                progress(installer.progress.fractionCompleted)
                try? await Task.sleep(for: .seconds(1))
            }
        }
        defer { progressMonitor.cancel() }
        do {
            try await installer.install()
            progress(1)
            bundle = try bundle.updatingInstallationState(.stopped)
        } catch {
            bundle = try bundle.updatingInstallationState(.installFailed)
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

    public func suspend() async throws {
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
            let receipt = try makeSavedStateReceipt(stateURL: stateURL, bundle: bundle)
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
            bundle = (try? bundle.updatingInstallationState(.stopped)) ?? bundle
            if virtualMachine.state == .paused {
                try? await virtualMachine.resume()
            }
            throw error
        }
    }

    public func restoreSuspendedState() async throws {
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
        let artifact = try DoryVZMacSavedStateArtifact.load(
            from: bundle.suspendedStateURL,
            for: bundle
        )
        bundle = try bundle.updatingInstallationState(.restoring)
        do {
            try await virtualMachine.restoreMachineStateFrom(url: artifact.stateURL)
            try await virtualMachine.resume()
            try FileManager.default.removeItem(at: artifact.rootURL)
            bundle = try bundle.updatingInstallationState(.stopped)
        } catch {
            if virtualMachine.state != .running {
                bundle = (try? bundle.updatingInstallationState(.suspended)) ?? bundle
            }
            throw error
        }
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

    deinit {
        cameraBridge.remove()
    }
}
