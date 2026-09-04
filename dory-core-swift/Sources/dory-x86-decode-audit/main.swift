import DoryDBTX86
import Foundation

private struct AuditFailure: Hashable {
  let mnemonic: String
  let bytes: String
  let reason: String
}

private struct AuditResult {
  var decoded = 0
  var total = 0
  var failures: [AuditFailure: Int] = [:]
}

private struct AuditOptions {
  let inventory: Bool
  let evidenceRoot: String?
  let mode: DoryX86ExecutionMode
  let inputArguments: [String]
  let startAddress: UInt64?
  let stopAddress: UInt64?
  let skipUnknownMnemonics: Bool
}

private enum AuditError: Error, CustomStringConvertible {
  case usage
  case noInputs(String)
  case objdumpFailed(path: String, status: Int32, stderr: String)

  var description: String {
    switch self {
    case .usage:
      "usage: dory-x86-decode-audit --inventory [--evidence-root <checkout>] (bounded corpus JSON; no execution)\n"
        + "   or: dory-x86-decode-audit [--mode real16|protected16|protected32|long64] "
        + "[--start-address <integer>] [--stop-address <integer>] [--skip-unknown-mnemonics] "
        + "<module-or-directory> [...]"
    case .noInputs(let path):
      "no .debug modules found at \(path)"
    case .objdumpFailed(let path, let status, let stderr):
      "llvm-objdump failed for \(path) with status \(status): \(stderr)"
    }
  }
}

private enum DoryX86DecodeAudit {
  static func main() throws {
    let options = try arguments(Array(CommandLine.arguments.dropFirst()))
    if options.inventory {
      let root = options.evidenceRoot.map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? ISASupportCatalog.discoverEvidenceRoot(
          startingAt: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
      let report = try ISAInventory.report(
        data: ISAInventory.bundledCorpusData(),
        supportCatalogData: root == nil ? nil : ISASupportCatalog.bundledData(),
        evidenceLoader: root.map { ISASupportCatalog.loader(root: $0) })
      FileHandle.standardOutput.write(try ISAInventory.json(report))
      FileHandle.standardOutput.write(Data([0x0A]))
      if report.mismatchedVectorCount != 0 { Foundation.exit(EXIT_FAILURE) }
      return
    }
    let inputs = try options.inputArguments.flatMap(resolveModules)
    guard !inputs.isEmpty else {
      throw AuditError.noInputs(options.inputArguments.joined(separator: ", "))
    }

    let decoder = DoryX86Decoder()
    var result = AuditResult()
    for input in inputs {
      let output = try disassemble(input, options: options)
      audit(
        output,
        mode: options.mode,
        skipUnknownMnemonics: options.skipUnknownMnemonics,
        decoder: decoder,
        result: &result
      )
    }

    print("mode: \(options.mode.rawValue)")
    print("modules: \(inputs.count)")
    print("static binary decoded: \(result.decoded)/\(result.total)")
    print("executed forms: 0 (not measured; decoder-only audit)")
    print("interpreter/JIT/flags/fault qualification: unmeasured")
    print("unique failures: \(result.failures.count)")

    for (failure, count) in result.failures.sorted(by: failureOrder) {
      print("\(count)\t\(failure.mnemonic)\t\(failure.bytes)\t\(failure.reason)")
    }

    if !result.failures.isEmpty {
      Foundation.exit(EXIT_FAILURE)
    }
  }

  private static func arguments(
    _ values: [String]
  ) throws -> AuditOptions {
    var mode = DoryX86ExecutionMode.long64
    var inventory = false
    var evidenceRoot: String?
    var modeSpecified = false
    var inputs: [String] = []
    var startAddress: UInt64?
    var stopAddress: UInt64?
    var skipUnknownMnemonics = false
    var index = 0
    while index < values.count {
      if values[index] == "--inventory" {
        inventory = true
        index += 1
      } else if values[index] == "--evidence-root" {
        guard evidenceRoot == nil, index + 1 < values.count, !values[index + 1].isEmpty else {
          throw AuditError.usage
        }
        evidenceRoot = values[index + 1]
        index += 2
      } else if values[index] == "--mode" {
        guard index + 1 < values.count,
          let requestedMode = DoryX86ExecutionMode(rawValue: values[index + 1])
        else {
          throw AuditError.usage
        }
        mode = requestedMode
        modeSpecified = true
        index += 2
      } else if values[index] == "--start-address" || values[index] == "--stop-address" {
        guard index + 1 < values.count, let address = integer(values[index + 1]) else {
          throw AuditError.usage
        }
        if values[index] == "--start-address" {
          startAddress = address
        } else {
          stopAddress = address
        }
        index += 2
      } else if values[index] == "--skip-unknown-mnemonics" {
        skipUnknownMnemonics = true
        index += 1
      } else if values[index].hasPrefix("-") {
        throw AuditError.usage
      } else {
        inputs.append(values[index])
        index += 1
      }
    }
    if inventory {
      guard inputs.isEmpty, !modeSpecified, startAddress == nil, stopAddress == nil,
        !skipUnknownMnemonics
      else { throw AuditError.usage }
    } else {
      guard !inputs.isEmpty, evidenceRoot == nil else { throw AuditError.usage }
    }
    if let startAddress, let stopAddress, startAddress >= stopAddress {
      throw AuditError.usage
    }
    return AuditOptions(
      inventory: inventory,
      evidenceRoot: evidenceRoot,
      mode: mode,
      inputArguments: inputs,
      startAddress: startAddress,
      stopAddress: stopAddress,
      skipUnknownMnemonics: skipUnknownMnemonics
    )
  }

  private static func integer(_ text: String) -> UInt64? {
    if text.hasPrefix("0x") || text.hasPrefix("0X") {
      return UInt64(text.dropFirst(2), radix: 16)
    }
    return UInt64(text)
  }

  private static func resolveModules(_ path: String) throws -> [String] {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
      throw AuditError.noInputs(path)
    }
    guard isDirectory.boolValue else { return [path] }

    return try FileManager.default.contentsOfDirectory(atPath: path)
      .filter { $0.hasSuffix(".debug") }
      .sorted()
      .map { URL(fileURLWithPath: path).appendingPathComponent($0).path }
  }

  private static func disassemble(_ path: String, options: AuditOptions) throws -> String {
    let process = Process()
    let output = Pipe()
    let errors = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    var arguments = ["llvm-objdump", "-d"]
    if let startAddress = options.startAddress {
      arguments.append("--start-address=0x\(String(startAddress, radix: 16))")
    }
    if let stopAddress = options.stopAddress {
      arguments.append("--stop-address=0x\(String(stopAddress, radix: 16))")
    }
    arguments.append(path)
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    let stdout = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    let stderr = String(
      decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    guard process.terminationStatus == 0 else {
      throw AuditError.objdumpFailed(
        path: path,
        status: process.terminationStatus,
        stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines)
      )
    }
    return String(decoding: stdout, as: UTF8.self)
  }

  private static func audit(
    _ disassembly: String,
    mode: DoryX86ExecutionMode,
    skipUnknownMnemonics: Bool,
    decoder: DoryX86Decoder,
    result: inout AuditResult
  ) {
    var pendingLock: (address: UInt64, bytes: [UInt8])?
    for line in disassembly.split(separator: "\n") {
      let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
      guard fields.count >= 2,
        let colon = fields[0].firstIndex(of: ":"),
        let instructionAddress = UInt64(
          fields[0][..<colon].trimmingCharacters(in: .whitespaces),
          radix: 16
        )
      else { continue }

      // Two objdump layouts appear in the wild:
      //   GNU binutils:  "  address: 55 89 e5\tpush\t%rbp"  (bytes share the address field)
      //   llvm-objdump:  "address:\t55 89 e5\tpush\t%rbp"   (bytes in their own tab field)
      // Pick the bytes from whichever field actually holds them, then take the mnemonic from
      // the field that follows the bytes.
      let addressSuffix = fields[0][fields[0].index(after: colon)...]
        .trimmingCharacters(in: .whitespaces)
      let bytesField: Substring
      let mnemonicField: Substring
      if addressSuffix.isEmpty {
        // llvm-objdump layout: fields = [address:, bytes, mnemonic, operands...]
        guard fields.count >= 3 else { continue }
        bytesField = fields[1]
        mnemonicField = fields[2]
      } else {
        // GNU binutils layout: fields = [address: bytes, mnemonic, operands...]
        bytesField = Substring(addressSuffix)
        mnemonicField = fields[1]
      }
      let byteFields = bytesField.split(whereSeparator: { $0 == " " })
      var bytes = byteFields.compactMap { UInt8($0, radix: 16) }
      guard !bytes.isEmpty, bytes.count == byteFields.count else { continue }

      var mnemonic = mnemonicField.trimmingCharacters(in: .whitespaces)
      guard !mnemonic.isEmpty else { continue }

      // llvm-objdump renders LOCK as a standalone one-byte record and the opcode as the next
      // contiguous record. Reassemble those bytes so the audit checks the real architectural
      // instruction, including whether Dory accepts LOCK for that exact operand.
      if bytes == [0xF0], mnemonic == "lock" {
        if let pendingLock {
          auditInstruction(
            mnemonic: "lock",
            bytes: pendingLock.bytes,
            mode: mode,
            decoder: decoder,
            result: &result
          )
        }
        pendingLock = (instructionAddress, bytes)
        continue
      }
      let unknownMnemonic = mnemonic == "<unknown>"
      if let pending = pendingLock {
        if instructionAddress == pending.address + UInt64(pending.bytes.count) {
          bytes = pending.bytes + bytes
          mnemonic = "lock \(mnemonic)"
        } else {
          auditInstruction(
            mnemonic: "lock",
            bytes: pending.bytes,
            mode: mode,
            decoder: decoder,
            result: &result
          )
        }
        pendingLock = nil
      }
      if skipUnknownMnemonics, unknownMnemonic { continue }
      auditInstruction(
        mnemonic: mnemonic,
        bytes: bytes,
        mode: mode,
        decoder: decoder,
        result: &result
      )
    }
    if let pendingLock {
      auditInstruction(
        mnemonic: "lock",
        bytes: pendingLock.bytes,
        mode: mode,
        decoder: decoder,
        result: &result
      )
    }
  }

  private static func auditInstruction(
    mnemonic: String,
    bytes: [UInt8],
    mode: DoryX86ExecutionMode,
    decoder: DoryX86Decoder,
    result: inout AuditResult
  ) {
    result.total += 1
    do {
      let instruction = try decoder.decode(bytes, at: 0, mode: mode)
      guard instruction.length == bytes.count else {
        record(
          mnemonic: mnemonic,
          bytes: bytes,
          reason: "decoded length \(instruction.length), expected \(bytes.count)",
          result: &result
        )
        return
      }
      result.decoded += 1
    } catch {
      record(
        mnemonic: mnemonic,
        bytes: bytes,
        reason: String(describing: error),
        result: &result
      )
    }
  }

  private static func record(
    mnemonic: String,
    bytes: [UInt8],
    reason: String,
    result: inout AuditResult
  ) {
    let failure = AuditFailure(
      mnemonic: mnemonic,
      bytes: bytes.map { String(format: "%02x", $0) }.joined(),
      reason: reason
    )
    result.failures[failure, default: 0] += 1
  }

  private static func failureOrder(
    _ lhs: (key: AuditFailure, value: Int),
    _ rhs: (key: AuditFailure, value: Int)
  ) -> Bool {
    if lhs.value != rhs.value { return lhs.value > rhs.value }
    if lhs.key.mnemonic != rhs.key.mnemonic { return lhs.key.mnemonic < rhs.key.mnemonic }
    return lhs.key.bytes < rhs.key.bytes
  }
}

try DoryX86DecodeAudit.main()
