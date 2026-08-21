import AppKit
import DoryHV
import Foundation
import MetalKit

enum DesktopMetalDisplayError: Error, CustomStringConvertible {
    case metalUnavailable
    case shaderCompilation(String)

    var description: String {
        switch self {
        case .metalUnavailable:
            return "this Mac does not expose a Metal display device"
        case let .shaderCompilation(detail):
            return "could not build the Dory display shader: \(detail)"
        }
    }
}

/// Coalesces producer-thread flushes to the newest complete frame and performs one main-thread
/// upload. This keeps a busy compositor from building an unbounded queue of stale 16 MiB frames.
final class DesktopFrameMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = [VirtioGPUScanoutFrame]()
    private var deliveryScheduled = false
    nonisolated(unsafe) weak var view: DesktopMetalView?

    func submit(_ frame: VirtioGPUScanoutFrame) {
        lock.lock()
        if frame.dirtyRect.x == 0, frame.dirtyRect.y == 0,
           frame.dirtyRect.width == frame.width, frame.dirtyRect.height == frame.height {
            pending = [frame]
        } else {
            pending.append(frame)
            if pending.count > 256 { pending.removeFirst(pending.count - 256) }
        }
        let shouldSchedule = !deliveryScheduled
        deliveryScheduled = true
        lock.unlock()
        guard shouldSchedule else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.deliver()
            }
        }
    }

    /// Drop presentation storage only when the guest destroys the corresponding virtio-gpu
    /// resource. Direct scanout temporarily switches between application and compositor buffers;
    /// evicting an older compositor buffer merely because it was not recently visible makes its
    /// next partial update appear as a black or torn frame.
    func release(resourceID: UInt32) {
        lock.lock()
        pending.removeAll { $0.resourceID == resourceID }
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.view?.release(resourceID: resourceID)
            }
        }
    }

    @MainActor
    private func deliver() {
        lock.lock()
        let frames = pending
        pending.removeAll(keepingCapacity: true)
        deliveryScheduled = false
        lock.unlock()
        view?.present(frames)
    }
}

/// Moves copied cursor-plane updates from a vCPU thread to AppKit without retaining the guest
/// resource or touching NSCursor off the main thread.
final class DesktopCursorMailbox: @unchecked Sendable {
    nonisolated(unsafe) weak var view: DesktopMetalView?

    func submit(_ update: VirtioGPUCursorUpdate?) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.view?.presentCursor(update)
            }
        }
    }
}

@MainActor
final class DesktopMetalView: MTKView, MTKViewDelegate {
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let input: VirtioInput
    private let guestBackingScaleFactor: CGFloat
    private var resourceTextures: [UInt32: MTLTexture] = [:]
    private var scanoutTexture: MTLTexture?
    private var scanoutSize = CGSize.zero
    private var guestCursor = NSCursor.arrow
    private var guestCursorUpdate: VirtioGPUCursorUpdate?
    private var tracking: NSTrackingArea?
    private var scrollAccumulator = VirtioInputScrollAccumulator()
    private var pressedInput = VirtioInputPressedState()
    private var resizeGeneration: UInt64 = 0
    var onDrawableSizeChange: ((UInt32, UInt32) -> Void)?
    var onMacShortcut: ((NSEvent) -> Bool)?

    init(
        frame: NSRect,
        input: VirtioInput,
        guestBackingScaleFactor: CGFloat = 2
    ) throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            throw DesktopMetalDisplayError.metalUnavailable
        }
        self.input = input
        self.guestBackingScaleFactor = guestBackingScaleFactor
        self.commandQueue = commandQueue
        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "dory_scanout_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: "dory_scanout_fragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            self.pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw DesktopMetalDisplayError.shaderCompilation(String(describing: error))
        }
        super.init(frame: frame, device: device)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0.025, 0.03, 0.04, 1)
        framebufferOnly = true
        enableSetNeedsDisplay = true
        isPaused = true
        preferredFramesPerSecond = 60
        delegate = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let replacement = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(replacement)
        tracking = replacement
        super.updateTrackingAreas()
    }

    func present(_ frames: [VirtioGPUScanoutFrame]) {
        var updated = false
        for frame in frames {
            updated = presentUpdate(frame) || updated
        }
        if updated { needsDisplay = true }
    }

    func release(resourceID: UInt32) {
        resourceTextures.removeValue(forKey: resourceID)
    }

    func presentCursor(_ update: VirtioGPUCursorUpdate?) {
        guestCursorUpdate = update
        rebuildGuestCursor()
    }

    private func rebuildGuestCursor(pixelSize: CGSize? = nil) {
        guard let update = guestCursorUpdate else {
            guestCursor = Self.transparentCursor
            window?.invalidateCursorRects(for: self)
            return
        }
        let effectivePixelSize = pixelSize ?? drawableSize
        let cursorScale = bounds.width > 0
            ? max(1, effectivePixelSize.width / bounds.width)
            : CGFloat(1)
        guestCursor = Self.makeCursor(update, scale: cursorScale) ?? Self.transparentCursor
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: guestCursor)
    }

    private func presentUpdate(_ frame: VirtioGPUScanoutFrame) -> Bool {
        guard let pixelFormat = Self.pixelFormat(for: frame.format),
              let device,
              frame.width > 0, frame.height > 0,
              frame.dirtyRect.width > 0, frame.dirtyRect.height > 0,
              frame.dirtyRect.x <= frame.width,
              frame.dirtyRect.width <= frame.width - frame.dirtyRect.x,
              frame.dirtyRect.y <= frame.height,
              frame.dirtyRect.height <= frame.height - frame.dirtyRect.y,
              frame.stride >= frame.dirtyRect.width * 4,
              frame.bytes.count >= Int(frame.stride) * Int(frame.dirtyRect.height) else {
            return false
        }
        var texture = resourceTextures[frame.resourceID]
        if texture?.width != Int(frame.width)
            || texture?.height != Int(frame.height)
            || texture?.pixelFormat != pixelFormat {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: pixelFormat,
                width: Int(frame.width),
                height: Int(frame.height),
                mipmapped: false
            )
            descriptor.storageMode = .shared
            descriptor.usage = [.shaderRead]
            texture = device.makeTexture(descriptor: descriptor)
            resourceTextures[frame.resourceID] = texture
        }
        guard let texture else { return false }
        frame.bytes.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(
                    Int(frame.dirtyRect.x),
                    Int(frame.dirtyRect.y),
                    Int(frame.dirtyRect.width),
                    Int(frame.dirtyRect.height)
                ),
                mipmapLevel: 0,
                withBytes: baseAddress,
                bytesPerRow: Int(frame.stride)
            )
        }
        scanoutTexture = texture
        scanoutSize = CGSize(width: Int(frame.width), height: Int(frame.height))
        return true
    }

    func draw(in view: MTKView) {
        guard let texture = scanoutTexture,
              let descriptor = currentRenderPassDescriptor,
              let drawable = currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }

        let contentRect = scanoutContentRect(in: drawableSize)
        let viewport = MTLViewport(
            originX: contentRect.minX,
            originY: contentRect.minY,
            width: contentRect.width,
            height: contentRect.height,
            znear: 0,
            zfar: 1
        )
        encoder.setViewport(viewport)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange _: CGSize) {
        let guestPixelSize = CGSize(
            width: max(1, bounds.width * guestBackingScaleFactor),
            height: max(1, bounds.height * guestBackingScaleFactor)
        )
        if guestCursorUpdate != nil { rebuildGuestCursor(pixelSize: guestPixelSize) }
        let width = UInt32(clamping: max(1, Int(guestPixelSize.width.rounded())))
        let height = UInt32(clamping: max(1, Int(guestPixelSize.height.rounded())))
        resizeGeneration &+= 1
        let generation = resizeGeneration
        // AppKit reports every intermediate drag size. Debounce the guest modeset so Mutter/Xfce
        // receives the final Retina pixel size without reallocating scanout resources per mouse
        // event while the window is still moving.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.resizeGeneration == generation else { return }
                self.onDrawableSizeChange?(width, height)
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        if onMacShortcut?(event) == true { return }
        if event.modifierFlags.contains(.command),
           let character = event.charactersIgnoringModifiers?.lowercased(),
           let code = Self.macCommandShortcutMap[character] {
            sendControlShortcut(keyCode: code)
            return
        }
        guard let code = Self.linuxKeyCode(macKeyCode: event.keyCode) else {
            super.keyDown(with: event)
            return
        }
        sendTracked([VirtioInputEvent(type: 1, code: code, value: event.isARepeat ? 2 : 1)])
    }

    override func keyUp(with event: NSEvent) {
        guard let code = Self.linuxKeyCode(macKeyCode: event.keyCode) else {
            super.keyUp(with: event)
            return
        }
        sendTracked([VirtioInputEvent(type: 1, code: code, value: 0)])
    }

    override func flagsChanged(with event: NSEvent) {
        guard let code = Self.linuxKeyCode(macKeyCode: event.keyCode),
              let flag = Self.modifierFlag(macKeyCode: event.keyCode) else {
            super.flagsChanged(with: event)
            return
        }
        sendTracked([
            VirtioInputEvent(type: 1, code: code, value: event.modifierFlags.contains(flag) ? 1 : 0)
        ])
    }

    override func mouseMoved(with event: NSEvent) { sendPointer(event: event) }
    override func mouseDragged(with event: NSEvent) { sendPointer(event: event) }
    override func rightMouseDragged(with event: NSEvent) { sendPointer(event: event) }
    override func otherMouseDragged(with event: NSEvent) { sendPointer(event: event) }
    override func mouseDown(with event: NSEvent) { sendPointer(event: event, button: 272, pressed: true) }
    override func mouseUp(with event: NSEvent) { sendPointer(event: event, button: 272, pressed: false) }
    override func rightMouseDown(with event: NSEvent) { sendPointer(event: event, button: 273, pressed: true) }
    override func rightMouseUp(with event: NSEvent) { sendPointer(event: event, button: 273, pressed: false) }
    override func otherMouseDown(with event: NSEvent) {
        sendPointer(event: event, button: linuxOtherMouseButton(for: event.buttonNumber), pressed: true)
    }
    override func otherMouseUp(with event: NSEvent) {
        sendPointer(event: event, button: linuxOtherMouseButton(for: event.buttonNumber), pressed: false)
    }

    private func linuxOtherMouseButton(for buttonNumber: Int) -> UInt16 {
        switch buttonNumber {
        case 2: 274  // BTN_MIDDLE
        case 3: 275  // BTN_SIDE
        default: 276 // BTN_EXTRA
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let events = scrollAccumulator.events(
            horizontalDelta: event.scrollingDeltaX,
            verticalDelta: event.scrollingDeltaY,
            hasPreciseDeltas: event.hasPreciseScrollingDeltas
        )
        if !events.isEmpty { sendTracked(events) }
    }

    private func sendPointer(
        event: NSEvent,
        button: UInt16? = nil,
        pressed: Bool = false
    ) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let contentRect = scanoutContentRect(in: bounds.size)
        let normalizedX = min(1, max(0, (point.x - contentRect.minX) / max(1, contentRect.width)))
        let normalizedY = min(1, max(0, (point.y - contentRect.minY) / max(1, contentRect.height)))
        var events = [
            VirtioInputEvent(type: 3, code: 0, value: Int32((normalizedX * 32_767).rounded())),
            VirtioInputEvent(type: 3, code: 1, value: Int32((normalizedY * 32_767).rounded())),
        ]
        if let button {
            events.append(VirtioInputEvent(type: 1, code: button, value: pressed ? 1 : 0))
        }
        sendTracked(events)
    }

    func releasePressedInput() {
        let releases = pressedInput.releaseFrame()
        scrollAccumulator = VirtioInputScrollAccumulator()
        if !releases.isEmpty { input.send(frame: releases) }
    }

    private func sendTracked(_ events: [VirtioInputEvent]) {
        for event in events { pressedInput.record(event) }
        input.send(frame: events)
    }

    private func scanoutContentRect(in targetSize: CGSize) -> CGRect {
        guard scanoutSize.width > 0, scanoutSize.height > 0,
              targetSize.width > 0, targetSize.height > 0 else {
            return CGRect(origin: .zero, size: targetSize)
        }
        let sourceAspect = scanoutSize.width / scanoutSize.height
        let targetAspect = targetSize.width / targetSize.height
        if targetAspect > sourceAspect {
            let width = targetSize.height * sourceAspect
            return CGRect(
                x: (targetSize.width - width) / 2,
                y: 0,
                width: width,
                height: targetSize.height
            )
        }
        let height = targetSize.width / sourceAspect
        return CGRect(
            x: 0,
            y: (targetSize.height - height) / 2,
            width: targetSize.width,
            height: height
        )
    }

    private static func pixelFormat(for virtioFormat: UInt32) -> MTLPixelFormat? {
        switch virtioFormat {
        case 1, 2: .bgra8Unorm
        case 3, 4, 67, 68, 121, 134: .rgba8Unorm
        default: nil
        }
    }

    private static let transparentCursor: NSCursor = {
        let image = NSImage(
            size: NSSize(width: 1, height: 1),
            flipped: false,
            drawingHandler: { _ in true }
        )
        return NSCursor(image: image, hotSpot: .zero)
    }()

    private static func makeCursor(
        _ update: VirtioGPUCursorUpdate,
        scale: CGFloat
    ) -> NSCursor? {
        guard update.width > 0, update.height > 0,
              update.width <= 256, update.height <= 256,
              update.hotX < update.width, update.hotY < update.height,
              update.bytes.count == Int(update.width * update.height * 4),
              let provider = CGDataProvider(data: update.bytes as CFData),
              let image = CGImage(
                  width: Int(update.width),
                  height: Int(update.height),
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: Int(update.width) * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(
                      rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                  )),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else {
            return nil
        }
        let cursorImage = NSImage(
            cgImage: image,
            size: NSSize(
                width: CGFloat(update.width) / scale,
                height: CGFloat(update.height) / scale
            )
        )
        // VirtIO cursor hotspots are top-left based; NSCursor image coordinates are bottom-left.
        let appKitHotY = update.height - 1 - update.hotY
        return NSCursor(
            image: cursorImage,
            hotSpot: NSPoint(
                x: CGFloat(update.hotX) / scale,
                y: CGFloat(appKitHotY) / scale
            )
        )
    }

    private static func modifierFlag(macKeyCode: UInt16) -> NSEvent.ModifierFlags? {
        switch macKeyCode {
        case 54, 55: .command
        case 56, 60: .shift
        case 57: .capsLock
        case 58, 61: .option
        case 59, 62: .control
        default: nil
        }
    }

    private static func linuxKeyCode(macKeyCode: UInt16) -> UInt16? {
        keyMap[macKeyCode]
    }

    private func sendControlShortcut(keyCode: UInt16) {
        input.send(frame: [
            VirtioInputEvent(type: 1, code: 125, value: 0),
            VirtioInputEvent(type: 1, code: 126, value: 0),
            VirtioInputEvent(type: 1, code: 29, value: 1),
            VirtioInputEvent(type: 1, code: keyCode, value: 1),
            VirtioInputEvent(type: 1, code: keyCode, value: 0),
            VirtioInputEvent(type: 1, code: 29, value: 0),
        ])
    }

    // Match the Mac muscle memory supported by mature desktop hypervisors while leaving Command+Q
    // to the host application. Shift remains physically pressed for gestures such as Command+Shift+T.
    private static let macCommandShortcutMap: [String: UInt16] = [
        "a": 30, "f": 33, "l": 38, "n": 49, "o": 24, "p": 25,
        "r": 19, "s": 31, "t": 20, "w": 17, "z": 44,
    ]

    private static let keyMap: [UInt16: UInt16] = [
        0: 30, 1: 31, 2: 32, 3: 33, 4: 35, 5: 34, 6: 44, 7: 45,
        8: 46, 9: 47, 11: 48, 12: 16, 13: 17, 14: 18, 15: 19, 16: 21,
        17: 20, 18: 2, 19: 3, 20: 4, 21: 5, 22: 7, 23: 6, 24: 13,
        25: 10, 26: 8, 27: 12, 28: 9, 29: 11, 30: 27, 31: 24, 32: 22,
        33: 26, 34: 23, 35: 25, 36: 28, 37: 38, 38: 36, 39: 40, 40: 37,
        41: 39, 42: 43, 43: 51, 44: 53, 45: 49, 46: 50, 47: 52, 48: 15,
        49: 57, 50: 41, 51: 14, 53: 1, 54: 126, 55: 125, 56: 42, 57: 58,
        58: 56, 59: 29, 60: 54, 61: 100, 62: 97,
        65: 83, 67: 55, 69: 78, 71: 69, 75: 98, 76: 96, 78: 74, 81: 117,
        82: 82, 83: 79, 84: 80, 85: 81, 86: 75, 87: 76, 88: 77, 89: 71,
        91: 72, 92: 73,
        96: 63, 97: 64, 98: 65, 99: 61, 100: 66, 101: 67, 103: 87,
        109: 68, 111: 88, 114: 110, 115: 102, 116: 104, 117: 111, 118: 62,
        119: 107, 120: 60, 121: 109, 122: 59, 123: 105, 124: 106, 125: 108,
        126: 103,
    ]

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct RasterData {
        float4 position [[position]];
        float2 textureCoordinate;
    };

    vertex RasterData dory_scanout_vertex(uint vertexID [[vertex_id]]) {
        const float2 positions[4] = {
            float2(-1.0, -1.0), float2(1.0, -1.0),
            float2(-1.0, 1.0), float2(1.0, 1.0)
        };
        const float2 coordinates[4] = {
            float2(0.0, 1.0), float2(1.0, 1.0),
            float2(0.0, 0.0), float2(1.0, 0.0)
        };
        RasterData output;
        output.position = float4(positions[vertexID], 0.0, 1.0);
        output.textureCoordinate = coordinates[vertexID];
        return output;
    }

    fragment float4 dory_scanout_fragment(
        RasterData input [[stage_in]],
        texture2d<float> scanout [[texture(0)]]) {
        constexpr sampler textureSampler(coord::normalized, filter::linear);
        return scanout.sample(textureSampler, input.textureCoordinate);
    }
    """
}
