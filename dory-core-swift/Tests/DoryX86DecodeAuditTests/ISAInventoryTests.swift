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
        record.jitSupport.optimizing, record.flags, record.faults,
        record.architecturalState, record.memoryOrdering, record.independentReference.qualification, record.realWorkload.qualification] {
        #expect(qualification.status == "unmeasured")
        #expect(qualification.evidence.isEmpty)
      }
    }
    let unsupported = try #require(report.records.first { $0.vector.id == "0f01.register.c8.long64" })
    #expect(unsupported.decoderSupport == "recognizedUnsupported")
    #expect(unsupported.decodedInstruction?.operation == .unsupportedSystemInstruction(.monitor))
  }

  @Test func historicalExecutionCannotQualifyUncoveredProofDimensions() throws {
    let report = try supportReport()
    #expect(report.executedFormCount > 0)
    let json = try #require(JSONSerialization.jsonObject(with: ISAInventory.json(report)) as? [String: Any])
    #expect(json["schemaVersion"] as? Int == 3)
    let rows = try #require(json["records"] as? [[String: Any]])
    #expect(rows.count == report.corpusVectorCount)
    for row in rows {
      #expect(row["qualificationStatus"] as? String == "unqualified")
      let workload = try #require(row["realWorkload"] as? [String: Any])
      #expect(workload["status"] as? String == "unmeasured")
      #expect(workload["evidence"] as? [String] == [])
      #expect(row["conformanceState"] as? String != "workloadQualified")
      for key in ["architecturalState", "memoryOrdering", "independentReference"] {
        let dimension = try #require(row[key] as? [String: Any])
        #expect(dimension["status"] as? String == "unmeasured")
        #expect((dimension["evidence"] as? [String]) == [])
        #expect((dimension["scope"] as? String)?.hasPrefix("Open A") == true)
      }
    }
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
    #expect(report.supportCatalog?.forms.allSatisfy { $0.realWorkloadReceipt == nil } == true)
    #expect(report.records.allSatisfy { $0.realWorkload.status == "unmeasured" })
    #expect(report.conformanceStateDistribution["workloadQualified", default: 0] == 0)
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

  @Test(arguments: ["kernelBoot", "userspace", "installer"])
  func parentBoundWorkloadReceiptIsVerifiedAndSerialized(kind: String) throws {
    let report = try workloadReport(modifyReceipt: { $0["workloadKind"] = kind })
    let record = try #require(report.records.first { $0.realWorkload.status == "verified" })
    #expect(record.realWorkload.evidence == ["test-fixtures/workload-receipt.json"])
    #expect(record.independentReference.status == "unmeasured")
    #expect(record.conformanceState < .independentlyVerified)
    #expect(report.records.filter { $0.realWorkload.status == "verified" }.count == 1)
    #expect(report.executedFormCount == 3)
    #expect(report.faultAttemptFormCount == 1)
    let json = try #require(JSONSerialization.jsonObject(with: ISAInventory.json(report)) as? [String: Any])
    let rows = try #require(json["records"] as? [[String: Any]])
    let row = try #require(rows.first {
      ($0["vector"] as? [String: Any])?["id"] as? String == record.vector.id
    })
    let workload = try #require(row["realWorkload"] as? [String: Any])
    #expect(workload["status"] as? String == "verified")
    #expect(workload["evidence"] as? [String] == record.realWorkload.evidence)
    #expect(row["executedFormCount"] as? Int == record.executedFormCount)
  }

  @Test(arguments: ["schema", "vector", "kind", "failed", "running", "unobserved", "scope", "scopeSize"])
  func workloadReceiptRejectsInvalidObservation(defect: String) throws {
    #expect(throws: (any Error).self) {
      try workloadReport(modifyReceipt: { receipt in
        switch defect {
        case "schema": receipt["schemaVersion"] = 2
        case "vector":
          var vector = try #require(receipt["vector"] as? [String: Any])
          vector["bytes"] = [0x0F]
          receipt["vector"] = vector
        case "kind": receipt["workloadKind"] = "interpreter"
        case "failed": receipt["outcome"] = "failed"
        case "running": receipt["outcome"] = "running"
        case "unobserved": receipt["observedExactForm"] = false
        case "scope": receipt["scope"] = " \n"
        default: receipt["scope"] = String(repeating: "x", count: 2049)
        }
      })
    }
  }

  @Test func selfDeclaredWorkloadFileAndMatchingDigestCannotQualify() throws {
    let catalog = try JSONDecoder().decode(ISASupportCatalog.self, from: ISASupportCatalog.bundledData())
    let vector = try #require(catalog.forms.first).vector
    // The child exists, hashes correctly and claims a passing exact observation.
    // The authentic parent run never vouched for it.
    #expect(throws: ISASupportError.invalid("workload parent binding: \(vector.id)")) {
      try workloadReport(authenticateChild: false)
    }
  }

  @Test(arguments: ["digest", "path", "duplicate", "otherRun"])
  func workloadChildMustMatchExactlyOneReferenceOnSelectedParentRun(defect: String) throws {
    let catalog = try JSONDecoder().decode(ISASupportCatalog.self, from: ISASupportCatalog.bundledData())
    let vector = try #require(catalog.forms.first).vector
    #expect(throws: ISASupportError.invalid("workload parent binding: \(vector.id)")) {
      try workloadReport(modifyParent: { parent in
        var runs = try #require(parent["runs"] as? [[String: Any]])
        let index = try #require(runs.firstIndex { $0["run"] as? Int == catalog.run })
        var children = try #require(runs[index]["workloadReceipts"] as? [[String: Any]])
        switch defect {
        case "digest": children[0]["sha256"] = String(repeating: "0", count: 64)
        case "path": children[0]["path"] = "test-fixtures/other-receipt.json"
        case "duplicate": children.append(children[0])
        default:
          let other = try #require(runs.indices.first { $0 != index })
          runs[other]["workloadReceipts"] = children
          children = []
        }
        runs[index]["workloadReceipts"] = children
        parent["runs"] = runs
      })
    }
  }

  @Test func forgedIndependentReferenceCannotCombineWithAuthenticatedWorkload() throws {
    let report = try workloadReport()
    let record = try #require(report.records.first { $0.realWorkload.status == "verified" })
    let proof = ISAWorkloadQualifiedProof(
      reference: record.independentReference, workload: record.realWorkload)
    #expect(proof == nil)
    let forged = ISAQualification(status: "verified", evidence: ["independent-reference"])
    #expect(ISAConformanceStateResolver.resolve(
      decoderSupport: "recognized", interpreterSemantics: .init(), jitBaseline: .init(),
      jitOptimizing: .init(), independentReference: forged, executedFormCount: 42,
      vector: record.vector, authenticatedProof: proof) == .independentlyVerified)
  }

  @Test(arguments: ["physicalHardware", "independentEmulator"])
  func authenticatedFullProofQualifiesOnlyExactNonRejectedVector(kind: String) throws {
    let report = try workloadReport(includeReference: true, modifyReference: { $0["referenceKind"] = kind })
    let record = try #require(report.records.first { $0.realWorkload.status == "verified" })
    let other = try #require(report.records.first { $0.vector != record.vector })
    let proof = try #require(ISAWorkloadQualifiedProof(
      reference: record.independentReference, workload: record.realWorkload))
    #expect(record.independentReference.status == "verified")
    #expect(record.conformanceState == .workloadQualified)
    #expect(report.conformanceStateDistribution["workloadQualified"] == 1)
    func resolve(vector: ISAVector, support: String = "recognized") -> ISAConformanceState {
      ISAConformanceStateResolver.resolve(
        decoderSupport: support, interpreterSemantics: .init(status: "supported"),
        jitBaseline: .init(status: "supported"), jitOptimizing: .init(),
        independentReference: .init(), executedFormCount: 0,
        vector: vector, authenticatedProof: proof)
    }
    // The top tier uses the full proof, independently of plain status/count inputs.
    #expect(resolve(vector: record.vector) == .workloadQualified)
    #expect(resolve(vector: record.vector, support: "rejected") == .rejected)
    #expect(resolve(vector: other.vector) == .loweredTier1)
    // Output serialization preserves annotations, but strips both legs' authority.
    let copiedReference = try JSONDecoder().decode(
      ISAQualification.self, from: JSONEncoder().encode(record.independentReference))
    let copiedWorkload = try JSONDecoder().decode(
      ISAQualification.self, from: JSONEncoder().encode(record.realWorkload))
    #expect(copiedReference.status == "verified")
    #expect(copiedWorkload.status == "verified")
    #expect(ISAConformanceStateResolver.resolve(
      decoderSupport: "recognized", interpreterSemantics: .init(), jitBaseline: .init(),
      jitOptimizing: .init(), independentReference: copiedReference, executedFormCount: 1,
      realWorkload: copiedWorkload) == .independentlyVerified)
    #expect(ISAWorkloadQualifiedProof(reference: record.independentReference, workload: .unmeasured) == nil)
    #expect(ISAWorkloadQualifiedProof(reference: .unmeasured, workload: record.realWorkload) == nil)
  }

  @Test func independentReferenceWithoutWorkloadCannotQualify() throws {
    let report = try workloadReport(includeReference: true, modifyCatalog: { object in
      var forms = try #require(object["forms"] as? [[String: Any]])
      forms[0].removeValue(forKey: "realWorkloadReceipt")
      object["forms"] = forms
    })
    let record = try #require(report.records.first { $0.independentReference.status == "verified" })
    #expect(record.realWorkload.status == "unmeasured")
    #expect(record.conformanceState == .independentlyVerified)
  }

  @Test(arguments: ["parent", "run", "vector"])
  func authenticatedLegsFromDifferentOriginsCannotCombine(defect: String) throws {
    let first = try workloadReport(includeReference: true, duplicateRun: defect == "run")
    let reference = try #require(first.records.first { $0.independentReference.status == "verified" }).independentReference
    let second = try workloadReport(includeReference: true, modifyCatalog: { object in
      if defect == "run" { object["run"] = 999 }
      if defect == "vector" {
        var forms = try #require(object["forms"] as? [[String: Any]])
        let child = forms[0].removeValue(forKey: "realWorkloadReceipt")
        forms[1]["realWorkloadReceipt"] = child
        object["forms"] = forms
      }
    }, modifyParent: { parent in
      if defect == "parent" { parent["fixtureRevision"] = 2 }
    }, modifyWorkloadVector: defect == "vector", duplicateRun: defect == "run")
    let workload = try #require(second.records.first { $0.realWorkload.status == "verified" }).realWorkload
    #expect(ISAWorkloadQualifiedProof(reference: reference, workload: workload) == nil)
  }

  @Test(arguments: ["schema", "vector", "kind", "failed", "running", "unobserved", "mismatch", "scope", "scopeSize"])
  func independentReferenceRejectsInvalidObservation(defect: String) throws {
    #expect(throws: (any Error).self) {
      try workloadReport(includeReference: true, modifyReference: { receipt in
        switch defect {
        case "schema": receipt["schemaVersion"] = 2
        case "vector":
          var vector = try #require(receipt["vector"] as? [String: Any])
          vector["bytes"] = [0x0F]
          receipt["vector"] = vector
        case "kind": receipt["referenceKind"] = "baselineJIT"
        case "failed": receipt["outcome"] = "failed"
        case "running": receipt["outcome"] = "running"
        case "unobserved": receipt["observedExactForm"] = false
        case "mismatch": receipt["comparisonMatched"] = false
        case "scope": receipt["scope"] = " \n"
        default: receipt["scope"] = String(repeating: "x", count: 2049)
        }
      })
    }
  }

  @Test(arguments: ["missing", "digest", "path", "duplicate", "otherRun"])
  func independentReferenceRequiresSelectedParentBinding(defect: String) throws {
    let catalog = try JSONDecoder().decode(ISASupportCatalog.self, from: ISASupportCatalog.bundledData())
    let vector = try #require(catalog.forms.first).vector
    #expect(throws: ISASupportError.invalid("independent reference parent binding: \(vector.id)")) {
      try workloadReport(includeReference: true, modifyParent: { parent in
        var runs = try #require(parent["runs"] as? [[String: Any]])
        let index = try #require(runs.firstIndex { $0["run"] as? Int == catalog.run })
        var children = try #require(runs[index]["independentReferenceReceipts"] as? [[String: Any]])
        switch defect {
        case "digest": children[0]["sha256"] = String(repeating: "0", count: 64)
        case "path": children[0]["path"] = "test-fixtures/other-reference.json"
        case "duplicate": children.append(children[0])
        case "otherRun":
          let other = try #require(runs.indices.first { $0 != index })
          runs[other]["independentReferenceReceipts"] = children
          children = []
        default: children = []
        }
        runs[index]["independentReferenceReceipts"] = children
        parent["runs"] = runs
      })
    }
  }

  @Test(arguments: ["tampered", "oversize"])
  func independentReferenceRequiresVerifiedBoundedBytes(defect: String) throws {
    #expect(throws: (any Error).self) {
      try workloadReport(includeReference: true, modifyLoadedReference: { bytes in
        if defect == "tampered" { bytes.append(0) }
        else { bytes = Data(repeating: 0, count: ISASupportCatalog.maximumArtifactBytes + 1) }
      })
    }
  }

  @Test func oneChildCannotStandInForBothProofLegs() throws {
    let report = try workloadReport(includeReference: true, modifyReference: { receipt in
      receipt["workloadKind"] = "userspace"
    }, modifyCatalog: { object in
      var forms = try #require(object["forms"] as? [[String: Any]])
      forms[0]["realWorkloadReceipt"] = forms[0]["independentReferenceReceipt"]
      object["forms"] = forms
    }, modifyParent: { parent in
      let catalog = try JSONDecoder().decode(ISASupportCatalog.self, from: ISASupportCatalog.bundledData())
      var runs = try #require(parent["runs"] as? [[String: Any]])
      let index = try #require(runs.firstIndex { $0["run"] as? Int == catalog.run })
      runs[index]["workloadReceipts"] = runs[index]["independentReferenceReceipts"]
      parent["runs"] = runs
    })
    let record = try #require(report.records.first { $0.independentReference.status == "verified" })
    #expect(record.realWorkload.status == "verified")
    #expect(record.conformanceState == .independentlyVerified)
    #expect(ISAWorkloadQualifiedProof(reference: record.independentReference, workload: record.realWorkload) == nil)
  }

  @Test(arguments: [false, true])
  func distinctChildPathsRequireDistinctContentForFullProof(identicalContent: Bool) throws {
    let catalog = try #require(
      JSONSerialization.jsonObject(with: ISASupportCatalog.bundledData()) as? [String: Any])
    let forms = try #require(catalog["forms"] as? [[String: Any]])
    // One payload satisfies both receipt schemas. The attack serves its exact
    // bytes at two paths; the control changes only the reference scope.
    let sharedReceipt: [String: Any] = [
      "schemaVersion": 1, "vector": try #require(forms.first?["vector"]),
      "workloadKind": "userspace", "referenceKind": "physicalHardware",
      "outcome": "passed", "observedExactForm": true, "comparisonMatched": true,
      "scope": "Synthetic exact-form receipt for validator tests only.",
    ]
    let workloadBytes = try JSONSerialization.data(withJSONObject: sharedReceipt, options: [.sortedKeys])
    var referenceReceipt = sharedReceipt
    if !identicalContent {
      referenceReceipt["scope"] = "Synthetic independent comparison for validator tests only."
    }
    let referenceBytes = try JSONSerialization.data(withJSONObject: referenceReceipt, options: [.sortedKeys])
    let workloadDigest = ISASupportCatalog.sha256(workloadBytes)
    let referenceDigest = ISASupportCatalog.sha256(referenceBytes)
    #expect((referenceBytes == workloadBytes) == identicalContent)
    #expect((referenceDigest == workloadDigest) == identicalContent)
    let report = try workloadReport(includeReference: true, modifyReference: { receipt in
      receipt = referenceReceipt
    }, modifyReceipt: { receipt in
      receipt = sharedReceipt
    }, modifyCatalog: { object in
      let forms = try #require(object["forms"] as? [[String: Any]])
      let reference = try #require(forms[0]["independentReferenceReceipt"] as? [String: String])
      let workload = try #require(forms[0]["realWorkloadReceipt"] as? [String: String])
      #expect(reference["path"] != workload["path"])
      #expect(reference["sha256"] == referenceDigest)
      #expect(workload["sha256"] == workloadDigest)
      #expect((reference["sha256"] == workload["sha256"]) == identicalContent)
    }, modifyParent: { parent in
      let runs = try #require(parent["runs"] as? [[String: Any]])
      let run = try #require(runs.first { $0["run"] as? Int == catalog["run"] as? Int })
      let references = try #require(run["independentReferenceReceipts"] as? [[String: String]])
      let workloads = try #require(run["workloadReceipts"] as? [[String: String]])
      #expect(references == [["path": "test-fixtures/independent-reference.json", "sha256": referenceDigest]])
      #expect(workloads == [["path": "test-fixtures/workload-receipt.json", "sha256": workloadDigest]])
    }, inspectFixtureBytes: { bytes in
      let reference = try #require(bytes["test-fixtures/independent-reference.json"])
      let workload = try #require(bytes["test-fixtures/workload-receipt.json"])
      #expect(reference == referenceBytes)
      #expect(workload == workloadBytes)
      #expect((reference == workload) == identicalContent)
    })
    let record = try #require(report.records.first { $0.independentReference.status == "verified" })
    #expect(record.realWorkload.status == "verified")
    let proof = ISAWorkloadQualifiedProof(reference: record.independentReference, workload: record.realWorkload)
    #expect((proof == nil) == identicalContent)
    #expect(record.conformanceState == (identicalContent ? .independentlyVerified : .workloadQualified))
    #expect(report.conformanceStateDistribution["workloadQualified", default: 0] == (identicalContent ? 0 : 1))
  }

  @Test(arguments: ["missing", "duplicate", "conflictAfter", "conflictBefore"])
  func parentRunIDMustSelectExactlyOneRun(defect: String) throws {
    let catalog = try JSONDecoder().decode(ISASupportCatalog.self, from: ISASupportCatalog.bundledData())
    #expect(throws: ISASupportError.invalid("passing source-bound run")) {
      try workloadReport(includeReference: true, modifyParent: { parent in
        var runs = try #require(parent["runs"] as? [[String: Any]])
        let index = try #require(runs.firstIndex { $0["run"] as? Int == catalog.run })
        if defect == "missing" {
          runs.remove(at: index)
        } else {
          var duplicate = runs[index]
          if defect != "duplicate" {
            duplicate["exitCode"] = 1
            duplicate["independentReferenceReceipts"] = [] as [[String: Any]]
            duplicate["workloadReceipts"] = [] as [[String: Any]]
          }
          runs.insert(duplicate, at: defect == "conflictBefore" ? index : index + 1)
        }
        parent["runs"] = runs
      })
    }
  }

  @Test func legacyCatalogClearsReusedWorkloadEvidenceIncludingUnlistedForms() throws {
    let report = try workloadReport(includeReference: true)
    let proved = try #require(report.records.first { $0.realWorkload.status == "verified" })
    let proof = proved.realWorkload
    var records = report.records
    // Cover listed, unlisted and rejected incoming records, including stale state.
    for index in records.indices {
      records[index].independentReference = proved.independentReference
      records[index].realWorkload = proof
      records[index].conformanceState = .workloadQualified
    }
    _ = try ISASupportCatalog.apply(
      data: ISASupportCatalog.bundledData(), corpusSHA256: report.corpusSHA256,
      records: &records, load: supportLoader())
    #expect(records.allSatisfy { $0.realWorkload.status == "unmeasured" && $0.realWorkload.evidence.isEmpty })
    #expect(records.allSatisfy { $0.independentReference.status == "unmeasured" })
    #expect(records.allSatisfy { ISAWorkloadQualifiedProof(reference: $0.independentReference, workload: $0.realWorkload) == nil })
    #expect(records.allSatisfy { $0.conformanceState < .independentlyVerified })
    #expect(records.filter { $0.decoderSupport == "rejected" }.allSatisfy { $0.conformanceState == .rejected })
  }

  @Test(arguments: ["engineID", "qualification", "engineReceipt", "digest", "path", "size"])
  func workloadReceiptCannotBeReplacedByEngineEvidenceOrUnverifiedBytes(defect: String) throws {
    #expect(throws: (any Error).self) {
      try workloadReport(modifyCatalog: { object in
        var forms = try #require(object["forms"] as? [[String: Any]])
        let executions = try #require(forms[0]["executions"] as? [[String: Any]])
        let testID = try #require(executions.first?["testID"] as? String)
        var artifact = try #require(forms[0]["realWorkloadReceipt"] as? [String: Any])
        switch defect {
        case "engineID": forms[0]["realWorkloadReceipt"] = testID
        case "qualification":
          forms[0]["realWorkloadReceipt"] = ["status": "verified", "evidence": [testID], "scope": "userspace"]
        case "engineReceipt": forms[0]["realWorkloadReceipt"] = object["receipt"]
        case "digest":
          artifact["sha256"] = String(repeating: "0", count: 64)
          forms[0]["realWorkloadReceipt"] = artifact
        case "path":
          artifact["path"] = "../workload-receipt.json"
          forms[0]["realWorkloadReceipt"] = artifact
        default: break
        }
        object["forms"] = forms
      }, oversize: defect == "size")
    }
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

  // Synthetic parent/child bytes exercise the validator contract only. Write
  // them through an in-memory loader; historical artifacts remain untouched.
  private func workloadReport(
    includeReference: Bool = false,
    modifyReference: (inout [String: Any]) throws -> Void = { _ in },
    modifyReceipt: (inout [String: Any]) throws -> Void = { _ in },
    modifyCatalog: (inout [String: Any]) throws -> Void = { _ in },
    modifyParent: (inout [String: Any]) throws -> Void = { _ in },
    authenticateChild: Bool = true,
    oversize: Bool = false,
    modifyWorkloadVector: Bool = false,
    duplicateRun: Bool = false,
    modifyLoadedReference: @escaping (inout Data) -> Void = { _ in },
    inspectFixtureBytes: ([String: Data]) throws -> Void = { _ in }
  ) throws -> ISAInventoryReport {
    var fixtureBytes: [String: Data] = [:]
    let path = "test-fixtures/workload-receipt.json"
    let parentPath = "test-fixtures/parent-receipt.json"
    let load = try supportLoader()
    let catalog = try modifiedSupport { object in
      var forms = try #require(object["forms"] as? [[String: Any]])
      var receipt: [String: Any] = [
        "schemaVersion": 1, "vector": try #require(forms[modifyWorkloadVector ? 1 : 0]["vector"]),
        "workloadKind": "userspace", "outcome": "passed", "observedExactForm": true,
        "scope": "Synthetic exact-form receipt for validator tests only.",
      ]
      try modifyReceipt(&receipt)
      var receiptData = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
      if oversize { receiptData = Data(repeating: 0, count: ISASupportCatalog.maximumArtifactBytes + 1) }
      fixtureBytes[path] = receiptData
      let child = ["path": path, "sha256": ISASupportCatalog.sha256(receiptData)]
      forms[0]["realWorkloadReceipt"] = child
      var referenceChild: [String: String]?
      if includeReference {
        let referencePath = "test-fixtures/independent-reference.json"
        var reference: [String: Any] = [
          "schemaVersion": 1, "vector": try #require(forms[0]["vector"]),
          "referenceKind": "physicalHardware", "outcome": "passed",
          "observedExactForm": true, "comparisonMatched": true,
          "scope": "Synthetic independent comparison for validator tests only.",
        ]
        try modifyReference(&reference)
        let bytes = try JSONSerialization.data(withJSONObject: reference, options: [.sortedKeys])
        fixtureBytes[referencePath] = bytes
        referenceChild = ["path": referencePath, "sha256": ISASupportCatalog.sha256(bytes)]
        forms[0]["independentReferenceReceipt"] = referenceChild
      }
      object["forms"] = forms

      let parentArtifact = try #require(object["receipt"] as? [String: Any])
      let originalPath = try #require(parentArtifact["path"] as? String)
      var parent = try #require(JSONSerialization.jsonObject(with: load(originalPath)) as? [String: Any])
      if authenticateChild {
        var runs = try #require(parent["runs"] as? [[String: Any]])
        let index = try #require(runs.firstIndex { $0["run"] as? Int == object["run"] as? Int })
        runs[index]["workloadReceipts"] = [child]
        if let referenceChild { runs[index]["independentReferenceReceipts"] = [referenceChild] }
        if duplicateRun {
          var additional = runs[index]
          additional["run"] = 999
          runs.append(additional)
        }
        parent["runs"] = runs
      }
      try modifyParent(&parent)
      let parentData = try JSONSerialization.data(withJSONObject: parent, options: [.sortedKeys])
      fixtureBytes[parentPath] = parentData
      object["receipt"] = ["path": parentPath, "sha256": ISASupportCatalog.sha256(parentData)]
      // Mutations here cannot change the already-bound child identity.
      try modifyCatalog(&object)
    }
    try inspectFixtureBytes(fixtureBytes)
    return try ISAInventory.report(
      data: ISAInventory.bundledCorpusData(), supportCatalogData: catalog,
      evidenceLoader: { requested in
        if var bytes = fixtureBytes[requested] {
          if requested == "test-fixtures/independent-reference.json" { modifyLoadedReference(&bytes) }
          return bytes
        }
        return try load(requested)
      })
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
