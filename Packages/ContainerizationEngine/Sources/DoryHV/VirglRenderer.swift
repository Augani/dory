import Darwin
import Foundation

public final class VirglRenderer: VirtioGPURenderer, @unchecked Sendable {
    public let libraryPath: String
    public let moltenVKICDPath: String
    public let capsets: [VirtioGPUCapset]

    private let handle: UnsafeMutableRawPointer
    private let callbacks: UnsafeMutablePointer<VirglRendererCallbacks>
    private let functions: Functions

    // Fence completions arrive on virglrenderer's internal threads (ASYNC_FENCE_CB); the C
    // callbacks have no per-instance cookie routing here, so a single active renderer is registered
    // globally (one renderer per engine process) and forwards into the device's sink.
    private static let fenceLock = NSLock()
    nonisolated(unsafe) private static weak var activeRenderer: VirglRenderer?
    nonisolated(unsafe) private var fenceSink: ((UInt32, UInt32, UInt64) -> Void)?

    public var onFenceSignaled: ((UInt32, UInt32, UInt64) -> Void)? {
        get { Self.fenceLock.lock(); defer { Self.fenceLock.unlock() }; return fenceSink }
        set { Self.fenceLock.lock(); fenceSink = newValue; Self.fenceLock.unlock() }
    }

    fileprivate static func signalFence(contextID: UInt32, ringIndex: UInt32, fenceID: UInt64) {
        fenceLock.lock()
        let sink = activeRenderer?.fenceSink
        fenceLock.unlock()
        sink?(contextID, ringIndex, fenceID)
    }

    public static func discover(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> VirglRenderer {
        guard let libraryPath = firstExistingPath(candidates: virglRendererCandidates(environment: environment)) else {
            throw VMError.invalidConfiguration(
                "gpu=venus requires libvirglrenderer.dylib; set DORY_VIRGLRENDERER_PATH or bundle it in Contents/Frameworks"
            )
        }
        guard let moltenVKICD = firstExistingPath(candidates: moltenVKICDCandidates(environment: environment)) else {
            throw VMError.invalidConfiguration(
                "gpu=venus requires MoltenVK_icd.json; set DORY_MOLTENVK_ICD or bundle it in Contents/Resources/vulkan/icd.d"
            )
        }
        return try VirglRenderer(libraryPath: libraryPath, moltenVKICDPath: moltenVKICD)
    }

    public init(libraryPath: String, moltenVKICDPath: String) throws {
        guard FileManager.default.fileExists(atPath: libraryPath) else {
            throw VMError.invalidConfiguration("virglrenderer library not found: \(libraryPath)")
        }
        guard FileManager.default.fileExists(atPath: moltenVKICDPath) else {
            throw VMError.invalidConfiguration("MoltenVK ICD not found: \(moltenVKICDPath)")
        }
        guard let handle = dlopen(libraryPath, RTLD_NOW | RTLD_LOCAL) else {
            let message = dlerror().map { String(cString: $0) } ?? "unknown dlopen failure"
            throw VMError.invalidConfiguration("cannot load virglrenderer at \(libraryPath): \(message)")
        }

        do {
            let functions = try Functions(handle: handle)
            guard functions.resourceMap != nil || functions.resourceGetMapPtr != nil else {
                throw VMError.invalidConfiguration(
                    "libvirglrenderer at \(libraryPath) exports neither virgl_renderer_resource_map nor virgl_renderer_resource_get_map_ptr; Dory's Venus path needs one to expose host-visible blobs to the guest"
                )
            }

            setenv("VK_ICD_FILENAMES", moltenVKICDPath, 1)

            if let sym = dlsym(handle, "virgl_set_log_callback") {
                typealias SetLogCallback = @convention(c) (
                    (@convention(c) (Int32, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void)?,
                    UnsafeMutableRawPointer?,
                    UnsafeMutableRawPointer?
                ) -> Void
                unsafeBitCast(sym, to: SetLogCallback.self)(doryVirglLog, nil, nil)
            }

            let callbacks = UnsafeMutablePointer<VirglRendererCallbacks>.allocate(capacity: 1)
            callbacks.initialize(to: VirglRendererCallbacks(
                version: 4,
                writeFence: doryVirglWriteFence,
                createGLContext: nil,
                destroyGLContext: nil,
                makeCurrent: nil,
                getDRMFD: nil,
                writeContextFence: doryVirglWriteContextFence,
                getServerFD: nil,
                getEGLDisplay: nil
            ))

            // Host-allocated HOST3D blobs (the zero-copy map model libkrun uses): do NOT set
            // USE_GUEST_VRAM, which would make virglrenderer choose guest-backed storage that returns
            // no mappable host pointer. ASYNC_FENCE_CB delivers fence completions from the renderer's
            // own threads, so no poll loop is needed for real fence signalling.
            let flags = RendererFlags.venus | RendererFlags.noVirgl | RendererFlags.asyncFenceCB
            let initStatus = functions.initialize(nil, flags, UnsafeMutableRawPointer(callbacks))
            guard initStatus == 0 else {
                callbacks.deinitialize(count: 1)
                callbacks.deallocate()
                throw VMError.invalidConfiguration("virgl_renderer_init(Venus) failed with status \(initStatus)")
            }

            var maxVersion: UInt32 = 0
            var maxSize: UInt32 = 0
            functions.getCapSet(VirtioGPUCapsetID.venus, &maxVersion, &maxSize)
            // Venus reports maxVersion == 0 (it negotiates its protocol via the capset data, not the
            // capset version number, unlike virgl). Gate on maxSize only.
            guard maxSize > 0 else {
                functions.cleanup(nil)
                callbacks.deinitialize(count: 1)
                callbacks.deallocate()
                throw VMError.invalidConfiguration("virglrenderer did not report a Venus capset")
            }

            var capsetData = [UInt8](repeating: 0, count: Int(maxSize))
            capsetData.withUnsafeMutableBytes { buffer in
                functions.fillCaps(VirtioGPUCapsetID.venus, maxVersion, buffer.baseAddress)
            }

            self.libraryPath = libraryPath
            self.moltenVKICDPath = moltenVKICDPath
            self.capsets = [VirtioGPUCapset(id: VirtioGPUCapsetID.venus, maxVersion: maxVersion, data: capsetData)]
            self.handle = handle
            self.callbacks = callbacks
            self.functions = functions
            Self.fenceLock.lock()
            Self.activeRenderer = self
            Self.fenceLock.unlock()
        } catch {
            dlclose(handle)
            throw error
        }
    }

    deinit {
        Self.fenceLock.lock()
        if Self.activeRenderer === self { Self.activeRenderer = nil }
        Self.fenceLock.unlock()
        functions.cleanup(nil)
        callbacks.deinitialize(count: 1)
        callbacks.deallocate()
        dlclose(handle)
    }

    /// Registers a host fence so virglrenderer signals it (via the async callbacks) once all GPU
    /// work submitted before it has completed. Context fences carry Venus's per-ring ordering;
    /// plain fences ride the global ctx0 timeline.
    public func createFence(contextID: UInt32, ringIndex: UInt32, fenceID: UInt64, contextFence: Bool) throws {
        if contextFence, let contextCreateFence = functions.contextCreateFence {
            try check(
                contextCreateFence(contextID, 0, ringIndex, fenceID),
                "virgl_renderer_context_create_fence"
            )
            return
        }
        try check(
            functions.createFence(Int32(truncatingIfNeeded: fenceID), contextID),
            "virgl_renderer_create_fence"
        )
    }

    public func createContext(id: UInt32, flags: UInt32, name: String) throws {
        let status = name.withCString { pointer in
            functions.contextCreateWithFlags(id, flags, UInt32(name.utf8.count), pointer)
        }
        try check(status, "virgl_renderer_context_create_with_flags")
    }

    public func destroyContext(id: UInt32) throws {
        functions.contextDestroy(id)
    }

    public func attachResource(contextID: UInt32, resourceID: UInt32) throws {
        functions.contextAttachResource(Int32(bitPattern: contextID), Int32(bitPattern: resourceID))
    }

    public func detachResource(contextID: UInt32, resourceID: UInt32) throws {
        functions.contextDetachResource(Int32(bitPattern: contextID), Int32(bitPattern: resourceID))
    }

    public func submit3D(contextID: UInt32, command: [UInt8]) throws {
        var command = command
        while command.count % 4 != 0 { command.append(0) }
        let dwordCount = Int32(command.count / 4)
        let status = command.withUnsafeMutableBytes { buffer in
            functions.submitCommand(buffer.baseAddress, Int32(bitPattern: contextID), dwordCount)
        }
        try check(status, "virgl_renderer_submit_cmd")
    }

    public func createResource3D(_ resource: VirtioGPUResourceCreate3D, entries: [VirtioGPUMemoryEntry]) throws {
        var args = VirglRendererResourceCreateArgs(
            handle: resource.resourceID,
            target: resource.target,
            format: resource.format,
            bind: resource.bind,
            width: resource.width,
            height: resource.height,
            depth: resource.depth,
            arraySize: resource.arraySize,
            lastLevel: resource.lastLevel,
            samples: resource.samples,
            flags: resource.flags
        )
        let status = try withIOVecs(entries) { pointer, count in
            withUnsafeMutablePointer(to: &args) { argsPointer in
                functions.resourceCreate(UnsafeMutableRawPointer(argsPointer), pointer, count)
            }
        }
        try check(status, "virgl_renderer_resource_create")
    }

    public func createBlob(
        resourceID: UInt32,
        contextID: UInt32,
        blobMemory: UInt32,
        blobFlags: UInt32,
        blobID: UInt64,
        size: UInt64,
        entries: [VirtioGPUMemoryEntry]
    ) throws {
        var args = VirglRendererResourceCreateBlobArgs(
            resourceHandle: resourceID,
            contextID: contextID,
            blobMemory: blobMemory,
            blobFlags: blobFlags,
            blobID: blobID,
            size: size,
            iovecs: nil,
            iovecCount: 0
        )
        let status = try withIOVecs(entries) { pointer, count in
            args.iovecs = pointer
            args.iovecCount = count
            return withUnsafePointer(to: &args) { argsPointer in
                functions.resourceCreateBlob(UnsafeRawPointer(argsPointer))
            }
        }
        try check(status, "virgl_renderer_resource_create_blob")
    }

    public func attachBacking(resourceID: UInt32, entries: [VirtioGPUMemoryEntry]) throws {
        let status = try withIOVecs(entries) { pointer, count in
            functions.resourceAttachIOV(Int32(bitPattern: resourceID), pointer, Int32(count))
        }
        try check(status, "virgl_renderer_resource_attach_iov")
    }

    public func detachBacking(resourceID: UInt32) throws {
        var detached: UnsafeMutablePointer<iovec>?
        var count: Int32 = 0
        functions.resourceDetachIOV(Int32(bitPattern: resourceID), &detached, &count)
    }

    public func unrefResource(resourceID: UInt32) throws {
        functions.resourceUnref(resourceID)
    }

    public func mapBlob(resourceID: UInt32) throws -> VirtioGPUBlobMapping {
        var pointer: UnsafeMutableRawPointer?
        var size: UInt64 = 0
        // On macOS the blob is MoltenVK-backed (Apple handle); virgl_renderer_resource_map returns
        // -EINVAL for it by design. get_map_ptr returns the vkMapMemory host VA to hv_vm_map into the
        // guest — the exact path libkrun/krunkit use. Fall back to resource_map only if absent.
        if let getPtr = functions.resourceGetMapPtr {
            var address: UInt64 = 0
            try check(getPtr(resourceID, &address), "virgl_renderer_resource_get_map_ptr")
            pointer = UnsafeMutableRawPointer(bitPattern: UInt(address))
        } else if let map = functions.resourceMap {
            try check(map(resourceID, &pointer, &size), "virgl_renderer_resource_map")
        } else {
            throw VMError.invalidConfiguration("virglrenderer has no blob map entrypoint")
        }
        guard let hostPointer = pointer else {
            throw VMError.invalidConfiguration("virglrenderer returned a null host pointer for blob resource \(resourceID)")
        }
        var mapInfo: UInt32 = 0
        try check(functions.resourceGetMapInfo(resourceID, &mapInfo), "virgl_renderer_resource_get_map_info")
        return VirtioGPUBlobMapping(hostPointer: hostPointer, size: size, mapInfo: mapInfo & 0x0f)
    }

    public func unmapBlob(resourceID: UInt32) throws {
        try check(functions.resourceUnmap(resourceID), "virgl_renderer_resource_unmap")
    }

    public func transferToHost3D(_ transfer: VirtioGPUTransfer3D, entries: [VirtioGPUMemoryEntry]) throws {
        var box = VirglBox(values: transfer.box)
        let status = try withIOVecs(entries) { pointer, count in
            withUnsafePointer(to: &box) { boxPointer in
                functions.transferWriteIOV(
                    transfer.resourceID,
                    transfer.contextID,
                    Int32(bitPattern: transfer.level),
                    transfer.stride,
                    transfer.layerStride,
                    UnsafeRawPointer(boxPointer),
                    transfer.offset,
                    pointer,
                    count
                )
            }
        }
        try check(status, "virgl_renderer_transfer_write_iov")
    }

    public func transferFromHost3D(_ transfer: VirtioGPUTransfer3D, entries: [VirtioGPUMemoryEntry]) throws {
        var box = VirglBox(values: transfer.box)
        let status = try withIOVecs(entries) { pointer, count in
            withUnsafePointer(to: &box) { boxPointer in
                functions.transferReadIOV(
                    transfer.resourceID,
                    transfer.contextID,
                    transfer.level,
                    transfer.stride,
                    transfer.layerStride,
                    UnsafeRawPointer(boxPointer),
                    transfer.offset,
                    pointer,
                    Int32(count)
                )
            }
        }
        try check(status, "virgl_renderer_transfer_read_iov")
    }

    private func withIOVecs<T>(
        _ entries: [VirtioGPUMemoryEntry],
        _ body: (UnsafePointer<iovec>?, UInt32) throws -> T
    ) throws -> T {
        let iovecs = entries.map { iovec(iov_base: $0.pointer, iov_len: $0.length) }
        if iovecs.isEmpty {
            return try body(nil, 0)
        }
        return try iovecs.withUnsafeBufferPointer { buffer in
            try body(buffer.baseAddress, UInt32(buffer.count))
        }
    }

    private func check(_ status: Int32, _ operation: String) throws {
        guard status == 0 else {
            throw VMError.invalidConfiguration("\(operation) failed with status \(status)")
        }
    }

    private static func virglRendererCandidates(environment: [String: String]) -> [String] {
        var candidates = [
            environment["DORY_VIRGLRENDERER_PATH"],
            environment["DORY_VIRGLRENDERER"],
            Bundle.main.privateFrameworksPath.map { "\($0)/libvirglrenderer.dylib" },
            Bundle.main.resourcePath.map { "\($0)/libvirglrenderer.dylib" },
        ].compactMap { $0?.isEmpty == false ? $0 : nil }
        if let executable = CommandLine.arguments.first {
            let directory = URL(fileURLWithPath: executable).deletingLastPathComponent().path
            candidates.append("\(directory)/../Frameworks/libvirglrenderer.dylib")
            candidates.append("\(directory)/libvirglrenderer.dylib")
        }
        candidates.append(contentsOf: [
            "/opt/homebrew/lib/libvirglrenderer.dylib",
            "/usr/local/lib/libvirglrenderer.dylib",
        ])
        return candidates
    }

    private static func moltenVKICDCandidates(environment: [String: String]) -> [String] {
        var candidates = [String]()
        if let override = environment["DORY_MOLTENVK_ICD"], !override.isEmpty {
            candidates.append(override)
        }
        if let existing = environment["VK_ICD_FILENAMES"], !existing.isEmpty {
            candidates.append(contentsOf: existing.split(separator: ":").map(String.init))
        }
        if let executable = CommandLine.arguments.first {
            let directory = URL(fileURLWithPath: executable).deletingLastPathComponent().path
            candidates.append("\(directory)/../Resources/vulkan/icd.d/MoltenVK_icd.json")
            candidates.append("\(directory)/../Resources/MoltenVK_icd.json")
        }
        candidates.append(contentsOf: [
            Bundle.main.resourcePath.map { "\($0)/vulkan/icd.d/MoltenVK_icd.json" },
            Bundle.main.resourcePath.map { "\($0)/MoltenVK_icd.json" },
            "/opt/homebrew/etc/vulkan/icd.d/MoltenVK_icd.json",
            "/opt/homebrew/share/vulkan/icd.d/MoltenVK_icd.json",
            "/usr/local/etc/vulkan/icd.d/MoltenVK_icd.json",
            "/usr/local/share/vulkan/icd.d/MoltenVK_icd.json",
        ].compactMap { $0 })
        return candidates
    }

    private static func firstExistingPath(candidates: [String]) -> String? {
        candidates.first { FileManager.default.fileExists(atPath: URL(fileURLWithPath: $0).standardizedFileURL.path) }
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
    }
}

private enum RendererFlags {
    static let venus: Int32 = 1 << 6
    static let noVirgl: Int32 = 1 << 7
    static let asyncFenceCB: Int32 = 1 << 8
    static let useGuestVRAM: Int32 = 1 << 14
}

private enum VirtioGPUCapsetID {
    static let venus: UInt32 = 4
}

private typealias WriteFenceCallback = @convention(c) (UnsafeMutableRawPointer?, UInt32) -> Void
private typealias WriteContextFenceCallback = @convention(c) (UnsafeMutableRawPointer?, UInt32, UInt32, UInt64) -> Void
private typealias CreateGLContextCallback = @convention(c) (
    UnsafeMutableRawPointer?,
    Int32,
    UnsafeMutableRawPointer?
) -> UnsafeMutableRawPointer?
private typealias DestroyGLContextCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
private typealias MakeCurrentCallback = @convention(c) (UnsafeMutableRawPointer?, Int32, UnsafeMutableRawPointer?) -> Int32
private typealias GetDRMFDCallback = @convention(c) (UnsafeMutableRawPointer?) -> Int32
private typealias GetServerFDCallback = @convention(c) (UnsafeMutableRawPointer?, UInt32) -> Int32
private typealias GetEGLDisplayCallback = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?

private let doryVirglLog: @convention(c) (Int32, UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void = { level, message, _ in
    let text = message.map { String(cString: $0) } ?? ""
    FileHandle.standardError.write(Data("virgl[\(level)]: \(text)\n".utf8))
}

// ctx0 fences ride the global timeline: write_fence has no context/ring, so they complete under
// (context 0, ring 0). Context fences carry their real coordinates.
private let doryVirglWriteFence: WriteFenceCallback = { _, fence in
    VirglRenderer.signalFence(contextID: 0, ringIndex: 0, fenceID: UInt64(fence))
}
private let doryVirglWriteContextFence: WriteContextFenceCallback = { _, contextID, ringIndex, fenceID in
    VirglRenderer.signalFence(contextID: contextID, ringIndex: ringIndex, fenceID: fenceID)
}

private struct VirglRendererCallbacks {
    var version: Int32
    var writeFence: WriteFenceCallback?
    var createGLContext: CreateGLContextCallback?
    var destroyGLContext: DestroyGLContextCallback?
    var makeCurrent: MakeCurrentCallback?
    var getDRMFD: GetDRMFDCallback?
    var writeContextFence: WriteContextFenceCallback?
    var getServerFD: GetServerFDCallback?
    var getEGLDisplay: GetEGLDisplayCallback?
}

private struct VirglRendererResourceCreateArgs {
    var handle: UInt32
    var target: UInt32
    var format: UInt32
    var bind: UInt32
    var width: UInt32
    var height: UInt32
    var depth: UInt32
    var arraySize: UInt32
    var lastLevel: UInt32
    var samples: UInt32
    var flags: UInt32
}

private struct VirglRendererResourceCreateBlobArgs {
    var resourceHandle: UInt32
    var contextID: UInt32
    var blobMemory: UInt32
    var blobFlags: UInt32
    var blobID: UInt64
    var size: UInt64
    var iovecs: UnsafePointer<iovec>?
    var iovecCount: UInt32
}

private struct VirglBox {
    var x: UInt32
    var y: UInt32
    var z: UInt32
    var width: UInt32
    var height: UInt32
    var depth: UInt32

    init(values: [UInt32]) {
        let padded = values + Array(repeating: 0, count: max(0, 6 - values.count))
        x = padded[0]
        y = padded[1]
        z = padded[2]
        width = padded[3]
        height = padded[4]
        depth = padded[5]
    }
}

private struct Functions {
    typealias Initialize = @convention(c) (UnsafeMutableRawPointer?, Int32, UnsafeMutableRawPointer?) -> Int32
    typealias Cleanup = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias GetCapSet = @convention(c) (UInt32, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?) -> Void
    typealias FillCaps = @convention(c) (UInt32, UInt32, UnsafeMutableRawPointer?) -> Void
    typealias ContextCreateWithFlags = @convention(c) (UInt32, UInt32, UInt32, UnsafePointer<CChar>?) -> Int32
    typealias ContextDestroy = @convention(c) (UInt32) -> Void
    typealias ContextResource = @convention(c) (Int32, Int32) -> Void
    typealias SubmitCommand = @convention(c) (UnsafeMutableRawPointer?, Int32, Int32) -> Int32
    typealias ResourceCreate = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<iovec>?, UInt32) -> Int32
    typealias ResourceCreateBlob = @convention(c) (UnsafeRawPointer?) -> Int32
    typealias ResourceAttachIOV = @convention(c) (Int32, UnsafePointer<iovec>?, Int32) -> Int32
    typealias ResourceDetachIOV = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<iovec>?>?, UnsafeMutablePointer<Int32>?) -> Void
    typealias ResourceUnref = @convention(c) (UInt32) -> Void
    typealias ResourceMapFixed = @convention(c) (UInt32, UnsafeMutableRawPointer?) -> Int32
    typealias ResourceMap = @convention(c) (UInt32, UnsafeMutablePointer<UnsafeMutableRawPointer?>?, UnsafeMutablePointer<UInt64>?) -> Int32
    typealias ResourceGetMapPtr = @convention(c) (UInt32, UnsafeMutablePointer<UInt64>?) -> Int32
    typealias ResourceUnmap = @convention(c) (UInt32) -> Int32
    typealias ResourceGetMapInfo = @convention(c) (UInt32, UnsafeMutablePointer<UInt32>?) -> Int32
    typealias TransferWriteIOV = @convention(c) (
        UInt32,
        UInt32,
        Int32,
        UInt32,
        UInt32,
        UnsafeRawPointer?,
        UInt64,
        UnsafePointer<iovec>?,
        UInt32
    ) -> Int32
    typealias TransferReadIOV = @convention(c) (
        UInt32,
        UInt32,
        UInt32,
        UInt32,
        UInt32,
        UnsafeRawPointer?,
        UInt64,
        UnsafePointer<iovec>?,
        Int32
    ) -> Int32
    typealias CreateFence = @convention(c) (Int32, UInt32) -> Int32
    typealias ContextCreateFence = @convention(c) (UInt32, UInt32, UInt32, UInt64) -> Int32

    let initialize: Initialize
    let cleanup: Cleanup
    let getCapSet: GetCapSet
    let fillCaps: FillCaps
    let contextCreateWithFlags: ContextCreateWithFlags
    let contextDestroy: ContextDestroy
    let contextAttachResource: ContextResource
    let contextDetachResource: ContextResource
    let submitCommand: SubmitCommand
    let resourceCreate: ResourceCreate
    let resourceCreateBlob: ResourceCreateBlob
    let resourceAttachIOV: ResourceAttachIOV
    let resourceDetachIOV: ResourceDetachIOV
    let resourceUnref: ResourceUnref
    let resourceMapFixed: ResourceMapFixed?
    let resourceMap: ResourceMap?
    let resourceGetMapPtr: ResourceGetMapPtr?
    let resourceUnmap: ResourceUnmap
    let resourceGetMapInfo: ResourceGetMapInfo
    let transferWriteIOV: TransferWriteIOV
    let transferReadIOV: TransferReadIOV
    let createFence: CreateFence
    let contextCreateFence: ContextCreateFence?

    init(handle: UnsafeMutableRawPointer) throws {
        initialize = try Self.required(handle, "virgl_renderer_init")
        cleanup = try Self.required(handle, "virgl_renderer_cleanup")
        getCapSet = try Self.required(handle, "virgl_renderer_get_cap_set")
        fillCaps = try Self.required(handle, "virgl_renderer_fill_caps")
        contextCreateWithFlags = try Self.required(handle, "virgl_renderer_context_create_with_flags")
        contextDestroy = try Self.required(handle, "virgl_renderer_context_destroy")
        contextAttachResource = try Self.required(handle, "virgl_renderer_ctx_attach_resource")
        contextDetachResource = try Self.required(handle, "virgl_renderer_ctx_detach_resource")
        submitCommand = try Self.required(handle, "virgl_renderer_submit_cmd")
        resourceCreate = try Self.required(handle, "virgl_renderer_resource_create")
        resourceCreateBlob = try Self.required(handle, "virgl_renderer_resource_create_blob")
        resourceAttachIOV = try Self.required(handle, "virgl_renderer_resource_attach_iov")
        resourceDetachIOV = try Self.required(handle, "virgl_renderer_resource_detach_iov")
        resourceUnref = try Self.required(handle, "virgl_renderer_resource_unref")
        resourceMapFixed = Self.optional(handle, "virgl_renderer_resource_map_fixed")
        resourceMap = Self.optional(handle, "virgl_renderer_resource_map")
        resourceGetMapPtr = Self.optional(handle, "virgl_renderer_resource_get_map_ptr")
        resourceUnmap = try Self.required(handle, "virgl_renderer_resource_unmap")
        resourceGetMapInfo = try Self.required(handle, "virgl_renderer_resource_get_map_info")
        transferWriteIOV = try Self.required(handle, "virgl_renderer_transfer_write_iov")
        transferReadIOV = try Self.required(handle, "virgl_renderer_transfer_read_iov")
        createFence = try Self.required(handle, "virgl_renderer_create_fence")
        contextCreateFence = Self.optional(handle, "virgl_renderer_context_create_fence")
    }

    private static func required<T>(_ handle: UnsafeMutableRawPointer, _ name: String) throws -> T {
        guard let symbol = dlsym(handle, name) else {
            throw VMError.invalidConfiguration("libvirglrenderer missing required symbol \(name)")
        }
        return unsafeBitCast(symbol, to: T.self)
    }

    private static func optional<T>(_ handle: UnsafeMutableRawPointer, _ name: String) -> T? {
        guard let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: T.self)
    }
}
