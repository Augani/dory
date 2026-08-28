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
            (.descriptorCountMismatch(expected: 1, actual: 0), .bootstrapDescriptorTransferFailed),
            (.rootDescriptorUnavailable(identifier, errno: EBADF), .bootstrapDescriptorTransferFailed),
            (.rootInspectionFailed(identifier, errno: EIO), .bootstrapRootOpenFailed),
            (.rootIsNotDirectory(identifier), .bootstrapRootOpenFailed),
            (.rootIdentityMismatch(identifier), .bootstrapRootIdentityMismatch),
        ]

        for (error, code) in cases {
            #expect(error.bootstrapFailureCode == code)
        }
    }

    @Test func acceptsAllDescriptorsBySealedOrdinalAndBoundsBorrows() throws {
        let tree = try TemporaryDirectoryTree()
        let firstURL = try tree.makeDirectory("first")
        let secondURL = try tree.makeDirectory("second")
        let firstHandle = try openHandle(firstURL, directoryOnly: true)
        let secondHandle = try openHandle(secondURL, directoryOnly: true)
        let firstIdentity = try pinnedIdentity(of: firstHandle)
        let secondIdentity = try pinnedIdentity(of: secondHandle)
        let first = try share(index: 200, descriptorIndex: 0, identity: firstIdentity)
        let second = try share(index: 1, descriptorIndex: 1, identity: secondIdentity)
        let bootstrap = try makeBootstrap(shares: [first, second])
        var authority: DoryFSWorkerRootAuthority? = makeAuthority()

        let receiptBytes = try authority!.bootstrap(
            exactBytes: DoryFSWorkerBootstrapCodec.encode(bootstrap),
            rootDescriptors: [firstHandle, secondHandle]
        )

        #expect(
            try DoryFSWorkerBootstrapCodec.decodeReceipt(receiptBytes)
                == DoryFSWorkerBootstrapReceipt(accepting: bootstrap)
        )
        #expect(matchingDescriptors(firstIdentity).count == 2)
        #expect(matchingDescriptors(secondIdentity).count == 2)

        var escapedDescriptor: Int32 = -1
        try authority!.withBorrowedRootFileDescriptor(for: first.capabilityID) { descriptor in
            escapedDescriptor = descriptor
            #expect(descriptorNames(descriptor, identity: firstIdentity))
            #expect(fcntl(descriptor, F_GETFD) & FD_CLOEXEC != 0)
        }
        #expect(!descriptorNames(escapedDescriptor, identity: firstIdentity))

        authority = nil
        #expect(matchingDescriptors(firstIdentity).count == 1)
        #expect(matchingDescriptors(secondIdentity).count == 1)
    }

    @Test func descriptorCountMismatchConsumesAttemptWithoutOpeningRoots() throws {
        let tree = try TemporaryDirectoryTree()
        let root = try tree.makeDirectory("root")
        let handle = try openHandle(root, directoryOnly: true)
        let identity = try pinnedIdentity(of: handle)
        let authorityShare = try share(index: 2, descriptorIndex: 0, identity: identity)
        let bytes = try encodedBootstrap([authorityShare])
        let baseline = matchingDescriptors(identity)
        let authority = makeAuthority()

        #expect(throws: DoryFSWorkerRootAuthorityError.descriptorCountMismatch(
            expected: 1,
            actual: 0
        )) {
            _ = try authority.bootstrap(exactBytes: bytes, rootDescriptors: [])
        }
        #expect(matchingDescriptors(identity) == baseline)
        #expect(throws: DoryFSWorkerRootAuthorityError.bootstrapAlreadyAttempted) {
            _ = try authority.bootstrap(exactBytes: bytes, rootDescriptors: [handle])
        }
    }

    @Test func closedTransferredDescriptorIsRejectedWithoutPathFallback() throws {
        let tree = try TemporaryDirectoryTree()
        let root = try tree.makeDirectory("root")
        let descriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        #expect(descriptor >= 0)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let identity = try pinnedIdentity(of: handle)
        let authorityShare = try share(index: 3, descriptorIndex: 0, identity: identity)
        _ = Darwin.close(descriptor)
        let authority = makeAuthority()

        do {
            _ = try authority.bootstrap(
                exactBytes: encodedBootstrap([authorityShare]),
                rootDescriptors: [handle]
            )
            Issue.record("closed descriptor unexpectedly accepted")
        } catch let error as DoryFSWorkerRootAuthorityError {
            guard case .rootDescriptorUnavailable(let capability, let observedErrno) = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
            #expect(capability == authorityShare.capabilityID)
            #expect(observedErrno == EBADF)
        }
    }

    @Test func nonDirectoryDescriptorIsRejected() throws {
        let tree = try TemporaryDirectoryTree()
        let file = try tree.makeFile("ordinary-file")
        let handle = try openHandle(file, directoryOnly: false)
        let authorityShare = try share(
            index: 4,
            descriptorIndex: 0,
            identity: pinnedIdentity(of: handle)
        )
        let authority = makeAuthority()

        #expect(throws: DoryFSWorkerRootAuthorityError.rootIsNotDirectory(
            authorityShare.capabilityID
        )) {
            _ = try authority.bootstrap(
                exactBytes: encodedBootstrap([authorityShare]),
                rootDescriptors: [handle]
            )
        }
    }

    @Test func descriptorIdentityMismatchIsRejected() throws {
        let tree = try TemporaryDirectoryTree()
        let sealed = try openHandle(tree.makeDirectory("sealed"), directoryOnly: true)
        let replacement = try openHandle(tree.makeDirectory("replacement"), directoryOnly: true)
        let authorityShare = try share(
            index: 5,
            descriptorIndex: 0,
            identity: pinnedIdentity(of: sealed)
        )
        let authority = makeAuthority()

        #expect(throws: DoryFSWorkerRootAuthorityError.rootIdentityMismatch(
            authorityShare.capabilityID
        )) {
            _ = try authority.bootstrap(
                exactBytes: encodedBootstrap([authorityShare]),
                rootDescriptors: [replacement]
            )
        }
    }

    @Test func partialFailureRollsBackEveryEarlierDuplicate() throws {
        let tree = try TemporaryDirectoryTree()
        let valid = try openHandle(tree.makeDirectory("valid"), directoryOnly: true)
        let sealedInvalid = try openHandle(tree.makeDirectory("sealed-invalid"), directoryOnly: true)
        let replacement = try openHandle(tree.makeDirectory("replacement"), directoryOnly: true)
        let validIdentity = try pinnedIdentity(of: valid)
        let validShare = try share(index: 6, descriptorIndex: 0, identity: validIdentity)
        let invalidShare = try share(
            index: 7,
            descriptorIndex: 1,
            identity: pinnedIdentity(of: sealedInvalid)
        )
        let baseline = matchingDescriptors(validIdentity)
        let authority = makeAuthority()

        #expect(throws: DoryFSWorkerRootAuthorityError.rootIdentityMismatch(
            invalidShare.capabilityID
        )) {
            _ = try authority.bootstrap(
                exactBytes: encodedBootstrap([validShare, invalidShare]),
                rootDescriptors: [valid, replacement]
            )
        }
        #expect(matchingDescriptors(validIdentity) == baseline)
        #expect(throws: DoryFSWorkerRootAuthorityError.bootstrapNotAccepted) {
            try authority.withBorrowedRootFileDescriptor(for: validShare.capabilityID) { _ in () }
        }
    }

    @Test func sharedAdmissionRejectsSecondAuthorityObject() throws {
        let tree = try TemporaryDirectoryTree()
        let handle = try openHandle(tree.makeDirectory("root"), directoryOnly: true)
        let authorityShare = try share(
            index: 8,
            descriptorIndex: 0,
            identity: pinnedIdentity(of: handle)
        )
        let bytes = try encodedBootstrap([authorityShare])
        let gate = DoryFSWorkerBootstrapAdmission()
        let first = DoryFSWorkerRootAuthority(bootstrapAdmission: gate)
        let second = DoryFSWorkerRootAuthority(bootstrapAdmission: gate)

        _ = try first.bootstrap(exactBytes: bytes, rootDescriptors: [handle])
        #expect(throws: DoryFSWorkerRootAuthorityError.bootstrapAlreadyAttempted) {
            _ = try second.bootstrap(exactBytes: bytes, rootDescriptors: [handle])
        }
    }

    @Test func malformedEnvelopeConsumesTheOnlyBootstrapAttempt() throws {
        let tree = try TemporaryDirectoryTree()
        let handle = try openHandle(tree.makeDirectory("root"), directoryOnly: true)
        let authorityShare = try share(
            index: 9,
            descriptorIndex: 0,
            identity: pinnedIdentity(of: handle)
        )
        let valid = try encodedBootstrap([authorityShare])
        var malformed = valid
        malformed.append(0)
        let authority = makeAuthority()

        #expect(throws: DoryFSWorkerBootstrapError.bootstrapLengthMismatch(
            declared: UInt32(valid.count),
            actual: malformed.count
        )) {
            _ = try authority.bootstrap(exactBytes: malformed, rootDescriptors: [handle])
        }
        #expect(throws: DoryFSWorkerRootAuthorityError.bootstrapAlreadyAttempted) {
            _ = try authority.bootstrap(exactBytes: valid, rootDescriptors: [handle])
        }
    }

    @Test func unknownCapabilityAndThrownBorrowDoNotLeakDescriptors() throws {
        enum BorrowFailure: Error { case expected }

        let tree = try TemporaryDirectoryTree()
        let handle = try openHandle(tree.makeDirectory("root"), directoryOnly: true)
        let identity = try pinnedIdentity(of: handle)
        let authorityShare = try share(index: 10, descriptorIndex: 0, identity: identity)
        let authority = makeAuthority()
        _ = try authority.bootstrap(
            exactBytes: encodedBootstrap([authorityShare]),
            rootDescriptors: [handle]
        )
        let beforeBorrow = matchingDescriptors(identity)
        var escaped: Int32 = -1

        #expect(throws: BorrowFailure.expected) {
            try authority.withBorrowedRootFileDescriptor(for: authorityShare.capabilityID) {
                escaped = $0
                throw BorrowFailure.expected
            }
        }
        #expect(!descriptorNames(escaped, identity: identity))
        #expect(matchingDescriptors(identity) == beforeBorrow)
        let unknown = try capability(index: 11)
        #expect(throws: DoryFSWorkerRootAuthorityError.unknownCapability(unknown)) {
            try authority.withBorrowedRootFileDescriptor(for: unknown) { _ in () }
        }
    }

    @Test func serviceBootstrapUsesTransferredRootAndRetainsHostFSAuthority() throws {
        let tree = try TemporaryDirectoryTree()
        let root = try tree.makeDirectory("root")
        let handle = try openHandle(root, directoryOnly: true)
        let authorityShare = try share(
            index: 12,
            descriptorIndex: 0,
            identity: pinnedIdentity(of: handle)
        )
        let bootstrap = try makeBootstrap(shares: [authorityShare])
        let service = DoryFSWorkerService(rootAuthority: makeAuthority())

        let receiptBytes = try unwrapRPC(service.bootstrap(
            exactBytes: DoryFSWorkerBootstrapCodec.encode(bootstrap),
            rootDescriptors: [handle]
        ))
        #expect(
            try DoryFSWorkerBootstrapCodec.decodeReceipt(receiptBytes)
                == DoryFSWorkerBootstrapReceipt(accepting: bootstrap)
        )

        let request = try DoryFSWorkerRequest(
            generation: bootstrap.generation,
            shareCapabilityID: authorityShare.capabilityID,
            requestID: 1,
            correlationID: 101,
            opcodeClass: .metadata,
            responseCapacity: UInt32(FuseOutHeader.byteCount + 104),
            deadlineUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + 5_000_000_000,
            payload: Data(
                FuseProtocol.encodeInHeader(FuseInHeader(
                    length: UInt32(FuseInHeader.byteCount + 16),
                    opcode: FuseOpcode.getattr.rawValue,
                    unique: 101,
                    nodeID: HostFS.rootNodeID,
                    uid: 1_000,
                    gid: 1_000,
                    pid: 42
                )) + FuseProtocol.encodeGetattrIn(FuseGetattrIn())
            )
        )
        let frame = try DoryFSWorkerFrameCodec.encode(
            .execute(request),
            maximumFrameBytes: DoryFSWorkerLimits.production.maximumFrameBytes
        )
        let response = try unwrapRPC(service.exchange(exactFrame: frame))
        guard case .reply(let reply) = try DoryFSWorkerFrameCodec.decodeServiceFrame(
            response,
            maximumFrameBytes: DoryFSWorkerLimits.production.maximumFrameBytes
        ), case .completed(let payload) = reply.outcome else {
            Issue.record("service did not complete root getattr")
            return
        }
        #expect(try FuseProtocol.decodeOutHeader([UInt8](payload)).error == 0)
    }

    @Test func serviceReturnsBoundedDescriptorTransferFailure() throws {
        let tree = try TemporaryDirectoryTree()
        let handle = try openHandle(tree.makeDirectory("root"), directoryOnly: true)
        let authorityShare = try share(
            index: 13,
            descriptorIndex: 0,
            identity: pinnedIdentity(of: handle)
        )
        let service = DoryFSWorkerService(rootAuthority: makeAuthority())
        let result = try DoryFSWorkerRPCResultCodec.decode(service.bootstrap(
            exactBytes: encodedBootstrap([authorityShare]),
            rootDescriptors: []
        ))
        #expect(result == .failure(.bootstrapDescriptorTransferFailed))
    }

    @Test func serviceRejectsAdvertisedCoherenceWithoutAnExchange() throws {
        let tree = try TemporaryDirectoryTree()
        let handle = try openHandle(tree.makeDirectory("root"), directoryOnly: true)
        let authorityShare = try share(
            index: 14,
            descriptorIndex: 0,
            identity: pinnedIdentity(of: handle),
            coherencePolicy: .invalidationOnly
        )
        let service = DoryFSWorkerService(rootAuthority: makeAuthority())

        let result = try DoryFSWorkerRPCResultCodec.decode(service.bootstrap(
            exactBytes: encodedBootstrap([authorityShare]),
            rootDescriptors: [handle]
        ))

        #expect(result == .failure(.bootstrapRejected))
        #expect(try DoryFSWorkerRPCResultCodec.decode(service.bootstrap(
            exactBytes: encodedBootstrap([authorityShare]),
            rootDescriptors: [handle]
        )) == .failure(.bootstrapAlreadyAttempted))
    }

    @Test func serviceAllowsDisabledOnlySharesWithoutAnExchange() throws {
        let tree = try TemporaryDirectoryTree()
        let handle = try openHandle(tree.makeDirectory("root"), directoryOnly: true)
        let authorityShare = try share(
            index: 15,
            descriptorIndex: 0,
            identity: pinnedIdentity(of: handle),
            coherencePolicy: .disabled
        )
        let bootstrap = try makeBootstrap(shares: [authorityShare])
        let service = DoryFSWorkerService(rootAuthority: makeAuthority())

        let receipt = try unwrapRPC(service.bootstrap(
            exactBytes: DoryFSWorkerBootstrapCodec.encode(bootstrap),
            rootDescriptors: [handle]
        ))

        #expect(
            try DoryFSWorkerBootstrapCodec.decodeReceipt(receipt)
                == DoryFSWorkerBootstrapReceipt(accepting: bootstrap)
        )
    }

    @Test func serviceSeparatesObservationPreparationFromDeliveryActivation() throws {
        let tree = try TemporaryDirectoryTree()
        let handle = try openHandle(tree.makeDirectory("root"), directoryOnly: true)
        let authorityShare = try share(
            index: 16,
            descriptorIndex: 0,
            identity: pinnedIdentity(of: handle),
            coherencePolicy: .invalidationOnly
        )
        let bootstrap = try makeBootstrap(shares: [authorityShare])
        let service = DoryFSWorkerService(
            coherenceExchange: { exactFrame in
                let batch = try DoryFSWorkerCoherenceCodec.decodeBatch(exactFrame)
                return DoryFSWorkerCoherenceCodec.encode(
                    try DoryFSWorkerCoherenceAcknowledgement(accepting: batch)
                )
            },
            onCoherenceFailure: { _ in }
        )

        _ = try unwrapRPC(service.bootstrap(
            exactBytes: DoryFSWorkerBootstrapCodec.encode(bootstrap),
            rootDescriptors: [handle]
        ))

        let prepared = try DoryFSWorkerCoherenceStatusCodec.decode(
            service.prepareCoherenceExactBytes()
        )
        #expect(prepared.generation == bootstrap.generation)
        #expect(!prepared.running)
        #expect(prepared.configuredShareCount == 1)
        #expect(prepared.observationStreamCount == 1)
        #expect(
            prepared.requiredObservationShareCount == prepared.observedRequiredShareCount
        )

        let active = try DoryFSWorkerCoherenceStatusCodec.decode(
            service.activateCoherenceExactBytes()
        )
        #expect(active.generation == bootstrap.generation)
        #expect(active.running)
        #expect(active.observationStreamCount == 1)
    }
}

private enum RootAuthorityTestError: Error {
    case unexpectedRPCFailure(DoryFSWorkerRPCFailureCode)
}

private func unwrapRPC(_ data: Data) throws -> Data {
    switch try DoryFSWorkerRPCResultCodec.decode(data) {
    case .success(let payload):
        return payload
    case .failure(let code):
        throw RootAuthorityTestError.unexpectedRPCFailure(code)
    }
}

private final class TemporaryDirectoryTree {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "dory-fs-root-authority-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
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

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}

private func makeAuthority() -> DoryFSWorkerRootAuthority {
    DoryFSWorkerRootAuthority(bootstrapAdmission: DoryFSWorkerBootstrapAdmission())
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
    descriptorIndex: UInt16,
    identity: DoryFSPinnedRootIdentity,
    coherencePolicy: DoryFSShareCoherencePolicy = .disabled
) throws -> DoryFSShareBootstrapAuthority {
    try DoryFSShareBootstrapAuthority(
        capabilityID: capability(index: index),
        expectedRootIdentity: identity,
        readOnly: index.isMultiple(of: 2),
        coherencePolicy: coherencePolicy,
        guestIdentity: DoryFSGuestIdentityPolicy(uid: 1_000, gid: 1_000),
        resourceLimits: .production,
        rootDescriptorIndex: descriptorIndex,
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

private func openHandle(_ url: URL, directoryOnly: Bool) throws -> FileHandle {
    let flags = O_RDONLY | O_CLOEXEC | (directoryOnly ? O_DIRECTORY : 0)
    let descriptor = Darwin.open(url.path, flags)
    guard descriptor >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
}

private func pinnedIdentity(of handle: FileHandle) throws -> DoryFSPinnedRootIdentity {
    var status = stat()
    guard fstat(handle.fileDescriptor, &status) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return try identity(status)
}

private func identity(_ status: stat) throws -> DoryFSPinnedRootIdentity {
    try DoryFSPinnedRootIdentity(
        device: UInt64(truncatingIfNeeded: status.st_dev),
        inode: UInt64(truncatingIfNeeded: status.st_ino),
        generation: UInt64(truncatingIfNeeded: status.st_gen)
    )
}

private func descriptorNames(
    _ descriptor: Int32,
    identity expected: DoryFSPinnedRootIdentity
) -> Bool {
    var status = stat()
    guard descriptor >= 0, fstat(descriptor, &status) == 0 else { return false }
    return (try? identity(status)) == expected
}

private func matchingDescriptors(_ expected: DoryFSPinnedRootIdentity) -> Set<Int32> {
    var result = Set<Int32>()
    for descriptor in Int32(0)..<Int32(4_096) {
        if descriptorNames(descriptor, identity: expected) {
            result.insert(descriptor)
        }
    }
    return result
}
