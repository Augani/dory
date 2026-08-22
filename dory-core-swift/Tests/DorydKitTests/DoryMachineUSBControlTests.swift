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

    @Test func detachRejectsAttachMetadataInSuccessResponse() throws {
        let server = try OneShotUSBServer(
            response: """
            {"ok":true,"port":7}
            """
        )
        defer { server.stop() }

        #expect(throws: DoryMachineUSBControlError.malformedResponse) {
            try UnixDoryMachineUSBController().detach(
                socketPath: server.path,
                busID: "3-2"
            )
        }
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
    private let queue = DispatchQueue(label: "dev.dory.tests.usb-control")
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var storedRequest: [String: Any]?

    var request: [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        return storedRequest
    }

    init(response: String) throws {
        root = "/tmp/dory-usb-client-\(getpid())-\(UInt32.random(in: 0..<UInt32.max))"
        path = root + "/u.sock"
        self.response = Data((response + "\n").utf8)
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
        queue.async { [weak self] in
            self?.serve(listenDescriptor: listenDescriptor)
        }
    }

    func stop() {
        let active = descriptor
        descriptor = -1
        if active >= 0 { close(active) }
        unlink(path)
        try? FileManager.default.removeItem(atPath: root)
    }

    private func serve(listenDescriptor: Int32) {
        let client = accept(listenDescriptor, nil, nil)
        guard client >= 0 else { return }
        defer { close(client) }
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
        _ = response.withUnsafeBytes { bytes in
            Darwin.write(client, bytes.baseAddress, bytes.count)
        }
    }

    deinit {
        stop()
    }
}
