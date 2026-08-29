#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <linux/dma-buf.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <unistd.h>
#include <vulkan/vulkan.h>

#include <drm.h>
#include <drm_fourcc.h>
#include <drm_mode.h>

/* libdrm's drmModeConnection enum is a userspace wrapper around this stable UAPI value. */
#define DORY_DRM_MODE_CONNECTED 1u

#ifndef DORY_COMPOSITOR_SOURCE_COMMIT
#error DORY_COMPOSITOR_SOURCE_COMMIT must bind the probed compositor source
#endif

/* Linux 5.10 headers predate the DMA-BUF sync-file ioctls, but the guest kernel and the
 * maintained wlroots profile consume the stable UAPI. Keep the old-glibc build floor without
 * silently dropping the runtime capability check. */
#ifndef DMA_BUF_IOCTL_EXPORT_SYNC_FILE
struct dma_buf_export_sync_file {
    uint32_t flags;
    int32_t fd;
};
#define DMA_BUF_IOCTL_EXPORT_SYNC_FILE \
    _IOWR(DMA_BUF_BASE, 2, struct dma_buf_export_sync_file)
#endif

#ifndef DMA_BUF_IOCTL_IMPORT_SYNC_FILE
struct dma_buf_import_sync_file {
    uint32_t flags;
    int32_t fd;
};
#define DMA_BUF_IOCTL_IMPORT_SYNC_FILE \
    _IOW(DMA_BUF_BASE, 3, struct dma_buf_import_sync_file)
#endif

struct exported_image {
    VkImage image;
    VkDeviceMemory memory;
    int dma_buf_fd;
    VkDeviceSize allocation_size;
    VkSubresourceLayout layout;
    uint64_t modifier;
};

struct kms_framebuffer {
    int drm_fd;
    uint32_t handle;
    uint32_t framebuffer_id;
};

struct probe_extent {
    uint32_t width;
    uint32_t height;
};

struct kms_scanout {
    int drm_fd;
    uint32_t connector_id;
    struct drm_mode_crtc previous_crtc;
    struct probe_extent extent;
    int committed;
};

struct imported_image {
    VkImage image;
    VkDeviceMemory memory;
    VkImageView view;
};

struct compositor_format {
    const char *name;
    VkFormat vk_format;
    uint32_t drm_format;
};

static int fail(const char *message, VkResult result)
{
    if (result == VK_SUCCESS)
        fprintf(stderr, "dory-vulkan-compositor-probe: %s\n", message);
    else
        fprintf(stderr, "dory-vulkan-compositor-probe: %s (%d)\n", message, result);
    return 1;
}

static int fail_errno(const char *message)
{
    fprintf(stderr, "dory-vulkan-compositor-probe: %s: %s\n", message, strerror(errno));
    return 1;
}

static void report_phase(const char *phase)
{
    fprintf(stderr, "dory-vulkan-compositor-probe: phase=%s\n", phase);
    fflush(stderr);
}

static int has_extension(const VkExtensionProperties *extensions, uint32_t count,
                         const char *name)
{
    for (uint32_t i = 0; i < count; i++) {
        if (strcmp(extensions[i].extensionName, name) == 0)
            return 1;
    }
    return 0;
}

static VkExtensionProperties *instance_extensions(uint32_t *count)
{
    *count = 0;
    VkResult result = vkEnumerateInstanceExtensionProperties(NULL, count, NULL);
    if (result != VK_SUCCESS || *count == 0)
        return NULL;
    VkExtensionProperties *extensions = calloc(*count, sizeof(*extensions));
    if (!extensions)
        return NULL;
    result = vkEnumerateInstanceExtensionProperties(NULL, count, extensions);
    if (result != VK_SUCCESS) {
        free(extensions);
        return NULL;
    }
    return extensions;
}

static VkExtensionProperties *device_extensions(VkPhysicalDevice device, uint32_t *count)
{
    *count = 0;
    VkResult result = vkEnumerateDeviceExtensionProperties(device, NULL, count, NULL);
    if (result != VK_SUCCESS || *count == 0)
        return NULL;
    VkExtensionProperties *extensions = calloc(*count, sizeof(*extensions));
    if (!extensions)
        return NULL;
    result = vkEnumerateDeviceExtensionProperties(device, NULL, count, extensions);
    if (result != VK_SUCCESS) {
        free(extensions);
        return NULL;
    }
    return extensions;
}

static void destroy_kms_framebuffer(struct kms_framebuffer *framebuffer)
{
    if (framebuffer->drm_fd >= 0 && framebuffer->framebuffer_id != 0)
        (void)ioctl(framebuffer->drm_fd, DRM_IOCTL_MODE_RMFB,
                    &framebuffer->framebuffer_id);
    if (framebuffer->drm_fd >= 0 && framebuffer->handle != 0) {
        struct drm_gem_close close_handle = {.handle = framebuffer->handle};
        (void)ioctl(framebuffer->drm_fd, DRM_IOCTL_GEM_CLOSE, &close_handle);
    }
    memset(framebuffer, 0, sizeof(*framebuffer));
    framebuffer->drm_fd = -1;
}

static int import_kms_framebuffer(int drm_fd, const struct exported_image *image,
                                  const struct compositor_format *format,
                                  const struct probe_extent *extent,
                                  struct kms_framebuffer *framebuffer)
{
    *framebuffer = (struct kms_framebuffer){
        .drm_fd = drm_fd,
    };
    if (image->layout.rowPitch > UINT32_MAX || image->layout.offset > UINT32_MAX)
        return fail("Vulkan scanout layout exceeds the KMS ABI", VK_SUCCESS);

    struct drm_prime_handle prime = {
        .fd = image->dma_buf_fd,
    };
    if (ioctl(drm_fd, DRM_IOCTL_PRIME_FD_TO_HANDLE, &prime) != 0)
        return fail_errno("DRM_IOCTL_PRIME_FD_TO_HANDLE rejected the Venus DMA-BUF");
    framebuffer->handle = prime.handle;

    /* virtio-gpu scanout uses the legacy implied layout and advertises no KMS
     * framebuffer modifiers. Vulkan still owns and declares the actual LINEAR
     * allocation; KMS only imports its DMA-BUF and consumes the matching pitch. */
    struct drm_mode_fb_cmd2 command = {
        .width = extent->width,
        .height = extent->height,
        .pixel_format = format->drm_format,
        .handles = {framebuffer->handle},
        .pitches = {(uint32_t)image->layout.rowPitch},
        .offsets = {(uint32_t)image->layout.offset},
    };
    if (ioctl(drm_fd, DRM_IOCTL_MODE_ADDFB2, &command) != 0) {
        int exit_code = fail_errno("DRM_IOCTL_MODE_ADDFB2 rejected the Venus scanout");
        destroy_kms_framebuffer(framebuffer);
        return exit_code;
    }
    framebuffer->framebuffer_id = command.fb_id;
    return 0;
}

static int discover_kms_scanout(int drm_fd, struct kms_scanout *scanout)
{
    *scanout = (struct kms_scanout){
        .drm_fd = drm_fd,
    };
    struct drm_mode_card_res resources = {0};
    if (ioctl(drm_fd, DRM_IOCTL_MODE_GETRESOURCES, &resources) != 0)
        return fail_errno("DRM_IOCTL_MODE_GETRESOURCES failed");
    if (resources.count_connectors == 0 || resources.count_connectors > 64)
        return fail("KMS exposed no bounded connector set", VK_SUCCESS);

    const uint32_t capacity = resources.count_connectors;
    uint32_t *connector_ids = calloc(capacity, sizeof(*connector_ids));
    if (!connector_ids)
        return fail("out of memory", VK_ERROR_OUT_OF_HOST_MEMORY);
    resources.count_fbs = 0;
    resources.count_crtcs = 0;
    resources.count_encoders = 0;
    resources.connector_id_ptr = (uint64_t)(uintptr_t)connector_ids;
    if (ioctl(drm_fd, DRM_IOCTL_MODE_GETRESOURCES, &resources) != 0) {
        int exit_code = fail_errno("KMS connector enumeration failed");
        free(connector_ids);
        return exit_code;
    }
    if (resources.count_connectors > capacity) {
        free(connector_ids);
        return fail("KMS connector enumeration changed during discovery", VK_SUCCESS);
    }

    int found = 0;
    for (uint32_t i = 0; i < resources.count_connectors; i++) {
        struct drm_mode_get_connector connector = {
            .connector_id = connector_ids[i],
        };
        if (ioctl(drm_fd, DRM_IOCTL_MODE_GETCONNECTOR, &connector) != 0 ||
            connector.connection != DORY_DRM_MODE_CONNECTED || connector.encoder_id == 0)
            continue;
        struct drm_mode_get_encoder encoder = {
            .encoder_id = connector.encoder_id,
        };
        if (ioctl(drm_fd, DRM_IOCTL_MODE_GETENCODER, &encoder) != 0 ||
            encoder.crtc_id == 0)
            continue;
        struct drm_mode_crtc crtc = {
            .crtc_id = encoder.crtc_id,
        };
        if (ioctl(drm_fd, DRM_IOCTL_MODE_GETCRTC, &crtc) != 0 ||
            crtc.mode_valid == 0 || crtc.mode.hdisplay == 0 ||
            crtc.mode.vdisplay == 0 || crtc.mode.hdisplay > 4096 ||
            crtc.mode.vdisplay > 4096)
            continue;
        scanout->connector_id = connector.connector_id;
        scanout->previous_crtc = crtc;
        scanout->extent = (struct probe_extent){
            .width = crtc.mode.hdisplay,
            .height = crtc.mode.vdisplay,
        };
        found = 1;
        break;
    }
    free(connector_ids);
    if (!found)
        return fail("no active bounded KMS scanout is available", VK_SUCCESS);
    fprintf(stderr,
            "dory-vulkan-compositor-probe: active-scanout=%ux%u connector=%u crtc=%u\n",
            scanout->extent.width, scanout->extent.height, scanout->connector_id,
            scanout->previous_crtc.crtc_id);
    return 0;
}

static int commit_kms_scanout(struct kms_scanout *scanout,
                              const struct kms_framebuffer *framebuffer)
{
    uint32_t connector_id = scanout->connector_id;
    struct drm_mode_crtc command = {
        .set_connectors_ptr = (uint64_t)(uintptr_t)&connector_id,
        .count_connectors = 1,
        .crtc_id = scanout->previous_crtc.crtc_id,
        .fb_id = framebuffer->framebuffer_id,
        .mode_valid = 1,
        .mode = scanout->previous_crtc.mode,
    };
    if (ioctl(scanout->drm_fd, DRM_IOCTL_MODE_SETCRTC, &command) != 0)
        return fail_errno("DRM_IOCTL_MODE_SETCRTC rejected the Venus scanout");
    scanout->committed = 1;
    return 0;
}

static int restore_kms_scanout(struct kms_scanout *scanout)
{
    if (!scanout->committed)
        return 0;
    uint32_t connector_id = scanout->connector_id;
    struct drm_mode_crtc command = scanout->previous_crtc;
    command.set_connectors_ptr = (uint64_t)(uintptr_t)&connector_id;
    command.count_connectors = 1;
    if (ioctl(scanout->drm_fd, DRM_IOCTL_MODE_SETCRTC, &command) != 0)
        return fail_errno("could not restore the previous KMS scanout");
    scanout->committed = 0;
    return 0;
}

static int check_dma_buf_sync_file(int dma_buf_fd)
{
    struct dma_buf_export_sync_file export_sync = {
        .flags = DMA_BUF_SYNC_RW,
        .fd = -1,
    };
    if (ioctl(dma_buf_fd, DMA_BUF_IOCTL_EXPORT_SYNC_FILE, &export_sync) != 0)
        return fail_errno("DMA_BUF_IOCTL_EXPORT_SYNC_FILE failed");
    if (export_sync.fd < 0)
        return fail("DMA_BUF_IOCTL_EXPORT_SYNC_FILE returned no sync file", VK_SUCCESS);

    struct dma_buf_import_sync_file import_sync = {
        .flags = DMA_BUF_SYNC_RW,
        .fd = export_sync.fd,
    };
    int import_result = ioctl(dma_buf_fd, DMA_BUF_IOCTL_IMPORT_SYNC_FILE, &import_sync);
    int saved_errno = errno;
    close(export_sync.fd);
    if (import_result != 0) {
        errno = saved_errno;
        return fail_errno("DMA_BUF_IOCTL_IMPORT_SYNC_FILE failed");
    }
    return 0;
}

static int query_linear_modifier(VkPhysicalDevice physical_device,
                                 const struct compositor_format *format,
                                 const char *capability,
                                 VkImageUsageFlags usage, VkFormatFeatureFlags required_features,
                                 VkExternalMemoryProperties *external_memory)
{
    VkDrmFormatModifierPropertiesListEXT modifier_list = {
        .sType = VK_STRUCTURE_TYPE_DRM_FORMAT_MODIFIER_PROPERTIES_LIST_EXT,
    };
    VkFormatProperties2 format_properties = {
        .sType = VK_STRUCTURE_TYPE_FORMAT_PROPERTIES_2,
        .pNext = &modifier_list,
    };
    vkGetPhysicalDeviceFormatProperties2(
        physical_device, format->vk_format, &format_properties);
    if (modifier_list.drmFormatModifierCount == 0)
        return 1;

    VkDrmFormatModifierPropertiesEXT *modifiers =
        calloc(modifier_list.drmFormatModifierCount, sizeof(*modifiers));
    if (!modifiers)
        return fail("out of memory", VK_ERROR_OUT_OF_HOST_MEMORY);
    modifier_list.pDrmFormatModifierProperties = modifiers;
    vkGetPhysicalDeviceFormatProperties2(
        physical_device, format->vk_format, &format_properties);

    int found = 0;
    for (uint32_t i = 0; i < modifier_list.drmFormatModifierCount; i++) {
        fprintf(stderr,
                "dory-vulkan-compositor-probe: format=%s capability=%s modifier=0x%016" PRIx64
                " planes=%" PRIu32 " features=0x%08" PRIx32 " required=0x%08" PRIx32
                "\n",
                format->name, capability, modifiers[i].drmFormatModifier,
                modifiers[i].drmFormatModifierPlaneCount,
                modifiers[i].drmFormatModifierTilingFeatures, required_features);
        if (modifiers[i].drmFormatModifier == DRM_FORMAT_MOD_LINEAR &&
            modifiers[i].drmFormatModifierPlaneCount == 1 &&
            (modifiers[i].drmFormatModifierTilingFeatures & required_features) ==
                required_features) {
            found = 1;
            break;
        }
    }
    free(modifiers);
    if (!found) {
        fprintf(stderr,
                "dory-vulkan-compositor-probe: format=%s LINEAR lacks %s modifier features\n",
                format->name, capability);
        return 1;
    }

    VkPhysicalDeviceImageDrmFormatModifierInfoEXT modifier_info = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_DRM_FORMAT_MODIFIER_INFO_EXT,
        .drmFormatModifier = DRM_FORMAT_MOD_LINEAR,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
    };
    VkPhysicalDeviceExternalImageFormatInfo external_info = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_IMAGE_FORMAT_INFO,
        .pNext = &modifier_info,
        .handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
    };
    VkPhysicalDeviceImageFormatInfo2 image_info = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_FORMAT_INFO_2,
        .pNext = &external_info,
        .format = format->vk_format,
        .type = VK_IMAGE_TYPE_2D,
        .tiling = VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT,
        .usage = usage,
    };
    VkExternalImageFormatProperties external_properties = {
        .sType = VK_STRUCTURE_TYPE_EXTERNAL_IMAGE_FORMAT_PROPERTIES,
    };
    VkImageFormatProperties2 image_properties = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_FORMAT_PROPERTIES_2,
        .pNext = &external_properties,
    };
    VkResult result = vkGetPhysicalDeviceImageFormatProperties2(
        physical_device, &image_info, &image_properties);
    if (result != VK_SUCCESS)
        return fail("selected LINEAR external image query failed", result);
    *external_memory = external_properties.externalMemoryProperties;
    VkExternalMemoryFeatureFlags required_external_features =
        VK_EXTERNAL_MEMORY_FEATURE_IMPORTABLE_BIT |
        VK_EXTERNAL_MEMORY_FEATURE_EXPORTABLE_BIT;
    fprintf(stderr,
            "dory-vulkan-compositor-probe: format=%s capability=%s "
            "external-memory-features=0x%08" PRIx32 " required=0x%08" PRIx32 "\n",
            format->name, capability, external_memory->externalMemoryFeatures,
            required_external_features);
    if ((external_memory->externalMemoryFeatures & required_external_features) !=
        required_external_features)
        return fail("selected LINEAR DMA-BUF memory is not importable and exportable",
                    VK_SUCCESS);
    return 0;
}

static uint32_t find_memory_type(VkPhysicalDevice physical_device, uint32_t permitted)
{
    VkPhysicalDeviceMemoryProperties properties = {0};
    vkGetPhysicalDeviceMemoryProperties(physical_device, &properties);
    for (uint32_t i = 0; i < properties.memoryTypeCount; i++) {
        if ((permitted & (1u << i)) != 0)
            return i;
    }
    return UINT32_MAX;
}

static uint32_t find_memory_type_with_flags(VkPhysicalDevice physical_device,
                                            uint32_t permitted,
                                            VkMemoryPropertyFlags required)
{
    VkPhysicalDeviceMemoryProperties properties = {0};
    vkGetPhysicalDeviceMemoryProperties(physical_device, &properties);
    for (uint32_t i = 0; i < properties.memoryTypeCount; i++) {
        if ((permitted & (1u << i)) != 0 &&
            (properties.memoryTypes[i].propertyFlags & required) == required)
            return i;
    }
    return UINT32_MAX;
}

static int create_exported_image(VkPhysicalDevice physical_device, VkDevice device,
                                 const struct compositor_format *format,
                                 VkImageUsageFlags usage,
                                 const struct probe_extent *extent,
                                 struct exported_image *exported)
{
    *exported = (struct exported_image){.dma_buf_fd = -1};
    uint64_t linear_modifier = DRM_FORMAT_MOD_LINEAR;
    VkImageDrmFormatModifierListCreateInfoEXT modifier_info = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_LIST_CREATE_INFO_EXT,
        .drmFormatModifierCount = 1,
        .pDrmFormatModifiers = &linear_modifier,
    };
    VkExternalMemoryImageCreateInfo external_info = {
        .sType = VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO,
        .pNext = &modifier_info,
        .handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
    };
    VkImageCreateInfo image_info = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .pNext = &external_info,
        .imageType = VK_IMAGE_TYPE_2D,
        .format = format->vk_format,
        .extent = {extent->width, extent->height, 1},
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = VK_SAMPLE_COUNT_1_BIT,
        .tiling = VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT,
        .usage = usage,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
        .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
    };
    VkResult result = vkCreateImage(device, &image_info, NULL, &exported->image);
    if (result != VK_SUCCESS)
        return fail("vkCreateImage for the exportable LINEAR scanout failed", result);

    VkMemoryRequirements requirements = {0};
    vkGetImageMemoryRequirements(device, exported->image, &requirements);
    uint32_t memory_type = find_memory_type_with_flags(
        physical_device, requirements.memoryTypeBits,
        VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    if (memory_type == UINT32_MAX)
        memory_type = find_memory_type(physical_device, requirements.memoryTypeBits);
    if (memory_type == UINT32_MAX)
        return fail("exportable LINEAR scanout has no Venus memory type", VK_SUCCESS);

    VkExportMemoryAllocateInfo export_info = {
        .sType = VK_STRUCTURE_TYPE_EXPORT_MEMORY_ALLOCATE_INFO,
        .handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
    };
    VkMemoryDedicatedAllocateInfo dedicated_info = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO,
        .image = exported->image,
    };
    export_info.pNext = &dedicated_info;
    VkMemoryAllocateInfo allocation = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .pNext = &export_info,
        .allocationSize = requirements.size,
        .memoryTypeIndex = memory_type,
    };
    result = vkAllocateMemory(device, &allocation, NULL, &exported->memory);
    if (result != VK_SUCCESS)
        return fail("vkAllocateMemory for the exportable LINEAR scanout failed", result);
    exported->allocation_size = requirements.size;
    result = vkBindImageMemory(device, exported->image, exported->memory, 0);
    if (result != VK_SUCCESS)
        return fail("vkBindImageMemory for the exportable LINEAR scanout failed", result);

    PFN_vkGetImageDrmFormatModifierPropertiesEXT get_modifier_properties =
        (PFN_vkGetImageDrmFormatModifierPropertiesEXT)vkGetDeviceProcAddr(
            device, "vkGetImageDrmFormatModifierPropertiesEXT");
    PFN_vkGetMemoryFdKHR get_memory_fd =
        (PFN_vkGetMemoryFdKHR)vkGetDeviceProcAddr(device, "vkGetMemoryFdKHR");
    if (!get_modifier_properties || !get_memory_fd)
        return fail("required DMA-BUF export entry point is unavailable", VK_SUCCESS);

    VkImageDrmFormatModifierPropertiesEXT modifier_properties = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_PROPERTIES_EXT,
    };
    result = get_modifier_properties(device, exported->image, &modifier_properties);
    if (result != VK_SUCCESS)
        return fail("could not read the exported scanout modifier", result);
    exported->modifier = modifier_properties.drmFormatModifier;
    if (exported->modifier != DRM_FORMAT_MOD_LINEAR)
        return fail("Venus did not allocate the required LINEAR scanout", VK_SUCCESS);

    VkImageSubresource subresource = {
        .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
    };
    vkGetImageSubresourceLayout(
        device, exported->image, &subresource, &exported->layout);
    if (exported->layout.rowPitch < (VkDeviceSize)extent->width * 4 ||
        exported->layout.size == 0 ||
        exported->layout.offset + exported->layout.size > exported->allocation_size)
        return fail("Venus returned an invalid LINEAR scanout layout", VK_SUCCESS);

    VkMemoryGetFdInfoKHR fd_info = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_GET_FD_INFO_KHR,
        .memory = exported->memory,
        .handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
    };
    result = get_memory_fd(device, &fd_info, &exported->dma_buf_fd);
    if (result != VK_SUCCESS || exported->dma_buf_fd < 0)
        return fail("vkGetMemoryFdKHR could not export the LINEAR scanout", result);
    fprintf(stderr,
            "dory-vulkan-compositor-probe: exported-scanout modifier=0x%016" PRIx64
            " allocation=%" PRIu64 " offset=%" PRIu64 " pitch=%" PRIu64 "\n",
            exported->modifier, (uint64_t)exported->allocation_size,
            (uint64_t)exported->layout.offset, (uint64_t)exported->layout.rowPitch);
    return 0;
}

static void destroy_exported_image(VkDevice device, struct exported_image *exported)
{
    if (exported->dma_buf_fd >= 0)
        close(exported->dma_buf_fd);
    if (exported->image)
        vkDestroyImage(device, exported->image, NULL);
    if (exported->memory)
        vkFreeMemory(device, exported->memory, NULL);
    memset(exported, 0, sizeof(*exported));
    exported->dma_buf_fd = -1;
}

static int import_exported_image(VkPhysicalDevice physical_device, VkDevice device,
                                 const struct exported_image *exported,
                                 const struct compositor_format *format,
                                 VkImageUsageFlags usage,
                                 const struct probe_extent *extent,
                                 struct imported_image *imported)
{
    *imported = (struct imported_image){0};
    VkSubresourceLayout plane_layout = {
        .offset = exported->layout.offset,
        /* VK_EXT_image_drm_format_modifier requires importers to infer plane
         * size from the DMA-BUF, format, offset, and row pitch. */
        .size = 0,
        .rowPitch = exported->layout.rowPitch,
    };
    VkImageDrmFormatModifierExplicitCreateInfoEXT modifier_info = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_EXPLICIT_CREATE_INFO_EXT,
        .drmFormatModifier = DRM_FORMAT_MOD_LINEAR,
        .drmFormatModifierPlaneCount = 1,
        .pPlaneLayouts = &plane_layout,
    };
    VkExternalMemoryImageCreateInfo external_info = {
        .sType = VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO,
        .pNext = &modifier_info,
        .handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
    };
    VkImageCreateInfo image_info = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .pNext = &external_info,
        .imageType = VK_IMAGE_TYPE_2D,
        .format = format->vk_format,
        .extent = {extent->width, extent->height, 1},
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = VK_SAMPLE_COUNT_1_BIT,
        .tiling = VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT,
        .usage = usage,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
        .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
    };
    report_phase("dma-buf-import-create-image-begin");
    VkResult result = vkCreateImage(device, &image_info, NULL, &imported->image);
    if (result != VK_SUCCESS)
        return fail("vkCreateImage for the DRM DMA-BUF failed", result);
    report_phase("dma-buf-import-create-image-complete");

    PFN_vkGetMemoryFdPropertiesKHR get_memory_fd_properties =
        (PFN_vkGetMemoryFdPropertiesKHR)vkGetDeviceProcAddr(
            device, "vkGetMemoryFdPropertiesKHR");
    PFN_vkGetImageMemoryRequirements2KHR get_image_memory_requirements2 =
        (PFN_vkGetImageMemoryRequirements2KHR)vkGetDeviceProcAddr(
            device, "vkGetImageMemoryRequirements2KHR");
    PFN_vkBindImageMemory2KHR bind_image_memory2 =
        (PFN_vkBindImageMemory2KHR)vkGetDeviceProcAddr(device, "vkBindImageMemory2KHR");
    if (!get_memory_fd_properties || !get_image_memory_requirements2 || !bind_image_memory2)
        return fail("required external-memory entry point is unavailable", VK_SUCCESS);

    VkMemoryFdPropertiesKHR fd_properties = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_FD_PROPERTIES_KHR,
    };
    result = get_memory_fd_properties(
        device, VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT, exported->dma_buf_fd,
        &fd_properties);
    if (result != VK_SUCCESS)
        return fail("vkGetMemoryFdPropertiesKHR rejected the Venus DMA-BUF", result);
    report_phase("dma-buf-import-fd-properties-complete");

    VkImageMemoryRequirementsInfo2 requirements_info = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_REQUIREMENTS_INFO_2,
        .image = imported->image,
    };
    VkMemoryRequirements2 requirements = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_REQUIREMENTS_2,
    };
    get_image_memory_requirements2(device, &requirements_info, &requirements);
    uint32_t memory_type = find_memory_type(
        physical_device,
        requirements.memoryRequirements.memoryTypeBits & fd_properties.memoryTypeBits);
    if (memory_type == UINT32_MAX)
        return fail("DRM DMA-BUF has no compatible Venus memory type", VK_SUCCESS);

    int import_fd = fcntl(exported->dma_buf_fd, F_DUPFD_CLOEXEC, 0);
    if (import_fd < 0)
        return fail_errno("could not duplicate the DMA-BUF for Vulkan import");
    VkImportMemoryFdInfoKHR import_info = {
        .sType = VK_STRUCTURE_TYPE_IMPORT_MEMORY_FD_INFO_KHR,
        .handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
        .fd = import_fd,
    };
    VkMemoryDedicatedAllocateInfo dedicated_info = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO,
        .image = imported->image,
    };
    import_info.pNext = &dedicated_info;
    VkMemoryAllocateInfo allocate_info = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .pNext = &import_info,
        .allocationSize = requirements.memoryRequirements.size,
        .memoryTypeIndex = memory_type,
    };
    result = vkAllocateMemory(device, &allocate_info, NULL, &imported->memory);
    if (result != VK_SUCCESS) {
        close(import_fd);
        return fail("vkAllocateMemory could not import the DRM DMA-BUF", result);
    }
    report_phase("dma-buf-import-memory-allocation-complete");

    VkBindImageMemoryInfo bind_info = {
        .sType = VK_STRUCTURE_TYPE_BIND_IMAGE_MEMORY_INFO,
        .image = imported->image,
        .memory = imported->memory,
    };
    result = bind_image_memory2(device, 1, &bind_info);
    if (result != VK_SUCCESS)
        return fail("vkBindImageMemory2KHR could not bind the DRM DMA-BUF", result);
    report_phase("dma-buf-import-bind-complete");

    if ((usage & (VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_SAMPLED_BIT)) == 0)
        return 0;

    VkImageViewCreateInfo view_info = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .image = imported->image,
        .viewType = VK_IMAGE_VIEW_TYPE_2D,
        .format = format->vk_format,
        .subresourceRange = {
            .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
            .levelCount = 1,
            .layerCount = 1,
        },
    };
    result = vkCreateImageView(device, &view_info, NULL, &imported->view);
    if (result != VK_SUCCESS)
        return fail("vkCreateImageView for the DRM DMA-BUF failed", result);
    return 0;
}

static void destroy_imported_image(VkDevice device, struct imported_image *imported)
{
    if (imported->view)
        vkDestroyImageView(device, imported->view, NULL);
    if (imported->image)
        vkDestroyImage(device, imported->image, NULL);
    if (imported->memory)
        vkFreeMemory(device, imported->memory, NULL);
    memset(imported, 0, sizeof(*imported));
}

static int render_and_copy_to_scanout(VkPhysicalDevice physical_device,
                                      VkDevice device, VkQueue queue,
                                      uint32_t queue_family,
                                      VkImage scanout_image,
                                      const struct compositor_format *format,
                                      const struct probe_extent *extent)
{
    VkImage render_image = VK_NULL_HANDLE;
    VkDeviceMemory render_memory = VK_NULL_HANDLE;
    VkImageView render_view = VK_NULL_HANDLE;
    VkRenderPass render_pass = VK_NULL_HANDLE;
    VkFramebuffer framebuffer = VK_NULL_HANDLE;
    VkCommandPool command_pool = VK_NULL_HANDLE;
    VkFence fence = VK_NULL_HANDLE;
    VkBuffer readback_buffer = VK_NULL_HANDLE;
    VkDeviceMemory readback_memory = VK_NULL_HANDLE;
    VkDeviceSize readback_allocation_size = 0;
    VkMemoryPropertyFlags readback_memory_flags = 0;
    int pixel_match = 1;
    VkResult result = VK_ERROR_INITIALIZATION_FAILED;
    VkDeviceSize pixel_bytes =
        (VkDeviceSize)extent->width * (VkDeviceSize)extent->height * 4;

    VkImageCreateInfo render_image_info = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .imageType = VK_IMAGE_TYPE_2D,
        .format = format->vk_format,
        .extent = {extent->width, extent->height, 1},
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = VK_SAMPLE_COUNT_1_BIT,
        .tiling = VK_IMAGE_TILING_OPTIMAL,
        .usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
        .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
    };
    result = vkCreateImage(device, &render_image_info, NULL, &render_image);
    if (result != VK_SUCCESS)
        goto cleanup;
    VkMemoryRequirements render_requirements = {0};
    vkGetImageMemoryRequirements(device, render_image, &render_requirements);
    uint32_t render_memory_type = find_memory_type_with_flags(
        physical_device, render_requirements.memoryTypeBits,
        VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    if (render_memory_type == UINT32_MAX) {
        result = VK_ERROR_FEATURE_NOT_PRESENT;
        goto cleanup;
    }
    VkMemoryAllocateInfo render_allocation = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = render_requirements.size,
        .memoryTypeIndex = render_memory_type,
    };
    result = vkAllocateMemory(device, &render_allocation, NULL, &render_memory);
    if (result != VK_SUCCESS)
        goto cleanup;
    result = vkBindImageMemory(device, render_image, render_memory, 0);
    if (result != VK_SUCCESS)
        goto cleanup;
    VkImageViewCreateInfo render_view_info = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .image = render_image,
        .viewType = VK_IMAGE_VIEW_TYPE_2D,
        .format = format->vk_format,
        .subresourceRange = {
            .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
            .levelCount = 1,
            .layerCount = 1,
        },
    };
    result = vkCreateImageView(device, &render_view_info, NULL, &render_view);
    if (result != VK_SUCCESS)
        goto cleanup;

    VkAttachmentDescription attachment = {
        .format = format->vk_format,
        .samples = VK_SAMPLE_COUNT_1_BIT,
        .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
        .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
        .stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
        .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
        .finalLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
    };
    VkAttachmentReference color_attachment = {
        .attachment = 0,
        .layout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
    };
    VkSubpassDescription subpass = {
        .pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS,
        .colorAttachmentCount = 1,
        .pColorAttachments = &color_attachment,
    };
    VkRenderPassCreateInfo render_pass_info = {
        .sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
        .attachmentCount = 1,
        .pAttachments = &attachment,
        .subpassCount = 1,
        .pSubpasses = &subpass,
    };
    result = vkCreateRenderPass(device, &render_pass_info, NULL, &render_pass);
    if (result != VK_SUCCESS)
        goto cleanup;

    VkFramebufferCreateInfo framebuffer_info = {
        .sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
        .renderPass = render_pass,
        .attachmentCount = 1,
        .pAttachments = &render_view,
        .width = extent->width,
        .height = extent->height,
        .layers = 1,
    };
    result = vkCreateFramebuffer(device, &framebuffer_info, NULL, &framebuffer);
    if (result != VK_SUCCESS)
        goto cleanup;

    VkBufferCreateInfo readback_buffer_info = {
        .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = pixel_bytes,
        .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
    };
    result = vkCreateBuffer(device, &readback_buffer_info, NULL, &readback_buffer);
    if (result != VK_SUCCESS)
        goto cleanup;
    VkMemoryRequirements readback_requirements = {0};
    vkGetBufferMemoryRequirements(device, readback_buffer, &readback_requirements);
    uint32_t readback_memory_type = find_memory_type_with_flags(
        physical_device, readback_requirements.memoryTypeBits,
        VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    if (readback_memory_type == UINT32_MAX)
        readback_memory_type = find_memory_type_with_flags(
            physical_device, readback_requirements.memoryTypeBits,
            VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT);
    if (readback_memory_type == UINT32_MAX) {
        result = VK_ERROR_FEATURE_NOT_PRESENT;
        goto cleanup;
    }
    VkPhysicalDeviceMemoryProperties memory_properties = {0};
    vkGetPhysicalDeviceMemoryProperties(physical_device, &memory_properties);
    readback_memory_flags =
        memory_properties.memoryTypes[readback_memory_type].propertyFlags;
    VkMemoryAllocateInfo readback_allocation = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = readback_requirements.size,
        .memoryTypeIndex = readback_memory_type,
    };
    result = vkAllocateMemory(device, &readback_allocation, NULL, &readback_memory);
    if (result != VK_SUCCESS)
        goto cleanup;
    readback_allocation_size = readback_requirements.size;
    result = vkBindBufferMemory(device, readback_buffer, readback_memory, 0);
    if (result != VK_SUCCESS)
        goto cleanup;

    VkCommandPoolCreateInfo pool_info = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = VK_COMMAND_POOL_CREATE_TRANSIENT_BIT,
        .queueFamilyIndex = queue_family,
    };
    result = vkCreateCommandPool(device, &pool_info, NULL, &command_pool);
    if (result != VK_SUCCESS)
        goto cleanup;
    VkCommandBufferAllocateInfo allocate_info = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = command_pool,
        .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    };
    VkCommandBuffer command_buffer = VK_NULL_HANDLE;
    result = vkAllocateCommandBuffers(device, &allocate_info, &command_buffer);
    if (result != VK_SUCCESS)
        goto cleanup;
    VkCommandBufferBeginInfo begin_info = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    };
    result = vkBeginCommandBuffer(command_buffer, &begin_info);
    if (result != VK_SUCCESS)
        goto cleanup;
    VkClearValue clear = {.color = {.float32 = {0.0f, 0.25f, 0.75f, 1.0f}}};
    VkRenderPassBeginInfo pass_begin = {
        .sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
        .renderPass = render_pass,
        .framebuffer = framebuffer,
        .renderArea = {.extent = {extent->width, extent->height}},
        .clearValueCount = 1,
        .pClearValues = &clear,
    };
    vkCmdBeginRenderPass(command_buffer, &pass_begin, VK_SUBPASS_CONTENTS_INLINE);
    vkCmdEndRenderPass(command_buffer);
    VkImageMemoryBarrier acquire_scanout = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
        .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED,
        .newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image = scanout_image,
        .subresourceRange = {
            .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
            .levelCount = 1,
            .layerCount = 1,
        },
    };
    vkCmdPipelineBarrier(command_buffer, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                         VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL,
                         1, &acquire_scanout);
    VkImageCopy copy_region = {
        .srcSubresource = {
            .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
            .layerCount = 1,
        },
        .dstSubresource = {
            .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
            .layerCount = 1,
        },
        .extent = {extent->width, extent->height, 1},
    };
    vkCmdCopyImage(command_buffer, render_image,
                   VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                   scanout_image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                   1, &copy_region);
    VkImageMemoryBarrier read_scanout = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
        .dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT,
        .oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        .newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image = scanout_image,
        .subresourceRange = {
            .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
            .levelCount = 1,
            .layerCount = 1,
        },
    };
    vkCmdPipelineBarrier(command_buffer, VK_PIPELINE_STAGE_TRANSFER_BIT,
                         VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL,
                         1, &read_scanout);
    VkBufferImageCopy readback_region = {
        .imageSubresource = {
            .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
            .layerCount = 1,
        },
        .imageExtent = {extent->width, extent->height, 1},
    };
    vkCmdCopyImageToBuffer(command_buffer, scanout_image,
                           VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                           readback_buffer, 1, &readback_region);
    VkBufferMemoryBarrier expose_readback = {
        .sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER,
        .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
        .dstAccessMask = VK_ACCESS_HOST_READ_BIT,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .buffer = readback_buffer,
        .size = VK_WHOLE_SIZE,
    };
    vkCmdPipelineBarrier(command_buffer, VK_PIPELINE_STAGE_TRANSFER_BIT,
                         VK_PIPELINE_STAGE_HOST_BIT, 0, 0, NULL, 1,
                         &expose_readback, 0, NULL);
    VkImageMemoryBarrier release_scanout = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .srcAccessMask = VK_ACCESS_TRANSFER_READ_BIT,
        .oldLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        .newLayout = VK_IMAGE_LAYOUT_GENERAL,
        .srcQueueFamilyIndex = queue_family,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_FOREIGN_EXT,
        .image = scanout_image,
        .subresourceRange = {
            .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
            .levelCount = 1,
            .layerCount = 1,
        },
    };
    vkCmdPipelineBarrier(command_buffer, VK_PIPELINE_STAGE_TRANSFER_BIT,
                         VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0, 0, NULL,
                         0, NULL, 1, &release_scanout);
    result = vkEndCommandBuffer(command_buffer);
    if (result != VK_SUCCESS)
        goto cleanup;

    PFN_vkQueueSubmit2KHR queue_submit2 =
        (PFN_vkQueueSubmit2KHR)vkGetDeviceProcAddr(device, "vkQueueSubmit2KHR");
    if (!queue_submit2) {
        result = VK_ERROR_EXTENSION_NOT_PRESENT;
        goto cleanup;
    }
    VkCommandBufferSubmitInfo command_submit = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO,
        .commandBuffer = command_buffer,
    };
    VkSubmitInfo2 submit = {
        .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO_2,
        .commandBufferInfoCount = 1,
        .pCommandBufferInfos = &command_submit,
    };
    VkFenceCreateInfo fence_info = {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
    result = vkCreateFence(device, &fence_info, NULL, &fence);
    if (result == VK_SUCCESS)
        result = queue_submit2(queue, 1, &submit, fence);
    if (result == VK_SUCCESS)
        result = vkWaitForFences(device, 1, &fence, VK_TRUE, 5ULL * 1000 * 1000 * 1000);
    if (result == VK_SUCCESS) {
        void *mapping = NULL;
        result = vkMapMemory(
            device, readback_memory, 0, readback_allocation_size, 0, &mapping);
        if (result == VK_SUCCESS &&
            (readback_memory_flags & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) == 0) {
            VkMappedMemoryRange range = {
                .sType = VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE,
                .memory = readback_memory,
                .size = VK_WHOLE_SIZE,
            };
            result = vkInvalidateMappedMemoryRanges(device, 1, &range);
        }
        if (result == VK_SUCCESS) {
            VkDeviceSize center_offset =
                ((VkDeviceSize)(extent->height / 2) * extent->width +
                 extent->width / 2) * 4;
            const uint8_t *pixel = (const uint8_t *)mapping + center_offset;
            uint8_t expected[4] = {0};
            if (format->vk_format == VK_FORMAT_B8G8R8A8_UNORM) {
                expected[0] = 191;
                expected[1] = 64;
                expected[2] = 0;
                expected[3] = 255;
            } else {
                expected[0] = 0;
                expected[1] = 64;
                expected[2] = 191;
                expected[3] = 255;
            }
            fprintf(stderr,
                    "dory-vulkan-compositor-probe: format=%s copied-pixel=%u,%u,%u,%u "
                    "expected=%u,%u,%u,%u readback=vulkan-staging\n",
                    format->name, pixel[0], pixel[1], pixel[2], pixel[3],
                    expected[0], expected[1], expected[2], expected[3]);
            for (uint32_t i = 0; i < 4; i++) {
                int difference = (int)pixel[i] - (int)expected[i];
                if (difference < -2 || difference > 2) {
                    pixel_match = 0;
                    break;
                }
            }
        }
        if (mapping)
            vkUnmapMemory(device, readback_memory);
    }

cleanup:
    if (fence)
        vkDestroyFence(device, fence, NULL);
    if (command_pool)
        vkDestroyCommandPool(device, command_pool, NULL);
    if (framebuffer)
        vkDestroyFramebuffer(device, framebuffer, NULL);
    if (readback_buffer)
        vkDestroyBuffer(device, readback_buffer, NULL);
    if (readback_memory)
        vkFreeMemory(device, readback_memory, NULL);
    if (render_pass)
        vkDestroyRenderPass(device, render_pass, NULL);
    if (render_view)
        vkDestroyImageView(device, render_view, NULL);
    if (render_image)
        vkDestroyImage(device, render_image, NULL);
    if (render_memory)
        vkFreeMemory(device, render_memory, NULL);
    if (result != VK_SUCCESS)
        return fail("optimal render to exported LINEAR scanout copy failed", result);
    if (!pixel_match)
        return fail("Vulkan scanout readback differs from the optimal render", VK_SUCCESS);
    return 0;
}

int main(int argc, char **argv)
{
    const char *drm_path = "/dev/dri/card0";
    if (argc == 2 && strncmp(argv[1], "--drm=", 6) == 0 && argv[1][6] != '\0')
        drm_path = argv[1] + 6;
    else if (argc != 1) {
        fprintf(stderr, "usage: %s [--drm=/dev/dri/cardN]\n", argv[0]);
        return 64;
    }

    int exit_code = 1;
    int drm_fd = -1;
    VkInstance instance = VK_NULL_HANDLE;
    VkDevice device = VK_NULL_HANDLE;
    struct exported_image scanout_image = {.dma_buf_fd = -1};
    struct kms_framebuffer kms_framebuffer = {.drm_fd = -1};
    struct kms_scanout kms_scanout = {.drm_fd = -1};
    struct imported_image texture_image = {0};

    drm_fd = open(drm_path, O_RDWR | O_NONBLOCK | O_CLOEXEC);
    if (drm_fd < 0)
        return fail_errno("could not open the compositor DRM node");
    struct stat drm_stat = {0};
    if (fstat(drm_fd, &drm_stat) != 0 || !S_ISCHR(drm_stat.st_mode)) {
        exit_code = fail_errno("could not identify the compositor DRM node");
        goto cleanup;
    }
    exit_code = discover_kms_scanout(drm_fd, &kms_scanout);
    if (exit_code != 0)
        goto cleanup;

    uint32_t instance_extension_count = 0;
    VkExtensionProperties *available_instance_extensions =
        instance_extensions(&instance_extension_count);
    if (!available_instance_extensions) {
        exit_code = fail("could not enumerate Vulkan instance extensions", VK_SUCCESS);
        goto cleanup;
    }
    const char *required_instance_extensions[] = {
        VK_KHR_GET_PHYSICAL_DEVICE_PROPERTIES_2_EXTENSION_NAME,
        VK_KHR_EXTERNAL_SEMAPHORE_CAPABILITIES_EXTENSION_NAME,
        VK_KHR_EXTERNAL_MEMORY_CAPABILITIES_EXTENSION_NAME,
    };
    for (uint32_t i = 0; i < sizeof(required_instance_extensions) /
                                sizeof(required_instance_extensions[0]); i++) {
        if (!has_extension(available_instance_extensions, instance_extension_count,
                           required_instance_extensions[i])) {
            fprintf(stderr, "dory-vulkan-compositor-probe: missing instance extension %s\n",
                    required_instance_extensions[i]);
            free(available_instance_extensions);
            goto cleanup;
        }
    }
    free(available_instance_extensions);

    VkApplicationInfo application = {
        .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "dory-vulkan-compositor-probe",
        .applicationVersion = 1,
        .pEngineName = "Dory",
        .engineVersion = 1,
        .apiVersion = VK_API_VERSION_1_0,
    };
    VkInstanceCreateInfo instance_info = {
        .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = &application,
        .enabledExtensionCount = (uint32_t)(sizeof(required_instance_extensions) /
                                            sizeof(required_instance_extensions[0])),
        .ppEnabledExtensionNames = required_instance_extensions,
    };
    VkResult result = vkCreateInstance(&instance_info, NULL, &instance);
    if (result != VK_SUCCESS) {
        exit_code = fail("vkCreateInstance for the compositor profile failed", result);
        goto cleanup;
    }

    uint32_t physical_device_count = 0;
    result = vkEnumeratePhysicalDevices(instance, &physical_device_count, NULL);
    if (result != VK_SUCCESS || physical_device_count == 0) {
        exit_code = fail("no Vulkan physical device", result);
        goto cleanup;
    }
    VkPhysicalDevice *physical_devices =
        calloc(physical_device_count, sizeof(*physical_devices));
    if (!physical_devices) {
        exit_code = fail("out of memory", VK_ERROR_OUT_OF_HOST_MEMORY);
        goto cleanup;
    }
    result = vkEnumeratePhysicalDevices(instance, &physical_device_count, physical_devices);
    if (result != VK_SUCCESS) {
        free(physical_devices);
        exit_code = fail("physical-device enumeration failed", result);
        goto cleanup;
    }

    const char *required_device_extensions[] = {
        VK_KHR_EXTERNAL_MEMORY_FD_EXTENSION_NAME,
        VK_KHR_IMAGE_FORMAT_LIST_EXTENSION_NAME,
        VK_EXT_EXTERNAL_MEMORY_DMA_BUF_EXTENSION_NAME,
        VK_EXT_QUEUE_FAMILY_FOREIGN_EXTENSION_NAME,
        VK_EXT_IMAGE_DRM_FORMAT_MODIFIER_EXTENSION_NAME,
        VK_KHR_TIMELINE_SEMAPHORE_EXTENSION_NAME,
        VK_KHR_SYNCHRONIZATION_2_EXTENSION_NAME,
        VK_KHR_EXTERNAL_MEMORY_EXTENSION_NAME,
        VK_KHR_BIND_MEMORY_2_EXTENSION_NAME,
        VK_KHR_SAMPLER_YCBCR_CONVERSION_EXTENSION_NAME,
        VK_KHR_EXTERNAL_SEMAPHORE_EXTENSION_NAME,
        VK_KHR_MAINTENANCE_1_EXTENSION_NAME,
        VK_KHR_GET_MEMORY_REQUIREMENTS_2_EXTENSION_NAME,
        VK_KHR_DEDICATED_ALLOCATION_EXTENSION_NAME,
    };
    VkPhysicalDevice physical_device = VK_NULL_HANDLE;
    VkPhysicalDeviceProperties2 selected_properties = {0};
    VkPhysicalDeviceDriverProperties selected_driver = {0};
    uint32_t queue_family = UINT32_MAX;
    for (uint32_t i = 0; i < physical_device_count; i++) {
        uint32_t extension_count = 0;
        VkExtensionProperties *extensions =
            device_extensions(physical_devices[i], &extension_count);
        if (!extensions)
            continue;
        if (!has_extension(extensions, extension_count,
                           VK_EXT_PHYSICAL_DEVICE_DRM_EXTENSION_NAME) ||
            !has_extension(extensions, extension_count,
                           VK_KHR_DRIVER_PROPERTIES_EXTENSION_NAME)) {
            free(extensions);
            continue;
        }
        int missing_extension = 0;
        for (uint32_t j = 0; j < sizeof(required_device_extensions) /
                                     sizeof(required_device_extensions[0]); j++) {
            if (!has_extension(extensions, extension_count, required_device_extensions[j])) {
                fprintf(stderr,
                        "dory-vulkan-compositor-probe: missing device extension %s\n",
                        required_device_extensions[j]);
                missing_extension = 1;
            }
        }
        if (!has_extension(extensions, extension_count,
                           VK_KHR_EXTERNAL_SEMAPHORE_FD_EXTENSION_NAME)) {
            fprintf(stderr,
                    "dory-vulkan-compositor-probe: missing device extension %s\n",
                    VK_KHR_EXTERNAL_SEMAPHORE_FD_EXTENSION_NAME);
            missing_extension = 1;
        }
        free(extensions);
        if (missing_extension)
            continue;

        VkPhysicalDeviceDrmPropertiesEXT drm_properties = {
            .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRM_PROPERTIES_EXT,
        };
        VkPhysicalDeviceDriverProperties driver_properties = {
            .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES,
            .pNext = &drm_properties,
        };
        VkPhysicalDeviceProperties2 properties = {
            .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2,
            .pNext = &driver_properties,
        };
        vkGetPhysicalDeviceProperties2(physical_devices[i], &properties);
        if (strcmp(driver_properties.driverName, "venus") != 0 ||
            properties.properties.deviceType == VK_PHYSICAL_DEVICE_TYPE_CPU)
            continue;
        dev_t primary_device = makedev(
            drm_properties.primaryMajor, drm_properties.primaryMinor);
        dev_t render_device = makedev(drm_properties.renderMajor, drm_properties.renderMinor);
        if ((!drm_properties.hasPrimary || primary_device != drm_stat.st_rdev) &&
            (!drm_properties.hasRender || render_device != drm_stat.st_rdev))
            continue;

        VkPhysicalDeviceSamplerYcbcrConversionFeatures ycbcr = {
            .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SAMPLER_YCBCR_CONVERSION_FEATURES,
        };
        VkPhysicalDeviceSynchronization2Features synchronization2 = {
            .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SYNCHRONIZATION_2_FEATURES,
            .pNext = &ycbcr,
        };
        VkPhysicalDeviceTimelineSemaphoreFeatures timeline = {
            .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TIMELINE_SEMAPHORE_FEATURES,
            .pNext = &synchronization2,
        };
        VkPhysicalDeviceFeatures2 features = {
            .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,
            .pNext = &timeline,
        };
        vkGetPhysicalDeviceFeatures2(physical_devices[i], &features);
        if (!timeline.timelineSemaphore || !synchronization2.synchronization2)
            continue;

        uint32_t queue_count = 0;
        vkGetPhysicalDeviceQueueFamilyProperties(physical_devices[i], &queue_count, NULL);
        VkQueueFamilyProperties *queues = calloc(queue_count, sizeof(*queues));
        if (!queues)
            continue;
        vkGetPhysicalDeviceQueueFamilyProperties(
            physical_devices[i], &queue_count, queues);
        uint32_t candidate_queue = UINT32_MAX;
        for (uint32_t j = 0; j < queue_count; j++) {
            if (queues[j].queueCount > 0 &&
                (queues[j].queueFlags & VK_QUEUE_GRAPHICS_BIT) != 0) {
                candidate_queue = j;
                break;
            }
        }
        free(queues);
        if (candidate_queue == UINT32_MAX)
            continue;

        physical_device = physical_devices[i];
        selected_properties = properties;
        selected_driver = driver_properties;
        queue_family = candidate_queue;
        break;
    }
    free(physical_devices);
    if (physical_device == VK_NULL_HANDLE) {
        exit_code = fail("no Venus device matches the DRM node and compositor profile",
                         VK_SUCCESS);
        goto cleanup;
    }

    VkPhysicalDeviceExternalSemaphoreInfo semaphore_info = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_SEMAPHORE_INFO,
        .handleType = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT,
    };
    VkExternalSemaphoreProperties semaphore_properties = {
        .sType = VK_STRUCTURE_TYPE_EXTERNAL_SEMAPHORE_PROPERTIES,
    };
    vkGetPhysicalDeviceExternalSemaphoreProperties(
        physical_device, &semaphore_info, &semaphore_properties);
    VkExternalSemaphoreFeatureFlags required_semaphore_features =
        VK_EXTERNAL_SEMAPHORE_FEATURE_IMPORTABLE_BIT |
        VK_EXTERNAL_SEMAPHORE_FEATURE_EXPORTABLE_BIT;
    if ((semaphore_properties.externalSemaphoreFeatures & required_semaphore_features) !=
        required_semaphore_features) {
        exit_code = fail("SYNC_FD semaphore import/export is unavailable", VK_SUCCESS);
        goto cleanup;
    }

    const struct compositor_format candidate_formats[] = {
        {
            .name = "xrgb8888/bgra8-unorm",
            .vk_format = VK_FORMAT_B8G8R8A8_UNORM,
            .drm_format = DRM_FORMAT_XRGB8888,
        },
        {
            .name = "xbgr8888/rgba8-unorm",
            .vk_format = VK_FORMAT_R8G8B8A8_UNORM,
            .drm_format = DRM_FORMAT_XBGR8888,
        },
    };
    const struct compositor_format *selected_format = NULL;
    VkImageUsageFlags shared_linear_usage =
        VK_IMAGE_USAGE_TRANSFER_DST_BIT |
        VK_IMAGE_USAGE_SAMPLED_BIT |
        VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
    for (uint32_t i = 0; i < sizeof(candidate_formats) / sizeof(candidate_formats[0]); i++) {
        VkFormatProperties format_properties = {0};
        vkGetPhysicalDeviceFormatProperties(
            physical_device, candidate_formats[i].vk_format, &format_properties);
        VkFormatFeatureFlags required_optimal_features =
            VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT |
            VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BLEND_BIT |
            VK_FORMAT_FEATURE_TRANSFER_SRC_BIT;
        fprintf(stderr,
                "dory-vulkan-compositor-probe: format=%s capability=optimal-render "
                "features=0x%08" PRIx32 " required=0x%08" PRIx32 "\n",
                candidate_formats[i].name, format_properties.optimalTilingFeatures,
                required_optimal_features);
        if ((format_properties.optimalTilingFeatures & required_optimal_features) !=
            required_optimal_features)
            continue;
        VkExternalMemoryProperties shared_external_memory = {0};
        if (query_linear_modifier(
                physical_device, &candidate_formats[i], "scanout-copy-and-texture",
                shared_linear_usage,
                VK_FORMAT_FEATURE_TRANSFER_DST_BIT |
                    VK_FORMAT_FEATURE_TRANSFER_SRC_BIT |
                    VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT |
                    VK_FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR_BIT,
                &shared_external_memory) != 0)
            continue;
        selected_format = &candidate_formats[i];
        break;
    }
    if (!selected_format) {
        exit_code = fail("no admitted LINEAR format joins KMS and the Vulkan compositor",
                         VK_SUCCESS);
        goto cleanup;
    }
    VkPhysicalDeviceSamplerYcbcrConversionFeatures enabled_ycbcr = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SAMPLER_YCBCR_CONVERSION_FEATURES,
    };
    VkPhysicalDeviceSynchronization2Features enabled_synchronization2 = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_SYNCHRONIZATION_2_FEATURES,
        .pNext = &enabled_ycbcr,
        .synchronization2 = VK_TRUE,
    };
    VkPhysicalDeviceTimelineSemaphoreFeatures enabled_timeline = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TIMELINE_SEMAPHORE_FEATURES,
        .pNext = &enabled_synchronization2,
        .timelineSemaphore = VK_TRUE,
    };
    const float queue_priority = 1.0f;
    VkDeviceQueueCreateInfo queue_info = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = queue_family,
        .queueCount = 1,
        .pQueuePriorities = &queue_priority,
    };
    const char *enabled_device_extensions[
        sizeof(required_device_extensions) / sizeof(required_device_extensions[0]) + 1];
    uint32_t enabled_device_extension_count = 0;
    for (uint32_t i = 0; i < sizeof(required_device_extensions) /
                                sizeof(required_device_extensions[0]); i++)
        enabled_device_extensions[enabled_device_extension_count++] =
            required_device_extensions[i];
    enabled_device_extensions[enabled_device_extension_count++] =
        VK_KHR_EXTERNAL_SEMAPHORE_FD_EXTENSION_NAME;
    VkDeviceCreateInfo device_info = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .pNext = &enabled_timeline,
        .queueCreateInfoCount = 1,
        .pQueueCreateInfos = &queue_info,
        .enabledExtensionCount = enabled_device_extension_count,
        .ppEnabledExtensionNames = enabled_device_extensions,
    };
    report_phase("device-create-begin");
    result = vkCreateDevice(physical_device, &device_info, NULL, &device);
    if (result != VK_SUCCESS) {
        exit_code = fail("vkCreateDevice for the compositor profile failed", result);
        goto cleanup;
    }
    report_phase("device-create-complete");
    VkQueue queue = VK_NULL_HANDLE;
    vkGetDeviceQueue(device, queue_family, 0, &queue);

    report_phase("venus-scanout-export-begin");
    exit_code = create_exported_image(
        physical_device, device, selected_format, shared_linear_usage,
        &kms_scanout.extent, &scanout_image);
    if (exit_code != 0)
        goto cleanup;
    report_phase("venus-scanout-export-complete");
    exit_code = check_dma_buf_sync_file(scanout_image.dma_buf_fd);
    if (exit_code != 0)
        goto cleanup;
    report_phase("dma-buf-sync-file-complete");
    exit_code = import_kms_framebuffer(
        drm_fd, &scanout_image, selected_format, &kms_scanout.extent,
        &kms_framebuffer);
    if (exit_code != 0)
        goto cleanup;
    report_phase("kms-framebuffer-admitted");
    report_phase("optimal-render-copy-begin");
    exit_code = render_and_copy_to_scanout(
        physical_device, device, queue, queue_family,
        scanout_image.image, selected_format, &kms_scanout.extent);
    if (exit_code != 0)
        goto cleanup;
    report_phase("optimal-render-copy-complete");
    report_phase("optimal-render-copy-readback-complete");
    report_phase("texture-import-begin");
    exit_code = import_exported_image(
        physical_device, device, &scanout_image, selected_format,
        VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
        &kms_scanout.extent, &texture_image);
    if (exit_code != 0)
        goto cleanup;
    report_phase("texture-import-complete");
    report_phase("kms-scanout-commit-begin");
    exit_code = commit_kms_scanout(&kms_scanout, &kms_framebuffer);
    if (exit_code != 0)
        goto cleanup;
    report_phase("kms-scanout-commit-complete");
    sleep(2);
    exit_code = restore_kms_scanout(&kms_scanout);
    if (exit_code != 0)
        goto cleanup;
    report_phase("kms-scanout-restore-complete");

    printf("contract=native-vulkan-optimal-copy-compositor-v2\n");
    printf("profile=wlroots-vulkan-optimal-copy@%s\n", DORY_COMPOSITOR_SOURCE_COMMIT);
    printf("device=%s\n", selected_properties.properties.deviceName);
    printf("driver=%s\n", selected_driver.driverName);
    printf("format=%s\n", selected_format->name);
    printf("drm-node=%s\n", drm_path);
    printf("drm-device-match=yes\n");
    printf("required-instance-extensions=yes\n");
    printf("required-device-extensions=yes\n");
    printf("timeline-semaphore=yes\n");
    printf("synchronization2=yes\n");
    printf("sync-fd-semaphore=yes\n");
    printf("dma-buf-sync-file=yes\n");
    printf("kms-scanout-linear=yes\n");
    printf("optimal-render-features=yes\n");
    printf("dma-buf-scanout-copy-modifier=yes\n");
    printf("dma-buf-scanout-copy-export=yes\n");
    printf("dma-buf-scanout-copy-import=yes\n");
    printf("optimal-render-copy-submit=yes\n");
    printf("optimal-render-copy-readback=yes\n");
    printf("dma-buf-texture-modifier=yes\n");
    printf("dma-buf-texture-import=yes\n");
    printf("kms-scanout-commit=yes\n");
    exit_code = 0;

cleanup:
    if (device)
        (void)vkDeviceWaitIdle(device);
    if (restore_kms_scanout(&kms_scanout) != 0 && exit_code == 0)
        exit_code = 1;
    destroy_imported_image(device, &texture_image);
    destroy_kms_framebuffer(&kms_framebuffer);
    destroy_exported_image(device, &scanout_image);
    if (device)
        vkDestroyDevice(device, NULL);
    if (instance)
        vkDestroyInstance(instance, NULL);
    if (drm_fd >= 0)
        close(drm_fd);
    return exit_code;
}
