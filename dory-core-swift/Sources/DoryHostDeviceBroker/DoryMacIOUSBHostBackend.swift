import CoreFoundation
import Darwin
import DoryMachinePC
import DoryVMContracts
import Foundation
import IOKit
import IOKit.usb.USB
import IOUSBHost

public enum DoryIOUSBHostCaptureError: Error, Sendable, Equatable {
  case invalidService
  case deviceNotFound
  case discoveryFailed(Int32)
  case identityUnavailable
  case identityMismatch
  case authorizationFailed(Int32)
  case storageMounted
  case captureFailed(Int32)
}

extension DoryIOUSBHostTransferCapability {
  /// Resolves a previously selected stable identity at the last responsible moment and captures
  /// that exact device. Transient bus addresses are deliberately not trusted for reopening.
  public static func capture(
    expectedIdentityToken: DoryUSBPhysicalIdentityToken,
    speed: DoryPCXHCIPortSpeed,
    allowUserInteraction: Bool = true,
    requireUnmountedStorage: Bool = false
  ) throws -> DoryIOUSBHostTransferCapability {
    var iterator: io_iterator_t = 0
    let status = IOServiceGetMatchingServices(
      kIOMainPortDefault,
      IOServiceMatching("IOUSBHostDevice"),
      &iterator
    )
    guard status == kIOReturnSuccess else {
      throw DoryIOUSBHostCaptureError.discoveryFailed(status)
    }
    defer { IOObjectRelease(iterator) }
    while true {
      let service = IOIteratorNext(iterator)
      guard service != 0 else { break }
      defer { IOObjectRelease(service) }
      guard DoryMacUSBIdentity.token(for: service) == expectedIdentityToken else { continue }
      return try capture(
        ioService: service,
        expectedIdentityToken: expectedIdentityToken,
        speed: speed,
        allowUserInteraction: allowUserInteraction,
        requireUnmountedStorage: requireUnmountedStorage
      )
    }
    throw DoryIOUSBHostCaptureError.deviceNotFound
  }

  /// Authorizes and exclusively captures a user-selected physical USB device. The service identity
  /// is re-derived immediately before capture so a stale discovery result cannot attach a different
  /// device that reused a transient USB address.
  public static func capture(
    ioService: io_service_t,
    expectedIdentityToken: DoryUSBPhysicalIdentityToken,
    speed: DoryPCXHCIPortSpeed,
    allowUserInteraction: Bool = true,
    requireUnmountedStorage: Bool = false
  ) throws -> DoryIOUSBHostTransferCapability {
    let backend = try DoryMacIOUSBHostBackend.capture(
      ioService: ioService,
      expectedIdentityToken: expectedIdentityToken,
      allowUserInteraction: allowUserInteraction,
      requireUnmountedStorage: requireUnmountedStorage
    )
    return DoryIOUSBHostTransferCapability(
      identityToken: expectedIdentityToken,
      speed: speed,
      backend: backend
    ) { deadline in
      DoryMacIOUSBHostBackend.reopen(
        expectedIdentityToken: expectedIdentityToken,
        allowUserInteraction: allowUserInteraction,
        requireUnmountedStorage: requireUnmountedStorage,
        deadline: deadline
      )
    }
  }
}

enum DoryMacUSBStorageMountAuthority: Sendable {
  static func provesUnmounted(deviceService: io_registry_entry_t) -> Bool {
    guard deviceService != 0 else { return false }
    let media = mediaBSDNames(below: deviceService)
    guard !media.isEmpty, let mounted = mountedBSDNames() else { return false }
    return media.isDisjoint(with: mounted)
  }

  static func provesUnmounted(
    mediaBSDNames: Set<String>,
    mountedDevicePaths: Set<String>
  ) -> Bool {
    guard !mediaBSDNames.isEmpty else { return false }
    let mounted = Set(mountedDevicePaths.compactMap { path -> String? in
      guard path.hasPrefix("/dev/") else { return nil }
      return String(path.dropFirst(5))
    })
    return mediaBSDNames.isDisjoint(with: mounted)
  }

  private static func mediaBSDNames(below service: io_registry_entry_t) -> Set<String> {
    var iterator: io_iterator_t = 0
    guard IORegistryEntryCreateIterator(
      service,
      kIOServicePlane,
      IOOptionBits(kIORegistryIterateRecursively),
      &iterator
    ) == KERN_SUCCESS else { return [] }
    defer { IOObjectRelease(iterator) }
    var result = Set<String>()
    while true {
      let child = IOIteratorNext(iterator)
      guard child != 0 else { break }
      defer { IOObjectRelease(child) }
      guard IOObjectConformsTo(child, "IOMedia") != 0,
        let value = IORegistryEntryCreateCFProperty(
          child,
          "BSD Name" as CFString,
          kCFAllocatorDefault,
          0
        )?.takeRetainedValue() as? String,
        !value.isEmpty
      else { continue }
      result.insert(value)
    }
    return result
  }

  private static func mountedBSDNames() -> Set<String>? {
    var table: UnsafeMutablePointer<statfs>?
    let count = getmntinfo(&table, MNT_NOWAIT)
    guard count >= 0, let table else { return nil }
    var result = Set<String>()
    for index in 0..<Int(count) {
      var mount = table[index]
      let source = withUnsafePointer(to: &mount.f_mntfromname) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: Int(MNAMELEN)) {
          String(cString: $0)
        }
      }
      if source.hasPrefix("/dev/") {
        result.insert(String(source.dropFirst(5)))
      }
    }
    return result
  }
}

private final class DoryMacIOUSBHostBackend: DoryIOUSBHostOperating, @unchecked Sendable {
  private static let maximumIsochronousTransactionsPerBatch = 1_024
  private static let serviceTerminatedMessage: UInt32 = 0xe000_0010
  private static let deviceRequestingCloseMessage: UInt32 = 0xe000_5003
  private static let hostPipeStalled = IOReturn(bitPattern: 0xe000_5000)
  private static let legacyPipeStalled = IOReturn(bitPattern: 0xe000_404f)

  private let lock = NSLock()
  private let queue = DispatchQueue(label: "com.dory.host-usb.io")
  private let signal: DisconnectSignal
  private var device: IOUSBHostDevice?
  private var interfaces: [UInt8: IOUSBHostInterface] = [:]
  private var pipes: [UInt8: IOUSBHostPipe] = [:]
  private var disconnectHandler: (@Sendable () -> Void)?
  private var closed = false

  var connected: Bool {
    lock.withLock { !closed && !signal.disconnected && device != nil }
  }

  private init(ioService: io_service_t) throws {
    let signal = DisconnectSignal()
    self.signal = signal
    do {
      device = try IOUSBHostDevice(
        __ioService: ioService,
        options: .deviceCapture,
        queue: queue,
        interestHandler: { _, messageType, _ in
          if messageType == Self.serviceTerminatedMessage
            || messageType == Self.deviceRequestingCloseMessage
          {
            signal.markDisconnected(
              surrenderRequested: messageType == Self.deviceRequestingCloseMessage)
          }
        }
      )
    } catch {
      throw DoryIOUSBHostCaptureError.captureFailed(Self.ioReturn(from: error))
    }
    signal.setHandler { [weak self] in self?.notifyDisconnected() }
    try? reloadInterfaces(deadline: .now.advanced(by: .milliseconds(250)))
  }

  static func capture(
    ioService: io_service_t,
    expectedIdentityToken: DoryUSBPhysicalIdentityToken,
    allowUserInteraction: Bool,
    requireUnmountedStorage: Bool
  ) throws -> DoryMacIOUSBHostBackend {
    guard ioService != 0 else { throw DoryIOUSBHostCaptureError.invalidService }
    guard let token = DoryMacUSBIdentity.token(for: ioService) else {
      throw DoryIOUSBHostCaptureError.identityUnavailable
    }
    guard token == expectedIdentityToken else {
      throw DoryIOUSBHostCaptureError.identityMismatch
    }
    let options = allowUserInteraction ? UInt32(kIOServiceInteractionAllowed) : 0
    let authorization = IOServiceAuthorize(ioService, options)
    guard authorization == kIOReturnSuccess else {
      throw DoryIOUSBHostCaptureError.authorizationFailed(authorization)
    }
    guard DoryMacUSBIdentity.token(for: ioService) == expectedIdentityToken else {
      throw DoryIOUSBHostCaptureError.identityMismatch
    }
    guard !requireUnmountedStorage
      || DoryMacUSBStorageMountAuthority.provesUnmounted(deviceService: ioService)
    else {
      throw DoryIOUSBHostCaptureError.storageMounted
    }
    return try DoryMacIOUSBHostBackend(ioService: ioService)
  }

  static func reopen(
    expectedIdentityToken: DoryUSBPhysicalIdentityToken,
    allowUserInteraction: Bool,
    requireUnmountedStorage: Bool,
    deadline: ContinuousClock.Instant
  ) -> DoryMacIOUSBHostBackend? {
    while ContinuousClock.now < deadline {
      var iterator: io_iterator_t = 0
      if IOServiceGetMatchingServices(
        kIOMainPortDefault,
        IOServiceMatching("IOUSBHostDevice"),
        &iterator
      ) == kIOReturnSuccess {
        defer { IOObjectRelease(iterator) }
        while true {
          let service = IOIteratorNext(iterator)
          guard service != 0 else { break }
          defer { IOObjectRelease(service) }
          guard DoryMacUSBIdentity.token(for: service) == expectedIdentityToken else { continue }
          if let backend = try? capture(
            ioService: service,
            expectedIdentityToken: expectedIdentityToken,
            allowUserInteraction: allowUserInteraction,
            requireUnmountedStorage: requireUnmountedStorage
          ) {
            return backend
          }
        }
      }
      Thread.sleep(forTimeInterval: 0.02)
    }
    return nil
  }

  func setDisconnectHandler(_ handler: (@Sendable () -> Void)?) {
    lock.withLock { disconnectHandler = handler }
  }

  func sendControl(
    _ request: DoryIOUSBHostControlRequest,
    payload: [UInt8],
    maximumResponseBytes: Int,
    deadline: ContinuousClock.Instant
  ) throws -> DoryIOUSBHostCompletion {
    let device = try currentDevice()
    let inbound = request.requestType & 0x80 != 0
    let requestedBytes = inbound ? maximumResponseBytes : min(payload.count, Int(request.length))
    let data =
      inbound
      ? NSMutableData(length: requestedBytes)
      : NSMutableData(bytes: payload, length: requestedBytes)
    var bytesTransferred = 0
    let nativeRequest = IOUSBDeviceRequest(
      bmRequestType: request.requestType,
      bRequest: request.request,
      wValue: request.value,
      wIndex: request.index,
      wLength: UInt16(requestedBytes)
    )
    do {
      try device.__send(
        nativeRequest,
        data: data,
        bytesTransferred: &bytesTransferred,
        completionTimeout: try Self.remainingSeconds(until: deadline)
      )
    } catch {
      throw Self.operationError(from: error)
    }
    let response = inbound ? Self.bytes(from: data, count: bytesTransferred) : []
    return .init(payload: response, bytesTransferred: bytesTransferred)
  }

  func sendData(
    type: DoryPCUSBTransferType,
    endpointAddress: UInt8,
    payload: [UInt8],
    maximumResponseBytes: Int,
    deadline: ContinuousClock.Instant
  ) throws -> DoryIOUSBHostCompletion {
    guard type != .control else {
      throw DoryIOUSBHostOperationError.transactionFailed(kIOReturnBadArgument)
    }
    let pipe = try pipe(withAddress: endpointAddress, deadline: deadline)
    if type == .isochronous {
      return try sendIsochronous(
        pipe: pipe,
        endpointAddress: endpointAddress,
        payload: payload,
        maximumResponseBytes: maximumResponseBytes,
        deadline: deadline
      )
    }
    let inbound = endpointAddress & 0x80 != 0
    let length = inbound ? maximumResponseBytes : payload.count
    let data =
      inbound
      ? NSMutableData(length: length)
      : NSMutableData(bytes: payload, length: length)
    let completion = AsyncCompletion()
    do {
      try pipe.enqueueIORequest(with: data, completionTimeout: 0) { status, count in
        completion.finish(status: status, bytesTransferred: count)
      }
    } catch {
      throw Self.operationError(from: error)
    }
    try wait(for: completion, aborting: pipe, deadline: deadline)
    let outcome = completion.outcome
    try Self.throwIfFailed(outcome.status)
    let response = inbound ? Self.bytes(from: data, count: outcome.bytesTransferred) : []
    return .init(payload: response, bytesTransferred: outcome.bytesTransferred)
  }

  func configure(value: UInt8, deadline: ContinuousClock.Instant) throws {
    _ = try Self.remainingSeconds(until: deadline)
    destroyInterfaces()
    do {
      try currentDevice().__configure(withValue: Int(value), matchInterfaces: true)
      if value != 0 { try reloadInterfaces(deadline: deadline) }
    } catch {
      throw Self.operationError(from: error)
    }
  }

  func selectAlternateSetting(
    interface: UInt8,
    alternateSetting: UInt8,
    deadline: ContinuousClock.Instant
  ) throws {
    var hostInterface = lock.withLock { interfaces[interface] }
    if hostInterface == nil {
      try reloadInterfaces(deadline: deadline)
      hostInterface = lock.withLock { interfaces[interface] }
    }
    guard let hostInterface else { throw DoryIOUSBHostOperationError.unavailable }
    do {
      try hostInterface.selectAlternateSetting(Int(alternateSetting))
      lock.withLock { pipes.removeAll() }
    } catch {
      throw Self.operationError(from: error)
    }
  }

  func clearStall(endpointAddress: UInt8, deadline: ContinuousClock.Instant) throws {
    do {
      try pipe(withAddress: endpointAddress, deadline: deadline).clearStall()
    } catch let error as DoryIOUSBHostOperationError {
      throw error
    } catch {
      throw Self.operationError(from: error)
    }
  }

  func reset(deadline: ContinuousClock.Instant) throws {
    _ = try Self.remainingSeconds(until: deadline)
    do {
      try currentDevice().reset()
      signal.markDisconnected(surrenderRequested: false)
    } catch {
      throw Self.operationError(from: error)
    }
  }

  func abortAll() {
    let resources = lock.withLock { (device, Array(pipes.values)) }
    try? resources.0?.__abortDeviceRequests(with: .synchronous)
    for pipe in resources.1 { try? pipe.__abort(with: .synchronous) }
  }

  func close() {
    let resources = lock.withLock { () -> (IOUSBHostDevice?, [IOUSBHostInterface]) in
      guard !closed else { return (nil, []) }
      closed = true
      let oldDevice = device
      let oldInterfaces = Array(interfaces.values)
      device = nil
      interfaces.removeAll()
      pipes.removeAll()
      disconnectHandler = nil
      return (oldDevice, oldInterfaces)
    }
    for hostInterface in resources.1 { hostInterface.destroy() }
    if signal.surrenderRequested {
      resources.0?.destroy(options: .deviceSurrender)
    } else {
      resources.0?.destroy()
    }
  }

  private func sendIsochronous(
    pipe: IOUSBHostPipe,
    endpointAddress: UInt8,
    payload: [UInt8],
    maximumResponseBytes: Int,
    deadline: ContinuousClock.Instant
  ) throws -> DoryIOUSBHostCompletion {
    let inbound = endpointAddress & 0x80 != 0
    let totalBytes = inbound ? maximumResponseBytes : payload.count
    guard totalBytes > 0 else { return .init(payload: [], bytesTransferred: 0) }
    let transactionBytes = Self.maximumIsochronousTransactionBytes(pipe)
    var offset = 0
    var transferred = 0
    var response: [UInt8] = []
    while offset < totalBytes {
      _ = try Self.remainingSeconds(until: deadline)
      let batchCapacity = transactionBytes * Self.maximumIsochronousTransactionsPerBatch
      let batchBytes = min(totalBytes - offset, batchCapacity)
      let batchPayload = inbound ? [] : Array(payload[offset..<(offset + batchBytes)])
      let completion = try sendIsochronousBatch(
        pipe: pipe,
        inbound: inbound,
        payload: batchPayload,
        requestedBytes: batchBytes,
        transactionBytes: transactionBytes,
        deadline: deadline
      )
      transferred += completion.bytesTransferred
      response.append(contentsOf: completion.payload)
      offset += batchBytes
      if completion.bytesTransferred < batchBytes { break }
    }
    return .init(payload: response, bytesTransferred: transferred)
  }

  private func sendIsochronousBatch(
    pipe: IOUSBHostPipe,
    inbound: Bool,
    payload: [UInt8],
    requestedBytes: Int,
    transactionBytes: Int,
    deadline: ContinuousClock.Instant
  ) throws -> DoryIOUSBHostCompletion {
    let data =
      inbound
      ? NSMutableData(length: requestedBytes)!
      : NSMutableData(bytes: payload, length: requestedBytes)
    var transactions: [IOUSBHostIsochronousTransaction] = []
    var offset = 0
    while offset < requestedBytes {
      let count = min(transactionBytes, requestedBytes - offset)
      transactions.append(
        .init(
          status: kIOReturnInvalid,
          requestCount: UInt32(count),
          offset: UInt32(offset),
          completeCount: 0,
          timeStamp: 0,
          options: []
        )
      )
      offset += count
    }
    let completion = AsyncIsochronousCompletion()
    let transactionStorage = IsochronousTransactionStorage(transactions)
    do {
      try pipe.enqueueIORequest(
        with: data,
        transactionList: transactionStorage.pointer,
        transactionListCount: transactionStorage.count,
        firstFrameNumber: 0,
        options: []
      ) { status, completed in
        let counts = (0..<transactionStorage.count).map { completed[$0].completeCount }
        let statuses = (0..<transactionStorage.count).map { completed[$0].status }
        completion.finish(status: status, counts: counts, transactionStatuses: statuses)
      }
    } catch {
      throw Self.operationError(from: error)
    }
    try wait(for: completion, aborting: pipe, deadline: deadline)
    let outcome = completion.outcome
    try Self.throwIfFailed(outcome.status)
    if let failure = outcome.transactionStatuses.first(where: { $0 != kIOReturnSuccess }) {
      try Self.throwIfFailed(failure)
    }
    let bytesTransferred = outcome.counts.reduce(0) { $0 + Int($1) }
    let response = inbound ? Self.bytes(from: data, count: bytesTransferred) : []
    return .init(payload: response, bytesTransferred: bytesTransferred)
  }

  private func pipe(
    withAddress address: UInt8,
    deadline: ContinuousClock.Instant
  ) throws -> IOUSBHostPipe {
    if let cached = lock.withLock({ pipes[address] }) { return cached }
    while ContinuousClock.now < deadline {
      let candidates = lock.withLock { Array(interfaces.values) }
      for hostInterface in candidates {
        if let pipe = try? hostInterface.copyPipe(withAddress: Int(address)) {
          lock.withLock { pipes[address] = pipe }
          return pipe
        }
      }
      try reloadInterfaces(deadline: min(deadline, .now.advanced(by: .milliseconds(50))))
      Thread.sleep(forTimeInterval: 0.005)
    }
    throw DoryIOUSBHostOperationError.unavailable
  }

  private func reloadInterfaces(deadline: ContinuousClock.Instant) throws {
    guard let device = lock.withLock({ device }), !signal.disconnected else {
      throw DoryIOUSBHostOperationError.disconnected
    }
    var opened: [UInt8: IOUSBHostInterface] = [:]
    repeat {
      var iterator: io_iterator_t = 0
      let status = IORegistryEntryGetChildIterator(device.ioService, kIOServicePlane, &iterator)
      guard status == kIOReturnSuccess else {
        throw DoryIOUSBHostOperationError.transactionFailed(status)
      }
      while true {
        let service = IOIteratorNext(iterator)
        guard service != 0 else { break }
        defer { IOObjectRelease(service) }
        if let hostInterface = try? IOUSBHostInterface(
          __ioService: service,
          options: [],
          queue: queue,
          interestHandler: nil
        ) {
          opened[hostInterface.interfaceDescriptor.pointee.bInterfaceNumber] = hostInterface
        }
      }
      IOObjectRelease(iterator)
      if !opened.isEmpty || ContinuousClock.now >= deadline { break }
      Thread.sleep(forTimeInterval: 0.005)
    } while true
    let old = lock.withLock { () -> [IOUSBHostInterface] in
      let value = Array(interfaces.values)
      interfaces = opened
      pipes.removeAll()
      return value
    }
    for hostInterface in old { hostInterface.destroy() }
  }

  private func destroyInterfaces() {
    let old = lock.withLock { () -> [IOUSBHostInterface] in
      let value = Array(interfaces.values)
      interfaces.removeAll()
      pipes.removeAll()
      return value
    }
    for hostInterface in old { hostInterface.destroy() }
  }

  private func currentDevice() throws -> IOUSBHostDevice {
    guard let device = lock.withLock({ closed || signal.disconnected ? nil : device }) else {
      throw DoryIOUSBHostOperationError.disconnected
    }
    return device
  }

  private func wait(
    for completion: AsyncCompletion,
    aborting pipe: IOUSBHostPipe,
    deadline: ContinuousClock.Instant
  ) throws {
    guard completion.wait(until: deadline) else {
      try? pipe.__abort(with: .synchronous)
      _ = completion.waitForAbort()
      throw DoryIOUSBHostOperationError.deadlineExpired
    }
  }

  private func wait(
    for completion: AsyncIsochronousCompletion,
    aborting pipe: IOUSBHostPipe,
    deadline: ContinuousClock.Instant
  ) throws {
    guard completion.wait(until: deadline) else {
      try? pipe.__abort(with: .synchronous)
      _ = completion.waitForAbort()
      throw DoryIOUSBHostOperationError.deadlineExpired
    }
  }

  private func notifyDisconnected() {
    let handler = lock.withLock { disconnectHandler }
    handler?()
  }

  private static func maximumIsochronousTransactionBytes(_ pipe: IOUSBHostPipe) -> Int {
    let descriptors = pipe.descriptors.pointee
    let packet = Int(UInt16(littleEndian: descriptors.descriptor.wMaxPacketSize))
    var maximum = (packet & 0x7ff) * (((packet >> 11) & 0x3) + 1)
    if UInt16(littleEndian: descriptors.bcdUSB) >= 0x0300 {
      let superSpeed = Int(
        UInt16(littleEndian: descriptors.ssCompanionDescriptor.wBytesPerInterval))
      if superSpeed > 0 { maximum = superSpeed }
      let plus = Int(
        UInt32(littleEndian: descriptors.sspCompanionDescriptor.dwBytesPerInterval))
      if plus > 0 { maximum = plus }
    }
    return min(max(maximum, 1), DoryPCUSBDeviceLimits.maximumTransferBytes)
  }

  private static func remainingSeconds(
    until deadline: ContinuousClock.Instant
  ) throws -> TimeInterval {
    let duration = ContinuousClock.now.duration(to: deadline)
    let components = duration.components
    let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
    guard seconds > 0 else { throw DoryIOUSBHostOperationError.deadlineExpired }
    return seconds
  }

  fileprivate static func dispatchDeadline(
    _ deadline: ContinuousClock.Instant
  ) -> DispatchTime {
    let duration = ContinuousClock.now.duration(to: deadline).components
    let nanoseconds = max(
      0,
      duration.seconds * 1_000_000_000 + duration.attoseconds / 1_000_000_000
    )
    return .now() + .nanoseconds(Int(clamping: nanoseconds))
  }

  private static func bytes(from data: NSMutableData?, count: Int) -> [UInt8] {
    guard let data, count > 0 else { return [] }
    return Array(Data(bytes: data.bytes, count: min(count, data.length)))
  }

  private static func throwIfFailed(_ status: IOReturn) throws {
    guard status == kIOReturnSuccess else {
      switch status {
      case hostPipeStalled, legacyPipeStalled: throw DoryIOUSBHostOperationError.stalled
      case kIOReturnNoDevice, kIOReturnNotOpen, kIOReturnNotAttached:
        throw DoryIOUSBHostOperationError.disconnected
      case kIOReturnTimeout: throw DoryIOUSBHostOperationError.deadlineExpired
      default: throw DoryIOUSBHostOperationError.transactionFailed(status)
      }
    }
  }

  private static func operationError(from error: Error) -> DoryIOUSBHostOperationError {
    if let error = error as? DoryIOUSBHostOperationError { return error }
    let code = ioReturn(from: error)
    switch code {
    case hostPipeStalled, legacyPipeStalled: return .stalled
    case kIOReturnNoDevice, kIOReturnNotOpen, kIOReturnNotAttached: return .disconnected
    case kIOReturnTimeout: return .deadlineExpired
    default: return .transactionFailed(code)
    }
  }

  private static func ioReturn(from error: Error) -> IOReturn {
    IOReturn(truncatingIfNeeded: (error as NSError).code)
  }
}

private final class DisconnectSignal: @unchecked Sendable {
  private let lock = NSLock()
  private var disconnectedStorage = false
  private var surrenderStorage = false
  private var handler: (@Sendable () -> Void)?

  var disconnected: Bool { lock.withLock { disconnectedStorage } }
  var surrenderRequested: Bool { lock.withLock { surrenderStorage } }

  func setHandler(_ handler: (@Sendable () -> Void)?) {
    lock.withLock { self.handler = handler }
  }

  func markDisconnected(surrenderRequested: Bool) {
    let handler = lock.withLock { () -> (@Sendable () -> Void)? in
      disconnectedStorage = true
      surrenderStorage = surrenderStorage || surrenderRequested
      return self.handler
    }
    handler?()
  }
}

private final class IsochronousTransactionStorage: @unchecked Sendable {
  let pointer: UnsafeMutablePointer<IOUSBHostIsochronousTransaction>
  let count: Int

  init(_ transactions: [IOUSBHostIsochronousTransaction]) {
    count = transactions.count
    pointer = .allocate(capacity: count)
    pointer.initialize(from: transactions, count: count)
  }

  deinit {
    pointer.deinitialize(count: count)
    pointer.deallocate()
  }
}

private class AsyncCompletion: @unchecked Sendable {
  private let lock = NSLock()
  private let semaphore = DispatchSemaphore(value: 0)
  private var storage: (status: IOReturn, bytesTransferred: Int) = (kIOReturnInvalid, 0)

  var outcome: (status: IOReturn, bytesTransferred: Int) { lock.withLock { storage } }

  func finish(status: IOReturn, bytesTransferred: Int) {
    lock.withLock { storage = (status, bytesTransferred) }
    semaphore.signal()
  }

  func wait(until deadline: ContinuousClock.Instant) -> Bool {
    semaphore.wait(timeout: DoryMacIOUSBHostBackend.dispatchDeadline(deadline)) == .success
  }

  func waitForAbort() -> Bool {
    semaphore.wait(timeout: .now() + .seconds(1)) == .success
  }
}

private final class AsyncIsochronousCompletion: @unchecked Sendable {
  private let lock = NSLock()
  private let semaphore = DispatchSemaphore(value: 0)
  private var storage: (status: IOReturn, counts: [UInt32], transactionStatuses: [IOReturn]) = (
    kIOReturnInvalid, [], []
  )

  var outcome: (status: IOReturn, counts: [UInt32], transactionStatuses: [IOReturn]) {
    lock.withLock { storage }
  }

  func finish(status: IOReturn, counts: [UInt32], transactionStatuses: [IOReturn]) {
    lock.withLock { storage = (status, counts, transactionStatuses) }
    semaphore.signal()
  }

  func wait(until deadline: ContinuousClock.Instant) -> Bool {
    semaphore.wait(timeout: DoryMacIOUSBHostBackend.dispatchDeadline(deadline)) == .success
  }

  func waitForAbort() -> Bool {
    semaphore.wait(timeout: .now() + .seconds(1)) == .success
  }
}

private enum DoryMacUSBIdentity {
  static func token(for service: io_registry_entry_t) -> DoryUSBPhysicalIdentityToken? {
    var unmanaged: Unmanaged<CFMutableDictionary>?
    guard
      IORegistryEntryCreateCFProperties(
        service, &unmanaged, kCFAllocatorDefault, 0
      ) == kIOReturnSuccess,
      let properties = unmanaged?.takeRetainedValue() as? [String: Any],
      let locationID = uint32(properties, ["locationID", "LocationID", "USB LocationID"]),
      let vendorID = uint32(properties, ["idVendor", "USB Vendor ID"]).flatMap(
        UInt16.init(exactly:)),
      let productID = uint32(properties, ["idProduct", "USB Product ID"]).flatMap(
        UInt16.init(exactly:)),
      let revision = UInt16(
        exactly: uint32(properties, ["bcdDevice", "USB Product Revision"]) ?? 0),
      let identity = try? DoryUSBPhysicalIdentity(
        locationID: locationID,
        vendorID: vendorID,
        productID: productID,
        bcdDevice: revision,
        serialNumber: string(
          properties,
          ["USB Serial Number", "kUSBSerialNumberString", "iSerialNumber"]
        )
      )
    else { return nil }
    return identity.token
  }

  private static func string(_ properties: [String: Any], _ keys: [String]) -> String {
    for key in keys {
      guard let value = properties[key] as? String,
        value.utf8.count <= DoryUSBPhysicalIdentity.maximumSerialNumberUTF8Bytes,
        !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
      else { continue }
      return value
    }
    return ""
  }

  private static func uint32(_ properties: [String: Any], _ keys: [String]) -> UInt32? {
    for key in keys {
      guard let raw = properties[key] else { continue }
      if let value = raw as? NSNumber,
        CFGetTypeID(value) != CFBooleanGetTypeID(),
        value.doubleValue.isFinite,
        value.doubleValue >= 0,
        value.doubleValue.rounded(.towardZero) == value.doubleValue,
        value.uint64Value <= UInt64(UInt32.max)
      {
        return UInt32(value.uint64Value)
      }
      if let value = raw as? String {
        if value.lowercased().hasPrefix("0x"),
          let parsed = UInt32(value.dropFirst(2), radix: 16)
        {
          return parsed
        }
        if let parsed = UInt32(value) { return parsed }
      }
    }
    return nil
  }
}
