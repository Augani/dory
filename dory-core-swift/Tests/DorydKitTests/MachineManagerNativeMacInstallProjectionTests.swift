import DoryOperations
import DoryVZMacCore
import XCTest
@testable import DorydKit

final class MachineManagerNativeMacInstallProjectionTests: XCTestCase {
    private let restore = DoryVMResolverReference(namespace: "macos-restore", identifier: "owned-restore")
    private let system = DoryVMResolverReference(namespace: "macos-machine", identifier: "owned-system")
    private let managedRAM = "/owned-state/mac/saved-state/state.vzvmsave"

    func testInterruptedInstallationKeepsTheExactInstallerBootAuthority() throws {
        let prepared = try MachineManager.nativeMacOSBootConfiguration(
            installationState: .prepared, restoreReference: restore, systemReference: system)
        for state in [DoryVZMacMachineInstallationState.prepared, .installFailed, .installing] {
            let projected = try MachineManager.nativeMacOSBootConfiguration(
                installationState: state, restoreReference: restore, systemReference: system)
            XCTAssertEqual(projected, prepared)
            XCTAssertEqual(projected.phase, .install)
            XCTAssertEqual(projected.devices.map(\.artifact), [restore])
            XCTAssertEqual(try MachineManager.nativeMacOSLaunchOperation(
                installationState: state, restoreStatePath: nil, managedStatePath: managedRAM), "install")
            XCTAssertThrowsError(try MachineManager.nativeMacOSLaunchOperation(
                installationState: state, restoreStatePath: managedRAM, managedStatePath: managedRAM))
        }
    }

    func testInstalledColdBootUsesSystemDiskAndResumeRequiresExactOwnedRAM() throws {
        for state in [DoryVZMacMachineInstallationState.stopped, .suspended] {
            let projected = try MachineManager.nativeMacOSBootConfiguration(
                installationState: state, restoreReference: restore, systemReference: system)
            XCTAssertEqual(projected.phase, .normal)
            XCTAssertEqual(projected.devices.map(\.artifact), [system])
        }
        XCTAssertEqual(try MachineManager.nativeMacOSLaunchOperation(
            installationState: .stopped, restoreStatePath: nil, managedStatePath: managedRAM), "run")
        XCTAssertThrowsError(try MachineManager.nativeMacOSLaunchOperation(
            installationState: .stopped, restoreStatePath: managedRAM, managedStatePath: managedRAM))
        XCTAssertEqual(try MachineManager.nativeMacOSLaunchOperation(
            installationState: .suspended, restoreStatePath: managedRAM, managedStatePath: managedRAM), "resume")
        for path in [nil, "/other-machine/saved-state/state.vzvmsave", managedRAM + ".stale"] {
            XCTAssertThrowsError(try MachineManager.nativeMacOSLaunchOperation(
                installationState: .suspended, restoreStatePath: path, managedStatePath: managedRAM))
        }
    }

    func testInstallRecoveryDoesNotAdmitInterruptedRAMOperations() {
        for state in [DoryVZMacMachineInstallationState.suspending, .restoring] {
            XCTAssertThrowsError(try MachineManager.nativeMacOSBootConfiguration(
                installationState: state, restoreReference: restore, systemReference: system))
            for path in [nil, managedRAM] {
                XCTAssertThrowsError(try MachineManager.nativeMacOSLaunchOperation(
                    installationState: state, restoreStatePath: path, managedStatePath: managedRAM))
            }
        }
    }
}
