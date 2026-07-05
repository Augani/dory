/// Minimal i8042 keyboard-controller stub. It owns only the data port (0x60) and the
/// command/status port (0x64); ports 0x61-0x63 are deliberately left unclaimed so the system
/// control port B is not black-holed. The only guest-visible side effect v1 needs is command
/// 0xFE, which Linux uses as a legacy reset pulse.
public final class I8042: PIODevice {
    public let basePort: UInt16 = 0x60
    public let portCount: UInt16 = 5
    private static let dataPort: UInt16 = 0x60
    private static let commandPort: UInt16 = 0x64
    private static let resetCommand: UInt8 = 0xFE

    private let reset: () -> Void

    public init(reset: @escaping () -> Void) {
        self.reset = reset
    }

    public func handles(port: UInt16) -> Bool {
        port == Self.dataPort || port == Self.commandPort
    }

    public func read(portOffset: UInt16, width: Int) -> UInt32 {
        0
    }

    public func write(portOffset: UInt16, value: UInt32, width: Int) {
        let port = basePort + portOffset
        if port == Self.commandPort, UInt8(truncatingIfNeeded: value) == Self.resetCommand {
            reset()
        }
    }
}
