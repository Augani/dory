/// A port-mapped device the x86 guest reaches through IN/OUT VM exits.
public protocol PIODevice: AnyObject {
    var basePort: UInt16 { get }
    var portCount: UInt16 { get }
    func handles(port: UInt16) -> Bool
    func read(portOffset: UInt16, width: Int) -> UInt32
    func write(portOffset: UInt16, value: UInt32, width: Int)
}

extension PIODevice {
    public func handles(port: UInt16) -> Bool {
        port >= basePort && port - basePort < portCount
    }
}

/// Routes x86 port I/O exits to the owning device by I/O port number.
public final class PIOBus {
    private var devices: [PIODevice] = []

    public init() {}

    public func attach(_ device: PIODevice) {
        devices.append(device)
    }

    public func device(for port: UInt16) -> (PIODevice, UInt16)? {
        for device in devices where device.handles(port: port) {
            return (device, port - device.basePort)
        }
        return nil
    }

    public func read(port: UInt16, width: Int) -> UInt32 {
        guard let (device, offset) = device(for: port) else {
            return Self.unmappedReadValue(width: width)
        }
        return device.read(portOffset: offset, width: width)
    }

    public func write(port: UInt16, value: UInt32, width: Int) {
        guard let (device, offset) = device(for: port) else { return }
        device.write(portOffset: offset, value: value, width: width)
    }

    public static func unmappedReadValue(width: Int) -> UInt32 {
        switch width {
        case 1: return 0xFF
        case 2: return 0xFFFF
        case 4: return 0xFFFF_FFFF
        default: return 0
        }
    }
}
