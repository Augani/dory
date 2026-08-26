import Darwin
import DoryFSWorkerContracts
@testable import DoryFSWorkerServiceCore
import Foundation
import Testing

@Suite(.serialized)
struct DoryFSWorkerRootAuthorityTests {
    @Test func rootAuthorityErrorsMapToBoundedNonSensitiveBootstrapReasons() throws {
        let identifier = try capability(index: 1)
        let cases: [(DoryFSWorkerRootAuthorityError, DoryFSWorkerRPCFailureCode)] = [
            (.bookmarkResolutionFailed(identifier), .bootstrapBookmarkResolutionFailed),
            (.staleBookmark(identifier), .bootstrapBookmarkStale),
            (.securityScopeDenied(identifier), .bootstrapScopeActivationFailed),
            (.rootOpenFailed(identifier, errno: EACCES), .bootstrapRootOpenFailed),
            (.rootInspectionFailed(identifier, errno: EIO), .bootstrapRootOpenFailed),
            (.rootIdentityMismatch(identifier), .bootstrapRootIdentityMismatch),
        ]

        for (error, code) in cases {
            #expect(error.bootstrapFailureCode == code)
        }
    }

    @Test func acceptsAllSharesThenReturnsExactReceiptAndBoundedDescriptors() throws {
        let tree = try TemporaryDirectoryTree()
        let firstURL = try tree.makeDirectory("first")
        let secondURL = try tree.makeDirectory("second")
        let firstBookmark = Data([1, 1, 1])
        let secondBookmark = Data([2, 2, 2])
        let firstIdentity = try pinnedIdentity(of: firstURL)
        let secondIdentity = try pinnedIdentity(of: secondURL)
        let first = try share(
            index: 1,
            bookmark: firstBookmark,
            identity: firstIdentity
        )
        let second = try share(
            index: 2,
            bookmark: secondBookmark,
            identity: secondIdentity
        )
        let bootstrap = try makeBootstrap(shares: [second, first])
        let resolver = TestBookmarkResolver([
            firstBookmark: .init(url: firstURL),
            secondBookmark: .init(url: secondURL),
        ])
        var authority: DoryFSWorkerRootAuthority? = makeAuthority(resolver: resolver)

        let receiptBytes = try authority!.bootstrap(
            exactBytes: DoryFSWorkerBootstrapCodec.encode(bootstrap)
        )

        #expect(
            try DoryFSWorkerBootstrapCodec.decodeReceipt(receiptBytes)
                == DoryFSWorkerBootstrapReceipt(accepting: bootstrap)
        )
        #expect(resolver.startAttempts(for: firstURL) == 1)
        #expect(resolver.startAttempts(for: secondURL) == 1)
        #expect(resolver.activeScopes(for: firstURL) == 1)
        #expect(resolver.activeScopes(for: secondURL) == 1)

        var escapedDescriptor: Int32 = -1
        try authority!.withBorrowedRootFileDescriptor(for: first.capabilityID) { descriptor in
            escapedDescriptor = descriptor
            var status = stat()
            #expect(fstat(descriptor, &status) == 0)
            let observedIdentity = try identity(status)
            #expect(observedIdentity == firstIdentity)
            let statusFlags = fcntl(descriptor, F_GETFL)
            #expect(statusFlags >= 0)
            #expect(statusFlags & O_ACCMODE == O_RDONLY)
            let descriptorFlags = fcntl(descriptor, F_GETFD)
            #expect(descriptorFlags >= 0)
            #expect(descriptorFlags & FD_CLOEXEC != 0)
        }
        // Capturing the temporary integer cannot extend the lexical borrow.
        #expect(!descriptor(escapedDescriptor, stillNames: firstIdentity))

        let firstBeforeRelease = matchingDescriptors(firstIdentity)
        #expect(!firstBeforeRelease.isEmpty)
        authority = nil
        #expect(resolver.activeScopes(for: firstURL) == 0)
        #expect(resolver.activeScopes(for: secondURL) == 0)
        #expect(resolver.stopCalls(for: firstURL) == 1)
        #expect(resolver.stopCalls(for: secondURL) == 1)
        #expect(matchingDescriptors(firstIdentity).isDisjoint(with: firstBeforeRelease))
    }

    @Test func processAdmissionRejectsSecondAuthorityObject() throws {
        let tree = try TemporaryDirectoryTree()
        let root = try tree.makeDirectory("root")
        let bookmark = Data([3])
        let bootstrap = try makeBootstrap(shares: [
            share(index: 3, bookmark: bookmark, identity: pinnedIdentity(of: root)),
        ])
        let bytes = try DoryFSWorkerBootstrapCodec.encode(bootstrap)
        let resolver = TestBookmarkResolver([bookmark: .init(url: root)])
        let gate = DoryFSWorkerBootstrapAdmission()
        let first = DoryFSWorkerRootAuthority(
            resolver: resolver,
            bootstrapAdmission: gate
        )
        let second = DoryFSWorkerRootAuthority(
            resolver: resolver,
            bootstrapAdmission: gate
        )

        _ = try first.bootstrap(exactBytes: bytes)
        #expect(throws: DoryFSWorkerRootAuthorityError.bootstrapAlreadyAttempted) {
            _ = try second.bootstrap(exactBytes: bytes)
        }
        #expect(resolver.startAttempts(for: root) == 1)
    }

    @Test func malformedExactEnvelopeConsumesTheOnlyBootstrapAttempt() throws {
        let tree = try TemporaryDirectoryTree()
        let root = try tree.makeDirectory("root")
        let bookmark = Data([4])
        let bootstrap = try makeBootstrap(shares: [
            share(index: 4, bookmark: bookmark, identity: pinnedIdentity(of: root)),
        ])
        let valid = try DoryFSWorkerBootstrapCodec.encode(bootstrap)
        var trailing = valid
        trailing.append(0)
        let authority = makeAuthority(
            resolver: TestBookmarkResolver([bookmark: .init(url: root)])
        )

        #expect(throws: DoryFSWorkerBootstrapError.bootstrapLengthMismatch(
            declared: UInt32(valid.count),
            actual: trailing.count
        )) {
            _ = try authority.bootstrap(exactBytes: trailing)
        }
        #expect(throws: DoryFSWorkerRootAuthorityError.bootstrapAlreadyAttempted) {
            _ = try authority.bootstrap(exactBytes: valid)
        }
    }

    @Test func staleOneShotBookmarkIsAcceptedOnlyWhenPinnedIdentityStillMatches() throws {
        let tree = try TemporaryDirectoryTree()
        let root = try tree.makeDirectory("root")
        let bookmark = Data([5])
        let authorityShare = try share(
            index: 5,
            bookmark: bookmark,
            identity: pinnedIdentity(of: root)
        )
        let resolver = TestBookmarkResolver([
            bookmark: .init(url: root, isStale: true),
        ])
        var authority: DoryFSWorkerRootAuthority? = makeAuthority(resolver: resolver)

        _ = try authority!.bootstrap(exactBytes: encodedBootstrap([authorityShare]))
        #expect(resolver.startAttempts(for: root) == 1)
        #expect(resolver.activeScopes(for: root) == 1)
        authority = nil
        #expect(resolver.stopCalls(for: root) == 1)
        #expect(resolver.activeScopes(for: root) == 0)
    }

    @Test func staleBookmarkThatNoLongerNamesPinnedIdentityIsRejectedAndReleased() throws {
        let tree = try TemporaryDirectoryTree()
        let original = try tree.makeDirectory("original")
        let replacement = try tree.makeDirectory("replacement")
        let bookmark = Data([15])
        let authorityShare = try share(
            index: 15,
            bookmark: bookmark,
            identity: pinnedIdentity(of: original)
        )
        let resolver = TestBookmarkResolver([
            bookmark: .init(url: replacement, isStale: true),
        ])
        let authority = makeAuthority(resolver: resolver)

        #expect(throws: DoryFSWorkerRootAuthorityError.staleBookmark(
            authorityShare.capabilityID
        )) {
            _ = try authority.bootstrap(exactBytes: encodedBootstrap([authorityShare]))
        }
        #expect(resolver.startAttempts(for: replacement) == 1)
        #expect(resolver.stopCalls(for: replacement) == 1)
        #expect(resolver.activeScopes(for: replacement) == 0)
    }

    @Test func deniedSecurityScopeNeverOpensOrStopsAnUnstartedScope() throws {
        let tree = try TemporaryDirectoryTree()
        let root = try tree.makeDirectory("root")
        let bookmark = Data([6])
        let authorityShare = try share(
            index: 6,
            bookmark: bookmark,
            identity: pinnedIdentity(of: root)
        )
        let resolver = TestBookmarkResolver([
            bookmark: .init(url: root, allowsScope: false),
        ])
        let before = matchingDescriptors(try pinnedIdentity(of: root))
        let authority = makeAuthority(resolver: resolver)

        #expect(throws: DoryFSWorkerRootAuthorityError.securityScopeDenied(
            authorityShare.capabilityID
        )) {
            _ = try authority.bootstrap(exactBytes: encodedBootstrap([authorityShare]))
        }
        #expect(resolver.startAttempts(for: root) == 1)
        #expect(resolver.activeScopes(for: root) == 0)
        #expect(resolver.stopCalls(for: root) == 0)
        #expect(matchingDescriptors(try pinnedIdentity(of: root)) == before)
    }

    @Test func rejectsNonDirectoryAndSymbolicLinkRoots() throws {
        let tree = try TemporaryDirectoryTree()
        let file = try tree.makeFile("ordinary-file")
        let target = try tree.makeDirectory("target")
        let link = try tree.makeSymbolicLink("link", destination: target)

        try assertRootOpenRejected(url: file, index: 7)
        try assertRootOpenRejected(url: link, index: 8, expectedIdentityURL: target)
    }

    @Test func rejectsPathReplacementAgainstSealedIdentity() throws {
        let tree = try TemporaryDirectoryTree()
        let root = try tree.makeDirectory("root")
        let sealedIdentity = try pinnedIdentity(of: root)
        let preserved = tree.root.appendingPathComponent("preserved", isDirectory: true)
        try FileManager.default.moveItem(at: root, to: preserved)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        #expect(try pinnedIdentity(of: root) != sealedIdentity)

        let bookmark = Data([9])
        let authorityShare = try share(
            index: 9,
            bookmark: bookmark,
            identity: sealedIdentity
        )
        let resolver = TestBookmarkResolver([bookmark: .init(url: root)])
        let authority = makeAuthority(resolver: resolver)

        #expect(throws: DoryFSWorkerRootAuthorityError.rootIdentityMismatch(
            authorityShare.capabilityID
        )) {
            _ = try authority.bootstrap(exactBytes: encodedBootstrap([authorityShare]))
        }
        #expect(resolver.startAttempts(for: root) == 1)
        #expect(resolver.stopCalls(for: root) == 1)
        #expect(resolver.activeScopes(for: root) == 0)
    }

    @Test func partialMultiShareFailureRollsBackEveryEarlierRootAndScope() throws {
        let tree = try TemporaryDirectoryTree()
        let validRoot = try tree.makeDirectory("valid")
        let invalidRoot = try tree.makeFile("invalid")
        let validBookmark = Data([10])
        let invalidBookmark = Data([11])
        let validIdentity = try pinnedIdentity(of: validRoot)
        let validShare = try share(
            index: 10,
            bookmark: validBookmark,
            identity: validIdentity
        )
        let invalidShare = try share(
            index: 11,
            bookmark: invalidBookmark,
            identity: pinnedIdentity(of: invalidRoot)
        )
        let resolver = TestBookmarkResolver([
            validBookmark: .init(url: validRoot),
            invalidBookmark: .init(url: invalidRoot),
        ])
        let before = matchingDescriptors(validIdentity)
        let authority = makeAuthority(resolver: resolver)

        do {
            _ = try authority.bootstrap(
                exactBytes: encodedBootstrap([validShare, invalidShare])
            )
            Issue.record("bootstrap unexpectedly accepted a non-directory second share")
        } catch let error as DoryFSWorkerRootAuthorityError {
            guard case .rootOpenFailed(let capabilityID, _) = error else {
                Issue.record("unexpected authority error: \(error)")
                return
            }
            #expect(capabilityID == invalidShare.capabilityID)
        }

        #expect(resolver.startAttempts(for: validRoot) == 1)
        #expect(resolver.stopCalls(for: validRoot) == 1)
        #expect(resolver.activeScopes(for: validRoot) == 0)
        #expect(resolver.startAttempts(for: invalidRoot) == 1)
        #expect(resolver.stopCalls(for: invalidRoot) == 1)
        #expect(resolver.activeScopes(for: invalidRoot) == 0)
        #expect(matchingDescriptors(validIdentity) == before)
        #expect(throws: DoryFSWorkerRootAuthorityError.bootstrapNotAccepted) {
            try authority.withBorrowedRootFileDescriptor(for: validShare.capabilityID) { _ in }
        }
    }

    @Test func unknownCapabilityCannotBorrowOrAlterAcceptedAuthority() throws {
        let tree = try TemporaryDirectoryTree()
        let root = try tree.makeDirectory("root")
        let bookmark = Data([12])
        let accepted = try share(
            index: 12,
            bookmark: bookmark,
            identity: pinnedIdentity(of: root)
        )
        let authority = makeAuthority(
            resolver: TestBookmarkResolver([bookmark: .init(url: root)])
        )
        _ = try authority.bootstrap(exactBytes: encodedBootstrap([accepted]))
        let unknown = try capability(index: 13)
        var invoked = false

        #expect(throws: DoryFSWorkerRootAuthorityError.unknownCapability(unknown)) {
            try authority.withBorrowedRootFileDescriptor(for: unknown) { _ in
                invoked = true
            }
        }
        #expect(!invoked)

        // The accepted root remains usable after an unauthorized lookup.
        try authority.withBorrowedRootFileDescriptor(for: accepted.capabilityID) { descriptor in
            var status = stat()
            #expect(fstat(descriptor, &status) == 0)
        }
    }

    @Test func thrownBorrowClosesTemporaryDescriptorWithoutRevokingRoot() throws {
        enum ProbeError: Error { case stop }

        let tree = try TemporaryDirectoryTree()
        let root = try tree.makeDirectory("root")
        let rootIdentity = try pinnedIdentity(of: root)
        let bookmark = Data([14])
        let accepted = try share(
            index: 14,
            bookmark: bookmark,
            identity: rootIdentity
        )
        let authority = makeAuthority(
            resolver: TestBookmarkResolver([bookmark: .init(url: root)])
        )
        _ = try authority.bootstrap(exactBytes: encodedBootstrap([accepted]))
        var escaped: Int32 = -1

        #expect(throws: ProbeError.stop) {
            try authority.withBorrowedRootFileDescriptor(for: accepted.capabilityID) { descriptor in
                escaped = descriptor
                throw ProbeError.stop
            }
        }
        #expect(!descriptor(escaped, stillNames: rootIdentity))
        try authority.withBorrowedRootFileDescriptor(for: accepted.capabilityID) { descriptor in
            var status = stat()
            #expect(fstat(descriptor, &status) == 0)
            let observedIdentity = try identity(status)
            #expect(observedIdentity == rootIdentity)
        }
    }

    private func assertRootOpenRejected(
        url: URL,
        index: Int,
        expectedIdentityURL: URL? = nil
    ) throws {
        let bookmark = Data([UInt8(index)])
        let authorityShare = try share(
            index: index,
            bookmark: bookmark,
            identity: pinnedIdentity(of: expectedIdentityURL ?? url)
        )
        let resolver = TestBookmarkResolver([bookmark: .init(url: url)])
        let authority = makeAuthority(resolver: resolver)

        do {
            _ = try authority.bootstrap(exactBytes: encodedBootstrap([authorityShare]))
            Issue.record("bootstrap unexpectedly opened a non-directory or symbolic-link root")
        } catch let error as DoryFSWorkerRootAuthorityError {
            guard case .rootOpenFailed(let capabilityID, _) = error else {
                Issue.record("unexpected authority error: \(error)")
                return
            }
            #expect(capabilityID == authorityShare.capabilityID)
        }
        #expect(resolver.startAttempts(for: url) == 1)
        #expect(resolver.stopCalls(for: url) == 1)
        #expect(resolver.activeScopes(for: url) == 0)
    }
}

@Suite(.serialized)
struct DoryFSWorkerServiceTeardownTests {
    @Test func syncfsFallbackThenCommittedDestroyResetsResourcesAndClosesAdmission() throws {
        let tree = try TemporaryDirectoryTree()
        let root = try tree.makeDirectory("root")
        let file = root.appendingPathComponent("payload.txt")
        #expect(FileManager.default.createFile(atPath: file.path, contents: Data([0x44])))
        let fileIdentity = try pinnedIdentity(of: file)
        let baselineDescriptors = matchingDescriptors(fileIdentity)
        let bookmark = Data([20])
        let authorityShare = try share(
            index: 20,
            bookmark: bookmark,
            identity: pinnedIdentity(of: root)
        )
        let rootAuthority = DoryFSWorkerRootAuthority(
            resolver: TestBookmarkResolver([bookmark: .init(url: root)]),
            bootstrapAdmission: DoryFSWorkerBootstrapAdmission()
        )
        let service = DoryFSWorkerService(rootAuthority: rootAuthority)
        let bootstrap = try makeBootstrap(shares: [authorityShare])
        let bootstrapBytes = try DoryFSWorkerBootstrapCodec.encode(bootstrap)

        let receiptBytes = try unwrapRPC(service.bootstrap(exactBytes: bootstrapBytes))
        #expect(
            try DoryFSWorkerBootstrapCodec.decodeReceipt(receiptBytes)
                == DoryFSWorkerBootstrapReceipt(accepting: bootstrap)
        )

        let lookup = try execute(
            service: service,
            share: authorityShare,
            requestID: 1,
            unique: 101,
            opcode: .lookup,
            payload: Array("payload.txt\0".utf8),
            responseCapacity: FuseOutHeader.byteCount + 128
        )
        let lookupResponse = try completedResponse(lookup)
        let nodeID = [UInt8](lookupResponse).leUInt64(at: FuseOutHeader.byteCount)
        try commit(lookup, service: service)

        let open = try execute(
            service: service,
            share: authorityShare,
            requestID: 2,
            unique: 102,
            opcode: .open,
            nodeID: nodeID,
            payload: littleEndian(UInt32(O_RDONLY)) + littleEndian(UInt32(0)),
            responseCapacity: FuseOutHeader.byteCount + 16
        )
        _ = try completedResponse(open)
        try commit(open, service: service)
        #expect(matchingDescriptors(fileIdentity).count > baselineDescriptors.count)

        let unknown = try execute(
            service: service,
            share: authorityShare,
            requestID: 3,
            unique: 103,
            rawOpcode: UInt32.max,
            opcodeClass: .control,
            responseCapacity: FuseOutHeader.byteCount
        )
        #expect(unknown.outcome == .rejected(.invalidRequest))

        let sync = try execute(
            service: service,
            share: authorityShare,
            requestID: 4,
            unique: 104,
            opcode: .syncfs,
            payload: [UInt8](repeating: 0, count: 8),
            responseCapacity: FuseOutHeader.byteCount
        )
        let syncResponse = try completedResponse(sync)
        #expect(
            try FuseProtocol.decodeOutHeader([UInt8](syncResponse)).error
                == -FuseProtocol.linuxErrno(ENOSYS)
        )
        try commit(sync, service: service)

        let destroy = try execute(
            service: service,
            share: authorityShare,
            requestID: 5,
            unique: 105,
            opcode: .destroy,
            nodeID: 0,
            responseCapacity: FuseOutHeader.byteCount
        )
        #expect(try FuseProtocol.decodeOutHeader([UInt8](completedResponse(destroy))).error == 0)
        try commit(destroy, service: service)

        #expect(matchingDescriptors(fileIdentity) == baselineDescriptors)
        let afterDestroy = try execute(
            service: service,
            share: authorityShare,
            requestID: 6,
            unique: 106,
            opcode: .getattr,
            payload: FuseProtocol.encodeGetattrIn(FuseGetattrIn()),
            responseCapacity: FuseOutHeader.byteCount + 104
        )
        #expect(afterDestroy.outcome == .rejected(.connectionTeardown))
    }

    private func execute(
        service: DoryFSWorkerService,
        share: DoryFSShareBootstrapAuthority,
        requestID: UInt64,
        unique: UInt64,
        opcode: FuseOpcode,
        nodeID: UInt64 = HostFS.rootNodeID,
        payload: [UInt8] = [],
        responseCapacity: Int
    ) throws -> DoryFSWorkerReply {
        try execute(
            service: service,
            share: share,
            requestID: requestID,
            unique: unique,
            rawOpcode: opcode.rawValue,
            opcodeClass: opcode.workerOpcodeClass,
            nodeID: nodeID,
            payload: payload,
            responseCapacity: responseCapacity
        )
    }

    private func execute(
        service: DoryFSWorkerService,
        share: DoryFSShareBootstrapAuthority,
        requestID: UInt64,
        unique: UInt64,
        rawOpcode: UInt32,
        opcodeClass: DoryFSWorkerOpcodeClass,
        nodeID: UInt64 = HostFS.rootNodeID,
        payload: [UInt8] = [],
        responseCapacity: Int
    ) throws -> DoryFSWorkerReply {
        let requestBytes = FuseProtocol.encodeInHeader(FuseInHeader(
            length: UInt32(FuseInHeader.byteCount + payload.count),
            opcode: rawOpcode,
            unique: unique,
            nodeID: nodeID,
            uid: 1_000,
            gid: 1_000,
            pid: 42
        )) + payload
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        let request = try DoryFSWorkerRequest(
            generation: DoryFSWorkerGeneration(rawValue: 17),
            shareCapabilityID: share.capabilityID,
            requestID: requestID,
            correlationID: unique,
            opcodeClass: opcodeClass,
            responseCapacity: UInt32(responseCapacity),
            deadlineUptimeNanoseconds: deadline,
            payload: Data(requestBytes)
        )
        let frame = try DoryFSWorkerFrameCodec.encode(
            .execute(request),
            maximumFrameBytes: DoryFSWorkerLimits.production.maximumFrameBytes
        )
        let response = try unwrapRPC(service.exchange(exactFrame: frame))
        guard case .reply(let reply) = try DoryFSWorkerFrameCodec.decodeServiceFrame(
            response,
            maximumFrameBytes: DoryFSWorkerLimits.production.maximumFrameBytes
        ) else {
            throw DoryFSWorkerServiceTeardownTestError.unexpectedServiceFrame
        }
        return reply
    }

    private func completedResponse(_ reply: DoryFSWorkerReply) throws -> Data {
        guard case .completed(let response) = reply.outcome else {
            throw DoryFSWorkerServiceTeardownTestError.unexpectedReply(reply.outcome)
        }
        return response
    }

    private func commit(
        _ reply: DoryFSWorkerReply,
        service: DoryFSWorkerService
    ) throws {
        let publication = try DoryFSWorkerPublication(
            generation: reply.generation,
            shareCapabilityID: reply.shareCapabilityID,
            requestID: reply.requestID,
            correlationID: reply.correlationID
        )
        service.sendOneWay(exactFrame: try DoryFSWorkerFrameCodec.encode(
            .commitPublication(publication),
            maximumFrameBytes: DoryFSWorkerLimits.production.maximumFrameBytes
        ))
    }
}

private enum DoryFSWorkerServiceTeardownTestError: Error {
    case unexpectedRPCFailure(DoryFSWorkerRPCFailureCode)
    case unexpectedServiceFrame
    case unexpectedReply(DoryFSWorkerReplyOutcome)
}

private func unwrapRPC(_ data: Data) throws -> Data {
    switch try DoryFSWorkerRPCResultCodec.decode(data) {
    case .success(let payload):
        return payload
    case .failure(let code):
        throw DoryFSWorkerServiceTeardownTestError.unexpectedRPCFailure(code)
    }
}

private func littleEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
    var value = value.littleEndian
    return withUnsafeBytes(of: &value) { Array($0) }
}

private final class TestBookmarkResolver: DoryFSWorkerBookmarkResolving {
    struct Entry {
        let url: URL
        let isStale: Bool
        let allowsScope: Bool

        init(url: URL, isStale: Bool = false, allowsScope: Bool = true) {
            self.url = url
            self.isStale = isStale
            self.allowsScope = allowsScope
        }
    }

    enum ResolutionError: Error { case unknownBookmark }

    private let lock = NSLock()
    private let entries: [Data: Entry]
    private var starts = [URL: Int]()
    private var stops = [URL: Int]()
    private var active = [URL: Int]()

    init(_ entries: [Data: Entry]) {
        self.entries = entries
    }

    func resolve(_ bookmark: Data) throws -> DoryFSWorkerResolvedBookmark {
        guard let entry = entries[bookmark] else { throw ResolutionError.unknownBookmark }
        return DoryFSWorkerResolvedBookmark(url: entry.url, isStale: entry.isStale)
    }

    func startAccessingSecurityScopedResource(_ url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        starts[url, default: 0] += 1
        guard entries.values.first(where: { $0.url == url })?.allowsScope == true else {
            return false
        }
        active[url, default: 0] += 1
        return true
    }

    func stopAccessingSecurityScopedResource(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        stops[url, default: 0] += 1
        active[url, default: 0] -= 1
    }

    func startAttempts(for url: URL) -> Int {
        value(in: starts, for: url)
    }

    func stopCalls(for url: URL) -> Int {
        value(in: stops, for: url)
    }

    func activeScopes(for url: URL) -> Int {
        value(in: active, for: url)
    }

    private func value(in values: [URL: Int], for url: URL) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return values[url, default: 0]
    }
}

private final class TemporaryDirectoryTree {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "dory-fs-worker-root-authority-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
    }

    func makeDirectory(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    func makeFile(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: false)
        guard FileManager.default.createFile(atPath: url.path, contents: Data([0x44])) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return url
    }

    func makeSymbolicLink(_ name: String, destination: URL) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: false)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: destination)
        return url
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}

private func makeAuthority(
    resolver: TestBookmarkResolver
) -> DoryFSWorkerRootAuthority {
    DoryFSWorkerRootAuthority(
        resolver: resolver,
        bootstrapAdmission: DoryFSWorkerBootstrapAdmission()
    )
}

private func encodedBootstrap(
    _ shares: [DoryFSShareBootstrapAuthority]
) throws -> Data {
    try DoryFSWorkerBootstrapCodec.encode(makeBootstrap(shares: shares))
}

private func makeBootstrap(
    shares: [DoryFSShareBootstrapAuthority]
) throws -> DoryFSWorkerBootstrap {
    try DoryFSWorkerBootstrap(
        workspaceID: DoryFSWorkerWorkspaceID(
            rawValue: #require(UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"))
        ),
        generation: DoryFSWorkerGeneration(rawValue: 17),
        workerLimits: .production,
        shares: shares
    )
}

private func share(
    index: Int,
    bookmark: Data,
    identity: DoryFSPinnedRootIdentity
) throws -> DoryFSShareBootstrapAuthority {
    try DoryFSShareBootstrapAuthority(
        capabilityID: capability(index: index),
        expectedRootIdentity: identity,
        readOnly: index.isMultiple(of: 2),
        guestIdentity: DoryFSGuestIdentityPolicy(uid: 1_000, gid: 1_000),
        resourceLimits: .production,
        securityScopedBookmark: bookmark,
        hiddenComponents: [".git"],
        rootHiddenComponents: ["library"]
    )
}

private func capability(index: Int) throws -> DoryFSShareCapabilityID {
    precondition((1...255).contains(index))
    return try DoryFSShareCapabilityID(rawValue: UUID(uuid: (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, UInt8(index)
    )))
}

private func pinnedIdentity(of url: URL) throws -> DoryFSPinnedRootIdentity {
    var status = stat()
    let result: Int32 = url.withUnsafeFileSystemRepresentation { representation in
        guard let representation else { return Int32(-1) }
        return lstat(representation, &status)
    }
    guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    return try identity(status)
}

private func identity(_ status: stat) throws -> DoryFSPinnedRootIdentity {
    try DoryFSPinnedRootIdentity(
        device: UInt64(truncatingIfNeeded: status.st_dev),
        inode: UInt64(truncatingIfNeeded: status.st_ino),
        generation: UInt64(truncatingIfNeeded: status.st_gen)
    )
}

private func descriptor(
    _ descriptor: Int32,
    stillNames expected: DoryFSPinnedRootIdentity
) -> Bool {
    guard descriptor >= 0 else { return false }
    var status = stat()
    guard fstat(descriptor, &status) == 0 else { return false }
    return (try? identity(status)) == expected
}

private func matchingDescriptors(
    _ expected: DoryFSPinnedRootIdentity
) -> Set<Int32> {
    var result = Set<Int32>()
    for descriptor in Int32(0)..<Int32(4_096) {
        if selfDescriptor(descriptor, names: expected) {
            result.insert(descriptor)
        }
    }
    return result
}

private func selfDescriptor(
    _ descriptor: Int32,
    names expected: DoryFSPinnedRootIdentity
) -> Bool {
    var status = stat()
    guard fstat(descriptor, &status) == 0 else { return false }
    return (try? identity(status)) == expected
}
