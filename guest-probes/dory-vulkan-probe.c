#define _POSIX_C_SOURCE 200809L
#define VK_USE_PLATFORM_WAYLAND_KHR
#define VK_USE_PLATFORM_XCB_KHR

#include <errno.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wayland-client.h>
#include <xcb/xcb.h>
#include <unistd.h>
#include <vulkan/vulkan.h>

#include "dory-visual-challenge.h"
#include <time.h>

enum wsi_mode {
    WSI_NONE,
    WSI_XCB,
    WSI_WAYLAND,
};

struct probe_options {
    enum wsi_mode mode;
    uint32_t width;
    uint32_t height;
    VkPresentModeKHR present_mode;
    const char *nonce;
    const char *ready_file;
    uint32_t hold_milliseconds;
};

struct native_surface {
    enum wsi_mode mode;
    xcb_connection_t *xcb_connection;
    xcb_window_t xcb_window;
    struct wl_display *wayland_display;
    struct wl_registry *wayland_registry;
    struct wl_compositor *wayland_compositor;
    struct wl_surface *wayland_surface;
};

static int fail(const char *message, VkResult result)
{
    if (result == VK_SUCCESS)
        fprintf(stderr, "dory-vulkan-probe: %s\n", message);
    else
        fprintf(stderr, "dory-vulkan-probe: %s (%d)\n", message, result);
    return 1;
}

static uint64_t monotonic_nanoseconds(void)
{
    struct timespec value = {0};
    if (clock_gettime(CLOCK_MONOTONIC, &value) != 0)
        return 0;
    return (uint64_t)value.tv_sec * UINT64_C(1000000000) + (uint64_t)value.tv_nsec;
}

static uint64_t fnv1a(const void *bytes, size_t count, uint64_t hash)
{
    const uint8_t *cursor = bytes;
    for (size_t index = 0; index < count; index++) {
        hash ^= cursor[index];
        hash *= UINT64_C(1099511628211);
    }
    return hash;
}

static void print_json_string(const char *value)
{
    putchar('"');
    for (const unsigned char *cursor = (const unsigned char *)value; *cursor; cursor++) {
        switch (*cursor) {
        case '"': fputs("\\\"", stdout); break;
        case '\\': fputs("\\\\", stdout); break;
        case '\n': fputs("\\n", stdout); break;
        case '\r': fputs("\\r", stdout); break;
        case '\t': fputs("\\t", stdout); break;
        default:
            if (*cursor < 0x20)
                printf("\\u%04x", *cursor);
            else
                putchar(*cursor);
        }
    }
    putchar('"');
}

static void record_visual_challenge(VkCommandBuffer command_buffer,
                                    const char *nonce, uint32_t frame_marker,
                                    VkExtent2D extent)
{
    const uint32_t cell_size = dory_visual_cell_size(extent.width, extent.height);
    const uint32_t origin_x = 24;
    const uint32_t origin_y = 24;
    const uint64_t challenge_hash = dory_visual_challenge_hash(nonce, frame_marker);
    if (DORY_VISUAL_CHALLENGE_COLUMNS * cell_size + origin_x > extent.width ||
        DORY_VISUAL_CHALLENGE_ROWS * cell_size + origin_y > extent.height)
        return;
    for (uint32_t row = 0; row < DORY_VISUAL_CHALLENGE_ROWS; row++) {
        for (uint32_t column = 0; column < DORY_VISUAL_CHALLENGE_COLUMNS; column++) {
            const struct dory_visual_color color = dory_visual_cell_color(
                column, row, challenge_hash, (uint16_t)frame_marker);
            VkClearAttachment attachment = {
                .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
                .colorAttachment = 0,
                .clearValue = {.color = {.float32 = {
                    color.red / 255.0f, color.green / 255.0f,
                    color.blue / 255.0f, color.alpha / 255.0f,
                }}},
            };
            VkClearRect rectangle = {
                .rect = {
                    .offset = {
                        (int32_t)(origin_x + column * cell_size),
                        (int32_t)(origin_y + row * cell_size),
                    },
                    .extent = {cell_size, cell_size},
                },
                .baseArrayLayer = 0,
                .layerCount = 1,
            };
            vkCmdClearAttachments(command_buffer, 1, &attachment, 1, &rectangle);
        }
    }
}

static const char *version_string(uint32_t version, char buffer[32])
{
    (void)snprintf(buffer, 32, "%u.%u.%u", VK_API_VERSION_MAJOR(version),
                   VK_API_VERSION_MINOR(version), VK_API_VERSION_PATCH(version));
    return buffer;
}

static int has_instance_extension(const VkExtensionProperties *extensions,
                                  uint32_t count, const char *name)
{
    for (uint32_t i = 0; i < count; i++) {
        if (strcmp(extensions[i].extensionName, name) == 0)
            return 1;
    }
    return 0;
}

static int has_device_extension(VkPhysicalDevice device, const char *name)
{
    uint32_t count = 0;
    VkResult result = vkEnumerateDeviceExtensionProperties(device, NULL, &count, NULL);
    if (result != VK_SUCCESS || count == 0)
        return 0;
    VkExtensionProperties *extensions = calloc(count, sizeof(*extensions));
    if (!extensions)
        return 0;
    result = vkEnumerateDeviceExtensionProperties(device, NULL, &count, extensions);
    int found = result == VK_SUCCESS;
    for (uint32_t i = 0; found && i < count; i++) {
        if (strcmp(extensions[i].extensionName, name) == 0) {
            free(extensions);
            return 1;
        }
    }
    free(extensions);
    return 0;
}

static void registry_global(void *data, struct wl_registry *registry, uint32_t name,
                            const char *interface, uint32_t version)
{
    struct native_surface *native = data;
    if (strcmp(interface, wl_compositor_interface.name) != 0)
        return;
    uint32_t bind_version = version < 4 ? version : 4;
    native->wayland_compositor = wl_registry_bind(
        registry, name, &wl_compositor_interface, bind_version);
}

static void registry_global_remove(void *data, struct wl_registry *registry, uint32_t name)
{
    (void)data;
    (void)registry;
    (void)name;
}

static const struct wl_registry_listener registry_listener = {
    .global = registry_global,
    .global_remove = registry_global_remove,
};

static void destroy_native_surface(struct native_surface *native)
{
    if (native->wayland_surface)
        wl_surface_destroy(native->wayland_surface);
    if (native->wayland_compositor)
        wl_compositor_destroy(native->wayland_compositor);
    if (native->wayland_registry)
        wl_registry_destroy(native->wayland_registry);
    if (native->wayland_display)
        wl_display_disconnect(native->wayland_display);
    if (native->xcb_connection) {
        if (native->xcb_window != XCB_WINDOW_NONE)
            xcb_destroy_window(native->xcb_connection, native->xcb_window);
        xcb_disconnect(native->xcb_connection);
    }
    memset(native, 0, sizeof(*native));
}

static int create_xcb_native_surface(struct native_surface *native,
                                     const struct probe_options *options)
{
    int screen_number = 0;
    native->xcb_connection = xcb_connect(NULL, &screen_number);
    if (!native->xcb_connection || xcb_connection_has_error(native->xcb_connection))
        return fail("could not connect to the active X11 display", VK_SUCCESS);

    const xcb_setup_t *setup = xcb_get_setup(native->xcb_connection);
    xcb_screen_iterator_t iterator = xcb_setup_roots_iterator(setup);
    for (int index = 0; index < screen_number && iterator.rem > 0; index++)
        xcb_screen_next(&iterator);
    if (iterator.rem == 0)
        return fail("the active X11 display has no selected screen", VK_SUCCESS);

    xcb_screen_t *screen = iterator.data;
    native->xcb_window = xcb_generate_id(native->xcb_connection);
    uint32_t values[] = {screen->black_pixel, XCB_EVENT_MASK_STRUCTURE_NOTIFY};
    xcb_void_cookie_t cookie = xcb_create_window_checked(
        native->xcb_connection, XCB_COPY_FROM_PARENT, native->xcb_window,
        screen->root, 0, 0, options->width, options->height, 0,
        XCB_WINDOW_CLASS_INPUT_OUTPUT,
        screen->root_visual, XCB_CW_BACK_PIXEL | XCB_CW_EVENT_MASK, values);
    xcb_generic_error_t *error = xcb_request_check(native->xcb_connection, cookie);
    if (error) {
        free(error);
        return fail("could not create the requested X11 test window", VK_SUCCESS);
    }
    xcb_map_window(native->xcb_connection, native->xcb_window);
    if (xcb_flush(native->xcb_connection) <= 0)
        return fail("could not flush the X11 test window", VK_SUCCESS);
    native->mode = WSI_XCB;
    return 0;
}

static int create_wayland_native_surface(struct native_surface *native)
{
    native->wayland_display = wl_display_connect(NULL);
    if (!native->wayland_display)
        return fail("could not connect to the active Wayland display", VK_SUCCESS);
    native->wayland_registry = wl_display_get_registry(native->wayland_display);
    if (!native->wayland_registry)
        return fail("could not obtain the Wayland registry", VK_SUCCESS);
    if (wl_registry_add_listener(native->wayland_registry, &registry_listener, native) != 0 ||
        wl_display_roundtrip(native->wayland_display) < 0)
        return fail("could not enumerate the Wayland registry", VK_SUCCESS);
    if (!native->wayland_compositor)
        return fail("the active Wayland display has no compositor", VK_SUCCESS);
    native->wayland_surface = wl_compositor_create_surface(native->wayland_compositor);
    if (!native->wayland_surface)
        return fail("could not create the Wayland test surface", VK_SUCCESS);
    native->mode = WSI_WAYLAND;
    return 0;
}

static int create_vulkan_surface(VkInstance instance, struct native_surface *native,
                                 VkSurfaceKHR *surface)
{
    if (native->mode == WSI_XCB) {
        PFN_vkCreateXcbSurfaceKHR create_xcb =
            (PFN_vkCreateXcbSurfaceKHR)vkGetInstanceProcAddr(instance, "vkCreateXcbSurfaceKHR");
        if (!create_xcb)
            return fail("vkCreateXcbSurfaceKHR is unavailable", VK_SUCCESS);
        VkXcbSurfaceCreateInfoKHR create = {
            .sType = VK_STRUCTURE_TYPE_XCB_SURFACE_CREATE_INFO_KHR,
            .connection = native->xcb_connection,
            .window = native->xcb_window,
        };
        VkResult result = create_xcb(instance, &create, NULL, surface);
        return result == VK_SUCCESS ? 0 : fail("vkCreateXcbSurfaceKHR failed", result);
    }
    if (native->mode == WSI_WAYLAND) {
        PFN_vkCreateWaylandSurfaceKHR create_wayland =
            (PFN_vkCreateWaylandSurfaceKHR)vkGetInstanceProcAddr(
                instance, "vkCreateWaylandSurfaceKHR");
        if (!create_wayland)
            return fail("vkCreateWaylandSurfaceKHR is unavailable", VK_SUCCESS);
        VkWaylandSurfaceCreateInfoKHR create = {
            .sType = VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR,
            .display = native->wayland_display,
            .surface = native->wayland_surface,
        };
        VkResult result = create_wayland(instance, &create, NULL, surface);
        return result == VK_SUCCESS ? 0 : fail("vkCreateWaylandSurfaceKHR failed", result);
    }
    return fail("no native WSI surface was requested", VK_SUCCESS);
}

static const char *surface_format_name(VkFormat format);

static VkSurfaceFormatKHR choose_surface_format(const VkSurfaceFormatKHR *formats,
                                                uint32_t count)
{
    if (count == 1 && formats[0].format == VK_FORMAT_UNDEFINED) {
        VkSurfaceFormatKHR selected = formats[0];
        selected.format = VK_FORMAT_B8G8R8A8_SRGB;
        return selected;
    }
    const VkFormat preferred[] = {
        VK_FORMAT_B8G8R8A8_UNORM, VK_FORMAT_R8G8B8A8_UNORM,
        VK_FORMAT_B8G8R8A8_SRGB, VK_FORMAT_R8G8B8A8_SRGB,
    };
    for (size_t preference = 0; preference < sizeof(preferred) / sizeof(preferred[0]);
         preference++) {
        for (uint32_t index = 0; index < count; index++) {
            if (formats[index].format == preferred[preference])
                return formats[index];
        }
    }
    VkSurfaceFormatKHR unavailable = {.format = VK_FORMAT_UNDEFINED};
    return unavailable;
}

static const char *surface_format_name(VkFormat format)
{
    switch (format) {
    case VK_FORMAT_B8G8R8A8_SRGB:
        return "bgra8-srgb";
    case VK_FORMAT_R8G8B8A8_SRGB:
        return "rgba8-srgb";
    case VK_FORMAT_B8G8R8A8_UNORM:
        return "bgra8-unorm";
    case VK_FORMAT_R8G8B8A8_UNORM:
        return "rgba8-unorm";
    default:
        return "other";
    }
}

static VkFormat choose_color_atlas_format(VkPhysicalDevice device)
{
    const VkFormat choices[] = {
        VK_FORMAT_B8G8R8A8_UNORM,
        VK_FORMAT_R8G8B8A8_UNORM,
    };
    const VkFormatFeatureFlags required =
        VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT | VK_FORMAT_FEATURE_TRANSFER_DST_BIT |
        VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT | VK_FORMAT_FEATURE_TRANSFER_SRC_BIT;
    for (uint32_t i = 0; i < sizeof(choices) / sizeof(choices[0]); i++) {
        VkFormatProperties properties = {0};
        vkGetPhysicalDeviceFormatProperties(device, choices[i], &properties);
        if ((properties.optimalTilingFeatures & required) == required)
            return choices[i];
    }
    return VK_FORMAT_UNDEFINED;
}

static const char *color_atlas_format_name(VkFormat format)
{
    return format == VK_FORMAT_B8G8R8A8_UNORM ? "bgra8-unorm" : "rgba8-unorm";
}

static uint32_t find_memory_type(VkPhysicalDevice physical_device,
                                 uint32_t supported_bits,
                                 VkMemoryPropertyFlags required)
{
    VkPhysicalDeviceMemoryProperties properties = {0};
    vkGetPhysicalDeviceMemoryProperties(physical_device, &properties);
    for (uint32_t index = 0; index < properties.memoryTypeCount; index++) {
        if ((supported_bits & (1u << index)) != 0 &&
            (properties.memoryTypes[index].propertyFlags & required) == required)
            return index;
    }
    return UINT32_MAX;
}

/* Render an actual graphics attachment even when there is no WSI surface. The readback is
 * retained as bytes, so the host verifier can replay the nonce-bound image oracle rather than
 * trusting a metadata-only result hash or this process's local success flag. */
static int render_offscreen_challenge(
    VkPhysicalDevice physical_device, VkDevice device, VkQueue queue,
    uint32_t queue_family, VkFormat format, const char *nonce,
    PFN_vkQueueSubmit2 queue_submit2,
    PFN_vkCmdPipelineBarrier2 cmd_pipeline_barrier2,
    PFN_vkCmdBeginRendering cmd_begin_rendering,
    PFN_vkCmdEndRendering cmd_end_rendering,
    uint8_t visual_readback_rgb[DORY_VISUAL_CHALLENGE_COLUMNS *
                                DORY_VISUAL_CHALLENGE_ROWS * 3],
    uint8_t background_rgba[4], VkBool32 *readback_coherent)
{
    const VkExtent2D extent = {320, 240};
    const VkDeviceSize image_bytes = (VkDeviceSize)extent.width * extent.height * 4;
    VkImage image = VK_NULL_HANDLE;
    VkDeviceMemory image_memory = VK_NULL_HANDLE;
    VkImageView view = VK_NULL_HANDLE;
    VkBuffer buffer = VK_NULL_HANDLE;
    VkDeviceMemory buffer_memory = VK_NULL_HANDLE;
    VkCommandPool pool = VK_NULL_HANDLE;
    VkFence fence = VK_NULL_HANDLE;
    VkResult result = VK_ERROR_INITIALIZATION_FAILED;
    const char *failure = "offscreen Vulkan challenge failed";
    void *mapped = NULL;
    int pixel_match = 1;

    VkImageCreateInfo image_info = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .imageType = VK_IMAGE_TYPE_2D,
        .format = format,
        .extent = {extent.width, extent.height, 1},
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = VK_SAMPLE_COUNT_1_BIT,
        .tiling = VK_IMAGE_TILING_OPTIMAL,
        .usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT |
                 VK_IMAGE_USAGE_TRANSFER_SRC_BIT |
                 VK_IMAGE_USAGE_TRANSFER_DST_BIT |
                 VK_IMAGE_USAGE_SAMPLED_BIT,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
        .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
    };
    result = vkCreateImage(device, &image_info, NULL, &image);
    if (result != VK_SUCCESS) goto cleanup;
    VkMemoryRequirements image_requirements = {0};
    vkGetImageMemoryRequirements(device, image, &image_requirements);
    uint32_t image_type = find_memory_type(
        physical_device, image_requirements.memoryTypeBits,
        VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    if (image_type == UINT32_MAX)
        image_type = find_memory_type(
            physical_device, image_requirements.memoryTypeBits, 0);
    if (image_type == UINT32_MAX) {
        result = VK_ERROR_FEATURE_NOT_PRESENT;
        goto cleanup;
    }
    VkMemoryAllocateInfo image_allocation = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = image_requirements.size,
        .memoryTypeIndex = image_type,
    };
    result = vkAllocateMemory(device, &image_allocation, NULL, &image_memory);
    if (result != VK_SUCCESS) goto cleanup;
    result = vkBindImageMemory(device, image, image_memory, 0);
    if (result != VK_SUCCESS) goto cleanup;
    VkImageViewCreateInfo view_info = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .image = image,
        .viewType = VK_IMAGE_VIEW_TYPE_2D,
        .format = format,
        .subresourceRange = {
            .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
            .levelCount = 1,
            .layerCount = 1,
        },
    };
    result = vkCreateImageView(device, &view_info, NULL, &view);
    if (result != VK_SUCCESS) goto cleanup;

    VkBufferCreateInfo buffer_info = {
        .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = image_bytes,
        .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
    };
    result = vkCreateBuffer(device, &buffer_info, NULL, &buffer);
    if (result != VK_SUCCESS) goto cleanup;
    VkMemoryRequirements buffer_requirements = {0};
    vkGetBufferMemoryRequirements(device, buffer, &buffer_requirements);
    uint32_t buffer_type = find_memory_type(
        physical_device, buffer_requirements.memoryTypeBits,
        VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    if (buffer_type == UINT32_MAX)
        buffer_type = find_memory_type(
            physical_device, buffer_requirements.memoryTypeBits,
            VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT);
    if (buffer_type == UINT32_MAX) {
        result = VK_ERROR_FEATURE_NOT_PRESENT;
        goto cleanup;
    }
    VkPhysicalDeviceMemoryProperties memory_properties = {0};
    vkGetPhysicalDeviceMemoryProperties(physical_device, &memory_properties);
    *readback_coherent = (memory_properties.memoryTypes[buffer_type].propertyFlags &
                          VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) != 0;
    VkMemoryAllocateInfo buffer_allocation = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = buffer_requirements.size,
        .memoryTypeIndex = buffer_type,
    };
    result = vkAllocateMemory(device, &buffer_allocation, NULL, &buffer_memory);
    if (result != VK_SUCCESS) goto cleanup;
    result = vkBindBufferMemory(device, buffer, buffer_memory, 0);
    if (result != VK_SUCCESS) goto cleanup;

    VkCommandPoolCreateInfo pool_info = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .queueFamilyIndex = queue_family,
    };
    result = vkCreateCommandPool(device, &pool_info, NULL, &pool);
    if (result != VK_SUCCESS) goto cleanup;
    VkCommandBufferAllocateInfo command_info = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = pool,
        .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    };
    VkCommandBuffer command = VK_NULL_HANDLE;
    result = vkAllocateCommandBuffers(device, &command_info, &command);
    if (result != VK_SUCCESS) goto cleanup;
    VkCommandBufferBeginInfo begin_info = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    };
    result = vkBeginCommandBuffer(command, &begin_info);
    if (result != VK_SUCCESS) goto cleanup;
    VkImageMemoryBarrier2 to_attachment = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
        .srcStageMask = VK_PIPELINE_STAGE_2_NONE,
        .srcAccessMask = VK_ACCESS_2_NONE,
        .dstStageMask = VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
        .dstAccessMask = VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
        .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED,
        .newLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresourceRange = view_info.subresourceRange,
    };
    VkDependencyInfo dependency = {
        .sType = VK_STRUCTURE_TYPE_DEPENDENCY_INFO,
        .imageMemoryBarrierCount = 1,
        .pImageMemoryBarriers = &to_attachment,
    };
    cmd_pipeline_barrier2(command, &dependency);
    VkRenderingAttachmentInfo attachment = {
        .sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
        .imageView = view,
        .imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
        .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
        .clearValue = {.color = {{8.0f / 255.0f, 24.0f / 255.0f,
                                 48.0f / 255.0f, 1.0f}}},
    };
    VkRenderingInfo rendering = {
        .sType = VK_STRUCTURE_TYPE_RENDERING_INFO,
        .renderArea = {.extent = extent},
        .layerCount = 1,
        .colorAttachmentCount = 1,
        .pColorAttachments = &attachment,
    };
    cmd_begin_rendering(command, &rendering);
    record_visual_challenge(command, nonce, 1, extent);
    cmd_end_rendering(command);
    VkImageMemoryBarrier2 to_readback = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
        .srcStageMask = VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
        .srcAccessMask = VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
        .dstStageMask = VK_PIPELINE_STAGE_2_COPY_BIT,
        .dstAccessMask = VK_ACCESS_2_TRANSFER_READ_BIT,
        .oldLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        .newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresourceRange = view_info.subresourceRange,
    };
    dependency.pImageMemoryBarriers = &to_readback;
    cmd_pipeline_barrier2(command, &dependency);
    VkBufferImageCopy copy = {
        .imageSubresource = {
            .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
            .layerCount = 1,
        },
        .imageExtent = {extent.width, extent.height, 1},
    };
    vkCmdCopyImageToBuffer(command, image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                           buffer, 1, &copy);
    VkBufferMemoryBarrier2 to_host = {
        .sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER_2,
        .srcStageMask = VK_PIPELINE_STAGE_2_COPY_BIT,
        .srcAccessMask = VK_ACCESS_2_TRANSFER_WRITE_BIT,
        .dstStageMask = VK_PIPELINE_STAGE_2_HOST_BIT,
        .dstAccessMask = VK_ACCESS_2_HOST_READ_BIT,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .buffer = buffer,
        .size = VK_WHOLE_SIZE,
    };
    VkDependencyInfo host_dependency = {
        .sType = VK_STRUCTURE_TYPE_DEPENDENCY_INFO,
        .bufferMemoryBarrierCount = 1,
        .pBufferMemoryBarriers = &to_host,
    };
    cmd_pipeline_barrier2(command, &host_dependency);
    result = vkEndCommandBuffer(command);
    if (result != VK_SUCCESS) goto cleanup;
    VkFenceCreateInfo fence_info = {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
    result = vkCreateFence(device, &fence_info, NULL, &fence);
    if (result != VK_SUCCESS) goto cleanup;
    VkCommandBufferSubmitInfo command_submit = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO,
        .commandBuffer = command,
        .deviceMask = 1,
    };
    VkSubmitInfo2 submit = {
        .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO_2,
        .commandBufferInfoCount = 1,
        .pCommandBufferInfos = &command_submit,
    };
    result = queue_submit2(queue, 1, &submit, fence);
    if (result != VK_SUCCESS) goto cleanup;
    result = vkWaitForFences(device, 1, &fence, VK_TRUE, 5000000000ULL);
    if (result != VK_SUCCESS) {
        int failure_code = fail("offscreen Vulkan challenge fence did not complete", result);
        (void)fflush(NULL);
        _Exit(failure_code);
    }
    result = vkMapMemory(device, buffer_memory, 0, buffer_requirements.size, 0, &mapped);
    if (result != VK_SUCCESS) goto cleanup;
    if (!*readback_coherent) {
        VkMappedMemoryRange range = {
            .sType = VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE,
            .memory = buffer_memory,
            .size = VK_WHOLE_SIZE,
        };
        result = vkInvalidateMappedMemoryRanges(device, 1, &range);
        if (result != VK_SUCCESS) goto cleanup;
    }
    const uint8_t *pixels = mapped;
    const int bgra = format == VK_FORMAT_B8G8R8A8_UNORM;
    background_rgba[0] = bgra ? pixels[2] : pixels[0];
    background_rgba[1] = pixels[1];
    background_rgba[2] = bgra ? pixels[0] : pixels[2];
    background_rgba[3] = pixels[3];
    const uint8_t expected_background[4] = {8, 24, 48, 255};
    for (uint32_t channel = 0; channel < 4; channel++) {
        int difference = (int)background_rgba[channel] - expected_background[channel];
        if (difference < -2 || difference > 2) pixel_match = 0;
    }
    const uint32_t cell_size = dory_visual_cell_size(extent.width, extent.height);
    const uint64_t challenge_hash = dory_visual_challenge_hash(nonce, 1);
    for (uint32_t row = 0; row < DORY_VISUAL_CHALLENGE_ROWS; row++) {
        for (uint32_t column = 0; column < DORY_VISUAL_CHALLENGE_COLUMNS; column++) {
            const uint32_t x = 24 + column * cell_size + cell_size / 2;
            const uint32_t y = 24 + row * cell_size + cell_size / 2;
            const uint8_t *sample = pixels + ((VkDeviceSize)y * extent.width + x) * 4;
            const size_t output =
                ((size_t)row * DORY_VISUAL_CHALLENGE_COLUMNS + column) * 3;
            visual_readback_rgb[output] = bgra ? sample[2] : sample[0];
            visual_readback_rgb[output + 1] = sample[1];
            visual_readback_rgb[output + 2] = bgra ? sample[0] : sample[2];
            const struct dory_visual_color color = dory_visual_cell_color(
                column, row, challenge_hash, 1);
            const uint8_t expected_rgb[3] = {color.red, color.green, color.blue};
            for (uint32_t channel = 0; channel < 3; channel++) {
                int difference = (int)visual_readback_rgb[output + channel]
                    - expected_rgb[channel];
                if (difference < -2 || difference > 2) pixel_match = 0;
            }
            if (sample[3] < 253) pixel_match = 0;
        }
    }
    if (!pixel_match) {
        failure = "offscreen Vulkan challenge readback differs from rendered pixels";
        result = VK_SUCCESS;
    }

cleanup:
    if (mapped) vkUnmapMemory(device, buffer_memory);
    if (fence) vkDestroyFence(device, fence, NULL);
    if (pool) vkDestroyCommandPool(device, pool, NULL);
    if (buffer) vkDestroyBuffer(device, buffer, NULL);
    if (buffer_memory) vkFreeMemory(device, buffer_memory, NULL);
    if (view) vkDestroyImageView(device, view, NULL);
    if (image) vkDestroyImage(device, image, NULL);
    if (image_memory) vkFreeMemory(device, image_memory, NULL);
    return result == VK_SUCCESS && pixel_match ? 0 : fail(failure, result);
}

struct presented_readback {
    VkBuffer buffer;
    VkDeviceMemory memory;
    VkDeviceSize allocation_size;
    VkBool32 coherent;
};

static void destroy_presented_readback(VkDevice device, struct presented_readback *readback)
{
    if (readback->buffer) vkDestroyBuffer(device, readback->buffer, NULL);
    if (readback->memory) vkFreeMemory(device, readback->memory, NULL);
    memset(readback, 0, sizeof(*readback));
}

static int create_presented_readback(VkPhysicalDevice physical_device,
                                     VkDevice device,
                                     struct presented_readback *readback)
{
    const VkDeviceSize byte_count =
        (1 + DORY_VISUAL_CHALLENGE_COLUMNS * DORY_VISUAL_CHALLENGE_ROWS) * 4;
    VkBufferCreateInfo buffer_info = {
        .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = byte_count,
        .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
    };
    VkResult result = vkCreateBuffer(device, &buffer_info, NULL, &readback->buffer);
    if (result != VK_SUCCESS)
        return fail("presented-frame readback buffer creation failed", result);
    VkMemoryRequirements requirements = {0};
    vkGetBufferMemoryRequirements(device, readback->buffer, &requirements);
    uint32_t memory_type = find_memory_type(
        physical_device, requirements.memoryTypeBits,
        VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    if (memory_type == UINT32_MAX)
        memory_type = find_memory_type(
            physical_device, requirements.memoryTypeBits,
            VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT);
    if (memory_type == UINT32_MAX) {
        destroy_presented_readback(device, readback);
        return fail("presented-frame readback has no host-visible memory", VK_SUCCESS);
    }
    VkPhysicalDeviceMemoryProperties properties = {0};
    vkGetPhysicalDeviceMemoryProperties(physical_device, &properties);
    readback->coherent = (properties.memoryTypes[memory_type].propertyFlags &
                          VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) != 0;
    readback->allocation_size = requirements.size;
    VkMemoryAllocateInfo allocation = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = requirements.size,
        .memoryTypeIndex = memory_type,
    };
    result = vkAllocateMemory(device, &allocation, NULL, &readback->memory);
    if (result == VK_SUCCESS)
        result = vkBindBufferMemory(device, readback->buffer, readback->memory, 0);
    if (result != VK_SUCCESS) {
        destroy_presented_readback(device, readback);
        return fail("presented-frame readback memory setup failed", result);
    }
    return 0;
}

static void record_presented_readback(
    VkCommandBuffer command, VkImage image, VkExtent2D extent,
    VkImageSubresourceRange image_range, VkBuffer buffer,
    PFN_vkCmdPipelineBarrier2 cmd_pipeline_barrier2)
{
    VkImageMemoryBarrier2 to_copy = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
        .srcStageMask = VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
        .srcAccessMask = VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
        .dstStageMask = VK_PIPELINE_STAGE_2_COPY_BIT,
        .dstAccessMask = VK_ACCESS_2_TRANSFER_READ_BIT,
        .oldLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        .newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresourceRange = image_range,
    };
    VkDependencyInfo copy_dependency = {
        .sType = VK_STRUCTURE_TYPE_DEPENDENCY_INFO,
        .imageMemoryBarrierCount = 1,
        .pImageMemoryBarriers = &to_copy,
    };
    cmd_pipeline_barrier2(command, &copy_dependency);
    VkBufferImageCopy regions[
        1 + DORY_VISUAL_CHALLENGE_COLUMNS * DORY_VISUAL_CHALLENGE_ROWS] = {0};
    const uint32_t cell_size = dory_visual_cell_size(extent.width, extent.height);
    for (size_t index = 0; index < sizeof(regions) / sizeof(regions[0]); index++) {
        regions[index].bufferOffset = (VkDeviceSize)index * 4;
        regions[index].imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        regions[index].imageSubresource.layerCount = 1;
        regions[index].imageExtent.width = 1;
        regions[index].imageExtent.height = 1;
        regions[index].imageExtent.depth = 1;
        if (index > 0) {
            const uint32_t cell = (uint32_t)index - 1;
            const uint32_t column = cell % DORY_VISUAL_CHALLENGE_COLUMNS;
            const uint32_t row = cell / DORY_VISUAL_CHALLENGE_COLUMNS;
            regions[index].imageOffset.x =
                (int32_t)(24 + column * cell_size + cell_size / 2);
            regions[index].imageOffset.y =
                (int32_t)(24 + row * cell_size + cell_size / 2);
        }
    }
    vkCmdCopyImageToBuffer(command, image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                           buffer, (uint32_t)(sizeof(regions) / sizeof(regions[0])),
                           regions);
    VkBufferMemoryBarrier2 to_host = {
        .sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER_2,
        .srcStageMask = VK_PIPELINE_STAGE_2_COPY_BIT,
        .srcAccessMask = VK_ACCESS_2_TRANSFER_WRITE_BIT,
        .dstStageMask = VK_PIPELINE_STAGE_2_HOST_BIT,
        .dstAccessMask = VK_ACCESS_2_HOST_READ_BIT,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .buffer = buffer,
        .size = VK_WHOLE_SIZE,
    };
    VkDependencyInfo host_dependency = {
        .sType = VK_STRUCTURE_TYPE_DEPENDENCY_INFO,
        .bufferMemoryBarrierCount = 1,
        .pBufferMemoryBarriers = &to_host,
    };
    cmd_pipeline_barrier2(command, &host_dependency);
}

static int decode_presented_readback(
    VkDevice device, const struct presented_readback *readback, VkFormat format,
    uint8_t visual_readback_rgb[DORY_VISUAL_CHALLENGE_COLUMNS *
                                DORY_VISUAL_CHALLENGE_ROWS * 3],
    uint8_t background_rgba[4])
{
    void *mapped = NULL;
    VkResult result = vkMapMemory(
        device, readback->memory, 0, readback->allocation_size, 0, &mapped);
    if (result != VK_SUCCESS)
        return fail("presented-frame readback mapping failed", result);
    if (!readback->coherent) {
        VkMappedMemoryRange range = {
            .sType = VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE,
            .memory = readback->memory,
            .size = VK_WHOLE_SIZE,
        };
        result = vkInvalidateMappedMemoryRanges(device, 1, &range);
    }
    if (result == VK_SUCCESS) {
        const uint8_t *pixels = mapped;
        const int bgra = format == VK_FORMAT_B8G8R8A8_UNORM ||
                         format == VK_FORMAT_B8G8R8A8_SRGB;
        background_rgba[0] = bgra ? pixels[2] : pixels[0];
        background_rgba[1] = pixels[1];
        background_rgba[2] = bgra ? pixels[0] : pixels[2];
        background_rgba[3] = pixels[3];
        for (size_t cell = 0;
             cell < DORY_VISUAL_CHALLENGE_COLUMNS * DORY_VISUAL_CHALLENGE_ROWS;
             cell++) {
            const uint8_t *sample = pixels + (cell + 1) * 4;
            visual_readback_rgb[cell * 3] = bgra ? sample[2] : sample[0];
            visual_readback_rgb[cell * 3 + 1] = sample[1];
            visual_readback_rgb[cell * 3 + 2] = bgra ? sample[0] : sample[2];
            if (sample[3] < 253) {
                result = VK_ERROR_FORMAT_NOT_SUPPORTED;
                break;
            }
        }
    }
    vkUnmapMemory(device, readback->memory);
    return result == VK_SUCCESS ? 0 : fail("presented-frame readback is invalid", result);
}

static VkCompositeAlphaFlagBitsKHR choose_composite_alpha(VkCompositeAlphaFlagsKHR supported)
{
    const VkCompositeAlphaFlagBitsKHR choices[] = {
        VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
        VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR,
        VK_COMPOSITE_ALPHA_POST_MULTIPLIED_BIT_KHR,
        VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR,
    };
    for (uint32_t i = 0; i < sizeof(choices) / sizeof(choices[0]); i++) {
        if ((supported & choices[i]) != 0)
            return choices[i];
    }
    return 0;
}

static uint32_t clamp_extent(uint32_t value, uint32_t minimum, uint32_t maximum)
{
    if (value < minimum)
        return minimum;
    if (value > maximum)
        return maximum;
    return value;
}

static int parse_extent(const char *value, uint32_t *width, uint32_t *height)
{
    char *width_end = NULL;
    char *height_end = NULL;
    errno = 0;
    unsigned long parsed_width = strtoul(value, &width_end, 10);
    if (errno != 0 || !width_end || (*width_end != 'x' && *width_end != 'X'))
        return 0;
    const char *height_start = width_end + 1;
    errno = 0;
    unsigned long parsed_height = strtoul(height_start, &height_end, 10);
    if (errno != 0 || height_end == height_start || *height_end != '\0' ||
        parsed_width == 0 || parsed_width > 16384 ||
        parsed_height == 0 || parsed_height > 16384)
        return 0;
    *width = (uint32_t)parsed_width;
    *height = (uint32_t)parsed_height;
    return 1;
}

static int parse_options(int argc, char **argv, struct probe_options *options)
{
    *options = (struct probe_options){
        .mode = WSI_NONE,
        .width = 64,
        .height = 64,
        .present_mode = VK_PRESENT_MODE_FIFO_KHR,
        .nonce = "dory-vulkan-default",
        .hold_milliseconds = 2000,
    };
    int extent_seen = 0;
    int mode_seen = 0;
    int present_mode_seen = 0;
    int nonce_seen = 0;
    int hold_seen = 0;
    for (int index = 1; index < argc; index++) {
        if (strcmp(argv[index], "--wsi=xcb") == 0 && !mode_seen) {
            options->mode = WSI_XCB;
            mode_seen = 1;
        } else if (strcmp(argv[index], "--wsi=wayland") == 0 && !mode_seen) {
            options->mode = WSI_WAYLAND;
            mode_seen = 1;
        } else if (strcmp(argv[index], "--wsi=auto") == 0 && !mode_seen) {
            if (getenv("WAYLAND_DISPLAY") && getenv("XDG_RUNTIME_DIR"))
                options->mode = WSI_WAYLAND;
            else if (getenv("DISPLAY"))
                options->mode = WSI_XCB;
            else
                return fail("--wsi=auto found no active desktop display", VK_SUCCESS);
            mode_seen = 1;
        } else if (strncmp(argv[index], "--extent=", 9) == 0 && !extent_seen) {
            if (!parse_extent(argv[index] + 9, &options->width, &options->height))
                goto invalid;
            extent_seen = 1;
        } else if (strcmp(argv[index], "--present-mode=fifo") == 0 &&
                   !present_mode_seen) {
            options->present_mode = VK_PRESENT_MODE_FIFO_KHR;
            present_mode_seen = 1;
        } else if (strcmp(argv[index], "--present-mode=mailbox") == 0 &&
                   !present_mode_seen) {
            options->present_mode = VK_PRESENT_MODE_MAILBOX_KHR;
            present_mode_seen = 1;
        } else if (strncmp(argv[index], "--nonce=", 8) == 0 &&
                   argv[index][8] != '\0' && !nonce_seen) {
            options->nonce = argv[index] + 8;
            nonce_seen = 1;
        } else if (strncmp(argv[index], "--hold-ms=", 10) == 0 && !hold_seen) {
            if (dory_visual_parse_hold_milliseconds(
                    argv[index] + 10, &options->hold_milliseconds) != 0)
                goto invalid;
            hold_seen = 1;
        } else if (strncmp(argv[index], "--ready-file=", 13) == 0 &&
                   argv[index][13] != '\0' && !options->ready_file) {
            options->ready_file = argv[index] + 13;
        } else {
            goto invalid;
        }
    }
    if ((extent_seen || present_mode_seen || hold_seen || options->ready_file) &&
        options->mode == WSI_NONE)
        goto invalid;
    if (options->mode != WSI_NONE) {
        if (!extent_seen) {
            options->width = 960;
            options->height = 600;
        }
        const uint32_t cell_size = dory_visual_cell_size(
            options->width, options->height);
        if (24u + DORY_VISUAL_CHALLENGE_COLUMNS * cell_size > options->width ||
            24u + DORY_VISUAL_CHALLENGE_ROWS * cell_size > options->height) {
            fprintf(stderr, "dory-vulkan-probe: extent cannot contain the visual challenge\n");
            return 64;
        }
    }
    return 0;

invalid:
    fprintf(stderr,
            "usage: %s [--wsi=xcb|wayland|auto] [--extent=WIDTHxHEIGHT] "
            "[--present-mode=fifo|mailbox] [--nonce=VALUE] "
            "[--hold-ms=0..30000] [--ready-file=/absolute/path]\n",
            argv[0]);
    return 64;
}

int main(int argc, char **argv)
{
    struct probe_options options;
    int exit_code = parse_options(argc, argv, &options);
    if (exit_code != 0)
        return exit_code;
    uint64_t started = monotonic_nanoseconds();

    PFN_vkEnumerateInstanceVersion enumerate_instance_version =
        (PFN_vkEnumerateInstanceVersion)vkGetInstanceProcAddr(NULL, "vkEnumerateInstanceVersion");
    if (!enumerate_instance_version)
        return fail("Vulkan loader does not expose vkEnumerateInstanceVersion", VK_SUCCESS);
    uint32_t loader_version = VK_API_VERSION_1_0;
    VkResult result = enumerate_instance_version(&loader_version);
    if (result != VK_SUCCESS)
        return fail("could not query the Vulkan loader version", result);
    if (loader_version < VK_API_VERSION_1_3)
        return fail("Vulkan loader API is below 1.3", VK_SUCCESS);

    uint32_t instance_extension_count = 0;
    result = vkEnumerateInstanceExtensionProperties(NULL, &instance_extension_count, NULL);
    if (result != VK_SUCCESS || instance_extension_count == 0)
        return fail("could not enumerate Vulkan instance extensions", result);
    VkExtensionProperties *instance_extensions =
        calloc(instance_extension_count, sizeof(*instance_extensions));
    if (!instance_extensions)
        return fail("out of memory", VK_ERROR_OUT_OF_HOST_MEMORY);
    result = vkEnumerateInstanceExtensionProperties(
        NULL, &instance_extension_count, instance_extensions);
    if (result != VK_SUCCESS) {
        free(instance_extensions);
        return fail("could not read Vulkan instance extensions", result);
    }
    const char *required_instance_extensions[] = {
        VK_KHR_SURFACE_EXTENSION_NAME,
        VK_KHR_XCB_SURFACE_EXTENSION_NAME,
        VK_KHR_WAYLAND_SURFACE_EXTENSION_NAME,
    };
    for (uint32_t i = 0;
         i < sizeof(required_instance_extensions) / sizeof(required_instance_extensions[0]); i++) {
        if (!has_instance_extension(instance_extensions, instance_extension_count,
                                    required_instance_extensions[i])) {
            fprintf(stderr, "dory-vulkan-probe: missing instance extension %s\n",
                    required_instance_extensions[i]);
            free(instance_extensions);
            return 1;
        }
    }
    free(instance_extensions);

    VkApplicationInfo application = {
        .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "dory-vulkan-probe",
        .applicationVersion = 2,
        .pEngineName = "Dory",
        .engineVersion = 2,
        .apiVersion = VK_API_VERSION_1_3,
    };
    VkInstanceCreateInfo instance_create = {
        .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = &application,
        .enabledExtensionCount = (uint32_t)(sizeof(required_instance_extensions) /
                                            sizeof(required_instance_extensions[0])),
        .ppEnabledExtensionNames = required_instance_extensions,
    };
    VkInstance instance = VK_NULL_HANDLE;
    result = vkCreateInstance(&instance_create, NULL, &instance);
    if (result != VK_SUCCESS)
        return fail("vkCreateInstance for Vulkan 1.3 failed", result);

    struct native_surface native = {0};
    VkSurfaceKHR surface = VK_NULL_HANDLE;
    if (options.mode == WSI_XCB)
        exit_code = create_xcb_native_surface(&native, &options);
    else if (options.mode == WSI_WAYLAND)
        exit_code = create_wayland_native_surface(&native);
    if (exit_code == 0 && options.mode != WSI_NONE)
        exit_code = create_vulkan_surface(instance, &native, &surface);
    if (exit_code != 0) {
        destroy_native_surface(&native);
        vkDestroyInstance(instance, NULL);
        return exit_code;
    }

    uint32_t device_count = 0;
    result = vkEnumeratePhysicalDevices(instance, &device_count, NULL);
    if (result != VK_SUCCESS || device_count == 0) {
        if (surface)
            vkDestroySurfaceKHR(instance, surface, NULL);
        destroy_native_surface(&native);
        vkDestroyInstance(instance, NULL);
        return fail("no Vulkan physical device", result);
    }
    VkPhysicalDevice *devices = calloc(device_count, sizeof(*devices));
    if (!devices) {
        if (surface)
            vkDestroySurfaceKHR(instance, surface, NULL);
        destroy_native_surface(&native);
        vkDestroyInstance(instance, NULL);
        return fail("out of memory", VK_ERROR_OUT_OF_HOST_MEMORY);
    }
    result = vkEnumeratePhysicalDevices(instance, &device_count, devices);
    if (result != VK_SUCCESS) {
        free(devices);
        if (surface)
            vkDestroySurfaceKHR(instance, surface, NULL);
        destroy_native_surface(&native);
        vkDestroyInstance(instance, NULL);
        return fail("physical-device enumeration failed", result);
    }

    VkPhysicalDevice physical_device = VK_NULL_HANDLE;
    VkPhysicalDeviceProperties2 selected_properties = {0};
    VkPhysicalDeviceDriverProperties selected_driver = {0};
    VkFormat color_atlas_format = VK_FORMAT_UNDEFINED;
    uint32_t queue_family = UINT32_MAX;
    for (uint32_t i = 0; i < device_count; i++) {
        VkPhysicalDeviceDriverProperties driver = {
            .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES,
        };
        VkPhysicalDeviceProperties2 properties = {
            .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2,
            .pNext = &driver,
        };
        vkGetPhysicalDeviceProperties2(devices[i], &properties);
        if (strcmp(driver.driverName, "venus") != 0 ||
            properties.properties.deviceType == VK_PHYSICAL_DEVICE_TYPE_CPU)
            continue;
        if (properties.properties.apiVersion < VK_API_VERSION_1_3) {
            fprintf(stderr, "dory-vulkan-probe: Venus device API is below 1.3\n");
            continue;
        }
        if (!has_device_extension(devices[i], VK_KHR_SWAPCHAIN_EXTENSION_NAME) ||
            !has_device_extension(devices[i], VK_KHR_EXTERNAL_SEMAPHORE_FD_EXTENSION_NAME)) {
            fprintf(stderr, "dory-vulkan-probe: Venus lacks a required device extension\n");
            continue;
        }

        VkPhysicalDeviceVulkan13Features features13 = {
            .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
        };
        VkPhysicalDeviceFeatures2 features = {
            .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,
            .pNext = &features13,
        };
        vkGetPhysicalDeviceFeatures2(devices[i], &features);
        if (!features.features.robustBufferAccess || !features13.dynamicRendering ||
            !features13.synchronization2 || !features13.maintenance4) {
            fprintf(stderr,
                    "dory-vulkan-probe: Venus lacks robust access or required Vulkan 1.3 features\n");
            continue;
        }
        VkFormat candidate_atlas_format = choose_color_atlas_format(devices[i]);
        if (candidate_atlas_format == VK_FORMAT_UNDEFINED) {
            fprintf(stderr,
                "dory-vulkan-probe: Venus lacks a sampled/renderable/readback BGRA8/RGBA8 format\n");
            continue;
        }

        VkPhysicalDeviceExternalSemaphoreInfo external_info = {
            .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_SEMAPHORE_INFO,
            .handleType = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT,
        };
        VkExternalSemaphoreProperties external_properties = {
            .sType = VK_STRUCTURE_TYPE_EXTERNAL_SEMAPHORE_PROPERTIES,
        };
        vkGetPhysicalDeviceExternalSemaphoreProperties(
            devices[i], &external_info, &external_properties);
        const VkExternalSemaphoreFeatureFlags required_external_features =
            VK_EXTERNAL_SEMAPHORE_FEATURE_IMPORTABLE_BIT |
            VK_EXTERNAL_SEMAPHORE_FEATURE_EXPORTABLE_BIT;
        if ((external_properties.compatibleHandleTypes &
             VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT) == 0 ||
            (external_properties.externalSemaphoreFeatures & required_external_features) !=
                required_external_features) {
            fprintf(stderr,
                    "dory-vulkan-probe: SYNC_FD semaphore import/export is unavailable\n");
            continue;
        }

        uint32_t queue_count = 0;
        vkGetPhysicalDeviceQueueFamilyProperties(devices[i], &queue_count, NULL);
        VkQueueFamilyProperties *queues = calloc(queue_count, sizeof(*queues));
        if (!queues)
            continue;
        vkGetPhysicalDeviceQueueFamilyProperties(devices[i], &queue_count, queues);
        uint32_t candidate_queue = UINT32_MAX;
        for (uint32_t j = 0; j < queue_count; j++) {
            if (queues[j].queueCount == 0 ||
                (queues[j].queueFlags & VK_QUEUE_GRAPHICS_BIT) == 0)
                continue;
            if (surface) {
                VkBool32 present_supported = VK_FALSE;
                result = vkGetPhysicalDeviceSurfaceSupportKHR(
                    devices[i], j, surface, &present_supported);
                if (result != VK_SUCCESS || !present_supported)
                    continue;
            }
            candidate_queue = j;
            break;
        }
        free(queues);
        if (candidate_queue == UINT32_MAX) {
            fprintf(stderr,
                    "dory-vulkan-probe: Venus has no graphics/present-capable queue\n");
            continue;
        }

        physical_device = devices[i];
        selected_properties = properties;
        selected_driver = driver;
        color_atlas_format = candidate_atlas_format;
        queue_family = candidate_queue;
        break;
    }
    free(devices);
    if (physical_device == VK_NULL_HANDLE) {
        if (surface)
            vkDestroySurfaceKHR(instance, surface, NULL);
        destroy_native_surface(&native);
        vkDestroyInstance(instance, NULL);
        return fail("no Vulkan 1.3 hardware Venus device satisfies the contract", VK_SUCCESS);
    }

    /* Query Zink prerequisites, then request only individually supported optional bits.
     * Missing optional capabilities must not break the baseline rendering probe: the
     * strategy comparison rejects their absence separately. Query structs must never be
     * reused wholesale as device-create requests. */
    const int has_extended_dynamic_state = has_device_extension(
        physical_device, VK_EXT_EXTENDED_DYNAMIC_STATE_EXTENSION_NAME);
    const int has_robustness2 = has_device_extension(
        physical_device, VK_EXT_ROBUSTNESS_2_EXTENSION_NAME);
    VkPhysicalDeviceVulkan12Features queried_features12 = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
    };
    VkPhysicalDeviceExtendedDynamicStateFeaturesEXT queried_dynamic_state = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTENDED_DYNAMIC_STATE_FEATURES_EXT,
        .pNext = &queried_features12,
    };
    VkPhysicalDeviceRobustness2FeaturesEXT queried_robustness2 = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ROBUSTNESS_2_FEATURES_EXT,
    };
    void *queried_chain = &queried_features12;
    if (has_extended_dynamic_state)
        queried_chain = &queried_dynamic_state;
    if (has_robustness2) {
        queried_robustness2.pNext = queried_chain;
        queried_chain = &queried_robustness2;
    }
    VkPhysicalDeviceFeatures2 queried_strategy_features = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,
        .pNext = queried_chain,
    };
    vkGetPhysicalDeviceFeatures2(physical_device, &queried_strategy_features);
    int enable_timeline = queried_features12.timelineSemaphore == VK_TRUE;
    int enable_dynamic_state = has_extended_dynamic_state &&
        queried_dynamic_state.extendedDynamicState == VK_TRUE;
    int enable_robustness2 = has_robustness2 &&
        queried_robustness2.robustBufferAccess2 == VK_TRUE;

    VkPhysicalDeviceVulkan13Features enabled_features13 = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
        .dynamicRendering = VK_TRUE,
        .synchronization2 = VK_TRUE,
        .maintenance4 = VK_TRUE,
    };
    VkPhysicalDeviceVulkan12Features enabled_features12 = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
        .pNext = &enabled_features13,
        .timelineSemaphore = enable_timeline ? VK_TRUE : VK_FALSE,
    };
    VkPhysicalDeviceExtendedDynamicStateFeaturesEXT enabled_dynamic_state = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTENDED_DYNAMIC_STATE_FEATURES_EXT,
        .pNext = &enabled_features12,
        .extendedDynamicState = enable_dynamic_state ? VK_TRUE : VK_FALSE,
    };
    VkPhysicalDeviceRobustness2FeaturesEXT enabled_robustness2 = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ROBUSTNESS_2_FEATURES_EXT,
        .robustBufferAccess2 = enable_robustness2 ? VK_TRUE : VK_FALSE,
    };
    void *enabled_chain = &enabled_features12;
    if (enable_dynamic_state)
        enabled_chain = &enabled_dynamic_state;
    if (enable_robustness2) {
        enabled_robustness2.pNext = enabled_chain;
        enabled_chain = &enabled_robustness2;
    }
    VkPhysicalDeviceFeatures2 enabled_features = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,
        .pNext = enabled_chain,
        .features = {.robustBufferAccess = VK_TRUE},
    };
    const float queue_priority = 1.0f;
    VkDeviceQueueCreateInfo queue_create = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = queue_family,
        .queueCount = 1,
        .pQueuePriorities = &queue_priority,
    };
    const char *device_extensions[4] = {
        VK_KHR_EXTERNAL_SEMAPHORE_FD_EXTENSION_NAME,
        VK_KHR_SWAPCHAIN_EXTENSION_NAME,
    };
    uint32_t device_extension_count = 2;
    if (enable_dynamic_state)
        device_extensions[device_extension_count++] = VK_EXT_EXTENDED_DYNAMIC_STATE_EXTENSION_NAME;
    if (enable_robustness2)
        device_extensions[device_extension_count++] = VK_EXT_ROBUSTNESS_2_EXTENSION_NAME;
    VkDeviceCreateInfo device_create = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .pNext = &enabled_features,
        .queueCreateInfoCount = 1,
        .pQueueCreateInfos = &queue_create,
        .enabledExtensionCount = device_extension_count,
        .ppEnabledExtensionNames = device_extensions,
    };
    VkDevice device = VK_NULL_HANDLE;
    int strategy_feature_fallback = 0;
    result = vkCreateDevice(physical_device, &device_create, NULL, &device);
    if (result != VK_SUCCESS && (enable_timeline || enable_dynamic_state ||
                                  enable_robustness2)) {
        fprintf(stderr,
                "dory-vulkan-probe: optional strategy feature negotiation failed (%d); "
                "retrying baseline device\n", result);
        strategy_feature_fallback = 1;
        enable_timeline = 0;
        enable_dynamic_state = 0;
        enable_robustness2 = 0;
        enabled_features12.timelineSemaphore = VK_FALSE;
        enabled_features.pNext = &enabled_features12;
        device_create.enabledExtensionCount = 2;
        result = vkCreateDevice(physical_device, &device_create, NULL, &device);
    }
    if (result != VK_SUCCESS) {
        if (surface)
            vkDestroySurfaceKHR(instance, surface, NULL);
        destroy_native_surface(&native);
        vkDestroyInstance(instance, NULL);
        return fail("vkCreateDevice with Vulkan 1.3 features failed", result);
    }

    VkSwapchainKHR swapchain = VK_NULL_HANDLE;
    uint32_t swapchain_image_count = 0;
    VkImage *swapchain_images = NULL;
    VkSurfaceFormatKHR surface_format = {.format = VK_FORMAT_UNDEFINED};
    VkExtent2D swapchain_extent = {0};
    if (surface) {
        VkSurfaceCapabilitiesKHR capabilities = {0};
        result = vkGetPhysicalDeviceSurfaceCapabilitiesKHR(
            physical_device, surface, &capabilities);
        const VkImageUsageFlags required_usage =
            VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
        if (result != VK_SUCCESS ||
            (capabilities.supportedUsageFlags & required_usage) != required_usage) {
            exit_code = fail("surface lacks color-attachment/readback capabilities", result);
            goto cleanup;
        }
        uint32_t format_count = 0;
        result = vkGetPhysicalDeviceSurfaceFormatsKHR(
            physical_device, surface, &format_count, NULL);
        if (result != VK_SUCCESS || format_count == 0) {
            exit_code = fail("surface exposes no formats", result);
            goto cleanup;
        }
        VkSurfaceFormatKHR *formats = calloc(format_count, sizeof(*formats));
        if (!formats) {
            exit_code = fail("out of memory", VK_ERROR_OUT_OF_HOST_MEMORY);
            goto cleanup;
        }
        result = vkGetPhysicalDeviceSurfaceFormatsKHR(
            physical_device, surface, &format_count, formats);
        if (result == VK_SUCCESS)
            surface_format = choose_surface_format(formats, format_count);
        free(formats);
        if (result != VK_SUCCESS || surface_format.format == VK_FORMAT_UNDEFINED) {
            exit_code = fail("surface lacks a BGRA8/RGBA8 application format", result);
            goto cleanup;
        }

        uint32_t present_mode_count = 0;
        result = vkGetPhysicalDeviceSurfacePresentModesKHR(
            physical_device, surface, &present_mode_count, NULL);
        if (result != VK_SUCCESS || present_mode_count == 0) {
            exit_code = fail("surface exposes no present modes", result);
            goto cleanup;
        }
        VkPresentModeKHR *present_modes = calloc(present_mode_count, sizeof(*present_modes));
        if (!present_modes) {
            exit_code = fail("out of memory", VK_ERROR_OUT_OF_HOST_MEMORY);
            goto cleanup;
        }
        result = vkGetPhysicalDeviceSurfacePresentModesKHR(
            physical_device, surface, &present_mode_count, present_modes);
        int has_requested_present_mode = 0;
        for (uint32_t i = 0; result == VK_SUCCESS && i < present_mode_count; i++) {
            if (present_modes[i] == options.present_mode)
                has_requested_present_mode = 1;
        }
        free(present_modes);
        if (result != VK_SUCCESS || !has_requested_present_mode) {
            exit_code = fail("surface lacks the requested presentation mode", result);
            goto cleanup;
        }

        if (capabilities.currentExtent.width == UINT32_MAX) {
            swapchain_extent.width = clamp_extent(
                options.width, capabilities.minImageExtent.width,
                capabilities.maxImageExtent.width);
            swapchain_extent.height = clamp_extent(
                options.height, capabilities.minImageExtent.height,
                capabilities.maxImageExtent.height);
        } else {
            swapchain_extent = capabilities.currentExtent;
        }
        if (swapchain_extent.width != options.width ||
            swapchain_extent.height != options.height) {
            exit_code = fail("surface cannot configure the requested readiness extent",
                             VK_SUCCESS);
            goto cleanup;
        }
        uint32_t min_image_count = capabilities.minImageCount + 1;
        if (capabilities.maxImageCount > 0 && min_image_count > capabilities.maxImageCount)
            min_image_count = capabilities.maxImageCount;
        VkCompositeAlphaFlagBitsKHR composite_alpha =
            choose_composite_alpha(capabilities.supportedCompositeAlpha);
        if (composite_alpha == 0) {
            exit_code = fail("surface exposes no composite-alpha mode", VK_SUCCESS);
            goto cleanup;
        }
        VkSwapchainCreateInfoKHR swapchain_create = {
            .sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
            .surface = surface,
            .minImageCount = min_image_count,
            .imageFormat = surface_format.format,
            .imageColorSpace = surface_format.colorSpace,
            .imageExtent = swapchain_extent,
            .imageArrayLayers = 1,
            .imageUsage = required_usage,
            .imageSharingMode = VK_SHARING_MODE_EXCLUSIVE,
            .preTransform = capabilities.currentTransform,
            .compositeAlpha = composite_alpha,
            .presentMode = options.present_mode,
            .clipped = VK_TRUE,
        };
        result = vkCreateSwapchainKHR(device, &swapchain_create, NULL, &swapchain);
        if (result != VK_SUCCESS) {
            exit_code = fail("requested FIFO swapchain creation failed", result);
            goto cleanup;
        }
        result = vkGetSwapchainImagesKHR(device, swapchain, &swapchain_image_count, NULL);
        if (result != VK_SUCCESS || swapchain_image_count == 0) {
            exit_code = fail("created swapchain exposes no images", result);
            goto cleanup;
        }
        swapchain_images = calloc(swapchain_image_count, sizeof(*swapchain_images));
        if (!swapchain_images) {
            exit_code = fail("out of memory", VK_ERROR_OUT_OF_HOST_MEMORY);
            goto cleanup;
        }
        result = vkGetSwapchainImagesKHR(
            device, swapchain, &swapchain_image_count, swapchain_images);
        if (result != VK_SUCCESS || swapchain_image_count == 0) {
            exit_code = fail("could not read the created swapchain images", result);
            goto cleanup;
        }
    }

    PFN_vkQueueSubmit2 queue_submit2 =
        (PFN_vkQueueSubmit2)vkGetDeviceProcAddr(device, "vkQueueSubmit2");
    PFN_vkCmdPipelineBarrier2 cmd_pipeline_barrier2 =
        (PFN_vkCmdPipelineBarrier2)vkGetDeviceProcAddr(device, "vkCmdPipelineBarrier2");
    PFN_vkCmdBeginRendering cmd_begin_rendering =
        (PFN_vkCmdBeginRendering)vkGetDeviceProcAddr(device, "vkCmdBeginRendering");
    PFN_vkCmdEndRendering cmd_end_rendering =
        (PFN_vkCmdEndRendering)vkGetDeviceProcAddr(device, "vkCmdEndRendering");
    PFN_vkImportSemaphoreFdKHR import_semaphore_fd =
        (PFN_vkImportSemaphoreFdKHR)vkGetDeviceProcAddr(device, "vkImportSemaphoreFdKHR");
    PFN_vkGetSemaphoreFdKHR get_semaphore_fd =
        (PFN_vkGetSemaphoreFdKHR)vkGetDeviceProcAddr(device, "vkGetSemaphoreFdKHR");
    if (!queue_submit2 || !cmd_pipeline_barrier2 || !cmd_begin_rendering ||
        !cmd_end_rendering || !import_semaphore_fd || !get_semaphore_fd) {
        exit_code = fail(
            "required Vulkan 1.3 or SYNC_FD entry point is unavailable", VK_SUCCESS);
        goto cleanup;
    }

    VkQueue queue = VK_NULL_HANDLE;
    vkGetDeviceQueue(device, queue_family, 0, &queue);
    VkCommandPoolCreateInfo pool_create = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = VK_COMMAND_POOL_CREATE_TRANSIENT_BIT,
        .queueFamilyIndex = queue_family,
    };
    VkCommandPool command_pool = VK_NULL_HANDLE;
    result = vkCreateCommandPool(device, &pool_create, NULL, &command_pool);
    if (result != VK_SUCCESS) {
        exit_code = fail("vkCreateCommandPool failed", result);
        goto cleanup;
    }
    VkCommandBufferAllocateInfo command_allocate = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = command_pool,
        .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    };
    VkCommandBuffer command_buffer = VK_NULL_HANDLE;
    result = vkAllocateCommandBuffers(device, &command_allocate, &command_buffer);
    if (result != VK_SUCCESS) {
        exit_code = fail("vkAllocateCommandBuffers failed", result);
        vkDestroyCommandPool(device, command_pool, NULL);
        goto cleanup;
    }

    uint8_t presented_readback_rgb[
        DORY_VISUAL_CHALLENGE_COLUMNS * DORY_VISUAL_CHALLENGE_ROWS * 3] = {0};
    uint8_t presented_background_rgba[4] = {0};
    VkBool32 presented_readback_coherent = VK_FALSE;

    if (surface) {
        VkSemaphoreCreateInfo present_semaphore_create = {
            .sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
        };
        VkSemaphore image_available = VK_NULL_HANDLE;
        VkSemaphore render_complete = VK_NULL_HANDLE;
        VkFenceCreateInfo present_fence_create = {
            .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
        };
        VkFence present_fence = VK_NULL_HANDLE;
        VkImageView present_view = VK_NULL_HANDLE;
        struct presented_readback readback = {0};

        result = vkCreateSemaphore(device, &present_semaphore_create, NULL, &image_available);
        if (result == VK_SUCCESS)
            result = vkCreateSemaphore(
                device, &present_semaphore_create, NULL, &render_complete);
        if (result == VK_SUCCESS)
            result = vkCreateFence(device, &present_fence_create, NULL, &present_fence);
        if (result != VK_SUCCESS) {
            exit_code = fail("swapchain synchronization object creation failed", result);
            if (present_fence)
                vkDestroyFence(device, present_fence, NULL);
            if (render_complete)
                vkDestroySemaphore(device, render_complete, NULL);
            if (image_available)
                vkDestroySemaphore(device, image_available, NULL);
            vkDestroyCommandPool(device, command_pool, NULL);
            goto cleanup;
        }

        uint32_t image_index = UINT32_MAX;
        result = vkAcquireNextImageKHR(
            device, swapchain, 5000000000ULL, image_available, VK_NULL_HANDLE, &image_index);
        if ((result != VK_SUCCESS && result != VK_SUBOPTIMAL_KHR) ||
            image_index >= swapchain_image_count) {
            exit_code = fail("could not acquire a swapchain image", result);
            vkDestroyFence(device, present_fence, NULL);
            vkDestroySemaphore(device, render_complete, NULL);
            vkDestroySemaphore(device, image_available, NULL);
            vkDestroyCommandPool(device, command_pool, NULL);
            goto cleanup;
        }

        VkImageViewCreateInfo view_create = {
            .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .image = swapchain_images[image_index],
            .viewType = VK_IMAGE_VIEW_TYPE_2D,
            .format = surface_format.format,
            .subresourceRange = {
                .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };
        result = vkCreateImageView(device, &view_create, NULL, &present_view);
        if (result != VK_SUCCESS) {
            exit_code = fail("swapchain image-view creation failed", result);
            vkDestroyFence(device, present_fence, NULL);
            vkDestroySemaphore(device, render_complete, NULL);
            vkDestroySemaphore(device, image_available, NULL);
            vkDestroyCommandPool(device, command_pool, NULL);
            goto cleanup;
        }
        if (create_presented_readback(physical_device, device, &readback) != 0) {
            exit_code = 1;
            vkDestroyImageView(device, present_view, NULL);
            vkDestroyFence(device, present_fence, NULL);
            vkDestroySemaphore(device, render_complete, NULL);
            vkDestroySemaphore(device, image_available, NULL);
            vkDestroyCommandPool(device, command_pool, NULL);
            goto cleanup;
        }
        presented_readback_coherent = readback.coherent;

        VkCommandBufferBeginInfo present_command_begin = {
            .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        };
        result = vkBeginCommandBuffer(command_buffer, &present_command_begin);
        if (result == VK_SUCCESS) {
            VkImageMemoryBarrier2 to_color_attachment = {
                .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
                .srcStageMask = VK_PIPELINE_STAGE_2_NONE,
                .srcAccessMask = VK_ACCESS_2_NONE,
                .dstStageMask = VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
                .dstAccessMask = VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
                .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED,
                .newLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
                .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
                .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
                .image = swapchain_images[image_index],
                .subresourceRange = view_create.subresourceRange,
            };
            VkDependencyInfo to_color_dependency = {
                .sType = VK_STRUCTURE_TYPE_DEPENDENCY_INFO,
                .imageMemoryBarrierCount = 1,
                .pImageMemoryBarriers = &to_color_attachment,
            };
            cmd_pipeline_barrier2(command_buffer, &to_color_dependency);

            VkRenderingAttachmentInfo color_attachment = {
                .sType = VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
                .imageView = present_view,
                .imageLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
                .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
                .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
                .clearValue = {.color = {{0.03125f, 0.09375f, 0.1875f, 1.0f}}},
            };
            VkRenderingInfo rendering = {
                .sType = VK_STRUCTURE_TYPE_RENDERING_INFO,
                .renderArea = {.offset = {0, 0}, .extent = swapchain_extent},
                .layerCount = 1,
                .colorAttachmentCount = 1,
                .pColorAttachments = &color_attachment,
            };
            cmd_begin_rendering(command_buffer, &rendering);
            record_visual_challenge(command_buffer, options.nonce, 1, swapchain_extent);
            cmd_end_rendering(command_buffer);

            record_presented_readback(
                command_buffer, swapchain_images[image_index], swapchain_extent,
                view_create.subresourceRange, readback.buffer, cmd_pipeline_barrier2);

            VkImageMemoryBarrier2 to_present = {
                .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
                .srcStageMask = VK_PIPELINE_STAGE_2_COPY_BIT,
                .srcAccessMask = VK_ACCESS_2_TRANSFER_READ_BIT,
                .dstStageMask = VK_PIPELINE_STAGE_2_NONE,
                .dstAccessMask = VK_ACCESS_2_NONE,
                .oldLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                .newLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
                .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
                .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
                .image = swapchain_images[image_index],
                .subresourceRange = view_create.subresourceRange,
            };
            VkDependencyInfo to_present_dependency = {
                .sType = VK_STRUCTURE_TYPE_DEPENDENCY_INFO,
                .imageMemoryBarrierCount = 1,
                .pImageMemoryBarriers = &to_present,
            };
            cmd_pipeline_barrier2(command_buffer, &to_present_dependency);
            result = vkEndCommandBuffer(command_buffer);
        }
        if (result != VK_SUCCESS) {
            exit_code = fail("swapchain render command recording failed", result);
            destroy_presented_readback(device, &readback);
            vkDestroyImageView(device, present_view, NULL);
            vkDestroyFence(device, present_fence, NULL);
            vkDestroySemaphore(device, render_complete, NULL);
            vkDestroySemaphore(device, image_available, NULL);
            vkDestroyCommandPool(device, command_pool, NULL);
            goto cleanup;
        }

        VkCommandBufferSubmitInfo present_command = {
            .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO,
            .commandBuffer = command_buffer,
            .deviceMask = 1,
        };
        VkSemaphoreSubmitInfo image_available_wait = {
            .sType = VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
            .semaphore = image_available,
            .stageMask = VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
        };
        VkSemaphoreSubmitInfo render_complete_signal = {
            .sType = VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
            .semaphore = render_complete,
            .stageMask = VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
        };
        VkSubmitInfo2 present_submit = {
            .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO_2,
            .waitSemaphoreInfoCount = 1,
            .pWaitSemaphoreInfos = &image_available_wait,
            .commandBufferInfoCount = 1,
            .pCommandBufferInfos = &present_command,
            .signalSemaphoreInfoCount = 1,
            .pSignalSemaphoreInfos = &render_complete_signal,
        };
        result = queue_submit2(queue, 1, &present_submit, present_fence);
        if (result == VK_SUCCESS)
            result = vkWaitForFences(device, 1, &present_fence, VK_TRUE, 5000000000ULL);
        if (result != VK_SUCCESS) {
            /* Submitted work may still own every object in this block. Process exit is the
             * bounded, fail-closed retirement boundary when the presentation fence stalls. */
            int failure = fail("swapchain render submission failed", result);
            (void)fflush(NULL);
            _Exit(failure);
        }
        if (decode_presented_readback(
                device, &readback, surface_format.format,
                presented_readback_rgb, presented_background_rgba) != 0) {
            exit_code = 1;
            destroy_presented_readback(device, &readback);
            vkDestroyImageView(device, present_view, NULL);
            vkDestroyFence(device, present_fence, NULL);
            vkDestroySemaphore(device, render_complete, NULL);
            vkDestroySemaphore(device, image_available, NULL);
            vkDestroyCommandPool(device, command_pool, NULL);
            goto cleanup;
        }
        destroy_presented_readback(device, &readback);

        VkPresentInfoKHR present = {
            .sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &render_complete,
            .swapchainCount = 1,
            .pSwapchains = &swapchain,
            .pImageIndices = &image_index,
        };
        VkResult present_result = vkQueuePresentKHR(queue, &present);
        VkResult idle_result = vkQueueWaitIdle(queue);
        if (idle_result != VK_SUCCESS) {
            int failure = fail("presentation queue did not become idle", idle_result);
            (void)fflush(NULL);
            _Exit(failure);
        }
        vkDestroyImageView(device, present_view, NULL);
        vkDestroyFence(device, present_fence, NULL);
        vkDestroySemaphore(device, render_complete, NULL);
        vkDestroySemaphore(device, image_available, NULL);
        if (present_result != VK_SUCCESS && present_result != VK_SUBOPTIMAL_KHR) {
            exit_code = fail("vkQueuePresentKHR failed", present_result);
            vkDestroyCommandPool(device, command_pool, NULL);
            goto cleanup;
        }
        if ((native.mode == WSI_XCB && xcb_flush(native.xcb_connection) <= 0) ||
            (native.mode == WSI_WAYLAND && wl_display_roundtrip(native.wayland_display) < 0)) {
            exit_code = fail("native display did not process the presentation", VK_SUCCESS);
            vkDestroyCommandPool(device, command_pool, NULL);
            goto cleanup;
        }
        result = vkResetCommandPool(device, command_pool, 0);
        if (result != VK_SUCCESS) {
            exit_code = fail("could not reset the presentation command pool", result);
            vkDestroyCommandPool(device, command_pool, NULL);
            goto cleanup;
        }
    }
    if (surface) {
        if (dory_visual_hold_milliseconds(50) != 0) {
            exit_code = fail("could not settle presented frame", VK_SUCCESS);
            vkDestroyCommandPool(device, command_pool, NULL);
            goto cleanup;
        }
        if (dory_visual_publish_presented(options.ready_file, options.nonce, 1) != 0) {
            exit_code = fail("could not publish presented-frame marker", VK_SUCCESS);
            vkDestroyCommandPool(device, command_pool, NULL);
            goto cleanup;
        }
        if (dory_visual_hold_milliseconds(options.hold_milliseconds) != 0) {
            exit_code = fail("could not hold presented frame", VK_SUCCESS);
            vkDestroyCommandPool(device, command_pool, NULL);
            goto cleanup;
        }
    }

    VkCommandBufferBeginInfo command_begin = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    };
    result = vkBeginCommandBuffer(command_buffer, &command_begin);
    if (result == VK_SUCCESS)
        result = vkEndCommandBuffer(command_buffer);
    if (result != VK_SUCCESS) {
        exit_code = fail("command recording failed", result);
        vkDestroyCommandPool(device, command_pool, NULL);
        goto cleanup;
    }

    VkFenceCreateInfo fence_create = {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
    VkFence fence = VK_NULL_HANDLE;
    result = vkCreateFence(device, &fence_create, NULL, &fence);
    if (result != VK_SUCCESS) {
        exit_code = fail("vkCreateFence failed", result);
        vkDestroyCommandPool(device, command_pool, NULL);
        goto cleanup;
    }
    VkSemaphoreCreateInfo semaphore_create = {
        .sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
    };
    VkSemaphore acquire_semaphore = VK_NULL_HANDLE;
    result = vkCreateSemaphore(device, &semaphore_create, NULL, &acquire_semaphore);
    if (result != VK_SUCCESS) {
        exit_code = fail("vkCreateSemaphore failed", result);
        vkDestroyFence(device, fence, NULL);
        vkDestroyCommandPool(device, command_pool, NULL);
        goto cleanup;
    }
    VkImportSemaphoreFdInfoKHR semaphore_import = {
        .sType = VK_STRUCTURE_TYPE_IMPORT_SEMAPHORE_FD_INFO_KHR,
        .semaphore = acquire_semaphore,
        .flags = VK_SEMAPHORE_IMPORT_TEMPORARY_BIT,
        .handleType = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT,
        .fd = -1,
    };
    result = import_semaphore_fd(device, &semaphore_import);
    if (result != VK_SUCCESS) {
        exit_code = fail("signaled SYNC_FD import failed", result);
        vkDestroySemaphore(device, acquire_semaphore, NULL);
        vkDestroyFence(device, fence, NULL);
        vkDestroyCommandPool(device, command_pool, NULL);
        goto cleanup;
    }

    VkExportSemaphoreCreateInfo semaphore_export = {
        .sType = VK_STRUCTURE_TYPE_EXPORT_SEMAPHORE_CREATE_INFO,
        .handleTypes = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT,
    };
    VkSemaphoreCreateInfo release_semaphore_create = {
        .sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
        .pNext = &semaphore_export,
    };
    VkSemaphore release_semaphore = VK_NULL_HANDLE;
    result = vkCreateSemaphore(device, &release_semaphore_create, NULL, &release_semaphore);
    if (result != VK_SUCCESS) {
        exit_code = fail("exportable release semaphore creation failed", result);
        vkDestroySemaphore(device, acquire_semaphore, NULL);
        vkDestroyFence(device, fence, NULL);
        vkDestroyCommandPool(device, command_pool, NULL);
        goto cleanup;
    }

    VkCommandBufferSubmitInfo command_submit = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO,
        .commandBuffer = command_buffer,
        .deviceMask = 1,
    };
    VkSemaphoreSubmitInfo semaphore_wait = {
        .sType = VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
        .semaphore = acquire_semaphore,
        .stageMask = VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
    };
    VkSubmitInfo2 submit = {
        .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO_2,
        .waitSemaphoreInfoCount = 1,
        .pWaitSemaphoreInfos = &semaphore_wait,
        .commandBufferInfoCount = 1,
        .pCommandBufferInfos = &command_submit,
    };
    VkSemaphoreSubmitInfo semaphore_signal = {
        .sType = VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
        .semaphore = release_semaphore,
        .stageMask = VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
    };
    submit.signalSemaphoreInfoCount = 1;
    submit.pSignalSemaphoreInfos = &semaphore_signal;
    VkResult submit_result = queue_submit2(queue, 1, &submit, fence);
    VkResult export_result = VK_SUCCESS;
    VkResult wait_result = VK_SUCCESS;
    int release_fd = -2;
    if (submit_result == VK_SUCCESS) {
        VkSemaphoreGetFdInfoKHR semaphore_get_fd = {
            .sType = VK_STRUCTURE_TYPE_SEMAPHORE_GET_FD_INFO_KHR,
            .semaphore = release_semaphore,
            .handleType = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT,
        };
        export_result = get_semaphore_fd(device, &semaphore_get_fd, &release_fd);
        wait_result = vkWaitForFences(device, 1, &fence, VK_TRUE, 5000000000ULL);
    }
    if (release_fd >= 0)
        (void)close(release_fd);
    if (submit_result == VK_SUCCESS && wait_result != VK_SUCCESS) {
        /* Do not destroy objects that the queue may still reference. Process exit is the bounded,
         * fail-closed retirement boundary if a submitted fence never completes. */
        int failure = fail("queue/fence round trip failed", wait_result);
        (void)fflush(NULL);
        _Exit(failure);
    }
    vkDestroySemaphore(device, release_semaphore, NULL);
    vkDestroySemaphore(device, acquire_semaphore, NULL);
    vkDestroyFence(device, fence, NULL);
    vkDestroyCommandPool(device, command_pool, NULL);
    if (submit_result != VK_SUCCESS)
        result = submit_result;
    else if (export_result != VK_SUCCESS)
        result = export_result;
    else if (release_fd < -1)
        result = VK_ERROR_UNKNOWN;
    else
        result = VK_SUCCESS;
    if (result != VK_SUCCESS) {
        exit_code = fail("queue/fence round trip failed", result);
        goto cleanup;
    }

    uint8_t offscreen_readback_rgb[
        DORY_VISUAL_CHALLENGE_COLUMNS * DORY_VISUAL_CHALLENGE_ROWS * 3] = {0};
    uint8_t offscreen_background_rgba[4] = {0};
    VkBool32 offscreen_readback_coherent = VK_FALSE;
    exit_code = render_offscreen_challenge(
        physical_device, device, queue, queue_family, color_atlas_format,
        options.nonce, queue_submit2, cmd_pipeline_barrier2,
        cmd_begin_rendering, cmd_end_rendering,
        offscreen_readback_rgb, offscreen_background_rgba,
        &offscreen_readback_coherent);
    if (exit_code != 0)
        goto cleanup;

    char loader_buffer[32];
    char device_buffer[32];
    uint64_t result_hash = fnv1a(
        options.nonce, strlen(options.nonce), UINT64_C(14695981039346656037));
    result_hash = fnv1a(selected_properties.properties.deviceName,
                        strlen(selected_properties.properties.deviceName), result_hash);
    result_hash = fnv1a(selected_driver.driverName,
                        strlen(selected_driver.driverName), result_hash);
    result_hash = fnv1a(&color_atlas_format, sizeof(color_atlas_format), result_hash);
    result_hash = fnv1a(&swapchain_extent, sizeof(swapchain_extent), result_hash);
    uint64_t finished = monotonic_nanoseconds();
    fputs("{\"schema\":\"dev.dory.gpu-probe\",\"version\":1,", stdout);
    fputs("\"probe\":\"vulkan-application\",\"deviceName\":", stdout);
    print_json_string(selected_properties.properties.deviceName);
    fputs(",\"driver\":", stdout);
    print_json_string(selected_driver.driverName);
    fputs(",\"apiVersion\":", stdout);
    print_json_string(version_string(
        selected_properties.properties.apiVersion, device_buffer));
    fputs(",\"loaderApiVersion\":", stdout);
    print_json_string(version_string(loader_version, loader_buffer));
    fputs(",\"extensionsUsed\":[", stdout);
    if (enable_dynamic_state)
        fputs("\"VK_EXT_extended_dynamic_state\",", stdout);
    if (enable_robustness2)
        fputs("\"VK_EXT_robustness2\",", stdout);
    fputs("\"VK_KHR_external_semaphore_fd\",\"VK_KHR_swapchain\"],", stdout);
    fputs("\"featuresUsed\":[\"dynamicRendering\",", stdout);
    if (enable_dynamic_state)
        fputs("\"extendedDynamicState\",", stdout);
    fputs("\"maintenance4\",\"robustBufferAccess\",", stdout);
    if (enable_robustness2)
        fputs("\"robustBufferAccess2\",", stdout);
    fputs("\"synchronization2\"", stdout);
    if (enable_timeline)
        fputs(",\"timelineSemaphore\"", stdout);
    fputs("],", stdout);
    printf("\"strategyFeatureFallback\":%s,",
           strategy_feature_fallback ? "true" : "false");
    printf("\"resultHash\":\"fnv1a64:%016" PRIx64 "\",", result_hash);
    printf("\"frameCount\":%u,\"nonce\":", surface ? 1u : 0u);
    print_json_string(options.nonce);
    if (surface) {
    printf(",\"visualChallenge\":{\"kind\":\"dev.dory.visual-challenge\","
               "\"version\":1,\"encoding\":\"fnv1a64-frame16-grid12x10\","
               "\"frameMarker\":1,\"payloadHash\":\"fnv1a64:%016" PRIx64 "\"}",
               dory_visual_challenge_hash(options.nonce, 1));
        printf(",\"presentedHoldMilliseconds\":%u", options.hold_milliseconds);
        if (options.ready_file) {
            fputs(",\"presentedReadyFile\":", stdout);
            print_json_string(options.ready_file);
        }
    }
    printf(",\"timings\":{\"totalMilliseconds\":%.3f},",
           (finished - started) / 1000000.0);
    fputs("\"wsi\":", stdout);
    print_json_string(!surface ? "none" : (native.mode == WSI_XCB ? "xcb" : "wayland"));
    printf(",\"surfaceFormat\":");
    print_json_string(!surface ? "none" : surface_format_name(surface_format.format));
    if (surface) {
        fputs(",\"presentedReadbackEncoding\":\"rgb8-cell-centers-top-left-grid12x10@1\"",
              stdout);
        fputs(",\"presentedReadbackRGBHex\":\"", stdout);
        for (size_t index = 0; index < sizeof(presented_readback_rgb); index++)
            printf("%02x", presented_readback_rgb[index]);
        putchar('"');
        printf(",\"presentedBackgroundRGBAHex\":\"%02x%02x%02x%02x\"",
               presented_background_rgba[0], presented_background_rgba[1],
               presented_background_rgba[2], presented_background_rgba[3]);
        fputs(",\"presentedReadbackMemoryCoherency\":", stdout);
        print_json_string(presented_readback_coherent ? "coherent" : "noncoherent");
    }
    printf(",\"colorAtlasFormat\":");
    print_json_string(color_atlas_format_name(color_atlas_format));
    fputs(",\"offscreenExtent\":{\"width\":320,\"height\":240}", stdout);
    fputs(",\"offscreenReadbackEncoding\":\"rgb8-cell-centers-top-left-grid12x10@1\"",
          stdout);
    fputs(",\"offscreenReadbackRGBHex\":\"", stdout);
    for (size_t index = 0; index < sizeof(offscreen_readback_rgb); index++)
        printf("%02x", offscreen_readback_rgb[index]);
    putchar('"');
    printf(",\"offscreenBackgroundRGBAHex\":\"%02x%02x%02x%02x\"",
           offscreen_background_rgba[0], offscreen_background_rgba[1],
           offscreen_background_rgba[2], offscreen_background_rgba[3]);
    fputs(",\"offscreenReadbackMemoryCoherency\":", stdout);
    print_json_string(offscreen_readback_coherent ? "coherent" : "noncoherent");
    printf(",\"presentMode\":");
    print_json_string(options.present_mode == VK_PRESENT_MODE_MAILBOX_KHR
        ? "mailbox" : "fifo");
    printf(",\"extent\":{\"width\":%u,\"height\":%u},"
           "\"swapchainImageCount\":%u}\n",
           swapchain_extent.width, swapchain_extent.height, swapchain_image_count);
    exit_code = 0;

cleanup:
    if (swapchain)
        vkDestroySwapchainKHR(device, swapchain, NULL);
    free(swapchain_images);
    vkDestroyDevice(device, NULL);
    if (surface)
        vkDestroySurfaceKHR(instance, surface, NULL);
    destroy_native_surface(&native);
    vkDestroyInstance(instance, NULL);
    return exit_code;
}
