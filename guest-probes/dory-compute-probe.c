#define _POSIX_C_SOURCE 200809L

#include <ctype.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <vulkan/vulkan.h>

#define DORY_VALUE_COUNT (1024u * 1024u)
#define DORY_LOCAL_SIZE 256u

static int fail(const char *message, VkResult result)
{
    if (result == VK_SUCCESS)
        fprintf(stderr, "dory-compute-probe: %s\n", message);
    else
        fprintf(stderr, "dory-compute-probe: %s (%d)\n", message, result);
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
        case '\b': fputs("\\b", stdout); break;
        case '\f': fputs("\\f", stdout); break;
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

static int contains_ignoring_case(const char *text, const char *needle)
{
    size_t needle_count = strlen(needle);
    for (; *text; text++) {
        size_t index = 0;
        while (index < needle_count && text[index] &&
               tolower((unsigned char)text[index]) ==
                   tolower((unsigned char)needle[index]))
            index++;
        if (index == needle_count)
            return 1;
    }
    return 0;
}

static uint32_t find_host_visible_memory_type(VkPhysicalDevice device, uint32_t allowed,
                                              VkBool32 require_noncoherent,
                                              VkBool32 *coherent)
{
    VkPhysicalDeviceMemoryProperties properties = {0};
    vkGetPhysicalDeviceMemoryProperties(device, &properties);
    uint32_t fallback = UINT32_MAX;
    for (uint32_t index = 0; index < properties.memoryTypeCount; index++) {
        VkMemoryPropertyFlags flags = properties.memoryTypes[index].propertyFlags;
        if ((allowed & (1u << index)) == 0 ||
            (flags & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT) == 0)
            continue;
        if (!require_noncoherent &&
            (flags & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) != 0) {
            *coherent = VK_TRUE;
            return index;
        }
        if ((flags & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) == 0 &&
            fallback == UINT32_MAX)
            fallback = index;
    }
    *coherent = VK_FALSE;
    return fallback;
}

struct host_buffer {
    VkBuffer buffer;
    VkDeviceMemory memory;
    void *mapping;
    VkBool32 coherent;
};

static int create_host_buffer(VkPhysicalDevice physical_device, VkDevice device,
                              VkDeviceSize size, VkBool32 require_noncoherent,
                              struct host_buffer *result)
{
    *result = (struct host_buffer){0};
    VkBufferCreateInfo create = {
        .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = size,
        .usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
    };
    VkResult status = vkCreateBuffer(device, &create, NULL, &result->buffer);
    if (status != VK_SUCCESS)
        return fail("vkCreateBuffer failed", status);
    VkMemoryRequirements requirements = {0};
    vkGetBufferMemoryRequirements(device, result->buffer, &requirements);
    uint32_t memory_type = find_host_visible_memory_type(
        physical_device, requirements.memoryTypeBits,
        require_noncoherent, &result->coherent);
    if (memory_type == UINT32_MAX)
        return fail(require_noncoherent
                        ? "no noncoherent host-visible Vulkan memory type"
                        : "no host-visible Vulkan memory type", VK_SUCCESS);
    VkMemoryAllocateInfo allocate = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = requirements.size,
        .memoryTypeIndex = memory_type,
    };
    status = vkAllocateMemory(device, &allocate, NULL, &result->memory);
    if (status != VK_SUCCESS)
        return fail("vkAllocateMemory failed", status);
    status = vkBindBufferMemory(device, result->buffer, result->memory, 0);
    if (status != VK_SUCCESS)
        return fail("vkBindBufferMemory failed", status);
    // Map the whole allocation so VK_WHOLE_SIZE covers the noncoherent atom-aligned tail.
    status = vkMapMemory(device, result->memory, 0, VK_WHOLE_SIZE, 0, &result->mapping);
    return status == VK_SUCCESS ? 0 : fail("vkMapMemory failed", status);
}

static int synchronize_host_buffer(VkDevice device, const struct host_buffer *buffer,
                                   VkBool32 device_wrote)
{
    if (buffer->coherent)
        return 0;
    VkMappedMemoryRange range = {
        .sType = VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE,
        .memory = buffer->memory,
        .offset = 0,
        .size = VK_WHOLE_SIZE,
    };
    VkResult status = device_wrote
        ? vkInvalidateMappedMemoryRanges(device, 1, &range)
        : vkFlushMappedMemoryRanges(device, 1, &range);
    return status == VK_SUCCESS ? 0 : fail(
        device_wrote ? "vkInvalidateMappedMemoryRanges failed"
                     : "vkFlushMappedMemoryRanges failed", status);
}

static void destroy_host_buffer(VkDevice device, struct host_buffer *buffer)
{
    if (buffer->mapping)
        vkUnmapMemory(device, buffer->memory);
    if (buffer->buffer)
        vkDestroyBuffer(device, buffer->buffer, NULL);
    if (buffer->memory)
        vkFreeMemory(device, buffer->memory, NULL);
    memset(buffer, 0, sizeof(*buffer));
}

static uint32_t *read_spirv(const char *path, size_t *byte_count)
{
    *byte_count = 0;
    FILE *file = fopen(path, "rb");
    if (!file)
        return NULL;
    if (fseek(file, 0, SEEK_END) != 0) {
        fclose(file);
        return NULL;
    }
    long length = ftell(file);
    if (length <= 0 || (length % 4) != 0 || fseek(file, 0, SEEK_SET) != 0) {
        fclose(file);
        return NULL;
    }
    uint32_t *words = malloc((size_t)length);
    if (!words) {
        fclose(file);
        return NULL;
    }
    if (fread(words, 1, (size_t)length, file) != (size_t)length) {
        free(words);
        fclose(file);
        return NULL;
    }
    fclose(file);
    *byte_count = (size_t)length;
    return words;
}

static const char *version_string(uint32_t version, char result[32])
{
    snprintf(result, 32, "%u.%u.%u", VK_API_VERSION_MAJOR(version),
             VK_API_VERSION_MINOR(version), VK_API_VERSION_PATCH(version));
    return result;
}

int main(int argc, char **argv)
{
    const char *nonce = "dory-compute-default";
    const char *shader_path = "dory-compute-reduce.spv";
    VkBool32 require_noncoherent = VK_FALSE;
    for (int index = 1; index < argc; index++) {
        if (strncmp(argv[index], "--nonce=", 8) == 0 && argv[index][8])
            nonce = argv[index] + 8;
        else if (strncmp(argv[index], "--shader=", 9) == 0 && argv[index][9])
            shader_path = argv[index] + 9;
        else if (strcmp(argv[index], "--memory=noncoherent") == 0)
            require_noncoherent = VK_TRUE;
        else {
            fprintf(stderr, "usage: %s [--nonce=VALUE] [--shader=PATH] [--memory=noncoherent]\n", argv[0]);
            return 64;
        }
    }

    int exit_code = 1;
    VkInstance instance = VK_NULL_HANDLE;
    VkDevice device = VK_NULL_HANDLE;
    VkDescriptorSetLayout set_layout = VK_NULL_HANDLE;
    VkDescriptorPool descriptor_pool = VK_NULL_HANDLE;
    VkPipelineLayout pipeline_layout = VK_NULL_HANDLE;
    VkShaderModule shader = VK_NULL_HANDLE;
    VkPipeline pipeline = VK_NULL_HANDLE;
    VkCommandPool command_pool = VK_NULL_HANDLE;
    VkFence fence = VK_NULL_HANDLE;
    struct host_buffer buffers[2] = {0};
    VkPhysicalDevice physical_device = VK_NULL_HANDLE;
    VkPhysicalDeviceProperties2 selected_properties = {0};
    VkPhysicalDeviceDriverProperties selected_driver = {0};
    uint32_t queue_family = UINT32_MAX;
    uint64_t started = monotonic_nanoseconds();

    VkApplicationInfo application = {
        .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "dory-compute-probe",
        .applicationVersion = 1,
        .pEngineName = "Dory guest probe",
        .engineVersion = 1,
        .apiVersion = VK_API_VERSION_1_2,
    };
    VkInstanceCreateInfo instance_create = {
        .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = &application,
    };
    VkResult status = vkCreateInstance(&instance_create, NULL, &instance);
    if (status != VK_SUCCESS)
        return fail("vkCreateInstance failed", status);

    uint32_t device_count = 0;
    status = vkEnumeratePhysicalDevices(instance, &device_count, NULL);
    if (status != VK_SUCCESS || device_count == 0) {
        exit_code = fail("no Vulkan physical device", status);
        goto cleanup;
    }
    VkPhysicalDevice *physical_devices = calloc(device_count, sizeof(*physical_devices));
    if (!physical_devices) {
        exit_code = fail("out of memory", VK_ERROR_OUT_OF_HOST_MEMORY);
        goto cleanup;
    }
    status = vkEnumeratePhysicalDevices(instance, &device_count, physical_devices);
    for (uint32_t index = 0; status == VK_SUCCESS && index < device_count; index++) {
        VkPhysicalDeviceDriverProperties driver = {
            .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES,
        };
        VkPhysicalDeviceProperties2 properties = {
            .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2,
            .pNext = &driver,
        };
        vkGetPhysicalDeviceProperties2(physical_devices[index], &properties);
        if (properties.properties.deviceType == VK_PHYSICAL_DEVICE_TYPE_CPU ||
            contains_ignoring_case(properties.properties.deviceName, "llvmpipe") ||
            contains_ignoring_case(properties.properties.deviceName, "lavapipe") ||
            contains_ignoring_case(driver.driverName, "llvmpipe") ||
            contains_ignoring_case(driver.driverName, "lavapipe"))
            continue;
        uint32_t family_count = 0;
        vkGetPhysicalDeviceQueueFamilyProperties(
            physical_devices[index], &family_count, NULL);
        VkQueueFamilyProperties *families = calloc(family_count, sizeof(*families));
        if (!families)
            continue;
        vkGetPhysicalDeviceQueueFamilyProperties(
            physical_devices[index], &family_count, families);
        for (uint32_t family = 0; family < family_count; family++) {
            if (families[family].queueCount > 0 &&
                (families[family].queueFlags & VK_QUEUE_COMPUTE_BIT) != 0) {
                physical_device = physical_devices[index];
                selected_properties = properties;
                selected_driver = driver;
                queue_family = family;
                break;
            }
        }
        free(families);
        if (physical_device)
            break;
    }
    free(physical_devices);
    if (!physical_device) {
        exit_code = fail("no hardware Vulkan compute device; llvmpipe/lavapipe are rejected",
                         VK_SUCCESS);
        goto cleanup;
    }

    float priority = 1.0f;
    VkDeviceQueueCreateInfo queue_create = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = queue_family,
        .queueCount = 1,
        .pQueuePriorities = &priority,
    };
    VkDeviceCreateInfo device_create = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .queueCreateInfoCount = 1,
        .pQueueCreateInfos = &queue_create,
    };
    status = vkCreateDevice(physical_device, &device_create, NULL, &device);
    if (status != VK_SUCCESS) {
        exit_code = fail("vkCreateDevice failed", status);
        goto cleanup;
    }
    VkQueue queue = VK_NULL_HANDLE;
    vkGetDeviceQueue(device, queue_family, 0, &queue);

    const VkDeviceSize buffer_size = DORY_VALUE_COUNT * sizeof(uint32_t);
    if (create_host_buffer(physical_device, device, buffer_size,
                           require_noncoherent, &buffers[0]) != 0 ||
        create_host_buffer(physical_device, device, buffer_size,
                           require_noncoherent, &buffers[1]) != 0)
        goto cleanup;

    uint64_t nonce_hash = fnv1a(nonce, strlen(nonce), UINT64_C(14695981039346656037));
    uint32_t seed = (uint32_t)(nonce_hash ^ (nonce_hash >> 32));
    uint32_t expected = 0;
    uint32_t *input = buffers[0].mapping;
    for (uint32_t index = 0; index < DORY_VALUE_COUNT; index++) {
        uint32_t value = ((index ^ seed) * 17u + 23u) % 251u;
        input[index] = value;
        expected += value;
    }
    memset(buffers[1].mapping, 0, (size_t)buffer_size);
    if (synchronize_host_buffer(device, &buffers[0], VK_FALSE) != 0 ||
        synchronize_host_buffer(device, &buffers[1], VK_FALSE) != 0)
        goto cleanup;

    VkDescriptorSetLayoutBinding bindings[2] = {
        {.binding = 0, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
         .descriptorCount = 1, .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT},
        {.binding = 1, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
         .descriptorCount = 1, .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT},
    };
    VkDescriptorSetLayoutCreateInfo set_layout_create = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .bindingCount = 2,
        .pBindings = bindings,
    };
    status = vkCreateDescriptorSetLayout(device, &set_layout_create, NULL, &set_layout);
    if (status != VK_SUCCESS) {
        exit_code = fail("vkCreateDescriptorSetLayout failed", status);
        goto cleanup;
    }
    VkPushConstantRange push_range = {
        .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT,
        .size = sizeof(uint32_t),
    };
    VkPipelineLayoutCreateInfo pipeline_layout_create = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = 1,
        .pSetLayouts = &set_layout,
        .pushConstantRangeCount = 1,
        .pPushConstantRanges = &push_range,
    };
    status = vkCreatePipelineLayout(
        device, &pipeline_layout_create, NULL, &pipeline_layout);
    if (status != VK_SUCCESS) {
        exit_code = fail("vkCreatePipelineLayout failed", status);
        goto cleanup;
    }

    size_t shader_bytes = 0;
    uint32_t *shader_words = read_spirv(shader_path, &shader_bytes);
    if (!shader_words) {
        exit_code = fail("could not read the compiled reduction shader", VK_SUCCESS);
        goto cleanup;
    }
    VkShaderModuleCreateInfo shader_create = {
        .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = shader_bytes,
        .pCode = shader_words,
    };
    status = vkCreateShaderModule(device, &shader_create, NULL, &shader);
    free(shader_words);
    if (status != VK_SUCCESS) {
        exit_code = fail("vkCreateShaderModule failed", status);
        goto cleanup;
    }
    VkComputePipelineCreateInfo pipeline_create = {
        .sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
        .stage = {
            .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage = VK_SHADER_STAGE_COMPUTE_BIT,
            .module = shader,
            .pName = "main",
        },
        .layout = pipeline_layout,
    };
    status = vkCreateComputePipelines(
        device, VK_NULL_HANDLE, 1, &pipeline_create, NULL, &pipeline);
    if (status != VK_SUCCESS) {
        exit_code = fail("vkCreateComputePipelines failed", status);
        goto cleanup;
    }

    VkDescriptorPoolSize pool_size = {
        .type = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
        .descriptorCount = 4,
    };
    VkDescriptorPoolCreateInfo pool_create = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .maxSets = 2,
        .poolSizeCount = 1,
        .pPoolSizes = &pool_size,
    };
    status = vkCreateDescriptorPool(device, &pool_create, NULL, &descriptor_pool);
    if (status != VK_SUCCESS) {
        exit_code = fail("vkCreateDescriptorPool failed", status);
        goto cleanup;
    }
    VkDescriptorSetLayout layouts[2] = {set_layout, set_layout};
    VkDescriptorSetAllocateInfo set_allocate = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .descriptorPool = descriptor_pool,
        .descriptorSetCount = 2,
        .pSetLayouts = layouts,
    };
    VkDescriptorSet sets[2] = {VK_NULL_HANDLE, VK_NULL_HANDLE};
    status = vkAllocateDescriptorSets(device, &set_allocate, sets);
    if (status != VK_SUCCESS) {
        exit_code = fail("vkAllocateDescriptorSets failed", status);
        goto cleanup;
    }
    VkDescriptorBufferInfo infos[4] = {
        {.buffer = buffers[0].buffer, .range = buffer_size},
        {.buffer = buffers[1].buffer, .range = buffer_size},
        {.buffer = buffers[1].buffer, .range = buffer_size},
        {.buffer = buffers[0].buffer, .range = buffer_size},
    };
    VkWriteDescriptorSet writes[4] = {0};
    for (uint32_t index = 0; index < 4; index++) {
        writes[index] = (VkWriteDescriptorSet){
            .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstSet = sets[index / 2],
            .dstBinding = index % 2,
            .descriptorCount = 1,
            .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .pBufferInfo = &infos[index],
        };
    }
    vkUpdateDescriptorSets(device, 4, writes, 0, NULL);

    VkCommandPoolCreateInfo command_pool_create = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .queueFamilyIndex = queue_family,
    };
    status = vkCreateCommandPool(device, &command_pool_create, NULL, &command_pool);
    if (status != VK_SUCCESS) {
        exit_code = fail("vkCreateCommandPool failed", status);
        goto cleanup;
    }
    VkCommandBufferAllocateInfo command_allocate = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = command_pool,
        .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    };
    VkCommandBuffer command = VK_NULL_HANDLE;
    status = vkAllocateCommandBuffers(device, &command_allocate, &command);
    if (status != VK_SUCCESS) {
        exit_code = fail("vkAllocateCommandBuffers failed", status);
        goto cleanup;
    }
    VkCommandBufferBeginInfo begin = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    };
    status = vkBeginCommandBuffer(command, &begin);
    if (status != VK_SUCCESS) {
        exit_code = fail("vkBeginCommandBuffer failed", status);
        goto cleanup;
    }
    VkMemoryBarrier host_to_compute = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER,
        .srcAccessMask = VK_ACCESS_HOST_WRITE_BIT,
        .dstAccessMask = VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_SHADER_WRITE_BIT,
    };
    vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_HOST_BIT,
                         VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0,
                         1, &host_to_compute, 0, NULL, 0, NULL);
    vkCmdBindPipeline(command, VK_PIPELINE_BIND_POINT_COMPUTE, pipeline);
    uint32_t counts[3] = {DORY_VALUE_COUNT, DORY_VALUE_COUNT / 256u,
                          DORY_VALUE_COUNT / (256u * 256u)};
    for (uint32_t pass = 0; pass < 3; pass++) {
        VkDescriptorSet set = sets[pass % 2];
        vkCmdBindDescriptorSets(command, VK_PIPELINE_BIND_POINT_COMPUTE,
                                pipeline_layout, 0, 1, &set, 0, NULL);
        vkCmdPushConstants(command, pipeline_layout, VK_SHADER_STAGE_COMPUTE_BIT,
                           0, sizeof(counts[pass]), &counts[pass]);
        vkCmdDispatch(command, (counts[pass] + DORY_LOCAL_SIZE - 1) / DORY_LOCAL_SIZE,
                      1, 1);
        if (pass != 2) {
            VkMemoryBarrier barrier = {
                .sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER,
                .srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT,
                .dstAccessMask = VK_ACCESS_SHADER_READ_BIT,
            };
            vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                                 VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0,
                                 1, &barrier, 0, NULL, 0, NULL);
        }
    }
    VkMemoryBarrier compute_to_host = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER,
        .srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT,
        .dstAccessMask = VK_ACCESS_HOST_READ_BIT,
    };
    vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                         VK_PIPELINE_STAGE_HOST_BIT, 0,
                         1, &compute_to_host, 0, NULL, 0, NULL);
    status = vkEndCommandBuffer(command);
    if (status != VK_SUCCESS) {
        exit_code = fail("vkEndCommandBuffer failed", status);
        goto cleanup;
    }
    VkFenceCreateInfo fence_create = {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
    status = vkCreateFence(device, &fence_create, NULL, &fence);
    if (status != VK_SUCCESS) {
        exit_code = fail("vkCreateFence failed", status);
        goto cleanup;
    }
    VkSubmitInfo submit = {
        .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .commandBufferCount = 1,
        .pCommandBuffers = &command,
    };
    uint64_t gpu_started = monotonic_nanoseconds();
    status = vkQueueSubmit(queue, 1, &submit, fence);
    if (status == VK_SUCCESS)
        status = vkWaitForFences(device, 1, &fence, VK_TRUE, UINT64_C(10000000000));
    uint64_t gpu_finished = monotonic_nanoseconds();
    if (status != VK_SUCCESS) {
        exit_code = fail("compute submission did not complete", status);
        goto cleanup;
    }

    if (synchronize_host_buffer(device, &buffers[1], VK_TRUE) != 0)
        goto cleanup;
    uint32_t actual = ((uint32_t *)buffers[1].mapping)[0];
    if (actual != expected) {
        fprintf(stderr, "dory-compute-probe: reduction mismatch: expected=%u actual=%u\n",
                expected, actual);
        goto cleanup;
    }
    uint64_t result_hash = fnv1a(&actual, sizeof(actual), nonce_hash);
    char api_version[32];
    uint64_t finished = monotonic_nanoseconds();
    fputs("{\"schema\":\"dev.dory.gpu-probe\",\"version\":1,", stdout);
    fputs("\"probe\":\"compute\",\"deviceName\":", stdout);
    print_json_string(selected_properties.properties.deviceName);
    fputs(",\"driver\":", stdout);
    print_json_string(selected_driver.driverName[0] ? selected_driver.driverName : "unknown");
    fputs(",\"apiVersion\":", stdout);
    print_json_string(version_string(selected_properties.properties.apiVersion, api_version));
    fputs(",\"extensionsUsed\":[],\"resultHash\":\"fnv1a64:", stdout);
    printf("%016" PRIx64 "\",\"frameCount\":1,\"nonce\":", result_hash);
    print_json_string(nonce);
    printf(",\"timings\":{\"gpuMilliseconds\":%.3f,\"totalMilliseconds\":%.3f},",
           (gpu_finished - gpu_started) / 1000000.0,
           (finished - started) / 1000000.0);
    printf("\"memoryCoherency\":{\"input\":\"%s\",\"output\":\"%s\"},",
           buffers[0].coherent ? "coherent" : "noncoherent",
           buffers[1].coherent ? "coherent" : "noncoherent");
    printf("\"elementCount\":%u,\"reduction\":%u}\n", DORY_VALUE_COUNT, actual);
    exit_code = 0;

cleanup:
    if (device)
        (void)vkDeviceWaitIdle(device);
    if (fence)
        vkDestroyFence(device, fence, NULL);
    if (command_pool)
        vkDestroyCommandPool(device, command_pool, NULL);
    if (descriptor_pool)
        vkDestroyDescriptorPool(device, descriptor_pool, NULL);
    if (pipeline)
        vkDestroyPipeline(device, pipeline, NULL);
    if (shader)
        vkDestroyShaderModule(device, shader, NULL);
    if (pipeline_layout)
        vkDestroyPipelineLayout(device, pipeline_layout, NULL);
    if (set_layout)
        vkDestroyDescriptorSetLayout(device, set_layout, NULL);
    if (device) {
        destroy_host_buffer(device, &buffers[1]);
        destroy_host_buffer(device, &buffers[0]);
        vkDestroyDevice(device, NULL);
    }
    if (instance)
        vkDestroyInstance(instance, NULL);
    return exit_code;
}
