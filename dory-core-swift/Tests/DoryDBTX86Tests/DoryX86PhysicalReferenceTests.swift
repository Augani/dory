import CryptoKit
import Foundation
import Testing

@testable import DoryDBTX86

@Suite struct DoryX86PhysicalReferenceTests {
  @Test func scalarCorpusMatchesSpecificationDerivedExpectations() throws {
    let corpus = try ReferenceCorpus.load()
    #expect(corpus.origin == "specification-derived")
    #expect(corpus.cases.count == 12)
    #expect(Set(corpus.cases.map(\.id)).count == corpus.cases.count)
    for vector in corpus.cases {
      let actual = try execute(vector)
      try expectMasked(actual, equals: vector.expected, masks: vector.masks)
    }
  }

  @Test func receiptImportRejectsUnqualifiedHostsAndAlteredContracts() throws {
    let corpus = try ReferenceCorpus.load()
    // This in-memory envelope exercises the parser only. It is never a hardware receipt.
    let cases = try corpus.cases.map { vector -> [String: Any] in
      var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(vector)) as? [String: Any])
      object["observedInitialRFLAGS"] = vector.initial.rflags
      object["observed"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(vector.expected))
      object["passed"] = true
      return object
    }
    let valid: [String: Any] = [
      "schemaVersion": 1, "corpus": corpus.corpus, "status": "passed", "execution": "physical-x86_64",
      "physicalAttestation": true, "sourceSHA256": try ReferenceCorpus.sourceHash(),
      "compiler": "synthetic parser test", "operator": "synthetic", "machineID": "synthetic",
      "unixTime": 1, "cases": cases,
      "host": ["machine": "x86_64", "os": "Linux", "release": "synthetic", "systemVendor": "synthetic",
        "model": "synthetic", "cpuVendor": "GenuineIntel", "cpuidLeaf1EAX": "00000001",
        "cpuidLeaf1ECX": "00000000", "translated": false, "virtualizationDetected": false,
        "factsComplete": true, "refusal": ""],
    ]
    _ = try ReferenceReceipt.validated(JSONSerialization.data(withJSONObject: valid), corpus: corpus)
    var invalid = valid
    invalid["physicalAttestation"] = false
    #expect(throws: ReferenceError.self) {
      try ReferenceReceipt.validated(JSONSerialization.data(withJSONObject: invalid), corpus: corpus)
    }
    invalid = valid
    invalid["sourceSHA256"] = String(repeating: "0", count: 64)
    #expect(throws: ReferenceError.self) {
      try ReferenceReceipt.validated(JSONSerialization.data(withJSONObject: invalid), corpus: corpus)
    }
    for field in ["translated", "virtualizationDetected"] {
      invalid = valid
      var host = try #require(valid["host"] as? [String: Any])
      host[field] = true
      invalid["host"] = host
      #expect(throws: ReferenceError.self) {
        try ReferenceReceipt.validated(JSONSerialization.data(withJSONObject: invalid), corpus: corpus)
      }
    }
    invalid = valid
    var cpuidHost = try #require(valid["host"] as? [String: Any])
    cpuidHost["cpuidLeaf1ECX"] = "80000000"
    invalid["host"] = cpuidHost
    #expect(throws: ReferenceError.self) {
      try ReferenceReceipt.validated(JSONSerialization.data(withJSONObject: invalid), corpus: corpus)
    }
    for field in ["bytes", "masks", "initial", "observedInitialRFLAGS"] {
      invalid = valid
      var altered = cases
      switch field {
      case "bytes": altered[0][field] = [0x90]
      case "observedInitialRFLAGS": altered[0][field] = "0000000000000203"
      default: altered[0][field] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ReferenceRegisters.zero))
      }
      invalid["cases"] = altered
      #expect(throws: ReferenceError.self) {
        try ReferenceReceipt.validated(JSONSerialization.data(withJSONObject: invalid), corpus: corpus)
      }
    }
  }

  // Disabled means unqualified. Only an explicitly supplied physical receipt enables this gate.
  @Test(.enabled(if: ProcessInfo.processInfo.environment["DORY_P02_X86_REFERENCE_RECEIPT"] != nil))
  func explicitlyImportedPhysicalReceiptMatchesInterpreter() throws {
    let path = try #require(ProcessInfo.processInfo.environment["DORY_P02_X86_REFERENCE_RECEIPT"])
    guard path.hasPrefix("/") else { throw ReferenceError.invalid("receipt path must be absolute") }
    let corpus = try ReferenceCorpus.load()
    let receipt = try ReferenceReceipt.validated(ReferenceCorpus.read(URL(fileURLWithPath: path)), corpus: corpus)
    for vector in receipt.cases {
      let actual = try execute(vector)
      let observed = try #require(vector.observed)
      try expectMasked(actual, equals: observed, masks: vector.masks)
    }
  }

  private func execute(_ vector: ReferenceVector) throws -> ReferenceRegisters {
    let initial = try vector.initial.values()
    let memory = try DoryX86ByteArrayMemory(baseAddress: 0x1000, bytes: vector.bytes)
    var state = try DoryX86ArchitecturalState(
      registers: .init(rax: initial[0], rcx: initial[2], rdx: initial[3], rbx: initial[1]), rip: 0x1000,
      rflags: .init(rawValue: initial[4]))
    let before = state
    guard case .retired = DoryX86Interpreter().step(state: &state, memory: memory, mode: .long64)
    else { throw ReferenceError.invalid("\(vector.id) unexpectedly faulted") }
    #expect(state.rip == 0x1000 + UInt64(vector.bytes.count))
    #expect(memory.snapshot() == vector.bytes)
    // The physical scope is RAX/RBX/RCX/RDX/RFLAGS; also check interpreter isolation.
    #expect(state.registers.rsp == before.registers.rsp)
    #expect(state.control == before.control)
    #expect(state.floatingPoint == before.floatingPoint)
    return .init(rax: hex(state.registers.rax), rbx: hex(state.registers.rbx), rcx: hex(state.registers.rcx),
      rdx: hex(state.registers.rdx), rflags: hex(state.rflags.rawValue))
  }

  private func expectMasked(_ actual: ReferenceRegisters, equals expected: ReferenceRegisters,
    masks: ReferenceRegisters) throws {
    for (value, pair) in zip(try actual.values(), zip(try expected.values(), try masks.values())) {
      #expect(value & pair.1 == pair.0 & pair.1)
    }
  }
}

private enum ReferenceError: Error { case invalid(String) }
private func hex(_ value: UInt64) -> String { String(format: "%016llx", value) }

private struct ReferenceRegisters: Codable, Equatable {
  let rax: String, rbx: String, rcx: String, rdx: String, rflags: String
  static let zero = Self(rax: hex(0), rbx: hex(0), rcx: hex(0), rdx: hex(0), rflags: hex(0))
  func values() throws -> [UInt64] {
    try [rax, rbx, rcx, rdx, rflags].map { value in
      guard value.count == 16, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
        let integer = UInt64(value, radix: 16)
      else { throw ReferenceError.invalid("invalid fixed-width hexadecimal value") }
      return integer
    }
  }
}
private struct ReferenceVector: Codable {
  let id: String, bytes: [UInt8], initial: ReferenceRegisters, expected: ReferenceRegisters, masks: ReferenceRegisters
  let observedInitialRFLAGS: String?, observed: ReferenceRegisters?, passed: Bool?
  func sameContract(as other: Self) -> Bool {
    id == other.id && bytes == other.bytes && initial == other.initial && expected == other.expected && masks == other.masks
  }
}
private struct ReferenceCorpus: Decodable {
  let schemaVersion: Int, corpus: String, origin: String, cases: [ReferenceVector]
  static var directory: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("guest/diagnostics/p02-x86-reference", isDirectory: true)
  }
  static func read(_ url: URL) throws -> Data {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular,
      let size = attributes[.size] as? NSNumber, size.intValue > 0, size.intValue <= 1_048_576
    else { throw ReferenceError.invalid("missing, nonregular or oversized reference input") }
    let data = try Data(contentsOf: url)
    guard data.count <= 1_048_576 else { throw ReferenceError.invalid("oversized reference input") }
    return data
  }
  static func load() throws -> Self {
    let corpus = try JSONDecoder().decode(Self.self, from: read(directory.appendingPathComponent("vectors.json")))
    guard corpus.schemaVersion == 1, corpus.corpus == "p02-scalar12-v1", corpus.origin == "specification-derived",
      corpus.cases.count == 12, Set(corpus.cases.map(\.id)).count == 12
    else { throw ReferenceError.invalid("unknown corpus") }
    for vector in corpus.cases {
      guard !vector.bytes.isEmpty, vector.bytes.count <= 15 else { throw ReferenceError.invalid("invalid instruction bytes") }
      _ = try vector.initial.values(); _ = try vector.expected.values(); _ = try vector.masks.values()
    }
    return corpus
  }
  static func sourceHash() throws -> String {
    var hash = SHA256()
    for name in ["reference.c", "cases.def"] { hash.update(data: try read(directory.appendingPathComponent(name))) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
}
private struct ReferenceReceipt: Decodable {
  let schemaVersion: Int, corpus: String, status: String, execution: String, physicalAttestation: Bool
  let sourceSHA256: String, compiler: String, `operator`: String, machineID: String, unixTime: Int64
  let host: Host, cases: [ReferenceVector]
  struct Host: Decodable {
    let machine: String, os: String, release: String, systemVendor: String, model: String, cpuVendor: String
    let cpuidLeaf1EAX: String, cpuidLeaf1ECX: String, translated: Bool, virtualizationDetected: Bool
    let factsComplete: Bool, refusal: String
  }
  static func validated(_ data: Data, corpus: ReferenceCorpus) throws -> Self {
    let receipt = try JSONDecoder().decode(Self.self, from: data)
    let hostNames = (receipt.host.systemVendor + " " + receipt.host.model).lowercased()
    let virtualNames = ["virtual", "vmware", "qemu", "kvm", "xen", "bochs", "hyper-v",
      "parallels", "bhyve", "openstack", "amazon ec2", "google compute", "nutanix"]
    guard receipt.schemaVersion == 1, receipt.corpus == corpus.corpus, receipt.status == "passed",
      receipt.execution == "physical-x86_64", receipt.physicalAttestation,
      receipt.sourceSHA256 == (try ReferenceCorpus.sourceHash()), !receipt.compiler.isEmpty,
      !receipt.operator.isEmpty, !receipt.machineID.isEmpty, receipt.unixTime > 0,
      receipt.host.machine == "x86_64", ["Darwin", "Linux"].contains(receipt.host.os),
      !receipt.host.release.isEmpty, !receipt.host.systemVendor.isEmpty, !receipt.host.model.isEmpty,
      !virtualNames.contains(where: { hostNames.contains($0) }),
      ["GenuineIntel", "AuthenticAMD"].contains(receipt.host.cpuVendor),
      receipt.host.factsComplete, !receipt.host.translated, !receipt.host.virtualizationDetected,
      receipt.host.refusal.isEmpty, receipt.host.cpuidLeaf1EAX.count == 8,
      UInt32(receipt.host.cpuidLeaf1EAX, radix: 16) != nil,
      receipt.host.cpuidLeaf1ECX.count == 8, let ecx = UInt32(receipt.host.cpuidLeaf1ECX, radix: 16),
      ecx & (1 << 31) == 0, receipt.cases.count == corpus.cases.count
    else { throw ReferenceError.invalid("receipt is unqualified or source/host identity differs") }
    for (actual, expected) in zip(receipt.cases, corpus.cases) {
      guard actual.sameContract(as: expected), actual.passed == true,
        actual.observedInitialRFLAGS == expected.initial.rflags, let observed = actual.observed
      else { throw ReferenceError.invalid("receipt case contract differs") }
      for (value, pair) in zip(try observed.values(), zip(try expected.expected.values(), try expected.masks.values())) {
        guard value & pair.1 == pair.0 & pair.1 else { throw ReferenceError.invalid("physical output mismatches") }
      }
    }
    return receipt
  }
}
