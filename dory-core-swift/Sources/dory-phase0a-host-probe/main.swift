import DoryPhase0AQualification
import Foundation

do {
    let receipt = try Phase0AHostCollector.collect()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    FileHandle.standardOutput.write(try encoder.encode(receipt))
    FileHandle.standardOutput.write(Data([0x0a]))
} catch {
    FileHandle.standardError.write(Data("dory Phase 0A host probe failed: \(error)\n".utf8))
    exit(EXIT_FAILURE)
}
