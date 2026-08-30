import Darwin
import DoryCameraBridgeContracts
import DoryHostCamera
import Foundation
import Virtualization

public enum DoryVZMacCameraBridgeError: Error, Sendable, CustomStringConvertible {
    case alreadyStarted
    case socketDuplicationFailed(Int32)

    public var description: String {
        switch self {
        case .alreadyStarted:
            "the VZMac camera bridge is already installed"
        case .socketDuplicationFailed(let code):
            "the VZMac camera connection could not be duplicated (errno \(code))"
        }
    }
}

/// Host half of Dory's VZMac camera path. The guest connects to port 1030, requests one bounded
/// format, and receives only the newest JPEG frame. One active consumer is admitted so two guest
/// processes cannot silently share host-camera authority.
public final class DoryVZMacCameraBridge: NSObject,
    VZVirtioSocketListenerDelegate, @unchecked Sendable
{
    private let camera: DoryMacCameraBackend
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var socketDevice: VZVirtioSocketDevice?
    private var listener: VZVirtioSocketListener?
    private var activeConnection = false

    public init(
        camera: DoryMacCameraBackend,
        log: @escaping @Sendable (String) -> Void
    ) {
        self.camera = camera
        self.log = log
    }

    /// Must be called on the virtual machine's serialization queue after the VM has exposed its
    /// VZVirtioSocketDevice.
    public func install(on socketDevice: VZVirtioSocketDevice) throws {
        lock.lock()
        guard listener == nil else {
            lock.unlock()
            throw DoryVZMacCameraBridgeError.alreadyStarted
        }
        let listener = VZVirtioSocketListener()
        listener.delegate = self
        self.listener = listener
        self.socketDevice = socketDevice
        lock.unlock()
        socketDevice.setSocketListener(listener, forPort: DoryCameraBridgeV1.vsockPort)
        log("Dory VZMac camera: listening on guest port \(DoryCameraBridgeV1.vsockPort)")
    }

    /// Must be called on the same virtual machine serialization queue used by `install`.
    public func remove() {
        lock.lock()
        let device = socketDevice
        socketDevice = nil
        listener = nil
        lock.unlock()
        device?.removeSocketListener(forPort: DoryCameraBridgeV1.vsockPort)
        camera.stop()
        log("Dory VZMac camera: bridge removed")
    }

    public func listener(
        _ listener: VZVirtioSocketListener,
        shouldAcceptNewConnection connection: VZVirtioSocketConnection,
        from socketDevice: VZVirtioSocketDevice
    ) -> Bool {
        lock.lock()
        guard self.listener === listener, self.socketDevice === socketDevice, !activeConnection else {
            lock.unlock()
            return false
        }
        activeConnection = true
        lock.unlock()

        let connectionBox = ConnectionBox(connection)
        DispatchQueue.global(qos: .userInitiated).async { [self, connectionBox] in
            defer {
                connectionBox.connection.close()
                lock.lock()
                activeConnection = false
                lock.unlock()
                log("Dory VZMac camera: guest stream stopped")
            }
            do {
                try DoryVZMacCameraSession(
                    connection: connectionBox.connection,
                    frameProvider: { [camera] width, height, timeout in
                        try camera.nextJPEGFrameOrThrow(
                            width: width,
                            height: height,
                            timeout: timeout
                        )
                    }
                ).run()
            } catch {
                log("Dory VZMac camera: guest stream failed: \(error)")
            }
        }
        return true
    }

    deinit {
        camera.stop()
    }

    private final class ConnectionBox: @unchecked Sendable {
        let connection: VZVirtioSocketConnection
        init(_ connection: VZVirtioSocketConnection) { self.connection = connection }
    }
}

struct DoryVZMacCameraSession: @unchecked Sendable {
    typealias FrameProvider = @Sendable (Int, Int, TimeInterval) throws -> Data

    let descriptor: Int32
    let frameProvider: FrameProvider

    init(connection: VZVirtioSocketConnection, frameProvider: @escaping FrameProvider) throws {
        let descriptor = dup(connection.fileDescriptor)
        guard descriptor >= 0 else {
            throw DoryVZMacCameraBridgeError.socketDuplicationFailed(errno)
        }
        self.descriptor = descriptor
        self.frameProvider = frameProvider
    }

    init(ownedDescriptor: Int32, frameProvider: @escaping FrameProvider) {
        descriptor = ownedDescriptor
        self.frameProvider = frameProvider
    }

    func run() throws {
        var noSignal: Int32 = 1
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout<Int32>.size)
        )
        defer {
            _ = shutdown(descriptor, SHUT_RDWR)
            close(descriptor)
        }

        var reader = DoryCameraBridgeMessageReader(descriptor: descriptor)
        let startMessage = try reader.readMessage()
        guard startMessage.kind == .start else {
            throw DoryCameraBridgeV1.ProtocolError.invalidStartPayload
        }
        let request = try DoryCameraBridgeV1.StartRequest.decode(startMessage.payload)
        let cancellation = CancellationState()
        let controlGroup = DispatchGroup()
        let controlReaderSeed = reader
        controlGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { controlGroup.leave() }
            var controlReader = controlReaderSeed
            do {
                while !cancellation.isCancelled {
                    let message = try controlReader.readMessage()
                    guard message.kind == .stop else { continue }
                    cancellation.cancel()
                }
            } catch {
                cancellation.cancel()
            }
        }

        var sequence: UInt64 = 0
        let interval = UInt64(1_000_000_000 / request.maximumFramesPerSecond)
        while !cancellation.isCancelled {
            let started = DispatchTime.now().uptimeNanoseconds
            let jpeg: Data
            do {
                jpeg = try frameProvider(
                    Int(request.widthPixels),
                    Int(request.heightPixels),
                    min(2, max(0.05, Double(interval) / 1_000_000_000 * 2))
                )
            } catch {
                try writeError(
                    String(String(describing: error).prefix(1_024)),
                    sequence: sequence,
                    to: descriptor
                )
                break
            }
            let frame = try DoryCameraBridgeV1.JPEGFrame(
                widthPixels: request.widthPixels,
                heightPixels: request.heightPixels,
                hostPresentationTimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
                jpeg: jpeg
            )
            let message = try DoryCameraBridgeV1.Message(
                kind: .frame,
                sequence: sequence,
                payload: frame.encode()
            )
            try writeAll(DoryCameraBridgeV1.encode(message), to: descriptor)
            sequence &+= 1
            let elapsed = DispatchTime.now().uptimeNanoseconds &- started
            if elapsed < interval {
                Thread.sleep(forTimeInterval: Double(interval - elapsed) / 1_000_000_000)
            }
        }
        cancellation.cancel()
        _ = shutdown(descriptor, SHUT_RD)
        controlGroup.wait()
    }

    private func writeError(_ detail: String, sequence: UInt64, to descriptor: Int32) throws {
        let message = try DoryCameraBridgeV1.Message(
            kind: .error,
            sequence: sequence,
            payload: Data(detail.utf8.prefix(1_024))
        )
        try writeAll(DoryCameraBridgeV1.encode(message), to: descriptor)
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                guard count > 0 else { throw POSIXError(.EIO) }
                offset += count
            }
        }
    }
}

private struct DoryCameraBridgeMessageReader: Sendable {
    let descriptor: Int32
    private var decoder = DoryCameraBridgeV1.Decoder()
    private var pending: [DoryCameraBridgeV1.Message] = []

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    mutating func readMessage() throws -> DoryCameraBridgeV1.Message {
        if !pending.isEmpty { return pending.removeFirst() }
        var chunk = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = read(descriptor, &chunk, chunk.count)
            if count == 0 { throw POSIXError(.ECONNRESET) }
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            pending.append(contentsOf: try decoder.append(Data(chunk.prefix(count))))
            if !pending.isEmpty { return pending.removeFirst() }
        }
    }
}

private final class CancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
