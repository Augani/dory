import DoryVirtio
import Foundation
import Testing

private let gpuTestWorkspaceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

/// These tests deliberately block at renderer/alias barriers. Dedicated execution threads keep
/// parallel Swift Testing tasks from starving the shared pool needed to reach those barriers.
private func gpuTestExecutionThread(_ body: @escaping @Sendable () -> Void) {
  Thread(block: body).start()
}

@Suite struct DoryVirtioGPUTests {
  @Test func blobMemoryRejectsMalformedRendererReadAndAtomicReplies() throws {
    for malformed in [[UInt8](), [0x11], [0x11, 0x22, 0x33]] {
      let region = DoryVirtioGPUBlobMemoryRegion(
        byteCount: 4_096,
        read: { _, _ in malformed },
        write: { _, _ in },
        compareExchange: { _, _, _, _ in 0x1_0000 }
      )
      #expect(throws: DoryVirtioGPUAccelerationError.invalidBlobMapping) {
        _ = try region.read(offset: 0, byteCount: 2)
      }
      #expect(throws: DoryVirtioGPUAccelerationError.invalidBlobMapping) {
        _ = try region.compareExchange(
          offset: 0, expected: 0, desired: 1, byteCount: 2)
      }
    }
    let valid = DoryVirtioGPUBlobMemoryRegion(
      byteCount: 4_096,
      read: { _, count in [UInt8](repeating: 0x5A, count: count) },
      write: { _, _ in },
      compareExchange: { _, _, _, _ in 0xFFFF }
    )
    #expect(try valid.read(offset: 0, byteCount: 2) == [0x5A, 0x5A])
    #expect(try valid.compareExchange(
      offset: 0, expected: 0, desired: 1, byteCount: 2) == 0xFFFF)
  }

  @Test func invalidPhysicalScanoutDimensionsReturnAnError() throws {
    let invalid = DoryVirtioGPUScanout(
      id: 0,
      rectangle: .init(x: 0, y: 0, width: 1_280, height: 800),
      physicalWidthMillimeters: 0,
      physicalHeightMillimeters: 4_096
    )
    #expect(throws: DoryVirtioGPUError.invalidPhysicalDimensions(
      widthMillimeters: 0,
      heightMillimeters: 4_096
    )) {
      try DoryVirtioGPUDevice(scanouts: [invalid])
    }
  }

  @Test func concurrentResetWaitsForApertureAndRendererRetirement() throws {
    let authority = try GPUAccelerationAuthority(
      features: [.gpuVirgl, .gpuResourceBlob],
      capsets: [.init(id: 2, maximumVersion: 2, data: [1])]
    )
    let aperture = GPUHostVisibleAperture()
    let device = try makeDevice(authority: authority, hostVisibleAperture: aperture)
    let enteredApertureReset = DispatchSemaphore(value: 0)
    let releaseApertureReset = DispatchSemaphore(value: 0)
    let firstResetFinished = DispatchSemaphore(value: 0)
    let secondResetStarted = DispatchSemaphore(value: 0)
    let secondResetFinished = DispatchSemaphore(value: 0)
    aperture.holdNextReset(entered: enteredApertureReset, release: releaseApertureReset)
    gpuTestExecutionThread {
      device.reset()
      firstResetFinished.signal()
    }
    #expect(enteredApertureReset.wait(timeout: .now() + 1) == .success)
    gpuTestExecutionThread {
      secondResetStarted.signal()
      device.reset()
      secondResetFinished.signal()
    }
    #expect(secondResetStarted.wait(timeout: .now() + 1) == .success)
    #expect(secondResetFinished.wait(timeout: .now() + 0.05) == .timedOut)
    releaseApertureReset.signal()
    #expect(firstResetFinished.wait(timeout: .now() + 1) == .success)
    #expect(secondResetFinished.wait(timeout: .now() + 1) == .success)
    #expect(aperture.resetCount == 2)
    #expect(authority.resetCount == 2)
  }

  @Test func hotplugUsesOnlyBootTimeConnectorCapacity() throws {
    let device = try DoryVirtioGPUDevice(scanouts: [
      .init(id: 0, rectangle: .init(x: 0, y: 0, width: 1_280, height: 800)),
      .init(
        id: 1,
        rectangle: .init(x: 0, y: 0, width: 1_280, height: 800),
        enabled: false
      ),
    ])
    let primary = DoryVirtioGPUDisplayMode(
      width: 1_280, height: 800,
      physicalWidthMillimeters: 203, physicalHeightMillimeters: 127
    )
    let secondary = DoryVirtioGPUDisplayMode(
      width: 1_920, height: 1_080,
      physicalWidthMillimeters: 300, physicalHeightMillimeters: 180
    )

    #expect(read32(device.configuration, 8) == 2)
    #expect(device.updateScanoutTopology([primary, secondary]))
    #expect(device.scanouts[1].enabled)
    #expect(device.scanouts[1].rectangle.width == secondary.width)
    #expect(device.scanouts[1].physicalWidthMillimeters == 300)
    #expect(read32(device.configuration, 0) & 1 == 1)
    let memory = GPUGuestMemory(byteCount: 0x5000)
    let addedInfo = try command(
      device,
      bytes: header(0x0100),
      responseBytes: 24 + 16 * 24,
      memory: memory
    )
    #expect(read32(addedInfo, 48 + 8) == 1_920)
    #expect(read32(addedInfo, 48 + 16) == 1)
    let edidRequest = header(0x010A) + littleEndian(UInt32(1)) + littleEndian(UInt32(0))
    let edidResponse = try command(
      device,
      bytes: edidRequest,
      responseBytes: 1_056,
      memory: memory
    )
    #expect(read32(edidResponse, 0) == 0x1104)
    #expect(read32(edidResponse, 24) == 128)
    let edid = Array(edidResponse[32..<160])
    #expect(edid.reduce(UInt8(0), &+) == 0)
    #expect(UInt32(edid[56]) | UInt32(edid[58] >> 4) << 8 == 1_920)
    #expect(UInt32(edid[59]) | UInt32(edid[61] >> 4) << 8 == 1_080)
    #expect(UInt32(edid[66]) | UInt32(edid[68] >> 4) << 8 == 300)
    #expect(UInt32(edid[67]) | UInt32(edid[68] & 0x0F) << 8 == 180)
    #expect(device.updateScanoutSize(
      scanoutID: 1,
      width: 1_920,
      height: 1_080,
      physicalWidthMillimeters: 320,
      physicalHeightMillimeters: 200
    ))
    let movedEDID = try command(
      device,
      bytes: edidRequest,
      responseBytes: 1_056,
      memory: memory
    )
    #expect(UInt32(movedEDID[32 + 66]) | UInt32(movedEDID[32 + 68] >> 4) << 8 == 320)
    #expect(UInt32(movedEDID[32 + 67]) | UInt32(movedEDID[32 + 68] & 0x0F) << 8 == 200)
    #expect(device.updateScanoutTopology([primary]))
    #expect(!device.scanouts[1].enabled)
    let removedInfo = try command(
      device,
      bytes: header(0x0100),
      responseBytes: 24 + 16 * 24,
      memory: memory
    )
    #expect(read32(removedInfo, 48 + 16) == 0)
    #expect(device.offeredFeatures.contains(.gpuEDID))
    #expect(read32(try command(
      device,
      bytes: edidRequest,
      responseBytes: 1_056,
      memory: memory
    ), 0) == 0x1104)
    #expect(read32(try command(
      device,
      bytes: header(0x010A) + littleEndian(UInt32(2)) + littleEndian(UInt32(0)),
      memory: memory
    ), 0) == 0x1205)
    #expect(!device.updateScanoutTopology([]))
    #expect(!device.updateScanoutTopology([primary, secondary, primary]))
  }

  @Test func publishesDisplayConfigurationAndDisplayInfo() throws {
    let device = try makeDevice()
    #expect(read32(device.configuration, 8) == 2)
    #expect(read32(device.configuration, 12) == 0)
    #expect(!device.offeredFeatures.contains(.gpuVirgl))
    #expect(device.offeredFeatures.contains(.gpuEDID))
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

  @Test func headlessPCGPUDoesNotOfferEDID() throws {
    let device = try DoryVirtioGPUDevice(scanouts: [
      .init(
        id: 0,
        rectangle: .init(x: 0, y: 0, width: 1_280, height: 800),
        enabled: false
      )
    ])
    #expect(!device.offeredFeatures.contains(.gpuEDID))
    let response = try command(
      device,
      bytes: header(0x010A) + littleEndian(UInt32(0)) + littleEndian(UInt32(0)),
      memory: GPUGuestMemory(byteCount: 0x5000)
    )
    #expect(read32(response, 0) == 0x1205)
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
    let aperture = GPUHostVisibleAperture()
    let device = try makeDevice(authority: authority, hostVisibleAperture: aperture)
    let memory = GPUGuestMemory(byteCount: 0x5000)

    #expect(device.offeredFeatures == authority.capabilities.features.union(.gpuEDID))
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
    #expect(aperture.resetCount == 1)
  }

  @Test func rendererResourceQuotaReturnsOutOfMemoryWithoutPublishingAResource() throws {
    let authority = try GPUAccelerationAuthority(
      features: [.gpuVirgl, .gpuResourceBlob],
      capsets: [.init(id: 2, maximumVersion: 2, data: [1])]
    )
    authority.setCreationLimitReached(true)
    let device = try makeDevice(
      authority: authority,
      hostVisibleAperture: GPUHostVisibleAperture()
    )
    let memory = GPUGuestMemory(byteCount: 0x20_000)
    let create3D = header(0x0204)
      + [UInt32(91), 2, 1, 2, 4, 4, 1, 1, 0, 0, 0, 0].flatMap(littleEndian)
    let createBlob = header(0x010C)
      + littleEndian(UInt32(92)) + littleEndian(UInt32(2))
      + littleEndian(UInt32(1)) + littleEndian(UInt32(0))
      + littleEndian(UInt64(0xABCD)) + littleEndian(UInt64(4_096))
    #expect(read32(try command(device, bytes: create3D, memory: memory), 0) == 0x1201)
    #expect(read32(try command(device, bytes: createBlob, memory: memory), 0) == 0x1201)
    #expect(authority.operations.isEmpty)
  }

  @Test func semanticGPUResourceQuotaIncludesInFlightBlobAndAllResourceKinds() throws {
    let authority = try GPUAccelerationAuthority(
      features: [.gpuVirgl, .gpuResourceBlob],
      capsets: [.init(id: 2, maximumVersion: 2, data: [1])]
    )
    let device = try makeDevice(
      authority: authority,
      hostVisibleAperture: GPUHostVisibleAperture(),
      maximumGPUResourceCount: 1
    )
    let memory = GPUGuestMemory(byteCount: 0x20_000)
    let createBlob = header(0x010C) + littleEndian(UInt32(91))
      + littleEndian(UInt32(2)) + littleEndian(UInt32(1)) + littleEndian(UInt32(0))
      + littleEndian(UInt64(0xABCD)) + littleEndian(UInt64(4_096))
    let create2D = header(0x0101) + [UInt32(92), 1, 4, 4].flatMap(littleEndian)
    let create3D = header(0x0204)
      + [UInt32(93), 2, 1, 2, 4, 4, 1, 1, 0, 0, 0, 0].flatMap(littleEndian)

    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    let recorded = GPUResponseRecorder()
    let heldMemory = GPUGuestMemory(byteCount: 0x20_000)
    authority.holdNextCreate(entered: entered, release: release)
    gpuTestExecutionThread {
      if let result = try? command(device, bytes: createBlob, memory: heldMemory) {
        recorded.append(result)
      }
      finished.signal()
    }
    guard entered.wait(timeout: .now() + 2) == .success else {
      release.signal()
      Issue.record("blob create did not reach the resource reservation barrier")
      return
    }
    #expect(read32(try command(device, bytes: create2D, memory: memory), 0) == 0x1201)
    #expect(read32(try command(device, bytes: create3D, memory: memory), 0) == 0x1201)
    #expect(read32(try command(device, bytes: createBlob, memory: memory), 0) == 0x1203)
    #expect(authority.operations == ["blob-create:91:4096:0"])
    release.signal()
    #expect(finished.wait(timeout: .now() + 2) == .success)
    #expect(recorded.values.first.map { read32($0, 0) } == 0x1100)

    let unref = header(0x0102) + littleEndian(UInt32(91)) + littleEndian(UInt32(0))
    #expect(read32(try command(device, bytes: unref, memory: memory), 0) == 0x1100)
    #expect(read32(try command(device, bytes: create3D, memory: memory), 0) == 0x1100)
    #expect(read32(try command(device, bytes: create2D, memory: memory), 0) == 0x1201)
  }

  @Test func semanticGPUContextQuotaRejectsAdditionalRendererCreates() throws {
    let authority = try GPUAccelerationAuthority(
      features: [.gpuVirgl, .gpuContextInit],
      capsets: [.init(id: 2, maximumVersion: 2, data: [1])]
    )
    let device = try makeDevice(authority: authority, maximumRendererContextCount: 1)
    let memory = GPUGuestMemory(byteCount: 0x20_000)
    @Sendable func create(_ id: UInt32) -> [UInt8] {
      header(0x0200, contextID: id) + littleEndian(UInt32(0))
        + littleEndian(UInt32(2)) + [UInt8](repeating: 0, count: 64)
    }
    #expect(read32(try command(device, bytes: create(17), memory: memory), 0) == 0x1100)
    #expect(read32(try command(device, bytes: create(18), memory: memory), 0) == 0x1201)
    #expect(authority.operations == ["context-create:17:2:virtio-gpu"])
    #expect(read32(try command(device, bytes: header(0x0201, contextID: 17), memory: memory), 0)
      == 0x1100)
    #expect(read32(try command(device, bytes: create(18), memory: memory), 0) == 0x1100)
  }

  @Test func semanticGPUContextQuotaCountsInFlightCreates() throws {
    let authority = try GPUAccelerationAuthority(
      features: [.gpuVirgl, .gpuContextInit],
      capsets: [.init(id: 2, maximumVersion: 2, data: [1])]
    )
    let device = try makeDevice(authority: authority, maximumRendererContextCount: 1)
    let memory = GPUGuestMemory(byteCount: 0x20_000)
    let heldMemory = GPUGuestMemory(byteCount: 0x20_000)
    @Sendable func create(_ id: UInt32) -> [UInt8] {
      header(0x0200, contextID: id) + littleEndian(UInt32(0))
        + littleEndian(UInt32(2)) + [UInt8](repeating: 0, count: 64)
    }
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    let recorded = GPUResponseRecorder()
    authority.holdNextContextCreate(entered: entered, release: release)
    gpuTestExecutionThread {
      if let result = try? command(device, bytes: create(17), memory: heldMemory) {
        recorded.append(result)
      }
      finished.signal()
    }
    guard entered.wait(timeout: .now() + 2) == .success else {
      release.signal()
      Issue.record("context create did not reach the context reservation barrier")
      return
    }
    #expect(read32(try command(device, bytes: create(18), memory: memory), 0) == 0x1201)
    #expect(read32(try command(device, bytes: create(17), memory: memory), 0) == 0x1205)
    #expect(authority.operations == ["context-create:17:2:virtio-gpu"])
    release.signal()
    #expect(finished.wait(timeout: .now() + 2) == .success)
    #expect(recorded.values.first.map { read32($0, 0) } == 0x1100)
  }

  @Test func semanticGPUBlobByteQuotaCountsPendingAndRetainedResources() throws {
    let authority = try GPUAccelerationAuthority(
      features: [.gpuVirgl, .gpuResourceBlob],
      capsets: [.init(id: 2, maximumVersion: 2, data: [1])]
    )
    let device = try makeDevice(
      authority: authority,
      hostVisibleAperture: GPUHostVisibleAperture(),
      maximumGPUResourceCount: 3,
      maximumBlobResourceBytes: 4_096
    )
    let memory = GPUGuestMemory(byteCount: 0x20_000)
    let heldMemory = GPUGuestMemory(byteCount: 0x20_000)
    @Sendable func create(_ id: UInt32) -> [UInt8] {
      header(0x010C) + littleEndian(id) + littleEndian(UInt32(2))
        + littleEndian(UInt32(1)) + littleEndian(UInt32(0))
        + littleEndian(UInt64(0xABCD)) + littleEndian(UInt64(4_096))
    }
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    let recorded = GPUResponseRecorder()
    authority.holdNextCreate(entered: entered, release: release)
    gpuTestExecutionThread {
      if let result = try? command(device, bytes: create(101), memory: heldMemory) {
        recorded.append(result)
      }
      finished.signal()
    }
    guard entered.wait(timeout: .now() + 2) == .success else {
      release.signal()
      Issue.record("blob create did not reach the byte reservation barrier")
      return
    }
    #expect(read32(try command(device, bytes: create(102), memory: memory), 0) == 0x1201)
    #expect(authority.operations == ["blob-create:101:4096:0"])
    release.signal()
    #expect(finished.wait(timeout: .now() + 2) == .success)
    #expect(recorded.values.first.map { read32($0, 0) } == 0x1100)
    #expect(read32(try command(device, bytes: create(102), memory: memory), 0) == 0x1201)

    let unref = header(0x0102) + littleEndian(UInt32(101)) + littleEndian(UInt32(0))
    #expect(read32(try command(device, bytes: unref, memory: memory), 0) == 0x1100)
    #expect(read32(try command(device, bytes: create(102), memory: memory), 0) == 0x1100)
  }

  @Test func createsMapsDisplaysFlushesAndRevokesBlobResources() throws {
    let authority = try GPUAccelerationAuthority(
      features: [.gpuVirgl, .gpuResourceBlob, .gpuContextInit],
      capsets: [
        .init(id: 2, maximumVersion: 2, data: [1]),
        .init(id: 4, maximumVersion: 0, data: [2]),
      ]
    )
    let aperture = GPUHostVisibleAperture()
    let sink = GPUDisplaySink()
    let device = try makeDevice(
      sink: sink, authority: authority, hostVisibleAperture: aperture)
    let memory = GPUGuestMemory(byteCount: 0x20_000)
    let resourceID: UInt32 = 41

    let create =
      header(0x010C) + littleEndian(resourceID) + littleEndian(UInt32(2))
      + littleEndian(UInt32(1)) + littleEndian(UInt32(0))
      + littleEndian(UInt64(0xD0_12_34)) + littleEndian(UInt64(16_384))
    #expect(read32(try command(device, bytes: create, memory: memory), 0) == 0x1100)

    let map =
      header(0x0208) + littleEndian(resourceID) + littleEndian(UInt32(0))
      + littleEndian(UInt64(0x4000))
    let mapResponse = try command(device, bytes: map, responseBytes: 32, memory: memory)
    #expect(read32(mapResponse, 0) == 0x1106)
    #expect(read32(mapResponse, 24) == 3)
    try aperture.write(offset: 0x4000, bytes: [0xD0, 0x52, 0x59])
    #expect(
      try authority.readBlob(resourceID: resourceID, offset: 0, byteCount: 3) == [0xD0, 0x52, 0x59])

    let rectangle = rect(x: 0, y: 0, width: 64, height: 32)
    let bind =
      header(0x010D) + rectangle + littleEndian(UInt32(0)) + littleEndian(resourceID)
      + littleEndian(UInt32(64)) + littleEndian(UInt32(32)) + littleEndian(UInt32(1))
      + littleEndian(UInt32(0))
      + [UInt32(256), 0, 0, 0].flatMap(littleEndian)
      + [UInt32(0), 0, 0, 0].flatMap(littleEndian)
    #expect(bind.count == 96)
    #expect(read32(try command(device, bytes: bind, memory: memory), 0) == 0x1100)

    let cursorID: UInt32 = 77
    let createCursor = header(0x0101) + littleEndian(cursorID)
      + littleEndian(UInt32(1)) + littleEndian(UInt32(64)) + littleEndian(UInt32(64))
    #expect(read32(try command(device, bytes: createCursor, memory: memory), 0) == 0x1100)
    let showCursor = header(0x0300)
      + [UInt32(0), 20, 30, 0, cursorID, 0, 0, 0].flatMap(littleEndian)
    #expect(showCursor.count == 56)
    #expect(read32(try command(
      device, bytes: showCursor, queue: 1, memory: memory), 0) == 0x1100)
    #expect(sink.cursors.last?.resourceID == cursorID)

    let flush = header(0x0104) + rectangle + littleEndian(resourceID) + littleEndian(UInt32(0))
    #expect(read32(try command(device, bytes: flush, memory: memory), 0) == 0x1100)
    #expect(authority.blobFlushIdentities == [
      .init(workspaceID: gpuTestWorkspaceID,
            resourceGeneration: 1, workerGeneration: 9, deviceGeneration: 7)
    ])

    let unmap = header(0x0209) + littleEndian(resourceID) + littleEndian(UInt32(0))
    #expect(read32(try command(device, bytes: unmap, memory: memory), 0) == 0x1100)
    // Removing the CPU alias must not retire the independent renderer scanout binding.
    #expect(read32(try command(device, bytes: flush, memory: memory), 0) == 0x1100)
    #expect(authority.blobFlushIdentities.count == 2)

    let unbind =
      header(0x010D) + rect(x: 0, y: 0, width: 0, height: 0)
      + littleEndian(UInt32(0)) + littleEndian(UInt32(0))
      + [UInt32](repeating: 0, count: 12).flatMap(littleEndian)
    #expect(unbind.count == 96)
    #expect(read32(try command(device, bytes: unbind, memory: memory), 0) == 0x1100)
    #expect(sink.cursors.last?.resourceID == 0)
    #expect(sink.cursors.last?.bytes.isEmpty == true)
    let moveCursor = header(0x0301)
      + [UInt32(0), 21, 31, 0, 0, 0, 0, 0].flatMap(littleEndian)
    #expect(read32(try command(
      device, bytes: moveCursor, queue: 1, memory: memory), 0) == 0x1100)
    #expect(sink.cursors.last?.resourceID == 0)
    #expect(read32(try command(device, bytes: unmap, memory: memory), 0) == 0x1203)
    #expect(throws: DoryVirtioGPUAccelerationError.self) {
      _ = try aperture.read(offset: 0x4000, byteCount: 1)
    }

    let unref = header(0x0102) + littleEndian(resourceID) + littleEndian(UInt32(0))
    #expect(read32(try command(device, bytes: unref, memory: memory), 0) == 0x1100)
    #expect(
      authority.operations == [
        "blob-create:41:16384:0",
        "blob-map:41:1:16384",
        "blob-flush:1:0:41:64x32",
        "blob-unmap-local:41:1:true",
        "blob-flush:1:0:41:64x32",
        "resource-unref:41",
      ])
  }

  @Test func blobMemoryTypeAndHostVisibleMappingFollowVirtioContract() throws {
    let authority = try GPUAccelerationAuthority(
      features: [.gpuVirgl, .gpuResourceBlob],
      capsets: [.init(id: 2, maximumVersion: 2, data: [1])]
    )
    let aperture = GPUHostVisibleAperture()
    let device = try makeDevice(authority: authority, hostVisibleAperture: aperture)
    let memory = GPUGuestMemory(byteCount: 0x20_000)

    func create(resourceID: UInt32, blobMemory: UInt32) -> [UInt8] {
      header(0x010C) + littleEndian(resourceID) + littleEndian(blobMemory)
        + littleEndian(UInt32(1)) + littleEndian(UInt32(0))
        + littleEndian(UInt64(0xABCD)) + littleEndian(UInt64(4_096))
    }
    #expect(read32(try command(
      device, bytes: create(resourceID: 81, blobMemory: 4), memory: memory), 0) == 0x1205)
    #expect(authority.operations.isEmpty)

    // HOST3D_GUEST is a valid blob, but MAP_BLOB is defined only for HOST3D.
    #expect(read32(try command(
      device, bytes: create(resourceID: 82, blobMemory: 3), memory: memory), 0) == 0x1100)
    let map = header(0x0208) + littleEndian(UInt32(82)) + littleEndian(UInt32(0))
      + littleEndian(UInt64(0x4000))
    #expect(read32(try command(device, bytes: map, memory: memory), 0) == 0x1203)
    #expect(!aperture.isMapped)
    #expect(authority.operations == ["blob-create:82:4096:0"])

    let displayRect = rect(x: 0, y: 0, width: 16, height: 16)
    let bindUnmappedBlob = header(0x010D) + displayRect
      + littleEndian(UInt32(0)) + littleEndian(UInt32(82))
      + littleEndian(UInt32(16)) + littleEndian(UInt32(16))
      + littleEndian(UInt32(1)) + littleEndian(UInt32(0))
      + [UInt32(64), 0, 0, 0].flatMap(littleEndian)
      + [UInt32(0), 0, 0, 0].flatMap(littleEndian)
    #expect(read32(try command(device, bytes: bindUnmappedBlob, memory: memory), 0) == 0x1100)
    let flushUnmappedBlob = header(0x0104) + displayRect
      + littleEndian(UInt32(82)) + littleEndian(UInt32(0))
    #expect(read32(try command(device, bytes: flushUnmappedBlob, memory: memory), 0) == 0x1100)
    #expect(!aperture.isMapped)
    #expect(authority.blobFlushIdentities.count == 1)

    let shadowed = header(0x010C) + littleEndian(UInt32(83))
      + littleEndian(UInt32(3)) + littleEndian(UInt32(1)) + littleEndian(UInt32(1))
      + littleEndian(UInt64(0xBCDE)) + littleEndian(UInt64(4_096))
      + littleEndian(UInt64(0x8000)) + littleEndian(UInt32(4_096))
      + littleEndian(UInt32(0))
    #expect(read32(try command(device, bytes: shadowed, memory: memory), 0) == 0x1100)
    #expect(authority.operations.last == "blob-create:83:4096:1")

    let detach = header(0x0107) + littleEndian(UInt32(83)) + littleEndian(UInt32(0))
    #expect(read32(try command(device, bytes: detach, memory: memory), 0) == 0x1100)
    #expect(authority.operations.last == "blob-backing-detach:83:1")
    let attach = header(0x0106) + littleEndian(UInt32(83)) + littleEndian(UInt32(1))
      + littleEndian(UInt64(0x8000)) + littleEndian(UInt32(4_096))
      + littleEndian(UInt32(0))
    #expect(read32(try command(device, bytes: attach, memory: memory), 0) == 0x1100)
    #expect(authority.operations.last == "blob-backing-attach:83:1:1")
    #expect(read32(try command(device, bytes: attach, memory: memory), 0) == 0x1203)

    let invalidHostShadow = header(0x010C) + littleEndian(UInt32(84))
      + littleEndian(UInt32(2)) + littleEndian(UInt32(1)) + littleEndian(UInt32(1))
      + littleEndian(UInt64(0xCDEF)) + littleEndian(UInt64(4_096))
      + littleEndian(UInt64(0x8000)) + littleEndian(UInt32(4_096))
      + littleEndian(UInt32(0))
    #expect(read32(try command(
      device, bytes: invalidHostShadow, memory: memory), 0) == 0x1205)
    #expect(authority.operations.last == "blob-backing-attach:83:1:1")

    #expect(read32(try command(
      device, bytes: create(resourceID: 85, blobMemory: 2), memory: memory), 0) == 0x1100)
    let bindUnmappedHostBlob = header(0x010D) + displayRect
      + littleEndian(UInt32(1)) + littleEndian(UInt32(85))
      + littleEndian(UInt32(16)) + littleEndian(UInt32(16))
      + littleEndian(UInt32(1)) + littleEndian(UInt32(0))
      + [UInt32(64), 0, 0, 0].flatMap(littleEndian)
      + [UInt32(0), 0, 0, 0].flatMap(littleEndian)
    #expect(read32(try command(device, bytes: bindUnmappedHostBlob, memory: memory), 0) == 0x1100)
    let flushUnmappedHostBlob = header(0x0104) + displayRect
      + littleEndian(UInt32(85)) + littleEndian(UInt32(0))
    #expect(read32(try command(device, bytes: flushUnmappedHostBlob, memory: memory), 0) == 0x1100)
    #expect(!aperture.isMapped)
    #expect(authority.blobFlushIdentities.count == 2)
  }

  @Test func guestOnlyBlobWithZeroBlobIDReachesRenderer() throws {
    let authority = try GPUAccelerationAuthority(
      features: [.gpuVirgl, .gpuResourceBlob],
      capsets: [.init(id: 2, maximumVersion: 2, data: [1])]
    )
    let device = try makeDevice(
      authority: authority,
      hostVisibleAperture: GPUHostVisibleAperture()
    )
    let memory = GPUGuestMemory(byteCount: 0x20_000)
    let create = header(0x010C) + littleEndian(UInt32(86))
      + littleEndian(UInt32(1)) + littleEndian(UInt32(0)) + littleEndian(UInt32(1))
      + littleEndian(UInt64(0)) + littleEndian(UInt64(4_096))
      + littleEndian(UInt64(0x8000)) + littleEndian(UInt32(4_096))
      + littleEndian(UInt32(0))
    #expect(read32(try command(device, bytes: create, memory: memory), 0) == 0x1100)
    #expect(authority.operations == ["blob-create:86:4096:1"])
  }

  @Test func invalidBlobBackingAddressReturnsGuestErrorWithoutFailingGPU() throws {
    let authority = try GPUAccelerationAuthority(
      features: [.gpuVirgl, .gpuResourceBlob],
      capsets: [.init(id: 2, maximumVersion: 2, data: [1])]
    )
    let device = try makeDevice(
      authority: authority,
      hostVisibleAperture: GPUHostVisibleAperture()
    )
    let memory = GPUGuestMemory(byteCount: 0x20_000)
    func create(backingAddress: UInt64) -> [UInt8] {
      header(0x010C) + littleEndian(UInt32(87))
        + littleEndian(UInt32(1)) + littleEndian(UInt32(0)) + littleEndian(UInt32(1))
        + littleEndian(UInt64(0)) + littleEndian(UInt64(4_096))
        + littleEndian(backingAddress) + littleEndian(UInt32(4_096))
        + littleEndian(UInt32(0))
    }
    let invalidAddress: UInt64 = 0x1_F800
    #expect(read32(try command(
      device, bytes: create(backingAddress: invalidAddress), memory: memory
    ), 0) == 0x1205)
    #expect(authority.operations.isEmpty)
    #expect(read32(try command(
      device, bytes: create(backingAddress: 0x8000), memory: memory
    ), 0) == 0x1100)
    let detach = header(0x0107) + littleEndian(UInt32(87)) + littleEndian(UInt32(0))
    #expect(read32(try command(device, bytes: detach, memory: memory), 0) == 0x1100)
    let operationsAfterDetach = authority.operations
    func attach(backingAddress: UInt64) -> [UInt8] {
      header(0x0106) + littleEndian(UInt32(87)) + littleEndian(UInt32(1))
        + littleEndian(backingAddress) + littleEndian(UInt32(4_096))
        + littleEndian(UInt32(0))
    }
    #expect(read32(try command(
      device, bytes: attach(backingAddress: invalidAddress), memory: memory
    ), 0) == 0x1205)
    #expect(authority.operations == operationsAfterDetach)
    #expect(read32(try command(
      device, bytes: attach(backingAddress: 0x8000), memory: memory
    ), 0) == 0x1100)
    #expect(authority.operations.last == "blob-backing-attach:87:1:1")
  }

  @Test func rendererBackingChangesCannotBeOvertakenByUnref() throws {
    let authority = try GPUAccelerationAuthority(
      features: [.gpuVirgl],
      capsets: [.init(id: 2, maximumVersion: 2, data: [1])]
    )
    let device = try makeDevice(authority: authority)
    let memory = GPUGuestMemory(byteCount: 0x20_000)
    let heldMemory = GPUGuestMemory(byteCount: 0x20_000)
    let create = header(0x0204)
      + [UInt32(91), 2, 1, 2, 4, 4, 1, 1, 0, 0, 0, 0].flatMap(littleEndian)
    let attach = header(0x0106) + littleEndian(UInt32(91)) + littleEndian(UInt32(1))
      + littleEndian(UInt64(0x8000)) + littleEndian(UInt32(4_096))
      + littleEndian(UInt32(0))
    let unref = header(0x0102) + littleEndian(UInt32(91)) + littleEndian(UInt32(0))
    let detach = header(0x0107) + littleEndian(UInt32(91)) + littleEndian(UInt32(0))
    #expect(read32(try command(device, bytes: create, memory: memory), 0) == 0x1100)
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    let recorded = GPUResponseRecorder()
    authority.holdNextBackingAttach(entered: entered, release: release)
    gpuTestExecutionThread {
      if let result = try? command(device, bytes: attach, memory: heldMemory) {
        recorded.append(result)
      }
      finished.signal()
    }
    guard entered.wait(timeout: .now() + 2) == .success else {
      release.signal()
      Issue.record("renderer backing attach did not reach its reservation barrier")
      return
    }
    #expect(read32(try command(device, bytes: unref, memory: memory), 0) == 0x1203)
    #expect(read32(try command(device, bytes: attach, memory: memory), 0) == 0x1203)
    #expect(authority.operations == ["resource-create:91:4x4", "backing-attach:91:1"])
    release.signal()
    #expect(finished.wait(timeout: .now() + 2) == .success)
    #expect(recorded.values.first.map { read32($0, 0) } == 0x1100)
    let detachEntered = DispatchSemaphore(value: 0)
    let detachRelease = DispatchSemaphore(value: 0)
    let detachFinished = DispatchSemaphore(value: 0)
    let detachRecorded = GPUResponseRecorder()
    authority.holdNextBackingDetach(entered: detachEntered, release: detachRelease)
    gpuTestExecutionThread {
      if let result = try? command(device, bytes: detach, memory: heldMemory) {
        detachRecorded.append(result)
      }
      detachFinished.signal()
    }
    guard detachEntered.wait(timeout: .now() + 2) == .success else {
      detachRelease.signal()
      Issue.record("renderer backing detach did not reach its reservation barrier")
      return
    }
    #expect(read32(try command(device, bytes: unref, memory: memory), 0) == 0x1203)
    #expect(read32(try command(device, bytes: detach, memory: memory), 0) == 0x1203)
    detachRelease.signal()
    #expect(detachFinished.wait(timeout: .now() + 2) == .success)
    #expect(detachRecorded.values.first.map { read32($0, 0) } == 0x1100)
    #expect(read32(try command(device, bytes: unref, memory: memory), 0) == 0x1100)
  }

  @Test func rendererTransferCannotBeOvertakenByResourceOrContextTeardown() throws {
    let authority = try GPUAccelerationAuthority(
      features: [.gpuVirgl],
      capsets: [.init(id: 2, maximumVersion: 2, data: [1])]
    )
    let device = try makeDevice(authority: authority)
    let memory = GPUGuestMemory(byteCount: 0x20_000)
    let heldMemory = GPUGuestMemory(byteCount: 0x20_000)
    let contextID: UInt32 = 32
    let createContext = header(0x0200, contextID: contextID)
      + littleEndian(UInt32(0)) + littleEndian(UInt32(2))
      + [UInt8](repeating: 0, count: 64)
    let create = header(0x0204)
      + [UInt32(92), 2, 1, 2, 4, 4, 1, 1, 0, 0, 0, 0].flatMap(littleEndian)
    let attach = header(0x0106) + littleEndian(UInt32(92)) + littleEndian(UInt32(1))
      + littleEndian(UInt64(0x8000)) + littleEndian(UInt32(4_096))
      + littleEndian(UInt32(0))
    let transfer = header(0x0205, contextID: contextID)
      + [UInt32(0), 0, 0, 4, 4, 1].flatMap(littleEndian)
      + littleEndian(UInt64(0)) + [UInt32(92), 0, 16, 64].flatMap(littleEndian)
    let unref = header(0x0102) + littleEndian(UInt32(92)) + littleEndian(UInt32(0))
    let detach = header(0x0107) + littleEndian(UInt32(92)) + littleEndian(UInt32(0))
    let destroyContext = header(0x0201, contextID: contextID)
    #expect(read32(try command(device, bytes: createContext, memory: memory), 0) == 0x1100)
    #expect(read32(try command(device, bytes: create, memory: memory), 0) == 0x1100)
    #expect(read32(try command(device, bytes: attach, memory: memory), 0) == 0x1100)
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    let recorded = GPUResponseRecorder()
    authority.holdNextTransfer(entered: entered, release: release)
    gpuTestExecutionThread {
      if let result = try? command(device, bytes: transfer, memory: heldMemory) {
        recorded.append(result)
      }
      finished.signal()
    }
    guard entered.wait(timeout: .now() + 2) == .success else {
      release.signal()
      Issue.record("renderer transfer did not reach its reservation barrier")
      return
    }
    #expect(read32(try command(device, bytes: unref, memory: memory), 0) == 0x1203)
    #expect(read32(try command(device, bytes: detach, memory: memory), 0) == 0x1203)
    #expect(read32(try command(device, bytes: destroyContext, memory: memory), 0) == 0x1205)
    release.signal()
    #expect(finished.wait(timeout: .now() + 2) == .success)
    #expect(recorded.values.first.map { read32($0, 0) } == 0x1100)
    #expect(read32(try command(device, bytes: detach, memory: memory), 0) == 0x1100)
    #expect(read32(try command(device, bytes: unref, memory: memory), 0) == 0x1100)
    #expect(read32(try command(device, bytes: destroyContext, memory: memory), 0) == 0x1100)
  }

  @Test func rendererContextMutationCannotBeOvertakenByDestroyOrResourceUnref() throws {
    let authority = try GPUAccelerationAuthority(
      features: [.gpuVirgl],
      capsets: [.init(id: 2, maximumVersion: 2, data: [1])]
    )
    let device = try makeDevice(authority: authority)
    let memory = GPUGuestMemory(byteCount: 0x20_000)
    let heldMemory = GPUGuestMemory(byteCount: 0x20_000)
    let contextID: UInt32 = 31
    let resourceID: UInt32 = 93
    let createContext = header(0x0200, contextID: contextID)
      + littleEndian(UInt32(0)) + littleEndian(UInt32(2))
      + [UInt8](repeating: 0, count: 64)
    let createResource = header(0x0204)
      + [resourceID, 2, 1, 2, 4, 4, 1, 1, 0, 0, 0, 0].flatMap(littleEndian)
    let attach = header(0x0202, contextID: contextID)
      + littleEndian(resourceID) + littleEndian(UInt32(0))
    let detach = header(0x0203, contextID: contextID)
      + littleEndian(resourceID) + littleEndian(UInt32(0))
    let destroy = header(0x0201, contextID: contextID)
    let unref = header(0x0102) + littleEndian(resourceID) + littleEndian(UInt32(0))
    #expect(read32(try command(device, bytes: createContext, memory: memory), 0) == 0x1100)
    #expect(read32(try command(device, bytes: createResource, memory: memory), 0) == 0x1100)

    let attachEntered = DispatchSemaphore(value: 0)
    let attachRelease = DispatchSemaphore(value: 0)
    let attachFinished = DispatchSemaphore(value: 0)
    let attachRecorded = GPUResponseRecorder()
    authority.holdNextContextAttach(entered: attachEntered, release: attachRelease)
    gpuTestExecutionThread {
      if let result = try? command(device, bytes: attach, memory: heldMemory) {
        attachRecorded.append(result)
      }
      attachFinished.signal()
    }
    guard attachEntered.wait(timeout: .now() + 2) == .success else {
      attachRelease.signal()
      Issue.record("renderer context attach did not reach its reservation barrier")
      return
    }
    #expect(read32(try command(device, bytes: destroy, memory: memory), 0) == 0x1205)
    #expect(read32(try command(device, bytes: detach, memory: memory), 0) == 0x1205)
    #expect(read32(try command(device, bytes: unref, memory: memory), 0) == 0x1203)
    attachRelease.signal()
    #expect(attachFinished.wait(timeout: .now() + 2) == .success)
    #expect(attachRecorded.values.first.map { read32($0, 0) } == 0x1100)

    let destroyEntered = DispatchSemaphore(value: 0)
    let destroyRelease = DispatchSemaphore(value: 0)
    let destroyFinished = DispatchSemaphore(value: 0)
    let destroyRecorded = GPUResponseRecorder()
    authority.holdNextContextDestroy(entered: destroyEntered, release: destroyRelease)
    gpuTestExecutionThread {
      if let result = try? command(device, bytes: destroy, memory: heldMemory) {
        destroyRecorded.append(result)
      }
      destroyFinished.signal()
    }
    guard destroyEntered.wait(timeout: .now() + 2) == .success else {
      destroyRelease.signal()
      Issue.record("renderer context destroy did not reach its reservation barrier")
      return
    }
    #expect(read32(try command(device, bytes: attach, memory: memory), 0) == 0x1205)
    destroyRelease.signal()
    #expect(destroyFinished.wait(timeout: .now() + 2) == .success)
    #expect(destroyRecorded.values.first.map { read32($0, 0) } == 0x1100)
    #expect(read32(try command(device, bytes: unref, memory: memory), 0) == 0x1100)
  }

  @Test func failedLocalBlobMapRetiresWorkerMapBeforeRetry() throws {
    let authority = try GPUAccelerationAuthority(
      features: [.gpuVirgl, .gpuResourceBlob],
      capsets: [.init(id: 2, maximumVersion: 2, data: [1])]
    )
    let aperture = GPUHostVisibleAperture()
    let device = try makeDevice(authority: authority, hostVisibleAperture: aperture)
    let memory = GPUGuestMemory(byteCount: 0x20_000)
    let resourceID: UInt32 = 42
    let create =
      header(0x010C) + littleEndian(resourceID) + littleEndian(UInt32(2))
      + littleEndian(UInt32(1)) + littleEndian(UInt32(0))
      + littleEndian(UInt64(0)) + littleEndian(UInt64(4_096))
    let map =
      header(0x0208) + littleEndian(resourceID) + littleEndian(UInt32(0))
      + littleEndian(UInt64(0x4000))
    let unmap = header(0x0209) + littleEndian(resourceID) + littleEndian(UInt32(0))
    #expect(read32(try command(device, bytes: create, memory: memory), 0) == 0x1100)

    aperture.rejectNextMap()
    #expect(read32(try command(device, bytes: map, memory: memory), 0) == 0x1205)
    #expect(!aperture.isMapped)
    #expect(authority.operations.suffix(2) == [
      "blob-map:42:1:4096", "blob-unmap-local:42:1:true",
    ])

    for reservedCacheMode in [UInt32(4), 15, 16] {
      authority.setMapInfo(reservedCacheMode)
      #expect(read32(try command(device, bytes: map, memory: memory), 0) == 0x1205)
      #expect(!aperture.isMapped)
      #expect(authority.operations.suffix(2) == [
        "blob-map:42:1:4096", "blob-unmap-local:42:1:true",
      ])
    }

    authority.setMapInfo(0)
    let cacheNoneReply = try command(device, bytes: map, responseBytes: 32, memory: memory)
    #expect(read32(cacheNoneReply, 0) == 0x1106)
    #expect(read32(cacheNoneReply, 24) == 0)
    #expect(aperture.isMapped)
    #expect(read32(try command(device, bytes: unmap, memory: memory), 0) == 0x1100)
    #expect(!aperture.isMapped)

    authority.setMapInfo(3)
    #expect(read32(try command(device, bytes: map, responseBytes: 32, memory: memory), 0) == 0x1106)
    #expect(aperture.isMapped)
    #expect(read32(try command(device, bytes: unmap, memory: memory), 0) == 0x1100)
    #expect(!aperture.isMapped)
    #expect(authority.resetCount == 0)
  }

  @Test func concurrentBlobCommandsCannotOvertakeAnInFlightMap() throws {
    let authority = try GPUAccelerationAuthority(
      features: [.gpuVirgl, .gpuResourceBlob],
      capsets: [.init(id: 2, maximumVersion: 2, data: [1])]
    )
    let aperture = GPUHostVisibleAperture()
    let device = try makeDevice(authority: authority, hostVisibleAperture: aperture)
    let memory = GPUGuestMemory(byteCount: 0x20_000)
    let resourceID: UInt32 = 48
    let create =
      header(0x010C) + littleEndian(resourceID) + littleEndian(UInt32(2))
      + littleEndian(UInt32(1)) + littleEndian(UInt32(0))
      + littleEndian(UInt64(0)) + littleEndian(UInt64(4_096))
    let map = header(0x0208) + littleEndian(resourceID) + littleEndian(UInt32(0))
      + littleEndian(UInt64(0x4000))
    let unmap = header(0x0209) + littleEndian(resourceID) + littleEndian(UInt32(0))
    let unref = header(0x0102) + littleEndian(resourceID) + littleEndian(UInt32(0))
    #expect(read32(try command(device, bytes: create, memory: memory), 0) == 0x1100)

    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    let response = GPUResponseRecorder()
    let concurrentMemory = GPUGuestMemory(byteCount: 0x20_000)
    concurrentMemory.put(map, at: 0x1000)
    let chain = DoryVirtioDescriptorChain(
      headIndex: 0,
      descriptors: [
        .init(address: 0x1000, length: UInt32(map.count), flags: 0, next: 1),
        .init(address: 0x4000, length: 32, flags: 2, next: 0),
      ],
      readableByteCount: UInt64(map.count),
      writableByteCount: 32
    )
    authority.holdNextMap(entered: entered, release: release)
    gpuTestExecutionThread {
      if let written = try? device.process(queue: 0, chain: chain, memory: concurrentMemory),
        let bytes = try? concurrentMemory.read(at: 0x4000, byteCount: Int(written))
      {
        response.append(bytes)
      }
      finished.signal()
    }
    guard entered.wait(timeout: .now() + 2) == .success else {
      release.signal()
      Issue.record("renderer map did not reach the concurrency barrier")
      return
    }
    #expect(read32(try command(device, bytes: map, responseBytes: 32, memory: memory), 0)
      == 0x1203)
    #expect(read32(try command(device, bytes: unmap, memory: memory), 0) == 0x1203)
    #expect(read32(try command(device, bytes: unref, memory: memory), 0) == 0x1203)
    release.signal()
    #expect(finished.wait(timeout: .now() + 2) == .success)
    #expect(response.values.first.map { read32($0, 0) } == 0x1106)
    #expect(aperture.isMapped)
    #expect(authority.operations.filter { $0.hasPrefix("blob-map:48:") }.count == 1)
    #expect(!authority.operations.contains("resource-unref:48"))
    #expect(read32(try command(device, bytes: unmap, memory: memory), 0) == 0x1100)
  }

  @Test func scanoutCannotBindOrFlushWhileBlobUnmapIsInFlight() throws {
    let authority = try GPUAccelerationAuthority(
      features: [.gpuVirgl, .gpuResourceBlob],
      capsets: [.init(id: 2, maximumVersion: 2, data: [1])]
    )
    let aperture = GPUHostVisibleAperture()
    let device = try makeDevice(authority: authority, hostVisibleAperture: aperture)
    let memory = GPUGuestMemory(byteCount: 0x20_000)
    let resourceID: UInt32 = 49
    let create = header(0x010C) + littleEndian(resourceID) + littleEndian(UInt32(2))
      + littleEndian(UInt32(1)) + littleEndian(UInt32(0))
      + littleEndian(UInt64(0)) + littleEndian(UInt64(16_384))
    let map = header(0x0208) + littleEndian(resourceID) + littleEndian(UInt32(0))
      + littleEndian(UInt64(0x4000))
    let unmap = header(0x0209) + littleEndian(resourceID) + littleEndian(UInt32(0))
    let rectangle = rect(x: 0, y: 0, width: 64, height: 32)
    let bind = header(0x010D) + rectangle + littleEndian(UInt32(0))
      + littleEndian(resourceID) + littleEndian(UInt32(64))
      + littleEndian(UInt32(32)) + littleEndian(UInt32(1))
      + littleEndian(UInt32(0))
      + [UInt32(256), 0, 0, 0].flatMap(littleEndian)
      + [UInt32](repeating: 0, count: 4).flatMap(littleEndian)
    let flush = header(0x0104) + rectangle + littleEndian(resourceID)
      + littleEndian(UInt32(0))
    #expect(bind.count == 96)
    #expect(read32(try command(device, bytes: create, memory: memory), 0) == 0x1100)
    #expect(read32(try command(device, bytes: map, responseBytes: 32, memory: memory), 0)
      == 0x1106)

    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    let response = GPUResponseRecorder()
    let concurrentMemory = GPUGuestMemory(byteCount: 0x20_000)
    concurrentMemory.put(unmap, at: 0x1000)
    let chain = DoryVirtioDescriptorChain(
      headIndex: 0,
      descriptors: [
        .init(address: 0x1000, length: UInt32(unmap.count), flags: 0, next: 1),
        .init(address: 0x4000, length: 24, flags: 2, next: 0),
      ],
      readableByteCount: UInt64(unmap.count),
      writableByteCount: 24
    )
    authority.holdNextUnmap(entered: entered, release: release)
    gpuTestExecutionThread {
      if let written = try? device.process(queue: 0, chain: chain, memory: concurrentMemory),
        let bytes = try? concurrentMemory.read(at: 0x4000, byteCount: Int(written))
      {
        response.append(bytes)
      }
      finished.signal()
    }
    guard entered.wait(timeout: .now() + 2) == .success else {
      release.signal()
      Issue.record("renderer unmap did not reach the concurrency barrier")
      return
    }
    #expect(read32(try command(device, bytes: bind, memory: memory), 0) == 0x1203)
    #expect(read32(try command(device, bytes: flush, memory: memory), 0) == 0x1203)
    release.signal()
    #expect(finished.wait(timeout: .now() + 2) == .success)
    #expect(response.values.first.map { read32($0, 0) } == 0x1100)
    #expect(!aperture.isMapped)
    // UNMAP_BLOB retires the CPU aperture alias, not the renderer-owned blob resource.
    // A new scanout bind becomes valid once the in-flight unmap has completed.
    #expect(read32(try command(device, bytes: bind, memory: memory), 0) == 0x1100)
    #expect(read32(try command(device, bytes: flush, memory: memory), 0) == 0x1100)
  }

  @Test func revokedBlobFlushResetsTheMappedApertureAndScanoutBinding() throws {
    let authority = try GPUAccelerationAuthority(
      features: [.gpuVirgl, .gpuResourceBlob],
      capsets: [.init(id: 2, maximumVersion: 2, data: [1])]
    )
    let aperture = GPUHostVisibleAperture()
    let device = try makeDevice(authority: authority, hostVisibleAperture: aperture)
    let memory = GPUGuestMemory(byteCount: 0x20_000)
    let resourceID: UInt32 = 47
    let create =
      header(0x010C) + littleEndian(resourceID) + littleEndian(UInt32(2))
      + littleEndian(UInt32(1)) + littleEndian(UInt32(0))
      + littleEndian(UInt64(0)) + littleEndian(UInt64(16_384))
    let map =
      header(0x0208) + littleEndian(resourceID) + littleEndian(UInt32(0))
      + littleEndian(UInt64(0x4000))
    let rectangle = rect(x: 0, y: 0, width: 64, height: 32)
    let bind =
      header(0x010D) + rectangle + littleEndian(UInt32(0)) + littleEndian(resourceID)
      + littleEndian(UInt32(64)) + littleEndian(UInt32(32)) + littleEndian(UInt32(1))
      + littleEndian(UInt32(0))
      + [UInt32(256), 0, 0, 0].flatMap(littleEndian)
      + [UInt32](repeating: 0, count: 4).flatMap(littleEndian)
    let flush = header(0x0104) + rectangle + littleEndian(resourceID) + littleEndian(UInt32(0))
    #expect(read32(try command(device, bytes: create, memory: memory), 0) == 0x1100)
    #expect(read32(try command(device, bytes: map, responseBytes: 32, memory: memory), 0) == 0x1106)
    #expect(read32(try command(device, bytes: bind, memory: memory), 0) == 0x1100)

    authority.setRevokeFlush(true)
    #expect(read32(try command(device, bytes: flush, memory: memory), 0) == 0x1205)
    #expect(authority.blobFlushIdentities == [
      .init(workspaceID: gpuTestWorkspaceID,
            resourceGeneration: 1, workerGeneration: 9, deviceGeneration: 7)
    ])
    #expect(authority.resetCount == 1)
    #expect(aperture.resetCount == 1)
    #expect(!aperture.isMapped)
    #expect(read32(try command(device, bytes: flush, memory: memory), 0) == 0x1203)
  }

  @Test func blobCreateAcceptedBeforeResetCannotCommitOrUnrefAReusedID() throws {
    let authority = try GPUAccelerationAuthority(
      features: [.gpuVirgl, .gpuResourceBlob],
      capsets: [.init(id: 2, maximumVersion: 2, data: [1])]
    )
    let aperture = GPUHostVisibleAperture()
    let device = try makeDevice(authority: authority, hostVisibleAperture: aperture)
    let memory = GPUGuestMemory(byteCount: 0x20_000)
    let create =
      header(0x010C) + littleEndian(UInt32(46)) + littleEndian(UInt32(2))
      + littleEndian(UInt32(1)) + littleEndian(UInt32(0))
      + littleEndian(UInt64(0)) + littleEndian(UInt64(4_096))
    memory.put(create, at: 0x1000)
    let chain = DoryVirtioDescriptorChain(
      headIndex: 0,
      descriptors: [
        .init(address: 0x1000, length: UInt32(create.count), flags: 0, next: 1),
        .init(address: 0x4000, length: 24, flags: 2, next: 0),
      ],
      readableByteCount: UInt64(create.count),
      writableByteCount: 24
    )
    let createEntered = DispatchSemaphore(value: 0)
    let releaseCreate = DispatchSemaphore(value: 0)
    let createFinished = DispatchSemaphore(value: 0)
    let response = GPUResponseRecorder()
    authority.holdNextCreate(entered: createEntered, release: releaseCreate)
    gpuTestExecutionThread {
      if let written = try? device.process(queue: 0, chain: chain, memory: memory),
        let bytes = try? memory.read(at: 0x4000, byteCount: Int(written))
      {
        response.append(bytes)
      }
      createFinished.signal()
    }
    guard createEntered.wait(timeout: .now() + 2) == .success else {
      releaseCreate.signal()
      Issue.record("renderer create did not reach the reset barrier")
      return
    }
    device.reset()
    releaseCreate.signal()
    #expect(createFinished.wait(timeout: .now() + 2) == .success)
    #expect(response.values.first.map { read32($0, 0) } == 0x1203)
    #expect(device.commandDiagnostics.resetCount == 2)
    #expect(authority.resetCount == 2)
    #expect(aperture.resetCount == 2)
    #expect(!authority.operations.contains("resource-unref:46"))
    let map = header(0x0208) + littleEndian(UInt32(46)) + littleEndian(UInt32(0))
      + littleEndian(UInt64(0x4000))
    #expect(read32(try command(device, bytes: map, responseBytes: 32, memory: memory), 0)
      == 0x1203)
  }

  @Test func contextCreateCompletingAfterResetCannotRepopulateLocalState() throws {
    let authority = try GPUAccelerationAuthority(
      features: [.gpuVirgl, .gpuContextInit],
      capsets: [.init(id: 2, maximumVersion: 2, data: [1])]
    )
    let device = try makeDevice(authority: authority)
    let memory = GPUGuestMemory(byteCount: 0x20_000)
    var name = [UInt8](repeating: 0, count: 64)
    name.replaceSubrange(0..<4, with: Array("mesa".utf8))
    let create = header(0x0200, contextID: 17) + littleEndian(UInt32(4))
      + littleEndian(UInt32(2)) + name
    memory.put(create, at: 0x1000)
    let chain = DoryVirtioDescriptorChain(
      headIndex: 0,
      descriptors: [
        .init(address: 0x1000, length: UInt32(create.count), flags: 0, next: 1),
        .init(address: 0x4000, length: 24, flags: 2, next: 0),
      ],
      readableByteCount: UInt64(create.count),
      writableByteCount: 24
    )
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    let response = GPUResponseRecorder()
    authority.holdNextContextCreate(entered: entered, release: release)
    gpuTestExecutionThread {
      if let written = try? device.process(queue: 0, chain: chain, memory: memory),
        let bytes = try? memory.read(at: 0x4000, byteCount: Int(written))
      {
        response.append(bytes)
      }
      finished.signal()
    }
    guard entered.wait(timeout: .now() + 2) == .success else {
      release.signal()
      Issue.record("renderer context create did not reach the reset barrier")
      return
    }
    device.reset()
    release.signal()
    #expect(finished.wait(timeout: .now() + 2) == .success)
    #expect(response.values.first.map { read32($0, 0) } == 0x1205)
    #expect(device.commandDiagnostics.resetCount == 2)
    let submit = header(0x0207, contextID: 17) + littleEndian(UInt32(4))
      + littleEndian(UInt32(0)) + [1, 2, 3, 4]
    #expect(read32(try command(device, bytes: submit, memory: memory), 0) == 0x1205)
    #expect(!authority.operations.contains(where: { $0.hasPrefix("submit:") }))
  }

  @Test func staleWorkerMapReplyRollsBackWithoutPublishingAnAlias() throws {
    let authority = try GPUAccelerationAuthority(
      features: [.gpuVirgl, .gpuResourceBlob],
      capsets: [.init(id: 2, maximumVersion: 2, data: [1])]
    )
    let aperture = GPUHostVisibleAperture()
    let device = try makeDevice(authority: authority, hostVisibleAperture: aperture)
    let memory = GPUGuestMemory(byteCount: 0x20_000)
    let create = header(0x010C) + littleEndian(UInt32(47)) + littleEndian(UInt32(2))
      + littleEndian(UInt32(1)) + littleEndian(UInt32(0))
      + littleEndian(UInt64(0)) + littleEndian(UInt64(4_096))
    #expect(read32(try command(device, bytes: create, memory: memory), 0) == 0x1100)

    authority.setNextMapWorkerGeneration(10)
    let map = header(0x0208) + littleEndian(UInt32(47)) + littleEndian(UInt32(0))
      + littleEndian(UInt64(0x4000))
    #expect(read32(try command(device, bytes: map, responseBytes: 32, memory: memory), 0)
      == 0x1205)
    #expect(!aperture.isMapped)
    #expect(authority.resetCount == 0)
    #expect(authority.operations == [
      "blob-create:47:4096:0",
      "blob-map:47:1:4096",
      "blob-unmap-local:47:1:true",
    ])

    authority.setNextMapWorkspaceID(
      UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
    )
    #expect(read32(try command(device, bytes: map, responseBytes: 32, memory: memory), 0)
      == 0x1205)
    #expect(!aperture.isMapped)
    #expect(authority.resetCount == 0)
    #expect(authority.operations.suffix(2) == [
      "blob-map:47:1:4096", "blob-unmap-local:47:1:true",
    ])
  }

  @Test func failedBlobMapRollbackRevokesDeviceGeneration() throws {
    let authority = try GPUAccelerationAuthority(
      features: [.gpuVirgl, .gpuResourceBlob],
      capsets: [.init(id: 2, maximumVersion: 2, data: [1])]
    )
    let aperture = GPUHostVisibleAperture()
    let device = try makeDevice(authority: authority, hostVisibleAperture: aperture)
    let memory = GPUGuestMemory(byteCount: 0x20_000)
    let resourceID: UInt32 = 43
    let create =
      header(0x010C) + littleEndian(resourceID) + littleEndian(UInt32(2))
      + littleEndian(UInt32(1)) + littleEndian(UInt32(0))
      + littleEndian(UInt64(0)) + littleEndian(UInt64(4_096))
    let map =
      header(0x0208) + littleEndian(resourceID) + littleEndian(UInt32(0))
      + littleEndian(UInt64(0x4000))
    #expect(read32(try command(device, bytes: create, memory: memory), 0) == 0x1100)

    aperture.rejectNextMap()
    authority.setRejectUnmap(true)
    #expect(read32(try command(device, bytes: map, memory: memory), 0) == 0x1205)
    #expect(!aperture.isMapped)
    #expect(authority.resetCount == 1)
    #expect(aperture.resetCount == 1)
    #expect(device.commandDiagnostics.resetCount == 1)
    #expect(read32(try command(device, bytes: map, memory: memory), 0) == 0x1203)
  }

  @Test func blobUnmapFailureBeforeLocalTeardownCanRetry() throws {
    let authority = try GPUAccelerationAuthority(
      features: [.gpuVirgl, .gpuResourceBlob],
      capsets: [.init(id: 2, maximumVersion: 2, data: [1])]
    )
    let aperture = GPUHostVisibleAperture()
    let device = try makeDevice(authority: authority, hostVisibleAperture: aperture)
    let memory = GPUGuestMemory(byteCount: 0x20_000)
    let resourceID: UInt32 = 44
    let create =
      header(0x010C) + littleEndian(resourceID) + littleEndian(UInt32(2))
      + littleEndian(UInt32(1)) + littleEndian(UInt32(0))
      + littleEndian(UInt64(0)) + littleEndian(UInt64(4_096))
    let map =
      header(0x0208) + littleEndian(resourceID) + littleEndian(UInt32(0))
      + littleEndian(UInt64(0x4000))
    let unmap = header(0x0209) + littleEndian(resourceID) + littleEndian(UInt32(0))
    #expect(read32(try command(device, bytes: create, memory: memory), 0) == 0x1100)
    #expect(read32(try command(device, bytes: map, responseBytes: 32, memory: memory), 0) == 0x1106)

    authority.setRejectUnmap(true)
    #expect(read32(try command(device, bytes: unmap, memory: memory), 0) == 0x1205)
    #expect(aperture.isMapped)
    #expect(device.commandDiagnostics.resetCount == 0)

    authority.setRejectUnmap(false)
    #expect(read32(try command(device, bytes: unmap, memory: memory), 0) == 0x1100)
    #expect(!aperture.isMapped)
  }

  @Test func blobUnmapFailureAfterLocalTeardownRevokesDeviceGeneration() throws {
    let authority = try GPUAccelerationAuthority(
      features: [.gpuVirgl, .gpuResourceBlob],
      capsets: [.init(id: 2, maximumVersion: 2, data: [1])]
    )
    let aperture = GPUHostVisibleAperture()
    let device = try makeDevice(authority: authority, hostVisibleAperture: aperture)
    let memory = GPUGuestMemory(byteCount: 0x20_000)
    let resourceID: UInt32 = 45
    let create =
      header(0x010C) + littleEndian(resourceID) + littleEndian(UInt32(2))
      + littleEndian(UInt32(1)) + littleEndian(UInt32(0))
      + littleEndian(UInt64(0)) + littleEndian(UInt64(4_096))
    let map =
      header(0x0208) + littleEndian(resourceID) + littleEndian(UInt32(0))
      + littleEndian(UInt64(0x4000))
    let unmap = header(0x0209) + littleEndian(resourceID) + littleEndian(UInt32(0))
    #expect(read32(try command(device, bytes: create, memory: memory), 0) == 0x1100)
    #expect(read32(try command(device, bytes: map, responseBytes: 32, memory: memory), 0) == 0x1106)

    authority.setFailAfterLocalUnmap(true)
    #expect(read32(try command(device, bytes: unmap, memory: memory), 0) == 0x1205)
    #expect(!aperture.isMapped)
    #expect(authority.resetCount == 1)
    #expect(aperture.resetCount == 1)
    #expect(device.commandDiagnostics.resetCount == 1)
    #expect(read32(try command(device, bytes: unmap, memory: memory), 0) == 0x1203)
  }

  @Test func revokedRendererGenerationRetiresExistingBlobAliases() throws {
    let authority = try GPUAccelerationAuthority(
      features: [.gpuVirgl, .gpuResourceBlob],
      capsets: [.init(id: 2, maximumVersion: 2, data: [1])]
    )
    let aperture = GPUHostVisibleAperture()
    let device = try makeDevice(authority: authority, hostVisibleAperture: aperture)
    let memory = GPUGuestMemory(byteCount: 0x20_000)
    for resourceID in [UInt32(46), 47] {
      let create =
        header(0x010C) + littleEndian(resourceID) + littleEndian(UInt32(2))
        + littleEndian(UInt32(1)) + littleEndian(UInt32(0))
        + littleEndian(UInt64(0)) + littleEndian(UInt64(4_096))
      #expect(read32(try command(device, bytes: create, memory: memory), 0) == 0x1100)
    }
    let firstMap =
      header(0x0208) + littleEndian(UInt32(46)) + littleEndian(UInt32(0))
      + littleEndian(UInt64(0x4000))
    let secondMap =
      header(0x0208) + littleEndian(UInt32(47)) + littleEndian(UInt32(0))
      + littleEndian(UInt64(0x8000))
    #expect(read32(try command(device, bytes: firstMap, responseBytes: 32, memory: memory), 0) == 0x1106)
    #expect(aperture.isMapped)

    authority.setRevokeMap(true)
    #expect(read32(try command(device, bytes: secondMap, memory: memory), 0) == 0x1205)
    #expect(!aperture.isMapped)
    #expect(authority.resetCount == 1)
    #expect(aperture.resetCount == 1)
    #expect(device.commandDiagnostics.resetCount == 1)
  }

  @Test func mapReplyAfterResetNeverInstallsAStaleApertureAlias() throws {
    let authority = try GPUAccelerationAuthority(
      features: [.gpuVirgl, .gpuResourceBlob],
      capsets: [.init(id: 2, maximumVersion: 2, data: [1])]
    )
    let aperture = GPUHostVisibleAperture()
    let device = try makeDevice(authority: authority, hostVisibleAperture: aperture)
    let memory = GPUGuestMemory(byteCount: 0x20_000)
    let resourceID: UInt32 = 48
    let create =
      header(0x010C) + littleEndian(resourceID) + littleEndian(UInt32(2))
      + littleEndian(UInt32(1)) + littleEndian(UInt32(0))
      + littleEndian(UInt64(0)) + littleEndian(UInt64(4_096))
    #expect(read32(try command(device, bytes: create, memory: memory), 0) == 0x1100)
    let map =
      header(0x0208) + littleEndian(resourceID) + littleEndian(UInt32(0))
      + littleEndian(UInt64(0x4000))
    memory.put(map, at: 0x1000)
    let chain = DoryVirtioDescriptorChain(
      headIndex: 0,
      descriptors: [
        .init(address: 0x1000, length: UInt32(map.count), flags: 0, next: 1),
        .init(address: 0x4000, length: 32, flags: 2, next: 0),
      ],
      readableByteCount: UInt64(map.count),
      writableByteCount: 32
    )
    let mapEntered = DispatchSemaphore(value: 0)
    let releaseMap = DispatchSemaphore(value: 0)
    let mapFinished = DispatchSemaphore(value: 0)
    let response = GPUResponseRecorder()
    authority.holdNextMap(entered: mapEntered, release: releaseMap)
    gpuTestExecutionThread {
      if let written = try? device.process(queue: 0, chain: chain, memory: memory),
        let bytes = try? memory.read(at: 0x4000, byteCount: Int(written))
      {
        response.append(bytes)
      }
      mapFinished.signal()
    }
    guard mapEntered.wait(timeout: .now() + 2) == .success else {
      releaseMap.signal()
      Issue.record("renderer map did not reach the reset barrier")
      return
    }
    device.reset()
    releaseMap.signal()
    #expect(mapFinished.wait(timeout: .now() + 2) == .success)
    #expect(response.values.first.map { read32($0, 0) } == 0x1205)
    #expect(!aperture.isMapped)
    #expect(aperture.resetCount == 1)
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
    #expect(read32(try command(
      device, bytes: header(0x0201, contextID: contextID), memory: memory
    ), 0) == 0x1205)
    authority.completeFence(at: 0, with: .signaled)
    let response = try #require(responses.values.first)
    #expect(read32(response, 0) == 0x1100)
    #expect(read32(response, 4) == 3)
    #expect(read64(response, 8) == 0)
    #expect(read32(response, 16) == contextID)
    #expect(response[20] == 2)
    #expect(read32(try command(
      device, bytes: header(0x0201, contextID: contextID), memory: memory
    ), 0) == 0x1100)
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

  @Test func oldFencedSubmitCannotCompleteSuccessfullyAfterGPUReset() throws {
    let authority = try GPUAccelerationAuthority(
      features: [.gpuVirgl, .gpuContextInit],
      capsets: [.init(id: 2, maximumVersion: 2, data: [1])]
    )
    let device = try makeDevice(authority: authority)
    let memory = GPUGuestMemory(byteCount: 0x20_000)
    let contextID: UInt32 = 34
    let createContext = header(0x0200, contextID: contextID)
      + littleEndian(UInt32(0)) + littleEndian(UInt32(2))
      + [UInt8](repeating: 0, count: 64)
    #expect(read32(try command(device, bytes: createContext, memory: memory), 0) == 0x1100)
    let submit = header(0x0207, flags: 1, fence: 7, contextID: contextID)
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
    device.reset()
    authority.completeFence(at: 0, with: .signaled)
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

  @Test func shortGuestBackingReadCannotPublishAPartialSoftwareFrame() throws {
    let sink = GPUDisplaySink()
    let device = try makeDevice(sink: sink)
    let memory = GPUGuestMemory(byteCount: 0x20_000)
    let rectangle = rect(x: 0, y: 0, width: 4, height: 2)
    let create = header(0x0101) + littleEndian(UInt32(7)) + littleEndian(UInt32(1))
      + littleEndian(UInt32(4)) + littleEndian(UInt32(2))
    let attach = header(0x0106) + littleEndian(UInt32(7)) + littleEndian(UInt32(1))
      + littleEndian(UInt64(0x8000)) + littleEndian(UInt32(32)) + littleEndian(UInt32(0))
    let transfer = header(0x0105) + rectangle + littleEndian(UInt64(0))
      + littleEndian(UInt32(7)) + littleEndian(UInt32(0))
    let bind = header(0x0103) + rectangle + littleEndian(UInt32(0))
      + littleEndian(UInt32(7))
    let flush = header(0x0104) + rectangle + littleEndian(UInt32(7))
      + littleEndian(UInt32(0))
    #expect(read32(try command(device, bytes: create, memory: memory), 0) == 0x1100)
    memory.put(Array(0..<32), at: 0x8000)
    #expect(read32(try command(device, bytes: attach, memory: memory), 0) == 0x1100)
    memory.shortenNextRead(at: 0x8000)
    #expect(throws: DoryVirtioGPUError.invalidGuestMemoryResponse(
      expected: 16, actual: 15
    )) {
      try command(device, bytes: transfer, memory: memory)
    }
    #expect(sink.frames.isEmpty)
    #expect(read32(try command(device, bytes: transfer, memory: memory), 0) == 0x1100)
    #expect(read32(try command(device, bytes: bind, memory: memory), 0) == 0x1100)
    #expect(read32(try command(device, bytes: flush, memory: memory), 0) == 0x1100)
    #expect(sink.frames.last?.pixels == Array(0..<32))
  }

  @Test func cursorPlaneSnapshotsMovesAndRetiresWithItsResource() throws {
    let sink = GPUDisplaySink()
    let device = try makeDevice(sink: sink)
    let memory = GPUGuestMemory(byteCount: 0x20_000)
    let resourceID: UInt32 = 37
    let pixels = [UInt8](repeating: 0x91, count: 64 * 64 * 4)
    let create = header(0x0101) + littleEndian(resourceID)
      + littleEndian(UInt32(1)) + littleEndian(UInt32(64)) + littleEndian(UInt32(64))
    #expect(read32(try command(device, bytes: create, memory: memory), 0) == 0x1100)
    memory.put(pixels, at: 0x8000)
    let attach = header(0x0106) + littleEndian(resourceID) + littleEndian(UInt32(1))
      + littleEndian(UInt64(0x8000)) + littleEndian(UInt32(pixels.count))
      + littleEndian(UInt32(0))
    #expect(read32(try command(device, bytes: attach, memory: memory), 0) == 0x1100)
    let transfer = header(0x0105) + rect(x: 0, y: 0, width: 64, height: 64)
      + littleEndian(UInt64(0)) + littleEndian(resourceID) + littleEndian(UInt32(0))
    #expect(read32(try command(device, bytes: transfer, memory: memory), 0) == 0x1100)

    func cursorRequest(_ kind: UInt32, x: UInt32, y: UInt32, resource: UInt32) -> [UInt8] {
      header(kind) + littleEndian(UInt32(0)) + littleEndian(x) + littleEndian(y)
        + littleEndian(UInt32(0)) + littleEndian(resource)
        + littleEndian(UInt32(3)) + littleEndian(UInt32(4)) + littleEndian(UInt32(0))
    }
    let update = cursorRequest(0x0300, x: 25, y: 35, resource: resourceID)
    #expect(update.count == 56)
    #expect(read32(try command(device, bytes: update, queue: 1, memory: memory), 0) == 0x1100)
    #expect(sink.cursors.last?.resourceID == resourceID)
    #expect(sink.cursors.last?.bytes == pixels)
    #expect(sink.cursors.last?.hotX == 3)
    #expect(sink.cursors.last?.hotY == 4)

    let move = cursorRequest(0x0301, x: 40, y: 50, resource: 0)
    #expect(read32(try command(device, bytes: move, queue: 1, memory: memory), 0) == 0x1100)
    #expect(sink.cursors.last?.x == 40)
    #expect(sink.cursors.last?.y == 50)
    #expect(sink.cursors.last?.bytes == pixels)

    let unref = header(0x0102) + littleEndian(resourceID) + littleEndian(UInt32(0))
    #expect(read32(try command(device, bytes: unref, memory: memory), 0) == 0x1100)
    #expect(sink.cursors.last?.resourceID == 0)
    #expect(sink.cursors.last?.bytes.isEmpty == true)
    #expect(read32(try command(device, bytes: update, queue: 1, memory: memory), 0) == 0x1203)
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

  @Test func softwareFramebuffersShareAnAggregateBudgetAndReleaseItOnUnrefOrReset() throws {
    let device = try DoryVirtioGPUDevice(
      scanouts: [.init(id: 0, rectangle: .init(x: 0, y: 0, width: 800, height: 600))],
      maximumResourceBytes: 64,
      maximumSoftwareResourceBytes: 64
    )
    let memory = GPUGuestMemory(byteCount: 0x5000)
    func create(_ resourceID: UInt32, width: UInt32 = 4) throws -> UInt32 {
      let request = header(0x0101) + littleEndian(resourceID) + littleEndian(UInt32(1))
        + littleEndian(width) + littleEndian(UInt32(2))
      return read32(try command(device, bytes: request, memory: memory), 0)
    }
    func unref(_ resourceID: UInt32) throws -> UInt32 {
      let request = header(0x0102) + littleEndian(resourceID) + littleEndian(UInt32(0))
      return read32(try command(device, bytes: request, memory: memory), 0)
    }

    #expect(try create(1) == 0x1100)
    #expect(try create(2) == 0x1100)
    #expect(try create(3) == 0x1201)
    #expect(try create(1) == 0x1203)
    #expect(try unref(1) == 0x1100)
    #expect(try create(3) == 0x1100)
    device.reset()
    #expect(try create(4, width: 8) == 0x1100)
  }

  @Test func softwareFramesCarryTheActualIncarnationAcrossIDReuseAndReset() throws {
    let sink = GPUDisplaySink()
    let device = try makeDevice(sink: sink)
    let memory = GPUGuestMemory(byteCount: 0x5000)
    let rectangle = rect(x: 0, y: 0, width: 4, height: 2)
    let create = header(0x0101) + littleEndian(UInt32(7)) + littleEndian(UInt32(1))
      + littleEndian(UInt32(4)) + littleEndian(UInt32(2))
    let unref = header(0x0102) + littleEndian(UInt32(7)) + littleEndian(UInt32(0))
    let bind = header(0x0103) + rectangle + littleEndian(UInt32(0))
      + littleEndian(UInt32(7))
    let flush = header(0x0104) + rectangle + littleEndian(UInt32(7))
      + littleEndian(UInt32(0))
    for incarnation in 1...3 {
      #expect(read32(try command(device, bytes: create, memory: memory), 0) == 0x1100)
      #expect(read32(try command(device, bytes: bind, memory: memory), 0) == 0x1100)
      #expect(read32(try command(device, bytes: flush, memory: memory), 0) == 0x1100)
      #expect(sink.frames.last?.resourceGeneration == UInt64(incarnation))
      if incarnation == 1 {
        #expect(read32(try command(device, bytes: unref, memory: memory), 0) == 0x1100)
      } else if incarnation == 2 {
        device.reset()
      }
    }
    #expect(sink.retiredResourceGenerations == [1, 2])
  }

  @Test func staleSoftwareTransferCannotWriteAReusedResourceID() throws {
    let sink = GPUDisplaySink()
    let device = try makeDevice(sink: sink)
    let memory = GPUGuestMemory(byteCount: 0x20_000)
    let create = header(0x0101) + littleEndian(UInt32(7)) + littleEndian(UInt32(1))
      + littleEndian(UInt32(4)) + littleEndian(UInt32(2))
    let attach = header(0x0106) + littleEndian(UInt32(7)) + littleEndian(UInt32(1))
      + littleEndian(UInt64(0x8000)) + littleEndian(UInt32(32)) + littleEndian(UInt32(0))
    let unref = header(0x0102) + littleEndian(UInt32(7)) + littleEndian(UInt32(0))
    #expect(read32(try command(device, bytes: create, memory: memory), 0) == 0x1100)
    #expect(read32(try command(device, bytes: attach, memory: memory), 0) == 0x1100)
    memory.put([UInt8](repeating: 0xA5, count: 32), at: 0x8000)

    let transfer = header(0x0105) + rect(x: 0, y: 0, width: 4, height: 2)
      + littleEndian(UInt64(0)) + littleEndian(UInt32(7)) + littleEndian(UInt32(0))
    memory.put(transfer, at: 0x1000)
    let chain = DoryVirtioDescriptorChain(
      headIndex: 0,
      descriptors: [
        .init(address: 0x1000, length: UInt32(transfer.count), flags: 0, next: 1),
        .init(address: 0x4000, length: 24, flags: 2, next: 0),
      ],
      readableByteCount: UInt64(transfer.count),
      writableByteCount: 24
    )
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    let response = GPUResponseRecorder()
    memory.holdNextRead(at: 0x8000, entered: entered, release: release)
    gpuTestExecutionThread {
      if let written = try? device.process(queue: 0, chain: chain, memory: memory),
        let bytes = try? memory.read(at: 0x4000, byteCount: Int(written))
      {
        response.append(bytes)
      }
      finished.signal()
    }
    guard entered.wait(timeout: .now() + 2) == .success else {
      release.signal()
      Issue.record("software transfer did not reach the guest-memory barrier")
      return
    }
    #expect(read32(try command(device, bytes: unref, memory: memory), 0) == 0x1100)
    #expect(read32(try command(device, bytes: create, memory: memory), 0) == 0x1100)
    #expect(read32(try command(device, bytes: attach, memory: memory), 0) == 0x1100)
    release.signal()
    #expect(finished.wait(timeout: .now() + 2) == .success)
    #expect(response.values.first.map { read32($0, 0) } == 0x1205)

    let rectangle = rect(x: 0, y: 0, width: 4, height: 2)
    let bind = header(0x0103) + rectangle + littleEndian(UInt32(0))
      + littleEndian(UInt32(7))
    let flush = header(0x0104) + rectangle + littleEndian(UInt32(7))
      + littleEndian(UInt32(0))
    #expect(read32(try command(device, bytes: bind, memory: memory), 0) == 0x1100)
    #expect(read32(try command(device, bytes: flush, memory: memory), 0) == 0x1100)
    #expect(sink.frames.last?.pixels == [UInt8](repeating: 0, count: 32))
  }

  @Test func preflightsInvalidLaterResponseTargetBeforeStateChange() throws {
    let device = try makeDevice()
    let memory = GPUGuestMemory(byteCount: 0x5000)
    let create =
      header(0x0101) + littleEndian(UInt32(7)) + littleEndian(UInt32(1))
      + littleEndian(UInt32(4)) + littleEndian(UInt32(2))
    memory.put(create, at: 0x1000)
    // Early valid writable response element followed by a later out-of-bounds element.
    let chain = DoryVirtioDescriptorChain(
      headIndex: 0,
      descriptors: [
        .init(address: 0x1000, length: UInt32(create.count), flags: 0, next: 1),
        .init(address: 0x4000, length: 24, flags: 2, next: 2),
        .init(address: 0x5000, length: 24, flags: 2, next: 0),
      ],
      readableByteCount: UInt64(create.count),
      writableByteCount: 48
    )
    #expect(throws: DoryVirtioGPUError.self) {
      _ = try device.process(queue: 0, chain: chain, memory: memory)
    }
    // No partial response bytes scattered into the valid early element.
    #expect(try memory.read(at: 0x4000, byteCount: 24) == [UInt8](repeating: 0, count: 24))
    // No device state mutation: the resource slot is still free, so a retry succeeds.
    let retry = try command(device, bytes: create, memory: memory)
    #expect(read32(retry, 0) == 0x1100)
  }

  @Test func preflightsDeferredInvalidResponseTargetBeforeScheduling() throws {
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
    memory.put(submit, at: 0x1000)
    // Early valid writable response element followed by a later out-of-bounds element.
    let chain = DoryVirtioDescriptorChain(
      headIndex: 0,
      descriptors: [
        .init(address: 0x1000, length: UInt32(submit.count), flags: 0, next: 1),
        .init(address: 0x5000, length: 24, flags: 2, next: 2),
        .init(address: 0x20_000, length: 24, flags: 2, next: 0),
      ],
      readableByteCount: UInt64(submit.count),
      writableByteCount: 48
    )
    let responses = GPUResponseRecorder()
    #expect(throws: DoryVirtioGPUError.self) {
      try device.processDeferred(
        queue: 0,
        chain: chain,
        memory: memory,
        completion: { response in
          responses.append(response)
          return true
        }
      )
    }
    // No fenced submit was scheduled and no completion was published.
    #expect(authority.operations == ["context-create:17:2:mesa"])
    #expect(responses.values.isEmpty)
    #expect(try memory.read(at: 0x5000, byteCount: 24) == [UInt8](repeating: 0, count: 24))
  }

  private func makeDevice(
    sink: GPUDisplaySink? = nil,
    authority: GPUAccelerationAuthority? = nil,
    hostVisibleAperture: GPUHostVisibleAperture? = nil,
    maximumGPUResourceCount: Int = 65_536,
    maximumRendererContextCount: Int = 4_096,
    maximumBlobResourceBytes: UInt64 = 8 * 1_024 * 1_024 * 1_024
  ) throws -> DoryVirtioGPUDevice {
    try .init(
      scanouts: [
        .init(id: 0, rectangle: .init(x: 0, y: 0, width: 800, height: 600)),
        .init(id: 1, rectangle: .init(x: 800, y: 0, width: 1_920, height: 1_080)),
      ],
      maximumGPUResourceCount: maximumGPUResourceCount,
      maximumRendererContextCount: maximumRendererContextCount,
      maximumBlobResourceBytes: maximumBlobResourceBytes,
      displaySink: sink,
      accelerationAuthority: authority,
      hostVisibleAperture: hostVisibleAperture
    )
  }

  private func command(
    _ device: DoryVirtioGPUDevice,
    bytes: [UInt8],
    queue: UInt16 = 0,
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
    let written = try device.process(queue: queue, chain: chain, memory: memory)
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
  private var blobFlushIdentityStorage: [DoryVirtioGPUBlobIdentity] = []
  private var blobGenerations: [UInt32: UInt64] = [:]
  private var blobMemory: [UInt32: GPUBlobMemory] = [:]
  private var blobMapInfo: UInt32 = 3
  private var nextMapWorkerGeneration: UInt64?
  private var nextMapWorkspaceID: UUID?
  private var revokeMap = false
  private var rejectUnmap = false
  private var failAfterLocalUnmap = false
  private var revokeFlush = false
  private var creationLimitReached = false
  private var nextCreateBarrier: (entered: DispatchSemaphore, release: DispatchSemaphore)?
  private var nextContextCreateBarrier: (entered: DispatchSemaphore, release: DispatchSemaphore)?
  private var nextContextAttachBarrier: (entered: DispatchSemaphore, release: DispatchSemaphore)?
  private var nextContextDestroyBarrier: (entered: DispatchSemaphore, release: DispatchSemaphore)?
  private var nextBackingAttachBarrier: (entered: DispatchSemaphore, release: DispatchSemaphore)?
  private var nextBackingDetachBarrier: (entered: DispatchSemaphore, release: DispatchSemaphore)?
  private var nextTransferBarrier: (entered: DispatchSemaphore, release: DispatchSemaphore)?
  private var nextMapBarrier: (entered: DispatchSemaphore, release: DispatchSemaphore)?
  private var nextUnmapBarrier: (entered: DispatchSemaphore, release: DispatchSemaphore)?
  var resetCount: Int { lock.withLock { resets } }
  var operations: [String] { lock.withLock { operationStorage } }
  var blobFlushIdentities: [DoryVirtioGPUBlobIdentity] {
    lock.withLock { blobFlushIdentityStorage }
  }

  func setMapInfo(_ value: UInt32) { lock.withLock { blobMapInfo = value } }
  func setNextMapWorkerGeneration(_ value: UInt64) {
    lock.withLock { nextMapWorkerGeneration = value }
  }
  func setNextMapWorkspaceID(_ value: UUID) {
    lock.withLock { nextMapWorkspaceID = value }
  }
  func setRevokeMap(_ value: Bool) { lock.withLock { revokeMap = value } }
  func setRejectUnmap(_ value: Bool) { lock.withLock { rejectUnmap = value } }
  func setFailAfterLocalUnmap(_ value: Bool) { lock.withLock { failAfterLocalUnmap = value } }
  func setRevokeFlush(_ value: Bool) { lock.withLock { revokeFlush = value } }
  func setCreationLimitReached(_ value: Bool) { lock.withLock { creationLimitReached = value } }
  func holdNextCreate(entered: DispatchSemaphore, release: DispatchSemaphore) {
    lock.withLock { nextCreateBarrier = (entered, release) }
  }
  func holdNextContextCreate(entered: DispatchSemaphore, release: DispatchSemaphore) {
    lock.withLock { nextContextCreateBarrier = (entered, release) }
  }
  func holdNextContextAttach(entered: DispatchSemaphore, release: DispatchSemaphore) {
    lock.withLock { nextContextAttachBarrier = (entered, release) }
  }
  func holdNextContextDestroy(entered: DispatchSemaphore, release: DispatchSemaphore) {
    lock.withLock { nextContextDestroyBarrier = (entered, release) }
  }
  func holdNextBackingAttach(entered: DispatchSemaphore, release: DispatchSemaphore) {
    lock.withLock { nextBackingAttachBarrier = (entered, release) }
  }
  func holdNextBackingDetach(entered: DispatchSemaphore, release: DispatchSemaphore) {
    lock.withLock { nextBackingDetachBarrier = (entered, release) }
  }
  func holdNextTransfer(entered: DispatchSemaphore, release: DispatchSemaphore) {
    lock.withLock { nextTransferBarrier = (entered, release) }
  }
  func holdNextMap(entered: DispatchSemaphore, release: DispatchSemaphore) {
    lock.withLock { nextMapBarrier = (entered, release) }
  }
  func holdNextUnmap(entered: DispatchSemaphore, release: DispatchSemaphore) {
    lock.withLock { nextUnmapBarrier = (entered, release) }
  }

  init(features: DoryVirtioFeatures, capsets: [DoryVirtioGPUCapset]) throws {
    capabilities = try .init(features: features, capsets: capsets)
  }

  func reset() { lock.withLock { resets += 1 } }

  func createContext(id: UInt32, capsetID: UInt32, name: String) {
    record("context-create:\(id):\(capsetID):\(name)")
    let barrier = lock.withLock { () -> (entered: DispatchSemaphore, release: DispatchSemaphore)? in
      let captured = nextContextCreateBarrier
      nextContextCreateBarrier = nil
      return captured
    }
    if let barrier {
      barrier.entered.signal()
      _ = barrier.release.wait(timeout: .now() + 2)
    }
  }

  func destroyContext(id: UInt32) {
    record("context-destroy:\(id)")
    let barrier = lock.withLock { () -> (entered: DispatchSemaphore, release: DispatchSemaphore)? in
      let captured = nextContextDestroyBarrier
      nextContextDestroyBarrier = nil
      return captured
    }
    if let barrier {
      barrier.entered.signal()
      _ = barrier.release.wait(timeout: .now() + 2)
    }
  }

  func attachResource(contextID: UInt32, resourceID: UInt32) {
    record("resource-attach:\(contextID):\(resourceID)")
    let barrier = lock.withLock { () -> (entered: DispatchSemaphore, release: DispatchSemaphore)? in
      let captured = nextContextAttachBarrier
      nextContextAttachBarrier = nil
      return captured
    }
    if let barrier {
      barrier.entered.signal()
      _ = barrier.release.wait(timeout: .now() + 2)
    }
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

  func createResource3D(_ resource: DoryVirtioGPUResource3D) throws {
    if lock.withLock({ creationLimitReached }) {
      throw DoryVirtioGPUAccelerationError.resourceLimitExceeded
    }
    record("resource-create:\(resource.resourceID):\(resource.width)x\(resource.height)")
  }

  func attachBacking(
    resourceID: UInt32,
    entries: [DoryVirtioGPUBackingEntry],
    memory: any DoryVirtioGuestMemory
  ) {
    record("backing-attach:\(resourceID):\(entries.count)")
    let barrier = lock.withLock { () -> (entered: DispatchSemaphore, release: DispatchSemaphore)? in
      let captured = nextBackingAttachBarrier
      nextBackingAttachBarrier = nil
      return captured
    }
    if let barrier {
      barrier.entered.signal()
      _ = barrier.release.wait(timeout: .now() + 2)
    }
  }

  func detachBacking(resourceID: UInt32) {
    record("backing-detach:\(resourceID)")
    let barrier = lock.withLock { () -> (entered: DispatchSemaphore, release: DispatchSemaphore)? in
      let captured = nextBackingDetachBarrier
      nextBackingDetachBarrier = nil
      return captured
    }
    if let barrier {
      barrier.entered.signal()
      _ = barrier.release.wait(timeout: .now() + 2)
    }
  }

  func attachBlobBacking(
    resourceID: UInt32,
    identity: DoryVirtioGPUBlobIdentity,
    entries: [DoryVirtioGPUBackingEntry],
    memory: any DoryVirtioGuestMemory
  ) throws {
    guard lock.withLock({ blobGenerations[resourceID] == identity.resourceGeneration }) else {
      throw DoryVirtioGPUAccelerationError.generationRevoked
    }
    record("blob-backing-attach:\(resourceID):\(identity.resourceGeneration):\(entries.count)")
  }

  func detachBlobBacking(
    resourceID: UInt32,
    identity: DoryVirtioGPUBlobIdentity
  ) throws {
    guard lock.withLock({ blobGenerations[resourceID] == identity.resourceGeneration }) else {
      throw DoryVirtioGPUAccelerationError.generationRevoked
    }
    record("blob-backing-detach:\(resourceID):\(identity.resourceGeneration)")
  }

  func transfer3D(
    _ transfer: DoryVirtioGPUTransfer3D,
    entries: [DoryVirtioGPUBackingEntry],
    memory: any DoryVirtioGuestMemory
  ) {
    record("transfer:\(transfer.direction):\(transfer.contextID):\(transfer.resourceID)")
    let barrier = lock.withLock { () -> (entered: DispatchSemaphore, release: DispatchSemaphore)? in
      let captured = nextTransferBarrier
      nextTransferBarrier = nil
      return captured
    }
    if let barrier {
      barrier.entered.signal()
      _ = barrier.release.wait(timeout: .now() + 2)
    }
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

  func unrefBlobResource(
    resourceID: UInt32,
    identity: DoryVirtioGPUBlobIdentity
  ) throws {
    guard identity.workspaceID == gpuTestWorkspaceID,
      identity.workerGeneration == 9, identity.deviceGeneration == 7,
      lock.withLock({ blobGenerations[resourceID] == identity.resourceGeneration })
    else { throw DoryVirtioGPUAccelerationError.generationRevoked }
    record("resource-unref:\(resourceID)")
  }

  func createBlob(
    _ resource: DoryVirtioGPUBlobResource,
    entries: [DoryVirtioGPUBackingEntry],
    memory: any DoryVirtioGuestMemory
  ) throws -> DoryVirtioGPUBlobIdentity {
    if lock.withLock({ creationLimitReached }) {
      throw DoryVirtioGPUAccelerationError.resourceLimitExceeded
    }
    let generation = lock.withLock { () -> UInt64 in
      let next = (blobGenerations[resource.resourceID] ?? 0) + 1
      blobGenerations[resource.resourceID] = next
      blobMemory[resource.resourceID] = GPUBlobMemory(byteCount: Int(resource.size))
      return next
    }
    record("blob-create:\(resource.resourceID):\(resource.size):\(entries.count)")
    let barrier = lock.withLock { () -> (entered: DispatchSemaphore, release: DispatchSemaphore)? in
      let captured = nextCreateBarrier
      nextCreateBarrier = nil
      return captured
    }
    if let barrier {
      barrier.entered.signal()
      _ = barrier.release.wait(timeout: .now() + 2)
    }
    return .init(
      workspaceID: gpuTestWorkspaceID,
      resourceGeneration: generation,
      workerGeneration: 9,
      deviceGeneration: 7
    )
  }

  func mapBlob(
    resourceID: UInt32,
    identity: DoryVirtioGPUBlobIdentity,
    hostVisibleOffset: UInt64
  ) throws -> DoryVirtioGPUBlobMapping {
    if lock.withLock({ revokeMap }) {
      throw DoryVirtioGPUAccelerationError.generationRevoked
    }
    let barrier = lock.withLock { () -> (entered: DispatchSemaphore, release: DispatchSemaphore)? in
      let captured = nextMapBarrier
      nextMapBarrier = nil
      return captured
    }
    if let barrier {
      barrier.entered.signal()
      guard barrier.release.wait(timeout: .now() + 2) == .success else {
        throw DoryVirtioGPUAccelerationError.invalidBlobMapping
      }
    }
    let store = try lock.withLock { () throws -> GPUBlobMemory in
      guard identity.workspaceID == gpuTestWorkspaceID,
        blobGenerations[resourceID] == identity.resourceGeneration,
        identity.workerGeneration == 9, identity.deviceGeneration == 7,
        let store = blobMemory[resourceID]
      else { throw DoryVirtioGPUAccelerationError.invalidBlobMapping }
      return store
    }
    let reply = lock.withLock { () -> (UInt32, UInt64, UUID) in
      let workerGeneration = nextMapWorkerGeneration ?? 9
      let workspaceID = nextMapWorkspaceID ?? gpuTestWorkspaceID
      nextMapWorkerGeneration = nil
      nextMapWorkspaceID = nil
      return (blobMapInfo, workerGeneration, workspaceID)
    }
    record("blob-map:\(resourceID):\(identity.resourceGeneration):\(store.byteCount)")
    return .init(
      workspaceID: reply.2,
      resourceID: resourceID,
      resourceGeneration: identity.resourceGeneration,
      workerGeneration: reply.1,
      deviceGeneration: 7,
      hostVisibleOffset: hostVisibleOffset,
      byteCount: UInt64(store.byteCount),
      mapInfo: reply.0,
      memory: store.region
    )
  }

  func unmapBlob(
    resourceID: UInt32,
    identity: DoryVirtioGPUBlobIdentity,
    beforeRendererUnmap: @escaping @Sendable () -> Bool
  ) throws {
    guard identity.workspaceID == gpuTestWorkspaceID,
      identity.workerGeneration == 9, identity.deviceGeneration == 7,
      lock.withLock({ blobGenerations[resourceID] == identity.resourceGeneration })
    else { throw DoryVirtioGPUAccelerationError.generationRevoked }
    if lock.withLock({ rejectUnmap }) {
      throw DoryVirtioGPUAccelerationError.invalidBlobMapping
    }
    let barrier = lock.withLock { () -> (entered: DispatchSemaphore, release: DispatchSemaphore)? in
      let captured = nextUnmapBarrier
      nextUnmapBarrier = nil
      return captured
    }
    if let barrier {
      barrier.entered.signal()
      guard barrier.release.wait(timeout: .now() + 2) == .success else {
        throw DoryVirtioGPUAccelerationError.invalidBlobMapping
      }
    }
    let revoked = beforeRendererUnmap()
    guard revoked else { throw DoryVirtioGPUAccelerationError.invalidBlobMapping }
    if lock.withLock({ failAfterLocalUnmap }) {
      throw DoryVirtioGPUAccelerationError.invalidBlobMapping
    }
    record("blob-unmap-local:\(resourceID):\(identity.resourceGeneration):\(revoked)")
  }

  func flushBlobResource(_ scanouts: [DoryVirtioGPUBlobScanoutFlush]) throws {
    let first = scanouts[0]
    lock.withLock { blobFlushIdentityStorage.append(first.identity) }
    if lock.withLock({ revokeFlush }) {
      throw DoryVirtioGPUAccelerationError.generationRevoked
    }
    record(
      "blob-flush:\(scanouts.count):\(first.scanoutID):\(first.resourceID):"
        + "\(first.width)x\(first.height)"
    )
  }

  func readBlob(resourceID: UInt32, offset: UInt64, byteCount: Int) throws -> [UInt8] {
    let store = try lock.withLock { () throws -> GPUBlobMemory in
      guard let store = blobMemory[resourceID] else {
        throw DoryVirtioGPUAccelerationError.invalidBlobMapping
      }
      return store
    }
    return try store.region.read(offset: offset, byteCount: byteCount)
  }

  private func record(_ operation: String) {
    lock.withLock { operationStorage.append(operation) }
  }
}

private final class GPUBlobMemory: @unchecked Sendable {
  let byteCount: Int
  private let lock = NSLock()
  private var bytes: [UInt8]

  init(byteCount: Int) {
    self.byteCount = byteCount
    bytes = .init(repeating: 0, count: byteCount)
  }

  lazy var region = DoryVirtioGPUBlobMemoryRegion(
    byteCount: UInt64(byteCount),
    read: { [weak self] offset, count in
      guard let self else { throw DoryVirtioGPUAccelerationError.invalidBlobMapping }
      return try lock.withLock { Array(bytes[try checked(offset, count)]) }
    },
    write: { [weak self] offset, value in
      guard let self else { throw DoryVirtioGPUAccelerationError.invalidBlobMapping }
      try lock.withLock { bytes.replaceSubrange(try checked(offset, value.count), with: value) }
    }
  )

  private func checked(_ offset: UInt64, _ count: Int) throws -> Range<Int> {
    guard count > 0, offset <= UInt64(byteCount), UInt64(count) <= UInt64(byteCount) - offset
    else { throw DoryVirtioGPUAccelerationError.invalidBlobMapping }
    return Int(offset)..<(Int(offset) + count)
  }
}

private final class GPUHostVisibleAperture: DoryVirtioGPUHostVisibleAperture,
  @unchecked Sendable
{
  let regionID: UInt8 = 1
  let byteCount: UInt64 = 256 * 1_024 * 1_024
  private let lock = NSLock()
  private var mapping: DoryVirtioGPUBlobMapping?
  private var resets = 0
  private var generation: UInt64 = 1
  private var shouldRejectNextMap = false
  private var nextResetBarrier: (entered: DispatchSemaphore, release: DispatchSemaphore)?
  var resetCount: Int { lock.withLock { resets } }
  var apertureGeneration: UInt64 { lock.withLock { generation } }
  var isMapped: Bool { lock.withLock { mapping != nil } }

  func rejectNextMap() { lock.withLock { shouldRejectNextMap = true } }

  func holdNextReset(entered: DispatchSemaphore, release: DispatchSemaphore) {
    lock.withLock { nextResetBarrier = (entered, release) }
  }

  func map(
    _ mapping: DoryVirtioGPUBlobMapping,
    expectedApertureGeneration: UInt64
  ) throws {
    try lock.withLock {
      guard generation == expectedApertureGeneration else {
        throw DoryVirtioGPUAccelerationError.invalidBlobMapping
      }
      if shouldRejectNextMap {
        shouldRejectNextMap = false
        throw DoryVirtioGPUAccelerationError.invalidBlobMapping
      }
      guard self.mapping == nil else { throw DoryVirtioGPUAccelerationError.invalidBlobMapping }
      self.mapping = mapping
    }
  }

  func unmap(resourceID: UInt32, identity: DoryVirtioGPUBlobIdentity) -> Bool {
    lock.withLock {
      guard mapping?.resourceID == resourceID,
        mapping?.workspaceID == identity.workspaceID,
        mapping?.resourceGeneration == identity.resourceGeneration,
        mapping?.workerGeneration == identity.workerGeneration,
        mapping?.deviceGeneration == identity.deviceGeneration
      else { return false }
      mapping = nil
      return true
    }
  }

  func reset() {
    let barrier = lock.withLock { () -> (DispatchSemaphore, DispatchSemaphore)? in
      let captured = nextResetBarrier
      nextResetBarrier = nil
      return captured
    }
    if let barrier {
      barrier.0.signal()
      _ = barrier.1.wait(timeout: .now() + 2)
    }
    lock.withLock {
      mapping = nil
      resets += 1
      generation &+= 1
    }
  }

  func read(offset: UInt64, byteCount: Int) throws -> [UInt8] {
    let mapping = try resolve(offset: offset, byteCount: byteCount)
    return try mapping.memory.read(
      offset: offset - mapping.hostVisibleOffset,
      byteCount: byteCount
    )
  }

  func write(offset: UInt64, bytes: [UInt8]) throws {
    let mapping = try resolve(offset: offset, byteCount: bytes.count)
    try mapping.memory.write(offset: offset - mapping.hostVisibleOffset, bytes: bytes)
  }

  private func resolve(offset: UInt64, byteCount: Int) throws -> DoryVirtioGPUBlobMapping {
    try lock.withLock {
      guard byteCount > 0, let mapping, offset >= mapping.hostVisibleOffset,
        UInt64(byteCount) <= mapping.hostVisibleOffset + mapping.byteCount - offset
      else { throw DoryVirtioGPUAccelerationError.invalidBlobMapping }
      return mapping
    }
  }
}

private final class GPUDisplaySink: DoryVirtioGPUDisplaySink, @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [DoryVirtioGPUFrame] = []
  private var cursorStorage: [DoryVirtioGPUCursorUpdate] = []
  private var retiredGenerations: [UInt64] = []
  var frames: [DoryVirtioGPUFrame] { lock.withLock { storage } }
  var cursors: [DoryVirtioGPUCursorUpdate] { lock.withLock { cursorStorage } }
  var retiredResourceGenerations: [UInt64] { lock.withLock { retiredGenerations } }
  func present(_ frame: DoryVirtioGPUFrame) { lock.withLock { storage.append(frame) } }
  func presentCursor(_ update: DoryVirtioGPUCursorUpdate) {
    lock.withLock { cursorStorage.append(update) }
  }
  func retireResource(resourceID: UInt32, resourceGeneration: UInt64) {
    guard resourceID == 7 else { return }
    lock.withLock { retiredGenerations.append(resourceGeneration) }
  }
}

private final class GPUGuestMemory: DoryVirtioGuestMemory, @unchecked Sendable {
  private let lock = NSLock()
  private var bytes: [UInt8]
  private var heldRead: (
    address: UInt64, entered: DispatchSemaphore, release: DispatchSemaphore
  )?
  private var shortReadAddress: UInt64?

  init(byteCount: Int) { bytes = .init(repeating: 0, count: byteCount) }

  func read(at address: UInt64, byteCount: Int) throws -> [UInt8] {
    let barrier = lock.withLock { () -> (DispatchSemaphore, DispatchSemaphore)? in
      guard heldRead?.address == address, let heldRead else { return nil }
      self.heldRead = nil
      return (heldRead.entered, heldRead.release)
    }
    if let barrier {
      barrier.0.signal()
      _ = barrier.1.wait(timeout: .now() + 2)
    }
    return try lock.withLock {
      let range = try checked(address, byteCount)
      if shortReadAddress == address {
        shortReadAddress = nil
        return Array(bytes[range].dropLast())
      }
      return Array(bytes[range])
    }
  }

  func shortenNextRead(at address: UInt64) {
    lock.withLock { shortReadAddress = address }
  }

  func holdNextRead(
    at address: UInt64,
    entered: DispatchSemaphore,
    release: DispatchSemaphore
  ) {
    lock.withLock { heldRead = (address, entered, release) }
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
