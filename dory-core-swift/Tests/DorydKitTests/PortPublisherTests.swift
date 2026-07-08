import DoryCore
@testable import DorydKit
import XCTest

final class PortPublisherTests: XCTestCase {
    func testReconcilePublishesSnapshotDiffs() {
        let publisher = PortPublisher()

        var diff = publisher.reconcile(DoryPortsSnapshot(
            ports: [
                DoryListenPort(protocol: "tcp", port: 8080),
                DoryListenPort(protocol: "udp", port: 5353),
            ],
            added: [],
            removed: []
        ))
        XCTAssertEqual(diff.added, [
            DoryListenPort(protocol: "udp", port: 5353),
            DoryListenPort(protocol: "tcp", port: 8080),
        ])
        XCTAssertEqual(diff.removed, [])

        diff = publisher.reconcile(DoryPortsSnapshot(
            ports: [
                DoryListenPort(protocol: "udp", port: 5353),
                DoryListenPort(protocol: "tcp", port: 8443),
            ],
            added: [],
            removed: []
        ))
        XCTAssertEqual(diff.added, [DoryListenPort(protocol: "tcp", port: 8443)])
        XCTAssertEqual(diff.removed, [DoryListenPort(protocol: "tcp", port: 8080)])
        XCTAssertEqual(publisher.current, [
            DoryListenPort(protocol: "udp", port: 5353),
            DoryListenPort(protocol: "tcp", port: 8443),
        ])
    }
}
