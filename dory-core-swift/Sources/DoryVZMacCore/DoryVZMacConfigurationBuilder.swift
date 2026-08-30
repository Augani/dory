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
    public let virtualMachine: VZVirtualMachine
    public let cameraBridge: DoryVZMacCameraBridge

    public init(
        bundle: DoryVZMacMachineBundle,
        camera: DoryMacCameraBackend? = nil,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) throws {
        self.bundle = bundle
        let configuration = try DoryVZMacConfigurationBuilder.makeConfiguration(for: bundle)
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

    public func install(from restoreImageURL: URL) async throws {
        guard bundle.manifest.installationState == .prepared
                || bundle.manifest.installationState == .installFailed else {
            throw DoryVZMacMachineBundleError.invalidBundle(
                "installation requires a prepared or failed-install machine"
            )
        }
        bundle = try bundle.updatingInstallationState(.installing)
        let installer = VZMacOSInstaller(
            virtualMachine: virtualMachine,
            restoringFromImageAt: restoreImageURL
        )
        do {
            try await installer.install()
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
