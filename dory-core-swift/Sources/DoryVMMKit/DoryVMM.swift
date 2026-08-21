import Darwin
import DoryCore
import DoryOperations
import DorydKit
import Foundation
@preconcurrency import Virtualization

public enum DoryVMMBootMode: Sendable, Equatable {
    case immediateHandoff
    case virtualMachine
}

public enum DoryVMMDisplayDefaults {
    /// A 2x backing surface for the default 1280x800-point desktop window.
    public static let widthInPixels = 2_560
    public static let heightInPixels = 1_600

    public static let capability = DoryVirtualMachineDisplayCapabilityRequest(
        widthPixels: UInt32(widthInPixels),
        heightPixels: UInt32(heightInPixels)
    )
}

public struct DoryVMMArguments: Sendable, Equatable {
    public var machineID: String?
    public var operationID: UUID?
    public var stateDirectory: String?
    public var dataDriveRoot: String?
    public var kernelPath: String?
    public var rootfsPath: String?
    public var machineBootMode: DoryMachineBootMode = .linuxKernel
    public var installerISOPath: String?
    public var gvproxyPath: String?
    public var sshAgentSocketPath: String?
    public var publishHost = "127.0.0.1"
    public var bridgeSubnetCIDR = DoryIPv4BridgeNetwork.defaultCIDR
    public var handoffSocketPath: String?
    public var dockerdSocketPath: String?
    public var agentSocketPath: String?
    public var shellSocketPath: String?
    public var controlSocketPath: String?
    public var restoreStatePath: String?
    public var agentBuild = "dory-vmm/handoff-shim"
    public var detail = "helper handoff ready"
    public var memoryMB: UInt64 = 2048
    public var cpuCount: Int = 2
    public var displayMode: DoryMachineDisplayMode = .headless
    public var kernelCommandLine: String?
    public var readyTimeoutSeconds: TimeInterval = 60
    public var exitAfterHandoff = false
    public var handoffOnly = false
    public var holdSeconds: UInt32?
    public var shares: [DoryMachineShareConfiguration] = []
    public var environment: [String: String] = [:]
    public var resolvedGraphics: DoryGraphicsAccelerationLevel?
    public var resolvedDevices: DoryVirtualMachineDeviceCapabilityRequest?

    public init() {}

    public var bootMode: DoryVMMBootMode {
        if handoffOnly || exitAfterHandoff || holdSeconds != nil {
            return .immediateHandoff
        }
        return .virtualMachine
    }
}

public enum DoryVMMArgumentError: Error, Sendable, Equatable, CustomStringConvertible {
    case missingValue(String)
    case invalidInteger(String, String)
    case missingMachineID
    case missingOperationID
    case missingHandoffSocket
    case missingStateDirectory
    case missingKernel
    case missingRootfs
    case missingGVProxy
    case invalidPublishHost(String)
    case invalidDisplayMode(String)
    case invalidMachineBootMode(String)
    case invalidEnvironment(String)
    case invalidResolvedGraphics(String)
    case invalidResolvedDevices(String)
    case invalidOperationID(String)

    public var description: String {
        switch self {
        case let .missingValue(flag):
            return "missing value for \(flag)"
        case let .invalidInteger(flag, value):
            return "invalid integer for \(flag): \(value)"
        case .missingMachineID:
            return "missing --machine-id"
        case .missingOperationID:
            return "missing --operation-id"
        case .missingHandoffSocket:
            return "missing --handoff-sock"
        case .missingStateDirectory:
            return "missing --state-dir"
        case .missingKernel:
            return "missing --kernel"
        case .missingRootfs:
            return "missing --rootfs"
        case .missingGVProxy:
            return "Docker VZ fallback requires explicit --gvproxy"
        case let .invalidPublishHost(host):
            return "invalid --publish-host (expected 127.0.0.1 or 0.0.0.0): \(host)"
        case let .invalidDisplayMode(mode):
            return "invalid --display-mode (expected headless or desktop): \(mode)"
        case let .invalidMachineBootMode(mode):
            return "invalid --boot-mode (expected linux-kernel or efi): \(mode)"
        case let .invalidEnvironment(value):
            return "invalid --env value: \(value)"
        case let .invalidResolvedGraphics(value):
            return "invalid --resolved-graphics value: \(value)"
        case let .invalidResolvedDevices(value):
            return "invalid --resolved-devices value: \(value)"
        case let .invalidOperationID(value):
            return "invalid --operation-id value: \(value)"
        }
    }
}

public func parseDoryVMMArguments(_ raw: [String]) throws -> DoryVMMArguments {
    var parsed = DoryVMMArguments()
    var index = raw.startIndex
    while index < raw.endIndex {
        let argument = raw[index]
        index = raw.index(after: index)
        switch argument {
        case "--machine-id":
            parsed.machineID = try value(after: argument, from: raw, index: &index)
        case "--operation-id":
            let rawValue = try value(after: argument, from: raw, index: &index)
            guard let operationID = DoryOperationIdentity.parseCanonical(rawValue) else {
                throw DoryVMMArgumentError.invalidOperationID(rawValue)
            }
            parsed.operationID = operationID
        case "--state-dir":
            parsed.stateDirectory = try value(after: argument, from: raw, index: &index)
        case "--data-drive":
            parsed.dataDriveRoot = try value(after: argument, from: raw, index: &index)
        case "--kernel":
            parsed.kernelPath = try value(after: argument, from: raw, index: &index)
        case "--rootfs":
            parsed.rootfsPath = try value(after: argument, from: raw, index: &index)
        case "--boot-mode":
            let value = try value(after: argument, from: raw, index: &index)
            guard let mode = DoryMachineBootMode(rawValue: value) else {
                throw DoryVMMArgumentError.invalidMachineBootMode(value)
            }
            parsed.machineBootMode = mode
        case "--installer-iso":
            parsed.installerISOPath = try value(after: argument, from: raw, index: &index)
        case "--gvproxy":
            parsed.gvproxyPath = try value(after: argument, from: raw, index: &index)
        case "--ssh-agent-socket":
            parsed.sshAgentSocketPath = try value(after: argument, from: raw, index: &index)
        case "--publish-host":
            parsed.publishHost = try value(after: argument, from: raw, index: &index)
        case "--container-subnet":
            parsed.bridgeSubnetCIDR = try value(after: argument, from: raw, index: &index)
        case "--memory-mb":
            parsed.memoryMB = try uint64Value(after: argument, from: raw, index: &index)
        case "--cpus":
            parsed.cpuCount = try intValue(after: argument, from: raw, index: &index)
        case "--display-mode":
            let value = try value(after: argument, from: raw, index: &index)
            guard let mode = DoryMachineDisplayMode(rawValue: value) else {
                throw DoryVMMArgumentError.invalidDisplayMode(value)
            }
            parsed.displayMode = mode
        case "--cmdline":
            parsed.kernelCommandLine = try value(after: argument, from: raw, index: &index)
        case "--handoff-sock":
            parsed.handoffSocketPath = try value(after: argument, from: raw, index: &index)
        case "--dockerd-sock":
            parsed.dockerdSocketPath = try value(after: argument, from: raw, index: &index)
        case "--agent-sock":
            parsed.agentSocketPath = try value(after: argument, from: raw, index: &index)
        case "--shell-sock":
            parsed.shellSocketPath = try value(after: argument, from: raw, index: &index)
        case "--control-sock":
            parsed.controlSocketPath = try value(after: argument, from: raw, index: &index)
        case "--restore-state":
            parsed.restoreStatePath = try value(after: argument, from: raw, index: &index)
        case "--agent-build":
            parsed.agentBuild = try value(after: argument, from: raw, index: &index)
        case "--detail":
            parsed.detail = try value(after: argument, from: raw, index: &index)
        case "--ready-timeout-seconds":
            parsed.readyTimeoutSeconds = TimeInterval(try uint64Value(after: argument, from: raw, index: &index))
        case "--hold-seconds":
            parsed.holdSeconds = UInt32(try uint64Value(after: argument, from: raw, index: &index))
        case "--share":
            parsed.shares.append(try DoryMachineShareConfiguration(argument: value(after: argument, from: raw, index: &index)))
        case "--env":
            let rawValue = try value(after: argument, from: raw, index: &index)
            guard let equals = rawValue.firstIndex(of: "="), equals != rawValue.startIndex else {
                throw DoryVMMArgumentError.invalidEnvironment(rawValue)
            }
            let key = String(rawValue[..<equals])
            guard key.wholeMatch(of: /[A-Za-z_][A-Za-z0-9_]*/) != nil else {
                throw DoryVMMArgumentError.invalidEnvironment(key)
            }
            parsed.environment[key] = String(rawValue[rawValue.index(after: equals)...])
        case "--resolved-graphics":
            let rawValue = try value(after: argument, from: raw, index: &index)
            guard let graphics = DoryGraphicsAccelerationLevel(rawValue: rawValue) else {
                throw DoryVMMArgumentError.invalidResolvedGraphics(rawValue)
            }
            parsed.resolvedGraphics = graphics
        case "--resolved-devices":
            let rawValue = try value(after: argument, from: raw, index: &index)
            do {
                parsed.resolvedDevices = try JSONDecoder().decode(
                    DoryVirtualMachineDeviceCapabilityRequest.self,
                    from: Data(rawValue.utf8)
                )
            } catch {
                throw DoryVMMArgumentError.invalidResolvedDevices(rawValue)
            }
        case "--exit-after-handoff":
            parsed.exitAfterHandoff = true
        case "--handoff-only":
            parsed.handoffOnly = true
        default:
            break
        }
    }
    return parsed
}

private func value(after flag: String, from raw: [String], index: inout Array<String>.Index) throws -> String {
    guard index < raw.endIndex else {
        throw DoryVMMArgumentError.missingValue(flag)
    }
    let value = raw[index]
    index = raw.index(after: index)
    return value
}

private func uint64Value(after flag: String, from raw: [String], index: inout Array<String>.Index) throws -> UInt64 {
    let rawValue = try value(after: flag, from: raw, index: &index)
    guard let value = UInt64(rawValue) else {
        throw DoryVMMArgumentError.invalidInteger(flag, rawValue)
    }
    return value
}

private func intValue(after flag: String, from raw: [String], index: inout Array<String>.Index) throws -> Int {
    let rawValue = try value(after: flag, from: raw, index: &index)
    guard let value = Int(rawValue) else {
        throw DoryVMMArgumentError.invalidInteger(flag, rawValue)
    }
    return value
}

public struct DoryVZMachineSpec: Sendable, Equatable {
    public var machineID: String
    public var operationID: UUID?
    public var stateDirectory: String
    public var kernelPath: String
    public var rootfsPath: String
    public var bootMode: DoryMachineBootMode
    public var installerISOPath: String?
    public var memoryMB: UInt64
    public var cpuCount: Int
    public var displayMode: DoryMachineDisplayMode
    public var kernelCommandLine: String?
    public var shares: [DoryMachineShareConfiguration]
    public var environment: [String: String]
    public var resolvedGraphics: DoryGraphicsAccelerationLevel?
    public var resolvedDevices: DoryVirtualMachineDeviceCapabilityRequest?
    public var dockerDataDiskPath: String?
    public var nativeIPv6: Bool
    public var sourcePreservingLAN: Bool
    public var bridgeSubnetCIDR: String

    public init(
        machineID: String,
        operationID: UUID? = nil,
        stateDirectory: String,
        kernelPath: String,
        rootfsPath: String,
        bootMode: DoryMachineBootMode = .linuxKernel,
        installerISOPath: String? = nil,
        memoryMB: UInt64,
        cpuCount: Int,
        displayMode: DoryMachineDisplayMode = .headless,
        kernelCommandLine: String? = nil,
        shares: [DoryMachineShareConfiguration] = [],
        environment: [String: String] = [:],
        resolvedGraphics: DoryGraphicsAccelerationLevel? = nil,
        resolvedDevices: DoryVirtualMachineDeviceCapabilityRequest? = nil,
        dockerDataDiskPath: String? = nil,
        nativeIPv6: Bool = false,
        sourcePreservingLAN: Bool = false,
        bridgeSubnetCIDR: String = DoryIPv4BridgeNetwork.defaultCIDR
    ) {
        self.machineID = machineID
        self.operationID = operationID
        self.stateDirectory = stateDirectory
        self.kernelPath = kernelPath
        self.rootfsPath = rootfsPath
        self.bootMode = bootMode
        self.installerISOPath = installerISOPath
        self.memoryMB = memoryMB
        self.cpuCount = cpuCount
        self.displayMode = displayMode
        self.kernelCommandLine = kernelCommandLine
        self.shares = shares
        self.environment = environment
        self.resolvedGraphics = resolvedGraphics
        self.resolvedDevices = resolvedDevices
        self.dockerDataDiskPath = dockerDataDiskPath
        self.nativeIPv6 = nativeIPv6
        self.sourcePreservingLAN = sourcePreservingLAN
        self.bridgeSubnetCIDR = bridgeSubnetCIDR
    }
}

public enum DoryVZMachineError: Error, Sendable, CustomStringConvertible {
    case missingFile(String)
    case storageAttachment(String)
    case validation(String)
    case missingSocketDevice
    case missingMemoryBalloonDevice
    case guestPortUnavailable(UInt32)
    case guestStoppedBeforePort(UInt32)
    case stoppedWithError(String)
    case syscall(String, Int32)

    public var description: String {
        switch self {
        case let .missingFile(path):
            return "required VM file is missing: \(path)"
        case let .storageAttachment(message):
            return "rootfs storage attachment failed: \(message)"
        case let .validation(message):
            return "VZ VM configuration is invalid: \(message)"
        case .missingSocketDevice:
            return "VZ VM did not expose a virtio socket device"
        case .missingMemoryBalloonDevice:
            return "VZ VM did not expose a memory balloon device"
        case let .guestPortUnavailable(port):
            return "guest vsock port did not become reachable: \(port)"
        case let .guestStoppedBeforePort(port):
            return "guest stopped before vsock port \(port) became reachable"
        case let .stoppedWithError(message):
            return "virtual machine stopped with an error: \(message)"
        case let .syscall(name, code):
            return "\(name): \(String(cString: strerror(code)))"
        }
    }
}

public enum DoryVZConfigurationBuilder {
    private static let bootConfigTag = "dorycfg"
    private static let bootConfigGuestPath = "/mnt/dory-config"

    public static func makeConfiguration(
        spec: DoryVZMachineSpec,
        serialOutput: FileHandle?,
        serialInput: FileHandle? = nil,
        networkAttachment: VZNetworkDeviceAttachment? = nil
    ) throws -> VZVirtualMachineConfiguration {
        let fileManager = FileManager.default
        let (memorySize, memoryOverflow) = spec.memoryMB.multipliedReportingOverflow(by: 1024 * 1024)
        let minimumMemorySize = VZVirtualMachineConfiguration.minimumAllowedMemorySize
        let maximumMemorySize = VZVirtualMachineConfiguration.maximumAllowedMemorySize
        guard !memoryOverflow,
              (minimumMemorySize...maximumMemorySize).contains(memorySize) else {
            throw DoryVZMachineError.validation("unsupported memoryMB: \(spec.memoryMB)")
        }
        let minimumCPUCount = Int(VZVirtualMachineConfiguration.minimumAllowedCPUCount)
        let maximumCPUCount = Int(VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        guard (minimumCPUCount...maximumCPUCount).contains(spec.cpuCount) else {
            throw DoryVZMachineError.validation("unsupported cpuCount: \(spec.cpuCount)")
        }
        if spec.nativeIPv6, networkAttachment == nil {
            throw DoryVZMachineError.validation(
                "native IPv6 requires the gvproxy file-handle network attachment"
            )
        }
        guard fileManager.fileExists(atPath: spec.rootfsPath) else {
            throw DoryVZMachineError.missingFile(spec.rootfsPath)
        }

        if let graphics = spec.resolvedGraphics {
            let expected: DoryGraphicsAccelerationLevel = spec.displayMode == .desktop
                ? .hostAcceleratedDisplay : .none
            guard graphics == expected else {
                throw DoryVZMachineError.validation(
                    "resolved graphics \(graphics.rawValue) cannot be represented by this VZ launch"
                )
            }
        }
        if let devices = spec.resolvedDevices {
            if let networkInterface = devices.networkInterface,
               !networkInterface.isValid {
                throw DoryVZMachineError.validation(
                    "resolved network interface identity or MTU is invalid"
                )
            }
            guard devices.networkAttachment == .sharedNAT
                    || devices.networkAttachment == .isolated
                    || devices.networkAttachment == .disconnected else {
                throw DoryVZMachineError.validation(
                    "resolved device contract contains a device not implemented by this VZ launch"
                )
            }
            if devices.networkAttachment == .disconnected,
               networkAttachment != nil || spec.nativeIPv6 {
                throw DoryVZMachineError.validation(
                    "disconnected networking cannot attach a host network backend"
                )
            }
            if devices.networkAttachment == .isolated,
               !(networkAttachment is VZFileHandleNetworkDeviceAttachment) || !spec.nativeIPv6 {
                throw DoryVZMachineError.validation(
                    "host-only networking requires the restricted gvproxy attachment"
                )
            }
            guard devices.directorySharing == !spec.shares.isEmpty else {
                throw DoryVZMachineError.validation(
                    "resolved directory-sharing contract does not match the launch shares"
                )
            }
            if spec.displayMode != .desktop,
               devices.display != nil || devices.audioInput || devices.audioOutput || devices.keyboard
                    || devices.pointer || devices.clipboard {
                throw DoryVZMachineError.validation(
                    "resolved desktop devices cannot be attached to a headless VZ launch"
                )
            }
        }

        let configuration = VZVirtualMachineConfiguration()
        switch spec.bootMode {
        case .linuxKernel:
            guard fileManager.fileExists(atPath: spec.kernelPath) else {
                throw DoryVZMachineError.missingFile(spec.kernelPath)
            }
            let bootLoader = VZLinuxBootLoader(kernelURL: URL(fileURLWithPath: spec.kernelPath))
            bootLoader.commandLine = spec.kernelCommandLine ?? defaultKernelCommandLine(
                machineID: spec.machineID,
                operationID: spec.operationID
            )
            configuration.bootLoader = bootLoader
        case .efi:
            guard spec.displayMode == .desktop else {
                throw DoryVZMachineError.validation("EFI boot requires desktop display mode")
            }
            let platform = VZGenericPlatformConfiguration()
            platform.machineIdentifier = try persistentMachineIdentifier(
                at: spec.stateDirectory + "/MachineIdentifier"
            )
            let bootLoader = VZEFIBootLoader()
            // Keep installation/recovery firmware state separate from the installed system.
            // UEFI remembers the disk as its first boot target after an OS installation, and
            // merely reconnecting a USB ISO does not override that persisted BootOrder. A
            // dedicated installer variable store gives attached media a stable CD-first boot
            // profile while preserving the installed disk's firmware entries for normal boots.
            let variableStoreName = spec.installerISOPath == nil ? "NVRAM" : "NVRAM.installer"
            bootLoader.variableStore = try persistentEFIVariableStore(
                at: spec.stateDirectory + "/\(variableStoreName)"
            )
            configuration.platform = platform
            configuration.bootLoader = bootLoader
        }
        configuration.cpuCount = spec.cpuCount
        configuration.memorySize = memorySize
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        configuration.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
        configuration.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        let network = VZVirtioNetworkDeviceConfiguration()
        if spec.resolvedDevices?.networkAttachment != .disconnected {
            network.attachment = networkAttachment ?? VZNATNetworkDeviceAttachment()
        }
        let macAddressString = spec.resolvedDevices?.networkInterface?.macAddress
            ?? (networkAttachment != nil
                ? DoryVMMNativeIPv6Plan.guestMAC
                : stableNetworkMACAddress(machineID: spec.machineID))
        guard let macAddress = VZMACAddress(string: macAddressString) else {
            throw DoryVZMachineError.validation("could not derive stable network identity")
        }
        network.macAddress = macAddress
        configuration.networkDevices = [network]

        if spec.displayMode == .desktop {
            let devices = spec.resolvedDevices
            let display = devices?.display ?? DoryVMMDisplayDefaults.capability
            guard display.isValid else {
                throw DoryVZMachineError.validation(
                    "resolved display geometry is outside the supported pixel bounds"
                )
            }
            let graphics = VZVirtioGraphicsDeviceConfiguration()
            graphics.scanouts = [VZVirtioGraphicsScanoutConfiguration(
                widthInPixels: Int(display.widthPixels),
                heightInPixels: Int(display.heightPixels)
            )]
            configuration.graphicsDevices = [graphics]
            if devices?.keyboard != false {
                configuration.keyboards = [VZUSBKeyboardConfiguration()]
            }
            if devices?.pointer != false {
                configuration.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
            }

            var audioDevices = [VZVirtioSoundDeviceConfiguration]()
            if devices?.audioOutput != false {
                let output = VZVirtioSoundDeviceOutputStreamConfiguration()
                output.sink = VZHostAudioOutputStreamSink()
                let outputSound = VZVirtioSoundDeviceConfiguration()
                outputSound.streams = [output]
                audioDevices.append(outputSound)
            }
            if devices?.audioInput != false {
                let input = VZVirtioSoundDeviceInputStreamConfiguration()
                input.source = VZHostAudioInputStreamSource()
                let inputSound = VZVirtioSoundDeviceConfiguration()
                inputSound.streams = [input]
                audioDevices.append(inputSound)
            }
            configuration.audioDevices = audioDevices

            if devices?.clipboard != false {
                let console = VZVirtioConsoleDeviceConfiguration()
                let spiceAgent = VZVirtioConsolePortConfiguration()
                spiceAgent.name = VZSpiceAgentPortAttachment.spiceAgentPortName
                let spiceAttachment = VZSpiceAgentPortAttachment()
                // The native SPICE bridge has only an all-or-nothing switch. Keep it for the efficient
                // bidirectional default; directional policies use Dory's agent-backed bridge instead.
                spiceAttachment.sharesClipboard = DoryDesktopClipboardPolicy(
                    environment: spec.environment
                ) == .bidirectional
                spiceAgent.attachment = spiceAttachment
                console.ports[0] = spiceAgent
                configuration.consoleDevices = [console]
            }
        }

        var dockerDataDiskPath: String?
        var allowDockerDataFormat = false
        if spec.machineID == "docker" {
            let dataDisk = spec.dockerDataDiskPath ?? (spec.stateDirectory + "/docker-data.ext4")
            let preparation: DockerDataDiskPreparation
            do {
                preparation = try DockerDataDisk.prepare(destination: dataDisk)
            } catch {
                throw DoryVZMachineError.storageAttachment("Docker data disk: \(error)")
            }
            switch preparation {
            case .createdBlank:
                allowDockerDataFormat = true
            case .alreadyPresent:
                allowDockerDataFormat = try !DockerDataDisk.isExt4Image(at: dataDisk)
            }
            dockerDataDiskPath = dataDisk
        }

        let directoryShares: [DoryMachineShareConfiguration]
        if spec.displayMode == .desktop {
            guard !spec.shares.contains(where: { $0.tag == bootConfigTag }) else {
                throw DoryVZMachineError.validation("machine share tag '\(bootConfigTag)' is reserved")
            }
            directoryShares = spec.shares
        } else {
            let bootConfigShare = try prepareBootConfigShare(
                spec: spec,
                allowDockerDataFormat: allowDockerDataFormat
            )
            directoryShares = [bootConfigShare] + spec.shares
        }
        let attachedDirectoryShares = spec.resolvedDevices?.directorySharing == false
            ? directoryShares.filter { $0.tag == bootConfigTag }
            : directoryShares
        configuration.directorySharingDevices = try attachedDirectoryShares.map { share in
            try share.validate()
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: share.hostPath, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw DoryVZMachineError.missingFile(share.hostPath)
            }
            do {
                try VZVirtioFileSystemDeviceConfiguration.validateTag(share.tag)
            } catch {
                throw DoryVZMachineError.validation("\(error)")
            }
            let directory = VZSharedDirectory(
                url: URL(fileURLWithPath: share.hostPath, isDirectory: true),
                readOnly: share.readOnly
            )
            let shareConfig = VZSingleDirectoryShare(directory: directory)
            let device = VZVirtioFileSystemDeviceConfiguration(tag: share.tag)
            device.share = shareConfig
            return device
        }

        do {
            let rootURL = URL(fileURLWithPath: spec.rootfsPath)
            if spec.bootMode == .efi {
                // EFI installers exercise long, flush-heavy writes before Dory guest tools exist.
                // Apple's native NVMe model avoids tying that workload to the VirtIO-block path
                // used by Dory-owned direct-kernel guests. Cached host I/O with fsync semantics
                // matches a normal virtual disk while retaining crash-consistent guest flushes.
                let attachment = try VZDiskImageStorageDeviceAttachment(
                    url: rootURL,
                    readOnly: false,
                    cachingMode: .cached,
                    synchronizationMode: .fsync
                )
                configuration.storageDevices = [
                    VZNVMExpressControllerDeviceConfiguration(attachment: attachment),
                ]
            } else {
                let attachment = try VZDiskImageStorageDeviceAttachment(
                    url: rootURL,
                    readOnly: false
                )
                let block = VZVirtioBlockDeviceConfiguration(attachment: attachment)
                block.blockDeviceIdentifier = "dory-rootfs"
                configuration.storageDevices = [block]
            }
            if let installerISOPath = spec.installerISOPath {
                guard spec.bootMode == .efi else {
                    throw DoryVZMachineError.validation("installer ISO requires EFI boot mode")
                }
                guard fileManager.fileExists(atPath: installerISOPath) else {
                    throw DoryVZMachineError.missingFile(installerISOPath)
                }
                let installerAttachment = try VZDiskImageStorageDeviceAttachment(
                    url: URL(fileURLWithPath: installerISOPath),
                    readOnly: true
                )
                configuration.storageDevices.insert(
                    VZUSBMassStorageDeviceConfiguration(attachment: installerAttachment),
                    at: 0
                )
            }
        } catch {
            if let error = error as? DoryVZMachineError { throw error }
            throw DoryVZMachineError.storageAttachment("\(error)")
        }

        if let dataDisk = dockerDataDiskPath {
            do {
                let attachment = try VZDiskImageStorageDeviceAttachment(
                    url: URL(fileURLWithPath: dataDisk),
                    readOnly: false
                )
                let block = VZVirtioBlockDeviceConfiguration(attachment: attachment)
                block.blockDeviceIdentifier = "dory-data"
                configuration.storageDevices.append(block)
            } catch {
                throw DoryVZMachineError.storageAttachment("Docker data disk: \(error)")
            }
        }

        if let serialOutput {
            let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
            serial.attachment = VZFileHandleSerialPortAttachment(
                fileHandleForReading: serialInput,
                fileHandleForWriting: serialOutput
            )
            configuration.serialPorts = [serial]
        }

        return configuration
    }

    static func stableNetworkMACAddress(machineID: String) -> String {
        // FNV-1a provides a deterministic identity without introducing a cryptographic trust
        // claim. Set the locally administered bit and clear multicast.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in machineID.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3
        }
        var bytes = (0..<6).map { UInt8(truncatingIfNeeded: hash >> UInt64($0 * 8)) }
        bytes[0] = (bytes[0] | 0x02) & 0xFE
        return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    private static func persistentMachineIdentifier(at path: String) throws -> VZGenericMachineIdentifier {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            let data = try Data(contentsOf: url)
            guard let identifier = VZGenericMachineIdentifier(dataRepresentation: data) else {
                throw DoryVZMachineError.validation("stored EFI machine identifier is invalid")
            }
            return identifier
        }
        let identifier = VZGenericMachineIdentifier()
        try identifier.dataRepresentation.write(to: url, options: [.atomic])
        guard chmod(path, mode_t(0o600)) == 0 else {
            throw DoryVZMachineError.syscall("chmod MachineIdentifier", errno)
        }
        return identifier
    }

    private static func persistentEFIVariableStore(at path: String) throws -> VZEFIVariableStore {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            return VZEFIVariableStore(url: url)
        }
        let store = try VZEFIVariableStore(creatingVariableStoreAt: url)
        guard chmod(path, mode_t(0o600)) == 0 else {
            throw DoryVZMachineError.syscall("chmod NVRAM", errno)
        }
        return store
    }

    public static func defaultKernelCommandLine(
        machineID: String,
        operationID: UUID? = nil
    ) -> String {
        var arguments = [
            "console=hvc0", "root=/dev/vda", "rw", "rootwait", "panic=1",
            "dory.machine_id=\(machineID)",
        ]
        if let operationID {
            arguments.append("dory.operation_id=\(DoryOperationIdentity.canonical(operationID))")
        }
        return arguments.joined(separator: " ")
    }

    private static func prepareBootConfigShare(
        spec: DoryVZMachineSpec,
        allowDockerDataFormat: Bool
    ) throws -> DoryMachineShareConfiguration {
        guard !spec.shares.contains(where: { $0.tag == bootConfigTag }) else {
            throw DoryVZMachineError.validation("machine share tag '\(bootConfigTag)' is reserved")
        }
        let directory = "\(spec.stateDirectory)/\(bootConfigTag)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let script = guestBootScript(
            shares: spec.shares,
            environment: spec.environment,
            operationID: spec.operationID,
            allowDockerDataFormat: allowDockerDataFormat,
            nativeIPv6: spec.nativeIPv6,
            sourcePreservingLAN: spec.sourcePreservingLAN,
            bridgeNetwork: try DoryIPv4BridgeNetwork(spec.bridgeSubnetCIDR)
        )
        try script.write(
            to: URL(fileURLWithPath: "\(directory)/boot.sh"),
            atomically: true,
            encoding: .utf8
        )
        return DoryMachineShareConfiguration(
            tag: bootConfigTag,
            hostPath: directory,
            guestPath: bootConfigGuestPath,
            readOnly: true
        )
    }

    private static func guestBootScript(
        shares: [DoryMachineShareConfiguration],
        environment: [String: String],
        operationID: UUID?,
        allowDockerDataFormat: Bool,
        nativeIPv6: Bool,
        sourcePreservingLAN: Bool,
        bridgeNetwork: DoryIPv4BridgeNetwork
    ) -> String {
        var lines = [
            "#!/bin/sh",
            "export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            "",
            "mountpoint() {",
            "  grep -q \" $1 \" /proc/mounts 2>/dev/null",
            "}",
            "",
            "mkdir -p /proc /sys /dev /dev/pts /run /tmp /var/log /var/run /var/lib/docker",
            "mountpoint /proc || mount -t proc proc /proc 2>/dev/null || true",
            "mountpoint /sys || mount -t sysfs sys /sys 2>/dev/null || true",
            "mountpoint /dev || mount -t devtmpfs devtmpfs /dev 2>/dev/null || true",
            "mountpoint /dev/pts || mount -t devpts devpts /dev/pts 2>/dev/null || true",
            "mountpoint /run || mount -t tmpfs tmpfs /run 2>/dev/null || true",
            "mountpoint /tmp || mount -t tmpfs tmpfs /tmp 2>/dev/null || true",
            "mkdir -p /sys/fs/cgroup",
            "mountpoint /sys/fs/cgroup || mount -t cgroup2 none /sys/fs/cgroup 2>/dev/null || true",
            GuestContainerCompatibilityCommand.configureKernel(),
            "",
            ": > /var/log/dory-mounts.log",
        ]
        if let operationID {
            let token = DoryOperationIdentity.canonical(operationID)
            lines += [
                "mkdir -p /run/dory",
                "chmod 700 /run/dory",
                "printf '%s\\n' \(shellQuote(token)) > /run/dory/operation-id",
                "chmod 600 /run/dory/operation-id",
                "export DORY_OPERATION_ID=\(shellQuote(token))",
                "",
            ]
        }
        for (key, value) in environment.sorted(by: { $0.key < $1.key }) {
            guard key.wholeMatch(of: /[A-Za-z_][A-Za-z0-9_]*/) != nil else { continue }
            lines.append("export \(key)=\(shellQuote(value))")
        }
        if !environment.isEmpty {
            lines.append("")
        }
        lines += [
            "if [ -x /usr/lib/dory/configure-machine ]; then",
            "  /usr/lib/dory/configure-machine",
            "fi",
            "",
        ]
        for share in shares {
            let options = share.readOnly ? "ro" : "rw"
            lines.append("mkdir -p \(shellQuote(share.guestPath))")
            lines.append(
                "if mountpoint \(shellQuote(share.guestPath)); then " +
                "echo \(shellQuote("DORY: \(share.tag) already mounted at \(share.guestPath)")) >>/var/log/dory-mounts.log; " +
                "elif mount -t virtiofs -o \(shellQuote(options)) \(shellQuote(share.tag)) \(shellQuote(share.guestPath)) 2>>/var/log/dory-mounts.log; then " +
                "echo \(shellQuote("DORY: mounted \(share.tag) at \(share.guestPath)")) >>/var/log/dory-mounts.log; " +
                "else echo \(shellQuote("DORY: failed to mount \(share.tag) at \(share.guestPath)")) >>/var/log/dory-mounts.log; fi"
            )
        }
        lines += [
            "",
            "ip link set lo up 2>/dev/null || true",
            "if ip link show eth0 >/dev/null 2>&1; then",
            "  ip link set eth0 up 2>/dev/null || true",
            "  udhcpc -i eth0 -q -n -t 5 -T 1 >/dev/null 2>&1 || true",
        ]
        if nativeIPv6 {
            lines.append(contentsOf: DoryVMMNativeIPv6Plan().guestSetupCommands.map { "  \($0)" })
        }
        if sourcePreservingLAN {
            lines.append(contentsOf: SourcePreservingLANPlan.guestSetupCommands(bridgeNetwork: bridgeNetwork).map { "  \($0)" })
        }
        lines += [
            "fi",
            "",
            "if [ -b /dev/vdb ]; then",
            "  DORY_ALLOW_DATA_FORMAT=\(allowDockerDataFormat ? 1 : 0)",
            "  if blkid /dev/vdb 2>/dev/null | grep -q 'TYPE=\"ext4\"'; then",
            "    DORY_DATA_DEVICE_BYTES=$(blockdev --getsize64 /dev/vdb 2>/dev/null || true)",
            "    DORY_DATA_GEOMETRY=$(dumpe2fs -h /dev/vdb 2>/dev/null | awk '/^Block count:/{blocks=$3} /^Block size:/{size=$3} END{if(blocks && size) print blocks, size}')",
            "    set -- $DORY_DATA_GEOMETRY",
            "    DORY_DATA_FS_BLOCKS=${1:-}; DORY_DATA_FS_BLOCK_SIZE=${2:-}",
            "    DORY_DATA_GEOMETRY_VALID=1",
            "    case \"$DORY_DATA_DEVICE_BYTES\" in ''|*[!0-9]*) DORY_DATA_GEOMETRY_VALID=0;; esac",
            "    case \"$DORY_DATA_FS_BLOCKS\" in ''|*[!0-9]*) DORY_DATA_GEOMETRY_VALID=0;; esac",
            "    case \"$DORY_DATA_FS_BLOCK_SIZE\" in ''|*[!0-9]*) DORY_DATA_GEOMETRY_VALID=0;; esac",
            "    if [ \"$DORY_DATA_GEOMETRY_VALID\" -ne 1 ]; then",
            "      echo \"DORY: could not read /dev/vdb ext4 geometry\" >/var/log/dory-data-resize.log",
            "      DORY_DATA_GROW_STATUS=2",
            "    else",
            "      DORY_DATA_FS_BYTES=$((DORY_DATA_FS_BLOCKS * DORY_DATA_FS_BLOCK_SIZE))",
            "      if [ \"$DORY_DATA_FS_BYTES\" -gt \"$DORY_DATA_DEVICE_BYTES\" ]; then",
            "        echo \"DORY: /dev/vdb ext4 geometry exceeds its block device\" >/var/log/dory-data-resize.log",
            "        DORY_DATA_GROW_STATUS=2",
            "      elif [ $((DORY_DATA_FS_BYTES + DORY_DATA_FS_BLOCK_SIZE)) -gt \"$DORY_DATA_DEVICE_BYTES\" ]; then",
            "        echo \"DORY: /dev/vdb ext4 already spans its block device\" >/var/log/dory-data-resize.log",
            "        DORY_DATA_GROW_STATUS=0",
            "      else",
            // A clean flag alone is insufficient after ext4 has been mounted since its last check;
            // resize2fs refuses growth until a forced offline preen completes.
            "        echo e2fsck_mode=forced-preen >/var/log/dory-data-resize.log",
            "        e2fsck -f -p /dev/vdb >>/var/log/dory-data-resize.log 2>&1",
            "        DORY_E2FSCK_STATUS=$?",
            "        if [ \"$DORY_E2FSCK_STATUS\" -gt 1 ] || ! resize2fs /dev/vdb >>/var/log/dory-data-resize.log 2>&1; then DORY_DATA_GROW_STATUS=2; else DORY_DATA_GROW_STATUS=0; fi",
            "      fi",
            "    fi",
            "    if [ \"$DORY_DATA_GROW_STATUS\" -ne 0 ]; then",
            "      echo \"DORY: failed to grow /dev/vdb\"",
            "      cat /var/log/dory-data-resize.log 2>/dev/null || true",
            "      sync",
            "      poweroff -f",
            "      exit 1",
            "    fi",
            "    DORY_DOCKER_MOUNT_OPTS=noatime,lazytime,commit=30",
            "    DORY_DOCKER_MOUNT_FALLBACK_OPTS=noatime,commit=30",
            "    mount -t ext4 -o \"$DORY_DOCKER_MOUNT_OPTS\" /dev/vdb /var/lib/docker || mount -t ext4 -o \"$DORY_DOCKER_MOUNT_FALLBACK_OPTS\" /dev/vdb /var/lib/docker || mount -t ext4 /dev/vdb /var/lib/docker || { echo DORY-DATA-DISK-MOUNT-FAILED-EXISTING-EXT4; sync; poweroff -f; exit 1; }",
            "  elif [ \"$DORY_ALLOW_DATA_FORMAT\" -eq 1 ]; then",
            "    echo DORY-DATA-DISK-FORMAT-PROVEN-BLANK",
            "    (mkfs.ext4 -F -O fast_commit /dev/vdb >/var/log/dory-data-mkfs.log 2>&1 || mkfs.ext4 -F /dev/vdb >>/var/log/dory-data-mkfs.log 2>&1) && mount -t ext4 /dev/vdb /var/lib/docker || { echo DORY-DATA-DISK-FORMAT-OR-MOUNT-FAILED; sync; poweroff -f; exit 1; }",
            "  else",
            "    echo DORY-DATA-DISK-UNKNOWN-FILESYSTEM-REFUSING-FORMAT",
            "    sync; poweroff -f; exit 1",
            "  fi",
            "  fstrim -v /var/lib/docker >/var/log/dory-data-trim.log 2>&1 || true",
            "fi",
            "",
            "if [ -x /usr/local/bin/dockerd ]; then",
            "  \(GuestBuildCacheGCCommand.configureDaemon())",
            "  cat >/run/dory-restart-dockerd <<'DORY_DOCKERD_SCRIPT'",
            "#!/bin/sh",
            "echo +memory >/sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true",
            "mkdir -p /sys/fs/cgroup/dory-dockerd 2>/dev/null || true",
            "if [ -w /sys/fs/cgroup/dory-dockerd/cgroup.procs ]; then echo $$ >/sys/fs/cgroup/dory-dockerd/cgroup.procs || true; fi",
            "exec /usr/local/bin/dockerd -H unix:///var/run/docker.sock \(bridgeNetwork.dockerDaemonArguments) \(nativeIPv6 ? DoryVMMNativeIPv6Plan().dockerDaemonArguments : "")",
            "DORY_DOCKERD_SCRIPT",
            "  chmod 0700 /run/dory-restart-dockerd",
            "  /run/dory-restart-dockerd >/var/log/dockerd.log 2>&1 &",
            "fi",
            "",
            GuestStorageReclaimCommand.periodicLoop(),
            "",
            GuestShutdownCommand.listener(),
            "",
            "if [ -x /usr/bin/dory-agent ]; then",
            "  exec /usr/bin/dory-agent >/var/log/dory-agent.log 2>&1",
            "fi",
            "",
            "if [ -x /usr/local/bin/docker-init ]; then",
            "  exec /usr/local/bin/docker-init -s -- sleep 2147483647",
            "fi",
            "",
            "while true; do sleep 2147483647; done",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

}

public enum DoryVMMMain {
    public static func run(_ rawArguments: [String] = Array(CommandLine.arguments.dropFirst())) -> Int32 {
        do {
            let arguments = try parseDoryVMMArguments(rawArguments)
            try run(arguments)
            return 0
        } catch {
            FileHandle.standardError.write(Data("dory-vmm: \(error)\n".utf8))
            return 2
        }
    }

    public static func run(_ arguments: DoryVMMArguments) throws {
        guard let machineID = arguments.machineID else {
            throw DoryVMMArgumentError.missingMachineID
        }
        guard let operationID = arguments.operationID else {
            throw DoryVMMArgumentError.missingOperationID
        }
        guard let handoffSocketPath = arguments.handoffSocketPath else {
            throw DoryVMMArgumentError.missingHandoffSocket
        }

        var shutdownCoordinator: DoryVMMShutdownCoordinator?
        defer { shutdownCoordinator?.cancelSignalHandlers() }
        var runtime: DoryVMMRuntime?
        switch arguments.bootMode {
        case .immediateHandoff:
            try sendHandoff(
                machineID: machineID,
                operationID: operationID,
                handoffSocketPath: handoffSocketPath,
                agentBuild: arguments.agentBuild,
                agentSocketPath: arguments.agentSocketPath,
                dockerdSocketPath: arguments.dockerdSocketPath,
                shellSocketPath: arguments.shellSocketPath,
                controlSocketPath: arguments.controlSocketPath,
                detail: arguments.detail
            )
        case .virtualMachine:
            guard let stateDirectory = arguments.stateDirectory else {
                throw DoryVMMArgumentError.missingStateDirectory
            }
            let stateDirectoryLock = try EngineStateDirectoryLock(stateDirectory: stateDirectory)
            defer { withExtendedLifetime(stateDirectoryLock) {} }
            let dataDriveLock: EngineStateDirectoryLock?
            if let dataDriveRoot = arguments.dataDriveRoot, machineID == "docker" {
                let drive = try DoryDataDrive(overrideRoot: dataDriveRoot)
                try drive.prepare()
                dataDriveLock = try EngineStateDirectoryLock(
                    stateDirectory: drive.root,
                    lockFileName: "drive.lock"
                )
            } else {
                dataDriveLock = nil
            }
            defer { withExtendedLifetime(dataDriveLock) {} }
            guard let kernelPath = arguments.kernelPath else {
                throw DoryVMMArgumentError.missingKernel
            }
            guard let rootfsPath = arguments.rootfsPath else {
                throw DoryVMMArgumentError.missingRootfs
            }
            let coordinator = DoryVMMShutdownCoordinator()
            coordinator.installSignalHandlers()
            shutdownCoordinator = coordinator
            runtime = try runVirtualMachine(
                machineID: machineID,
                operationID: operationID,
                stateDirectory: stateDirectory,
                kernelPath: kernelPath,
                rootfsPath: rootfsPath,
                bootMode: arguments.machineBootMode,
                installerISOPath: arguments.installerISOPath,
                handoffSocketPath: handoffSocketPath,
                dockerdSocketPath: arguments.dockerdSocketPath ?? "\(stateDirectory)/dockerd.sock",
                agentSocketPath: arguments.agentSocketPath ?? "\(stateDirectory)/agent.sock",
                shellSocketPath: arguments.shellSocketPath ?? "\(stateDirectory)/shell.sock",
                controlSocketPath: arguments.controlSocketPath ?? "\(stateDirectory)/control.sock",
                memoryMB: arguments.memoryMB,
                cpuCount: arguments.cpuCount,
                displayMode: arguments.displayMode,
                kernelCommandLine: arguments.kernelCommandLine,
                readyTimeoutSeconds: arguments.readyTimeoutSeconds,
                shares: arguments.shares,
                environment: arguments.environment,
                resolvedGraphics: arguments.resolvedGraphics,
                resolvedDevices: arguments.resolvedDevices,
                gvproxyPath: arguments.gvproxyPath,
                sshAgentSocketPath: arguments.sshAgentSocketPath,
                publishHost: arguments.publishHost,
                bridgeSubnetCIDR: arguments.bridgeSubnetCIDR,
                dataDriveRoot: arguments.dataDriveRoot,
                restoreStatePath: arguments.restoreStatePath,
                onRuntimeCreated: { coordinator.attach($0) }
            )
        }

        if arguments.exitAfterHandoff {
            return
        }
        if let holdSeconds = arguments.holdSeconds {
            _ = withExtendedLifetime(runtime) {
                sleep(holdSeconds)
            }
            return
        }
        if let runtime {
            try withExtendedLifetime(shutdownCoordinator) {
                if arguments.displayMode == .desktop {
                    guard Thread.isMainThread else {
                        throw DoryVZMachineError.validation(
                            "desktop display must run on the dory-vmm main thread"
                        )
                    }
                    try MainActor.assumeIsolated {
                        try DoryVMMDesktopApplication.run(
                            runtime: runtime,
                            machineID: machineID,
                            environment: arguments.environment,
                            resolvedDevices: arguments.resolvedDevices
                        )
                    }
                } else {
                    try runtime.waitUntilStopped()
                }
            }
        } else {
            while true {
                pause()
            }
        }
    }

    private static func sendHandoff(
        machineID: String,
        operationID: UUID,
        handoffSocketPath: String,
        agentBuild: String?,
        agentProtocolVersion: UInt32? = nil,
        agentCapabilities: [DoryAgentCapability] = [],
        agentSocketPath: String?,
        dockerdSocketPath: String?,
        shellSocketPath: String?,
        controlSocketPath: String?,
        detail: String?
    ) throws {
        try VmmHandoffClient.send(
            path: handoffSocketPath,
            ready: VmmReadyMessage(
                machineID: machineID,
                operationID: DoryOperationIdentity.canonical(operationID),
                agentBuild: agentBuild,
                agentProtocolVersion: agentProtocolVersion,
                agentCapabilities: agentCapabilities,
                agentSocketPath: agentSocketPath,
                dockerdSocketPath: dockerdSocketPath,
                shellSocketPath: shellSocketPath,
                controlSocketPath: controlSocketPath,
                detail: detail
            )
        )
    }

    private static func runVirtualMachine(
        machineID: String,
        operationID: UUID,
        stateDirectory: String,
        kernelPath: String,
        rootfsPath: String,
        bootMode: DoryMachineBootMode,
        installerISOPath: String?,
        handoffSocketPath: String,
        dockerdSocketPath: String,
        agentSocketPath: String,
        shellSocketPath: String,
        controlSocketPath: String,
        memoryMB: UInt64,
        cpuCount: Int,
        displayMode: DoryMachineDisplayMode,
        kernelCommandLine: String?,
        readyTimeoutSeconds: TimeInterval,
        shares: [DoryMachineShareConfiguration],
        environment: [String: String],
        resolvedGraphics: DoryGraphicsAccelerationLevel?,
        resolvedDevices: DoryVirtualMachineDeviceCapabilityRequest?,
        gvproxyPath: String?,
        sshAgentSocketPath: String?,
        publishHost: String,
        bridgeSubnetCIDR: String,
        dataDriveRoot: String?,
        restoreStatePath: String?,
        onRuntimeCreated: (DoryVMMRuntime) -> Void
    ) throws -> DoryVMMRuntime {
        try FileManager.default.createDirectory(atPath: stateDirectory, withIntermediateDirectories: true)
        for socketPath in [dockerdSocketPath, agentSocketPath, shellSocketPath, controlSocketPath] {
            try FileManager.default.createDirectory(
                atPath: (socketPath as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
        }
        let serialLog = try openAppendLog("\(stateDirectory)/serial.log")
        try appendBootSessionMarker(
            to: serialLog,
            machineID: machineID,
            operationID: operationID,
            bootMode: bootMode,
            cpuCount: cpuCount,
            memoryMB: memoryMB,
            runtimeProfile: bootMode == .efi
                ? DoryInstallerRuntimeProfile.current.rawValue
                : "linux-kernel-virtio-blk"
        )
        let runtimeSocketDirectory = (controlSocketPath as NSString).deletingLastPathComponent
        let serialConsole = try DoryVMMSerialConsole(
            socketPath: "\(runtimeSocketDirectory)/console.sock",
            log: serialLog
        )
        let dataDrive: DoryDataDrive?
        if let dataDriveRoot, machineID == "docker" {
            dataDrive = try DoryDataDrive(overrideRoot: dataDriveRoot)
            try dataDrive?.prepare()
        } else {
            dataDrive = nil
        }
        let requestedNetwork = resolvedDevices?.networkAttachment ?? .sharedNAT
        // An exact NIC contract uses the same gvproxy datapath on every supported attachment so
        // the backend can enforce both its MAC lease and MTU rather than delegating them to VZ NAT.
        let usesGVProxy = machineID == "docker"
            || requestedNetwork == .isolated
            || resolvedDevices?.networkInterface != nil
        let gvproxyNetwork: DoryVMMGVProxyNetwork?
        if usesGVProxy, requestedNetwork != .disconnected {
            guard let gvproxyPath else { throw DoryVMMArgumentError.missingGVProxy }
            guard publishHost == "127.0.0.1" || publishHost == "0.0.0.0" else {
                throw DoryVMMArgumentError.invalidPublishHost(publishHost)
            }
            if requestedNetwork == .isolated, publishHost != "127.0.0.1" {
                throw DoryVZMachineError.validation(
                    "host-only networking cannot publish a source-preserving LAN route"
                )
            }
            gvproxyNetwork = try DoryVMMGVProxyNetwork(
                gvproxyPath: gvproxyPath,
                stateDirectory: stateDirectory,
                networkAttachment: requestedNetwork,
                networkInterface: resolvedDevices?.networkInterface,
                sourcePreservingLAN: requestedNetwork == .sharedNAT && publishHost == "0.0.0.0"
            )
        } else {
            gvproxyNetwork = nil
        }
        let bridgeNetwork = try DoryIPv4BridgeNetwork(bridgeSubnetCIDR)
        let sourcePreservingLANClient: SourcePreservingLANPrivilegedClient?
        let sourcePreservingLANSessionID: String?
        if publishHost == "0.0.0.0", let gvproxyNetwork,
           let lanDatapathSocketPath = gvproxyNetwork.lanDatapathSocketPath {
            let client = SourcePreservingLANPrivilegedClient()
            let sessionID = "vz-\(getpid())"
            do {
                let response = try client.apply(SourcePreservingLANRequest(
                    operation: .activate,
                    sessionID: sessionID,
                    gvproxySocketPath: lanDatapathSocketPath,
                    mtu: resolvedDevices?.networkInterface.map {
                        Int($0.maximumTransmissionUnit)
                    } ?? DoryNetworkMTU.resolved(),
                    bridgeSubnetCIDR: bridgeNetwork.cidr,
                    guestMACAddress: resolvedDevices?.networkInterface?.macAddress
                        ?? SourcePreservingLANPlan.defaultGuestMAC
                ))
                guard response.status == "active" else {
                    throw DoryVZMachineError.validation("source-preserving LAN helper did not activate")
                }
            } catch {
                gvproxyNetwork.stop()
                throw error
            }
            sourcePreservingLANClient = client
            sourcePreservingLANSessionID = sessionID
        } else {
            sourcePreservingLANClient = nil
            sourcePreservingLANSessionID = nil
        }
        let spec = DoryVZMachineSpec(
            machineID: machineID,
            operationID: operationID,
            stateDirectory: stateDirectory,
            kernelPath: kernelPath,
            rootfsPath: rootfsPath,
            bootMode: bootMode,
            installerISOPath: installerISOPath,
            memoryMB: memoryMB,
            cpuCount: cpuCount,
            displayMode: displayMode,
            kernelCommandLine: kernelCommandLine,
            shares: shares,
            environment: environment,
            resolvedGraphics: resolvedGraphics,
            resolvedDevices: resolvedDevices,
            dockerDataDiskPath: dataDrive?.engineDataDiskPath,
            nativeIPv6: gvproxyNetwork != nil,
            sourcePreservingLAN: sourcePreservingLANClient != nil,
            bridgeSubnetCIDR: bridgeNetwork.cidr
        )
        let configuration = try DoryVZConfigurationBuilder.makeConfiguration(
            spec: spec,
            serialOutput: serialConsole.guestOutput,
            serialInput: serialConsole.guestInput,
            networkAttachment: gvproxyNetwork?.attachment
        )
        try validate(configuration: configuration)
        let machine = DoryVZMachine(configuration: configuration, label: machineID)
        if let restoreStatePath {
            try machine.restoreMachineState(from: restoreStatePath)
        } else {
            try machine.start()
        }
        let sshAgentBridge: DoryVZHostSSHAgentBridge?
        let sandboxSSHAgentDenied = environment["DORY_SANDBOX"] == "1"
            && environment["DORY_SANDBOX_SSH_AGENT"] != "1"
        if let sshAgentSocketPath, !sshAgentSocketPath.isEmpty, !sandboxSSHAgentDenied {
            let bridge = try DoryVZHostSSHAgentBridge(
                machine: machine,
                hostSocketPath: sshAgentSocketPath,
                port: DoryGuestPorts.sshAgent
            )
            try bridge.start()
            sshAgentBridge = bridge
        } else {
            sshAgentBridge = nil
        }

        let controlServer = try DoryVMMControlServer(
            machine: machine,
            localSocketPath: controlSocketPath,
            stateDirectory: stateDirectory
        )
        let dockerdProxy = try DoryVZPortUnixProxy(
            machine: machine,
            guestPort: DoryGuestPorts.docker,
            localSocketPath: dockerdSocketPath
        )
        let agentProxy = try DoryVZPortUnixProxy(
            machine: machine,
            guestPort: DoryGuestPorts.control,
            localSocketPath: agentSocketPath
        )
        let shellProxy = try DoryVZPortUnixProxy(
            machine: machine,
            guestPort: DoryGuestPorts.shell,
            localSocketPath: shellSocketPath
        )
        do {
            try controlServer.start()
            try dockerdProxy.start()
            try agentProxy.start()
            try shellProxy.start()
        } catch {
            controlServer.stop()
            dockerdProxy.stop()
            agentProxy.stop()
            shellProxy.stop()
            throw error
        }

        let runtime = DoryVMMRuntime(
            machine: machine,
            controlServer: controlServer,
            proxies: [dockerdProxy, agentProxy, shellProxy],
            serialLog: serialLog,
            serialConsole: serialConsole,
            gvproxyNetwork: gvproxyNetwork,
            sourcePreservingLANClient: sourcePreservingLANClient,
            sourcePreservingLANSessionID: sourcePreservingLANSessionID,
            sshAgentBridge: sshAgentBridge,
            portForwarder: gvproxyNetwork.map {
                DoryVMMPortForwarder(
                    dockerSocketPath: dockerdSocketPath,
                    gvproxyAPISocketPath: $0.apiSocketPath,
                    publishHost: publishHost,
                    sourcePreservingLANClient: sourcePreservingLANClient,
                    sourcePreservingLANSessionID: sourcePreservingLANSessionID,
                    sourcePreservingLANGVProxySocketPath: sourcePreservingLANClient == nil
                        ? nil : $0.lanDatapathSocketPath,
                    bridgeSubnetCIDR: bridgeNetwork.cidr,
                    guestMACAddress: resolvedDevices?.networkInterface?.macAddress
                        ?? SourcePreservingLANPlan.defaultGuestMAC
                )
            }
        )
        runtime.portForwarder?.start()
        onRuntimeCreated(runtime)

        if restoreStatePath != nil {
            try machine.resume()
        }

        if bootMode == .efi {
            try sendHandoff(
                machineID: machineID,
                operationID: operationID,
                handoffSocketPath: handoffSocketPath,
                agentBuild: "dory-vmm/efi",
                agentSocketPath: nil,
                dockerdSocketPath: nil,
                shellSocketPath: nil,
                controlSocketPath: controlSocketPath,
                detail: installerISOPath == nil
                    ? "EFI machine running from its installed disk"
                    : "EFI machine running with read-only installer media attached"
            )
            return runtime
        }

        let agentConnection = try machine.waitForConnection(toPort: DoryGuestPorts.control, timeout: readyTimeoutSeconds)
        defer { agentConnection.close() }
        let agentInfo = try prepareAgent(
            from: agentConnection,
            operationID: operationID,
            displayMode: displayMode,
            environment: environment,
            shares: shares,
            resolvedDevices: resolvedDevices,
            restoringSavedState: restoreStatePath != nil
        )
        // For the Docker VM, this handoff means VM + guest-agent readiness. doryd owns the next
        // ordered stages (data mount, route/resolver, dockerd /version, and host socket), so a VMM
        // process can never collapse all of them into one misleading "running" bit.
        try sendHandoff(
            machineID: machineID,
            operationID: operationID,
            handoffSocketPath: handoffSocketPath,
            agentBuild: agentInfo.agentBuild,
            agentProtocolVersion: agentInfo.protocolVersion,
            agentCapabilities: agentInfo.capabilities,
            agentSocketPath: agentSocketPath,
            dockerdSocketPath: machineID == "docker" ? dockerdSocketPath : nil,
            shellSocketPath: shellSocketPath,
            controlSocketPath: controlSocketPath,
            detail: machineID == "docker"
                ? "VZ Docker VM running; dory-agent answered protocol \(agentInfo.protocolVersion)"
                : "VZ machine running; dory-agent answered protocol \(agentInfo.protocolVersion)"
        )
        return runtime
    }

    private static func prepareAgent(
        from connection: VZVirtioSocketConnection,
        operationID: UUID,
        displayMode: DoryMachineDisplayMode,
        environment: [String: String],
        shares: [DoryMachineShareConfiguration],
        resolvedDevices: DoryVirtualMachineDeviceCapabilityRequest?,
        restoringSavedState: Bool
    ) throws -> DoryAgentInfo {
        let fd = dup(connection.fileDescriptor)
        guard fd >= 0 else {
            throw DoryVZMachineError.syscall("dup", errno)
        }
        let control = try DoryCore.connectAgentControlOverFD(fd)
        defer { control.close() }
        let info = try control.info()
        let operationToken = DoryOperationIdentity.canonical(operationID)
        try requireSuccessfulDesktopExec(control.exec(
            argv: [
                "/bin/sh", "-c",
                "mkdir -p /run/dory && chmod 700 /run/dory && umask 077 && printf '%s\\n' \"$DORY_OPERATION_ID\" > /run/dory/operation-id",
            ],
            env: [DoryExecEnvironment(key: "DORY_OPERATION_ID", value: operationToken)],
            timeoutMs: 10_000,
            outputLimitBytes: 16 * 1_024
        ), operation: "bind lifecycle operation")
        if restoringSavedState { return info }
        guard displayMode == .desktop else { return info }

        if let display = resolvedDevices?.display {
            guard let command = DoryVMMGuestDisplayScale.persistenceCommand(
                scaleFactor: display.guestUIScaleFactor
            ) else {
                throw DoryVZMachineError.validation(
                    "resolved guest UI scale is not supported by Dory Tools"
                )
            }
            try requireSuccessfulDesktopExec(control.exec(
                argv: command,
                timeoutMs: 10_000,
                outputLimitBytes: 64 * 1_024
            ), operation: "persist guest UI scale")
        }

        var guestEnvironment = environment
        guestEnvironment["DORY_OPERATION_ID"] = operationToken
        try requireSuccessfulDesktopExec(control.exec(
            argv: ["/usr/lib/dory/configure-machine"],
            env: guestEnvironment.sorted(by: { $0.key < $1.key }).map {
                DoryExecEnvironment(key: $0.key, value: $0.value)
            },
            timeoutMs: 30_000,
            outputLimitBytes: 64 * 1024
        ), operation: "guest account configuration")

        for share in shares {
            try requireSuccessfulDesktopExec(control.exec(
                argv: ["/bin/mkdir", "-p", share.guestPath],
                timeoutMs: 10_000,
                outputLimitBytes: 64 * 1024
            ), operation: "create share mount point \(share.guestPath)")
            let options = share.readOnly ? "ro,dax=never" : "rw,dax=never"
            try requireSuccessfulDesktopExec(control.exec(
                argv: [
                    "/bin/mount", "-t", "virtiofs", "-o", options,
                    share.tag, share.guestPath,
                ],
                timeoutMs: 30_000,
                outputLimitBytes: 64 * 1024
            ), operation: "mount share \(share.tag) at \(share.guestPath)")
        }

        try requireSuccessfulDesktopExec(control.exec(
            argv: ["/usr/bin/touch", "/var/lib/dory/host-configured"],
            timeoutMs: 10_000,
            outputLimitBytes: 64 * 1024
        ), operation: "complete desktop configuration")
        return info
    }

    private static func requireSuccessfulDesktopExec(
        _ result: DoryExecResult,
        operation: String
    ) throws {
        guard !result.timedOut, result.exitCode == 0 else {
            let stderr = String(decoding: result.stderr, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = result.timedOut
                ? "timed out"
                : (stderr.isEmpty ? "exit code \(result.exitCode)" : stderr)
            throw DoryVZMachineError.validation("desktop \(operation) failed: \(detail)")
        }
    }

    private static func openAppendLog(_ path: String) throws -> FileHandle {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else {
            throw DoryVZMachineError.syscall("open", errno)
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    private static func appendBootSessionMarker(
        to log: FileHandle,
        machineID: String,
        operationID: UUID,
        bootMode: DoryMachineBootMode,
        cpuCount: Int,
        memoryMB: UInt64,
        runtimeProfile: String
    ) throws {
        let timestamp = Date().formatted(.iso8601)
        let marker = "\n--- DORY BOOT \(timestamp) machine=\(machineID) operation=\(DoryOperationIdentity.canonical(operationID)) mode=\(bootMode.rawValue) cpus=\(cpuCount) memoryMB=\(memoryMB) runtime=\(runtimeProfile) ---\n"
        try log.write(contentsOf: Data(marker.utf8))
        try log.synchronize()
    }

    private static func validate(configuration: VZVirtualMachineConfiguration) throws {
        do {
            try configuration.validate()
        } catch {
            throw DoryVZMachineError.validation("\(error)")
        }
    }
}

private enum DoryGuestPorts {
    static let control: UInt32 = 1024
    static let docker: UInt32 = 1026
    static let shell: UInt32 = 1027
    static let sshAgent: UInt32 = 1029
    static let shutdown: UInt32 = 2377
}

protocol DoryVMMGuestShutdownHandling: AnyObject, Sendable {
    var isStopped: Bool { get }
    func requestGuestShutdown() throws
    func forceCleanup()
}

extension DoryVMMGuestShutdownHandling {
    func forceCleanup() {}
}

final class DoryVMMShutdownCoordinator: @unchecked Sendable {
    typealias WatchdogScheduler = @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void
    typealias ForceExit = @Sendable (Int32) -> Void

    private let lock = NSLock()
    private let worker = DispatchQueue(label: "dev.dory.dory-vmm.shutdown", qos: .userInitiated)
    private let watchdogSeconds: TimeInterval
    private let scheduleWatchdog: WatchdogScheduler
    private let forceExit: ForceExit
    private var target: (any DoryVMMGuestShutdownHandling)?
    private var requested = false
    private var begun = false
    private var signalSources: [DispatchSourceSignal] = []
    private var previousSignalHandlers: [(Int32, sig_t)] = []

    init(
        watchdogSeconds: TimeInterval = DoryEngineShutdownTiming.helperWatchdogSeconds,
        scheduleWatchdog: @escaping WatchdogScheduler = { delay, action in
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay, execute: action)
        },
        forceExit: @escaping ForceExit = { code in exit(code) }
    ) {
        self.watchdogSeconds = watchdogSeconds
        self.scheduleWatchdog = scheduleWatchdog
        self.forceExit = forceExit
    }

    func installSignalHandlers() {
        lock.lock()
        guard signalSources.isEmpty else {
            lock.unlock()
            return
        }
        signalSources = [SIGTERM, SIGINT].map { signalNumber in
            if let previous = signal(signalNumber, SIG_IGN) {
                previousSignalHandlers.append((signalNumber, previous))
            }
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: worker)
            source.setEventHandler { [weak self] in
                self?.request(reason: signalNumber == SIGTERM ? "SIGTERM" : "SIGINT")
            }
            source.resume()
            return source
        }
        lock.unlock()
    }

    func cancelSignalHandlers() {
        lock.lock()
        let sources = signalSources
        let handlers = previousSignalHandlers
        signalSources = []
        previousSignalHandlers = []
        lock.unlock()
        sources.forEach { $0.cancel() }
        handlers.forEach { signalNumber, handler in
            _ = signal(signalNumber, handler)
        }
    }

    func attach(_ target: any DoryVMMGuestShutdownHandling) {
        lock.lock()
        self.target = target
        let shouldBegin = requested && !begun
        if shouldBegin { begun = true }
        lock.unlock()
        if shouldBegin {
            beginShutdown(target)
        }
    }

    func request(reason: String) {
        lock.lock()
        guard !requested else {
            lock.unlock()
            return
        }
        requested = true
        let target = target
        if target != nil { begun = true }
        lock.unlock()

        FileHandle.standardError.write(Data("dory-vmm: graceful shutdown requested (\(reason))\n".utf8))
        if let target {
            beginShutdown(target)
        }
    }

    private func beginShutdown(_ target: any DoryVMMGuestShutdownHandling) {
        scheduleWatchdog(watchdogSeconds) { [weak self, weak target] in
            guard let self, let target, !target.isStopped else { return }
            FileHandle.standardError.write(Data(
                "dory-vmm: guest did not stop in \(self.watchdogSeconds)s, forcing exit\n".utf8
            ))
            target.forceCleanup()
            self.forceExit(1)
        }
        worker.async {
            do {
                try target.requestGuestShutdown()
            } catch {
                FileHandle.standardError.write(Data(
                    "dory-vmm: guest shutdown request failed: \(error)\n".utf8
                ))
            }
        }
    }
}

final class DoryVMMRuntime: DoryVMMGuestShutdownHandling, @unchecked Sendable {
    let machine: DoryVZMachine
    private let controlServer: DoryVMMControlServer
    private let proxies: [DoryVZPortUnixProxy]
    private let serialLog: FileHandle
    private let serialConsole: DoryVMMSerialConsole
    private let gvproxyNetwork: DoryVMMGVProxyNetwork?
    private let sourcePreservingLANClient: SourcePreservingLANPrivilegedClient?
    private let sourcePreservingLANSessionID: String?
    private let sshAgentBridge: DoryVZHostSSHAgentBridge?
    private(set) var portForwarder: DoryVMMPortForwarder?

    fileprivate init(
        machine: DoryVZMachine,
        controlServer: DoryVMMControlServer,
        proxies: [DoryVZPortUnixProxy],
        serialLog: FileHandle,
        serialConsole: DoryVMMSerialConsole,
        gvproxyNetwork: DoryVMMGVProxyNetwork?,
        sourcePreservingLANClient: SourcePreservingLANPrivilegedClient?,
        sourcePreservingLANSessionID: String?,
        sshAgentBridge: DoryVZHostSSHAgentBridge?,
        portForwarder: DoryVMMPortForwarder?
    ) {
        self.machine = machine
        self.controlServer = controlServer
        self.proxies = proxies
        self.serialLog = serialLog
        self.serialConsole = serialConsole
        self.gvproxyNetwork = gvproxyNetwork
        self.sourcePreservingLANClient = sourcePreservingLANClient
        self.sourcePreservingLANSessionID = sourcePreservingLANSessionID
        self.sshAgentBridge = sshAgentBridge
        self.portForwarder = portForwarder
    }

    var isStopped: Bool {
        machine.isStopped
    }

    func executeDesktopIntegration(
        argv: [String],
        stdin: Data,
        timeoutMs: UInt64,
        outputLimitBytes: UInt64
    ) throws -> DoryExecResult {
        let connection = try machine.connect(toPort: DoryGuestPorts.control)
        defer { connection.close() }
        let fd = dup(connection.fileDescriptor)
        guard fd >= 0 else { throw DoryVZMachineError.syscall("dup", errno) }
        let control = try DoryCore.connectAgentControlOverFD(fd)
        defer { control.close() }
        return try control.execWithInput(
            argv: argv,
            stdin: stdin,
            timeoutMs: timeoutMs,
            outputLimitBytes: outputLimitBytes
        )
    }

    func requestGuestShutdown() throws {
        do {
            try requestGuestShutdownThroughAgent()
            return
        } catch {
            FileHandle.standardError.write(Data(
                "dory-vmm: agent shutdown request failed, trying transport fallback: \(error)\n".utf8
            ))
        }
        if let gvproxyNetwork {
            try gvproxyNetwork.requestGuestShutdown()
            return
        }
        do {
            try machine.requestGuestStop()
            return
        } catch {
            FileHandle.standardError.write(Data(
                "dory-vmm: virtual power-button shutdown request failed, trying transport fallback: \(error)\n".utf8
            ))
        }
        let deadline = Date().addingTimeInterval(5)
        var lastError: Error?
        repeat {
            if machine.isStopped { return }
            do {
                let connection = try machine.connect(toPort: DoryGuestPorts.shutdown)
                connection.close()
                return
            } catch {
                lastError = error
                Thread.sleep(forTimeInterval: DoryEngineShutdownTiming.pollIntervalSeconds)
            }
        } while Date() < deadline
        throw lastError ?? DoryVZMachineError.guestPortUnavailable(DoryGuestPorts.shutdown)
    }

    private func requestGuestShutdownThroughAgent() throws {
        let connection = try machine.connect(toPort: DoryGuestPorts.control)
        defer { connection.close() }
        let fd = dup(connection.fileDescriptor)
        guard fd >= 0 else {
            throw DoryVZMachineError.syscall("dup", errno)
        }
        let control = try DoryCore.connectAgentControlOverFD(fd)
        defer { control.close() }
        let result = try control.exec(
            argv: ["/bin/sh", "-c", GuestShutdownCommand.detachedAgentRequest()],
            cwd: "",
            env: [],
            timeoutMs: 5_000,
            outputLimitBytes: 64 * 1024
        )
        guard result.exitCode == 0, !result.timedOut else {
            let stderr = String(decoding: result.stderr.prefix(4_096), as: UTF8.self)
            throw DoryVZMachineError.validation(
                "agent rejected guest shutdown (exit=\(result.exitCode), timedOut=\(result.timedOut)): \(stderr)"
            )
        }
    }

    func waitUntilStopped() throws {
        defer { forceCleanup() }
        try machine.waitUntilStopped()
    }

    func forceCleanup() {
        controlServer.stop()
        proxies.forEach { $0.stop() }
        sshAgentBridge?.stop()
        portForwarder?.stop()
        if let sourcePreservingLANClient, let sourcePreservingLANSessionID {
            _ = try? sourcePreservingLANClient.apply(SourcePreservingLANRequest(
                operation: .deactivate,
                sessionID: sourcePreservingLANSessionID
            ))
        }
        gvproxyNetwork?.stop()
        serialConsole.stop()
        try? serialLog.close()
    }
}

private final class DoryVZMachineStopObserver: NSObject, VZVirtualMachineDelegate, @unchecked Sendable {
    private let condition = NSCondition()
    private var completion: Result<Void, Error>?

    var isStopped: Bool {
        condition.lock()
        defer { condition.unlock() }
        return completion != nil
    }

    func waitUntilStopped() throws {
        condition.lock()
        while completion == nil {
            condition.wait()
        }
        let result = completion
        condition.unlock()
        try result?.get()
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        complete(.success(()))
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: any Error) {
        complete(.failure(DoryVZMachineError.stoppedWithError("\(error)")))
    }

    private func complete(_ result: Result<Void, Error>) {
        condition.lock()
        guard completion == nil else {
            condition.unlock()
            return
        }
        completion = result
        condition.broadcast()
        condition.unlock()
    }
}

public final class DoryVZMachine: @unchecked Sendable {
    private let queue: DispatchQueue
    private let configuration: VZVirtualMachineConfiguration
    private let virtualMachine: VZVirtualMachine
    private let stopObserver: DoryVZMachineStopObserver

    public init(configuration: VZVirtualMachineConfiguration, label: String) {
        self.queue = DispatchQueue(label: "dev.dory.dory-vmm.\(label)")
        self.configuration = configuration
        self.stopObserver = DoryVZMachineStopObserver()
        self.virtualMachine = VZVirtualMachine(configuration: configuration, queue: queue)
        self.queue.sync {
            self.virtualMachine.delegate = self.stopObserver
        }
    }

    public func start() throws {
        let box = BlockingResultBox<Void>()
        queue.async { [self] in
            self.virtualMachine.start { result in
                box.complete(result.map { _ in () })
            }
        }
        try box.wait()
    }

    public func pause() throws {
        let box = BlockingResultBox<Void>()
        queue.async { [self] in
            guard virtualMachine.state == .running else {
                box.complete(.failure(DoryVZMachineError.validation(
                    "virtual machine is not running"
                )))
                return
            }
            virtualMachine.pause { box.complete($0) }
        }
        try box.wait()
    }

    public func resume() throws {
        let box = BlockingResultBox<Void>()
        queue.async { [self] in
            guard virtualMachine.state == .paused else {
                box.complete(.failure(DoryVZMachineError.validation(
                    "virtual machine is not paused"
                )))
                return
            }
            virtualMachine.resume { box.complete($0) }
        }
        try box.wait()
    }

    /// Saves the current VZ execution state and reports whether this call temporarily paused a
    /// running machine. The control server uses that fact to restore the original power state if
    /// it cannot deliver the successful response to doryd.
    @discardableResult
    public func saveMachineState(to path: String) throws -> Bool {
        let url = URL(fileURLWithPath: path)
        let box = BlockingResultBox<Bool>()
        queue.async { [self] in
            do {
                try configuration.validateSaveRestoreSupport()
            } catch {
                box.complete(.failure(error))
                return
            }
            let save = { (resumeOnFailure: Bool) in
                self.virtualMachine.saveMachineStateTo(url: url) { error in
                    guard let error else {
                        box.complete(.success(resumeOnFailure))
                        return
                    }
                    guard resumeOnFailure else {
                        box.complete(.failure(error))
                        return
                    }
                    // Saving a running machine requires an internal pause. If persistence fails,
                    // undo that pause so the daemon's still-running lifecycle state remains true.
                    self.virtualMachine.resume { resumeResult in
                        switch resumeResult {
                        case .success:
                            box.complete(.failure(error))
                        case .failure(let resumeError):
                            box.complete(.failure(DoryVZMachineError.validation(
                                "saved-state write failed (\(error)); virtual machine resume also failed (\(resumeError))"
                            )))
                        }
                    }
                }
            }
            switch virtualMachine.state {
            case .paused:
                save(false)
            case .running:
                virtualMachine.pause { result in
                    switch result {
                    case .success: save(true)
                    case .failure(let error): box.complete(.failure(error))
                    }
                }
            default:
                box.complete(.failure(DoryVZMachineError.validation(
                    "virtual machine must be running or paused before saving state"
                )))
            }
        }
        return try box.wait()
    }

    public func restoreMachineState(from path: String) throws {
        let url = URL(fileURLWithPath: path)
        let box = BlockingResultBox<Void>()
        queue.async { [self] in
            do {
                try configuration.validateSaveRestoreSupport()
            } catch {
                box.complete(.failure(error))
                return
            }
            guard virtualMachine.state == .stopped else {
                box.complete(.failure(DoryVZMachineError.validation(
                    "virtual machine must be stopped before restoring state"
                )))
                return
            }
            virtualMachine.restoreMachineStateFrom(url: url) { error in
                if let error { box.complete(.failure(error)) }
                else { box.complete(.success(())) }
            }
        }
        try box.wait()
    }

    var virtualMachineForDisplay: VZVirtualMachine {
        virtualMachine
    }

    func reconfigurePrimaryDisplay(sizeInPixels: CGSize) throws {
        try queue.sync {
            guard let display = virtualMachine.graphicsDevices.first?.displays.first else {
                throw DoryVZMachineError.validation("desktop VM did not expose a graphics display")
            }
            try display.reconfigure(sizeInPixels: sizeInPixels)
        }
    }

    public func waitForConnection(toPort port: UInt32, timeout: TimeInterval) throws -> VZVirtioSocketConnection {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Error?
        while Date() < deadline {
            if isStopped {
                throw DoryVZMachineError.guestStoppedBeforePort(port)
            }
            do {
                return try connect(toPort: port)
            } catch {
                lastError = error
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
        if let lastError {
            FileHandle.standardError.write(Data("dory-vmm: last vsock \(port) error: \(lastError)\n".utf8))
        }
        throw DoryVZMachineError.guestPortUnavailable(port)
    }

    public var isStopped: Bool {
        stopObserver.isStopped
    }

    public func waitUntilStopped() throws {
        try stopObserver.waitUntilStopped()
    }

    /// Ask the guest firmware/OS to shut down as if its virtual power button were pressed.
    /// This is the integration-free shutdown path for arbitrary EFI guests that do not run
    /// Dory's agent yet; it gives Linux a chance to flush filesystems before the VMM exits.
    public func requestGuestStop() throws {
        try queue.sync {
            guard virtualMachine.canRequestStop else {
                throw DoryVZMachineError.validation(
                    "virtual machine is not in a state that accepts a guest stop request"
                )
            }
            try virtualMachine.requestStop()
        }
    }

    public func connect(toPort port: UInt32) throws -> VZVirtioSocketConnection {
        let box = BlockingResultBox<VZVirtioSocketConnection>()
        queue.async { [self] in
            let socketDevice: VZVirtioSocketDevice
            do {
                socketDevice = try self.firstSocketDeviceOnQueue()
            } catch {
                box.complete(.failure(error))
                return
            }
            socketDevice.connect(toPort: port) { result in
                box.complete(result)
            }
        }
        return try box.wait()
    }

    func installGuestListener(_ listener: VZVirtioSocketListener, port: UInt32) throws {
        try queue.sync {
            let device = try firstSocketDeviceOnQueue()
            device.setSocketListener(listener, forPort: port)
        }
    }

    func removeGuestListener(port: UInt32) {
        queue.sync {
            guard let device = virtualMachine.socketDevices.first as? VZVirtioSocketDevice else {
                return
            }
            device.removeSocketListener(forPort: port)
        }
    }

    public func setBalloonTarget(memoryMB: UInt64) throws -> UInt64 {
        let target = memoryMB.multipliedReportingOverflow(by: 1024 * 1024)
        guard !target.overflow else {
            throw DoryVZMachineError.validation("balloon target is too large: \(memoryMB) MiB")
        }
        let targetBytes = target.partialValue
        let box = BlockingResultBox<UInt64>()
        queue.async { [self] in
            guard let balloon = self.virtualMachine.memoryBalloonDevices.first as? VZVirtioTraditionalMemoryBalloonDevice else {
                box.complete(.failure(DoryVZMachineError.missingMemoryBalloonDevice))
                return
            }
            balloon.targetVirtualMachineMemorySize = targetBytes
            box.complete(.success(balloon.targetVirtualMachineMemorySize / 1024 / 1024))
        }
        return try box.wait()
    }

    private func firstSocketDeviceOnQueue() throws -> VZVirtioSocketDevice {
        guard let device = virtualMachine.socketDevices.first as? VZVirtioSocketDevice else {
            throw DoryVZMachineError.missingSocketDevice
        }
        return device
    }
}

final class DoryVZHostSSHAgentBridge: NSObject, VZVirtioSocketListenerDelegate, @unchecked Sendable {
    private let machine: DoryVZMachine
    private let hostSocketPath: String
    private let expectedUID: uid_t
    private let port: UInt32
    private let lock = NSLock()
    private var listener: VZVirtioSocketListener?

    init(
        machine: DoryVZMachine,
        hostSocketPath: String,
        expectedUID: uid_t = getuid(),
        port: UInt32
    ) throws {
        guard hostSocketPath.hasPrefix("/"), !hostSocketPath.contains("\0") else {
            throw DoryVZMachineError.validation("SSH agent socket path must be absolute and NUL-free")
        }
        _ = try unixAddress(path: hostSocketPath)
        self.machine = machine
        self.hostSocketPath = hostSocketPath
        self.expectedUID = expectedUID
        self.port = port
    }

    func start() throws {
        let listener = VZVirtioSocketListener()
        listener.delegate = self
        try machine.installGuestListener(listener, port: port)
        lock.lock()
        self.listener = listener
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let wasRunning = listener != nil
        listener = nil
        lock.unlock()
        if wasRunning {
            machine.removeGuestListener(port: port)
        }
    }

    func listener(
        _ listener: VZVirtioSocketListener,
        shouldAcceptNewConnection connection: VZVirtioSocketConnection,
        from socketDevice: VZVirtioSocketDevice
    ) -> Bool {
        let box = GuestConnectionBox(connection)
        DispatchQueue.global(qos: .userInitiated).async { [self, box] in
            guard let upstream = Self.connectSameUserSocket(
                path: hostSocketPath,
                expectedUID: expectedUID
            ) else {
                box.connection.close()
                return
            }
            DoryFDSplice(clientFD: upstream, guestConnection: box.connection).start()
        }
        return true
    }

    private final class GuestConnectionBox: @unchecked Sendable {
        let connection: VZVirtioSocketConnection
        init(_ connection: VZVirtioSocketConnection) { self.connection = connection }
    }

    static func connectSameUserSocket(
        path: String,
        expectedUID: uid_t,
        timeoutMilliseconds: Int32 = 2_000
    ) -> Int32? {
        var status = stat()
        guard lstat(path, &status) == 0,
              status.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK),
              status.st_uid == expectedUID else {
            return nil
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        let originalFlags = fcntl(fd, F_GETFL, 0)
        guard originalFlags >= 0,
              fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK) == 0 else {
            close(fd)
            return nil
        }
        var noSigpipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
        do {
            var address = try unixAddress(path: path)
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if connected != 0 {
                guard errno == EINPROGRESS else {
                    close(fd)
                    return nil
                }
                var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                guard poll(&descriptor, 1, max(0, timeoutMilliseconds)) > 0 else {
                    close(fd)
                    return nil
                }
                var socketError: Int32 = 0
                var socketErrorLength = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(
                    fd,
                    SOL_SOCKET,
                    SO_ERROR,
                    &socketError,
                    &socketErrorLength
                ) == 0, socketError == 0 else {
                    close(fd)
                    return nil
                }
            }
            guard fcntl(fd, F_SETFL, originalFlags) == 0 else {
                close(fd)
                return nil
            }
            return fd
        } catch {
            close(fd)
            return nil
        }
    }

    deinit {
        stop()
    }
}

private final class DoryVMMControlServer: @unchecked Sendable {
    private let machine: DoryVZMachine
    private let localSocketPath: String
    private let stateDirectory: String
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var listenerFD: Int32 = -1
    private var running = false

    init(
        machine: DoryVZMachine,
        localSocketPath: String,
        stateDirectory: String
    ) throws {
        self.machine = machine
        self.localSocketPath = localSocketPath
        self.stateDirectory = URL(fileURLWithPath: stateDirectory).standardizedFileURL.path
        self.queue = DispatchQueue(label: "dev.dory.dory-vmm.control")
    }

    func start() throws {
        try FileManager.default.createDirectory(
            atPath: (localSocketPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        unlink(localSocketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DoryVZMachineError.syscall("socket", errno) }

        do {
            var address = try unixAddress(path: localSocketPath)
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                    Darwin.bind(fd, raw, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0 else { throw DoryVZMachineError.syscall("bind", errno) }
            chmod(localSocketPath, 0o600)
            guard listen(fd, 32) == 0 else { throw DoryVZMachineError.syscall("listen", errno) }

            lock.lock()
            listenerFD = fd
            running = true
            lock.unlock()
            queue.async { [weak self] in
                self?.acceptLoop(listenerFD: fd)
            }
        } catch {
            close(fd)
            unlink(localSocketPath)
            throw error
        }
    }

    func stop() {
        lock.lock()
        let fd = listenerFD
        listenerFD = -1
        running = false
        lock.unlock()
        if fd >= 0 {
            close(fd)
        }
        unlink(localSocketPath)
    }

    private func acceptLoop(listenerFD: Int32) {
        while isRunning(listenerFD: listenerFD) {
            let client = accept(listenerFD, nil, nil)
            if client < 0 {
                continue
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else {
                    close(client)
                    return
                }
                self.handle(clientFD: client)
            }
        }
    }

    private func handle(clientFD: Int32) {
        defer { close(clientFD) }
        let response: VmmControlResponse
        var exitAfterResponse = false
        var resumeAfterResponseFailure = false
        do {
            let request = try readRequest(from: clientFD)
            let handled = try handle(request: request)
            response = handled.response
            exitAfterResponse = handled.exitAfterResponse
            resumeAfterResponseFailure = handled.resumeAfterResponseFailure
        } catch {
            response = VmmControlResponse(ok: false, message: "\(error)")
        }
        do {
            try writeResponse(response, to: clientFD)
        } catch {
            FileHandle.standardError.write(Data("dory-vmm: control response failed: \(error)\n".utf8))
            if resumeAfterResponseFailure {
                do {
                    try machine.resume()
                } catch {
                    FileHandle.standardError.write(Data(
                        "dory-vmm: failed to resume after saved-state response failure: \(error)\n".utf8
                    ))
                    // The daemon cannot safely continue to advertise this helper as running when
                    // the internally-paused VZ machine could not be resumed.
                    exit(1)
                }
            }
            return
        }
        if exitAfterResponse {
            // The caller marks this helper exit as expected before issuing the command. Delay
            // until the accepted response has reached the socket buffer, then tear down the VZ
            // process; the daemon verifies, fsyncs, hashes, and publishes the completed file.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.05) {
                exit(0)
            }
        }
    }

    private struct HandledControlResponse {
        var response: VmmControlResponse
        var exitAfterResponse = false
        var resumeAfterResponseFailure = false
    }

    private func handle(request: VmmControlRequest) throws -> HandledControlResponse {
        switch request.command {
        case "setBalloonTarget":
            guard let targetMB = request.targetMB, targetMB > 0 else {
                return HandledControlResponse(
                    response: VmmControlResponse(ok: false, message: "missing positive targetMB")
                )
            }
            let appliedMB = try machine.setBalloonTarget(memoryMB: targetMB)
            return HandledControlResponse(
                response: VmmControlResponse(ok: true, targetMB: appliedMB)
            )
        case "pauseMachine":
            try machine.pause()
            return HandledControlResponse(response: VmmControlResponse(ok: true))
        case "resumeMachine":
            try machine.resume()
            return HandledControlResponse(response: VmmControlResponse(ok: true))
        case "saveMachineState":
            guard let path = request.statePath,
                  let accepted = acceptedSavedStatePath(path) else {
                return HandledControlResponse(
                    response: VmmControlResponse(
                        ok: false,
                        message: "saved-state path is outside the private machine state directory"
                    )
                )
            }
            let pausedRunningMachine = try machine.saveMachineState(to: accepted)
            return HandledControlResponse(
                response: VmmControlResponse(ok: true),
                exitAfterResponse: true,
                resumeAfterResponseFailure: pausedRunningMachine
            )
        default:
            return HandledControlResponse(
                response: VmmControlResponse(
                    ok: false,
                    message: "unknown VMM control command: \(request.command)"
                )
            )
        }
    }

    private func acceptedSavedStatePath(_ path: String) -> String? {
        guard path.hasPrefix("/"), !path.contains("\0") else { return nil }
        let canonical = URL(fileURLWithPath: path).standardizedFileURL.path
        let allowedDirectory = stateDirectory + "/saved-state-v1"
        guard (canonical as NSString).deletingLastPathComponent == allowedDirectory,
              (canonical as NSString).lastPathComponent.hasPrefix("state.tmp-") else {
            return nil
        }
        return canonical
    }

    private func isRunning(listenerFD: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running && self.listenerFD == listenerFD
    }

    deinit {
        stop()
    }
}

private func readRequest(from fd: Int32) throws -> VmmControlRequest {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 16 * 1024)
    while true {
        let count = buffer.withUnsafeMutableBytes { raw in
            read(fd, raw.baseAddress, raw.count)
        }
        if count == 0 {
            break
        }
        if count < 0 {
            if errno == EINTR { continue }
            throw DoryVZMachineError.syscall("read", errno)
        }
        data.append(contentsOf: buffer.prefix(count))
        if data.count > 1024 * 1024 {
            throw VmmControlError.invalidJSON("request exceeded 1 MiB")
        }
    }
    guard !data.isEmpty else {
        throw VmmControlError.invalidJSON("empty request")
    }
    do {
        return try JSONDecoder().decode(VmmControlRequest.self, from: data)
    } catch {
        throw VmmControlError.invalidJSON("\(error)")
    }
}

private func writeResponse(_ response: VmmControlResponse, to fd: Int32) throws {
    let data = try JSONEncoder().encode(response)
    try data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        var offset = 0
        while offset < data.count {
            let written = send(fd, base.advanced(by: offset), data.count - offset, MSG_NOSIGNAL)
            if written < 0 {
                if errno == EINTR { continue }
                throw DoryVZMachineError.syscall("write", errno)
            }
            offset += written
        }
    }
}

private final class BlockingResultBox<T>: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var result: Result<T, Error>?

    func complete(_ result: Result<T, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
        semaphore.signal()
    }

    func wait() throws -> T {
        semaphore.wait()
        lock.lock()
        let result = self.result
        lock.unlock()
        return try result!.get()
    }
}

public final class DoryVZPortUnixProxy: @unchecked Sendable {
    private let machine: DoryVZMachine
    private let guestPort: UInt32
    public let localSocketPath: String
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var listenerFD: Int32 = -1
    private var running = false

    public init(machine: DoryVZMachine, guestPort: UInt32, localSocketPath: String) throws {
        self.machine = machine
        self.guestPort = guestPort
        self.localSocketPath = localSocketPath
        self.queue = DispatchQueue(label: "dev.dory.dory-vmm.proxy.\(guestPort)")
    }

    public func start() throws {
        try FileManager.default.createDirectory(
            atPath: (localSocketPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        unlink(localSocketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DoryVZMachineError.syscall("socket", errno) }

        do {
            var address = try unixAddress(path: localSocketPath)
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                    Darwin.bind(fd, raw, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0 else { throw DoryVZMachineError.syscall("bind", errno) }
            chmod(localSocketPath, 0o600)
            guard listen(fd, 128) == 0 else { throw DoryVZMachineError.syscall("listen", errno) }

            lock.lock()
            listenerFD = fd
            running = true
            lock.unlock()
            queue.async { [weak self] in
                self?.acceptLoop(listenerFD: fd)
            }
        } catch {
            close(fd)
            unlink(localSocketPath)
            throw error
        }
    }

    public func stop() {
        lock.lock()
        let fd = listenerFD
        listenerFD = -1
        running = false
        lock.unlock()
        if fd >= 0 {
            close(fd)
        }
        unlink(localSocketPath)
    }

    private func acceptLoop(listenerFD: Int32) {
        while isRunning(listenerFD: listenerFD) {
            let client = accept(listenerFD, nil, nil)
            if client < 0 {
                continue
            }
            DispatchQueue.global(qos: .userInitiated).async { [machine, guestPort] in
                do {
                    let guest = try machine.connect(toPort: guestPort)
                    DoryFDSplice(clientFD: client, guestConnection: guest).start()
                } catch {
                    FileHandle.standardError.write(Data("dory-vmm: proxy connect failed: \(error)\n".utf8))
                    close(client)
                }
            }
        }
    }

    private func isRunning(listenerFD: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running && self.listenerFD == listenerFD
    }

    deinit {
        stop()
    }
}

private final class DoryFDSplice: @unchecked Sendable {
    private let clientFD: Int32
    private let guestConnection: VZVirtioSocketConnection
    private let group = DispatchGroup()

    init(clientFD: Int32, guestConnection: VZVirtioSocketConnection) {
        self.clientFD = clientFD
        self.guestConnection = guestConnection
    }

    func start() {
        let guestFD = guestConnection.fileDescriptor
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            pump(from: clientFD, to: guestFD)
            shutdown(guestFD, SHUT_WR)
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            pump(from: guestFD, to: clientFD)
            shutdown(clientFD, SHUT_WR)
            group.leave()
        }
        group.notify(queue: .global(qos: .utility)) { [self] in
            close(clientFD)
            guestConnection.close()
        }
    }
}

private func pump(from source: Int32, to destination: Int32) {
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while true {
        let readCount = buffer.withUnsafeMutableBytes { raw in
            read(source, raw.baseAddress, raw.count)
        }
        if readCount == 0 {
            return
        }
        if readCount < 0 {
            if errno == EINTR {
                continue
            }
            return
        }
        var offset = 0
        while offset < readCount {
            let written = buffer.withUnsafeBytes { raw in
                send(destination, raw.baseAddress!.advanced(by: offset), readCount - offset, MSG_NOSIGNAL)
            }
            if written < 0 {
                if errno == EINTR {
                    continue
                }
                return
            }
            offset += written
        }
    }
}

private func unixAddress(path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
        throw VmmHandoffError.pathTooLong(path)
    }
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
        bytes.withUnsafeBytes { source in
            destination.baseAddress!.copyMemory(from: source.baseAddress!, byteCount: bytes.count)
        }
    }
    return address
}
