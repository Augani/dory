import AppKit
import CryptoKit
import Darwin
import DoryVZMacCore
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

private enum CaptureError: Error, CustomStringConvertible {
  case usage(String)
  case noMatchingWindow
  case ambiguousWindows([Int])
  case wrongProcess
  case invalidChallengeResult
  case wrongQualificationWindow
  case invalidViewport
  case pngEncodingFailed
  case destinationExists(String)

  var description: String {
    switch self {
    case .usage(let message): message
    case .noMatchingWindow: "no on-screen dory-vmm window matches the selected process/window"
    case .ambiguousWindows(let numbers):
      "multiple dory-vmm windows match; pass --window-number (\(numbers))"
    case .wrongProcess: "--pid must identify the running dory-vmm product application"
    case .invalidChallengeResult: "the guest result does not match the exact challenge identity"
    case .wrongQualificationWindow:
      "the selected product window is not bound to this Metal probe challenge"
    case .invalidViewport: "--guest-preview must be a nonempty x,y,width,height rectangle inside the capture"
    case .pngEncodingFailed: "the selected product window could not be encoded as PNG"
    case .destinationExists(let path): "refusing to replace an existing capture artifact: \(path)"
    }
  }
}

private struct CaptureInputs {
  let processID: Int32
  let windowNumber: Int?
  let challengeURL: URL
  let resultURL: URL
  let captureURL: URL
  let receiptURL: URL
  let preview: (x: Int, y: Int, width: Int, height: Int)

  init(_ arguments: [String]) throws {
    var values = [String: String]()
    var index = 0
    let allowed = Set([
      "--pid", "--window-number", "--challenge", "--result", "--capture", "--receipt",
      "--guest-preview",
    ])
    while index < arguments.count {
      let flag = arguments[index]
      guard allowed.contains(flag), values[flag] == nil, index + 1 < arguments.count else {
        throw CaptureError.usage(Self.usage)
      }
      values[flag] = arguments[index + 1]
      index += 2
    }
    guard let rawPID = values["--pid"], let processID = Int32(rawPID), processID > 0,
      let rawChallenge = values["--challenge"],
      let rawResult = values["--result"],
      let rawCapture = values["--capture"],
      let rawReceipt = values["--receipt"],
      let rawPreview = values["--guest-preview"]
    else {
      throw CaptureError.usage(Self.usage)
    }
    self.processID = processID
    if let rawWindowNumber = values["--window-number"] {
      guard let number = Int(rawWindowNumber), number > 0 else {
        throw CaptureError.usage(Self.usage)
      }
      windowNumber = number
    } else {
      windowNumber = nil
    }
    func absoluteURL(_ path: String) throws -> URL {
      guard path.hasPrefix("/"), !path.contains("\0") else {
        throw CaptureError.usage(Self.usage)
      }
      let url = URL(fileURLWithPath: path).standardizedFileURL
      guard url.path == path else { throw CaptureError.usage(Self.usage) }
      return url
    }
    challengeURL = try absoluteURL(rawChallenge)
    resultURL = try absoluteURL(rawResult)
    captureURL = try absoluteURL(rawCapture)
    receiptURL = try absoluteURL(rawReceipt)
    guard captureURL != receiptURL,
      captureURL != challengeURL, captureURL != resultURL,
      receiptURL != challengeURL, receiptURL != resultURL
    else {
      throw CaptureError.usage(Self.usage)
    }
    let components = rawPreview.split(separator: ",", omittingEmptySubsequences: false)
    guard components.count == 4,
      let x = Int(components[0]), let y = Int(components[1]),
      let width = Int(components[2]), let height = Int(components[3]),
      x >= 0, y >= 0, width > 0, height > 0
    else {
      throw CaptureError.invalidViewport
    }
    preview = (x, y, width, height)
  }

  static let usage = """
    Usage: dory-vzmac-window-capture --pid <dory-vmm PID> [--window-number <CGWindowID>] \\
      --challenge <absolute JSON> --result <absolute JSON> \\
      --capture <absolute PNG> --receipt <absolute JSON> \\
      --guest-preview <x,y,width,height in capture pixels>
    """
}

private struct GuestPreview: Encodable {
  let coordinateSpace = "capture-pixels-top-left"
  let x: Int
  let y: Int
  let width: Int
  let height: Int
  let sourceWidth: Int
  let sourceHeight: Int
  let backingScaleFactor: Double
  let colorSpace = "sRGB"
}

private struct CaptureReceipt: Encodable {
  let schema = "dory.macos-guest-metal-window-capture@2"
  let capturedAt: String
  let capturedMonotonicNanoseconds: UInt64
  let captureScope = "selected-vzmac-product-window"
  let candidateID: String
  let machineID: String
  let operationID: String
  let nonce: String
  let challengeSHA256: String
  let resultSHA256: String
  let captureSHA256: String
  let captureByteCount: Int
  let captureWidth: Int
  let captureHeight: Int
  let guestPreview: GuestPreview
  let windowProcessIdentifier: Int32
  let windowNumber: Int
}

@main
private struct DoryVZMacWindowCapture {
  @MainActor
  static func main() async {
    do {
      try await capture(CaptureInputs(Array(CommandLine.arguments.dropFirst())))
    } catch {
      FileHandle.standardError.write(Data("dory-vzmac-window-capture: \(error)\n".utf8))
      exit(2)
    }
  }

  @MainActor
  private static func capture(_ inputs: CaptureInputs) async throws {
    guard let process = NSRunningApplication(processIdentifier: inputs.processID),
      process.bundleIdentifier == "dory-vmm",
      process.executableURL?.lastPathComponent == "dory-vmm"
    else {
      throw CaptureError.wrongProcess
    }
    for destination in [inputs.captureURL, inputs.receiptURL] {
      guard !FileManager.default.fileExists(atPath: destination.path) else {
        throw CaptureError.destinationExists(destination.path)
      }
    }
    let challengeBytes = try Data(contentsOf: inputs.challengeURL)
    let challenge = try JSONDecoder().decode(DoryVZMacMetalProbeChallenge.self, from: challengeBytes)
    try challenge.validate()
    let resultBytes = try Data(contentsOf: inputs.resultURL)
    guard let result = try JSONSerialization.jsonObject(with: resultBytes) as? [String: Any],
      result["schema"] as? String == DoryVZMacMetalProbeTransport.resultSchema,
      result["candidateID"] as? String == challenge.candidateID,
      result["machineID"] as? String == challenge.machineID,
      result["operationID"] as? String == challenge.operationID,
      result["nonce"] as? String == challenge.nonce
    else {
      throw CaptureError.invalidChallengeResult
    }

    let content = try await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: true
    )
    let matching = content.windows.filter { window in
      guard let app = window.owningApplication else { return false }
      return app.processID == inputs.processID
        && app.bundleIdentifier == "dory-vmm"
        && (inputs.windowNumber == nil || Int(window.windowID) == inputs.windowNumber)
        && window.frame.width >= 640 && window.frame.height >= 400
    }
    guard !matching.isEmpty else { throw CaptureError.noMatchingWindow }
    guard matching.count == 1, let window = matching.first else {
      throw CaptureError.ambiguousWindows(matching.map { Int($0.windowID) })
    }
    guard window.title?.hasSuffix("[\(challenge.productWindowTitleToken)]") == true else {
      throw CaptureError.wrongQualificationWindow
    }
    let filter = SCContentFilter(desktopIndependentWindow: window)
    let configuration = SCStreamConfiguration()
    configuration.width = Int(window.frame.width.rounded())
    configuration.height = Int(window.frame.height.rounded())
    configuration.scalesToFit = true
    configuration.showsCursor = false
    configuration.colorSpaceName = CGColorSpace.sRGB as CFString
    let image = try await SCScreenshotManager.captureImage(
      contentFilter: filter,
      configuration: configuration
    )
    // Both clocks describe the completed ScreenCaptureKit snapshot, not later PNG encoding.
    let capturedAt = Date()
    let capturedMonotonicNanoseconds = DispatchTime.now().uptimeNanoseconds
    let width = image.width
    let height = image.height
    let viewport = inputs.preview
    guard viewport.x < width, viewport.y < height,
      viewport.width <= width - viewport.x,
      viewport.height <= height - viewport.y
    else {
      throw CaptureError.invalidViewport
    }
    let png = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
      png, UTType.png.identifier as CFString, 1, nil
    ) else {
      throw CaptureError.pngEncodingFailed
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw CaptureError.pngEncodingFailed
    }
    let pngBytes = png as Data
    let timestampFormatter = ISO8601DateFormatter()
    timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let receipt = CaptureReceipt(
      capturedAt: timestampFormatter.string(from: capturedAt),
      capturedMonotonicNanoseconds: capturedMonotonicNanoseconds,
      candidateID: challenge.candidateID,
      machineID: challenge.machineID,
      operationID: challenge.operationID,
      nonce: challenge.nonce,
      challengeSHA256: sha256(challengeBytes),
      resultSHA256: sha256(resultBytes),
      captureSHA256: sha256(pngBytes),
      captureByteCount: pngBytes.count,
      captureWidth: width,
      captureHeight: height,
      guestPreview: GuestPreview(
        x: viewport.x, y: viewport.y, width: viewport.width, height: viewport.height,
        sourceWidth: width, sourceHeight: height,
        backingScaleFactor: Double(width) / window.frame.width
      ),
      windowProcessIdentifier: inputs.processID,
      windowNumber: Int(window.windowID)
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try publishPrivate(pngBytes, to: inputs.captureURL)
    do {
      try publishPrivate(encoder.encode(receipt), to: inputs.receiptURL)
    } catch {
      try? FileManager.default.removeItem(at: inputs.captureURL)
      throw error
    }
    print("Captured dory-vmm window \(window.windowID) from PID \(inputs.processID): \(inputs.captureURL.path)")
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private static func publishPrivate(_ data: Data, to destination: URL) throws {
    let temporary = destination.deletingLastPathComponent().appendingPathComponent(
      ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
    )
    let descriptor = open(
      temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600
    )
    guard descriptor >= 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer {
      close(descriptor)
      _ = unlink(temporary.path)
    }
    try data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let written = write(
          descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset
        )
        if written < 0 {
          if errno == EINTR { continue }
          throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard written > 0 else { throw POSIXError(.EIO) }
        offset += written
      }
    }
    guard fsync(descriptor) == 0, link(temporary.path, destination.path) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }
}
