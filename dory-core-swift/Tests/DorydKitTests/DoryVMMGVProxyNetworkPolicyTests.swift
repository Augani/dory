import DoryCore
import DoryOperations
import Testing
@testable import DoryVMMKit

@Suite struct DoryVMMGVProxyNetworkPolicyTests {
    @Test func isolatedModeAllowsOnlyLiteralLoopbackBindings() throws {
        for host in ["127.0.0.1", "127.0.0.2", "[::1]", "[0:0:0:0:0:0:0:1]"] {
            try DoryVMMGVProxyNetwork.validateAttachmentPolicy(
                .isolated, sourcePreservingLAN: false, resolvedPortForwards: [forward(host)]
            )
        }
    }

    @Test func isolatedModeRejectsEveryLANOrAmbiguousBinding() {
        for host in [
            "0.0.0.0", "[::]", "192.168.1.10", "[fd00::1]", "localhost",
            "::1", "[::1%lo0]", "[::ffff:127.0.0.1]", "127.0.0.1.example", "127.0.0.1\0"
        ] {
            #expect(throws: DoryVZMachineError.self, "isolated mode accepted binding: \(String(reflecting: host))") {
                try DoryVMMGVProxyNetwork.validateAttachmentPolicy(
                    .isolated, sourcePreservingLAN: false, resolvedPortForwards: [forward(host)]
                )
            }
        }
    }

    @Test func isolatedModeRejectsLANBridgeEvenWithoutForwardedPorts() {
        #expect(throws: DoryVZMachineError.self) {
            try DoryVMMGVProxyNetwork.validateAttachmentPolicy(
                .isolated, sourcePreservingLAN: true, resolvedPortForwards: []
            )
        }
    }

    @Test func sharedNATRetainsExplicitLANPolicyAndUnsupportedAttachmentsFailClosed() throws {
        try DoryVMMGVProxyNetwork.validateAttachmentPolicy(
            .sharedNAT, sourcePreservingLAN: true, resolvedPortForwards: [forward("0.0.0.0")]
        )
        for attachment in [DoryVirtualMachineNetworkAttachmentMode.disconnected, .bridged] {
            #expect(throws: DoryVZMachineError.self) {
                try DoryVMMGVProxyNetwork.validateAttachmentPolicy(
                    attachment, sourcePreservingLAN: false, resolvedPortForwards: []
                )
            }
        }
    }

    private func forward(_ host: String) -> PublishedPortForward {
        .init(
            protocol: .tcp, publishedPort: 8_080, localHost: host, localPort: 8_080,
            guestHost: "192.168.127.2", guestPort: 80
        )
    }
}
