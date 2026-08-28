import DoryVMContracts
import Foundation

public enum UsbipManagerError: Error, Equatable, Sendable {
    case duplicateBusID(String)
    case deviceCapacityReached(limit: Int)
    case listenerAlreadyAttached
    case invalidControlMutationLease
    case controlMutationBusIDMismatch(expected: String, actual: String)
    case claimLeaseMismatch(String)
    case claimNotRegistered(String)
    case stopped
}

/// Result of crossing the VM-owner's terminal guest-execution boundary. Once the guest can no
/// longer execute, an uncertain vhci result no longer requires a guest detach RPC: destroying the
/// VM has established the detached guest state. If a host-side mutation is still admitted, the
/// manager retains itself and every claim until that mutation drains and terminal retirement runs.
public enum UsbipManagerGuestTerminationOutcome: Equatable, Sendable {
    case completed
    case authorityRetained(retainedClaimBusIDs: [String])
}

/// Exact authority for one host-device/guest-agent mutation. It binds the operation and bus ID as
/// well as the manager generation, so a lease can neither mutate another physical claim nor turn a
/// post-stop detach reconciliation into a new attach admission.
struct UsbipManagerControlMutationLease: Sendable, Equatable {
    fileprivate let id: UUID
    fileprivate let operation: DoryUSBControlV1.Operation
    fileprivate let busID: String
    fileprivate let authority: Authority

    fileprivate enum Authority: Sendable, Equatable {
        case active(lifecycleGeneration: UUID, claimGeneration: UUID?)
        case reconciliation(claimGeneration: UUID)
    }
}

/// Owns one guest-initiated USB/IP listener, every admitted bridge, and every claimed host device.
/// Listener registration is one-shot: replacing it in place would make teardown generation-unsafe.
public final class UsbipManager: @unchecked Sendable {
    private enum ListenerState {
        case idle
        case attaching
        case attached(VirtioVsockListenerRegistration)
        case stopped
    }

    private enum ControlLifecycle {
        case active
        /// New mutations are closed while stop waits every mutation admitted by the prior epoch.
        case quiescing
        /// The data path is stopped. Only detach reconciliation for an explicitly uncertain claim
        /// may be admitted.
        case quiesced
    }

    private enum ClaimDisposition: Equatable {
        case provisional(attachMutationID: UUID)
        case stable
        case uncertain
    }

    private struct DeviceRecord {
        let device: any UsbipExportedDevice
        let generation: UUID
        var disposition: ClaimDisposition
    }

    private enum BridgeAuthorization {
        case awaitingImport
        case imported(busID: String, deviceGeneration: UUID)
        case invalidated
    }

    private struct BridgeRecord {
        let snapshotGenerations: [String: UUID]
        let completion: DispatchGroup
        var bridge: UsbipBridge?
        var authorization: BridgeAuthorization
    }

    private struct DeviceRetirement {
        let busID: String
        let record: DeviceRecord
        let affectedBridges: [(bridge: UsbipBridge?, completion: DispatchGroup)]
    }

    private let lock = NSLock()
    private let stopLock = NSLock()
    private let listenerAttachmentCompletion = DispatchGroup()
    private let controlMutationCompletion = DispatchGroup()
    private let bridgeCompletion = DispatchGroup()
    private let deviceShutdownCompletion = DispatchGroup()
    private let deviceShutdownQueue = DispatchQueue(
        label: "dory.usbip.device-shutdown",
        attributes: .concurrent
    )
    private let terminalRetirementQueue = DispatchQueue(
        label: "dory.usbip.terminal-retirement",
        qos: .userInitiated
    )
    private var devices: [String: DeviceRecord] = [:]
    private var bridgeRecords: [UUID: BridgeRecord] = [:]
    private var controlMutationLeases: [UUID: UsbipManagerControlMutationLease] = [:]
    private var lifecycleGeneration = UUID()
    private var listenerState: ListenerState = .idle
    private var controlLifecycle: ControlLifecycle = .active
    private var guestExecutionEnded = false
    private var terminalRetirementScheduled = false
    private let vsockPort: UInt32
    private let maxActiveConnections: Int
    private let maxClaimedDevices: Int
    private let stopWaitLimit: TimeInterval
    private let log: @Sendable (String) -> Void
    private var rejectedConnections: UInt64 = 0

    public init(
        vsockPort: UInt32 = VsockPorts.usbip,
        maxActiveConnections: Int = 8,
        maxClaimedDevices: Int = 32,
        stopWaitLimit: TimeInterval = 5,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        precondition((1...64).contains(maxActiveConnections))
        precondition((1...256).contains(maxClaimedDevices))
        precondition(stopWaitLimit.isFinite && stopWaitLimit > 0 && stopWaitLimit <= 30)
        self.vsockPort = vsockPort
        self.maxActiveConnections = maxActiveConnections
        self.maxClaimedDevices = maxClaimedDevices
        self.stopWaitLimit = stopWaitLimit
        self.log = log
    }

    public var port: UInt32 { vsockPort }

    /// Registers exactly one listener generation. The retained token is closed by `stop`/deinit;
    /// a duplicate call never replaces the active handler. The in-progress registration is itself
    /// tracked so stop cannot return while a newly created token is still able to publish.
    public func attachListener(to vsock: VirtioVsock) throws {
        lock.lock()
        switch listenerState {
        case .idle:
            listenerState = .attaching
            listenerAttachmentCompletion.enter()
        case .attaching, .attached:
            lock.unlock()
            throw UsbipManagerError.listenerAlreadyAttached
        case .stopped:
            lock.unlock()
            throw UsbipManagerError.stopped
        }
        lock.unlock()
        defer { listenerAttachmentCompletion.leave() }

        let registration: VirtioVsockListenerRegistration
        do {
            registration = try vsock.registerServiceListener(
                port: vsockPort,
                service: .usbip
            ) { [weak self] connection in
                guard let self else {
                    connection.close()
                    return
                }
                self.accept(connection)
            }
        } catch {
            lock.lock()
            if case .attaching = listenerState { listenerState = .idle }
            lock.unlock()
            throw error
        }

        lock.lock()
        guard case .attaching = listenerState else {
            let stopped: Bool
            if case .stopped = listenerState { stopped = true } else { stopped = false }
            lock.unlock()
            registration.close()
            throw stopped ? UsbipManagerError.stopped : UsbipManagerError.listenerAlreadyAttached
        }
        listenerState = .attached(registration)
        lock.unlock()
    }

    /// Publishes the physical claim acquired by one exact attach mutation. Every rejection closes
    /// the passed device, including stale/cross-bus authority, so a caller cannot accidentally leak
    /// a host claim after the manager refuses ownership.
    func register(
        _ device: any UsbipExportedDevice,
        under lease: UsbipManagerControlMutationLease
    ) throws {
        let busID = device.descriptor.busID
        let rejection: UsbipManagerError?
        lock.lock()
        if controlMutationLeases[lease.id] != lease || !controlMutationIsCurrentLocked(lease) {
            rejection = .invalidControlMutationLease
        } else if lease.operation != .attach {
            rejection = .claimLeaseMismatch(lease.busID)
        } else if lease.busID != busID {
            rejection = .controlMutationBusIDMismatch(expected: lease.busID, actual: busID)
        } else if case .stopped = listenerState {
            rejection = .stopped
        } else if devices[busID] != nil {
            rejection = .duplicateBusID(busID)
        } else if devices.count >= maxClaimedDevices {
            rejection = .deviceCapacityReached(limit: maxClaimedDevices)
        } else {
            devices[busID] = DeviceRecord(
                device: device,
                generation: UUID(),
                disposition: .provisional(attachMutationID: lease.id)
            )
            rejection = nil
        }
        lock.unlock()
        if let rejection {
            device.shutdown()
            throw rejection
        }
    }

    /// Removes only the claim generation authorized by this exact attach-compensation or detach
    /// lease. The bus ID comes from the sealed lease, preventing cross-bus cleanup.
    @discardableResult
    func unregisterClaim(
        under lease: UsbipManagerControlMutationLease
    ) throws -> (any UsbipExportedDevice) {
        let retirement: DeviceRetirement
        lock.lock()
        do {
            try validateClaimAuthorityLocked(lease)
            guard let current = devices[lease.busID] else {
                throw UsbipManagerError.claimNotRegistered(lease.busID)
            }
            try validateClaimGenerationLocked(current, for: lease)
            retirement = removeDeviceLocked(busID: lease.busID, expectedGeneration: current.generation)
        } catch {
            lock.unlock()
            throw error
        }
        lock.unlock()
        retireSynchronously(retirement)
        return retirement.record.device
    }

    /// Marks a still-owned claim as outcome-unknown before the handler publishes that uncertainty.
    /// Stop preserves these exact claim generations and only a later detach lease may retire them.
    func preserveClaimForReconciliation(
        under lease: UsbipManagerControlMutationLease
    ) throws {
        lock.lock(); defer { lock.unlock() }
        try validateClaimAuthorityLocked(lease)
        guard var current = devices[lease.busID] else {
            throw UsbipManagerError.claimNotRegistered(lease.busID)
        }
        try validateClaimGenerationLocked(current, for: lease)
        current.disposition = .uncertain
        devices[lease.busID] = current
    }

    func exportedDevice(busID: String) -> (any UsbipExportedDevice)? {
        lock.lock(); defer { lock.unlock() }
        return devices[busID]?.device
    }

    func exportedDevices() -> [any UsbipExportedDevice] {
        lock.lock(); defer { lock.unlock() }
        return devices.values.map(\.device)
    }

    var claimedBusIDs: [String] {
        lock.lock(); defer { lock.unlock() }
        return devices.keys.sorted()
    }

    var activeConnectionCount: Int {
        lock.lock(); defer { lock.unlock() }
        return bridgeRecords.count
    }

    var rejectedConnectionCount: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return rejectedConnections
    }

    var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        if case .stopped = listenerState { return true }
        return false
    }

    /// Admits an operation in the active epoch, or an exact detach reconciliation for an uncertain
    /// claim after data-path quiescence. A stopped manager never admits a new attach.
    func beginControlMutation(
        operation: DoryUSBControlV1.Operation,
        busID: String
    ) throws -> UsbipManagerControlMutationLease {
        lock.lock()
        guard !guestExecutionEnded else {
            lock.unlock()
            throw UsbipManagerError.stopped
        }
        let authority: UsbipManagerControlMutationLease.Authority
        switch controlLifecycle {
        case .active:
            authority = .active(
                lifecycleGeneration: lifecycleGeneration,
                claimGeneration: devices[busID]?.generation
            )
        case .quiescing:
            lock.unlock()
            throw UsbipManagerError.stopped
        case .quiesced:
            guard operation == .detach,
                  let record = devices[busID],
                  record.disposition == .uncertain else {
                lock.unlock()
                throw UsbipManagerError.stopped
            }
            authority = .reconciliation(claimGeneration: record.generation)
        }
        let lease = UsbipManagerControlMutationLease(
            id: UUID(),
            operation: operation,
            busID: busID,
            authority: authority
        )
        controlMutationLeases[lease.id] = lease
        controlMutationCompletion.enter()
        lock.unlock()
        return lease
    }

    func isControlMutationCurrent(_ lease: UsbipManagerControlMutationLease) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return controlMutationIsCurrentLocked(lease)
    }

    /// Linearizes an attach commit against stop and makes its claim provably stable in that same
    /// critical section. Stop can therefore distinguish commit-before-stop from an invalidated
    /// attach that still requires compensation.
    func withCurrentControlMutation<Result>(
        _ lease: UsbipManagerControlMutationLease,
        _ body: () -> Result
    ) -> Result? {
        lock.lock(); defer { lock.unlock() }
        guard controlMutationIsCurrentLocked(lease) else { return nil }
        let result = body()
        if lease.operation == .attach,
           var record = devices[lease.busID],
           record.disposition == .provisional(attachMutationID: lease.id) {
            record.disposition = .stable
            devices[lease.busID] = record
        }
        return result
    }

    func finishControlMutation(_ lease: UsbipManagerControlMutationLease) {
        lock.lock()
        let owned = controlMutationLeases.removeValue(forKey: lease.id) == lease
        // Fail closed if an attach exits without either committing, unregistering, or explicitly
        // publishing uncertainty. Retaining authority is safer than releasing a claim whose
        // guest-side outcome was never established.
        if owned,
           lease.operation == .attach,
           var record = devices[lease.busID],
           record.disposition == .provisional(attachMutationID: lease.id) {
            record.disposition = .uncertain
            devices[lease.busID] = record
        }
        lock.unlock()
        precondition(owned, "USB/IP control mutation lease finished more than once")
        controlMutationCompletion.leave()
    }

    /// Executes one serialized quiescence transaction. Admission closes and the active generation
    /// is invalidated before waiting admitted mutations. Only after they finish are stable claims
    /// retired; outcome-unknown claims remain registered and make the result false until an exact
    /// later detach reconciliation removes them.
    @discardableResult
    public func stop(timeout: TimeInterval? = nil) -> Bool {
        quiesce(timeout: timeout, retireAllClaimsAfterGuestTermination: false)
    }

    private func quiesce(
        timeout: TimeInterval?,
        retireAllClaimsAfterGuestTermination: Bool
    ) -> Bool {
        stopLock.lock()
        defer { stopLock.unlock() }
        let requested = timeout ?? stopWaitLimit
        let bounded = requested.isFinite ? min(max(0, requested), stopWaitLimit) : stopWaitLimit
        let deadline = ProcessInfo.processInfo.systemUptime + bounded
        let registration: VirtioVsockListenerRegistration?
        let activeBridges: [UsbipBridge]

        lock.lock()
        switch controlLifecycle {
        case .active:
            controlLifecycle = .quiescing
            lifecycleGeneration = UUID()
            if case .attached(let current) = listenerState { registration = current }
            else { registration = nil }
            listenerState = .stopped
            activeBridges = bridgeRecords.values.compactMap(\.bridge)
            for token in Array(bridgeRecords.keys) {
                bridgeRecords[token]?.authorization = .invalidated
            }
        case .quiescing:
            registration = nil
            activeBridges = bridgeRecords.values.compactMap(\.bridge)
            for token in Array(bridgeRecords.keys) {
                bridgeRecords[token]?.authorization = .invalidated
            }
        case .quiesced:
            // Temporarily close reconciliation admission so the mutation group has a stable epoch.
            controlLifecycle = .quiescing
            registration = nil
            activeBridges = bridgeRecords.values.compactMap(\.bridge)
            for token in Array(bridgeRecords.keys) {
                bridgeRecords[token]?.authorization = .invalidated
            }
        }
        lock.unlock()

        registration?.close()
        for bridge in activeBridges { bridge.requestStop() }

        let listenerDrained = wait(listenerAttachmentCompletion, until: deadline)
        let mutationsDrained = wait(controlMutationCompletion, until: deadline)
        let bridgesDrained = wait(bridgeCompletion, until: deadline)
        var safeRetirements: [DeviceRetirement] = []
        let unresolvedBusIDs: [String]
        lock.lock()
        if mutationsDrained {
            // A provisional record after the group drains is an internal invariant breach. Preserve
            // it as uncertain instead of silently releasing physical authority.
            for busID in Array(devices.keys) {
                guard var record = devices[busID] else { continue }
                if case .provisional = record.disposition {
                    record.disposition = .uncertain
                    devices[busID] = record
                }
            }
            let safeClaims = devices.compactMap { busID, record in
                if retireAllClaimsAfterGuestTermination || record.disposition == .stable {
                    return (busID, record.generation)
                }
                return nil
            }
            safeRetirements.reserveCapacity(safeClaims.count)
            for (busID, generation) in safeClaims {
                safeRetirements.append(
                    removeDeviceLocked(busID: busID, expectedGeneration: generation)
                )
            }
        }
        unresolvedBusIDs = devices.keys.sorted()
        controlLifecycle = .quiesced
        lock.unlock()

        let shutdownCompletion = deviceShutdownCompletion
        for retirement in safeRetirements {
            for affected in retirement.affectedBridges { affected.bridge?.requestStop() }
            deviceShutdownQueue.async {
                retirement.record.device.shutdown()
                shutdownCompletion.leave()
            }
        }
        let devicesDrained = wait(deviceShutdownCompletion, until: deadline)
        let drained = listenerDrained
            && mutationsDrained
            && bridgesDrained
            && devicesDrained
            && unresolvedBusIDs.isEmpty
        if !drained {
            if !unresolvedBusIDs.isEmpty {
                log("USB/IP quiescence retained outcome-unknown claims pending detach: \(unresolvedBusIDs.joined(separator: ", "))")
            } else {
                log("USB/IP teardown did not drain within \(bounded) seconds")
            }
        }
        return drained
    }

    /// Crosses the owner-proven boundary where the VM has either never started or `Machine.run()`
    /// has returned. Guest execution can no longer retain a vhci attachment, so outcome-unknown
    /// claims are now safe to retire without another guest RPC. A bounded initial quiescence keeps
    /// normal shutdown responsive. If an admitted host mutation or terminal drain outlives it, one
    /// self-retaining worker completes that exact retirement; releasing the external owner cannot
    /// release a physical claim underneath the mutation.
    public func stopAfterGuestExecutionEnded(
        timeout: TimeInterval? = nil
    ) -> UsbipManagerGuestTerminationOutcome {
        lock.lock()
        guestExecutionEnded = true
        lock.unlock()

        if quiesce(timeout: timeout, retireAllClaimsAfterGuestTermination: true) {
            return .completed
        }

        let retainedClaimBusIDs: [String]
        let scheduleRetirement: Bool
        lock.lock()
        retainedClaimBusIDs = devices.keys.sorted()
        if terminalRetirementScheduled {
            scheduleRetirement = false
        } else {
            terminalRetirementScheduled = true
            scheduleRetirement = true
        }
        lock.unlock()

        if scheduleRetirement {
            terminalRetirementQueue.async { [self] in
                completeTerminalRetirement()
            }
        }
        return .authorityRetained(retainedClaimBusIDs: retainedClaimBusIDs)
    }

    deinit {
        _ = stop()
    }

    private func accept(_ connection: VsockConnection) {
        let token = UUID()
        let exported: [any UsbipExportedDevice]
        lock.lock()
        guard case .attached = listenerState,
              bridgeRecords.count < maxActiveConnections else {
            incrementRejectedConnectionsLocked()
            lock.unlock()
            connection.close()
            return
        }
        guard !devices.isEmpty else {
            incrementRejectedConnectionsLocked()
            lock.unlock()
            connection.close()
            return
        }
        exported = devices.values.map(\.device)
        let snapshotGenerations = devices.mapValues(\.generation)
        let completion = DispatchGroup()
        completion.enter()
        bridgeCompletion.enter()
        bridgeRecords[token] = BridgeRecord(
            snapshotGenerations: snapshotGenerations,
            completion: completion,
            bridge: nil,
            authorization: .awaitingImport
        )
        lock.unlock()
        log("USB/IP guest connection accepted with \(exported.count) exported device(s)")

        let bridge = UsbipBridge(
            connection: connection,
            server: UsbipServer(devices: exported),
            authorizeImport: { [weak self] busID in
                self?.authorizeImport(busID: busID, bridgeToken: token) ?? false
            },
            log: log,
            onClose: { [weak self] in self?.bridgeFinished(token: token) }
        )

        lock.lock()
        let shouldStart: Bool
        if var record = bridgeRecords[token] {
            record.bridge = bridge
            bridgeRecords[token] = record
            if case .attached = listenerState,
               case .awaitingImport = record.authorization {
                shouldStart = true
            } else {
                shouldStart = false
            }
        } else {
            shouldStart = false
        }
        lock.unlock()

        if let ownedConnection = connection as? ServiceOwnedVsockConnection,
           !ownedConnection.replaceServiceStopAction({ bridge.requestStop() }) {
            bridge.requestStop()
        }

        if shouldStart {
            log("USB/IP bridge started")
            bridge.start()
        }
        else { bridge.requestStop() }
    }

    private func authorizeImport(busID: String, bridgeToken: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard case .attached = listenerState,
              var bridge = bridgeRecords[bridgeToken],
              case .awaitingImport = bridge.authorization,
              let expectedGeneration = bridge.snapshotGenerations[busID],
              devices[busID]?.generation == expectedGeneration,
              !bridgeRecords.contains(where: { token, record in
                  guard token != bridgeToken else { return false }
                  if case let .imported(importedBusID, importedGeneration) = record.authorization {
                      return importedBusID == busID
                          && importedGeneration == expectedGeneration
                  }
                  return false
              }) else {
            return false
        }
        bridge.authorization = .imported(
            busID: busID,
            deviceGeneration: expectedGeneration
        )
        bridgeRecords[bridgeToken] = bridge
        log("USB/IP import authorized for \(busID)")
        return true
    }

    private func bridgeFinished(token: UUID) {
        let completion: DispatchGroup?
        lock.lock()
        completion = bridgeRecords.removeValue(forKey: token)?.completion
        lock.unlock()
        guard let completion else { return }
        completion.leave()
        bridgeCompletion.leave()
    }

    private func controlMutationIsCurrentLocked(
        _ lease: UsbipManagerControlMutationLease
    ) -> Bool {
        guard controlMutationLeases[lease.id] == lease else { return false }
        switch lease.authority {
        case .active(let admittedGeneration, _):
            guard case .active = controlLifecycle else { return false }
            return lifecycleGeneration == admittedGeneration
        case .reconciliation(let claimGeneration):
            guard lease.operation == .detach,
                  let record = devices[lease.busID],
                  record.generation == claimGeneration,
                  record.disposition == .uncertain else { return false }
            switch controlLifecycle {
            case .active: return false
            case .quiescing, .quiesced: return true
            }
        }
    }

    private func validateClaimAuthorityLocked(
        _ lease: UsbipManagerControlMutationLease
    ) throws {
        guard controlMutationLeases[lease.id] == lease else {
            throw UsbipManagerError.invalidControlMutationLease
        }
    }

    private func validateClaimGenerationLocked(
        _ record: DeviceRecord,
        for lease: UsbipManagerControlMutationLease
    ) throws {
        switch lease.operation {
        case .attach:
            guard record.disposition == .provisional(attachMutationID: lease.id) else {
                throw UsbipManagerError.claimLeaseMismatch(lease.busID)
            }
        case .detach:
            let expectedGeneration: UUID?
            switch lease.authority {
            case .active(_, let claimGeneration): expectedGeneration = claimGeneration
            case .reconciliation(let claimGeneration): expectedGeneration = claimGeneration
            }
            guard expectedGeneration == record.generation else {
                throw UsbipManagerError.claimLeaseMismatch(lease.busID)
            }
            if case .provisional = record.disposition {
                throw UsbipManagerError.claimLeaseMismatch(lease.busID)
            }
        }
    }

    /// Removes the live registry generation while holding `lock`, invalidates every bridge whose
    /// immutable snapshot retained it, and transfers shutdown ownership to a retirement object.
    private func removeDeviceLocked(
        busID: String,
        expectedGeneration: UUID
    ) -> DeviceRetirement {
        guard let current = devices[busID], current.generation == expectedGeneration else {
            preconditionFailure("USB/IP claim generation changed during serialized retirement")
        }
        devices.removeValue(forKey: busID)
        deviceShutdownCompletion.enter()
        let affectedTokens = bridgeRecords.compactMap { token, bridge -> UUID? in
            switch bridge.authorization {
            case .awaitingImport:
                return bridge.snapshotGenerations[busID] == current.generation ? token : nil
            case let .imported(importedBusID, generation):
                return importedBusID == busID && generation == current.generation ? token : nil
            case .invalidated:
                return nil
            }
        }
        var affected: [(bridge: UsbipBridge?, completion: DispatchGroup)] = []
        affected.reserveCapacity(affectedTokens.count)
        for token in affectedTokens {
            guard var bridge = bridgeRecords[token] else { continue }
            bridge.authorization = .invalidated
            bridgeRecords[token] = bridge
            affected.append((bridge.bridge, bridge.completion))
        }
        return DeviceRetirement(
            busID: busID,
            record: current,
            affectedBridges: affected
        )
    }

    private func retireSynchronously(_ retirement: DeviceRetirement) {
        for affected in retirement.affectedBridges { affected.bridge?.requestStop() }
        // Keep the claim strongly held while terminal abort/drain runs. HostUsbDevice bounds this
        // wait and preserves late-completion object lifetime if the framework misses its deadline.
        retirement.record.device.shutdown()
        deviceShutdownCompletion.leave()
        let deadline = ProcessInfo.processInfo.systemUptime + stopWaitLimit
        let drained = retirement.affectedBridges.allSatisfy {
            wait($0.completion, until: deadline)
        }
        if !drained {
            log("USB/IP connections for \(retirement.busID) did not drain within \(stopWaitLimit) seconds")
        }
    }

    /// Runs only after the guest-execution boundary has permanently closed admission. This wait is
    /// intentionally not timed out: abandoning the worker would abandon physical claim authority.
    /// All production control RPCs and host requests have their own finite deadlines; an internal
    /// invariant failure therefore leaks authority fail-closed instead of releasing it unsafely.
    private func completeTerminalRetirement() {
        stopLock.lock()
        defer { stopLock.unlock() }

        listenerAttachmentCompletion.wait()
        controlMutationCompletion.wait()

        let retirements: [DeviceRetirement]
        let activeBridges: [UsbipBridge]
        lock.lock()
        precondition(guestExecutionEnded)
        activeBridges = bridgeRecords.values.compactMap(\.bridge)
        for token in Array(bridgeRecords.keys) {
            bridgeRecords[token]?.authorization = .invalidated
        }
        let liveClaimGenerations = devices.map { ($0.key, $0.value.generation) }
        retirements = liveClaimGenerations.map { busID, generation in
            removeDeviceLocked(busID: busID, expectedGeneration: generation)
        }
        controlLifecycle = .quiesced
        lock.unlock()

        for bridge in activeBridges { bridge.requestStop() }
        for retirement in retirements {
            retirement.record.device.shutdown()
            deviceShutdownCompletion.leave()
        }

        bridgeCompletion.wait()
        deviceShutdownCompletion.wait()
        log("USB/IP terminal guest boundary retired all host claim authority")
    }

    private func incrementRejectedConnectionsLocked() {
        if rejectedConnections < UInt64.max { rejectedConnections += 1 }
    }

    private func wait(_ group: DispatchGroup, until deadline: TimeInterval) -> Bool {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else {
            return group.wait(timeout: .now()) == .success
        }
        return group.wait(timeout: .now() + remaining) == .success
    }
}
