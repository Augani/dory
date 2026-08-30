import Testing

@testable import DoryPhase0AQualification

@Suite("Phase 0A deterministic block schedule")
struct DeterministicBlockScheduleTests {
    @Test("same seed is reproducible and every index is in bounds")
    func reproducibleAndBounded() throws {
        let first = try Phase0ADeterministicBlockSchedule.indices(
            seed: 0xd0_72_00_01,
            count: 1_000,
            blockCount: 32_768
        )
        let second = try Phase0ADeterministicBlockSchedule.indices(
            seed: 0xd0_72_00_01,
            count: 1_000,
            blockCount: 32_768
        )

        #expect(first == second)
        #expect(first.allSatisfy { 0..<32_768 ~= $0 })
        #expect(Set(first).count > 900)
    }

    @Test("zero seed, count, or block count fails closed", arguments: [
        (UInt64(0), 1, 1),
        (UInt64(1), 0, 1),
        (UInt64(1), 1, 0),
    ])
    func invalidConfiguration(seed: UInt64, count: Int, blockCount: Int) {
        #expect(throws: Phase0ADeterministicBlockScheduleError.invalidConfiguration) {
            try Phase0ADeterministicBlockSchedule.indices(
                seed: seed,
                count: count,
                blockCount: blockCount
            )
        }
    }
}
