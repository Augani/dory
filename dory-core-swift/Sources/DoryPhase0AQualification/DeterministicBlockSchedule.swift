public enum Phase0ADeterministicBlockSchedule {
    public static func indices(
        seed: UInt64,
        count: Int,
        blockCount: Int
    ) throws -> [Int] {
        guard seed != 0, count > 0, blockCount > 0 else {
            throw Phase0ADeterministicBlockScheduleError.invalidConfiguration
        }
        var state = seed
        var result: [Int] = []
        result.reserveCapacity(count)
        for _ in 0..<count {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            result.append(Int(state % UInt64(blockCount)))
        }
        return result
    }
}

public enum Phase0ADeterministicBlockScheduleError: Error, Equatable {
    case invalidConfiguration
}
