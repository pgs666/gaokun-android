#!/usr/bin/env python3
"""patch 0004 v2：修 ANB image 的 image->mem 从未赋值导致的双重 bug。

根因（2026-08-18 定位，addr2line + BuildId 核对）：
  patch 0004 v1 在 BindImageMemory2(memory=NULL) 时直接 return VK_SUCCESS，
  从不给 image->mem 赋值。于是
    1) 用户态：tu_allocate_transient_attachments() 里 !iview->image->mem->bo
       解引用 NULL（tu_cmd_buffer.cc:3955，fault addr 0xd0）
    2) 内核态：该 image 的 iova 无效 → GPU 访问非法地址 → GPU SMMU
       translation fault → stall（本平台 context-fault 中断不通）→ GPU 死锁
  真正的内存是 vkCreateImage 时 vk_android_import_anb() 导入、存在
  image->vk.anb_memory 里的，必须装进 image->mem。
幂等。
"""
import sys

V = '/home/vahiru/aosp/external/mesa3d/src/freedreno/vulkan/'
rc = 0

# ---- 修复 1：tu_image.cc 真正绑定 anb_memory ----
p1 = V + 'tu_image.cc'
s = open(p1).read()
old1 = """      if (vk_image_is_android_native_buffer(&image->vk))
         return VK_SUCCESS;
      UNREACHABLE("VkBindImageMemoryInfo with no memory");"""
new1 = """      /* Android/ANGLE 会用 NULL memory 重绑定 ANB image。真正的内存是
       * vkCreateImage 时 vk_android_import_anb() 导入并存进 vk.anb_memory 的，
       * 必须在这里装进 image->mem —— 否则 image->mem 保持 NULL：
       *   1) tu_allocate_transient_attachments() 解引用它（!image->mem->bo）
       *   2) image->iova 无效 → GPU 访问非法地址 → SMMU translation fault
       * (gaokun patch 0004 v2) */
      if (image->vk.anb_memory != VK_NULL_HANDLE) {
         mem = tu_device_memory_from_handle(image->vk.anb_memory);
         offset = 0;
      } else {
         /* 既没传 memory 又没有已导入的 ANB 内存：无可绑定，跳过而不是 UB */
         return VK_SUCCESS;
      }"""
if new1 in s:
    print('tu_image.cc: 已是 v2，跳过')
elif old1 in s:
    open(p1, 'w').write(s.replace(old1, new1, 1))
    print('tu_image.cc: patch 0004 v2 已应用')
else:
    print('!! tu_image.cc 未匹配 v1 片段', file=sys.stderr)
    rc = 1

# ---- 修复 2：tu_cmd_buffer.cc 防御 NULL mem ----
p2 = V + 'tu_cmd_buffer.cc'
s = open(p2).read()
old2 = """      const struct tu_image_view *iview = cmd->state.attachments[i];
      if (iview && !(iview->image->vk.create_flags &"""
new2 = """      const struct tu_image_view *iview = cmd->state.attachments[i];
      /* image->mem 可能为 NULL（attachment 未绑定内存）：没有内存自然不需要
       * 惰性分配，跳过而不是解引用。(gaokun) */
      if (iview && iview->image->mem &&
          !(iview->image->vk.create_flags &"""
if new2 in s:
    print('tu_cmd_buffer.cc: 已有防御，跳过')
elif old2 in s:
    open(p2, 'w').write(s.replace(old2, new2, 1))
    print('tu_cmd_buffer.cc: NULL mem 防御已应用')
else:
    print('!! tu_cmd_buffer.cc 未匹配', file=sys.stderr)
    rc = 1

sys.exit(rc)
