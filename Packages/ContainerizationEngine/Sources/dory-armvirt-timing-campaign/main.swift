import Darwin
import DoryARMVirtQualification
import Foundation

private struct Options {
  var matrixPath: String?
  var gateID: String?
  var minimumSampleCount = DoryARMVirtTimingCampaign.releaseMinimumSampleCount
  var receiptPaths: [String] = []
}

private func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("dory-armvirt-timing-campaign: \(message)\n".utf8))
  exit(1)
}

private func parseOptions(_ arguments: ArraySlice<String>) -> Options {
  var options = Options()
  var iterator = arguments.makeIterator()
  while let argument = iterator.next() {
    switch argument {
    case "--compatibility-matrix":
      guard options.matrixPath == nil, let value = iterator.next() else {
        fail("--compatibility-matrix requires exactly one path")
      }
      options.matrixPath = value
    case "--qualification-gate":
      guard options.gateID == nil, let value = iterator.next() else {
        fail("--qualification-gate requires exactly one identifier")
      }
      options.gateID = value
    case "--minimum-samples":
      guard let text = iterator.next(), let value = Int(text),
        (DoryARMVirtTimingCampaign
          .releaseMinimumSampleCount...DoryARMVirtTimingCampaign.maximumSampleCount).contains(value)
      else {
        fail("--minimum-samples must be between 9 and 100")
      }
      options.minimumSampleCount = value
    default:
      guard !argument.hasPrefix("-") else { fail("unknown option \(argument)") }
      options.receiptPaths.append(argument)
    }
  }
  guard options.matrixPath != nil, options.gateID != nil else {
    fail("--compatibility-matrix and --qualification-gate are required")
  }
  guard
    (options.minimumSampleCount...DoryARMVirtTimingCampaign.maximumSampleCount)
      .contains(options.receiptPaths.count)
  else {
    fail("receipt count must be between --minimum-samples and 100")
  }
  return options
}

private func admittedData(at suppliedPath: String) throws -> Data {
  let canonicalPath = URL(fileURLWithPath: suppliedPath).standardizedFileURL.path
  guard suppliedPath == canonicalPath else {
    fail("input paths must be absolute and standardized")
  }
  let descriptor = open(canonicalPath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
  guard descriptor >= 0 else { fail("cannot open input as a direct regular file") }
  let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
  var status = stat()
  guard fstat(descriptor, &status) == 0,
    status.st_mode & S_IFMT == S_IFREG,
    status.st_uid == geteuid(),
    status.st_mode & 0o022 == 0,
    status.st_size > 0,
    status.st_size <= 1 << 20
  else {
    fail("inputs must be owned, non-writable regular files no larger than 1 MiB")
  }
  guard let data = try handle.readToEnd(), data.count == Int(status.st_size) else {
    fail("input changed while being read")
  }
  return data
}

private let options = parseOptions(CommandLine.arguments.dropFirst())
guard let matrixPath = options.matrixPath, let gateID = options.gateID else {
  fail("missing required authority")
}
do {
  let matrixData = try admittedData(at: matrixPath)
  let receiptData = try options.receiptPaths.map(admittedData)
  let campaign = try DoryARMVirtTimingCampaign.aggregate(
    receiptData: receiptData,
    matrixData: matrixData,
    gateID: gateID,
    minimumSampleCount: options.minimumSampleCount
  )
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
  FileHandle.standardOutput.write(try encoder.encode(campaign))
  FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
  fail(String(describing: error))
}
