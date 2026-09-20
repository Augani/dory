#include "DoryVirglRendererShim.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stddef.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

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

int DoryCreateRendererHostVisibleArena(uint64_t byte_count)
{
    if (byte_count == 0 || byte_count > INT64_MAX) {
        errno = EINVAL;
        return -1;
    }
    int descriptor = -1;
    for (int attempt = 0; attempt < 16; ++attempt) {
        uint64_t nonce = 0;
        arc4random_buf(&nonce, sizeof(nonce));
        char name[40];
        int length = snprintf(
            name,
            sizeof(name),
            "/dory-gpu-%016llx",
            (unsigned long long)nonce
        );
        if (length <= 0 || (size_t)length >= sizeof(name)) {
            errno = EINVAL;
            return -1;
        }
        descriptor = shm_open(name, O_RDWR | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR);
        if (descriptor < 0) {
            if (errno == EEXIST) {
                continue;
            }
            return -1;
        }
        if (shm_unlink(name) != 0) {
            int saved_errno = errno;
            close(descriptor);
            errno = saved_errno;
            return -1;
        }
        break;
    }
    if (descriptor < 0) {
        errno = EEXIST;
        return -1;
    }
    int flags = fcntl(descriptor, F_GETFD);
    if (flags < 0
        || fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) != 0
        || ftruncate(descriptor, (off_t)byte_count) != 0) {
        int saved_errno = errno;
        close(descriptor);
        errno = saved_errno;
        return -1;
    }
    return descriptor;
}
