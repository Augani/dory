import Darwin
import Foundation
import OpenGL
import OpenGL.GL3

public final class VirglRenderer: VirtioGPURenderer, @unchecked Sendable {
    public let libraryPath: String
    public let moltenVKICDPath: String?
    public let capsets: [VirtioGPUCapset]

    private let handle: UnsafeMutableRawPointer
    private let callbacks: UnsafeMutablePointer<VirglRendererCallbacks>
    private let glContextManager: VirglCGLContextManager
    private let functions: Functions
    private let submissionSyncMode: SubmissionSyncMode
    private let classicOnly: Bool
    private let rendererLock = NSRecursiveLock()
    private var pollSource: DispatchSourceRead?
    private var pollTimer: DispatchSourceTimer?
    // Each guest renderer context gets one rolling GL fence. Submissions only flush the producer
    // context; scanout readback waits for the latest fence from every producer in ctx0. This keeps
    // shared textures coherent without blocking the vCPU on glFinish after every command buffer.
    private var pendingSubmissionSyncs: [UInt32: GLsync] = [:]
    // Retain guest-provided labels so a renderer failure identifies Mutter, Firefox, or the Vulkan
    // client that supplied the command stream without relying on process IDs.
    private var contextLabels: [UInt32: String] = [:]
    // Fence creation in classic VirGL must happen in the producer's OpenGL context. Keep each
    // context's negotiated capset so Venus fences can stay on their native renderer timeline while
    // VirGL fences explicitly restore the producer context after Dory clears thread-local CGL state.
    private var contextFlags: [UInt32: UInt32] = [:]
    // virglrenderer retains the *iovec array pointer* supplied at resource creation/attach; it
    // does not copy those descriptors. Swift's temporary Array storage therefore cannot be used
    // for resource backing even though the guest-memory pointers inside each descriptor are
    // stable. Keep an owned C allocation alive for exactly as long as the renderer resource.
    private var resourceIOVecs: [UInt32: OwnedIOVecs] = [:]

    // The C callbacks have no per-instance cookie routing here, so a single active renderer is
    // registered globally (one renderer per engine process). A callback can run synchronously from
    // virgl_renderer_poll while rendererLock is held. Calling the virtio device from there would
    // invert rendererLock and the transport's queue lock: a vCPU creating the next fence holds the
    // queue lock while waiting for rendererLock, and the poll callback would hold rendererLock while
    // waiting for that queue lock. Buffer completions here and deliver them only after the renderer
    // API boundary releases rendererLock.
    private static let fenceLock = NSLock()
    nonisolated(unsafe) private static weak var activeRenderer: VirglRenderer?
    nonisolated(unsafe) private var fenceSink: ((UInt32, UInt32, UInt64) -> Void)?
    nonisolated(unsafe) private var pendingFenceSignals: [(contextID: UInt32, ringIndex: UInt32, fenceID: UInt64)] = []

    public var onFenceSignaled: ((UInt32, UInt32, UInt64) -> Void)? {
        get { Self.fenceLock.lock(); defer { Self.fenceLock.unlock() }; return fenceSink }
        set { Self.fenceLock.lock(); fenceSink = newValue; Self.fenceLock.unlock() }
    }

    fileprivate static func signalFence(contextID: UInt32, ringIndex: UInt32, fenceID: UInt64) {
        fenceLock.lock()
        activeRenderer?.pendingFenceSignals.append((contextID, ringIndex, fenceID))
        fenceLock.unlock()
    }

    public static func discover(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> VirglRenderer {
        let classicOnly = environment["DORY_VIRGL_CLASSIC_ONLY"] == "1"
        guard let libraryPath = firstExistingPath(candidates: virglRendererCandidates(environment: environment)) else {
            throw VMError.invalidConfiguration(
                "accelerated graphics require libvirglrenderer.dylib; set DORY_VIRGLRENDERER_PATH or bundle it in Contents/Frameworks"
            )
        }
        let moltenVKICD = firstExistingPath(candidates: moltenVKICDCandidates(environment: environment))
        guard classicOnly || moltenVKICD != nil else {
            throw VMError.invalidConfiguration(
                "VirGL + Venus graphics require MoltenVK_icd.json; set DORY_MOLTENVK_ICD or bundle it in Contents/Resources/vulkan/icd.d"
            )
        }
        return try VirglRenderer(
            libraryPath: libraryPath,
            moltenVKICDPath: moltenVKICD,
            environment: environment
        )
    }

    public init(
        libraryPath: String,
        moltenVKICDPath: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        let classicOnly = environment["DORY_VIRGL_CLASSIC_ONLY"] == "1"
        guard FileManager.default.fileExists(atPath: libraryPath) else {
            throw VMError.invalidConfiguration("virglrenderer library not found: \(libraryPath)")
        }
        if !classicOnly {
            guard let moltenVKICDPath,
                  FileManager.default.fileExists(atPath: moltenVKICDPath) else {
                throw VMError.invalidConfiguration("VirGL + Venus graphics require a valid MoltenVK ICD")
            }
        }
        guard let handle = dlopen(libraryPath, RTLD_NOW | RTLD_LOCAL) else {
            let message = dlerror().map { String(cString: $0) } ?? "unknown dlopen failure"
            throw VMError.invalidConfiguration("cannot load virglrenderer at \(libraryPath): \(message)")
        }

        do {
            let functions = try Functions(handle: handle)
            let glContextManager = try VirglCGLContextManager()
            if !classicOnly,
               dlsym(handle, "dory_virglrenderer_macos_venus_fence_fix") == nil {
                throw VMError.invalidConfiguration(
                    "libvirglrenderer at \(libraryPath) is missing Dory's macOS Venus fence fix; rebuild or install the pinned Dory renderer"
                )
            }
            if !classicOnly,
               dlsym(handle, "dory_moltenvk_spirv_native_array_fix") == nil {
                throw VMError.invalidConfiguration(
                    "libvirglrenderer at \(libraryPath) is not linked to Dory's patched MoltenVK runtime; the ICD path alone cannot replace a directly linked MoltenVK dylib"
                )
            }
            guard functions.resourceMap != nil || functions.resourceGetMapPtr != nil else {
                throw VMError.invalidConfiguration(
                    "libvirglrenderer at \(libraryPath) exports neither virgl_renderer_resource_map nor virgl_renderer_resource_get_map_ptr; Dory's Venus path needs one to expose host-visible blobs to the guest"
                )
            }

            if let moltenVKICDPath {
                setenv("VK_ICD_FILENAMES", moltenVKICDPath, 1)
            }

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
                createGLContext: doryVirglCreateGLContext,
                destroyGLContext: doryVirglDestroyGLContext,
                makeCurrent: doryVirglMakeCurrent,
                getDRMFD: nil,
                writeContextFence: doryVirglWriteContextFence,
                getServerFD: nil,
                getEGLDisplay: nil
            ))

            // Host-allocated HOST3D blobs (the zero-copy map model libkrun uses): do NOT set
            // USE_GUEST_VRAM, which would make virglrenderer choose guest-backed storage that returns
            // no mappable host pointer. Keep both renderers active: VirGL gives the Linux desktop a
            // reliable accelerated OpenGL compositor through CGL, while Venus remains available to
            // Vulkan applications and compute workloads. The macOS renderer build does not expose
            // the Linux eventfd needed by virglrenderer's threaded/async fence mode, so Dory polls
            // its fence timelines explicitly below. This covers both VirGL and Venus contexts.
            let flags = classicOnly ? 0 : RendererFlags.venus
            let rendererCookie = Unmanaged.passUnretained(glContextManager).toOpaque()
            let initStatus = functions.initialize(rendererCookie, flags, UnsafeMutableRawPointer(callbacks))
            guard initStatus == 0 else {
                callbacks.deinitialize(count: 1)
                callbacks.deallocate()
                throw VMError.invalidConfiguration("virgl_renderer_init(VirGL + Venus) failed with status \(initStatus)")
            }

            var discoveredCapsets = [VirtioGPUCapset]()
            for capsetID in [VirtioGPUCapsetID.virgl, VirtioGPUCapsetID.virgl2, VirtioGPUCapsetID.venus] {
                var maxVersion: UInt32 = 0
                var maxSize: UInt32 = 0
                functions.getCapSet(capsetID, &maxVersion, &maxSize)
                guard maxSize > 0 else { continue }
                var capsetData = [UInt8](repeating: 0, count: Int(maxSize))
                capsetData.withUnsafeMutableBytes { buffer in
                    functions.fillCaps(capsetID, maxVersion, buffer.baseAddress)
                }
                discoveredCapsets.append(VirtioGPUCapset(
                    id: capsetID,
                    maxVersion: maxVersion,
                    data: capsetData
                ))
            }
            let hasVirgl2 = discoveredCapsets.contains(where: { $0.id == VirtioGPUCapsetID.virgl2 })
            let hasVenus = discoveredCapsets.contains(where: { $0.id == VirtioGPUCapsetID.venus })
            guard hasVirgl2, classicOnly || hasVenus else {
                functions.cleanup(nil)
                callbacks.deinitialize(count: 1)
                callbacks.deallocate()
                throw VMError.invalidConfiguration(
                    classicOnly
                        ? "virglrenderer did not report the VirGL2 capset"
                        : "virglrenderer did not report both VirGL2 and Venus capsets"
                )
            }

            // CGL contexts are current per host thread. Initialization runs on the app thread,
            // while virtio notifications can subsequently arrive on any vCPU thread. Leave no
            // renderer context attached to the initializer so each command can bind it safely on
            // the thread that is actually executing the command.
            glContextManager.clearCurrent()

            self.libraryPath = libraryPath
            self.moltenVKICDPath = moltenVKICDPath
            self.capsets = discoveredCapsets
            self.handle = handle
            self.callbacks = callbacks
            self.glContextManager = glContextManager
            self.functions = functions
            self.submissionSyncMode = SubmissionSyncMode(environment: environment)
            self.classicOnly = classicOnly
            Self.fenceLock.lock()
            Self.activeRenderer = self
            Self.fenceLock.unlock()
            FileHandle.standardError.write(Data(
                "dory-gpu: renderer mode=\(classicOnly ? "classic" : "virgl+venus") "
                    .appending("cross-context synchronization mode=\(submissionSyncMode.rawValue)\n").utf8
            ))
            startFencePolling()
        } catch {
            dlclose(handle)
            throw error
        }
    }

    deinit {
        pollSource?.cancel()
        pollSource = nil
        pollTimer?.cancel()
        pollTimer = nil
        Self.fenceLock.lock()
        if Self.activeRenderer === self { Self.activeRenderer = nil }
        Self.fenceLock.unlock()
        rendererLock.lock()
        functions.forceContext0()
        deletePendingSubmissionSyncs()
        functions.cleanup(nil)
        resourceIOVecs.removeAll()
        glContextManager.clearCurrent()
        rendererLock.unlock()
        callbacks.deinitialize(count: 1)
        callbacks.deallocate()
        dlclose(handle)
    }

    /// Registers a host fence so virglrenderer signals it once all GPU work submitted before it has
    /// completed. Context fences carry Venus's per-ring ordering; plain fences ride the global ctx0
    /// timeline.
    public func createFence(contextID: UInt32, ringIndex: UInt32, fenceID: UInt64, contextFence: Bool) throws {
        try withRendererContext(forceContextZero: false) {
            let capsetID = contextFlags[contextID].map { $0 & 0xff }
            // Besides binding ctx0 on this host thread, force_ctx_0 invalidates virglrenderer's
            // process-global current-context cache. Without that invalidation a zero-length submit
            // to the previous producer can be treated as an already-complete switch even though
            // Dory cleared the thread-local CGL context at the prior API boundary.
            functions.forceContext0()
            if contextID != 0, capsetID != VirtioGPUCapsetID.venus {
                // virgl_renderer_create_fence records a ctx0 timeline entry but inserts glFenceSync
                // into whichever GL context is current. QEMU naturally leaves the producer current;
                // Dory deliberately clears CGL at each API boundary because vCPU calls can migrate
                // across host threads. A zero-length submit performs virglrenderer's normal context
                // switch without changing guest state, restoring the producer before fence creation.
                try check(
                    functions.submitCommand(nil, Int32(bitPattern: contextID), 0),
                    "virgl_renderer_submit_cmd(context restore for fence)"
                )
            }
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
    }

    public func createContext(id: UInt32, flags: UInt32, name: String) throws {
        try withRendererContext {
            let status = name.withCString { pointer in
                functions.contextCreateWithFlags(id, flags, UInt32(name.utf8.count), pointer)
            }
            guard status == 0 else {
                throw VMError.invalidConfiguration(
                    "virgl_renderer_context_create_with_flags failed with status \(status) "
                        + "(context=\(id), flags=0x\(String(flags, radix: 16)), name=\(name))"
                )
            }
            contextLabels[id] = name
            contextFlags[id] = flags
        }
    }

    public func destroyContext(id: UInt32) throws {
        try withRendererContext {
            functions.contextDestroy(id)
            contextLabels.removeValue(forKey: id)
            contextFlags.removeValue(forKey: id)
        }
    }

    public func attachResource(contextID: UInt32, resourceID: UInt32) throws {
        try withRendererContext {
            functions.contextAttachResource(Int32(bitPattern: contextID), Int32(bitPattern: resourceID))
        }
    }

    public func detachResource(contextID: UInt32, resourceID: UInt32) throws {
        try withRendererContext {
            functions.contextDetachResource(Int32(bitPattern: contextID), Int32(bitPattern: resourceID))
        }
    }

    public func submit3D(contextID: UInt32, command: [UInt8]) throws {
        try withRendererContext {
            var command = command
            while command.count % 4 != 0 { command.append(0) }
            let dwordCount = Int32(command.count / 4)
            let status = command.withUnsafeMutableBytes { buffer in
                functions.submitCommand(buffer.baseAddress, Int32(bitPattern: contextID), dwordCount)
            }
            guard status == 0 else {
                let label = contextLabels[contextID] ?? "unknown"
                let summary = Self.commandSummary(command)
                throw VMError.invalidConfiguration(
                    "virgl_renderer_submit_cmd failed with status \(status) "
                        + "(context=\(contextID), name=\(label), bytes=\(command.count), commands=\(summary))"
                )
            }
            // Contexts share textures, but cross-context visibility still needs explicit ordering.
            // Keep the latest completion fence for each producer and resolve it at the readback
            // boundary. glFinish is retained as a diagnostic mode for isolating driver bugs.
            if submissionSyncMode == .finishAfterSubmit {
                glFinish()
                return
            }
            if let previous = pendingSubmissionSyncs.removeValue(forKey: contextID) {
                glDeleteSync(previous)
            }
            if let sync = glFenceSync(GLenum(GL_SYNC_GPU_COMMANDS_COMPLETE), 0) {
                pendingSubmissionSyncs[contextID] = sync
                glFlush()
            } else {
                // Extremely old/limited OpenGL implementations still remain correct.
                glFinish()
            }
        }
    }

    private static func commandSummary(_ command: [UInt8]) -> String {
        var offset = 0
        var descriptions = [String]()
        while offset + 4 <= command.count, descriptions.count < 24 {
            let header = UInt32(command[offset])
                | (UInt32(command[offset + 1]) << 8)
                | (UInt32(command[offset + 2]) << 16)
                | (UInt32(command[offset + 3]) << 24)
            let opcode = header & 0xff
            let length = Int(header >> 16)
            descriptions.append("\(offset / 4):\(opcode)/\(length)")
            let advance = (length + 1) * 4
            guard advance > 0, advance <= command.count - offset else { break }
            offset += advance
        }
        if offset < command.count { descriptions.append("...") }
        return descriptions.joined(separator: ",")
    }

    public func createResource3D(_ resource: VirtioGPUResourceCreate3D, entries: [VirtioGPUMemoryEntry]) throws {
        try withRendererContext {
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
            let backing = entries.isEmpty ? nil : OwnedIOVecs(entries: entries)
            let status = withUnsafeMutablePointer(to: &args) { argsPointer in
                functions.resourceCreate(
                    UnsafeMutableRawPointer(argsPointer),
                    backing?.pointer,
                    backing?.count ?? 0
                )
            }
            try check(status, "virgl_renderer_resource_create")
            if let backing {
                resourceIOVecs[resource.resourceID] = backing
            }
        }
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
        try withRendererContext {
            let backing = entries.isEmpty ? nil : OwnedIOVecs(entries: entries)
            var args = VirglRendererResourceCreateBlobArgs(
                resourceHandle: resourceID,
                contextID: contextID,
                blobMemory: blobMemory,
                blobFlags: blobFlags,
                blobID: blobID,
                size: size,
                iovecs: backing?.pointer,
                iovecCount: backing?.count ?? 0
            )
            let status = withUnsafePointer(to: &args) { argsPointer in
                functions.resourceCreateBlob(UnsafeRawPointer(argsPointer))
            }
            try check(status, "virgl_renderer_resource_create_blob")
            if let backing {
                resourceIOVecs[resourceID] = backing
            }
        }
    }

    public func attachBacking(resourceID: UInt32, entries: [VirtioGPUMemoryEntry]) throws {
        try withRendererContext {
            guard !entries.isEmpty else {
                throw VMError.invalidConfiguration("cannot attach empty backing to renderer resource \(resourceID)")
            }
            let backing = OwnedIOVecs(entries: entries)
            let status = functions.resourceAttachIOV(
                Int32(bitPattern: resourceID),
                backing.pointer,
                Int32(backing.count)
            )
            try check(status, "virgl_renderer_resource_attach_iov")
            resourceIOVecs[resourceID] = backing
        }
    }

    public func detachBacking(resourceID: UInt32) throws {
        try withRendererContext {
            var detached: UnsafeMutablePointer<iovec>?
            var count: Int32 = 0
            functions.resourceDetachIOV(Int32(bitPattern: resourceID), &detached, &count)
            resourceIOVecs.removeValue(forKey: resourceID)
        }
    }

    public func unrefResource(resourceID: UInt32) throws {
        try withRendererContext {
            functions.resourceUnref(resourceID)
            resourceIOVecs.removeValue(forKey: resourceID)
        }
    }

    public func mapBlob(resourceID: UInt32) throws -> VirtioGPUBlobMapping {
        try withRendererContext {
            var pointer: UnsafeMutableRawPointer?
            var size: UInt64 = 0
            // On macOS the blob is MoltenVK-backed (Apple handle); virgl_renderer_resource_map returns
            // -EINVAL for it by design. get_map_ptr returns the vkMapMemory host VA to hv_vm_map into the
            // guest — the exact path libkrun/krunkit use. Fall back to resource_map only if absent.
            let requiresRendererUnmap: Bool
            if let getPtr = functions.resourceGetMapPtr {
                var address: UInt64 = 0
                try check(getPtr(resourceID, &address), "virgl_renderer_resource_get_map_ptr")
                pointer = UnsafeMutableRawPointer(bitPattern: UInt(address))
                // get_map_ptr exposes the existing Vulkan allocation without changing virglrenderer's
                // resource-map state. Calling resource_unmap for this path is therefore invalid.
                requiresRendererUnmap = false
            } else if let map = functions.resourceMap {
                try check(map(resourceID, &pointer, &size), "virgl_renderer_resource_map")
                requiresRendererUnmap = true
            } else {
                throw VMError.invalidConfiguration("virglrenderer has no blob map entrypoint")
            }
            guard let hostPointer = pointer else {
                throw VMError.invalidConfiguration("virglrenderer returned a null host pointer for blob resource \(resourceID)")
            }
            var mapInfo: UInt32 = 0
            try check(functions.resourceGetMapInfo(resourceID, &mapInfo), "virgl_renderer_resource_get_map_info")
            return VirtioGPUBlobMapping(
                hostPointer: hostPointer,
                size: size,
                mapInfo: mapInfo & 0x0f,
                requiresRendererUnmap: requiresRendererUnmap
            )
        }
    }

    public func unmapBlob(resourceID: UInt32) throws {
        try withRendererContext {
            try check(functions.resourceUnmap(resourceID), "virgl_renderer_resource_unmap")
        }
    }

    public func transferToHost3D(_ transfer: VirtioGPUTransfer3D, entries: [VirtioGPUMemoryEntry]) throws {
        try withRendererContext {
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
    }

    public func transferFromHost3D(_ transfer: VirtioGPUTransfer3D, entries: [VirtioGPUMemoryEntry]) throws {
        try withRendererContext {
            try waitForPendingSubmissions()
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
    }

    private func waitForPendingSubmissions() throws {
        for sync in pendingSubmissionSyncs.values {
            switch submissionSyncMode {
            case .clientWaitBeforeReadback:
                // glWaitSync only orders commands subsequently issued by its *current* context.
                // virglrenderer may switch from ctx0 to a resource context during transfer_read,
                // so a server-side wait in ctx0 does not protect that readback. A client wait
                // establishes completion before any context switch and is valid for shared sync
                // objects created by Firefox, Mutter, or another guest GL producer.
                try waitForCompletion(sync)
            case .serverWaitBeforeReadback:
                glWaitSync(sync, 0, GLuint64(GL_TIMEOUT_IGNORED))
            case .finishAfterSubmit:
                break
            }
            glDeleteSync(sync)
        }
        pendingSubmissionSyncs.removeAll(keepingCapacity: true)
    }

    private func waitForCompletion(_ sync: GLsync) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while true {
            let result = glClientWaitSync(sync, 0, 100_000_000)
            switch result {
            case GLenum(GL_ALREADY_SIGNALED), GLenum(GL_CONDITION_SATISFIED):
                return
            case GLenum(GL_TIMEOUT_EXPIRED):
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    throw VMError.invalidConfiguration(
                        "timed out waiting for a shared OpenGL submission before scanout readback"
                    )
                }
            default:
                throw VMError.invalidConfiguration(
                    "glClientWaitSync failed before scanout readback (status=0x\(String(result, radix: 16)))"
                )
            }
        }
    }

    private func deletePendingSubmissionSyncs() {
        for sync in pendingSubmissionSyncs.values { glDeleteSync(sync) }
        pendingSubmissionSyncs.removeAll()
    }

    /// virglrenderer caches its active context globally because QEMU normally calls it from one
    /// event-loop thread. Dory's MMIO notifications can originate on any vCPU thread, while CGL's
    /// current context is thread-local. Resetting to ctx0 at each serialized API boundary makes
    /// virglrenderer issue the appropriate make-current callback on the actual calling thread.
    private func withRendererContext<T>(
        forceContextZero: Bool = true,
        _ body: () throws -> T
    ) throws -> T {
        rendererLock.lock()
        if forceContextZero {
            functions.forceContext0()
        }
        defer {
            glContextManager.clearCurrent()
            rendererLock.unlock()
            deliverPendingFenceSignals()
        }
        return try body()
    }

    /// Runs the device-facing part of a fence completion outside rendererLock. Besides avoiding the
    /// lock inversion documented above, this keeps virglrenderer's C callback short and prevents
    /// guest used-ring writes or virtual interrupts from re-entering the renderer while it polls.
    private func deliverPendingFenceSignals() {
        Self.fenceLock.lock()
        let signals = pendingFenceSignals
        pendingFenceSignals.removeAll(keepingCapacity: true)
        let sink = fenceSink
        Self.fenceLock.unlock()
        guard let sink else { return }
        for signal in signals {
            sink(signal.contextID, signal.ringIndex, signal.fenceID)
        }
    }

    /// virglrenderer's threaded fence worker signals this descriptor when the caller must run
    /// `virgl_renderer_poll` (notably to service GL queries before retiring a fence). Without an
    /// event-loop subscriber, a compositor can wait forever after submitting its first frame.
    private func startFencePolling() {
        let descriptor = functions.getPollFD()
        let queue = DispatchQueue(label: "dev.dory.virgl.poll", qos: .userInteractive)
        let poll: @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            try? self.withRendererContext {
                self.functions.poll()
            }
        }
        if descriptor >= 0 {
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            source.setEventHandler(handler: poll)
            pollSource = source
            source.resume()
        } else {
            // CGL builds have no eventfd. One millisecond keeps guest fence latency below a frame
            // without burning a vCPU in a busy loop; poll itself is non-blocking.
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(1), leeway: .milliseconds(1))
            timer.setEventHandler(handler: poll)
            pollTimer = timer
            timer.resume()
        }
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
    static let threadSync: Int32 = 1 << 1
    static let venus: Int32 = 1 << 6
    static let asyncFenceCB: Int32 = 1 << 8
    static let useGuestVRAM: Int32 = 1 << 14
}

private enum SubmissionSyncMode: String {
    case clientWaitBeforeReadback = "client-wait"
    case serverWaitBeforeReadback = "server-wait"
    case finishAfterSubmit = "finish"

    init(environment: [String: String]) {
        let requested = environment["DORY_VIRGL_SYNC_MODE"]?.lowercased()
        self = SubmissionSyncMode(rawValue: requested ?? "") ?? .serverWaitBeforeReadback
    }
}

private final class OwnedIOVecs {
    let pointer: UnsafeMutablePointer<iovec>
    let count: UInt32

    init(entries: [VirtioGPUMemoryEntry]) {
        precondition(!entries.isEmpty)
        count = UInt32(entries.count)
        pointer = .allocate(capacity: entries.count)
        for (index, entry) in entries.enumerated() {
            pointer.advanced(by: index).initialize(to: iovec(
                iov_base: entry.pointer,
                iov_len: entry.length
            ))
        }
    }

    deinit {
        pointer.deinitialize(count: Int(count))
        pointer.deallocate()
    }
}

private enum VirtioGPUCapsetID {
    static let virgl: UInt32 = 1
    static let virgl2: UInt32 = 2
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

/// virglrenderer's classic 3D path needs the VMM to supply host OpenGL contexts when it is not
/// using EGL or GLX. CGL is the native offscreen OpenGL context API on macOS and remains backed by
/// the Apple GPU, so the guest compositor avoids llvmpipe without adding another window surface.
private final class VirglCGLContextManager: @unchecked Sendable {
    private let lock = NSLock()
    private let pixelFormat: CGLPixelFormatObj
    private var shareContext: CGLContextObj?

    init() throws {
        var format: CGLPixelFormatObj?
        var formatCount: GLint = 0
        var attributes: [CGLPixelFormatAttribute] = [
            kCGLPFAAccelerated,
            kCGLPFAOpenGLProfile,
            CGLPixelFormatAttribute(kCGLOGLPVersion_GL4_Core.rawValue),
            CGLPixelFormatAttribute(0),
        ]
        let status = CGLChoosePixelFormat(&attributes, &format, &formatCount)
        guard status == kCGLNoError, formatCount > 0, let format else {
            throw VMError.invalidConfiguration("cannot create an accelerated macOS OpenGL pixel format (CGL status \(status.rawValue))")
        }
        pixelFormat = format
    }

    deinit {
        CGLDestroyPixelFormat(pixelFormat)
    }

    func createContext(shared: Bool) -> UnsafeMutableRawPointer? {
        lock.lock()
        defer { lock.unlock() }
        var context: CGLContextObj?
        let sharedContext = shared ? shareContext : nil
        let status = CGLCreateContext(pixelFormat, sharedContext, &context)
        guard status == kCGLNoError, let context else {
            FileHandle.standardError.write(Data(
                "dory-gpu: CGL context creation failed shared=\(shared) status=\(status.rawValue)\n".utf8
            ))
            return nil
        }
        if shareContext == nil {
            shareContext = context
        }
        return UnsafeMutableRawPointer(context)
    }

    func destroyContext(_ pointer: UnsafeMutableRawPointer) {
        let context = pointer.assumingMemoryBound(to: CGLContextObj.Pointee.self)
        lock.lock()
        let wasRoot = shareContext == context
        if wasRoot {
            shareContext = nil
        }
        lock.unlock()
        if CGLGetCurrentContext() == context {
            _ = CGLSetCurrentContext(nil)
        }
        CGLDestroyContext(context)
    }

    func makeCurrent(_ pointer: UnsafeMutableRawPointer?) -> Int32 {
        let context = pointer.map { $0.assumingMemoryBound(to: CGLContextObj.Pointee.self) }
        return CGLSetCurrentContext(context) == kCGLNoError ? 0 : -1
    }

    func clearCurrent() {
        _ = CGLSetCurrentContext(nil)
    }
}

private func doryVirglContextManager(_ cookie: UnsafeMutableRawPointer?) -> VirglCGLContextManager? {
    cookie.map { Unmanaged<VirglCGLContextManager>.fromOpaque($0).takeUnretainedValue() }
}

private let doryVirglCreateGLContext: CreateGLContextCallback = { cookie, _, parameters in
    guard let manager = doryVirglContextManager(cookie), let parameters else { return nil }
    // C layout: int version; bool shared; 3 bytes padding; int major; int minor; int compat.
    let shared = parameters.load(fromByteOffset: 4, as: UInt8.self) != 0
    return manager.createContext(shared: shared)
}

private let doryVirglDestroyGLContext: DestroyGLContextCallback = { cookie, context in
    guard let manager = doryVirglContextManager(cookie), let context else { return }
    manager.destroyContext(context)
}

private let doryVirglMakeCurrent: MakeCurrentCallback = { cookie, _, context in
    guard let manager = doryVirglContextManager(cookie) else { return -1 }
    return manager.makeCurrent(context)
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
    typealias ForceContext0 = @convention(c) () -> Void
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
    typealias Poll = @convention(c) () -> Void
    typealias GetPollFD = @convention(c) () -> Int32

    let initialize: Initialize
    let cleanup: Cleanup
    let getCapSet: GetCapSet
    let fillCaps: FillCaps
    let contextCreateWithFlags: ContextCreateWithFlags
    let contextDestroy: ContextDestroy
    let forceContext0: ForceContext0
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
    let poll: Poll
    let getPollFD: GetPollFD

    init(handle: UnsafeMutableRawPointer) throws {
        initialize = try Self.required(handle, "virgl_renderer_init")
        cleanup = try Self.required(handle, "virgl_renderer_cleanup")
        getCapSet = try Self.required(handle, "virgl_renderer_get_cap_set")
        fillCaps = try Self.required(handle, "virgl_renderer_fill_caps")
        contextCreateWithFlags = try Self.required(handle, "virgl_renderer_context_create_with_flags")
        contextDestroy = try Self.required(handle, "virgl_renderer_context_destroy")
        forceContext0 = try Self.required(handle, "virgl_renderer_force_ctx_0")
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
        poll = try Self.required(handle, "virgl_renderer_poll")
        getPollFD = try Self.required(handle, "virgl_renderer_get_poll_fd")
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
