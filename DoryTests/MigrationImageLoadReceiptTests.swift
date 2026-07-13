import Foundation
import Testing
@testable import Dory

@Suite struct MigrationImageLoadReceiptTests {
    private let imageID = "sha256:" + String(repeating: "a", count: 64)
    private let secondImageID = "sha256:" + String(repeating: "b", count: 64)

    @Test func parsesExactUntaggedImageIDAmongProgressMessages() throws {
        let response = lines(
            #"{"status":"Loading layer","id":"abc","progressDetail":{"current":1,"total":2}}"#,
            #"{"stream":"Loaded image ID: \#(imageID)\n"}"#
        )

        let receipt = try MigrationImageLoadReceipt.parse(response)

        #expect(receipt.loadedImageID == imageID)
    }

    @Test func acceptsRepeatedEvidenceForTheSameImageID() throws {
        let response = lines(
            #"{"stream":"Loaded image ID: \#(imageID)\nLoaded image ID: \#(imageID)\n"}"#
        )

        #expect(try MigrationImageLoadReceipt.parse(response).loadedImageID == imageID)
    }

    @Test func rejectsEmptyOrReceiptFreeResponses() {
        #expect(throws: MigrationImageLoadReceiptError.self) {
            try MigrationImageLoadReceipt.parse(Data())
        }
        #expect(throws: MigrationImageLoadReceiptError.self) {
            try MigrationImageLoadReceipt.parse(lines(#"{"status":"Loading layer"}"#))
        }
        #expect(throws: MigrationImageLoadReceiptError.self) {
            try MigrationImageLoadReceipt.parse(Data("\r\n".utf8))
        }
    }

    @Test func rejectsMultipleDistinctImageIDs() {
        let response = lines(
            #"{"stream":"Loaded image ID: \#(imageID)\nLoaded image ID: \#(secondImageID)\n"}"#
        )

        #expect(throws: MigrationImageLoadReceiptError.self) {
            try MigrationImageLoadReceipt.parse(response)
        }
    }

    @Test func rejectsMutableImageReferences() {
        let response = lines(#"{"stream":"Loaded image: example/app:latest\n"}"#)

        #expect(throws: MigrationImageLoadReceiptError.self) {
            try MigrationImageLoadReceipt.parse(response)
        }
    }

    @Test func rejectsErrorAndErrorDetailMessages() {
        let responses = [
            lines(#"{"error":"invalid archive"}"#),
            lines(#"{"errorDetail":{"message":"digest mismatch"}}"#),
            lines(
                #"{"stream":"Loaded image ID: \#(imageID)\n"}"#,
                #"{"error":"late failure"}"#
            )
        ]

        for response in responses {
            #expect(throws: MigrationImageLoadReceiptError.self) {
                try MigrationImageLoadReceipt.parse(response)
            }
        }
    }

    @Test func rejectsMalformedJSONAndNonUTF8() {
        #expect(throws: MigrationImageLoadReceiptError.self) {
            try MigrationImageLoadReceipt.parse(Data("not-json\n".utf8))
        }
        #expect(throws: MigrationImageLoadReceiptError.self) {
            try MigrationImageLoadReceipt.parse(Data([0xff, 0xfe]))
        }
    }

    @Test func rejectsOversizedResponsesBeforeParsing() {
        let response = Data(repeating: 0x20, count: MigrationImageLoadReceipt.maximumResponseBytes + 1)

        #expect(throws: MigrationImageLoadReceiptError.self) {
            try MigrationImageLoadReceipt.parse(response)
        }
    }

    @Test(arguments: [
        "sha256:" + String(repeating: "a", count: 63),
        "sha256:" + String(repeating: "A", count: 64),
        "sha512:" + String(repeating: "a", count: 64),
        String(repeating: "a", count: 64),
        "sha256:" + String(repeating: "g", count: 64),
        "sha256:" + String(repeating: "a", count: 64) + " trailing"
    ])
    func rejectsMalformedImmutableImageIDs(_ malformedID: String) {
        let response = lines(#"{"stream":"Loaded image ID: \#(malformedID)\n"}"#)

        #expect(throws: MigrationImageLoadReceiptError.self) {
            try MigrationImageLoadReceipt.parse(response)
        }
    }

    @Test func rejectsUnexpectedStdoutEvenWhenAnIDIsPresent() {
        let response = lines(
            #"{"stream":"warning: altered import behavior\nLoaded image ID: \#(imageID)\n"}"#
        )

        #expect(throws: MigrationImageLoadReceiptError.self) {
            try MigrationImageLoadReceipt.parse(response)
        }
    }
}

private extension MigrationImageLoadReceiptTests {
    func lines(_ messages: String...) -> Data {
        Data((messages.joined(separator: "\r\n") + "\r\n").utf8)
    }
}

@MainActor
@Suite struct MigrationImageLoadReceiptShimTests {
    @Test func shimPreservesTheEngineLoadReceiptByteForByte() async {
        let archive = Data("docker archive".utf8)
        let engineResponse = Data(
            (#"{"stream":"Loaded image ID: sha256:"}"#
                + String(repeating: "c", count: 64)
                + #"\n"}"#
                + "\r\n").utf8
        )
        let runtime = ImageReceiptRuntime(
            expectedArchive: archive,
            response: engineResponse
        )

        let response = await DockerShim(runtime: runtime).handle(ParsedRequest(
            method: "POST",
            target: "/v1.55/images/load",
            headers: ["content-type": "application/x-tar"],
            body: archive
        ))

        #expect(response.status == 200)
        #expect(response.headers.contains {
            $0.name.lowercased() == "content-type" && $0.value == "application/json"
        })
        #expect(response.body == engineResponse)
    }

    @Test func shimRejectsAnAdvertisedReceiptCapabilityWithNoReceipt() async throws {
        let archive = Data("docker archive".utf8)
        let runtime = ImageReceiptRuntime(expectedArchive: archive, response: Data())

        let response = await DockerShim(runtime: runtime).handle(ParsedRequest(
            method: "POST",
            target: "/v1.55/images/load",
            headers: ["content-type": "application/x-tar"],
            body: archive
        ))

        #expect(response.status == 502)
        let payload = try #require(
            try JSONSerialization.jsonObject(with: response.body) as? [String: String]
        )
        #expect(payload["message"] == "target engine returned an empty image-load response")
    }
}

private struct ImageReceiptRuntime: ContainerRuntime {
    let kind: RuntimeKind = .docker
    let expectedArchive: Data
    let response: Data

    nonisolated var supportsImageLoadReceipt: Bool { true }

    func snapshot() async throws -> RuntimeSnapshot { RuntimeSnapshot() }
    func start(containerID: String) async throws {}
    func stop(containerID: String) async throws {}
    func restart(containerID: String) async throws {}
    func remove(containerID: String) async throws {}
    func logs(containerID: String) async throws -> [LogLine] { [] }
    func env(containerID: String) async throws -> [EnvVar] { [] }
    func create(_ spec: ContainerSpec) async throws -> String { "created" }
    func exec(containerID: String, command: [String]) async throws -> ExecResult {
        ExecResult(exitCode: 0, output: "")
    }

    func loadImageThrowingWithResponse(
        stream: AsyncThrowingStream<Data, Error>
    ) async throws -> Data {
        var archive = Data()
        for try await chunk in stream { archive.append(chunk) }
        guard archive == expectedArchive else { throw ImageReceiptRuntimeError.archiveMismatch }
        return response
    }
}

private enum ImageReceiptRuntimeError: Error {
    case archiveMismatch
}
