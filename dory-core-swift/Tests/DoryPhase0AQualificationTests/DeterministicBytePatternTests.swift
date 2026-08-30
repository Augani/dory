import Testing

@testable import DoryPhase0AQualification

@Suite("Phase 0A deterministic byte pattern")
struct DeterministicBytePatternTests {
    @Test("pattern is stable at representative offsets")
    func representativeOffsets() {
        #expect(Phase0ADeterministicBytePattern.byte(at: 0) == 17)
        #expect(Phase0ADeterministicBytePattern.byte(at: 1) == 48)
        #expect(Phase0ADeterministicBytePattern.byte(at: 255) == 242)
        #expect(Phase0ADeterministicBytePattern.byte(at: 1_048_575) == 242)
    }

    @Test("pattern repeats every 256 bytes")
    func repeats() {
        for offset in 0..<256 {
            #expect(
                Phase0ADeterministicBytePattern.byte(at: offset)
                    == Phase0ADeterministicBytePattern.byte(at: offset + 256)
            )
        }
    }
}
