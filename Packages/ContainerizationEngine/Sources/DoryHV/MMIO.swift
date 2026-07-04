/// A memory-mapped device the guest reaches through stage-2 data aborts.
public protocol MMIODevice: AnyObject {
    var baseAddress: UInt64 { get }
    var size: UInt64 { get }
    func read(offset: UInt64, width: Int) -> UInt64
    func write(offset: UInt64, value: UInt64, width: Int)
}

/// Routes guest data aborts to the owning device by physical address.
public final class MMIOBus {
    private var devices: [MMIODevice] = []

    public init() {}

    public func attach(_ device: MMIODevice) {
        devices.append(device)
    }

    public func device(for address: UInt64) -> (MMIODevice, UInt64)? {
        for device in devices where address >= device.baseAddress && address < device.baseAddress + device.size {
            return (device, address - device.baseAddress)
        }
        return nil
    }
}

/// Fields of an EC=0x24 (data abort from a lower EL) syndrome, valid when ISV is set.
public struct DataAbortInfo {
    public let isValid: Bool
    public let width: Int
    public let registerIndex: Int
    public let isWrite: Bool
    public let signExtend: Bool
    public let sixtyFourBit: Bool

    public init(syndrome: UInt64) {
        self.isValid = (syndrome >> 24) & 1 == 1
        self.width = 1 << Int((syndrome >> 22) & 0b11)
        self.signExtend = (syndrome >> 21) & 1 == 1
        self.registerIndex = Int((syndrome >> 16) & 0x1F)
        self.sixtyFourBit = (syndrome >> 15) & 1 == 1
        self.isWrite = (syndrome >> 6) & 1 == 1
    }
}
