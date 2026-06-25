import Foundation

struct DockerVersionOut: Encodable, Sendable {
    let Version: String, ApiVersion: String, MinAPIVersion: String
    let Os: String, Arch: String, KernelVersion: String
    let GoVersion: String, GitCommit: String, BuildTime: String
}

struct DockerInfoOut: Encodable, Sendable {
    let ID: String, Name: String
    let Containers: Int, ContainersRunning: Int, ContainersPaused: Int, ContainersStopped: Int
    let Images: Int, NCPU: Int
    let MemTotal: Int64
    let ServerVersion: String, OperatingSystem: String, OSType: String, Architecture: String, Driver: String
}

struct DockerPortOut: Codable, Sendable {
    let PrivatePort: Int
    let PublicPort: Int?
    let portType: String
    enum CodingKeys: String, CodingKey {
        case PrivatePort, PublicPort, portType = "Type"
    }
}

struct DockerContainerHostConfigSummaryOut: Codable, Sendable {
    let NetworkMode: String
}

struct DockerContainerNetworkSettingsOut: Codable, Sendable {
    let Networks: [String: DockerEndpointSettings]
}

struct DockerContainerOut: Codable, Sendable {
    let Id: String
    let Names: [String]
    let Image: String, ImageID: String, Command: String
    let Created: Int
    let State: String, Status: String
    let Ports: [DockerPortOut]
    let Labels: [String: String]
    let HostConfig: DockerContainerHostConfigSummaryOut
    let NetworkSettings: DockerContainerNetworkSettingsOut
    let Mounts: [DockerInspectMountOut]
    let SizeRw: Int64?
    let SizeRootFs: Int64?

    init(
        Id: String,
        Names: [String],
        Image: String,
        ImageID: String,
        Command: String,
        Created: Int,
        State: String,
        Status: String,
        Ports: [DockerPortOut],
        Labels: [String: String],
        HostConfig: DockerContainerHostConfigSummaryOut,
        NetworkSettings: DockerContainerNetworkSettingsOut,
        Mounts: [DockerInspectMountOut],
        SizeRw: Int64? = nil,
        SizeRootFs: Int64? = nil
    ) {
        self.Id = Id
        self.Names = Names
        self.Image = Image
        self.ImageID = ImageID
        self.Command = Command
        self.Created = Created
        self.State = State
        self.Status = Status
        self.Ports = Ports
        self.Labels = Labels
        self.HostConfig = HostConfig
        self.NetworkSettings = NetworkSettings
        self.Mounts = Mounts
        self.SizeRw = SizeRw
        self.SizeRootFs = SizeRootFs
    }
}

struct DockerImageOut: Encodable, Sendable {
    let Id: String
    let RepoTags: [String]
    let RepoDigests: [String]
    let Created: Int
    let Size: Int64
    let SharedSize: Int64
    let VirtualSize: Int64
    let Labels: [String: String]
    let Containers: Int

    init(
        Id: String,
        RepoTags: [String],
        Containers: Int,
        RepoDigests: [String] = [],
        Created: Int = 0,
        Size: Int64 = 0,
        SharedSize: Int64 = -1,
        VirtualSize: Int64? = nil,
        Labels: [String: String] = [:]
    ) {
        self.Id = Id
        self.RepoTags = RepoTags
        self.RepoDigests = RepoDigests
        self.Created = Created
        self.Size = Size
        self.SharedSize = SharedSize
        self.VirtualSize = VirtualSize ?? Size
        self.Labels = Labels
        self.Containers = Containers
    }
}

struct DockerImageSearchOut: Codable, Sendable {
    let description: String
    let is_official: Bool
    let is_automated: Bool
    let name: String
    let star_count: Int
}

struct DockerContainerTopOut: Encodable, Sendable {
    let Titles: [String]
    let Processes: [[String]]
}

struct DockerContainerChangeOut: Encodable, Sendable {
    let Path: String
    let Kind: Int
}

struct DockerImageHistoryOut: Encodable, Sendable {
    let Id: String
    let Created: Int
    let CreatedBy: String
    let Tags: [String]
    let Size: Int64
    let Comment: String
}

struct DockerImageInspectOut: Encodable, Sendable {
    let Id: String
    let RepoTags: [String]
    let RepoDigests: [String]
    let Created: String
    let Size: Int64
    let VirtualSize: Int64
    let Architecture: String
    let Os: String
    let Config: DockerImageInspectConfigOut
}

struct DockerImageInspectConfigOut: Encodable, Sendable {
    let Env: [String]
    let Cmd: [String]?
    let Entrypoint: [String]?
    let WorkingDir: String
    let Labels: [String: String]
    let ExposedPorts: [String: DockerEmptyObject]
}

struct DockerErrorOut: Encodable, Sendable {
    let message: String
}

struct DockerNetworkOut: Encodable, Sendable {
    let Id: String
    let Name: String
    let Driver: String
    let Scope: String
    let Labels: [String: String]

    init(Id: String, Name: String, Driver: String, Scope: String, Labels: [String: String] = [:]) {
        self.Id = Id
        self.Name = Name
        self.Driver = Driver
        self.Scope = Scope
        self.Labels = Labels
    }
}

struct DockerNetworkInspectOut: Encodable, Sendable {
    let Name: String
    let Id: String
    let Created: String
    let Scope: String
    let Driver: String
    let EnableIPv6: Bool
    let IPAM: DockerNetworkInspectIPAMOut
    let Internal: Bool
    let Attachable: Bool
    let Ingress: Bool
    let ConfigFrom: DockerEmptyObject
    let ConfigOnly: Bool
    let Containers: [String: DockerEmptyObject]
    let Options: [String: String]
    let Labels: [String: String]
}

struct DockerNetworkInspectIPAMOut: Encodable, Sendable {
    let Driver: String
    let Options: [String: String]?
    let Config: [DockerNetworkInspectIPAMConfigOut]
}

struct DockerNetworkInspectIPAMConfigOut: Encodable, Sendable {
    let Subnet: String?
    let Gateway: String?
}

struct DockerVolumeOut: Encodable, Sendable {
    let Name: String
    let Driver: String
    let Mountpoint: String
    let Labels: [String: String]
    let Scope: String
    let Options: [String: String]

    init(
        Name: String,
        Driver: String,
        Mountpoint: String,
        Labels: [String: String] = [:],
        Scope: String = "local",
        Options: [String: String] = [:]
    ) {
        self.Name = Name
        self.Driver = Driver
        self.Mountpoint = Mountpoint
        self.Labels = Labels
        self.Scope = Scope
        self.Options = Options
    }
}

struct DockerVolumeListOut: Encodable, Sendable {
    let Volumes: [DockerVolumeOut]
}

struct DockerVolumeInspectOut: Encodable, Sendable {
    let CreatedAt: String
    let Driver: String
    let Labels: [String: String]
    let Mountpoint: String
    let Name: String
    let Options: [String: String]
    let Scope: String
}

struct DockerSystemDiskUsageOut: Codable, Sendable {
    let LayersSize: Int64
    let Images: [DockerSystemImageOut]
    let Containers: [DockerContainerOut]
    let Volumes: [DockerSystemVolumeOut]
    let BuildCache: [DockerSystemBuildCacheOut]
}

struct DockerSystemImageOut: Codable, Sendable {
    let Id: String
    let ParentId: String
    let RepoTags: [String]
    let RepoDigests: [String]
    let Created: Int
    let Size: Int64
    let SharedSize: Int64
    let VirtualSize: Int64
    let Labels: [String: String]
    let Containers: Int
}

struct DockerSystemVolumeOut: Codable, Sendable {
    let Name: String
    let Driver: String
    let Mountpoint: String
    let CreatedAt: String
    let Labels: [String: String]
    let Scope: String
    let Options: [String: String]
    let UsageData: DockerSystemVolumeUsageOut
}

struct DockerSystemVolumeUsageOut: Codable, Sendable {
    let Size: Int64
    let RefCount: Int
}

struct DockerSystemBuildCacheOut: Codable, Sendable {}

struct DockerVolumeCreateRequest: Decodable, Sendable {
    var Name: String?
    var Driver: String?
    var DriverOpts: [String: String]?
    var Labels: [String: String]?
}

struct DockerVolumePruneOut: Encodable, Sendable {
    let VolumesDeleted: [String]
    let SpaceReclaimed: Int64
}

struct DockerContainerPruneOut: Codable, Sendable {
    let ContainersDeleted: [String]
    let SpaceReclaimed: Int64
}

struct DockerNetworkPruneOut: Codable, Sendable {
    let NetworksDeleted: [String]
    let SpaceReclaimed: Int64
}

struct DockerImageDeleteOut: Codable, Sendable {
    let Deleted: String?
    let Untagged: String?
}

struct DockerImagePruneOut: Encodable, Sendable {
    let ImagesDeleted: [DockerImageDeleteOut]
    let SpaceReclaimed: Int64
}

struct DockerCommitRequest: Decodable, Sendable {
    var Labels: [String: String]?
    var Config: DockerCommitConfig?

    var labels: [String: String] {
        Labels ?? Config?.Labels ?? [:]
    }
}

struct DockerCommitConfig: Decodable, Sendable {
    var Labels: [String: String]?
}

struct DockerCommitOut: Codable, Sendable {
    let Id: String
}

struct DockerImageLoadOut: Encodable, Sendable {
    let stream: String
}

struct DockerAuthRequest: Decodable, Sendable {
    var username: String?
    var password: String?
    var serveraddress: String?
    var auth: String?

    var decodedCredentials: (username: String, password: String)? {
        let user = username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !user.isEmpty, let password {
            return (user, password)
        }
        guard let auth,
              let data = Data(base64Encoded: auth),
              let decoded = String(data: data, encoding: .utf8) else { return nil }
        let parts = decoded.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty else { return nil }
        return (parts[0], parts[1])
    }

    var registry: String {
        DockerRegistry.normalizeRegistry(serveraddress ?? "")
    }
}

struct DockerAuthOut: Codable, Sendable {
    let Status: String
}

struct DockerInspectStateOut: Encodable, Sendable {
    let Running: Bool
    let Paused: Bool
    let Status: String
    let ExitCode: Int
}

struct DockerInspectConfigOut: Encodable, Sendable {
    let Hostname: String
    let Domainname: String
    let User: String
    let AttachStdin: Bool
    let AttachStdout: Bool
    let AttachStderr: Bool
    let Image: String
    let Cmd: [String]?
    let Env: [String]
    let Entrypoint: [String]?
    let Labels: [String: String]
    let ExposedPorts: [String: DockerEmptyObject]
    let Volumes: [String: DockerEmptyObject]?
    let Healthcheck: DockerHealthConfig?
    let WorkingDir: String
    let Tty: Bool
    let OpenStdin: Bool
    let StdinOnce: Bool
    let NetworkDisabled: Bool?
    let StopSignal: String?
    let StopTimeout: Int?
    let Shell: [String]?
}

struct DockerHostBindingOut: Encodable, Sendable {
    let HostIp: String
    let HostPort: String
}

struct DockerInspectNetOut: Encodable, Sendable {
    let IPAddress: String
    let Ports: [String: [DockerHostBindingOut]]
    let Networks: [String: DockerEndpointSettings]
}

struct DockerHostMountOut: Encodable, Sendable {
    let type: String
    let source: String?
    let target: String
    let readOnly: Bool?

    enum CodingKeys: String, CodingKey {
        case type = "Type", source = "Source", target = "Target", readOnly = "ReadOnly"
    }

    nonisolated init(_ mount: ContainerMount) {
        type = mount.type
        source = mount.source
        target = mount.target
        readOnly = mount.readOnly ? true : nil
    }
}

struct DockerInspectMountOut: Codable, Sendable {
    let type: String
    let name: String?
    let source: String
    let destination: String
    let driver: String
    let mode: String
    let rw: Bool
    let propagation: String

    enum CodingKeys: String, CodingKey {
        case type = "Type", name = "Name", source = "Source", destination = "Destination"
        case driver = "Driver", mode = "Mode", rw = "RW", propagation = "Propagation"
    }

    nonisolated static func legacyBind(_ raw: String) -> DockerInspectMountOut? {
        let parts = raw.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return nil }
        let mode = parts.count == 3 ? parts[2] : ""
        let readOnly = mode.split(separator: ",").contains("ro")
        return DockerInspectMountOut(
            type: "bind",
            name: nil,
            source: parts[0],
            destination: parts[1],
            driver: "",
            mode: mode,
            rw: !readOnly,
            propagation: "rprivate"
        )
    }

    nonisolated static func volumeTarget(_ target: String) -> DockerInspectMountOut {
        let name = "dory-anon-\(target.trimmingCharacters(in: CharacterSet(charactersIn: "/")).replacingOccurrences(of: "/", with: "_"))"
        return DockerInspectMountOut(
            type: "volume",
            name: name,
            source: "/var/lib/dory/volumes/\(name)/_data",
            destination: target,
            driver: "local",
            mode: "",
            rw: true,
            propagation: ""
        )
    }

    nonisolated static func mount(_ mount: ContainerMount) -> DockerInspectMountOut? {
        guard !mount.target.isEmpty else { return nil }
        switch mount.type.lowercased() {
        case "bind":
            guard let source = mount.source, !source.isEmpty else { return nil }
            return DockerInspectMountOut(
                type: "bind",
                name: nil,
                source: source,
                destination: mount.target,
                driver: "",
                mode: mount.readOnly ? "ro" : "",
                rw: !mount.readOnly,
                propagation: "rprivate"
            )
        case "tmpfs":
            return DockerInspectMountOut(
                type: "tmpfs",
                name: nil,
                source: "",
                destination: mount.target,
                driver: "",
                mode: mount.readOnly ? "ro" : "",
                rw: !mount.readOnly,
                propagation: ""
            )
        default:
            let name = mount.source?.isEmpty == false ? mount.source! : "dory-anon-\(mount.target.trimmingCharacters(in: CharacterSet(charactersIn: "/")).replacingOccurrences(of: "/", with: "_"))"
            return DockerInspectMountOut(
                type: "volume",
                name: name,
                source: "/var/lib/dory/volumes/\(name)/_data",
                destination: mount.target,
                driver: "local",
                mode: mount.readOnly ? "ro" : "",
                rw: !mount.readOnly,
                propagation: ""
            )
        }
    }
}

struct DockerHostConfigOut: Encodable, Sendable {
    let NetworkMode: String
    let PortBindings: [String: [DockerHostBindingOut]]
    let RestartPolicy: DockerRestartPolicyBody
    let Binds: [String]?
    let Mounts: [DockerHostMountOut]?
    let ContainerIDFile: String?
    let LogConfig: DockerLogConfig?
    let VolumeDriver: String?
    let VolumesFrom: [String]?
    let ConsoleSize: [Int]?
    let Annotations: [String: String]?
    let NanoCpus: Int64?
    let CpuShares: Int64?
    let CgroupParent: String?
    let CpuPeriod: Int64?
    let CpuQuota: Int64?
    let CpuRealtimePeriod: Int64?
    let CpuRealtimeRuntime: Int64?
    let CpusetCpus: String?
    let CpusetMems: String?
    let Devices: [DockerDeviceMapping]?
    let DeviceCgroupRules: [String]?
    let DeviceRequests: [DockerDeviceRequest]?
    let Memory: Int64?
    let KernelMemoryTCP: Int64?
    let MemoryReservation: Int64?
    let MemorySwap: Int64?
    let MemorySwappiness: Int64?
    let OomKillDisable: Bool?
    let Init: Bool?
    let PidsLimit: Int64?
    let BlkioWeight: Int64?
    let BlkioWeightDevice: [DockerBlkioWeightDevice]?
    let BlkioDeviceReadBps: [DockerThrottleDevice]?
    let BlkioDeviceWriteBps: [DockerThrottleDevice]?
    let BlkioDeviceReadIOps: [DockerThrottleDevice]?
    let BlkioDeviceWriteIOps: [DockerThrottleDevice]?
    let CpuCount: Int64?
    let CpuPercent: Int64?
    let IOMaximumIOps: Int64?
    let IOMaximumBandwidth: Int64?
    let AutoRemove: Bool?
    let Privileged: Bool?
    let CapAdd: [String]?
    let CapDrop: [String]?
    let CgroupnsMode: String?
    let Dns: [String]?
    let DnsOptions: [String]?
    let DnsSearch: [String]?
    let ExtraHosts: [String]?
    let GroupAdd: [String]?
    let IpcMode: String?
    let Cgroup: String?
    let Links: [String]?
    let OomScoreAdj: Int?
    let PublishAllPorts: Bool?
    let PidMode: String?
    let UsernsMode: String?
    let ReadonlyRootfs: Bool?
    let SecurityOpt: [String]?
    let StorageOpt: [String: String]?
    let ShmSize: Int64?
    let Tmpfs: [String: String]?
    let UTSMode: String?
    let Sysctls: [String: String]?
    let Runtime: String?
    let Isolation: String?
    let MaskedPaths: [String]?
    let ReadonlyPaths: [String]?
    let Ulimits: [DockerUlimit]?

    init(
        container: Container,
        networkMode: String,
        portBindings: [String: [DockerHostBindingOut]],
        binds: [String],
        mounts: [ContainerMount]
    ) {
        NetworkMode = networkMode
        PortBindings = portBindings
        RestartPolicy = Self.restartPolicy(container)
        Binds = Self.nilIfEmpty(binds)
        Mounts = mounts.isEmpty ? nil : mounts.map(DockerHostMountOut.init)
        ContainerIDFile = container.containerIDFile
        LogConfig = container.logConfig
        VolumeDriver = container.volumeDriver
        VolumesFrom = Self.nilIfEmpty(container.volumesFrom)
        ConsoleSize = Self.nilIfEmpty(container.consoleSize)
        Annotations = Self.nilIfEmpty(container.annotations)
        NanoCpus = container.resources.nanoCPUs ?? container.nanoCPUs
        CpuShares = container.resources.cpuShares
        CgroupParent = container.resources.cgroupParent
        CpuPeriod = container.resources.cpuPeriod
        CpuQuota = container.resources.cpuQuota
        CpuRealtimePeriod = container.resources.cpuRealtimePeriod
        CpuRealtimeRuntime = container.resources.cpuRealtimeRuntime
        CpusetCpus = container.resources.cpusetCPUs
        CpusetMems = container.resources.cpusetMems
        Devices = container.resources.devices
        DeviceCgroupRules = container.resources.deviceCgroupRules
        DeviceRequests = container.resources.deviceRequests
        Memory = container.resources.memoryLimitBytes ?? container.memoryLimitBytes
        KernelMemoryTCP = container.resources.kernelMemoryTCPBytes
        MemoryReservation = container.resources.memoryReservationBytes
        MemorySwap = container.resources.memorySwapBytes
        MemorySwappiness = container.resources.memorySwappiness
        OomKillDisable = container.resources.oomKillDisable
        Init = container.initProcessEnabled ?? container.resources.initProcessEnabled
        PidsLimit = container.resources.pidsLimit
        BlkioWeight = container.resources.blkioWeight
        BlkioWeightDevice = container.resources.blkioWeightDevice
        BlkioDeviceReadBps = container.resources.blkioDeviceReadBps
        BlkioDeviceWriteBps = container.resources.blkioDeviceWriteBps
        BlkioDeviceReadIOps = container.resources.blkioDeviceReadIOps
        BlkioDeviceWriteIOps = container.resources.blkioDeviceWriteIOps
        CpuCount = container.resources.cpuCount
        CpuPercent = container.resources.cpuPercent
        IOMaximumIOps = container.resources.ioMaximumIOps
        IOMaximumBandwidth = container.resources.ioMaximumBandwidth
        AutoRemove = container.autoRemove
        Privileged = container.privileged
        CapAdd = Self.nilIfEmpty(container.capAdd)
        CapDrop = Self.nilIfEmpty(container.capDrop)
        CgroupnsMode = container.cgroupnsMode
        Dns = Self.nilIfEmpty(container.dns)
        DnsOptions = Self.nilIfEmpty(container.dnsOptions)
        DnsSearch = Self.nilIfEmpty(container.dnsSearch)
        ExtraHosts = Self.nilIfEmpty(container.extraHosts)
        GroupAdd = Self.nilIfEmpty(container.groupAdd)
        IpcMode = container.ipcMode
        Cgroup = container.cgroup
        Links = Self.nilIfEmpty(container.links)
        OomScoreAdj = container.oomScoreAdj
        PublishAllPorts = container.publishAllPorts
        PidMode = container.pidMode
        UsernsMode = container.usernsMode
        ReadonlyRootfs = container.readonlyRootfs
        SecurityOpt = Self.nilIfEmpty(container.securityOpt)
        StorageOpt = Self.nilIfEmpty(container.storageOpt)
        ShmSize = container.shmSize
        Tmpfs = Self.nilIfEmpty(container.tmpfs)
        UTSMode = container.utsMode
        Sysctls = Self.nilIfEmpty(container.sysctls)
        Runtime = container.runtimeName
        Isolation = container.isolation
        MaskedPaths = Self.nilIfEmpty(container.maskedPaths)
        ReadonlyPaths = Self.nilIfEmpty(container.readonlyPaths)
        Ulimits = container.resources.ulimits
    }

    private static func restartPolicy(_ container: Container) -> DockerRestartPolicyBody {
        let name = container.resources.restartPolicy ?? container.restartPolicy
        let normalized = name.isEmpty || name == "—" ? "no" : name
        return DockerRestartPolicyBody(Name: normalized, MaximumRetryCount: container.resources.restartMaximumRetryCount)
    }

    private static func nilIfEmpty<T>(_ values: [T]) -> [T]? {
        values.isEmpty ? nil : values
    }

    private static func nilIfEmpty<T>(_ values: [String: T]) -> [String: T]? {
        values.isEmpty ? nil : values
    }
}

struct DockerInspectOut: Encodable, Sendable {
    let Id: String
    let Name: String
    let Image: String
    let Created: String
    let State: DockerInspectStateOut
    let Config: DockerInspectConfigOut
    let NetworkSettings: DockerInspectNetOut
    let HostConfig: DockerHostConfigOut
    let Mounts: [DockerInspectMountOut]
    let SizeRw: Int64?
    let SizeRootFs: Int64?
}

struct DockerContainerUpdateRequest: Decodable, Sendable {
    var NanoCpus: Int64?
    var CpuShares: Int64?
    var CgroupParent: String?
    var CpuPeriod: Int64?
    var CpuQuota: Int64?
    var CpuRealtimePeriod: Int64?
    var CpuRealtimeRuntime: Int64?
    var CpusetCpus: String?
    var CpusetMems: String?
    var Devices: [DockerDeviceMapping]?
    var DeviceCgroupRules: [String]?
    var DeviceRequests: [DockerDeviceRequest]?
    var Memory: Int64?
    var KernelMemoryTCP: Int64?
    var MemoryReservation: Int64?
    var MemorySwap: Int64?
    var MemorySwappiness: Int64?
    var OomKillDisable: Bool?
    var Init: Bool?
    var PidsLimit: Int64?
    var BlkioWeight: Int64?
    var BlkioWeightDevice: [DockerBlkioWeightDevice]?
    var BlkioDeviceReadBps: [DockerThrottleDevice]?
    var BlkioDeviceWriteBps: [DockerThrottleDevice]?
    var BlkioDeviceReadIOps: [DockerThrottleDevice]?
    var BlkioDeviceWriteIOps: [DockerThrottleDevice]?
    var CpuCount: Int64?
    var CpuPercent: Int64?
    var IOMaximumIOps: Int64?
    var IOMaximumBandwidth: Int64?
    var RestartPolicy: DockerInboundRestart?
    var Ulimits: [DockerUlimit]?

    var resources: ContainerResourceUpdate {
        ContainerResourceUpdate(
            nanoCPUs: NanoCpus,
            cpuShares: CpuShares,
            cgroupParent: CgroupParent,
            cpuPeriod: CpuPeriod,
            cpuQuota: CpuQuota,
            cpuRealtimePeriod: CpuRealtimePeriod,
            cpuRealtimeRuntime: CpuRealtimeRuntime,
            cpusetCPUs: CpusetCpus,
            cpusetMems: CpusetMems,
            devices: Devices,
            deviceCgroupRules: DeviceCgroupRules,
            deviceRequests: DeviceRequests,
            memoryLimitBytes: Memory,
            kernelMemoryTCPBytes: KernelMemoryTCP,
            memoryReservationBytes: MemoryReservation,
            memorySwapBytes: MemorySwap,
            memorySwappiness: MemorySwappiness,
            oomKillDisable: OomKillDisable,
            initProcessEnabled: Init,
            pidsLimit: PidsLimit,
            blkioWeight: BlkioWeight,
            blkioWeightDevice: BlkioWeightDevice,
            blkioDeviceReadBps: BlkioDeviceReadBps,
            blkioDeviceWriteBps: BlkioDeviceWriteBps,
            blkioDeviceReadIOps: BlkioDeviceReadIOps,
            blkioDeviceWriteIOps: BlkioDeviceWriteIOps,
            cpuCount: CpuCount,
            cpuPercent: CpuPercent,
            ioMaximumIOps: IOMaximumIOps,
            ioMaximumBandwidth: IOMaximumBandwidth,
            restartPolicy: RestartPolicy?.Name,
            restartMaximumRetryCount: RestartPolicy?.MaximumRetryCount,
            ulimits: Ulimits
        )
    }
}

struct DockerContainerUpdateOut: Codable, Sendable {
    let Warnings: [String]
}

// MARK: Incoming request bodies (docker create / network create)

struct DockerCreateRequest: Decodable, Sendable {
    var Hostname: String?
    var Domainname: String?
    var User: String?
    var AttachStdin: Bool?
    var AttachStdout: Bool?
    var AttachStderr: Bool?
    var Image: String?
    var Cmd: DockerFlexibleStringList?
    var Entrypoint: DockerFlexibleStringList?
    var Env: [String]?
    var Labels: [String: String]?
    var ExposedPorts: [String: DockerEmptyObject]?
    var Volumes: [String: DockerEmptyObject]?
    var Healthcheck: DockerHealthConfig?
    var WorkingDir: String?
    var Tty: Bool?
    var OpenStdin: Bool?
    var StdinOnce: Bool?
    var NetworkDisabled: Bool?
    var StopSignal: String?
    var StopTimeout: Int?
    var Shell: [String]?
    var HostConfig: DockerCreateHostConfig?
    var NetworkingConfig: DockerCreateNetworkingConfig?

    func spec(name: String?, platform: String? = nil) -> ContainerSpec {
        var environment: [String: String] = [:]
        for entry in Env ?? [] {
            if let eq = entry.firstIndex(of: "=") {
                environment[String(entry[entry.startIndex..<eq])] = String(entry[entry.index(after: eq)...])
            }
        }
        let requestedPlatform = platform?.trimmingCharacters(in: .whitespacesAndNewlines)
        let ports = Self.ports(from: ExposedPorts ?? [:], bindings: HostConfig?.PortBindings ?? [:])
        let endpoints = NetworkingConfig?.EndpointsConfig ?? [:]
        let networks = endpoints.keys.sorted()
        return ContainerSpec(
            name: name?.isEmpty == false ? name! : "dory-\(UUID().uuidString.prefix(12))",
            image: Image ?? "",
            platform: requestedPlatform?.isEmpty == false ? requestedPlatform : nil,
            command: Cmd?.values ?? [],
            environment: environment,
            ports: ports,
            labels: Labels ?? [:],
            networks: networks,
            networkAliases: Dictionary(uniqueKeysWithValues: endpoints.compactMap { entry in
                guard let aliases = entry.value.Aliases, !aliases.isEmpty else { return nil }
                return (entry.key, aliases)
            }),
            networkEndpointSettings: endpoints,
            volumes: HostConfig?.Binds ?? [],
            restart: HostConfig?.RestartPolicy?.Name,
            nanoCPUs: HostConfig?.NanoCpus,
            memoryLimitBytes: HostConfig?.Memory,
            mounts: HostConfig?.Mounts?.compactMap(\.containerMount) ?? [],
            volumeTargets: (Volumes ?? [:]).keys.sorted(),
            hostname: Hostname,
            domainname: Domainname,
            user: User,
            workingDir: WorkingDir,
            entrypoint: Entrypoint?.values ?? [],
            shell: Shell ?? [],
            tty: Tty ?? false,
            openStdin: OpenStdin ?? false,
            stdinOnce: StdinOnce ?? false,
            stopSignal: StopSignal,
            stopTimeout: StopTimeout,
            networkMode: HostConfig?.NetworkMode,
            autoRemove: HostConfig?.AutoRemove,
            privileged: HostConfig?.Privileged,
            initProcessEnabled: HostConfig?.Init,
            capAdd: HostConfig?.CapAdd ?? [],
            capDrop: HostConfig?.CapDrop ?? [],
            dns: HostConfig?.Dns ?? [],
            dnsOptions: HostConfig?.DnsOptions ?? [],
            dnsSearch: HostConfig?.DnsSearch ?? [],
            extraHosts: HostConfig?.ExtraHosts ?? [],
            groupAdd: HostConfig?.GroupAdd ?? [],
            ipcMode: HostConfig?.IpcMode,
            pidMode: HostConfig?.PidMode,
            usernsMode: HostConfig?.UsernsMode,
            readonlyRootfs: HostConfig?.ReadonlyRootfs,
            shmSize: HostConfig?.ShmSize,
            tmpfs: HostConfig?.Tmpfs ?? [:],
            attachStdin: AttachStdin,
            attachStdout: AttachStdout,
            attachStderr: AttachStderr,
            healthcheck: Healthcheck,
            networkDisabled: NetworkDisabled,
            containerIDFile: HostConfig?.ContainerIDFile,
            logConfig: HostConfig?.LogConfig,
            volumeDriver: HostConfig?.VolumeDriver,
            volumesFrom: HostConfig?.VolumesFrom ?? [],
            consoleSize: HostConfig?.ConsoleSize ?? [],
            annotations: HostConfig?.Annotations ?? [:],
            cgroupnsMode: HostConfig?.CgroupnsMode,
            cgroup: HostConfig?.Cgroup,
            links: HostConfig?.Links ?? [],
            oomScoreAdj: HostConfig?.OomScoreAdj,
            publishAllPorts: HostConfig?.PublishAllPorts,
            securityOpt: HostConfig?.SecurityOpt ?? [],
            storageOpt: HostConfig?.StorageOpt ?? [:],
            utsMode: HostConfig?.UTSMode,
            sysctls: HostConfig?.Sysctls ?? [:],
            runtimeName: HostConfig?.Runtime,
            isolation: HostConfig?.Isolation,
            maskedPaths: HostConfig?.MaskedPaths ?? [],
            readonlyPaths: HostConfig?.ReadonlyPaths ?? [],
            resources: HostConfig?.resources ?? ContainerResourceUpdate(
                nanoCPUs: HostConfig?.NanoCpus,
                memoryLimitBytes: HostConfig?.Memory,
                restartPolicy: HostConfig?.RestartPolicy?.Name,
                restartMaximumRetryCount: HostConfig?.RestartPolicy?.MaximumRetryCount
            )
        )
    }

    private static func ports(
        from exposedPorts: [String: DockerEmptyObject],
        bindings: [String: [DockerInboundBinding]?]
    ) -> [String] {
        var ports: [String] = []
        var seen = Set<String>()
        for key in bindings.keys.sorted() {
            let bindingList: [DockerInboundBinding]? = bindings[key] ?? nil
            let specs = bindingList?.map { portSpec(key: key, binding: $0) } ?? [portSpec(key: key, binding: nil)]
            for spec in specs where seen.insert(spec).inserted { ports.append(spec) }
        }
        for key in exposedPorts.keys.sorted() {
            let spec = portSpec(key: key, binding: nil)
            if seen.insert(spec).inserted { ports.append(spec) }
        }
        return ports
    }

    private static func portSpec(key: String, binding: DockerInboundBinding?) -> String {
        let pieces = key.split(separator: "/", maxSplits: 1).map(String.init)
        let port = pieces.first ?? key
        let proto = pieces.count > 1 ? pieces[1].lowercased() : "tcp"
        let target = proto == "tcp" ? port : "\(port)/\(proto)"
        guard let host = binding?.HostPort, !host.isEmpty else { return target }
        if let hostIP = binding?.HostIp, !hostIP.isEmpty {
            return "\(publishHostIP(hostIP)):\(host):\(target)"
        }
        return "\(host):\(target)"
    }

    private static func publishHostIP(_ hostIP: String) -> String {
        if hostIP.contains(":"), !hostIP.hasPrefix("[") {
            return "[\(hostIP)]"
        }
        return hostIP
    }
}

struct DockerCreateNetworkingConfig: Codable, Sendable {
    var EndpointsConfig: [String: DockerEndpointSettings]?
}

struct DockerEndpointIPAMConfig: Codable, Sendable, Equatable, Hashable {
    var IPv4Address: String? = nil
    var IPv6Address: String? = nil
    var LinkLocalIPs: [String]? = nil
}

struct DockerEndpointSettings: Codable, Sendable, Equatable, Hashable {
    var IPAMConfig: DockerEndpointIPAMConfig? = nil
    var Links: [String]? = nil
    var Aliases: [String]? = nil
    var NetworkID: String? = nil
    var EndpointID: String? = nil
    var Gateway: String? = nil
    var IPAddress: String? = nil
    var IPPrefixLen: Int? = nil
    var IPv6Gateway: String? = nil
    var GlobalIPv6Address: String? = nil
    var GlobalIPv6PrefixLen: Int? = nil
    var MacAddress: String? = nil
    var DriverOpts: [String: String]? = nil
}

struct DockerCreateHostConfig: Decodable, Sendable {
    var PortBindings: [String: [DockerInboundBinding]?]?
    var RestartPolicy: DockerInboundRestart?
    var Binds: [String]?
    var Mounts: [DockerInboundMount]?
    var ContainerIDFile: String?
    var LogConfig: DockerLogConfig?
    var VolumeDriver: String?
    var VolumesFrom: [String]?
    var ConsoleSize: [Int]?
    var Annotations: [String: String]?
    var NanoCpus: Int64?
    var CpuShares: Int64?
    var CgroupParent: String?
    var CpuPeriod: Int64?
    var CpuQuota: Int64?
    var CpuRealtimePeriod: Int64?
    var CpuRealtimeRuntime: Int64?
    var CpusetCpus: String?
    var CpusetMems: String?
    var Devices: [DockerDeviceMapping]?
    var DeviceCgroupRules: [String]?
    var DeviceRequests: [DockerDeviceRequest]?
    var Memory: Int64?
    var KernelMemoryTCP: Int64?
    var MemoryReservation: Int64?
    var MemorySwap: Int64?
    var MemorySwappiness: Int64?
    var OomKillDisable: Bool?
    var PidsLimit: Int64?
    var BlkioWeight: Int64?
    var BlkioWeightDevice: [DockerBlkioWeightDevice]?
    var BlkioDeviceReadBps: [DockerThrottleDevice]?
    var BlkioDeviceWriteBps: [DockerThrottleDevice]?
    var BlkioDeviceReadIOps: [DockerThrottleDevice]?
    var BlkioDeviceWriteIOps: [DockerThrottleDevice]?
    var CpuCount: Int64?
    var CpuPercent: Int64?
    var IOMaximumIOps: Int64?
    var IOMaximumBandwidth: Int64?
    var AutoRemove: Bool?
    var Privileged: Bool?
    var Init: Bool?
    var CapAdd: [String]?
    var CapDrop: [String]?
    var CgroupnsMode: String?
    var Dns: [String]?
    var DnsOptions: [String]?
    var DnsSearch: [String]?
    var ExtraHosts: [String]?
    var GroupAdd: [String]?
    var IpcMode: String?
    var Cgroup: String?
    var Links: [String]?
    var OomScoreAdj: Int?
    var PublishAllPorts: Bool?
    var NetworkMode: String?
    var PidMode: String?
    var UsernsMode: String?
    var ReadonlyRootfs: Bool?
    var SecurityOpt: [String]?
    var StorageOpt: [String: String]?
    var ShmSize: Int64?
    var Tmpfs: [String: String]?
    var UTSMode: String?
    var Sysctls: [String: String]?
    var Runtime: String?
    var Isolation: String?
    var MaskedPaths: [String]?
    var ReadonlyPaths: [String]?
    var Ulimits: [DockerUlimit]?

    var resources: ContainerResourceUpdate {
        ContainerResourceUpdate(
            nanoCPUs: NanoCpus,
            cpuShares: CpuShares,
            cgroupParent: CgroupParent,
            cpuPeriod: CpuPeriod,
            cpuQuota: CpuQuota,
            cpuRealtimePeriod: CpuRealtimePeriod,
            cpuRealtimeRuntime: CpuRealtimeRuntime,
            cpusetCPUs: CpusetCpus,
            cpusetMems: CpusetMems,
            devices: Devices,
            deviceCgroupRules: DeviceCgroupRules,
            deviceRequests: DeviceRequests,
            memoryLimitBytes: Memory,
            kernelMemoryTCPBytes: KernelMemoryTCP,
            memoryReservationBytes: MemoryReservation,
            memorySwapBytes: MemorySwap,
            memorySwappiness: MemorySwappiness,
            oomKillDisable: OomKillDisable,
            initProcessEnabled: Init,
            pidsLimit: PidsLimit,
            blkioWeight: BlkioWeight,
            blkioWeightDevice: BlkioWeightDevice,
            blkioDeviceReadBps: BlkioDeviceReadBps,
            blkioDeviceWriteBps: BlkioDeviceWriteBps,
            blkioDeviceReadIOps: BlkioDeviceReadIOps,
            blkioDeviceWriteIOps: BlkioDeviceWriteIOps,
            cpuCount: CpuCount,
            cpuPercent: CpuPercent,
            ioMaximumIOps: IOMaximumIOps,
            ioMaximumBandwidth: IOMaximumBandwidth,
            restartPolicy: RestartPolicy?.Name,
            restartMaximumRetryCount: RestartPolicy?.MaximumRetryCount,
            ulimits: Ulimits
        )
    }
}

struct DockerFlexibleStringList: Decodable, Sendable {
    var values: [String]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let list = try? container.decode([String].self) {
            values = list
        } else if let item = try? container.decode(String.self), !item.isEmpty {
            values = [item]
        } else {
            values = []
        }
    }
}

struct DockerInboundBinding: Decodable, Sendable {
    var HostIp: String?
    var HostPort: String?
}
struct DockerInboundRestart: Decodable, Sendable {
    var Name: String?
    var MaximumRetryCount: Int?
}
struct DockerInboundMount: Decodable, Sendable {
    var type: String?
    var source: String?
    var target: String?
    var destination: String?
    var name: String?
    var readOnly: Bool?
    var rw: Bool?

    enum CodingKeys: String, CodingKey {
        case type = "Type", source = "Source", target = "Target", destination = "Destination"
        case name = "Name", readOnly = "ReadOnly", rw = "RW"
    }

    var containerMount: ContainerMount? {
        let target = target ?? destination
        guard let target, !target.isEmpty else { return nil }
        return ContainerMount(
            type: (type ?? "volume").lowercased(),
            source: source ?? name,
            target: target,
            readOnly: readOnly ?? rw.map { !$0 } ?? false
        )
    }
}

struct DockerCreateContainerOut: Encodable, Sendable {
    let Id: String
    let Warnings: [String]
}

struct DockerNetworkCreateRequest: Decodable, Sendable {
    var Name: String
    var Labels: [String: String]?
}

struct DockerNetworkConnectRequest: Codable, Sendable {
    var Container: String?
}

struct DockerNetworkDisconnectRequest: Codable, Sendable {
    var Container: String?
    var Force: Bool?
}

struct DockerNetworkCreatedOut: Encodable, Sendable {
    let Id: String
    let Warning: String
}

struct DockerPathStat: Encodable, Sendable {
    let name: String
    let size: Int
    let mode: Int
}

struct DockerExecCreateRequest: Decodable, Sendable {
    var Cmd: [String]?
}

struct DockerExecCreatedOut: Encodable, Sendable {
    let Id: String
}

struct DockerExecInspectOut: Encodable, Sendable {
    let ExitCode: Int
    let Running: Bool
}

struct DockerEventActor: Encodable, Sendable {
    let ID: String
    let Attributes: [String: String]
}

struct DockerEventOut: Encodable, Sendable {
    let eventType: String
    let Action: String
    let Actor: DockerEventActor
    let time: Int
    let timeNano: Int64
    enum CodingKeys: String, CodingKey { case eventType = "Type", Action, Actor, time, timeNano }
}

struct DockerStatsCPUUsageOut: Encodable, Sendable {
    let total_usage: Int64
    let percpu_usage: [Int64]
    let usage_in_kernelmode: Int64
    let usage_in_usermode: Int64
}

struct DockerStatsCPUOut: Encodable, Sendable {
    let cpu_usage: DockerStatsCPUUsageOut
    let system_cpu_usage: Int64
    let online_cpus: Int
}

struct DockerStatsMemoryOut: Encodable, Sendable {
    let usage: Int64
    let max_usage: Int64
    let limit: Int64
    let stats: [String: Int64]
}

struct DockerStatsPIDsOut: Encodable, Sendable {
    let current: Int
}

struct DockerStatsNetworkOut: Encodable, Sendable {
    let rx_bytes: Int64
    let tx_bytes: Int64
}

struct DockerContainerStatsOut: Encodable, Sendable {
    let read: String
    let preread: String
    let name: String
    let id: String
    let cpu_stats: DockerStatsCPUOut
    let precpu_stats: DockerStatsCPUOut
    let memory_stats: DockerStatsMemoryOut
    let pids_stats: DockerStatsPIDsOut
    let networks: [String: DockerStatsNetworkOut]

    static func make(container: Container, cpuPercent: Double, memoryLimit: Int64, read: String, cpus: Int) -> DockerContainerStatsOut {
        let safeCPUs = max(1, cpus)
        let systemDelta: Int64 = 1_000_000_000
        let previousSystem: Int64 = 10_000_000_000
        let previousCPU: Int64 = 1_000_000_000
        let cpuDelta = max(0, Int64((max(0, cpuPercent) / 100.0 / Double(safeCPUs)) * Double(systemDelta)))
        let previous = DockerStatsCPUOut(
            cpu_usage: DockerStatsCPUUsageOut(
                total_usage: previousCPU,
                percpu_usage: Array(repeating: previousCPU / Int64(safeCPUs), count: safeCPUs),
                usage_in_kernelmode: 0,
                usage_in_usermode: previousCPU
            ),
            system_cpu_usage: previousSystem,
            online_cpus: safeCPUs
        )
        let current = DockerStatsCPUOut(
            cpu_usage: DockerStatsCPUUsageOut(
                total_usage: previousCPU + cpuDelta,
                percpu_usage: Array(repeating: (previousCPU + cpuDelta) / Int64(safeCPUs), count: safeCPUs),
                usage_in_kernelmode: 0,
                usage_in_usermode: previousCPU + cpuDelta
            ),
            system_cpu_usage: previousSystem + systemDelta,
            online_cpus: safeCPUs
        )
        let usage = max(0, container.memoryBytes)
        return DockerContainerStatsOut(
            read: read,
            preread: read,
            name: "/\(container.name)",
            id: container.id,
            cpu_stats: current,
            precpu_stats: previous,
            memory_stats: DockerStatsMemoryOut(usage: usage, max_usage: usage, limit: max(memoryLimit, usage), stats: [:]),
            pids_stats: DockerStatsPIDsOut(current: container.isRunning ? 1 : 0),
            networks: ["eth0": DockerStatsNetworkOut(rx_bytes: 0, tx_bytes: 0)]
        )
    }
}
