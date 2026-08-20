import Foundation
import Testing
@testable import DoryOperations

@Suite("VM resource policy")
struct DoryVMResourcePolicyTests {
    private let gibibyte: UInt64 = 1_073_741_824

    @Test("desktop recommendation preserves host reserves")
    func desktopRecommendation() {
        let host = host(cpu: 12, memoryGiB: 32, storageGiB: 500)
        let request = request(cpu: 4, memoryGiB: 8, diskGiB: 64)
        let result = DoryVMResourcePolicy.assess(
            host: host,
            workload: .desktop,
            request: request
        )

        #expect(result.isValid)
        #expect(result.host == host)
        #expect(result.request == request)
        #expect(result.issues.isEmpty)
        #expect(result.recommendation.virtualCPUCount == guidance(2, 4, 9))
        #expect(result.recommendation.memoryBytes == guidanceGiB(4, 8, 24))
        #expect(result.recommendation.diskBytes == guidanceGiB(32, 64, 450))
        #expect(result.recommendation.hostReserve == DoryVMHostReserve(
            logicalCPUCount: 3,
            memoryBytes: 8 * gibibyte,
            storageBytes: 50 * gibibyte
        ))
        #expect(result.recommendation.isFeasible)
    }

    @Test("recommendation is lowered to fit a constrained but viable host")
    func constrainedRecommendation() {
        let recommendation = DoryVMResourcePolicy.recommend(
            host: host(cpu: 4, memoryGiB: 8, storageGiB: 50),
            workload: .desktop
        )

        #expect(recommendation.virtualCPUCount == guidance(2, 3, 3))
        #expect(recommendation.memoryBytes == guidanceGiB(4, 6, 6))
        #expect(recommendation.diskBytes == guidanceGiB(32, 40, 40))
        #expect(recommendation.isFeasible)
    }

    @Test("running and starting VM admissions reduce the next maximum")
    func existingAdmissions() {
        let noActiveVMs = DoryVMResourcePolicy.recommend(
            host: host(cpu: 12, memoryGiB: 32, storageGiB: 500),
            workload: .desktop
        )
        let admittedHost = DoryVMHostResources(
            logicalCPUCount: 12,
            physicalMemoryBytes: 32 * gibibyte,
            freeStorageBytes: 500 * gibibyte,
            admittedVirtualCPUCount: 4,
            admittedMemoryBytes: 8 * gibibyte,
            reservedStorageBytes: 100 * gibibyte
        )
        let result = DoryVMResourcePolicy.assess(
            host: admittedHost,
            workload: .desktop,
            request: request(cpu: 4, memoryGiB: 8, diskGiB: 64)
        )

        #expect(noActiveVMs.virtualCPUCount.maximum == 9)
        #expect(result.isValid)
        #expect(result.host == admittedHost)
        #expect(result.recommendation.virtualCPUCount.maximum == 5)
        #expect(result.recommendation.memoryBytes.maximum == 16 * gibibyte)
        #expect(result.recommendation.diskBytes.maximum == 350 * gibibyte)
    }

    @Test("stopped VM compute is not admitted while its disk reservation remains")
    func stoppedVMCapacitySemantics() {
        let host = DoryVMHostResources(
            logicalCPUCount: 12,
            physicalMemoryBytes: 32 * gibibyte,
            freeStorageBytes: 500 * gibibyte,
            admittedVirtualCPUCount: 0,
            admittedMemoryBytes: 0,
            reservedStorageBytes: 100 * gibibyte
        )
        let recommendation = DoryVMResourcePolicy.recommend(host: host, workload: .desktop)

        #expect(recommendation.virtualCPUCount.maximum == 9)
        #expect(recommendation.memoryBytes.maximum == 24 * gibibyte)
        #expect(recommendation.diskBytes.maximum == 350 * gibibyte)
    }

    @Test("image and component requirements compose per resource dimension")
    func composableRequirements() throws {
        let windowsImage = DoryVMResourceRequirement(
            kind: .image,
            identifier: "windows-11-arm64",
            minimum: request(cpu: 2, memoryGiB: 8, diskGiB: 64),
            recommended: request(cpu: 4, memoryGiB: 16, diskGiB: 128)
        )
        let developmentTools = DoryVMResourceRequirement(
            kind: .component,
            identifier: "development-tools",
            minimum: request(cpu: 6, memoryGiB: 12, diskGiB: 20),
            recommended: request(cpu: 8, memoryGiB: 32, diskGiB: 40)
        )
        let recommendation = DoryVMResourcePolicy.recommend(
            host: host(cpu: 32, memoryGiB: 128, storageGiB: 1_000),
            workload: .desktop,
            requirements: [windowsImage, developmentTools]
        )

        #expect(recommendation.virtualCPUCount.minimum == 6)
        #expect(recommendation.virtualCPUCount.recommended == 8)
        #expect(recommendation.memoryBytes.minimum == 12 * gibibyte)
        #expect(recommendation.memoryBytes.recommended == 32 * gibibyte)
        #expect(recommendation.diskBytes.minimum == 64 * gibibyte)
        #expect(recommendation.diskBytes.recommended == 128 * gibibyte)

        let encoded = try JSONEncoder().encode([windowsImage, developmentTools])
        let decoded = try JSONDecoder().decode([DoryVMResourceRequirement].self, from: encoded)
        #expect(decoded == [windowsImage, developmentTools])
    }

    @Test("explicit minimum cannot be weakened by a lower recommendation")
    func requirementRecommendationNormalization() {
        let requirement = DoryVMResourceRequirement(
            kind: .component,
            identifier: "large-memory-component",
            minimum: request(cpu: 8, memoryGiB: 24, diskGiB: 80),
            recommended: request(cpu: 1, memoryGiB: 1, diskGiB: 1)
        )
        let result = DoryVMResourcePolicy.assess(
            host: host(cpu: 32, memoryGiB: 128, storageGiB: 1_000),
            workload: .server,
            requirements: [requirement],
            request: request(cpu: 8, memoryGiB: 24, diskGiB: 80)
        )

        #expect(result.isValid)
        #expect(result.issues.isEmpty)
        #expect(result.requirements == [requirement])
        #expect(result.recommendation.virtualCPUCount.recommended == 8)
        #expect(result.recommendation.memoryBytes.recommended == 24 * gibibyte)
        #expect(result.recommendation.diskBytes.recommended == 80 * gibibyte)
    }

    @Test("workload profiles have intentional requirements", arguments: [
        (DoryVMWorkloadProfile.server, UInt64(1), UInt64(2), UInt64(16), UInt64(2), UInt64(4), UInt64(32)),
        (DoryVMWorkloadProfile.desktop, UInt64(2), UInt64(4), UInt64(32), UInt64(4), UInt64(8), UInt64(64)),
        (DoryVMWorkloadProfile.installer, UInt64(2), UInt64(4), UInt64(40), UInt64(4), UInt64(8), UInt64(64)),
    ])
    func workloadRequirements(
        workload: DoryVMWorkloadProfile,
        minimumCPU: UInt64,
        minimumMemoryGiB: UInt64,
        minimumDiskGiB: UInt64,
        recommendedCPU: UInt64,
        recommendedMemoryGiB: UInt64,
        recommendedDiskGiB: UInt64
    ) {
        let result = DoryVMResourcePolicy.assess(
            host: host(cpu: 64, memoryGiB: 128, storageGiB: 2_000),
            workload: workload,
            request: request(
                cpu: recommendedCPU,
                memoryGiB: recommendedMemoryGiB,
                diskGiB: recommendedDiskGiB
            )
        )

        #expect(result.isValid)
        #expect(result.recommendation.virtualCPUCount.minimum == minimumCPU)
        #expect(result.recommendation.virtualCPUCount.recommended == recommendedCPU)
        #expect(result.recommendation.memoryBytes.minimum == minimumMemoryGiB * gibibyte)
        #expect(result.recommendation.memoryBytes.recommended == recommendedMemoryGiB * gibibyte)
        #expect(result.recommendation.diskBytes.minimum == minimumDiskGiB * gibibyte)
        #expect(result.recommendation.diskBytes.recommended == recommendedDiskGiB * gibibyte)
    }

    @Test("valid but conservative resources produce warnings")
    func belowRecommendationWarnings() {
        let result = DoryVMResourcePolicy.assess(
            host: host(cpu: 8, memoryGiB: 16, storageGiB: 200),
            workload: .desktop,
            request: request(cpu: 2, memoryGiB: 4, diskGiB: 32)
        )

        #expect(result.isValid)
        #expect(result.issues.count == 3)
        #expect(result.issues.allSatisfy { issue in
            issue.code == .requestBelowRecommendation && issue.severity == .warning
        })
        #expect(Set(result.issues.map(\.resource)) == Set(DoryVMResourceDimension.allCases))
    }

    @Test("requests below minimum and above safe maximum are errors")
    func invalidRequest() {
        let result = DoryVMResourcePolicy.assess(
            host: host(cpu: 8, memoryGiB: 16, storageGiB: 100),
            workload: .desktop,
            request: request(cpu: 1, memoryGiB: 13, diskGiB: 95)
        )

        #expect(!result.isValid)
        #expect(result.issues.contains(issue(.requestBelowWorkloadMinimum, .cpu, actual: 1, threshold: 2)))
        #expect(result.issues.contains(issue(
            .requestExceedsHostSafeMaximum,
            .memory,
            actual: 13 * gibibyte,
            threshold: 12 * gibibyte
        )))
        #expect(result.issues.contains(issue(
            .requestExceedsHostSafeMaximum,
            .storage,
            actual: 95 * gibibyte,
            threshold: 90 * gibibyte
        )))
    }

    @Test("undersized hosts report infeasible workload dimensions")
    func undersizedHost() {
        let result = DoryVMResourcePolicy.assess(
            host: host(cpu: 2, memoryGiB: 4, storageGiB: 45),
            workload: .installer,
            request: request(cpu: 2, memoryGiB: 4, diskGiB: 40)
        )

        #expect(!result.isValid)
        #expect(!result.recommendation.isFeasible)
        #expect(result.issues.contains(issue(
            .hostCapacityBelowWorkloadMinimum,
            .cpu,
            actual: 1,
            threshold: 2
        )))
        #expect(result.issues.contains(issue(
            .hostCapacityBelowWorkloadMinimum,
            .memory,
            actual: 2 * gibibyte,
            threshold: 4 * gibibyte
        )))
        #expect(result.issues.contains(issue(
            .hostCapacityBelowWorkloadMinimum,
            .storage,
            actual: 35 * gibibyte,
            threshold: 40 * gibibyte
        )))
    }

    @Test("zero host facts are diagnosed independently")
    func invalidHostFacts() {
        let result = DoryVMResourcePolicy.assess(
            host: DoryVMHostResources(
                logicalCPUCount: 0,
                physicalMemoryBytes: 0,
                freeStorageBytes: 0
            ),
            workload: .server,
            request: DoryVMResourceRequest(virtualCPUCount: 0, memoryBytes: 0, diskBytes: 0)
        )

        #expect(!result.isValid)
        #expect(result.issues.filter { $0.code == .invalidHostCapacity }.count == 3)
        #expect(result.issues.filter { $0.code == .hostCapacityBelowWorkloadMinimum }.count == 3)
        #expect(result.issues.filter { $0.code == .requestBelowWorkloadMinimum }.count == 3)
    }

    @Test("maximum integer host facts do not overflow")
    func overflowSafety() {
        let host = DoryVMHostResources(
            logicalCPUCount: .max,
            physicalMemoryBytes: .max,
            freeStorageBytes: .max
        )
        let result = DoryVMResourcePolicy.assess(
            host: host,
            workload: .server,
            request: request(cpu: 2, memoryGiB: 4, diskGiB: 32)
        )

        let expectedReserve = UInt64.max / 4 + 1
        #expect(result.isValid)
        #expect(result.recommendation.hostReserve.logicalCPUCount == expectedReserve)
        #expect(result.recommendation.hostReserve.memoryBytes == expectedReserve)
        #expect(result.recommendation.hostReserve.storageBytes == UInt64.max / 10 + 1)
        #expect(result.recommendation.virtualCPUCount.maximum == UInt64.max - expectedReserve)
    }

    @Test("admissions and storage reservations beyond capacity are diagnosed separately")
    func excessiveAdmissions() {
        let host = DoryVMHostResources(
            logicalCPUCount: 4,
            physicalMemoryBytes: 8 * gibibyte,
            freeStorageBytes: 20 * gibibyte,
            admittedVirtualCPUCount: .max,
            admittedMemoryBytes: .max,
            reservedStorageBytes: .max
        )
        let result = DoryVMResourcePolicy.assess(
            host: host,
            workload: .server,
            request: request(cpu: 1, memoryGiB: 2, diskGiB: 16)
        )

        #expect(!result.isValid)
        #expect(result.recommendation.virtualCPUCount.maximum == 0)
        #expect(result.recommendation.memoryBytes.maximum == 0)
        #expect(result.recommendation.diskBytes.maximum == 0)
        #expect(result.issues.filter { $0.code == .hostAdmissionExceedsCapacity }.count == 2)
        #expect(result.issues.filter { $0.code == .storageReservationExceedsCapacity }.count == 1)
    }

    @Test("assessment has a stable Codable representation")
    func codableRoundTrip() throws {
        let original = DoryVMResourcePolicy.assess(
            host: host(cpu: 10, memoryGiB: 24, storageGiB: 250),
            workload: .installer,
            request: request(cpu: 4, memoryGiB: 8, diskGiB: 64)
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DoryVMResourceAssessment.self, from: data)
        #expect(decoded == original)
    }

    @Test("older host facts decode with zero active admissions")
    func hostFactsBackwardCompatibility() throws {
        let data = Data(#"{"logicalCPUCount":8,"physicalMemoryBytes":17179869184,"freeStorageBytes":214748364800}"#.utf8)
        let decoded = try JSONDecoder().decode(DoryVMHostResources.self, from: data)

        #expect(decoded == host(cpu: 8, memoryGiB: 16, storageGiB: 200))
        #expect(decoded.admittedVirtualCPUCount == 0)
        #expect(decoded.admittedMemoryBytes == 0)
        #expect(decoded.reservedStorageBytes == 0)

        let legacy = Data(#"""
        {
          "logicalCPUCount":8,"physicalMemoryBytes":17179869184,
          "freeStorageBytes":214748364800,"committedVirtualCPUCount":2,
          "committedMemoryBytes":4294967296,"reservedStorageBytes":34359738368
        }
        """#.utf8)
        let migrated = try JSONDecoder().decode(DoryVMHostResources.self, from: legacy)
        #expect(migrated.admittedVirtualCPUCount == 2)
        #expect(migrated.admittedMemoryBytes == 4 * gibibyte)
        #expect(migrated.reservedStorageBytes == 32 * gibibyte)

        let currentJSON = try #require(String(
            data: JSONEncoder().encode(migrated),
            encoding: .utf8
        ))
        #expect(currentJSON.contains("admittedVirtualCPUCount"))
        #expect(!currentJSON.contains("committedVirtualCPUCount"))
    }

    private func host(cpu: UInt64, memoryGiB: UInt64, storageGiB: UInt64) -> DoryVMHostResources {
        DoryVMHostResources(
            logicalCPUCount: cpu,
            physicalMemoryBytes: memoryGiB * gibibyte,
            freeStorageBytes: storageGiB * gibibyte
        )
    }

    private func request(cpu: UInt64, memoryGiB: UInt64, diskGiB: UInt64) -> DoryVMResourceRequest {
        DoryVMResourceRequest(
            virtualCPUCount: cpu,
            memoryBytes: memoryGiB * gibibyte,
            diskBytes: diskGiB * gibibyte
        )
    }

    private func guidance(_ minimum: UInt64, _ recommended: UInt64, _ maximum: UInt64) -> DoryVMResourceGuidance {
        DoryVMResourceGuidance(minimum: minimum, recommended: recommended, maximum: maximum)
    }

    private func guidanceGiB(_ minimum: UInt64, _ recommended: UInt64, _ maximum: UInt64) -> DoryVMResourceGuidance {
        guidance(minimum * gibibyte, recommended * gibibyte, maximum * gibibyte)
    }

    private func issue(
        _ code: DoryVMResourceValidationCode,
        _ resource: DoryVMResourceDimension,
        actual: UInt64,
        threshold: UInt64
    ) -> DoryVMResourceValidationIssue {
        DoryVMResourceValidationIssue(
            code: code,
            severity: .error,
            resource: resource,
            actual: actual,
            threshold: threshold
        )
    }
}
