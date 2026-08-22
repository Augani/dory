import DoryCore
import Foundation
import XCTest
@testable import DorydKit

final class MachineManagerUSBControlTests: XCTestCase {
    func testRoutesAttachAndDetachOnlyToThePinnedRawHVLaunch() throws {
        let fixture = try Fixture(capabilities: [
            DoryAgentCapability(id: "usb-vhci", version: 1),
        ])
        defer { fixture.cleanup() }

        let attachment = try fixture.manager.attachUSBDevice(
            id: "desktop",
            busID: "3-2",
            mode: .capture
        )
        XCTAssertEqual(attachment.machineID, "desktop")
        XCTAssertEqual(attachment.busID, "3-2")
        XCTAssertEqual(attachment.port, 4)

        try fixture.manager.detachUSBDevice(id: "desktop", busID: "3-2")

        let calls = fixture.controller.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].operation, "attach")
        XCTAssertEqual(calls[0].machineID, "desktop")
        XCTAssertEqual(calls[0].busID, "3-2")
        XCTAssertEqual(calls[0].mode, .capture)
        XCTAssertTrue(calls[0].socketPath.hasPrefix(fixture.runtimeDirectory + "/"))
        XCTAssertTrue(calls[0].socketPath.hasSuffix("/u.sock"))
        XCTAssertLessThan(calls[0].socketPath.utf8.count, 104)
        XCTAssertEqual(calls[1].operation, "detach")
        XCTAssertEqual(calls[1].socketPath, calls[0].socketPath)
    }

    func testRejectsMissingGuestCapabilityBeforeContactingUSBController() throws {
        let fixture = try Fixture(capabilities: [
            DoryAgentCapability(id: "exec", version: 1),
        ])
        defer { fixture.cleanup() }

        XCTAssertThrowsError(
            try fixture.manager.attachUSBDevice(id: "desktop", busID: "3-2")
        ) { error in
            XCTAssertEqual(error as? MachineManagerError, .usbUnavailable("desktop"))
        }
        XCTAssertThrowsError(
            try fixture.manager.detachUSBDevice(id: "desktop", busID: "3-2")
        ) { error in
            XCTAssertEqual(error as? MachineManagerError, .usbUnavailable("desktop"))
        }
        XCTAssertTrue(fixture.controller.calls.isEmpty)
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
                displayMode: .desktop
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
