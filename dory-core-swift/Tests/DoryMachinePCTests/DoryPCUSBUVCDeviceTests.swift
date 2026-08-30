import DoryMachinePC
import Testing

@Suite struct DoryPCUSBUVCDeviceTests {
  @Test func cameraEnumeratesAndPacketizesBoundedYUY2Frames() throws {
    let camera = try DoryPCUSBUVCDevice(width: 2, height: 1, framesPerSecond: 30)
    let descriptorSetup = try DoryPCUSBSetupPacket(bytes: [0x80, 6, 0, 2, 0, 0, 0xFF, 0])
    let descriptor = camera.perform(
      try .init(
        type: .control, direction: .in, endpoint: 0, setup: descriptorSetup,
        maximumResponseBytes: 255)
    )
    #expect(descriptor.status == .success)
    #expect(descriptor.payload[4] == 2)
    #expect(descriptor.payload.contains(0x0E))

    let setInterface = try DoryPCUSBSetupPacket(bytes: [0x01, 11, 1, 0, 1, 0, 0, 0])
    #expect(
      camera.perform(
        try .init(type: .control, direction: .out, endpoint: 0, setup: setInterface)
      ).status == .success)
    try camera.enqueueYUY2Frame([1, 2, 3, 4])
    let packet = camera.perform(
      try .init(type: .isochronous, direction: .in, endpoint: 1, maximumResponseBytes: 6)
    )
    #expect(packet.payload.count == 6)
    #expect(packet.payload[1] & 2 != 0)
    #expect(Array(packet.payload[2...]) == [1, 2, 3, 4])
    #expect(
      camera.perform(
        try .init(type: .isochronous, direction: .in, endpoint: 1, maximumResponseBytes: 6)
      ).status == .notReady)
  }
}
