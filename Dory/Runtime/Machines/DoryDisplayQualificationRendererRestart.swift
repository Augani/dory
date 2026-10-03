import CryptoKit
import Foundation

nonisolated struct DoryDisplayQualificationRendererRestartRequest: Codable, Equatable, Sendable {
    static let expectedKind = "dev.dory.display-qualification-renderer-restart-request"
    let kind: String
    let schemaVersion: Int
    let machineID: String
    let machServiceName: String
    let operationID: String
    let nonce: String
    let beforeRendererGeneration: UInt64
    let beforeDisplayResourceGeneration: UInt64
    let beforeFrameSequence: UInt64

    func validate(machineID: String, service: String, operationID: String, displayGeneration: UInt64,
                  frameSequence: UInt64) throws {
        guard kind == Self.expectedKind, schemaVersion == 1,
              self.machineID == machineID, machineID.hasPrefix("readiness-arm-ubuntu-"),
              self.machServiceName == service,
              service == "dev.dory.readiness.armubuntu." + machineID.dropFirst("readiness-arm-ubuntu-".count),
              let expectedOperation = UUID(uuidString: operationID),
              UUID(uuidString: self.operationID) == expectedOperation,
              nonce.utf8.count == 32, nonce.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              beforeRendererGeneration > 0, beforeDisplayResourceGeneration > 0,
              beforeFrameSequence > 0, frameSequence >= beforeFrameSequence, displayGeneration > 0 else {
            throw DoryDisplayQualificationInputError.invalidScript
        }
        // Compositor buffers can rotate after the baseline capture. Resource generation is
        // evidence, not restart authority: the operation and monotonic frame cursor bind intent.
    }

    static func load(at path: String) throws -> (request: Self, sha256: String) {
        let data = try DoryDisplayQualificationInputFiles.loadDirectData(at: path, maximumByteCount: 4_096)
        let request = try JSONDecoder().decode(Self.self, from: data)
        return (request, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }
}

/// This receipt acknowledges the runner command only. Renderer generation, guest liveness
/// and independently decoded redraw pixels are separate required campaign observations.
nonisolated struct DoryDisplayQualificationRendererRestartReceipt: Encodable, Sendable {
    let kind = "dev.dory.display-qualification-renderer-restart"
    let schemaVersion = 1
    let delivery = "runner-applied"
    let rendererRecoveryVerified = false
    let completedAt: String
    let bundleIdentifier: String
    let processID: Int32
    let machineID: String
    let machServiceName: String
    let operationID: String
    let nonce: String
    let requestSHA256: String
    let beforeRendererGeneration: UInt64
    let beforeDisplayResourceGeneration: UInt64
    let beforeFrameSequence: UInt64
    let commandFrameSequence: UInt64
    let commandDisplayResourceGeneration: UInt64
    let commandMetalCommandBufferCompletionID: UInt64
    let commandSequence: UInt64
}
