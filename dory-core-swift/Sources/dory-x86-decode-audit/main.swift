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

private enum AuditError: Error, CustomStringConvertible {
  case usage
  case noInputs(String)
  case objdumpFailed(path: String, status: Int32, stderr: String)

  var description: String {
    switch self {
    case .usage:
      "usage: dory-x86-decode-audit [--mode real16|protected16|protected32|long64] <module-or-directory> [...]"
    case .noInputs(let path):
      "no .debug modules found at \(path)"
    case .objdumpFailed(let path, let status, let stderr):
      "llvm-objdump failed for \(path) with status \(status): \(stderr)"
    }
  }
}

@main
private enum DoryX86DecodeAudit {
  static func main() throws {
    let (mode, inputArguments) = try arguments(Array(CommandLine.arguments.dropFirst()))
    let inputs = try inputArguments.flatMap(resolveModules)
    guard !inputs.isEmpty else {
      throw AuditError.noInputs(inputArguments.joined(separator: ", "))
    }

    let decoder = DoryX86Decoder()
    var result = AuditResult()
    for input in inputs {
      let output = try disassemble(input)
      audit(output, mode: mode, decoder: decoder, result: &result)
    }

    print("mode: \(mode.rawValue)")
    print("modules: \(inputs.count)")
    print("decoded: \(result.decoded)/\(result.total)")
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
  ) throws -> (DoryX86ExecutionMode, [String]) {
    var mode = DoryX86ExecutionMode.long64
    var inputs: [String] = []
    var index = 0
    while index < values.count {
      if values[index] == "--mode" {
        guard index + 1 < values.count,
          let requestedMode = DoryX86ExecutionMode(rawValue: values[index + 1])
        else {
          throw AuditError.usage
        }
        mode = requestedMode
        index += 2
      } else if values[index].hasPrefix("-") {
        throw AuditError.usage
      } else {
        inputs.append(values[index])
        index += 1
      }
    }
    guard !inputs.isEmpty else { throw AuditError.usage }
    return (mode, inputs)
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

  private static func disassemble(_ path: String) throws -> String {
    let process = Process()
    let output = Pipe()
    let errors = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["llvm-objdump", "-d", path]
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
    decoder: DoryX86Decoder,
    result: inout AuditResult
  ) {
    for line in disassembly.split(separator: "\n") {
      let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
      guard fields.count >= 2,
        let colon = fields[0].firstIndex(of: ":")
      else { continue }

      let byteFields = fields[0][fields[0].index(after: colon)...]
        .split(whereSeparator: { $0 == " " })
      let bytes = byteFields.compactMap { UInt8($0, radix: 16) }
      guard !bytes.isEmpty, bytes.count == byteFields.count else { continue }

      let mnemonic = fields[1].trimmingCharacters(in: .whitespaces)
      guard !mnemonic.isEmpty else { continue }
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
          continue
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
