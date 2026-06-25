import Testing
@testable import Dory

struct PublishedPortParsingTests {
    @Test func parsesSinglePort() {
        let ports = parsePublishedPorts("0.0.0.0:8080->80/tcp")
        #expect(ports == [PublishedPort(hostPort: 8080, containerPort: 80, proto: "tcp")])
    }

    @Test func dedupesIPv4AndIPv6() {
        let ports = parsePublishedPorts("0.0.0.0:8080->80/tcp, :::8080->80/tcp")
        #expect(ports.count == 1)
        #expect(ports.first?.hostPort == 8080)
    }

    @Test func keepsDistinctHostPortsSorted() {
        let ports = parsePublishedPorts("0.0.0.0:5432->5432/tcp, 0.0.0.0:8080->80/tcp")
        #expect(ports.map(\.hostPort) == [5432, 8080])
    }

    @Test func ignoresExposedOnlyAndEmpty() {
        #expect(parsePublishedPorts("80/tcp").isEmpty)
        #expect(parsePublishedPorts("").isEmpty)
    }

    @Test func parsesUdp() {
        let ports = parsePublishedPorts("0.0.0.0:53->53/udp")
        #expect(ports.first?.proto == "udp")
    }

    @Test func parsesLegacyArrowDisplay() {
        let ports = parsePublishedPorts("8080→80, 5353→53/udp")
        #expect(ports == [
            PublishedPort(hostPort: 5353, containerPort: 53, proto: "udp"),
            PublishedPort(hostPort: 8080, containerPort: 80, proto: "tcp"),
        ])
    }
}
