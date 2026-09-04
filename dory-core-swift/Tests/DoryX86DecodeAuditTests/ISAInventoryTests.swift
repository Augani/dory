import DoryDBTX86
import Foundation
import Testing

@testable import dory_x86_decode_audit

@Suite struct ISAInventoryTests {
  @Test func checkedInVectorsMatchExactDecoderOperationsAndPrefixes() throws {
    let report = try ISAInventory.report(data: ISAInventory.bundledCorpusData())
    #expect(report.corpusVectorCount == 1158)
    #expect(report.staticDecodedFormCount == 1081)
    #expect(report.rejectedVectorCount == 77)
    for record in report.records {
      #expect(record.expectationMismatches.isEmpty,
        "\(record.vector.id): \(record.expectationMismatches); \(record.decodeError ?? "decoded")")
    }
    #expect(report.mismatchedVectorCount == 0)
  }

  @Test func corpusCoversEveryGroup0F01ModRMInEveryMode() throws {
    let corpus = try ISAInventory.parse(ISAInventory.bundledCorpusData())
    for mode: DoryX86ExecutionMode in [.real16, .protected16, .protected32, .long64] {
      let baseVectors = corpus.vectors.filter {
        $0.mode == mode && ($0.id.hasPrefix("0f01.register.") || $0.id.hasPrefix("0f01.memory."))
      }
      #expect(baseVectors.count == 256)
      #expect(Set(baseVectors.map { $0.bytes[2] }) == Set(UInt8.min...UInt8.max))
      #expect(baseVectors.allSatisfy { $0.bytes.starts(with: [0x0F, 0x01]) })
    }
  }

  @Test func inventorySeparatesStaticDecodingFromExecutionQualification() throws {
    let report = try ISAInventory.report(data: ISAInventory.bundledCorpusData())
    #expect(report.staticBinaryInstructionCount == 0)
    #expect(report.executedFormCount == 0)
    for record in report.records {
      #expect(record.executedFormCount == 0)
      for qualification in [record.interpreterSemantics, record.jitSupport, record.flags, record.faults] {
        #expect(qualification.status == "unmeasured")
        #expect(qualification.evidence.isEmpty)
      }
    }
    let unsupported = try #require(report.records.first { $0.vector.id == "0f01.register.c8.long64" })
    #expect(unsupported.decoderSupport == "recognizedUnsupported")
    #expect(unsupported.decodedInstruction?.operation == .unsupportedSystemInstruction(.monitor))
  }

  @Test func rejectedFormsRetainAuthoredMetadataAndExpectedFailure() throws {
    let report = try ISAInventory.report(data: ISAInventory.bundledCorpusData())
    let rejected = try #require(report.records.first { $0.vector.id == "0f01.register.f8.protected32" })
    #expect(rejected.vector.name == "SWAPGS")
    #expect(rejected.vector.bytes == [0x0F, 0x01, 0xF8])
    #expect(rejected.vector.mode == .protected32)
    #expect(rejected.vector.expectedErrorCategory == "invalidEncoding")
    #expect(!rejected.vector.referenceIDs.isEmpty)
    #expect(rejected.decoderSupport == "rejected")
    #expect(rejected.decodedInstruction == nil)
    #expect(rejected.sizeAttributeSource == "reference prefixes; decode rejected")
    #expect(rejected.decodeErrorCategory == "invalidEncoding")
    #expect(rejected.decodeError != nil)
    #expect(rejected.expectationMismatches.isEmpty)
  }

  @Test func expectedOperationDriftFailsWithoutDroppingTheRecord() throws {
    let data = try modifiedCorpus { object in
      var vectors = try #require(object["vectors"] as? [[String: Any]])
      let index = try #require(vectors.firstIndex { $0["id"] as? String == "baseline.nop.long64" })
      vectors[index]["expectedOperation"] = ["halt": [String: Any]()]
      object["vectors"] = vectors
    }
    let report = try ISAInventory.report(data: data)
    #expect(report.mismatchedVectorCount == 1)
    let record = try #require(report.records.first { $0.vector.id == "baseline.nop.long64" })
    #expect(record.vector.expectedOperation == .halt)
    #expect(record.decodedInstruction?.operation == .noOperation)
    #expect(record.expectationMismatches == ["operation"])
  }

  @Test func JSONOutputHasStableOrderingAndOperandAddressSizes() throws {
    let data = try ISAInventory.bundledCorpusData()
    let report = try ISAInventory.report(data: data)
    #expect(report.records.map(\.vector.id) == report.records.map(\.vector.id).sorted())
    #expect(try ISAInventory.json(report) == ISAInventory.json(ISAInventory.report(data: data)))
    let sized = try #require(report.records.first { $0.vector.id == "baseline.mov-memory.6467.long64" })
    #expect(sized.operandSizeAttributeBits == 32)
    #expect(sized.addressSizeAttributeBits == 32)
    #expect(sized.decodedOperandWidthsBits == [32])
    #expect(sized.decodedAddressWidthsBits == [32])
    #expect(sized.decodedInstruction?.prefixes.segmentOverride == 0x64)
    #expect(sized.decodedInstruction?.prefixes.addressSizeOverride == true)
  }

  @Test func parserRejectsExcessDataRecordCountsAndMalformedVectors() throws {
    #expect(throws: ISAInventoryError.corpusTooLarge) {
      try ISAInventory.parse(Data(repeating: 0, count: ISAInventory.maximumCorpusBytes + 1))
    }
    let excessiveRecords = try modifiedCorpus { object in
      let vectors = try #require(object["vectors"] as? [[String: Any]])
      object["vectors"] = Array(repeating: try #require(vectors.first), count: ISAInventory.maximumVectorCount + 1)
    }
    #expect(throws: ISAInventoryError.invalidCorpus("header or record count")) {
      try ISAInventory.parse(excessiveRecords)
    }
    for defect in ["longInstruction", "unknownReference", "missingExpectation", "duplicate"] {
      let malformed = try modifiedCorpus { object in
        var vectors = try #require(object["vectors"] as? [[String: Any]])
        switch defect {
        case "longInstruction": vectors[0]["bytes"] = [UInt8](repeating: 0x90, count: 16)
        case "unknownReference": vectors[0]["referenceIDs"] = ["absent-reference"]
        case "missingExpectation":
          vectors[0].removeValue(forKey: "expectedErrorCategory")
          vectors[0].removeValue(forKey: "expectedOperation")
        default: vectors.append(vectors[0])
        }
        object["vectors"] = vectors
      }
      #expect(throws: ISAInventoryError.self) { try ISAInventory.parse(malformed) }
    }
  }

  private func modifiedCorpus(_ body: (inout [String: Any]) throws -> Void) throws -> Data {
    var object = try #require(
      JSONSerialization.jsonObject(with: ISAInventory.bundledCorpusData()) as? [String: Any])
    try body(&object)
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }
}
