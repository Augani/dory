import DoryCore
import Foundation

public final class SourcePreservingLANPrivilegedDaemon: NSObject, NSXPCListenerDelegate {
    private let controller: SourcePreservingLANPrivilegedController
    private let listener: NSXPCListener

    public init(
        controller: SourcePreservingLANPrivilegedController = SourcePreservingLANPrivilegedController()
    ) {
        self.controller = controller
        self.listener = NSXPCListener(machServiceName: DoryPrivilegedNetworkXPC.serviceName)
        super.init()
        self.listener.delegate = self
    }

    public func run() -> Never {
        do {
            try controller.clearStaleAnchor()
            try NetworkingAuthorizationApplier().restorePFIfAuthorized()
        } catch {
            FileHandle.standardError.write(
                Data("dory-network-helper: privileged startup cleanup failed: \(error)\n".utf8)
            )
            exit(1)
        }
        listener.resume()
        dispatchMain()
    }

    public func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        let clientUID = newConnection.effectiveUserIdentifier
        newConnection.setCodeSigningRequirement(DoryPrivilegedNetworkXPC.productionClientRequirement)
        newConnection.exportedInterface = NSXPCInterface(with: DoryPrivilegedNetworkControl.self)
        newConnection.exportedObject = SourcePreservingLANPrivilegedService(
            controller: controller,
            clientUID: clientUID
        )
        newConnection.resume()
        return true
    }
}

private final class SourcePreservingLANPrivilegedService: NSObject, DoryPrivilegedNetworkControl {
    private let controller: SourcePreservingLANPrivilegedController
    private let clientUID: uid_t

    init(controller: SourcePreservingLANPrivilegedController, clientUID: uid_t) {
        self.controller = controller
        self.clientUID = clientUID
    }

    func applySourcePreservingLAN(
        _ request: NSData,
        withReply reply: @escaping (NSData?, NSString?) -> Void
    ) {
        do {
            let decoded = try JSONDecoder().decode(SourcePreservingLANRequest.self, from: request as Data)
            let response = try controller.apply(decoded, clientUID: clientUID)
            reply(try JSONEncoder().encode(response) as NSData, nil)
        } catch {
            reply(nil, "\(error)" as NSString)
        }
    }

    func reconcileAuthorizedNetworking(
        _ request: NSData,
        withReply reply: @escaping (Bool, NSString?) -> Void
    ) {
        do {
            let data = request as Data
            guard data.count <= 1 << 20 else {
                throw NetworkingAuthorizationApplyError.unsafeRequest("authorization-plan-size")
            }
            let plan = try JSONDecoder().decode(NetworkingAuthorizationPlan.self, from: data)
            let reconciled = try NetworkingAuthorizationApplier().reconcileIfAuthorized(
                plan,
                clientUID: clientUID
            )
            reply(reconciled, nil)
        } catch {
            reply(false, "\(error)" as NSString)
        }
    }
}
