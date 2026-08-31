import DoryHostDeviceBroker
import DoryHV
import DoryMachinePC
import DoryVMContracts
import Foundation

/// Direct DoryPC USB control. A stable, user-selected physical identity is captured through the
/// host-device lease broker and attached to the emulated xHCI root hub. The VM never receives
/// ambient IOKit authority or a USB/IP listener.
final class DoryPCUSBControlHandler: UsbControlRequestHandling, @unchecked Sendable {
    typealias CandidateLookup = @Sendable (String) throws -> HostUsbDeviceCandidate
    typealias LeaseOpener = @Sendable (
        HostUsbDeviceCandidate,
        DoryUSBPhysicalIdentityToken
    ) throws -> DoryHostUSBLeaseDevice

    private struct Attachment {
        let port: Int
        let lease: DoryHostUSBLeaseDevice
    }

    private let lock = NSLock()
    private var controller: DoryPCXHCIController
    private let lookupCandidate: CandidateLookup
    private let openLease: LeaseOpener
    private var attachments = [String: Attachment]()

    init(
        controller: DoryPCXHCIController,
        machineID: String,
        broker: DoryHostUSBLeaseBroker = DoryHostUSBLeaseBroker(),
        lookupCandidate: CandidateLookup? = nil,
        openLease: LeaseOpener? = nil
    ) {
        self.controller = controller
        self.lookupCandidate = lookupCandidate ?? { busID in
            guard let candidate = try HostUsbDiscovery.list().first(where: {
                $0.descriptor.busID == busID
            }) else {
                throw HostUsbOpenError.notFound(busID)
            }
            return candidate
        }
        self.openLease = openLease ?? { candidate, identity in
            let capability = try DoryIOUSBHostTransferCapability.capture(
                expectedIdentityToken: identity,
                speed: Self.portSpeed(candidate.descriptor.speed)
            )
            do {
                return try broker.acquire(
                    machineID: machineID,
                    identityToken: identity,
                    family: Self.family(candidate),
                    admission: .init(userSelected: true),
                    capability: capability
                )
            } catch {
                capability.close()
                throw error
            }
        }
    }

    func replaceController(_ replacement: DoryPCXHCIController) throws {
        try lock.withLock {
            var connectedPorts = [Int]()
            do {
                for attachment in attachments.values.sorted(by: { $0.port < $1.port }) {
                    try replacement.connect(port: attachment.port, device: attachment.lease)
                    connectedPorts.append(attachment.port)
                }
            } catch {
                for port in connectedPorts { try? replacement.disconnect(port: port) }
                throw error
            }
            controller = replacement
        }
    }

    func attach(
        busID: String,
        expectedIdentity: DoryUSBPhysicalIdentityToken,
        mode: HostUsbOpenMode
    ) async throws -> DoryUSBControlV1.Attachment {
        guard DoryUSBControlV1.BusID.isValid(busID) else {
            throw UsbControlError.invalidBusID(busID)
        }
        guard mode == .userAuthorized else {
            throw UsbControlError.openModeNotAllowed(mode)
        }
        let admitted = try lock.withLock { () -> (DoryUSBControlV1.Attachment, DoryHostUSBLeaseDevice) in
            guard attachments[busID] == nil else {
                throw UsbControlError.alreadyAttached(busID)
            }
            guard let port = (2...DoryPCXHCIController.portCount).first(where: { candidate in
                !attachments.values.contains(where: { $0.port == candidate })
            }) else {
                throw UsbControlError.mutationRejected(
                    operation: .attach,
                    busID: busID,
                    detail: "all DoryPC xHCI passthrough ports are occupied"
                )
            }
            let candidate = try lookupCandidate(busID)
            guard candidate.descriptor.busID == busID else {
                throw UsbControlError.deviceIdentityMismatch(
                    expected: busID,
                    actual: candidate.descriptor.busID
                )
            }
            guard candidate.identityToken == expectedIdentity else {
                throw HostUsbOpenError.identityMismatch(
                    busID: busID,
                    expected: expectedIdentity,
                    actual: candidate.identityToken
                )
            }
            guard candidate.captureDecision.allowed else {
                throw HostUsbOpenError.captureDenied(
                    busID: busID,
                    reason: candidate.captureDecision.blockReason ?? .internalHostDevice
                )
            }
            let descriptor = candidate.descriptor
            guard descriptor.busNumber <= UInt32(UInt16.max),
                  descriptor.deviceNumber > 0,
                  descriptor.deviceNumber <= UInt32(UInt16.max) else {
                throw UsbControlError.invalidDeviceIdentity(
                    busID: busID,
                    busNumber: descriptor.busNumber,
                    deviceNumber: descriptor.deviceNumber
                )
            }
            let lease = try openLease(candidate, expectedIdentity)
            let deviceID = (descriptor.busNumber << 16) | descriptor.deviceNumber
            do {
                let wireAttachment = try DoryUSBControlV1.Attachment(
                    port: port,
                    vsockPort: DoryUSBControlV1.usbipVsockPort,
                    deviceID: deviceID,
                    speed: descriptor.speed
                )
                try controller.connect(port: port, device: lease)
                attachments[busID] = Attachment(
                    port: port,
                    lease: lease
                )
                return (wireAttachment, lease)
            } catch {
                lease.setRevocationHandler(nil)
                lease.release()
                throw error
            }
        }
        admitted.1.setRevocationHandler { [weak self, weak lease = admitted.1] in
            guard let lease else { return }
            self?.leaseRevoked(busID: busID, leaseID: lease.leaseID)
        }
        return admitted.0
    }

    func detach(busID: String) async throws {
        let detached = try lock.withLock { () -> (DoryPCXHCIController, Attachment) in
            guard let attachment = attachments.removeValue(forKey: busID) else {
                throw UsbControlError.notAttached(busID)
            }
            attachment.lease.setRevocationHandler(nil)
            return (controller, attachment)
        }
        do {
            try detached.0.disconnect(port: detached.1.port)
        } catch {
            detached.1.lease.release()
            throw UsbControlError.outcomeUnknown(
                operation: .detach,
                busID: busID,
                detail: "host lease was released but xHCI disconnect failed: \(error)"
            )
        }
        detached.1.lease.release()
    }

    func stop() {
        let retired = lock.withLock { () -> (DoryPCXHCIController, [Attachment]) in
            let result = attachments.values.sorted(by: { $0.port < $1.port })
            attachments.removeAll()
            result.forEach { $0.lease.setRevocationHandler(nil) }
            return (controller, result)
        }
        for attachment in retired.1 {
            try? retired.0.disconnect(port: attachment.port)
            attachment.lease.release()
        }
    }

    private func leaseRevoked(busID: String, leaseID: UUID) {
        let detached = lock.withLock { () -> (DoryPCXHCIController, Attachment)? in
            guard let attachment = attachments[busID], attachment.lease.leaseID == leaseID else {
                return nil
            }
            attachments.removeValue(forKey: busID)
            return (controller, attachment)
        }
        if let detached { try? detached.0.disconnect(port: detached.1.port) }
    }

    private static func portSpeed(_ rawValue: UInt32) -> DoryPCXHCIPortSpeed {
        switch rawValue {
        case 1: .low
        case 2: .full
        case 3: .high
        case 5: .superSpeed
        case 6: .superSpeedPlus
        default: .high
        }
    }

    private static func family(_ candidate: HostUsbDeviceCandidate) -> DoryHostUSBDeviceFamily {
        let identities = [(candidate.descriptor.deviceClass, candidate.descriptor.deviceProtocol)]
            + candidate.interfaces.map { ($0.interfaceClass, $0.interfaceProtocol) }
        if identities.contains(where: { $0.0 == 0x08 }) { return .storage }
        if identities.contains(where: { $0.0 == 0x0b }) { return .smartCard }
        if identities.contains(where: { $0.0 == 0x0e }) { return .camera }
        if identities.contains(where: { $0.0 == 0x01 }) { return .audio }
        if identities.contains(where: { $0 == (0x03, 0x01) }) { return .keyboard }
        if identities.contains(where: { $0 == (0x03, 0x02) }) { return .pointingDevice }
        if identities.contains(where: { $0.0 == 0x02 || $0.0 == 0x0a }) {
            return .serialAdapter
        }
        return .other
    }

    deinit { stop() }
}
