import DoryMachinePC
import DoryVMContracts
import Foundation
import Testing

@testable import DoryHostDeviceBroker

@Suite struct DoryIOUSBHostTransferCapabilityTests {
  @Test func storageMountAuthorityRequiresMediaAndRejectsAnyMountedDescendant() {
    #expect(!DoryMacUSBStorageMountAuthority.provesUnmounted(
      mediaBSDNames: [],
      mountedDevicePaths: []
    ))
    #expect(!DoryMacUSBStorageMountAuthority.provesUnmounted(
      mediaBSDNames: ["disk7", "disk7s1"],
      mountedDevicePaths: ["/dev/disk7s1"]
    ))
    #expect(DoryMacUSBStorageMountAuthority.provesUnmounted(
      mediaBSDNames: ["disk7", "disk7s1"],
      mountedDevicePaths: ["map auto_home", "/dev/disk3s1"]
    ))
  }

  @Test func mapsEndpointDirectionAndShortPackets() throws {
    let backend = RecordingIOUSBHostBackend()
    backend.completion = .init(payload: [1, 2, 3], bytesTransferred: 3)
    let capability = makeCapability(backend)
    let transfer = try DoryPCUSBTransfer(
      type: .bulk,
      direction: .in,
      endpoint: 5,
      maximumResponseBytes: 8
    )

    let result = capability.perform(transfer, deadline: .now.advanced(by: .seconds(1)))

    #expect(result.status == .shortPacket)
    #expect(result.payload == [1, 2, 3])
    #expect(backend.dataRequests == [.init(type: .bulk, endpoint: 0x85)])
  }

  @Test func mapsGeneralControlRequestsAndBoundsTheirDataPhase() throws {
    let backend = RecordingIOUSBHostBackend()
    backend.completion = .init(payload: [9, 8, 7, 6], bytesTransferred: 4)
    let capability = makeCapability(backend)
    let setup = try DoryPCUSBSetupPacket(bytes: [0xC0, 0x55, 0x34, 0x12, 2, 0, 4, 0])
    let transfer = try DoryPCUSBTransfer(
      type: .control,
      direction: .in,
      endpoint: 0,
      setup: setup,
      maximumResponseBytes: 32
    )

    let result = capability.perform(transfer, deadline: .now.advanced(by: .seconds(1)))

    #expect(result.status == .success)
    #expect(result.payload == [9, 8, 7, 6])
    #expect(
      backend.controlRequests == [
        .init(requestType: 0xC0, request: 0x55, value: 0x1234, index: 2, length: 4)
      ]
    )
    #expect(backend.controlResponseLengths == [4])
  }

  @Test func ownsConfigurationAlternateSettingAndEndpointHaltSideEffects() throws {
    let backend = RecordingIOUSBHostBackend()
    let capability = makeCapability(backend)
    let requests: [[UInt8]] = [
      [0x00, 9, 3, 0, 0, 0, 0, 0],
      [0x01, 11, 2, 0, 4, 0, 0, 0],
      [0x02, 1, 0, 0, 0x83, 0, 0, 0],
    ]

    for bytes in requests {
      let transfer = try DoryPCUSBTransfer(
        type: .control,
        direction: .out,
        endpoint: 0,
        setup: try .init(bytes: bytes)
      )
      #expect(
        capability.perform(transfer, deadline: .now.advanced(by: .seconds(1))).status
          == .success
      )
    }

    #expect(backend.configurations == [3])
    #expect(backend.alternateSettings == [.init(interface: 4, setting: 2)])
    #expect(backend.clearedEndpoints == [0x83])
    #expect(backend.controlRequests.isEmpty)
  }

  @Test func mapsTransportFailuresAndPropagatesPhysicalRevocation() throws {
    let backend = RecordingIOUSBHostBackend()
    let capability = makeCapability(backend)
    let revoked = LockedFlag()
    capability.setRevocationHandler { revoked.set() }
    let transfer = try DoryPCUSBTransfer(
      type: .interrupt,
      direction: .out,
      endpoint: 1,
      payload: [1]
    )

    backend.error = .stalled
    #expect(
      capability.perform(transfer, deadline: .now.advanced(by: .seconds(1))).status == .stalled
    )
    backend.disconnect()
    #expect(revoked.value)
    #expect(
      capability.perform(transfer, deadline: .now.advanced(by: .seconds(1))).status
        == .disconnected
    )
  }

  private func makeCapability(
    _ backend: RecordingIOUSBHostBackend
  ) -> DoryIOUSBHostTransferCapability {
    DoryIOUSBHostTransferCapability(
      identityToken: DoryUSBPhysicalIdentityToken(rawValue: String(repeating: "a", count: 64))!,
      speed: .high,
      backend: backend
    )
  }
}

private final class LockedFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = false
  var value: Bool { lock.withLock { storage } }
  func set() { lock.withLock { storage = true } }
}

private final class RecordingIOUSBHostBackend: DoryIOUSBHostOperating, @unchecked Sendable {
  struct DataRequest: Sendable, Hashable {
    let type: DoryPCUSBTransferType
    let endpoint: UInt8
  }

  struct AlternateSetting: Sendable, Hashable {
    let interface: UInt8
    let setting: UInt8
  }

  private let lock = NSLock()
  var completion = DoryIOUSBHostCompletion(payload: [], bytesTransferred: 0)
  var error: DoryIOUSBHostOperationError?
  private var connectedStorage = true
  private var disconnectHandler: (@Sendable () -> Void)?
  private(set) var controlRequests: [DoryIOUSBHostControlRequest] = []
  private(set) var controlResponseLengths: [Int] = []
  private(set) var dataRequests: [DataRequest] = []
  private(set) var configurations: [UInt8] = []
  private(set) var alternateSettings: [AlternateSetting] = []
  private(set) var clearedEndpoints: [UInt8] = []

  var connected: Bool { lock.withLock { connectedStorage } }

  func setDisconnectHandler(_ handler: (@Sendable () -> Void)?) {
    lock.withLock { disconnectHandler = handler }
  }

  func sendControl(
    _ request: DoryIOUSBHostControlRequest,
    payload: [UInt8],
    maximumResponseBytes: Int,
    deadline: ContinuousClock.Instant
  ) throws -> DoryIOUSBHostCompletion {
    controlRequests.append(request)
    controlResponseLengths.append(maximumResponseBytes)
    if let error { throw error }
    return completion
  }

  func sendData(
    type: DoryPCUSBTransferType,
    endpointAddress: UInt8,
    payload: [UInt8],
    maximumResponseBytes: Int,
    deadline: ContinuousClock.Instant
  ) throws -> DoryIOUSBHostCompletion {
    dataRequests.append(.init(type: type, endpoint: endpointAddress))
    if let error { throw error }
    return completion
  }

  func configure(value: UInt8, deadline: ContinuousClock.Instant) throws {
    configurations.append(value)
  }

  func selectAlternateSetting(
    interface: UInt8,
    alternateSetting: UInt8,
    deadline: ContinuousClock.Instant
  ) throws {
    alternateSettings.append(.init(interface: interface, setting: alternateSetting))
  }

  func clearStall(endpointAddress: UInt8, deadline: ContinuousClock.Instant) throws {
    clearedEndpoints.append(endpointAddress)
  }

  func reset(deadline: ContinuousClock.Instant) throws {}
  func abortAll() {}
  func close() { lock.withLock { connectedStorage = false } }

  func disconnect() {
    let handler = lock.withLock { () -> (@Sendable () -> Void)? in
      connectedStorage = false
      return disconnectHandler
    }
    handler?()
  }
}
