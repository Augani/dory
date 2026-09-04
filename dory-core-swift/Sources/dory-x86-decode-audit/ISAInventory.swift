import CryptoKit
import DoryDBTX86
import Foundation

struct ISAReference: Codable, Equatable {
  let id: String
  let title: String
  let url: String
}

struct ISAVector: Codable, Equatable {
  let id: String
  let name: String
  let form: String
  let mode: DoryX86ExecutionMode
  let bytes: [UInt8]
  let referenceIDs: [String]
  let expectedPrefixes: DoryX86InstructionPrefixes
  let expectedOperation: DoryX86InstructionOperation?
  let expectedErrorCategory: String?
}

struct ISACorpus: Codable {
  let schemaVersion: Int
  let id: String
  let scope: String
  let references: [ISAReference]
  let vectors: [ISAVector]
}

struct ISAQualification: Codable, Equatable {
  var status = "unmeasured"
  var evidence: [String] = []
  var scope = "No verified execution evidence for this exact form."
}

struct ISAJITQualification: Encodable {
  var baseline = ISAQualification()
  var optimizing = ISAQualification()
}

struct ISAInventoryRecord: Encodable {
  // Keep the authored vector intact even if the decoder rejects it.
  let vector: ISAVector
  let operandSizeAttributeBits: Int
  let addressSizeAttributeBits: Int
  let sizeAttributeSource: String
  let decodedInstruction: DoryX86DecodedInstruction?
  let decodedOperandWidthsBits: [Int]
  let decodedAddressWidthsBits: [Int]
  let decoderSupport: String
  let decodeErrorCategory: String?
  let decodeError: String?
  let expectationMismatches: [String]
  var interpreterSemantics = ISAQualification()
  var jitSupport = ISAJITQualification()
  var flags = ISAQualification()
  var faults = ISAQualification()
  var executedFormCount = 0
  var faultAttemptFormCount = 0
}

struct ISAInventoryReport: Encodable {
  let schemaVersion = 2
  let corpusID: String
  let corpusSHA256: String
  let scope: String
  let references: [ISAReference]
  let formCountingRule = "One unique mode plus exact byte vector; not an architectural ISA denominator."
  let corpusVectorCount: Int
  let staticDecodedFormCount: Int
  let rejectedVectorCount: Int
  let mismatchedVectorCount: Int
  let staticBinaryInstructionCount = 0
  let executedFormCount: Int
  let faultAttemptFormCount: Int
  let currentInvocationExecutedFormCount = 0
  let physicalReferenceExecutedFormCount = 0
  let physicalReference = ISAQualification()
  let supportCatalog: ISASupportSummary?
  let executionMeasurement = "Historical, exact-form test evidence only; this invocation executes no guest instructions. Fault attempts are counted separately from retired forms."
  let qualification = "Each annotation is limited to its recorded case and source revision. Uncovered dimensions remain unmeasured; no full ISA, current-source, physical-reference or release qualification is implied."
  let records: [ISAInventoryRecord]
}

enum ISAInventoryError: Error, Equatable {
  case missingBundledCorpus
  case corpusTooLarge
  case invalidCorpus(String)
}

enum ISAInventory {
  static let maximumCorpusBytes = 2 * 1024 * 1024
  static let maximumVectorCount = 4096

  static func bundledCorpusData() throws -> Data {
    guard let url = Bundle.module.url(
      forResource: "p02-isa-v1", withExtension: "json", subdirectory: "Vectors")
    else { throw ISAInventoryError.missingBundledCorpus }
    guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
      size <= maximumCorpusBytes
    else { throw ISAInventoryError.corpusTooLarge }
    return try Data(contentsOf: url)
  }

  static func parse(_ data: Data) throws -> ISACorpus {
    guard data.count <= maximumCorpusBytes else { throw ISAInventoryError.corpusTooLarge }
    let corpus = try JSONDecoder().decode(ISACorpus.self, from: data)
    guard corpus.schemaVersion == 1,
      !corpus.id.isEmpty, corpus.id.utf8.count <= 128,
      !corpus.scope.isEmpty, corpus.scope.utf8.count <= 2048,
      !corpus.vectors.isEmpty, corpus.vectors.count <= maximumVectorCount,
      !corpus.references.isEmpty, corpus.references.count <= 32
    else { throw ISAInventoryError.invalidCorpus("header or record count") }
    let referenceIDs = Set(corpus.references.map(\.id))
    guard referenceIDs.count == corpus.references.count,
      corpus.references.allSatisfy({
        !$0.id.isEmpty && !$0.title.isEmpty && $0.url.hasPrefix("https://")
          && $0.url.utf8.count <= 2048
      })
    else { throw ISAInventoryError.invalidCorpus("references") }
    var ids = Set<String>()
    var byteForms = Set<String>()
    let errorCategories: Set<String> = ["invalidEncoding", "unsupportedOpcode", "truncated", "instructionTooLong"]
    for vector in corpus.vectors {
      let byteForm = vector.mode.rawValue + ":" + vector.bytes.map { String(format: "%02x", $0) }.joined()
      guard !vector.id.isEmpty, vector.id.utf8.count <= 128,
        !vector.name.isEmpty, vector.name.utf8.count <= 256,
        !vector.form.isEmpty, vector.form.utf8.count <= 128,
        !vector.bytes.isEmpty, vector.bytes.count <= 15,
        ids.insert(vector.id).inserted, byteForms.insert(byteForm).inserted,
        !vector.referenceIDs.isEmpty, Set(vector.referenceIDs).isSubset(of: referenceIDs),
        (vector.expectedOperation != nil) != (vector.expectedErrorCategory != nil),
        vector.expectedErrorCategory.map(errorCategories.contains) ?? true
      else { throw ISAInventoryError.invalidCorpus("vector \(vector.id)") }
    }
    return corpus
  }

  static func report(
    data: Data, decoder: DoryX86Decoder = .init(), supportCatalogData: Data? = nil,
    evidenceLoader: ((String) throws -> Data)? = nil
  ) throws -> ISAInventoryReport {
    let corpus = try parse(data)
    var records = try corpus.vectors.sorted { $0.id < $1.id }.map { vector in
      try record(vector: vector, decoder: decoder)
    }
    let corpusDigest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    var support: ISASupportSummary?
    if let supportCatalogData {
      guard let evidenceLoader else { throw ISASupportError.invalid("missing evidence root") }
      support = try ISASupportCatalog.apply(
        data: supportCatalogData, corpusSHA256: corpusDigest,
        records: &records, load: evidenceLoader)
    }
    return .init(
      corpusID: corpus.id,
      corpusSHA256: corpusDigest,
      scope: corpus.scope,
      references: corpus.references.sorted { $0.id < $1.id },
      corpusVectorCount: records.count,
      staticDecodedFormCount: records.filter { $0.decodedInstruction != nil }.count,
      rejectedVectorCount: records.filter { $0.decodedInstruction == nil }.count,
      mismatchedVectorCount: records.filter { !$0.expectationMismatches.isEmpty }.count,
      executedFormCount: records.reduce(0) { $0 + $1.executedFormCount },
      faultAttemptFormCount: records.reduce(0) { $0 + $1.faultAttemptFormCount },
      supportCatalog: support,
      records: records)
  }

  static func json(_ report: ISAInventoryReport) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(report)
  }

  private static func record(vector: ISAVector, decoder: DoryX86Decoder) throws -> ISAInventoryRecord {
    var instruction: DoryX86DecodedInstruction?
    var errorCategory: String?
    var errorDescription: String?
    do {
      instruction = try decoder.decode(vector.bytes, at: 0, mode: vector.mode)
    } catch let error as DoryX86DecodeError {
      switch error {
      case .invalidEncoding: errorCategory = "invalidEncoding"
      case .unsupportedOpcode: errorCategory = "unsupportedOpcode"
      case .truncated: errorCategory = "truncated"
      case .instructionTooLong: errorCategory = "instructionTooLong"
      }
      errorDescription = error.description
    } catch {
      errorCategory = "unexpectedError"
      errorDescription = String(describing: error)
    }
    var mismatches: [String] = []
    if instruction?.operation != vector.expectedOperation { mismatches.append("operation") }
    if errorCategory != vector.expectedErrorCategory { mismatches.append("errorCategory") }
    if let instruction {
      if instruction.bytes != vector.bytes { mismatches.append("bytesOrLength") }
      if instruction.prefixes != vector.expectedPrefixes { mismatches.append("prefixes") }
    }
    let support: String
    switch instruction?.operation {
    case .undefinedInstruction?: support = "undefinedInstruction"
    case .unsupportedSystemInstruction?: support = "recognizedUnsupported"
    case nil: support = "rejected"
    default: support = "recognized"
    }
    var operandWidths = Set<Int>()
    var addressWidths = Set<Int>()
    if let instruction {
      // Include operand-specific sizes as well as the default size attributes.
      // Implicit operands may have no serialized width; the full operation remains visible.
      let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(instruction.operation))
      collectWidths(object, operandWidths: &operandWidths, addressWidths: &addressWidths)
    }
    let prefixes = instruction?.prefixes ?? vector.expectedPrefixes
    let defaultWord = vector.mode == .real16 || vector.mode == .protected16
    let operandSize = vector.mode == .long64 && prefixes.rex?.w == true ? 64
      : (prefixes.operandSizeOverride ? (defaultWord ? 32 : 16) : (defaultWord ? 16 : 32))
    let addressSize: Int
    switch (vector.mode, prefixes.addressSizeOverride) {
    case (.real16, false), (.protected16, false), (.protected32, true): addressSize = 16
    case (.long64, false): addressSize = 64
    default: addressSize = 32
    }
    return .init(
      vector: vector, operandSizeAttributeBits: operandSize, addressSizeAttributeBits: addressSize,
      sizeAttributeSource: instruction == nil ? "reference prefixes; decode rejected" : "decoded prefixes",
      decodedInstruction: instruction, decodedOperandWidthsBits: operandWidths.sorted(),
      decodedAddressWidthsBits: addressWidths.sorted(), decoderSupport: support,
      decodeErrorCategory: errorCategory, decodeError: errorDescription,
      expectationMismatches: mismatches)
  }

  private static func collectWidths(
    _ value: Any, operandWidths: inout Set<Int>, addressWidths: inout Set<Int>
  ) {
    if let object = value as? [String: Any] {
      for (key, child) in object {
        if key == "width", let width = child as? Int { operandWidths.insert(width) }
        if key == "addressWidth", let width = child as? Int { addressWidths.insert(width) }
        collectWidths(child, operandWidths: &operandWidths, addressWidths: &addressWidths)
      }
    } else if let array = value as? [Any] {
      for child in array { collectWidths(child, operandWidths: &operandWidths, addressWidths: &addressWidths) }
    }
  }
}
