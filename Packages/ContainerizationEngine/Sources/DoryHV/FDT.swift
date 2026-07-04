import Foundation

/// Minimal flattened device tree writer (v17 format). Everything in the structure and header is
/// big-endian per spec. Produces the blob handed to the kernel in x0.
public final class FDTBuilder {
    private var structure = [UInt8]()
    private var strings = [UInt8]()
    private var stringOffsets = [String: UInt32]()
    private var openNodes = 0
    private var finished = false

    private static let beginNode: UInt32 = 1
    private static let endNode: UInt32 = 2
    private static let prop: UInt32 = 3
    private static let end: UInt32 = 9
    private static let magic: UInt32 = 0xD00D_FEED

    public init() {}

    public func beginNode(_ name: String) {
        precondition(!finished, "builder already finished")
        appendToken(Self.beginNode)
        appendNullTerminated(name)
        alignStructure()
        openNodes += 1
    }

    public func endNode() {
        precondition(openNodes > 0, "no open node")
        appendToken(Self.endNode)
        openNodes -= 1
    }

    public func property(_ name: String, bytes: [UInt8]) {
        precondition(openNodes > 0, "property outside node")
        appendToken(Self.prop)
        appendToken(UInt32(bytes.count))
        appendToken(stringOffset(for: name))
        structure.append(contentsOf: bytes)
        alignStructure()
    }

    public func property(_ name: String, cells: [UInt32]) {
        var bytes = [UInt8]()
        bytes.reserveCapacity(cells.count * 4)
        for cell in cells {
            withUnsafeBytes(of: cell.bigEndian) { bytes.append(contentsOf: $0) }
        }
        property(name, bytes: bytes)
    }

    public func property(_ name: String, cells64 values: [UInt64]) {
        var cells = [UInt32]()
        cells.reserveCapacity(values.count * 2)
        for value in values {
            cells.append(UInt32(value >> 32))
            cells.append(UInt32(value & 0xFFFF_FFFF))
        }
        property(name, cells: cells)
    }

    public func property(_ name: String, string value: String) {
        property(name, bytes: [UInt8](value.utf8) + [0])
    }

    public func property(_ name: String, strings values: [String]) {
        var bytes = [UInt8]()
        for value in values {
            bytes.append(contentsOf: [UInt8](value.utf8))
            bytes.append(0)
        }
        property(name, bytes: bytes)
    }

    public func emptyProperty(_ name: String) {
        property(name, bytes: [])
    }

    public func finish(bootCPU: UInt32 = 0) -> [UInt8] {
        precondition(openNodes == 0, "unbalanced nodes")
        precondition(!finished, "already finished")
        finished = true
        appendToken(Self.end)

        let headerSize = 40
        let reserveMapSize = 16
        let structureOffset = headerSize + reserveMapSize
        let stringsOffset = structureOffset + structure.count
        let totalSize = stringsOffset + strings.count

        var blob = [UInt8]()
        blob.reserveCapacity(totalSize)
        appendBigEndian(Self.magic, to: &blob)
        appendBigEndian(UInt32(totalSize), to: &blob)
        appendBigEndian(UInt32(structureOffset), to: &blob)
        appendBigEndian(UInt32(stringsOffset), to: &blob)
        appendBigEndian(UInt32(headerSize), to: &blob)
        appendBigEndian(UInt32(17), to: &blob)
        appendBigEndian(UInt32(16), to: &blob)
        appendBigEndian(bootCPU, to: &blob)
        appendBigEndian(UInt32(strings.count), to: &blob)
        appendBigEndian(UInt32(structure.count), to: &blob)
        blob.append(contentsOf: [UInt8](repeating: 0, count: reserveMapSize))
        blob.append(contentsOf: structure)
        blob.append(contentsOf: strings)
        return blob
    }

    private func appendToken(_ token: UInt32) {
        appendBigEndian(token, to: &structure)
    }

    private func appendBigEndian(_ value: UInt32, to buffer: inout [UInt8]) {
        withUnsafeBytes(of: value.bigEndian) { buffer.append(contentsOf: $0) }
    }

    private func appendNullTerminated(_ text: String) {
        structure.append(contentsOf: [UInt8](text.utf8))
        structure.append(0)
    }

    private func alignStructure() {
        while structure.count % 4 != 0 { structure.append(0) }
    }

    private func stringOffset(for name: String) -> UInt32 {
        if let existing = stringOffsets[name] { return existing }
        let offset = UInt32(strings.count)
        strings.append(contentsOf: [UInt8](name.utf8))
        strings.append(0)
        stringOffsets[name] = offset
        return offset
    }
}
