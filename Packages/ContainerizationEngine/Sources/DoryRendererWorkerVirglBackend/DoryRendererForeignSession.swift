import Darwin
import DoryRendererWorkerContracts
import DoryVirglRendererShim
import Foundation
import Metal

public enum DoryRendererForeignSessionError: Error, Equatable, Sendable {
    case openFailed(Int32)
    case callFailed(operation: String, status: Int32)
    case submitFailed(status: Int32, diagnostic: DoryRendererForeignSubmitFailure?)
    case invalidResult(operation: String)
}

public enum DoryRendererCreateObjectSubtypeDisposition: UInt32, Equatable, Sendable {
    case absent = 0
    case present = 1
    case ambiguous = 2
}

/// Exact pinned `virgl_object_type` ordinals accepted from a CREATE_OBJECT command header.
public enum DoryRendererVirglObjectType: UInt32, Equatable, Sendable {
    case null = 0
    case blend = 1
    case rasterizer = 2
    case depthStencilAlpha = 3
    case shader = 4
    case vertexElements = 5
    case samplerView = 6
    case samplerState = 7
    case surface = 8
    case query = 9
    case streamOutputTarget = 10
    case multisampleSurface = 11
}

/// Closed validation reasons emitted only for a failed pinned VirGL surface CREATE_OBJECT.
public enum DoryRendererVirglSurfaceFailureReason: UInt32, Equatable, Sendable {
    case none = 0
    case createPayloadTooShort = 1
    case createHandleZero = 2
    case surfaceLengthMismatch = 3
    case resourceMissing = 4
    case resourceGLObjectMissing = 5
    case formatOutOfRange = 6
    case invalidLayerRange = 7
}

/// Closed categories admitted from fixed vrend error prefixes. No suffix or renderer text survives.
public enum DoryRendererVirglSubmitPrecursorCategory: UInt32, Equatable, Sendable {
    case none = 0
    case shaderCompileFailed = 1
    case tgsiAssignmentFailed = 2
    case geometryShaderUnsupported = 3
    case tessellationShaderUnsupported = 4
    case computeShaderUnsupported = 5
    case invalidExpectedTokenCount = 6
    case expectedLongContinuation = 7
    case invalidContinuationHandle = 8
    case continuationWithoutOriginal = 9
    case mismatchedContinuation = 10
    case oversizedContinuation = 11
}

/// Sanitized vrend submit failure captured by the C shim. The command identifier is admitted only
/// after matching the complete name in the pinned static command table. CREATE_OBJECT subtype comes
/// only from the bounded command-header parser; renderer log text and command payloads are discarded.
public struct DoryRendererForeignSubmitFailure: Equatable, Sendable {
    public let decoderDiagnosticIsAvailable: Bool
    public let contextID: UInt32
    public let commandID: UInt32
    public let status: Int32
    public let createObjectSubtypeDisposition: DoryRendererCreateObjectSubtypeDisposition
    public let createObjectSubtype: DoryRendererVirglObjectType?
    /// Saturating count of CREATE_OBJECT headers (0...255), never a command-stream length.
    public let createObjectCandidateCount: UInt32
    /// Closed low-12-bit set of pinned object subtypes observed in CREATE_OBJECT headers.
    public let createObjectSubtypeMask: UInt32
    public let surfaceFailureReason: DoryRendererVirglSurfaceFailureReason
    public let precursorCategory: DoryRendererVirglSubmitPrecursorCategory

    public init(
        contextID: UInt32,
        commandID: UInt32,
        status: Int32,
        createObjectSubtypeDisposition: DoryRendererCreateObjectSubtypeDisposition = .absent,
        createObjectSubtype: DoryRendererVirglObjectType? = nil,
        createObjectCandidateCount: UInt32 = 0,
        createObjectSubtypeMask: UInt32 = 0,
        precursorCategory: DoryRendererVirglSubmitPrecursorCategory = .none
    ) {
        self.init(
            decoderDiagnosticIsAvailable: true,
            failedCommandLocationIsExact: true,
            contextID: contextID,
            commandID: commandID,
            status: status,
            createObjectSubtypeDisposition: createObjectSubtypeDisposition,
            createObjectSubtype: createObjectSubtype,
            createObjectCandidateCount: createObjectCandidateCount == 0
                ? (createObjectSubtype == nil ? 0 : 1)
                : createObjectCandidateCount,
            createObjectSubtypeMask: createObjectSubtypeMask == 0
                ? createObjectSubtype.map { 1 << $0.rawValue } ?? 0
                : createObjectSubtypeMask,
            // Only the C shim's exact-tuple sanitizer may admit a surface reason.
            surfaceFailureReason: .none,
            precursorCategory: precursorCategory
        )
    }

    private init(
        decoderDiagnosticIsAvailable: Bool,
        failedCommandLocationIsExact: Bool,
        contextID: UInt32,
        commandID: UInt32,
        status: Int32,
        createObjectSubtypeDisposition: DoryRendererCreateObjectSubtypeDisposition,
        createObjectSubtype: DoryRendererVirglObjectType?,
        createObjectCandidateCount: UInt32,
        createObjectSubtypeMask: UInt32,
        surfaceFailureReason: DoryRendererVirglSurfaceFailureReason,
        precursorCategory: DoryRendererVirglSubmitPrecursorCategory
    ) {
        self.decoderDiagnosticIsAvailable = decoderDiagnosticIsAvailable
        self.contextID = decoderDiagnosticIsAvailable ? contextID : 0
        self.commandID = decoderDiagnosticIsAvailable ? commandID : 0
        self.status = decoderDiagnosticIsAvailable ? status : 0
        if decoderDiagnosticIsAvailable && commandID == 1 {
            let candidateSummaryIsValid = createObjectCandidateCount <= 255 &&
                createObjectSubtypeMask & ~0x0fff == 0
            if createObjectSubtypeDisposition == .present,
               let createObjectSubtype,
               candidateSummaryIsValid,
               createObjectCandidateCount > 0,
               createObjectSubtypeMask & (1 << createObjectSubtype.rawValue) != 0 {
                self.createObjectSubtypeDisposition = .present
                self.createObjectSubtype = createObjectSubtype
            } else {
                self.createObjectSubtypeDisposition =
                    createObjectSubtypeDisposition == .present || !candidateSummaryIsValid
                    ? .ambiguous
                    : createObjectSubtypeDisposition
                self.createObjectSubtype = nil
            }
            self.createObjectCandidateCount = candidateSummaryIsValid
                ? createObjectCandidateCount
                : 0
            self.createObjectSubtypeMask = candidateSummaryIsValid
                ? createObjectSubtypeMask
                : 0
        } else {
            self.createObjectSubtypeDisposition = .absent
            self.createObjectSubtype = nil
            self.createObjectCandidateCount = 0
            self.createObjectSubtypeMask = 0
        }
        self.surfaceFailureReason = decoderDiagnosticIsAvailable &&
            failedCommandLocationIsExact &&
            commandID == 1 && status == EINVAL && self.createObjectSubtype == .surface
            ? surfaceFailureReason
            : .none
        self.precursorCategory = precursorCategory
    }

    init?(sanitizing diagnostic: DoryVirglRendererSubmitDiagnostic) {
        let decoderDiagnosticIsAvailable = diagnostic.valid == 1
        let precursorCategory = DoryRendererVirglSubmitPrecursorCategory(
            rawValue: diagnostic.precursor_category
        ) ?? .none
        guard decoderDiagnosticIsAvailable || precursorCategory != .none else { return nil }

        let rawDisposition = DoryRendererCreateObjectSubtypeDisposition(
            rawValue: diagnostic.create_object_subtype_disposition
        ) ?? .ambiguous
        let objectType = rawDisposition == .present
            ? DoryRendererVirglObjectType(rawValue: diagnostic.create_object_subtype)
            : nil
        let surfaceFailureReason = DoryRendererVirglSurfaceFailureReason(
            rawValue: diagnostic.surface_failure_reason
        ) ?? .none
        self.init(
            decoderDiagnosticIsAvailable: decoderDiagnosticIsAvailable,
            failedCommandLocationIsExact:
                diagnostic.failed_command_location_disposition == 1,
            contextID: diagnostic.context_id,
            commandID: diagnostic.command_id,
            status: diagnostic.status,
            createObjectSubtypeDisposition: rawDisposition,
            createObjectSubtype: objectType,
            createObjectCandidateCount: diagnostic.create_object_candidate_count,
            createObjectSubtypeMask: diagnostic.create_object_subtype_mask,
            surfaceFailureReason: surfaceFailureReason,
            precursorCategory: precursorCategory
        )
    }
}

public struct DoryRendererForeignCapset: Equatable, Sendable {
    public let id: UInt32
    public let maximumVersion: UInt32
    public let bytes: Data

    public init(id: UInt32, maximumVersion: UInt32, bytes: Data) {
        self.id = id
        self.maximumVersion = maximumVersion
        self.bytes = bytes
    }
}

public struct DoryRendererForeignBlobCreate: Equatable, Sendable {
    public let resourceID: UInt32
    public let contextID: UInt32
    public let payload: DoryRendererBlobCreatePayload

    public init(
        resourceID: UInt32,
        contextID: UInt32,
        payload: DoryRendererBlobCreatePayload
    ) {
        self.resourceID = resourceID
        self.contextID = contextID
        self.payload = payload
    }
}

public struct DoryRendererForeignResource3DCreate: Equatable, Sendable {
    public let resourceID: UInt32
    public let payload: DoryRendererResource3DCreatePayload

    public init(resourceID: UInt32, payload: DoryRendererResource3DCreatePayload) {
        self.resourceID = resourceID
        self.payload = payload
    }
}

public struct DoryRendererForeignResourceInfo: Equatable, Sendable {
    public let resourceID: UInt32
    public let format: UInt32
    public let width: UInt32
    public let height: UInt32
    public let flags: UInt32
    public let stride: UInt32

    public init(
        resourceID: UInt32,
        format: UInt32,
        width: UInt32,
        height: UInt32,
        flags: UInt32,
        stride: UInt32
    ) {
        self.resourceID = resourceID
        self.format = format
        self.width = width
        self.height = height
        self.flags = flags
        self.stride = stride
    }
}

public struct DoryRendererForeignExportedBlob: Sendable {
    public let type: UInt32
    public let ownedFileDescriptor: Int32

    public init(type: UInt32, ownedFileDescriptor: Int32) {
        self.type = type
        self.ownedFileDescriptor = ownedFileDescriptor
    }
}

public protocol DoryRendererForeignSession: AnyObject, Sendable {
    func capset(id: UInt32) throws -> DoryRendererForeignCapset
    func createContext(id: UInt32, capsetID: UInt32, name: String) throws
    func destroyContext(id: UInt32)
    func attachResource(contextID: UInt32, resourceID: UInt32)
    func detachResource(contextID: UInt32, resourceID: UInt32)
    func submit(contextID: UInt32, bytes: UnsafeRawPointer, dwordCount: UInt32) throws
    func createBlob(
        _ resource: DoryRendererForeignBlobCreate,
        iovecs: UnsafePointer<iovec>?,
        iovecCount: UInt32
    ) throws
    func createResource3D(_ resource: DoryRendererForeignResource3DCreate) throws
    func attachBacking(
        resourceID: UInt32,
        iovecs: UnsafePointer<iovec>,
        iovecCount: UInt32
    ) throws
    func detachBacking(resourceID: UInt32)
    func unrefResource(id: UInt32)
    func mapInfo(resourceID: UInt32) throws -> UInt32
    func exportBlob(resourceID: UInt32) throws -> DoryRendererForeignExportedBlob
    func resourceInfo(resourceID: UInt32) throws -> DoryRendererForeignResourceInfo
    func acquireScanoutMetalTexture(
        resourceID: UInt32,
        width: UInt32,
        height: UInt32,
        virglFormat: UInt32,
        stride: UInt32,
        offset: UInt32
    ) throws -> any MTLTexture
    func transfer(
        toHost: Bool,
        resourceID: UInt32,
        contextID: UInt32,
        payload: DoryRendererTransfer3DPayload,
        iovecs: UnsafePointer<iovec>?,
        iovecCount: UInt32
    ) throws
    func createFence(
        contextID: UInt32,
        flags: UInt32,
        ringIndex: UInt32,
        fenceID: UInt64
    ) throws
    /// Creates a classic VirGL ctx0 fence. The shim owns the lossless mapping from this guest
    /// 64-bit identity to virglrenderer's collision-safe 32-bit callback token.
    func createGlobalFence(fenceID: UInt64) throws
    func exportFence(fenceID: UInt64) throws -> Int32
    /// Borrowed renderer event descriptor when threaded sync is available. Darwin may legitimately
    /// strip that hint; nil selects the backend's bounded timer pump. The backend never closes a
    /// returned descriptor; `invalidate` releases the underlying renderer authority.
    func pollDescriptor() throws -> Int32?
    func poll()
    func invalidate()
}

public protocol DoryRendererForeignSessionCreating: Sendable {
    func create(
        attestation: DoryRendererArtifactAttestation
    ) throws -> any DoryRendererForeignSession
}

public struct DoryRendererCForeignSessionFactory:
    DoryRendererForeignSessionCreating,
    Sendable
{
    public init() {}

    public func create(
        attestation _: DoryRendererArtifactAttestation
    ) throws -> any DoryRendererForeignSession {
        try DoryRendererCForeignSession()
    }
}

private final class DoryRendererCForeignSession:
    DoryRendererForeignSession,
    @unchecked Sendable
{
    private var session: OpaquePointer?

    init() throws {
        var opened: OpaquePointer?
        let status = DoryVirglRendererSessionCreate(&opened)
        guard status == 0, let opened else {
            throw DoryRendererForeignSessionError.openFailed(status)
        }
        session = opened
    }

    deinit { invalidate() }

    func capset(id: UInt32) throws -> DoryRendererForeignCapset {
        let session = try requiredSession()
        var maximumVersion: UInt32 = 0
        var byteCount = 0
        try Self.check(
            DoryVirglRendererGetCapset(
                session,
                id,
                &maximumVersion,
                nil,
                0,
                &byteCount
            ),
            "virgl_renderer_get_cap_set"
        )
        guard byteCount > 0,
              byteCount <= DoryRendererCapsetAttestation.maximumCapsetBytes else {
            throw DoryRendererForeignSessionError.invalidResult(operation: "capset-size")
        }
        var data = Data(count: byteCount)
        let status = data.withUnsafeMutableBytes {
            DoryVirglRendererGetCapset(
                session,
                id,
                &maximumVersion,
                $0.baseAddress,
                $0.count,
                &byteCount
            )
        }
        try Self.check(status, "virgl_renderer_fill_caps")
        guard data.count == byteCount else {
            throw DoryRendererForeignSessionError.invalidResult(operation: "capset-size")
        }
        return DoryRendererForeignCapset(
            id: id,
            maximumVersion: maximumVersion,
            bytes: data
        )
    }

    func createContext(id: UInt32, capsetID: UInt32, name: String) throws {
        let session = try requiredSession()
        let bytes = Array(name.utf8)
        let status = bytes.withUnsafeBufferPointer { buffer in
            DoryVirglRendererContextCreate(
                session,
                id,
                capsetID,
                buffer.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) },
                buffer.count
            )
        }
        try Self.check(status, "virgl_renderer_context_create_with_flags")
    }

    func destroyContext(id: UInt32) {
        guard let session else { return }
        DoryVirglRendererContextDestroy(session, id)
    }

    func attachResource(contextID: UInt32, resourceID: UInt32) {
        guard let session else { return }
        DoryVirglRendererContextAttachResource(session, contextID, resourceID)
    }

    func detachResource(contextID: UInt32, resourceID: UInt32) {
        guard let session else { return }
        DoryVirglRendererContextDetachResource(session, contextID, resourceID)
    }

    func submit(contextID: UInt32, bytes: UnsafeRawPointer, dwordCount: UInt32) throws {
        var diagnostic = DoryVirglRendererSubmitDiagnostic()
        let status = DoryVirglRendererSubmit(
            try requiredSession(),
            contextID,
            bytes,
            dwordCount,
            &diagnostic
        )
        guard status == 0 else {
            let failure = DoryRendererForeignSubmitFailure(sanitizing: diagnostic)
            throw DoryRendererForeignSessionError.submitFailed(
                status: status,
                diagnostic: failure
            )
        }
    }

    func createBlob(
        _ resource: DoryRendererForeignBlobCreate,
        iovecs: UnsafePointer<iovec>?,
        iovecCount: UInt32
    ) throws {
        var arguments = DoryVirglRendererBlobCreateArguments(
            resource_handle: resource.resourceID,
            context_id: resource.contextID,
            blob_memory: resource.payload.blobMemory,
            blob_flags: resource.payload.blobFlags,
            blob_id: resource.payload.blobID,
            size: resource.payload.size,
            iovecs: iovecs,
            iovec_count: iovecCount
        )
        try Self.check(
            DoryVirglRendererBlobCreate(try requiredSession(), &arguments),
            "virgl_renderer_resource_create_blob"
        )
    }

    func createResource3D(_ resource: DoryRendererForeignResource3DCreate) throws {
        var arguments = DoryVirglRendererResource3DCreateArguments(
            handle: resource.resourceID,
            target: resource.payload.target,
            format: resource.payload.format,
            bind: resource.payload.bind,
            width: resource.payload.width,
            height: resource.payload.height,
            depth: resource.payload.depth,
            array_size: resource.payload.arraySize,
            last_level: resource.payload.lastLevel,
            samples: resource.payload.samples,
            flags: resource.payload.flags
        )
        try Self.check(
            DoryVirglRendererResource3DCreate(try requiredSession(), &arguments),
            "virgl_renderer_resource_create"
        )
    }

    func attachBacking(
        resourceID: UInt32,
        iovecs: UnsafePointer<iovec>,
        iovecCount: UInt32
    ) throws {
        try Self.check(
            DoryVirglRendererResourceAttachBacking(
                try requiredSession(),
                resourceID,
                iovecs,
                iovecCount
            ),
            "virgl_renderer_resource_attach_iov"
        )
    }

    func detachBacking(resourceID: UInt32) {
        guard let session else { return }
        DoryVirglRendererResourceDetachBacking(session, resourceID)
    }

    func unrefResource(id: UInt32) {
        guard let session else { return }
        DoryVirglRendererResourceUnref(session, id)
    }

    func mapInfo(resourceID: UInt32) throws -> UInt32 {
        var mapInfo: UInt32 = 0
        try Self.check(
            DoryVirglRendererResourceGetMapInfo(
                try requiredSession(),
                resourceID,
                &mapInfo
            ),
            "virgl_renderer_resource_get_map_info"
        )
        return mapInfo
    }

    func exportBlob(resourceID: UInt32) throws -> DoryRendererForeignExportedBlob {
        var type: UInt32 = 0
        var fileDescriptor: Int32 = -1
        try Self.check(
            DoryVirglRendererResourceExportBlob(
                try requiredSession(),
                resourceID,
                &type,
                &fileDescriptor
            ),
            "virgl_renderer_resource_export_blob"
        )
        guard fileDescriptor >= 0 else {
            throw DoryRendererForeignSessionError.invalidResult(operation: "export-blob-fd")
        }
        return DoryRendererForeignExportedBlob(
            type: type,
            ownedFileDescriptor: fileDescriptor
        )
    }

    func resourceInfo(resourceID: UInt32) throws -> DoryRendererForeignResourceInfo {
        var info = DoryVirglRendererResourceInfo()
        try Self.check(
            DoryVirglRendererResourceGetInfo(
                try requiredSession(),
                resourceID,
                &info
            ),
            "virgl_renderer_resource_get_info"
        )
        return DoryRendererForeignResourceInfo(
            resourceID: info.handle,
            format: info.virgl_format,
            width: info.width,
            height: info.height,
            flags: info.flags,
            stride: info.stride
        )
    }

    func acquireScanoutMetalTexture(
        resourceID: UInt32,
        width: UInt32,
        height: UInt32,
        virglFormat: UInt32,
        stride: UInt32,
        offset: UInt32
    ) throws -> any MTLTexture {
        var retainedTexture: UnsafeMutableRawPointer?
        try Self.check(
            DoryVirglRendererResourceAcquireScanoutMetalTexture(
                try requiredSession(),
                resourceID,
                width,
                height,
                virglFormat,
                stride,
                offset,
                &retainedTexture
            ),
            "virgl_renderer_create_handle_for_scanout"
        )
        guard let retainedTexture else {
            throw DoryRendererForeignSessionError.invalidResult(
                operation: "metal-scanout-texture"
            )
        }
        let object = Unmanaged<AnyObject>.fromOpaque(retainedTexture).takeRetainedValue()
        guard let texture = object as? any MTLTexture else {
            throw DoryRendererForeignSessionError.invalidResult(
                operation: "metal-scanout-texture-type"
            )
        }
        return texture
    }

    func transfer(
        toHost: Bool,
        resourceID: UInt32,
        contextID: UInt32,
        payload: DoryRendererTransfer3DPayload,
        iovecs: UnsafePointer<iovec>?,
        iovecCount: UInt32
    ) throws {
        var box = DoryVirglRendererBox(
            x: payload.x,
            y: payload.y,
            z: payload.z,
            width: payload.width,
            height: payload.height,
            depth: payload.depth
        )
        let status = toHost
            ? DoryVirglRendererTransferToHost(
                try requiredSession(),
                resourceID,
                contextID,
                payload.level,
                payload.stride,
                payload.layerStride,
                &box,
                payload.offset,
                iovecs,
                iovecCount
            )
            : DoryVirglRendererTransferFromHost(
                try requiredSession(),
                resourceID,
                contextID,
                payload.level,
                payload.stride,
                payload.layerStride,
                &box,
                payload.offset,
                iovecs,
                iovecCount
            )
        try Self.check(
            status,
            toHost ? "virgl_renderer_transfer_write_iov" : "virgl_renderer_transfer_read_iov"
        )
    }

    func createFence(
        contextID: UInt32,
        flags: UInt32,
        ringIndex: UInt32,
        fenceID: UInt64
    ) throws {
        try Self.check(
            DoryVirglRendererCreateContextFence(
                try requiredSession(),
                contextID,
                flags,
                ringIndex,
                fenceID
            ),
            "virgl_renderer_context_create_fence"
        )
    }

    func createGlobalFence(fenceID: UInt64) throws {
        try Self.check(
            DoryVirglRendererCreateGlobalFence(
                try requiredSession(),
                fenceID
            ),
            "virgl_renderer_create_fence"
        )
    }

    func exportFence(fenceID: UInt64) throws -> Int32 {
        let descriptor = DoryVirglRendererGetFenceFileDescriptor(
            try requiredSession(),
            fenceID
        )
        guard descriptor >= 0 else {
            throw DoryRendererForeignSessionError.invalidResult(operation: "export-fence-fd")
        }
        return descriptor
    }

    func pollDescriptor() throws -> Int32? {
        let descriptor = DoryVirglRendererGetPollFileDescriptor(try requiredSession())
        guard descriptor >= 0 else { return nil }
        guard fcntl(descriptor, F_GETFD) >= 0 else {
            throw DoryRendererForeignSessionError.invalidResult(operation: "renderer-poll-fd")
        }
        return descriptor
    }

    func poll() {
        guard let session else { return }
        DoryVirglRendererPoll(session)
    }

    func invalidate() {
        guard let existing = session else { return }
        session = nil
        DoryVirglRendererSessionDestroy(existing)
    }

    private func requiredSession() throws -> OpaquePointer {
        guard let session else {
            throw DoryRendererForeignSessionError.invalidResult(operation: "closed-session")
        }
        return session
    }

    private static func check(_ status: Int32, _ operation: String) throws {
        guard status == 0 else {
            throw DoryRendererForeignSessionError.callFailed(
                operation: operation,
                status: status
            )
        }
    }
}
