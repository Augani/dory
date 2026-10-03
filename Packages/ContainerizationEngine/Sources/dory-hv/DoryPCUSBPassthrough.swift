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

    private struct PendingAttachment: Equatable {
        let port: Int
        let id = UUID()
    }

    private let lock = NSLock()
    private var controller: DoryPCXHCIController
    private let lookupCandidate: CandidateLookup
    private let openLease: LeaseOpener
    private var attachments = [String: Attachment]()
    private var pendingAttachments = [String: PendingAttachment]()
    private var retiringPorts = Set<Int>()
    private var stopped = false

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
            let family = try Self.supportedFamily(candidate)
            let capability = try DoryIOUSBHostTransferCapability.capture(
                expectedIdentityToken: identity,
                speed: Self.portSpeed(candidate.descriptor.speed),
                requireUnmountedStorage: family == .storage,
                serviceAllowed: { service in
                    guard let current = HostUsbDiscovery.candidate(ioService: service) else {
                        return false
                    }
                    return Self.hasSameAdmittedConfiguration(selected: candidate, current: current)
                }
            )
            do {
                return try broker.acquire(
                    machineID: machineID,
                    identityToken: identity,
                    family: family,
                    admission: .init(
                        userSelected: true,
                        hostStorageUnmounted: candidate.hostStorageUnmounted
                    ),
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
            guard !stopped else {
                throw UsbControlError.managerStoppedDuringTransition("controller-reset")
            }
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
        // Reserve admission under the lifecycle lock, but do not hold it across discovery or
        // capture. Stop must revoke an in-flight capture before that platform call returns.
        let reservation = try lock.withLock { () -> PendingAttachment in
            guard !stopped else {
                throw UsbControlError.managerStoppedDuringTransition(busID)
            }
            guard attachments[busID] == nil else {
                throw UsbControlError.alreadyAttached(busID)
            }
            guard pendingAttachments[busID] == nil else {
                throw UsbControlError.transitionInProgress(busID: busID, operation: "attaching")
            }
            guard let port = (2...DoryPCXHCIController.portCount).first(where: { candidate in
                !attachments.values.contains(where: { $0.port == candidate })
                    && !pendingAttachments.values.contains(where: { $0.port == candidate })
                    && !retiringPorts.contains(candidate)
            }) else {
                throw UsbControlError.mutationRejected(
                    operation: .attach,
                    busID: busID,
                    detail: "all DoryPC xHCI passthrough ports are occupied"
                )
            }
            let reservation = PendingAttachment(port: port)
            pendingAttachments[busID] = reservation
            return reservation
        }
        defer {
            lock.withLock {
                if pendingAttachments[busID] == reservation {
                    pendingAttachments.removeValue(forKey: busID)
                }
            }
        }
        let port = reservation.port
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
            // A physical capture claims every interface, not just the first supported one.
            // Check the complete class composition before the opener touches IOKit.
            _ = try Self.supportedFamily(candidate)
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
            // A discovery callback may itself outlive stop. Avoid invoking the privileged
            // opener at all if that earlier stage has already lost admission.
            try lock.withLock {
                guard !stopped, pendingAttachments[busID] == reservation else {
                    throw UsbControlError.managerStoppedDuringTransition(busID)
                }
            }
            let lease = try openLease(candidate, expectedIdentity)
            let deviceID = (descriptor.busNumber << 16) | descriptor.deviceNumber
            let admitted: DoryUSBControlV1.Attachment
            do {
                let wireAttachment = try DoryUSBControlV1.Attachment(
                    port: port,
                    vsockPort: DoryUSBControlV1.usbipVsockPort,
                    deviceID: deviceID,
                    speed: descriptor.speed
                )
                try lock.withLock {
                    guard !stopped, pendingAttachments[busID] == reservation else {
                        throw UsbControlError.managerStoppedDuringTransition(busID)
                    }
                    guard lease.isActive else {
                        throw UsbControlError.mutationRejected(
                            operation: .attach, busID: busID, detail: "host USB lease was revoked during capture"
                        )
                    }
                    try controller.connect(port: port, device: lease)
                    attachments[busID] = Attachment(port: port, lease: lease)
                    pendingAttachments.removeValue(forKey: busID)
                }
                admitted = wireAttachment
            } catch {
                lease.setRevocationHandler(nil)
                lease.release()
                throw error
            }
        lease.setRevocationHandler { [weak self, weak lease] in
            guard let lease else { return }
            self?.leaseRevoked(busID: busID, leaseID: lease.leaseID)
        }
        let stillAttached = lock.withLock {
            !stopped && attachments[busID]?.lease.leaseID == lease.leaseID && lease.isActive
        }
        guard stillAttached else {
            lease.setRevocationHandler(nil)
            lease.release()
            throw UsbControlError.mutationRejected(
                operation: .attach, busID: busID, detail: "host USB lease was revoked before attachment completed"
            )
        }
        return admitted
    }

    func detach(busID: String) async throws {
        let detached = try lock.withLock { () -> (DoryPCXHCIController, Attachment) in
            guard let attachment = attachments.removeValue(forKey: busID) else {
                throw UsbControlError.notAttached(busID)
            }
            attachment.lease.setRevocationHandler(nil)
            retiringPorts.insert(attachment.port)
            return (controller, attachment)
        }
        defer { lock.withLock { _ = retiringPorts.remove(detached.1.port) } }
        do {
            try detached.0.disconnect(port: detached.1.port)
        } catch {
            detached.1.lease.release()
            throw UsbControlError.outcomeUnknown(
                operation: .detach,
                busID: busID,
                detail: "host lease revocation began but xHCI disconnect failed: \(error)"
            )
        }
        detached.1.lease.release()
        guard detached.1.lease.waitForRetirement(timeout: 1) else {
            throw UsbControlError.outcomeUnknown(
                operation: .detach,
                busID: busID,
                detail: "guest port disconnected, but an in-flight host USB operation still holds the physical lease"
            )
        }
    }

    func stop() {
        let retired = lock.withLock { () -> (DoryPCXHCIController, [Attachment]) in
            stopped = true
            pendingAttachments.removeAll()
            let result = attachments.values.sorted(by: { $0.port < $1.port })
            attachments.removeAll()
            result.forEach { $0.lease.setRevocationHandler(nil) }
            retiringPorts.formUnion(result.map(\.port))
            return (controller, result)
        }
        for attachment in retired.1 {
            try? retired.0.disconnect(port: attachment.port)
            attachment.lease.release()
            lock.withLock { _ = retiringPorts.remove(attachment.port) }
        }
    }

    private func leaseRevoked(busID: String, leaseID: UUID) {
        let detached = lock.withLock { () -> (DoryPCXHCIController, Attachment)? in
            guard let attachment = attachments[busID], attachment.lease.leaseID == leaseID else {
                return nil
            }
            attachments.removeValue(forKey: busID)
            retiringPorts.insert(attachment.port)
            return (controller, attachment)
        }
        if let detached {
            try? detached.0.disconnect(port: detached.1.port)
            lock.withLock { _ = retiringPorts.remove(detached.1.port) }
        }
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

    /// The selected stable token does not include USB class, configuration or interface layout.
    /// Reset/reopen must preserve all of them before the host grants capture authority again.
    static func hasSameAdmittedConfiguration(
        selected: HostUsbDeviceCandidate,
        current: HostUsbDeviceCandidate
    ) -> Bool {
        guard let selectedFamily = try? supportedFamily(selected),
              let currentFamily = try? supportedFamily(current),
              selectedFamily == currentFamily,
              current.captureDecision.allowed,
              current.identityToken != nil,
              current.identityToken == selected.identityToken,
              current.descriptor.deviceClass == selected.descriptor.deviceClass,
              current.descriptor.deviceSubClass == selected.descriptor.deviceSubClass,
              current.descriptor.deviceProtocol == selected.descriptor.deviceProtocol,
              current.descriptor.configurationValue == selected.descriptor.configurationValue,
              current.descriptor.configurationCount == selected.descriptor.configurationCount,
              current.descriptor.interfaceCount == selected.descriptor.interfaceCount,
              current.descriptor.speed == selected.descriptor.speed,
              current.interfaces == selected.interfaces else { return false }
        return true
    }

    /// PC physical passthrough admission table. Storage and CDC serial use the implemented
    /// control/bulk/interrupt path. HID, UVC, audio, smart cards and vendor-specific devices
    /// remain unavailable until their endpoint behavior and revocation are qualified.
    private static func supportedFamily(
        _ candidate: HostUsbDeviceCandidate
    ) throws -> DoryHostUSBDeviceFamily {
        let descriptor = candidate.descriptor
        func reject(_ detail: String) -> UsbControlError {
            .mutationRejected(operation: .attach, busID: descriptor.busID, detail: detail)
        }
        let interfaces = candidate.interfaces
        guard !interfaces.isEmpty,
              interfaces.count == Int(descriptor.interfaceCount),
              Set(interfaces.map(\.number)).count == interfaces.count else {
            throw reject("complete USB interface identities are required before physical capture")
        }
        let classes = Set(interfaces.map(\.interfaceClass))
        let deviceClass = descriptor.deviceClass
        if classes == [0x08], [0x00, 0x08].contains(deviceClass) {
            return .storage
        }
        if classes.isSubset(of: [0x02, 0x0a]), classes.contains(0x02),
           [0x00, 0x02, 0xef].contains(deviceClass) {
            return .serialAdapter
        }
        throw reject("USB class composition is not supported for PC physical passthrough (storage and CDC serial only; mixed, HID, camera, audio and vendor-specific devices are unavailable)")
    }

    deinit { stop() }
}
