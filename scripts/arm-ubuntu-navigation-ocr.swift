// Local, read-only recognition of the guest viewport, never the host window title.
// Uses Apple's documented VNRecognizeTextRequest path on macOS 15+.
import CryptoKit
import CoreML
import Foundation
import ImageIO
import Vision

struct Viewport: Decodable {
    let coordinateSpace: String
    let x: Int
    let y: Int
    let width: Int
    let height: Int
}
struct Window: Decodable { let guestViewport: Viewport }
struct Line: Encodable {
    let text: String
    let confidence: Float
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}
struct Result: Encodable {
    let kind = "dev.dory.guest-viewport-text"
    let schemaVersion = 1
    let revision = 3
    let framebufferSHA256: String
    let cropWidth: Int
    let cropHeight: Int
    let lines: [Line]
}

do {
    guard CommandLine.arguments.count == 3 else {
        throw CocoaError(.fileReadInvalidFileName)
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    guard data.count <= 32 * 1_024 * 1_024,
          data.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]),
          let source = CGImageSourceCreateWithData(data as CFData, nil),
          CGImageSourceGetCount(source) == 1,
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          image.width <= 16_384, image.height <= 16_384,
          image.width * image.height <= 64 * 1_024 * 1_024 else {
        throw CocoaError(.fileReadCorruptFile)
    }
    let window = try JSONDecoder().decode(Window.self, from: Data(
        contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
    let v = window.guestViewport
    guard v.coordinateSpace == "capture-pixels-top-left", v.x >= 0, v.y >= 0,
          v.width >= 320, v.height >= 200,
          v.width <= image.width, v.height <= image.height,
          v.x <= image.width - v.width, v.y <= image.height - v.height,
          let cropped = image.cropping(to: CGRect(x: v.x, y: v.y, width: v.width, height: v.height)) else {
        throw CocoaError(.fileReadCorruptFile)
    }
    let request = VNRecognizeTextRequest()
    request.revision = VNRecognizeTextRequestRevision3
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["en-US"]
    request.usesLanguageCorrection = false
    request.minimumTextHeight = 0.008
    // Keep replay independent of a live guest's GPU/renderer load. This is host-side
    // recognition only and is not counted as guest hardware-rendering evidence.
    let stageDevices = try request.supportedComputeStageDevices
    guard !stageDevices.isEmpty else { throw CocoaError(.featureUnsupported) }
    for (stage, devices) in stageDevices {
        guard let cpu = devices.first(where: { if case .cpu = $0 { return true }; return false }) else {
            throw CocoaError(.featureUnsupported)
        }
        request.setComputeDevice(cpu, for: stage)
    }
    try VNImageRequestHandler(cgImage: cropped, options: [:]).perform([request])
    let lines = (request.results ?? []).compactMap { observation -> Line? in
        guard let text = observation.topCandidates(1).first, text.confidence >= 0.5 else { return nil }
        let box = observation.boundingBox
        return Line(text: text.string, confidence: text.confidence,
                    x: box.minX, y: box.minY, width: box.width, height: box.height)
    }.sorted { $0.y == $1.y ? $0.x < $1.x : $0.y > $1.y }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let result = Result(framebufferSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                        cropWidth: v.width, cropHeight: v.height, lines: lines)
    FileHandle.standardOutput.write(try encoder.encode(result) + Data("\n".utf8))
} catch {
    FileHandle.standardError.write(Data("navigation OCR: \(error)\n".utf8))
    exit(2)
}
