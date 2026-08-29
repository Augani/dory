import DoryCore
import Foundation
import XCTest
@testable import DorydKit

final class MachineManagerUSBControlTests: XCTestCase {
    func testResolvedOnlyPublicRouteRejectsLegacyCompatibility() throws {
        let fixture = try Fixture(capabilities: [
            DoryAgentCapability(id: "usb-vhci", version: 1),
        ])
        defer { fixture.cleanup() }

        XCTAssertThrowsError(
            try fixture.manager.attachResolvedUSBDevice(id: "desktop", busID: "3-2")
        ) { error in
            XCTAssertEqual(error as? MachineManagerError, .usbUnavailable("desktop"))
        }
        XCTAssertThrowsError(
            try fixture.manager.detachResolvedUSBDevice(id: "desktop", busID: "3-2")
        ) { error in
            XCTAssertEqual(error as? MachineManagerError, .usbUnavailable("desktop"))
        }
        XCTAssertTrue(fixture.controller.calls.isEmpty)
        let runtimeLeaves = try FileManager.default.contentsOfDirectory(
            atPath: fixture.runtimeDirectory
        ).filter { $0.wholeMatch(of: /[0-9a-f]{24}/) != nil }
        XCTAssertEqual(runtimeLeaves.count, 1)
        let runtimeLeaf = try XCTUnwrap(runtimeLeaves.first)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: fixture.runtimeDirectory + "/" + runtimeLeaf
        )
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o700))
    }

    func testAttachTransactionCompensatesWhenPinnedLaunchAuthorityChanges() throws {
        let controller = TransactionUSBController(attachBehavior: .success)
        let transaction = DoryResolvedUSBControlTransaction(controller: controller)

        XCTAssertThrowsError(try transaction.attach(
            machineID: "desktop",
            socketPath: "/private/tmp/runtime/u.sock",
            busID: "3-2",
            mode: .userAuthorized,
            launchAuthorityRemainsValid: { false }
        )) { error in
            XCTAssertEqual(
                error as? MachineManagerError,
                .usbControlFailed(
                    "desktop",
                    "live launch changed while attaching the USB device"
                )
            )
        }
        XCTAssertEqual(controller.operations, ["attach:3-2", "detach:3-2"])
    }

    func testAttachTransactionCompensatesUnknownHelperOutcome() throws {
        let attachFailure = DoryMachineUSBControlError.outcomeUnknown(
            operation: "attach",
            detail: "response was lost"
        )
        let controller = TransactionUSBController(
            attachBehavior: .failure(attachFailure)
        )
        let transaction = DoryResolvedUSBControlTransaction(controller: controller)

        XCTAssertThrowsError(try transaction.attach(
            machineID: "desktop",
            socketPath: "/private/tmp/runtime/u.sock",
            busID: "3-2",
            mode: .userAuthorized,
            launchAuthorityRemainsValid: { true }
        )) { error in
            XCTAssertEqual(
                error as? MachineManagerError,
                .usbControlFailed(
                    "desktop",
                    "attach request failed: \(attachFailure)"
                )
            )
        }
        XCTAssertEqual(controller.operations, ["attach:3-2", "detach:3-2"])
    }

    func testAttachTransactionPreservesOriginalFailureWhenCompensationIsUncertain() throws {
        let detachFailure = DoryMachineUSBControlError.outcomeUnknown(
            operation: "detach",
            detail: "response was lost"
        )
        let controller = TransactionUSBController(
            attachBehavior: .mismatchedMachine,
            detachError: detachFailure
        )
        let transaction = DoryResolvedUSBControlTransaction(controller: controller)

        XCTAssertThrowsError(try transaction.attach(
            machineID: "desktop",
            socketPath: "/private/tmp/runtime/u.sock",
            busID: "3-2",
            mode: .userAuthorized,
            launchAuthorityRemainsValid: { true }
        )) { error in
            XCTAssertEqual(
                error as? MachineManagerError,
                .usbAttachCompensationUncertain(
                    "desktop",
                    original: "helper response does not match the requested machine and device",
                    compensation: detachFailure.description
                )
            )
        }
        XCTAssertEqual(controller.operations, ["attach:3-2", "detach:3-2"])
    }

    func testAttachTransactionDoesNotCompensateDefiniteRejection() throws {
        let rejection = DoryMachineUSBControlError.rejected("device is busy")
        let controller = TransactionUSBController(attachBehavior: .failure(rejection))
        let transaction = DoryResolvedUSBControlTransaction(controller: controller)

        XCTAssertThrowsError(try transaction.attach(
            machineID: "desktop",
            socketPath: "/private/tmp/runtime/u.sock",
            busID: "3-2",
            mode: .userAuthorized,
            launchAuthorityRemainsValid: { true }
        )) { error in
            XCTAssertEqual(
                error as? MachineManagerError,
                .usbControlFailed("desktop", "attach request failed: \(rejection)")
            )
        }
        XCTAssertEqual(controller.operations, ["attach:3-2"])
    }

    func testDetachTransactionPreservesUnknownHelperOutcome() throws {
        let detachFailure = DoryMachineUSBControlError.outcomeUnknown(
            operation: "detach",
            detail: "response was lost"
        )
        let controller = TransactionUSBController(
            attachBehavior: .success,
            detachError: detachFailure
        )
        let transaction = DoryResolvedUSBControlTransaction(controller: controller)

        XCTAssertThrowsError(try transaction.detach(
            machineID: "desktop",
            socketPath: "/private/tmp/runtime/u.sock",
            busID: "3-2",
            launchAuthorityRemainsValid: { true }
        )) { error in
            XCTAssertEqual(
                error as? MachineManagerError,
                .usbDetachOutcomeUnknown(
                    "desktop",
                    busID: "3-2",
                    detail: detachFailure.description
                )
            )
        }
        XCTAssertEqual(controller.operations, ["detach:3-2"])
    }

    func testDetachTransactionTreatsPostSuccessAuthorityChangeAsUnknown() throws {
        let controller = TransactionUSBController(attachBehavior: .success)
        let transaction = DoryResolvedUSBControlTransaction(controller: controller)

        XCTAssertThrowsError(try transaction.detach(
            machineID: "desktop",
            socketPath: "/private/tmp/runtime/u.sock",
            busID: "3-2",
            launchAuthorityRemainsValid: { false }
        )) { error in
            XCTAssertEqual(
                error as? MachineManagerError,
                .usbDetachOutcomeUnknown(
                    "desktop",
                    busID: "3-2",
                    detail: "the helper confirmed detach, but the live launch changed before "
                        + "the manager could confirm its authority"
                )
            )
        }
        XCTAssertEqual(controller.operations, ["detach:3-2"])
    }

    private final class Fixture {
        let root: String
        let runtimeDirectory: String
        let manager: MachineManager
        let controller = RecordingUSBController()

        init(capabilities: [DoryAgentCapability]) throws {
            root = "/tmp/dory-machine-usb-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
            runtimeDirectory = root + "/runtime"
            let helper = root + "/dory-hv"
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
            try "#!/bin/sh\nexec /bin/sleep 30\n".write(
                toFile: helper,
                atomically: true,
                encoding: .utf8
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: helper
            )
            manager = MachineManager(
                configuration: MachineManagerConfiguration(
                    vmmExecutablePath: "/usr/bin/false",
                    acceleratedDesktopExecutablePath: helper,
                    stateDirectory: root + "/machines",
                    runtimeDirectory: runtimeDirectory,
                    acceleratedDesktopBaseArguments: ["desktop", "--gvproxy", "/tmp/gvproxy"],
                    requiresReadyHandoff: true
                ),
                usbController: controller
            )
            _ = try manager.create(DoryMachineConfiguration(
                id: "desktop",
                kernelPath: doryTestKernelPath,
                rootfsPath: doryTestRootfsPath,
                displayMode: .desktop,
                environment: ["DORY_DESKTOP_VMM": "accelerated"]
            ))
            let starting = try manager.start(id: "desktop")
            try sendVmmHandoff(
                path: try XCTUnwrap(starting.handoffSocketPath),
                ready: VmmReadyMessage(
                    machineID: "desktop",
                    operationID: try XCTUnwrap(starting.activeOperationID),
                    agentBuild: "dory-agent/usb-test",
                    agentProtocolVersion: DoryCore.protocolVersion(),
                    agentCapabilities: capabilities.sorted { $0.id < $1.id },
                    agentSocketPath: "/run/dory-agent.sock"
                ),
                fileDescriptors: []
            )
            for _ in 0..<200 {
                if manager.status(id: "desktop")?.state == .running { return }
                Thread.sleep(forTimeInterval: 0.01)
            }
            XCTFail("machine did not reach running state")
        }

        func cleanup() {
            _ = try? manager.stop(id: "desktop")
            try? manager.delete(id: "desktop")
            try? FileManager.default.removeItem(atPath: root)
        }
    }
}

private final class TransactionUSBController: DoryMachineUSBControlling, @unchecked Sendable {
    enum AttachBehavior {
        case success
        case mismatchedMachine
        case failure(any Error)
    }

    private let lock = NSLock()
    private let attachBehavior: AttachBehavior
    private let detachError: (any Error)?
    private var storedOperations = [String]()

    init(
        attachBehavior: AttachBehavior,
        detachError: (any Error)? = nil
    ) {
        self.attachBehavior = attachBehavior
        self.detachError = detachError
    }

    var operations: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedOperations
    }

    func attach(
        machineID: String,
        socketPath: String,
        busID: String,
        mode: DoryMachineUSBOpenMode
    ) throws -> DoryMachineUSBAttachment {
        _ = socketPath
        _ = mode
        lock.lock()
        storedOperations.append("attach:\(busID)")
        lock.unlock()
        switch attachBehavior {
        case .success:
            return attachment(machineID: machineID, busID: busID)
        case .mismatchedMachine:
            return attachment(machineID: machineID + "-wrong", busID: busID)
        case .failure(let error):
            throw error
        }
    }

    func detach(socketPath: String, busID: String) throws {
        _ = socketPath
        lock.lock()
        storedOperations.append("detach:\(busID)")
        lock.unlock()
        if let detachError { throw detachError }
    }

    private func attachment(
        machineID: String,
        busID: String
    ) -> DoryMachineUSBAttachment {
        DoryMachineUSBAttachment(
            machineID: machineID,
            busID: busID,
            port: 4,
            vsockPort: 1025,
            deviceID: 0x0003_0002,
            speed: 3
        )
    }
}

private final class RecordingUSBController: DoryMachineUSBControlling, @unchecked Sendable {
    struct Call: Equatable {
        var operation: String
        var machineID: String?
        var socketPath: String
        var busID: String
        var mode: DoryMachineUSBOpenMode?
    }

    private let lock = NSLock()
    private var storedCalls = [Call]()

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return storedCalls
    }

    func attach(
        machineID: String,
        socketPath: String,
        busID: String,
        mode: DoryMachineUSBOpenMode
    ) throws -> DoryMachineUSBAttachment {
        lock.lock()
        storedCalls.append(Call(
            operation: "attach",
            machineID: machineID,
            socketPath: socketPath,
            busID: busID,
            mode: mode
        ))
        lock.unlock()
        return DoryMachineUSBAttachment(
            machineID: machineID,
            busID: busID,
            port: 4,
            vsockPort: 1025,
            deviceID: 0x0003_0002,
            speed: 3
        )
    }

    func detach(socketPath: String, busID: String) throws {
        lock.lock()
        storedCalls.append(Call(
            operation: "detach",
            machineID: nil,
            socketPath: socketPath,
            busID: busID,
            mode: nil
        ))
        lock.unlock()
    }
}
