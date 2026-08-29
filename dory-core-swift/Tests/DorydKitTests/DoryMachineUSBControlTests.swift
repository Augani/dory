import Darwin
import Foundation
import Testing
@testable import DorydKit

@Suite(.serialized)
struct DoryMachineUSBControlTests {
    @Test func attachUsesExactPrivateSocketWireContract() throws {
        let server = try OneShotUSBServer(
            response: """
            {"ok":true,"port":7,"vsockPort":1025,"deviceID":196610,"speed":3}
            """
        )
        defer { server.stop() }

        let attachment = try UnixDoryMachineUSBController().attach(
            machineID: "desktop",
            socketPath: server.path,
            busID: "3-2",
            mode: .capture
        )

        #expect(attachment == DoryMachineUSBAttachment(
            machineID: "desktop",
            busID: "3-2",
            port: 7,
            vsockPort: 1025,
            deviceID: 196_610,
            speed: 3
        ))
        #expect(server.request?["cmd"] as? String == "attach")
        #expect(server.request?["busid"] as? String == "3-2")
        #expect(server.request?["mode"] as? String == "capture")
    }

    @Test func detachTreatsMalformedSuccessAsAnUnknownOutcome() throws {
        let server = try OneShotUSBServer(
            response: """
            {"ok":true,"port":7}
            """
        )
        defer { server.stop() }

        #expect(throws: DoryMachineUSBControlError.outcomeUnknown(
            operation: "detach",
            detail: DoryMachineUSBControlError.malformedResponse.description
        )) {
            try UnixDoryMachineUSBController(operationTimeout: 1).detach(
                socketPath: server.path,
                busID: "3-2"
            )
        }
    }

    @Test func explicitFailureDispositionControlsRetrySafety() throws {
        let rejected = try OneShotUSBServer(
            response: #"{"ok":false,"disposition":"rejected","error":"device is busy"}"#
        )
        defer { rejected.stop() }
        #expect(throws: DoryMachineUSBControlError.rejected("device is busy")) {
            try UnixDoryMachineUSBController(operationTimeout: 1).detach(
                socketPath: rejected.path,
                busID: "3-2"
            )
        }

        let unknown = try OneShotUSBServer(
            response: #"{"ok":false,"disposition":"outcomeUnknown","error":"rollback unconfirmed"}"#
        )
        defer { unknown.stop() }
        #expect(throws: DoryMachineUSBControlError.outcomeUnknown(
            operation: "detach",
            detail: "rollback unconfirmed"
        )) {
            try UnixDoryMachineUSBController(operationTimeout: 1).detach(
                socketPath: unknown.path,
                busID: "3-2"
            )
        }
    }

    @Test func duplicateResponseFieldsProduceAnUnknownOutcome() throws {
        let server = try OneShotUSBServer(
            response: #"{"ok":false,"ok":true,"disposition":"rejected","error":"busy"}"#
        )
        defer { server.stop() }

        #expect(throws: DoryMachineUSBControlError.outcomeUnknown(
            operation: "detach",
            detail: DoryMachineUSBControlError.malformedResponse.description
        )) {
            try UnixDoryMachineUSBController(operationTimeout: 1).detach(
                socketPath: server.path,
                busID: "3-2"
            )
        }
    }

    @Test func strictBusIDGrammarMatchesTheEngineContract() {
        for valid in ["3-2", "pci_1:USB.4", String(repeating: "a", count: 31)] {
            #expect(DoryMachineUSBWireContract.isValidBusID(valid))
        }
        for invalid in [
            "",
            "3/2",
            "3 2",
            "usb\n2",
            "usb-é",
            String(repeating: "a", count: 32),
        ] {
            #expect(!DoryMachineUSBWireContract.isValidBusID(invalid))
        }
    }

    @Test func noncanonicalSocketPathIsRejectedBeforeConnecting() throws {
        let server = try OneShotUSBServer(response: "{\"ok\":true}")
        defer { server.stop() }

        #expect(throws: DoryMachineUSBControlError.invalidSocketPath) {
            try UnixDoryMachineUSBController().detach(
                socketPath: server.root + "/./u.sock",
                busID: "3-2"
            )
        }
        #expect(server.request == nil)
    }

    @Test func configuredClientDescriptorIsNonblockingCloseOnExecAndNoSigpipe() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        defer {
            if descriptors[0] >= 0 { close(descriptors[0]) }
            if descriptors[1] >= 0 { close(descriptors[1]) }
        }

        try DoryMachineUSBClientSocketIO.configureOwnedSocket(descriptors[0])
        #expect(fcntl(descriptors[0], F_GETFD) & FD_CLOEXEC != 0)
        #expect(fcntl(descriptors[0], F_GETFL) & O_NONBLOCK != 0)
        var noSigpipe: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        #expect(getsockopt(
            descriptors[0],
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigpipe,
            &length
        ) == 0)
        #expect(noSigpipe == 1)
    }

    @Test func slowResponseCannotExtendTheWholeOperationDeadline() throws {
        let server = try OneShotUSBServer(
            response: "{\"ok\":true}",
            responseByteInterval: 0.03
        )
        defer { server.stop() }

        do {
            try UnixDoryMachineUSBController(operationTimeout: 0.09).detach(
                socketPath: server.path,
                busID: "3-2"
            )
            Issue.record("slow response unexpectedly completed")
        } catch let error as DoryMachineUSBControlError {
            guard case let .outcomeUnknown(operation, detail) = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
            #expect(operation == "detach")
            #expect(detail.contains("timed out"))
        }
    }

    @Test func trailingResponseBytesProduceAnUnknownOutcome() throws {
        let server = try OneShotUSBServer(
            responseData: Data("{\"ok\":true}\n{}".utf8)
        )
        defer { server.stop() }

        do {
            try UnixDoryMachineUSBController(operationTimeout: 1).detach(
                socketPath: server.path,
                busID: "3-2"
            )
            Issue.record("response with trailing bytes unexpectedly succeeded")
        } catch let error as DoryMachineUSBControlError {
            guard case let .outcomeUnknown(operation, detail) = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
            #expect(operation == "detach")
            #expect(detail.contains("malformed response"))
        }
    }

    @Test func endpointReplacementAfterConnectIsRejectedBeforeRequestWrite() throws {
        let server = try OneShotUSBServer(response: "{\"ok\":true}")
        defer { server.stop() }
        let controller = UnixDoryMachineUSBController(
            operationTimeout: 1,
            beforeEndpointRevalidation: {
                server.replacePublishedEndpoint()
            }
        )

        #expect(throws: DoryMachineUSBControlError.untrustedSocket) {
            try controller.detach(socketPath: server.path, busID: "3-2")
        }
        #expect(server.request == nil)
    }

    @Test func nonprivateParentDirectoryIsRejectedBeforeConnecting() throws {
        let server = try OneShotUSBServer(response: "{\"ok\":true}")
        defer { server.stop() }
        #expect(chmod(server.root, 0o755) == 0)

        #expect(throws: DoryMachineUSBControlError.untrustedSocket) {
            try UnixDoryMachineUSBController().detach(
                socketPath: server.path,
                busID: "3-2"
            )
        }
        #expect(server.request == nil)
    }

    @Test func regularFileCannotSubstituteForControlSocket() throws {
        let root = "/tmp/dory-usb-client-file-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let path = root + "/u.sock"
        try Data("not-a-socket".utf8).write(to: URL(fileURLWithPath: path))

        #expect(throws: DoryMachineUSBControlError.untrustedSocket) {
            _ = try UnixDoryMachineUSBController().attach(
                machineID: "desktop",
                socketPath: path,
                busID: "3-2",
                mode: .userAuthorized
            )
        }
    }
}

private final class OneShotUSBServer: @unchecked Sendable {
    let root: String
    let path: String
    private let response: Data
    private let responseByteInterval: TimeInterval
    private let queue = DispatchQueue(label: "dev.dory.tests.usb-control")
    private let completion = DispatchGroup()
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var clientDescriptor: Int32 = -1
    private var replacementDescriptor: Int32 = -1
    private var storedRequest: [String: Any]?

    var request: [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        return storedRequest
    }

    convenience init(response: String, responseByteInterval: TimeInterval = 0) throws {
        try self.init(
            responseData: Data((response + "\n").utf8),
            responseByteInterval: responseByteInterval
        )
    }

    init(responseData: Data, responseByteInterval: TimeInterval = 0) throws {
        root = "/tmp/dory-usb-client-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        path = root + "/u.sock"
        response = responseData
        self.responseByteInterval = responseByteInterval
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root)

        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.ENOTSOCK) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            destination.copyBytes(from: path.utf8)
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(descriptor, 1) == 0 else {
            stop()
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let listenDescriptor = descriptor
        completion.enter()
        queue.async { [weak self] in
            defer { self?.completion.leave() }
            self?.serve(listenDescriptor: listenDescriptor)
        }
    }

    func stop() {
        lock.lock()
        let active = descriptor
        descriptor = -1
        let client = clientDescriptor
        let replacement = replacementDescriptor
        replacementDescriptor = -1
        if active >= 0 { _ = shutdown(active, SHUT_RDWR) }
        if client >= 0 { _ = shutdown(client, SHUT_RDWR) }
        lock.unlock()
        if active >= 0 { close(active) }
        _ = completion.wait(timeout: .now() + 1)
        if replacement >= 0 { close(replacement) }
        unlink(path)
        try? FileManager.default.removeItem(atPath: root)
    }

    func replacePublishedEndpoint() {
        precondition(unlink(path) == 0)
        let replacement = socket(AF_UNIX, SOCK_STREAM, 0)
        precondition(replacement >= 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            destination.copyBytes(from: path.utf8)
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    replacement,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        precondition(bound == 0 && chmod(path, 0o600) == 0 && listen(replacement, 1) == 0)
        lock.lock()
        replacementDescriptor = replacement
        lock.unlock()
    }

    private func serve(listenDescriptor: Int32) {
        let client = accept(listenDescriptor, nil, nil)
        guard client >= 0 else { return }
        var noSigpipe: Int32 = 1
        _ = setsockopt(
            client,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigpipe,
            socklen_t(MemoryLayout<Int32>.size)
        )
        lock.lock()
        clientDescriptor = client
        lock.unlock()
        defer {
            lock.lock()
            if clientDescriptor == client { clientDescriptor = -1 }
            close(client)
            lock.unlock()
        }
        var data = Data()
        var byte: UInt8 = 0
        while data.count < 8 * 1024, Darwin.read(client, &byte, 1) == 1 {
            if byte == 0x0a { break }
            data.append(byte)
        }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            lock.lock()
            storedRequest = object
            lock.unlock()
        }
        if responseByteInterval > 0 {
            for byte in response {
                let written = withUnsafeBytes(of: byte) {
                    Darwin.write(client, $0.baseAddress, 1)
                }
                if written != 1 { break }
                Thread.sleep(forTimeInterval: responseByteInterval)
            }
        } else {
            _ = response.withUnsafeBytes { bytes in
                Darwin.write(client, bytes.baseAddress, bytes.count)
            }
        }
    }

    deinit {
        stop()
    }
}
