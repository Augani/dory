import DoryMachinePC
import Foundation
import Testing

@Suite struct DoryPCUSBHIDDeviceTests {
  @Test func keyboardEnumeratesWithStandardHIDDescriptors() throws {
    let keyboard = DoryPCUSBHIDDevice(profile: .keyboard)
    let setup = try DoryPCUSBSetupPacket(bytes: [0x80, 6, 0, 1, 0, 0, 18, 0])
    let result = keyboard.perform(
      try .init(
        type: .control,
        direction: .in,
        endpoint: 0,
        setup: setup,
        maximumResponseBytes: 18
      )
    )
    #expect(result.status == .success)
    #expect(result.payload.count == 18)
    #expect(result.payload[8..<12] == [0xF4, 0x1A, 0x01, 0x12])
  }

  @Test func interruptReportsAreBoundedAndWaitWhenEmpty() throws {
    let mouse = DoryPCUSBHIDDevice(profile: .mouse, maximumQueuedReports: 1)
    let readiness = ReadinessCounter()
    mouse.setTransferReadyHandler { readiness.increment() }
    let transfer = try DoryPCUSBTransfer(
      type: .interrupt,
      direction: .in,
      endpoint: 1,
      maximumResponseBytes: 4
    )
    #expect(mouse.perform(transfer).status == .notReady)
    try mouse.enqueue(report: [1, 2, 3, 4])
    #expect(readiness.value == 1)
    #expect(throws: DoryPCUSBHIDError.queueFull(maximum: 1)) {
      try mouse.enqueue(report: [0, 0, 0, 0])
    }
    #expect(mouse.perform(transfer).payload == [1, 2, 3, 4])
    #expect(mouse.perform(transfer).status == .notReady)
  }
}

private final class ReadinessCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var value: Int { lock.withLock { count } }
  func increment() { lock.withLock { count += 1 } }
}
