import DoryVMContracts
import Foundation

public struct UsbAgentAttachRequest: Equatable, Sendable {
    public var busid: String
    public var port: Int
    public var vsock_port: UInt32
    public var device_id: UInt32
    public var speed: UInt32
}

public struct UsbAgentDetachRequest: Equatable, Sendable {
    public var busid: String
    public var port: Int
}

public enum UsbControlError: Error, Equatable, Sendable, CustomStringConvertible {
    case alreadyAttached(String)
    case notAttached(String)
    case transitionInProgress(busID: String, operation: String)
    case invalidBusID(String)
    case deviceIdentityMismatch(expected: String, actual: String)
    case invalidDeviceIdentity(busID: String, busNumber: UInt32, deviceNumber: UInt32)
    case invalidAttachmentMetadata(busID: String, vsockPort: UInt32, deviceID: UInt32, speed: UInt32)
    case openModeNotAllowed(HostUsbOpenMode)
    case managerStoppedDuringTransition(String)
    case mutationRejected(operation: DoryUSBControlV1.Operation, busID: String, detail: String)
    case outcomeUnknown(operation: DoryUSBControlV1.Operation, busID: String, detail: String)
    case guestAgentRPCUnavailable

    public var failureDisposition: DoryUSBControlV1.FailureDisposition {
        if case .outcomeUnknown = self { return .outcomeUnknown }
        return .rejected
    }

    public var description: String {
        switch self {
        case .alreadyAttached(let busID):
            return "USB device is already attached: \(busID)"
        case .notAttached(let busID):
            return "USB device is not attached: \(busID)"
        case let .transitionInProgress(busID, operation):
            return "USB device \(busID) is already \(operation)"
        case .invalidBusID(let busID):
            return "USB bus ID is not canonical: \(busID)"
        case let .deviceIdentityMismatch(expected, actual):
            return "USB device identity changed while opening (expected \(expected), got \(actual))"
        case let .invalidDeviceIdentity(busID, busNumber, deviceNumber):
            return "USB device \(busID) has an invalid USB/IP identity \(busNumber):\(deviceNumber)"
        case let .invalidAttachmentMetadata(busID, vsockPort, deviceID, speed):
            return "USB device \(busID) has invalid attachment metadata (vsock port \(vsockPort), device ID \(deviceID), speed \(speed))"
        case .openModeNotAllowed(let mode):
            return "USB open mode is not authorized by the engine policy: \(mode)"
        case .managerStoppedDuringTransition(let busID):
            return "USB manager stopped during the \(busID) transition; the operation was rolled back"
        case let .mutationRejected(operation, busID, detail):
            return "USB \(operation.rawValue) was rejected for \(busID): \(detail)"
        case let .outcomeUnknown(operation, busID, detail):
            return "USB \(operation.rawValue) outcome is unknown for \(busID): \(detail)"
        case .guestAgentRPCUnavailable:
            return "USB attach/detach is unavailable: the guest does not expose usb-vhci@1"
        }
    }
}

/// The engine-side logic behind `dory usb attach/detach`: claim the host device, register it with the
/// `UsbipManager` so the listener can serve it, and tell the guest agent to dial and vhci-attach. All
/// three collaborators are injected so the full sequence (including rollback when the guest notify
/// fails) is unit-testable without real hardware, a socket, or a running guest.
public final class UsbControlHandler: @unchecked Sendable {
    private let manager: UsbipManager
    private let allowedOpenModes: Set<HostUsbOpenMode>
    private let ensureSupported: () async throws -> Void
    private let openDevice: (String, HostUsbOpenMode) throws -> any UsbipExportedDevice
    private let notifyAttach: (UsbAgentAttachRequest) async throws -> Void
    private let notifyDetach: (UsbAgentDetachRequest) async throws -> Void

    private let lock = NSLock()
    private enum AttachmentState: Equatable {
        case attaching(port: Int)
        case attached(port: Int)
        /// The host claim and USB/IP registration are deliberately retained because guest attach
        /// may have committed and its compensating detach did not establish a terminal state.
        case uncertain(port: Int)
        case detaching(port: Int, priorWasUncertain: Bool)

        var port: Int {
            switch self {
            case .attaching(let port), .attached(let port), .uncertain(let port):
                return port
            case .detaching(let port, _): return port
            }
        }

        var operation: String {
            switch self {
            case .attaching: return "attaching"
            case .attached: return "attached"
            case .uncertain: return "in an uncertain attach state"
            case .detaching: return "detaching"
            }
        }
    }

    private var attachmentByBusID: [String: AttachmentState] = [:]
    private var usedPorts = Set<Int>()

    public init(
        manager: UsbipManager,
        allowedOpenModes: Set<HostUsbOpenMode> = [.userAuthorized],
        ensureSupported: @escaping () async throws -> Void = {},
        openDevice: @escaping (String, HostUsbOpenMode) throws -> any UsbipExportedDevice,
        notifyAttach: @escaping (UsbAgentAttachRequest) async throws -> Void,
        notifyDetach: @escaping (UsbAgentDetachRequest) async throws -> Void
    ) {
        self.manager = manager
        self.allowedOpenModes = allowedOpenModes
        self.ensureSupported = ensureSupported
        self.openDevice = openDevice
        self.notifyAttach = notifyAttach
        self.notifyDetach = notifyDetach
    }

    public func attach(
        busID: String,
        mode: HostUsbOpenMode = .userAuthorized
    ) async throws -> DoryUSBControlV1.Attachment {
        // Capability is checked before opening or claiming the host device. A missing guest RPC must
        // fail closed; briefly seizing hardware and rolling back is still an observable disruption.
        guard DoryUSBControlV1.BusID.isValid(busID) else {
            throw UsbControlError.invalidBusID(busID)
        }
        guard allowedOpenModes.contains(mode) else {
            throw UsbControlError.openModeNotAllowed(mode)
        }
        let mutation = try manager.beginControlMutation(operation: .attach, busID: busID)
        defer { manager.finishControlMutation(mutation) }
        // Capability negotiation is also an admitted, potentially uncancellable RPC. Keep it under
        // the manager generation lease so stop cannot report a clean drain while it is still running.
        try await ensureSupported()
        guard manager.isControlMutationCurrent(mutation) else {
            throw UsbControlError.managerStoppedDuringTransition(busID)
        }
        let port = try lock.withLock { () -> Int in
            guard let current = attachmentByBusID[busID] else {
                let port = allocatePortLocked()
                attachmentByBusID[busID] = .attaching(port: port)
                return port
            }
            switch current {
            case .attached:
                throw UsbControlError.alreadyAttached(busID)
            case .uncertain:
                throw UsbControlError.outcomeUnknown(
                    operation: .attach,
                    busID: busID,
                    detail: "a prior attach may have committed; detach it before attaching again"
                )
            case .attaching, .detaching:
                throw UsbControlError.transitionInProgress(
                    busID: busID,
                    operation: current.operation
                )
            }
        }
        let device: any UsbipExportedDevice
        do {
            device = try openDevice(busID, mode)
        } catch {
            lock.withLock { rollbackLocked(busID, expected: .attaching(port: port)) }
            throw error
        }
        let descriptor = device.descriptor
        guard descriptor.busID == busID else {
            device.shutdown()
            lock.withLock { rollbackLocked(busID, expected: .attaching(port: port)) }
            throw UsbControlError.deviceIdentityMismatch(
                expected: busID,
                actual: descriptor.busID
            )
        }
        guard descriptor.busNumber <= UInt32(UInt16.max),
              descriptor.deviceNumber > 0,
              descriptor.deviceNumber <= UInt32(UInt16.max) else {
            device.shutdown()
            lock.withLock { rollbackLocked(busID, expected: .attaching(port: port)) }
            throw UsbControlError.invalidDeviceIdentity(
                busID: busID,
                busNumber: descriptor.busNumber,
                deviceNumber: descriptor.deviceNumber
            )
        }
        let deviceID = (descriptor.busNumber << 16) | descriptor.deviceNumber
        let attachment: DoryUSBControlV1.Attachment
        do {
            attachment = try DoryUSBControlV1.Attachment(
                port: port,
                vsockPort: manager.port,
                deviceID: deviceID,
                speed: descriptor.speed
            )
        } catch {
            device.shutdown()
            lock.withLock { rollbackLocked(busID, expected: .attaching(port: port)) }
            throw UsbControlError.invalidAttachmentMetadata(
                busID: busID,
                vsockPort: manager.port,
                deviceID: deviceID,
                speed: descriptor.speed
            )
        }
        do {
            try manager.register(device, under: mutation)
        } catch {
            lock.withLock { rollbackLocked(busID, expected: .attaching(port: port)) }
            throw error
        }
        let request = UsbAgentAttachRequest(
            busid: busID,
            port: port,
            vsock_port: attachment.vsockPort,
            device_id: attachment.deviceID,
            speed: attachment.speed
        )
        guard manager.isControlMutationCurrent(mutation) else {
            _ = try manager.unregisterClaim(under: mutation)
            lock.withLock { rollbackLocked(busID, expected: .attaching(port: port)) }
            throw UsbControlError.managerStoppedDuringTransition(busID)
        }
        do {
            try await notifyAttach(request)
        } catch {
            try await compensateAttachUncertainty(
                busID: busID,
                port: port,
                mutation: mutation,
                rejectionDetail: "guest attach RPC failed: \(error)"
            )
        }
        let committed = manager.withCurrentControlMutation(mutation) {
            lock.withLock {
                guard case .attaching(let currentPort) = attachmentByBusID[busID],
                      currentPort == port else {
                    preconditionFailure("USB attach state changed without owning the transition")
                }
                attachmentByBusID[busID] = .attached(port: port)
            }
            return true
        } ?? false
        guard committed else {
            try await compensateAttachUncertainty(
                busID: busID,
                port: port,
                mutation: mutation,
                rejectionDetail: "manager stopped after the guest attach RPC committed"
            )
        }
        return attachment
    }

    public func detach(busID: String) async throws {
        guard DoryUSBControlV1.BusID.isValid(busID) else {
            throw UsbControlError.invalidBusID(busID)
        }
        let mutation = try manager.beginControlMutation(operation: .detach, busID: busID)
        defer { manager.finishControlMutation(mutation) }
        try await ensureSupported()
        guard manager.isControlMutationCurrent(mutation) else {
            throw UsbControlError.managerStoppedDuringTransition(busID)
        }
        let transition = try lock.withLock { () -> (port: Int, priorWasUncertain: Bool) in
            guard let state = attachmentByBusID[busID] else {
                throw UsbControlError.notAttached(busID)
            }
            let port: Int
            let priorWasUncertain: Bool
            switch state {
            case .attached(let currentPort):
                port = currentPort
                priorWasUncertain = false
            case .uncertain(let currentPort):
                port = currentPort
                priorWasUncertain = true
            case .attaching, .detaching:
                throw UsbControlError.transitionInProgress(
                    busID: busID,
                    operation: state.operation
                )
            }
            attachmentByBusID[busID] = .detaching(
                port: port,
                priorWasUncertain: priorWasUncertain
            )
            return (port, priorWasUncertain)
        }
        let port = transition.port
        guard manager.isControlMutationCurrent(mutation) else {
            lock.withLock {
                restoreAfterFailedDetachLocked(
                    busID,
                    port: port,
                    priorWasUncertain: transition.priorWasUncertain
                )
            }
            throw UsbControlError.managerStoppedDuringTransition(busID)
        }
        do {
            try await notifyDetach(UsbAgentDetachRequest(busid: busID, port: port))
        } catch {
            // A failed RPC does not prove whether vhci-detach committed. Retaining both the host
            // claim and the prior certainty lets an explicit later detach safely reconcile it.
            lock.withLock {
                restoreAfterFailedDetachLocked(
                    busID,
                    port: port,
                    priorWasUncertain: transition.priorWasUncertain
                )
            }
            let retentionDetail: String
            do {
                try manager.preserveClaimForReconciliation(under: mutation)
                retentionDetail = ""
            } catch {
                retentionDetail = "; preserving the host claim failed: \(error)"
            }
            throw UsbControlError.outcomeUnknown(
                operation: .detach,
                busID: busID,
                detail: "guest detach RPC failed: \(error)\(retentionDetail)"
            )
        }
        _ = try manager.unregisterClaim(under: mutation)
        lock.withLock {
            rollbackLocked(
                busID,
                expected: .detaching(
                    port: port,
                    priorWasUncertain: transition.priorWasUncertain
                )
            )
        }
    }

    public var attachedBusIDs: [String] {
        lock.withLock {
            attachmentByBusID.compactMap { busID, state in
                switch state {
                case .attached, .uncertain: return busID
                case .attaching, .detaching: return nil
                }
            }.sorted()
        }
    }

    public var uncertainBusIDs: [String] {
        lock.withLock {
            attachmentByBusID.compactMap { busID, state in
                if case .uncertain = state { return busID }
                return nil
            }.sorted()
        }
    }

    private func compensateAttachUncertainty(
        busID: String,
        port: Int,
        mutation: UsbipManagerControlMutationLease,
        rejectionDetail: String
    ) async throws -> Never {
        do {
            try await notifyDetach(UsbAgentDetachRequest(busid: busID, port: port))
        } catch {
            let retentionDetail: String
            do {
                try manager.preserveClaimForReconciliation(under: mutation)
                retentionDetail = ""
            } catch {
                retentionDetail = "; preserving the host claim failed: \(error)"
            }
            lock.withLock {
                guard attachmentByBusID[busID] == .attaching(port: port) else {
                    preconditionFailure("USB attach compensation lost transition ownership")
                }
                attachmentByBusID[busID] = .uncertain(port: port)
            }
            throw UsbControlError.outcomeUnknown(
                operation: .attach,
                busID: busID,
                detail: "\(rejectionDetail); guest detach compensation failed: \(error)\(retentionDetail)"
            )
        }
        // Only a successful guest detach establishes the pre-attach state. Release the host claim
        // afterwards; reversing this order would make an uncertain guest attachment unrecoverable.
        _ = try manager.unregisterClaim(under: mutation)
        lock.withLock { rollbackLocked(busID, expected: .attaching(port: port)) }
        throw UsbControlError.mutationRejected(
            operation: .attach,
            busID: busID,
            detail: rejectionDetail
        )
    }

    private func restoreAfterFailedDetachLocked(
        _ busID: String,
        port: Int,
        priorWasUncertain: Bool
    ) {
        let expected = AttachmentState.detaching(
            port: port,
            priorWasUncertain: priorWasUncertain
        )
        guard attachmentByBusID[busID] == expected else {
            preconditionFailure("USB detach rollback lost transition ownership")
        }
        attachmentByBusID[busID] = priorWasUncertain
            ? .uncertain(port: port)
            : .attached(port: port)
    }

    private func allocatePortLocked() -> Int {
        var port = 0
        while usedPorts.contains(port) { port += 1 }
        usedPorts.insert(port)
        return port
    }

    private func rollbackLocked(_ busID: String, expected: AttachmentState) {
        guard attachmentByBusID[busID] == expected else {
            preconditionFailure("USB transition rollback lost ownership")
        }
        attachmentByBusID.removeValue(forKey: busID)
        usedPorts.remove(expected.port)
    }
}

private extension NSLock {
    func withLock<R>(_ body: () throws -> R) rethrows -> R {
        lock(); defer { unlock() }
        return try body()
    }
}
