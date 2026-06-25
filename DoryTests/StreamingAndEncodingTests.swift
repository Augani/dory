import Testing
import Foundation
@testable import Dory

struct StreamingAndEncodingTests {
    private func frame(_ payload: String, stream: UInt8 = 1) -> Data {
        let bytes = Array(payload.utf8)
        let size = UInt32(bytes.count)
        var data = Data([stream, 0, 0, 0])
        data.append(contentsOf: [UInt8(size >> 24 & 0xff), UInt8(size >> 16 & 0xff), UInt8(size >> 8 & 0xff), UInt8(size & 0xff)])
        data.append(contentsOf: bytes)
        return data
    }

    @Test func logStreamDecoderParsesCompleteFrames() {
        let decoder = LogStreamDecoder()
        let lines = decoder.feed(frame("2026-06-18T12:00:00.123456789Z hello world\n"))
        #expect(lines.count == 1)
        #expect(lines.first?.message == "hello world")
        #expect(lines.first?.timestamp == "12:00:00.123")
    }

    @Test func logStreamDecoderHandlesSplitChunks() {
        let decoder = LogStreamDecoder()
        let full = frame("line one\n")
        let firstHalf = full.prefix(5)
        let secondHalf = full.suffix(from: full.index(full.startIndex, offsetBy: 5))
        #expect(decoder.feed(Data(firstHalf)).isEmpty) // incomplete frame -> no lines yet
        let lines = decoder.feed(Data(secondHalf))
        #expect(lines.first?.message == "line one")
    }

    @Test func logStreamDecoderDetectsLevels() {
        let decoder = LogStreamDecoder()
        let lines = decoder.feed(frame("ERROR something failed\n") + frame("WARN watch out\n"))
        #expect(lines.count == 2)
        #expect(lines[0].level == .error)
        #expect(lines[1].level == .warn)
    }

    @Test func createBodyEncodesPortsEnvAndHostResources() throws {
        let spec = ContainerSpec(
            name: "web",
            image: "nginx:alpine",
            environment: ["A": "b"],
            ports: ["127.0.0.1:8080:80", "5353:53/udp", "443", "[::1]:9443:8443"],
            labels: ["x": "y"],
            volumes: ["/Users/me/app:/workspace:ro", "/cache"],
            nanoCPUs: 2_000_000_000,
            memoryLimitBytes: 1_073_741_824,
            mounts: [
                ContainerMount(type: "bind", source: "/Users/me/src", target: "/src", readOnly: true),
                ContainerMount(type: "volume", source: "tool-cache", target: "/tool-cache"),
            ],
            hostname: "web-host",
            user: "1000:1000",
            workingDir: "/workspace",
            entrypoint: ["/bin/sh", "-lc"],
            tty: true,
            openStdin: true,
            stopSignal: "SIGTERM",
            stopTimeout: 15,
            networkMode: "bridge",
            autoRemove: true,
            privileged: true,
            initProcessEnabled: true,
            capAdd: ["NET_ADMIN"],
            capDrop: ["MKNOD"],
            dns: ["1.1.1.1"],
            dnsOptions: ["ndots:0"],
            dnsSearch: ["dory.local"],
            extraHosts: ["host.docker.internal:host-gateway"],
            groupAdd: ["staff"],
            pidMode: "host",
            readonlyRootfs: true,
            shmSize: 67_108_864,
            tmpfs: ["/tmp": "rw,noexec"],
            attachStdin: true,
            attachStdout: true,
            attachStderr: false,
            healthcheck: DockerHealthConfig(
                Test: ["CMD-SHELL", "curl -f http://localhost/health || exit 1"],
                Interval: 30_000_000_000,
                Timeout: 3_000_000_000,
                Retries: 3,
                StartPeriod: 10_000_000_000,
                StartInterval: 1_000_000_000
            ),
            networkDisabled: true,
            containerIDFile: "/tmp/container.id",
            logConfig: DockerLogConfig(Type: "json-file", Config: ["max-size": "10m"]),
            volumeDriver: "local",
            volumesFrom: ["parent:ro"],
            consoleSize: [40, 120],
            annotations: ["com.example.runtime": "dev"],
            cgroupnsMode: "private",
            cgroup: "dory",
            links: ["redis:redis"],
            oomScoreAdj: 250,
            publishAllPorts: true,
            securityOpt: ["no-new-privileges"],
            storageOpt: ["size": "20G"],
            utsMode: "host",
            sysctls: ["net.ipv4.ip_forward": "1"],
            runtimeName: "runc",
            isolation: "default",
            maskedPaths: ["/proc/acpi"],
            readonlyPaths: ["/proc/sys"],
            resources: ContainerResourceUpdate(
                memoryReservationBytes: 536_870_912,
                pidsLimit: 128,
                ulimits: [DockerUlimit(Name: "nofile", Soft: 1_024, Hard: 2_048)]
            )
        )
        let data = try JSONEncoder().encode(DockerCreateBody(spec: spec))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["Image"] as? String == "nginx:alpine")
        #expect(json["Hostname"] as? String == "web-host")
        #expect(json["User"] as? String == "1000:1000")
        #expect(json["AttachStdin"] as? Bool == true)
        #expect(json["AttachStdout"] as? Bool == true)
        #expect(json["AttachStderr"] as? Bool == false)
        #expect(json["WorkingDir"] as? String == "/workspace")
        #expect(json["Entrypoint"] as? [String] == ["/bin/sh", "-lc"])
        #expect(json["Tty"] as? Bool == true)
        #expect(json["OpenStdin"] as? Bool == true)
        #expect(json["NetworkDisabled"] as? Bool == true)
        #expect(json["StopSignal"] as? String == "SIGTERM")
        #expect(json["StopTimeout"] as? Int == 15)
        let healthcheck = json["Healthcheck"] as? [String: Any]
        #expect(healthcheck?["Test"] as? [String] == ["CMD-SHELL", "curl -f http://localhost/health || exit 1"])
        #expect((healthcheck?["Retries"] as? NSNumber)?.intValue == 3)
        let env = json["Env"] as? [String]
        #expect(env == ["A=b"])
        let exposed = json["ExposedPorts"] as? [String: Any]
        #expect(exposed?["80/tcp"] != nil)
        #expect(exposed?["53/udp"] != nil)
        #expect(exposed?["443/tcp"] != nil)
        #expect(exposed?["8443/tcp"] != nil)
        let hostConfig = json["HostConfig"] as? [String: Any]
        let bindings = hostConfig?["PortBindings"] as? [String: Any]
        let portMaps = bindings?["80/tcp"] as? [[String: Any]]
        #expect(portMaps?.first?["HostPort"] as? String == "8080")
        #expect(portMaps?.first?["HostIp"] as? String == "127.0.0.1")
        let udpMaps = bindings?["53/udp"] as? [[String: Any]]
        #expect(udpMaps?.first?["HostPort"] as? String == "5353")
        let ipv6Maps = bindings?["8443/tcp"] as? [[String: Any]]
        #expect(ipv6Maps?.first?["HostPort"] as? String == "9443")
        #expect(ipv6Maps?.first?["HostIp"] as? String == "::1")
        #expect(hostConfig?["NetworkMode"] as? String == "bridge")
        #expect(hostConfig?["AutoRemove"] as? Bool == true)
        #expect(hostConfig?["Privileged"] as? Bool == true)
        #expect(hostConfig?["ContainerIDFile"] as? String == "/tmp/container.id")
        let logConfig = hostConfig?["LogConfig"] as? [String: Any]
        #expect(logConfig?["Type"] as? String == "json-file")
        #expect((logConfig?["Config"] as? [String: String])?["max-size"] == "10m")
        #expect(hostConfig?["VolumeDriver"] as? String == "local")
        #expect(hostConfig?["VolumesFrom"] as? [String] == ["parent:ro"])
        #expect(hostConfig?["ConsoleSize"] as? [Int] == [40, 120])
        #expect((hostConfig?["Annotations"] as? [String: String])?["com.example.runtime"] == "dev")
        #expect(hostConfig?["Init"] as? Bool == true)
        #expect(hostConfig?["CapAdd"] as? [String] == ["NET_ADMIN"])
        #expect(hostConfig?["CapDrop"] as? [String] == ["MKNOD"])
        #expect(hostConfig?["CgroupnsMode"] as? String == "private")
        #expect(hostConfig?["Dns"] as? [String] == ["1.1.1.1"])
        #expect(hostConfig?["DnsOptions"] as? [String] == ["ndots:0"])
        #expect(hostConfig?["DnsSearch"] as? [String] == ["dory.local"])
        #expect(hostConfig?["ExtraHosts"] as? [String] == ["host.docker.internal:host-gateway"])
        #expect(hostConfig?["GroupAdd"] as? [String] == ["staff"])
        #expect(hostConfig?["Cgroup"] as? String == "dory")
        #expect(hostConfig?["Links"] as? [String] == ["redis:redis"])
        #expect(hostConfig?["OomScoreAdj"] as? Int == 250)
        #expect(hostConfig?["PublishAllPorts"] as? Bool == true)
        #expect(hostConfig?["PidMode"] as? String == "host")
        #expect(hostConfig?["ReadonlyRootfs"] as? Bool == true)
        #expect(hostConfig?["SecurityOpt"] as? [String] == ["no-new-privileges"])
        #expect((hostConfig?["StorageOpt"] as? [String: String])?["size"] == "20G")
        #expect((hostConfig?["ShmSize"] as? NSNumber)?.int64Value == 67_108_864)
        #expect((hostConfig?["Tmpfs"] as? [String: String])?["/tmp"] == "rw,noexec")
        #expect(hostConfig?["UTSMode"] as? String == "host")
        #expect((hostConfig?["Sysctls"] as? [String: String])?["net.ipv4.ip_forward"] == "1")
        #expect(hostConfig?["Runtime"] as? String == "runc")
        #expect(hostConfig?["Isolation"] as? String == "default")
        #expect(hostConfig?["MaskedPaths"] as? [String] == ["/proc/acpi"])
        #expect(hostConfig?["ReadonlyPaths"] as? [String] == ["/proc/sys"])
        #expect(hostConfig?["Binds"] as? [String] == ["/Users/me/app:/workspace:ro"])
        let volumes = json["Volumes"] as? [String: Any]
        #expect(volumes?["/cache"] != nil)
        let mounts = hostConfig?["Mounts"] as? [[String: Any]]
        #expect(mounts?.first?["Type"] as? String == "bind")
        #expect(mounts?.first?["Source"] as? String == "/Users/me/src")
        #expect(mounts?.first?["Target"] as? String == "/src")
        #expect(mounts?.first?["ReadOnly"] as? Bool == true)
        #expect(mounts?.last?["Type"] as? String == "volume")
        #expect(mounts?.last?["Source"] as? String == "tool-cache")
        #expect(mounts?.last?["Target"] as? String == "/tool-cache")
        #expect((hostConfig?["NanoCpus"] as? NSNumber)?.int64Value == 2_000_000_000)
        #expect((hostConfig?["Memory"] as? NSNumber)?.int64Value == 1_073_741_824)
        #expect((hostConfig?["MemoryReservation"] as? NSNumber)?.int64Value == 536_870_912)
        #expect((hostConfig?["PidsLimit"] as? NSNumber)?.int64Value == 128)
        let ulimits = hostConfig?["Ulimits"] as? [[String: Any]]
        #expect(ulimits?.first?["Name"] as? String == "nofile")
        #expect((ulimits?.first?["Hard"] as? NSNumber)?.int64Value == 2_048)
    }

    @Test func serializeResponseRoundTrips() throws {
        let response = HTTPCodec.serializeResponse(status: 200, headers: [(name: "Content-Type", value: "application/json")], body: Data("{}".utf8))
        let text = String(data: response, encoding: .utf8)!
        #expect(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(text.contains("Content-Length: 2\r\n"))
        #expect(text.hasSuffix("\r\n\r\n{}"))
    }

    @Test func createBodyEncodesNetworkingConfigEndpointSettings() throws {
        var spec = ContainerSpec(name: "web", image: "nginx:alpine")
        spec.networks = ["front", "back"]
        spec.networkAliases = ["front": ["web", "api"]]
        spec.networkEndpointSettings = [
            "front": DockerEndpointSettings(
                IPAMConfig: DockerEndpointIPAMConfig(
                    IPv4Address: "172.20.0.10",
                    IPv6Address: "fd00::10",
                    LinkLocalIPs: ["169.254.1.2"]
                ),
                Links: ["db:db"],
                Aliases: ["web", "api"],
                NetworkID: "net123",
                EndpointID: "endpoint123",
                Gateway: "172.20.0.1",
                IPAddress: "172.20.0.10",
                IPPrefixLen: 24,
                IPv6Gateway: "fd00::1",
                GlobalIPv6Address: "fd00::10",
                GlobalIPv6PrefixLen: 64,
                MacAddress: "02:42:ac:14:00:0a",
                DriverOpts: ["com.example.mode": "fast"]
            ),
        ]

        let data = try JSONEncoder().encode(DockerCreateBody(spec: spec))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hostConfig = try #require(json["HostConfig"] as? [String: Any])
        let networking = try #require(json["NetworkingConfig"] as? [String: Any])
        let endpoints = try #require(networking["EndpointsConfig"] as? [String: Any])
        let front = try #require(endpoints["front"] as? [String: Any])
        let back = try #require(endpoints["back"] as? [String: Any])

        #expect(hostConfig["NetworkMode"] as? String == "front")
        #expect(front["Aliases"] as? [String] == ["web", "api"])
        let ipam = try #require(front["IPAMConfig"] as? [String: Any])
        #expect(ipam["IPv4Address"] as? String == "172.20.0.10")
        #expect(ipam["IPv6Address"] as? String == "fd00::10")
        #expect(ipam["LinkLocalIPs"] as? [String] == ["169.254.1.2"])
        #expect(front["Links"] as? [String] == ["db:db"])
        #expect(front["NetworkID"] as? String == "net123")
        #expect(front["EndpointID"] as? String == "endpoint123")
        #expect(front["Gateway"] as? String == "172.20.0.1")
        #expect(front["IPAddress"] as? String == "172.20.0.10")
        #expect(front["IPPrefixLen"] as? Int == 24)
        #expect(front["IPv6Gateway"] as? String == "fd00::1")
        #expect(front["GlobalIPv6Address"] as? String == "fd00::10")
        #expect(front["GlobalIPv6PrefixLen"] as? Int == 64)
        #expect(front["MacAddress"] as? String == "02:42:ac:14:00:0a")
        #expect((front["DriverOpts"] as? [String: String])?["com.example.mode"] == "fast")
        #expect(back["Aliases"] == nil)
    }

    @Test func parsesRequestWithQueryAndBody() throws {
        let raw = "POST /v1.47/containers/create?name=web HTTP/1.1\r\nContent-Length: 7\r\n\r\n{\"a\":1}"
        let request = try #require(try HTTPCodec.parseRequest(Data(raw.utf8)))
        #expect(request.method == "POST")
        #expect(request.path == "/v1.47/containers/create")
        #expect(request.query["name"] == "web")
        #expect(String(data: request.body, encoding: .utf8) == "{\"a\":1}")
    }

    @Test func parsesQueryPlusAsSpaceAndPreservesEncodedPlus() throws {
        let raw = "GET /containers/c1/archive?path=%2Fdata%2Ftwo+words%2Ba.txt&filters=%7B%22label%22%3A%5B%22team+platform%22%5D%7D HTTP/1.1\r\n\r\n"
        let request = try #require(try HTTPCodec.parseRequest(Data(raw.utf8)))
        #expect(request.query["path"] == "/data/two words+a.txt")
        #expect(request.query["filters"] == #"{"label":["team platform"]}"#)
    }

    @Test func preservesRepeatedQueryValuesForDockerAPIs() throws {
        let raw = "GET /images/get?names=alpine&names=busybox%3Alatest&names= HTTP/1.1\r\n\r\n"
        let request = try #require(try HTTPCodec.parseRequest(Data(raw.utf8)))
        #expect(request.queryItems.map(\.key) == ["names", "names", "names"])
        #expect(request.queryValues(for: "names") == ["alpine", "busybox:latest", ""])
        #expect(DockerShim.imageSaveReferences(from: request.queryValues(for: "names")) == [
            "alpine",
            "busybox:latest",
        ])
    }

    @Test func chunkedStreamDecoderStripsFraming() {
        let decoder = ChunkedStreamDecoder()
        #expect(String(data: decoder.feed(Data("5\r\nhello\r\n".utf8)), encoding: .utf8) == "hello")
        #expect(String(data: decoder.feed(Data("6\r\n world\r\n0\r\n\r\n".utf8)), encoding: .utf8) == " world")
    }

    @Test func chunkedStreamDecoderWaitsForFullChunk() {
        let decoder = ChunkedStreamDecoder()
        #expect(decoder.feed(Data("5\r\nhel".utf8)).isEmpty) // partial chunk -> nothing yet
        #expect(String(data: decoder.feed(Data("lo\r\n".utf8)), encoding: .utf8) == "hello")
    }

    @Test func parsesChunkedRequestBody() throws {
        let raw = "PUT /containers/x/archive?path=/tmp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n4\r\ntar1\r\n4\r\ntar2\r\n0\r\n\r\n"
        let request = try #require(try HTTPCodec.parseRequest(Data(raw.utf8)))
        #expect(request.method == "PUT")
        #expect(String(data: request.body, encoding: .utf8) == "tar1tar2")
    }

    @Test func serializeChunkedRequestOmitsContentLength() {
        let request = HTTPRequest(method: "POST", path: "/images/load", headers: [
            (name: "Content-Type", value: "application/x-tar"),
            (name: "Content-Length", value: "999"),
            (name: "Transfer-Encoding", value: "identity"),
        ])
        let text = String(decoding: HTTPCodec.serializeChunkedRequest(request), as: UTF8.self)
        #expect(text.hasPrefix("POST /images/load HTTP/1.1\r\n"))
        #expect(text.contains("Host: dory\r\n"))
        #expect(text.contains("Content-Type: application/x-tar\r\n"))
        #expect(text.contains("Transfer-Encoding: chunked\r\n"))
        #expect(!text.contains("Content-Length:"))
        #expect(!text.contains("Transfer-Encoding: identity"))
        #expect(text.hasSuffix("\r\n\r\n"))
    }

    @Test func chunkedStreamDecoderRejectsOversizedChunkSize() {
        // A near-Int.max chunk size used to trap on `dataStart + size + 2`; it must now be rejected
        // cleanly without crashing or allocating.
        let decoder = ChunkedStreamDecoder()
        #expect(decoder.feed(Data("7ffffffffffffffe\r\nx".utf8)).isEmpty)
        let huge = String(format: "%x", HTTPCodec.maxChunkBytes + 1)
        #expect(ChunkedStreamDecoder().feed(Data("\(huge)\r\nx".utf8)).isEmpty)
    }

    @Test func decodeChunkedRejectsOversizedChunkSize() {
        // The buffering decoder must surface a malformed-chunk error rather than trap on overflow.
        #expect(throws: HTTPError.malformedChunk) {
            _ = try HTTPCodec.decodeChunked(Data("7ffffffffffffffe\r\nx".utf8))
        }
    }

    @Test func parseResponseRejectsNegativeContentLength() throws {
        // A negative Content-Length used to trap on an index offset; it must fall through to
        // connection-close delimiting instead.
        let raw = "HTTP/1.1 200 OK\r\nContent-Length: -5\r\n\r\nbody"
        let response = try #require(try HTTPCodec.parseResponse(Data(raw.utf8), connectionClosed: true))
        #expect(response.statusCode == 200)
        #expect(String(data: response.body, encoding: .utf8) == "body")
    }

    @Test func durationParsingEdgeCases() {
        #expect(ComposeParser.duration(nil) == nil)
        #expect(ComposeParser.duration("0s") == 0)
        #expect(ComposeParser.duration("1h30m") == 5400)
    }

    @Test func interpolatesNestedYAMLValues() {
        let value = YAMLValue.mapping([
            "url": .string("http://${HOST}:${PORT}"),
            "list": .sequence([.string("$ENV-a"), .string("plain")]),
        ])
        let out = ComposeInterpolation.interpolate(value, variables: ["HOST": "db", "PORT": "5432", "ENV": "prod"])
        #expect(out["url"]?.stringValue == "http://db:5432")
        #expect(out["list"]?.sequenceValue?.first?.stringValue == "prod-a")
    }

    @MainActor
    @Test func eventBusBroadcastsToConsumers() async {
        let bus = EventBus()
        let stream = bus.stream()
        bus.publish([DoryEvent(containerID: "a", name: "a", image: "img", action: .start,
                               attributes: ["name": "a", "image": "img"])])
        var received: DoryEvent?
        for await event in stream { received = event; break }
        #expect(received?.action == .start)
        #expect(received?.containerID == "a")
    }
}
