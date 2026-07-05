import Darwin
import Foundation

public struct UsbControlRequest: Codable, Equatable, Sendable {
    public var cmd: String            // "attach" | "detach"
    public var busid: String
    public var mode: String?          // "userAuthorized" | "seize" | "capture" (attach only)

    public init(cmd: String, busid: String, mode: String? = nil) {
        self.cmd = cmd
        self.busid = busid
        self.mode = mode
    }
}

public struct UsbControlResponse: Codable, Equatable, Sendable {
    public var ok: Bool
    public var port: Int?
    public var vsockPort: UInt32?
    public var deviceID: UInt32?
    public var speed: UInt32?
    public var error: String?

    public static func success(_ outcome: UsbAttachOutcome) -> UsbControlResponse {
        UsbControlResponse(ok: true, port: outcome.port, vsockPort: outcome.vsockPort, deviceID: outcome.deviceID, speed: outcome.speed, error: nil)
    }

    public static func ok() -> UsbControlResponse { UsbControlResponse(ok: true, port: nil, vsockPort: nil, deviceID: nil, speed: nil, error: nil) }
    public static func failure(_ message: String) -> UsbControlResponse { UsbControlResponse(ok: false, port: nil, vsockPort: nil, deviceID: nil, speed: nil, error: message) }
}

/// Codec for the newline-delimited JSON control protocol. Pure and unit-tested; the socket layer only
/// moves bytes.
public enum UsbControlCodec {
    public static func encodeRequest(_ request: UsbControlRequest) throws -> Data {
        var data = try JSONEncoder().encode(request)
        data.append(0x0a)
        return data
    }

    public static func decodeRequest(_ line: Data) throws -> UsbControlRequest {
        try JSONDecoder().decode(UsbControlRequest.self, from: line)
    }

    public static func encodeResponse(_ response: UsbControlResponse) throws -> Data {
        var data = try JSONEncoder().encode(response)
        data.append(0x0a)
        return data
    }

    public static func decodeResponse(_ line: Data) throws -> UsbControlResponse {
        try JSONDecoder().decode(UsbControlResponse.self, from: line)
    }

    public static func mode(from raw: String?) -> HostUsbOpenMode {
        switch raw {
        case "seize": return .seize
        case "capture": return .capture
        default: return .userAuthorized
        }
    }
}

/// Serves the `dory usb attach/detach` control protocol on a unix socket in the engine process (which
/// owns the device claim, the UsbipManager, and the guest agent channel). One request per connection.
public final class UsbControlServer: @unchecked Sendable {
    private let path: String
    private let handler: UsbControlHandler
    private let queue = DispatchQueue(label: "dory.usb.control")
    private var listenFD: Int32 = -1

    public init(path: String, handler: UsbControlHandler) {
        self.path = path
        self.handler = handler
    }

    public func start() throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UsbControlServerError.socket("socket: errno \(errno)") }
        unlink(path)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        Self.copyPath(path, into: &address)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { close(fd); throw UsbControlServerError.socket("bind \(path): errno \(errno)") }
        guard listen(fd, 8) == 0 else { close(fd); throw UsbControlServerError.socket("listen: errno \(errno)") }
        listenFD = fd
        queue.async { [weak self] in self?.acceptLoop() }
    }

    public func stop() {
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(path)
    }

    private func acceptLoop() {
        while true {
            let client = accept(listenFD, nil, nil)
            guard client >= 0 else { return }
            handleClient(client)
        }
    }

    private func handleClient(_ fd: Int32) {
        defer { close(fd) }
        guard let line = Self.readLine(fd) else { return }
        let response: UsbControlResponse
        if let request = try? UsbControlCodec.decodeRequest(line) {
            response = runHandler(request)
        } else {
            response = .failure("malformed control request")
        }
        if let data = try? UsbControlCodec.encodeResponse(response) {
            _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        }
    }

    private func runHandler(_ request: UsbControlRequest) -> UsbControlResponse {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()
        let handler = self.handler
        Task {
            let response: UsbControlResponse
            do {
                switch request.cmd {
                case "attach":
                    let outcome = try await handler.attach(busID: request.busid, mode: UsbControlCodec.mode(from: request.mode))
                    response = .success(outcome)
                case "detach":
                    try await handler.detach(busID: request.busid)
                    response = .ok()
                default:
                    response = .failure("unknown command \(request.cmd)")
                }
            } catch {
                response = .failure("\(error)")
            }
            box.value = response
            semaphore.signal()
        }
        semaphore.wait()  // one control request per connection; the accept loop serializes them
        return box.value ?? .failure("no result")
    }

    private final class ResultBox: @unchecked Sendable {
        var value: UsbControlResponse?
    }

    private static func readLine(_ fd: Int32) -> Data? {
        var data = Data()
        var byte: UInt8 = 0
        while data.count < 8192 {
            let n = Darwin.read(fd, &byte, 1)
            guard n == 1 else { return data.isEmpty ? nil : data }
            if byte == 0x0a { return data }
            data.append(byte)
        }
        return data
    }

    private static func copyPath(_ path: String, into address: inout sockaddr_un) {
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            let bytes = [UInt8](path.utf8.prefix(destination.count - 1))
            destination.copyBytes(from: bytes)
        }
    }
}

public enum UsbControlServerError: Error, Equatable, Sendable {
    case socket(String)
}

/// The guest agent's usb.attach/usb.detach reply. We only need to know the call succeeded, so the
/// fields (`attached`/`detached`, `busid`, `port`) are optional and unused.
public struct UsbAgentReply: Decodable, Sendable {
    public var busid: String?
    public var port: Int?
}

/// Client used by `dory-hv usb attach/detach`: connect to the engine's control socket, send one
/// request, read one response.
public enum UsbControlClient {
    public static func send(_ request: UsbControlRequest, socketPath: String) throws -> UsbControlResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UsbControlServerError.socket("socket: errno \(errno)") }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        UsbControlServer_copyPath(socketPath, into: &address)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw UsbControlServerError.socket("connect \(socketPath): errno \(errno) (is the engine running?)") }
        let payload = try UsbControlCodec.encodeRequest(request)
        _ = payload.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        var response = Data()
        var byte: UInt8 = 0
        while response.count < 8192 {
            let n = Darwin.read(fd, &byte, 1)
            guard n == 1 else { break }
            if byte == 0x0a { break }
            response.append(byte)
        }
        return try UsbControlCodec.decodeResponse(response)
    }
}

private func UsbControlServer_copyPath(_ path: String, into address: inout sockaddr_un) {
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
        let bytes = [UInt8](path.utf8.prefix(destination.count - 1))
        destination.copyBytes(from: bytes)
    }
}
