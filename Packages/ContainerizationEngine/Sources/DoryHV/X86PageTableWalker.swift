public struct X86PageWalkResult: Equatable, Sendable {
    public let physicalAddress: UInt64
    public let pageSize: UInt64
}

public enum X86PageWalkError: Error, Equatable, CustomStringConvertible {
    case nonCanonical(UInt64)
    case notPresent(level: String, address: UInt64)
    case reservedHugePage(level: String, address: UInt64)
    case memoryFault(address: UInt64)

    public var description: String {
        switch self {
        case .nonCanonical(let address):
            "non-canonical x86 virtual address 0x\(String(address, radix: 16))"
        case .notPresent(let level, let address):
            "\(level) entry not present at 0x\(String(address, radix: 16))"
        case .reservedHugePage(let level, let address):
            "\(level) huge-page entry has reserved low address bits at 0x\(String(address, radix: 16))"
        case .memoryFault(let address):
            "page table memory fault at 0x\(String(address, radix: 16))"
        }
    }
}

public struct X86PageTableWalker {
    private let memory: GuestMemory

    private static let present: UInt64 = 1 << 0
    private static let pageSize: UInt64 = 1 << 7
    private static let addressMask4K: UInt64 = 0x000F_FFFF_FFFF_F000
    private static let addressMask2M: UInt64 = 0x000F_FFFF_FFE0_0000
    private static let addressMask1G: UInt64 = 0x000F_FFFF_C000_0000
    private static let reservedMask1G: UInt64 = 0x3FFF_E000
    private static let reservedMask2M: UInt64 = 0x001F_E000

    public init(memory: GuestMemory) {
        self.memory = memory
    }

    public func translate(virtualAddress: UInt64, cr3: UInt64) throws -> X86PageWalkResult {
        guard Self.isCanonical(virtualAddress) else {
            throw X86PageWalkError.nonCanonical(virtualAddress)
        }

        let pml4 = cr3 & Self.addressMask4K
        let pml4Entry = try readEntry(table: pml4, index: (virtualAddress >> 39) & 0x1FF, level: "PML4")
        let pdpt = pml4Entry & Self.addressMask4K
        let pdptEntry = try readEntry(table: pdpt, index: (virtualAddress >> 30) & 0x1FF, level: "PDPT")
        if pdptEntry & Self.pageSize != 0 {
            let base = pdptEntry & Self.addressMask1G
            guard pdptEntry & Self.reservedMask1G == 0 else {
                throw X86PageWalkError.reservedHugePage(level: "PDPT", address: base)
            }
            return X86PageWalkResult(physicalAddress: base | (virtualAddress & 0x3FFF_FFFF), pageSize: 1 << 30)
        }

        let pd = pdptEntry & Self.addressMask4K
        let pdEntry = try readEntry(table: pd, index: (virtualAddress >> 21) & 0x1FF, level: "PD")
        if pdEntry & Self.pageSize != 0 {
            let base = pdEntry & Self.addressMask2M
            guard pdEntry & Self.reservedMask2M == 0 else {
                throw X86PageWalkError.reservedHugePage(level: "PD", address: base)
            }
            return X86PageWalkResult(physicalAddress: base | (virtualAddress & 0x1F_FFFF), pageSize: 1 << 21)
        }

        let pt = pdEntry & Self.addressMask4K
        let ptEntry = try readEntry(table: pt, index: (virtualAddress >> 12) & 0x1FF, level: "PT")
        let base = ptEntry & Self.addressMask4K
        return X86PageWalkResult(physicalAddress: base | (virtualAddress & 0xFFF), pageSize: 1 << 12)
    }

    public func readBytes(virtualAddress: UInt64, count: Int, cr3: UInt64) throws -> [UInt8] {
        guard count > 0 else { return [] }
        var output = [UInt8]()
        output.reserveCapacity(count)
        var current = virtualAddress
        var remaining = count

        while remaining > 0 {
            let result: X86PageWalkResult
            do {
                result = try translate(virtualAddress: current, cr3: cr3)
            } catch {
                guard output.isEmpty else { break }
                throw error
            }
            let pageOffset = Int(current & (result.pageSize - 1))
            let take = min(remaining, Int(result.pageSize) - pageOffset)
            let chunk: [UInt8]
            do {
                chunk = try memory.readBytes(at: result.physicalAddress, count: take)
            } catch {
                guard output.isEmpty else { break }
                throw error
            }
            output += chunk
            current += UInt64(take)
            remaining -= take
        }
        return output
    }

    private func readEntry(table: UInt64, index: UInt64, level: String) throws -> UInt64 {
        let address = table + index * 8
        let entry: UInt64
        do {
            entry = try memory.read(UInt64.self, at: address)
        } catch {
            throw X86PageWalkError.memoryFault(address: address)
        }
        guard entry & Self.present != 0 else {
            throw X86PageWalkError.notPresent(level: level, address: address)
        }
        return entry
    }

    private static func isCanonical(_ address: UInt64) -> Bool {
        let high = address >> 48
        let sign = (address >> 47) & 1
        return sign == 0 ? high == 0 : high == 0xFFFF
    }
}
