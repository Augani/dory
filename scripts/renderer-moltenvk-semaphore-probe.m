#include <vulkan/vulkan.h>

#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/*
 * Production MoltenVK hides every statically linked Vulkan call except vkGetInstanceProcAddr.
 * Qualify the exact same archive shape as virglrenderer: bind that one supported entrypoint and
 * resolve the remaining dispatch table without a Vulkan loader, ICD manifest, dlopen, or dlsym.
 */
static PFN_vkEnumerateInstanceExtensionProperties dory_vkEnumerateInstanceExtensionProperties;
static PFN_vkCreateInstance dory_vkCreateInstance;
static PFN_vkDestroyInstance dory_vkDestroyInstance;
static PFN_vkEnumeratePhysicalDevices dory_vkEnumeratePhysicalDevices;
static PFN_vkEnumerateDeviceExtensionProperties dory_vkEnumerateDeviceExtensionProperties;
static PFN_vkGetPhysicalDeviceQueueFamilyProperties dory_vkGetPhysicalDeviceQueueFamilyProperties;
static PFN_vkCreateDevice dory_vkCreateDevice;
static PFN_vkGetDeviceProcAddr dory_vkGetDeviceProcAddr;
static PFN_vkDestroyDevice dory_vkDestroyDevice;
static PFN_vkGetDeviceQueue dory_vkGetDeviceQueue;
static PFN_vkQueueSubmit dory_vkQueueSubmit;
static PFN_vkQueueWaitIdle dory_vkQueueWaitIdle;
static PFN_vkCreateSemaphore dory_vkCreateSemaphore;
static PFN_vkDestroySemaphore dory_vkDestroySemaphore;
static PFN_vkSignalSemaphore dory_vkSignalSemaphore;

#define vkEnumerateInstanceExtensionProperties dory_vkEnumerateInstanceExtensionProperties
#define vkCreateInstance dory_vkCreateInstance
#define vkDestroyInstance dory_vkDestroyInstance
#define vkEnumeratePhysicalDevices dory_vkEnumeratePhysicalDevices
#define vkEnumerateDeviceExtensionProperties dory_vkEnumerateDeviceExtensionProperties
#define vkGetPhysicalDeviceQueueFamilyProperties dory_vkGetPhysicalDeviceQueueFamilyProperties
#define vkCreateDevice dory_vkCreateDevice
#define vkGetDeviceProcAddr dory_vkGetDeviceProcAddr
#define vkDestroyDevice dory_vkDestroyDevice
#define vkGetDeviceQueue dory_vkGetDeviceQueue
#define vkQueueSubmit dory_vkQueueSubmit
#define vkQueueWaitIdle dory_vkQueueWaitIdle
#define vkCreateSemaphore dory_vkCreateSemaphore
#define vkDestroySemaphore dory_vkDestroySemaphore
#define vkSignalSemaphore dory_vkSignalSemaphore

static bool load_global_dispatch(void)
{
#define DORY_LOAD_GLOBAL(name) \
    dory_##name = (PFN_##name)vkGetInstanceProcAddr(VK_NULL_HANDLE, #name)
    DORY_LOAD_GLOBAL(vkEnumerateInstanceExtensionProperties);
    DORY_LOAD_GLOBAL(vkCreateInstance);
#undef DORY_LOAD_GLOBAL
    return vkEnumerateInstanceExtensionProperties != NULL && vkCreateInstance != NULL;
}

static bool load_instance_dispatch(VkInstance instance)
{
#define DORY_LOAD_INSTANCE(name) \
    dory_##name = (PFN_##name)vkGetInstanceProcAddr(instance, #name)
    DORY_LOAD_INSTANCE(vkDestroyInstance);
    DORY_LOAD_INSTANCE(vkEnumeratePhysicalDevices);
    DORY_LOAD_INSTANCE(vkEnumerateDeviceExtensionProperties);
    DORY_LOAD_INSTANCE(vkGetPhysicalDeviceQueueFamilyProperties);
    DORY_LOAD_INSTANCE(vkCreateDevice);
    DORY_LOAD_INSTANCE(vkGetDeviceProcAddr);
#undef DORY_LOAD_INSTANCE
    return vkDestroyInstance != NULL && vkEnumeratePhysicalDevices != NULL &&
        vkEnumerateDeviceExtensionProperties != NULL &&
        vkGetPhysicalDeviceQueueFamilyProperties != NULL && vkCreateDevice != NULL &&
        vkGetDeviceProcAddr != NULL;
}

static bool validate_hidden_alias_dispatch(VkInstance instance)
{
    const PFN_vkVoidFunction release_khr =
        vkGetInstanceProcAddr(instance, "vkReleaseSwapchainImagesKHR");
    const PFN_vkVoidFunction release_ext =
        vkGetInstanceProcAddr(instance, "vkReleaseSwapchainImagesEXT");
    return release_khr != NULL && release_ext == release_khr;
}

static bool load_device_dispatch(VkDevice device)
{
#define DORY_LOAD_DEVICE(name) \
    dory_##name = (PFN_##name)vkGetDeviceProcAddr(device, #name)
    DORY_LOAD_DEVICE(vkDestroyDevice);
    DORY_LOAD_DEVICE(vkGetDeviceQueue);
    DORY_LOAD_DEVICE(vkQueueSubmit);
    DORY_LOAD_DEVICE(vkQueueWaitIdle);
    DORY_LOAD_DEVICE(vkCreateSemaphore);
    DORY_LOAD_DEVICE(vkDestroySemaphore);
    DORY_LOAD_DEVICE(vkSignalSemaphore);
#undef DORY_LOAD_DEVICE
    return vkDestroyDevice != NULL && vkGetDeviceQueue != NULL &&
        vkQueueSubmit != NULL && vkQueueWaitIdle != NULL &&
        vkCreateSemaphore != NULL && vkDestroySemaphore != NULL &&
        vkSignalSemaphore != NULL;
}

static int fail(const char *operation, VkResult result)
{
    fprintf(stderr, "dory-moltenvk-semaphore-probe: %s (%d)\n", operation, result);
    return 1;
}

static int has_extension(
    const VkExtensionProperties *extensions,
    uint32_t count,
    const char *name
)
{
    for (uint32_t index = 0; index < count; ++index) {
        if (strcmp(extensions[index].extensionName, name) == 0)
            return 1;
    }
    return 0;
}

static VkResult signal_and_finish(VkQueue queue, VkSemaphore semaphore)
{
    const VkSubmitInfo submit = {
        .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .signalSemaphoreCount = 1,
        .pSignalSemaphores = &semaphore,
    };
    VkResult result = vkQueueSubmit(queue, 1, &submit, VK_NULL_HANDLE);
    return result == VK_SUCCESS ? vkQueueWaitIdle(queue) : result;
}

typedef struct ExportTask {
    PFN_vkGetSemaphoreFdKHR export_fd;
    VkDevice device;
    VkSemaphore semaphore;
    atomic_bool started;
    atomic_bool completed;
    VkResult result;
    int fd;
} ExportTask;

static void *export_semaphore(void *context)
{
    ExportTask *task = context;
    const VkSemaphoreGetFdInfoKHR get_fd = {
        .sType = VK_STRUCTURE_TYPE_SEMAPHORE_GET_FD_INFO_KHR,
        .semaphore = task->semaphore,
        .handleType = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT,
    };
    atomic_store_explicit(&task->started, true, memory_order_release);
    task->result = task->export_fd(task->device, &get_fd, &task->fd);
    atomic_store_explicit(&task->completed, true, memory_order_release);
    return NULL;
}

static int wait_for_flag(atomic_bool *flag, uint32_t timeout_ms)
{
    const struct timespec interval = { .tv_nsec = 1000000 };
    for (uint32_t elapsed = 0; elapsed < timeout_ms; ++elapsed) {
        if (atomic_load_explicit(flag, memory_order_acquire))
            return 1;
        nanosleep(&interval, NULL);
    }
    return atomic_load_explicit(flag, memory_order_acquire);
}

static VkResult export_now(
    PFN_vkGetSemaphoreFdKHR export_fd,
    VkDevice device,
    VkSemaphore semaphore
)
{
    const VkSemaphoreGetFdInfoKHR get_fd = {
        .sType = VK_STRUCTURE_TYPE_SEMAPHORE_GET_FD_INFO_KHR,
        .semaphore = semaphore,
        .handleType = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT,
    };
    int fd = -2;
    const VkResult result = export_fd(device, &get_fd, &fd);
    return result == VK_SUCCESS && fd == -1 ? VK_SUCCESS : VK_ERROR_UNKNOWN;
}

static VkResult import_signaled(
    PFN_vkImportSemaphoreFdKHR import_fd,
    VkDevice device,
    VkSemaphore semaphore
)
{
    const VkImportSemaphoreFdInfoKHR import = {
        .sType = VK_STRUCTURE_TYPE_IMPORT_SEMAPHORE_FD_INFO_KHR,
        .semaphore = semaphore,
        .flags = VK_SEMAPHORE_IMPORT_TEMPORARY_BIT,
        .handleType = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT,
        .fd = -1,
    };
    return import_fd(device, &import);
}

static int gated_signal_and_export(
    VkDevice device,
    VkQueue queue,
    VkSemaphore timeline_gate,
    uint64_t gate_value,
    VkSemaphore semaphore,
    PFN_vkGetSemaphoreFdKHR export_fd
)
{
    const uint64_t binary_signal_value = 0;
    const VkTimelineSemaphoreSubmitInfo timeline_submit = {
        .sType = VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO,
        .waitSemaphoreValueCount = 1,
        .pWaitSemaphoreValues = &gate_value,
        .signalSemaphoreValueCount = 1,
        .pSignalSemaphoreValues = &binary_signal_value,
    };
    const VkPipelineStageFlags wait_stage = VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT;
    const VkSubmitInfo submit = {
        .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .pNext = &timeline_submit,
        .waitSemaphoreCount = 1,
        .pWaitSemaphores = &timeline_gate,
        .pWaitDstStageMask = &wait_stage,
        .signalSemaphoreCount = 1,
        .pSignalSemaphores = &semaphore,
    };
    VkResult result = vkQueueSubmit(queue, 1, &submit, VK_NULL_HANDLE);
    if (result != VK_SUCCESS)
        return fail("gated semaphore signal submission failed", result);

    ExportTask task = {
        .export_fd = export_fd,
        .device = device,
        .semaphore = semaphore,
        .result = VK_NOT_READY,
        .fd = -2,
    };
    atomic_init(&task.started, false);
    atomic_init(&task.completed, false);
    pthread_t thread;
    if (pthread_create(&thread, NULL, export_semaphore, &task) != 0) {
        const VkSemaphoreSignalInfo release_gate = {
            .sType = VK_STRUCTURE_TYPE_SEMAPHORE_SIGNAL_INFO,
            .semaphore = timeline_gate,
            .value = gate_value,
        };
        (void)vkSignalSemaphore(device, &release_gate);
        (void)vkQueueWaitIdle(queue);
        return fail("export thread creation failed", VK_ERROR_INITIALIZATION_FAILED);
    }

    const int started = wait_for_flag(&task.started, 1000);
    const int completed_before_signal = wait_for_flag(&task.completed, 100);
    const VkSemaphoreSignalInfo signal_gate = {
        .sType = VK_STRUCTURE_TYPE_SEMAPHORE_SIGNAL_INFO,
        .semaphore = timeline_gate,
        .value = gate_value,
    };
    result = vkSignalSemaphore(device, &signal_gate);
    if (result != VK_SUCCESS) {
        fprintf(stderr, "dory-moltenvk-semaphore-probe: timeline gate signal failed (%d)\n", result);
        _Exit(1);
    }
    if (!wait_for_flag(&task.completed, 5000)) {
        fprintf(stderr, "dory-moltenvk-semaphore-probe: gated export did not complete\n");
        _Exit(1);
    }
    pthread_join(thread, NULL);
    result = vkQueueWaitIdle(queue);
    if (result != VK_SUCCESS)
        return fail("queue did not finish after timeline release", result);
    if (!started)
        return fail("export thread did not start promptly", VK_TIMEOUT);
    if (task.result != VK_SUCCESS || task.fd != -1)
        return fail("gated sync-fd export failed", task.result);
    if (completed_before_signal)
        return fail("export reused an already-consumed binary generation", VK_ERROR_UNKNOWN);
    return 0;
}

static int qualify_device(VkPhysicalDevice physical_device)
{
    uint32_t extension_count = 0;
    VkResult result = vkEnumerateDeviceExtensionProperties(
        physical_device, NULL, &extension_count, NULL);
    if (result != VK_SUCCESS)
        return fail("device extension count failed", result);
    VkExtensionProperties *extensions = calloc(extension_count, sizeof(*extensions));
    if (extensions == NULL)
        return fail("device extension allocation failed", VK_ERROR_OUT_OF_HOST_MEMORY);
    result = vkEnumerateDeviceExtensionProperties(
        physical_device, NULL, &extension_count, extensions);
    if (result != VK_SUCCESS) {
        free(extensions);
        return fail("device extension enumeration failed", result);
    }
    if (!has_extension(
            extensions, extension_count, VK_KHR_EXTERNAL_SEMAPHORE_FD_EXTENSION_NAME)) {
        free(extensions);
        return fail("required semaphore extensions unavailable", VK_ERROR_EXTENSION_NOT_PRESENT);
    }

    const char *device_extensions[2] = {
        VK_KHR_EXTERNAL_SEMAPHORE_FD_EXTENSION_NAME,
    };
    uint32_t enabled_extension_count = 1;
    if (has_extension(extensions, extension_count, "VK_KHR_portability_subset"))
        device_extensions[enabled_extension_count++] = "VK_KHR_portability_subset";
    free(extensions);

    uint32_t queue_family_count = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(
        physical_device, &queue_family_count, NULL);
    VkQueueFamilyProperties *queue_families =
        calloc(queue_family_count, sizeof(*queue_families));
    if (queue_families == NULL)
        return fail("queue family allocation failed", VK_ERROR_OUT_OF_HOST_MEMORY);
    vkGetPhysicalDeviceQueueFamilyProperties(
        physical_device, &queue_family_count, queue_families);
    uint32_t queue_family_index = queue_family_count;
    for (uint32_t index = 0; index < queue_family_count; ++index) {
        if (queue_families[index].queueCount > 0) {
            queue_family_index = index;
            break;
        }
    }
    free(queue_families);
    if (queue_family_index == queue_family_count)
        return fail("no Vulkan queue family", VK_ERROR_INITIALIZATION_FAILED);

    const float priority = 1.0f;
    const VkDeviceQueueCreateInfo queue_create = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = queue_family_index,
        .queueCount = 1,
        .pQueuePriorities = &priority,
    };
    const VkPhysicalDeviceTimelineSemaphoreFeatures timeline_feature = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TIMELINE_SEMAPHORE_FEATURES,
        .timelineSemaphore = VK_TRUE,
    };
    const VkDeviceCreateInfo device_create = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .pNext = &timeline_feature,
        .queueCreateInfoCount = 1,
        .pQueueCreateInfos = &queue_create,
        .enabledExtensionCount = enabled_extension_count,
        .ppEnabledExtensionNames = device_extensions,
    };
    VkDevice device = VK_NULL_HANDLE;
    result = vkCreateDevice(physical_device, &device_create, NULL, &device);
    if (result != VK_SUCCESS)
        return fail("vkCreateDevice failed", result);
    if (!load_device_dispatch(device))
        return fail("MoltenVK device dispatch is incomplete", VK_ERROR_INITIALIZATION_FAILED);

    PFN_vkImportSemaphoreFdKHR import_fd =
        (PFN_vkImportSemaphoreFdKHR)vkGetDeviceProcAddr(
            device, "vkImportSemaphoreFdKHR");
    PFN_vkGetSemaphoreFdKHR export_fd =
        (PFN_vkGetSemaphoreFdKHR)vkGetDeviceProcAddr(device, "vkGetSemaphoreFdKHR");
    if (import_fd == NULL || export_fd == NULL) {
        vkDestroyDevice(device, NULL);
        return fail("required semaphore entry point unavailable", VK_ERROR_EXTENSION_NOT_PRESENT);
    }

    const VkExportSemaphoreCreateInfo fd_export_create = {
        .sType = VK_STRUCTURE_TYPE_EXPORT_SEMAPHORE_CREATE_INFO,
        .handleTypes = VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT,
    };
    const VkSemaphoreCreateInfo semaphore_create = {
        .sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
        .pNext = &fd_export_create,
    };
    VkSemaphore semaphore = VK_NULL_HANDLE;
    result = vkCreateSemaphore(device, &semaphore_create, NULL, &semaphore);
    if (result != VK_SUCCESS) {
        vkDestroyDevice(device, NULL);
        return fail("vkCreateSemaphore failed", result);
    }

    const VkSemaphoreTypeCreateInfo timeline_type = {
        .sType = VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO,
        .semaphoreType = VK_SEMAPHORE_TYPE_TIMELINE,
        .initialValue = 0,
    };
    const VkSemaphoreCreateInfo timeline_create = {
        .sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
        .pNext = &timeline_type,
    };
    VkSemaphore timeline_gate = VK_NULL_HANDLE;
    result = vkCreateSemaphore(device, &timeline_create, NULL, &timeline_gate);
    if (result != VK_SUCCESS) {
        vkDestroySemaphore(device, semaphore, NULL);
        vkDestroyDevice(device, NULL);
        return fail("timeline gate creation failed", result);
    }

    VkQueue queue = VK_NULL_HANDLE;
    vkGetDeviceQueue(device, queue_family_index, 0, &queue);
    result = signal_and_finish(queue, semaphore);
    if (result == VK_SUCCESS)
        result = export_now(export_fd, device, semaphore);
    if (result == VK_SUCCESS &&
        gated_signal_and_export(
            device, queue, timeline_gate, 1, semaphore, export_fd) != 0) {
        result = VK_ERROR_UNKNOWN;
    }

    for (uint64_t cycle = 0; result == VK_SUCCESS && cycle < 2; ++cycle) {
        result = import_signaled(import_fd, device, semaphore);
        if (result == VK_SUCCESS)
            result = export_now(export_fd, device, semaphore);
        if (result == VK_SUCCESS &&
            gated_signal_and_export(
                device, queue, timeline_gate, cycle + 2, semaphore, export_fd) != 0) {
            result = VK_ERROR_UNKNOWN;
        }
    }

    vkDestroySemaphore(device, timeline_gate, NULL);
    vkDestroySemaphore(device, semaphore, NULL);
    vkDestroyDevice(device, NULL);
    if (result != VK_SUCCESS)
        return fail("binary semaphore generation cycle failed", result);
    printf("moltenvk.sync-fd.signal-export-generations=2\n");
    printf("moltenvk.sync-fd.import-export-generations=2\n");
    return 0;
}

int main(void)
{
    @autoreleasepool {
        if (!load_global_dispatch())
            return fail("MoltenVK global dispatch is incomplete", VK_ERROR_INITIALIZATION_FAILED);
        uint32_t instance_extension_count = 0;
        VkResult result = vkEnumerateInstanceExtensionProperties(
            NULL, &instance_extension_count, NULL);
        if (result != VK_SUCCESS)
            return fail("instance extension count failed", result);
        VkExtensionProperties *instance_extensions =
            calloc(instance_extension_count, sizeof(*instance_extensions));
        if (instance_extensions == NULL)
            return fail("instance extension allocation failed", VK_ERROR_OUT_OF_HOST_MEMORY);
        result = vkEnumerateInstanceExtensionProperties(
            NULL, &instance_extension_count, instance_extensions);
        if (result != VK_SUCCESS) {
            free(instance_extensions);
            return fail("instance extension enumeration failed", result);
        }
        const int has_portability_enumeration = has_extension(
            instance_extensions,
            instance_extension_count,
            VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME);
        free(instance_extensions);
        const char *enabled_instance_extensions[] = {
            VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME,
        };
        const VkApplicationInfo application = {
            .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
            .pApplicationName = "dory-moltenvk-semaphore-probe",
            .applicationVersion = 1,
            .pEngineName = "Dory",
            .engineVersion = 1,
            .apiVersion = VK_API_VERSION_1_2,
        };
        const VkInstanceCreateInfo instance_create = {
            .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .flags = has_portability_enumeration
                ? VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR
                : 0,
            .pApplicationInfo = &application,
            .enabledExtensionCount = has_portability_enumeration ? 1 : 0,
            .ppEnabledExtensionNames = has_portability_enumeration
                ? enabled_instance_extensions
                : NULL,
        };
        VkInstance instance = VK_NULL_HANDLE;
        result = vkCreateInstance(&instance_create, NULL, &instance);
        if (result != VK_SUCCESS)
            return fail("vkCreateInstance failed", result);
        if (!load_instance_dispatch(instance))
            return fail("MoltenVK instance dispatch is incomplete", VK_ERROR_INITIALIZATION_FAILED);
        if (!validate_hidden_alias_dispatch(instance)) {
            vkDestroyInstance(instance, NULL);
            return fail("MoltenVK hidden alias dispatch differs", VK_ERROR_INITIALIZATION_FAILED);
        }

        uint32_t device_count = 0;
        result = vkEnumeratePhysicalDevices(instance, &device_count, NULL);
        if (result != VK_SUCCESS || device_count == 0) {
            vkDestroyInstance(instance, NULL);
            return fail("no MoltenVK physical device", result);
        }
        VkPhysicalDevice *devices = calloc(device_count, sizeof(*devices));
        if (devices == NULL) {
            vkDestroyInstance(instance, NULL);
            return fail("physical device allocation failed", VK_ERROR_OUT_OF_HOST_MEMORY);
        }
        result = vkEnumeratePhysicalDevices(instance, &device_count, devices);
        int exit_code = result == VK_SUCCESS
            ? qualify_device(devices[0])
            : fail("physical device enumeration failed", result);
        free(devices);
        vkDestroyInstance(instance, NULL);
        return exit_code;
    }
}
