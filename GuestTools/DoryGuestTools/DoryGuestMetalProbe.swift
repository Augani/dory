import AppKit
import CryptoKit
import Darwin
import Foundation
import Metal
import MetalKit
import SwiftUI

/// A small, deterministic Metal workload intended to run *inside* a Dory macOS
/// guest.  It deliberately has no host privileges: the caller supplies the
/// host-issued nonce and staged-candidate identifier that bind an exported raw
/// result to a qualification run.
enum DoryGuestMetalProbe {
  static let schema = "dory.guest-tools.metal-probe@2"
  static let elementCount = 1_024
  static let imageExtent = 64
  static let visibleFrameMarker: UInt32 = 1

  static func run(
    nonce: String,
    candidateID: String,
    machineID: String,
    operationID: String
  ) throws -> DoryGuestMetalProbeResult {
    let nonce = try normalizedIdentifier(nonce, label: "nonce")
    let candidateID = try normalizedIdentifier(candidateID, label: "candidate ID")
    let machineID = try normalizedIdentifier(machineID, label: "machine ID")
    let operationID = try normalizedIdentifier(operationID, label: "operation ID")
    let challenge = visualChallenge(nonce: nonce, frameMarker: visibleFrameMarker)
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw DoryGuestMetalProbeError.metalUnavailable
    }
    guard let commandQueue = device.makeCommandQueue() else {
      throw DoryGuestMetalProbeError.commandQueueUnavailable
    }
    guard let library = try? device.makeLibrary(source: shaderSource, options: nil),
      let computeFunction = library.makeFunction(name: "dory_probe_compute"),
      let vertexFunction = library.makeFunction(name: "dory_probe_vertex"),
      let fragmentFunction = library.makeFunction(name: "dory_probe_fragment")
    else {
      throw DoryGuestMetalProbeError.shaderCompilationFailed
    }
    let computePipeline: MTLComputePipelineState
    let renderPipeline: MTLRenderPipelineState
    do {
      computePipeline = try device.makeComputePipelineState(function: computeFunction)
      let descriptor = MTLRenderPipelineDescriptor()
      descriptor.vertexFunction = vertexFunction
      descriptor.fragmentFunction = fragmentFunction
      descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
      renderPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    } catch {
      throw DoryGuestMetalProbeError.pipelineCreationFailed(String(describing: error))
    }

    let computeBytes = try executeCompute(
      device: device,
      commandQueue: commandQueue,
      pipeline: computePipeline
    )
    let renderedBytes = try executeRender(
      device: device,
      commandQueue: commandQueue,
      pipeline: renderPipeline,
      challenge: challenge
    )
    let bundle = Bundle.main
    let process = ProcessInfo.processInfo
    let operatingSystem = process.operatingSystemVersion
    return DoryGuestMetalProbeResult(
      schema: schema,
      createdAt: ISO8601DateFormatter().string(from: Date()),
      nonce: nonce,
      candidateID: candidateID,
      machineID: machineID,
      operationID: operationID,
      guestOperatingSystemVersion:
        "\(operatingSystem.majorVersion).\(operatingSystem.minorVersion).\(operatingSystem.patchVersion)",
      guestOperatingSystemBuild: try operatingSystemBuild(),
      guestActiveProcessorCount: process.activeProcessorCount,
      guestPhysicalMemoryBytes: process.physicalMemory,
      guestToolsBundleIdentifier: bundle.bundleIdentifier ?? "unknown",
      guestToolsVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
        as? String
        ?? "unknown",
      guestToolsBuild: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        ?? "unknown",
      metalDeviceName: device.name,
      metalRegistryID: String(device.registryID),
      usesUnifiedMemory: device.hasUnifiedMemory,
      probeShaderSHA256: digest(of: Data(shaderSource.utf8)),
      computeOutputSHA256: digest(of: computeBytes),
      renderedPatternSHA256: digest(of: renderedBytes),
      visualChallenge: challenge.record,
      computeValueCount: elementCount,
      renderedWidth: imageExtent,
      renderedHeight: imageExtent,
      computeCommandBufferStatus: "completed",
      renderCommandBufferStatus: "completed"
    )
  }

  static func encodedResult(_ result: DoryGuestMetalProbeResult) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(result), as: UTF8.self)
  }

  static func makePreviewRenderer(for device: MTLDevice) throws
    -> DoryGuestMetalProbePreviewRenderer
  {
    guard let library = try? device.makeLibrary(source: shaderSource, options: nil),
      let vertexFunction = library.makeFunction(name: "dory_probe_vertex"),
      let fragmentFunction = library.makeFunction(name: "dory_probe_fragment")
    else {
      throw DoryGuestMetalProbeError.shaderCompilationFailed
    }
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = vertexFunction
    descriptor.fragmentFunction = fragmentFunction
    descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
    do {
      return DoryGuestMetalProbePreviewRenderer(
        commandQueue: try requireCommandQueue(device),
        pipeline: try device.makeRenderPipelineState(descriptor: descriptor)
      )
    } catch {
      throw DoryGuestMetalProbeError.pipelineCreationFailed(String(describing: error))
    }
  }

  private static func executeCompute(
    device: MTLDevice,
    commandQueue: MTLCommandQueue,
    pipeline: MTLComputePipelineState
  ) throws -> Data {
    let byteCount = elementCount * MemoryLayout<UInt32>.size
    guard let output = device.makeBuffer(length: byteCount, options: .storageModeShared),
      let commandBuffer = commandQueue.makeCommandBuffer(),
      let encoder = commandBuffer.makeComputeCommandEncoder()
    else {
      throw DoryGuestMetalProbeError.commandEncodingFailed
    }
    encoder.setComputePipelineState(pipeline)
    encoder.setBuffer(output, offset: 0, index: 0)
    let width = min(elementCount, pipeline.maxTotalThreadsPerThreadgroup)
    encoder.dispatchThreads(
      MTLSize(width: elementCount, height: 1, depth: 1),
      threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1)
    )
    encoder.endEncoding()
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    guard commandBuffer.status == .completed else {
      throw DoryGuestMetalProbeError.commandFailed(
        commandBuffer.error.map(String.init(describing:)) ?? "compute command did not complete"
      )
    }
    let values = output.contents().bindMemory(to: UInt32.self, capacity: elementCount)
    for index in 0..<elementCount {
      let expected = (UInt32(index) &* 17 ^ 0x5A5A) &+ 3
      guard values[index] == expected else {
        throw DoryGuestMetalProbeError.computeOutputMismatch(index: index)
      }
    }
    return Data(bytes: values, count: byteCount)
  }

  private static func executeRender(
    device: MTLDevice,
    commandQueue: MTLCommandQueue,
    pipeline: MTLRenderPipelineState,
    challenge: DoryGuestMetalVisualChallengeUniform
  ) throws -> Data {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm,
      width: imageExtent,
      height: imageExtent,
      mipmapped: false
    )
    descriptor.storageMode = .shared
    descriptor.usage = [.renderTarget, .shaderRead]
    guard let target = device.makeTexture(descriptor: descriptor),
      let commandBuffer = commandQueue.makeCommandBuffer()
    else {
      throw DoryGuestMetalProbeError.commandEncodingFailed
    }
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = target
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
    guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
      throw DoryGuestMetalProbeError.commandEncodingFailed
    }
    encoder.setRenderPipelineState(pipeline)
    var challenge = challenge
    encoder.setFragmentBytes(
      &challenge,
      length: MemoryLayout<DoryGuestMetalVisualChallengeUniform>.stride,
      index: 0
    )
    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    encoder.endEncoding()
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    guard commandBuffer.status == .completed else {
      throw DoryGuestMetalProbeError.commandFailed(
        commandBuffer.error.map(String.init(describing:)) ?? "render command did not complete"
      )
    }
    var bytes = [UInt8](repeating: 0, count: imageExtent * imageExtent * 4)
    target.getBytes(
      &bytes,
      bytesPerRow: imageExtent * 4,
      from: MTLRegionMake2D(0, 0, imageExtent, imageExtent),
      mipmapLevel: 0
    )
    guard verifiesPattern(bytes, challenge: challenge) else {
      throw DoryGuestMetalProbeError.renderOutputMismatch
    }
    return Data(bytes)
  }

  private static func requireCommandQueue(_ device: MTLDevice) throws -> MTLCommandQueue {
    guard let queue = device.makeCommandQueue() else {
      throw DoryGuestMetalProbeError.commandQueueUnavailable
    }
    return queue
  }

  private static func normalizedIdentifier(_ raw: String, label: String) throws -> String {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let allowed = CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:-")
    guard !value.isEmpty,
      value.utf8.count <= 128,
      value.unicodeScalars.allSatisfy(allowed.contains)
    else {
      throw DoryGuestMetalProbeError.invalidIdentifier(label)
    }
    return value
  }

  private static func operatingSystemBuild() throws -> String {
    var byteCount = 0
    guard sysctlbyname("kern.osversion", nil, &byteCount, nil, 0) == 0,
      byteCount > 1,
      byteCount <= 128
    else {
      throw DoryGuestMetalProbeError.operatingSystemBuildUnavailable
    }
    var bytes = [CChar](repeating: 0, count: byteCount)
    guard sysctlbyname("kern.osversion", &bytes, &byteCount, nil, 0) == 0 else {
      throw DoryGuestMetalProbeError.operatingSystemBuildUnavailable
    }
    let build = String(cString: bytes)
    guard (try? normalizedIdentifier(build, label: "guest operating-system build")) != nil else {
      throw DoryGuestMetalProbeError.operatingSystemBuildUnavailable
    }
    return build
  }

  private static func digest(of data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  static func visualChallenge(
    nonce: String,
    frameMarker: UInt32 = visibleFrameMarker
  ) -> DoryGuestMetalVisualChallengeUniform {
    var hash = UInt64(14_695_981_039_346_656_037)
    let challengeBytes =
      Array(nonce.utf8) + [
        UInt8(truncatingIfNeeded: frameMarker),
        UInt8(truncatingIfNeeded: frameMarker >> 8),
        UInt8(truncatingIfNeeded: frameMarker >> 16),
        UInt8(truncatingIfNeeded: frameMarker >> 24),
      ]
    for byte in challengeBytes {
      hash ^= UInt64(byte)
      hash &*= 1_099_511_628_211
    }
    return DoryGuestMetalVisualChallengeUniform(
      hashLow: UInt32(truncatingIfNeeded: hash),
      hashHigh: UInt32(truncatingIfNeeded: hash >> 32),
      frameMarker: frameMarker,
      reserved: 0
    )
  }

  /// The vertex shader maps the top of the viewport to UV y=0, so a vertically inverted
  /// readback is a rendering defect rather than an alternate accepted texture origin.
  private static func verifiesPattern(
    _ bytes: [UInt8],
    challenge: DoryGuestMetalVisualChallengeUniform
  ) -> Bool {
    guard bytes.count == imageExtent * imageExtent * 4 else { return false }
    for y in 0..<imageExtent {
      for x in 0..<imageExtent {
        let offset = (y * imageExtent + x) * 4
        let blue = bytes[offset]
        let green = bytes[offset + 1]
        let red = bytes[offset + 2]
        let alpha = bytes[offset + 3]
        let expected = expectedBGRA(x: x, y: y, challenge: challenge)
        guard alpha == expected.3,
          blue == expected.0,
          green == expected.1,
          red == expected.2
        else {
          return false
        }
      }
    }
    return true
  }

  private static func expectedBGRA(
    x: Int,
    y: Int,
    challenge: DoryGuestMetalVisualChallengeUniform
  ) -> (UInt8, UInt8, UInt8, UInt8) {
    let markerX = x - 8
    let markerY = y - 12
    if markerX >= 0, markerY >= 0, markerX < 48, markerY < 40 {
      let column = markerX / 4
      let row = markerY / 4
      let rgba: (UInt8, UInt8, UInt8, UInt8)
      switch (column, row) {
      case (0, 0): rgba = (244, 67, 54, 255)
      case (11, 0): rgba = (76, 175, 80, 255)
      case (0, 9): rgba = (33, 150, 243, 255)
      case (11, 9): rgba = (255, 235, 59, 255)
      case (_, 0), (_, 9), (0, _), (11, _): rgba = (6, 10, 20, 255)
      default:
        let bitIndex = UInt32((row - 1) * 10 + (column - 1))
        let bit: UInt32
        if bitIndex < 32 {
          bit = (challenge.hashLow >> bitIndex) & 1
        } else if bitIndex < 64 {
          bit = (challenge.hashHigh >> (bitIndex - 32)) & 1
        } else {
          bit = (challenge.frameMarker >> (bitIndex - 64)) & 1
        }
        rgba = bit == 1 ? (64, 224, 196, 255) : (24, 52, 92, 255)
      }
      return (rgba.2, rgba.1, rgba.0, rgba.3)
    }
    let alternate = ((x >> 3) ^ (y >> 3)) & 1 == 1
    return alternate ? (242, 191, 13, 255) : (89, 51, 230, 255)
  }

  private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    kernel void dory_probe_compute(device uint *output [[buffer(0)]],
                                   uint index [[thread_position_in_grid]]) {
        output[index] = ((index * 17) ^ 0x5A5A) + 3;
    }

    struct DoryProbeRasterOut {
        float4 position [[position]];
        float2 uv;
    };

    struct DoryProbeChallenge {
        uint2 hashWords;
        uint frameMarker;
        uint reserved;
    };

    vertex DoryProbeRasterOut dory_probe_vertex(uint index [[vertex_id]]) {
        constexpr float2 positions[] = {
            float2(-1.0, -1.0), float2(1.0, -1.0),
            float2(-1.0, 1.0), float2(1.0, 1.0),
        };
        DoryProbeRasterOut output;
        output.position = float4(positions[index], 0.0, 1.0);
        output.uv = float2((positions[index].x + 1.0) * 0.5,
                           (1.0 - positions[index].y) * 0.5);
        return output;
    }

    fragment float4 dory_probe_fragment(
        DoryProbeRasterOut input [[stage_in]],
        constant DoryProbeChallenge &challenge [[buffer(0)]]) {
        uint2 pixel = uint2(min(input.uv * 64.0, float2(63.0)));
        if (pixel.x >= 8 && pixel.x < 56 && pixel.y >= 12 && pixel.y < 52) {
            uint column = (pixel.x - 8) / 4;
            uint row = (pixel.y - 12) / 4;
            if (column == 0 && row == 0) return float4(244.0 / 255.0, 67.0 / 255.0, 54.0 / 255.0, 1.0);
            if (column == 11 && row == 0) return float4(76.0 / 255.0, 175.0 / 255.0, 80.0 / 255.0, 1.0);
            if (column == 0 && row == 9) return float4(33.0 / 255.0, 150.0 / 255.0, 243.0 / 255.0, 1.0);
            if (column == 11 && row == 9) return float4(255.0 / 255.0, 235.0 / 255.0, 59.0 / 255.0, 1.0);
            if (column == 0 || column == 11 || row == 0 || row == 9)
                return float4(6.0 / 255.0, 10.0 / 255.0, 20.0 / 255.0, 1.0);
            uint bitIndex = (row - 1) * 10 + (column - 1);
            uint bit = bitIndex < 32 ? ((challenge.hashWords.x >> bitIndex) & 1)
                     : bitIndex < 64 ? ((challenge.hashWords.y >> (bitIndex - 32)) & 1)
                                     : ((challenge.frameMarker >> (bitIndex - 64)) & 1);
            return bit ? float4(64.0 / 255.0, 224.0 / 255.0, 196.0 / 255.0, 1.0)
                       : float4(24.0 / 255.0, 52.0 / 255.0, 92.0 / 255.0, 1.0);
        }
        bool alternate = ((pixel.x >> 3) ^ (pixel.y >> 3)) & 1;
        return alternate ? float4(13.0 / 255.0, 191.0 / 255.0, 242.0 / 255.0, 1.0)
                         : float4(230.0 / 255.0, 51.0 / 255.0, 89.0 / 255.0, 1.0);
    }
    """
}

struct DoryGuestMetalVisualChallengeUniform {
  let hashLow: UInt32
  let hashHigh: UInt32
  let frameMarker: UInt32
  let reserved: UInt32

  var record: DoryGuestMetalVisualChallenge {
    let hash = UInt64(hashLow) | UInt64(hashHigh) << 32
    return DoryGuestMetalVisualChallenge(
      kind: "dev.dory.visual-challenge",
      version: 1,
      encoding: "fnv1a64-frame16-grid12x10",
      frameMarker: frameMarker,
      payloadHash: String(format: "fnv1a64:%016llx", hash)
    )
  }
}

struct DoryGuestMetalVisualChallenge: Codable, Equatable {
  let kind: String
  let version: Int
  let encoding: String
  let frameMarker: UInt32
  let payloadHash: String
}

struct DoryGuestMetalProbeResult: Codable, Equatable {
  let schema: String
  let createdAt: String
  let nonce: String
  let candidateID: String
  let machineID: String
  let operationID: String
  let guestOperatingSystemVersion: String
  let guestOperatingSystemBuild: String
  let guestActiveProcessorCount: Int
  let guestPhysicalMemoryBytes: UInt64
  let guestToolsBundleIdentifier: String
  let guestToolsVersion: String
  let guestToolsBuild: String
  let metalDeviceName: String
  let metalRegistryID: String
  let usesUnifiedMemory: Bool
  let probeShaderSHA256: String
  let computeOutputSHA256: String
  let renderedPatternSHA256: String
  let visualChallenge: DoryGuestMetalVisualChallenge
  let computeValueCount: Int
  let renderedWidth: Int
  let renderedHeight: Int
  let computeCommandBufferStatus: String
  let renderCommandBufferStatus: String
}

enum DoryGuestMetalProbeError: LocalizedError {
  case invalidIdentifier(String)
  case metalUnavailable
  case commandQueueUnavailable
  case shaderCompilationFailed
  case pipelineCreationFailed(String)
  case commandEncodingFailed
  case commandFailed(String)
  case computeOutputMismatch(index: Int)
  case renderOutputMismatch
  case operatingSystemBuildUnavailable

  var errorDescription: String? {
    switch self {
    case .invalidIdentifier(let label):
      "Enter a host-issued \(label) using letters, digits, '.', '_', ':' or '-'."
    case .metalUnavailable: "Metal is unavailable in this macOS guest."
    case .commandQueueUnavailable: "The Metal device could not create a command queue."
    case .shaderCompilationFailed: "The retained Dory Metal probe shader could not compile."
    case .pipelineCreationFailed(let detail):
      "The Metal probe pipeline could not be created: \(detail)"
    case .commandEncodingFailed: "The Metal probe could not encode its command buffer."
    case .commandFailed(let detail): "The Metal probe command buffer failed: \(detail)"
    case .computeOutputMismatch(let index): "The Metal compute output differed at element \(index)."
    case .renderOutputMismatch:
      "The Metal render probe did not produce the expected checkerboard pattern."
    case .operatingSystemBuildUnavailable:
      "The guest operating-system build could not be determined."
    }
  }
}

final class DoryGuestMetalProbePreviewRenderer: NSObject, MTKViewDelegate {
  private let commandQueue: MTLCommandQueue
  private let pipeline: MTLRenderPipelineState
  private var challenge = DoryGuestMetalProbe.visualChallenge(nonce: "unbound")

  init(commandQueue: MTLCommandQueue, pipeline: MTLRenderPipelineState) {
    self.commandQueue = commandQueue
    self.pipeline = pipeline
  }

  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

  func update(nonce: String) {
    let normalized = nonce.trimmingCharacters(in: .whitespacesAndNewlines)
    challenge = DoryGuestMetalProbe.visualChallenge(
      nonce: normalized.isEmpty ? "unbound" : normalized
    )
  }

  func draw(in view: MTKView) {
    guard let descriptor = view.currentRenderPassDescriptor,
      let drawable = view.currentDrawable,
      let commandBuffer = commandQueue.makeCommandBuffer(),
      let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
    else {
      return
    }
    encoder.setRenderPipelineState(pipeline)
    var challenge = challenge
    encoder.setFragmentBytes(
      &challenge,
      length: MemoryLayout<DoryGuestMetalVisualChallengeUniform>.stride,
      index: 0
    )
    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    encoder.endEncoding()
    commandBuffer.present(drawable)
    commandBuffer.commit()
  }
}

struct DoryGuestMetalProbePatternView: NSViewRepresentable {
  let nonce: String

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> MTKView {
    let view = MTKView()
    view.colorPixelFormat = .bgra8Unorm
    view.clearColor = MTLClearColorMake(0, 0, 0, 1)
    view.preferredFramesPerSecond = 30
    view.enableSetNeedsDisplay = false
    guard let device = MTLCreateSystemDefaultDevice() else { return view }
    view.device = device
    context.coordinator.renderer = try? DoryGuestMetalProbe.makePreviewRenderer(for: device)
    context.coordinator.renderer?.update(nonce: nonce)
    view.delegate = context.coordinator.renderer
    return view
  }

  func updateNSView(_ view: MTKView, context: Context) {
    context.coordinator.renderer?.update(nonce: nonce)
    view.setNeedsDisplay(view.bounds)
  }

  final class Coordinator {
    var renderer: DoryGuestMetalProbePreviewRenderer?
  }
}

@MainActor
final class DoryGuestMetalProbeController: ObservableObject {
  @Published var nonce = ""
  @Published var candidateID = ""
  @Published var machineID = ""
  @Published var operationID = ""
  @Published private(set) var status =
    "Enter the host-issued nonce, candidate ID, and machine ID, then run the probe inside this guest."
  @Published private(set) var resultJSON = ""
  @Published private(set) var isCollecting = false

  var hasResult: Bool { !resultJSON.isEmpty }

  func run() {
    do {
      let result = try DoryGuestMetalProbe.run(
        nonce: nonce,
        candidateID: candidateID,
        machineID: machineID,
        operationID: operationID
      )
      resultJSON = try DoryGuestMetalProbe.encodedResult(result)
      status =
        "Metal compute and render completed. Copy the raw JSON into the matching host qualification receipt."
    } catch {
      resultJSON = ""
      status = error.localizedDescription
    }
  }

  func runAndSendToHost() {
    guard !isCollecting else { return }
    isCollecting = true
    resultJSON = ""
    status = "Connecting to the matching Dory qualification run…"
    Task { @MainActor in
      defer { isCollecting = false }
      do {
        resultJSON = try await Task.detached(priority: .userInitiated) {
          try DoryGuestMetalProbeTransport.collect()
        }.value
        if let payload = resultJSON.data(using: .utf8),
          let result = try? JSONDecoder().decode(DoryGuestMetalProbeResult.self, from: payload)
        {
          nonce = result.nonce
          candidateID = result.candidateID
          machineID = result.machineID
          operationID = result.operationID
        }
        status =
          "Metal compute and render completed. The raw result was retained by the matching Dory host run."
      } catch {
        resultJSON = ""
        status = error.localizedDescription
      }
    }
  }

  func copyResult() {
    guard !resultJSON.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(resultJSON, forType: .string)
    status = "Raw Metal probe JSON copied. Preserve it with the exact host candidate and nonce."
  }
}
