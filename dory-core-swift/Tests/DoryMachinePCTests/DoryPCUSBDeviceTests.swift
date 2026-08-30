import DoryMachinePC
import Testing

@Suite struct DoryPCUSBDeviceTests {
  @Test func setupAndTransfersAreTypedAndBounded() throws {
    let setup = try DoryPCUSBSetupPacket(
      bytes: [0x80, 6, 0, 1, 0, 0, 18, 0]
    )
    #expect(setup.direction == .in)
    #expect(setup.value == 0x0100)
    #expect(setup.length == 18)
    let transfer = try DoryPCUSBTransfer(
      type: .control,
      direction: .in,
      endpoint: 0,
      setup: setup,
      maximumResponseBytes: 18
    )
    let result = try DoryPCUSBTransferResult(status: .success, payload: [1, 2, 3])
    let device = DoryPCUSBRecordingDevice(queuedResults: [result])

    #expect(device.perform(transfer) == result)
    #expect(device.transfers == [transfer])
    device.reset()
    device.cancelAll()
    #expect(device.resetCount == 1)
    #expect(device.cancellationCount == 1)
  }

  @Test func malformedOrOversizedRequestsFailClosed() {
    #expect(throws: DoryPCUSBDeviceError.invalidSetupPacket) {
      _ = try DoryPCUSBSetupPacket(bytes: [UInt8](repeating: 0, count: 7))
    }
    #expect(throws: DoryPCUSBDeviceError.invalidTransfer) {
      _ = try DoryPCUSBTransfer(
        type: .bulk,
        direction: .out,
        endpoint: 1,
        payload: [UInt8](
          repeating: 0,
          count: DoryPCUSBDeviceLimits.maximumTransferBytes + 1
        )
      )
    }
  }
}
