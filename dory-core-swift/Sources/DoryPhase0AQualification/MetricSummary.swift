import Foundation

public struct Phase0AMetricSummary: Codable, Equatable, Sendable {
    public var sampleCount: Int
    public var minimum: Double
    public var lowerQuartile: Double
    public var median: Double
    public var upperQuartile: Double
    public var p90: Double
    public var p95: Double
    public var p99: Double
    public var maximum: Double
    public var mean: Double
    public var variance: Double
    public var coefficientOfVariation: Double

    public init(samples: [Double], allowsNegativeValues: Bool = false) throws {
        guard
            !samples.isEmpty,
            samples.allSatisfy({ $0.isFinite && (allowsNegativeValues || $0 >= 0) })
        else {
            throw Phase0AMetricSummaryError.invalidSamples
        }
        let ordered = samples.sorted()
        let mean = ordered.reduce(0, +) / Double(ordered.count)
        let variance = ordered.reduce(0) { total, sample in
            let delta = sample - mean
            return total + (delta * delta)
        } / Double(ordered.count)
        self.sampleCount = ordered.count
        self.minimum = ordered[0]
        self.lowerQuartile = Self.percentile(ordered, probability: 0.25)
        self.median = Self.percentile(ordered, probability: 0.5)
        self.upperQuartile = Self.percentile(ordered, probability: 0.75)
        self.p90 = Self.percentile(ordered, probability: 0.9)
        self.p95 = Self.percentile(ordered, probability: 0.95)
        self.p99 = Self.percentile(ordered, probability: 0.99)
        self.maximum = ordered[ordered.count - 1]
        self.mean = mean
        self.variance = variance
        self.coefficientOfVariation = mean == 0 ? 0 : variance.squareRoot() / mean
    }

    /// R-7/NumPy-style linear interpolation at `p * (n - 1)`.
    private static func percentile(_ ordered: [Double], probability: Double) -> Double {
        let rank = probability * Double(ordered.count - 1)
        let lowerIndex = Int(rank.rounded(.down))
        let upperIndex = Int(rank.rounded(.up))
        guard lowerIndex != upperIndex else { return ordered[lowerIndex] }
        let fraction = rank - Double(lowerIndex)
        return ordered[lowerIndex] + ((ordered[upperIndex] - ordered[lowerIndex]) * fraction)
    }
}

public enum Phase0AMetricSummaryError: Error, Equatable {
    case invalidSamples
}
