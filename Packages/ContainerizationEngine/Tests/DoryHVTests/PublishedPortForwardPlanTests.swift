import Testing
@testable import DoryHV
import DoryCore
import DoryOperations

@Suite struct PublishedPortForwardPlanTests {
    @Test func parsesDockerTransportTypes() {
        #expect(PublishedPortBinding(dockerType: "tcp", publicPort: 8080) == PublishedPortBinding(protocol: .tcp, port: 8080))
        #expect(PublishedPortBinding(dockerType: "tcp6", publicPort: 8080) == PublishedPortBinding(protocol: .tcp, port: 8080))
        #expect(PublishedPortBinding(dockerType: "udp", publicPort: 5353) == PublishedPortBinding(protocol: .udp, port: 5353))
        #expect(PublishedPortBinding(dockerType: "udp6", publicPort: 5353) == PublishedPortBinding(protocol: .udp, port: 5353))
        #expect(PublishedPortBinding(dockerType: "sctp", publicPort: 8080) == nil)
        #expect(PublishedPortBinding(dockerType: "tcp", publicPort: 0) == nil)
    }

    @Test func resolvedWorkspaceForwardsPreserveExactPortsAndExposure() throws {
        let forwards = try #require(PublishedPortForwardPlan.resolvedForwards([
            DoryVMPortForward(id: "web", hostPort: 8_080, guestPort: 80),
            DoryVMPortForward(
                id: "dns",
                transport: .udp,
                hostPort: 5_353,
                guestPort: 53,
                exposure: .lan
            ),
        ], guestIP: "192.168.127.2"))
        #expect(forwards == [
            PublishedPortForward(
                protocol: .tcp,
                publishedPort: 8_080,
                localHost: "127.0.0.1",
                localPort: 8_080,
                guestHost: "192.168.127.2",
                guestPort: 80
            ),
            PublishedPortForward(
                protocol: .udp,
                publishedPort: 5_353,
                localHost: "0.0.0.0",
                localPort: 5_353,
                guestHost: "192.168.127.2",
                guestPort: 53
            ),
        ])
        #expect(PublishedPortForwardPlan.resolvedForwards([
            DoryVMPortForward(id: "privileged", hostPort: 443, guestPort: 443),
        ], guestIP: "192.168.127.2") == nil)
        #expect(PublishedPortForwardPlan.resolvedForwards([
            DoryVMPortForward(id: "one", hostPort: 8_080, guestPort: 80),
            DoryVMPortForward(id: "two", hostPort: 8_080, guestPort: 81),
        ], guestIP: "192.168.127.2") == nil)
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

    @Test func lanPolicyNeverWidensExplicitLoopbackBindings() {
        let forwards = PublishedPortForwardPlan.forwards(
            for: [PublishedPortBinding(protocol: .tcp, port: 8080, hostIP: "127.0.0.1")],
            publishHost: "0.0.0.0",
            guestIP: "192.168.127.2"
        )

        #expect(forwards == [
            forward(.tcp, host: "127.0.0.1", localPort: 8080, guestPort: 8080),
        ])
    }

    @Test func localhostPolicyClampsDockerWildcardAndInterfaceBindings() {
        let bindings: Set<PublishedPortBinding> = [
            PublishedPortBinding(protocol: .tcp, port: 8080, hostIP: "0.0.0.0"),
            PublishedPortBinding(protocol: .tcp, port: 9090, hostIP: "192.168.1.25"),
        ]
        let forwards = PublishedPortForwardPlan.forwards(
            for: bindings,
            publishHost: "127.0.0.1",
            guestIP: "192.168.127.2"
        )

        #expect(forwards == [
            forward(.tcp, host: "127.0.0.1", localPort: 8080, guestPort: 8080),
            forward(.tcp, host: "[::1]", localPort: 8080, guestPort: 8080),
            forward(.tcp, host: "127.0.0.1", localPort: 9090, guestPort: 9090),
            forward(.tcp, host: "[::1]", localPort: 9090, guestPort: 9090),
        ])
    }

    @Test func lanPolicyHonorsAnInterfaceSpecificAddress() {
        let forwards = PublishedPortForwardPlan.forwards(
            for: [PublishedPortBinding(protocol: .udp, port: 5353, hostIP: "192.168.1.25")],
            publishHost: "0.0.0.0",
            guestIP: "192.168.127.2"
        )

        #expect(forwards == [
            forward(.udp, host: "192.168.1.25", localPort: 5353, guestPort: 5353),
        ])
    }

    @Test func malformedRequestedAddressFailsClosedToLoopback() {
        #expect(PublishedPortForwardPlan.localHosts(for: "0.0.0.0", requestedHost: "all.example") == ["127.0.0.1", "[::1]"])
        #expect(PublishedPortForwardPlan.localHosts(for: "0.0.0.0", requestedHost: "999.1.1.1") == ["127.0.0.1", "[::1]"])
    }

    @Test func dataplaneLoopbackIntentSurvivesDockerWildcardNormalization() {
        let label = #"{"8080/tcp":{"49100":"ipv4"},"5353/udp":{"":"ipv6"},"9000/tcp":"localhost"}"#
        let intents = PublishedPortForwardPlan.loopbackIntents(fromLabel: label)

        #expect(PublishedPortForwardPlan.requestedHost(
            dockerHost: "0.0.0.0", containerPort: 8080, publicPort: 49100, dockerType: "tcp", loopbackIntents: intents
        ) == "127.0.0.1")
        #expect(PublishedPortForwardPlan.requestedHost(
            dockerHost: "0.0.0.0", containerPort: 5353, publicPort: 49101, dockerType: "udp", loopbackIntents: intents
        ) == "::1")
        #expect(PublishedPortForwardPlan.requestedHost(
            dockerHost: "0.0.0.0", containerPort: 9000, publicPort: 49102, dockerType: "tcp", loopbackIntents: intents
        ) == "localhost")
        #expect(PublishedPortForwardPlan.requestedHost(
            dockerHost: "0.0.0.0", containerPort: 443, publicPort: 49103, dockerType: "tcp", loopbackIntents: intents
        ) == "0.0.0.0")
    }

    @Test func malformedDataplaneIntentIsIgnored() {
        let label = #"{"0/tcp":{"80":"ipv4"},"8080/sctp":{"80":"ipv4"},"9090/tcp":{"80":"wide"},"bad":{"80":"ipv6"}}"#
        #expect(PublishedPortForwardPlan.loopbackIntents(fromLabel: label).isEmpty)
        #expect(PublishedPortForwardPlan.loopbackIntents(fromLabel: "not-json").isEmpty)
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
