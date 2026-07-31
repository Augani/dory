import Foundation
import Testing
@testable import Dory

struct MigrationImageArchiveTests {
    @Test func fingerprintsAnUntaggedImageAcrossArbitraryChunkBoundaries() throws {
        let fixture = MigrationImageArchiveTestSupport.fixture()

        let fingerprint = try MigrationImageArchiveTestSupport.fingerprint(fixture.archive)

        #expect(fingerprint.semanticIdentity == "sha256:\(fixture.configDigest)")
        #expect(fingerprint.validatedImageIDs == ["sha256:\(fixture.configDigest)"])
        #expect(fingerprint.configSha256 == fixture.configDigest)
        #expect(fingerprint.layers.map(\.position) == [0, 1])
        #expect(fingerprint.layers.map(\.sha256) == fixture.layerDigests)
        #expect(fingerprint.archiveBytes == UInt64(fixture.archive.count))
        #expect(fingerprint.archiveEntryCount == 4)
        #expect(fingerprint.archiveSha256 == MigrationImageArchiveTestSupport.sha256(fixture.archive))
        #expect(fingerprint.archiveContractSha256.count == 64)
    }

    @Test func acceptsContentAddressedLayoutAndEmptyStreamChunks() throws {
        let fixture = MigrationImageArchiveTestSupport.contentAddressedFixture()
        var reader = MigrationImageArchiveReader()

        try reader.feed(Data())
        try reader.feed(fixture.archive)
        try reader.feed(Data())
        let fingerprint = try reader.finish()

        #expect(fingerprint.semanticIdentity == "sha256:\(fixture.configDigest)")
        #expect(fingerprint.validatedImageIDs == [
            "sha256:\(fixture.configDigest)",
            "sha256:\(try #require(fixture.ociIndexDigest))",
            "sha256:\(try #require(fixture.ociManifestDigest))"
        ])
        #expect(fingerprint.configArchivePath.hasPrefix("blobs/sha256/"))
        #expect(fingerprint.layers.map(\.sha256) == fixture.layerDigests)
        #expect(fingerprint.archiveSha256 == MigrationImageArchiveTestSupport.sha256(fixture.archive))
    }

    @Test func rejectsUnverifiableOCIIdentityChains() throws {
        let fixture = MigrationImageArchiveTestSupport.contentAddressedFixture()
        let nestedDigest = try #require(fixture.ociIndexDigest)
        let nestedPath = "blobs/sha256/\(nestedDigest)"
        let nested = try #require(fixture.entries.first { $0.path == nestedPath })
        let malformedRoot = MigrationImageArchiveTestSupport.json(["schemaVersion": 2])
        let wrongSizeRoot = MigrationImageArchiveTestSupport.json([
            "schemaVersion": 2,
            "manifests": [[
                "mediaType": "application/vnd.oci.image.index.v1+json",
                "digest": "sha256:\(nestedDigest)",
                "size": nested.payload.count + 1
            ]]
        ])
        let invalid = [
            MigrationImageArchiveTestSupport.replacingEntry(
                in: fixture,
                path: "index.json",
                payload: malformedRoot
            ),
            MigrationImageArchiveTestSupport.replacingEntry(
                in: fixture,
                path: "index.json",
                payload: wrongSizeRoot
            ),
            MigrationImageArchiveTestSupport.archive(
                fixture.entries.filter { $0.path != nestedPath }
            )
        ]

        for archive in invalid {
            #expect(throws: MigrationImageArchiveError.self) {
                try MigrationImageArchiveTestSupport.fingerprint(archive)
            }
        }
    }

    @Test func acceptsPAXPathsAndPositiveBase256Sizes() throws {
        let fixture = MigrationImageArchiveTestSupport.fixture(
            base256LayerSize: true,
            paxLayerPath: true
        )

        let fingerprint = try MigrationImageArchiveTestSupport.fingerprint(fixture.archive)

        #expect(fingerprint.layers.first?.archivePath.utf8.count ?? 0 > 100)
        #expect(fingerprint.layers.first?.sha256 == fixture.layerDigests.first)
    }

    @Test func distinguishesExactArchiveBytesFromSemanticContent() throws {
        let fixture = MigrationImageArchiveTestSupport.contentAddressedFixture()
        let changedEntries = fixture.entries.map { entry in
            entry.path == "oci-layout"
                ? MigrationImageTarTestEntry(
                    path: entry.path,
                    payload: MigrationImageArchiveTestSupport.json(["imageLayoutVersion": "1.0.1"])
                )
                : entry
        }

        let original = try MigrationImageArchiveTestSupport.fingerprint(fixture.archive)
        let changed = try MigrationImageArchiveTestSupport.fingerprint(
            MigrationImageArchiveTestSupport.archive(changedEntries)
        )

        #expect(original.semanticIdentity == changed.semanticIdentity)
        #expect(original.archiveContractSha256 == changed.archiveContractSha256)
        #expect(original.archiveSha256 != changed.archiveSha256)
    }

    @Test func acceptsTaggedArchivesWithoutIncludingTagsInContentIdentity() throws {
        let untagged = MigrationImageArchiveTestSupport.fixture()
        let tagged = MigrationImageArchiveTestSupport.fixture(
            repoTags: ["user/app:v1", "registry.example.com/team/app:latest"]
        )

        let untaggedFingerprint = try MigrationImageArchiveTestSupport.fingerprint(untagged.archive)
        let taggedFingerprint = try MigrationImageArchiveTestSupport.fingerprint(tagged.archive)

        #expect(taggedFingerprint.semanticIdentity == untaggedFingerprint.semanticIdentity)
        #expect(taggedFingerprint.archiveContractSha256 == untaggedFingerprint.archiveContractSha256)
        #expect(taggedFingerprint.archiveSha256 != untaggedFingerprint.archiveSha256)
    }

    @Test func stripsRepoTagsWithoutChangingManifestEntrySize() throws {
        let fixture = MigrationImageArchiveTestSupport.fixture(repoTags: ["user/app:v1"])
        let manifest = try #require(fixture.entries.first { $0.path == "manifest.json" }).payload

        let sanitized = try MigrationImageArchiveManifest.strippingRepoTags(manifest)
        let root = try #require(
            JSONSerialization.jsonObject(with: sanitized) as? [[String: Any]]
        )

        #expect(sanitized.count == manifest.count)
        #expect(root.count == 1)
        #expect(root[0]["RepoTags"] is NSNull)
    }

    @Test func acceptsAndCoalescesDuplicateRecordsForTheSameImage() throws {
        let fixture = MigrationImageArchiveTestSupport.fixture(repoTags: ["user/app:v1"])
        let manifest = try #require(fixture.entries.first { $0.path == "manifest.json" })
        let root = try #require(
            JSONSerialization.jsonObject(with: manifest.payload) as? [[String: Any]]
        )
        var alias = try #require(root.first)
        alias["RepoTags"] = ["user/app:stable"]
        let duplicateManifest = MigrationImageArchiveTestSupport.json([root[0], alias])
        let duplicateArchive = MigrationImageArchiveTestSupport.replacingManifest(
            in: fixture,
            payload: duplicateManifest
        )

        let fingerprint = try MigrationImageArchiveTestSupport.fingerprint(duplicateArchive)
        let sanitized = try MigrationImageArchiveManifest.strippingRepoTags(duplicateManifest)
        let sanitizedRoot = try #require(
            JSONSerialization.jsonObject(with: sanitized) as? [[String: Any]]
        )

        #expect(fingerprint.semanticIdentity == "sha256:\(fixture.configDigest)")
        #expect(sanitized.count == duplicateManifest.count)
        #expect(sanitizedRoot.count == 1)
        #expect(sanitizedRoot[0]["RepoTags"] is NSNull)
    }

    @Test func acceptsDuplicateOCIIndexDescriptorsForTheSameImage() throws {
        let fixture = MigrationImageArchiveTestSupport.contentAddressedFixture()
        let indexEntry = try #require(fixture.entries.first { $0.path == "index.json" })
        var root = try #require(
            JSONSerialization.jsonObject(with: indexEntry.payload) as? [String: Any]
        )
        let descriptors = try #require(root["manifests"] as? [[String: Any]])
        var alias = try #require(descriptors.first)
        alias["annotations"] = ["org.opencontainers.image.ref.name": "stable"]
        root["manifests"] = [descriptors[0], alias]
        let duplicateIndex = MigrationImageArchiveTestSupport.json(root)
        let archive = MigrationImageArchiveTestSupport.replacingEntry(
            in: fixture,
            path: "index.json",
            payload: duplicateIndex
        )

        let fingerprint = try MigrationImageArchiveTestSupport.fingerprint(archive)
        let sanitized = try MigrationImageOCIArchiveIdentity.strippingAliases(duplicateIndex)
        let sanitizedRoot = try #require(
            JSONSerialization.jsonObject(with: sanitized) as? [String: Any]
        )
        let sanitizedDescriptors = try #require(
            sanitizedRoot["manifests"] as? [[String: Any]]
        )

        #expect(fingerprint.semanticIdentity == "sha256:\(fixture.configDigest)")
        #expect(fingerprint.validatedImageIDs.count == 3)
        #expect(sanitized.count == duplicateIndex.count)
        #expect(sanitizedDescriptors.count == 1)
        #expect(sanitizedDescriptors[0]["annotations"] == nil)
    }

    @Test func rejectsInvalidRepoTagsMissingFilesAndMismatchedConfigIdentity() throws {
        let fixture = MigrationImageArchiveTestSupport.fixture()
        let invalidRepoTags = MigrationImageArchiveTestSupport.replacingManifest(
            in: fixture,
            payload: MigrationImageArchiveTestSupport.json([[
                "Config": fixture.entries[0].path,
                "RepoTags": "user/app:v1",
                "Layers": [fixture.entries[1].path, fixture.entries[2].path]
            ]])
        )
        let invalid = [
            invalidRepoTags,
            MigrationImageArchiveTestSupport.fixture(missingReferencedLayer: true).archive,
            MigrationImageArchiveTestSupport.fixture(mismatchedConfigPath: true).archive
        ]

        for archive in invalid {
            #expect(throws: MigrationImageArchiveError.self) {
                try MigrationImageArchiveTestSupport.fingerprint(archive)
            }
        }
    }

    @Test func rejectsTraversalDuplicatesLinksAndBrokenChecksums() throws {
        let fixture = MigrationImageArchiveTestSupport.fixture()
        let malicious = MigrationImageTarTestEntry(path: "../escape", payload: Data("x".utf8))
        let duplicate = fixture.entries + [fixture.entries[0]]
        let symbolicLink = MigrationImageTarTestEntry(
            path: "link",
            type: UInt8(ascii: "2")
        )
        var badChecksum = fixture.archive
        badChecksum[0] ^= 0xff
        let invalid = [
            MigrationImageArchiveTestSupport.archive([malicious] + fixture.entries),
            MigrationImageArchiveTestSupport.archive(duplicate),
            MigrationImageArchiveTestSupport.archive([symbolicLink] + fixture.entries),
            badChecksum
        ]

        for archive in invalid {
            #expect(throws: MigrationImageArchiveError.self) {
                try MigrationImageArchiveTestSupport.fingerprint(archive)
            }
        }
    }

    @Test func rejectsTruncationNonzeroPaddingAndTrailingData() throws {
        let fixture = MigrationImageArchiveTestSupport.fixture()
        var nonzeroPadding = fixture.archive
        let firstPayloadEnd = MigrationImageTarHeaderDecoder.blockBytes
            + fixture.entries[0].payload.count
        nonzeroPadding[firstPayloadEnd] = 1
        let noTerminator = MigrationImageArchiveTestSupport.archive(
            fixture.entries,
            terminator: false
        )
        var trailingData = fixture.archive
        trailingData.append(1)

        for archive in [nonzeroPadding, noTerminator, trailingData] {
            #expect(throws: MigrationImageArchiveError.self) {
                try MigrationImageArchiveTestSupport.fingerprint(archive)
            }
        }
    }

    @Test func rejectsDuplicateManifestsAndIncompleteTerminators() throws {
        let fixture = MigrationImageArchiveTestSupport.fixture()
        let manifest = try #require(fixture.entries.last)
        var singleZero = MigrationImageArchiveTestSupport.archive(
            fixture.entries,
            terminator: false
        )
        singleZero.append(Data(repeating: 0, count: MigrationImageTarHeaderDecoder.blockBytes))
        let invalid = [
            MigrationImageArchiveTestSupport.archive(fixture.entries + [manifest]),
            singleZero
        ]

        for archive in invalid {
            #expect(throws: MigrationImageArchiveError.self) {
                try MigrationImageArchiveTestSupport.fingerprint(archive)
            }
        }
    }

    @Test func rejectsMalformedNumericAndExtensionHeaders() throws {
        let fixture = MigrationImageArchiveTestSupport.fixture()
        let unsafePAX = MigrationImageTarTestEntry(
            path: "PaxHeaders/path",
            type: UInt8(ascii: "x"),
            payload: MigrationImageArchiveTestSupport.pax(key: "path", value: "../escape")
        )
        let sparsePAX = MigrationImageTarTestEntry(
            path: "PaxHeaders/sparse",
            type: UInt8(ascii: "x"),
            payload: MigrationImageArchiveTestSupport.pax(key: "GNU.sparse.map", value: "0,1")
        )
        let placeholder = MigrationImageTarTestEntry(path: "placeholder")
        let negative = [UInt8(0xc0)] + [UInt8](repeating: 0, count: 11)
        let overflow = [UInt8(0xbf)] + [UInt8](repeating: 0xff, count: 11)
        var malformedOctal = [UInt8](repeating: UInt8(ascii: "0"), count: 12)
        malformedOctal[10] = UInt8(ascii: "8")
        let invalid = [
            MigrationImageArchiveTestSupport.archive([unsafePAX, placeholder] + fixture.entries),
            MigrationImageArchiveTestSupport.archive([sparsePAX, placeholder] + fixture.entries),
            MigrationImageArchiveTestSupport.archiveWithRawSizeField(negative),
            MigrationImageArchiveTestSupport.archiveWithRawSizeField(overflow),
            MigrationImageArchiveTestSupport.archiveWithRawSizeField(malformedOctal)
        ]

        for archive in invalid {
            #expect(throws: MigrationImageArchiveError.self) {
                try MigrationImageArchiveTestSupport.fingerprint(archive)
            }
        }
    }

    @Test func rejectsMultipleImagesDuplicateLayersAndInvalidConfigs() throws {
        let fixture = MigrationImageArchiveTestSupport.fixture()
        let config = fixture.entries[0].path
        let layers = [fixture.entries[1].path, fixture.entries[2].path]
        let validRecord: [String: Any] = [
            "Config": config,
            "RepoTags": NSNull(),
            "Layers": layers
        ]
        let duplicateLayerRecord: [String: Any] = [
            "Config": config,
            "RepoTags": NSNull(),
            "Layers": [layers[0], layers[0]]
        ]
        let invalid = [
            MigrationImageArchiveTestSupport.replacingManifest(
                in: fixture,
                payload: MigrationImageArchiveTestSupport.json([
                    validRecord,
                    [
                        "Config": config,
                        "RepoTags": NSNull(),
                        "Layers": Array(layers.reversed())
                    ] as [String: Any]
                ])
            ),
            MigrationImageArchiveTestSupport.replacingManifest(
                in: fixture,
                payload: MigrationImageArchiveTestSupport.json([duplicateLayerRecord])
            ),
            MigrationImageArchiveTestSupport.invalidConfigArchive(architecture: "amd64"),
            MigrationImageArchiveTestSupport.invalidConfigArchive(operatingSystem: "windows"),
            MigrationImageArchiveTestSupport.invalidConfigArchive(
                diffIDs: ["sha256:" + String(repeating: "0", count: 64)]
            )
        ]

        for archive in invalid {
            #expect(throws: MigrationImageArchiveError.self) {
                try MigrationImageArchiveTestSupport.fingerprint(archive)
            }
        }
    }

    @Test func fingerprintsAsyncStreamsAcrossChunks() async throws {
        let fixture = MigrationImageArchiveTestSupport.fixture()
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            continuation.yield(fixture.archive.prefix(700))
            continuation.yield(fixture.archive.dropFirst(700))
            continuation.finish()
        }

        let fingerprint = try await MigrationImageArchiveReader.fingerprint(stream)

        #expect(fingerprint.configSha256 == fixture.configDigest)
    }

    @Test func propagatesAsyncStreamFailures() async {
        let fixture = MigrationImageArchiveTestSupport.fixture()
        let stream = AsyncThrowingStream<Data, Error> { continuation in
            continuation.yield(fixture.archive.prefix(700))
            continuation.finish(throwing: MigrationImageArchiveStreamError.injected)
        }

        await #expect(throws: MigrationImageArchiveStreamError.injected) {
            try await MigrationImageArchiveReader.fingerprint(stream)
        }
    }
}

private enum MigrationImageArchiveStreamError: Error {
    case injected
}
