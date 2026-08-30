#if arch(arm64)
import DoryFirmware
import Foundation

/// Live MMIO adapter for `dory.uefi.variable-bridge.armvirt@1`.
///
/// Command submission and persistence are serialized under one lock. Guests can transfer mailbox
/// bytes with 1/2/4/8-byte accesses, while scalar registers require their exact frozen widths.
final class ARMVirtUEFIVariableBridgeMMIO: MMIODevice, @unchecked Sendable {
    let baseAddress = DoryUEFIVariableBridgeV1ABI.baseAddress
    let size = DoryUEFIVariableBridgeV1ABI.byteCount

    private let lock = NSLock()
    private let service: DoryUEFIVariableBridgeService
    private var status = DoryUEFIVariableBridgeStatus.idle
    private var command = DoryUEFIVariableBridgeCommand.reset.rawValue
    private var attributes: UInt32 = 0
    private var generation: UInt64 = 0
    private var vendor = [UInt8](repeating: 0, count: DoryUEFIVariableBridgeV1ABI.vendorByteCount)
    private var nameLength: UInt32 = 0
    private var dataLength: UInt32 = 0
    private var name = [UInt8](repeating: 0, count: DoryUEFIVariableBridgeV1ABI.nameByteCount)
    private var data = [UInt8](repeating: 0, count: DoryUEFIVariableBridgeV1ABI.dataByteCount)

    init(store: DoryUEFIVariableStoreFile) throws {
        try DoryUEFIVariableBridgeV1ABI.validateLayout()
        self.service = DoryUEFIVariableBridgeService(store: store)
        let initial = service.execute(.init(command: .reset))
        self.status = initial.status
        self.generation = initial.generation
    }

    func read(offset: UInt64, width: Int) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        guard Self.isSupportedWidth(width), Self.range(offset: offset, width: width, fits: size)
        else { return 0 }

        if offset == DoryUEFIVariableBridgeV1ABI.magicOffset, width == 8 {
            return DoryUEFIVariableBridgeV1ABI.magic
        }
        if offset == DoryUEFIVariableBridgeV1ABI.versionOffset, width == 4 {
            return UInt64(DoryUEFIVariableBridgeV1ABI.version)
        }
        if offset == DoryUEFIVariableBridgeV1ABI.statusOffset, width == 4 {
            return UInt64(status.rawValue)
        }
        if offset == DoryUEFIVariableBridgeV1ABI.commandOffset, width == 4 {
            return UInt64(command)
        }
        if offset == DoryUEFIVariableBridgeV1ABI.attributesOffset, width == 4 {
            return UInt64(attributes)
        }
        if offset == DoryUEFIVariableBridgeV1ABI.generationOffset, width == 8 {
            return generation
        }
        if offset == DoryUEFIVariableBridgeV1ABI.nameLengthOffset, width == 4 {
            return UInt64(nameLength)
        }
        if offset == DoryUEFIVariableBridgeV1ABI.dataLengthOffset, width == 4 {
            return UInt64(dataLength)
        }
        if let start = Self.mailboxIndex(
            offset: offset,
            width: width,
            base: DoryUEFIVariableBridgeV1ABI.vendorOffset,
            count: vendor.count
        ) {
            return Self.littleEndianValue(vendor[start..<(start + width)])
        }
        if let start = Self.mailboxIndex(
            offset: offset,
            width: width,
            base: DoryUEFIVariableBridgeV1ABI.nameOffset,
            count: name.count
        ) {
            return Self.littleEndianValue(name[start..<(start + width)])
        }
        if let start = Self.mailboxIndex(
            offset: offset,
            width: width,
            base: DoryUEFIVariableBridgeV1ABI.dataOffset,
            count: data.count
        ) {
            return Self.littleEndianValue(data[start..<(start + width)])
        }
        return 0
    }

    func write(offset: UInt64, value: UInt64, width: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard Self.isSupportedWidth(width), Self.range(offset: offset, width: width, fits: size)
        else { return }

        if offset == DoryUEFIVariableBridgeV1ABI.commandOffset, width == 4 {
            command = UInt32(truncatingIfNeeded: value)
            executeCommand(command)
            return
        }
        if offset == DoryUEFIVariableBridgeV1ABI.attributesOffset, width == 4 {
            attributes = UInt32(truncatingIfNeeded: value)
            return
        }
        if offset == DoryUEFIVariableBridgeV1ABI.nameLengthOffset, width == 4 {
            nameLength = UInt32(truncatingIfNeeded: value)
            return
        }
        if offset == DoryUEFIVariableBridgeV1ABI.dataLengthOffset, width == 4 {
            dataLength = UInt32(truncatingIfNeeded: value)
            return
        }
        if let start = Self.mailboxIndex(
            offset: offset,
            width: width,
            base: DoryUEFIVariableBridgeV1ABI.vendorOffset,
            count: vendor.count
        ) {
            Self.storeLittleEndian(value, width: width, in: &vendor, at: start)
            return
        }
        if let start = Self.mailboxIndex(
            offset: offset,
            width: width,
            base: DoryUEFIVariableBridgeV1ABI.nameOffset,
            count: name.count
        ) {
            Self.storeLittleEndian(value, width: width, in: &name, at: start)
            return
        }
        if let start = Self.mailboxIndex(
            offset: offset,
            width: width,
            base: DoryUEFIVariableBridgeV1ABI.dataOffset,
            count: data.count
        ) {
            Self.storeLittleEndian(value, width: width, in: &data, at: start)
        }
    }

    private func executeCommand(_ rawValue: UInt32) {
        guard let command = DoryUEFIVariableBridgeCommand(rawValue: rawValue) else {
            apply(.init(status: .invalidRequest, generation: generation))
            return
        }
        if command == .reset {
            clearResponseMailboxes()
            apply(service.execute(.init(command: .reset)))
            return
        }
        guard let nameCount = Int(exactly: nameLength), nameCount <= name.count,
              let dataCount = Int(exactly: dataLength), dataCount <= data.count else {
            apply(.init(status: .invalidRequest, generation: generation))
            return
        }

        let needsKey = command == .get || command == .set || command == .delete || command == .next
        let requestVendor = needsKey ? Self.uuid(from: vendor) : nil
        let requestName = needsKey ? String(data: Data(name.prefix(nameCount)), encoding: .utf8) : nil
        guard !needsKey || (requestVendor != nil && requestName != nil) else {
            apply(.init(status: .invalidRequest, generation: generation))
            return
        }
        let request = DoryUEFIVariableBridgeRequest(
            command: command,
            vendor: requestVendor,
            name: requestName,
            attributes: DoryUEFIVariableAttributes(rawValue: attributes),
            data: command == .set ? Data(data.prefix(dataCount)) : Data()
        )
        apply(service.execute(request))
    }

    private func apply(_ response: DoryUEFIVariableBridgeResponse) {
        status = response.status
        generation = response.generation
        clearResponseMailboxes()
        guard let variable = response.variable else { return }
        vendor = Self.bytes(of: variable.key.vendor)
        let nameBytes = Array(variable.key.name.utf8)
        name.replaceSubrange(0..<nameBytes.count, with: nameBytes)
        nameLength = UInt32(nameBytes.count)
        let variableData = [UInt8](variable.data)
        data.replaceSubrange(0..<variableData.count, with: variableData)
        dataLength = UInt32(variableData.count)
        attributes = variable.attributes.rawValue
    }

    private func clearResponseMailboxes() {
        attributes = 0
        nameLength = 0
        dataLength = 0
        vendor = [UInt8](repeating: 0, count: vendor.count)
        name = [UInt8](repeating: 0, count: name.count)
        data = [UInt8](repeating: 0, count: data.count)
    }

    private static func isSupportedWidth(_ width: Int) -> Bool {
        width == 1 || width == 2 || width == 4 || width == 8
    }

    private static func range(offset: UInt64, width: Int, fits byteCount: UInt64) -> Bool {
        guard width > 0, let unsignedWidth = UInt64(exactly: width) else { return false }
        let (end, overflow) = offset.addingReportingOverflow(unsignedWidth)
        return !overflow && end <= byteCount
    }

    private static func mailboxIndex(
        offset: UInt64,
        width: Int,
        base: UInt64,
        count: Int
    ) -> Int? {
        guard offset >= base else { return nil }
        let relative = offset - base
        guard let start = Int(exactly: relative), start <= count,
              width <= count - start else { return nil }
        return start
    }

    private static func littleEndianValue(_ bytes: ArraySlice<UInt8>) -> UInt64 {
        bytes.enumerated().reduce(into: UInt64(0)) { value, element in
            value |= UInt64(element.element) << UInt64(element.offset * 8)
        }
    }

    private static func storeLittleEndian(
        _ value: UInt64,
        width: Int,
        in bytes: inout [UInt8],
        at start: Int
    ) {
        for index in 0..<width {
            bytes[start + index] = UInt8(truncatingIfNeeded: value >> UInt64(index * 8))
        }
    }

    private static func bytes(of uuid: UUID) -> [UInt8] {
        var raw = uuid.uuid
        return withUnsafeBytes(of: &raw) { Array($0) }
    }

    private static func uuid(from bytes: [UInt8]) -> UUID? {
        guard bytes.count == DoryUEFIVariableBridgeV1ABI.vendorByteCount else { return nil }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
#endif
