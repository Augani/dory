import Testing
@testable import DoryHV

@Suite struct PublishedPortForwardPlanTests {
    @Test func parsesDockerTransportTypes() {
        #expect(PublishedPortBinding(dockerType: "tcp", publicPort: 8080) == PublishedPortBinding(protocol: .tcp, port: 8080))
        #expect(PublishedPortBinding(dockerType: "tcp6", publicPort: 8080) == PublishedPortBinding(protocol: .tcp, port: 8080))
        #expect(PublishedPortBinding(dockerType: "udp", publicPort: 5353) == PublishedPortBinding(protocol: .udp, port: 5353))
        #expect(PublishedPortBinding(dockerType: "udp6", publicPort: 5353) == PublishedPortBinding(protocol: .udp, port: 5353))
        #expect(PublishedPortBinding(dockerType: "sctp", publicPort: 8080) == nil)
        #expect(PublishedPortBinding(dockerType: "tcp", publicPort: 0) == nil)
    }

    @Test func loopbackPlanIncludesIPv4AndIPv6ForTCPAndUDP() {
        let forwards = PublishedPortForwardPlan.forwards(
            for: [
                PublishedPortBinding(protocol: .tcp, port: 8080),
                PublishedPortBinding(protocol: .udp, port: 5353),
            ],
            publishHost: "127.0.0.1",
            guestIP: "192.168.127.2"
        )

        #expect(forwards == [
            forward(.tcp, host: "127.0.0.1", localPort: 8080, guestPort: 8080),
            forward(.tcp, host: "[::1]", localPort: 8080, guestPort: 8080),
            forward(.udp, host: "127.0.0.1", localPort: 5353, guestPort: 5353),
            forward(.udp, host: "[::1]", localPort: 5353, guestPort: 5353),
        ])
    }

    @Test func lowPublishedPortsUseHighLocalPortsButOriginalGuestPorts() {
        let forwards = PublishedPortForwardPlan.forwards(
            for: [PublishedPortBinding(protocol: .tcp, port: 80)],
            publishHost: "127.0.0.1",
            guestIP: "192.168.127.2"
        )

        #expect(forwards == [
            forward(.tcp, host: "127.0.0.1", localPort: 60_080, guestPort: 80),
            forward(.tcp, host: "[::1]", localPort: 60_080, guestPort: 80),
        ])
    }

    @Test func lanVisiblePlanDoesNotEnableIPv6LanWildcard() {
        let hosts = PublishedPortForwardPlan.localHosts(for: "0.0.0.0")

        #expect(hosts == ["0.0.0.0", "[::1]"])
    }

    private func forward(
        _ proto: PublishedPortForwardProtocol,
        host: String,
        localPort: Int,
        guestPort: Int
    ) -> PublishedPortForward {
        PublishedPortForward(
            protocol: proto,
            publishedPort: guestPort,
            localHost: host,
            localPort: localPort,
            guestHost: "192.168.127.2",
            guestPort: guestPort
        )
    }
}
