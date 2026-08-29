import Foundation
import SystemConfiguration

private final class CorporateConnectivityChangeCallbackBox: @unchecked Sendable {
    weak var owner: SystemCorporateConnectivityChangeMonitor?

    init(owner: SystemCorporateConnectivityChangeMonitor) {
        self.owner = owner
    }
}

public protocol CorporateConnectivitySystemChangeMonitoring: Sendable {
    func start(onChange: @escaping @Sendable () -> Void) throws
    func stop()
}

/// Event-driven observation of the macOS dynamic-store keys that change when Wi-Fi, a packet
/// tunnel, split DNS, PAC, or the default route changes. The reconciler keeps its timer as a
/// fallback; this monitor removes the normal polling delay from VPN recovery.
public final class SystemCorporateConnectivityChangeMonitor:
    CorporateConnectivitySystemChangeMonitoring, @unchecked Sendable
{
    private let callbackQueue: DispatchQueue
    private let lock = NSLock()
    private var store: SCDynamicStore?
    private var onChange: (@Sendable () -> Void)?
    private var activationID: UInt64 = 0

    public init(
        callbackQueue: DispatchQueue = DispatchQueue(
            label: "dev.dory.corporate-connectivity.dynamic-store"
        )
    ) {
        self.callbackQueue = callbackQueue
    }

    public func start(onChange: @escaping @Sendable () -> Void) throws {
        lock.lock()
        guard store == nil else {
            lock.unlock()
            return
        }
        activationID &+= 1
        let requestedActivationID = activationID
        self.onChange = onChange
        lock.unlock()

        let callbackBox = CorporateConnectivityChangeCallbackBox(owner: self)
        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(callbackBox).toOpaque(),
            retain: { info in
                _ = Unmanaged<CorporateConnectivityChangeCallbackBox>
                    .fromOpaque(info).retain()
                return info
            },
            release: { info in
                Unmanaged<CorporateConnectivityChangeCallbackBox>
                    .fromOpaque(info).release()
            },
            copyDescription: nil
        )
        guard let created = SCDynamicStoreCreate(
            nil,
            "dev.dory.corporate-connectivity" as CFString,
            { _, _, info in
                guard let info else { return }
                Unmanaged<CorporateConnectivityChangeCallbackBox>
                    .fromOpaque(info).takeUnretainedValue().owner?.notify()
            },
            &context
        ) else {
            clearCallback(activationID: requestedActivationID)
            throw CorporateConnectivityError.unavailable(
                "could not create the macOS network change monitor"
            )
        }
        let keys = [
            "State:/Network/Global/IPv4",
            "State:/Network/Global/IPv6",
            "State:/Network/Global/DNS",
            "State:/Network/Global/Proxies",
        ] as CFArray
        let patterns = [
            "State:/Network/Service/.*/DNS",
            "State:/Network/Service/.*/IPv4",
            "State:/Network/Service/.*/IPv6",
            "State:/Network/Interface/.*/IPv4",
            "State:/Network/Interface/.*/IPv6",
        ] as CFArray
        guard SCDynamicStoreSetNotificationKeys(created, keys, patterns),
              SCDynamicStoreSetDispatchQueue(created, callbackQueue) else {
            SCDynamicStoreSetDispatchQueue(created, nil)
            clearCallback(activationID: requestedActivationID)
            throw CorporateConnectivityError.unavailable(
                "could not subscribe to macOS network changes: "
                    + String(cString: SCErrorString(SCError()))
            )
        }

        lock.lock()
        if store == nil,
           activationID == requestedActivationID,
           self.onChange != nil {
            store = created
            lock.unlock()
        } else {
            lock.unlock()
            SCDynamicStoreSetDispatchQueue(created, nil)
        }
    }

    public func stop() {
        lock.lock()
        let current = store
        store = nil
        onChange = nil
        activationID &+= 1
        lock.unlock()
        if let current {
            SCDynamicStoreSetDispatchQueue(current, nil)
        }
    }

    private func notify() {
        lock.lock()
        let callback = onChange
        let active = store != nil
        lock.unlock()
        if active { callback?() }
    }

    private func clearCallback(activationID expected: UInt64) {
        lock.lock()
        if activationID == expected {
            onChange = nil
        }
        lock.unlock()
    }

    deinit { stop() }
}
