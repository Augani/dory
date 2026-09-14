import AppKit
import CryptoKit
import Foundation
import Metal
import MetalKit
import SwiftUI

/// A small, deterministic Metal workload intended to run *inside* a Dory macOS
/// guest.  It deliberately has no host privileges: the caller supplies the
/// host-issued nonce and staged-candidate identifier that bind an exported raw
/// result to a qualification run.
enum DoryGuestMetalProbe {
    static let schema = "dory.guest-tools.metal-probe@1"
    static let elementCount = 1_024
    static let imageExtent = 64

    static func run(nonce: String, candidateID: String) throws -> DoryGuestMetalProbeResult {
        let nonce = try normalizedIdentifier(nonce, label: "nonce")
        let candidateID = try normalizedIdentifier(candidateID, label: "candidate ID")
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw DoryGuestMetalProbeError.metalUnavailable
        }
        guard let commandQueue = device.makeCommandQueue() else {
            throw DoryGuestMetalProbeError.commandQueueUnavailable
        }
        guard let library = try? device.makeLibrary(source: shaderSource, options: nil),
              let computeFunction = library.makeFunction(name: "dory_probe_compute"),
              let vertexFunction = library.makeFunction(name: "dory_probe_vertex"),
              let fragmentFunction = library.makeFunction(name: "dory_probe_fragment") else {
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
            pipeline: renderPipeline
        )
        let bundle = Bundle.main
        return DoryGuestMetalProbeResult(
            schema: schema,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            nonce: nonce,
            candidateID: candidateID,
            guestToolsBundleIdentifier: bundle.bundleIdentifier ?? "unknown",
            guestToolsVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                ?? "unknown",
            guestToolsBuild: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
                ?? "unknown",
            metalDeviceName: device.name,
            metalRegistryID: String(device.registryID),
            usesUnifiedMemory: device.hasUnifiedMemory,
            probeShaderSHA256: digest(of: Data(shaderSource.utf8)),
            computeOutputSHA256: digest(of: computeBytes),
            renderedPatternSHA256: digest(of: renderedBytes),
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

    static func makePreviewRenderer(for device: MTLDevice) throws -> DoryGuestMetalProbePreviewRenderer {
        guard let library = try? device.makeLibrary(source: shaderSource, options: nil),
              let vertexFunction = library.makeFunction(name: "dory_probe_vertex"),
              let fragmentFunction = library.makeFunction(name: "dory_probe_fragment") else {
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
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
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
        pipeline: MTLRenderPipelineState
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
              let commandBuffer = commandQueue.makeCommandBuffer() else {
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
        guard verifiesCheckerboard(bytes) else {
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
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:-")
        guard !value.isEmpty,
              value.utf8.count <= 128,
              value.unicodeScalars.allSatisfy(allowed.contains) else {
            throw DoryGuestMetalProbeError.invalidIdentifier(label)
        }
        return value
    }

    private static func digest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A Metal render target may be read back with either vertical origin. Both
    /// orientations are valid, but every pixel must still match the two-color,
    /// eight-pixel checkerboard emitted by the retained fragment shader.
    private static func verifiesCheckerboard(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == imageExtent * imageExtent * 4 else { return false }
        return [false, true].contains { invertedY in
            for y in 0..<imageExtent {
                for x in 0..<imageExtent {
                    let offset = (y * imageExtent + x) * 4
                    let blue = bytes[offset]
                    let green = bytes[offset + 1]
                    let red = bytes[offset + 2]
                    let alpha = bytes[offset + 3]
                    let alternate = ((x >> 3) ^ (y >> 3)) & 1 == 1
                    let expectsCyan = invertedY ? !alternate : alternate
                    let isCyan = red <= 24 && (180...205).contains(green) && blue >= 230
                    let isMagenta = red >= 220 && (40...62).contains(green) && (76...104).contains(blue)
                    guard alpha == 255, expectsCyan ? isCyan : isMagenta else {
                        return false
                    }
                }
            }
            return true
        }
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

    vertex DoryProbeRasterOut dory_probe_vertex(uint index [[vertex_id]]) {
        constexpr float2 positions[] = {
            float2(-1.0, -1.0), float2(1.0, -1.0),
            float2(-1.0, 1.0), float2(1.0, 1.0),
        };
        DoryProbeRasterOut output;
        output.position = float4(positions[index], 0.0, 1.0);
        output.uv = (positions[index] + 1.0) * 0.5;
        return output;
    }

    fragment float4 dory_probe_fragment(DoryProbeRasterOut input [[stage_in]]) {
        uint2 pixel = uint2(min(input.uv * 64.0, float2(63.0)));
        bool alternate = ((pixel.x >> 3) ^ (pixel.y >> 3)) & 1;
        return alternate ? float4(0.05, 0.75, 0.95, 1.0)
                         : float4(0.90, 0.20, 0.35, 1.0);
    }
    """
}

struct DoryGuestMetalProbeResult: Codable, Equatable {
    let schema: String
    let createdAt: String
    let nonce: String
    let candidateID: String
    let guestToolsBundleIdentifier: String
    let guestToolsVersion: String
    let guestToolsBuild: String
    let metalDeviceName: String
    let metalRegistryID: String
    let usesUnifiedMemory: Bool
    let probeShaderSHA256: String
    let computeOutputSHA256: String
    let renderedPatternSHA256: String
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

    var errorDescription: String? {
        switch self {
        case let .invalidIdentifier(label): "Enter a host-issued \(label) using letters, digits, '.', '_', ':' or '-'."
        case .metalUnavailable: "Metal is unavailable in this macOS guest."
        case .commandQueueUnavailable: "The Metal device could not create a command queue."
        case .shaderCompilationFailed: "The retained Dory Metal probe shader could not compile."
        case let .pipelineCreationFailed(detail): "The Metal probe pipeline could not be created: \(detail)"
        case .commandEncodingFailed: "The Metal probe could not encode its command buffer."
        case let .commandFailed(detail): "The Metal probe command buffer failed: \(detail)"
        case let .computeOutputMismatch(index): "The Metal compute output differed at element \(index)."
        case .renderOutputMismatch: "The Metal render probe did not produce the expected checkerboard pattern."
        }
    }
}

final class DoryGuestMetalProbePreviewRenderer: NSObject, MTKViewDelegate {
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState

    init(commandQueue: MTLCommandQueue, pipeline: MTLRenderPipelineState) {
        self.commandQueue = commandQueue
        self.pipeline = pipeline
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

struct DoryGuestMetalProbePatternView: NSViewRepresentable {
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
        view.delegate = context.coordinator.renderer
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {}

    final class Coordinator {
        var renderer: DoryGuestMetalProbePreviewRenderer?
    }
}

@MainActor
final class DoryGuestMetalProbeController: ObservableObject {
    @Published var nonce = ""
    @Published var candidateID = ""
    @Published private(set) var status = "Enter the host-issued nonce and candidate ID, then run the probe inside this guest."
    @Published private(set) var resultJSON = ""

    var hasResult: Bool { !resultJSON.isEmpty }

    func run() {
        do {
            let result = try DoryGuestMetalProbe.run(nonce: nonce, candidateID: candidateID)
            resultJSON = try DoryGuestMetalProbe.encodedResult(result)
            status = "Metal compute and render completed. Copy the raw JSON into the matching host qualification receipt."
        } catch {
            resultJSON = ""
            status = error.localizedDescription
        }
    }

    func copyResult() {
        guard !resultJSON.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(resultJSON, forType: .string)
        status = "Raw Metal probe JSON copied. Preserve it with the exact host candidate and nonce."
    }
}
