import Foundation

public struct UsbAttachOutcome: Equatable, Sendable, Codable {
    public var busID: String
    public var port: Int
    public var vsockPort: UInt32
    public var deviceID: UInt32
    public var speed: UInt32
}

public struct UsbAgentAttachRequest: Equatable, Sendable, Encodable {
    public var busid: String
    public var port: Int
    public var vsock_port: UInt32
    public var device_id: UInt32
    public var speed: UInt32
}

public struct UsbAgentDetachRequest: Equatable, Sendable, Encodable {
    public var busid: String
    public var port: Int
}

public enum UsbControlError: Error, Equatable, Sendable, CustomStringConvertible {
    case alreadyAttached(String)
    case notAttached(String)
    case guestAgentRPCUnavailable

    public var description: String {
        switch self {
        case .alreadyAttached(let busID):
            return "USB device is already attached: \(busID)"
        case .notAttached(let busID):
            return "USB device is not attached: \(busID)"
        case .guestAgentRPCUnavailable:
            return "USB attach/detach is unavailable: dory-agent control protocol has no USB RPC"
        }
    }
}

/// The engine-side logic behind `dory usb attach/detach`: claim the host device, register it with the
/// `UsbipManager` so the listener can serve it, and tell the guest agent to dial and vhci-attach. All
/// three collaborators are injected so the full sequence (including rollback when the guest notify
/// fails) is unit-testable without real hardware, a socket, or a running guest.
public final class UsbControlHandler: @unchecked Sendable {
    private let manager: UsbipManager
    private let ensureSupported: () throws -> Void
    private let openDevice: (String, HostUsbOpenMode) throws -> any UsbipExportedDevice
    private let notifyAttach: (UsbAgentAttachRequest) async throws -> Void
    private let notifyDetach: (UsbAgentDetachRequest) async throws -> Void

    private let lock = NSLock()
    private var portByBusID: [String: Int] = [:]
    private var usedPorts = Set<Int>()

    public init(
        manager: UsbipManager,
        ensureSupported: @escaping () throws -> Void = {},
        openDevice: @escaping (String, HostUsbOpenMode) throws -> any UsbipExportedDevice,
        notifyAttach: @escaping (UsbAgentAttachRequest) async throws -> Void,
        notifyDetach: @escaping (UsbAgentDetachRequest) async throws -> Void
    ) {
        self.manager = manager
        self.ensureSupported = ensureSupported
        self.openDevice = openDevice
        self.notifyAttach = notifyAttach
        self.notifyDetach = notifyDetach
    }

    public func attach(busID: String, mode: HostUsbOpenMode = .userAuthorized) async throws -> UsbAttachOutcome {
        // Capability is checked before opening or claiming the host device. A missing guest RPC must
        // fail closed; briefly seizing hardware and rolling back is still an observable disruption.
        try ensureSupported()
        try lock.withLock {
            guard portByBusID[busID] == nil else { throw UsbControlError.alreadyAttached(busID) }
        }
        let device = try openDevice(busID, mode)
        manager.register(device)
        let port = lock.withLock { allocatePortLocked(for: busID) }
        let descriptor = device.descriptor
        let request = UsbAgentAttachRequest(
            busid: busID,
            port: port,
            vsock_port: manager.port,
            device_id: (descriptor.busNumber << 16) | descriptor.deviceNumber,
            speed: descriptor.speed
        )
        do {
            try await notifyAttach(request)
        } catch {
            // The guest could not attach — undo the host-side claim so the device returns to macOS.
            manager.unregister(busID: busID)
            lock.withLock { releasePortLocked(busID) }
            throw error
        }
        return UsbAttachOutcome(busID: busID, port: port, vsockPort: request.vsock_port, deviceID: request.device_id, speed: request.speed)
    }

    public func detach(busID: String) async throws {
        try ensureSupported()
        let port = try lock.withLock { () -> Int in
            guard let port = portByBusID[busID] else { throw UsbControlError.notAttached(busID) }
            return port
        }
        try await notifyDetach(UsbAgentDetachRequest(busid: busID, port: port))
        manager.unregister(busID: busID)
        lock.withLock { releasePortLocked(busID) }
    }

    public var attachedBusIDs: [String] {
        lock.withLock { portByBusID.keys.sorted() }
    }

    private func allocatePortLocked(for busID: String) -> Int {
        var port = 0
        while usedPorts.contains(port) { port += 1 }
        usedPorts.insert(port)
        portByBusID[busID] = port
        return port
    }

    private func releasePortLocked(_ busID: String) {
        if let port = portByBusID.removeValue(forKey: busID) {
            usedPorts.remove(port)
        }
    }
}

private extension NSLock {
    func withLock<R>(_ body: () throws -> R) rethrows -> R {
        lock(); defer { unlock() }
        return try body()
    }
}
