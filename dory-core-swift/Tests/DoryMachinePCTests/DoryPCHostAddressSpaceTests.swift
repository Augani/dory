import Darwin
import DoryDBTX86
import Foundation
import Testing

@testable import DoryMachinePC

@Suite struct DoryPCHostAddressSpaceTests {
  private func residentByteCount() -> UInt64? {
    var info = mach_task_basic_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { infoPointer in
      infoPointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
      }
    }
    return result == KERN_SUCCESS ? info.resident_size : nil
  }

  private func protection(
    at hostAddress: UInt64
  ) -> vm_prot_t? {
    var address = mach_vm_address_t(hostAddress)
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
    return result == KERN_SUCCESS && address == hostAddress ? info.protection : nil
  }

  private func kernelReadResult(at hostAddress: UInt64) -> kern_return_t {
    var value: UInt8 = 0
    var copiedByteCount: mach_vm_size_t = 0
    return withUnsafeMutablePointer(to: &value) { valuePointer in
      mach_vm_read_overwrite(
        mach_task_self_, mach_vm_address_t(hostAddress), 1,
        mach_vm_address_t(UInt(bitPattern: valuePointer)), &copiedByteCount)
    }
  }

  private func kernelWriteResult(at hostAddress: UInt64) -> kern_return_t {
    var value: UInt8 = 0
    return withUnsafeMutablePointer(to: &value) { valuePointer in
      mach_vm_write(
        mach_task_self_, mach_vm_address_t(hostAddress),
        vm_offset_t(UInt(bitPattern: valuePointer)), 1)
    }
  }

  @Test func configuredRAMUsesAFullGuestPhysicalReservation() throws {
    let machine = try DoryPCDirectKernelMachine(memoryBytes: 2 << 20)
    #expect(machine.hostAddressSpaceBase != 0)
    #expect(machine.hostAddressSpaceByteCount == Int(DoryPCV1ABI.above4GRAMStart))
    #expect(
      protection(at: machine.hostAddressSpaceBase) == (VM_PROT_READ | VM_PROT_WRITE)
    )
    #expect(
      protection(at: machine.hostAddressSpaceBase + DoryPCV1ABI.pcieMMIOBase)
        == VM_PROT_NONE
    )
    #expect(
      kernelReadResult(at: machine.hostAddressSpaceBase + DoryPCV1ABI.pcieMMIOBase)
        != KERN_SUCCESS)
    #expect(machine.physicalMemory.hostAddressSpaceBase == machine.hostAddressSpaceBase)
    #expect(
      machine.physicalMemory.hostAddressSpaceByteCount == machine.hostAddressSpaceByteCount)
    try machine.memory.writeScalar(at: 0x1ff000, value: 0x8877_6655_4433_2211, byteCount: 8)
    let direct = UnsafeRawPointer(
      bitPattern: UInt(machine.hostAddressSpaceBase + 0x1ff000)
    )!.loadUnaligned(as: UInt64.self)
    #expect(UInt64(littleEndian: direct) == 0x8877_6655_4433_2211)
  }

  @Test func RAMAboveTheMMIOHoleUsesItsArchitecturalPhysicalOffset() throws {
    let memoryBytes = Int(DoryPCV1ABI.mmioHoleStart) + (2 << 20)
    let machine = try DoryPCDirectKernelMachine(memoryBytes: memoryBytes)
    #expect(
      machine.hostAddressSpaceByteCount
        == Int(DoryPCV1ABI.above4GRAMStart) + (2 << 20)
    )
    try machine.physicalMemory.writeScalar(
      at: DoryPCV1ABI.above4GRAMStart,
      value: 0xA5,
      byteCount: 1
    )
    let direct = UnsafeRawPointer(
      bitPattern: UInt(machine.hostAddressSpaceBase + DoryPCV1ABI.above4GRAMStart)
    )!.assumingMemoryBound(to: UInt8.self)
    #expect(direct.pointee == 0xA5)
    #expect(
      protection(at: machine.hostAddressSpaceBase + DoryPCV1ABI.above4GRAMStart)
        == (VM_PROT_READ | VM_PROT_WRITE)
    )
  }

  @Test func firmwareImageIsMirroredIntoReadOnlyROM() throws {
    let image = Data(repeating: 0xA5, count: 4_096)
    let flash = try DoryPCFirmwareFlash(image: image)
    let machine = try DoryPCDirectKernelMachine(
      memoryBytes: 2 << 20,
      platformMMIODevices: [flash]
    )
    let romAddress = machine.hostAddressSpaceBase + DoryPCV1ABI.firmwareCodeBase
    let rom = UnsafeRawPointer(bitPattern: UInt(romAddress))!.assumingMemoryBound(to: UInt8.self)
    #expect(rom.pointee == 0xff)
    #expect(rom.advanced(by: Int(flash.imageOffset) - 1).pointee == 0xff)
    #expect(rom.advanced(by: Int(flash.imageOffset)).pointee == 0xA5)
    #expect(rom.advanced(by: Int(flash.byteCount) - 1).pointee == 0xA5)
    #expect(protection(at: romAddress) == VM_PROT_READ)
    #expect(kernelWriteResult(at: romAddress) != KERN_SUCCESS)
    #expect(
      try machine.physicalMemory.read(at: DoryPCV1ABI.uefiResetAddress, byteCount: 1) == [0xA5])
    #expect(throws: DoryPCPhysicalMemoryError.self) {
      try machine.physicalMemory.write(at: DoryPCV1ABI.uefiResetAddress, bytes: [0])
    }
  }

  @Test func multiGigabyteReservationDoesNotBecomeResidentMemory() throws {
    let before = try #require(residentByteCount())
    let machine = try DoryPCDirectKernelMachine(memoryBytes: 2 << 20)
    let after = try #require(residentByteCount())
    #expect(machine.hostAddressSpaceByteCount == 4 << 30)
    #expect(after >= before ? after - before < 256 << 20 : true)
  }
}
