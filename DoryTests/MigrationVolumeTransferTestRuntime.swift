import Foundation
@testable import Dory

enum MigrationTestTar {
    static func singleFile(name: String, contents: Data) -> Data {
        files([(name, contents)])
    }

    static func files(_ files: [(String, Data)]) -> Data {
        var archive = Data()
        for (name, contents) in files {
            var header = Data(repeating: 0, count: 512)
            write(Data(name.utf8), to: &header, position: 0, count: 100)
            writeOctal(0o100644, to: &header, position: 100, count: 8)
            writeOctal(0, to: &header, position: 108, count: 8)
            writeOctal(0, to: &header, position: 116, count: 8)
            writeOctal(contents.count, to: &header, position: 124, count: 12)
            writeOctal(0, to: &header, position: 136, count: 12)
            for index in 148..<156 { header[index] = UInt8(ascii: " ") }
            header[156] = UInt8(ascii: "0")
            write(Data("ustar\0".utf8), to: &header, position: 257, count: 6)
            let checksum = header.reduce(0) { $0 + Int($1) }
            let checksumText = String(format: "%06o", checksum)
            write(Data(checksumText.utf8), to: &header, position: 148, count: 6)
            header[154] = 0
            header[155] = UInt8(ascii: " ")
            archive.append(header)
            archive.append(contents)
            let padding = (512 - contents.count % 512) % 512
            archive.append(Data(repeating: 0, count: padding))
        }
        archive.append(Data(repeating: 0, count: 1_024))
        return archive
    }

    private static func writeOctal(
        _ value: Int,
        to data: inout Data,
        position: Int,
        count: Int
    ) {
        let text = String(format: "%0*o", count - 1, value)
        write(Data(text.utf8), to: &data, position: position, count: count - 1)
        data[position + count - 1] = 0
    }

    private static func write(_ value: Data, to data: inout Data, position: Int, count: Int) {
        for (offset, byte) in value.prefix(count).enumerated() {
            data[position + offset] = byte
        }
    }
}

@MainActor
final class VolumeTransferRuntime: ContainerRuntime {
    enum Side { case source, target }
    enum Failure: Error { case injected }

    let kind: RuntimeKind = .docker
    nonisolated let supportsImageArchiveTransfer = true
    nonisolated let supportsImageLoadReceipt = true
    nonisolated let supportsRawProxy = true
    let metadata: MigrationTransferHelperMetadata
    let side: Side
    let dataArchive = Data("streamed-volume-archive".utf8)

    var initialManifest = Data()
    var sourceAfterManifest = Data()
    var targetManifest = Data()
    var createdSpecs: [ContainerSpec] = []
    var createdIDs: [String] = []
    var liveContainers: [String: ContainerSpec] = [:]
    var removedContainers: [String] = []
    var removedImages: [String] = []
    var imagePresent = false
    var receivedDataArchive = Data()
    var receivedManifestArchive = Data()
    var failingRole: String?
    var failDataArchiveStream = false
    var failImageCleanup = false

    init(metadata: MigrationTransferHelperMetadata, side: Side) {
        self.metadata = metadata
        self.side = side
    }

    func snapshot() async throws -> RuntimeSnapshot { RuntimeSnapshot() }
    func stop(containerID: String) async throws {}
    func restart(containerID: String) async throws {}
    func logs(containerID: String) async throws -> [LogLine] { [] }
    func env(containerID: String) async throws -> [EnvVar] { [] }
    func exec(containerID: String, command: [String]) async throws -> ExecResult {
        ExecResult(exitCode: 0, output: "")
    }

    func loadImage(tar: Data) async throws { imagePresent = true }

    func loadImageThrowingWithResponse(
        stream: AsyncThrowingStream<Data, Error>
    ) async throws -> Data {
        for try await _ in stream {}
        imagePresent = true
        return Data((
            #"{"stream":"Loaded image ID: \#(metadata.imageConfigDigest)\n"}"# + "\n"
        ).utf8)
    }

    func tagImage(source: String, repo: String, tag: String) async throws {}

    func removeImage(id: String) async throws {
        if failImageCleanup { throw Failure.injected }
        removedImages.append(id)
        imagePresent = false
    }

    func create(_ spec: ContainerSpec) async throws -> String {
        let id = "\(side)-helper-\(createdSpecs.count + 1)"
        createdSpecs.append(spec)
        createdIDs.append(id)
        liveContainers[id] = spec
        return id
    }

    func start(containerID: String) async throws {}

    func remove(containerID: String) async throws {
        removedContainers.append(containerID)
        liveContainers.removeValue(forKey: containerID)
    }

    func proxyRequest(
        method: String,
        path: String,
        headers: [(name: String, value: String)],
        body: Data
    ) async -> HTTPResponse? {
        if method == "GET", path.hasPrefix("/images/") {
            guard imagePresent else { return nil }
            let object: [String: Any] = [
                "Id": metadata.imageConfigDigest,
                "Architecture": "arm64",
                "Os": "linux",
                "RepoTags": [],
                "Config": [
                    "Entrypoint": ["/dory-transfer-helper"],
                    "User": "0",
                    "WorkingDir": "/",
                    "Labels": [
                        "dev.dory.component": "transfer-helper",
                        "dev.dory.helper.sha256": metadata.helperSha256,
                        "dev.dory.manifest.schema": "1"
                    ]
                ],
                "RootFS": ["Layers": [metadata.layerDiffId]]
            ]
            return response(object)
        }
        guard method == "GET", path.hasPrefix("/containers/"),
              let id = createdIDs.first(where: { path.contains($0) }),
              let spec = liveContainers[id] else { return nil }
        let role = spec.labels["dev.dory.operation.role"] ?? "unknown"
        let failed = role == failingRole
        return response([
            "State": [
                "Status": "exited",
                "Running": false,
                "ExitCode": failed ? 17 : 0,
                "Error": "",
                "OOMKilled": false
            ]
        ])
    }

    func copyOutStream(
        containerID: String,
        path: String
    ) -> AsyncThrowingStream<Data, Error> {
        guard let spec = liveContainers[containerID] else {
            return AsyncThrowingStream { $0.finish(throwing: Failure.injected) }
        }
        let role = spec.labels["dev.dory.operation.role"] ?? ""
        if path == "/data/." {
            let data = dataArchive
            let fail = failDataArchiveStream
            return AsyncThrowingStream { continuation in
                continuation.yield(Data(data.prefix(data.count / 2)))
                if fail {
                    continuation.finish(throwing: Failure.injected)
                } else {
                    continuation.yield(Data(data.suffix(from: data.count / 2)))
                    continuation.finish()
                }
            }
        }
        let manifest: Data
        switch role {
        case "source-scan": manifest = initialManifest
        case "source-rescan": manifest = sourceAfterManifest
        case "target-scan": manifest = targetManifest
        default: manifest = Data()
        }
        let archive = MigrationTestTar.singleFile(name: "manifest.json", contents: manifest)
        return AsyncThrowingStream { continuation in
            continuation.yield(Data(archive.prefix(700)))
            continuation.yield(Data(archive.dropFirst(700)))
            continuation.finish()
        }
    }

    func copyInThrowing(
        containerID: String,
        path: String,
        archiveStream: AsyncThrowingStream<Data, Error>
    ) async throws {
        var received = Data()
        for try await chunk in archiveStream { received.append(chunk) }
        if path == "/data" {
            receivedDataArchive = received
        } else if path == "/" {
            receivedManifestArchive = received
        } else {
            throw Failure.injected
        }
    }

    private func response(_ object: [String: Any]) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data()
        return HTTPResponse(statusCode: 200, reason: "OK", headers: [:], body: data)
    }
}
