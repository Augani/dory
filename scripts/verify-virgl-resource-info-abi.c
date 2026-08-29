#include <stddef.h>

#include "virglrenderer.h"
#include "virgl_hw.h"
#include "drm/drm-uapi/virtgpu_drm.h"
#include "DoryVirglRendererShim.h"

/*
 * Compile this translation unit against both the pinned virglrenderer source and Dory's runtime
 * shim. A renderer artifact must not be published if either side changes independently.
 */
_Static_assert(sizeof(struct virgl_renderer_resource_info)
                   == sizeof(DoryVirglRendererResourceInfo),
               "Dory resource-info size differs from the pinned virglrenderer ABI");
_Static_assert(offsetof(struct virgl_renderer_resource_info, handle)
                   == offsetof(DoryVirglRendererResourceInfo, handle),
               "resource-info handle offset differs");
_Static_assert(offsetof(struct virgl_renderer_resource_info, virgl_format)
                   == offsetof(DoryVirglRendererResourceInfo, virgl_format),
               "resource-info format offset differs");
_Static_assert(offsetof(struct virgl_renderer_resource_info, tex_id)
                   == offsetof(DoryVirglRendererResourceInfo, tex_id),
               "resource-info texture offset differs");
_Static_assert(offsetof(struct virgl_renderer_resource_info, drm_fourcc)
                   == offsetof(DoryVirglRendererResourceInfo, drm_fourcc),
               "resource-info DRM format offset differs");
_Static_assert(offsetof(struct virgl_renderer_resource_info, fd)
                   == offsetof(DoryVirglRendererResourceInfo, fd),
               "resource-info file-descriptor offset differs");

_Static_assert(sizeof(struct virgl_renderer_callbacks)
                   == sizeof(DoryVirglRendererCallbacks),
               "Dory callback-table size differs from the pinned virglrenderer ABI");
_Static_assert(offsetof(struct virgl_renderer_callbacks, get_egl_display)
                   == offsetof(DoryVirglRendererCallbacks, get_egl_display),
               "Dory callback-table tail offset differs");
_Static_assert(sizeof(struct virgl_renderer_gl_ctx_param)
                   == sizeof(DoryVirglRendererGLContextParameters),
               "Dory GL context parameter size differs");
_Static_assert(offsetof(struct virgl_renderer_gl_ctx_param, shared)
                   == offsetof(DoryVirglRendererGLContextParameters, shared),
               "Dory GL context shared flag offset differs");
_Static_assert(sizeof(struct virgl_renderer_resource_create_blob_args)
                   == sizeof(DoryVirglRendererBlobCreateArguments),
               "Dory blob-create size differs");
_Static_assert(offsetof(struct virgl_renderer_resource_create_blob_args, iovecs)
                   == offsetof(DoryVirglRendererBlobCreateArguments, iovecs),
               "Dory blob-create iovec offset differs");
_Static_assert(offsetof(struct virgl_renderer_resource_create_blob_args, num_iovs)
                   == offsetof(DoryVirglRendererBlobCreateArguments, iovec_count),
               "Dory blob-create iovec-count offset differs");
_Static_assert(sizeof(struct virgl_box) == sizeof(DoryVirglRendererBox),
               "Dory transfer-box size differs");
_Static_assert(offsetof(struct virgl_box, d)
                   == offsetof(DoryVirglRendererBox, depth),
               "Dory transfer-box tail offset differs");

_Static_assert(DORY_VIRGL_RENDERER_CAPSET_VIRGL2 == VIRTGPU_DRM_CAPSET_VIRGL2,
               "Dory VirGL2 capset identity differs");
_Static_assert(DORY_VIRGL_RENDERER_CAPSET_VENUS == VIRTGPU_DRM_CAPSET_VENUS,
               "Dory Venus capset identity differs");
_Static_assert(DORY_VIRGL_RENDERER_BLOB_MEMORY_HOST3D == VIRGL_RENDERER_BLOB_MEM_HOST3D,
               "Dory HOST3D identity differs");
_Static_assert(DORY_VIRGL_RENDERER_BLOB_FLAG_MAPPABLE
                   == VIRGL_RENDERER_BLOB_FLAG_USE_MAPPABLE,
               "Dory mappable blob flag differs");
_Static_assert(DORY_VIRGL_RENDERER_BLOB_FLAG_SHAREABLE
                   == VIRGL_RENDERER_BLOB_FLAG_USE_SHAREABLE,
               "Dory shareable blob flag differs");
_Static_assert(DORY_VIRGL_RENDERER_BLOB_FD_TYPE_SHM == VIRGL_RENDERER_BLOB_FD_TYPE_SHM,
               "Dory SHM blob descriptor type differs");
_Static_assert(DORY_VIRGL_RENDERER_FORMAT_BGRA8_UNORM == VIRGL_FORMAT_B8G8R8A8_UNORM,
               "Dory BGRA scanout format differs");
_Static_assert(DORY_VIRGL_RENDERER_FORMAT_RGBA8_UNORM == VIRGL_FORMAT_R8G8B8A8_UNORM,
               "Dory RGBA scanout format differs");
_Static_assert(DORY_VIRGL_RENDERER_RESOURCE_BIND_RENDER_TARGET
                   == VIRGL_RES_BIND_RENDER_TARGET,
               "Dory render-target bind bit differs");
_Static_assert(DORY_VIRGL_RENDERER_RESOURCE_BIND_SAMPLER_VIEW
                   == VIRGL_RES_BIND_SAMPLER_VIEW,
               "Dory sampler-view bind bit differs");
_Static_assert(DORY_VIRGL_RENDERER_RESOURCE_BIND_SCANOUT == VIRGL_RES_BIND_SCANOUT,
               "Dory scanout bind bit differs");
_Static_assert(DORY_VIRGL_RENDERER_THREAD_SYNC == VIRGL_RENDERER_THREAD_SYNC,
               "Dory thread-sync flag differs");
_Static_assert(DORY_VIRGL_RENDERER_ASYNC_FENCE_CALLBACK
                   == VIRGL_RENDERER_ASYNC_FENCE_CB,
               "Dory asynchronous fence-callback flag differs");
_Static_assert(DORY_VIRGL_RENDERER_RENDER_SERVER == VIRGL_RENDERER_RENDER_SERVER,
               "Dory render-server flag differs");

typedef int (*DoryExpectedInitialize)(
    void *,
    int,
    struct virgl_renderer_callbacks *
);
typedef void (*DoryExpectedCleanup)(void *);
typedef void (*DoryExpectedGetCapSet)(uint32_t, uint32_t *, uint32_t *);
typedef void (*DoryExpectedFillCaps)(uint32_t, uint32_t, void *);
typedef int (*DoryExpectedContextCreate)(uint32_t, uint32_t, uint32_t, const char *);
typedef void (*DoryExpectedContextDestroy)(uint32_t);
typedef void (*DoryExpectedContextResource)(int, int);
typedef int (*DoryExpectedSubmitCommand2)(void *, int, int, uint64_t *, uint32_t);
typedef int (*DoryExpectedBlobCreate)(
    const struct virgl_renderer_resource_create_blob_args *
);
typedef int (*DoryExpectedAttachIOV)(int, struct iovec *, int);
typedef void (*DoryExpectedDetachIOV)(int, struct iovec **, int *);
typedef void (*DoryExpectedResourceUnref)(uint32_t);
typedef int (*DoryExpectedMapInfo)(uint32_t, uint32_t *);
typedef int (*DoryExpectedResourceExportBlob)(uint32_t, uint32_t *, int *);
typedef int (*DoryExpectedResourceInfo)(
    int,
    struct virgl_renderer_resource_info *
);
typedef int (*DoryExpectedTransferWrite)(
    uint32_t,
    uint32_t,
    int,
    uint32_t,
    uint32_t,
    struct virgl_box *,
    uint64_t,
    struct iovec *,
    unsigned int
);
typedef int (*DoryExpectedTransferRead)(
    uint32_t,
    uint32_t,
    uint32_t,
    uint32_t,
    uint32_t,
    struct virgl_box *,
    uint64_t,
    struct iovec *,
    int
);
typedef int (*DoryExpectedContextCreateFence)(uint32_t, uint32_t, uint32_t, uint64_t);
typedef void (*DoryExpectedPoll)(void);

#define DORY_ASSERT_FUNCTION(symbol, expected_type) \
    _Static_assert( \
        __builtin_types_compatible_p(__typeof__(&(symbol)), expected_type), \
        #symbol " signature changed" \
    )

DORY_ASSERT_FUNCTION(virgl_renderer_init, DoryExpectedInitialize);
DORY_ASSERT_FUNCTION(virgl_renderer_cleanup, DoryExpectedCleanup);
DORY_ASSERT_FUNCTION(virgl_renderer_get_cap_set, DoryExpectedGetCapSet);
DORY_ASSERT_FUNCTION(virgl_renderer_fill_caps, DoryExpectedFillCaps);
DORY_ASSERT_FUNCTION(
    virgl_renderer_context_create_with_flags,
    DoryExpectedContextCreate
);
DORY_ASSERT_FUNCTION(virgl_renderer_context_destroy, DoryExpectedContextDestroy);
DORY_ASSERT_FUNCTION(virgl_renderer_ctx_attach_resource, DoryExpectedContextResource);
DORY_ASSERT_FUNCTION(virgl_renderer_ctx_detach_resource, DoryExpectedContextResource);
DORY_ASSERT_FUNCTION(virgl_renderer_submit_cmd2, DoryExpectedSubmitCommand2);
DORY_ASSERT_FUNCTION(virgl_renderer_resource_create_blob, DoryExpectedBlobCreate);
DORY_ASSERT_FUNCTION(virgl_renderer_resource_attach_iov, DoryExpectedAttachIOV);
DORY_ASSERT_FUNCTION(virgl_renderer_resource_detach_iov, DoryExpectedDetachIOV);
DORY_ASSERT_FUNCTION(virgl_renderer_resource_unref, DoryExpectedResourceUnref);
DORY_ASSERT_FUNCTION(virgl_renderer_resource_get_map_info, DoryExpectedMapInfo);
DORY_ASSERT_FUNCTION(
    virgl_renderer_resource_export_blob,
    DoryExpectedResourceExportBlob
);
DORY_ASSERT_FUNCTION(virgl_renderer_resource_get_info, DoryExpectedResourceInfo);
DORY_ASSERT_FUNCTION(virgl_renderer_transfer_write_iov, DoryExpectedTransferWrite);
DORY_ASSERT_FUNCTION(virgl_renderer_transfer_read_iov, DoryExpectedTransferRead);
DORY_ASSERT_FUNCTION(
    virgl_renderer_context_create_fence,
    DoryExpectedContextCreateFence
);
DORY_ASSERT_FUNCTION(virgl_renderer_poll, DoryExpectedPoll);

#undef DORY_ASSERT_FUNCTION

/* Force ordinary typed assignments as well as the Clang compatibility assertions above. */
static DoryExpectedInitialize dory_initialize = virgl_renderer_init;
static DoryExpectedCleanup dory_cleanup = virgl_renderer_cleanup;
static DoryExpectedGetCapSet dory_get_cap_set = virgl_renderer_get_cap_set;
static DoryExpectedFillCaps dory_fill_caps = virgl_renderer_fill_caps;
static DoryExpectedContextCreate dory_context_create =
    virgl_renderer_context_create_with_flags;
static DoryExpectedContextDestroy dory_context_destroy =
    virgl_renderer_context_destroy;
static DoryExpectedContextResource dory_context_attach =
    virgl_renderer_ctx_attach_resource;
static DoryExpectedContextResource dory_context_detach =
    virgl_renderer_ctx_detach_resource;
static DoryExpectedSubmitCommand2 dory_submit_cmd2 = virgl_renderer_submit_cmd2;
static DoryExpectedBlobCreate dory_blob_create = virgl_renderer_resource_create_blob;
static DoryExpectedAttachIOV dory_attach_iov = virgl_renderer_resource_attach_iov;
static DoryExpectedDetachIOV dory_detach_iov = virgl_renderer_resource_detach_iov;
static DoryExpectedResourceUnref dory_resource_unref = virgl_renderer_resource_unref;
static DoryExpectedMapInfo dory_map_info = virgl_renderer_resource_get_map_info;
static DoryExpectedResourceExportBlob dory_resource_export_blob =
    virgl_renderer_resource_export_blob;
static DoryExpectedResourceInfo dory_resource_info = virgl_renderer_resource_get_info;
static DoryExpectedTransferWrite dory_transfer_write =
    virgl_renderer_transfer_write_iov;
static DoryExpectedTransferRead dory_transfer_read =
    virgl_renderer_transfer_read_iov;
static DoryExpectedContextCreateFence dory_context_create_fence =
    virgl_renderer_context_create_fence;
static DoryExpectedPoll dory_poll = virgl_renderer_poll;

int main(void)
{
    return dory_initialize == NULL ||
        dory_cleanup == NULL ||
        dory_get_cap_set == NULL ||
        dory_fill_caps == NULL ||
        dory_context_create == NULL ||
        dory_context_destroy == NULL ||
        dory_context_attach == NULL ||
        dory_context_detach == NULL ||
        dory_submit_cmd2 == NULL ||
        dory_blob_create == NULL ||
        dory_attach_iov == NULL ||
        dory_detach_iov == NULL ||
        dory_resource_unref == NULL ||
        dory_map_info == NULL ||
        dory_resource_export_blob == NULL ||
        dory_resource_info == NULL ||
        dory_transfer_write == NULL ||
        dory_transfer_read == NULL ||
        dory_context_create_fence == NULL ||
        dory_poll == NULL;
}
