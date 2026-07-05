import Darwin
import Foundation

/// Frames the usbip command stream on the wire. The guest's vhci_hcd writes a fixed 48-byte usbip
/// command header, and CMD_SUBMIT with an OUT direction appends `transfer_buffer_length` more bytes.
enum UsbipCommandFraming {
    static let fixedHeaderByteCount = UsbipSubmitCommand.headerByteCount

    static func outPayloadLength(_ header: [UInt8]) -> Int {
        guard header.count >= fixedHeaderByteCount else { return 0 }
        func be32(_ offset: Int) -> UInt32 {
            (UInt32(header[offset]) << 24) | (UInt32(header[offset + 1]) << 16)
                | (UInt32(header[offset + 2]) << 8) | UInt32(header[offset + 3])
        }
        guard be32(0) == UsbipOperation.cmdSubmit.rawValue,
              be32(12) == UsbipDirection.out.rawValue else { return 0 }
        return Int(min(be32(24), UsbipSubmitCommand.maxTransferBytes))
    }
}

/// Bridges one guest usbip vsock connection to one claimed host USB device. The guest agent dials
/// `VsockPorts.usbip` and performs the OP_REQ_IMPORT handshake; this bridge answers via `UsbipServer`,
/// then pumps USBIP_CMD_SUBMIT/UNLINK frames to the device and writes the replies back — until the
/// guest closes the connection (`isPeerClosed`), at which point `onClose` fires so the engine releases
/// the device. The serve loop runs on its own queue, never the vsock dispatch queue, because a host
/// device submit blocks on the transfer completing.
public final class UsbipBridge: @unchecked Sendable {
    private let connection: VsockConnection
    private let server: UsbipServer
    private let busID: String
    private let onClose: () -> Void
    private let queue: DispatchQueue

    public init(connection: VsockConnection, device: any UsbipExportedDevice, onClose: @escaping () -> Void = {}) {
        self.connection = connection
        self.server = UsbipServer(devices: [device])
        self.busID = device.descriptor.busID
        self.onClose = onClose
        self.queue = DispatchQueue(label: "dory.usbip.bridge.\(device.descriptor.busID)")
    }

    public func start() {
        queue.async { [weak self] in self?.serve() }
    }

    /// Runs the serve loop synchronously; returns when the connection ends. Exposed for the loopback
    /// integration test to drive the bridge without a real queue/thread.
    public func serve() {
        defer {
            connection.close()
            onClose()
        }
        guard let importFrame = readExact(UsbipImportRequest.byteCount),
              let importReply = try? server.handleImport(importFrame) else { return }
        write(importReply)

        while true {
            guard let header = readExact(UsbipCommandFraming.fixedHeaderByteCount) else { return }
            var frame = header
            let extra = UsbipCommandFraming.outPayloadLength(header)
            if extra > 0 {
                guard let payload = readExact(extra) else { return }
                frame += payload
            }
            guard let reply = try? server.handleURB(frame, busID: busID) else { return }
            write(reply)
        }
    }

    private func write(_ bytes: [UInt8]) {
        try? connection.write(bytes)
    }

    /// Reads exactly `count` bytes, polling the non-blocking vsock connection with backoff. Returns
    /// nil on EOF (the peer closed with fewer than `count` bytes remaining). "No data yet" is a wait,
    /// not an error, so an idle device is never torn down — only a real peer close ends the loop.
    private func readExact(_ count: Int) -> [UInt8]? {
        guard count > 0 else { return [] }
        var result = [UInt8]()
        result.reserveCapacity(count)
        var buffer = [UInt8](repeating: 0, count: count)
        var pollInterval: useconds_t = 1_000
        let maxPollInterval: useconds_t = 16_000
        while result.count < count {
            let read = (try? buffer.withUnsafeMutableBytes {
                try connection.read(into: UnsafeMutableRawBufferPointer(rebasing: $0[0..<(count - result.count)]))
            }) ?? 0
            if read == 0 {
                if connection.isPeerClosed { return nil }
                usleep(pollInterval)
                pollInterval = min(pollInterval * 2, maxPollInterval)
                continue
            }
            result.append(contentsOf: buffer.prefix(read))
            pollInterval = 1_000
        }
        return result
    }
}
