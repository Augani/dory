import Foundation

/// Owns the engine's usbip listener and the set of currently-claimed host devices. `dory usb attach`
/// claims a device (via the control plane) and `register`s it here; the guest agent then dials
/// `VsockPorts.usbip`, and the accepted connection is served by a `UsbipBridge` backed by whatever
/// devices are registered — the guest's OP_REQ_IMPORT busID selects which one. Detach `unregister`s it.
public final class UsbipManager: @unchecked Sendable {
    private let lock = NSLock()
    private var devices: [String: any UsbipExportedDevice] = [:]
    private let vsockPort: UInt32

    public init(vsockPort: UInt32 = VsockPorts.usbip) {
        self.vsockPort = vsockPort
    }

    public var port: UInt32 { vsockPort }

    /// Registers the listener on the engine's vsock so guest usbip dials are served on their own
    /// bridge queue (never the vsock dispatch queue).
    public func attachListener(to vsock: VirtioVsock) {
        vsock.listen(port: vsockPort) { [weak self] connection in
            guard let self else { connection.close(); return }
            let exported = self.exportedDevices()
            guard !exported.isEmpty else { connection.close(); return }
            UsbipBridge(connection: connection, server: UsbipServer(devices: exported)).start()
        }
    }

    public func register(_ device: any UsbipExportedDevice) {
        lock.lock(); defer { lock.unlock() }
        devices[device.descriptor.busID] = device
    }

    @discardableResult
    public func unregister(busID: String) -> (any UsbipExportedDevice)? {
        lock.lock(); defer { lock.unlock() }
        return devices.removeValue(forKey: busID)
    }

    public func exportedDevice(busID: String) -> (any UsbipExportedDevice)? {
        lock.lock(); defer { lock.unlock() }
        return devices[busID]
    }

    public func exportedDevices() -> [any UsbipExportedDevice] {
        lock.lock(); defer { lock.unlock() }
        return Array(devices.values)
    }

    public var claimedBusIDs: [String] {
        lock.lock(); defer { lock.unlock() }
        return devices.keys.sorted()
    }
}
