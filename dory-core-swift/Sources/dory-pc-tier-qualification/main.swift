import DoryPCQualification
import Foundation

private enum CLIError: Error, CustomStringConvertible {
  case usage(String)

  var description: String {
    switch self {
    case .usage(let message): message
    }
  }
}

private func parseArguments() throws -> ([DoryPCQualificationTier: URL], URL?) {
  let names: [String: DoryPCQualificationTier] = [
    "--interpreter-receipt": .interpreter,
    "--baseline-jit-receipt": .baselineJIT,
    "--optimizing-jit-receipt": .optimizingJIT,
  ]
  var receipts: [DoryPCQualificationTier: URL] = [:]
  var output: URL?
  var index = 1
  while index < CommandLine.arguments.count {
    guard index + 1 < CommandLine.arguments.count else {
      throw CLIError.usage("missing value for \(CommandLine.arguments[index])")
    }
    let option = CommandLine.arguments[index]
    let value = CommandLine.arguments[index + 1]
    guard value.hasPrefix("/"), value != "/", !value.utf8.contains(0) else {
      throw CLIError.usage("paths must be absolute and narrowly scoped")
    }
    let url = URL(fileURLWithPath: value).standardizedFileURL
    if option == "--output" {
      guard output == nil else { throw CLIError.usage("duplicate --output") }
      output = url
    } else if let tier = names[option] {
      guard receipts.updateValue(url, forKey: tier) == nil else {
        throw CLIError.usage("duplicate \(option)")
      }
    } else {
      throw CLIError.usage("unknown option: \(option)")
    }
    index += 2
  }
  return (receipts, output)
}

do {
  let (receiptURLs, outputURL) = try parseArguments()
  var receiptData: [DoryPCQualificationTier: Data] = [:]
  for tier in DoryPCQualificationTier.allCases {
    guard let url = receiptURLs[tier] else {
      throw CLIError.usage(
        "missing --\(tier == .interpreter ? "interpreter" : tier == .baselineJIT ? "baseline-jit" : "optimizing-jit")-receipt"
      )
    }
    receiptData[tier] = try Data(contentsOf: url, options: [.mappedIfSafe])
  }
  let receipt = try DoryPCUEFITierQualifier.qualify(receiptData: receiptData)
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  let data = try encoder.encode(receipt) + Data("\n".utf8)
  if let outputURL {
    try data.write(to: outputURL, options: [.atomic])
  } else {
    FileHandle.standardOutput.write(data)
  }
} catch {
  FileHandle.standardError.write(Data("dory-pc-tier-qualification: \(error)\n".utf8))
  exit(2)
}
