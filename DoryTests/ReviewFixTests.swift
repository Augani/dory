import Testing
import Foundation
@testable import Dory

@MainActor
struct ReviewFixTests {
    // #1 + #2: shim create + lifecycle must not deadlock and must round-trip.
    @Test func shimCreateAndStartDoNotDeadlock() async throws {
        let path = shortSocketPath("dory-fix")
        let runtime = RecordingRuntime()
        let shim = DockerShim(runtime: runtime)
        let server = ShimHTTPServer(socketPath: path) { await shim.handle($0) }
        try server.start()
        defer { server.stop() }
        let client = UnixSocketHTTP(path: path)

        let body = Data(#"{"Image":"nginx:alpine","HostConfig":{"PortBindings":{"80/tcp":[{"HostPort":"8080"}]}}}"#.utf8)
        let create = try await client.send(HTTPRequest(method: "POST", path: "/v1.47/containers/create?name=web&platform=linux%2Famd64",
            headers: [(name: "Content-Type", value: "application/json")], body: body))
        #expect(create.statusCode == 201)
        struct CreateOut: Decodable { let Id: String }
        let created = try JSONDecoder().decode(CreateOut.self, from: create.body)
        let id = created.Id
        #expect(runtime.createdSpecs.first?.image == "nginx:alpine")
        #expect(runtime.createdSpecs.first?.platform == "linux/amd64")
        #expect(runtime.createdSpecs.first?.ports == ["8080:80"])

        // The lifecycle path used to deadlock the MainActor via a semaphore — must now return 204.
        let start = try await client.send(HTTPRequest(method: "POST", path: "/v1.47/containers/\(id)/start"))
        #expect(start.statusCode == 204)
        #expect(runtime.startedIDs.contains(id))

        // Unknown action -> 404 (was 409 for everything).
        let bogus = try await client.send(HTTPRequest(method: "POST", path: "/v1.47/containers/\(id)/frobnicate"))
        #expect(bogus.statusCode == 404)
    }

    @Test func shimCreatePreservesCommonConfigAndHostConfigFields() async throws {
        let path = shortSocketPath("dory-create-config")
        let runtime = RecordingRuntime()
        let shim = DockerShim(runtime: runtime)
        let server = ShimHTTPServer(socketPath: path) { await shim.handle($0) }
        try server.start()
        defer { server.stop() }
        let client = UnixSocketHTTP(path: path)

        let body = Data(#"""
        {
          "Hostname":"web-host",
          "Domainname":"dory.local",
          "User":"1000:1000",
          "AttachStdin":true,
          "AttachStdout":true,
          "AttachStderr":false,
          "Image":"nginx:alpine",
          "Entrypoint":"/entrypoint",
          "Cmd":"echo ok",
          "Tty":true,
          "OpenStdin":true,
          "StdinOnce":true,
          "Healthcheck":{
            "Test":["CMD-SHELL","curl -f http://localhost/health || exit 1"],
            "Interval":30000000000,
            "Timeout":3000000000,
            "Retries":3,
            "StartPeriod":10000000000,
            "StartInterval":1000000000
          },
          "WorkingDir":"/workspace",
          "NetworkDisabled":true,
          "ExposedPorts":{"8443/tcp":{}},
          "StopSignal":"SIGTERM",
          "StopTimeout":15,
          "Shell":["/bin/sh","-c"],
          "HostConfig":{
            "PortBindings":{
              "443/tcp":[{"HostIp":"::1","HostPort":"8443"}],
              "80/tcp":[{"HostIp":"127.0.0.1","HostPort":"8080"}],
              "53/udp":[{"HostPort":"5353"}]
            },
            "RestartPolicy":{"Name":"on-failure","MaximumRetryCount":3},
            "NetworkMode":"bridge",
            "AutoRemove":true,
            "Privileged":true,
            "ContainerIDFile":"/tmp/container.id",
            "LogConfig":{"Type":"json-file","Config":{"max-size":"10m"}},
            "VolumeDriver":"local",
            "VolumesFrom":["parent:ro"],
            "ConsoleSize":[40,120],
            "Annotations":{"com.example.runtime":"dev"},
            "Init":true,
            "CapAdd":["NET_ADMIN"],
            "CapDrop":["MKNOD"],
            "CgroupnsMode":"private",
            "Dns":["1.1.1.1"],
            "DnsOptions":["ndots:0"],
            "DnsSearch":["dory.local"],
            "ExtraHosts":["host.docker.internal:host-gateway"],
            "GroupAdd":["staff"],
            "IpcMode":"private",
            "Cgroup":"dory",
            "Links":["redis:redis"],
            "OomScoreAdj":250,
            "PublishAllPorts":true,
            "PidMode":"host",
            "UsernsMode":"host",
            "ReadonlyRootfs":true,
            "SecurityOpt":["no-new-privileges"],
            "StorageOpt":{"size":"20G"},
            "ShmSize":67108864,
            "Tmpfs":{"/tmp":"rw,noexec"},
            "UTSMode":"host",
            "Sysctls":{"net.ipv4.ip_forward":"1"},
            "Runtime":"runc",
            "Isolation":"default",
            "MaskedPaths":["/proc/acpi"],
            "ReadonlyPaths":["/proc/sys"],
            "MemoryReservation":536870912,
            "PidsLimit":128,
            "Ulimits":[{"Name":"nofile","Soft":1024,"Hard":2048}]
          }
        }
        """#.utf8)
        let create = try await client.send(HTTPRequest(
            method: "POST",
            path: "/v1.47/containers/create?name=web",
            headers: [(name: "Content-Type", value: "application/json")],
            body: body
        ))
        #expect(create.statusCode == 201)
        struct CreateOut: Decodable { let Id: String }
        let id = try JSONDecoder().decode(CreateOut.self, from: create.body).Id
        let spec = try #require(runtime.createdSpecs.first)
        #expect(spec.hostname == "web-host")
        #expect(spec.domainname == "dory.local")
        #expect(spec.user == "1000:1000")
        #expect(spec.attachStdin == true)
        #expect(spec.attachStdout == true)
        #expect(spec.attachStderr == false)
        #expect(spec.workingDir == "/workspace")
        #expect(spec.entrypoint == ["/entrypoint"])
        #expect(spec.command == ["echo ok"])
        #expect(spec.tty == true)
        #expect(spec.openStdin == true)
        #expect(spec.stdinOnce == true)
        #expect(spec.healthcheck == DockerHealthConfig(
            Test: ["CMD-SHELL", "curl -f http://localhost/health || exit 1"],
            Interval: 30_000_000_000,
            Timeout: 3_000_000_000,
            Retries: 3,
            StartPeriod: 10_000_000_000,
            StartInterval: 1_000_000_000
        ))
        #expect(spec.networkDisabled == true)
        #expect(spec.ports == ["[::1]:8443:443", "5353:53/udp", "127.0.0.1:8080:80", "8443"])
        #expect(spec.stopSignal == "SIGTERM")
        #expect(spec.stopTimeout == 15)
        #expect(spec.shell == ["/bin/sh", "-c"])
        #expect(spec.restart == "on-failure")
        #expect(spec.resources.restartPolicy == "on-failure")
        #expect(spec.resources.restartMaximumRetryCount == 3)
        #expect(spec.networkMode == "bridge")
        #expect(spec.autoRemove == true)
        #expect(spec.privileged == true)
        #expect(spec.containerIDFile == "/tmp/container.id")
        #expect(spec.logConfig == DockerLogConfig(Type: "json-file", Config: ["max-size": "10m"]))
        #expect(spec.volumeDriver == "local")
        #expect(spec.volumesFrom == ["parent:ro"])
        #expect(spec.consoleSize == [40, 120])
        #expect(spec.annotations == ["com.example.runtime": "dev"])
        #expect(spec.initProcessEnabled == true)
        #expect(spec.capAdd == ["NET_ADMIN"])
        #expect(spec.capDrop == ["MKNOD"])
        #expect(spec.cgroupnsMode == "private")
        #expect(spec.dns == ["1.1.1.1"])
        #expect(spec.dnsOptions == ["ndots:0"])
        #expect(spec.dnsSearch == ["dory.local"])
        #expect(spec.extraHosts == ["host.docker.internal:host-gateway"])
        #expect(spec.groupAdd == ["staff"])
        #expect(spec.ipcMode == "private")
        #expect(spec.cgroup == "dory")
        #expect(spec.links == ["redis:redis"])
        #expect(spec.oomScoreAdj == 250)
        #expect(spec.publishAllPorts == true)
        #expect(spec.pidMode == "host")
        #expect(spec.usernsMode == "host")
        #expect(spec.readonlyRootfs == true)
        #expect(spec.securityOpt == ["no-new-privileges"])
        #expect(spec.storageOpt == ["size": "20G"])
        #expect(spec.shmSize == 67_108_864)
        #expect(spec.tmpfs == ["/tmp": "rw,noexec"])
        #expect(spec.utsMode == "host")
        #expect(spec.sysctls == ["net.ipv4.ip_forward": "1"])
        #expect(spec.runtimeName == "runc")
        #expect(spec.isolation == "default")
        #expect(spec.maskedPaths == ["/proc/acpi"])
        #expect(spec.readonlyPaths == ["/proc/sys"])
        #expect(spec.resources.memoryReservationBytes == 536_870_912)
        #expect(spec.resources.pidsLimit == 128)
        #expect(spec.resources.ulimits == [DockerUlimit(Name: "nofile", Soft: 1_024, Hard: 2_048)])

        let inspect = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/containers/\(id)/json"))
        #expect(inspect.statusCode == 200)
        let json = try #require(try JSONSerialization.jsonObject(with: inspect.body) as? [String: Any])
        let config = try #require(json["Config"] as? [String: Any])
        #expect(config["Hostname"] as? String == "web-host")
        #expect(config["Domainname"] as? String == "dory.local")
        #expect(config["User"] as? String == "1000:1000")
        #expect(config["Image"] as? String == "nginx:alpine")
        #expect(config["Entrypoint"] as? [String] == ["/entrypoint"])
        #expect(config["Cmd"] as? [String] == ["echo ok"])
        #expect(config["WorkingDir"] as? String == "/workspace")
        #expect(config["Tty"] as? Bool == true)
        #expect(config["OpenStdin"] as? Bool == true)
        #expect(config["StdinOnce"] as? Bool == true)
        #expect(config["NetworkDisabled"] as? Bool == true)
        #expect(config["StopSignal"] as? String == "SIGTERM")
        #expect(config["StopTimeout"] as? Int == 15)
        #expect(config["Shell"] as? [String] == ["/bin/sh", "-c"])
        let inspectHealth = try #require(config["Healthcheck"] as? [String: Any])
        #expect(inspectHealth["Test"] as? [String] == ["CMD-SHELL", "curl -f http://localhost/health || exit 1"])
        let exposed = try #require(config["ExposedPorts"] as? [String: Any])
        #expect(exposed["8443/tcp"] != nil)
        #expect(exposed["443/tcp"] != nil)

        let hostConfig = try #require(json["HostConfig"] as? [String: Any])
        #expect(hostConfig["NetworkMode"] as? String == "bridge")
        let portBindings = try #require(hostConfig["PortBindings"] as? [String: [[String: String]]])
        #expect(portBindings["443/tcp"]?.first?["HostIp"] == "::1")
        #expect(portBindings["443/tcp"]?.first?["HostPort"] == "8443")
        #expect(portBindings["80/tcp"]?.first?["HostIp"] == "127.0.0.1")
        #expect(portBindings["80/tcp"]?.first?["HostPort"] == "8080")
        #expect(portBindings["53/udp"]?.first?["HostIp"] == "0.0.0.0")
        #expect(portBindings["53/udp"]?.first?["HostPort"] == "5353")
        let restartPolicy = try #require(hostConfig["RestartPolicy"] as? [String: Any])
        #expect(restartPolicy["Name"] as? String == "on-failure")
        #expect(restartPolicy["MaximumRetryCount"] as? Int == 3)
        #expect(hostConfig["AutoRemove"] as? Bool == true)
        #expect(hostConfig["Privileged"] as? Bool == true)
        #expect(hostConfig["ContainerIDFile"] as? String == "/tmp/container.id")
        #expect(hostConfig["VolumeDriver"] as? String == "local")
        #expect(hostConfig["VolumesFrom"] as? [String] == ["parent:ro"])
        #expect(hostConfig["ConsoleSize"] as? [Int] == [40, 120])
        #expect(hostConfig["Annotations"] as? [String: String] == ["com.example.runtime": "dev"])
        #expect(hostConfig["Init"] as? Bool == true)
        #expect(hostConfig["CapAdd"] as? [String] == ["NET_ADMIN"])
        #expect(hostConfig["CapDrop"] as? [String] == ["MKNOD"])
        #expect(hostConfig["CgroupnsMode"] as? String == "private")
        #expect(hostConfig["Dns"] as? [String] == ["1.1.1.1"])
        #expect(hostConfig["DnsOptions"] as? [String] == ["ndots:0"])
        #expect(hostConfig["DnsSearch"] as? [String] == ["dory.local"])
        #expect(hostConfig["ExtraHosts"] as? [String] == ["host.docker.internal:host-gateway"])
        #expect(hostConfig["GroupAdd"] as? [String] == ["staff"])
        #expect(hostConfig["IpcMode"] as? String == "private")
        #expect(hostConfig["Cgroup"] as? String == "dory")
        #expect(hostConfig["Links"] as? [String] == ["redis:redis"])
        #expect(hostConfig["OomScoreAdj"] as? Int == 250)
        #expect(hostConfig["PublishAllPorts"] as? Bool == true)
        #expect(hostConfig["PidMode"] as? String == "host")
        #expect(hostConfig["UsernsMode"] as? String == "host")
        #expect(hostConfig["ReadonlyRootfs"] as? Bool == true)
        #expect(hostConfig["SecurityOpt"] as? [String] == ["no-new-privileges"])
        #expect(hostConfig["StorageOpt"] as? [String: String] == ["size": "20G"])
        #expect(hostConfig["ShmSize"] as? Int == 67_108_864)
        #expect(hostConfig["Tmpfs"] as? [String: String] == ["/tmp": "rw,noexec"])
        #expect(hostConfig["UTSMode"] as? String == "host")
        #expect(hostConfig["Sysctls"] as? [String: String] == ["net.ipv4.ip_forward": "1"])
        #expect(hostConfig["Runtime"] as? String == "runc")
        #expect(hostConfig["Isolation"] as? String == "default")
        #expect(hostConfig["MaskedPaths"] as? [String] == ["/proc/acpi"])
        #expect(hostConfig["ReadonlyPaths"] as? [String] == ["/proc/sys"])
        #expect(hostConfig["MemoryReservation"] as? Int == 536_870_912)
        #expect(hostConfig["PidsLimit"] as? Int == 128)
        let logConfig = try #require(hostConfig["LogConfig"] as? [String: Any])
        #expect(logConfig["Type"] as? String == "json-file")
        #expect(logConfig["Config"] as? [String: String] == ["max-size": "10m"])
        let ulimits = try #require(hostConfig["Ulimits"] as? [[String: Any]])
        let nofile = try #require(ulimits.first)
        #expect(nofile["Name"] as? String == "nofile")
        #expect(nofile["Soft"] as? Int == 1_024)
        #expect(nofile["Hard"] as? Int == 2_048)
    }

    @Test func shimCreatePreservesNetworkingConfigEndpointSettings() async throws {
        let path = shortSocketPath("dory-create-networking-config")
        let runtime = RecordingRuntime()
        let shim = DockerShim(runtime: runtime)
        let server = ShimHTTPServer(socketPath: path) { await shim.handle($0) }
        try server.start()
        defer { server.stop() }
        let client = UnixSocketHTTP(path: path)

        let body = Data(#"""
        {
          "Image": "nginx:alpine",
          "NetworkingConfig": {
            "EndpointsConfig": {
              "front": {
                "IPAMConfig": {
                  "IPv4Address": "172.20.0.10",
                  "IPv6Address": "fd00::10",
                  "LinkLocalIPs": ["169.254.1.2"]
                },
                "Links": ["db:db"],
                "Aliases": ["web", "api"],
                "NetworkID": "net123",
                "EndpointID": "endpoint123",
                "Gateway": "172.20.0.1",
                "IPAddress": "172.20.0.10",
                "IPPrefixLen": 24,
                "IPv6Gateway": "fd00::1",
                "GlobalIPv6Address": "fd00::10",
                "GlobalIPv6PrefixLen": 64,
                "MacAddress": "02:42:ac:14:00:0a",
                "DriverOpts": {"com.example.mode": "fast"}
              },
              "back": {}
            }
          }
        }
        """#.utf8)
        let create = try await client.send(HTTPRequest(
            method: "POST",
            path: "/v1.47/containers/create?name=web",
            headers: [(name: "Content-Type", value: "application/json")],
            body: body
        ))

        #expect(create.statusCode == 201)
        struct CreateOut: Decodable { let Id: String }
        let id = try JSONDecoder().decode(CreateOut.self, from: create.body).Id
        let spec = try #require(runtime.createdSpecs.first)
        #expect(spec.networks == ["back", "front"])
        #expect(spec.networkAliases["front"] == ["web", "api"])
        #expect(spec.networkAliases["back"] == nil)
        let endpoint = try #require(spec.networkEndpointSettings["front"])
        #expect(endpoint.IPAMConfig?.IPv4Address == "172.20.0.10")
        #expect(endpoint.IPAMConfig?.IPv6Address == "fd00::10")
        #expect(endpoint.IPAMConfig?.LinkLocalIPs == ["169.254.1.2"])
        #expect(endpoint.Links == ["db:db"])
        #expect(endpoint.NetworkID == "net123")
        #expect(endpoint.EndpointID == "endpoint123")
        #expect(endpoint.Gateway == "172.20.0.1")
        #expect(endpoint.IPAddress == "172.20.0.10")
        #expect(endpoint.IPPrefixLen == 24)
        #expect(endpoint.IPv6Gateway == "fd00::1")
        #expect(endpoint.GlobalIPv6Address == "fd00::10")
        #expect(endpoint.GlobalIPv6PrefixLen == 64)
        #expect(endpoint.MacAddress == "02:42:ac:14:00:0a")
        #expect(endpoint.DriverOpts == ["com.example.mode": "fast"])

        let inspect = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/containers/\(id)/json"))
        #expect(inspect.statusCode == 200)
        let json = try #require(try JSONSerialization.jsonObject(with: inspect.body) as? [String: Any])
        let networkSettings = try #require(json["NetworkSettings"] as? [String: Any])
        let inspectNetworks = try #require(networkSettings["Networks"] as? [String: Any])
        let front = try #require(inspectNetworks["front"] as? [String: Any])
        let back = try #require(inspectNetworks["back"] as? [String: Any])
        let ipam = try #require(front["IPAMConfig"] as? [String: Any])
        #expect(ipam["IPv4Address"] as? String == "172.20.0.10")
        #expect(ipam["IPv6Address"] as? String == "fd00::10")
        #expect(ipam["LinkLocalIPs"] as? [String] == ["169.254.1.2"])
        #expect(front["Links"] as? [String] == ["db:db"])
        #expect(front["Aliases"] as? [String] == ["web", "api"])
        #expect(front["NetworkID"] as? String == "net123")
        #expect(front["EndpointID"] as? String == "endpoint123")
        #expect(front["Gateway"] as? String == "172.20.0.1")
        #expect(front["IPAddress"] as? String == "172.20.0.10")
        #expect(front["IPPrefixLen"] as? Int == 24)
        #expect(front["IPv6Gateway"] as? String == "fd00::1")

        let list = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/containers/json?all=1"))
        let rows = try #require(try JSONSerialization.jsonObject(with: list.body) as? [[String: Any]])
        let row = try #require(rows.first { ($0["Names"] as? [String])?.contains("/web") == true })
        let rowHostConfig = try #require(row["HostConfig"] as? [String: Any])
        let rowNetworkSettings = try #require(row["NetworkSettings"] as? [String: Any])
        let rowNetworks = try #require(rowNetworkSettings["Networks"] as? [String: Any])
        let rowFront = try #require(rowNetworks["front"] as? [String: Any])
        #expect(rowHostConfig["NetworkMode"] as? String == "back")
        #expect(rowFront["IPAddress"] as? String == "172.20.0.10")
        #expect(rowFront["Aliases"] as? [String] == ["web", "api"])
        #expect(front["GlobalIPv6Address"] as? String == "fd00::10")
        #expect(front["GlobalIPv6PrefixLen"] as? Int == 64)
        #expect(front["MacAddress"] as? String == "02:42:ac:14:00:0a")
        #expect(front["DriverOpts"] as? [String: String] == ["com.example.mode": "fast"])
        #expect(back.isEmpty)
    }

    @Test func shimCoversContainerRenamePauseAndUnpauseEndpoints() async throws {
        let path = shortSocketPath("dory-container-mutations")
        let runtime = RecordingRuntime()
        let shim = DockerShim(runtime: runtime)
        let server = ShimHTTPServer(socketPath: path) { await shim.handle($0) }
        try server.start()
        defer { server.stop() }
        let client = UnixSocketHTTP(path: path)

        let create = try await client.send(HTTPRequest(
            method: "POST",
            path: "/v1.47/containers/create?name=api",
            headers: [(name: "Content-Type", value: "application/json")],
            body: Data(#"{"Image":"nginx:alpine"}"#.utf8)
        ))
        #expect(create.statusCode == 201)
        struct CreateOut: Decodable { let Id: String }
        let id = try JSONDecoder().decode(CreateOut.self, from: create.body).Id

        let pause = try await client.send(HTTPRequest(method: "POST", path: "/v1.47/containers/\(id)/pause"))
        #expect(pause.statusCode == 204)
        #expect(runtime.pausedIDs == [id])

        let pausedInspect = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/containers/\(id)/json"))
        let pausedJSON = try #require(try JSONSerialization.jsonObject(with: pausedInspect.body) as? [String: Any])
        let pausedState = try #require(pausedJSON["State"] as? [String: Any])
        #expect(pausedState["Status"] as? String == "paused")
        #expect(pausedState["Paused"] as? Bool == true)
        #expect(pausedState["Running"] as? Bool == true)

        let unpause = try await client.send(HTTPRequest(method: "POST", path: "/v1.47/containers/\(id)/unpause"))
        #expect(unpause.statusCode == 204)
        #expect(runtime.unpausedIDs == [id])

        let rename = try await client.send(HTTPRequest(method: "POST", path: "/v1.47/containers/\(id)/rename?name=api-renamed"))
        #expect(rename.statusCode == 204)
        #expect(runtime.renamedContainers.first?.id == id)
        #expect(runtime.renamedContainers.first?.name == "api-renamed")

        let renamedInspect = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/containers/\(id)/json"))
        let renamedJSON = try #require(try JSONSerialization.jsonObject(with: renamedInspect.body) as? [String: Any])
        let renamedState = try #require(renamedJSON["State"] as? [String: Any])
        #expect(renamedJSON["Name"] as? String == "/api-renamed")
        #expect(renamedState["Status"] as? String == "running")
        #expect(renamedState["Paused"] as? Bool == false)

        let kill = try await client.send(HTTPRequest(method: "POST", path: "/v1.47/containers/\(id)/kill?signal=SIGTERM"))
        #expect(kill.statusCode == 204)
        #expect(runtime.killedContainers.first?.id == id)
        #expect(runtime.killedContainers.first?.signal == "SIGTERM")

        let killedInspect = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/containers/\(id)/json"))
        let killedJSON = try #require(try JSONSerialization.jsonObject(with: killedInspect.body) as? [String: Any])
        let killedState = try #require(killedJSON["State"] as? [String: Any])
        #expect(killedState["Status"] as? String == "exited")
        #expect(killedState["Running"] as? Bool == false)

        let update = try await client.send(HTTPRequest(
            method: "POST",
            path: "/v1.47/containers/\(id)/update",
            headers: [(name: "Content-Type", value: "application/json")],
            body: Data(#"""
            {"NanoCpus":3000000000,"CpuShares":512,"CgroupParent":"/dory","CpuPeriod":100000,"CpuQuota":50000,"CpuRealtimePeriod":950000,"CpuRealtimeRuntime":900000,"CpusetCpus":"0-1","CpusetMems":"0","Devices":[{"PathOnHost":"/dev/fuse","PathInContainer":"/dev/fuse","CgroupPermissions":"mrw"}],"DeviceCgroupRules":["c 10:229 rwm"],"DeviceRequests":[{"Driver":"nvidia","Count":-1,"DeviceIDs":["GPU-1"],"Capabilities":[["gpu","compute"]],"Options":{"cap":"all"}}],"Memory":536870912,"KernelMemoryTCP":1048576,"MemoryReservation":268435456,"MemorySwap":1073741824,"MemorySwappiness":10,"OomKillDisable":true,"Init":true,"PidsLimit":256,"BlkioWeight":300,"BlkioWeightDevice":[{"Path":"/dev/disk1","Weight":200}],"BlkioDeviceReadBps":[{"Path":"/dev/disk1","Rate":1048576}],"BlkioDeviceWriteBps":[{"Path":"/dev/disk1","Rate":2097152}],"BlkioDeviceReadIOps":[{"Path":"/dev/disk1","Rate":1000}],"BlkioDeviceWriteIOps":[{"Path":"/dev/disk1","Rate":2000}],"CpuCount":2,"CpuPercent":50,"IOMaximumIOps":4000,"IOMaximumBandwidth":8192,"RestartPolicy":{"Name":"on-failure","MaximumRetryCount":5},"Ulimits":[{"Name":"nofile","Soft":1024,"Hard":2048}]}
            """#.utf8)
        ))
        #expect(update.statusCode == 200)
        let updateResult = try JSONDecoder().decode(DockerContainerUpdateOut.self, from: update.body)
        #expect(updateResult.Warnings.isEmpty)
        #expect(runtime.updatedContainers.first?.id == id)
        #expect(runtime.updatedContainers.first?.resources == ContainerResourceUpdate(
            nanoCPUs: 3_000_000_000,
            cpuShares: 512,
            cgroupParent: "/dory",
            cpuPeriod: 100_000,
            cpuQuota: 50_000,
            cpuRealtimePeriod: 950_000,
            cpuRealtimeRuntime: 900_000,
            cpusetCPUs: "0-1",
            cpusetMems: "0",
            devices: [DockerDeviceMapping(PathOnHost: "/dev/fuse", PathInContainer: "/dev/fuse", CgroupPermissions: "mrw")],
            deviceCgroupRules: ["c 10:229 rwm"],
            deviceRequests: [DockerDeviceRequest(
                Driver: "nvidia",
                Count: -1,
                DeviceIDs: ["GPU-1"],
                Capabilities: [["gpu", "compute"]],
                Options: ["cap": "all"]
            )],
            memoryLimitBytes: 536_870_912,
            kernelMemoryTCPBytes: 1_048_576,
            memoryReservationBytes: 268_435_456,
            memorySwapBytes: 1_073_741_824,
            memorySwappiness: 10,
            oomKillDisable: true,
            initProcessEnabled: true,
            pidsLimit: 256,
            blkioWeight: 300,
            blkioWeightDevice: [DockerBlkioWeightDevice(Path: "/dev/disk1", Weight: 200)],
            blkioDeviceReadBps: [DockerThrottleDevice(Path: "/dev/disk1", Rate: 1_048_576)],
            blkioDeviceWriteBps: [DockerThrottleDevice(Path: "/dev/disk1", Rate: 2_097_152)],
            blkioDeviceReadIOps: [DockerThrottleDevice(Path: "/dev/disk1", Rate: 1_000)],
            blkioDeviceWriteIOps: [DockerThrottleDevice(Path: "/dev/disk1", Rate: 2_000)],
            cpuCount: 2,
            cpuPercent: 50,
            ioMaximumIOps: 4_000,
            ioMaximumBandwidth: 8_192,
            restartPolicy: "on-failure",
            restartMaximumRetryCount: 5,
            ulimits: [DockerUlimit(Name: "nofile", Soft: 1_024, Hard: 2_048)]
        ))

        let updatedInspect = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/containers/\(id)/json"))
        let updatedJSON = try #require(try JSONSerialization.jsonObject(with: updatedInspect.body) as? [String: Any])
        let host = try #require(updatedJSON["HostConfig"] as? [String: Any])
        #expect((host["NanoCpus"] as? NSNumber)?.int64Value == 3_000_000_000)
        #expect((host["Memory"] as? NSNumber)?.int64Value == 536_870_912)

        let resize = try await client.send(HTTPRequest(method: "POST", path: "/v1.47/containers/\(id)/resize?h=40&w=120"))
        #expect(resize.statusCode == 200)
        #expect(runtime.resizedContainers.first?.id == id)
        #expect(runtime.resizedContainers.first?.height == 40)
        #expect(runtime.resizedContainers.first?.width == 120)

        let badRename = try await client.send(HTTPRequest(method: "POST", path: "/v1.47/containers/\(id)/rename"))
        #expect(badRename.statusCode == 400)
    }

    @Test func dockerEngineRuntimeUsesCreatePlatformQuery() async throws {
        let path = shortSocketPath("dory-docker-create-platform")
        let recorder = RequestRecorder()
        let server = ShimHTTPServer(socketPath: path) { request in
            recorder.record(method: request.method, target: request.target, body: request.body)
            return ShimResponse.json(Data(#"{"Id":"created"}"#.utf8), status: 201)
        }
        try server.start()
        defer { server.stop() }

        let runtime = DockerEngineRuntime(socketPath: path)
        let id = try await runtime.create(ContainerSpec(name: "amd", image: "alpine:3.22", platform: "linux/amd64"))

        #expect(id == "created")
        #expect(recorder.requests.map(\.method) == ["POST"])
        #expect(recorder.requests.map(\.target) == [
            "/containers/create?name=amd&platform=linux%2Famd64",
        ])
    }

    @Test func dockerEngineRuntimeUsesNativeContainerMutationEndpoints() async throws {
        let path = shortSocketPath("dory-docker-mutations")
        let recorder = RequestRecorder()
        let server = ShimHTTPServer(socketPath: path) { request in
            recorder.record(method: request.method, target: request.target, body: request.body)
            return ShimResponse.empty(status: 204)
        }
        try server.start()
        defer { server.stop() }

        let runtime = DockerEngineRuntime(socketPath: path)
        try await runtime.pause(containerID: "abc123")
        try await runtime.unpause(containerID: "abc123")
        try await runtime.rename(containerID: "abc123", name: "api renamed")
        try await runtime.kill(containerID: "abc123", signal: "SIGTERM")
        try await runtime.update(containerID: "abc123", resources: ContainerResourceUpdate(
            nanoCPUs: 2_000_000_000,
            cpuShares: 256,
            cgroupParent: "/docker/dory",
            cpuPeriod: 100_000,
            cpuQuota: 25_000,
            cpusetCPUs: "0",
            devices: [DockerDeviceMapping(PathOnHost: "/dev/fuse", PathInContainer: "/dev/fuse", CgroupPermissions: "mrw")],
            deviceCgroupRules: ["c 10:229 rwm"],
            deviceRequests: [DockerDeviceRequest(
                Driver: "nvidia",
                Count: -1,
                DeviceIDs: ["GPU-1"],
                Capabilities: [["gpu"]],
                Options: ["cap": "all"]
            )],
            memoryLimitBytes: 1_073_741_824,
            kernelMemoryTCPBytes: 1_048_576,
            memoryReservationBytes: 536_870_912,
            memorySwapBytes: 2_147_483_648,
            oomKillDisable: true,
            initProcessEnabled: true,
            pidsLimit: 128,
            blkioWeightDevice: [DockerBlkioWeightDevice(Path: "/dev/disk1", Weight: 200)],
            blkioDeviceReadBps: [DockerThrottleDevice(Path: "/dev/disk1", Rate: 1_048_576)],
            cpuCount: 2,
            cpuPercent: 50,
            ioMaximumIOps: 4_000,
            ioMaximumBandwidth: 8_192,
            restartPolicy: "on-failure",
            restartMaximumRetryCount: 3,
            ulimits: [DockerUlimit(Name: "nofile", Soft: 1_024, Hard: 2_048)]
        ))
        try await runtime.resize(containerID: "abc123", height: 40, width: 120)
        try await runtime.pruneContainers()

        #expect(recorder.requests.map(\.method) == ["POST", "POST", "POST", "POST", "POST", "POST", "POST"])
        #expect(recorder.requests.map(\.target) == [
            "/containers/abc123/pause",
            "/containers/abc123/unpause",
            "/containers/abc123/rename?name=api%20renamed",
            "/containers/abc123/kill?signal=SIGTERM",
            "/containers/abc123/update",
            "/containers/abc123/resize?h=40&w=120",
            "/containers/prune",
        ])
        let updateBody = try #require(recorder.requests.dropLast(2).last?.body)
        let updateJSON = try #require(try JSONSerialization.jsonObject(with: updateBody) as? [String: Any])
        #expect((updateJSON["NanoCpus"] as? NSNumber)?.int64Value == 2_000_000_000)
        #expect((updateJSON["CpuShares"] as? NSNumber)?.int64Value == 256)
        #expect(updateJSON["CgroupParent"] as? String == "/docker/dory")
        #expect((updateJSON["CpuPeriod"] as? NSNumber)?.int64Value == 100_000)
        #expect((updateJSON["CpuQuota"] as? NSNumber)?.int64Value == 25_000)
        #expect(updateJSON["CpusetCpus"] as? String == "0")
        let devices = try #require(updateJSON["Devices"] as? [[String: Any]])
        #expect(devices.first?["PathOnHost"] as? String == "/dev/fuse")
        let rules = try #require(updateJSON["DeviceCgroupRules"] as? [String])
        #expect(rules == ["c 10:229 rwm"])
        let requests = try #require(updateJSON["DeviceRequests"] as? [[String: Any]])
        #expect(requests.first?["Driver"] as? String == "nvidia")
        #expect((updateJSON["Memory"] as? NSNumber)?.int64Value == 1_073_741_824)
        #expect((updateJSON["KernelMemoryTCP"] as? NSNumber)?.int64Value == 1_048_576)
        #expect((updateJSON["MemoryReservation"] as? NSNumber)?.int64Value == 536_870_912)
        #expect((updateJSON["MemorySwap"] as? NSNumber)?.int64Value == 2_147_483_648)
        #expect(updateJSON["OomKillDisable"] as? Bool == true)
        #expect(updateJSON["Init"] as? Bool == true)
        #expect((updateJSON["PidsLimit"] as? NSNumber)?.int64Value == 128)
        let weights = try #require(updateJSON["BlkioWeightDevice"] as? [[String: Any]])
        #expect(weights.first?["Weight"] as? Int == 200)
        let readBps = try #require(updateJSON["BlkioDeviceReadBps"] as? [[String: Any]])
        #expect((readBps.first?["Rate"] as? NSNumber)?.int64Value == 1_048_576)
        #expect((updateJSON["CpuCount"] as? NSNumber)?.int64Value == 2)
        #expect((updateJSON["CpuPercent"] as? NSNumber)?.int64Value == 50)
        #expect((updateJSON["IOMaximumIOps"] as? NSNumber)?.int64Value == 4_000)
        #expect((updateJSON["IOMaximumBandwidth"] as? NSNumber)?.int64Value == 8_192)
        let restart = try #require(updateJSON["RestartPolicy"] as? [String: Any])
        #expect(restart["Name"] as? String == "on-failure")
        #expect((restart["MaximumRetryCount"] as? NSNumber)?.intValue == 3)
        let ulimits = try #require(updateJSON["Ulimits"] as? [[String: Any]])
        #expect(ulimits.first?["Name"] as? String == "nofile")
        #expect((ulimits.first?["Hard"] as? NSNumber)?.int64Value == 2_048)
    }

    @Test func dockerEngineRuntimeUsesNativeNetworkLifecycleEndpoints() async throws {
        let path = shortSocketPath("dory-docker-network-lifecycle")
        let recorder = RequestRecorder()
        let server = ShimHTTPServer(socketPath: path) { request in
            recorder.record(method: request.method, target: request.target, body: request.body)
            if request.target == "/networks/create" {
                return ShimResponse.json(Data(#"{"Id":"demo_default"}"#.utf8), status: 201)
            }
            return ShimResponse.empty(status: request.method == "DELETE" ? 204 : 200)
        }
        try server.start()
        defer { server.stop() }

        let runtime = DockerEngineRuntime(socketPath: path)
        try await runtime.createNetwork(name: "demo_default", labels: ["com.example": "true"])
        try await runtime.connectNetwork(name: "demo_default", containerID: "web")
        try await runtime.disconnectNetwork(name: "demo_default", containerID: "web", force: true)
        try await runtime.removeNetwork(name: "demo_default")
        try await runtime.pruneNetworks()

        #expect(recorder.requests.map(\.method) == ["POST", "POST", "POST", "DELETE", "POST"])
        #expect(recorder.requests.map(\.target) == [
            "/networks/create",
            "/networks/demo_default/connect",
            "/networks/demo_default/disconnect",
            "/networks/demo_default",
            "/networks/prune",
        ])

        let createBody = try #require(recorder.requests.first?.body)
        let createJSON = try #require(try JSONSerialization.jsonObject(with: createBody) as? [String: Any])
        #expect(createJSON["Name"] as? String == "demo_default")
        let labels = try #require(createJSON["Labels"] as? [String: Any])
        #expect(labels["com.example"] as? String == "true")

        let connectBody = try #require(recorder.requests.dropFirst().first?.body)
        let connectJSON = try #require(try JSONSerialization.jsonObject(with: connectBody) as? [String: Any])
        #expect(connectJSON["Container"] as? String == "web")

        let disconnectBody = try #require(recorder.requests.dropFirst(2).first?.body)
        let disconnectJSON = try #require(try JSONSerialization.jsonObject(with: disconnectBody) as? [String: Any])
        #expect(disconnectJSON["Container"] as? String == "web")
        #expect(disconnectJSON["Force"] as? Bool == true)
    }

    @Test func dockerEngineRuntimeUsesNativeImageTagEndpoint() async throws {
        let path = shortSocketPath("dory-docker-tag")
        let recorder = RequestRecorder()
        let server = ShimHTTPServer(socketPath: path) { request in
            recorder.record(method: request.method, target: request.target, body: request.body)
            return ShimResponse.empty(status: 201)
        }
        try server.start()
        defer { server.stop() }

        let runtime = DockerEngineRuntime(socketPath: path)
        try await runtime.tagImage(source: "dory/web-api:latest", repo: "registry.example.com/dory/web-api", tag: "dev")

        #expect(recorder.requests.map(\.method) == ["POST"])
        #expect(recorder.requests.map(\.target) == [
            "/images/dory%2Fweb-api:latest/tag?repo=registry.example.com%2Fdory%2Fweb-api&tag=dev",
        ])
    }

    @Test func dockerEngineRuntimeUsesNativeImagePushEndpoint() async throws {
        let path = shortSocketPath("dory-docker-push")
        let recorder = RequestRecorder()
        let server = ShimHTTPServer(socketPath: path) { request in
            recorder.record(method: request.method, target: request.target, body: request.body, headers: request.headers)
            return ShimResponse.json(Data(#"{"status":"pushed"}"#.utf8) + Data("\n".utf8))
        }
        try server.start()
        defer { server.stop() }

        let runtime = DockerEngineRuntime(socketPath: path)
        let stream = try await runtime.pushImage(reference: "registry.example.com/dory/web-api:dev")
        var body = Data()
        for await chunk in stream { body.append(chunk) }

        #expect(String(data: body, encoding: .utf8) == #"{"status":"pushed"}"# + "\n")
        #expect(recorder.requests.map(\.method) == ["POST"])
        #expect(recorder.requests.map(\.target) == [
            "/images/registry.example.com%2Fdory%2Fweb-api/push?tag=dev",
        ])
        #expect(recorder.requests.first?.headers["x-registry-auth"] == "e30=")
    }

    @Test func dockerEngineRuntimeUsesNativeMultiImageSaveEndpoint() async throws {
        let path = shortSocketPath("dory-docker-save-images")
        let recorder = RequestRecorder()
        let server = ShimHTTPServer(socketPath: path) { request in
            recorder.record(method: request.method, target: request.target, body: request.body)
            return ShimResponse(status: 200, headers: [(name: "Content-Type", value: "application/x-tar")], body: Data("multi archive".utf8))
        }
        try server.start()
        defer { server.stop() }

        let runtime = DockerEngineRuntime(socketPath: path)
        let stream = try await runtime.saveImages(references: ["postgres:16", "registry.example.com/team/app:qa"])
        var body = Data()
        for await chunk in stream { body.append(chunk) }

        #expect(String(data: body, encoding: .utf8) == "multi archive")
        #expect(recorder.requests.map(\.method) == ["GET"])
        #expect(recorder.requests.map(\.target) == [
            "/images/get?names=postgres%3A16&names=registry.example.com%2Fteam%2Fapp%3Aqa",
        ])
    }

    @Test func dockerEngineRuntimeStrictlyEncodesArchiveQueryPath() async throws {
        let path = shortSocketPath("dory-docker-archive-encoding")
        let recorder = RequestRecorder()
        let server = ShimHTTPServer(socketPath: path) { request in
            recorder.record(method: request.method, target: request.target, body: request.body)
            return ShimResponse(status: 200, headers: [], body: Data("archive".utf8))
        }
        try server.start()
        defer { server.stop() }

        let runtime = DockerEngineRuntime(socketPath: path)
        _ = await runtime.copyOut(containerID: "abc123", path: "/tmp/a&b?c=d+e")
        _ = await runtime.copyIn(containerID: "abc123", path: "/tmp/a&b?c=d+e", archive: Data("tar".utf8))

        #expect(recorder.requests.map(\.method) == ["GET", "PUT"])
        #expect(recorder.requests.map(\.target) == [
            "/containers/abc123/archive?path=%2Ftmp%2Fa%26b%3Fc%3Dd%2Be",
            "/containers/abc123/archive?path=%2Ftmp%2Fa%26b%3Fc%3Dd%2Be",
        ])
        #expect(recorder.requests.last?.body == Data("tar".utf8))
    }

    @Test func shimArchiveDecodesGoStyleQuerySpaces() async throws {
        let path = shortSocketPath("dory-shim-archive-query")
        let runtime = RecordingRuntime()
        runtime.copyOutArchive = Data("archive".utf8)
        let shim = DockerShim(runtime: runtime)
        let server = ShimHTTPServer(socketPath: path) { await shim.handle($0) }
        try server.start(); defer { server.stop() }
        let client = UnixSocketHTTP(path: path)

        let create = try await client.send(HTTPRequest(
            method: "POST",
            path: "/v1.47/containers/create?name=files",
            headers: [(name: "Content-Type", value: "application/json")],
            body: Data(#"{"Image":"busybox"}"#.utf8)
        ))
        #expect(create.statusCode == 201)
        struct CreateOut: Decodable { let Id: String }
        let id = try JSONDecoder().decode(CreateOut.self, from: create.body).Id

        let response = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/containers/files/archive?path=%2Ftmp%2Ftwo+words%2Ba.txt"))

        #expect(response.statusCode == 200)
        #expect(runtime.copiedOutPaths.first?.containerID == id)
        #expect(runtime.copiedOutPaths.first?.path == "/tmp/two words+a.txt")
    }

    @Test func shimArchiveHeadReturnsDockerPathStat() async throws {
        let path = shortSocketPath("dory-shim-archive-head")
        let runtime = RecordingRuntime()
        runtime.copyOutArchive = Data("archive".utf8)
        let shim = DockerShim(runtime: runtime)
        let server = ShimHTTPServer(socketPath: path) { await shim.handle($0) }
        try server.start(); defer { server.stop() }
        let client = UnixSocketHTTP(path: path)

        let create = try await client.send(HTTPRequest(
            method: "POST",
            path: "/v1.47/containers/create?name=files",
            headers: [(name: "Content-Type", value: "application/json")],
            body: Data(#"{"Image":"busybox"}"#.utf8)
        ))
        #expect(create.statusCode == 201)
        struct CreateOut: Decodable { let Id: String }
        let id = try JSONDecoder().decode(CreateOut.self, from: create.body).Id

        let response = try await client.send(HTTPRequest(method: "HEAD", path: "/v1.47/containers/files/archive?path=%2Fetc%2Fhosts"))
        #expect(response.statusCode == 200)
        #expect(response.body.isEmpty)
        #expect(runtime.copiedOutPaths.first?.containerID == id)
        #expect(runtime.copiedOutPaths.first?.path == "/etc/hosts")

        let encoded = try #require(response.headers["x-docker-container-path-stat"])
        let statData = try #require(Data(base64Encoded: encoded))
        let stat = try #require(try JSONSerialization.jsonObject(with: statData) as? [String: Any])
        #expect(stat["name"] as? String == "hosts")
        #expect((stat["size"] as? NSNumber)?.intValue == 7)
        #expect((stat["mode"] as? NSNumber)?.intValue == 0o644)

        runtime.copyOutArchive = nil
        let missing = try await client.send(HTTPRequest(method: "HEAD", path: "/v1.47/containers/files/archive?path=%2Fmissing"))
        #expect(missing.statusCode == 404)
    }

    // Image references that begin with '-' must be rejected at the shim boundary so they can never
    // be smuggled in as an option to the underlying engine CLI.
    @Test func shimRejectsOptionInjectionImage() async throws {
        let path = shortSocketPath("dory-inject")
        let runtime = RecordingRuntime()
        let shim = DockerShim(runtime: runtime)
        let server = ShimHTTPServer(socketPath: path) { await shim.handle($0) }
        try server.start(); defer { server.stop() }
        let client = UnixSocketHTTP(path: path)

        let create = try await client.send(HTTPRequest(method: "POST", path: "/v1.47/containers/create?name=x",
            headers: [(name: "Content-Type", value: "application/json")], body: Data(#"{"Image":"--privileged"}"#.utf8)))
        #expect(create.statusCode == 400)
        #expect(runtime.createdSpecs.isEmpty)
    }

    // exec: create -> start (101 upgrade) -> inspect exit code.
    @Test func shimExecRoundTrips() async throws {
        let path = shortSocketPath("dory-exec")
        let shim = DockerShim(runtime: RecordingRuntime())
        let server = ShimHTTPServer(socketPath: path) { await shim.handle($0) }
        try server.start(); defer { server.stop() }
        let client = UnixSocketHTTP(path: path)

        let container = try await client.send(HTTPRequest(
            method: "POST",
            path: "/v1.47/containers/create?name=exec-target",
            headers: [(name: "Content-Type", value: "application/json")],
            body: Data(#"{"Image":"busybox"}"#.utf8)
        ))
        #expect(container.statusCode == 201)
        struct CreateOut: Decodable { let Id: String }
        let containerID = try JSONDecoder().decode(CreateOut.self, from: container.body).Id

        let create = try await client.send(HTTPRequest(method: "POST", path: "/v1.47/containers/\(containerID)/exec",
            headers: [(name: "Content-Type", value: "application/json")], body: Data(#"{"Cmd":["echo","hi"]}"#.utf8)))
        #expect(create.statusCode == 201)
        struct ExecOut: Decodable { let Id: String }
        let execID = try JSONDecoder().decode(ExecOut.self, from: create.body).Id

        let start = try await client.send(HTTPRequest(method: "POST", path: "/v1.47/exec/\(execID)/start",
            headers: [(name: "Content-Type", value: "application/json")], body: Data("{}".utf8)))
        #expect(start.statusCode == 101)

        let inspect = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/exec/\(execID)/json"))
        struct ExecInspect: Decodable { let ExitCode: Int }
        let code = try JSONDecoder().decode(ExecInspect.self, from: inspect.body).ExitCode
        #expect(code == 0)
    }

    // #3: inspect must expose NetworkSettings.Ports for getMappedPort().
    @Test func inspectExposesPortMappings() async throws {
        let path = shortSocketPath("dory-fix2")
        let shim = DockerShim(runtime: MockRuntime())
        let server = ShimHTTPServer(socketPath: path) { await shim.handle($0) }
        try server.start(); defer { server.stop() }
        let client = UnixSocketHTTP(path: path)
        let resp = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/containers/c1/json"))
        let json = try #require(try JSONSerialization.jsonObject(with: resp.body) as? [String: Any])
        let net = json["NetworkSettings"] as? [String: Any]
        let ports = net?["Ports"] as? [String: Any]
        #expect(ports?["5432/tcp"] != nil) // postgres-db publishes 5432→5432
        let host = json["HostConfig"] as? [String: Any]
        let bindings = host?["PortBindings"] as? [String: Any]
        #expect(bindings?["5432/tcp"] != nil)
        #expect((json["Created"] as? String)?.isEmpty == false)
    }

    @Test func inspectExposesConfigEnvLabelsAndExitCode() async throws {
        let path = shortSocketPath("dory-inspect-config")
        let shim = DockerShim(runtime: MockRuntime())
        let server = ShimHTTPServer(socketPath: path) { await shim.handle($0) }
        try server.start(); defer { server.stop() }
        let client = UnixSocketHTTP(path: path)

        let resp = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/containers/c1/json"))
        let json = try #require(try JSONSerialization.jsonObject(with: resp.body) as? [String: Any])
        let config = try #require(json["Config"] as? [String: Any])
        let state = try #require(json["State"] as? [String: Any])
        let exposed = try #require(config["ExposedPorts"] as? [String: Any])
        let env = try #require(config["Env"] as? [String])
        let labels = try #require(config["Labels"] as? [String: String])

        #expect(json["Image"] as? String == "sha256:3f1a2b9c")
        #expect(config["Image"] as? String == "postgres:16")
        #expect(env.contains("NODE_ENV=production"))
        #expect(labels["com.docker.compose.project"] == "dory-stack")
        #expect(exposed["5432/tcp"] != nil)
        #expect(state["ExitCode"] as? Int == 0)
    }

    @Test func shimCreateInspectRoundTripsHostResourcesAndBinds() async throws {
        let path = shortSocketPath("dory-hostconfig")
        let runtime = RecordingRuntime()
        let shim = DockerShim(runtime: runtime)
        let server = ShimHTTPServer(socketPath: path) { await shim.handle($0) }
        try server.start(); defer { server.stop() }
        let client = UnixSocketHTTP(path: path)

        let body = Data("""
        {
          "Image": "ubuntu:24.04",
          "Labels": {"dory.machine": "ubuntu"},
          "HostConfig": {
            "Binds": ["/Users/me/project:/workspace:ro"],
            "NanoCpus": 2000000000,
            "Memory": 1073741824,
            "PortBindings": {"443/tcp": [{"HostPort": "8443"}]}
          }
        }
        """.utf8)
        let create = try await client.send(HTTPRequest(method: "POST", path: "/v1.47/containers/create?name=dev",
            headers: [(name: "Content-Type", value: "application/json")], body: body))
        #expect(create.statusCode == 201)
        #expect(runtime.createdSpecs.first?.volumes == ["/Users/me/project:/workspace:ro"])
        #expect(runtime.createdSpecs.first?.nanoCPUs == 2_000_000_000)
        #expect(runtime.createdSpecs.first?.memoryLimitBytes == 1_073_741_824)

        struct CreateOut: Decodable { let Id: String }
        let id = try JSONDecoder().decode(CreateOut.self, from: create.body).Id
        let inspect = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/containers/\(id)/json"))
        let json = try #require(try JSONSerialization.jsonObject(with: inspect.body) as? [String: Any])
        let host = try #require(json["HostConfig"] as? [String: Any])
        let net = try #require(json["NetworkSettings"] as? [String: Any])
        let hostBindings = try #require(host["PortBindings"] as? [String: Any])
        let netPorts = try #require(net["Ports"] as? [String: Any])
        #expect(host["Binds"] as? [String] == ["/Users/me/project:/workspace:ro"])
        #expect((host["NanoCpus"] as? NSNumber)?.int64Value == 2_000_000_000)
        #expect((host["Memory"] as? NSNumber)?.int64Value == 1_073_741_824)
        #expect((hostBindings["443/tcp"] as? [[String: Any]])?.first?["HostPort"] as? String == "8443")
        #expect((netPorts["443/tcp"] as? [[String: Any]])?.first?["HostPort"] as? String == "8443")
    }

    @Test func shimCreateInspectRoundTripsMountsAndTopLevelVolumes() async throws {
        let path = shortSocketPath("dory-mounts")
        let runtime = RecordingRuntime()
        let shim = DockerShim(runtime: runtime)
        let server = ShimHTTPServer(socketPath: path) { await shim.handle($0) }
        try server.start(); defer { server.stop() }
        let client = UnixSocketHTTP(path: path)

        let body = Data("""
        {
          "Image": "ubuntu:24.04",
          "Volumes": {"/cache": {}},
          "HostConfig": {
            "Mounts": [
              {"Type": "bind", "Source": "/Users/me/src", "Target": "/src", "ReadOnly": true},
              {"Type": "volume", "Source": "tool-cache", "Target": "/tool-cache"}
            ]
          }
        }
        """.utf8)
        let create = try await client.send(HTTPRequest(method: "POST", path: "/v1.47/containers/create?name=modern",
            headers: [(name: "Content-Type", value: "application/json")], body: body))
        #expect(create.statusCode == 201)
        #expect(runtime.createdSpecs.first?.volumeTargets == ["/cache"])
        #expect(runtime.createdSpecs.first?.mounts == [
            ContainerMount(type: "bind", source: "/Users/me/src", target: "/src", readOnly: true),
            ContainerMount(type: "volume", source: "tool-cache", target: "/tool-cache"),
        ])

        struct CreateOut: Decodable { let Id: String }
        let id = try JSONDecoder().decode(CreateOut.self, from: create.body).Id
        let inspect = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/containers/\(id)/json"))
        let json = try #require(try JSONSerialization.jsonObject(with: inspect.body) as? [String: Any])
        let config = try #require(json["Config"] as? [String: Any])
        let volumes = try #require(config["Volumes"] as? [String: Any])
        let mounts = try #require(json["Mounts"] as? [[String: Any]])
        #expect(volumes["/cache"] != nil)
        #expect(mounts.contains { $0["Type"] as? String == "bind" && $0["Source"] as? String == "/Users/me/src" && $0["Destination"] as? String == "/src" && $0["RW"] as? Bool == false })
        #expect(mounts.contains { $0["Type"] as? String == "volume" && $0["Name"] as? String == "tool-cache" && $0["Destination"] as? String == "/tool-cache" })
        #expect(mounts.contains { $0["Type"] as? String == "volume" && $0["Destination"] as? String == "/cache" })

        let list = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/containers/json?all=1"))
        let rows = try #require(try JSONSerialization.jsonObject(with: list.body) as? [[String: Any]])
        let row = try #require(rows.first { ($0["Names"] as? [String])?.contains("/modern") == true })
        let rowMounts = try #require(row["Mounts"] as? [[String: Any]])
        #expect(rowMounts.contains { $0["Type"] as? String == "bind" && $0["Source"] as? String == "/Users/me/src" && $0["Destination"] as? String == "/src" && $0["RW"] as? Bool == false })
        #expect(rowMounts.contains { $0["Type"] as? String == "volume" && $0["Name"] as? String == "tool-cache" && $0["Destination"] as? String == "/tool-cache" })
        #expect(rowMounts.contains { $0["Type"] as? String == "volume" && $0["Destination"] as? String == "/cache" })
    }

    @Test func shimWaitReturnsRuntimeExitCode() async throws {
        let path = shortSocketPath("dory-wait")
        let runtime = WaitRuntime(containers: [
            waitContainer(id: "c1", name: "worker", status: .stopped)
        ], exitCode: 137)
        let shim = DockerShim(runtime: runtime)
        let server = ShimHTTPServer(socketPath: path) { await shim.handle($0) }
        try server.start(); defer { server.stop() }
        let client = UnixSocketHTTP(path: path)

        let response = try await client.send(HTTPRequest(method: "POST", path: "/v1.47/containers/worker/wait"))
        let json = try #require(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        #expect(response.statusCode == 200)
        #expect(json["StatusCode"] as? Int == 137)

        let missing = try await client.send(HTTPRequest(method: "POST", path: "/v1.47/containers/missing/wait"))
        #expect(missing.statusCode == 404)
    }

    @Test func shimWaitBlocksUntilContainerStops() async throws {
        let path = shortSocketPath("dory-wait-blocking")
        let runtime = WaitRuntime(containers: [
            waitContainer(id: "c1abcdef", name: "worker", status: .running)
        ], exitCode: 12)
        let shim = DockerShim(runtime: runtime)
        let server = ShimHTTPServer(socketPath: path) { await shim.handle($0) }
        try server.start(); defer { server.stop() }
        let client = UnixSocketHTTP(path: path)

        let waitTask = Task {
            try await client.send(HTTPRequest(method: "POST", path: "/v1.47/containers/c1/wait"))
        }
        for _ in 0..<600 where await runtime.snapshotCount < 1 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await runtime.snapshotCount >= 1)
        await runtime.setStatus(id: "c1abcdef", status: .stopped)

        let response = try await waitTask.value
        let json = try #require(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        #expect(response.statusCode == 200)
        #expect(json["StatusCode"] as? Int == 12)
        #expect(await runtime.snapshotCount >= 2)
    }

    @Test func shimStatsEndpointReturnsDockerCompatiblePayload() async throws {
        let path = shortSocketPath("dory-stats")
        let shim = DockerShim(runtime: MockRuntime())
        let server = ShimHTTPServer(socketPath: path) { await shim.handle($0) }
        try server.start(); defer { server.stop() }
        let client = UnixSocketHTTP(path: path)

        let response = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/containers/c1/stats?stream=false"))

        #expect(response.statusCode == 200)
        let stats = try JSONDecoder().decode(DockerStats.self, from: response.body)
        let json = try #require(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        let memory = try #require(stats.memoryStats)
        #expect(json["name"] as? String == "/postgres-db")
        #expect(memory.usage == Int64(134_217_728))
        #expect(memory.limit == Int64(2 * 1024 * 1024 * 1024))
        #expect(abs(stats.cpuPercent - 2.4) < 0.01)
    }

    @Test func shimCoversSystemDiskUsageEndpoint() async throws {
        let path = shortSocketPath("dory-system-df")
        let shim = DockerShim(runtime: MockRuntime())
        let server = ShimHTTPServer(socketPath: path) { await shim.handle($0) }
        try server.start(); defer { server.stop() }
        let client = UnixSocketHTTP(path: path)

        let response = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/system/df"))

        #expect(response.statusCode == 200)
        let usage = try JSONDecoder().decode(DockerSystemDiskUsageOut.self, from: response.body)
        #expect(usage.Images.count == MockData.images.count)
        #expect(usage.Containers.count == MockData.containers.count)
        #expect(usage.Volumes.count == MockData.volumes.count)
        #expect(usage.BuildCache.isEmpty)
        #expect(usage.LayersSize == MockData.images.reduce(0) { $0 + $1.sizeBytes })
        #expect(usage.Images.first { $0.RepoTags.contains("postgres:16") }?.Size == 459_276_288)
        let postgresVolume = try #require(usage.Volumes.first { $0.Name == "postgres-data" })
        #expect(postgresVolume.UsageData.Size == 412 * 1024 * 1024)
        #expect(postgresVolume.UsageData.RefCount == 1)
        let postgresContainer = try #require(usage.Containers.first { $0.Names.contains("/postgres-db") })
        #expect(postgresContainer.ImageID == "sha256:3f1a2b9c")
    }

    @Test func shimCoversImageSearchEndpoint() async throws {
        let path = shortSocketPath("dory-image-search")
        let shim = DockerShim(runtime: MockRuntime())
        let server = ShimHTTPServer(socketPath: path) { await shim.handle($0) }
        try server.start(); defer { server.stop() }
        let client = UnixSocketHTTP(path: path)

        let response = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/images/search?term=nginx&limit=1"))
        #expect(response.statusCode == 200)
        let results = try JSONDecoder().decode([DockerImageSearchOut].self, from: response.body)
        #expect(results.count == 1)
        #expect(results.first?.name == "nginx")
        #expect(results.first?.is_official == true)
        #expect(results.first?.is_automated == false)
        #expect(results.first?.star_count == 0)

        let filters = (#"{"is-official":{"true":true},"stars":["0"]}"#)
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let filtered = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/images/search?term=dory&filters=\(filters)"))
        #expect(filtered.statusCode == 200)
        let filteredResults = try JSONDecoder().decode([DockerImageSearchOut].self, from: filtered.body)
        #expect(filteredResults.isEmpty)

        let missingTerm = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/images/search"))
        #expect(missingTerm.statusCode == 400)
    }

    @Test func shimPullFailureStreamsDockerErrorLine() async throws {
        let path = shortSocketPath("dory-pull-error")
        let runtime = RecordingRuntime()
        runtime.pullError = ShellError.nonZeroExit(1, "pull access denied")
        let shim = DockerShim(runtime: runtime)
        let server = ShimHTTPServer(socketPath: path) { await shim.handle($0) }
        try server.start(); defer { server.stop() }
        let client = UnixSocketHTTP(path: path)

        let response = try await client.send(HTTPRequest(method: "POST", path: "/v1.47/images/create?fromImage=registry.example.com%2Fprivate%2Fapp&tag=latest"))

        #expect(response.statusCode == 200)
        #expect(runtime.pulledImages == ["registry.example.com/private/app:latest"])
        let lines = String(decoding: response.body, as: UTF8.self).split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        let first = try #require(try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        #expect((first["status"] as? String)?.contains("Pulling from registry.example.com/private/app") == true)
        let last = try #require(try JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any])
        let detail = try #require(last["errorDetail"] as? [String: Any])
        #expect(detail["message"] as? String == "pull access denied")
        #expect(last["error"] as? String == "pull access denied")
        #expect(lines.contains { $0.contains("Pulled registry.example.com/private/app:latest") } == false)
    }

    @Test func containersJsonSizeFlagAddsContainerSizeFields() async throws {
        let path = shortSocketPath("dory-container-size")
        let shim = DockerShim(runtime: MockRuntime())
        let server = ShimHTTPServer(socketPath: path) { await shim.handle($0) }
        try server.start(); defer { server.stop() }
        let client = UnixSocketHTTP(path: path)

        let withoutSize = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/containers/json?all=1"))
        let withoutSizeJSON = try #require(try JSONSerialization.jsonObject(with: withoutSize.body) as? [[String: Any]])
        #expect(withoutSizeJSON.first?["SizeRw"] == nil)
        #expect(withoutSizeJSON.first?["SizeRootFs"] == nil)

        let withSize = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/containers/json?all=1&size=1"))
        #expect(withSize.statusCode == 200)
        let containers = try JSONDecoder().decode([DockerContainerOut].self, from: withSize.body)
        let postgres = try #require(containers.first { $0.Names.contains("/postgres-db") })
        #expect(postgres.SizeRw == 0)
        #expect(postgres.SizeRootFs == 459_276_288)
    }

    @Test func containerInspectSizeFlagAddsSizeFields() async throws {
        let path = shortSocketPath("dory-inspect-size")
        let shim = DockerShim(runtime: MockRuntime())
        let server = ShimHTTPServer(socketPath: path) { await shim.handle($0) }
        try server.start(); defer { server.stop() }
        let client = UnixSocketHTTP(path: path)

        let withoutSize = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/containers/c1/json"))
        let withoutSizeJSON = try #require(try JSONSerialization.jsonObject(with: withoutSize.body) as? [String: Any])
        #expect(withoutSizeJSON["SizeRw"] == nil)
        #expect(withoutSizeJSON["SizeRootFs"] == nil)

        let withSize = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/containers/c1/json?size=1"))
        #expect(withSize.statusCode == 200)
        let json = try #require(try JSONSerialization.jsonObject(with: withSize.body) as? [String: Any])
        #expect((json["SizeRw"] as? NSNumber)?.int64Value == 0)
        #expect((json["SizeRootFs"] as? NSNumber)?.int64Value == 459_276_288)
    }

    @Test func shimLogsHonorTailTimestampsAndFollow() async throws {
        let path = shortSocketPath("dory-logs")
        let runtime = RecordingRuntime()
        runtime.logLines = [
            LogLine(timestamp: "10:00:00.000", level: .info, message: "first"),
            LogLine(timestamp: "10:00:01.000", level: .error, message: "second"),
            LogLine(timestamp: "10:00:02.000", level: .info, message: "third"),
        ]
        runtime.streamedLogLines = [
            LogLine(timestamp: "10:00:03.000", level: .info, message: "live"),
        ]
        let shim = DockerShim(runtime: runtime)
        let server = ShimHTTPServer(socketPath: path) { await shim.handle($0) }
        try server.start(); defer { server.stop() }
        let client = UnixSocketHTTP(path: path)

        let create = try await client.send(HTTPRequest(
            method: "POST",
            path: "/v1.47/containers/create?name=logger",
            headers: [(name: "Content-Type", value: "application/json")],
            body: Data(#"{"Image":"busybox"}"#.utf8)
        ))
        #expect(create.statusCode == 201)
        struct CreateOut: Decodable { let Id: String }
        let id = try JSONDecoder().decode(CreateOut.self, from: create.body).Id

        let tailed = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/containers/\(id)/logs?stdout=1&stderr=1&tail=2"))
        #expect(tailed.statusCode == 200)
        #expect(tailed.headers["content-type"] == "application/vnd.docker.raw-stream")
        #expect(DockerLogFrames.plainText(tailed.body) == "second\nthird\n")

        let stamped = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/containers/\(id)/logs?stdout=1&tail=1&timestamps=1"))
        #expect(DockerLogFrames.plainText(stamped.body) == "10:00:02.000 third\n")

        let since = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/containers/\(id)/logs?stdout=1&timestamps=1&since=10%3A00%3A01.000"))
        #expect(DockerLogFrames.plainText(since.body) == "10:00:01.000 second\n10:00:02.000 third\n")

        let bounded = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/containers/\(id)/logs?stdout=1&timestamps=1&since=10%3A00%3A01.000&until=10%3A00%3A01.000"))
        #expect(DockerLogFrames.plainText(bounded.body) == "10:00:01.000 second\n")

        let rfc3339Since = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/containers/\(id)/logs?stdout=1&timestamps=1&since=2026-06-24T10%3A00%3A02Z"))
        #expect(DockerLogFrames.plainText(rfc3339Since.body) == "10:00:02.000 third\n")

        let stdoutOnly = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/containers/\(id)/logs?stdout=1&stderr=0&timestamps=1"))
        #expect(DockerLogFrames.plainText(stdoutOnly.body) == "10:00:00.000 first\n10:00:02.000 third\n")
        #expect(rawStreamTypes(stdoutOnly.body) == [1, 1])

        let stderrOnly = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/containers/\(id)/logs?stdout=0&stderr=1&timestamps=1"))
        #expect(DockerLogFrames.plainText(stderrOnly.body) == "10:00:01.000 second\n")
        #expect(rawStreamTypes(stderrOnly.body) == [2])

        let suppressed = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/containers/\(id)/logs?stdout=0&stderr=0"))
        #expect(suppressed.statusCode == 200)
        #expect(suppressed.body.isEmpty)

        let followed = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/containers/\(id)/logs?follow=1&stdout=1&tail=1&timestamps=1"))
        #expect(followed.statusCode == 200)
        #expect(DockerLogFrames.plainText(followed.body) == "10:00:02.000 third\n10:00:03.000 live\n")
    }

    @Test func shimAttachStreamsLogsOnTranslatedBackends() async throws {
        let path = shortSocketPath("dory-attach")
        let runtime = RecordingRuntime()
        runtime.logLines = [
            LogLine(timestamp: "10:00:00.000", level: .info, message: "first"),
            LogLine(timestamp: "10:00:01.000", level: .error, message: "second"),
        ]
        runtime.streamedLogLines = [
            LogLine(timestamp: "10:00:02.000", level: .error, message: "live"),
        ]
        let shim = DockerShim(runtime: runtime)
        let server = ShimHTTPServer(socketPath: path) { await shim.handle($0) }
        try server.start(); defer { server.stop() }
        let client = UnixSocketHTTP(path: path)

        let create = try await client.send(HTTPRequest(
            method: "POST",
            path: "/v1.47/containers/create?name=logger",
            headers: [(name: "Content-Type", value: "application/json")],
            body: Data(#"{"Image":"busybox"}"#.utf8)
        ))
        #expect(create.statusCode == 201)
        struct CreateOut: Decodable { let Id: String }
        let id = try JSONDecoder().decode(CreateOut.self, from: create.body).Id

        let attached = try await client.send(HTTPRequest(
            method: "POST",
            path: "/v1.47/containers/logger/attach?logs=1&stream=1&stdout=1&stderr=1&tail=1&timestamps=1",
            headers: [
                (name: "Connection", value: "Upgrade"),
                (name: "Upgrade", value: "tcp"),
            ]
        ))
        #expect(attached.statusCode == 101)
        #expect(attached.headers["content-type"] == "application/vnd.docker.raw-stream")
        #expect(attached.headers["upgrade"] == "tcp")
        #expect(runtime.loggedIDs == [id])
        #expect(DockerLogFrames.plainText(attached.body) == "10:00:01.000 second\n10:00:02.000 live\n")
        #expect(rawStreamTypes(attached.body) == [2, 2])
    }

    @Test func translatedContainerActionsResolveNamesAndShortIDs() async throws {
        let path = shortSocketPath("dory-container-resolve")
        let runtime = RecordingRuntime()
        runtime.logLines = [LogLine(timestamp: "", level: .info, message: "ready")]
        runtime.copyOutArchive = Data("archive".utf8)
        let shim = DockerShim(runtime: runtime)
        let server = ShimHTTPServer(socketPath: path) { await shim.handle($0) }
        try server.start(); defer { server.stop() }
        let client = UnixSocketHTTP(path: path)

        let create = try await client.send(HTTPRequest(
            method: "POST",
            path: "/v1.47/containers/create?name=web",
            headers: [(name: "Content-Type", value: "application/json")],
            body: Data(#"{"Image":"nginx:alpine"}"#.utf8)
        ))
        #expect(create.statusCode == 201)
        struct CreateOut: Decodable { let Id: String }
        let id = try JSONDecoder().decode(CreateOut.self, from: create.body).Id

        let logs = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/containers/web/logs?stdout=1"))
        #expect(logs.statusCode == 200)
        #expect(runtime.loggedIDs == [id])
        #expect(DockerLogFrames.plainText(logs.body) == "ready\n")

        let archive = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/containers/web/archive?path=%2Fetc%2Fhosts"))
        #expect(archive.statusCode == 200)
        #expect(runtime.copiedOutPaths.first?.containerID == id)
        #expect(runtime.copiedOutPaths.first?.path == "/etc/hosts")

        let shortID = String(id.prefix(2))
        let execCreate = try await client.send(HTTPRequest(
            method: "POST",
            path: "/v1.47/containers/\(shortID)/exec",
            headers: [(name: "Content-Type", value: "application/json")],
            body: Data(#"{"Cmd":["true"]}"#.utf8)
        ))
        #expect(execCreate.statusCode == 201)
        struct ExecOut: Decodable { let Id: String }
        let execID = try JSONDecoder().decode(ExecOut.self, from: execCreate.body).Id
        let execStart = try await client.send(HTTPRequest(
            method: "POST",
            path: "/v1.47/exec/\(execID)/start",
            headers: [(name: "Content-Type", value: "application/json")],
            body: Data("{}".utf8)
        ))
        #expect(execStart.statusCode == 101)
        #expect(runtime.execCalls.first?.id == id)

        let remove = try await client.send(HTTPRequest(method: "DELETE", path: "/v1.47/containers/web"))
        #expect(remove.statusCode == 204)
        #expect(runtime.removedIDs == [id])

        let missing = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/containers/web/logs?stdout=1"))
        #expect(missing.statusCode == 404)
        #expect(runtime.loggedIDs == [id])
    }

    @Test func shimCoversVolumeNetworkAndImageLifecycleEndpoints() async throws {
        let path = shortSocketPath("dory-lifecycle")
        let runtime = RecordingRuntime()
        let shim = DockerShim(runtime: runtime)
        let server = ShimHTTPServer(socketPath: path) { await shim.handle($0) }
        try server.start(); defer { server.stop() }
        let client = UnixSocketHTTP(path: path)

        let createVolume = try await client.send(HTTPRequest(
            method: "POST",
            path: "/v1.47/volumes/create",
            headers: [(name: "Content-Type", value: "application/json")],
            body: Data(#"{"Name":"cache-data","Driver":"local","DriverOpts":{"type":"tmpfs"},"Labels":{"com.example.cache":"true"}}"#.utf8)
        ))
        #expect(createVolume.statusCode == 201)
        #expect(runtime.volumesCreated == ["cache-data"])
        let createdVolume = try #require(try JSONSerialization.jsonObject(with: createVolume.body) as? [String: Any])
        #expect(createdVolume["Driver"] as? String == "local")
        #expect((createdVolume["Labels"] as? [String: Any])?["com.example.cache"] as? String == "true")
        #expect((createdVolume["Options"] as? [String: Any])?["type"] as? String == "tmpfs")
        #expect(runtime.volumeCreateRequests.first?.labels["com.example.cache"] == "true")
        #expect(runtime.volumeCreateRequests.first?.driverOptions["type"] == "tmpfs")

        let volumeFilters = #"{"label":["com.example.cache=true"]}"#.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let filteredVolumes = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/volumes?filters=\(volumeFilters)"))
        #expect(filteredVolumes.statusCode == 200)
        let filteredJSON = try #require(try JSONSerialization.jsonObject(with: filteredVolumes.body) as? [String: Any])
        let filteredVolumeList = try #require(filteredJSON["Volumes"] as? [[String: Any]])
        #expect(filteredVolumeList.count == 1)
        #expect(filteredVolumeList.first?["Name"] as? String == "cache-data")

        let removeVolume = try await client.send(HTTPRequest(method: "DELETE", path: "/v1.47/volumes/cache-data?force=true"))
        #expect(removeVolume.statusCode == 204)
        #expect(runtime.volumesRemoved == ["cache-data"])

        let missingVolume = try await client.send(HTTPRequest(method: "DELETE", path: "/v1.47/volumes/missing?force=true"))
        #expect(missingVolume.statusCode == 404)
        #expect(runtime.volumesRemoved == ["cache-data"])

        let createNetwork = try await client.send(HTTPRequest(
            method: "POST",
            path: "/v1.47/networks/create",
            headers: [(name: "Content-Type", value: "application/json")],
            body: Data(#"{"Name":"demo_default","Labels":{"com.docker.compose.project":"demo"}}"#.utf8)
        ))
        #expect(createNetwork.statusCode == 201)
        #expect(runtime.networksCreated == ["demo_default"])
        let createdNetwork = try #require(try JSONSerialization.jsonObject(with: createNetwork.body) as? [String: Any])
        #expect(createdNetwork["Id"] as? String == "demo_default")

        let connectNetwork = try await client.send(HTTPRequest(
            method: "POST",
            path: "/v1.47/networks/demo_default/connect",
            headers: [(name: "Content-Type", value: "application/json")],
            body: Data(#"{"Container":"web"}"#.utf8)
        ))
        #expect(connectNetwork.statusCode == 200)
        #expect(runtime.networksConnected.first?.name == "demo_default")
        #expect(runtime.networksConnected.first?.containerID == "web")

        let disconnectNetwork = try await client.send(HTTPRequest(
            method: "POST",
            path: "/v1.47/networks/demo_default/disconnect",
            headers: [(name: "Content-Type", value: "application/json")],
            body: Data(#"{"Container":"web","Force":true}"#.utf8)
        ))
        #expect(disconnectNetwork.statusCode == 200)
        #expect(runtime.networksDisconnected.first?.name == "demo_default")
        #expect(runtime.networksDisconnected.first?.containerID == "web")
        #expect(runtime.networksDisconnected.first?.force == true)

        let invalidConnect = try await client.send(HTTPRequest(
            method: "POST",
            path: "/v1.47/networks/demo_default/connect",
            headers: [(name: "Content-Type", value: "application/json")],
            body: Data(#"{}"#.utf8)
        ))
        #expect(invalidConnect.statusCode == 400)

        let removeNetwork = try await client.send(HTTPRequest(method: "DELETE", path: "/v1.47/networks/demo_default"))
        #expect(removeNetwork.statusCode == 204)
        #expect(runtime.networksRemoved == ["demo_default"])

        let removeImage = try await client.send(HTTPRequest(method: "DELETE", path: "/v1.47/images/dory%2Fweb-api:latest?force=1"))
        #expect(removeImage.statusCode == 200)
        #expect(runtime.imagesRemoved == ["dory/web-api:latest"])
        let deleted = try JSONDecoder().decode([DockerImageDeleteOut].self, from: removeImage.body)
        #expect(deleted.first?.Deleted == "dory/web-api:latest")

        let missingImage = try await client.send(HTTPRequest(method: "DELETE", path: "/v1.47/images/missing:latest?force=1"))
        #expect(missingImage.statusCode == 404)
        #expect(runtime.imagesRemoved == ["dory/web-api:latest"])

        let pruneContainers = try await client.send(HTTPRequest(method: "POST", path: "/v1.47/containers/prune"))
        let containerPruneResult = try JSONDecoder().decode(DockerContainerPruneOut.self, from: pruneContainers.body)
        let pruneVolumes = try await client.send(HTTPRequest(method: "POST", path: "/v1.47/volumes/prune"))
        let pruneNetworks = try await client.send(HTTPRequest(method: "POST", path: "/v1.47/networks/prune"))
        let networkPruneResult = try JSONDecoder().decode(DockerNetworkPruneOut.self, from: pruneNetworks.body)
        let pruneImages = try await client.send(HTTPRequest(method: "POST", path: "/v1.47/images/prune"))
        #expect(pruneContainers.statusCode == 200)
        #expect(containerPruneResult.ContainersDeleted.isEmpty)
        #expect(containerPruneResult.SpaceReclaimed == 0)
        #expect(pruneVolumes.statusCode == 200)
        #expect(pruneNetworks.statusCode == 200)
        #expect(networkPruneResult.NetworksDeleted.isEmpty)
        #expect(networkPruneResult.SpaceReclaimed == 0)
        #expect(pruneImages.statusCode == 200)
        #expect(runtime.prunedContainers)
        #expect(runtime.prunedVolumes)
        #expect(runtime.prunedNetworks)
        #expect(runtime.prunedImages)
    }

    @Test func shimMapsNetworkLifecycleRuntimeFailuresToDockerStatuses() async throws {
        let path = shortSocketPath("dory-network-failure-status")
        let runtime = RecordingRuntime()
        runtime.preexistingNetworks = ["taken"]
        runtime.missingNetworks = ["gone"]
        let shim = DockerShim(runtime: runtime)
        let server = ShimHTTPServer(socketPath: path) { await shim.handle($0) }
        try server.start(); defer { server.stop() }
        let client = UnixSocketHTTP(path: path)

        let duplicate = try await client.send(HTTPRequest(
            method: "POST",
            path: "/v1.47/networks/create",
            headers: [(name: "Content-Type", value: "application/json")],
            body: Data(#"{"Name":"taken"}"#.utf8)
        ))
        #expect(duplicate.statusCode == 409)
        let duplicateError = try #require(try JSONSerialization.jsonObject(with: duplicate.body) as? [String: String])
        #expect(duplicateError["message"]?.localizedCaseInsensitiveContains("already exists") == true)

        let missing = try await client.send(HTTPRequest(method: "DELETE", path: "/v1.47/networks/gone"))
        #expect(missing.statusCode == 404)
        let missingError = try #require(try JSONSerialization.jsonObject(with: missing.body) as? [String: String])
        #expect(missingError["message"] == "network gone not found")
    }

    @Test func shimCoversImageArchiveAndCommitEndpoints() async throws {
        let path = shortSocketPath("dory-image-archive")
        let runtime = RecordingRuntime()
        runtime.imageArchiveChunks = [Data("archive-".utf8), Data("chunk".utf8)]
        let shim = DockerShim(runtime: runtime)
        let server = ShimHTTPServer(socketPath: path) { await shim.handle($0) }
        try server.start(); defer { server.stop() }
        let client = UnixSocketHTTP(path: path)

        let container = try await client.send(HTTPRequest(
            method: "POST",
            path: "/v1.47/containers/create?name=snapshot-source",
            headers: [(name: "Content-Type", value: "application/json")],
            body: Data(#"{"Image":"busybox"}"#.utf8)
        ))
        #expect(container.statusCode == 201)
        struct CreateOut: Decodable { let Id: String }
        let containerID = try JSONDecoder().decode(CreateOut.self, from: container.body).Id

        let commit = try await client.send(HTTPRequest(
            method: "POST",
            path: "/v1.47/commit?container=\(containerID)&repo=dory%2Fsnapshot&tag=dev",
            headers: [(name: "Content-Type", value: "application/json")],
            body: Data(#"{"Labels":{"com.example.snapshot":"true"}}"#.utf8)
        ))
        #expect(commit.statusCode == 201)
        let commitOut = try JSONDecoder().decode(DockerCommitOut.self, from: commit.body)
        #expect(commitOut.Id == "sha256:commit1")
        #expect(runtime.committedImages.first?.containerID == containerID)
        #expect(runtime.committedImages.first?.repo == "dory/snapshot")
        #expect(runtime.committedImages.first?.tag == "dev")
        #expect(runtime.committedImages.first?.labels["com.example.snapshot"] == "true")

        let tag = try await client.send(HTTPRequest(method: "POST", path: "/v1.47/images/dory%2Fsnapshot:dev/tag?repo=dory%2Fsnapshot-copy&tag=qa"))
        #expect(tag.statusCode == 201)
        #expect(runtime.taggedImages.first?.source == "dory/snapshot:dev")
        #expect(runtime.taggedImages.first?.repo == "dory/snapshot-copy")
        #expect(runtime.taggedImages.first?.tag == "qa")

        let badTag = try await client.send(HTTPRequest(method: "POST", path: "/v1.47/images/dory%2Fsnapshot:dev/tag"))
        #expect(badTag.statusCode == 400)

        runtime.imagePushChunks = [Data(#"{"status":"pushed qa"}"#.utf8) + Data("\n".utf8)]
        let push = try await client.send(HTTPRequest(
            method: "POST",
            path: "/v1.47/images/dory%2Fsnapshot-copy/push?tag=qa",
            headers: [(name: "X-Registry-Auth", value: "e30=")]
        ))
        #expect(push.statusCode == 200)
        #expect(push.headers["content-type"] == "application/json")
        #expect(String(data: push.body, encoding: .utf8) == #"{"status":"pushed qa"}"# + "\n")
        #expect(runtime.pushedImages == ["dory/snapshot-copy:qa"])

        let save = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/images/dory%2Fsnapshot:dev/get"))
        #expect(save.statusCode == 200)
        #expect(save.headers["content-type"] == "application/x-tar")
        #expect(String(data: save.body, encoding: .utf8) == "archive-chunk")
        #expect(runtime.savedImages == ["dory/snapshot:dev"])

        let names = (#"["postgres:16"]"#).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let saveByNames = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/images/get?names=\(names)"))
        #expect(saveByNames.statusCode == 200)
        #expect(runtime.savedImages.last == "postgres:16")

        let multiImageSave = try await client.send(HTTPRequest(
            method: "GET",
            path: "/v1.47/images/get?names=postgres%3A16&names=alpine%3A3.22"
        ))
        #expect(multiImageSave.statusCode == 200)
        #expect(multiImageSave.headers["content-type"] == "application/x-tar")
        #expect(String(data: multiImageSave.body, encoding: .utf8) == "archive-chunk")
        #expect(runtime.savedImageBatches == [["postgres:16"], ["postgres:16", "alpine:3.22"]])

        let loadArchive = Data("loaded archive".utf8)
        let load = try await client.send(HTTPRequest(
            method: "POST",
            path: "/v1.47/images/load",
            headers: [(name: "Content-Type", value: "application/x-tar")],
            body: loadArchive
        ))
        #expect(load.statusCode == 200)
        #expect(runtime.loadedImageArchives == [loadArchive])
        #expect(String(data: load.body, encoding: .utf8)?.contains("Loaded image") == true)

        let missingNames = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/images/get"))
        #expect(missingNames.statusCode == 400)
    }

    @Test func shimCoversContainerExportEndpoint() async throws {
        let path = shortSocketPath("dory-container-export")
        let runtime = RecordingRuntime()
        runtime.copyOutArchive = Data("container rootfs tar".utf8)
        let shim = DockerShim(runtime: runtime)
        let server = ShimHTTPServer(socketPath: path) { await shim.handle($0) }
        try server.start(); defer { server.stop() }
        let client = UnixSocketHTTP(path: path)

        let create = try await client.send(HTTPRequest(
            method: "POST",
            path: "/v1.47/containers/create?name=exportable",
            headers: [(name: "Content-Type", value: "application/json")],
            body: Data(#"{"Image":"busybox"}"#.utf8)
        ))
        #expect(create.statusCode == 201)
        struct CreateOut: Decodable { let Id: String }
        let id = try JSONDecoder().decode(CreateOut.self, from: create.body).Id

        let export = try await client.send(HTTPRequest(method: "GET", path: "/v1.47/containers/exportable/export"))

        #expect(export.statusCode == 200)
        #expect(export.headers["content-type"] == "application/x-tar")
        #expect(String(data: export.body, encoding: .utf8) == "container rootfs tar")
        #expect(runtime.copiedOutPaths.first?.containerID == id)
        #expect(runtime.copiedOutPaths.first?.path == "/")
    }

    @Test func shimCoversRegistryAuthEndpoint() async throws {
        let path = shortSocketPath("dory-registry-auth")
        let runtime = RecordingRuntime()
        let shim = DockerShim(runtime: runtime)
        let server = ShimHTTPServer(socketPath: path) { await shim.handle($0) }
        try server.start(); defer { server.stop() }
        let client = UnixSocketHTTP(path: path)

        let login = try await client.send(HTTPRequest(
            method: "POST",
            path: "/v1.47/auth",
            headers: [(name: "Content-Type", value: "application/json")],
            body: Data(#"{"username":"octo","password":"secret","serveraddress":"Registry.Example.com"}"#.utf8)
        ))

        #expect(login.statusCode == 200)
        #expect(try JSONDecoder().decode(DockerAuthOut.self, from: login.body).Status == "Login Succeeded")
        #expect(runtime.logins.first?.registry == "registry.example.com")
        #expect(runtime.logins.first?.username == "octo")
        #expect(runtime.logins.first?.password == "secret")

        let encodedAuth = Data("bot:token".utf8).base64EncodedString()
        let authFieldLogin = try await client.send(HTTPRequest(
            method: "POST",
            path: "/v1.47/auth",
            headers: [(name: "Content-Type", value: "application/json")],
            body: Data(#"{"auth":"\#(encodedAuth)","serveraddress":"docker.io"}"#.utf8)
        ))
        #expect(authFieldLogin.statusCode == 200)
        #expect(runtime.logins.last?.registry == "https://index.docker.io/v1/")
        #expect(runtime.logins.last?.username == "bot")
        #expect(runtime.logins.last?.password == "token")

        let invalid = try await client.send(HTTPRequest(
            method: "POST",
            path: "/v1.47/auth",
            headers: [(name: "Content-Type", value: "application/json")],
            body: Data(#"{"serveraddress":"registry.example.com"}"#.utf8)
        ))
        #expect(invalid.statusCode == 400)
    }

    // #12: interpolation operator precedence with a hyphen in the error message.
    @Test func interpolationHandlesHyphenInRequiredMessage() {
        #expect(ComposeInterpolation.interpolate("${VAR:?must-be-set}", variables: ["VAR": "x"]) == "x")
        #expect(ComposeInterpolation.interpolate("${VAR-a-b-c}", variables: [:]) == "a-b-c")
    }

    // #21: yes/no must remain strings (YAML 1.2 / compose), not become true/false.
    @Test func yamlYesNoStayStrings() throws {
        let root = try YAMLParser.parse("env:\n  FEATURE: yes\n  OTHER: no\n  REAL: true")
        #expect(root["env"]?["FEATURE"]?.stringValue == "yes")
        #expect(root["env"]?["OTHER"]?.stringValue == "no")
        #expect(root["env"]?["REAL"]?.boolValue == true)
    }

    // #14: nested block under an inline-map sequence item must not be dropped.
    @Test func yamlNestedBlockUnderSequenceItem() throws {
        let yaml = """
        ports:
          - target: 80
            published: 8080
            meta:
              key: val
        """
        let item = try #require(try YAMLParser.parse(yaml)["ports"]?.sequenceValue?.first)
        #expect(item["target"]?.stringValue == "80")
        #expect(item["published"]?.stringValue == "8080")
        #expect(item["meta"]?["key"]?.stringValue == "val") // previously dropped to null
    }

    // #13: service_completed_successfully must fail when the dependency exits non-zero.
    @Test func composeFailsOnNonZeroCompletedDependency() async throws {
        let yaml = """
        services:
          migrate:
            image: busybox
          app:
            image: nginx
            depends_on:
              migrate:
                condition: service_completed_successfully
        """
        let project = try ComposeParser.parse(yaml, projectName: "demo")
        let runtime = FailingCompletionRuntime()
        let engine = ComposeEngine(runtime: runtime, healthPollCap: 0.01, maxHealthAttempts: 3)
        await #expect(throws: ComposeError.self) { try await engine.up(project) }
    }

    private func shortSocketPath(_ prefix: String) -> String {
        "/tmp/\(prefix)-\(UUID().uuidString).sock"
    }

    private func rawStreamTypes(_ data: Data) -> [UInt8] {
        let bytes = [UInt8](data)
        var types: [UInt8] = []
        var index = 0
        while index + 8 <= bytes.count {
            let streamType = bytes[index]
            guard streamType <= 2,
                  bytes[index + 1] == 0,
                  bytes[index + 2] == 0,
                  bytes[index + 3] == 0 else {
                break
            }
            let size = (Int(bytes[index + 4]) << 24)
                | (Int(bytes[index + 5]) << 16)
                | (Int(bytes[index + 6]) << 8)
                | Int(bytes[index + 7])
            guard size >= 0, index + 8 + size <= bytes.count else { break }
            types.append(streamType)
            index += 8 + size
        }
        return types
    }
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [(method: String, target: String, body: Data, headers: [String: String])] = []

    var requests: [(method: String, target: String, body: Data, headers: [String: String])] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func record(method: String, target: String, body: Data, headers: [String: String] = [:]) {
        lock.lock()
        stored.append((method, target, body, headers))
        lock.unlock()
    }
}

private func waitContainer(id: String, name: String, status: RunState) -> Container {
    Container(
        id: id,
        name: name,
        image: "busybox",
        status: status,
        cpuPercent: 0,
        memoryDisplay: "0 MB",
        memoryLimitDisplay: "—",
        memoryFraction: 0,
        ports: "—",
        uptime: "—",
        created: "now",
        ipAddress: "—",
        domain: "",
        command: "true",
        restartPolicy: "no"
    )
}

@MainActor
private final class WaitRuntime: ContainerRuntime {
    let kind: RuntimeKind = .mock
    private var containers: [Container]
    private let exitCode: Int?
    private(set) var snapshotCount = 0

    init(containers: [Container], exitCode: Int?) {
        self.containers = containers
        self.exitCode = exitCode
    }

    func snapshot() async throws -> RuntimeSnapshot {
        snapshotCount += 1
        return RuntimeSnapshot(containers: containers)
    }

    func setStatus(id: String, status: RunState) {
        guard let index = containers.firstIndex(where: { $0.id == id || $0.name == id }) else { return }
        containers[index].status = status
    }

    func start(containerID: String) async throws {}
    func stop(containerID: String) async throws {}
    func restart(containerID: String) async throws {}
    func remove(containerID: String) async throws {}
    func logs(containerID: String) async throws -> [LogLine] { [] }
    func env(containerID: String) async throws -> [EnvVar] { [] }
    func create(_ spec: ContainerSpec) async throws -> String { "created" }
    func exec(containerID: String, command: [String]) async throws -> ExecResult { ExecResult(exitCode: 0, output: "") }
    func containerExitCode(_ id: String) async -> Int? { exitCode }
}

@MainActor
final class FailingCompletionRuntime: ContainerRuntime {
    let kind: RuntimeKind = .mock
    private var live: [Container] = []
    private var n = 0
    func snapshot() async throws -> RuntimeSnapshot { RuntimeSnapshot(containers: live) }
    func create(_ spec: ContainerSpec) async throws -> String {
        n += 1; let id = "id\(n)"
        // migrate is created already-stopped (completed); app would start after.
        let stopped = spec.name.contains("migrate")
        live.append(Container(id: id, name: spec.name, image: spec.image, status: stopped ? .stopped : .running,
            cpuPercent: 0, memoryDisplay: "0", memoryLimitDisplay: "—", memoryFraction: 0, ports: "—",
            uptime: "—", created: "now", ipAddress: "—", domain: "", command: "", restartPolicy: "no"))
        return id
    }
    func start(containerID: String) async throws {}
    func stop(containerID: String) async throws {}
    func restart(containerID: String) async throws {}
    func remove(containerID: String) async throws {}
    func logs(containerID: String) async throws -> [LogLine] { [] }
    func env(containerID: String) async throws -> [EnvVar] { [] }
    func exec(containerID: String, command: [String]) async throws -> ExecResult { ExecResult(exitCode: 0, output: "") }
    func containerExitCode(_ id: String) async -> Int? { 1 } // dependency failed
}
