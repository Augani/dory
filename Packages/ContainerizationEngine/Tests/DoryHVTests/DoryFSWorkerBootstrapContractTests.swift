import DoryFSWorkerContracts
import Foundation
import Testing
@testable import DoryHV

struct DoryFSWorkerBootstrapContractTests {
    @Test func rpcResultRoundTripsEveryNonSensitiveBootstrapRejectionReason() throws {
        let cases: [(DoryFSWorkerRPCFailureCode, DoryFSWorkerBootstrapRejectionReason)] = [
            (.bootstrapBookmarkResolutionFailed, .bookmarkResolution),
            (.bootstrapBookmarkStale, .staleBookmark),
            (.bootstrapScopeActivationFailed, .scopeActivation),
            (.bootstrapRootOpenFailed, .rootOpen),
            (.bootstrapRootIdentityMismatch, .rootIdentity),
        ]

        for (code, reason) in cases {
            let encoded = try DoryFSWorkerRPCResultCodec.encode(.failure(code))
            #expect(try DoryFSWorkerRPCResultCodec.decode(encoded) == .failure(code))
            #expect(code.bootstrapRejectionReason == reason)
            #expect(encoded.count == DoryFSWorkerRPCResultCodec.headerByteCount)
        }
        #expect(DoryFSWorkerRPCFailureCode.bootstrapRejected.bootstrapRejectionReason == nil)
    }

    @Test func runnerPromotesTypedBootstrapStageIntoItsDiagnosticError() throws {
        let result = DoryFSWorkerXPCChannel.unwrapBootstrapResult(
            try DoryFSWorkerRPCResultCodec.encode(
                .failure(.bootstrapScopeActivationFailed)
            )
        )

        #expect(result == .failure(.bootstrapRejected(.scopeActivation)))
    }

    @Test func canonicalBootstrapAndExactReceiptRoundTrip() throws {
        let second = try bootstrapShare(
            index: 2,
            hidden: ["Zulu", ".SSH", "Cafe\u{301}"],
            rootHidden: ["Library"]
        )
        let first = try bootstrapShare(index: 1)
        let bootstrap = try makeBootstrap(shares: [second, first])

        #expect(bootstrap.shares.map(\.capabilityID) == [first.capabilityID, second.capabilityID])
        #expect(bootstrap.shares[1].hiddenComponents == [".ssh", "caf\u{e9}", "zulu"])
        #expect(bootstrap.shares[1].rootHiddenComponents == ["library"])

        let encoded = try DoryFSWorkerBootstrapCodec.encode(bootstrap)
        let decoded = try DoryFSWorkerBootstrapCodec.decode(encoded)
        #expect(decoded == bootstrap)
        #expect(try DoryFSWorkerBootstrapCodec.encode(decoded) == encoded)

        let receipt = DoryFSWorkerBootstrapReceipt(accepting: decoded)
        let encodedReceipt = DoryFSWorkerBootstrapCodec.encode(receipt)
        #expect(encodedReceipt.count == DoryFSWorkerBootstrapCodec.receiptByteCount)
        #expect(try DoryFSWorkerBootstrapCodec.decodeReceipt(encodedReceipt) == receipt)
        #expect(receipt.workspaceID == bootstrap.workspaceID)
        #expect(receipt.generation == bootstrap.generation)
        #expect(receipt.acceptedShareCount == UInt16(bootstrap.shares.count))
    }

    @Test func authorityRejectsSentinelsBookmarksAndNonComponents() throws {
        #expect(throws: DoryFSWorkerBootstrapError.invalidWorkspaceIdentity) {
            _ = try DoryFSWorkerWorkspaceID(
                rawValue: #require(UUID(uuidString: "00000000-0000-0000-0000-000000000000"))
            )
        }
        #expect(throws: DoryFSWorkerBootstrapError.invalidPinnedRootIdentity(field: "device")) {
            _ = try DoryFSPinnedRootIdentity(device: 0, inode: 1, generation: 0)
        }
        #expect(throws: DoryFSWorkerBootstrapError.invalidPinnedRootIdentity(field: "inode")) {
            _ = try DoryFSPinnedRootIdentity(device: 1, inode: 0, generation: 0)
        }

        let capability = try capability(index: 1)
        let root = try DoryFSPinnedRootIdentity(device: 1, inode: 2, generation: 0)
        #expect(throws: DoryFSWorkerBootstrapError.invalidBookmarkSize(
            limit: DoryFSWorkerBootstrapCodec.maximumBookmarkBytes,
            actual: 0
        )) {
            _ = try DoryFSShareBootstrapAuthority(
                capabilityID: capability,
                expectedRootIdentity: root,
                readOnly: false,
                guestIdentity: DoryFSGuestIdentityPolicy(uid: 0, gid: 0),
                resourceLimits: .production,
                securityScopedBookmark: Data()
            )
        }
        #expect(throws: DoryFSWorkerBootstrapError.invalidComponent("../secret")) {
            _ = try bootstrapShare(index: 1, hidden: ["../secret"])
        }
        #expect(throws: DoryFSWorkerBootstrapError.invalidComponent(".")) {
            _ = try bootstrapShare(index: 1, hidden: ["."])
        }
        #expect(throws: DoryFSWorkerBootstrapError.invalidComponent("bad\0name")) {
            _ = try bootstrapShare(index: 1, hidden: ["bad\0name"])
        }
        #expect(throws: DoryFSWorkerBootstrapError.invalidComponent(String(repeating: "x", count: 256))) {
            _ = try bootstrapShare(index: 1, hidden: [String(repeating: "x", count: 256)])
        }
    }

    @Test func hiddenPoliciesRejectCanonicalDuplicatesOverlapAndCountAmplification() throws {
        #expect(throws: DoryFSWorkerBootstrapError.duplicateComponent(".ssh")) {
            _ = try bootstrapShare(index: 1, hidden: [".ssh", ".SSH"])
        }
        #expect(throws: DoryFSWorkerBootstrapError.overlappingComponent("library")) {
            _ = try bootstrapShare(
                index: 1,
                hidden: ["Library"],
                rootHidden: ["library"]
            )
        }
        let tooMany = (0...DoryFSWorkerBootstrapCodec.maximumComponentsPerList).map {
            "component-\($0)"
        }
        #expect(throws: DoryFSWorkerBootstrapError.tooManyComponents(
            limit: DoryFSWorkerBootstrapCodec.maximumComponentsPerList,
            actual: tooMany.count
        )) {
            _ = try bootstrapShare(index: 1, hidden: tooMany)
        }
    }

    @Test func workspaceRequiresOneBoundedUniqueShareAuthoritySet() throws {
        #expect(throws: DoryFSWorkerBootstrapError.invalidShareCount(
            limit: DoryFSWorkerBootstrapCodec.maximumShares,
            actual: 0
        )) {
            _ = try makeBootstrap(shares: [])
        }

        let duplicate = try bootstrapShare(index: 1)
        #expect(throws: DoryFSWorkerBootstrapError.duplicateShareCapabilityID) {
            _ = try makeBootstrap(shares: [duplicate, duplicate])
        }

        let tooMany = try (1...(DoryFSWorkerBootstrapCodec.maximumShares + 1)).map {
            try bootstrapShare(index: $0)
        }
        #expect(throws: DoryFSWorkerBootstrapError.invalidShareCount(
            limit: DoryFSWorkerBootstrapCodec.maximumShares,
            actual: tooMany.count
        )) {
            _ = try makeBootstrap(shares: tooMany)
        }

        let maximumBookmarks = try (1...16).map {
            try bootstrapShare(
                index: $0,
                bookmark: Data(count: DoryFSWorkerBootstrapCodec.maximumBookmarkBytes)
            )
        }
        let expectedEncodedBytes = DoryFSWorkerBootstrapCodec.bootstrapHeaderByteCount
            + maximumBookmarks.count * (
                DoryFSWorkerBootstrapCodec.shareRecordHeaderByteCount
                    + DoryFSWorkerBootstrapCodec.maximumBookmarkBytes
            )
        #expect(throws: DoryFSWorkerBootstrapError.bootstrapTooLarge(
            limit: DoryFSWorkerBootstrapCodec.absoluteMaximumBootstrapBytes,
            actual: expectedEncodedBytes
        )) {
            _ = try makeBootstrap(shares: maximumBookmarks)
        }
    }

    @Test func perShareLimitsAreBoundedAndCannotExceedWorkspaceAdmission() throws {
        #expect(throws: DoryFSWorkerBootstrapError.invalidShareResourceLimits(
            field: "maximumInFlightRequests"
        )) {
            _ = try shareLimits(maximumInFlightRequests: 0)
        }
        #expect(throws: DoryFSWorkerBootstrapError.invalidShareResourceLimits(
            field: "reservedFileDescriptorHeadroom"
        )) {
            _ = try shareLimits(reservedFileDescriptorHeadroom: 0)
        }

        let restrictiveWorker = try workerLimits(
            maximumInFlightRequests: 1,
            maximumAggregateRequestBytes: 64,
            maximumAggregateResponseBytes: 64
        )
        let share = try bootstrapShare(index: 1)
        #expect(throws: DoryFSWorkerBootstrapError.incompatibleShareLimit(
            field: "maximumInFlightRequests"
        )) {
            _ = try makeBootstrap(workerLimits: restrictiveWorker, shares: [share])
        }
    }

    @Test func bootstrapHeaderRejectsWrongVersionReservedTrailingAndUnboundedData() throws {
        let encoded = try DoryFSWorkerBootstrapCodec.encode(
            makeBootstrap(shares: [bootstrapShare(index: 1)])
        )

        var wrongVersion = encoded
        writeUInt16(2, to: &wrongVersion, at: 4)
        #expect(throws: DoryFSWorkerBootstrapError.unsupportedBootstrapVersion(2)) {
            _ = try DoryFSWorkerBootstrapCodec.decode(wrongVersion)
        }

        var reserved = encoded
        writeUInt16(1, to: &reserved, at: 6)
        #expect(throws: DoryFSWorkerBootstrapError.nonzeroReservedField) {
            _ = try DoryFSWorkerBootstrapCodec.decode(reserved)
        }

        var zeroShares = encoded
        writeUInt16(0, to: &zeroShares, at: 12)
        #expect(throws: DoryFSWorkerBootstrapError.invalidShareCount(
            limit: DoryFSWorkerBootstrapCodec.maximumShares,
            actual: 0
        )) {
            _ = try DoryFSWorkerBootstrapCodec.decode(zeroShares)
        }

        var tooManyShares = encoded
        writeUInt16(
            UInt16(DoryFSWorkerBootstrapCodec.maximumShares + 1),
            to: &tooManyShares,
            at: 12
        )
        #expect(throws: DoryFSWorkerBootstrapError.invalidShareCount(
            limit: DoryFSWorkerBootstrapCodec.maximumShares,
            actual: DoryFSWorkerBootstrapCodec.maximumShares + 1
        )) {
            _ = try DoryFSWorkerBootstrapCodec.decode(tooManyShares)
        }

        var zeroWorkerLimit = encoded
        writeUInt32(0, to: &zeroWorkerLimit, at: 52)
        #expect(throws: DoryFSWorkerBootstrapError.invalidWorkerLimits(
            field: "maximumInFlightRequests"
        )) {
            _ = try DoryFSWorkerBootstrapCodec.decode(zeroWorkerLimit)
        }

        var trailing = encoded
        trailing.append(0)
        #expect(throws: DoryFSWorkerBootstrapError.bootstrapLengthMismatch(
            declared: UInt32(encoded.count),
            actual: trailing.count
        )) {
            _ = try DoryFSWorkerBootstrapCodec.decode(trailing)
        }

        #expect(throws: DoryFSWorkerBootstrapError.shortBootstrap(
            minimum: DoryFSWorkerBootstrapCodec.bootstrapHeaderByteCount,
            actual: DoryFSWorkerBootstrapCodec.bootstrapHeaderByteCount - 1
        )) {
            _ = try DoryFSWorkerBootstrapCodec.decode(Data(
                count: DoryFSWorkerBootstrapCodec.bootstrapHeaderByteCount - 1
            ))
        }

        let oversizedCount = DoryFSWorkerBootstrapCodec.absoluteMaximumBootstrapBytes + 1
        #expect(throws: DoryFSWorkerBootstrapError.bootstrapTooLarge(
            limit: DoryFSWorkerBootstrapCodec.absoluteMaximumBootstrapBytes,
            actual: oversizedCount
        )) {
            _ = try DoryFSWorkerBootstrapCodec.decode(Data(count: oversizedCount))
        }
    }

    @Test func shareRecordsRejectUnknownFlagsReservedBytesAndLengthConfusion() throws {
        let encoded = try DoryFSWorkerBootstrapCodec.encode(
            makeBootstrap(shares: [bootstrapShare(index: 1)])
        )
        let record = DoryFSWorkerBootstrapCodec.bootstrapHeaderByteCount

        var flags = encoded
        writeUInt16(2, to: &flags, at: record + 4)
        #expect(throws: DoryFSWorkerBootstrapError.invalidShareFlags(2)) {
            _ = try DoryFSWorkerBootstrapCodec.decode(flags)
        }

        var reserved = encoded
        writeUInt16(1, to: &reserved, at: record + 6)
        #expect(throws: DoryFSWorkerBootstrapError.nonzeroReservedField) {
            _ = try DoryFSWorkerBootstrapCodec.decode(reserved)
        }

        var reservedTail = encoded
        writeUInt32(1, to: &reservedTail, at: record + 124)
        #expect(throws: DoryFSWorkerBootstrapError.nonzeroReservedField) {
            _ = try DoryFSWorkerBootstrapCodec.decode(reservedTail)
        }

        var shortRecord = encoded
        writeUInt32(
            UInt32(DoryFSWorkerBootstrapCodec.shareRecordHeaderByteCount - 1),
            to: &shortRecord,
            at: record
        )
        #expect(throws: DoryFSWorkerBootstrapError.invalidShareRecordLength(
            UInt32(DoryFSWorkerBootstrapCodec.shareRecordHeaderByteCount - 1)
        )) {
            _ = try DoryFSWorkerBootstrapCodec.decode(shortRecord)
        }

        var emptyBookmark = encoded
        writeUInt32(0, to: &emptyBookmark, at: record + 112)
        #expect(throws: DoryFSWorkerBootstrapError.invalidBookmarkSize(
            limit: DoryFSWorkerBootstrapCodec.maximumBookmarkBytes,
            actual: 0
        )) {
            _ = try DoryFSWorkerBootstrapCodec.decode(emptyBookmark)
        }

        var tooManyComponents = encoded
        writeUInt16(
            UInt16(DoryFSWorkerBootstrapCodec.maximumComponentsPerList + 1),
            to: &tooManyComponents,
            at: record + 116
        )
        #expect(throws: DoryFSWorkerBootstrapError.tooManyComponents(
            limit: DoryFSWorkerBootstrapCodec.maximumComponentsPerList,
            actual: DoryFSWorkerBootstrapCodec.maximumComponentsPerList + 1
        )) {
            _ = try DoryFSWorkerBootstrapCodec.decode(tooManyComponents)
        }

        var zeroShareLimit = encoded
        writeUInt32(0, to: &zeroShareLimit, at: record + 56)
        #expect(throws: DoryFSWorkerBootstrapError.invalidShareResourceLimits(
            field: "maximumInFlightRequests"
        )) {
            _ = try DoryFSWorkerBootstrapCodec.decode(zeroShareLimit)
        }
    }

    @Test func decodeRejectsDuplicateAndNonCanonicalShareOrder() throws {
        let first = try bootstrapShare(index: 1)
        let second = try bootstrapShare(index: 2, bookmark: Data([2, 2]))
        let encoded = try DoryFSWorkerBootstrapCodec.encode(
            makeBootstrap(shares: [first, second])
        )
        let header = DoryFSWorkerBootstrapCodec.bootstrapHeaderByteCount
        let firstLength = Int(readUInt32(encoded, at: header))
        let secondStart = header + firstLength
        let secondLength = Int(readUInt32(encoded, at: secondStart))

        var duplicate = encoded
        duplicate.replaceSubrange(
            (secondStart + 8)..<(secondStart + 24),
            with: encoded[(header + 8)..<(header + 24)]
        )
        #expect(throws: DoryFSWorkerBootstrapError.duplicateShareCapabilityID) {
            _ = try DoryFSWorkerBootstrapCodec.decode(duplicate)
        }

        var reordered = Data(encoded.prefix(header))
        reordered.append(encoded[secondStart..<(secondStart + secondLength)])
        reordered.append(encoded[header..<(header + firstLength)])
        #expect(reordered.count == encoded.count)
        #expect(throws: DoryFSWorkerBootstrapError.nonCanonicalEncoding) {
            _ = try DoryFSWorkerBootstrapCodec.decode(reordered)
        }
    }

    @Test func decodeRejectsNonCanonicalComponentSpellingAndComponentTrailingBytes() throws {
        let share = try bootstrapShare(index: 1, hidden: [".ssh"])
        let encoded = try DoryFSWorkerBootstrapCodec.encode(makeBootstrap(shares: [share]))
        let record = DoryFSWorkerBootstrapCodec.bootstrapHeaderByteCount
        let componentStart = record
            + DoryFSWorkerBootstrapCodec.shareRecordHeaderByteCount
            + share.securityScopedBookmark.count
        var nonCanonical = encoded
        // Skip the UInt16 component length and replace the first ASCII `s`.
        nonCanonical[componentStart + 3] = Character("S").asciiValue!
        #expect(throws: DoryFSWorkerBootstrapError.nonCanonicalEncoding) {
            _ = try DoryFSWorkerBootstrapCodec.decode(nonCanonical)
        }

        var trailing = encoded
        trailing.append(0)
        writeUInt32(UInt32(trailing.count), to: &trailing, at: 8)
        let originalRecordLength = readUInt32(encoded, at: record)
        writeUInt32(originalRecordLength + 1, to: &trailing, at: record)
        #expect(throws: DoryFSWorkerBootstrapError.shareRecordLengthMismatch(
            declared: originalRecordLength + 1,
            consumed: Int(originalRecordLength)
        )) {
            _ = try DoryFSWorkerBootstrapCodec.decode(trailing)
        }

        let duplicateSource = try bootstrapShare(index: 1, hidden: [".ssh", "abcd"])
        var duplicate = try DoryFSWorkerBootstrapCodec.encode(
            makeBootstrap(shares: [duplicateSource])
        )
        let duplicateComponentStart = record
            + DoryFSWorkerBootstrapCodec.shareRecordHeaderByteCount
            + duplicateSource.securityScopedBookmark.count
        // Both names have four UTF-8 bytes. Replace the second spelling while retaining its
        // original length prefix so duplicate validation, not truncation, rejects the frame.
        duplicate.replaceSubrange(
            (duplicateComponentStart + 8)..<(duplicateComponentStart + 12),
            with: duplicate[(duplicateComponentStart + 2)..<(duplicateComponentStart + 6)]
        )
        #expect(throws: DoryFSWorkerBootstrapError.duplicateComponent(".ssh")) {
            _ = try DoryFSWorkerBootstrapCodec.decode(duplicate)
        }
    }

    @Test func receiptRejectsMissingSharesReservedFieldsAndTrailingBytes() throws {
        let bootstrap = try makeBootstrap(shares: [bootstrapShare(index: 1)])
        let receipt = DoryFSWorkerBootstrapReceipt(accepting: bootstrap)
        let encoded = DoryFSWorkerBootstrapCodec.encode(receipt)

        var zeroShares = encoded
        writeUInt16(0, to: &zeroShares, at: 12)
        #expect(throws: DoryFSWorkerBootstrapError.invalidReceiptShareCount(
            limit: DoryFSWorkerBootstrapCodec.maximumShares,
            actual: 0
        )) {
            _ = try DoryFSWorkerBootstrapCodec.decodeReceipt(zeroShares)
        }

        var reserved = encoded
        writeUInt16(1, to: &reserved, at: 14)
        #expect(throws: DoryFSWorkerBootstrapError.nonzeroReservedField) {
            _ = try DoryFSWorkerBootstrapCodec.decodeReceipt(reserved)
        }

        var trailing = encoded
        trailing.append(0)
        #expect(throws: DoryFSWorkerBootstrapError.bootstrapLengthMismatch(
            declared: UInt32(DoryFSWorkerBootstrapCodec.receiptByteCount),
            actual: DoryFSWorkerBootstrapCodec.receiptByteCount + 1
        )) {
            _ = try DoryFSWorkerBootstrapCodec.decodeReceipt(trailing)
        }
    }
}

private func makeBootstrap(
    workerLimits: DoryFSWorkerLimits = .production,
    shares: [DoryFSShareBootstrapAuthority]
) throws -> DoryFSWorkerBootstrap {
    try DoryFSWorkerBootstrap(
        workspaceID: DoryFSWorkerWorkspaceID(
            rawValue: #require(UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"))
        ),
        generation: DoryFSWorkerGeneration(rawValue: 9),
        workerLimits: workerLimits,
        shares: shares
    )
}

private func bootstrapShare(
    index: Int,
    bookmark: Data? = nil,
    hidden: [String] = [],
    rootHidden: [String] = [],
    resourceLimits: DoryFSShareResourceLimits = .production
) throws -> DoryFSShareBootstrapAuthority {
    try DoryFSShareBootstrapAuthority(
        capabilityID: capability(index: index),
        expectedRootIdentity: DoryFSPinnedRootIdentity(
            device: 0x1_000 + UInt64(index),
            inode: 0x2_000 + UInt64(index),
            generation: UInt64(index - 1)
        ),
        readOnly: index.isMultiple(of: 2),
        guestIdentity: DoryFSGuestIdentityPolicy(
            uid: UInt32(1_000 + index),
            gid: UInt32(2_000 + index)
        ),
        resourceLimits: resourceLimits,
        securityScopedBookmark: bookmark ?? Data([UInt8(truncatingIfNeeded: index)]),
        hiddenComponents: hidden,
        rootHiddenComponents: rootHidden
    )
}

private func capability(index: Int) throws -> DoryFSShareCapabilityID {
    precondition((1...255).contains(index))
    return try DoryFSShareCapabilityID(rawValue: UUID(uuid: (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, UInt8(index)
    )))
}

private func shareLimits(
    maximumInFlightRequests: Int = 32,
    reservedFileDescriptorHeadroom: Int = 256
) throws -> DoryFSShareResourceLimits {
    try DoryFSShareResourceLimits(
        maximumInFlightRequests: maximumInFlightRequests,
        maximumAggregateRequestBytes: 8 * (40 + 1 * 1_024 * 1_024),
        maximumAggregateResponseBytes: 8 * (16 + 1 * 1_024 * 1_024),
        maximumLiveNonRootNodes: 65_536,
        maximumFileHandles: 16_384,
        maximumDirectoryHandles: 4_096,
        maximumDirectoryCursorEntries: 262_144,
        maximumDirectoryCursorNameBytes: 32 * 1_024 * 1_024,
        maximumAdvisoryLockOwners: 4_096,
        maximumPendingBlockingLocks: 1_024,
        reservedFileDescriptorHeadroom: reservedFileDescriptorHeadroom
    )
}

private func workerLimits(
    maximumInFlightRequests: Int,
    maximumAggregateRequestBytes: Int,
    maximumAggregateResponseBytes: Int
) throws -> DoryFSWorkerLimits {
    try DoryFSWorkerLimits(
        maximumRequestBytes: 32,
        maximumResponseBytes: 32,
        maximumFrameBytes: 512,
        maximumInFlightRequests: maximumInFlightRequests,
        maximumAggregateRequestBytes: maximumAggregateRequestBytes,
        maximumAggregateResponseBytes: maximumAggregateResponseBytes,
        maximumOperationNanoseconds: 1_000_000_000,
        maximumDrainNanoseconds: 1_000_000_000
    )
}

private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
    var result: UInt32 = 0
    for index in 0..<4 {
        result |= UInt32(data[offset + index]) << UInt32(index * 8)
    }
    return result
}

private func writeUInt16(_ value: UInt16, to data: inout Data, at offset: Int) {
    data[offset] = UInt8(truncatingIfNeeded: value)
    data[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
}

private func writeUInt32(_ value: UInt32, to data: inout Data, at offset: Int) {
    for index in 0..<4 {
        data[offset + index] = UInt8(truncatingIfNeeded: value >> UInt32(index * 8))
    }
}
