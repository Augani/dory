import CryptoKit
import Foundation
@testable import Dory

struct MigrationImageTarTestEntry {
    let path: String
    let type: UInt8
    let payload: Data
    let base256Size: Bool

    init(
        path: String,
        type: UInt8 = UInt8(ascii: "0"),
        payload: Data = Data(),
        base256Size: Bool = false
    ) {
        self.path = path
        self.type = type
        self.payload = payload
        self.base256Size = base256Size
    }
}

struct MigrationImageArchiveTestFixture {
    let archive: Data
    let entries: [MigrationImageTarTestEntry]
    let configDigest: String
    let layerDigests: [String]
}

enum MigrationImageArchiveTestSupport {
    private struct FixtureOptions {
        var repoTags: [String]?
        var missingReferencedLayer = false
        var mismatchedConfigPath = false
        var base256LayerSize = false
        var paxLayerPath = false
        var contentAddressedLayout = false
        var architecture = "arm64"
        var operatingSystem = "linux"
        var diffIDs: [String]?
        var layerPayloads = [
            Data("first deterministic rootfs layer".utf8),
            Data("second deterministic rootfs layer".utf8)
        ]
    }

    private struct ImageEntriesInput {
        let configPath: String
        let config: Data
        let layerPaths: [String]
        let layerPayloads: [Data]
        let manifest: Data
        let missingReferencedLayer: Bool
        let base256LayerSize: Bool
        let paxLayerPath: Bool
        let contentAddressedLayout: Bool
    }

    static func fixture(
        repoTags: [String]? = nil,
        missingReferencedLayer: Bool = false,
        mismatchedConfigPath: Bool = false,
        base256LayerSize: Bool = false,
        paxLayerPath: Bool = false
    ) -> MigrationImageArchiveTestFixture {
        var options = FixtureOptions()
        options.repoTags = repoTags
        options.missingReferencedLayer = missingReferencedLayer
        options.mismatchedConfigPath = mismatchedConfigPath
        options.base256LayerSize = base256LayerSize
        options.paxLayerPath = paxLayerPath
        return fixture(options)
    }

    static func contentAddressedFixture() -> MigrationImageArchiveTestFixture {
        var options = FixtureOptions()
        options.contentAddressedLayout = true
        return fixture(options)
    }

    static func fixture(layerPayloads: [Data]) -> MigrationImageArchiveTestFixture {
        precondition(layerPayloads.count == 2)
        var options = FixtureOptions()
        options.layerPayloads = layerPayloads
        return fixture(options)
    }

    static func invalidConfigArchive(
        architecture: String = "arm64",
        operatingSystem: String = "linux",
        diffIDs: [String]? = nil
    ) -> Data {
        var options = FixtureOptions()
        options.architecture = architecture
        options.operatingSystem = operatingSystem
        options.diffIDs = diffIDs
        return fixture(options).archive
    }

    private static func fixture(
        _ options: FixtureOptions
    ) -> MigrationImageArchiveTestFixture {
        let layerPayloads = options.layerPayloads
        let layerDigests = layerPayloads.map(sha256)
        let config = json([
            "architecture": options.architecture,
            "config": [:],
            "history": [],
            "os": options.operatingSystem,
            "rootfs": [
                "type": "layers",
                "diff_ids": options.diffIDs ?? layerDigests.map { "sha256:\($0)" }
            ]
        ])
        let configDigest = sha256(config)
        let selectedConfigDigest = options.mismatchedConfigPath
            ? String(repeating: "0", count: 64)
            : configDigest
        let configPath = options.contentAddressedLayout
            ? "blobs/sha256/\(selectedConfigDigest)"
            : selectedConfigDigest + ".json"
        let longLayerPath = "layers/" + String(repeating: "a", count: 120) + "/layer.tar"
        let layerPaths = options.contentAddressedLayout
            ? layerDigests.map { "blobs/sha256/\($0)" }
            : [options.paxLayerPath ? longLayerPath : "layer-a/layer.tar", "layer-b/layer.tar"]
        let manifest = json([[
            "Config": configPath,
            "RepoTags": (options.repoTags as Any?) ?? NSNull(),
            "Layers": options.missingReferencedLayer ? ["missing/layer.tar"] : layerPaths
        ]])
        let entries = imageEntries(ImageEntriesInput(
            configPath: configPath,
            config: config,
            layerPaths: layerPaths,
            layerPayloads: layerPayloads,
            manifest: manifest,
            missingReferencedLayer: options.missingReferencedLayer,
            base256LayerSize: options.base256LayerSize,
            paxLayerPath: options.paxLayerPath,
            contentAddressedLayout: options.contentAddressedLayout
        ))
        return MigrationImageArchiveTestFixture(
            archive: archive(entries),
            entries: entries,
            configDigest: configDigest,
            layerDigests: layerDigests
        )
    }

    private static func imageEntries(_ input: ImageEntriesInput) -> [MigrationImageTarTestEntry] {
        var entries = input.contentAddressedLayout ? [
            MigrationImageTarTestEntry(path: "blobs/", type: UInt8(ascii: "5")),
            MigrationImageTarTestEntry(path: "blobs/sha256/", type: UInt8(ascii: "5"))
        ] : []
        entries.append(MigrationImageTarTestEntry(
            path: input.configPath,
            payload: input.config
        ))
        if input.paxLayerPath {
            entries.append(MigrationImageTarTestEntry(
                path: "PaxHeaders/layer",
                type: UInt8(ascii: "x"),
                payload: paxRecord(key: "path", value: input.layerPaths[0])
            ))
            entries.append(MigrationImageTarTestEntry(
                path: "placeholder",
                payload: input.layerPayloads[0],
                base256Size: input.base256LayerSize
            ))
        } else {
            entries.append(MigrationImageTarTestEntry(
                path: input.layerPaths[0],
                payload: input.layerPayloads[0],
                base256Size: input.base256LayerSize
            ))
        }
        if !input.missingReferencedLayer {
            entries.append(MigrationImageTarTestEntry(
                path: input.layerPaths[1],
                payload: input.layerPayloads[1]
            ))
        }
        if input.contentAddressedLayout {
            entries.append(MigrationImageTarTestEntry(
                path: "index.json",
                payload: json(["schemaVersion": 2])
            ))
            entries.append(MigrationImageTarTestEntry(
                path: "oci-layout",
                payload: json(["imageLayoutVersion": "1.0.0"])
            ))
        }
        entries.append(MigrationImageTarTestEntry(
            path: "manifest.json",
            payload: input.manifest
        ))
        return entries
    }

    static func archive(
        _ entries: [MigrationImageTarTestEntry],
        terminator: Bool = true
    ) -> Data {
        var result = Data()
        for entry in entries {
            result.append(header(entry))
            result.append(entry.payload)
            let remainder = entry.payload.count % MigrationImageTarHeaderDecoder.blockBytes
            if remainder > 0 {
                result.append(Data(
                    repeating: 0,
                    count: MigrationImageTarHeaderDecoder.blockBytes - remainder
                ))
            }
        }
        if terminator {
            result.append(Data(
                repeating: 0,
                count: MigrationImageTarHeaderDecoder.blockBytes * 2
            ))
        }
        return result
    }

    static func fingerprint(
        _ archive: Data,
        chunkPattern: [Int] = [1, 7, 509, 2_047]
    ) throws -> MigrationImageArchiveFingerprint {
        var reader = MigrationImageArchiveReader()
        var offset = 0
        var chunkIndex = 0
        while offset < archive.count {
            let requested = chunkPattern[chunkIndex % chunkPattern.count]
            let count = min(requested, archive.count - offset)
            try reader.feed(archive.subdata(in: offset..<(offset + count)))
            offset += count
            chunkIndex += 1
        }
        return try reader.finish()
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func replacingManifest(
        in fixture: MigrationImageArchiveTestFixture,
        payload: Data
    ) -> Data {
        archive(fixture.entries.map { entry in
            entry.path == "manifest.json"
                ? MigrationImageTarTestEntry(path: entry.path, payload: payload)
                : entry
        })
    }

    static func pax(key: String, value: String) -> Data {
        paxRecord(key: key, value: value)
    }

    static func archiveWithRawSizeField(_ field: [UInt8]) -> Data {
        precondition(field.count == 12)
        var rawHeader = header(MigrationImageTarTestEntry(path: "invalid-size"))
        for (offset, byte) in field.enumerated() { rawHeader[124 + offset] = byte }
        updateChecksum(&rawHeader)
        return rawHeader + Data(repeating: 0, count: MigrationImageTarHeaderDecoder.blockBytes * 2)
    }

    static func json(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }
}

private extension MigrationImageArchiveTestSupport {
    static func paxRecord(key: String, value: String) -> Data {
        let body = "\(key)=\(value)\n"
        var length = body.utf8.count + 2
        while true {
            let record = "\(length) \(body)"
            if record.utf8.count == length { return Data(record.utf8) }
            length = record.utf8.count
        }
    }

    static func header(_ entry: MigrationImageTarTestEntry) -> Data {
        var header = Data(repeating: 0, count: MigrationImageTarHeaderDecoder.blockBytes)
        write(entry.path, to: &header, range: 0..<100)
        writeOctal(0o644, to: &header, range: 100..<108)
        writeOctal(0, to: &header, range: 108..<116)
        writeOctal(0, to: &header, range: 116..<124)
        if entry.base256Size {
            writeBase256(UInt64(entry.payload.count), to: &header, range: 124..<136)
        } else {
            writeOctal(UInt64(entry.payload.count), to: &header, range: 124..<136)
        }
        writeOctal(0, to: &header, range: 136..<148)
        for index in 148..<156 { header[index] = UInt8(ascii: " ") }
        header[156] = entry.type
        write("ustar", to: &header, range: 257..<263)
        write("00", to: &header, range: 263..<265)
        updateChecksum(&header)
        return header
    }

    static func updateChecksum(_ header: inout Data) {
        for index in 148..<156 { header[index] = UInt8(ascii: " ") }
        let checksum = header.reduce(UInt64(0)) { $0 + UInt64($1) }
        let encoded = String(checksum, radix: 8)
        let padded = String(repeating: "0", count: max(0, 6 - encoded.count)) + encoded
        write(padded, to: &header, range: 148..<154)
        header[154] = 0
        header[155] = UInt8(ascii: " ")
    }

    static func write(_ value: String, to data: inout Data, range: Range<Int>) {
        for (offset, byte) in value.utf8.prefix(range.count).enumerated() {
            data[range.lowerBound + offset] = byte
        }
    }

    static func writeOctal(_ value: UInt64, to data: inout Data, range: Range<Int>) {
        let encoded = String(value, radix: 8)
        let text = String(repeating: "0", count: max(0, range.count - encoded.count - 1)) + encoded
        write(text, to: &data, range: range.dropLast())
        data[range.upperBound - 1] = 0
    }

    static func writeBase256(_ value: UInt64, to data: inout Data, range: Range<Int>) {
        var remaining = value
        for index in range.reversed() {
            data[index] = UInt8(remaining & 0xff)
            remaining >>= 8
        }
        data[range.lowerBound] |= 0x80
    }
}
