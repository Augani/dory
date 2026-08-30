import CoreGraphics
import DoryHostCamera
import DoryMachinePC
import Foundation
import ImageIO

public enum DoryPCCameraBridgeError: Error, Sendable, Equatable {
  case invalidDimensions
  case encodedFrameTooLarge(actual: Int, maximum: Int)
  case imageDecodeFailed
  case unexpectedImageDimensions(
    expectedWidth: Int, expectedHeight: Int, actualWidth: Int, actualHeight: Int)
  case bitmapAllocationFailed
  case bitmapRenderFailed
}

public protocol DoryPCCameraJPEGFrameSource: AnyObject, Sendable {
  func nextJPEGFrameOrThrow(width: Int, height: Int, timeout: TimeInterval) throws -> Data
  func stop()
}

extension DoryMacCameraBackend: DoryPCCameraJPEGFrameSource {}

public enum DoryPCCameraJPEGConverter {
  public static let maximumEncodedFrameBytes = 4 * 1024 * 1024

  public static func yuy2(
    encodedImage: Data,
    width: Int,
    height: Int
  ) throws -> [UInt8] {
    guard width > 0, height > 0, width <= 4_096, height <= 2_160, width.isMultiple(of: 2)
    else { throw DoryPCCameraBridgeError.invalidDimensions }
    guard encodedImage.count <= maximumEncodedFrameBytes else {
      throw DoryPCCameraBridgeError.encodedFrameTooLarge(
        actual: encodedImage.count,
        maximum: maximumEncodedFrameBytes
      )
    }
    guard
      let source = CGImageSourceCreateWithData(encodedImage as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(
        source,
        0,
        [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
      )
    else { throw DoryPCCameraBridgeError.imageDecodeFailed }
    guard image.width == width, image.height == height else {
      throw DoryPCCameraBridgeError.unexpectedImageDimensions(
        expectedWidth: width,
        expectedHeight: height,
        actualWidth: image.width,
        actualHeight: image.height
      )
    }
    let rowBytes = width * 4
    var bgra = [UInt8](repeating: 0, count: rowBytes * height)
    let rendered = bgra.withUnsafeMutableBytes { bytes -> Bool in
      guard
        let context = CGContext(
          data: bytes.baseAddress,
          width: width,
          height: height,
          bitsPerComponent: 8,
          bytesPerRow: rowBytes,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.premultipliedFirst.rawValue
        )
      else { return false }
      context.interpolationQuality = .none
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    guard rendered else { throw DoryPCCameraBridgeError.bitmapRenderFailed }

    var output = [UInt8](repeating: 0, count: width * height * 2)
    var outputOffset = 0
    for row in 0..<height {
      let rowOffset = row * rowBytes
      for column in stride(from: 0, to: width, by: 2) {
        let first = rowOffset + column * 4
        let second = first + 4
        let b0 = Int(bgra[first])
        let g0 = Int(bgra[first + 1])
        let r0 = Int(bgra[first + 2])
        let b1 = Int(bgra[second])
        let g1 = Int(bgra[second + 1])
        let r1 = Int(bgra[second + 2])
        output[outputOffset] = luma(red: r0, green: g0, blue: b0)
        output[outputOffset + 1] = chromaBlue(
          red: (r0 + r1) / 2,
          green: (g0 + g1) / 2,
          blue: (b0 + b1) / 2
        )
        output[outputOffset + 2] = luma(red: r1, green: g1, blue: b1)
        output[outputOffset + 3] = chromaRed(
          red: (r0 + r1) / 2,
          green: (g0 + g1) / 2,
          blue: (b0 + b1) / 2
        )
        outputOffset += 4
      }
    }
    return output
  }

  private static func luma(red: Int, green: Int, blue: Int) -> UInt8 {
    clamped(((66 * red + 129 * green + 25 * blue + 128) >> 8) + 16)
  }

  private static func chromaBlue(red: Int, green: Int, blue: Int) -> UInt8 {
    clamped(((-38 * red - 74 * green + 112 * blue + 128) >> 8) + 128)
  }

  private static func chromaRed(red: Int, green: Int, blue: Int) -> UInt8 {
    clamped(((112 * red - 94 * green - 18 * blue + 128) >> 8) + 128)
  }

  private static func clamped(_ value: Int) -> UInt8 {
    UInt8(max(0, min(255, value)))
  }
}

public final class DoryPCCameraBridge: @unchecked Sendable {
  public let device: DoryPCUSBUVCDevice

  private let source: any DoryPCCameraJPEGFrameSource
  private let queue = DispatchQueue(label: "com.dory.desktop.pc-camera-bridge", qos: .userInitiated)
  private let lock = NSLock()
  private let frameTimeout: TimeInterval
  private let failureHandler: @Sendable (Error) -> Void
  private var active = true
  private var frameRequestPending = false

  public init(
    source: any DoryPCCameraJPEGFrameSource,
    width: UInt16 = 1_280,
    height: UInt16 = 720,
    framesPerSecond: UInt32 = 30,
    frameTimeout: TimeInterval = 2,
    failureHandler: @escaping @Sendable (Error) -> Void = { _ in }
  ) throws {
    guard width.isMultiple(of: 2), frameTimeout > 0, frameTimeout <= 15 else {
      throw DoryPCCameraBridgeError.invalidDimensions
    }
    self.source = source
    self.frameTimeout = frameTimeout
    self.failureHandler = failureHandler
    device = try .init(
      width: width,
      height: height,
      framesPerSecond: framesPerSecond,
      maximumQueuedFrames: 3
    )
    device.setFrameDemandHandler { [weak self] in self?.requestFrame() }
  }

  public var isActive: Bool { lock.withLock { active } }

  public func stop() {
    let shouldStop = lock.withLock {
      guard active else { return false }
      active = false
      return true
    }
    guard shouldStop else { return }
    device.setFrameDemandHandler(nil)
    device.cancelAll()
    source.stop()
  }

  private func requestFrame() {
    let admitted = lock.withLock {
      guard active, !frameRequestPending else { return false }
      frameRequestPending = true
      return true
    }
    guard admitted else { return }
    queue.async { [weak self] in self?.produceFrame() }
  }

  private func produceFrame() {
    defer { lock.withLock { frameRequestPending = false } }
    guard lock.withLock({ active }) else { return }
    do {
      let encoded = try source.nextJPEGFrameOrThrow(
        width: Int(device.width),
        height: Int(device.height),
        timeout: frameTimeout
      )
      let yuy2 = try DoryPCCameraJPEGConverter.yuy2(
        encodedImage: encoded,
        width: Int(device.width),
        height: Int(device.height)
      )
      guard lock.withLock({ active }) else { return }
      try device.enqueueNewestYUY2Frame(yuy2)
    } catch {
      if lock.withLock({ active }) { failureHandler(error) }
    }
  }

  deinit {
    stop()
  }
}
