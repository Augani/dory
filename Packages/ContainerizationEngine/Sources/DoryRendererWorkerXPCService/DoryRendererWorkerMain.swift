import Darwin
import DoryRendererWorkerContracts
import DoryRendererWorkerMetalTransport
import DoryRendererWorkerServiceCore
import DoryRendererWorkerVirglBackend
import Foundation
import Metal
import XPC

private enum DoryRendererWorkerBackendFactory {
    static func make() -> any DoryRendererWorkerBackend {
        do {
            return try DoryRendererWorkerVirglBackend()
        } catch {
            // A standalone executable, invalid nested-bundle layout, or missing fixed production
            // authority must never silently become an in-process or software renderer.
            return DoryRendererWorkerFailClosedBackend()
        }
    }
}

private final class DoryRendererWorkerXPCAdapter:
    NSObject,
    DoryRendererWorkerXPCProtocol
{
    private let service = DoryRendererWorkerService(
        backend: DoryRendererWorkerBackendFactory.make()
    )

    func bootstrap(_ request: Data, withReply reply: @escaping (Data) -> Void) {
        reply(service.bootstrap(exactBytes: request))
    }

    func exchange(
        _ frame: Data,
        descriptors: [FileHandle],
        withReply reply: @escaping (Data, [FileHandle], MTLSharedTextureHandle?) -> Void
    ) {
        let result = service.exchange(exactFrame: frame, descriptors: descriptors)
        reply(result.result, result.descriptors, result.sharedTextureHandle)
    }
}

private final class DoryRendererWorkerListenerDelegate:
    NSObject,
    NSXPCListenerDelegate,
    @unchecked Sendable
{
    private let admissionLock = NSLock()
    private let adapter = DoryRendererWorkerXPCAdapter()
    private var acceptedConnection = false

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        guard connection.processIdentifier > 1,
              connection.effectiveUserIdentifier == geteuid(),
              connection.effectiveGroupIdentifier == getegid() else {
            return false
        }
        let claimed = admissionLock.withLock {
            guard !acceptedConnection else { return false }
            acceptedConnection = true
            return true
        }
        guard claimed else { return false }
        // This service owns one renderer generation, foreign-library state, shared mappings, and
        // live scanout/fence leases for the complete accepted connection. Keep launchd from
        // idle-killing it between bounded command batches; invalidation terminates the process, so
        // there is deliberately no reconnect or transaction-end path.
        xpc_transaction_begin()
        connection.setCodeSigningRequirement(
            DoryRendererWorkerIdentity.runnerCodeSigningRequirement
        )
        connection.exportedInterface = DoryRendererWorkerXPCInterface.make()
        connection.exportedObject = adapter
        connection.interruptionHandler = Self.terminate
        connection.invalidationHandler = Self.terminate
        connection.activate()
        return true
    }

    private static func terminate() {
        Darwin._exit(EXIT_SUCCESS)
    }
}

@main
private enum DoryRendererWorkerMain {
    private static let listenerDelegate = DoryRendererWorkerListenerDelegate()

    static func main() {
        let listener = NSXPCListener.service()
        listener.delegate = listenerDelegate
        listener.resume()
    }
}
