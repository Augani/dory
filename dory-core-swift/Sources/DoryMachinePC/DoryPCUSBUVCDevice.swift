import Foundation

public enum DoryPCUSBUVCError: Error, Sendable, Equatable {
  case invalidDimensions
  case invalidFrameBytes(expected: Int, actual: Int)
  case queueFull(maximum: Int)
}

/// UVC 1.1 YUY2 camera backed by frames from Dory's separately authorized media bridge.
public final class DoryPCUSBUVCDevice: DoryPCUSBDevice, @unchecked Sendable {
  public let speed: DoryPCXHCIPortSpeed = .high
  public let width: UInt16
  public let height: UInt16
  public let framesPerSecond: UInt32
  public let maximumQueuedFrames: Int

  private let lock = NSLock()
  private var frames: [[UInt8]] = []
  private var activeFrame: [UInt8] = []
  private var activeOffset = 0
  private var frameIdentifier = false
  private var streamingAlternateSetting: UInt8 = 0
  private var probeControl: [UInt8]
  private var commitControl: [UInt8]

  public init(
    width: UInt16 = 1_280,
    height: UInt16 = 720,
    framesPerSecond: UInt32 = 30,
    maximumQueuedFrames: Int = 3
  ) throws {
    guard width > 0, height > 0, framesPerSecond > 0, maximumQueuedFrames > 0,
      Int(width) <= 4_096, Int(height) <= 2_160
    else { throw DoryPCUSBUVCError.invalidDimensions }
    self.width = width
    self.height = height
    self.framesPerSecond = framesPerSecond
    self.maximumQueuedFrames = maximumQueuedFrames
    probeControl = Self.streamingControl(
      width: width,
      height: height,
      framesPerSecond: framesPerSecond
    )
    commitControl = probeControl
  }

  public var frameByteCount: Int { Int(width) * Int(height) * 2 }

  public func enqueueYUY2Frame(_ bytes: [UInt8]) throws {
    guard bytes.count == frameByteCount else {
      throw DoryPCUSBUVCError.invalidFrameBytes(expected: frameByteCount, actual: bytes.count)
    }
    try lock.withLock {
      guard frames.count < maximumQueuedFrames else {
        throw DoryPCUSBUVCError.queueFull(maximum: maximumQueuedFrames)
      }
      frames.append(bytes)
    }
  }

  public func perform(_ transfer: DoryPCUSBTransfer) -> DoryPCUSBTransferResult {
    if transfer.type == .isochronous, transfer.direction == .in, transfer.endpoint == 1 {
      return nextVideoPacket(maximumBytes: transfer.maximumResponseBytes)
    }
    guard transfer.type == .control, let setup = transfer.setup else { return result(.stalled) }
    if setup.requestType & 0x60 == 0 { return standardControl(setup) }
    return videoControl(setup, payload: transfer.payload)
  }

  public func reset() {
    lock.withLock {
      frames.removeAll(keepingCapacity: true)
      activeFrame.removeAll(keepingCapacity: true)
      activeOffset = 0
      streamingAlternateSetting = 0
      probeControl = Self.streamingControl(
        width: width,
        height: height,
        framesPerSecond: framesPerSecond
      )
      commitControl = probeControl
    }
  }

  public func cancelAll() {
    lock.withLock {
      frames.removeAll(keepingCapacity: true)
      activeFrame.removeAll(keepingCapacity: true)
      activeOffset = 0
    }
  }

  private func nextVideoPacket(maximumBytes: Int) -> DoryPCUSBTransferResult {
    lock.withLock {
      guard streamingAlternateSetting == 1, maximumBytes > 2 else { return result(.notReady) }
      if activeFrame.isEmpty {
        guard !frames.isEmpty else { return result(.notReady) }
        activeFrame = frames.removeFirst()
        activeOffset = 0
        frameIdentifier.toggle()
      }
      let payloadBytes = min(maximumBytes - 2, activeFrame.count - activeOffset)
      let ending = activeOffset + payloadBytes == activeFrame.count
      var packet: [UInt8] = [2, 0x80 | (frameIdentifier ? 1 : 0) | (ending ? 2 : 0)]
      packet += activeFrame[activeOffset..<(activeOffset + payloadBytes)]
      activeOffset += payloadBytes
      if ending {
        activeFrame.removeAll(keepingCapacity: true)
        activeOffset = 0
      }
      return result(.success, packet)
    }
  }

  private func standardControl(_ setup: DoryPCUSBSetupPacket) -> DoryPCUSBTransferResult {
    switch setup.request {
    case 6 where setup.direction == .in:
      let type = UInt8(setup.value >> 8)
      let index = UInt8(truncatingIfNeeded: setup.value)
      let descriptor: [UInt8]?
      switch type {
      case 1: descriptor = deviceDescriptor
      case 2: descriptor = configurationDescriptor
      case 3: descriptor = stringDescriptor(index)
      default: descriptor = nil
      }
      guard let descriptor else { return result(.stalled) }
      return result(.success, Array(descriptor.prefix(Int(setup.length))))
    case 5,
      9 where setup.direction == .out:
      return result(.success)
    case 11 where setup.direction == .out && setup.index == 1:
      let alternate = UInt8(truncatingIfNeeded: setup.value)
      guard alternate <= 1 else { return result(.stalled) }
      lock.withLock { streamingAlternateSetting = alternate }
      return result(.success)
    case 10 where setup.direction == .in && setup.index == 1:
      return lock.withLock { result(.success, [streamingAlternateSetting]) }
    default:
      return result(.stalled)
    }
  }

  private func videoControl(
    _ setup: DoryPCUSBSetupPacket,
    payload: [UInt8]
  ) -> DoryPCUSBTransferResult {
    guard setup.index == 1 else { return result(.stalled) }
    let selector = UInt8(setup.value >> 8)
    guard selector == 1 || selector == 2 else { return result(.stalled) }
    switch setup.request {
    case 1 where setup.direction == .out:
      guard payload.count >= 26 else { return result(.stalled) }
      lock.withLock {
        if selector == 1 {
          probeControl = Array(payload.prefix(26))
        } else {
          commitControl = Array(payload.prefix(26))
        }
      }
      return result(.success)
    case 0x81 where setup.direction == .in:
      return lock.withLock {
        result(
          .success, Array((selector == 1 ? probeControl : commitControl).prefix(Int(setup.length))))
      }
    case 0x82, 0x83,
      0x87 where setup.direction == .in:
      return result(
        .success,
        Array(
          Self.streamingControl(
            width: width,
            height: height,
            framesPerSecond: framesPerSecond
          ).prefix(Int(setup.length))))
    case 0x85 where setup.direction == .in:
      return result(.success, [26, 0])
    case 0x86 where setup.direction == .in:
      return result(.success, [3])
    default:
      return result(.stalled)
    }
  }

  private var deviceDescriptor: [UInt8] {
    [18, 1, 0x00, 0x02, 0xEF, 0x02, 0x01, 64, 0xF4, 0x1A, 0x10, 0x12, 0, 1, 1, 2, 3, 1]
  }

  private var configurationDescriptor: [UInt8] {
    let interval = UInt32(10_000_000 / framesPerSecond)
    let frameBytes = UInt32(frameByteCount)
    let bitrate = frameBytes * framesPerSecond * 8
    var body: [UInt8] = [
      8, 11, 0, 2, 0x0E, 0x03, 0, 2,
      9, 4, 0, 0, 0, 0x0E, 0x01, 0, 0,
      13, 0x24, 1, 0x10, 0x01, 40, 0, 0x00, 0x6C, 0xDC, 0x02, 1, 1,
      18, 0x24, 2, 1, 0x01, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
      11, 0x24, 5, 2, 1, 0, 0, 0, 2, 0, 0,
      9, 0x24, 3, 3, 0x01, 0x01, 0, 2, 0,
      9, 4, 1, 0, 0, 0x0E, 0x02, 0, 0,
      14, 0x24, 1, 1, 77, 0, 0x81, 0, 3, 0, 0, 0, 1, 0,
      27, 0x24, 4, 1,
      0x59, 0x55, 0x59, 0x32, 0, 0x10, 0, 0x80, 0, 0, 0xAA, 0, 0x38, 0x9B, 0x71,
      16, 1, 0, 0, 0, 0,
      30, 0x24, 5, 1, 0,
    ]
    append(width, to: &body)
    append(height, to: &body)
    append(bitrate, to: &body)
    append(bitrate, to: &body)
    append(frameBytes, to: &body)
    append(interval, to: &body)
    body += [1]
    append(interval, to: &body)
    body += [6, 0x24, 13, 1, 1, 4]
    body += [9, 4, 1, 1, 1, 0x0E, 0x02, 0, 0]
    body += [7, 5, 0x81, 1, 0x00, 0x04, 1]
    let total = UInt16(body.count + 9)
    return [
      9, 2, UInt8(truncatingIfNeeded: total), UInt8(truncatingIfNeeded: total >> 8), 2, 1, 0, 0x80,
      50,
    ] + body
  }

  private func stringDescriptor(_ index: UInt8) -> [UInt8]? {
    if index == 0 { return [4, 3, 9, 4] }
    let text: String
    switch index {
    case 1: text = "Dory"
    case 2: text = "Dory Camera"
    case 3: text = "DORY-UVC-1"
    default: return nil
    }
    let payload = text.utf16.flatMap {
      [UInt8(truncatingIfNeeded: $0), UInt8(truncatingIfNeeded: $0 >> 8)]
    }
    return [UInt8(payload.count + 2), 3] + payload
  }

  private static func streamingControl(
    width: UInt16,
    height: UInt16,
    framesPerSecond: UInt32
  ) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 26)
    bytes[2] = 1
    bytes[3] = 1
    put(UInt32(10_000_000 / framesPerSecond), at: 4, in: &bytes)
    put(UInt32(width) * UInt32(height) * 2, at: 18, in: &bytes)
    put(UInt32(1_024), at: 22, in: &bytes)
    return bytes
  }

  private func result(_ status: DoryPCUSBTransferStatus, _ payload: [UInt8] = [])
    -> DoryPCUSBTransferResult
  {
    try! .init(status: status, payload: payload)
  }
}

private func append<T: FixedWidthInteger>(_ value: T, to bytes: inout [UInt8]) {
  bytes += (0..<MemoryLayout<T>.size).map { UInt8(truncatingIfNeeded: value >> T($0 * 8)) }
}

private func put<T: FixedWidthInteger>(_ value: T, at offset: Int, in bytes: inout [UInt8]) {
  for index in 0..<MemoryLayout<T>.size {
    bytes[offset + index] = UInt8(truncatingIfNeeded: value >> T(index * 8))
  }
}
