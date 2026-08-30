import XCTest
@testable import DoryVZMacCore

final class DoryVZMacResourcePlanTests: XCTestCase {
    func testDefaultsToRestoreImageMinimums() throws {
        let plan = try DoryVZMacResourcePlan(
            requestedCPUCount: nil,
            requestedMemoryBytes: nil,
            requestedDiskBytes: 80 * DoryVZMacResourcePlan.gibibyte,
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
            minimumCPUCount: 4,
            minimumMemoryBytes: 8 * DoryVZMacResourcePlan.gibibyte,
            maximumCPUCount: 12,
            maximumMemoryBytes: 64 * DoryVZMacResourcePlan.gibibyte
        ))
    }
}
