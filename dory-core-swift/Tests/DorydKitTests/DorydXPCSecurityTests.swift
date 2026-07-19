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
}
