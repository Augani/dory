import DoryVirtio
import Foundation
import Testing

@Suite struct DoryVirtioGPUTests {
  @Test func publishesDisplayConfigurationAndDisplayInfo() throws {
    let device = try makeDevice()
    #expect(read32(device.configuration, 8) == 2)
    #expect(read32(device.configuration, 12) == 0)
    #expect(!device.offeredFeatures.contains(.gpuVirgl))
    let memory = GPUGuestMemory(byteCount: 0x5000)
    let response = try command(
      device,
      bytes: header(0x0100),
      responseBytes: 24 + 16 * 24,
      memory: memory
    )
    #expect(read32(response, 0) == 0x1101)
    #expect(read32(response, 24 + 8) == 800)
    #expect(read32(response, 24 + 12) == 600)
    #expect(read32(response, 24 + 16) == 1)
    #expect(read32(response, 48 + 8) == 1_920)
    #expect(read32(response, 48 + 12) == 1_080)
  }

  @Test func retainsBoundedCommandDiagnosticsAcrossReset() throws {
    let device = try makeDevice()
    let memory = GPUGuestMemory(byteCount: 0x5000)

    for _ in 0..<70 {
      _ = try command(
        device,
        bytes: header(0x0100),
        responseBytes: 24 + 16 * 24,
        memory: memory
      )
    }
    _ = try command(device, bytes: header(0xFFFF_FFFF), memory: memory)
    device.reset()

    let diagnostics = device.commandDiagnostics
    #expect(diagnostics.completedCommandCount == 71)
    #expect(diagnostics.failedCommandCount == 0)
    #expect(diagnostics.resetCount == 1)
    #expect(diagnostics.recentCommands.count == 64)
    #expect(diagnostics.recentCommands.first?.sequenceNumber == 8)
    #expect(diagnostics.recentCommands.last?.requestType == 0xFFFF_FFFF)
    #expect(diagnostics.recentCommands.last?.requestByteCount == 24)
    #expect(diagnostics.recentCommands.last?.responseType == 0x1200)
    #expect(diagnostics.recentCommands.last?.responseByteCount == 24)
  }

  @Test func publishesOnlyRendererAuthenticatedFeaturesAndCapsets() throws {
    let authority = try GPUAccelerationAuthority(
      features: [.gpuVirgl, .gpuResourceBlob, .gpuContextInit],
      capsets: [
        .init(id: 2, maximumVersion: 2, data: [0x56, 0x49, 0x52, 0x47, 0x4C]),
        .init(id: 4, maximumVersion: 0, data: [0x56, 0x45, 0x4E, 0x55, 0x53]),
      ]
    )
    let device = try makeDevice(authority: authority)
    let memory = GPUGuestMemory(byteCount: 0x5000)

    #expect(device.offeredFeatures == authority.capabilities.features)
    #expect(read32(device.configuration, 12) == 2)

    let info = try command(
      device,
      bytes: header(0x0108) + littleEndian(UInt32(1)) + littleEndian(UInt32(0)),
      responseBytes: 40,
      memory: memory
    )
    #expect(read32(info, 0) == 0x1102)
    #expect(read32(info, 24) == 4)
    #expect(read32(info, 28) == 0)
    #expect(read32(info, 32) == 5)

    let capset = try command(
      device,
      bytes: header(0x0109) + littleEndian(UInt32(2)) + littleEndian(UInt32(2)),
      responseBytes: 29,
      memory: memory
    )
    #expect(read32(capset, 0) == 0x1103)
    #expect(Array(capset.dropFirst(24)) == [0x56, 0x49, 0x52, 0x47, 0x4C])

    device.reset()
    #expect(authority.resetCount == 1)
  }

  @Test func rejectsUnboundedOrFeaturelessRendererCapabilities() {
    #expect(throws: DoryVirtioGPUError.invalidAccelerationCapabilities) {
      _ = try DoryVirtioGPUAccelerationCapabilities(
        features: [.gpuResourceBlob],
        capsets: [.init(id: 4, maximumVersion: 0, data: [1])]
      )
    }
    #expect(throws: DoryVirtioGPUError.invalidAccelerationCapabilities) {
      _ = try DoryVirtioGPUAccelerationCapabilities(
        features: [.gpuVirgl],
        capsets: [
          .init(id: 2, maximumVersion: 2, data: [1]),
          .init(id: 2, maximumVersion: 2, data: [2]),
        ]
      )
    }
  }

  @Test func routesContextResourceSubmitAndTransferCommandsToRendererAuthority() throws {
    let authority = try GPUAccelerationAuthority(
      features: [.gpuVirgl, .gpuResourceUUID, .gpuContextInit],
      capsets: [.init(id: 2, maximumVersion: 2, data: [1, 2, 3])]
    )
    let device = try makeDevice(authority: authority)
    let memory = GPUGuestMemory(byteCount: 0x20_000)
    let contextID: UInt32 = 17
    let resourceID: UInt32 = 23

    var contextName = [UInt8](repeating: 0, count: 64)
    contextName.replaceSubrange(0..<4, with: Array("mesa".utf8))
    let createContext =
      header(0x0200, contextID: contextID) + littleEndian(UInt32(4))
      + littleEndian(UInt32(2)) + contextName
    #expect(read32(try command(device, bytes: createContext, memory: memory), 0) == 0x1100)

    let createResource =
      header(0x0204)
      + [resourceID, 2, 1, 2, 64, 32, 1, 1, 0, 0, 0, 0]
      .flatMap(littleEndian)
    #expect(read32(try command(device, bytes: createResource, memory: memory), 0) == 0x1100)

    let assignUUID = header(0x010B) + littleEndian(resourceID) + [0, 0, 0, 0]
    let firstUUID = try command(
      device,
      bytes: assignUUID,
      responseBytes: 40,
      memory: memory
    )
    let secondUUID = try command(
      device,
      bytes: assignUUID,
      responseBytes: 40,
      memory: memory
    )
    #expect(read32(firstUUID, 0) == 0x1105)
    #expect(Array(firstUUID[24..<40]) == Array(secondUUID[24..<40]))
    #expect(firstUUID[24..<40].contains(where: { $0 != 0 }))

    let attachBacking =
      header(0x0106) + littleEndian(resourceID) + littleEndian(UInt32(1))
      + littleEndian(UInt64(0x8000)) + littleEndian(UInt32(8_192)) + littleEndian(UInt32(0))
    #expect(read32(try command(device, bytes: attachBacking, memory: memory), 0) == 0x1100)

    let attach = header(0x0202, contextID: contextID) + littleEndian(resourceID) + [0, 0, 0, 0]
    #expect(read32(try command(device, bytes: attach, memory: memory), 0) == 0x1100)

    let submit =
      header(0x0207, contextID: contextID) + littleEndian(UInt32(4))
      + littleEndian(UInt32(0)) + [0xAA, 0xBB, 0xCC, 0xDD]
    #expect(read32(try command(device, bytes: submit, memory: memory), 0) == 0x1100)

    let transfer =
      header(0x0205, contextID: contextID)
      + [UInt32(0), 0, 0, 64, 32, 1].flatMap(littleEndian)
      + littleEndian(UInt64(0)) + [resourceID, 0, 256, 8_192].flatMap(littleEndian)
    #expect(read32(try command(device, bytes: transfer, memory: memory), 0) == 0x1100)

    let scanoutRectangle = rect(x: 0, y: 0, width: 64, height: 32)
    let bind =
      header(0x0103) + scanoutRectangle + littleEndian(UInt32(0))
      + littleEndian(resourceID)
    #expect(read32(try command(device, bytes: bind, memory: memory), 0) == 0x1100)
    let damage = rect(x: 8, y: 4, width: 16, height: 8)
    let flush = header(0x0104) + damage + littleEndian(resourceID) + [0, 0, 0, 0]
    #expect(read32(try command(device, bytes: flush, memory: memory), 0) == 0x1100)

    let detach = header(0x0203, contextID: contextID) + littleEndian(resourceID) + [0, 0, 0, 0]
    #expect(read32(try command(device, bytes: detach, memory: memory), 0) == 0x1100)
    #expect(
      read32(
        try command(
          device,
          bytes: header(0x0107) + littleEndian(resourceID) + [0, 0, 0, 0],
          memory: memory
        ), 0) == 0x1100)
    #expect(
      read32(
        try command(
          device,
          bytes: header(0x0102) + littleEndian(resourceID) + [0, 0, 0, 0],
          memory: memory
        ), 0) == 0x1100)
    #expect(
      read32(
        try command(device, bytes: header(0x0201, contextID: contextID), memory: memory),
        0
      ) == 0x1100)

    #expect(
      authority.operations == [
        "context-create:17:2:mesa",
        "resource-create:23:64x32",
        "backing-attach:23:1",
        "resource-attach:17:23",
        "submit:17:4",
        "transfer:toHost:17:23",
        "flush:1:0:23:64x32:8,4+16x8:256:0",
        "resource-detach:17:23",
        "backing-detach:23",
        "resource-unref:23",
        "context-destroy:17",
      ])
  }


  @Test func fencedAcceleratedSubmitCompletesOnlyAfterFenceSignal() throws {
    let authority = try GPUAccelerationAuthority(
      features: [.gpuVirgl, .gpuContextInit],
      capsets: [.init(id: 2, maximumVersion: 2, data: [1])]
    )
    let device = try makeDevice(authority: authority)
    let memory = GPUGuestMemory(byteCount: 0x20_000)
    let contextID: UInt32 = 17

    var contextName = [UInt8](repeating: 0, count: 64)
    contextName.replaceSubrange(0..<4, with: Array("mesa".utf8))
    let createContext =
      header(0x0200, contextID: contextID) + littleEndian(UInt32(4))
      + littleEndian(UInt32(2)) + contextName
    #expect(read32(try command(device, bytes: createContext, memory: memory), 0) == 0x1100)

    let submit =
      header(0x0207, flags: 3, fence: 0, contextID: contextID, ringIndex: 2)
      + littleEndian(UInt32(4)) + littleEndian(UInt32(0))
      + [0xAA, 0xBB, 0xCC, 0xDD]
    let responses = GPUResponseRecorder()
    try deferredCommand(device, bytes: submit, memory: memory) { response in
      responses.append(response)
      return true
    }

    #expect(responses.values.isEmpty)
    #expect(authority.operations == ["context-create:17:2:mesa", "submit-fenced:17:4:17:2:0:true"])
    authority.completeFence(at: 0, with: .signaled)
    let response = try #require(responses.values.first)
    #expect(read32(response, 0) == 0x1100)
    #expect(read32(response, 4) == 3)
    #expect(read64(response, 8) == 0)
    #expect(read32(response, 16) == contextID)
    #expect(response[20] == 2)
  }

  @Test func fencedAcceleratedSubmitOutcomeUnknownRequestsTerminalFailure() throws {
    let authority = try GPUAccelerationAuthority(
      features: [.gpuVirgl, .gpuContextInit],
      capsets: [.init(id: 2, maximumVersion: 2, data: [1])]
    )
    let device = try makeDevice(authority: authority)
    let memory = GPUGuestMemory(byteCount: 0x20_000)
    let contextID: UInt32 = 17

    var contextName = [UInt8](repeating: 0, count: 64)
    contextName.replaceSubrange(0..<4, with: Array("mesa".utf8))
    let createContext =
      header(0x0200, contextID: contextID) + littleEndian(UInt32(4))
      + littleEndian(UInt32(2)) + contextName
    #expect(read32(try command(device, bytes: createContext, memory: memory), 0) == 0x1100)

    let submit =
      header(0x0207, flags: 1, fence: 5, contextID: contextID)
      + littleEndian(UInt32(4)) + littleEndian(UInt32(0))
      + [0xAA, 0xBB, 0xCC, 0xDD]
    let responses = GPUResponseRecorder()
    let failures = GPUFailureRecorder()
    try deferredCommand(
      device,
      bytes: submit,
      memory: memory,
      completion: { response in
        responses.append(response)
        return true
      },
      terminalFailure: {
        failures.record()
        return true
      }
    )

    authority.completeFence(at: 0, with: .outcomeUnknown)
    #expect(responses.values.isEmpty)
    #expect(failures.count == 1)
  }

  @Test func createsBacksTransfersBindsAndFlushesA2DResource() throws {
    let sink = GPUDisplaySink()
    let device = try makeDevice(sink: sink)
    let memory = GPUGuestMemory(byteCount: 0x20_000)

    let create =
      header(0x0101) + littleEndian(UInt32(7)) + littleEndian(UInt32(1))
      + littleEndian(UInt32(4)) + littleEndian(UInt32(2))
    #expect(read32(try command(device, bytes: create, memory: memory), 0) == 0x1100)

    memory.put(Array(0..<32), at: 0x8000)
    let attach =
      header(0x0106) + littleEndian(UInt32(7)) + littleEndian(UInt32(1))
      + littleEndian(UInt64(0x8000)) + littleEndian(UInt32(32)) + littleEndian(UInt32(0))
    #expect(read32(try command(device, bytes: attach, memory: memory), 0) == 0x1100)

    let rectangle = rect(x: 0, y: 0, width: 4, height: 2)
    let transfer =
      header(0x0105) + rectangle + littleEndian(UInt64(0))
      + littleEndian(UInt32(7)) + littleEndian(UInt32(0))
    #expect(read32(try command(device, bytes: transfer, memory: memory), 0) == 0x1100)

    let bind = header(0x0103) + rectangle + littleEndian(UInt32(0)) + littleEndian(UInt32(7))
    #expect(read32(try command(device, bytes: bind, memory: memory), 0) == 0x1100)

    let flush = header(0x0104) + rectangle + littleEndian(UInt32(7)) + littleEndian(UInt32(0))
    #expect(read32(try command(device, bytes: flush, memory: memory), 0) == 0x1100)
    #expect(sink.frames.count == 1)
    #expect(sink.frames[0].scanoutID == 0)
    #expect(sink.frames[0].pixels == Array(0..<32))
  }

  @Test func supportsScatterBackingAndFencedResponses() throws {
    let sink = GPUDisplaySink()
    let device = try makeDevice(sink: sink)
    let memory = GPUGuestMemory(byteCount: 0x20_000)
    let fencedHeader = header(0x0101, flags: 1, fence: 0x1234)
    let create =
      fencedHeader + littleEndian(UInt32(9)) + littleEndian(UInt32(1))
      + littleEndian(UInt32(4)) + littleEndian(UInt32(2))
    let createResponse = try command(device, bytes: create, memory: memory)
    #expect(read32(createResponse, 4) == 1)
    #expect(read64(createResponse, 8) == 0x1234)

    memory.put(Array(0..<12), at: 0x9000)
    memory.put(Array(12..<32), at: 0xA000)
    let attach =
      header(0x0106) + littleEndian(UInt32(9)) + littleEndian(UInt32(2))
      + littleEndian(UInt64(0x9000)) + littleEndian(UInt32(12)) + littleEndian(UInt32(0))
      + littleEndian(UInt64(0xA000)) + littleEndian(UInt32(20)) + littleEndian(UInt32(0))
    #expect(read32(try command(device, bytes: attach, memory: memory), 0) == 0x1100)

    let rectangle = rect(x: 0, y: 0, width: 4, height: 2)
    let transfer =
      header(0x0105) + rectangle + littleEndian(UInt64(0))
      + littleEndian(UInt32(9)) + littleEndian(UInt32(0))
    #expect(read32(try command(device, bytes: transfer, memory: memory), 0) == 0x1100)
    let bind = header(0x0103) + rectangle + littleEndian(UInt32(1)) + littleEndian(UInt32(9))
    _ = try command(device, bytes: bind, memory: memory)
    let flush = header(0x0104) + rectangle + littleEndian(UInt32(9)) + littleEndian(UInt32(0))
    _ = try command(device, bytes: flush, memory: memory)
    #expect(sink.frames[0].pixels == Array(0..<32))
  }

  @Test func rejectsOversizedResourcesAndInvalidScanoutsWithoutAllocating() throws {
    let device = try DoryVirtioGPUDevice(
      scanouts: [.init(id: 0, rectangle: .init(x: 0, y: 0, width: 800, height: 600))],
      maximumResourceBytes: 4_096
    )
    let memory = GPUGuestMemory(byteCount: 0x5000)
    let create =
      header(0x0101) + littleEndian(UInt32(1)) + littleEndian(UInt32(1))
      + littleEndian(UInt32(1_024)) + littleEndian(UInt32(1_024))
    #expect(read32(try command(device, bytes: create, memory: memory), 0) == 0x1205)

    let bind =
      header(0x0103) + rect(x: 0, y: 0, width: 1, height: 1)
      + littleEndian(UInt32(3)) + littleEndian(UInt32(0))
    #expect(read32(try command(device, bytes: bind, memory: memory), 0) == 0x1202)
  }

  private func makeDevice(
    sink: GPUDisplaySink? = nil,
    authority: GPUAccelerationAuthority? = nil
  ) throws -> DoryVirtioGPUDevice {
    try .init(
      scanouts: [
        .init(id: 0, rectangle: .init(x: 0, y: 0, width: 800, height: 600)),
        .init(id: 1, rectangle: .init(x: 800, y: 0, width: 1_920, height: 1_080)),
      ],
      displaySink: sink,
      accelerationAuthority: authority
    )
  }

  private func command(
    _ device: DoryVirtioGPUDevice,
    bytes: [UInt8],
    responseBytes: Int = 24,
    memory: GPUGuestMemory
  ) throws -> [UInt8] {
    memory.put(bytes, at: 0x1000)
    let chain = DoryVirtioDescriptorChain(
      headIndex: 0,
      descriptors: [
        .init(address: 0x1000, length: UInt32(bytes.count), flags: 0, next: 1),
        .init(address: 0x4000, length: UInt32(responseBytes), flags: 2, next: 0),
      ],
      readableByteCount: UInt64(bytes.count),
      writableByteCount: UInt64(responseBytes)
    )
    let written = try device.process(queue: 0, chain: chain, memory: memory)
    return try memory.read(at: 0x4000, byteCount: Int(written))
  }

  private func deferredCommand(
    _ device: DoryVirtioGPUDevice,
    bytes: [UInt8],
    responseBytes: Int = 24,
    memory: GPUGuestMemory,
    completion: @escaping @Sendable ([UInt8]) -> Bool,
    terminalFailure: @escaping @Sendable () -> Bool = { false }
  ) throws {
    memory.put(bytes, at: 0x1000)
    let chain = DoryVirtioDescriptorChain(
      headIndex: 0,
      descriptors: [
        .init(address: 0x1000, length: UInt32(bytes.count), flags: 0, next: 1),
        .init(address: 0x4000, length: UInt32(responseBytes), flags: 2, next: 0),
      ],
      readableByteCount: UInt64(bytes.count),
      writableByteCount: UInt64(responseBytes)
    )
    try device.processDeferred(
      queue: 0,
      chain: chain,
      memory: memory,
      completion: completion,
      terminalFailure: terminalFailure
    )
  }

  private func header(
    _ command: UInt32,
    flags: UInt32 = 0,
    fence: UInt64 = 0,
    contextID: UInt32 = 0,
    ringIndex: UInt8 = 0
  ) -> [UInt8] {
    littleEndian(command) + littleEndian(flags) + littleEndian(fence)
      + littleEndian(contextID) + [ringIndex, 0, 0, 0]
  }

  private func rect(x: UInt32, y: UInt32, width: UInt32, height: UInt32) -> [UInt8] {
    littleEndian(x) + littleEndian(y) + littleEndian(width) + littleEndian(height)
  }
}

private final class GPUResponseRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [[UInt8]] = []

  var values: [[UInt8]] { lock.withLock { storage } }

  func append(_ response: [UInt8]) { lock.withLock { storage.append(response) } }
}

private final class GPUFailureRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storage = 0

  var count: Int { lock.withLock { storage } }

  func record() { lock.withLock { storage += 1 } }
}

private final class GPUAccelerationAuthority: DoryVirtioGPUAccelerationAuthority,
  @unchecked Sendable
{
  let capabilities: DoryVirtioGPUAccelerationCapabilities
  private let lock = NSLock()
  private var resets = 0
  private var operationStorage: [String] = []
  var resetCount: Int { lock.withLock { resets } }
  var operations: [String] { lock.withLock { operationStorage } }

  init(features: DoryVirtioFeatures, capsets: [DoryVirtioGPUCapset]) throws {
    capabilities = try .init(features: features, capsets: capsets)
  }

  func reset() { lock.withLock { resets += 1 } }

  func createContext(id: UInt32, capsetID: UInt32, name: String) {
    record("context-create:\(id):\(capsetID):\(name)")
  }

  func destroyContext(id: UInt32) { record("context-destroy:\(id)") }

  func attachResource(contextID: UInt32, resourceID: UInt32) {
    record("resource-attach:\(contextID):\(resourceID)")
  }

  func detachResource(contextID: UInt32, resourceID: UInt32) {
    record("resource-detach:\(contextID):\(resourceID)")
  }

  private var fenceCompletions: [@Sendable (DoryVirtioGPUFenceCompletion) -> Void] = []

  func submit3D(contextID: UInt32, command: [UInt8]) {
    record("submit:\(contextID):\(command.count)")
  }

  func submit3D(
    contextID: UInt32,
    command: [UInt8],
    fence: DoryVirtioGPUFenceRequest,
    completion: @escaping @Sendable (DoryVirtioGPUFenceCompletion) -> Void
  ) {
    lock.withLock { fenceCompletions.append(completion) }
    record(
      "submit-fenced:\(contextID):\(command.count):\(fence.contextID):"
        + "\(fence.ringIndex):\(fence.fenceID):\(fence.contextFence)"
    )
  }

  func createFence(
    _ fence: DoryVirtioGPUFenceRequest,
    completion: @escaping @Sendable (DoryVirtioGPUFenceCompletion) -> Void
  ) {
    lock.withLock { fenceCompletions.append(completion) }
    record("fence:\(fence.contextID):\(fence.ringIndex):\(fence.fenceID):\(fence.contextFence)")
  }

  func completeFence(at index: Int, with result: DoryVirtioGPUFenceCompletion) {
    let completion = lock.withLock { fenceCompletions.remove(at: index) }
    completion(result)
  }

  func createResource3D(_ resource: DoryVirtioGPUResource3D) {
    record("resource-create:\(resource.resourceID):\(resource.width)x\(resource.height)")
  }

  func attachBacking(
    resourceID: UInt32,
    entries: [DoryVirtioGPUBackingEntry],
    memory: any DoryVirtioGuestMemory
  ) {
    record("backing-attach:\(resourceID):\(entries.count)")
  }

  func detachBacking(resourceID: UInt32) { record("backing-detach:\(resourceID)") }

  func transfer3D(
    _ transfer: DoryVirtioGPUTransfer3D,
    entries: [DoryVirtioGPUBackingEntry],
    memory: any DoryVirtioGuestMemory
  ) {
    record("transfer:\(transfer.direction):\(transfer.contextID):\(transfer.resourceID)")
  }

  func flushResource(_ scanouts: [DoryVirtioGPUAcceleratedScanoutFlush]) {
    let first = scanouts[0]
    record(
      "flush:\(scanouts.count):\(first.scanoutID):\(first.resourceID):"
        + "\(first.resourceWidth)x\(first.resourceHeight):"
        + "\(first.damagedRectangle.x),\(first.damagedRectangle.y)+"
        + "\(first.damagedRectangle.width)x\(first.damagedRectangle.height):"
        + "\(first.stride):\(first.storageOffset)"
    )
  }

  func unrefResource(resourceID: UInt32) { record("resource-unref:\(resourceID)") }

  private func record(_ operation: String) {
    lock.withLock { operationStorage.append(operation) }
  }
}

private final class GPUDisplaySink: DoryVirtioGPUDisplaySink, @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [DoryVirtioGPUFrame] = []
  var frames: [DoryVirtioGPUFrame] { lock.withLock { storage } }
  func present(_ frame: DoryVirtioGPUFrame) { lock.withLock { storage.append(frame) } }
}

private final class GPUGuestMemory: DoryVirtioGuestMemory, @unchecked Sendable {
  private let lock = NSLock()
  private var bytes: [UInt8]

  init(byteCount: Int) { bytes = .init(repeating: 0, count: byteCount) }

  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    try lock.withLock { Array(bytes[try checked(address, byteCount)]) }
  }

  func validate(at address: UInt64, byteCount: Int, deviceWillWrite: Bool) throws {
    _ = try lock.withLock { try checked(address, byteCount) }
  }

  func write(at address: UInt64, bytes: [UInt8]) throws {
    try lock.withLock { self.bytes.replaceSubrange(try checked(address, bytes.count), with: bytes) }
  }

  func synchronize() {}

  func put(_ value: [UInt8], at address: UInt64) {
    lock.withLock {
      bytes.replaceSubrange(Int(address)..<(Int(address) + value.count), with: value)
    }
  }

  private func checked(_ address: UInt64, _ count: Int) throws -> Range<Int> {
    guard count >= 0, address <= UInt64(bytes.count), UInt64(count) <= UInt64(bytes.count) - address
    else { throw DoryVirtioGPUError.malformedRequest }
    return Int(address)..<(Int(address) + count)
  }
}

private func read32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
  (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << UInt32($1 * 8) }
}

private func read64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
  (0..<8).reduce(0) { $0 | UInt64(bytes[offset + $1]) << UInt64($1 * 8) }
}

private func littleEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
  (0..<MemoryLayout<T>.size).map { UInt8(truncatingIfNeeded: value >> T($0 * 8)) }
}
