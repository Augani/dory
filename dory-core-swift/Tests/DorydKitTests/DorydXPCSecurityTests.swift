import DorydKit
import XCTest

final class DorydXPCSecurityTests: XCTestCase {
    func testProductionDaemonAcceptsOnlySameUIDBeforeCodeRequirement() {
        XCTAssertTrue(DorydXPCSecurity.acceptsConnection(
            clientUID: 501,
            daemonUID: 501,
            daemonTeamID: DorydXPCSecurity.productionTeamID
        ))
        XCTAssertFalse(DorydXPCSecurity.acceptsConnection(
            clientUID: 502,
            daemonUID: 501,
            daemonTeamID: DorydXPCSecurity.productionTeamID
        ))
    }

    func testUnexpectedSignedDaemonFailsClosed() {
        XCTAssertFalse(DorydXPCSecurity.acceptsConnection(
            clientUID: 501,
            daemonUID: 501,
            daemonTeamID: "OTHERTEAM"
        ))
    }

    func testAdHocDevelopmentDaemonRemainsSameUIDOnly() {
        XCTAssertTrue(DorydXPCSecurity.acceptsConnection(
            clientUID: 501,
            daemonUID: 501,
            daemonTeamID: nil
        ))
        XCTAssertFalse(DorydXPCSecurity.acceptsConnection(
            clientUID: 0,
            daemonUID: 501,
            daemonTeamID: nil
        ))
    }

    func testRequirementsPinProductionIdentifiersAndTeam() {
        XCTAssertTrue(DorydXPCSecurity.productionClientRequirement.contains("864H636QW4"))
        XCTAssertTrue(DorydXPCSecurity.productionClientRequirement.contains("com.pythonxi.Dory"))
        XCTAssertTrue(DorydXPCSecurity.productionClientRequirement.contains("dorydctl"))
        XCTAssertTrue(DorydXPCSecurity.productionDaemonRequirement.contains("identifier \"doryd\""))
    }

    func testProductionDaemonIdentityRejectsWrongTeam() {
        // A00.3: a binary signed by a different team is not the production daemon.
        XCTAssertFalse(DorydXPCSecurity.isProductionDaemonIdentity(
            teamIdentifier: "WRONGTEAM",
            signingIdentifier: "doryd"
        ))
        XCTAssertFalse(DorydXPCSecurity.isProductionDaemonIdentity(
            teamIdentifier: "",
            signingIdentifier: "doryd"
        ))
    }

    func testProductionDaemonIdentityRejectsWrongSigningIdentifier() {
        // A00.3: a same-team binary with a different signing identifier is not doryd.
        XCTAssertFalse(DorydXPCSecurity.isProductionDaemonIdentity(
            teamIdentifier: DorydXPCSecurity.productionTeamID,
            signingIdentifier: "Dory"
        ))
        XCTAssertFalse(DorydXPCSecurity.isProductionDaemonIdentity(
            teamIdentifier: DorydXPCSecurity.productionTeamID,
            signingIdentifier: "dorydctl"
        ))
        XCTAssertFalse(DorydXPCSecurity.isProductionDaemonIdentity(
            teamIdentifier: DorydXPCSecurity.productionTeamID,
            signingIdentifier: "dory-vmm"
        ))
    }

    func testProductionDaemonIdentityRejectsUnsignedPeer() {
        // A00.3: an unsigned or missing identity cannot satisfy the production requirement.
        XCTAssertFalse(DorydXPCSecurity.isProductionDaemonIdentity(
            teamIdentifier: nil,
            signingIdentifier: "doryd"
        ))
        XCTAssertFalse(DorydXPCSecurity.isProductionDaemonIdentity(
            teamIdentifier: DorydXPCSecurity.productionTeamID,
            signingIdentifier: nil
        ))
    }

}
