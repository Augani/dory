import DoryFirmware
import Foundation

private enum BundlerError: Error, CustomStringConvertible {
  case usage(String)
  case invalidUnsignedInteger(name: String, value: String)
  case invalidSecureBootPolicy(String)

  var description: String {
    switch self {
    case .usage(let message): message
    case .invalidUnsignedInteger(let name, let value):
      "invalid unsigned integer for \(name): \(value)"
    case .invalidSecureBootPolicy(let value):
      "invalid secure-boot policy: \(value)"
    }
  }
}

private struct Arguments {
  let firmwareCode: URL
  let platformConfiguration: URL
  let toolchainDescriptor: URL
  let output: URL
  let buildIdentifier: String
  let sourceRepository: String
  let sourceRevision: String
  let sourceDateEpoch: UInt64
  let secureBootPolicy: DoryFirmwareSecureBootPolicy

  init(_ raw: [String]) throws {
    var values: [String: String] = [:]
    var index = 0
    while index < raw.count {
      let name = raw[index]
      guard name.hasPrefix("--"), index + 1 < raw.count else {
        throw BundlerError.usage("every option requires a value")
      }
      guard values.updateValue(raw[index + 1], forKey: name) == nil else {
        throw BundlerError.usage("duplicate option: \(name)")
      }
      index += 2
    }
    let required = [
      "--firmware-code", "--platform-configuration", "--toolchain-descriptor", "--output",
      "--build-identifier", "--source-repository", "--source-revision", "--source-date-epoch",
      "--secure-boot-policy",
    ]
    guard Set(values.keys) == Set(required) else {
      throw BundlerError.usage("required options: \(required.joined(separator: " "))")
    }
    guard let epochText = values["--source-date-epoch"], let epoch = UInt64(epochText) else {
      throw BundlerError.invalidUnsignedInteger(
        name: "--source-date-epoch",
        value: values["--source-date-epoch"] ?? ""
      )
    }
    guard let policyText = values["--secure-boot-policy"],
      let policy = DoryFirmwareSecureBootPolicy(rawValue: policyText)
    else {
      throw BundlerError.invalidSecureBootPolicy(values["--secure-boot-policy"] ?? "")
    }
    firmwareCode = URL(fileURLWithPath: values["--firmware-code"]!)
    platformConfiguration = URL(fileURLWithPath: values["--platform-configuration"]!)
    toolchainDescriptor = URL(fileURLWithPath: values["--toolchain-descriptor"]!)
    output = URL(fileURLWithPath: values["--output"]!)
    buildIdentifier = values["--build-identifier"]!
    sourceRepository = values["--source-repository"]!
    sourceRevision = values["--source-revision"]!
    sourceDateEpoch = epoch
    secureBootPolicy = policy
  }
}

do {
  let arguments = try Arguments(Array(CommandLine.arguments.dropFirst()))
  let input = DoryFirmwareBundleBuildInput(
    buildIdentifier: arguments.buildIdentifier,
    source: try DoryFirmwareSourcePin(
      repository: arguments.sourceRepository,
      revision: arguments.sourceRevision
    ),
    sourceDateEpoch: arguments.sourceDateEpoch,
    platformConfiguration: try Data(contentsOf: arguments.platformConfiguration),
    toolchainDescriptor: try Data(contentsOf: arguments.toolchainDescriptor),
    firmwareCode: try Data(contentsOf: arguments.firmwareCode),
    secureBootPolicy: arguments.secureBootPolicy
  )
  let bundle = try DoryFirmwareBundleBuilder.build(input)
  try bundle.write(to: arguments.output)
  print(bundle.manifest.buildIdentifier)
} catch {
  FileHandle.standardError.write(Data("dory-firmware-bundler: \(error)\n".utf8))
  exit(2)
}
