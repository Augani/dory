import Testing
import Foundation
@testable import Dory

struct ShimContainerMappingTests {
    @Test func summaryPreservesComposeLabels() throws {
        let container = Container(id: "abc", name: "demo-web-1", image: "nginx:alpine", status: .running,
                                  cpuPercent: 0, memoryDisplay: "0", memoryLimitDisplay: "—", memoryFraction: 0,
                                  ports: "8080→80", uptime: "5s", created: "now", ipAddress: "—", domain: "",
                                  command: "nginx", restartPolicy: "no", createdEpoch: 42,
                                  labels: ["com.docker.compose.project": "demo", "com.docker.compose.service": "web"])

        let summary = try #require(ShimContainerMapping.summary(container, all: false))
        #expect(summary.State == "running")
        #expect(summary.Status == "Up 5s")
        #expect(summary.Labels["com.docker.compose.project"] == "demo")
        #expect(summary.Ports.first?.PublicPort == 8080)
    }

    @Test func stoppedContainerIsHiddenUnlessAllIsRequested() {
        let container = Container(id: "abc", name: "worker", image: "busybox", status: .stopped,
                                  cpuPercent: 0, memoryDisplay: "0", memoryLimitDisplay: "—", memoryFraction: 0,
                                  ports: "—", uptime: "—", created: "now", ipAddress: "—", domain: "",
                                  command: "true", restartPolicy: "no")
        #expect(ShimContainerMapping.summary(container, all: false) == nil)
        #expect(ShimContainerMapping.summary(container, all: true)?.State == "exited")
    }

    @Test func portsPreserveDockerStyleProtocolAndExposedOnlyPorts() {
        let ports = ShimContainerMapping.ports("127.0.0.1:5353->53/udp, 0.0.0.0:8443->443/tcp, 9090/tcp")
        #expect(ports.count == 3)
        #expect(ports[0].PrivatePort == 53)
        #expect(ports[0].PublicPort == 5353)
        #expect(ports[0].portType == "udp")
        #expect(ports[1].PrivatePort == 443)
        #expect(ports[1].PublicPort == 8443)
        #expect(ports[1].portType == "tcp")
        #expect(ports[2].PrivatePort == 9090)
        #expect(ports[2].PublicPort == nil)
        #expect(ports[2].portType == "tcp")
    }

    @Test func waitCodeFallsBackOnlyWhenUnknown() {
        #expect(ContainerWait.statusCode(0) == 0)
        #expect(ContainerWait.statusCode(137) == 137)
        #expect(ContainerWait.statusCode(nil) == 0)
    }

    @Test func pullProgressUsesJsonLines() throws {
        let lines = PullProgress.lines(repository: "alpine", tag: "latest", reference: "alpine:latest")
        #expect(lines.count == 3)
        let decoded = try lines.map { try JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        #expect(decoded[0]?["status"] as? String == "Pulling from alpine")
        #expect(decoded[0]?["id"] as? String == "latest")
        #expect(decoded[2]?["status"] as? String == "Pulled alpine:latest")
    }

    @Test func pullProgressErrorUsesDockerStreamErrorShape() throws {
        let line = PullProgress.error(message: "pull access denied")
        let decoded = try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])
        let detail = try #require(decoded["errorDetail"] as? [String: Any])
        #expect(detail["message"] as? String == "pull access denied")
        #expect(decoded["error"] as? String == "pull access denied")
        #expect(String(decoding: line, as: UTF8.self).hasSuffix("\n"))
    }

    @Test func imageReferenceSplitPreservesDigest() {
        #expect(PullReference.resolve(fromImage: "alpine@sha256:abc", tagQuery: nil).reference == "alpine@sha256:abc")
        #expect(PullReference.resolve(fromImage: "alpine:3.22", tagQuery: "").reference == "alpine:3.22")
        #expect(PullReference.resolve(fromImage: "alpine", tagQuery: "sha256:abc").reference == "alpine@sha256:abc")
        #expect(PullReference.resolve(fromImage: "alpine:3.22", tagQuery: "latest").reference == "alpine:latest")
        #expect(PullReference.resolve(fromImage: "localhost:5000/app:old", tagQuery: "new").reference == "localhost:5000/app:new")
    }

    @Test func dockerListFiltersMatchLabelsAndStatus() {
        let running = Container(id: "abc123", name: "demo-web-1", image: "nginx:alpine", status: .running,
                                cpuPercent: 0, memoryDisplay: "0", memoryLimitDisplay: "—", memoryFraction: 0,
                                ports: "—", uptime: "1s", created: "now", ipAddress: "—", domain: "",
                                command: "nginx", restartPolicy: "no",
                                labels: ["com.docker.compose.project": "demo", "com.docker.compose.service": "web"])
        let stopped = Container(id: "def456", name: "demo-worker-1", image: "busybox", status: .stopped,
                                cpuPercent: 0, memoryDisplay: "0", memoryLimitDisplay: "—", memoryFraction: 0,
                                ports: "—", uptime: "—", created: "now", ipAddress: "—", domain: "",
                                command: "true", restartPolicy: "no",
                                labels: ["com.docker.compose.project": "demo"])

        let filters = DockerListFilters.parse(#"{"label":["com.docker.compose.project=demo","com.docker.compose.service=web"],"status":["running"],"ancestor":["nginx"]}"#)
        #expect(DockerListFilters.matches(running, filters: filters))
        #expect(!DockerListFilters.matches(stopped, filters: filters))
    }
}
