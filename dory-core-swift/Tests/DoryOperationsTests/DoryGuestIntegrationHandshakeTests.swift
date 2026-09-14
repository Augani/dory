import Foundation
import Testing
@testable import DoryOperations

@Suite("Guest integration handshake admission")
struct DoryGuestIntegrationHandshakeTests {
    private let operationID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let nonce = "0123456789abcdef0123456789abcdef"

    @Test("canonical peer is admitted only for its exact machine operation and grants")
    func admitsBoundPeer() {
        let issues = expectation().admit(handshake())
        #expect(issues.isEmpty)
    }

    @Test("stale operation generations and replayed challenges are rejected")
    func rejectsStaleGenerationAndReplay() {
        var staleGeneration = handshake()
        staleGeneration.lifecycleGeneration = 6
        #expect(expectation().admit(staleGeneration).contains {
            $0.code == .generationMismatch
        })

        var replay = handshake()
        replay.nonce = String(repeating: "a", count: 32)
        #expect(expectation().admit(replay).contains { $0.code == .nonceMismatch })
    }

    @Test("guest cannot request a permission not explicitly granted by the operation")
    func rejectsPermissionEscalation() {
        var escalating = handshake()
        escalating.requestedPermissions.append(.fileTransferPull)
        escalating.requestedPermissions.sort { $0.rawValue < $1.rawValue }

        #expect(expectation().admit(escalating).contains { $0.code == .permissionDenied })
    }

    @Test("malformed or ambiguous peers fail before host comparison")
    func rejectsMalformedPeer() {
        var malformed = handshake()
        malformed.capabilities.append(.init(id: "clock-sync", version: 0))
        malformed.requestedPermissions.append(.clipboardWrite)
        malformed.nonce = "not-a-nonce"

        let codes = Set(expectation().admit(malformed).map(\.code))
        #expect(codes.contains(.invalidCapabilities))
        #expect(codes.contains(.invalidPermissions))
        #expect(codes.contains(.invalidNonce))
    }

    private func expectation() -> DoryGuestIntegrationHandshakeExpectation {
        .init(
            machineID: "mac-guest-01",
            operationID: operationID,
            lifecycleGeneration: 7,
            guest: .init(family: .macOS, architecture: .arm64),
            protocolVersion: 1,
            nonce: nonce,
            grantedPermissions: [.clockSynchronization, .clipboardRead]
        )
    }

    private func handshake() -> DoryGuestIntegrationHandshake {
        .init(
            machineID: "mac-guest-01",
            operationID: operationID,
            lifecycleGeneration: 7,
            guest: .init(family: .macOS, architecture: .arm64),
            toolsBuild: "dory-guest-tools/1.0.0",
            protocolVersion: 1,
            capabilities: [
                .init(id: "clock-sync", version: 1),
                .init(id: "readiness", version: 1),
            ],
            requestedPermissions: [.clipboardRead, .clockSynchronization],
            nonce: nonce
        )
    }
}
