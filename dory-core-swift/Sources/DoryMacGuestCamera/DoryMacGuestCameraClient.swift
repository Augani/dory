import Darwin
import DoryCameraBridgeContracts
import Foundation

public enum DoryMacGuestCameraError: Error, Sendable, CustomStringConvertible {
    case alreadyConnected
    case notConnected
    case socketFailed(Int32)
    case connectFailed(Int32)
    case connectionClosed
    case remote(String)
    case unexpectedMessage(DoryCameraBridgeV1.MessageKind)

    public var description: String {
        switch self {
        case .alreadyConnected: "Dory Camera is already connected"
        case .notConnected: "Dory Camera is not connected"
        case .socketFailed(let code): "Dory Camera could not create a guest socket (errno \(code))"
        case .connectFailed(let code): "Dory Camera could not reach the host (errno \(code))"
        case .connectionClosed: "the Dory Camera host connection closed"
        case .remote(let detail): "the Dory Camera host reported: \(detail)"
        case .unexpectedMessage(let kind): "Dory Camera received an unexpected \(kind) message"
        }
    }
}

/// Guest-side camera client usable by both Dory-specific apps and the CoreMediaIO Camera Extension.
/// An ordinary app can consume `nextFrame()` directly; no Camera Extension is required for that
/// application-scoped use case.
public final class DoryMacGuestCameraClient: @unchecked Sendable {
    private let lock = NSLock()
    private let readLock = NSLock()
    private var descriptor: Int32 = -1
    private var decoder = DoryCameraBridgeV1.Decoder()
    private var pending: [DoryCameraBridgeV1.Message] = []
    private var nextControlSequence: UInt64 = 0

    public init() {}

    init(connectedDescriptor: Int32) {
        descriptor = connectedDescriptor
    }

    public func connect(
        widthPixels: UInt32 = 1_280,
        heightPixels: UInt32 = 720,
        maximumFramesPerSecond: UInt32 = 30
    ) throws {
        let request = try DoryCameraBridgeV1.StartRequest(
            widthPixels: widthPixels,
            heightPixels: heightPixels,
            maximumFramesPerSecond: maximumFramesPerSecond
        )
        lock.lock()
        guard descriptor < 0 else {
            lock.unlock()
            throw DoryMacGuestCameraError.alreadyConnected
        }
        lock.unlock()

        let socketDescriptor = socket(AF_VSOCK, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else { throw DoryMacGuestCameraError.socketFailed(errno) }
        var noSignal: Int32 = 1
        _ = setsockopt(
            socketDescriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout<Int32>.size)
        )
        var address = sockaddr_vm()
        address.svm_len = UInt8(MemoryLayout<sockaddr_vm>.size)
        address.svm_family = sa_family_t(AF_VSOCK)
        address.svm_port = DoryCameraBridgeV1.vsockPort
        address.svm_cid = UInt32(VMADDR_CID_HOST)
        let status = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_vm>.size))
            }
        }
        guard status == 0 else {
            let code = errno
            close(socketDescriptor)
            throw DoryMacGuestCameraError.connectFailed(code)
        }

        lock.lock()
        descriptor = socketDescriptor
        nextControlSequence = 0
        lock.unlock()
        readLock.lock()
        decoder = DoryCameraBridgeV1.Decoder()
        pending.removeAll(keepingCapacity: true)
        readLock.unlock()
        do {
            try send(kind: .start, payload: request.encode())
        } catch {
            disconnectWithoutMessage()
            throw error
        }
    }

    public func nextFrame() throws -> DoryCameraBridgeV1.JPEGFrame {
        let message = try readMessage()
        switch message.kind {
        case .frame:
            return try DoryCameraBridgeV1.JPEGFrame.decode(message.payload)
        case .error:
            throw DoryMacGuestCameraError.remote(
                String(decoding: message.payload.prefix(1_024), as: UTF8.self)
            )
        default:
            throw DoryMacGuestCameraError.unexpectedMessage(message.kind)
        }
    }

    public func stop() {
        try? send(kind: .stop)
        disconnectWithoutMessage()
    }

    deinit {
        stop()
    }

    private func send(kind: DoryCameraBridgeV1.MessageKind, payload: Data = Data()) throws {
        lock.lock()
        let socketDescriptor = descriptor
        let sequence = nextControlSequence
        if socketDescriptor >= 0 { nextControlSequence &+= 1 }
        lock.unlock()
        guard socketDescriptor >= 0 else { throw DoryMacGuestCameraError.notConnected }
        let bytes = DoryCameraBridgeV1.encode(
            try DoryCameraBridgeV1.Message(kind: kind, sequence: sequence, payload: payload)
        )
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = write(
                    socketDescriptor,
                    buffer.baseAddress!.advanced(by: offset),
                    buffer.count - offset
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                guard count > 0 else { throw DoryMacGuestCameraError.connectionClosed }
                offset += count
            }
        }
    }

    private func readMessage() throws -> DoryCameraBridgeV1.Message {
        readLock.lock()
        defer { readLock.unlock() }
        lock.lock()
        let socketDescriptor = descriptor
        lock.unlock()
        guard socketDescriptor >= 0 else { throw DoryMacGuestCameraError.notConnected }
        if !pending.isEmpty { return pending.removeFirst() }
        var chunk = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = read(socketDescriptor, &chunk, chunk.count)
            if count == 0 { throw DoryMacGuestCameraError.connectionClosed }
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            pending.append(contentsOf: try decoder.append(Data(chunk.prefix(count))))
            if !pending.isEmpty { return pending.removeFirst() }
        }
    }

    private func disconnectWithoutMessage() {
        lock.lock()
        let socketDescriptor = descriptor
        descriptor = -1
        lock.unlock()
        if socketDescriptor >= 0 {
            _ = shutdown(socketDescriptor, SHUT_RDWR)
            close(socketDescriptor)
        }
        readLock.lock()
        decoder = DoryCameraBridgeV1.Decoder()
        pending.removeAll(keepingCapacity: false)
        readLock.unlock()
    }
}
