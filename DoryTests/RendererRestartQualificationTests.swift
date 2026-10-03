import Foundation
import Testing
@testable import Dory

@MainActor
struct RendererRestartQualificationTests {
    private let machine = "readiness-arm-ubuntu-unit"
    private let service = "dev.dory.readiness.armubuntu.unit"
    private let operation = "00112233-4455-6677-8899-aabbccddeeff"

    private var request: DoryDisplayQualificationRendererRestartRequest {
        .init(kind: DoryDisplayQualificationRendererRestartRequest.expectedKind, schemaVersion: 1,
              machineID: machine, machServiceName: service, operationID: operation,
              nonce: String(repeating: "a", count: 32), beforeRendererGeneration: 7,
              beforeDisplayResourceGeneration: 8, beforeFrameSequence: 44)
    }

    @Test func requestBindsExactMachineServiceOperationAndMonotonicFrameCursor() throws {
        try request.validate(machineID: machine, service: service, operationID: operation.uppercased(), displayGeneration: 8, frameSequence: 44)
        for (target, endpoint, identity, generation) in [
            ("readiness-arm-ubuntu-other", service, operation, UInt64(8)),
            (machine, "dev.dory.doryd", operation, UInt64(8)),
            (machine, service, UUID().uuidString, UInt64(8)),
            (machine, service, operation, UInt64(0)),
        ] {
            #expect(throws: DoryDisplayQualificationInputError.invalidScript) {
                try request.validate(machineID: target, service: endpoint, operationID: identity, displayGeneration: generation, frameSequence: 44)
            }
        }
    }

    @Test func compositorBufferRotationIsAcceptedButOlderFramesAreRejected() throws {
        try request.validate(machineID: machine, service: service, operationID: operation, displayGeneration: 3, frameSequence: 46)
        #expect(throws: DoryDisplayQualificationInputError.invalidScript) {
            try request.validate(machineID: machine, service: service, operationID: operation, displayGeneration: 8, frameSequence: 43)
        }
    }

    @Test func restartPathsMustBePairedDistinctAndOutsideOtherEvidence() throws {
        var environment = [
            DoryDisplayQualificationLaunch.machineIDEnvironmentKey: machine,
            DoryDisplayQualificationLaunch.machServiceEnvironmentKey: service,
            DoryDisplayQualificationLaunch.windowReceiptEnvironmentKey: "/tmp/restart-window.json",
            DoryDisplayQualificationLaunch.rendererRestartRequestEnvironmentKey: "/tmp/restart-request.json",
        ]
        #expect(throws: DoryDisplayQualificationLaunchError.incompleteRendererRestartAuthority) {
            try DoryDisplayQualificationLaunch.parse(environment: environment)
        }
        environment[DoryDisplayQualificationLaunch.rendererRestartReceiptEnvironmentKey] = "/tmp/restart-ack.json"
        let launch = try #require(try DoryDisplayQualificationLaunch.parse(environment: environment))
        #expect(launch.rendererRestartRequestPath == "/tmp/restart-request.json")
        for invalid in ["/tmp/restart-request.json", "/tmp/restart-window.json", "relative.json", "/tmp/../restart-ack.json"] {
            environment[DoryDisplayQualificationLaunch.rendererRestartReceiptEnvironmentKey] = invalid
            #expect(throws: DoryDisplayQualificationLaunchError.invalidRendererRestartPath) {
                try DoryDisplayQualificationLaunch.parse(environment: environment)
            }
        }
    }

    @Test func invalidRestartNonceAndGenerationsAreRejected() throws {
        let data = try JSONEncoder().encode(request)
        let original = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let mutations: [(String, Any)] = [("nonce", "stale"), ("nonce", String(repeating: "A", count: 32)),
                                        ("beforeRendererGeneration", 0), ("beforeDisplayResourceGeneration", 0),
                                        ("kind", "unrelated"), ("schemaVersion", 2), ("beforeFrameSequence", 0)]
        for (key, value) in mutations {
            var body = original
            body[key] = value
            let invalid = try JSONDecoder().decode(DoryDisplayQualificationRendererRestartRequest.self,
                                                   from: JSONSerialization.data(withJSONObject: body))
            #expect(throws: DoryDisplayQualificationInputError.invalidScript) {
                try invalid.validate(machineID: machine, service: service, operationID: operation, displayGeneration: 8, frameSequence: 44)
            }
        }
    }

    @Test func restartRequestReaderRejectsSymlinkAndOversizedAuthority() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dory-restart-unit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("request.json")
        try JSONEncoder().encode(request).write(to: path, options: .withoutOverwriting)
        let loaded = try DoryDisplayQualificationRendererRestartRequest.load(at: path.path)
        #expect(loaded.request == request)
        #expect(loaded.sha256.count == 64)
        let link = root.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: path)
        #expect(throws: (any Error).self) { try DoryDisplayQualificationRendererRestartRequest.load(at: link.path) }
        let big = root.appendingPathComponent("oversized.json")
        try Data(repeating: 32, count: 4097).write(to: big)
        #expect(throws: (any Error).self) { try DoryDisplayQualificationRendererRestartRequest.load(at: big.path) }
    }

    @Test func acknowledgementNeverClaimsCompletedRendererRecovery() throws {
        let receipt = DoryDisplayQualificationRendererRestartReceipt(completedAt: "2026-10-02T00:00:00Z",
            bundleIdentifier: "com.pythonxi.Dory", processID: 42, machineID: machine, machServiceName: service,
            operationID: operation, nonce: request.nonce, requestSHA256: String(repeating: "b", count: 64),
            beforeRendererGeneration: 7, beforeDisplayResourceGeneration: 8, beforeFrameSequence: 44,
            commandFrameSequence: 46, commandDisplayResourceGeneration: 3,
            commandMetalCommandBufferCompletionID: 19, commandSequence: 99)
        let body = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as? [String: Any])
        #expect(body["rendererRecoveryVerified"] as? Bool == false)
        #expect(body["delivery"] as? String == "runner-applied")
    }
}
