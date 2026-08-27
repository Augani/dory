import Darwin
import DoryFSWorkerContracts
import DoryFSWorkerServiceCore
import Foundation
import XPC

/// The only Objective-C object exported by the filesystem worker. The adapter deliberately adds
/// no object-model API of its own: every request and reply remains an exact bounded binary
/// envelope validated independently by `DoryFSWorkerService`.
private final class DoryFSWorkerXPCAdapter: NSObject, DoryFSWorkerXPCProtocol {
    private let service = DoryFSWorkerService()

    func bootstrap(
        _ request: Data,
        rootDescriptors: [FileHandle],
        withReply reply: @escaping (Data) -> Void
    ) {
        reply(service.bootstrap(
            exactBytes: request,
            rootDescriptors: rootDescriptors
        ))
    }

    func exchange(_ frame: Data, withReply reply: @escaping (Data) -> Void) {
        reply(service.exchange(exactFrame: frame))
    }

    func sendOneWay(_ frame: Data) {
        service.sendOneWay(exactFrame: frame)
    }
}

/// Accepts one runner connection for the lifetime of this process. A disconnected worker exits
/// instead of returning to launchd with live roots, handles, locks, or a reusable bootstrap gate.
private final class DoryFSWorkerListenerDelegate:
    NSObject,
    NSXPCListenerDelegate,
    @unchecked Sendable
{
    private static let runnerSigningRequirement = """
        anchor apple generic and identifier "com.pythonxi.Dory.HVRunner" and \
        certificate leaf[subject.OU] = "864H636QW4"
        """

    private let admissionLock = NSLock()
    private let adapter = DoryFSWorkerXPCAdapter()
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

        // XPC services are otherwise eligible for launchd's idle SIGKILL between FUSE requests.
        // This connection owns process-local root descriptors, FUSE handles, and one immutable
        // worker generation, so its entire accepted lifetime is one explicit XPC transaction.
        // Invalidation exits the process below; there is deliberately no reconnect/end path.
        xpc_transaction_begin()

        // Foundation validates every incoming message against the sender's audit-token-bound code
        // identity. This avoids PID-only identity checks and rejects an unsigned, re-signed, or
        // different-team process even if it can discover the service name. The requirement is a
        // fixed source literal; malformed dynamic requirement strings are intentionally impossible.
        connection.setCodeSigningRequirement(Self.runnerSigningRequirement)

        connection.exportedInterface = DoryFSWorkerXPCInterface.make()
        connection.exportedObject = adapter
        connection.interruptionHandler = Self.terminateProcess
        connection.invalidationHandler = Self.terminateProcess
        connection.activate()
        return true
    }

    private static func terminateProcess() {
        // `_exit` is intentional: process termination is the deterministic cleanup boundary for
        // descriptors and blocking host filesystem operations. No fallback/reconnect is allowed.
        Darwin._exit(EXIT_SUCCESS)
    }
}

@main
private enum DoryFSWorkerMain {
    // NSXPCListener holds its delegate weakly, so process lifetime owns the one delegate strongly.
    private static let listenerDelegate = DoryFSWorkerListenerDelegate()

    static func main() {
        do {
            try DoryFSWorkerProcessResources.raiseFileDescriptorSoftLimit()
        } catch {
            // The worker contract permits package-manager-scale descriptor ownership. Continuing
            // with launchd's lower inherited soft limit would advertise capacity this process
            // cannot honor, so fail before accepting or bootstrapping a workspace authority.
            FileHandle.standardError.write(Data(
                "dory-fs-worker: descriptor admission unavailable\n".utf8
            ))
            Darwin._exit(EXIT_FAILURE)
        }
        let listener = NSXPCListener.service()
        listener.delegate = listenerDelegate
        listener.resume()
    }
}
