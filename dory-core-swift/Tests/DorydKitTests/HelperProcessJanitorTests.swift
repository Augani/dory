@testable import DorydKit
import XCTest

final class HelperProcessJanitorTests: XCTestCase {
    func testFindsExactStateDirectoryForHelper() {
        let output = """
          101 /opt/dory/dory-hv engine --state-dir /Users/me/.dory/hv --kernel Image
          102 /opt/dory/dory-hv engine --state-dir /Users/me/.dory/other --kernel Image
          103 /opt/dory/dory-vmm --state-dir /Users/me/.dory/machines/dev
        """

        XCTAssertEqual(
            HelperProcessJanitor.staleHelperPIDs(
                executablePath: "/opt/dory/dory-hv",
                stateDirectory: "/Users/me/.dory/hv",
                psOutput: output,
                currentPID: 999
            ),
            [101]
        )
    }

    func testFindsDescendantStateDirectoriesForMachines() {
        let output = """
          201 /opt/dory/dory-vmm --machine-id dev --state-dir /Users/me/.dory/machines/dev
          202 /opt/dory/dory-vmm --machine-id ci --state-dir=/Users/me/.dory/machines/ci
          203 /opt/dory/dory-vmm --machine-id other --state-dir /Users/me/.other/machines/other
        """

        XCTAssertEqual(
            HelperProcessJanitor.staleHelperPIDs(
                executablePath: "/opt/dory/dory-vmm",
                stateDirectory: "/Users/me/.dory/machines",
                includeDescendants: true,
                psOutput: output,
                currentPID: 999
            ),
            [201, 202]
        )
    }

    func testIgnoresCurrentProcessAndMissingStateDirectory() {
        let output = """
          301 /opt/dory/dory-hv engine --state-dir /Users/me/.dory/hv
          302 /opt/dory/dory-hv engine --kernel Image
        """

        XCTAssertEqual(
            HelperProcessJanitor.staleHelperPIDs(
                executablePath: "/opt/dory/dory-hv",
                stateDirectory: "/Users/me/.dory/hv",
                psOutput: output,
                currentPID: 301
            ),
            []
        )
    }
}
