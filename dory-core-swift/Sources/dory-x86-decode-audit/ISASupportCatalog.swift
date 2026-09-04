import CryptoKit
import Foundation
import zlib

struct ISAEvidenceArtifact: Codable, Equatable {
  let path: String
  let sha256: String
}

struct ISASupportTest: Codable {
  let id: String
  let method: String
  let source: ISAEvidenceArtifact
  let firstLine: Int
  let lastLine: Int
  let excerptSHA256: String
  let passedLogLine: String
}

struct ISAExecutionCase: Codable {
  let testID: String
  let engine: String
  let outcome: String
  let description: String
  // Reviewed anchors bind the authored case to the exact, passing test method.
  // They are not an automatic proof that arbitrary Swift code executes a vector.
  let sourceAnchors: [String]
}

struct ISASupportForm: Codable {
  let vector: ISAVector
  let operandSizeAttributeBits: Int
  let addressSizeAttributeBits: Int
  let decodedOperandWidthsBits: [Int]
  let decodedAddressWidthsBits: [Int]
  let interpreterSemantics: ISAQualification
  let baselineJIT: ISAQualification
  let optimizingJIT: ISAQualification
  let flags: ISAQualification
  let faults: ISAQualification
  let executions: [ISAExecutionCase]
}

struct ISASupportSummary: Encodable {
  let id: String
  let sha256: String
  let sourceCommit: String
  let run: Int
  let receipt: ISAEvidenceArtifact
  let log: ISAEvidenceArtifact
  let manifest: ISAEvidenceArtifact
  let overlay: ISAEvidenceArtifact
  let tests: [ISASupportTest]
  let forms: [ISASupportForm]
  let verification = "Digest-verified retained receipt, passing log, source manifest and archived test bytes; current decoded form identity checked. Historical observations, not a new execution."
}

enum ISASupportError: Error, Equatable {
  case invalid(String)
}

struct ISASupportCatalog: Codable {
  let schemaVersion: Int
  let id: String
  let corpusSHA256: String
  let sourceCommit: String
  let run: Int
  let receipt: ISAEvidenceArtifact
  let log: ISAEvidenceArtifact
  let manifest: ISAEvidenceArtifact
  let overlay: ISAEvidenceArtifact
  let tests: [ISASupportTest]
  let forms: [ISASupportForm]

  static let maximumArtifactBytes = 4 * 1024 * 1024
  static let maximumExpandedBytes = 16 * 1024 * 1024
  static let evidenceDirectory = "docs/virtualization/evidence/p02-correctness-2026-09-04"

  static func bundledData() throws -> Data {
    guard let url = Bundle.module.url(
      forResource: "p02-support-v1", withExtension: "json", subdirectory: "Vectors")
    else { throw ISASupportError.invalid("missing bundled support catalog") }
    return try boundedFile(url)
  }

  static func discoverEvidenceRoot(startingAt start: URL) -> URL? {
    var candidate = start.standardizedFileURL
    for _ in 0..<32 {
      if FileManager.default.fileExists(atPath: candidate.appendingPathComponent(evidenceDirectory).path) {
        return candidate
      }
      let parent = candidate.deletingLastPathComponent()
      if parent == candidate { break }
      candidate = parent
    }
    return nil
  }

  static func loader(root: URL) -> (String) throws -> Data {
    let root = root.resolvingSymlinksInPath().standardizedFileURL
    return { path in
      guard validPath(path) else { throw ISASupportError.invalid("artifact path") }
      let url = root.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
      guard url.path.hasPrefix(root.path + "/") else {
        throw ISASupportError.invalid("artifact escapes evidence root")
      }
      return try boundedFile(url)
    }
  }

  static func apply(
    data: Data, corpusSHA256: String, records: inout [ISAInventoryRecord],
    load: (String) throws -> Data
  ) throws -> ISASupportSummary {
    guard data.count <= ISAInventory.maximumCorpusBytes else {
      throw ISASupportError.invalid("catalog size")
    }
    let catalog = try JSONDecoder().decode(Self.self, from: data)
    guard catalog.schemaVersion == 1, !catalog.id.isEmpty, catalog.id.utf8.count <= 128,
      catalog.corpusSHA256 == corpusSHA256, validHex(catalog.sourceCommit, length: 40),
      catalog.run > 0, (1...64).contains(catalog.tests.count),
      (1...256).contains(catalog.forms.count),
      Set(catalog.tests.map(\.id)).count == catalog.tests.count,
      Set(catalog.forms.map { $0.vector.id }).count == catalog.forms.count
    else { throw ISASupportError.invalid("catalog header or duplicate identity") }

    // Verify the parent artifacts themselves, not merely a path or an excerpt.
    let receiptData = try verified(catalog.receipt, load: load)
    let logData = try gunzip(verified(catalog.log, load: load))
    let manifestData = try gunzip(verified(catalog.manifest, load: load))
    let tar = try gunzip(verified(catalog.overlay, load: load))
    let receipt = try object(receiptData)
    guard receipt["sourceCommit"] as? String == catalog.sourceCommit,
      let host = receipt["host"] as? [String: Any], host["architecture"] as? String == "arm64",
      let runs = receipt["runs"] as? [[String: Any]],
      let run = runs.first(where: { $0["run"] as? Int == catalog.run }),
      run["exitCode"] as? Int == 0,
      let binding = run["sourceBinding"] as? [String: Any],
      binding["comparisonCommit"] as? String == catalog.sourceCommit,
      binding["baseAndOverlayReconstructionPassed"] as? Bool == true,
      let differences = binding["trackedDifferences"] as? [Any], differences.isEmpty,
      artifact(run["log"], matches: catalog.log),
      artifact(run["manifest"], matches: catalog.manifest),
      artifact(run["overlay"], matches: catalog.overlay),
      let swift = run["swiftTesting"] as? [String: Any], swift["failed"] as? Int == 0,
      let logText = String(data: logData, encoding: .utf8),
      let fileEntries = try object(manifestData)["files"] as? [[String: Any]]
    else { throw ISASupportError.invalid("passing source-bound run") }

    let logLines = logText.components(separatedBy: "\n")
    var excerpts: [String: String] = [:]
    for test in catalog.tests {
      guard !test.id.isEmpty, test.id.utf8.count <= 128,
        !test.method.isEmpty, test.method.utf8.count <= 256,
        !test.method.contains("\n"), !test.method.contains("("),
        validPath(test.source.path), validHex(test.source.sha256, length: 64),
        fileEntries.filter({ artifact($0, matches: test.source) }).count == 1,
        let source = try tarFile(test.source.path, in: tar), sha256(source) == test.source.sha256,
        let text = String(data: source, encoding: .utf8),
        test.firstLine > 0, test.lastLine >= test.firstLine,
        test.lastLine - test.firstLine < 1024
      else { throw ISASupportError.invalid("test source identity: \(test.id)") }
      let lines = text.components(separatedBy: "\n")
      guard test.lastLine <= lines.count else { throw ISASupportError.invalid("test excerpt range") }
      let excerpt = lines[(test.firstLine - 1)..<test.lastLine].joined(separator: "\n") + "\n"
      guard sha256(Data(excerpt.utf8)) == test.excerptSHA256,
        lines[test.firstLine - 1].contains("@Test func \(test.method)()"),
        !test.passedLogLine.contains("\n"),
        logLines.filter({ $0 == test.passedLogLine }).count == 1,
        test.passedLogLine.range(
          of: "^\\S+  Test " + NSRegularExpression.escapedPattern(for: test.method)
            + "\\(\\) passed after [0-9]+\\.[0-9]+ seconds\\.$", options: .regularExpression) != nil
      else { throw ISASupportError.invalid("passed test/excerpt identity: \(test.id)") }
      excerpts[test.id] = excerpt
    }

    // Apply only after every parent artifact has been verified. The decoder must
    // still agree with the exact catalog identity, including sizes and prefixes.
    var updated = records
    for form in catalog.forms {
      guard let index = updated.firstIndex(where: { $0.vector.id == form.vector.id }) else {
        throw ISASupportError.invalid("unknown vector: \(form.vector.id)")
      }
      let record = updated[index]
      guard record.vector == form.vector, record.expectationMismatches.isEmpty,
        record.decodedInstruction?.operation == form.vector.expectedOperation,
        record.decodedInstruction?.prefixes == form.vector.expectedPrefixes,
        record.operandSizeAttributeBits == form.operandSizeAttributeBits,
        record.addressSizeAttributeBits == form.addressSizeAttributeBits,
        record.decodedOperandWidthsBits == form.decodedOperandWidthsBits,
        record.decodedAddressWidthsBits == form.decodedAddressWidthsBits,
        !form.executions.isEmpty, form.executions.count <= 8
      else { throw ISASupportError.invalid("decoded form identity: \(form.vector.id)") }
      var executionKeys = Set<String>()
      for execution in form.executions {
        guard let excerpt = excerpts[execution.testID],
          ["interpreter", "baselineJIT", "optimizingJIT"].contains(execution.engine),
          ["retired", "faulted"].contains(execution.outcome),
          executionKeys.insert(execution.testID + ":" + execution.engine).inserted,
          !execution.description.isEmpty, execution.description.utf8.count <= 2048,
          (1...16).contains(execution.sourceAnchors.count),
          execution.sourceAnchors.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 2048 && excerpt.contains($0) })
        else { throw ISASupportError.invalid("executed case identity: \(form.vector.id)") }
      }
      for (qualification, engine) in [
        (form.interpreterSemantics, "interpreter"), (form.baselineJIT, "baselineJIT"),
        (form.optimizingJIT, "optimizingJIT"), (form.flags, ""), (form.faults, ""),
      ] {
        guard ["supported", "unsupported", "unmeasured"].contains(qualification.status),
          !qualification.scope.isEmpty, qualification.scope.utf8.count <= 2048,
          Set(qualification.evidence).count == qualification.evidence.count,
          qualification.status == "unmeasured" ? qualification.evidence.isEmpty
            : (!qualification.evidence.isEmpty && qualification.evidence.allSatisfy({ id in
              form.executions.contains { $0.testID == id && (engine.isEmpty || $0.engine == engine) }
            }))
        else { throw ISASupportError.invalid("qualification evidence: \(form.vector.id)") }
        if !engine.isEmpty {
          let observations = form.executions.filter { $0.engine == engine }
          guard observations.isEmpty || qualification.status != "unmeasured",
            qualification.status != "supported" || observations.contains(where: { $0.outcome == "retired" }),
            qualification.status != "unsupported" || observations.allSatisfy({ $0.outcome == "faulted" })
          else { throw ISASupportError.invalid("execution outcome/qualification: \(form.vector.id)") }
        }
      }
      guard form.faults.status != "supported" || form.executions.contains(where: { $0.outcome == "faulted" }),
        form.flags.status != "supported" || form.executions.contains(where: { $0.outcome == "retired" })
      else { throw ISASupportError.invalid("flags/fault observation: \(form.vector.id)") }
      updated[index].interpreterSemantics = form.interpreterSemantics
      updated[index].jitSupport.baseline = form.baselineJIT
      updated[index].jitSupport.optimizing = form.optimizingJIT
      updated[index].flags = form.flags
      updated[index].faults = form.faults
      updated[index].executedFormCount = form.executions.contains { $0.outcome == "retired" } ? 1 : 0
      updated[index].faultAttemptFormCount = form.executions.contains { $0.outcome == "faulted" } ? 1 : 0
    }
    records = updated
    return .init(
      id: catalog.id, sha256: sha256(data), sourceCommit: catalog.sourceCommit, run: catalog.run,
      receipt: catalog.receipt, log: catalog.log, manifest: catalog.manifest, overlay: catalog.overlay,
      tests: catalog.tests, forms: catalog.forms)
  }

  private static func artifact(_ object: Any?, matches expected: ISAEvidenceArtifact) -> Bool {
    guard let value = object as? [String: Any] else { return false }
    return value["path"] as? String == expected.path && value["sha256"] as? String == expected.sha256
  }

  private static func object(_ data: Data) throws -> [String: Any] {
    guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw ISASupportError.invalid("JSON object")
    }
    return value
  }

  static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func verified(_ artifact: ISAEvidenceArtifact, load: (String) throws -> Data) throws -> Data {
    guard validPath(artifact.path), validHex(artifact.sha256, length: 64) else {
      throw ISASupportError.invalid("artifact identity")
    }
    let data = try load(artifact.path)
    guard data.count <= maximumArtifactBytes, sha256(data) == artifact.sha256 else {
      throw ISASupportError.invalid("artifact digest: \(artifact.path)")
    }
    return data
  }

  private static func boundedFile(_ url: URL) throws -> Data {
    let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
    guard values.isRegularFile == true, let size = values.fileSize,
      size <= maximumArtifactBytes else { throw ISASupportError.invalid("artifact size/type") }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: maximumArtifactBytes + 1) ?? Data()
    guard data.count <= maximumArtifactBytes else { throw ISASupportError.invalid("artifact size") }
    return data
  }

  private static func validPath(_ path: String) -> Bool {
    !path.isEmpty && path.utf8.count <= 1024 && !path.hasPrefix("/") && !path.contains("\\")
      && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
        !$0.isEmpty && $0 != "." && $0 != ".."
      }
  }

  private static func validHex(_ value: String, length: Int) -> Bool {
    value.utf8.count == length && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }

  private static func gunzip(_ input: Data) throws -> Data {
    guard input.count >= 18 else { throw ISASupportError.invalid("gzip header") }
    let size = input.suffix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
    guard size > 0, size <= maximumExpandedBytes else { throw ISASupportError.invalid("expanded artifact size") }
    var output = Data(count: Int(size))
    var stream = z_stream()
    guard inflateInit2_(&stream, MAX_WBITS + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK
    else { throw ISASupportError.invalid("gzip initialization") }
    defer { inflateEnd(&stream) }
    let result = input.withUnsafeBytes { inputBytes in
      output.withUnsafeMutableBytes { outputBytes in
        stream.next_in = UnsafeMutablePointer(mutating: inputBytes.bindMemory(to: Bytef.self).baseAddress!)
        stream.avail_in = uInt(inputBytes.count)
        stream.next_out = outputBytes.bindMemory(to: Bytef.self).baseAddress!
        stream.avail_out = uInt(outputBytes.count)
        return inflate(&stream, Z_FINISH)
      }
    }
    guard result == Z_STREAM_END, stream.total_out == size, stream.avail_out == 0, stream.avail_in == 0
    else { throw ISASupportError.invalid("gzip contents") }
    return output
  }

  // Read a regular file in a digest-verified retained tar without extracting anything
  // to disk. Our three source paths fit the ustar name/prefix fields; extended names
  // are deliberately not interpreted as source identities.
  private static func tarFile(_ path: String, in data: Data) throws -> Data? {
    var offset = 0
    var found: Data?
    while offset <= data.count - 512 {
      let header = data.subdata(in: offset..<(offset + 512))
      if header.allSatisfy({ $0 == 0 }) { break }
      func field(_ range: Range<Int>) -> String {
        String(decoding: header[range].prefix { $0 != 0 }, as: UTF8.self)
      }
      guard let size = Int(field(124..<136).trimmingCharacters(in: .whitespaces), radix: 8),
        size >= 0, size <= data.count - offset - 512
      else { throw ISASupportError.invalid("tar entry bounds") }
      let prefix = field(345..<500)
      let name = (prefix.isEmpty ? "" : prefix + "/") + field(0..<100)
      if name == path {
        guard found == nil, header[156] == 0 || header[156] == 48 else {
          throw ISASupportError.invalid("tar source entry type/duplicate")
        }
        found = data.subdata(in: (offset + 512)..<(offset + 512 + size))
      }
      offset += 512 + ((size + 511) / 512) * 512
    }
    return found
  }
}
