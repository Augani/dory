import Testing

@testable import DoryPhase0AQualification

@Suite("Phase 0A metric summaries")
struct MetricSummaryTests {
    @Test("R-7 percentiles and population variance are deterministic")
    func deterministicSummary() throws {
        let summary = try Phase0AMetricSummary(samples: [40, 10, 30, 20])

        #expect(summary.sampleCount == 4)
        #expect(summary.minimum == 10)
        #expect(summary.lowerQuartile == 17.5)
        #expect(summary.median == 25)
        #expect(summary.upperQuartile == 32.5)
        #expect(summary.p90 == 37)
        #expect(abs(summary.p95 - 38.5) < 0.000_001)
        #expect(abs(summary.p99 - 39.7) < 0.000_001)
        #expect(summary.maximum == 40)
        #expect(summary.mean == 25)
        #expect(summary.variance == 125)
    }

    @Test("empty, negative, and non-finite samples fail closed", arguments: [
        [], [-1], [Double.nan], [Double.infinity],
    ])
    func invalidSamples(samples: [Double]) {
        #expect(throws: Phase0AMetricSummaryError.invalidSamples) {
            try Phase0AMetricSummary(samples: samples)
        }
    }

    @Test("signed comparison deltas are supported only when explicitly requested")
    func signedComparisonDeltas() throws {
        let summary = try Phase0AMetricSummary(
            samples: [-2, 1, 4],
            allowsNegativeValues: true
        )

        #expect(summary.minimum == -2)
        #expect(summary.median == 1)
        #expect(summary.maximum == 4)
    }
}
