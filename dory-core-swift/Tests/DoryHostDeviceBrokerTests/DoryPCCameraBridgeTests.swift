import CoreGraphics
import DoryHostDeviceBroker
import DoryMachinePC
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@Suite struct DoryPCCameraBridgeTests {
  @Test func convertsBoundedEncodedFramesToYUY2() throws {
    let encoded = try encodedImage(width: 2, height: 1)
    let yuy2 = try DoryPCCameraJPEGConverter.yuy2(
      encodedImage: encoded,
      width: 2,
      height: 1
    )

    #expect(yuy2.count == 4)
    #expect(yuy2[0] != yuy2[2])
    #expect(
      throws: DoryPCCameraBridgeError.unexpectedImageDimensions(
        expectedWidth: 4,
        expectedHeight: 1,
        actualWidth: 2,
        actualHeight: 1
      )
    ) {
      try DoryPCCameraJPEGConverter.yuy2(encodedImage: encoded, width: 4, height: 1)
    }
  }

  @Test func guestDemandLazilyCapturesAndWakesUVC() throws {
    let source = RecordingCameraSource(frame: try encodedImage(width: 2, height: 1))
    let bridge = try DoryPCCameraBridge(
      source: source,
      width: 2,
      height: 1,
      framesPerSecond: 30,
      frameTimeout: 1
    )
    let setInterface = try DoryPCUSBSetupPacket(bytes: [0x01, 11, 1, 0, 1, 0, 0, 0])
    #expect(
      bridge.device.perform(
        try .init(type: .control, direction: .out, endpoint: 0, setup: setInterface)
      ).status == .success
    )
    let transfer = try DoryPCUSBTransfer(
      type: .isochronous,
      direction: .in,
      endpoint: 1,
      maximumResponseBytes: 6
    )

    #expect(bridge.device.perform(transfer).status == .notReady)
    var packet: DoryPCUSBTransferResult?
    for _ in 0..<100 {
      let candidate = bridge.device.perform(transfer)
      if candidate.status == .success {
        packet = candidate
        break
      }
      usleep(10_000)
    }
    #expect(packet?.payload.count == 6)
    #expect(source.requestCount == 1)
    bridge.stop()
    #expect(source.stopped)
    #expect(!bridge.isActive)
  }
}

private final class RecordingCameraSource: DoryPCCameraJPEGFrameSource, @unchecked Sendable {
  private let lock = NSLock()
  private let frame: Data
  private var requests = 0
  private var stoppedStorage = false

  init(frame: Data) { self.frame = frame }

  var requestCount: Int { lock.withLock { requests } }
  var stopped: Bool { lock.withLock { stoppedStorage } }

  func nextJPEGFrameOrThrow(width: Int, height: Int, timeout: TimeInterval) throws -> Data {
    lock.withLock {
      requests += 1
      return frame
    }
  }

  func stop() { lock.withLock { stoppedStorage = true } }
}

private func encodedImage(width: Int, height: Int) throws -> Data {
  let rowBytes = width * 4
  var pixels = [UInt8](repeating: 0, count: rowBytes * height)
  for row in 0..<height {
    for column in 0..<width {
      let offset = row * rowBytes + column * 4
      if column.isMultiple(of: 2) {
        pixels.replaceSubrange(offset..<(offset + 4), with: [0, 0, 255, 255])
      } else {
        pixels.replaceSubrange(offset..<(offset + 4), with: [255, 0, 0, 255])
      }
    }
  }
  guard
    let provider = CGDataProvider(data: Data(pixels) as CFData),
    let image = CGImage(
      width: width,
      height: height,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: rowBytes,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(
        rawValue: CGBitmapInfo.byteOrder32Little.rawValue
          | CGImageAlphaInfo.premultipliedFirst.rawValue
      ),
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent
    )
  else { throw DoryPCCameraBridgeError.bitmapAllocationFailed }
  let data = NSMutableData()
  guard
    let destination = CGImageDestinationCreateWithData(
      data,
      UTType.jpeg.identifier as CFString,
      1,
      nil
    )
  else { throw DoryPCCameraBridgeError.imageDecodeFailed }
  CGImageDestinationAddImage(destination, image, nil)
  guard CGImageDestinationFinalize(destination) else {
    throw DoryPCCameraBridgeError.imageDecodeFailed
  }
  return data as Data
}
