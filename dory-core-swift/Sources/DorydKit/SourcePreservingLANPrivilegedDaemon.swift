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
        controller.clearStaleAnchor()
        do {
            try NetworkingAuthorizationApplier().restorePFIfAuthorized()
        } catch {
            FileHandle.standardError.write(
                Data("dory-network-helper: authorized PF restore failed: \(error)\n".utf8)
            )
        }
        listener.resume()
        dispatchMain()
    }

    public func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        let clientUID = newConnection.effectiveUserIdentifier
        newConnection.setCodeSigningRequirement(DoryPrivilegedNetworkXPC.productionPeerRequirement)
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
}
