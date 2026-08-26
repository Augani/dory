#include "DoryVirglRendererShim.h"

#include <stddef.h>

_Static_assert(sizeof(DoryVirglRendererResourceInfo) == 40,
               "virgl resource-info ABI size changed");
_Static_assert(offsetof(DoryVirglRendererResourceInfo, handle) == 0,
               "virgl resource-info handle offset changed");
_Static_assert(offsetof(DoryVirglRendererResourceInfo, tex_id) == 24,
               "virgl resource-info texture offset changed");
_Static_assert(offsetof(DoryVirglRendererResourceInfo, drm_fourcc) == 32,
               "virgl resource-info DRM format offset changed");
_Static_assert(offsetof(DoryVirglRendererResourceInfo, fd) == 36,
               "virgl resource-info file-descriptor offset changed");
_Static_assert(DORY_VIRGL_RENDERER_RESOURCE_BIND_RENDER_TARGET == (1u << 1),
               "virgl render-target resource-bind ABI changed");
_Static_assert(DORY_VIRGL_RENDERER_RESOURCE_BIND_SAMPLER_VIEW == (1u << 3),
               "virgl sampler-view resource-bind ABI changed");
_Static_assert(DORY_VIRGL_RENDERER_RESOURCE_BIND_SCANOUT == (1u << 18),
               "virgl scanout resource-bind ABI changed");

size_t DoryVirglRendererResourceInfoSize(void)
{
    return sizeof(DoryVirglRendererResourceInfo);
}

size_t DoryVirglRendererResourceInfoFileDescriptorOffset(void)
{
    return offsetof(DoryVirglRendererResourceInfo, fd);
}
