import Foundation
import Virtualization
import XCTest
@testable import DoryVZMacCore

final class DoryVZMacSharedDirectoryTests: XCTestCase {
    func testAcceptsBoundedDirectDirectory() throws {
        let share = try DoryVZMacSharedDirectory(
            name: "Dory Guest Tools",
            url: FileManager.default.temporaryDirectory,
            readOnly: true
        )
        XCTAssertTrue(share.readOnly)
    }

    func testRejectsUnsafeNameAndNonDirectory() throws {
        XCTAssertThrowsError(
            try DoryVZMacSharedDirectory(
                name: "../escape",
                url: FileManager.default.temporaryDirectory,
                readOnly: true
            )
        )
        XCTAssertThrowsError(
            try DoryVZMacSharedDirectory(
                name: "Dory",
                url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                readOnly: true
            )
        )
    }

    func testConfigurationFingerprintChangesWithSharePolicy() throws {
        let readOnly = try DoryVZMacSharedDirectory(
            name: "Dory Guest Tools",
            url: FileManager.default.temporaryDirectory,
            readOnly: true
        )
        let readWrite = try DoryVZMacSharedDirectory(
            name: "Dory Guest Tools",
            url: FileManager.default.temporaryDirectory,
            readOnly: false
        )
        let first = try DoryVZMacConfigurationBuilder.fingerprint(
            sharedDirectories: [readOnly]
        )
        XCTAssertEqual(first.count, 64)
        XCTAssertEqual(
            first,
            try DoryVZMacConfigurationBuilder.fingerprint(sharedDirectories: [readOnly])
        )
        XCTAssertNotEqual(
            first,
            try DoryVZMacConfigurationBuilder.fingerprint(sharedDirectories: [readWrite])
        )
    }

    func testEffectiveDevicePolicyConstructsRequestedVZDevices() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let share = try DoryVZMacSharedDirectory(
            name: "Dory Guest Tools",
            url: directory,
            readOnly: true
        )
        let configuration = VZVirtualMachineConfiguration()

        try DoryVZMacConfigurationBuilder.applyDevicePolicy(
            to: configuration,
            macAddress: "02:00:5e:10:20:30",
            sharedDirectories: [share],
            devicePolicy: .legacyDefault
        )

        let report = DoryVZMacConfigurationBuilder.inspectEffectiveDevices(configuration)
        XCTAssertEqual(report.networkDeviceCount, 1)
        XCTAssertTrue(report.usesNATNetworkAttachment)
        XCTAssertEqual(report.audioDeviceCount, 1)
        XCTAssertEqual(report.audioInputStreamCount, 1)
        XCTAssertEqual(report.audioOutputStreamCount, 1)
        XCTAssertEqual(report.directorySharingDeviceCount, 1)
        XCTAssertEqual(report.sharedDirectoryCount, 1)
        XCTAssertEqual(report.consoleDeviceCount, 1)
        XCTAssertTrue(report.spiceClipboardEnabled)
    }

    func testDisabledEffectiveDevicePolicyRemovesVZDevices() throws {
        let configuration = VZVirtualMachineConfiguration()
        let policy = DoryVZMacDevicePolicy(
            network: .disconnected,
            audio: DoryVZMacAudioPolicy(inputEnabled: false, outputEnabled: false),
            clipboardEnabled: false,
            directorySharingEnabled: false
        )

        try DoryVZMacConfigurationBuilder.applyDevicePolicy(
            to: configuration,
            macAddress: "02:00:5e:10:20:30",
            sharedDirectories: [],
            devicePolicy: policy
        )

        let report = DoryVZMacConfigurationBuilder.inspectEffectiveDevices(configuration)
        XCTAssertFalse(report.hasNetwork)
        XCTAssertFalse(report.hasAudioInput)
        XCTAssertFalse(report.hasAudioOutput)
        XCTAssertFalse(report.hasDirectorySharing)
        XCTAssertFalse(report.hasClipboard)
    }

    func testRejectsConfiguredShareWhenDirectorySharingDisabled() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let share = try DoryVZMacSharedDirectory(
            name: "Dory Guest Tools",
            url: directory,
            readOnly: true
        )
        let policy = DoryVZMacDevicePolicy(directorySharingEnabled: false)

        XCTAssertThrowsError(try DoryVZMacConfigurationBuilder.fingerprint(
            sharedDirectories: [share],
            devicePolicy: policy
        )) { error in
            XCTAssertEqual(
                String(describing: error),
                DoryVZMacConfigurationError.integrationDisabled("directory sharing").description
            )
        }
    }

    func testDevicePolicyFingerprintBindsDisabledIntegrations() throws {
        let disabled = DoryVZMacDevicePolicy(
            network: .disconnected,
            audio: DoryVZMacAudioPolicy(inputEnabled: false, outputEnabled: false),
            clipboardEnabled: false,
            directorySharingEnabled: false
        )

        XCTAssertNotEqual(
            try DoryVZMacConfigurationBuilder.fingerprint(),
            try DoryVZMacConfigurationBuilder.fingerprint(devicePolicy: disabled)
        )
        XCTAssertEqual(
            try DoryVZMacConfigurationBuilder.fingerprint(devicePolicy: disabled),
            try DoryVZMacConfigurationBuilder.fingerprint(devicePolicy: disabled)
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DoryVZMacSharedDirectoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        return directory
    }
}
