#ifndef DORY_VIRGL_RENDERER_SHIM_H
#define DORY_VIRGL_RENDERER_SHIM_H

#include <stddef.h>
#include <stdint.h>
#include <sys/uio.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * ABI mirror of virglrenderer.h's struct virgl_renderer_resource_info.
 *
 * The production worker statically links the exact qualified virglrenderer archives, but this
 * package target deliberately does not import the renderer's private build tree. Keep the foreign
 * layout in C: Swift must not reproduce it with a private struct because a missing trailing field
 * lets virglrenderer overwrite adjacent Swift storage. scripts/build-virglrenderer.sh separately
 * compiles this mirror against the pinned upstream header before publishing a renderer artifact.
 */
typedef struct DoryVirglRendererResourceInfo {
    uint32_t handle;
    uint32_t virgl_format;
    uint32_t width;
    uint32_t height;
    uint32_t depth;
    uint32_t flags;
    uint32_t tex_id;
    uint32_t stride;
    int32_t drm_fourcc;
    int fd;
} DoryVirglRendererResourceInfo;

/*
 * Exact C-owned mirrors used by the renderer worker. Swift deliberately does not reproduce any
 * virglrenderer aggregate: every writable or retained foreign record still needs a compile-checked
 * layout boundary even though the renderer is statically linked into the worker.
 */
typedef void *DoryVirglRendererGLContext;

typedef struct DoryVirglRendererGLContextParameters {
    int32_t version;
    uint8_t shared;
    uint8_t reserved[3];
    int32_t major_version;
    int32_t minor_version;
    int32_t compatibility_context;
} DoryVirglRendererGLContextParameters;

typedef struct DoryVirglRendererCallbacks {
    int32_t version;
    void (*write_fence)(void *cookie, uint32_t fence);
    DoryVirglRendererGLContext (*create_gl_context)(
        void *cookie,
        int32_t scanout_index,
        DoryVirglRendererGLContextParameters *parameters
    );
    void (*destroy_gl_context)(void *cookie, DoryVirglRendererGLContext context);
    int32_t (*make_current)(
        void *cookie,
        int32_t scanout_index,
        DoryVirglRendererGLContext context
    );
    int32_t (*get_drm_fd)(void *cookie);
    void (*write_context_fence)(
        void *cookie,
        uint32_t context_id,
        uint32_t ring_index,
        uint64_t fence_id
    );
    int32_t (*get_server_fd)(void *cookie, uint32_t version);
    void *(*get_egl_display)(void *cookie);
} DoryVirglRendererCallbacks;

typedef struct DoryVirglRendererBlobCreateArguments {
    uint32_t resource_handle;
    uint32_t context_id;
    uint32_t blob_memory;
    uint32_t blob_flags;
    uint64_t blob_id;
    uint64_t size;
    const struct iovec *iovecs;
    uint32_t iovec_count;
} DoryVirglRendererBlobCreateArguments;

typedef struct DoryVirglRendererResource3DCreateArguments {
    uint32_t handle;
    uint32_t target;
    uint32_t format;
    uint32_t bind;
    uint32_t width;
    uint32_t height;
    uint32_t depth;
    uint32_t array_size;
    uint32_t last_level;
    uint32_t samples;
    uint32_t flags;
} DoryVirglRendererResource3DCreateArguments;

typedef struct DoryVirglRendererBox {
    uint32_t x;
    uint32_t y;
    uint32_t z;
    uint32_t width;
    uint32_t height;
    uint32_t depth;
} DoryVirglRendererBox;

enum {
    /* Exact pinned virglrenderer initialization ABI for Dory's dual Metal worker. */
    DORY_VIRGL_RENDERER_USE_EGL = 1 << 0,
    DORY_VIRGL_RENDERER_THREAD_SYNC = 1 << 1,
    DORY_VIRGL_RENDERER_USE_GLES = 1 << 4,
    DORY_VIRGL_RENDERER_USE_EXTERNAL_BLOB = 1 << 5,
    DORY_VIRGL_RENDERER_VENUS = 1 << 6,
    DORY_VIRGL_RENDERER_NO_VIRGL = 1 << 7,
    DORY_VIRGL_RENDERER_ASYNC_FENCE_CALLBACK = 1 << 8,
    DORY_VIRGL_RENDERER_RENDER_SERVER = 1 << 9,
    DORY_VIRGL_RENDERER_NATIVE_SHARE_TEXTURE = 1 << 12,
    DORY_VIRGL_RENDERER_VENUS_ONLY_INITIALIZATION_FLAGS =
        DORY_VIRGL_RENDERER_THREAD_SYNC |
        DORY_VIRGL_RENDERER_USE_EXTERNAL_BLOB |
        DORY_VIRGL_RENDERER_VENUS |
        DORY_VIRGL_RENDERER_NO_VIRGL |
        DORY_VIRGL_RENDERER_ASYNC_FENCE_CALLBACK |
        DORY_VIRGL_RENDERER_RENDER_SERVER,
    DORY_VIRGL_RENDERER_DUAL_METAL_INITIALIZATION_FLAGS =
        DORY_VIRGL_RENDERER_THREAD_SYNC |
        DORY_VIRGL_RENDERER_USE_GLES |
        DORY_VIRGL_RENDERER_USE_EXTERNAL_BLOB |
        DORY_VIRGL_RENDERER_VENUS |
        DORY_VIRGL_RENDERER_NATIVE_SHARE_TEXTURE |
        DORY_VIRGL_RENDERER_ASYNC_FENCE_CALLBACK |
        DORY_VIRGL_RENDERER_RENDER_SERVER,
    DORY_VIRGL_RENDERER_CAPSET_VIRGL2 = 2,
    DORY_VIRGL_RENDERER_CAPSET_VENUS = 4,
    DORY_VIRGL_RENDERER_BLOB_MEMORY_HOST3D = 0x0002,
    DORY_VIRGL_RENDERER_BLOB_FLAG_MAPPABLE = 0x0001,
    DORY_VIRGL_RENDERER_BLOB_FLAG_SHAREABLE = 0x0002,
    DORY_VIRGL_RENDERER_BLOB_FD_TYPE_SHM = 0x0003,
    DORY_VIRGL_RENDERER_NATIVE_HANDLE_METAL_TEXTURE = 2,
    /* Exact pinned virglrenderer resource-bind ABI used by the native Metal scanout path. */
    DORY_VIRGL_RENDERER_RESOURCE_BIND_RENDER_TARGET = 1 << 1,
    DORY_VIRGL_RENDERER_RESOURCE_BIND_SAMPLER_VIEW = 1 << 3,
    DORY_VIRGL_RENDERER_RESOURCE_BIND_SCANOUT = 1 << 18,
    DORY_VIRGL_RENDERER_FORMAT_BGRA8_UNORM = 1,
    DORY_VIRGL_RENDERER_FORMAT_RGBA8_UNORM = 67,
};

typedef struct DoryVirglRendererSession DoryVirglRendererSession;

/*
 * Sanitized result of the one exact vrend decoder-error message accepted while a submit is in
 * progress. `command_id` is the pinned `enum virgl_context_cmd` ordinal after the callback has
 * matched the complete static command name; no raw renderer log bytes cross this boundary.
 */
typedef struct DoryVirglRendererSubmitDiagnostic {
    uint32_t valid;
    uint32_t context_id;
    uint32_t command_id;
    int32_t status;
    /*
     * Future exact decoder location tuple. 0 absent, 1 present, 2 ambiguous/malformed.
     * Offset is a dword index and ordinal is a zero-based command-header index. Both must match
     * the same header in a complete bounded walk before either can influence subtype reporting.
     */
    uint32_t failed_command_location_disposition;
    uint32_t failed_command_dword_offset;
    uint32_t failed_command_ordinal;
    /* 0 absent, 1 present, 2 ambiguous/malformed. Present values are pinned object types 0...11. */
    uint32_t create_object_subtype_disposition;
    uint32_t create_object_subtype;
    /* Saturating 0...255 CREATE_OBJECT header count; never a payload or stream length. */
    uint32_t create_object_candidate_count;
    /* Closed 12-bit set of pinned object types observed in CREATE_OBJECT headers. */
    uint32_t create_object_subtype_mask;
    /*
     * Closed surface-validation reason from the exact dispatch tuple. Zero is absent/unknown;
     * 1...7 are accepted only after correlation proves CREATE_OBJECT subtype SURFACE + EINVAL.
     */
    uint32_t surface_failure_reason;
    /* Closed fixed-prefix category; zero means no approved precursor was observed. */
    uint32_t precursor_category;
} DoryVirglRendererSubmitDiagnostic;

/*
 * Binds only renderer symbols resolved into the executable itself. The production target defines
 * DORY_VIRGL_RENDERER_STATIC_LINKED and force-loads the reviewed archives. Other builds fail closed
 * with ENOSYS; packaging rejects unresolved renderer symbols. No path, environment variable,
 * loader, or ICD manifest participates in renderer selection.
 */
int32_t DoryVirglRendererSessionCreate(DoryVirglRendererSession **session);
void DoryVirglRendererSessionDestroy(DoryVirglRendererSession *session);

int32_t DoryVirglRendererGetCapset(
    DoryVirglRendererSession *session,
    uint32_t capset_id,
    uint32_t *maximum_version,
    void *bytes,
    size_t capacity,
    size_t *actual_size
);
int32_t DoryVirglRendererContextCreate(
    DoryVirglRendererSession *session,
    uint32_t context_id,
    uint32_t flags,
    const char *name,
    size_t name_length
);
void DoryVirglRendererContextDestroy(
    DoryVirglRendererSession *session,
    uint32_t context_id
);
void DoryVirglRendererContextAttachResource(
    DoryVirglRendererSession *session,
    uint32_t context_id,
    uint32_t resource_id
);
void DoryVirglRendererContextDetachResource(
    DoryVirglRendererSession *session,
    uint32_t context_id,
    uint32_t resource_id
);
int32_t DoryVirglRendererSubmit(
    DoryVirglRendererSession *session,
    uint32_t context_id,
    const void *command_bytes,
    uint32_t dword_count,
    DoryVirglRendererSubmitDiagnostic *diagnostic
);
/* Pure classifier used by the production callback and focused ABI/security tests. */
int32_t DoryVirglRendererClassifySubmitDiagnosticMessage(
    const char *message,
    uint32_t expected_context_id,
    DoryVirglRendererSubmitDiagnostic *diagnostic
);
/* Exact additive machine diagnostic; returns -EINVAL for a matching prefix with invalid grammar. */
int32_t DoryVirglRendererClassifyExactSubmitDiagnosticMessage(
    const char *message,
    uint32_t expected_context_id,
    DoryVirglRendererSubmitDiagnostic *diagnostic
);
uint32_t DoryVirglRendererClassifySubmitPrecursorMessage(const char *message);
int32_t DoryVirglRendererClassifyCreateObjectSubtype(
    const void *command_bytes,
    uint32_t dword_count,
    DoryVirglRendererSubmitDiagnostic *diagnostic
);
/*
 * Correlates an already-sanitized decoder tuple against command headers only. The submitted
 * payload is neither retained nor returned. With no tuple, this preserves the legacy unique-header
 * classifier; a present tuple additionally requires exact offset + ordinal + opcode agreement.
 */
int32_t DoryVirglRendererCorrelateCreateObjectSubtype(
    const void *command_bytes,
    uint32_t dword_count,
    DoryVirglRendererSubmitDiagnostic *diagnostic
);
int32_t DoryVirglRendererBlobCreate(
    DoryVirglRendererSession *session,
    const DoryVirglRendererBlobCreateArguments *arguments
);
int32_t DoryVirglRendererResource3DCreate(
    DoryVirglRendererSession *session,
    const DoryVirglRendererResource3DCreateArguments *arguments
);
int32_t DoryVirglRendererResourceAttachBacking(
    DoryVirglRendererSession *session,
    uint32_t resource_id,
    const struct iovec *iovecs,
    uint32_t iovec_count
);
void DoryVirglRendererResourceDetachBacking(
    DoryVirglRendererSession *session,
    uint32_t resource_id
);
void DoryVirglRendererResourceUnref(
    DoryVirglRendererSession *session,
    uint32_t resource_id
);
int32_t DoryVirglRendererResourceGetMapInfo(
    DoryVirglRendererSession *session,
    uint32_t resource_id,
    uint32_t *map_info
);
int32_t DoryVirglRendererResourceExportBlob(
    DoryVirglRendererSession *session,
    uint32_t resource_id,
    uint32_t *fd_type,
    int32_t *owned_file_descriptor
);
int32_t DoryVirglRendererResourceGetInfo(
    DoryVirglRendererSession *session,
    uint32_t resource_id,
    DoryVirglRendererResourceInfo *info
);
/*
 * Transfers one retained id<MTLTexture> for a native-share scanout resource. The caller must
 * consume the returned +1 Objective-C reference exactly once. No texture pointer crosses XPC;
 * the Swift worker converts it to an MTLSharedTextureHandle first.
 */
int32_t DoryVirglRendererResourceAcquireScanoutMetalTexture(
    DoryVirglRendererSession *session,
    uint32_t resource_id,
    uint32_t width,
    uint32_t height,
    uint32_t virgl_format,
    uint32_t stride,
    uint32_t offset,
    void **retained_texture
);
int32_t DoryVirglRendererTransferToHost(
    DoryVirglRendererSession *session,
    uint32_t resource_id,
    uint32_t context_id,
    uint32_t level,
    uint32_t stride,
    uint32_t layer_stride,
    const DoryVirglRendererBox *box,
    uint64_t offset,
    const struct iovec *iovecs,
    uint32_t iovec_count
);
int32_t DoryVirglRendererTransferFromHost(
    DoryVirglRendererSession *session,
    uint32_t resource_id,
    uint32_t context_id,
    uint32_t level,
    uint32_t stride,
    uint32_t layer_stride,
    const DoryVirglRendererBox *box,
    uint64_t offset,
    const struct iovec *iovecs,
    uint32_t iovec_count
);
int32_t DoryVirglRendererCreateContextFence(
    DoryVirglRendererSession *session,
    uint32_t context_id,
    uint32_t flags,
    uint32_t ring_index,
    uint64_t fence_id
);
/*
 * Registers a classic VirGL ctx0 fence while preserving the guest's full 64-bit identity. The
 * shim allocates an independent collision-safe 32-bit renderer callback token and translates the
 * callback back to `fence_id`; callers continue to export completion by the original id.
 */
int32_t DoryVirglRendererCreateGlobalFence(
    DoryVirglRendererSession *session,
    uint64_t fence_id
);
/*
 * Transfers the read side of the shim's one-shot callback-backed completion pipe. The descriptor
 * becomes readable only after virglrenderer retires this context/ring fence; this deliberately
 * does not rely on virgl_renderer_export_fence, which is not a Venus completion API on macOS.
 */
int32_t DoryVirglRendererGetFenceFileDescriptor(
    DoryVirglRendererSession *session,
    uint64_t fence_id
);
/*
 * Returns virglrenderer's borrowed event descriptor, or -1 when Darwin selected explicit polling.
 * A nonnegative descriptor must be observed but never closed by the caller.
 */
int32_t DoryVirglRendererGetPollFileDescriptor(
    DoryVirglRendererSession *session
);
void DoryVirglRendererPoll(DoryVirglRendererSession *session);

/* Exported for a Swift test that proves it is using this imported C layout. */
size_t DoryVirglRendererResourceInfoSize(void);
size_t DoryVirglRendererResourceInfoFileDescriptorOffset(void);

#ifdef __cplusplus
}
#endif

#endif /* DORY_VIRGL_RENDERER_SHIM_H */
