#define VK_USE_PLATFORM_WAYLAND_KHR
#define VK_USE_PLATFORM_XCB_KHR

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wayland-client.h>
#include <xcb/xcb.h>
#include <unistd.h>
#include <vulkan/vulkan.h>

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
    if (count > 0)
        return formats[0];
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
        VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT | VK_FORMAT_FEATURE_TRANSFER_DST_BIT;
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
    };
    int extent_seen = 0;
    int mode_seen = 0;
    int present_mode_seen = 0;
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
        } else {
            goto invalid;
        }
    }
    if ((extent_seen || present_mode_seen) && options->mode == WSI_NONE)
        goto invalid;
    return 0;

invalid:
    fprintf(stderr,
            "usage: %s [--wsi=xcb|wayland|auto] [--extent=WIDTHxHEIGHT] "
            "[--present-mode=fifo|mailbox]\n",
            argv[0]);
    return 64;
}

int main(int argc, char **argv)
{
    struct probe_options options;
    int exit_code = parse_options(argc, argv, &options);
    if (exit_code != 0)
        return exit_code;

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
                    "dory-vulkan-probe: Venus lacks a sampled/copy-destination BGRA8/RGBA8 atlas format\n");
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

    /* Enable only the capabilities this probe consumes. Query structs contain every supported
     * optional bit and must not be reused as device-create requests. */
    VkPhysicalDeviceVulkan13Features enabled_features13 = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
        .dynamicRendering = VK_TRUE,
        .synchronization2 = VK_TRUE,
        .maintenance4 = VK_TRUE,
    };
    VkPhysicalDeviceFeatures2 enabled_features = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,
        .pNext = &enabled_features13,
        .features = {.robustBufferAccess = VK_TRUE},
    };
    const float queue_priority = 1.0f;
    VkDeviceQueueCreateInfo queue_create = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = queue_family,
        .queueCount = 1,
        .pQueuePriorities = &queue_priority,
    };
    const char *device_extensions[] = {
        VK_KHR_SWAPCHAIN_EXTENSION_NAME,
        VK_KHR_EXTERNAL_SEMAPHORE_FD_EXTENSION_NAME,
    };
    VkDeviceCreateInfo device_create = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .pNext = &enabled_features,
        .queueCreateInfoCount = 1,
        .pQueueCreateInfos = &queue_create,
        .enabledExtensionCount =
            (uint32_t)(sizeof(device_extensions) / sizeof(device_extensions[0])),
        .ppEnabledExtensionNames = device_extensions,
    };
    VkDevice device = VK_NULL_HANDLE;
    result = vkCreateDevice(physical_device, &device_create, NULL, &device);
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
        if (result != VK_SUCCESS ||
            (capabilities.supportedUsageFlags & VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT) == 0) {
            exit_code = fail("surface lacks color-attachment capabilities", result);
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
            .imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
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
            cmd_end_rendering(command_buffer);

            VkImageMemoryBarrier2 to_present = {
                .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
                .srcStageMask = VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
                .srcAccessMask = VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
                .dstStageMask = VK_PIPELINE_STAGE_2_NONE,
                .dstAccessMask = VK_ACCESS_2_NONE,
                .oldLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
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
            .stageMask = VK_PIPELINE_STAGE_2_ALL_GRAPHICS_BIT,
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

    char loader_buffer[32];
    char device_buffer[32];
    printf("contract=vulkan-1.3-application loader-api=%s device-api=%s "
           "device=%s driver=%s hardware-device=yes robust-buffer-access=yes "
           "dynamic-rendering=yes synchronization2=yes maintenance4=yes "
           "color-atlas-format=%s color-atlas-texture-binding=yes color-atlas-copy-dst=yes "
           "swapchain=yes external-sync-fd=yes import-signaled-fd=yes export-sync-fd=yes "
           "device-create=yes queue-submit2=yes fence-signal=yes "
           "wsi-instance=xcb,wayland ",
           version_string(loader_version, loader_buffer),
           version_string(selected_properties.properties.apiVersion, device_buffer),
           selected_properties.properties.deviceName, selected_driver.driverName,
           color_atlas_format_name(color_atlas_format));
    if (!surface) {
        printf("wsi-surface=not-requested\n");
    } else {
        printf("wsi-surface=%s surface-create=yes present-queue=yes "
               "surface-format-policy=first-capability-format surface-format=%s "
               "surface-format-id=%u present-mode=%s %s-present=yes swapchain-create=yes "
               "swapchain-extent=%ux%u swapchain-images=%u swapchain-acquire=yes "
               "swapchain-render=yes queue-present=yes present-idle=yes\n",
               native.mode == WSI_XCB ? "xcb" : "wayland",
               surface_format_name(surface_format.format), (uint32_t)surface_format.format,
               options.present_mode == VK_PRESENT_MODE_MAILBOX_KHR ? "mailbox" : "fifo",
               options.present_mode == VK_PRESENT_MODE_MAILBOX_KHR ? "mailbox" : "fifo",
               swapchain_extent.width, swapchain_extent.height, swapchain_image_count);
    }
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
