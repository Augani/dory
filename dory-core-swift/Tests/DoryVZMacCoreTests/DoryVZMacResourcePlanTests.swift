import XCTest
@testable import DoryVZMacCore

final class DoryVZMacResourcePlanTests: XCTestCase {
    func testDefaultsToRestoreImageMinimums() throws {
        let plan = try DoryVZMacResourcePlan(
            requestedCPUCount: nil,
            requestedMemoryBytes: nil,
            requestedDiskBytes: 80 * DoryVZMacResourcePlan.gibibyte,
            requestedDisplays: nil,
            minimumCPUCount: 4,
            minimumMemoryBytes: 8 * DoryVZMacResourcePlan.gibibyte,
            maximumCPUCount: 12,
            maximumMemoryBytes: 64 * DoryVZMacResourcePlan.gibibyte
        )

        XCTAssertEqual(plan.cpuCount, 4)
        XCTAssertEqual(plan.memoryBytes, 8 * DoryVZMacResourcePlan.gibibyte)
        XCTAssertEqual(plan.diskBytes, 80 * DoryVZMacResourcePlan.gibibyte)
    }

    func testRejectsResourcesOutsideHostAndRestoreBounds() throws {
        XCTAssertThrowsError(try DoryVZMacResourcePlan(
            requestedCPUCount: 2,
            requestedMemoryBytes: 8 * DoryVZMacResourcePlan.gibibyte,
            requestedDiskBytes: 64 * DoryVZMacResourcePlan.gibibyte,
            requestedDisplays: nil,
            minimumCPUCount: 4,
            minimumMemoryBytes: 8 * DoryVZMacResourcePlan.gibibyte,
            maximumCPUCount: 12,
            maximumMemoryBytes: 64 * DoryVZMacResourcePlan.gibibyte
        )) { error in
            XCTAssertEqual(
                error as? DoryVZMacResourcePlanError,
                .invalidCPUCount(requested: 2, minimum: 4, maximum: 12)
            )
        }
        XCTAssertThrowsError(try DoryVZMacResourcePlan(
            requestedCPUCount: 4,
            requestedMemoryBytes: 65 * DoryVZMacResourcePlan.gibibyte,
            requestedDiskBytes: 64 * DoryVZMacResourcePlan.gibibyte,
            requestedDisplays: nil,
            minimumCPUCount: 4,
            minimumMemoryBytes: 8 * DoryVZMacResourcePlan.gibibyte,
            maximumCPUCount: 12,
            maximumMemoryBytes: 64 * DoryVZMacResourcePlan.gibibyte
        ))
    }

    func testRejectsMisalignedMemoryAndSmallDisk() throws {
        XCTAssertThrowsError(try DoryVZMacResourcePlan(
            requestedCPUCount: 4,
            requestedMemoryBytes: 8 * DoryVZMacResourcePlan.gibibyte + 1,
            requestedDiskBytes: 64 * DoryVZMacResourcePlan.gibibyte,
            requestedDisplays: nil,
            minimumCPUCount: 4,
            minimumMemoryBytes: 8 * DoryVZMacResourcePlan.gibibyte,
            maximumCPUCount: 12,
            maximumMemoryBytes: 64 * DoryVZMacResourcePlan.gibibyte
        )) { error in
            XCTAssertEqual(
                error as? DoryVZMacResourcePlanError,
                .memoryMustBeMiBAligned(8 * DoryVZMacResourcePlan.gibibyte + 1)
            )
        }
        XCTAssertThrowsError(try DoryVZMacResourcePlan(
            requestedCPUCount: 4,
            requestedMemoryBytes: 8 * DoryVZMacResourcePlan.gibibyte,
            requestedDiskBytes: 63 * DoryVZMacResourcePlan.gibibyte,
            requestedDisplays: nil,
            minimumCPUCount: 4,
            minimumMemoryBytes: 8 * DoryVZMacResourcePlan.gibibyte,
            maximumCPUCount: 12,
            maximumMemoryBytes: 64 * DoryVZMacResourcePlan.gibibyte
        ))
    }

    func testSystemDiskResizeOnlyPermitsGrowthAndPreservesOtherResources() throws {
        let plan = try DoryVZMacResourcePlan(
            requestedCPUCount: 4,
            requestedMemoryBytes: 8 * DoryVZMacResourcePlan.gibibyte,
            requestedDiskBytes: 80 * DoryVZMacResourcePlan.gibibyte,
            requestedDisplays: nil,
            minimumCPUCount: 4,
            minimumMemoryBytes: 8 * DoryVZMacResourcePlan.gibibyte,
            maximumCPUCount: 12,
            maximumMemoryBytes: 64 * DoryVZMacResourcePlan.gibibyte
        )
        let resized = try plan.growingSystemDisk(to: 120 * DoryVZMacResourcePlan.gibibyte)
        XCTAssertEqual(resized.cpuCount, plan.cpuCount)
        XCTAssertEqual(resized.memoryBytes, plan.memoryBytes)
        XCTAssertEqual(resized.displays, plan.displays)
        XCTAssertEqual(resized.diskBytes, 120 * DoryVZMacResourcePlan.gibibyte)
        XCTAssertThrowsError(try plan.growingSystemDisk(to: plan.diskBytes)) { error in
            XCTAssertEqual(
                error as? DoryVZMacResourcePlanError,
                .diskResizeMustGrow(current: plan.diskBytes, requested: plan.diskBytes)
            )
        }
    }

    func testDataDisksAreBoundedStableAndPreservedBySystemDiskGrowth() throws {
        let plan = try DoryVZMacResourcePlan(
            requestedCPUCount: 4,
            requestedMemoryBytes: 8 * DoryVZMacResourcePlan.gibibyte,
            requestedDiskBytes: 80 * DoryVZMacResourcePlan.gibibyte,
            requestedDisplays: nil,
            requestedDataDiskBytes: [
                DoryVZMacResourcePlan.gibibyte,
                4 * DoryVZMacResourcePlan.gibibyte,
            ],
            minimumCPUCount: 4,
            minimumMemoryBytes: 8 * DoryVZMacResourcePlan.gibibyte,
            maximumCPUCount: 12,
            maximumMemoryBytes: 64 * DoryVZMacResourcePlan.gibibyte
        )
        XCTAssertEqual(plan.dataDisks.map(\.fileName), ["data-01.img", "data-02.img"])
        XCTAssertEqual(plan.dataDisks.map(\.byteCount), [
            DoryVZMacResourcePlan.gibibyte,
            4 * DoryVZMacResourcePlan.gibibyte,
        ])
        XCTAssertEqual(
            try plan.growingSystemDisk(to: 120 * DoryVZMacResourcePlan.gibibyte).dataDisks,
            plan.dataDisks
        )
    }

    func testMultipleDisplaysPersistWithinThePresentationBound() throws {
        let displays = [
            DoryVZMacDisplay(widthInPixels: 2_560, heightInPixels: 1_600, pixelsPerInch: 220),
            DoryVZMacDisplay(widthInPixels: 1_920, heightInPixels: 1_080, pixelsPerInch: 144),
        ]
        let plan = try DoryVZMacResourcePlan(
            requestedCPUCount: 4,
            requestedMemoryBytes: 8 * DoryVZMacResourcePlan.gibibyte,
            requestedDiskBytes: 64 * DoryVZMacResourcePlan.gibibyte,
            requestedDisplays: displays,
            minimumCPUCount: 2,
            minimumMemoryBytes: 4 * DoryVZMacResourcePlan.gibibyte,
            maximumCPUCount: 8,
            maximumMemoryBytes: 32 * DoryVZMacResourcePlan.gibibyte
        )
        XCTAssertEqual(plan.displays, displays)
        XCTAssertThrowsError(try DoryVZMacResourcePlan(
            requestedCPUCount: 4,
            requestedMemoryBytes: 8 * DoryVZMacResourcePlan.gibibyte,
            requestedDiskBytes: 64 * DoryVZMacResourcePlan.gibibyte,
            requestedDisplays: Array(repeating: displays[0], count: DoryVZMacResourcePlan.maximumDisplayCount + 1),
            minimumCPUCount: 2,
            minimumMemoryBytes: 4 * DoryVZMacResourcePlan.gibibyte,
            maximumCPUCount: 8,
            maximumMemoryBytes: 32 * DoryVZMacResourcePlan.gibibyte
        ))
    }

    func testDataDiskGrowthIsExplicitAndCannotShrinkOrChangeOtherDisks() throws {
        let gibibyte = DoryVZMacResourcePlan.gibibyte
        let memoryBytes: UInt64 = 8 * gibibyte
        let systemDiskBytes: UInt64 = 64 * gibibyte
        let firstDataDiskBytes: UInt64 = 8 * gibibyte
        let secondDataDiskBytes: UInt64 = 16 * gibibyte
        let grownDataDiskBytes: UInt64 = 24 * gibibyte
        let plan = try DoryVZMacResourcePlan(
            requestedCPUCount: 4,
            requestedMemoryBytes: memoryBytes,
            requestedDiskBytes: systemDiskBytes,
            requestedDisplays: nil,
            requestedDataDiskBytes: [
                firstDataDiskBytes,
                secondDataDiskBytes,
            ],
            minimumCPUCount: 2,
            minimumMemoryBytes: 4 * gibibyte,
            maximumCPUCount: 8,
            maximumMemoryBytes: 32 * gibibyte
        )
        let resized = try plan.growingDataDisk(at: 1, to: grownDataDiskBytes)
        XCTAssertEqual(resized.dataDisks.map(\.byteCount), [
            firstDataDiskBytes,
            grownDataDiskBytes,
        ])
        XCTAssertEqual(resized.diskBytes, plan.diskBytes)
        XCTAssertThrowsError(try plan.growingDataDisk(at: 0, to: firstDataDiskBytes))
        XCTAssertThrowsError(try plan.growingDataDisk(at: 2, to: grownDataDiskBytes))
    }

    func testDataDiskDecodingRemainsCompatibleAndRejectsRedirectedOrSmallImages() throws {
        let legacy = """
        {"cpuCount":4,"memoryBytes":8589934592,"diskBytes":85899345920,
        "displays":[{"widthInPixels":1920,"heightInPixels":1080,"pixelsPerInch":144}]}
        """.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(DoryVZMacResourcePlan.self, from: legacy).dataDisks, [])

        let redirected = """
        {"cpuCount":4,"memoryBytes":8589934592,"diskBytes":85899345920,
        "displays":[{"widthInPixels":1920,"heightInPixels":1080,"pixelsPerInch":144}],
        "dataDisks":[{"fileName":"../../outside.img","byteCount":1073741824}]}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(DoryVZMacResourcePlan.self, from: redirected))

        let tooSmall = """
        {"cpuCount":4,"memoryBytes":8589934592,"diskBytes":85899345920,
        "displays":[{"widthInPixels":1920,"heightInPixels":1080,"pixelsPerInch":144}],
        "dataDisks":[{"fileName":"data-01.img","byteCount":1024}]}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(DoryVZMacResourcePlan.self, from: tooSmall))
    }
}
