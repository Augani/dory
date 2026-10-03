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

/// Owns a native XPC reply block across the service's serial execution handoff. A lock claims it
/// exactly once; arbitrary callback code is never invoked while the lock is held.
private final class DoryRendererWorkerExchangeReply: @unchecked Sendable {
    private let lock = NSLock()
    private var reply: ((Data, [FileHandle], MTLSharedTextureHandle?) -> Void)?
    init(_ reply: @escaping (Data, [FileHandle], MTLSharedTextureHandle?) -> Void) { self.reply = reply }
    func send(_ bytes: Data, _ descriptors: [FileHandle], _ texture: MTLSharedTextureHandle?) {
        let delivery = lock.withLock { let delivery = reply; reply = nil; return delivery }
        guard let delivery else {
            for descriptor in descriptors { try? descriptor.close() }
            return
        }
        delivery(bytes, descriptors, texture)
    }
}

private final class DoryRendererWorkerXPCAdapter:
    NSObject,
    DoryRendererWorkerXPCProtocol
{
    private let service = DoryRendererWorkerService(
        backend: DoryRendererWorkerBackendFactory.make()
    )

    func bootstrap(
        _ request: Data,
        withReply reply: @escaping (Data, [FileHandle]) -> Void
    ) {
        let result = service.bootstrapWithDescriptors(exactBytes: request)
        reply(result.result, result.descriptors)
    }

    func exchange(
        _ frame: Data,
        descriptors: [FileHandle],
        withReply reply: @escaping (Data, [FileHandle], MTLSharedTextureHandle?) -> Void
    ) {
        let reply = DoryRendererWorkerExchangeReply(reply)
        service.exchangeAsynchronously(exactFrame: frame, descriptors: descriptors) { bytes, descriptors, texture in
            reply.send(bytes, descriptors, texture)
        }
    }

    func qualificationCrash(_ request: Data, withReply reply: @escaping (Bool, UInt32) -> Void) {
        let admission = service.admitQualificationCrash(exactBytes: request)
        reply(admission.accepted, admission.inFlightCommands)
        guard admission.accepted,
              let intent = try? DoryRendererWorkerQualificationCrashRequest.decode(request) else { return }
        // Let the acknowledgement leave XPC, then die without resetting/quiescing the backend.
        // getpid() targets only this authenticated worker instance; no caller supplies a PID.
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + .milliseconds(25)) {
            guard DispatchTime.now().uptimeNanoseconds < intent.deadlineUptimeNanoseconds else { return }
            Darwin.kill(Darwin.getpid(), SIGKILL)
            Darwin._exit(EXIT_FAILURE)
        }
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
