import AppKit
import CoreGraphics
import Darwin
import DoryRendererWorkerWireContracts
import DoryVMDisplayWireContracts
import Metal
import QuartzCore
import SwiftUI

extension Notification.Name {
    static let doryOpenLinuxMachineDisplay = Notification.Name(
        "dev.dory.open-linux-machine-display"
    )
}

nonisolated struct LinuxMachineDisplayWindow: Codable, Hashable, Identifiable {
    var machineID: String
    var scanoutID: UInt32 = 0

    var id: String { "\(machineID):\(scanoutID)" }
}

struct LinuxMachineDisplayView: NSViewRepresentable {
    let machineID: String
    let scanoutID: UInt32

    func makeNSView(context: Context) -> LinuxMachineMetalView {
        LinuxMachineMetalView(machineID: machineID, scanoutID: scanoutID)
    }

    func updateNSView(_ nsView: LinuxMachineMetalView, context: Context) {}

    static func dismantleNSView(_ nsView: LinuxMachineMetalView, coordinator: ()) {
        nsView.stop()
    }
}

private final class LinuxMachineImportedFrame: @unchecked Sendable {
    let texture: any MTLTexture
    let frame: DoryVMDisplayFrame

    private let mappedAddress: UnsafeMutableRawPointer?
    private let mappedLength: Int
    private let buffer: (any MTLBuffer)?
    private let sharedTextureHandle: MTLSharedTextureHandle?

    init(
        texture: any MTLTexture,
        frame: DoryVMDisplayFrame,
        mappedAddress: UnsafeMutableRawPointer? = nil,
        mappedLength: Int = 0,
        buffer: (any MTLBuffer)? = nil,
        sharedTextureHandle: MTLSharedTextureHandle? = nil
    ) {
        self.texture = texture
        self.frame = frame
        self.mappedAddress = mappedAddress
        self.mappedLength = mappedLength
        self.buffer = buffer
        self.sharedTextureHandle = sharedTextureHandle
    }

    deinit {
        if let mappedAddress, mappedLength > 0 {
            munmap(mappedAddress, mappedLength)
        }
    }
}

private enum LinuxMachineCaptureModifierTransition {
    case forward
    case release
    case consume
}

private struct LinuxMachinePointerCaptureState {
    private(set) var isCaptured = false
    private(set) var acceptsAbsoluteInput = true
    private var consumesReleaseChord = false

    mutating func capture() -> Bool {
        guard !isCaptured else { return false }
        isCaptured = true
        acceptsAbsoluteInput = false
        consumesReleaseChord = false
        return true
    }

    mutating func cancel() -> Bool {
        let wasCaptured = isCaptured
        isCaptured = false
        consumesReleaseChord = false
        return wasCaptured
    }

    mutating func modifierTransition(
        command: Bool,
        control: Bool
    ) -> LinuxMachineCaptureModifierTransition {
        if isCaptured, command, control {
            isCaptured = false
            consumesReleaseChord = true
            return .release
        }
        if consumesReleaseChord {
            if !command && !control { consumesReleaseChord = false }
            return .consume
        }
        return .forward
    }
}

private final class LinuxMachineDisplayClient: @unchecked Sendable {
    typealias FrameHandler = @MainActor @Sendable (
        DoryVMDisplayFrame,
        [FileHandle],
        MTLSharedTextureHandle?
    ) -> Void
    typealias CursorHandler = @MainActor @Sendable (DoryVMDisplayCursor?) -> Void

    private struct State {
        var stopped = false
        var framePollInFlight = false
        var cursorPollInFlight = false
        var afterFrameSequence: UInt64 = 0
        var afterCursorSequence: UInt64 = 0
        var operationID: UUID?
        var nextCommandSequence: UInt64 = 1
    }

    private let machineID: String
    private let scanoutID: UInt32
    private let connection: NSXPCConnection
    private let frameHandler: FrameHandler
    private let cursorHandler: CursorHandler
    private let failureHandler: @MainActor @Sendable (String) -> Void
    private let queue = DispatchQueue(
        label: "dev.dory.app.linux-display-relay",
        qos: .userInteractive
    )
    private let lock = NSLock()
    private var state = State()

    init(
        machineID: String,
        scanoutID: UInt32,
        frameHandler: @escaping FrameHandler,
        cursorHandler: @escaping CursorHandler,
        failureHandler: @escaping @MainActor @Sendable (String) -> Void
    ) {
        self.machineID = machineID
        self.scanoutID = scanoutID
        self.frameHandler = frameHandler
        self.cursorHandler = cursorHandler
        self.failureHandler = failureHandler
        let controlName = ProcessInfo.processInfo.environment["DORYD_MACH_SERVICE"]
            ?? "dev.dory.doryd"
        let serviceName = DoryVMDisplayBrokerXPCInterface.serviceName(
            controlServiceName: controlName
        )
        let connection = NSXPCConnection(machServiceName: serviceName, options: [])
        connection.remoteObjectInterface = DoryVMDisplayBrokerXPCInterface.make()
        self.connection = connection
        connection.interruptionHandler = { [weak self] in
            self?.failed("The VM display broker was interrupted.")
        }
        connection.invalidationHandler = { [weak self] in
            self?.failed("The VM display broker disconnected.")
        }
        connection.resume()
    }

    func start() {
        schedulePoll(after: 0)
        scheduleCursorPoll(after: 0)
    }

    func stop() {
        let shouldInvalidate = lock.withLock { () -> Bool in
            guard !state.stopped else { return false }
            state.stopped = true
            return true
        }
        if shouldInvalidate { connection.invalidate() }
    }

    func acknowledge(_ frame: DoryVMDisplayFrame, presented: Bool) {
        guard let leaseID = try? frame.leaseID.rawValue.uuidString else {
            failed("The VM display frame carried an invalid lease.")
            return
        }
        proxy { proxy in
            proxy.acknowledgeFrame(
                self.machineID,
                leaseID: leaseID,
                presented: presented
            ) { [weak self] accepted, detail in
                guard let self else { return }
                if accepted {
                    self.lock.withLock {
                        self.state.afterFrameSequence = max(
                            self.state.afterFrameSequence,
                            frame.sequence
                        )
                    }
                    self.schedulePoll(after: 0)
                } else {
                    self.failed("The VM display broker rejected a frame acknowledgement: \(detail)")
                }
            }
        }
    }

    func sendInput(
        endpoint: DoryVMDisplayInputEndpoint,
        events: [DoryVMDisplayInputEvent]
    ) {
        sendCommand { operationID, sequence in
            try .input(
                machineID: machineID,
                operationID: operationID,
                sequence: sequence,
                endpoint: endpoint,
                events: events
            )
        }
    }

    func sendResize(
        width: UInt32,
        height: UInt32,
        physicalWidthMillimeters: UInt16,
        physicalHeightMillimeters: UInt16
    ) {
        sendCommand { operationID, sequence in
            try .resize(
                machineID: machineID,
                operationID: operationID,
                sequence: sequence,
                scanoutID: scanoutID,
                width: width,
                height: height,
                physicalWidthMillimeters: physicalWidthMillimeters,
                physicalHeightMillimeters: physicalHeightMillimeters
            )
        }
    }

    private func sendCommand(
        _ make: (UUID, UInt64) throws -> DoryVMDisplayCommand
    ) {
        let identity = lock.withLock { () -> (UUID, UInt64)? in
            guard !state.stopped,
                  let operationID = state.operationID,
                  state.nextCommandSequence < UInt64.max else { return nil }
            let sequence = state.nextCommandSequence
            state.nextCommandSequence += 1
            return (operationID, sequence)
        }
        guard let identity else { return }
        do {
            let data = try DoryVMDisplayCommandCodec.encode(
                make(identity.0, identity.1)
            )
            proxy { proxy in
                proxy.sendCommand(data) { [weak self] accepted, detail in
                    if !accepted {
                        self?.failed("The VM rejected a display command: \(detail)")
                    }
                }
            }
        } catch {
            failed("Could not encode a VM display command: \(error)")
        }
    }

    private func schedulePoll(after delay: TimeInterval) {
        queue.asyncAfter(deadline: .now() + max(0, delay)) { [weak self] in
            self?.poll()
        }
    }

    private func poll() {
        let afterSequence = lock.withLock { () -> UInt64? in
            guard !state.stopped, !state.framePollInFlight else { return nil }
            state.framePollInFlight = true
            return state.afterFrameSequence
        }
        guard let afterSequence else { return }
        proxy { proxy in
            proxy.nextFrame(
                self.machineID,
                scanoutID: self.scanoutID,
                afterSequence: afterSequence
            ) { [weak self] found, data, descriptors, handle, detail in
                self?.receivedFrame(
                    found: found,
                    data: data,
                    descriptors: descriptors,
                    handle: handle,
                    detail: detail
                )
            }
        }
    }

    private func receivedFrame(
        found: Bool,
        data: Data,
        descriptors: [FileHandle],
        handle: MTLSharedTextureHandle?,
        detail: String
    ) {
        lock.withLock { state.framePollInFlight = false }
        guard found else {
            if !detail.isEmpty, detail != "no-frame" {
                failed("The VM display broker could not provide a frame: \(detail)")
            } else {
                schedulePoll(after: 1.0 / 60.0)
            }
            return
        }
        do {
            let frame = try DoryVMDisplayFrameCodec.decode(data)
            try frame.validate(
                descriptorCount: descriptors.count,
                hasSharedTextureHandle: handle != nil
            )
            guard frame.machineID == machineID, frame.scanoutID == scanoutID,
                  let operationID = UUID(uuidString: frame.operationID) else {
                throw DoryVMDisplayWireError.invalidFrameIdentity
            }
            lock.withLock { state.operationID = operationID }
            Task { @MainActor [frameHandler] in
                frameHandler(frame, descriptors, handle)
            }
        } catch {
            for descriptor in descriptors { try? descriptor.close() }
            failed("The VM display broker returned an invalid frame: \(error)")
            schedulePoll(after: 0.25)
        }
    }

    private func scheduleCursorPoll(after delay: TimeInterval) {
        queue.asyncAfter(deadline: .now() + max(0, delay)) { [weak self] in
            self?.pollCursor()
        }
    }

    private func pollCursor() {
        let afterSequence = lock.withLock { () -> UInt64? in
            guard !state.stopped, !state.cursorPollInFlight else { return nil }
            state.cursorPollInFlight = true
            return state.afterCursorSequence
        }
        guard let afterSequence else { return }
        proxy { proxy in
            proxy.nextCursor(
                self.machineID,
                scanoutID: self.scanoutID,
                afterSequence: afterSequence
            ) { [weak self] found, data, detail in
                self?.receivedCursor(found: found, data: data, detail: detail)
            }
        }
    }

    private func receivedCursor(found: Bool, data: Data, detail: String) {
        lock.withLock { state.cursorPollInFlight = false }
        guard found else {
            if !detail.isEmpty, detail != "no-cursor" {
                failed("The VM display broker could not provide a cursor: \(detail)")
                scheduleCursorPoll(after: 0.25)
            } else {
                scheduleCursorPoll(after: 1.0 / 60.0)
            }
            return
        }
        do {
            let cursor = try DoryVMDisplayCursorCodec.decode(data)
            guard cursor.machineID == machineID,
                  cursor.scanoutID == scanoutID,
                  lock.withLock({ state.operationID?.uuidString.lowercased() })
                    == cursor.operationID else {
                throw DoryVMDisplayWireError.invalidCursor
            }
            lock.withLock { state.afterCursorSequence = cursor.sequence }
            Task { @MainActor [cursorHandler] in
                cursorHandler(cursor.visible ? cursor : nil)
            }
            scheduleCursorPoll(after: 0)
        } catch {
            failed("The VM display broker returned an invalid cursor: \(error)")
            scheduleCursorPoll(after: 0.25)
        }
    }

    private func proxy(_ body: (DoryVMDisplayBrokerXPCProtocol) -> Void) {
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] error in
            self?.failed("The VM display broker call failed: \(error)")
        }) as? DoryVMDisplayBrokerXPCProtocol else {
            failed("The VM display broker proxy is unavailable.")
            return
        }
        body(proxy)
    }

    private func failed(_ message: String) {
        let shouldReport = lock.withLock { !state.stopped }
        guard shouldReport else { return }
        Task { @MainActor [failureHandler] in failureHandler(message) }
    }
}

@MainActor
final class LinuxMachineMetalView: NSView {
    private let machineID: String
    private let scanoutID: UInt32
    private let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private let pipeline: any MTLRenderPipelineState
    private let sampler: any MTLSamplerState
    private var client: LinuxMachineDisplayClient!
    private var resizeWorkItem: DispatchWorkItem?
    private var trackingAreaReference: NSTrackingArea?
    private var lastFailure: String?
    private var guestCursor = NSCursor.arrow
    private var guestCursorUpdate: DoryVMDisplayCursor?
    private var scanoutSize = CGSize.zero
    private var pointerCaptureState = LinuxMachinePointerCaptureState()
    private var pressedKeyboardCodes = Set<UInt16>()
    private var pressedAbsoluteButtons = Set<UInt16>()
    private var pressedRelativeButtons = Set<UInt16>()
    private var hostCursorHidden = false

    override var acceptsFirstResponder: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override var isFlipped: Bool { true }
    override func makeBackingLayer() -> CALayer { CAMetalLayer() }

    init(machineID: String, scanoutID: UInt32) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.shaderSource, options: nil),
              let vertex = library.makeFunction(name: "doryLinuxDisplayVertex"),
              let fragment = library.makeFunction(name: "doryLinuxDisplayFragment") else {
            fatalError("Dory requires Metal for Linux VM presentation")
        }
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertex
        pipelineDescriptor.fragmentFunction = fragment
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(
            descriptor: pipelineDescriptor
        ) else {
            fatalError("Dory could not create its Linux display pipeline")
        }
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            fatalError("Dory could not create its Linux display sampler")
        }
        self.machineID = machineID
        self.scanoutID = scanoutID
        self.device = device
        self.commandQueue = queue
        self.pipeline = pipeline
        self.sampler = sampler
        super.init(frame: .zero)
        wantsLayer = true
        guard let metalLayer = layer as? CAMetalLayer else {
            fatalError("Dory could not create a Linux display Metal layer")
        }
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.contentsGravity = .resizeAspect
        client = LinuxMachineDisplayClient(
            machineID: machineID,
            scanoutID: scanoutID,
            frameHandler: { [weak self] in self?.present($0, descriptors: $1, handle: $2) },
            cursorHandler: { [weak self] in self?.presentCursor($0) },
            failureHandler: { [weak self] in self?.showFailure($0) }
        )
        client.start()
    }

    required init?(coder: NSCoder) { nil }

    func stop() {
        resizeWorkItem?.cancel()
        resizeWorkItem = nil
        releasePressedInput()
        client?.stop()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        updateDrawableSizeAndScheduleResize()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { releasePressedInput() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        updateDrawableSizeAndScheduleResize()
    }

    override func updateTrackingAreas() {
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingAreaReference = area
        super.updateTrackingAreas()
    }

    private func updateDrawableSizeAndScheduleResize() {
        guard let metalLayer = layer as? CAMetalLayer else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let pixelSize = CGSize(
            width: max(1, bounds.width * scale),
            height: max(1, bounds.height * scale)
        )
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = pixelSize
        resizeWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.sendResize(pixelSize: pixelSize) }
        }
        resizeWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: item)
    }

    private func sendResize(pixelSize: CGSize) {
        let width = UInt32(clamping: max(1, Int(pixelSize.width.rounded())))
        let height = UInt32(clamping: max(1, Int(pixelSize.height.rounded())))
        let physical = physicalSize(width: width, height: height)
        client.sendResize(
            width: width,
            height: height,
            physicalWidthMillimeters: physical.0,
            physicalHeightMillimeters: physical.1
        )
    }

    private func physicalSize(width: UInt32, height: UInt32) -> (UInt16, UInt16) {
        guard let screen = window?.screen,
              let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
              ] as? NSNumber,
              screen.frame.width > 0, screen.frame.height > 0 else {
            return Self.fallbackPhysicalSize(width: width, height: height)
        }
        let panel = CGDisplayScreenSize(CGDirectDisplayID(number.uint32Value))
        guard panel.width > 0, panel.height > 0 else {
            return Self.fallbackPhysicalSize(width: width, height: height)
        }
        return (
            UInt16(clamping: max(1, Int((panel.width * bounds.width / screen.frame.width).rounded()))),
            UInt16(clamping: max(1, Int((panel.height * bounds.height / screen.frame.height).rounded())))
        )
    }

    private static func fallbackPhysicalSize(width: UInt32, height: UInt32) -> (UInt16, UInt16) {
        (
            UInt16(clamping: max(1, Int((Double(width) * 25.4 / 160).rounded()))),
            UInt16(clamping: max(1, Int((Double(height) * 25.4 / 160).rounded())))
        )
    }

    private func present(
        _ frame: DoryVMDisplayFrame,
        descriptors: [FileHandle],
        handle: MTLSharedTextureHandle?
    ) {
        do {
            let imported = try importFrame(frame, descriptors: descriptors, handle: handle)
            scanoutSize = CGSize(
                width: Int(frame.sourceRect.width),
                height: Int(frame.sourceRect.height)
            )
            if guestCursorUpdate != nil { rebuildGuestCursor() }
            guard render(imported) else {
                client.acknowledge(frame, presented: false)
                return
            }
            client.acknowledge(frame, presented: true)
        } catch {
            for descriptor in descriptors { try? descriptor.close() }
            client.acknowledge(frame, presented: false)
            showFailure("Dory could not import the Linux display frame: \(error)")
        }
    }

    private func importFrame(
        _ frame: DoryVMDisplayFrame,
        descriptors: [FileHandle],
        handle: MTLSharedTextureHandle?
    ) throws -> LinuxMachineImportedFrame {
        switch frame.transport {
        case .sharedTexture:
            guard descriptors.isEmpty, let handle,
                  let texture = device.makeSharedTexture(handle: handle) else {
                throw DoryVMDisplayWireError.invalidTransportAuthority
            }
            return LinuxMachineImportedFrame(
                texture: texture,
                frame: frame,
                sharedTextureHandle: handle
            )
        case .sharedMemory:
            guard descriptors.count == 1, handle == nil else {
                throw DoryVMDisplayWireError.invalidTransportAuthority
            }
            let descriptor = descriptors[0]
            let lease = try DoryRendererScanoutLeaseCodec.decode(frame.leasePayload)
            guard lease.declaredFileSize <= UInt64(Int.max),
                  lease.storageOffset <= UInt64(Int.max) else {
                throw DoryVMDisplayWireError.invalidTransportAuthority
            }
            let length = Int(lease.declaredFileSize)
            var statBuffer = stat()
            guard length > 0, fstat(descriptor.fileDescriptor, &statBuffer) == 0,
                  statBuffer.st_size == off_t(length) else {
                throw DoryVMDisplayWireError.invalidTransportAuthority
            }
            let address = mmap(
                nil,
                length,
                PROT_READ,
                MAP_SHARED,
                descriptor.fileDescriptor,
                0
            )
            guard address != MAP_FAILED else {
                throw DoryVMDisplayWireError.invalidTransportAuthority
            }
            try? descriptor.close()
            guard let buffer = device.makeBuffer(
                bytesNoCopy: address!,
                length: length,
                options: .storageModeShared,
                deallocator: nil
            ) else {
                munmap(address, length)
                throw DoryVMDisplayWireError.invalidTransportAuthority
            }
            let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: Self.pixelFormat(lease.pixelFormat),
                width: Int(lease.width),
                height: Int(lease.height),
                mipmapped: false
            )
            textureDescriptor.storageMode = .shared
            textureDescriptor.usage = [.shaderRead]
            guard let texture = buffer.makeTexture(
                descriptor: textureDescriptor,
                offset: Int(lease.storageOffset),
                bytesPerRow: Int(lease.stride)
            ) else {
                munmap(address, length)
                throw DoryVMDisplayWireError.invalidTransportAuthority
            }
            return LinuxMachineImportedFrame(
                texture: texture,
                frame: frame,
                mappedAddress: address,
                mappedLength: length,
                buffer: buffer
            )
        }
    }

    private func render(_ imported: LinuxMachineImportedFrame) -> Bool {
        guard let metalLayer = layer as? CAMetalLayer,
              let drawable = metalLayer.nextDrawable(),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return false }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: 0.025, green: 0.03, blue: 0.04, alpha: 1
        )
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            return false
        }
        let leaseWidth = Float(imported.texture.width)
        let leaseHeight = Float(imported.texture.height)
        let source = imported.frame.sourceRect
        var uv = SIMD4<Float>(
            Float(source.x) / leaseWidth,
            Float(source.y) / leaseHeight,
            Float(source.x + source.width) / leaseWidth,
            Float(source.y + source.height) / leaseHeight
        )
        let yOriginTop: Bool
        switch imported.frame.transport {
        case .sharedMemory:
            yOriginTop = (try? DoryRendererScanoutLeaseCodec.decode(
                imported.frame.leasePayload
            ).yOriginTop) ?? true
        case .sharedTexture:
            yOriginTop = (try? DoryRendererSharedTextureScanoutLeaseCodec.decode(
                imported.frame.leasePayload
            ).yOriginTop) ?? true
        }
        if !yOriginTop {
            let top = uv.y
            uv.y = uv.w
            uv.w = top
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&uv, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.setFragmentTexture(imported.texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
        commandBuffer.addCompletedHandler { [imported, failureTarget = self] buffer in
            guard buffer.status != .completed else { return }
            let detail = buffer.error?.localizedDescription
                ?? "Metal presentation failed with status \(buffer.status.rawValue)"
            Task { @MainActor in failureTarget.showFailure(detail) }
            _ = imported
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
        return true
    }

    private func showFailure(_ message: String) {
        guard lastFailure != message else { return }
        lastFailure = message
        toolTip = message
    }

    private func presentCursor(_ cursor: DoryVMDisplayCursor?) {
        guestCursorUpdate = cursor
        rebuildGuestCursor()
    }

    private func rebuildGuestCursor() {
        guard let cursor = guestCursorUpdate else {
            guestCursor = Self.transparentCursor
            window?.invalidateCursorRects(for: self)
            return
        }
        let scale = bounds.width > 0 && scanoutSize.width > 0
            ? max(1, scanoutSize.width / bounds.width)
            : max(1, window?.backingScaleFactor ?? 1)
        guestCursor = Self.makeCursor(cursor, scale: scale) ?? Self.transparentCursor
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: guestCursor)
    }

    override func keyDown(with event: NSEvent) {
        guard let code = Self.keyMap[event.keyCode] else {
            super.keyDown(with: event)
            return
        }
        sendKeyboard([
            DoryVMDisplayInputEvent(
                type: 1,
                code: code,
                value: event.isARepeat ? 2 : 1
            )
        ])
    }

    override func keyUp(with event: NSEvent) {
        guard let code = Self.keyMap[event.keyCode] else {
            super.keyUp(with: event)
            return
        }
        sendKeyboard([DoryVMDisplayInputEvent(type: 1, code: code, value: 0)])
    }

    override func flagsChanged(with event: NSEvent) {
        switch pointerCaptureState.modifierTransition(
            command: event.modifierFlags.contains(.command),
            control: event.modifierFlags.contains(.control)
        ) {
        case .release:
            releaseTrackedInput()
            restoreHostPointerAfterCapture()
            return
        case .consume:
            return
        case .forward:
            break
        }
        guard let code = Self.keyMap[event.keyCode],
              let flag = Self.modifierFlag(for: event.keyCode) else {
            super.flagsChanged(with: event)
            return
        }
        sendKeyboard([.init(
            type: 1,
            code: code,
            value: event.modifierFlags.contains(flag) ? 1 : 0
        )])
    }

    override func mouseMoved(with event: NSEvent) { sendPointer(event) }
    override func mouseDragged(with event: NSEvent) { sendPointer(event) }
    override func rightMouseDragged(with event: NSEvent) { sendPointer(event) }
    override func otherMouseDragged(with event: NSEvent) { sendPointer(event) }
    override func mouseDown(with event: NSEvent) { sendPointer(event, button: 272, pressed: true) }
    override func mouseUp(with event: NSEvent) { sendPointer(event, button: 272, pressed: false) }
    override func rightMouseDown(with event: NSEvent) { sendPointer(event, button: 273, pressed: true) }
    override func rightMouseUp(with event: NSEvent) { sendPointer(event, button: 273, pressed: false) }
    override func otherMouseDown(with event: NSEvent) {
        sendPointer(event, button: Self.otherButton(event.buttonNumber), pressed: true)
    }
    override func otherMouseUp(with event: NSEvent) {
        sendPointer(event, button: Self.otherButton(event.buttonNumber), pressed: false)
    }

    private func sendPointer(_ event: NSEvent, button: UInt16? = nil, pressed: Bool = false) {
        window?.makeFirstResponder(self)
        if button != nil, !pointerCaptureState.isCaptured { enterPointerCapture() }
        if pointerCaptureState.isCaptured {
            var events: [DoryVMDisplayInputEvent] = []
            let x = Self.relativeDelta(event.deltaX)
            let y = Self.relativeDelta(-event.deltaY)
            if x != 0 { events.append(.init(type: 2, code: 0, value: x)) }
            if y != 0 { events.append(.init(type: 2, code: 1, value: y)) }
            if let button {
                events.append(.init(type: 1, code: button, value: pressed ? 1 : 0))
            }
            if !events.isEmpty { sendPointer(events, endpoint: .relativePointer) }
            return
        }
        guard pointerCaptureState.acceptsAbsoluteInput else { return }
        let point = convert(event.locationInWindow, from: nil)
        let x = Int32((min(1, max(0, point.x / max(1, bounds.width))) * 32_767).rounded())
        let y = Int32((min(1, max(0, point.y / max(1, bounds.height))) * 32_767).rounded())
        var events = [
            DoryVMDisplayInputEvent(type: 3, code: 0, value: x),
            DoryVMDisplayInputEvent(type: 3, code: 1, value: y),
        ]
        if let button {
            events.append(DoryVMDisplayInputEvent(
                type: 1,
                code: button,
                value: pressed ? 1 : 0
            ))
        }
        sendPointer(events, endpoint: .absolutePointer)
    }

    override func scrollWheel(with event: NSEvent) {
        let vertical = Int32(event.scrollingDeltaY.rounded())
        let horizontal = Int32(event.scrollingDeltaX.rounded())
        var events: [DoryVMDisplayInputEvent] = []
        if vertical != 0 {
            events.append(.init(type: 2, code: 8, value: vertical))
        }
        if horizontal != 0 {
            events.append(.init(type: 2, code: 6, value: horizontal))
        }
        if !events.isEmpty {
            sendPointer(
                events,
                endpoint: pointerCaptureState.isCaptured ? .relativePointer : .absolutePointer
            )
        }
    }

    private func sendKeyboard(_ events: [DoryVMDisplayInputEvent]) {
        for event in events where event.type == 1 {
            if event.value == 0 {
                pressedKeyboardCodes.remove(event.code)
            } else {
                pressedKeyboardCodes.insert(event.code)
            }
        }
        client.sendInput(endpoint: .keyboard, events: events)
    }

    private func sendPointer(
        _ events: [DoryVMDisplayInputEvent],
        endpoint: DoryVMDisplayInputEndpoint
    ) {
        for event in events where event.type == 1 {
            if event.value == 0 {
                if endpoint == .relativePointer {
                    pressedRelativeButtons.remove(event.code)
                } else {
                    pressedAbsoluteButtons.remove(event.code)
                }
            } else if endpoint == .relativePointer {
                pressedRelativeButtons.insert(event.code)
            } else {
                pressedAbsoluteButtons.insert(event.code)
            }
        }
        client.sendInput(endpoint: endpoint, events: events)
    }

    private func releasePressedInput() {
        if pointerCaptureState.cancel() { restoreHostPointerAfterCapture() }
        releaseTrackedInput()
    }

    private func releaseTrackedInput() {
        let keys = pressedKeyboardCodes.sorted()
        let absoluteButtons = pressedAbsoluteButtons.sorted()
        let relativeButtons = pressedRelativeButtons.sorted()
        pressedKeyboardCodes.removeAll()
        pressedAbsoluteButtons.removeAll()
        pressedRelativeButtons.removeAll()
        if !keys.isEmpty {
            client.sendInput(
                endpoint: .keyboard,
                events: keys.map { .init(type: 1, code: $0, value: 0) }
            )
        }
        if !absoluteButtons.isEmpty {
            client.sendInput(
                endpoint: .absolutePointer,
                events: absoluteButtons.map { .init(type: 1, code: $0, value: 0) }
            )
        }
        if !relativeButtons.isEmpty {
            client.sendInput(
                endpoint: .relativePointer,
                events: relativeButtons.map { .init(type: 1, code: $0, value: 0) }
            )
        }
    }

    private func enterPointerCapture() {
        guard !pointerCaptureState.isCaptured,
              CGAssociateMouseAndMouseCursorPosition(0) == .success else { return }
        guard pointerCaptureState.capture() else {
            _ = CGAssociateMouseAndMouseCursorPosition(1)
            return
        }
        NSCursor.hide()
        hostCursorHidden = true
    }

    private func restoreHostPointerAfterCapture() {
        _ = CGAssociateMouseAndMouseCursorPosition(1)
        if hostCursorHidden {
            NSCursor.unhide()
            hostCursorHidden = false
        }
    }

    private static func relativeDelta(_ value: Double) -> Int32 {
        guard value.isFinite else { return 0 }
        if value >= Double(Int32.max) { return .max }
        if value <= Double(Int32.min) { return .min }
        return Int32(value.rounded())
    }

    private static func otherButton(_ buttonNumber: Int) -> UInt16 {
        switch buttonNumber {
        case 2: 274
        case 3: 275
        default: 276
        }
    }

    private static func modifierFlag(for keyCode: UInt16) -> NSEvent.ModifierFlags? {
        switch keyCode {
        case 54, 55: .command
        case 56, 60: .shift
        case 57: .capsLock
        case 58, 61: .option
        case 59, 62: .control
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
        _ update: DoryVMDisplayCursor,
        scale: CGFloat
    ) -> NSCursor? {
        guard update.visible,
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
              ) else { return nil }
        let imageSize = NSSize(
            width: CGFloat(update.width) / scale,
            height: CGFloat(update.height) / scale
        )
        return NSCursor(
            image: NSImage(cgImage: image, size: imageSize),
            hotSpot: NSPoint(
                x: CGFloat(update.hotX) / scale,
                y: CGFloat(update.hotY) / scale
            )
        )
    }

    private static func pixelFormat(
        _ format: DoryRendererScanoutPixelFormat
    ) -> MTLPixelFormat {
        switch format {
        case .bgra8Unorm: .bgra8Unorm
        case .rgba8Unorm: .rgba8Unorm
        }
    }

    private static let keyMap: [UInt16: UInt16] = [
        0: 30, 1: 31, 2: 32, 3: 33, 4: 35, 5: 34, 6: 44, 7: 45,
        8: 46, 9: 47, 11: 48, 12: 16, 13: 17, 14: 18, 15: 19, 16: 21,
        17: 20, 18: 2, 19: 3, 20: 4, 21: 5, 22: 7, 23: 6, 24: 13,
        25: 10, 26: 8, 27: 12, 28: 9, 29: 11, 30: 27, 31: 24, 32: 22,
        33: 26, 34: 23, 35: 25, 36: 28, 37: 38, 38: 36, 39: 40, 40: 37,
        41: 39, 42: 43, 43: 51, 44: 53, 45: 49, 46: 50, 47: 52, 48: 15,
        49: 57, 50: 41, 51: 14, 53: 1, 54: 126, 55: 125, 56: 42, 57: 58,
        58: 56, 59: 29, 60: 54, 61: 100, 62: 97, 65: 83, 67: 55, 69: 78,
        71: 69, 75: 98, 76: 96, 78: 74, 81: 117, 82: 82, 83: 79, 84: 80,
        85: 81, 86: 75, 87: 76, 88: 77, 89: 71, 91: 72, 92: 73,
        96: 63, 97: 64, 98: 65, 99: 61, 100: 66, 101: 67, 103: 87,
        109: 68, 111: 88, 114: 110, 115: 102, 116: 104, 117: 111,
        118: 62, 119: 107, 120: 60, 121: 109, 122: 59, 123: 105,
        124: 106, 125: 108, 126: 103,
    ]

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct DoryLinuxDisplayVertexOutput {
        float4 position [[position]];
        float2 textureCoordinate;
    };
    vertex DoryLinuxDisplayVertexOutput doryLinuxDisplayVertex(
        uint vertexID [[vertex_id]], constant float4 &sourceUV [[buffer(0)]]) {
        const float2 positions[6] = {
            float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0),
            float2(-1.0, 1.0), float2(1.0, -1.0), float2(1.0, 1.0)
        };
        const float2 coordinates[6] = {
            float2(0.0, 0.0), float2(1.0, 0.0), float2(0.0, 1.0),
            float2(0.0, 1.0), float2(1.0, 0.0), float2(1.0, 1.0)
        };
        DoryLinuxDisplayVertexOutput output;
        output.position = float4(positions[vertexID], 0.0, 1.0);
        const float2 unit = coordinates[vertexID];
        output.textureCoordinate = float2(
            mix(sourceUV.x, sourceUV.z, unit.x),
            mix(sourceUV.y, sourceUV.w, unit.y));
        return output;
    }
    fragment half4 doryLinuxDisplayFragment(
        DoryLinuxDisplayVertexOutput input [[stage_in]],
        texture2d<half> source [[texture(0)]],
        sampler sourceSampler [[sampler(0)]]) {
        return source.sample(sourceSampler, input.textureCoordinate);
    }
    """
}
