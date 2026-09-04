import DoryDBTX86
import Foundation
import Testing

@testable import dory_x86_decode_audit

@Suite struct SSE2ConversionInventoryTests {
  @Test func separateConversionCorpusMatchesTheCurrentDecoderWithoutInheritingExecutionClaims() throws {
    let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let path = package.appendingPathComponent("Sources/dory-x86-decode-audit/Vectors/p02-sse2-conversions-v1.json")
    let report = try ISAInventory.report(data: Data(contentsOf: path))
    #expect(report.corpusID == "dory.p02.sse2-conversions-v1")
    #expect(report.corpusVectorCount == 50 && report.staticDecodedFormCount == 38)
    #expect(report.rejectedVectorCount == 12 && report.mismatchedVectorCount == 0)
    #expect(report.executedFormCount == 0 && report.faultAttemptFormCount == 0)
    #expect(report.currentInvocationExecutedFormCount == 0 && report.physicalReferenceExecutedFormCount == 0)
    #expect(report.supportCatalog == nil)
    #expect(report.records.map(\.vector.id) == report.records.map(\.vector.id).sorted())
    for record in report.records {
      #expect(record.expectationMismatches.isEmpty, "\(record.vector.id): \(record.expectationMismatches)")
      #expect(record.interpreterSemantics.status == "unmeasured")
      #expect(record.jitSupport.baseline.status == "unmeasured" && record.jitSupport.optimizing.status == "unmeasured")
    }
    for mode in [DoryX86ExecutionMode.real16, .protected16, .protected32, .long64] {
      #expect(report.records.filter { $0.vector.mode == mode && $0.decodedInstruction != nil }.count
        == (mode == .long64 ? 11 : 9))
    }
  }
}
