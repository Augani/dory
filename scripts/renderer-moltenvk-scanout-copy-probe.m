#include <vulkan/vulkan.h>

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/*
 * This probe qualifies the host half of Dory's emulated DRM_FORMAT_MOD_LINEAR
 * contract. It proves that direct linear attachments are unsupported, renders
 * through a blend-enabled graphics pipeline into an optimal image, copies that
 * image into a linear scanout image, and verifies the actual mapped bytes. The
 * production archive exposes only vkGetInstanceProcAddr, so all other entry
 * points are resolved through Vulkan dispatch tables.
 *
 * The embedded SPIR-V modules are deterministic outputs of glslangValidator -V
 * from the GLSL sources recorded beside each array below:
 *   vertex:   ebc5c12b4c55b322bc1a61165e108bd3feb7b09d72f4d9a22b6f9d2a9c3143c9
 *   fragment: 263ffeba5fe166adfd8aa7c140ec83518490b1b1c20c95917101d2471e4177d8
 */

static const uint32_t vertex_spirv[] = {
    /*
     * #version 450
     * const vec2 positions[3] = vec2[](
     *     vec2(-1.0, -1.0), vec2(3.0, -1.0), vec2(-1.0, 3.0));
     * void main() {
     *     gl_Position = vec4(positions[gl_VertexIndex], 0.0, 1.0);
     * }
     */
    0x07230203, 0x00010000, 0x0008000b, 0x00000028, 0x00000000, 0x00020011, 0x00000001, 0x0006000b,
    0x00000001, 0x4c534c47, 0x6474732e, 0x3035342e, 0x00000000, 0x0003000e, 0x00000000, 0x00000001,
    0x0007000f, 0x00000000, 0x00000004, 0x6e69616d, 0x00000000, 0x0000000d, 0x0000001a, 0x00030003,
    0x00000002, 0x000001c2, 0x00040005, 0x00000004, 0x6e69616d, 0x00000000, 0x00060005, 0x0000000b,
    0x505f6c67, 0x65567265, 0x78657472, 0x00000000, 0x00060006, 0x0000000b, 0x00000000, 0x505f6c67,
    0x7469736f, 0x006e6f69, 0x00070006, 0x0000000b, 0x00000001, 0x505f6c67, 0x746e696f, 0x657a6953,
    0x00000000, 0x00070006, 0x0000000b, 0x00000002, 0x435f6c67, 0x4470696c, 0x61747369, 0x0065636e,
    0x00070006, 0x0000000b, 0x00000003, 0x435f6c67, 0x446c6c75, 0x61747369, 0x0065636e, 0x00030005,
    0x0000000d, 0x00000000, 0x00060005, 0x0000001a, 0x565f6c67, 0x65747265, 0x646e4978, 0x00007865,
    0x00050005, 0x0000001d, 0x65646e69, 0x6c626178, 0x00000065, 0x00030047, 0x0000000b, 0x00000002,
    0x00050048, 0x0000000b, 0x00000000, 0x0000000b, 0x00000000, 0x00050048, 0x0000000b, 0x00000001,
    0x0000000b, 0x00000001, 0x00050048, 0x0000000b, 0x00000002, 0x0000000b, 0x00000003, 0x00050048,
    0x0000000b, 0x00000003, 0x0000000b, 0x00000004, 0x00040047, 0x0000001a, 0x0000000b, 0x0000002a,
    0x00020013, 0x00000002, 0x00030021, 0x00000003, 0x00000002, 0x00030016, 0x00000006, 0x00000020,
    0x00040017, 0x00000007, 0x00000006, 0x00000004, 0x00040015, 0x00000008, 0x00000020, 0x00000000,
    0x0004002b, 0x00000008, 0x00000009, 0x00000001, 0x0004001c, 0x0000000a, 0x00000006, 0x00000009,
    0x0006001e, 0x0000000b, 0x00000007, 0x00000006, 0x0000000a, 0x0000000a, 0x00040020, 0x0000000c,
    0x00000003, 0x0000000b, 0x0004003b, 0x0000000c, 0x0000000d, 0x00000003, 0x00040015, 0x0000000e,
    0x00000020, 0x00000001, 0x0004002b, 0x0000000e, 0x0000000f, 0x00000000, 0x00040017, 0x00000010,
    0x00000006, 0x00000002, 0x0004002b, 0x00000008, 0x00000011, 0x00000003, 0x0004001c, 0x00000012,
    0x00000010, 0x00000011, 0x0004002b, 0x00000006, 0x00000013, 0xbf800000, 0x0005002c, 0x00000010,
    0x00000014, 0x00000013, 0x00000013, 0x0004002b, 0x00000006, 0x00000015, 0x40400000, 0x0005002c,
    0x00000010, 0x00000016, 0x00000015, 0x00000013, 0x0005002c, 0x00000010, 0x00000017, 0x00000013,
    0x00000015, 0x0006002c, 0x00000012, 0x00000018, 0x00000014, 0x00000016, 0x00000017, 0x00040020,
    0x00000019, 0x00000001, 0x0000000e, 0x0004003b, 0x00000019, 0x0000001a, 0x00000001, 0x00040020,
    0x0000001c, 0x00000007, 0x00000012, 0x00040020, 0x0000001e, 0x00000007, 0x00000010, 0x0004002b,
    0x00000006, 0x00000021, 0x00000000, 0x0004002b, 0x00000006, 0x00000022, 0x3f800000, 0x00040020,
    0x00000026, 0x00000003, 0x00000007, 0x00050036, 0x00000002, 0x00000004, 0x00000000, 0x00000003,
    0x000200f8, 0x00000005, 0x0004003b, 0x0000001c, 0x0000001d, 0x00000007, 0x0004003d, 0x0000000e,
    0x0000001b, 0x0000001a, 0x0003003e, 0x0000001d, 0x00000018, 0x00050041, 0x0000001e, 0x0000001f,
    0x0000001d, 0x0000001b, 0x0004003d, 0x00000010, 0x00000020, 0x0000001f, 0x00050051, 0x00000006,
    0x00000023, 0x00000020, 0x00000000, 0x00050051, 0x00000006, 0x00000024, 0x00000020, 0x00000001,
    0x00070050, 0x00000007, 0x00000025, 0x00000023, 0x00000024, 0x00000021, 0x00000022, 0x00050041,
    0x00000026, 0x00000027, 0x0000000d, 0x0000000f, 0x0003003e, 0x00000027, 0x00000025, 0x000100fd,
    0x00010038,
};

static const uint32_t fragment_spirv[] = {
    /*
     * #version 450
     * layout(push_constant) uniform PushConstants { vec4 color; } pc;
     * layout(location = 0) out vec4 output_color;
     * void main() { output_color = pc.color; }
     */
    0x07230203, 0x00010000, 0x0008000b, 0x00000012, 0x00000000, 0x00020011, 0x00000001, 0x0006000b,
    0x00000001, 0x4c534c47, 0x6474732e, 0x3035342e, 0x00000000, 0x0003000e, 0x00000000, 0x00000001,
    0x0006000f, 0x00000004, 0x00000004, 0x6e69616d, 0x00000000, 0x00000009, 0x00030010, 0x00000004,
    0x00000007, 0x00030003, 0x00000002, 0x000001c2, 0x00040005, 0x00000004, 0x6e69616d, 0x00000000,
    0x00060005, 0x00000009, 0x7074756f, 0x635f7475, 0x726f6c6f, 0x00000000, 0x00060005, 0x0000000a,
    0x68737550, 0x736e6f43, 0x746e6174, 0x00000073, 0x00050006, 0x0000000a, 0x00000000, 0x6f6c6f63,
    0x00000072, 0x00060005, 0x0000000c, 0x68737570, 0x6e6f635f, 0x6e617473, 0x00007374, 0x00040047,
    0x00000009, 0x0000001e, 0x00000000, 0x00030047, 0x0000000a, 0x00000002, 0x00050048, 0x0000000a,
    0x00000000, 0x00000023, 0x00000000, 0x00020013, 0x00000002, 0x00030021, 0x00000003, 0x00000002,
    0x00030016, 0x00000006, 0x00000020, 0x00040017, 0x00000007, 0x00000006, 0x00000004, 0x00040020,
    0x00000008, 0x00000003, 0x00000007, 0x0004003b, 0x00000008, 0x00000009, 0x00000003, 0x0003001e,
    0x0000000a, 0x00000007, 0x00040020, 0x0000000b, 0x00000009, 0x0000000a, 0x0004003b, 0x0000000b,
    0x0000000c, 0x00000009, 0x00040015, 0x0000000d, 0x00000020, 0x00000001, 0x0004002b, 0x0000000d,
    0x0000000e, 0x00000000, 0x00040020, 0x0000000f, 0x00000009, 0x00000007, 0x00050036, 0x00000002,
    0x00000004, 0x00000000, 0x00000003, 0x000200f8, 0x00000005, 0x00050041, 0x0000000f, 0x00000010,
    0x0000000c, 0x0000000e, 0x0004003d, 0x00000007, 0x00000011, 0x00000010, 0x0003003e, 0x00000009,
    0x00000011, 0x000100fd, 0x00010038,
};

static PFN_vkEnumerateInstanceExtensionProperties dory_vkEnumerateInstanceExtensionProperties;
static PFN_vkCreateInstance dory_vkCreateInstance;
static PFN_vkDestroyInstance dory_vkDestroyInstance;
static PFN_vkEnumeratePhysicalDevices dory_vkEnumeratePhysicalDevices;
static PFN_vkEnumerateDeviceExtensionProperties dory_vkEnumerateDeviceExtensionProperties;
static PFN_vkGetPhysicalDeviceProperties dory_vkGetPhysicalDeviceProperties;
static PFN_vkGetPhysicalDeviceQueueFamilyProperties dory_vkGetPhysicalDeviceQueueFamilyProperties;
static PFN_vkGetPhysicalDeviceMemoryProperties dory_vkGetPhysicalDeviceMemoryProperties;
static PFN_vkGetPhysicalDeviceFormatProperties dory_vkGetPhysicalDeviceFormatProperties;
static PFN_vkGetPhysicalDeviceImageFormatProperties2 dory_vkGetPhysicalDeviceImageFormatProperties2;
static PFN_vkCreateDevice dory_vkCreateDevice;
static PFN_vkGetDeviceProcAddr dory_vkGetDeviceProcAddr;
static PFN_vkDestroyDevice dory_vkDestroyDevice;
static PFN_vkDeviceWaitIdle dory_vkDeviceWaitIdle;
static PFN_vkGetDeviceQueue dory_vkGetDeviceQueue;
static PFN_vkCreateImage dory_vkCreateImage;
static PFN_vkDestroyImage dory_vkDestroyImage;
static PFN_vkGetImageMemoryRequirements dory_vkGetImageMemoryRequirements;
static PFN_vkAllocateMemory dory_vkAllocateMemory;
static PFN_vkFreeMemory dory_vkFreeMemory;
static PFN_vkBindImageMemory dory_vkBindImageMemory;
static PFN_vkMapMemory dory_vkMapMemory;
static PFN_vkUnmapMemory dory_vkUnmapMemory;
static PFN_vkInvalidateMappedMemoryRanges dory_vkInvalidateMappedMemoryRanges;
static PFN_vkGetImageSubresourceLayout dory_vkGetImageSubresourceLayout;
static PFN_vkCreateImageView dory_vkCreateImageView;
static PFN_vkDestroyImageView dory_vkDestroyImageView;
static PFN_vkCreateRenderPass dory_vkCreateRenderPass;
static PFN_vkDestroyRenderPass dory_vkDestroyRenderPass;
static PFN_vkCreateFramebuffer dory_vkCreateFramebuffer;
static PFN_vkDestroyFramebuffer dory_vkDestroyFramebuffer;
static PFN_vkCreateShaderModule dory_vkCreateShaderModule;
static PFN_vkDestroyShaderModule dory_vkDestroyShaderModule;
static PFN_vkCreatePipelineLayout dory_vkCreatePipelineLayout;
static PFN_vkDestroyPipelineLayout dory_vkDestroyPipelineLayout;
static PFN_vkCreateGraphicsPipelines dory_vkCreateGraphicsPipelines;
static PFN_vkDestroyPipeline dory_vkDestroyPipeline;
static PFN_vkCreateCommandPool dory_vkCreateCommandPool;
static PFN_vkDestroyCommandPool dory_vkDestroyCommandPool;
static PFN_vkAllocateCommandBuffers dory_vkAllocateCommandBuffers;
static PFN_vkBeginCommandBuffer dory_vkBeginCommandBuffer;
static PFN_vkEndCommandBuffer dory_vkEndCommandBuffer;
static PFN_vkCmdBeginRenderPass dory_vkCmdBeginRenderPass;
static PFN_vkCmdEndRenderPass dory_vkCmdEndRenderPass;
static PFN_vkCmdBindPipeline dory_vkCmdBindPipeline;
static PFN_vkCmdPushConstants dory_vkCmdPushConstants;
static PFN_vkCmdDraw dory_vkCmdDraw;
static PFN_vkCmdCopyImage dory_vkCmdCopyImage;
static PFN_vkCmdPipelineBarrier dory_vkCmdPipelineBarrier;
static PFN_vkCreateFence dory_vkCreateFence;
static PFN_vkDestroyFence dory_vkDestroyFence;
static PFN_vkQueueSubmit dory_vkQueueSubmit;
static PFN_vkWaitForFences dory_vkWaitForFences;

#define vkEnumerateInstanceExtensionProperties dory_vkEnumerateInstanceExtensionProperties
#define vkCreateInstance dory_vkCreateInstance
#define vkDestroyInstance dory_vkDestroyInstance
#define vkEnumeratePhysicalDevices dory_vkEnumeratePhysicalDevices
#define vkEnumerateDeviceExtensionProperties dory_vkEnumerateDeviceExtensionProperties
#define vkGetPhysicalDeviceProperties dory_vkGetPhysicalDeviceProperties
#define vkGetPhysicalDeviceQueueFamilyProperties dory_vkGetPhysicalDeviceQueueFamilyProperties
#define vkGetPhysicalDeviceMemoryProperties dory_vkGetPhysicalDeviceMemoryProperties
#define vkGetPhysicalDeviceFormatProperties dory_vkGetPhysicalDeviceFormatProperties
#define vkGetPhysicalDeviceImageFormatProperties2 dory_vkGetPhysicalDeviceImageFormatProperties2
#define vkCreateDevice dory_vkCreateDevice
#define vkGetDeviceProcAddr dory_vkGetDeviceProcAddr
#define vkDestroyDevice dory_vkDestroyDevice
#define vkDeviceWaitIdle dory_vkDeviceWaitIdle
#define vkGetDeviceQueue dory_vkGetDeviceQueue
#define vkCreateImage dory_vkCreateImage
#define vkDestroyImage dory_vkDestroyImage
#define vkGetImageMemoryRequirements dory_vkGetImageMemoryRequirements
#define vkAllocateMemory dory_vkAllocateMemory
#define vkFreeMemory dory_vkFreeMemory
#define vkBindImageMemory dory_vkBindImageMemory
#define vkMapMemory dory_vkMapMemory
#define vkUnmapMemory dory_vkUnmapMemory
#define vkInvalidateMappedMemoryRanges dory_vkInvalidateMappedMemoryRanges
#define vkGetImageSubresourceLayout dory_vkGetImageSubresourceLayout
#define vkCreateImageView dory_vkCreateImageView
#define vkDestroyImageView dory_vkDestroyImageView
#define vkCreateRenderPass dory_vkCreateRenderPass
#define vkDestroyRenderPass dory_vkDestroyRenderPass
#define vkCreateFramebuffer dory_vkCreateFramebuffer
#define vkDestroyFramebuffer dory_vkDestroyFramebuffer
#define vkCreateShaderModule dory_vkCreateShaderModule
#define vkDestroyShaderModule dory_vkDestroyShaderModule
#define vkCreatePipelineLayout dory_vkCreatePipelineLayout
#define vkDestroyPipelineLayout dory_vkDestroyPipelineLayout
#define vkCreateGraphicsPipelines dory_vkCreateGraphicsPipelines
#define vkDestroyPipeline dory_vkDestroyPipeline
#define vkCreateCommandPool dory_vkCreateCommandPool
#define vkDestroyCommandPool dory_vkDestroyCommandPool
#define vkAllocateCommandBuffers dory_vkAllocateCommandBuffers
#define vkBeginCommandBuffer dory_vkBeginCommandBuffer
#define vkEndCommandBuffer dory_vkEndCommandBuffer
#define vkCmdBeginRenderPass dory_vkCmdBeginRenderPass
#define vkCmdEndRenderPass dory_vkCmdEndRenderPass
#define vkCmdBindPipeline dory_vkCmdBindPipeline
#define vkCmdPushConstants dory_vkCmdPushConstants
#define vkCmdDraw dory_vkCmdDraw
#define vkCmdCopyImage dory_vkCmdCopyImage
#define vkCmdPipelineBarrier dory_vkCmdPipelineBarrier
#define vkCreateFence dory_vkCreateFence
#define vkDestroyFence dory_vkDestroyFence
#define vkQueueSubmit dory_vkQueueSubmit
#define vkWaitForFences dory_vkWaitForFences

static int fail(const char *operation, VkResult result)
{
    fprintf(stderr, "dory-moltenvk-scanout-copy-probe: %s (%d)\n", operation, result);
    return 1;
}

static bool has_extension(
    const VkExtensionProperties *extensions,
    uint32_t count,
    const char *name
)
{
    for (uint32_t index = 0; index < count; ++index) {
        if (strcmp(extensions[index].extensionName, name) == 0)
            return true;
    }
    return false;
}

static bool load_global_dispatch(void)
{
#define DORY_LOAD_GLOBAL(name) dory_##name = (PFN_##name)vkGetInstanceProcAddr(VK_NULL_HANDLE, #name)
    DORY_LOAD_GLOBAL(vkEnumerateInstanceExtensionProperties);
    DORY_LOAD_GLOBAL(vkCreateInstance);
#undef DORY_LOAD_GLOBAL
    return vkEnumerateInstanceExtensionProperties != NULL && vkCreateInstance != NULL;
}

static bool load_instance_dispatch(VkInstance instance)
{
#define DORY_LOAD_INSTANCE(name) dory_##name = (PFN_##name)vkGetInstanceProcAddr(instance, #name)
    DORY_LOAD_INSTANCE(vkDestroyInstance);
    DORY_LOAD_INSTANCE(vkEnumeratePhysicalDevices);
    DORY_LOAD_INSTANCE(vkEnumerateDeviceExtensionProperties);
    DORY_LOAD_INSTANCE(vkGetPhysicalDeviceProperties);
    DORY_LOAD_INSTANCE(vkGetPhysicalDeviceQueueFamilyProperties);
    DORY_LOAD_INSTANCE(vkGetPhysicalDeviceMemoryProperties);
    DORY_LOAD_INSTANCE(vkGetPhysicalDeviceFormatProperties);
    DORY_LOAD_INSTANCE(vkGetPhysicalDeviceImageFormatProperties2);
    DORY_LOAD_INSTANCE(vkCreateDevice);
    DORY_LOAD_INSTANCE(vkGetDeviceProcAddr);
#undef DORY_LOAD_INSTANCE
    return vkDestroyInstance != NULL && vkEnumeratePhysicalDevices != NULL &&
        vkEnumerateDeviceExtensionProperties != NULL &&
        vkGetPhysicalDeviceProperties != NULL &&
        vkGetPhysicalDeviceQueueFamilyProperties != NULL &&
        vkGetPhysicalDeviceMemoryProperties != NULL &&
        vkGetPhysicalDeviceFormatProperties != NULL &&
        vkGetPhysicalDeviceImageFormatProperties2 != NULL &&
        vkCreateDevice != NULL && vkGetDeviceProcAddr != NULL;
}

static bool load_device_dispatch(VkDevice device)
{
#define DORY_LOAD_DEVICE(name) dory_##name = (PFN_##name)vkGetDeviceProcAddr(device, #name)
    DORY_LOAD_DEVICE(vkDestroyDevice);
    DORY_LOAD_DEVICE(vkDeviceWaitIdle);
    DORY_LOAD_DEVICE(vkGetDeviceQueue);
    DORY_LOAD_DEVICE(vkCreateImage);
    DORY_LOAD_DEVICE(vkDestroyImage);
    DORY_LOAD_DEVICE(vkGetImageMemoryRequirements);
    DORY_LOAD_DEVICE(vkAllocateMemory);
    DORY_LOAD_DEVICE(vkFreeMemory);
    DORY_LOAD_DEVICE(vkBindImageMemory);
    DORY_LOAD_DEVICE(vkMapMemory);
    DORY_LOAD_DEVICE(vkUnmapMemory);
    DORY_LOAD_DEVICE(vkInvalidateMappedMemoryRanges);
    DORY_LOAD_DEVICE(vkGetImageSubresourceLayout);
    DORY_LOAD_DEVICE(vkCreateImageView);
    DORY_LOAD_DEVICE(vkDestroyImageView);
    DORY_LOAD_DEVICE(vkCreateRenderPass);
    DORY_LOAD_DEVICE(vkDestroyRenderPass);
    DORY_LOAD_DEVICE(vkCreateFramebuffer);
    DORY_LOAD_DEVICE(vkDestroyFramebuffer);
    DORY_LOAD_DEVICE(vkCreateShaderModule);
    DORY_LOAD_DEVICE(vkDestroyShaderModule);
    DORY_LOAD_DEVICE(vkCreatePipelineLayout);
    DORY_LOAD_DEVICE(vkDestroyPipelineLayout);
    DORY_LOAD_DEVICE(vkCreateGraphicsPipelines);
    DORY_LOAD_DEVICE(vkDestroyPipeline);
    DORY_LOAD_DEVICE(vkCreateCommandPool);
    DORY_LOAD_DEVICE(vkDestroyCommandPool);
    DORY_LOAD_DEVICE(vkAllocateCommandBuffers);
    DORY_LOAD_DEVICE(vkBeginCommandBuffer);
    DORY_LOAD_DEVICE(vkEndCommandBuffer);
    DORY_LOAD_DEVICE(vkCmdBeginRenderPass);
    DORY_LOAD_DEVICE(vkCmdEndRenderPass);
    DORY_LOAD_DEVICE(vkCmdBindPipeline);
    DORY_LOAD_DEVICE(vkCmdPushConstants);
    DORY_LOAD_DEVICE(vkCmdDraw);
    DORY_LOAD_DEVICE(vkCmdCopyImage);
    DORY_LOAD_DEVICE(vkCmdPipelineBarrier);
    DORY_LOAD_DEVICE(vkCreateFence);
    DORY_LOAD_DEVICE(vkDestroyFence);
    DORY_LOAD_DEVICE(vkQueueSubmit);
    DORY_LOAD_DEVICE(vkWaitForFences);
#undef DORY_LOAD_DEVICE

    const void *dispatch[] = {
        (const void *)vkDestroyDevice, (const void *)vkDeviceWaitIdle,
        (const void *)vkGetDeviceQueue, (const void *)vkCreateImage,
        (const void *)vkDestroyImage, (const void *)vkGetImageMemoryRequirements,
        (const void *)vkAllocateMemory, (const void *)vkFreeMemory,
        (const void *)vkBindImageMemory, (const void *)vkMapMemory,
        (const void *)vkUnmapMemory, (const void *)vkInvalidateMappedMemoryRanges,
        (const void *)vkGetImageSubresourceLayout, (const void *)vkCreateImageView,
        (const void *)vkDestroyImageView, (const void *)vkCreateRenderPass,
        (const void *)vkDestroyRenderPass, (const void *)vkCreateFramebuffer,
        (const void *)vkDestroyFramebuffer, (const void *)vkCreateShaderModule,
        (const void *)vkDestroyShaderModule, (const void *)vkCreatePipelineLayout,
        (const void *)vkDestroyPipelineLayout, (const void *)vkCreateGraphicsPipelines,
        (const void *)vkDestroyPipeline, (const void *)vkCreateCommandPool,
        (const void *)vkDestroyCommandPool, (const void *)vkAllocateCommandBuffers,
        (const void *)vkBeginCommandBuffer, (const void *)vkEndCommandBuffer,
        (const void *)vkCmdBeginRenderPass, (const void *)vkCmdEndRenderPass,
        (const void *)vkCmdBindPipeline, (const void *)vkCmdPushConstants,
        (const void *)vkCmdDraw, (const void *)vkCmdCopyImage,
        (const void *)vkCmdPipelineBarrier,
        (const void *)vkCreateFence, (const void *)vkDestroyFence,
        (const void *)vkQueueSubmit, (const void *)vkWaitForFences,
    };
    for (size_t index = 0; index < sizeof(dispatch) / sizeof(dispatch[0]); ++index) {
        if (dispatch[index] == NULL)
            return false;
    }
    return true;
}

static bool approximately(uint8_t actual, uint8_t expected)
{
    const int difference = (int)actual - (int)expected;
    return difference >= -8 && difference <= 8;
}

static int find_memory_type(
    const VkPhysicalDeviceMemoryProperties *properties,
    uint32_t allowed_types,
    VkMemoryPropertyFlags required_flags,
    VkMemoryPropertyFlags preferred_flags,
    uint32_t *type_index,
    VkMemoryPropertyFlags *type_flags
)
{
    for (uint32_t index = 0; index < properties->memoryTypeCount; ++index) {
        const VkMemoryPropertyFlags flags = properties->memoryTypes[index].propertyFlags;
        if ((allowed_types & (1u << index)) != 0 &&
            (flags & required_flags) == required_flags &&
            (flags & preferred_flags) == preferred_flags) {
            *type_index = index;
            *type_flags = flags;
            return 0;
        }
    }
    for (uint32_t index = 0; index < properties->memoryTypeCount; ++index) {
        const VkMemoryPropertyFlags flags = properties->memoryTypes[index].propertyFlags;
        if ((allowed_types & (1u << index)) != 0 &&
            (flags & required_flags) == required_flags) {
            *type_index = index;
            *type_flags = flags;
            return 0;
        }
    }
    return 1;
}

static int qualify_format(
    VkPhysicalDevice physical_device,
    VkDevice device,
    VkQueue queue,
    uint32_t queue_family_index,
    VkFormat format,
    const char *label,
    bool bgra
)
{
    enum { width = 32, height = 32 };
    const VkFormatFeatureFlags direct_required_features =
        VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT |
        VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BLEND_BIT;
    const VkFormatFeatureFlags linear_copy_required_features =
        VK_FORMAT_FEATURE_TRANSFER_DST_BIT;
    const VkFormatFeatureFlags optimal_required_features =
        VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT |
        VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BLEND_BIT |
        VK_FORMAT_FEATURE_TRANSFER_SRC_BIT;
    VkFormatProperties format_properties = {0};
    vkGetPhysicalDeviceFormatProperties(physical_device, format, &format_properties);
    printf(
        "moltenvk.direct-linear-blend.%s.features=0x%08x required=0x%08x\n",
        label,
        format_properties.linearTilingFeatures,
        direct_required_features);
    printf(
        "moltenvk.optimal-blend-linear-copy.%s.linear-features=0x%08x required=0x%08x\n",
        label,
        format_properties.linearTilingFeatures,
        linear_copy_required_features);
    printf(
        "moltenvk.optimal-blend-linear-copy.%s.optimal-features=0x%08x required=0x%08x\n",
        label,
        format_properties.optimalTilingFeatures,
        optimal_required_features);

    const VkPhysicalDeviceImageFormatInfo2 direct_image_format_info = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_FORMAT_INFO_2,
        .format = format,
        .type = VK_IMAGE_TYPE_2D,
        .tiling = VK_IMAGE_TILING_LINEAR,
        .usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
    };
    VkImageFormatProperties2 direct_image_format_properties = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_FORMAT_PROPERTIES_2,
    };
    const VkResult direct_result = vkGetPhysicalDeviceImageFormatProperties2(
        physical_device, &direct_image_format_info, &direct_image_format_properties);
    printf(
        "moltenvk.direct-linear-blend.%s.image-format-query=%d\n",
        label,
        direct_result);

    if ((format_properties.linearTilingFeatures & linear_copy_required_features) !=
        linear_copy_required_features) {
        return fail("linear format lacks transfer-destination support", VK_ERROR_FORMAT_NOT_SUPPORTED);
    }
    if ((format_properties.optimalTilingFeatures & optimal_required_features) !=
        optimal_required_features) {
        return fail("optimal format lacks render-and-copy support", VK_ERROR_FORMAT_NOT_SUPPORTED);
    }
    const VkPhysicalDeviceImageFormatInfo2 linear_image_format_info = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_FORMAT_INFO_2,
        .format = format,
        .type = VK_IMAGE_TYPE_2D,
        .tiling = VK_IMAGE_TILING_LINEAR,
        .usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT,
    };
    VkImageFormatProperties2 linear_image_format_properties = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_FORMAT_PROPERTIES_2,
    };
    VkResult result = vkGetPhysicalDeviceImageFormatProperties2(
        physical_device, &linear_image_format_info, &linear_image_format_properties);
    printf(
        "moltenvk.optimal-blend-linear-copy.%s.linear-image-format-query=%d\n",
        label,
        result);
    if (result != VK_SUCCESS)
        return fail("linear transfer-destination image query failed", result);
    const VkPhysicalDeviceImageFormatInfo2 optimal_image_format_info = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_FORMAT_INFO_2,
        .format = format,
        .type = VK_IMAGE_TYPE_2D,
        .tiling = VK_IMAGE_TILING_OPTIMAL,
        .usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
    };
    VkImageFormatProperties2 optimal_image_format_properties = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_FORMAT_PROPERTIES_2,
    };
    result = vkGetPhysicalDeviceImageFormatProperties2(
        physical_device, &optimal_image_format_info, &optimal_image_format_properties);
    printf(
        "moltenvk.optimal-blend-linear-copy.%s.optimal-image-format-query=%d\n",
        label,
        result);
    if (result != VK_SUCCESS)
        return fail("optimal render-source image query failed", result);

    VkImage image = VK_NULL_HANDLE;
    VkDeviceMemory memory = VK_NULL_HANDLE;
    VkImage render_image = VK_NULL_HANDLE;
    VkDeviceMemory render_memory = VK_NULL_HANDLE;
    VkImageView image_view = VK_NULL_HANDLE;
    VkRenderPass render_pass = VK_NULL_HANDLE;
    VkFramebuffer framebuffer = VK_NULL_HANDLE;
    VkShaderModule vertex_shader = VK_NULL_HANDLE;
    VkShaderModule fragment_shader = VK_NULL_HANDLE;
    VkPipelineLayout pipeline_layout = VK_NULL_HANDLE;
    VkPipeline pipeline = VK_NULL_HANDLE;
    VkCommandPool command_pool = VK_NULL_HANDLE;
    VkFence fence = VK_NULL_HANDLE;
    void *mapped = NULL;
    int exit_code = 1;

    const VkImageCreateInfo image_create = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .imageType = VK_IMAGE_TYPE_2D,
        .format = format,
        .extent = { width, height, 1 },
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = VK_SAMPLE_COUNT_1_BIT,
        .tiling = VK_IMAGE_TILING_LINEAR,
        .usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
        .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
    };
    result = vkCreateImage(device, &image_create, NULL, &image);
    if (result != VK_SUCCESS) {
        fail("linear scanout image creation failed", result);
        goto cleanup;
    }

    VkMemoryRequirements requirements = {0};
    vkGetImageMemoryRequirements(device, image, &requirements);
    VkPhysicalDeviceMemoryProperties memory_properties = {0};
    vkGetPhysicalDeviceMemoryProperties(physical_device, &memory_properties);
    uint32_t memory_type_index = 0;
    VkMemoryPropertyFlags memory_flags = 0;
    if (find_memory_type(
            &memory_properties,
            requirements.memoryTypeBits,
            VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT,
            VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            &memory_type_index,
            &memory_flags) != 0) {
        fail("linear image has no host-visible memory type", VK_ERROR_FEATURE_NOT_PRESENT);
        goto cleanup;
    }
    const VkMemoryAllocateInfo allocation = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = requirements.size,
        .memoryTypeIndex = memory_type_index,
    };
    result = vkAllocateMemory(device, &allocation, NULL, &memory);
    if (result != VK_SUCCESS) {
        fail("linear image memory allocation failed", result);
        goto cleanup;
    }
    result = vkBindImageMemory(device, image, memory, 0);
    if (result != VK_SUCCESS) {
        fail("linear image memory binding failed", result);
        goto cleanup;
    }

    const VkImageCreateInfo render_image_create = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .imageType = VK_IMAGE_TYPE_2D,
        .format = format,
        .extent = { width, height, 1 },
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = VK_SAMPLE_COUNT_1_BIT,
        .tiling = VK_IMAGE_TILING_OPTIMAL,
        .usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
        .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
    };
    result = vkCreateImage(device, &render_image_create, NULL, &render_image);
    if (result != VK_SUCCESS) {
        fail("optimal render image creation failed", result);
        goto cleanup;
    }
    VkMemoryRequirements render_requirements = {0};
    vkGetImageMemoryRequirements(device, render_image, &render_requirements);
    uint32_t render_memory_type_index = 0;
    VkMemoryPropertyFlags render_memory_flags = 0;
    if (find_memory_type(
            &memory_properties,
            render_requirements.memoryTypeBits,
            0,
            VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
            &render_memory_type_index,
            &render_memory_flags) != 0) {
        fail("optimal render image has no compatible memory type", VK_ERROR_FEATURE_NOT_PRESENT);
        goto cleanup;
    }
    printf(
        "moltenvk.optimal-blend-linear-copy.%s.memory-flags=scanout:0x%08x,render:0x%08x\n",
        label,
        memory_flags,
        render_memory_flags);
    const VkMemoryAllocateInfo render_allocation = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = render_requirements.size,
        .memoryTypeIndex = render_memory_type_index,
    };
    result = vkAllocateMemory(device, &render_allocation, NULL, &render_memory);
    if (result != VK_SUCCESS) {
        fail("optimal render image memory allocation failed", result);
        goto cleanup;
    }
    result = vkBindImageMemory(device, render_image, render_memory, 0);
    if (result != VK_SUCCESS) {
        fail("optimal render image memory binding failed", result);
        goto cleanup;
    }

    const VkImageViewCreateInfo view_create = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .image = render_image,
        .viewType = VK_IMAGE_VIEW_TYPE_2D,
        .format = format,
        .components = {
            VK_COMPONENT_SWIZZLE_IDENTITY,
            VK_COMPONENT_SWIZZLE_IDENTITY,
            VK_COMPONENT_SWIZZLE_IDENTITY,
            VK_COMPONENT_SWIZZLE_IDENTITY,
        },
        .subresourceRange = {
            .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
            .levelCount = 1,
            .layerCount = 1,
        },
    };
    result = vkCreateImageView(device, &view_create, NULL, &image_view);
    if (result != VK_SUCCESS) {
        fail("optimal render image view creation failed", result);
        goto cleanup;
    }

    const VkAttachmentDescription attachment = {
        .format = format,
        .samples = VK_SAMPLE_COUNT_1_BIT,
        .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
        .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
        .stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
        .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
        .finalLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
    };
    const VkAttachmentReference color_attachment = {
        .attachment = 0,
        .layout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
    };
    const VkSubpassDescription subpass = {
        .pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS,
        .colorAttachmentCount = 1,
        .pColorAttachments = &color_attachment,
    };
    const VkSubpassDependency dependency = {
        .srcSubpass = VK_SUBPASS_EXTERNAL,
        .dstSubpass = 0,
        .srcStageMask = VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
        .dstStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        .dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
    };
    const VkRenderPassCreateInfo render_pass_create = {
        .sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
        .attachmentCount = 1,
        .pAttachments = &attachment,
        .subpassCount = 1,
        .pSubpasses = &subpass,
        .dependencyCount = 1,
        .pDependencies = &dependency,
    };
    result = vkCreateRenderPass(device, &render_pass_create, NULL, &render_pass);
    if (result != VK_SUCCESS) {
        fail("render pass creation failed", result);
        goto cleanup;
    }

    const VkFramebufferCreateInfo framebuffer_create = {
        .sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
        .renderPass = render_pass,
        .attachmentCount = 1,
        .pAttachments = &image_view,
        .width = width,
        .height = height,
        .layers = 1,
    };
    result = vkCreateFramebuffer(device, &framebuffer_create, NULL, &framebuffer);
    if (result != VK_SUCCESS) {
        fail("framebuffer creation failed", result);
        goto cleanup;
    }

    const VkShaderModuleCreateInfo vertex_create = {
        .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = sizeof(vertex_spirv),
        .pCode = vertex_spirv,
    };
    result = vkCreateShaderModule(device, &vertex_create, NULL, &vertex_shader);
    if (result != VK_SUCCESS) {
        fail("vertex shader creation failed", result);
        goto cleanup;
    }
    const VkShaderModuleCreateInfo fragment_create = {
        .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = sizeof(fragment_spirv),
        .pCode = fragment_spirv,
    };
    result = vkCreateShaderModule(device, &fragment_create, NULL, &fragment_shader);
    if (result != VK_SUCCESS) {
        fail("fragment shader creation failed", result);
        goto cleanup;
    }

    const VkPushConstantRange push_range = {
        .stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT,
        .offset = 0,
        .size = 4 * sizeof(float),
    };
    const VkPipelineLayoutCreateInfo layout_create = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .pushConstantRangeCount = 1,
        .pPushConstantRanges = &push_range,
    };
    result = vkCreatePipelineLayout(device, &layout_create, NULL, &pipeline_layout);
    if (result != VK_SUCCESS) {
        fail("pipeline layout creation failed", result);
        goto cleanup;
    }

    const VkPipelineShaderStageCreateInfo shader_stages[] = {
        {
            .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage = VK_SHADER_STAGE_VERTEX_BIT,
            .module = vertex_shader,
            .pName = "main",
        },
        {
            .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage = VK_SHADER_STAGE_FRAGMENT_BIT,
            .module = fragment_shader,
            .pName = "main",
        },
    };
    const VkPipelineVertexInputStateCreateInfo vertex_input = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    };
    const VkPipelineInputAssemblyStateCreateInfo input_assembly = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        .topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
    };
    const VkViewport viewport = {
        .x = 0.0f,
        .y = 0.0f,
        .width = width,
        .height = height,
        .minDepth = 0.0f,
        .maxDepth = 1.0f,
    };
    const VkRect2D scissor = {
        .extent = { width, height },
    };
    const VkPipelineViewportStateCreateInfo viewport_state = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        .viewportCount = 1,
        .pViewports = &viewport,
        .scissorCount = 1,
        .pScissors = &scissor,
    };
    const VkPipelineRasterizationStateCreateInfo rasterization = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        .polygonMode = VK_POLYGON_MODE_FILL,
        .cullMode = VK_CULL_MODE_NONE,
        .frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE,
        .lineWidth = 1.0f,
    };
    const VkPipelineMultisampleStateCreateInfo multisample = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        .rasterizationSamples = VK_SAMPLE_COUNT_1_BIT,
    };
    const VkPipelineColorBlendAttachmentState blend_attachment = {
        .blendEnable = VK_TRUE,
        .srcColorBlendFactor = VK_BLEND_FACTOR_SRC_ALPHA,
        .dstColorBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
        .colorBlendOp = VK_BLEND_OP_ADD,
        .srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE,
        .dstAlphaBlendFactor = VK_BLEND_FACTOR_ZERO,
        .alphaBlendOp = VK_BLEND_OP_ADD,
        .colorWriteMask = VK_COLOR_COMPONENT_R_BIT |
            VK_COLOR_COMPONENT_G_BIT |
            VK_COLOR_COMPONENT_B_BIT |
            VK_COLOR_COMPONENT_A_BIT,
    };
    const VkPipelineColorBlendStateCreateInfo blend_state = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        .attachmentCount = 1,
        .pAttachments = &blend_attachment,
    };
    const VkGraphicsPipelineCreateInfo pipeline_create = {
        .sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
        .stageCount = 2,
        .pStages = shader_stages,
        .pVertexInputState = &vertex_input,
        .pInputAssemblyState = &input_assembly,
        .pViewportState = &viewport_state,
        .pRasterizationState = &rasterization,
        .pMultisampleState = &multisample,
        .pColorBlendState = &blend_state,
        .layout = pipeline_layout,
        .renderPass = render_pass,
        .subpass = 0,
    };
    result = vkCreateGraphicsPipelines(
        device, VK_NULL_HANDLE, 1, &pipeline_create, NULL, &pipeline);
    if (result != VK_SUCCESS) {
        fail("blend-enabled graphics pipeline creation failed", result);
        goto cleanup;
    }

    const VkCommandPoolCreateInfo command_pool_create = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .queueFamilyIndex = queue_family_index,
    };
    result = vkCreateCommandPool(device, &command_pool_create, NULL, &command_pool);
    if (result != VK_SUCCESS) {
        fail("command pool creation failed", result);
        goto cleanup;
    }
    const VkCommandBufferAllocateInfo command_buffer_allocate = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = command_pool,
        .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    };
    VkCommandBuffer command_buffer = VK_NULL_HANDLE;
    result = vkAllocateCommandBuffers(device, &command_buffer_allocate, &command_buffer);
    if (result != VK_SUCCESS) {
        fail("command buffer allocation failed", result);
        goto cleanup;
    }
    const VkCommandBufferBeginInfo command_begin = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    };
    result = vkBeginCommandBuffer(command_buffer, &command_begin);
    if (result != VK_SUCCESS) {
        fail("command buffer begin failed", result);
        goto cleanup;
    }
    const VkClearValue clear = { .color = { .float32 = { 0.0f, 1.0f, 0.0f, 1.0f } } };
    const VkRenderPassBeginInfo render_begin = {
        .sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
        .renderPass = render_pass,
        .framebuffer = framebuffer,
        .renderArea = { .extent = { width, height } },
        .clearValueCount = 1,
        .pClearValues = &clear,
    };
    vkCmdBeginRenderPass(command_buffer, &render_begin, VK_SUBPASS_CONTENTS_INLINE);
    vkCmdBindPipeline(command_buffer, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
    const float source_color[] = { 1.0f, 0.0f, 0.0f, 0.25f };
    vkCmdPushConstants(
        command_buffer,
        pipeline_layout,
        VK_SHADER_STAGE_FRAGMENT_BIT,
        0,
        sizeof(source_color),
        source_color);
    vkCmdDraw(command_buffer, 3, 1, 0, 0);
    vkCmdEndRenderPass(command_buffer);
    const VkImageMemoryBarrier scanout_transfer_barrier = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
        .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED,
        .newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresourceRange = {
            .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
            .levelCount = 1,
            .layerCount = 1,
        },
    };
    vkCmdPipelineBarrier(
        command_buffer,
        VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
        VK_PIPELINE_STAGE_TRANSFER_BIT,
        0,
        0,
        NULL,
        0,
        NULL,
        1,
        &scanout_transfer_barrier);
    const VkImageCopy copy_region = {
        .srcSubresource = {
            .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
            .layerCount = 1,
        },
        .dstSubresource = {
            .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
            .layerCount = 1,
        },
        .extent = { width, height, 1 },
    };
    vkCmdCopyImage(
        command_buffer,
        render_image,
        VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        image,
        VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        1,
        &copy_region);
    const VkImageMemoryBarrier host_read_barrier = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
        .dstAccessMask = VK_ACCESS_HOST_READ_BIT,
        .oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        .newLayout = VK_IMAGE_LAYOUT_GENERAL,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresourceRange = {
            .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
            .levelCount = 1,
            .layerCount = 1,
        },
    };
    vkCmdPipelineBarrier(
        command_buffer,
        VK_PIPELINE_STAGE_TRANSFER_BIT,
        VK_PIPELINE_STAGE_HOST_BIT,
        0,
        0,
        NULL,
        0,
        NULL,
        1,
        &host_read_barrier);
    result = vkEndCommandBuffer(command_buffer);
    if (result != VK_SUCCESS) {
        fail("command buffer end failed", result);
        goto cleanup;
    }

    const VkFenceCreateInfo fence_create = {
        .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
    };
    result = vkCreateFence(device, &fence_create, NULL, &fence);
    if (result != VK_SUCCESS) {
        fail("fence creation failed", result);
        goto cleanup;
    }
    const VkSubmitInfo submit = {
        .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .commandBufferCount = 1,
        .pCommandBuffers = &command_buffer,
    };
    result = vkQueueSubmit(queue, 1, &submit, fence);
    if (result != VK_SUCCESS) {
        fail("blend render submission failed", result);
        goto cleanup;
    }
    result = vkWaitForFences(device, 1, &fence, VK_TRUE, UINT64_MAX);
    if (result != VK_SUCCESS) {
        fail("blend render fence wait failed", result);
        goto cleanup;
    }

    result = vkMapMemory(device, memory, 0, VK_WHOLE_SIZE, 0, &mapped);
    if (result != VK_SUCCESS) {
        fail("linear image memory mapping failed", result);
        goto cleanup;
    }
    if ((memory_flags & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) == 0) {
        const VkMappedMemoryRange invalidate = {
            .sType = VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE,
            .memory = memory,
            .offset = 0,
            .size = VK_WHOLE_SIZE,
        };
        result = vkInvalidateMappedMemoryRanges(device, 1, &invalidate);
        if (result != VK_SUCCESS) {
            fail("linear image memory invalidation failed", result);
            goto cleanup;
        }
    }

    const VkImageSubresource subresource = {
        .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
    };
    VkSubresourceLayout subresource_layout = {0};
    vkGetImageSubresourceLayout(device, image, &subresource, &subresource_layout);
    const uint8_t *pixel = (const uint8_t *)mapped +
        subresource_layout.offset + (height / 2) * subresource_layout.rowPitch +
        (width / 2) * 4;
    const uint8_t expected[] = {
        bgra ? 0 : 64,
        191,
        bgra ? 64 : 0,
        64,
    };
    printf(
        "moltenvk.optimal-blend-linear-copy.%s.pixel=%u,%u,%u,%u expected=%u,%u,%u,%u row-pitch=%llu\n",
        label,
        pixel[0], pixel[1], pixel[2], pixel[3],
        expected[0], expected[1], expected[2], expected[3],
        (unsigned long long)subresource_layout.rowPitch);
    for (size_t channel = 0; channel < sizeof(expected); ++channel) {
        if (!approximately(pixel[channel], expected[channel])) {
            fail("copied blend readback differs from the submitted blend", VK_ERROR_UNKNOWN);
            goto cleanup;
        }
    }
    exit_code = 0;

cleanup:
    if (mapped != NULL)
        vkUnmapMemory(device, memory);
    (void)vkDeviceWaitIdle(device);
    if (fence != VK_NULL_HANDLE)
        vkDestroyFence(device, fence, NULL);
    if (command_pool != VK_NULL_HANDLE)
        vkDestroyCommandPool(device, command_pool, NULL);
    if (pipeline != VK_NULL_HANDLE)
        vkDestroyPipeline(device, pipeline, NULL);
    if (pipeline_layout != VK_NULL_HANDLE)
        vkDestroyPipelineLayout(device, pipeline_layout, NULL);
    if (fragment_shader != VK_NULL_HANDLE)
        vkDestroyShaderModule(device, fragment_shader, NULL);
    if (vertex_shader != VK_NULL_HANDLE)
        vkDestroyShaderModule(device, vertex_shader, NULL);
    if (framebuffer != VK_NULL_HANDLE)
        vkDestroyFramebuffer(device, framebuffer, NULL);
    if (render_pass != VK_NULL_HANDLE)
        vkDestroyRenderPass(device, render_pass, NULL);
    if (image_view != VK_NULL_HANDLE)
        vkDestroyImageView(device, image_view, NULL);
    if (render_image != VK_NULL_HANDLE)
        vkDestroyImage(device, render_image, NULL);
    if (render_memory != VK_NULL_HANDLE)
        vkFreeMemory(device, render_memory, NULL);
    if (image != VK_NULL_HANDLE)
        vkDestroyImage(device, image, NULL);
    if (memory != VK_NULL_HANDLE)
        vkFreeMemory(device, memory, NULL);
    return exit_code;
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
    const char *device_extensions[] = { "VK_KHR_portability_subset" };
    const uint32_t enabled_extension_count =
        has_extension(extensions, extension_count, device_extensions[0]) ? 1 : 0;
    free(extensions);

    uint32_t queue_family_count = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(physical_device, &queue_family_count, NULL);
    VkQueueFamilyProperties *queue_families = calloc(queue_family_count, sizeof(*queue_families));
    if (queue_families == NULL)
        return fail("queue family allocation failed", VK_ERROR_OUT_OF_HOST_MEMORY);
    vkGetPhysicalDeviceQueueFamilyProperties(
        physical_device, &queue_family_count, queue_families);
    uint32_t queue_family_index = queue_family_count;
    for (uint32_t index = 0; index < queue_family_count; ++index) {
        if (queue_families[index].queueCount > 0 &&
            (queue_families[index].queueFlags & VK_QUEUE_GRAPHICS_BIT) != 0) {
            queue_family_index = index;
            break;
        }
    }
    free(queue_families);
    if (queue_family_index == queue_family_count)
        return fail("no graphics-capable Vulkan queue", VK_ERROR_INITIALIZATION_FAILED);

    const float priority = 1.0f;
    const VkDeviceQueueCreateInfo queue_create = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = queue_family_index,
        .queueCount = 1,
        .pQueuePriorities = &priority,
    };
    const VkDeviceCreateInfo device_create = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .queueCreateInfoCount = 1,
        .pQueueCreateInfos = &queue_create,
        .enabledExtensionCount = enabled_extension_count,
        .ppEnabledExtensionNames = enabled_extension_count != 0 ? device_extensions : NULL,
    };
    VkDevice device = VK_NULL_HANDLE;
    result = vkCreateDevice(physical_device, &device_create, NULL, &device);
    if (result != VK_SUCCESS)
        return fail("device creation failed", result);
    if (!load_device_dispatch(device)) {
        vkDestroyDevice(device, NULL);
        return fail("MoltenVK device dispatch is incomplete", VK_ERROR_INITIALIZATION_FAILED);
    }
    VkQueue queue = VK_NULL_HANDLE;
    vkGetDeviceQueue(device, queue_family_index, 0, &queue);

    VkPhysicalDeviceProperties properties = {0};
    vkGetPhysicalDeviceProperties(physical_device, &properties);
    printf("moltenvk.scanout-copy.device=%s\n", properties.deviceName);

    const int bgra_exit_code = qualify_format(
        physical_device,
        device,
        queue,
        queue_family_index,
        VK_FORMAT_B8G8R8A8_UNORM,
        "bgra8-unorm",
        true);
    const int rgba_exit_code = qualify_format(
        physical_device,
        device,
        queue,
        queue_family_index,
        VK_FORMAT_R8G8B8A8_UNORM,
        "rgba8-unorm",
        false);
    vkDestroyDevice(device, NULL);
    return bgra_exit_code == 0 && rgba_exit_code == 0 ? 0 : 1;
}

int main(void)
{
    @autoreleasepool {
        if (!load_global_dispatch())
            return fail("MoltenVK global dispatch is incomplete", VK_ERROR_INITIALIZATION_FAILED);
        uint32_t extension_count = 0;
        VkResult result = vkEnumerateInstanceExtensionProperties(
            NULL, &extension_count, NULL);
        if (result != VK_SUCCESS)
            return fail("instance extension count failed", result);
        VkExtensionProperties *extensions = calloc(extension_count, sizeof(*extensions));
        if (extensions == NULL)
            return fail("instance extension allocation failed", VK_ERROR_OUT_OF_HOST_MEMORY);
        result = vkEnumerateInstanceExtensionProperties(
            NULL, &extension_count, extensions);
        if (result != VK_SUCCESS) {
            free(extensions);
            return fail("instance extension enumeration failed", result);
        }
        const bool portability = has_extension(
            extensions,
            extension_count,
            VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME);
        free(extensions);
        const char *instance_extensions[] = {
            VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME,
        };
        const VkApplicationInfo application = {
            .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
            .pApplicationName = "dory-moltenvk-scanout-copy-probe",
            .applicationVersion = 1,
            .pEngineName = "Dory",
            .engineVersion = 1,
            .apiVersion = VK_API_VERSION_1_2,
        };
        const VkInstanceCreateInfo instance_create = {
            .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .flags = portability ? VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR : 0,
            .pApplicationInfo = &application,
            .enabledExtensionCount = portability ? 1 : 0,
            .ppEnabledExtensionNames = portability ? instance_extensions : NULL,
        };
        VkInstance instance = VK_NULL_HANDLE;
        result = vkCreateInstance(&instance_create, NULL, &instance);
        if (result != VK_SUCCESS)
            return fail("instance creation failed", result);
        if (!load_instance_dispatch(instance)) {
            vkDestroyInstance(instance, NULL);
            return fail("MoltenVK instance dispatch is incomplete", VK_ERROR_INITIALIZATION_FAILED);
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
        const int exit_code = result == VK_SUCCESS
            ? qualify_device(devices[0])
            : fail("physical device enumeration failed", result);
        free(devices);
        vkDestroyInstance(instance, NULL);
        return exit_code;
    }
}
