import AppKit
import CryptoKit
import Darwin
import DoryMacGuestIntegrationWire
import Foundation
import ImageIO
import SystemConfiguration

extension Notification.Name {
  static let doryGuestToolsOpenUI = Notification.Name("dory.guest-tools.open-ui")
}

/// Runs for the lifetime of Guest Tools, including when its window is closed. Host access is
/// confined to this VM's vsock endpoint; no network address, shared folder or host path is used.
final class DoryGuestIntegrationClient: @unchecked Sendable {
  static let shared = DoryGuestIntegrationClient()

  static var receivedFilesDirectory: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Dory Guest Tools", isDirectory: true)
      .appendingPathComponent("Received Files", isDirectory: true)
  }

  private let lock = NSLock()
  private var started = false
  private var stopping = false
  private var activeDescriptor: Int32?
  private var activeConnectionID: UUID?
  private var activeUserAction: UserActionCompletion?
  private var sessionReady = false
  private var offeredFile: OfferedFile?
  private var userSession = DoryMacGuestIntegrationWire.UserSessionAuthority()

  static func isActiveConsoleUser() -> Bool {
    var uid = uid_t(0), gid = gid_t(0)
    guard SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) != nil else { return false }
    return DoryMacGuestIntegrationWire.UserSessionAuthority.ownsConsoleSession(
      consoleUID: UInt32(uid), effectiveUID: UInt32(geteuid()))
  }

  /// Notification callbacks revoke the socket and queued AppKit actions immediately.
  /// The worker owns final descriptor closure and incomplete-file cleanup as before.
  func setUserSessionActive(_ active: Bool) {
    lock.withLock {
      userSession.transition(active: active)
      sessionReady = false
      activeUserAction?.revoke()
      if let activeDescriptor { _ = shutdown(activeDescriptor, SHUT_RDWR) }
      offeredFile?.close()
      offeredFile = nil
    }
  }

  private func permitsUserSession(_ lease: UUID) -> Bool {
    Self.isActiveConsoleUser() && lock.withLock { !stopping && userSession.permits(lease) }
  }

  private func beginUserAction(
    _ completion: UserActionCompletion, userSessionLease: UUID, descriptor: Int32
  ) -> Bool {
    guard Self.isActiveConsoleUser(), !Self.peerRevoked(descriptor) else {
      completion.revoke()
      return false
    }
    return lock.withLock {
      guard !stopping, sessionReady, activeDescriptor == descriptor,
        activeUserAction === completion else {
        completion.revoke()
        return false
      }
      // Revocation uses this same client -> completion lock order. Do not release the client
      // lock between validating the exact console nonce and claiming the AppKit mutation.
      return completion.beginIfPending(userSession: userSession, lease: userSessionLease)
    }
  }

  private final class OfferedFile {
    let reader: DoryGuestFileOfferReader
    let offer: DoryMacGuestIntegrationWire.FilePullOffer
    let authority: DoryMacGuestIntegrationWire.FileOfferAuthority
    var offset: UInt64 = 0
    var digest = SHA256()

    init(
      url: URL, scoped: Bool, handle: FileHandle,
      offer: DoryMacGuestIntegrationWire.FilePullOffer,
      connectionID: UUID, userSessionLease: UUID
    ) {
      reader = DoryGuestFileOfferReader(handle: handle) {
        if scoped { url.stopAccessingSecurityScopedResource() }
      }
      self.offer = offer
      authority = .init(offerID: offer.offerID, connectionID: connectionID,
        userSessionLease: userSessionLease)
    }

    func close() {
      reader.retire()
    }
  }

  /// Called only after a guest user picks a file. The offer is revoked on disconnect, app
  /// termination, replacement, or completion; no guest filesystem path crosses the wire.
  func offerFileToHost(_ url: URL) throws -> String {
    let owner = lock.withLock { () -> (UUID, UUID)? in
      guard !stopping, sessionReady, let connectionID = activeConnectionID,
        let lease = userSession.lease else { return nil }
      return (connectionID, lease)
    }
    guard let (connectionID, userSessionLease) = owner, Self.isActiveConsoleUser() else {
      throw DoryMacGuestIntegrationWire.WireError.connectionClosed
    }
    let scoped = url.startAccessingSecurityScopedResource()
    var scopeTransferred = false
    defer { if scoped && !scopeTransferred { url.stopAccessingSecurityScopedResource() } }
    let handle = try FileHandle(forReadingFrom: url)
    var handleTransferred = false
    defer { if !handleTransferred { try? handle.close() } }
    var metadata = stat()
    guard fstat(handle.fileDescriptor, &metadata) == 0,
      metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      metadata.st_size >= 0
    else { throw DoryMacGuestIntegrationWire.WireError.invalidEnvelope }
    let offer = try DoryMacGuestIntegrationWire.FilePullOffer(
      offerID: UUID(), name: url.lastPathComponent,
      byteCount: UInt64(metadata.st_size)
    )
    let next = OfferedFile(url: url, scoped: scoped, handle: handle, offer: offer,
      connectionID: connectionID, userSessionLease: userSessionLease)
    // The reader now owns both cleanup responsibilities even if final admission is revoked.
    scopeTransferred = true
    handleTransferred = true
    let admitted = lock.withLock { () -> Bool in
      guard !stopping, sessionReady, activeConnectionID == connectionID,
        userSession.permits(userSessionLease) else { return false }
      offeredFile?.close()
      offeredFile = next
      return true
    }
    guard admitted else { throw DoryMacGuestIntegrationWire.WireError.connectionClosed }
    return offer.name
  }

  func revokeOfferedFile() {
    lock.withLock {
      offeredFile?.close()
      offeredFile = nil
    }
  }

  func start() {
    let shouldStart = lock.withLock { () -> Bool in
      guard !started else { return false }
      started = true
      stopping = false
      return true
    }
    guard shouldStart else { return }
    DispatchQueue.global(qos: .utility).async { [self] in
      while !lock.withLock({ stopping }) {
        do {
          if Self.isActiveConsoleUser(), let lease = lock.withLock({ userSession.lease }) {
            try connectAndServe(userSessionLease: lease)
          }
        } catch {
          // The host may start after login, reset, or replace its VZ socket listener. Reconnect
          // with a bounded delay; never surface a transient absence as a privileged fallback.
        }
        if !lock.withLock({ stopping }) { Thread.sleep(forTimeInterval: 2) }
      }
    }
  }

  func stop() {
    lock.withLock {
      stopping = true
      userSession.transition(active: false)
      sessionReady = false
      activeUserAction?.revoke()
      if let activeDescriptor { _ = shutdown(activeDescriptor, SHUT_RDWR) }
    }
    revokeOfferedFile()
  }

  private func connectAndServe(userSessionLease: UUID) throws {
    let descriptor = try Self.connectToHost()
    let connectionID = UUID()
    let consoleActive = Self.isActiveConsoleUser()
    let admitted = lock.withLock { () -> Bool in
      guard !stopping, userSession.permits(userSessionLease), consoleActive else { return false }
      activeDescriptor = descriptor
      activeConnectionID = connectionID
      return true
    }
    guard admitted else { close(descriptor); return }
    let fileReceiver = FilePushReceiver()
    defer {
      fileReceiver.cancel()
      lock.lock()
      if activeConnectionID == connectionID {
        sessionReady = false
        activeUserAction?.revoke()
        activeUserAction = nil
        if offeredFile?.authority.connectionID == connectionID {
          offeredFile?.close()
          offeredFile = nil
        }
        activeDescriptor = nil
        activeConnectionID = nil
      }
      lock.unlock()
      _ = shutdown(descriptor, SHUT_RDWR)
      close(descriptor)
    }

    let challenge = try DoryMacGuestIntegrationWire.readFrame(from: descriptor)
    guard challenge.kind == .challenge, let nonce = challenge.challengeNonce else {
      throw DoryMacGuestIntegrationWire.WireError.invalidEnvelope
    }
    let bundle = Bundle.main
    let hello = try DoryMacGuestIntegrationWire.Hello(
      bundleIdentifier: bundle.bundleIdentifier ?? "",
      toolsVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
      toolsBuild: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
      offeredCapabilities: DoryMacGuestIntegrationWire.implementedCapabilitiesV2
    )
    try DoryMacGuestIntegrationWire.writeFrame(
      DoryMacGuestIntegrationWire.Envelope(
        kind: .hello, sessionID: challenge.sessionID,
        machineID: challenge.machineID,
        runtimeGeneration: challenge.runtimeGeneration,
        challengeNonce: nonce, hello: hello
      ), to: descriptor
    )
    let opened = try DoryMacGuestIntegrationWire.readFrame(from: descriptor)
    guard opened.kind == .open,
      opened.sessionID == challenge.sessionID,
      opened.machineID == challenge.machineID,
      opened.runtimeGeneration == challenge.runtimeGeneration,
      let grants = opened.grantedCapabilities,
      grants.allSatisfy({ hello.offeredCapabilities.contains($0) }) else {
      throw DoryMacGuestIntegrationWire.WireError.invalidEnvelope
    }
    let stillOwnsConsole = Self.isActiveConsoleUser()
    let openedForActiveUser = lock.withLock { () -> Bool in
      guard !stopping, activeConnectionID == connectionID, activeDescriptor == descriptor,
        userSession.permits(userSessionLease), stillOwnsConsole else { return false }
      sessionReady = true
      return true
    }
    guard openedForActiveUser else { throw DoryMacGuestIntegrationWire.WireError.connectionClosed }

    var lastRequestID: UInt64 = 0
    while !lock.withLock({ stopping }) {
      let request = try DoryMacGuestIntegrationWire.readFrame(from: descriptor)
      let receivedAt = DispatchTime.now().uptimeNanoseconds
      if request.kind == .revoke || request.kind == .close {
        guard Self.matches(request, challenge: challenge) else {
          throw DoryMacGuestIntegrationWire.WireError.invalidEnvelope
        }
        return
      }
      guard request.kind == .request,
        Self.matches(request, challenge: challenge),
        let requestID = request.requestID, requestID > lastRequestID,
        let capability = request.capability,
        request.timeoutMilliseconds != nil else {
        throw DoryMacGuestIntegrationWire.WireError.invalidEnvelope
      }
      lastRequestID = requestID
      let actionAdmission = try DoryMacGuestIntegrationWire.UserActionAdmission(
        request: request, receivedAtUptimeNanoseconds: receivedAt)
      let now = Self.nowMilliseconds()
      var status: DoryMacGuestIntegrationWire.ResponseStatus
      var body: Data?
      if !permitsUserSession(userSessionLease) {
        throw DoryMacGuestIntegrationWire.WireError.connectionClosed
      } else if !grants.contains(capability) {
        status = .denied
      } else if request.isExpired(
        receivedAtUptimeNanoseconds: receivedAt,
        nowUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
      ) {
        status = .expired
      } else {
        switch capability {
        case .health:
          guard request.body == nil else {
            status = .invalidRequest
            break
          }
          let report = try DoryMacGuestIntegrationWire.HealthReport(
            bundleIdentifier: hello.bundleIdentifier,
            toolsVersion: hello.toolsVersion,
            toolsBuild: hello.toolsBuild,
            guestOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            observedAtUnixMilliseconds: now
          )
          let encoder = JSONEncoder()
          encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
          body = try encoder.encode(report)
          status = .success
        case .guestTime:
          guard request.body == nil else {
            status = .invalidRequest
            break
          }
          body = Data(String(now).utf8)
          status = .success
        case .filePush:
          guard let payload = request.body,
            let command = try? DoryMacGuestIntegrationWire.decodeFilePushRequest(payload)
          else {
            fileReceiver.cancel()
            status = .invalidRequest
            break
          }
          do {
            var admission = actionAdmission
            try fileReceiver.apply(command) { mutation in
              try authorizeFileAction(&admission, descriptor: descriptor,
                connectionID: connectionID, userSessionLease: userSessionLease,
                mutation: mutation)
            }
            status = .success
          } catch {
            fileReceiver.cancel()
            if case DoryMacGuestIntegrationWire.WireError.connectionClosed = error { throw error }
            status = error is ExpiredFileAction ? .expired : .invalidRequest
          }
        case .filePull:
          guard let payload = request.body,
            let command = try? DoryMacGuestIntegrationWire.decodeFilePullBody(
              payload, as: DoryMacGuestIntegrationWire.FilePullRequest.self
            ), (try? command.validate()) != nil
          else {
            status = .invalidRequest
            break
          }
          do {
            var admission = actionAdmission
            (status, body) = try applyFilePull(command, admission: &admission,
              descriptor: descriptor, connectionID: connectionID,
              userSessionLease: userSessionLease)
          } catch {
            if case DoryMacGuestIntegrationWire.WireError.connectionClosed = error { throw error }
            status = error is ExpiredFileAction ? .expired : .invalidRequest
          }
        case .openURL:
          if let payload = request.body,
            let command = try? DoryMacGuestIntegrationWire.decodeOpenURLRequest(payload),
            let url = URL(string: command.url)
          {
            let completion = UserActionCompletion(admission: actionAdmission)
            let admitted = lock.withLock { () -> Bool in
              guard !stopping, activeDescriptor == descriptor, userSession.permits(userSessionLease) else { return false }
              activeUserAction = completion
              return true
            }
            if admitted {
              Task { @MainActor in
                if beginUserAction(completion, userSessionLease: userSessionLease, descriptor: descriptor) {
                  completion.finish(
                    status: NSWorkspace.shared.open(url) ? .success : .denied
                  )
                }
              }
              status = completion.wait(descriptor: descriptor).status
              lock.withLock {
                if activeUserAction === completion { activeUserAction = nil }
              }
            } else {
              status = .revoked
            }
          } else {
            status = .invalidRequest
          }
        case .clipboardTextRead:
          guard request.body == nil else {
            status = .invalidRequest
            break
          }
          let completion = UserActionCompletion(admission: actionAdmission)
          let admitted = lock.withLock { () -> Bool in
              guard !stopping, activeDescriptor == descriptor, userSession.permits(userSessionLease) else { return false }
            activeUserAction = completion
            return true
          }
          if admitted {
            Task { @MainActor in
              guard beginUserAction(completion, userSessionLease: userSessionLease, descriptor: descriptor) else { return }
              guard let text = NSPasteboard.general.string(forType: .string),
                let response = try? DoryMacGuestIntegrationWire.ClipboardTextResponse(text: text),
                let encoded = try? DoryMacGuestIntegrationWire.encodeClipboardTextResponse(response)
              else {
                completion.finish(status: .unsupported)
                return
              }
              completion.finish(status: .success, body: encoded)
            }
            let response = completion.wait(descriptor: descriptor)
            status = response.status
            body = response.body
            lock.withLock {
              if activeUserAction === completion { activeUserAction = nil }
            }
          } else {
            status = .revoked
          }
        case .clipboardTextWrite:
          guard let payload = request.body,
            let command = try? DoryMacGuestIntegrationWire.decodeClipboardTextWriteRequest(payload)
          else {
            status = .invalidRequest
            break
          }
          let completion = UserActionCompletion(admission: actionAdmission)
          let admitted = lock.withLock { () -> Bool in
              guard !stopping, activeDescriptor == descriptor, userSession.permits(userSessionLease) else { return false }
            activeUserAction = completion
            return true
          }
          if admitted {
            Task { @MainActor in
              guard beginUserAction(completion, userSessionLease: userSessionLease, descriptor: descriptor) else { return }
              NSPasteboard.general.clearContents()
              completion.finish(
                status: NSPasteboard.general.setString(command.text, forType: .string)
                  ? .success : .denied
              )
            }
            status = completion.wait(descriptor: descriptor).status
            lock.withLock {
              if activeUserAction === completion { activeUserAction = nil }
            }
          } else {
            status = .revoked
          }
        case .clipboardImageRead:
          guard request.body == nil else {
            status = .invalidRequest
            break
          }
          let completion = UserActionCompletion(admission: actionAdmission)
          let admitted = lock.withLock { () -> Bool in
              guard !stopping, activeDescriptor == descriptor, userSession.permits(userSessionLease) else { return false }
            activeUserAction = completion
            return true
          }
          if admitted {
            Task { @MainActor in
              guard beginUserAction(completion, userSessionLease: userSessionLease, descriptor: descriptor) else { return }
              guard let png = Self.readPasteboardPNG() else {
                completion.finish(status: .unsupported)
                return
              }
              completion.finish(status: .success, body: png)
            }
            let response = completion.wait(descriptor: descriptor)
            status = response.status
            body = response.body
            lock.withLock {
              if activeUserAction === completion { activeUserAction = nil }
            }
          } else {
            status = .revoked
          }
        case .clipboardImageWrite:
          guard let png = request.body,
            (try? DoryMacGuestIntegrationWire.validateClipboardPNG(png)) != nil
          else {
            status = .invalidRequest
            break
          }
          let completion = UserActionCompletion(admission: actionAdmission)
          let admitted = lock.withLock { () -> Bool in
              guard !stopping, activeDescriptor == descriptor, userSession.permits(userSessionLease) else { return false }
            activeUserAction = completion
            return true
          }
          if admitted {
            Task { @MainActor in
              if !permitsUserSession(userSessionLease) || Self.peerRevoked(descriptor) {
                completion.revoke()
                return
              }
              guard let image = NSBitmapImageRep(data: png), image.bitmapData != nil else {
                completion.finish(status: .invalidRequest)
                return
              }
              // Decode before claiming the irreversible AppKit action. A timeout, host revoke,
              // or disconnect during decoding must prevent a later pasteboard mutation.
              guard beginUserAction(completion, userSessionLease: userSessionLease, descriptor: descriptor) else { return }
              NSPasteboard.general.clearContents()
              completion.finish(
                status: NSPasteboard.general.setData(png, forType: .png)
                  ? .success : .denied
              )
            }
            status = completion.wait(descriptor: descriptor).status
            lock.withLock {
              if activeUserAction === completion { activeUserAction = nil }
            }
          } else {
            status = .revoked
          }
        default:
          status = .unsupported
        }
      }
      if request.isExpired(
        receivedAtUptimeNanoseconds: receivedAt,
        nowUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
      ) {
        status = .expired
        body = nil
      }
      try DoryMacGuestIntegrationWire.writeFrame(
        DoryMacGuestIntegrationWire.Envelope(
          kind: .response, sessionID: challenge.sessionID,
          machineID: challenge.machineID,
          runtimeGeneration: challenge.runtimeGeneration,
          requestID: requestID, capability: capability,
          status: status, body: body
        ), to: descriptor,
        deadlineUptimeNanoseconds: actionAdmission.deadlineUptimeNanoseconds
      )
    }
  }

  private static func matches(
    _ message: DoryMacGuestIntegrationWire.Envelope,
    challenge: DoryMacGuestIntegrationWire.Envelope
  ) -> Bool {
    message.sessionID == challenge.sessionID
      && message.machineID == challenge.machineID
      && message.runtimeGeneration == challenge.runtimeGeneration
  }

  @MainActor private static func readPasteboardPNG() -> Data? {
    let pasteboard = NSPasteboard.general
    if let png = pasteboard.data(forType: .png),
      png.count <= DoryMacGuestIntegrationWire.maximumImageBytes,
      (try? DoryMacGuestIntegrationWire.validateClipboardPNG(png)) != nil,
      NSBitmapImageRep(data: png)?.bitmapData != nil
    {
      return png
    }
    // Convert only inline TIFF bytes. Never resolve a file URL or pasteboard file promise.
    guard let tiff = pasteboard.data(forType: .tiff),
      let image = Self.boundedInlineTIFF(tiff),
      let png = image.representation(using: .png, properties: [:]),
      (try? DoryMacGuestIntegrationWire.validateClipboardPNG(png)) != nil
    else { return nil }
    return png
  }

  @MainActor private static func boundedInlineTIFF(_ tiff: Data) -> NSBitmapImageRep? {
    guard tiff.count <= DoryMacGuestIntegrationWire.maximumImageBytes,
      let source = CGImageSourceCreateWithData(tiff as CFData, nil),
      CGImageSourceGetCount(source) == 1,
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?,
      let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
      let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
      (1...8_192).contains(width.intValue), (1...8_192).contains(height.intValue),
      Int64(width.intValue) * Int64(height.intValue) <= 16_777_216,
      let image = NSBitmapImageRep(data: tiff), image.bitmapData != nil
    else { return nil }
    return image
  }

  private static func peerRevoked(_ descriptor: Int32) -> Bool {
    var socket = pollfd(
      fd: descriptor,
      events: Int16(POLLIN | POLLHUP | POLLERR),
      revents: 0
    )
    let ready = poll(&socket, 1, 0)
    return ready > 0 ? socket.revents != 0 : ready < 0 && errno != EINTR
  }

  private static func connectToHost() throws -> Int32 {
    let descriptor = socket(AF_VSOCK, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
      throw DoryMacGuestIntegrationWire.WireError.ioFailure(errno)
    }
    do {
      var noSignal: Int32 = 1
      guard setsockopt(
        descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
        socklen_t(MemoryLayout<Int32>.size)
      ) == 0 else { throw DoryMacGuestIntegrationWire.WireError.ioFailure(errno) }
      let originalFlags = fcntl(descriptor, F_GETFL)
      guard originalFlags >= 0, fcntl(descriptor, F_SETFL, originalFlags | O_NONBLOCK) == 0 else {
        throw DoryMacGuestIntegrationWire.WireError.ioFailure(errno)
      }
      var address = sockaddr_vm()
      address.svm_len = UInt8(MemoryLayout<sockaddr_vm>.size)
      address.svm_family = sa_family_t(AF_VSOCK)
      address.svm_port = DoryMacGuestIntegrationWire.port
      address.svm_cid = UInt32(VMADDR_CID_HOST)
      let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_vm>.size))
        }
      }
      if connected != 0 {
        guard errno == EINPROGRESS else {
          throw DoryMacGuestIntegrationWire.WireError.ioFailure(errno)
        }
        var wait = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        guard poll(&wait, 1, 5_000) > 0 else {
          throw DoryMacGuestIntegrationWire.WireError.ioFailure(ETIMEDOUT)
        }
        var result: Int32 = 0
        var resultLength = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &result, &resultLength) == 0,
          result == 0 else {
          throw DoryMacGuestIntegrationWire.WireError.ioFailure(result == 0 ? errno : result)
        }
      }
      guard fcntl(descriptor, F_SETFL, originalFlags) == 0 else {
        throw DoryMacGuestIntegrationWire.WireError.ioFailure(errno)
      }
      var timeout = timeval(tv_sec: 10, tv_usec: 0)
      for option in [SO_RCVTIMEO, SO_SNDTIMEO] {
        guard setsockopt(
          descriptor, SOL_SOCKET, option, &timeout,
          socklen_t(MemoryLayout<timeval>.size)
        ) == 0 else { throw DoryMacGuestIntegrationWire.WireError.ioFailure(errno) }
      }
      return descriptor
    } catch {
      close(descriptor)
      throw error
    }
  }

  private static func nowMilliseconds() -> UInt64 {
    UInt64(max(1, Int64(Date().timeIntervalSince1970 * 1_000)))
  }

  private struct ExpiredFileAction: Error {}

  /// The exact connection and console nonce are checked at the filesystem/offer mutation,
  /// after decoding and (for publication) flushing. No new receive-time budget is minted.
  private func authorizeFileAction<T>(
    _ admission: inout DoryMacGuestIntegrationWire.UserActionAdmission,
    descriptor: Int32, connectionID: UUID, userSessionLease: UUID,
    mutation: () throws -> T
  ) throws -> T {
    guard Self.isActiveConsoleUser(), !Self.peerRevoked(descriptor) else {
      throw DoryMacGuestIntegrationWire.WireError.connectionClosed
    }
    return try lock.withLock {
      guard !stopping, sessionReady, activeDescriptor == descriptor else {
        throw DoryMacGuestIntegrationWire.WireError.connectionClosed
      }
      guard admission.begin(connectionID: connectionID,
        currentConnectionID: activeConnectionID, userSession: userSession,
        lease: userSessionLease, nowUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds)
      else {
        if admission.state == .expired { throw ExpiredFileAction() }
        throw DoryMacGuestIntegrationWire.WireError.connectionClosed
      }
      return try mutation()
    }
  }

  private func applyFilePull(
    _ command: DoryMacGuestIntegrationWire.FilePullRequest,
    admission: inout DoryMacGuestIntegrationWire.UserActionAdmission,
    descriptor: Int32, connectionID: UUID, userSessionLease: UUID
  ) throws -> (DoryMacGuestIntegrationWire.ResponseStatus, Data?) {
    if command.phase == .chunk || command.phase == .finish {
      return try readOfferedFile(command, admission: &admission, descriptor: descriptor,
        connectionID: connectionID, userSessionLease: userSessionLease)
    }
    return try authorizeFileAction(&admission, descriptor: descriptor, connectionID: connectionID,
      userSessionLease: userSessionLease) {
      guard let offeredFile else { return (.denied, nil) }
      // A request for an older selection cannot cancel or consume a successor selection.
      guard offeredFile.authority.permits(command, connectionID: connectionID,
        userSessionLease: userSessionLease) else {
        return (.denied, nil)
      }
      do {
        switch command.phase {
      case .metadata:
        return (.success, try DoryMacGuestIntegrationWire.encodeFilePullBody(
          offeredFile.offer
        ))
      case .chunk, .finish:
        // Sequential file I/O uses a separate lease, never the client/session owner lock.
        throw DoryMacGuestIntegrationWire.WireError.invalidEnvelope
      case .cancel:
        guard command.offerID == offeredFile.offer.offerID else {
          throw DoryMacGuestIntegrationWire.WireError.invalidEnvelope
        }
        self.offeredFile = nil
        offeredFile.close()
        return (.success, nil)
        }
      } catch {
        // Only this exact admitted offer is retired. Never perform delayed global cleanup
        // after releasing the owner lock, where a newly selected file could have replaced it.
        if self.offeredFile === offeredFile {
          self.offeredFile = nil
          offeredFile.close()
        }
        throw error
      }
    }
  }

  private func readOfferedFile(
    _ command: DoryMacGuestIntegrationWire.FilePullRequest,
    admission: inout DoryMacGuestIntegrationWire.UserActionAdmission,
    descriptor: Int32, connectionID: UUID, userSessionLease: UUID
  ) throws -> (DoryMacGuestIntegrationWire.ResponseStatus, Data?) {
    let selected = try authorizeFileAction(&admission, descriptor: descriptor,
      connectionID: connectionID, userSessionLease: userSessionLease) {
      () -> (OfferedFile, UInt64, Int)? in
      guard let offeredFile,
        offeredFile.authority.permits(command, connectionID: connectionID,
          userSessionLease: userSessionLease) else { return nil }
      do {
        let offset = offeredFile.offset
        if command.phase == .chunk {
          guard command.offset == offset, offset < offeredFile.offer.byteCount else {
            throw DoryMacGuestIntegrationWire.WireError.invalidEnvelope
          }
          return (offeredFile, offset, Int(min(
            UInt64(DoryMacGuestIntegrationWire.maximumFileChunkBytes),
            offeredFile.offer.byteCount - offset)))
        }
        guard command.phase == .finish, offset == offeredFile.offer.byteCount else {
          throw DoryMacGuestIntegrationWire.WireError.invalidEnvelope
        }
        return (offeredFile, offset, 1)
      } catch {
        // Validation already selected this exact live offer under the client lock. Retire it
        // on a malformed sequential phase, as before; foreign IDs returned denied above and
        // can never enter this cleanup or discard the user's successor selection.
        if self.offeredFile === offeredFile {
          self.offeredFile = nil
          offeredFile.close()
        }
        throw error
      }
    }
    guard let (source, originalOffset, count) = selected else { return (.denied, nil) }
    do {
      return try source.reader.read({ handle in
        if command.phase == .finish { return try handle.read(upToCount: 1) ?? Data() }
        var data = Data()
        while data.count < count {
          guard let part = try handle.read(upToCount: count - data.count), !part.isEmpty else {
            throw DoryMacGuestIntegrationWire.WireError.invalidEnvelope
          }
          data.append(part)
        }
        return data
      }, authorizeResult: { data in
        guard Self.isActiveConsoleUser(), !Self.peerRevoked(descriptor) else {
          throw DoryMacGuestIntegrationWire.WireError.connectionClosed
        }
        return try lock.withLock {
          guard !stopping, sessionReady, activeDescriptor == descriptor,
            activeConnectionID == connectionID, userSession.permits(userSessionLease) else {
            throw DoryMacGuestIntegrationWire.WireError.connectionClosed
          }
          guard self.offeredFile === source, source.offset == originalOffset,
            source.authority.permits(command, connectionID: connectionID,
              userSessionLease: userSessionLease) else {
            throw DoryMacGuestIntegrationWire.WireError.invalidEnvelope
          }
          let now = DispatchTime.now().uptimeNanoseconds
          guard admission.state == .begun, now >= admission.receivedAtUptimeNanoseconds,
            now < admission.deadlineUptimeNanoseconds else {
            admission.expire()
            throw ExpiredFileAction()
          }
          if command.phase == .chunk {
            source.digest.update(data: data)
            source.offset += UInt64(data.count)
            admission.complete()
            return (.success, data)
          }
          guard data.isEmpty else { throw DoryMacGuestIntegrationWire.WireError.invalidEnvelope }
          let checksum = source.digest.finalize().map { String(format: "%02x", $0) }.joined()
          let digest = try DoryMacGuestIntegrationWire.FilePullDigest(sha256: checksum)
          let body = try DoryMacGuestIntegrationWire.encodeFilePullBody(digest)
          self.offeredFile = nil
          source.close() // Detached cleanup joins this reader's still-active access lease.
          admission.complete()
          return (.success, body)
        }
      })
    } catch {
      lock.withLock {
        // A consumed old descriptor offset is never replayed into a newly selected offer.
        if self.offeredFile === source { self.offeredFile = nil }
        source.close()
      }
      throw error
    }
  }

  /// Only the Guest Tools app's private container is writable. A transfer never interprets its
  /// display name as a path, and a disconnected or invalid stream discards the partial file.
  private final class FilePushReceiver {
    private var transferID: UUID?
    private var expectedBytes: UInt64 = 0
    private var receivedBytes: UInt64 = 0
    private var publication: DoryGuestFilePublication?
    private var digest = SHA256()

    static var receivedDirectory: URL {
      DoryGuestIntegrationClient.receivedFilesDirectory
    }

    func apply(
      _ request: DoryMacGuestIntegrationWire.FilePushRequest,
      authorize: (_ mutation: () throws -> Void) throws -> Void
    ) throws {
      try request.validate()
      switch request.phase {
      case .begin:
        guard transferID == nil, let name = request.name,
          let byteCount = request.byteCount else {
          throw DoryMacGuestIntegrationWire.WireError.invalidEnvelope
        }
        try authorize {
          let publication = try DoryGuestFilePublication(
            directory: Self.receivedDirectory, transferID: request.transferID, name: name
          )
          self.publication = publication
          transferID = request.transferID
          expectedBytes = byteCount
          receivedBytes = 0
          digest = SHA256()
        }
      case .chunk:
        guard transferID == request.transferID, let publication,
          let offset = request.offset, let chunk = request.chunk,
          offset == receivedBytes,
          receivedBytes <= expectedBytes,
          UInt64(chunk.count) <= expectedBytes - receivedBytes
        else { throw DoryMacGuestIntegrationWire.WireError.invalidEnvelope }
        try authorize {
          try publication.output.write(contentsOf: chunk)
          digest.update(data: chunk)
          receivedBytes += UInt64(chunk.count)
        }
      case .commit:
        guard transferID == request.transferID, receivedBytes == expectedBytes,
          let publication, let sha256 = request.sha256,
          digest.finalize().map({ String(format: "%02x", $0) }).joined() == sha256
        else { throw DoryMacGuestIntegrationWire.WireError.invalidEnvelope }
        try publication.publish(authorizePublication: authorize)
        self.publication = nil
        transferID = nil
      case .cancel:
        guard transferID == request.transferID else {
          throw DoryMacGuestIntegrationWire.WireError.invalidEnvelope
        }
        try authorize { cancel() }
      }
    }

    func cancel() {
      publication = nil
      transferID = nil
    }
  }

  private final class UserActionCompletion: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var terminalStatus: DoryMacGuestIntegrationWire.ResponseStatus?
    private var responseBody: Data?
    private var admission: DoryMacGuestIntegrationWire.UserActionAdmission

    init(admission: DoryMacGuestIntegrationWire.UserActionAdmission) {
      self.admission = admission
    }

    func beginIfPending(
      userSession: DoryMacGuestIntegrationWire.UserSessionAuthority, lease: UUID
    ) -> Bool {
      let result = lock.withLock { () -> (Bool, Bool) in
        guard terminalStatus == nil else { return (false, false) }
        if admission.begin(userSession: userSession, lease: lease,
            nowUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds) {
          return (true, false)
        }
        if admission.state == .expired {
          terminalStatus = .expired
          return (false, true)
        }
        if admission.state == .revoked {
          terminalStatus = .revoked
          return (false, true)
        }
        return (false, false)
      }
      if result.1 { semaphore.signal() }
      return result.0
    }

    func finish(
      status: DoryMacGuestIntegrationWire.ResponseStatus, body: Data? = nil
    ) {
      let shouldSignal = lock.withLock { () -> Bool in
        guard terminalStatus == nil else { return false }
        admission.complete()
        terminalStatus = status
        responseBody = body
        return true
      }
      if shouldSignal { semaphore.signal() }
    }

    func revoke() {
      let shouldSignal = lock.withLock { () -> Bool in
        // Once AppKit has begun the action, revocation cannot truthfully undo it. A peer
        // disconnect suppresses only a callback still queued on the main actor.
        guard terminalStatus == nil, admission.revoke() else { return false }
        terminalStatus = .revoked
        return true
      }
      if shouldSignal { semaphore.signal() }
    }

    func wait(
      descriptor: Int32
    ) -> (status: DoryMacGuestIntegrationWire.ResponseStatus, body: Data?) {
      let deadline = lock.withLock { admission.deadlineUptimeNanoseconds }
      while true {
        if let result = lock.withLock({ () -> (
          DoryMacGuestIntegrationWire.ResponseStatus, Data?
        )? in
          guard let terminalStatus else { return nil }
          return (terminalStatus, responseBody)
        }) { return result }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline else {
          return lock.withLock {
            if terminalStatus == nil { admission.expire(); terminalStatus = .expired }
            return (terminalStatus!, responseBody)
          }
        }
        let interval = Int(min(deadline - now, 50_000_000))
        if semaphore.wait(timeout: .now() + .nanoseconds(interval)) == .success {
          continue
        }
        // The host never sends another ordinary request before this response. Readability or
        // hangup here means revoke/close (or a protocol violation), not permission to open later.
        if DoryGuestIntegrationClient.peerRevoked(descriptor) { revoke() }
      }
    }
  }
}

@MainActor
final class DoryGuestToolsLifecycleDelegate: NSObject, NSApplicationDelegate {
  private let integration = DoryGuestIntegrationClient.shared
  private var sessionObservers: [NSObjectProtocol] = []

  func applicationDidFinishLaunching(_ notification: Notification) {
    if ProcessInfo.processInfo.arguments.contains("--integration-agent") {
      NSApp.setActivationPolicy(.accessory)
      NSApp.windows.forEach { $0.orderOut(nil) }
    }
    let center = NSWorkspace.shared.notificationCenter
    let client = integration
    sessionObservers = [
      center.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: nil) { _ in
        client.setUserSessionActive(false)
      },
      center.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: nil) { _ in
        client.setUserSessionActive(DoryGuestIntegrationClient.isActiveConsoleUser())
      },
    ]
    integration.setUserSessionActive(DoryGuestIntegrationClient.isActiveConsoleUser())
    integration.start()
  }

  func applicationShouldHandleReopen(
    _ sender: NSApplication, hasVisibleWindows flag: Bool
  ) -> Bool {
    guard !flag, ProcessInfo.processInfo.arguments.contains("--integration-agent") else {
      return true
    }
    sender.setActivationPolicy(.regular)
    NotificationCenter.default.post(name: .doryGuestToolsOpenUI, object: nil)
    sender.windows.first?.makeKeyAndOrderFront(nil)
    sender.activate(ignoringOtherApps: true)
    return true
  }

  func applicationWillTerminate(_ notification: Notification) {
    let center = NSWorkspace.shared.notificationCenter
    sessionObservers.forEach { center.removeObserver($0) }
    sessionObservers.removeAll()
    integration.stop()
  }
}
