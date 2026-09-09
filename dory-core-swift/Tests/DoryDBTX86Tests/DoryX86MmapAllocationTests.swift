import Darwin
import Foundation
import Testing

@testable import DoryDBTX86

@Suite struct DoryX86MmapAllocationTests {
  @Test func byteCountInitializerReturnsConfigurationAndHostMappingErrors() throws {
    for count in [Int.min, -1, 0] {
      #expect(throws: DoryX86MemoryAllocationError.invalidByteCount(count)) {
        try DoryX86MmapMemory(byteCount: count)
      }
    }
    #expect(throws: DoryX86MemoryAllocationError.addressOverflow(baseAddress: .max, byteCount: 1)) {
      try DoryX86MmapMemory(baseAddress: .max, byteCount: 1)
    }
    do {
      _ = try DoryX86MmapMemory(byteCount: .max)
      Issue.record("An impossible address-space reservation unexpectedly succeeded")
    } catch let error as DoryX86MemoryAllocationError {
      guard case .mappingFailed(let count, let number) = error else {
        Issue.record("Expected a recoverable mmap error, received \(error)")
        return
      }
      #expect(count == Int.max)
      #expect(number != 0)
    }
    let memory = try DoryX86MmapMemory(byteCount: 4096)
    #expect(try memory.readScalar(at: 4088, byteCount: 8) == 0)
    try memory.writeScalar(at: 4088, value: .max, byteCount: 8)
    #expect(try memory.readScalar(at: 4088, byteCount: 8) == .max)
  }

  @Test func sparseReservationKeepsLogicalRAMContiguousAndHostHolesUncommitted() throws {
    let page = Int(getpagesize())
    let memory = try DoryX86MmapMemory(
      validatingByteCount: page * 2,
      hostAddressSpaceByteCount: page * 4,
      ramMappings: [
        .init(logicalOffset: 0, hostOffset: 0, byteCount: page),
        .init(logicalOffset: page, hostOffset: page * 3, byteCount: page),
      ]
    )

    #expect(memory.hostAddressSpaceByteCount == page * 4)
    #expect(memory.hostAddressSpaceBase != 0)
    try memory.write(at: UInt64(page - 2), bytes: [0x11, 0x22, 0x33, 0x44])
    #expect(try memory.read(at: UInt64(page - 2), byteCount: 4) == [0x11, 0x22, 0x33, 0x44])
    #expect(memory.bulkCopyRAMSpan(at: UInt64(page - 2), maximumByteCount: 4) == 2)

    let base = mach_vm_address_t(memory.hostAddressSpaceBase)
    var address = base + mach_vm_address_t(page)
    var size: mach_vm_size_t = 0
    var info = vm_region_basic_info_data_64_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<vm_region_basic_info_data_64_t>.size / MemoryLayout<integer_t>.size)
    var objectName: mach_port_t = 0
    let result = withUnsafeMutablePointer(to: &info) { infoPointer in
      infoPointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
        mach_vm_region(
          mach_task_self_,
          &address,
          &size,
          VM_REGION_BASIC_INFO_64,
          rebound,
          &count,
          &objectName
        )
      }
    }
    #expect(result == KERN_SUCCESS)
    #expect(address == base + mach_vm_address_t(page))
    #expect(info.protection == VM_PROT_NONE)
  }

  @Test func sparseReservationRejectsGapsOverlapAndUnalignedMappings() throws {
    let page = Int(getpagesize())
    let invalid: [[DoryX86MmapRAMMapping]] = [
      [.init(logicalOffset: page, hostOffset: 0, byteCount: page)],
      [
        .init(logicalOffset: 0, hostOffset: 0, byteCount: page),
        .init(logicalOffset: page, hostOffset: 0, byteCount: page),
      ],
      [.init(logicalOffset: 0, hostOffset: 1, byteCount: page)],
    ]
    for mappings in invalid {
      #expect(throws: DoryX86MemoryAllocationError.self) {
        try DoryX86MmapMemory(
          validatingByteCount: page * (mappings.count == 1 ? 1 : 2),
          hostAddressSpaceByteCount: page * 4,
          ramMappings: mappings
        )
      }
    }
    #expect(throws: DoryX86MemoryAllocationError.invalidHostAddressSpace(byteCount: page + 1)) {
      try DoryX86MmapMemory(
        validatingByteCount: page,
        hostAddressSpaceByteCount: page + 1,
        ramMappings: [.init(logicalOffset: 0, hostOffset: 0, byteCount: page)]
      )
    }
  }

  @Test func sparseReservationInstallsReadOnlyFilledMappings() throws {
    let page = Int(getpagesize())
    let memory = try DoryX86MmapMemory(
      validatingByteCount: page,
      hostAddressSpaceByteCount: page * 3,
      ramMappings: [.init(logicalOffset: 0, hostOffset: 0, byteCount: page)],
      readOnlyMappings: [
        .init(
          hostOffset: page * 2,
          byteCount: page,
          contents: Data([0x11, 0x22]),
          contentsOffset: page - 2,
          fillByte: 0xff
        )
      ]
    )

    let base = UnsafeRawPointer(bitPattern: UInt(memory.hostAddressSpaceBase))!
    let region = base.advanced(by: page * 2).assumingMemoryBound(to: UInt8.self)
    #expect(region.pointee == 0xff)
    #expect(region.advanced(by: page - 3).pointee == 0xff)
    #expect(region.advanced(by: page - 2).pointee == 0x11)
    #expect(region.advanced(by: page - 1).pointee == 0x22)

    var address = mach_vm_address_t(memory.hostAddressSpaceBase) + mach_vm_address_t(page * 2)
    var size: mach_vm_size_t = 0
    var info = vm_region_basic_info_data_64_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<vm_region_basic_info_data_64_t>.size / MemoryLayout<integer_t>.size)
    var objectName: mach_port_t = 0
    let result = withUnsafeMutablePointer(to: &info) { infoPointer in
      infoPointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
        mach_vm_region(
          mach_task_self_, &address, &size, VM_REGION_BASIC_INFO_64, rebound, &count, &objectName)
      }
    }
    #expect(result == KERN_SUCCESS)
    #expect(info.protection == VM_PROT_READ)
  }

  @Test func translatedCodeProtectionRevokesWritesUntilCheckedMutationInvalidatesIt() throws {
    let page = Int(getpagesize())
    let memory = try DoryX86MmapMemory(validatingByteCount: page)
    try memory.write(at: 0, bytes: [0x90])
    let generation = try #require(try memory.codeGeneration(at: 0, byteCount: 1))

    try memory.protectTranslatedCode(at: 0, byteCount: 1)
    #expect(memory.protectedTranslatedCodePageCount == 1)
    #expect(regionProtection(at: memory.hostAddressSpaceBase) == VM_PROT_READ)

    try memory.write(at: 0, bytes: [0xCC])
    #expect(memory.protectedTranslatedCodePageCount == 0)
    #expect(
      regionProtection(at: memory.hostAddressSpaceBase)
        == VM_PROT_READ | VM_PROT_WRITE)
    #expect(try memory.read(at: 0, byteCount: 1) == [0xCC])
    #expect(try memory.codeGeneration(at: 0, byteCount: 1) != generation)
  }

  @Test func sparseReservationRejectsReadOnlyOverlapAndOverflow() throws {
    let page = Int(getpagesize())
    for mapping in [
      DoryX86MmapReadOnlyMapping(
        hostOffset: 0, byteCount: page, contents: Data(), fillByte: 0xff),
      DoryX86MmapReadOnlyMapping(
        hostOffset: page * 2, byteCount: page, contents: Data([1]), contentsOffset: page),
    ] {
      #expect(throws: DoryX86MemoryAllocationError.self) {
        try DoryX86MmapMemory(
          validatingByteCount: page,
          hostAddressSpaceByteCount: page * 2,
          ramMappings: [.init(logicalOffset: 0, hostOffset: 0, byteCount: page)],
          readOnlyMappings: [mapping]
        )
      }
    }
  }


  private func regionProtection(at rawAddress: UInt64) -> vm_prot_t? {
    var address = mach_vm_address_t(rawAddress)
    var size: mach_vm_size_t = 0
    var info = vm_region_basic_info_data_64_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<vm_region_basic_info_data_64_t>.size / MemoryLayout<integer_t>.size)
    var objectName: mach_port_t = 0
    let result = withUnsafeMutablePointer(to: &info) { infoPointer in
      infoPointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
        mach_vm_region(
          mach_task_self_, &address, &size, VM_REGION_BASIC_INFO_64, rebound, &count, &objectName)
      }
    }
    return result == KERN_SUCCESS ? info.protection : nil
  }
}
