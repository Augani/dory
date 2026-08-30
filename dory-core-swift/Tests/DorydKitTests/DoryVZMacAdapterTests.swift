import DoryVZMacCore
@testable import DoryVMMKit
import Foundation
import XCTest

final class DoryVZMacAdapterTests: XCTestCase {
    func testProjectsEveryDurableMachineStateTruthfully() {
        let cases: [(DoryVZMacMachineInstallationState, DoryVZMacAdapterState)] = [
            (.prepared, .prepared),
            (.installing, .installing),
            (.installFailed, .installFailed),
            (.stopped, .stopped),
            (.suspending, .suspending),
            (.suspended, .suspended),
            (.restoring, .restoring),
        ]

        for (durable, projected) in cases {
            XCTAssertEqual(DoryVZMacAdapter.initialState(for: durable), projected)
        }
    }

    func testConfigurationStandardizesAllLocalArtifactPaths() {
        let configuration = DoryVZMacAdapterConfiguration(
            machineBundleURL: URL(fileURLWithPath: "/tmp/machines/../mac.doryvm"),
            guestToolsURL: URL(fileURLWithPath: "/tmp/tools/../guest-tools"),
            usbDiskURL: URL(fileURLWithPath: "/tmp/disks/../removable.img"),
            usbDiskReadOnly: false
        )

        XCTAssertEqual(configuration.machineBundleURL.path, "/tmp/mac.doryvm")
        XCTAssertEqual(configuration.guestToolsURL?.path, "/tmp/guest-tools")
        XCTAssertEqual(configuration.usbDiskURL?.path, "/tmp/removable.img")
        XCTAssertFalse(configuration.usbDiskReadOnly)
        XCTAssertEqual(DoryVZMacAdapter.maximumGuestDisplayCount, 1)
    }

    func testInvalidStateErrorNamesExpectedAndActualStates() {
        let error = DoryVZMacAdapterError.invalidState(
            expected: [.stopped, .suspended],
            actual: .running
        )

        XCTAssertEqual(
            error.description,
            "VZMac is running; expected stopped or suspended"
        )
    }
}
