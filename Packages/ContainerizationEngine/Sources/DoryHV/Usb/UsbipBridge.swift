import Darwin
import Foundation

/// Frames the usbip command stream on the wire. The guest's vhci_hcd writes a fixed 48-byte usbip
/// command header, and CMD_SUBMIT with an OUT direction appends `transfer_buffer_length` more bytes.
enum UsbipCommandFraming {
    static let fixedHeaderByteCount = UsbipSubmitCommand.headerByteCount

    enum Frame: Equatable {
        case submit(UsbipSubmitCommand.HeaderMetadata)
        case unlink
    }

    static func inspect(_ header: [UInt8]) throws -> Frame {
        guard header.count == fixedHeaderByteCount else {
            if header.count < fixedHeaderByteCount { throw UsbipProtocolError.shortFrame }
            throw UsbipProtocolError.invalidFrameLength(expected: fixedHeaderByteCount, actual: header.count)
        }
        let basic = try UsbipHeaderBasic(decoding: header)
        switch basic.command {
        case .cmdSubmit:
            return .submit(try UsbipSubmitCommand.inspectHeader(header))
        case .cmdUnlink:
            _ = try UsbipUnlinkCommand(decoding: header)
            return .unlink
        case .retSubmit, .retUnlink:
            throw UsbipProtocolError.unexpectedOperation(expected: .cmdSubmit, actual: basic.command)
        }
    }
}

/// Bridges one guest usbip vsock connection to one claimed host USB device. The guest agent dials
/// `VsockPorts.usbip` and performs the OP_REQ_IMPORT handshake; this bridge answers via `UsbipServer`,
/// then pumps USBIP_CMD_SUBMIT/UNLINK frames to the device and writes the replies back — until the
/// guest closes the connection (`isPeerClosed`), at which point `onClose` fires so the manager releases
/// the connection and any import lease it owns. The serve loop runs on its own queue, never the vsock
/// dispatch queue, because a host
/// device submit blocks on the transfer completing.
public final class UsbipBridge: @unchecked Sendable {
    private static let maximumHandshakeTimeout: TimeInterval = 30
    private static let maximumWriteTimeoutNanoseconds: UInt64 = 30_000_000_000

    private let connection: VsockConnection
    private let server: UsbipServer
    private let stateLock = NSLock()
    private let queue: DispatchQueue
    private let context = UsbipRequestContext()
    private let handshakeTimeout: TimeInterval
    private let writeTimeoutNanoseconds: UInt64
    private let authorizeImport: @Sendable (String) -> Bool
    private let log: @Sendable (String) -> Void
    private var onClose: (@Sendable () -> Void)?
    private var started = false
    private var stopRequested = false
    private var finished = false

    /// Backed by a server that may export several claimed devices; the busID is read from the guest's
    /// OP_REQ_IMPORT frame, so one listener can serve whichever device the guest asked for.
    public init(
        connection: VsockConnection,
        server: UsbipServer,
        label: String = "shared",
        handshakeTimeout: TimeInterval = 5,
        writeTimeoutNanoseconds: UInt64 = 5_000_000_000,
        authorizeImport: @escaping @Sendable (String) -> Bool,
        log: @escaping @Sendable (String) -> Void = { NSLog("%@", $0) },
        onClose: @escaping @Sendable () -> Void = {}
    ) {
        precondition(
            handshakeTimeout.isFinite
                && handshakeTimeout > 0
                && handshakeTimeout <= Self.maximumHandshakeTimeout
        )
        precondition(
            writeTimeoutNanoseconds > 0
                && writeTimeoutNanoseconds <= Self.maximumWriteTimeoutNanoseconds
        )
        self.connection = connection
        self.server = server
        self.onClose = onClose
        self.handshakeTimeout = handshakeTimeout
        self.writeTimeoutNanoseconds = writeTimeoutNanoseconds
        self.authorizeImport = authorizeImport
        self.log = log
        self.queue = DispatchQueue(label: "dory.usbip.bridge.\(label)")
    }

    /// Single-device convenience.
    public convenience init(
        connection: VsockConnection,
        device: any UsbipExportedDevice,
        handshakeTimeout: TimeInterval = 5,
        log: @escaping @Sendable (String) -> Void = { NSLog("%@", $0) },
        onClose: @escaping @Sendable () -> Void = {}
    ) {
        let ownedBusID = device.descriptor.busID
        self.init(
            connection: connection,
            server: UsbipServer(devices: [device]),
            label: ownedBusID,
            handshakeTimeout: handshakeTimeout,
            authorizeImport: { $0 == ownedBusID },
            log: log,
            onClose: onClose
        )
    }

    public func start() {
        guard claimRun() else { return }
        queue.async { self.runClaimed() }
    }

    /// Wakes an idle import/command read. `VsockConnection.close` is idempotent and is the only
    /// cancellation primitive needed; `finish` remains the sole completion owner.
    public func requestStop() {
        stateLock.lock()
        guard !stopRequested, !finished else {
            stateLock.unlock()
            return
        }
        stopRequested = true
        let finishWithoutRun = !started
        stateLock.unlock()
        connection.close()
        if finishWithoutRun { finish(importedBusID: nil) }
    }

    /// Runs the serve loop synchronously; returns when the connection ends. Exposed for the loopback
    /// integration test to drive the bridge without a real queue/thread.
    public func serve() {
        guard claimRun() else { return }
        runClaimed()
    }

    private func claimRun() -> Bool {
        stateLock.lock()
        guard !started, !finished else {
            stateLock.unlock()
            return false
        }
        started = true
        let canRun = !stopRequested
        stateLock.unlock()
        if !canRun { finish(importedBusID: nil) }
        return canRun
    }

    private func runClaimed() {
        var importedBusID: String?
        defer { finish(importedBusID: importedBusID) }
        let importDeadline = ProcessInfo.processInfo.systemUptime + handshakeTimeout
        guard let importFrame = readExact(
            UsbipImportRequest.byteCount,
            deadline: importDeadline
        ) else { return }
        let busID: String
        let importReply: [UInt8]
        do {
            busID = try UsbipImportRequest(decoding: importFrame).busID
        } catch {
            log("USB/IP import request rejected: \(error)")
            return
        }
        guard authorizeImport(busID) else {
            log("USB/IP import authorization expired for \(busID)")
            _ = write(UsbipImportReply(status: 1, device: nil).encoded())
            return
        }
        do {
            importReply = try server.handleImport(importFrame)
        } catch {
            log("USB/IP import request rejected: \(error)")
            return
        }
        guard write(importReply) else { return }
        do {
            guard try UsbipOperationHeader(decoding: importReply).status == 0 else { return }
        } catch {
            log("USB/IP generated an invalid import reply: \(error)")
            return
        }
        importedBusID = busID

        while true {
            guard let header = readExact(
                UsbipCommandFraming.fixedHeaderByteCount,
                deadline: nil
            ) else { return }
            let framing: UsbipCommandFraming.Frame
            do {
                framing = try UsbipCommandFraming.inspect(header)
            } catch {
                log("USB/IP command header rejected: \(error)")
                return
            }
            var frame = header
            switch framing {
            case .submit(let metadata):
                if metadata.isIsochronous {
                    // The fixed header is sufficient to reject isochronous URBs. Close afterwards:
                    // an OUT payload may already be on the stream and must never be reinterpreted
                    // as another command header.
                    let reply: [UInt8]
                    do {
                        reply = try server.handleURB(header, busID: busID, context: context)
                    } catch {
                        log("USB/IP isochronous rejection failed: \(error)")
                        return
                    }
                    _ = write(reply)
                    return
                }
                if metadata.outPayloadByteCount > 0 {
                    let totalCount = UsbipCommandFraming.fixedHeaderByteCount
                        + metadata.outPayloadByteCount
                    guard totalCount <= UsbipCommandFraming.fixedHeaderByteCount
                            + Int(UsbipSubmitCommand.maxTransferBytes) else { return }
                    frame = [UInt8](repeating: 0, count: totalCount)
                    frame.replaceSubrange(0..<header.count, with: header)
                    guard fillExact(
                        &frame,
                        range: header.count..<totalCount,
                        deadline: nil
                    ) else { return }
                }
            case .unlink:
                break
            }
            let reply: [UInt8]
            do {
                reply = try server.handleURB(frame, busID: busID, context: context)
            } catch {
                log("USB/IP command rejected: \(error)")
                return
            }
            guard write(reply) else { return }
        }
    }

    @discardableResult
    private func write(_ bytes: [UInt8]) -> Bool {
        do {
            try connection.write(bytes, timeoutNanoseconds: writeTimeoutNanoseconds)
            return true
        } catch {
            if !shouldStop { log("USB/IP response write failed: \(error)") }
            return false
        }
    }

    /// Reads exactly `count` bytes, polling the non-blocking vsock connection with backoff. Returns
    /// nil on EOF (the peer closed with fewer than `count` bytes remaining). "No data yet" is a wait,
    /// not an error, so an idle device is never torn down — only a real peer close ends the loop.
    private func readExact(_ count: Int, deadline: TimeInterval?) -> [UInt8]? {
        guard count >= 0,
              count <= UsbipCommandFraming.fixedHeaderByteCount
                    + Int(UsbipSubmitCommand.maxTransferBytes) else {
            log("USB/IP refused an out-of-range frame allocation of \(count) bytes")
            return nil
        }
        var result = [UInt8](repeating: 0, count: count)
        guard fillExact(&result, range: 0..<count, deadline: deadline) else { return nil }
        return result
    }

    private func fillExact(
        _ bytes: inout [UInt8],
        range: Range<Int>,
        deadline: TimeInterval?
    ) -> Bool {
        guard range.lowerBound >= 0,
              range.upperBound <= bytes.count else { return false }
        var offset = range.lowerBound
        while offset < range.upperBound {
            if shouldStop { return false }
            if let deadline,
               ProcessInfo.processInfo.systemUptime >= deadline {
                log("USB/IP import handshake timed out")
                return false
            }
            let count: Int
            do {
                count = try bytes.withUnsafeMutableBytes { buffer in
                    try connection.read(
                        into: UnsafeMutableRawBufferPointer(
                            rebasing: buffer[offset..<range.upperBound]
                        )
                    )
                }
            } catch {
                if !shouldStop { log("USB/IP stream read failed: \(error)") }
                return false
            }
            // Positive trickle progress must not reset or bypass the whole-handshake deadline.
            if let deadline,
               ProcessInfo.processInfo.systemUptime >= deadline {
                log("USB/IP import handshake timed out")
                return false
            }
            guard count >= 0, count <= range.upperBound - offset else {
                log("USB/IP stream returned an invalid read length of \(count)")
                return false
            }
            if count > 0 {
                offset += count
                continue
            }
            if connection.isPeerClosed { return false }
            let timeoutNanoseconds: UInt64?
            if let deadline {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else {
                    log("USB/IP import handshake timed out")
                    return false
                }
                timeoutNanoseconds = UInt64(min(remaining, 0.05) * 1_000_000_000)
            } else {
                timeoutNanoseconds = 50_000_000
            }
            _ = connection.waitForReadable(timeoutNanoseconds: timeoutNanoseconds)
        }
        return true
    }

    private var shouldStop: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return stopRequested || finished
    }

    private func finish(importedBusID: String?) {
        let completion: (@Sendable () -> Void)?
        stateLock.lock()
        guard !finished else {
            stateLock.unlock()
            return
        }
        finished = true
        completion = onClose
        onClose = nil
        stateLock.unlock()

        server.closeSession(context, busID: importedBusID)
        connection.close()
        completion?()
    }

    deinit {
        requestStop()
    }
}
