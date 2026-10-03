import DorydKit
import Foundation
import XCTest

final class DoryVZMacMetalProbeLaunchRequestTests: XCTestCase {
  func testRejectsRelativeAliasedAndSplitOutputPaths() {
    XCTAssertThrowsError(try DoryVZMacMetalProbeLaunchRequest(
      challengePath: "challenge.json", resultPath: "/tmp/result.json"
    ))
    XCTAssertThrowsError(try DoryVZMacMetalProbeLaunchRequest(
      challengePath: "/tmp/challenge.json", resultPath: "/tmp/challenge.json"
    ))
    XCTAssertThrowsError(try DoryVZMacMetalProbeLaunchRequest(
      challengePath: "/tmp/challenge.json", resultPath: "/var/tmp/result.json"
    ))
    XCTAssertThrowsError(try DoryVZMacMetalProbeLaunchRequest(
      challengePath: "/tmp/../tmp/challenge.json", resultPath: "/tmp/result.json"
    ))
  }

  func testRejectsNonMacGuestBeforeReadingAnyChallenge() throws {
    let request = try DoryVZMacMetalProbeLaunchRequest(
      challengePath: "/tmp/dory-metal-challenge.json",
      resultPath: "/tmp/dory-metal-result.json"
    )
    let linux = DoryMachineConfiguration(
      id: "linux", kernelPath: "/tmp/kernel", rootfsPath: "/tmp/disk"
    )
    XCTAssertThrowsError(try request.validate(machine: linux, operationID: UUID())) { error in
      XCTAssertEqual(error as? DoryVZMacMetalProbeLaunchError, .requiresMacGuest)
    }
  }
}
