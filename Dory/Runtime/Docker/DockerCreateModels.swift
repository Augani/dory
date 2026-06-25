import Foundation

struct DockerEmptyObject: Codable, Sendable {}

struct DockerPortBinding: Encodable, Sendable {
    let HostIp: String?
    let HostPort: String

    init(HostPort: String, HostIp: String? = nil) {
        self.HostIp = HostIp
        self.HostPort = HostPort
    }
}

struct DockerRestartPolicyBody: Encodable, Sendable {
    let Name: String
    let MaximumRetryCount: Int?

    init(Name: String, MaximumRetryCount: Int? = nil) {
        self.Name = Name
        self.MaximumRetryCount = MaximumRetryCount
    }
}

struct DockerContainerUpdateBody: Encodable, Sendable {
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
    let RestartPolicy: DockerRestartPolicyBody?
    let Ulimits: [DockerUlimit]?

    init(resources: ContainerResourceUpdate) {
        NanoCpus = resources.nanoCPUs
        CpuShares = resources.cpuShares
        CgroupParent = resources.cgroupParent
        CpuPeriod = resources.cpuPeriod
        CpuQuota = resources.cpuQuota
        CpuRealtimePeriod = resources.cpuRealtimePeriod
        CpuRealtimeRuntime = resources.cpuRealtimeRuntime
        CpusetCpus = resources.cpusetCPUs
        CpusetMems = resources.cpusetMems
        Devices = resources.devices
        DeviceCgroupRules = resources.deviceCgroupRules
        DeviceRequests = resources.deviceRequests
        Memory = resources.memoryLimitBytes
        KernelMemoryTCP = resources.kernelMemoryTCPBytes
        MemoryReservation = resources.memoryReservationBytes
        MemorySwap = resources.memorySwapBytes
        MemorySwappiness = resources.memorySwappiness
        OomKillDisable = resources.oomKillDisable
        Init = resources.initProcessEnabled
        PidsLimit = resources.pidsLimit
        BlkioWeight = resources.blkioWeight
        BlkioWeightDevice = resources.blkioWeightDevice
        BlkioDeviceReadBps = resources.blkioDeviceReadBps
        BlkioDeviceWriteBps = resources.blkioDeviceWriteBps
        BlkioDeviceReadIOps = resources.blkioDeviceReadIOps
        BlkioDeviceWriteIOps = resources.blkioDeviceWriteIOps
        CpuCount = resources.cpuCount
        CpuPercent = resources.cpuPercent
        IOMaximumIOps = resources.ioMaximumIOps
        IOMaximumBandwidth = resources.ioMaximumBandwidth
        RestartPolicy = resources.restartPolicy.map {
            DockerRestartPolicyBody(Name: $0, MaximumRetryCount: resources.restartMaximumRetryCount)
        }
        Ulimits = resources.ulimits
    }
}

struct DockerMountBody: Encodable, Sendable {
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

struct DockerHostConfigBody: Encodable, Sendable {
    let PortBindings: [String: [DockerPortBinding]]
    let NetworkMode: String?
    let RestartPolicy: DockerRestartPolicyBody?
    let Binds: [String]?
    let Mounts: [DockerMountBody]?
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
}

struct DockerNetworkingConfigBody: Encodable, Sendable {
    let EndpointsConfig: [String: DockerEndpointSettings]
}

struct DockerCreateBody: Encodable, Sendable {
    let Hostname: String?
    let Domainname: String?
    let User: String?
    let AttachStdin: Bool?
    let AttachStdout: Bool?
    let AttachStderr: Bool?
    let Image: String
    let Cmd: [String]?
    let Entrypoint: [String]?
    let Env: [String]
    let Labels: [String: String]
    let ExposedPorts: [String: DockerEmptyObject]
    let Volumes: [String: DockerEmptyObject]?
    let Healthcheck: DockerHealthConfig?
    let WorkingDir: String?
    let Tty: Bool?
    let OpenStdin: Bool?
    let StdinOnce: Bool?
    let NetworkDisabled: Bool?
    let StopSignal: String?
    let StopTimeout: Int?
    let Shell: [String]?
    let HostConfig: DockerHostConfigBody
    let NetworkingConfig: DockerNetworkingConfigBody?

    init(spec: ContainerSpec) {
        Hostname = spec.hostname
        Domainname = spec.domainname
        User = spec.user
        AttachStdin = spec.attachStdin
        AttachStdout = spec.attachStdout
        AttachStderr = spec.attachStderr
        Image = spec.image
        Cmd = spec.command.isEmpty ? nil : spec.command
        Entrypoint = spec.entrypoint.isEmpty ? nil : spec.entrypoint
        Env = spec.environment.map { "\($0.key)=\($0.value)" }.sorted()
        Labels = spec.labels
        Healthcheck = spec.healthcheck
        WorkingDir = spec.workingDir
        Tty = spec.tty ? true : nil
        OpenStdin = spec.openStdin ? true : nil
        StdinOnce = spec.stdinOnce ? true : nil
        NetworkDisabled = spec.networkDisabled
        StopSignal = spec.stopSignal
        StopTimeout = spec.stopTimeout
        Shell = spec.shell.isEmpty ? nil : spec.shell
        NetworkingConfig = Self.networkingConfig(spec)

        var exposed: [String: DockerEmptyObject] = [:]
        var bindings: [String: [DockerPortBinding]] = [:]
        for mapping in spec.ports {
            let (key, hostPort, hostIP) = Self.parsePort(mapping)
            guard let key else { continue }
            exposed[key] = DockerEmptyObject()
            if let hostPort { bindings[key] = [DockerPortBinding(HostPort: hostPort, HostIp: hostIP)] }
        }
        ExposedPorts = exposed
        let binds = spec.volumes.filter(Self.isLegacyBind)
        let volumeTargets = Self.unique(spec.volumeTargets + spec.volumes.filter { !Self.isLegacyBind($0) })
            .filter { !$0.isEmpty }
        Volumes = volumeTargets.isEmpty ? nil : Dictionary(uniqueKeysWithValues: volumeTargets.map { ($0, DockerEmptyObject()) })
        HostConfig = DockerHostConfigBody(
            PortBindings: bindings,
            NetworkMode: spec.networkMode ?? spec.networks.first,
            RestartPolicy: (spec.restart ?? spec.resources.restartPolicy).map {
                DockerRestartPolicyBody(Name: $0, MaximumRetryCount: spec.resources.restartMaximumRetryCount)
            },
            Binds: binds.isEmpty ? nil : binds,
            Mounts: spec.mounts.isEmpty ? nil : spec.mounts.map(DockerMountBody.init),
            ContainerIDFile: spec.containerIDFile,
            LogConfig: spec.logConfig,
            VolumeDriver: spec.volumeDriver,
            VolumesFrom: spec.volumesFrom.isEmpty ? nil : spec.volumesFrom,
            ConsoleSize: spec.consoleSize.isEmpty ? nil : spec.consoleSize,
            Annotations: spec.annotations.isEmpty ? nil : spec.annotations,
            NanoCpus: spec.resources.nanoCPUs ?? spec.nanoCPUs,
            CpuShares: spec.resources.cpuShares,
            CgroupParent: spec.resources.cgroupParent,
            CpuPeriod: spec.resources.cpuPeriod,
            CpuQuota: spec.resources.cpuQuota,
            CpuRealtimePeriod: spec.resources.cpuRealtimePeriod,
            CpuRealtimeRuntime: spec.resources.cpuRealtimeRuntime,
            CpusetCpus: spec.resources.cpusetCPUs,
            CpusetMems: spec.resources.cpusetMems,
            Devices: spec.resources.devices,
            DeviceCgroupRules: spec.resources.deviceCgroupRules,
            DeviceRequests: spec.resources.deviceRequests,
            Memory: spec.resources.memoryLimitBytes ?? spec.memoryLimitBytes,
            KernelMemoryTCP: spec.resources.kernelMemoryTCPBytes,
            MemoryReservation: spec.resources.memoryReservationBytes,
            MemorySwap: spec.resources.memorySwapBytes,
            MemorySwappiness: spec.resources.memorySwappiness,
            OomKillDisable: spec.resources.oomKillDisable,
            Init: spec.initProcessEnabled ?? spec.resources.initProcessEnabled,
            PidsLimit: spec.resources.pidsLimit,
            BlkioWeight: spec.resources.blkioWeight,
            BlkioWeightDevice: spec.resources.blkioWeightDevice,
            BlkioDeviceReadBps: spec.resources.blkioDeviceReadBps,
            BlkioDeviceWriteBps: spec.resources.blkioDeviceWriteBps,
            BlkioDeviceReadIOps: spec.resources.blkioDeviceReadIOps,
            BlkioDeviceWriteIOps: spec.resources.blkioDeviceWriteIOps,
            CpuCount: spec.resources.cpuCount,
            CpuPercent: spec.resources.cpuPercent,
            IOMaximumIOps: spec.resources.ioMaximumIOps,
            IOMaximumBandwidth: spec.resources.ioMaximumBandwidth,
            AutoRemove: spec.autoRemove,
            Privileged: spec.privileged,
            CapAdd: spec.capAdd.isEmpty ? nil : spec.capAdd,
            CapDrop: spec.capDrop.isEmpty ? nil : spec.capDrop,
            CgroupnsMode: spec.cgroupnsMode,
            Dns: spec.dns.isEmpty ? nil : spec.dns,
            DnsOptions: spec.dnsOptions.isEmpty ? nil : spec.dnsOptions,
            DnsSearch: spec.dnsSearch.isEmpty ? nil : spec.dnsSearch,
            ExtraHosts: spec.extraHosts.isEmpty ? nil : spec.extraHosts,
            GroupAdd: spec.groupAdd.isEmpty ? nil : spec.groupAdd,
            IpcMode: spec.ipcMode,
            Cgroup: spec.cgroup,
            Links: spec.links.isEmpty ? nil : spec.links,
            OomScoreAdj: spec.oomScoreAdj,
            PublishAllPorts: spec.publishAllPorts,
            PidMode: spec.pidMode,
            UsernsMode: spec.usernsMode,
            ReadonlyRootfs: spec.readonlyRootfs,
            SecurityOpt: spec.securityOpt.isEmpty ? nil : spec.securityOpt,
            StorageOpt: spec.storageOpt.isEmpty ? nil : spec.storageOpt,
            ShmSize: spec.shmSize,
            Tmpfs: spec.tmpfs.isEmpty ? nil : spec.tmpfs,
            UTSMode: spec.utsMode,
            Sysctls: spec.sysctls.isEmpty ? nil : spec.sysctls,
            Runtime: spec.runtimeName,
            Isolation: spec.isolation,
            MaskedPaths: spec.maskedPaths.isEmpty ? nil : spec.maskedPaths,
            ReadonlyPaths: spec.readonlyPaths.isEmpty ? nil : spec.readonlyPaths,
            Ulimits: spec.resources.ulimits
        )
    }

    private static func networkingConfig(_ spec: ContainerSpec) -> DockerNetworkingConfigBody? {
        guard !spec.networks.isEmpty else { return nil }
        var endpoints: [String: DockerEndpointSettings] = [:]
        for network in spec.networks where endpoints[network] == nil {
            var endpoint = spec.networkEndpointSettings[network] ?? DockerEndpointSettings()
            if endpoint.Aliases == nil {
                endpoint.Aliases = spec.networkAliases[network]
            }
            endpoints[network] = endpoint
        }
        return DockerNetworkingConfigBody(EndpointsConfig: endpoints)
    }

    static func parsePort(_ mapping: String) -> (key: String?, hostPort: String?, hostIP: String?) {
        var proto = "tcp"
        var spec = mapping
        if let slash = spec.lastIndex(of: "/") {
            proto = String(spec[spec.index(after: slash)...])
            spec = String(spec[spec.startIndex..<slash])
        }
        let parts = spec.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        switch parts.count {
        case 1: return ("\(parts[0])/\(proto)", nil, nil)
        case 2: return ("\(parts[1])/\(proto)", parts[0], nil)
        case 3: return ("\(parts[2])/\(proto)", parts[1], normalizedHostIP(parts[0]))
        default:
            let containerPort = parts[parts.count - 1]
            let hostPort = parts[parts.count - 2]
            let hostIP = parts.dropLast(2).joined(separator: ":")
            return ("\(containerPort)/\(proto)", hostPort, normalizedHostIP(hostIP))
        }
    }

    private static func normalizedHostIP(_ raw: String) -> String? {
        guard !raw.isEmpty else { return nil }
        if raw.hasPrefix("["), raw.hasSuffix("]"), raw.count >= 2 {
            return String(raw.dropFirst().dropLast())
        }
        return raw
    }

    nonisolated static func isLegacyBind(_ volume: String) -> Bool {
        volume.contains(":")
    }

    private nonisolated static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

struct DockerCreateResult: Decodable, Sendable {
    let id: String
    enum CodingKeys: String, CodingKey { case id = "Id" }
}

struct DockerExecCreate: Encodable, Sendable {
    let AttachStdout = true
    let AttachStderr = true
    let Cmd: [String]
}

struct DockerExecResult: Decodable, Sendable {
    let id: String
    enum CodingKeys: String, CodingKey { case id = "Id" }
}

struct DockerExecStart: Encodable, Sendable {
    let Detach = false
    let Tty = false
}

struct DockerExecInspect: Decodable, Sendable {
    let exitCode: Int?
    enum CodingKeys: String, CodingKey { case exitCode = "ExitCode" }
}

struct DockerNetworkCreate: Encodable, Sendable {
    let Name: String
    let Labels: [String: String]
}

struct DockerVolumeCreate: Encodable, Sendable {
    let Name: String
    let Driver: String?
    let DriverOpts: [String: String]?
    let Labels: [String: String]?

    init(name: String, driver: String?, labels: [String: String], driverOptions: [String: String]) {
        let cleanDriver = driver?.trimmingCharacters(in: .whitespacesAndNewlines)
        Name = name
        Driver = cleanDriver?.isEmpty == false ? cleanDriver : nil
        DriverOpts = driverOptions.isEmpty ? nil : driverOptions
        Labels = labels.isEmpty ? nil : labels
    }
}

struct DockerNetworkCreateResult: Decodable, Sendable {
    let id: String?
    enum CodingKeys: String, CodingKey { case id = "Id" }
}
