import CryptoKit
import Darwin
import Foundation
import Testing
@testable import DoryOperations

private struct RestoreHTTPPlan: Sendable {
    var status = 200
    var headers: [String: String]
    var payload: Data
    var holdOpen = false
    var failure: URLError?
}

private final class RestoreHTTPRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var plans: [String: [RestoreHTTPPlan]] = [:]
    private var calls: [String: [URLRequest]] = [:]

    func set(_ plans: [RestoreHTTPPlan], url: URL) {
        lock.lock(); defer { lock.unlock() }
        self.plans[url.absoluteString] = plans
    }

    func take(_ request: URLRequest) -> RestoreHTTPPlan? {
        lock.lock(); defer { lock.unlock() }
        let key = request.url!.absoluteString
        calls[key, default: []].append(request)
        guard var values = plans[key], !values.isEmpty else { return nil }
        let plan = values.removeFirst()
        plans[key] = values
        return plan
    }

    func requests(_ url: URL) -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return calls[url.absoluteString] ?? []
    }
}

private final class RestoreHTTPProtocol: URLProtocol, @unchecked Sendable {
    static let registry = RestoreHTTPRegistry()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let plan = Self.registry.take(request), let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: plan.status, httpVersion: "HTTP/1.1", headerFields: plan.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: plan.payload)
        if let error = plan.failure { client?.urlProtocol(self, didFailWithError: error) }
        else if !plan.holdOpen { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() {}
}

private final class RestoreFixture: Sendable {
    let directory: URL
    let request: DoryRestoreImageDownloadRequest
    let session: URLSession
    let store: DoryRestoreImageDownloadStore
    let payload = Data("signed-image-fixture-bytes-not-a-real-ipsw".utf8)
    let tag = "\"apple-build-fixture\""

    init() throws {
        directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("dory-restore-test-" + UUID().uuidString, isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        request = try .init(sourceURL: URL(string: "https://updates.cdn-apple.com/" + UUID().uuidString + "/UniversalMac.ipsw")!,
                            build: "24A335", version: "15.0.0")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RestoreHTTPProtocol.self]
        session = URLSession(configuration: configuration)
        store = DoryRestoreImageDownloadStore(directory: directory, session: session)
    }

    deinit {
        session.invalidateAndCancel()
        try? FileManager.default.removeItem(at: directory)
    }

    func set(_ plans: [RestoreHTTPPlan]) { RestoreHTTPProtocol.registry.set(plans, url: request.sourceURL) }
    func full(_ data: Data? = nil) -> RestoreHTTPPlan {
        let data = data ?? payload
        return .init(headers: ["Content-Length": String(data.count), "ETag": tag], payload: data)
    }
    func partial(_ prefix: Int) -> RestoreHTTPPlan {
        .init(headers: ["Content-Length": String(payload.count), "ETag": tag], payload: payload.prefix(prefix))
    }
    func resume(_ offset: Int) -> RestoreHTTPPlan {
        .init(status: 206, headers: ["Content-Length": String(payload.count - offset), "ETag": tag,
                                    "Content-Range": "bytes \(offset)-\(payload.count - 1)/\(payload.count)"],
              payload: payload.dropFirst(offset))
    }
    var part: URL { directory.appendingPathComponent(request.cacheKey + ".partial") }
    var journal: URL { part.appendingPathExtension("json") }
    func mutateJournal(_ mutation: (inout [String: Any]) -> Void) throws {
        var value = try JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as! [String: Any]
        mutation(&value)
        try JSONSerialization.data(withJSONObject: value).write(to: journal)
    }
}

struct DoryRestoreImageDownloadTests {
    @Test func requestRejectsMirrorsPlainHTTPAuthorityAndMalformedIdentity() throws {
        for source in ["http://updates.apple.com/image.ipsw", "https://evil.test/image.ipsw", "https://apple.com.evil.test/image.ipsw",
                       "https://updates.apple.com.evil.test/image.ipsw", "https://user@updates.apple.com/image.ipsw",
                       "https://updates.apple.com:8443/image.ipsw", "file:///tmp/image.ipsw",
                       "https://updates.apple.com/image.zip", "https://updates.apple.com/image.ipsw#fragment"] {
            #expect(throws: DoryRestoreImageDownloadError.invalidSource) {
                try DoryRestoreImageDownloadRequest(sourceURL: URL(string: source)!, build: "24A335", version: "15.0.0")
            }
        }
        #expect(throws: DoryRestoreImageDownloadError.invalidSource) {
            try DoryRestoreImageDownloadRequest(sourceURL: URL(string: "https://updates.apple.com/image.ipsw")!, build: "../escape", version: "15.0.0")
        }
        #expect(throws: DoryRestoreImageDownloadError.invalidSource) {
            try DoryRestoreImageDownloadRequest(sourceURL: URL(string: "https://updates.apple.com/image.ipsw")!, build: "24A335", version: "..")
        }
    }

    @Test func completeTransferHasPrivateDurableDigestAndNoNetworkCacheReplay() async throws {
        let f = try RestoreFixture(); f.set([f.full()])
        let url = try await f.store.download(f.request)
        #expect(try Data(contentsOf: url) == f.payload)
        let receipt = try JSONDecoder().decode(DoryRestoreImageDownloadReceipt.self, from: Data(contentsOf: url.appendingPathExtension("json")))
        #expect(receipt.request == f.request && receipt.byteCount == f.payload.count)
        #expect(receipt.sha256 == DoryRestoreImageDownloadRequest.digest(f.payload))
        var info = stat(); #expect(lstat(url.path, &info) == 0 && info.st_mode & 0o777 == 0o600)
        #expect(!FileManager.default.fileExists(atPath: f.part.path))
        #expect(!FileManager.default.fileExists(atPath: f.journal.path))
        #expect(try await f.store.download(f.request) == url)
        #expect(RestoreHTTPProtocol.registry.requests(f.request.sourceURL).count == 1)
    }

    @Test func truncatedTransferResumesFrozenBuildAcrossStoreRestart() async throws {
        let f = try RestoreFixture(); f.set([f.partial(13), f.resume(13)])
        await #expect(throws: DoryRestoreImageDownloadError.truncated) { try await f.store.download(f.request) }
        let restarted = DoryRestoreImageDownloadStore(directory: f.directory, session: f.session)
        #expect(try await restarted.pendingRequest() == f.request)
        let url = try await restarted.download(f.request)
        #expect(try Data(contentsOf: url) == f.payload)
        let calls = RestoreHTTPProtocol.registry.requests(f.request.sourceURL)
        #expect(calls.count == 2 && calls[1].value(forHTTPHeaderField: "Range") == "bytes=13-")
        #expect(calls[1].value(forHTTPHeaderField: "If-Range") == f.tag)
    }

    @Test func cancellationJoinsTransferRetainsPrefixAndAllowsResume() async throws {
        let f = try RestoreFixture()
        let payload = Data(repeating: 42, count: 512 * 1024)
        let initial = RestoreHTTPPlan(headers: ["Content-Length": String(payload.count), "ETag": f.tag],
                                      payload: payload.prefix(256 * 1024), holdOpen: true)
        f.set([initial, .init(status: 206, headers: ["Content-Length": String(256 * 1024), "ETag": f.tag,
                        "Content-Range": "bytes \(256 * 1024)-\(payload.count - 1)/\(payload.count)"], payload: payload.dropFirst(256 * 1024))])
        let (updates, continuation) = AsyncStream<DoryRestoreImageDownloadProgress>.makeStream()
        let task = Task { try await f.store.download(f.request) { continuation.yield($0) } }
        for await update in updates where update.completedBytes >= 256 * 1024 { task.cancel(); break }
        do { _ = try await task.value; Issue.record("cancelled transfer unexpectedly completed") } catch {}
        continuation.finish()
        #expect(try Data(contentsOf: f.part).count == 256 * 1024)
        let url = try await f.store.download(f.request)
        #expect(try Data(contentsOf: url) == payload)
    }

    @Test func damagedPartialDoesNotSendNetworkRequestOrOverwriteBytes() async throws {
        let f = try RestoreFixture(); f.set([f.partial(13)])
        await #expect(throws: DoryRestoreImageDownloadError.truncated) { try await f.store.download(f.request) }
        try Data(repeating: 0, count: 13).write(to: f.part)
        await #expect(throws: DoryRestoreImageDownloadError.damagedPartial) { try await f.store.download(f.request) }
        #expect(RestoreHTTPProtocol.registry.requests(f.request.sourceURL).count == 1)
        #expect(try Data(contentsOf: f.part) == Data(repeating: 0, count: 13))
    }

    @Test func forgedJournalCannotRetargetRequestClaimMissingBytesOrOversizedImage() async throws {
        for mutation in 0..<3 {
            let f = try RestoreFixture(); f.set([f.partial(13)])
            await #expect(throws: DoryRestoreImageDownloadError.truncated) { try await f.store.download(f.request) }
            try f.mutateJournal { value in
                if mutation == 0 { value["committedBytes"] = 99 }
                if mutation == 1 { value["totalBytes"] = DoryRestoreImageDownloadStore.maximumImageBytes + 1 }
                if mutation == 2 {
                    var request = value["request"] as! [String: Any]; request["build"] = "another-build"; value["request"] = request
                }
            }
            await #expect(throws: DoryRestoreImageDownloadError.damagedPartial) { try await f.store.download(f.request) }
            #expect(RestoreHTTPProtocol.registry.requests(f.request.sourceURL).count == 1)
        }
    }

    @Test func durableCompletedCheckpointPublishesWithoutNetworkAndNeverReturnsPartialPath() async throws {
        let f = try RestoreFixture(); f.set([f.partial(13)])
        await #expect(throws: DoryRestoreImageDownloadError.truncated) { try await f.store.download(f.request) }
        try f.payload.write(to: f.part)
        try f.mutateJournal { value in
            value["committedBytes"] = f.payload.count
            value["committedSHA256"] = DoryRestoreImageDownloadRequest.digest(f.payload)
            value["transferComplete"] = true
        }
        let recovered = DoryRestoreImageDownloadStore(directory: f.directory, session: f.session)
        let url = try await recovered.download(f.request)
        #expect(url.pathExtension == "ipsw" && url != f.part)
        #expect(try Data(contentsOf: url) == f.payload)
        #expect(RestoreHTTPProtocol.registry.requests(f.request.sourceURL).count == 1)
    }

    @Test func uncommittedCrashTailIsDiscardedBeforeExactRangeResume() async throws {
        let f = try RestoreFixture(); f.set([f.partial(13), f.resume(13)])
        await #expect(throws: DoryRestoreImageDownloadError.truncated) { try await f.store.download(f.request) }
        let handle = try FileHandle(forWritingTo: f.part); try handle.seekToEnd(); try handle.write(contentsOf: Data("crash-tail".utf8)); try handle.close()
        let url = try await f.store.download(f.request)
        #expect(try Data(contentsOf: url) == f.payload)
    }

    @Test func wrongEntityIgnoredRangeAndWrongRangeAreRejectedWithoutMixing() async throws {
        for mutation in 0..<3 {
            let f = try RestoreFixture(); var response = f.resume(13)
            if mutation == 0 { response.headers["ETag"] = "\"another-build\"" }
            if mutation == 1 { response.status = 200 }
            if mutation == 2 { response.headers["Content-Range"] = "bytes 14-\(f.payload.count - 1)/\(f.payload.count)" }
            f.set([f.partial(13), response])
            await #expect(throws: DoryRestoreImageDownloadError.truncated) { try await f.store.download(f.request) }
            do { _ = try await f.store.download(f.request); Issue.record("invalid range/entity accepted") } catch {}
            #expect(try Data(contentsOf: f.part) == f.payload.prefix(13))
            #expect(!FileManager.default.fileExists(atPath: f.directory.appendingPathComponent(f.request.cacheKey + ".ipsw").path))
        }
    }

    @Test func weakOrAbsentEntityTagCannotResumePartialImage() async throws {
        for tag in [nil, "W/\"weak\""] as [String?] {
            let f = try RestoreFixture(); var response = f.partial(13); response.headers["ETag"] = tag; f.set([response])
            await #expect(throws: DoryRestoreImageDownloadError.truncated) { try await f.store.download(f.request) }
            await #expect(throws: DoryRestoreImageDownloadError.changedSource) { try await f.store.download(f.request) }
            #expect(RestoreHTTPProtocol.registry.requests(f.request.sourceURL).count == 1)
        }
    }

    @Test func oversizedBodyAndInvalidEncodingNeverPublish() async throws {
        for encoding in [false, true] {
            let f = try RestoreFixture(); var response = f.full()
            if encoding { response.headers["Content-Encoding"] = "gzip" }
            else { response.headers["Content-Length"] = "3" }
            f.set([response])
            await #expect(throws: DoryRestoreImageDownloadError.invalidResponse) { try await f.store.download(f.request) }
            #expect(!FileManager.default.fileExists(atPath: f.directory.appendingPathComponent(f.request.cacheKey + ".ipsw").path))
        }
    }

    @Test func byteCompleteFailedStreamMustReacquireFinalByteNotPublishFromFailure() async throws {
        let f = try RestoreFixture()
        let payload = Data(repeating: 42, count: 256 * 1024)
        var response = f.full(payload); response.failure = URLError(.networkConnectionLost)
        f.set([response, .init(status: 206, headers: ["Content-Length": "1", "ETag": f.tag,
                        "Content-Range": "bytes \(payload.count - 1)-\(payload.count - 1)/\(payload.count)"], payload: payload.suffix(1))])
        do { _ = try await f.store.download(f.request); Issue.record("failed stream published") } catch {}
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: f.journal)) as! [String: Any]
        // Foundation may surface the transport error before draining the final network buffer;
        // exercise the exact all-bytes/no-EOF journal state independently as well.
        if (saved["committedBytes"] as? Int) != payload.count {
            try payload.write(to: f.part)
            try f.mutateJournal { value in
                value["committedBytes"] = payload.count
                value["committedSHA256"] = DoryRestoreImageDownloadRequest.digest(payload)
            }
        }
        let url = try await f.store.download(f.request)
        #expect(try Data(contentsOf: url) == payload)
        #expect(RestoreHTTPProtocol.registry.requests(f.request.sourceURL).last?.value(forHTTPHeaderField: "Range") == "bytes=\(payload.count - 1)-")
    }

    @Test func completedCacheMutationAndSymlinkAreRejectedWithoutRedownload() async throws {
        let f = try RestoreFixture(); f.set([f.full()])
        let url = try await f.store.download(f.request)
        try Data("changed".utf8).write(to: url)
        await #expect(throws: DoryRestoreImageDownloadError.damagedPartial) { try await f.store.download(f.request) }
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: f.journal)
        await #expect(throws: DoryRestoreImageDownloadError.unsafeCache) { try await f.store.download(f.request) }
        #expect(RestoreHTTPProtocol.registry.requests(f.request.sourceURL).count == 1)
    }

    @Test func explicitRestartOnlyRemovesThisPrivatePartialAndLeavesCompletedOrForeignImages() async throws {
        let f = try RestoreFixture(); f.set([f.partial(13), f.full()])
        await #expect(throws: DoryRestoreImageDownloadError.truncated) { try await f.store.download(f.request) }
        let foreign = f.directory.appendingPathComponent("user.ipsw"); try Data("original".utf8).write(to: foreign)
        try await f.store.discardPartial(f.request)
        #expect(!FileManager.default.fileExists(atPath: f.part.path) && !FileManager.default.fileExists(atPath: f.journal.path))
        let url = try await f.store.download(f.request)
        try await f.store.discardPartial(f.request)
        #expect(try Data(contentsOf: url) == f.payload && Data(contentsOf: foreign) == Data("original".utf8))
    }

    @Test func indirectSharedAndHardLinkedCacheEntriesAreNeverReadOrDeleted() async throws {
        let f = try RestoreFixture()
        let external = f.directory.appendingPathComponent("external"); try Data("private".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(at: f.part, withDestinationURL: external)
        do { try await f.store.discardPartial(f.request); Issue.record("symlink removed") } catch {}
        #expect(try Data(contentsOf: external) == Data("private".utf8))
        try FileManager.default.removeItem(at: f.part)
        #expect(link(external.path, f.part.path) == 0)
        do { try await f.store.discardPartial(f.request); Issue.record("hard link removed") } catch {}
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.directory.path)
        await #expect(throws: DoryRestoreImageDownloadError.unsafeCache) { try await f.store.pendingRequest() }
    }

    @Test func independentlyOpenedStoreCannotRaceActiveTransferOrDiscard() async throws {
        let f = try RestoreFixture(); var response = f.full(Data(repeating: 1, count: 256 * 1024)); response.holdOpen = true; f.set([response])
        let (updates, continuation) = AsyncStream<DoryRestoreImageDownloadProgress>.makeStream()
        let task = Task { try await f.store.download(f.request) { continuation.yield($0) } }
        for await update in updates where update.completedBytes > 0 { break }
        let another = DoryRestoreImageDownloadStore(directory: f.directory, session: f.session)
        await #expect(throws: DoryRestoreImageDownloadError.busy) { try await another.download(f.request) }
        await #expect(throws: DoryRestoreImageDownloadError.busy) { try await another.discardPartial(f.request) }
        await #expect(throws: DoryRestoreImageDownloadError.busy) { try await f.store.discardPartial(f.request) }
        task.cancel(); _ = try? await task.value; continuation.finish()
    }

    @Test func responseValidationRejectsForeignHTTPSAndMalformedOrOversizedLengths() throws {
        let f = try RestoreFixture()
        for (url, headers) in [(URL(string: "https://mirror.test/image.ipsw")!, ["Content-Length": "10"]),
                              (f.request.sourceURL, ["Content-Length": "-1"]),
                              (f.request.sourceURL, ["Content-Length": "999999999999"]),
                              (f.request.sourceURL, ["Content-Length": "10", "Content-Range": "bytes 0-9/10"])] {
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
            #expect(throws: DoryRestoreImageDownloadError.invalidResponse) {
                try DoryRestoreImageDownloadStore.validateResponse(response, request: f.request, offset: 0, priorTotal: 0, priorTag: nil)
            }
        }
    }
}
