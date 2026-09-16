import Foundation
import XCTest
@testable import DorydKit

final class DoryMachineConfigurationDataDiskTests: XCTestCase {
    func testOptionalMachineStorageIntentRoundTripsAndLegacyPayloadGetsSafeDefaults() throws {
        let original = DoryMachineConfiguration(
            id: "native-data-disk",
            guestFamily: .macOS,
            guestArchitecture: .arm64,
            kernelPath: "",
            rootfsPath: "",
            bootMode: .macOSRestore,
            macOSRestoreImagePath: "/managed/Restore.ipsw",
            macOSMachineBundlePath: "/managed/Machine.dorymac",
            diskSizeBytes: 64 * 1_073_741_824,
            dataDiskBytes: [8 * 1_073_741_824, 16 * 1_073_741_824],
            memoryMB: 8_192,
            cpuCount: 4,
            displayMode: .desktop
        )
        let encoded = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(DoryMachineConfiguration.self, from: encoded), original)

        var legacyObject = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "dataDiskBytes")
        let legacy = try JSONSerialization.data(withJSONObject: legacyObject, options: [.sortedKeys])
        XCTAssertEqual(
            try JSONDecoder().decode(DoryMachineConfiguration.self, from: legacy).dataDiskBytes,
            []
        )
        XCTAssertEqual(
            try JSONDecoder().decode(DoryMachineConfiguration.self, from: legacy).rootDiskFormat,
            .raw
        )

        let qcow2 = DoryMachineConfiguration(
            id: "qcow2-source",
            kernelPath: "/input/Image",
            rootfsPath: "/input/disk.qcow2",
            rootDiskFormat: .qcow2
        )
        XCTAssertEqual(
            try JSONDecoder().decode(DoryMachineConfiguration.self, from: JSONEncoder().encode(qcow2)),
            qcow2
        )
    }
}
