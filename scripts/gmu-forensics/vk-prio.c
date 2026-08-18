/* vk-prio: 最小跨优先级提交风暴（复刻 Android SF 高优先级 + app 默认优先级并发）
 * 用法: vk-prio <low|medium|high|realtime> <迭代数> <每次间隔us>
 * 空命令缓冲提交即可行使 submitqueue/调度/GMU 唤醒路径。
 * gcc -O2 -o vk-prio vk-prio.c -lvulkan
 */
#include <vulkan/vulkan.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static VkQueueGlobalPriorityKHR parse_prio(const char *s) {
    if (!strcmp(s, "low"))      return VK_QUEUE_GLOBAL_PRIORITY_LOW_KHR;
    if (!strcmp(s, "high"))     return VK_QUEUE_GLOBAL_PRIORITY_HIGH_KHR;
    if (!strcmp(s, "realtime")) return VK_QUEUE_GLOBAL_PRIORITY_REALTIME_KHR;
    return VK_QUEUE_GLOBAL_PRIORITY_MEDIUM_KHR;
}

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "用法: %s <low|medium|high|realtime> <iters> [sleep_us]\n", argv[0]); return 2; }
    VkQueueGlobalPriorityKHR prio = parse_prio(argv[1]);
    long iters = atol(argv[2]);
    long sleep_us = argc > 3 ? atol(argv[3]) : 0;

    VkApplicationInfo app = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "vk-prio", .apiVersion = VK_API_VERSION_1_1 };
    VkInstanceCreateInfo ici = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = &app };
    VkInstance inst;
    if (vkCreateInstance(&ici, NULL, &inst) != VK_SUCCESS) { fprintf(stderr, "no instance\n"); return 1; }

    uint32_t n = 0; vkEnumeratePhysicalDevices(inst, &n, NULL);
    VkPhysicalDevice pds[8]; if (n > 8) n = 8;
    vkEnumeratePhysicalDevices(inst, &n, pds);
    VkPhysicalDevice pd = VK_NULL_HANDLE;
    for (uint32_t i = 0; i < n; i++) {
        VkPhysicalDeviceProperties p; vkGetPhysicalDeviceProperties(pds[i], &p);
        if (p.vendorID == 0x5143) { pd = pds[i]; printf("[%s] 用 %s\n", argv[1], p.deviceName); break; }
    }
    if (pd == VK_NULL_HANDLE) { fprintf(stderr, "没找到 turnip (vendor 0x5143)\n"); return 1; }

    float qp = 1.0f;
    VkDeviceQueueGlobalPriorityCreateInfoKHR gp = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_GLOBAL_PRIORITY_CREATE_INFO_KHR,
        .globalPriority = prio };
    VkDeviceQueueCreateInfo qci = { .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .pNext = &gp, .queueFamilyIndex = 0, .queueCount = 1, .pQueuePriorities = &qp };
    const char *dev_ext = VK_KHR_GLOBAL_PRIORITY_EXTENSION_NAME;
    VkDeviceCreateInfo dci = { .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci,
        .enabledExtensionCount = 1, .ppEnabledExtensionNames = &dev_ext };
    VkDevice dev;
    VkResult r = vkCreateDevice(pd, &dci, NULL, &dev);
    if (r != VK_SUCCESS) {
        /* 扩展不可用时退回无优先级（medium 等价） */
        dci.enabledExtensionCount = 0; qci.pNext = NULL;
        r = vkCreateDevice(pd, &dci, NULL, &dev);
        if (r != VK_SUCCESS) { fprintf(stderr, "vkCreateDevice=%d\n", r); return 1; }
        printf("[%s] 警告: global_priority 扩展不可用，用默认优先级\n", argv[1]);
    }
    VkQueue q; vkGetDeviceQueue(dev, 0, 0, &q);

    VkCommandPoolCreateInfo cpi = { .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT, .queueFamilyIndex = 0 };
    VkCommandPool pool; vkCreateCommandPool(dev, &cpi, NULL, &pool);
    VkCommandBufferAllocateInfo cai = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 };
    VkCommandBuffer cb; vkAllocateCommandBuffers(dev, &cai, &cb);
    VkFenceCreateInfo fci = { .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
    VkFence fence; vkCreateFence(dev, &fci, NULL, &fence);

    long fails = 0;
    for (long i = 0; i < iters; i++) {
        VkCommandBufferBeginInfo bi = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
        vkBeginCommandBuffer(cb, &bi);
        vkEndCommandBuffer(cb);
        VkSubmitInfo si = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .commandBufferCount = 1, .pCommandBuffers = &cb };
        r = vkQueueSubmit(q, 1, &si, fence);
        if (r != VK_SUCCESS) { fails++; fprintf(stderr, "[%s] submit %ld: %d\n", argv[1], i, r); if (fails > 5) break; }
        r = vkWaitForFences(dev, 1, &fence, VK_TRUE, 2000000000ull);
        if (r != VK_SUCCESS) { fprintf(stderr, "[%s] fence %ld: %d (DEVICE_LOST?)\n", argv[1], i, r); break; }
        vkResetFences(dev, 1, &fence);
        vkResetCommandBuffer(cb, 0);
        if (sleep_us) usleep(sleep_us);
        if (i % 1000 == 0 && i) printf("[%s] %ld 次提交完成\n", argv[1], i);
    }
    printf("[%s] 结束: %ld 次提交, %ld 失败, 最后状态=%d\n", argv[1], iters, fails, r);
    return (fails || r != VK_SUCCESS) ? 1 : 0;
}
