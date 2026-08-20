#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <vulkan/vulkan.h>

static int fail(const char *message, VkResult result)
{
    fprintf(stderr, "dory-vulkan-probe: %s (%d)\n", message, result);
    return 1;
}

int main(void)
{
    VkApplicationInfo application = {
        .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "dory-vulkan-probe",
        .applicationVersion = 1,
        .pEngineName = "Dory",
        .engineVersion = 1,
        .apiVersion = VK_API_VERSION_1_2,
    };
    VkInstanceCreateInfo create = {
        .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = &application,
    };
    VkInstance instance = VK_NULL_HANDLE;
    VkResult result = vkCreateInstance(&create, NULL, &instance);
    if (result != VK_SUCCESS)
        return fail("vkCreateInstance failed", result);

    uint32_t count = 0;
    result = vkEnumeratePhysicalDevices(instance, &count, NULL);
    if (result != VK_SUCCESS || count == 0) {
        vkDestroyInstance(instance, NULL);
        return fail("no Vulkan physical device", result);
    }
    VkPhysicalDevice *devices = calloc(count, sizeof(*devices));
    if (!devices) {
        vkDestroyInstance(instance, NULL);
        return fail("out of memory", VK_ERROR_OUT_OF_HOST_MEMORY);
    }
    result = vkEnumeratePhysicalDevices(instance, &count, devices);
    if (result != VK_SUCCESS) {
        free(devices);
        vkDestroyInstance(instance, NULL);
        return fail("physical-device enumeration failed", result);
    }

    int exit_code = 2;
    for (uint32_t i = 0; i < count; i++) {
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

        uint32_t extension_count = 0;
        result = vkEnumerateDeviceExtensionProperties(
            devices[i], NULL, &extension_count, NULL);
        if (result != VK_SUCCESS)
            continue;
        VkExtensionProperties *extensions = calloc(extension_count, sizeof(*extensions));
        if (!extensions) {
            exit_code = 1;
            break;
        }
        result = vkEnumerateDeviceExtensionProperties(
            devices[i], NULL, &extension_count, extensions);
        int has_swapchain = 0;
        if (result == VK_SUCCESS) {
            for (uint32_t j = 0; j < extension_count; j++) {
                if (strcmp(extensions[j].extensionName, VK_KHR_SWAPCHAIN_EXTENSION_NAME) == 0) {
                    has_swapchain = 1;
                    break;
                }
            }
        }
        free(extensions);
        if (!has_swapchain) {
            fprintf(stderr, "dory-vulkan-probe: Venus lacks VK_KHR_swapchain\n");
            exit_code = 3;
            break;
        }
        printf("device=%s driver=%s info=%s swapchain=yes\n",
               properties.properties.deviceName, driver.driverName, driver.driverInfo);
        exit_code = 0;
        break;
    }

    free(devices);
    vkDestroyInstance(instance, NULL);
    if (exit_code == 2)
        fprintf(stderr, "dory-vulkan-probe: no hardware Venus device\n");
    return exit_code;
}
