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
      for qualification in [record.interpreterSemantics, record.jitSupport.baseline,
        record.jitSupport.optimizing, record.flags, record.faults] {
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

  @Test func verifiedCatalogSeparatesRetirementFaultAttemptsAndCurrentDecoding() throws {
    let report = try supportReport()
    #expect(report.executedFormCount == 3)
    #expect(report.faultAttemptFormCount == 1)
    #expect(report.currentInvocationExecutedFormCount == 0)
    #expect(report.physicalReferenceExecutedFormCount == 0)
    #expect(report.physicalReference.status == "unmeasured")
    #expect(report.staticDecodedFormCount == 1081)
    #expect(report.supportCatalog?.sourceCommit == "61cd728a4938e6e7e44319e0bd71f6147b115205")
    #expect(report.supportCatalog?.forms.count == 4)
    let add = try #require(report.records.first { $0.vector.id == "baseline.add-register.48.long64" })
    #expect(add.interpreterSemantics.status == "supported")
    #expect(add.jitSupport.baseline.status == "supported")
    #expect(add.jitSupport.optimizing.status == "unmeasured")
    #expect(add.flags.status == "supported")
    #expect(add.faults.status == "unmeasured")
    let monitor = try #require(report.records.first { $0.vector.id == "0f01.register.c8.long64" })
    #expect(monitor.interpreterSemantics.status == "unsupported")
    #expect(monitor.faults.status == "supported")
    #expect(monitor.jitSupport.baseline.status == "unmeasured")
    #expect(monitor.executedFormCount == 0)
    #expect(monitor.faultAttemptFormCount == 1)
    let unmeasured = try #require(report.records.first { $0.vector.id == "baseline.nop.protected32" })
    #expect(unmeasured.decoderSupport == "recognized")
    #expect(unmeasured.interpreterSemantics.status == "unmeasured")
    #expect(unmeasured.executedFormCount == 0)
    #expect(try ISAInventory.json(report) == ISAInventory.json(supportReport()))
  }

  @Test func catalogRejectsStaleBytesModePrefixesOperationsAndSizes() throws {
    for defect in ["bytes", "mode", "prefixes", "operation", "operand", "address", "widths"] {
      let catalog = try modifiedSupport { object in
        var forms = try #require(object["forms"] as? [[String: Any]])
        let index = try #require(forms.firstIndex {
          ($0["vector"] as? [String: Any])?["id"] as? String == "baseline.add-register.48.long64"
        })
        var vector = try #require(forms[index]["vector"] as? [String: Any])
        switch defect {
        case "bytes": vector["bytes"] = [0x90]
        case "mode": vector["mode"] = "protected32"
        case "prefixes":
          var prefixes = try #require(vector["expectedPrefixes"] as? [String: Any])
          prefixes["operandSizeOverride"] = true
          vector["expectedPrefixes"] = prefixes
        case "operation": vector["expectedOperation"] = ["halt": [String: Any]()]
        case "operand": forms[index]["operandSizeAttributeBits"] = 32
        case "address": forms[index]["addressSizeAttributeBits"] = 32
        default: forms[index]["decodedOperandWidthsBits"] = [32]
        }
        forms[index]["vector"] = vector
        object["forms"] = forms
      }
      #expect(throws: (any Error).self) { try supportReport(catalog: catalog) }
    }
  }

  @Test func catalogRejectsStaleTestSourceExcerptAndPassedResult() throws {
    for defect in ["source", "excerpt", "method", "pass", "range", "case"] {
      let catalog = try modifiedSupport { object in
        var tests = try #require(object["tests"] as? [[String: Any]])
        switch defect {
        case "source":
          var source = try #require(tests[0]["source"] as? [String: Any])
          source["sha256"] = String(repeating: "0", count: 64)
          tests[0]["source"] = source
        case "excerpt": tests[0]["excerptSHA256"] = String(repeating: "0", count: 64)
        case "method": tests[0]["method"] = "someOtherPassingTest"
        case "pass": tests[0]["passedLogLine"] = "Test agreementIncludesExtendedStateMemoryDevicesAndExit() started."
        case "range": tests[0]["firstLine"] = 1
        default:
          var forms = try #require(object["forms"] as? [[String: Any]])
          var executions = try #require(forms[0]["executions"] as? [[String: Any]])
          executions[0]["sourceAnchors"] = ["this exact executed case is absent"]
          forms[0]["executions"] = executions
          object["forms"] = forms
        }
        object["tests"] = tests
      }
      #expect(throws: ISASupportError.self) { try supportReport(catalog: catalog) }
    }
  }

  @Test func artifactReferencesRequireExactRetainedBytesAndPassingSourceBinding() throws {
    let data = try ISASupportCatalog.bundledData()
    let catalog = try JSONDecoder().decode(ISASupportCatalog.self, from: data)
    let load = try supportLoader()
    for artifact in [catalog.receipt, catalog.log, catalog.manifest, catalog.overlay] {
      #expect(throws: ISASupportError.self) {
        try ISAInventory.report(
          data: ISAInventory.bundledCorpusData(), supportCatalogData: data,
          evidenceLoader: { path in
            var bytes = try load(path)
            if path == artifact.path { bytes.append(0) }
            return bytes
          })
      }
    }
    let stale = try modifiedSupport { $0["sourceCommit"] = String(repeating: "0", count: 40) }
    #expect(throws: ISASupportError.self) { try supportReport(catalog: stale) }
    let failedRun = try modifiedSupport { $0["run"] = 29 }
    #expect(throws: ISASupportError.self) { try supportReport(catalog: failedRun) }
  }

  @Test func decodedOrReferencedFormsCannotBecomeExecutedWithoutCaseEvidence() throws {
    for defect in ["missing", "unknownTest", "physical", "retiredFault", "qualification"] {
      let catalog = try modifiedSupport { object in
        var forms = try #require(object["forms"] as? [[String: Any]])
        let index = try #require(forms.firstIndex {
          ($0["vector"] as? [String: Any])?["id"] as? String == "0f01.register.c8.long64"
        })
        var executions = try #require(forms[index]["executions"] as? [[String: Any]])
        switch defect {
        case "missing": executions = []
        case "unknownTest": executions[0]["testID"] = "staticDecodeOnly"
        case "physical": executions[0]["engine"] = "physicalReference"
        case "retiredFault": executions[0]["outcome"] = "retired"
        default:
          forms[index]["baselineJIT"] = ["status": "supported", "evidence": ["monitor-ud"], "scope": "No native execution took place."]
        }
        forms[index]["executions"] = executions
        object["forms"] = forms
      }
      #expect(throws: ISASupportError.self) { try supportReport(catalog: catalog) }
    }
  }

  @Test func decodeDriftCannotInheritHistoricalSemanticsEvenWithNewCorpusDigest() throws {
    let corpus = try modifiedCorpus { object in
      var vectors = try #require(object["vectors"] as? [[String: Any]])
      let index = try #require(vectors.firstIndex { $0["id"] as? String == "baseline.nop.long64" })
      vectors[index]["expectedOperation"] = ["halt": [String: Any]()]
      object["vectors"] = vectors
    }
    let catalog = try modifiedSupport { $0["corpusSHA256"] = ISASupportCatalog.sha256(corpus) }
    #expect(throws: ISASupportError.self) {
      try ISAInventory.report(data: corpus, supportCatalogData: catalog, evidenceLoader: supportLoader())
    }
  }

  @Test func evidenceRootRejectsTraversalAndSymlinkEscapeBeforeReading() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let outside = directory.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    try Data("outside evidence root".utf8).write(to: outside, options: .withoutOverwriting)
    defer {
      try? FileManager.default.removeItem(at: directory)
      try? FileManager.default.removeItem(at: outside)
    }
    let load = ISASupportCatalog.loader(root: directory)
    for path in ["../outside", "/outside", "a/../outside", "a//outside", "a\\outside"] {
      #expect(throws: ISASupportError.self) { try load(path) }
    }
    try FileManager.default.createSymbolicLink(
      at: directory.appendingPathComponent("escape"), withDestinationURL: directory.deletingLastPathComponent())
    #expect(throws: ISASupportError.self) { try load("escape/\(outside.lastPathComponent)") }
  }

  private func supportLoader() throws -> (String) throws -> Data {
    let start = ProcessInfo.processInfo.environment["DORY_ISA_EVIDENCE_ROOT"]
      ?? FileManager.default.currentDirectoryPath
    let root = try #require(ISASupportCatalog.discoverEvidenceRoot(startingAt: URL(fileURLWithPath: start)))
    return ISASupportCatalog.loader(root: root)
  }

  private func supportReport(catalog: Data? = nil) throws -> ISAInventoryReport {
    try ISAInventory.report(
      data: ISAInventory.bundledCorpusData(),
      supportCatalogData: catalog ?? ISASupportCatalog.bundledData(), evidenceLoader: supportLoader())
  }

  private func modifiedSupport(_ body: (inout [String: Any]) throws -> Void) throws -> Data {
    var object = try #require(
      JSONSerialization.jsonObject(with: ISASupportCatalog.bundledData()) as? [String: Any])
    try body(&object)
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }

  private func modifiedCorpus(_ body: (inout [String: Any]) throws -> Void) throws -> Data {
    var object = try #require(
      JSONSerialization.jsonObject(with: ISAInventory.bundledCorpusData()) as? [String: Any])
    try body(&object)
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }
}
