@testable import DoryMachinePC
import DoryDBTX86
import DoryVirtio
import Foundation
import Testing

private let pcBlobTestWorkspaceID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

@Suite struct DoryPCHostVisibleGPUApertureTests {
  @Test func rejectsNonStandardRegionAndBARLargerThanThePCMMIOWindow() {
    #expect(throws: DoryPCHostVisibleGPUApertureError.invalidConfiguration) {
      _ = try DoryPCHostVisibleGPUAperture(
        byteCount: 256 * 1_024 * 1_024,
        regionID: 2
      )
    }
    #expect(throws: DoryPCHostVisibleGPUApertureError.invalidConfiguration) {
      _ = try DoryPCHostVisibleGPUAperture(
        byteCount: DoryPCV1ABI.pcie64MMIOBytes * 2
      )
    }
  }

  @Test func acceptsCacheNoneAndRejectsUndefinedBlobCacheModes() throws {
    let aperture = try DoryPCHostVisibleGPUAperture(byteCount: 256 * 1_024 * 1_024)
    let store = BlobStore(byteCount: 4_096)
    try aperture.map(mapping(resourceID: 1, generation: 1, offset: 0, store: store, mapInfo: 0))
    #expect(aperture.snapshot.mappings.count == 1)
    #expect(aperture.unmap(resourceID: 1, identity: identity(resourceGeneration: 1)))
    for cacheMode in [UInt32(4), 15, 16] {
      #expect(throws: DoryPCHostVisibleGPUApertureError.invalidConfiguration) {
        try aperture.map(mapping(
          resourceID: 1, generation: 1, offset: 0, store: store,
          mapInfo: cacheMode
        ))
      }
      #expect(aperture.snapshot.mappings.isEmpty)
    }
  }

  @Test func rejectsRendererBackingLargerThanItsAuthorizedLease() throws {
    let aperture = try DoryPCHostVisibleGPUAperture(byteCount: 256 * 1_024 * 1_024)
    let oversizedBacking = BlobStore(byteCount: 8_192)
    #expect(throws: DoryPCHostVisibleGPUApertureError.invalidConfiguration) {
      try aperture.map(.init(
        workspaceID: pcBlobTestWorkspaceID,
        resourceID: 1,
        resourceGeneration: 1,
        workerGeneration: 3,
        deviceGeneration: 4,
        hostVisibleOffset: 0,
        byteCount: 4_096,
        mapInfo: 3,
        memory: oversizedBacking.region
      ))
    }
    #expect(aperture.snapshot.mappings.isEmpty)
  }

  @Test func readOnlyBackingRejectsForeignMutationBeforeCallingTheRenderer() throws {
    let store = BlobStore(byteCount: 4_096, access: .readOnly)
    #expect(store.region.access == .readOnly)
    #expect(try store.region.read(offset: 4_095, byteCount: 1) == [0])
    #expect(throws: DoryVirtioGPUAccelerationError.invalidBlobMapping) {
      try store.region.write(offset: 0, bytes: [0xFF])
    }
    #expect(throws: DoryVirtioGPUAccelerationError.invalidBlobMapping) {
      _ = try store.region.compareExchange(offset: 0, expected: 0, desired: 1, byteCount: 4)
    }
    for range in [(UInt64(4_095), 2), (UInt64.max, 1), (UInt64(0), -1)] {
      #expect(throws: DoryVirtioGPUAccelerationError.invalidBlobMapping) {
        _ = try store.region.read(offset: range.0, byteCount: range.1)
      }
    }
    #expect(store.mutationCallbackCount == 0)
    #expect(try store.read(offset: 0, byteCount: 4) == [0, 0, 0, 0])
  }

  @Test(arguments: [UInt32(0), 1, 2, 3])
  func readOnlyAperturePermissionIsIndependentOfCacheMode(cacheMode: UInt32) throws {
    let aperture = try DoryPCHostVisibleGPUAperture(byteCount: 256 * 1_024 * 1_024)
    let readOnly = BlobStore(byteCount: 4_096, access: .readOnly)
    let writable = BlobStore(byteCount: 4_096)
    try aperture.map(mapping(
      resourceID: 1, generation: 1, offset: 0, store: readOnly, mapInfo: cacheMode
    ))
    // Adjacent 4-KiB blobs may share a host granule without sharing write authority.
    try aperture.map(mapping(resourceID: 2, generation: 2, offset: 4_096, store: writable))
    try aperture.validateRead(offset: 0, byteCount: 4_096)
    #expect(try aperture.read(offset: 4_095, byteCount: 1) == [0])
    #expect(throws: DoryPCHostVisibleGPUApertureError.self) {
      try aperture.validateWrite(offset: 0, byteCount: 1)
    }
    #expect(throws: DoryPCHostVisibleGPUApertureError.self) {
      try aperture.write(offset: 0, bytes: [1])
    }
    #expect(throws: DoryPCHostVisibleGPUApertureError.self) {
      _ = try aperture.compareExchange(offset: 0, expected: 0, desired: 1, byteCount: 4)
    }
    for range in [(UInt64(4_095), 2), (UInt64.max, 1), (UInt64(0), -1)] {
      #expect(throws: DoryPCHostVisibleGPUApertureError.self) {
        try aperture.validateRead(offset: range.0, byteCount: range.1)
      }
    }
    try aperture.validateWrite(offset: 4_096, byteCount: 4)
    try aperture.write(offset: 4_096, bytes: [9, 8, 7, 6])
    #expect(try aperture.compareExchange(
      offset: 4_096, expected: 0x0607_0809, desired: 0xAABB_CCDD, byteCount: 4
    ) == 0x0607_0809)
    #expect(try writable.read(offset: 0, byteCount: 4) == [0xDD, 0xCC, 0xBB, 0xAA])
    #expect(readOnly.mutationCallbackCount == 0)
    #expect(try readOnly.read(offset: 0, byteCount: 4) == [0, 0, 0, 0])
  }

  @Test func readOnlyPolicyReachesCPUScalarNativeAndDMAPaths() throws {
    let memoryBytes = 32 * 1_024 * 1_024
    let aperture = try DoryPCHostVisibleGPUAperture(byteCount: 256 * 1_024 * 1_024)
    let barAddress = DoryPCV1ABI.gpuHostVisibleBARAddress(memoryBytes: UInt64(memoryBytes))
    let gpu = try DoryPCVirtioGPUPCIDevice(
      address: DoryPCV1ABI.displayPCIAddress,
      initialBARAddress: DoryPCV1ABI.displayBARAddress,
      scanouts: [.init(id: 0, rectangle: .init(x: 0, y: 0, width: 800, height: 600))],
      accelerationAuthority: BlobCapableAuthority(),
      hostVisibleAperture: aperture,
      initialHostVisibleBARAddress: barAddress
    )
    let machine = try DoryPCDirectKernelMachine(memoryBytes: memoryBytes, pciFunctions: [gpu])
    try gpu.writeConfiguration(offset: 4, bytes: [2, 0])
    let readOnly = BlobStore(byteCount: 4_096, access: .readOnly)
    let writable = BlobStore(byteCount: 4_096)
    try aperture.map(mapping(resourceID: 1, generation: 1, offset: 0, store: readOnly))
    try aperture.map(mapping(resourceID: 2, generation: 2, offset: 4_096, store: writable))
    let dma = machine.qualificationDMAMemory
    try machine.physicalMemory.validateRead(at: barAddress, byteCount: 4)
    try dma.validate(at: barAddress, byteCount: 4, deviceWillWrite: false)
    #expect(try machine.physicalMemory.read(at: barAddress, byteCount: 4) == [0, 0, 0, 0])
    #expect(try machine.physicalMemory.readScalar(at: barAddress, byteCount: 4) == 0)
    #expect(try dma.read(at: barAddress, byteCount: 4) == [0, 0, 0, 0])
    #expect(throws: (any Error).self) {
      try machine.physicalMemory.validateWrite(at: barAddress, byteCount: 4)
    }
    #expect(throws: (any Error).self) {
      try machine.physicalMemory.write(at: barAddress, bytes: [1, 2, 3, 4])
    }
    #expect(throws: (any Error).self) {
      try machine.physicalMemory.writeScalar(at: barAddress, value: 1, byteCount: 4)
    }
    #expect(throws: (any Error).self) {
      _ = try machine.physicalMemory.compareExchangeScalar(
        at: barAddress, expected: 0, desired: 1, byteCount: 4)
    }
    #expect(throws: (any Error).self) {
      try machine.physicalMemory.validateDMA(at: barAddress, byteCount: 4, deviceWillWrite: true)
    }
    #expect(throws: (any Error).self) {
      try dma.validate(at: barAddress, byteCount: 4, deviceWillWrite: true)
    }
    // Backends which skip preflight must still be rejected before the backing writer runs.
    #expect(throws: (any Error).self) {
      try dma.write(at: barAddress, bytes: [1, 2, 3, 4])
    }
    for access in [DoryX86MemoryAccessKind.read, .write] {
      #expect(machine.physicalMemory.hostAddressSpaceOffset(
        at: barAddress, byteCount: 4, access: access
      ) == nil)
    }
    #expect(try machine.physicalMemory.readRestartableScalar(at: barAddress, byteCount: 4) == nil)
    #expect(try machine.physicalMemory.codeGeneration(at: barAddress, byteCount: 4) == nil)
    #expect(throws: (any Error).self) {
      _ = try machine.physicalMemory.read(at: barAddress + 4_095, byteCount: 2)
    }
    #expect(throws: (any Error).self) {
      try dma.validate(at: barAddress + 4_095, byteCount: 2, deviceWillWrite: false)
    }
    try dma.write(at: barAddress + 4_096, bytes: [9, 8, 7, 6])
    #expect(try machine.physicalMemory.compareExchangeScalar(
      at: barAddress + 4_096, expected: 0x0607_0809, desired: 0xAABB_CCDD, byteCount: 4
    ) == 0x0607_0809)
    #expect(try writable.read(offset: 0, byteCount: 4) == [0xDD, 0xCC, 0xBB, 0xAA])
    #expect(readOnly.mutationCallbackCount == 0)
    #expect(try readOnly.read(offset: 0, byteCount: 4) == [0, 0, 0, 0])
  }

  @Test func mappingReplacementAndResetCannotReuseAnOldWritePermission() throws {
    let aperture = try DoryPCHostVisibleGPUAperture(byteCount: 256 * 1_024 * 1_024)
    let writable = BlobStore(byteCount: 4_096)
    let readOnly = BlobStore(byteCount: 4_096, access: .readOnly)
    try aperture.map(mapping(resourceID: 1, generation: 1, offset: 0, store: writable))
    let oldWritableRoute = aperture.apertureGeneration
    try aperture.validateWrite(offset: 0, byteCount: 1)
    #expect(aperture.unmap(resourceID: 1, identity: identity(resourceGeneration: 1)))
    try aperture.map(mapping(resourceID: 1, generation: 2, offset: 0, store: readOnly))
    #expect(throws: DoryPCHostVisibleGPUApertureError.self) {
      try aperture.write(offset: 0, bytes: [1], expectedApertureGeneration: oldWritableRoute)
    }
    #expect(throws: DoryPCHostVisibleGPUApertureError.self) {
      try aperture.validateWrite(offset: 0, byteCount: 1)
    }
    let oldReadOnlyRoute = aperture.apertureGeneration
    aperture.reset()
    #expect(throws: DoryPCHostVisibleGPUApertureError.self) {
      _ = try aperture.read(offset: 0, byteCount: 1)
    }
    try aperture.map(mapping(
      resourceID: 1, generation: 3, offset: 0, store: writable, deviceGeneration: 5
    ))
    #expect(throws: DoryPCHostVisibleGPUApertureError.self) {
      _ = try aperture.read(offset: 0, byteCount: 1, expectedApertureGeneration: oldReadOnlyRoute)
    }
    #expect(throws: DoryPCHostVisibleGPUApertureError.self) {
      try aperture.write(offset: 0, bytes: [1], expectedApertureGeneration: oldReadOnlyRoute)
    }
    try aperture.write(offset: 0, bytes: [0x5A])
    #expect(try aperture.read(offset: 0, byteCount: 1) == [0x5A])
    #expect(readOnly.mutationCallbackCount == 0)
  }

  @Test func independentBlobMapsDoNotInvalidateCapturedAdmissionButResetDoes() throws {
    let aperture = try DoryPCHostVisibleGPUAperture(byteCount: 256 * 1_024 * 1_024)
    let first = BlobStore(byteCount: 4_096)
    let second = BlobStore(byteCount: 4_096)
    let capturedAdmission = aperture.mapAdmissionGeneration
    let capturedRoute = aperture.apertureGeneration
    try aperture.map(
      mapping(resourceID: 1, generation: 1, offset: 0, store: first),
      expectedApertureGeneration: capturedAdmission
    )
    try aperture.map(
      mapping(resourceID: 2, generation: 2, offset: 4_096, store: second),
      expectedApertureGeneration: capturedAdmission
    )
    #expect(aperture.snapshot.mapAdmissionGeneration == capturedAdmission)
    #expect(aperture.snapshot.apertureGeneration > capturedRoute)
    #expect(throws: DoryPCHostVisibleGPUApertureError.self) {
      _ = try aperture.read(
        offset: 4_096, byteCount: 1,
        expectedApertureGeneration: capturedRoute
      )
    }
    #expect(aperture.unmap(resourceID: 1, identity: identity(resourceGeneration: 1)))
    #expect(aperture.mapAdmissionGeneration == capturedAdmission)
    try aperture.map(
      mapping(resourceID: 3, generation: 3, offset: 8_192, store: first),
      expectedApertureGeneration: capturedAdmission
    )
    aperture.reset()
    #expect(aperture.mapAdmissionGeneration != capturedAdmission)
    #expect(throws: DoryPCHostVisibleGPUApertureError.staleMapping(4)) {
      try aperture.map(
        mapping(
          resourceID: 4, generation: 4, offset: 12_288, store: first,
          deviceGeneration: 5
        ),
        expectedApertureGeneration: capturedAdmission
      )
    }
  }

  @Test func routesOnlyExactLiveMappingsAndRejectsOverlapHolesAndStaleUnmap() throws {
    let aperture = try DoryPCHostVisibleGPUAperture(byteCount: 256 * 1_024 * 1_024)
    let first = BlobStore(byteCount: 4_096)
    let second = BlobStore(byteCount: 4_096)
    try aperture.map(mapping(resourceID: 1, generation: 10, offset: 0, store: first))
    let routeBeforeSecondMap = aperture.apertureGeneration
    // Distinct 4-KiB guest mappings may share one 16-KiB host granule without aliasing.
    try aperture.map(mapping(resourceID: 2, generation: 20, offset: 4_096, store: second))
    #expect(throws: DoryPCHostVisibleGPUApertureError.self) {
      _ = try aperture.read(
        offset: 4_096, byteCount: 1,
        expectedApertureGeneration: routeBeforeSecondMap)
    }

    try aperture.write(offset: 4_094, bytes: [1, 2])
    try aperture.write(offset: 4_096, bytes: [3, 4])
    #expect(try first.read(offset: 4_094, byteCount: 2) == [1, 2])
    #expect(try second.read(offset: 0, byteCount: 2) == [3, 4])
    #expect(throws: DoryPCHostVisibleGPUApertureError.self) {
      _ = try aperture.read(offset: 4_094, byteCount: 4)
    }
    #expect(throws: DoryPCHostVisibleGPUApertureError.self) {
      _ = try aperture.read(offset: 8_192, byteCount: 1)
    }
    #expect(throws: DoryPCHostVisibleGPUApertureError.self) {
      try aperture.map(mapping(resourceID: 3, generation: 30, offset: 4_096, store: second))
    }
    let foreignWorkspace = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
    #expect(throws: DoryPCHostVisibleGPUApertureError.staleMapping(3)) {
      try aperture.map(mapping(
        resourceID: 3, generation: 30, offset: 8_192, store: second,
        workspaceID: foreignWorkspace
      ))
    }

    #expect(!aperture.unmap(resourceID: 1, identity: identity(resourceGeneration: 9)))
    #expect(!aperture.unmap(resourceID: 1, identity: identity(
      resourceGeneration: 10, workerGeneration: 99)))
    #expect(!aperture.unmap(resourceID: 1, identity: identity(
      resourceGeneration: 10,
      workspaceID: foreignWorkspace)))
    #expect(try aperture.read(offset: 4_094, byteCount: 2) == [1, 2])
    let routeBeforeUnmap = aperture.apertureGeneration
    #expect(aperture.unmap(resourceID: 1, identity: identity(resourceGeneration: 10)))
    #expect(throws: DoryPCHostVisibleGPUApertureError.self) {
      _ = try aperture.read(offset: 0, byteCount: 1)
    }

    let replacement = BlobStore(byteCount: 4_096)
    try aperture.map(mapping(resourceID: 1, generation: 11, offset: 0, store: replacement))
    #expect(throws: DoryPCHostVisibleGPUApertureError.self) {
      _ = try aperture.read(
        offset: 0, byteCount: 1,
        expectedApertureGeneration: routeBeforeUnmap)
    }
    #expect(throws: DoryPCHostVisibleGPUApertureError.self) {
      try aperture.write(
        offset: 0, bytes: [0xFF],
        expectedApertureGeneration: routeBeforeUnmap)
    }
    let oldApertureGeneration = aperture.apertureGeneration
    aperture.reset()
    #expect(aperture.snapshot.apertureGeneration == oldApertureGeneration + 1)
    #expect(aperture.snapshot.mappings.isEmpty)
    #expect(throws: DoryPCHostVisibleGPUApertureError.staleMapping(3)) {
      try aperture.map(
        mapping(resourceID: 3, generation: 30, offset: 0x3000, store: replacement),
        expectedApertureGeneration: oldApertureGeneration
      )
    }
    #expect(throws: DoryPCHostVisibleGPUApertureError.self) {
      try aperture.map(mapping(resourceID: 1, generation: 11, offset: 0, store: replacement))
    }
    #expect(throws: DoryPCHostVisibleGPUApertureError.self) {
      try aperture.write(offset: 0, bytes: [0xFF])
    }
  }

  @Test func offsetIndexRoutesManyOutOfOrderBlobsAndRetiresTheExactMapping() throws {
    let aperture = try DoryPCHostVisibleGPUAperture(byteCount: 256 * 1_024 * 1_024)
    let stores = (0..<512).map { _ in BlobStore(byteCount: 4_096) }
    // The mapping callbacks borrow their backing. Keep every owner alive through all accesses.
    defer { withExtendedLifetime(stores) {} }
    for index in stores.indices.reversed() {
      try aperture.map(mapping(
        resourceID: UInt32(index + 1), generation: UInt64(index + 1),
        offset: UInt64(index) * 8_192, store: stores[index]
      ))
    }
    #expect(aperture.snapshot.mappings.count == stores.count)
    for index in [0, 1, 255, 256, 510, 511] {
      let offset = UInt64(index) * 8_192
      try aperture.write(offset: offset + 4_095, bytes: [UInt8(truncatingIfNeeded: index)])
      #expect(try aperture.read(offset: offset + 4_095, byteCount: 1)
        == [UInt8(truncatingIfNeeded: index)])
      #expect(throws: DoryPCHostVisibleGPUApertureError.self) {
        _ = try aperture.read(offset: offset + 4_096, byteCount: 1)
      }
    }
    #expect(aperture.unmap(resourceID: 256, identity: identity(resourceGeneration: 256)))
    #expect(throws: DoryPCHostVisibleGPUApertureError.self) {
      _ = try aperture.read(offset: 255 * 8_192, byteCount: 1)
    }
    #expect(try aperture.read(offset: 254 * 8_192, byteCount: 1) == [0])
    #expect(try aperture.read(offset: 256 * 8_192, byteCount: 1) == [0])
    let replacement = BlobStore(byteCount: 4_096)
    defer { withExtendedLifetime(replacement) {} }
    try aperture.map(mapping(
      resourceID: 256, generation: 513, offset: 255 * 8_192, store: replacement
    ))
    #expect(try aperture.read(offset: 255 * 8_192, byteCount: 1) == [0])
  }

  @Test func publishesSharedMemoryCapabilityAndRoutesCPUAndDMAThroughBAR4() async throws {
    let apertureBytes: UInt64 = 256 * 1_024 * 1_024
    let aperture = try DoryPCHostVisibleGPUAperture(byteCount: apertureBytes)
    let authority = try BlobCapableAuthority()
    let memoryBytes = 2 * 1_024 * 1_024
    let initialAddress = DoryPCV1ABI.gpuHostVisibleBARAddress(memoryBytes: UInt64(memoryBytes))
    let gpu = try DoryPCVirtioGPUPCIDevice(
      address: DoryPCV1ABI.displayPCIAddress,
      initialBARAddress: DoryPCV1ABI.displayBARAddress,
      scanouts: [.init(id: 0, rectangle: .init(x: 0, y: 0, width: 800, height: 600))],
      accelerationAuthority: authority,
      hostVisibleAperture: aperture,
      initialHostVisibleBARAddress: initialAddress
    )
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: memoryBytes,
      pciFunctions: [gpu]
    )

    let capability = try gpu.readConfiguration(offset: 0xB4, byteCount: 24)
    #expect(Array(capability[0..<8]) == [0x09, 0, 24, 8, 4, 1, 0, 0])
    #expect(read32(capability, 8) == 0)
    #expect(read32(capability, 12) == UInt32(apertureBytes))
    #expect(read32(capability, 16) == 0)
    #expect(read32(capability, 20) == 0)
    #expect(read32(try gpu.readConfiguration(offset: 0x20, byteCount: 4)) & 0xF == 0xC)
    #expect(read32(try gpu.readConfiguration(offset: 0x24, byteCount: 4)) == 1)
    #expect(try gpu.readConfiguration(offset: 0x100, byteCount: 4) == [0, 0, 0, 0])
    let ecamGPUOffset = UInt64(DoryPCV1ABI.displayPCIAddress.device) << 15
    #expect(
      try machine.physicalMemory.read(
        at: DoryPCV1ABI.pcieECAMBase + ecamGPUOffset + 0x100,
        byteCount: 4
      ) == [0, 0, 0, 0]
    )

    let preNegotiationGeneration = aperture.apertureGeneration
    try gpu.writeConfiguration(
      offset: 0x20,
      bytes: littleEndian(UInt32(truncatingIfNeeded: initialAddress + apertureBytes))
    )
    #expect(aperture.apertureGeneration != preNegotiationGeneration)
    #expect(gpu.transport.deviceState.snapshot().status.isEmpty)
    try gpu.writeConfiguration(
      offset: 0x20,
      bytes: littleEndian(UInt32(truncatingIfNeeded: initialAddress))
    )
    #expect(try gpu.configurationFunction.bar(at: 4)?.address == initialAddress)

    let store = BlobStore(byteCount: 4_096)
    try aperture.map(mapping(resourceID: 7, generation: 1, offset: 0x4000, store: store))
    #expect(throws: DoryPCHostVisibleGPUApertureError.self) {
      _ = try aperture.read(
        offset: 0x4000,
        byteCount: 1,
        expectedApertureGeneration: preNegotiationGeneration
      )
    }
    #expect(throws: DoryPCHostVisibleGPUApertureError.self) {
      try aperture.write(
        offset: 0x4000,
        bytes: [0xFF],
        expectedApertureGeneration: preNegotiationGeneration
      )
    }
    #expect(try store.read(offset: 0, byteCount: 1) == [0])
    #expect(throws: DoryPCHostVisibleGPUApertureError.self) {
      try aperture.validateRead(
        offset: 0x4000,
        byteCount: 1,
        expectedApertureGeneration: preNegotiationGeneration
      )
    }
    #expect(throws: DoryPCHostVisibleGPUApertureError.self) {
      try aperture.validateWrite(
        offset: 0x4000,
        byteCount: 1,
        expectedApertureGeneration: preNegotiationGeneration
      )
    }
    try gpu.writeConfiguration(offset: 4, bytes: [2, 0])
    try machine.physicalMemory.write(at: initialAddress + 0x4000, bytes: [9, 8, 7, 6])
    #expect(try store.read(offset: 0, byteCount: 4) == [9, 8, 7, 6])
    let blobAddress = initialAddress + 0x4000
    let dma = machine.qualificationDMAMemory
    #expect(try dma.read(at: blobAddress, byteCount: 4) == [9, 8, 7, 6])
    try dma.write(at: blobAddress + 4, bytes: [0x5A])
    #expect(try store.read(offset: 4, byteCount: 1) == [0x5A])
    #expect(throws: DoryX86MemoryError.unmapped(
      address: DoryPCV1ABI.displayBARAddress,
      byteCount: 1,
      access: .read
    )) {
      _ = try dma.read(at: DoryPCV1ABI.displayBARAddress, byteCount: 1)
    }
    #expect(try machine.physicalMemory.compareExchangeScalar(
      at: blobAddress, expected: 0x0607_0809, desired: 0xAABB_CCDD, byteCount: 4
    ) == 0x0607_0809)
    #expect(try store.read(offset: 0, byteCount: 4) == [0xDD, 0xCC, 0xBB, 0xAA])
    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0..<4 {
        group.addTask {
          for _ in 0..<256 {
            var expected: UInt64 = 0
            while true {
              guard let observed = try machine.physicalMemory.compareExchangeScalar(
                at: blobAddress, expected: expected, desired: expected &+ 1, byteCount: 4
              ) else { throw DoryVirtioGPUAccelerationError.invalidBlobMapping }
              if observed == expected { break }
              expected = observed
            }
          }
        }
      }
      try await group.waitForAll()
    }
    #expect(try machine.physicalMemory.readScalar(at: blobAddress, byteCount: 4)
      == 0xAABB_CCDD + 1_024)
    try machine.physicalMemory.writeScalar(
      at: blobAddress, value: 0xAABB_CCDD, byteCount: 4)
    #expect(try machine.physicalMemory.compareExchangeScalar(
      at: blobAddress, expected: 0, desired: 1, byteCount: 4
    ) == 0xAABB_CCDD)
    #expect(try store.read(offset: 0, byteCount: 4) == [0xDD, 0xCC, 0xBB, 0xAA])
    // Native translation must fall back to the checked device route. A cached RAM pointer or
    // restartable scalar would outlive a blob unmap or PCI BAR relocation.
    #expect(machine.physicalMemory.hostAddressSpaceOffset(
      at: initialAddress + 0x4000, byteCount: 4, access: .read
    ) == nil)
    #expect(try machine.physicalMemory.readRestartableScalar(
      at: initialAddress + 0x4000, byteCount: 4
    ) == nil)
    #expect(try machine.physicalMemory.codeGeneration(
      at: initialAddress + 0x4000, byteCount: 4
    ) == nil)
    try machine.physicalMemory.validateDMA(
      at: initialAddress + 0x4000,
      byteCount: 4,
      deviceWillWrite: true
    )
    #expect(throws: (any Error).self) {
      try machine.physicalMemory.validateDMA(
        at: initialAddress + 0x3000,
        byteCount: 4,
        deviceWillWrite: true
      )
    }
    #expect(throws: DoryPCHostVisibleGPUApertureError.self) {
      _ = try machine.physicalMemory.compareExchangeScalar(
        at: initialAddress + 0x3000, expected: 0, desired: 1, byteCount: 4)
    }

    // Disabling PCI memory decode also invalidates a route resolved before the command write.
    let enabledRouteGeneration = aperture.apertureGeneration
    try gpu.writeConfiguration(offset: 4, bytes: [0, 0])
    #expect(aperture.apertureGeneration != enabledRouteGeneration)
    #expect(aperture.snapshot.mappings.isEmpty)
    #expect(throws: (any Error).self) {
      _ = try machine.physicalMemory.read(at: initialAddress + 0x4000, byteCount: 1)
    }
    #expect(throws: (any Error).self) {
      _ = try dma.read(at: initialAddress + 0x4000, byteCount: 1)
    }
    #expect(throws: (any Error).self) {
      _ = try machine.physicalMemory.compareExchangeScalar(
        at: blobAddress, expected: 0, desired: 1, byteCount: 4)
    }
    #expect(authority.resetCount == 0)
    try gpu.writeConfiguration(offset: 4, bytes: [2, 0])
    try aperture.map(mapping(
      resourceID: 8, generation: 2, offset: 0x4000, store: store,
      deviceGeneration: 5
    ))
    #expect(try machine.physicalMemory.read(at: initialAddress + 0x4000, byteCount: 4)
      == [0xDD, 0xCC, 0xBB, 0xAA])

    gpu.transport.deviceState.writeStatus([.acknowledge, .driver])
    let relocatedAddress = initialAddress + apertureBytes
    try gpu.writeConfiguration(
      offset: 0x20,
      bytes: littleEndian(UInt32(truncatingIfNeeded: relocatedAddress))
    )
    #expect(try gpu.configurationFunction.bar(at: 4)?.address == relocatedAddress)
    #expect(gpu.transport.deviceState.snapshot().status.contains(.deviceNeedsReset))
    #expect(authority.resetCount == 1)
    #expect(aperture.snapshot.mappings.isEmpty)
    #expect(throws: (any Error).self) {
      _ = try machine.physicalMemory.read(at: initialAddress + 0x4000, byteCount: 1)
    }
    #expect(throws: (any Error).self) {
      _ = try machine.physicalMemory.read(at: relocatedAddress + 0x4000, byteCount: 1)
    }
  }

  @Test func unmapWaitsForAnInFlightCPUAliasBeforeRetiringRendererMemory() throws {
    let aperture = try DoryPCHostVisibleGPUAperture(byteCount: 256 * 1_024 * 1_024)
    let readEntered = DispatchSemaphore(value: 0)
    let releaseRead = DispatchSemaphore(value: 0)
    let readFinished = DispatchSemaphore(value: 0)
    let unmapFinished = DispatchSemaphore(value: 0)
    let region = DoryVirtioGPUBlobMemoryRegion(
      byteCount: 4_096,
      read: { _, count in
        readEntered.signal()
        guard releaseRead.wait(timeout: .now() + 2) == .success else {
          throw DoryVirtioGPUAccelerationError.invalidBlobMapping
        }
        return [UInt8](repeating: 0x5A, count: count)
      },
      write: { _, _ in }
    )
    try aperture.map(
      .init(
        workspaceID: pcBlobTestWorkspaceID,
        resourceID: 12,
        resourceGeneration: 1,
        workerGeneration: 3,
        deviceGeneration: 4,
        hostVisibleOffset: 0,
        byteCount: 4_096,
        mapInfo: 3,
        memory: region
      ))

    DispatchQueue.global().async {
      _ = try? aperture.read(offset: 0, byteCount: 1)
      readFinished.signal()
    }
    #expect(readEntered.wait(timeout: .now() + 1) == .success)
    DispatchQueue.global().async {
      _ = aperture.unmap(resourceID: 12, identity: .init(
        workspaceID: pcBlobTestWorkspaceID,
        resourceGeneration: 1, workerGeneration: 3, deviceGeneration: 4))
      unmapFinished.signal()
    }
    #expect(unmapFinished.wait(timeout: .now() + 0.05) == .timedOut)
    releaseRead.signal()
    #expect(readFinished.wait(timeout: .now() + 1) == .success)
    #expect(unmapFinished.wait(timeout: .now() + 1) == .success)
    #expect(throws: DoryPCHostVisibleGPUApertureError.self) {
      _ = try aperture.read(offset: 0, byteCount: 1)
    }
  }

  @Test func BARRelocationWaitsForAnInFlightResolvedBlobRead() throws {
    let apertureBytes: UInt64 = 256 * 1_024 * 1_024
    let aperture = try DoryPCHostVisibleGPUAperture(byteCount: apertureBytes)
    let authority = try BlobCapableAuthority()
    let memoryBytes = 2 * 1_024 * 1_024
    let initialAddress = DoryPCV1ABI.gpuHostVisibleBARAddress(memoryBytes: UInt64(memoryBytes))
    let gpu = try DoryPCVirtioGPUPCIDevice(
      address: DoryPCV1ABI.displayPCIAddress,
      initialBARAddress: DoryPCV1ABI.displayBARAddress,
      scanouts: [.init(id: 0, rectangle: .init(x: 0, y: 0, width: 800, height: 600))],
      accelerationAuthority: authority,
      hostVisibleAperture: aperture,
      initialHostVisibleBARAddress: initialAddress
    )
    let machine = try DoryPCDirectKernelMachine(memoryBytes: memoryBytes, pciFunctions: [gpu])
    try gpu.writeConfiguration(offset: 4, bytes: [2, 0])
    let readEntered = DispatchSemaphore(value: 0)
    let releaseRead = DispatchSemaphore(value: 0)
    let readFinished = DispatchSemaphore(value: 0)
    let relocationStarted = DispatchSemaphore(value: 0)
    let relocationFinished = DispatchSemaphore(value: 0)
    let region = DoryVirtioGPUBlobMemoryRegion(
      byteCount: 4_096,
      read: { _, count in
        readEntered.signal()
        guard releaseRead.wait(timeout: .now() + 2) == .success else {
          throw DoryVirtioGPUAccelerationError.invalidBlobMapping
        }
        return [UInt8](repeating: 0x5A, count: count)
      },
      write: { _, _ in }
    )
    try aperture.map(.init(
      workspaceID: pcBlobTestWorkspaceID,
      resourceID: 21,
      resourceGeneration: 1,
      workerGeneration: 3,
      deviceGeneration: 4,
      hostVisibleOffset: 0x4_000,
      byteCount: 4_096,
      mapInfo: 3,
      memory: region
    ))
    let admissionBeforeRelocation = aperture.mapAdmissionGeneration

    DispatchQueue.global().async {
      _ = try? machine.physicalMemory.read(at: initialAddress + 0x4_000, byteCount: 1)
      readFinished.signal()
    }
    #expect(readEntered.wait(timeout: .now() + 1) == .success)
    DispatchQueue.global().async {
      relocationStarted.signal()
      try? gpu.writeConfiguration(
        offset: 0x20,
        bytes: littleEndian(UInt32(truncatingIfNeeded: initialAddress + apertureBytes))
      )
      relocationFinished.signal()
    }
    #expect(relocationStarted.wait(timeout: .now() + 1) == .success)
    #expect(relocationFinished.wait(timeout: .now() + 0.05) == .timedOut)
    #expect(try gpu.configurationFunction.bar(at: 4)?.address == initialAddress)
    releaseRead.signal()
    #expect(readFinished.wait(timeout: .now() + 1) == .success)
    #expect(relocationFinished.wait(timeout: .now() + 1) == .success)
    #expect(try gpu.configurationFunction.bar(at: 4)?.address == initialAddress + apertureBytes)
    #expect(aperture.snapshot.mappings.isEmpty)
    #expect(aperture.mapAdmissionGeneration != admissionBeforeRelocation)
  }

  @Test func unmapWaitsForAnInFlightDeviceDMARead() throws {
    let aperture = try DoryPCHostVisibleGPUAperture(byteCount: 256 * 1_024 * 1_024)
    let authority = try BlobCapableAuthority()
    let memoryBytes = 2 * 1_024 * 1_024
    let barAddress = DoryPCV1ABI.gpuHostVisibleBARAddress(memoryBytes: UInt64(memoryBytes))
    let gpu = try DoryPCVirtioGPUPCIDevice(
      address: DoryPCV1ABI.displayPCIAddress,
      initialBARAddress: DoryPCV1ABI.displayBARAddress,
      scanouts: [.init(id: 0, rectangle: .init(x: 0, y: 0, width: 800, height: 600))],
      accelerationAuthority: authority,
      hostVisibleAperture: aperture,
      initialHostVisibleBARAddress: barAddress
    )
    let machine = try DoryPCDirectKernelMachine(memoryBytes: memoryBytes, pciFunctions: [gpu])
    try gpu.writeConfiguration(offset: 4, bytes: [2, 0])
    let entered = DispatchSemaphore(value: 0)
    let releaseRead = DispatchSemaphore(value: 0)
    let readFinished = DispatchSemaphore(value: 0)
    let unmapFinished = DispatchSemaphore(value: 0)
    let region = DoryVirtioGPUBlobMemoryRegion(
      byteCount: 4_096,
      read: { _, count in
        entered.signal()
        guard releaseRead.wait(timeout: .now() + 2) == .success else {
          throw DoryVirtioGPUAccelerationError.invalidBlobMapping
        }
        return [UInt8](repeating: 0x5A, count: count)
      },
      write: { _, _ in }
    )
    let identity = DoryVirtioGPUBlobIdentity(
      workspaceID: pcBlobTestWorkspaceID,
      resourceGeneration: 1,
      workerGeneration: 3,
      deviceGeneration: 4
    )
    try aperture.map(.init(
      workspaceID: identity.workspaceID,
      resourceID: 12,
      resourceGeneration: identity.resourceGeneration,
      workerGeneration: identity.workerGeneration,
      deviceGeneration: identity.deviceGeneration,
      hostVisibleOffset: 0x4000,
      byteCount: 4_096,
      mapInfo: 3,
      memory: region
    ))
    DispatchQueue.global().async {
      _ = try? machine.qualificationDMAMemory.read(at: barAddress + 0x4000, byteCount: 1)
      readFinished.signal()
    }
    #expect(entered.wait(timeout: .now() + 1) == .success)
    DispatchQueue.global().async {
      _ = aperture.unmap(resourceID: 12, identity: identity)
      unmapFinished.signal()
    }
    #expect(unmapFinished.wait(timeout: .now() + 0.05) == .timedOut)
    releaseRead.signal()
    #expect(readFinished.wait(timeout: .now() + 1) == .success)
    #expect(unmapFinished.wait(timeout: .now() + 1) == .success)
    #expect(throws: (any Error).self) {
      _ = try machine.qualificationDMAMemory.read(at: barAddress + 0x4000, byteCount: 1)
    }
  }

  @Test func disablingPCIMemoryDecodeAfterNegotiationRevokesBlobAliases() throws {
    let aperture = try DoryPCHostVisibleGPUAperture(byteCount: 256 * 1_024 * 1_024)
    let authority = try BlobCapableAuthority()
    let memoryBytes = 2 * 1_024 * 1_024
    let initialAddress = DoryPCV1ABI.gpuHostVisibleBARAddress(memoryBytes: UInt64(memoryBytes))
    let gpu = try DoryPCVirtioGPUPCIDevice(
      address: DoryPCV1ABI.displayPCIAddress,
      initialBARAddress: DoryPCV1ABI.displayBARAddress,
      scanouts: [.init(id: 0, rectangle: .init(x: 0, y: 0, width: 800, height: 600))],
      accelerationAuthority: authority,
      hostVisibleAperture: aperture,
      initialHostVisibleBARAddress: initialAddress
    )
    let machine = try DoryPCDirectKernelMachine(memoryBytes: memoryBytes, pciFunctions: [gpu])
    try gpu.writeConfiguration(offset: 4, bytes: [2, 0])
    let store = BlobStore(byteCount: 4_096)
    try aperture.map(mapping(resourceID: 7, generation: 1, offset: 0, store: store))
    gpu.transport.deviceState.writeStatus([.acknowledge, .driver])
    try machine.physicalMemory.write(at: initialAddress, bytes: [0x5A])
    let enabledGeneration = aperture.apertureGeneration

    try gpu.writeConfiguration(offset: 4, bytes: [0, 0])
    #expect(authority.resetCount == 1)
    #expect(gpu.transport.deviceState.snapshot().status.contains(.deviceNeedsReset))
    #expect(aperture.snapshot.apertureGeneration != enabledGeneration)
    #expect(aperture.snapshot.mappings.isEmpty)
    #expect(throws: (any Error).self) {
      _ = try machine.physicalMemory.read(at: initialAddress, byteCount: 1)
    }
    try gpu.writeConfiguration(offset: 4, bytes: [2, 0])
    #expect(throws: (any Error).self) {
      _ = try machine.physicalMemory.read(at: initialAddress, byteCount: 1)
    }
  }

  @Test func resetWaitsForAnInFlightCPUAliasAndRejectsTheOldGeneration() throws {
    let aperture = try DoryPCHostVisibleGPUAperture(byteCount: 256 * 1_024 * 1_024)
    let readEntered = DispatchSemaphore(value: 0)
    let releaseRead = DispatchSemaphore(value: 0)
    let readFinished = DispatchSemaphore(value: 0)
    let resetFinished = DispatchSemaphore(value: 0)
    let region = DoryVirtioGPUBlobMemoryRegion(
      byteCount: 4_096,
      read: { _, count in
        readEntered.signal()
        guard releaseRead.wait(timeout: .now() + 2) == .success else {
          throw DoryVirtioGPUAccelerationError.invalidBlobMapping
        }
        return [UInt8](repeating: 0x5A, count: count)
      },
      write: { _, _ in }
    )
    let staleMapping = DoryVirtioGPUBlobMapping(
      workspaceID: pcBlobTestWorkspaceID,
      resourceID: 12,
      resourceGeneration: 1,
      workerGeneration: 3,
      deviceGeneration: 4,
      hostVisibleOffset: 0,
      byteCount: 4_096,
      mapInfo: 3,
      memory: region
    )
    let oldApertureGeneration = aperture.apertureGeneration
    try aperture.map(staleMapping, expectedApertureGeneration: oldApertureGeneration)

    DispatchQueue.global().async {
      _ = try? aperture.read(offset: 0, byteCount: 1)
      readFinished.signal()
    }
    #expect(readEntered.wait(timeout: .now() + 1) == .success)
    DispatchQueue.global().async {
      aperture.reset()
      resetFinished.signal()
    }
    #expect(resetFinished.wait(timeout: .now() + 0.05) == .timedOut)
    releaseRead.signal()
    #expect(readFinished.wait(timeout: .now() + 1) == .success)
    #expect(resetFinished.wait(timeout: .now() + 1) == .success)
    #expect(aperture.snapshot.mappings.isEmpty)
    #expect(throws: DoryPCHostVisibleGPUApertureError.staleMapping(12)) {
      try aperture.map(staleMapping, expectedApertureGeneration: oldApertureGeneration)
    }
    #expect(throws: DoryPCHostVisibleGPUApertureError.self) {
      _ = try aperture.read(offset: 0, byteCount: 1)
    }
  }

  @Test func concurrentResetsEachRetireTheGenerationObservedAfterWaiting() throws {
    let aperture = try DoryPCHostVisibleGPUAperture(byteCount: 256 * 1_024 * 1_024)
    let readEntered = DispatchSemaphore(value: 0)
    let releaseRead = DispatchSemaphore(value: 0)
    let readFinished = DispatchSemaphore(value: 0)
    let firstResetFinished = DispatchSemaphore(value: 0)
    let secondResetFinished = DispatchSemaphore(value: 0)
    let region = DoryVirtioGPUBlobMemoryRegion(
      byteCount: 4_096,
      read: { _, count in
        readEntered.signal()
        guard releaseRead.wait(timeout: .now() + 2) == .success else {
          throw DoryVirtioGPUAccelerationError.invalidBlobMapping
        }
        return [UInt8](repeating: 0x5A, count: count)
      },
      write: { _, _ in }
    )
    try aperture.map(.init(
      workspaceID: pcBlobTestWorkspaceID,
      resourceID: 12,
      resourceGeneration: 1,
      workerGeneration: 3,
      deviceGeneration: 4,
      hostVisibleOffset: 0,
      byteCount: 4_096,
      mapInfo: 3,
      memory: region
    ))
    let initialGeneration = aperture.apertureGeneration
    DispatchQueue.global().async {
      _ = try? aperture.read(offset: 0, byteCount: 1)
      readFinished.signal()
    }
    #expect(readEntered.wait(timeout: .now() + 1) == .success)
    DispatchQueue.global().async {
      aperture.reset()
      firstResetFinished.signal()
    }
    let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
    while !aperture.snapshot.isResetting && DispatchTime.now().uptimeNanoseconds < deadline {
      Thread.sleep(forTimeInterval: 0.001)
    }
    #expect(aperture.snapshot.isResetting)
    DispatchQueue.global().async {
      aperture.reset()
      secondResetFinished.signal()
    }
    let secondDeadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
    while aperture.snapshot.pendingResetCount != 1
      && DispatchTime.now().uptimeNanoseconds < secondDeadline {
      Thread.sleep(forTimeInterval: 0.001)
    }
    #expect(aperture.snapshot.pendingResetCount == 1)
    releaseRead.signal()
    #expect(readFinished.wait(timeout: .now() + 1) == .success)
    #expect(firstResetFinished.wait(timeout: .now() + 1) == .success)
    #expect(secondResetFinished.wait(timeout: .now() + 1) == .success)
    #expect(aperture.snapshot.apertureGeneration == initialGeneration + 2)
    #expect(aperture.snapshot.mappings.isEmpty)
    #expect(aperture.snapshot.pendingResetCount == 0)
  }

  @Test func resetBlocksNewMappingsUntilOldReaderHasRetired() throws {
    let aperture = try DoryPCHostVisibleGPUAperture(byteCount: 256 * 1_024 * 1_024)
    let readEntered = DispatchSemaphore(value: 0)
    let releaseRead = DispatchSemaphore(value: 0)
    let readFinished = DispatchSemaphore(value: 0)
    let resetFinished = DispatchSemaphore(value: 0)
    let region = DoryVirtioGPUBlobMemoryRegion(
      byteCount: 4_096,
      read: { _, count in
        readEntered.signal()
        guard releaseRead.wait(timeout: .now() + 2) == .success else {
          throw DoryVirtioGPUAccelerationError.invalidBlobMapping
        }
        return [UInt8](repeating: 0x5A, count: count)
      },
      write: { _, _ in }
    )
    try aperture.map(.init(
      workspaceID: pcBlobTestWorkspaceID,
      resourceID: 12,
      resourceGeneration: 1,
      workerGeneration: 3,
      deviceGeneration: 4,
      hostVisibleOffset: 0,
      byteCount: 4_096,
      mapInfo: 3,
      memory: region
    ))

    DispatchQueue.global().async {
      _ = try? aperture.read(offset: 0, byteCount: 1)
      readFinished.signal()
    }
    #expect(readEntered.wait(timeout: .now() + 1) == .success)
    DispatchQueue.global().async {
      aperture.reset()
      resetFinished.signal()
    }
    let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
    while !aperture.snapshot.isResetting && DispatchTime.now().uptimeNanoseconds < deadline {
      Thread.sleep(forTimeInterval: 0.001)
    }
    #expect(aperture.snapshot.isResetting)
    #expect(throws: DoryPCHostVisibleGPUApertureError.staleMapping(13)) {
      try aperture.map(.init(
        workspaceID: pcBlobTestWorkspaceID,
        resourceID: 13,
        resourceGeneration: 1,
        workerGeneration: 3,
        deviceGeneration: 4,
        hostVisibleOffset: 4_096,
        byteCount: 4_096,
        mapInfo: 3,
        memory: region
      ))
    }
    #expect(!aperture.unmap(resourceID: 12, identity: identity(resourceGeneration: 1)))
    #expect(resetFinished.wait(timeout: .now() + 0.05) == .timedOut)
    releaseRead.signal()
    #expect(readFinished.wait(timeout: .now() + 1) == .success)
    #expect(resetFinished.wait(timeout: .now() + 1) == .success)
    #expect(!aperture.snapshot.isResetting)
    #expect(aperture.snapshot.mappings.isEmpty)

    let replacement = BlobStore(byteCount: 4_096)
    try aperture.map(mapping(
      resourceID: 12, generation: 1, offset: 0, store: replacement,
      deviceGeneration: 5
    ))
    // A new worker can reuse the same resource ID and resource generation. The old unmap
    // callback must not retire that new device generation's alias.
    #expect(!aperture.unmap(resourceID: 12, identity: identity(resourceGeneration: 1)))
    #expect(aperture.snapshot.mappings.map(\.deviceGeneration) == [5])
    #expect(try aperture.read(offset: 0, byteCount: 1) == [0])
  }

  private func mapping(
    resourceID: UInt32,
    generation: UInt64,
    offset: UInt64,
    store: BlobStore,
    deviceGeneration: UInt64 = 4,
    workspaceID: UUID = pcBlobTestWorkspaceID,
    mapInfo: UInt32 = 3
  ) -> DoryVirtioGPUBlobMapping {
    .init(
      workspaceID: workspaceID,
      resourceID: resourceID,
      resourceGeneration: generation,
      workerGeneration: 3,
      deviceGeneration: deviceGeneration,
      hostVisibleOffset: offset,
      byteCount: UInt64(store.byteCount),
      mapInfo: mapInfo,
      memory: store.region
    )
  }

  private func identity(
    resourceGeneration: UInt64,
    workerGeneration: UInt64 = 3,
    deviceGeneration: UInt64 = 4,
    workspaceID: UUID = pcBlobTestWorkspaceID
  ) -> DoryVirtioGPUBlobIdentity {
    .init(
      workspaceID: workspaceID,
      resourceGeneration: resourceGeneration,
      workerGeneration: workerGeneration,
      deviceGeneration: deviceGeneration
    )
  }
}

private final class BlobCapableAuthority: DoryVirtioGPUAccelerationAuthority,
  @unchecked Sendable
{
  let capabilities: DoryVirtioGPUAccelerationCapabilities
  private let lock = NSLock()
  private var resets = 0
  var resetCount: Int { lock.withLock { resets } }

  init() throws {
    capabilities = try .init(
      features: [.gpuVirgl, .gpuResourceBlob, .gpuContextInit],
      capsets: [
        .init(id: 2, maximumVersion: 2, data: [1]),
        .init(id: 4, maximumVersion: 0, data: [2]),
      ]
    )
  }

  func reset() { lock.withLock { resets += 1 } }
}

private final class BlobStore: @unchecked Sendable {
  let byteCount: Int
  let access: DoryVirtioGPUBlobMemoryRegion.Access
  private let lock = NSLock()
  private var bytes: [UInt8]
  private var mutationCallbacks = 0
  var mutationCallbackCount: Int { lock.withLock { mutationCallbacks } }

  init(byteCount: Int, access: DoryVirtioGPUBlobMemoryRegion.Access = .readWrite) {
    self.byteCount = byteCount
    self.access = access
    bytes = .init(repeating: 0, count: byteCount)
  }

  lazy var region = DoryVirtioGPUBlobMemoryRegion(
    byteCount: UInt64(byteCount),
    access: access,
    read: { [weak self] offset, count in
      guard let self else { throw DoryVirtioGPUAccelerationError.invalidBlobMapping }
      return try read(offset: offset, byteCount: count)
    },
    write: { [weak self] offset, value in
      guard let self else { throw DoryVirtioGPUAccelerationError.invalidBlobMapping }
      try write(offset: offset, bytes: value)
    },
    compareExchange: { [weak self] offset, expected, desired, count in
      guard let self else { throw DoryVirtioGPUAccelerationError.invalidBlobMapping }
      return try compareExchange(offset: offset, expected: expected, desired: desired, byteCount: count)
    }
  )

  func read(offset: UInt64, byteCount: Int) throws -> [UInt8] {
    try lock.withLock { Array(bytes[try checked(offset, byteCount)]) }
  }

  private func write(offset: UInt64, bytes value: [UInt8]) throws {
    try lock.withLock {
      mutationCallbacks += 1
      bytes.replaceSubrange(try checked(offset, value.count), with: value)
    }
  }

  private func compareExchange(
    offset: UInt64, expected: UInt64, desired: UInt64, byteCount: Int
  ) throws -> UInt64 {
    try lock.withLock {
      mutationCallbacks += 1
      let range = try checked(offset, byteCount)
      let observed = range.enumerated().reduce(UInt64(0)) {
        $0 | UInt64(bytes[$1.element]) << UInt64($1.offset * 8)
      }
      let mask = byteCount == 8 ? UInt64.max : (UInt64(1) << UInt64(byteCount * 8)) - 1
      if observed == expected & mask {
        for index in 0..<byteCount {
          bytes[range.lowerBound + index] = UInt8(truncatingIfNeeded: desired >> UInt64(index * 8))
        }
      }
      return observed
    }
  }

  private func checked(_ offset: UInt64, _ count: Int) throws -> Range<Int> {
    guard count > 0, offset <= UInt64(byteCount), UInt64(count) <= UInt64(byteCount) - offset
    else { throw DoryVirtioGPUAccelerationError.invalidBlobMapping }
    return Int(offset)..<(Int(offset) + count)
  }
}

private func read32(_ bytes: [UInt8], _ offset: Int = 0) -> UInt32 {
  (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << UInt32($1 * 8) }
}

private func littleEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
  (0..<MemoryLayout<T>.size).map { UInt8(truncatingIfNeeded: value >> T($0 * 8)) }
}
