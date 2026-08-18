# Stage 5 Phase B：freedreno / turnip 硬件 GPU（sc8280xp / Adreno 690）

> 目标：把图形从 Phase A 的软渲染（ANGLE over SwiftShader）换成硬件加速。
> 手游要么走 GLES 要么走 Vulkan，软渲染下都没有可玩性，这是 Stage 5 的前置条件。

## 路线选择：turnip + ANGLE，而不是 freedreno GL

| 方案 | 说明 | 结论 |
|---|---|---|
| **turnip（Vulkan）+ ANGLE（GLES→Vulkan）** | AOSP 的 `external/mesa3d` 自带官方 turnip Android 构建工具；ANGLE 已在 Phase A 装好并跑通，把它的 Vulkan 后端从 SwiftShader 换成 turnip 即可 | ✅ 采用 |
| freedreno gallium（原生 GL） | 需要 EGL/gbm/GL 全栈上 Android，工具链支持差 | ✗ |
| zink over turnip | 多一层翻译，turnip 通了就没必要 | ✗ 备选 |

**关键正确性**：mesa 的 freedreno 有两个内核后端 —— `kgsl`（高通闭源内核接口，
库存 Android 用）和 `msm`（主线 DRM/KMS）。我们跑主线内核，必须
`freedreno-kmds = 'msm'`；AOSP 自带的 `meson_to_hermetic/aosp.toml` 默认是 kgsl，
照抄会得到一个在本机根本打不开设备的驱动。生成结果里出现
`src/freedreno/vulkan/tu_knl_drm_msm.cc` 才算对。

## 构建流程（可复现）

```bash
# 0. 前提：external/mesa3d（mesa 25.3.0-devel）与 external/deqp-deps/glslang 已同步
cd ~/aosp/external/mesa3d
ln -sf meson.options meson_options.txt      # 工具认旧文件名

# 1. 补工具与 mesa 版本落差（11 处，幂等）
python3 <repo>/scripts/mesa-tool-fixes.py

# 2. 造设备配置：msm KMD + SDK 36 + 只要 Vulkan
#    （EGL/GBM/GL 全关：GLES 由 ANGLE 提供，且能绕开大量无关生成目标）
cp meson_to_hermetic/aosp.toml meson_to_hermetic/gaokun.toml
#   vulkan-drivers = 'freedreno'；freedreno-kmds = 'msm'；platform-sdk-version = 36
#   egl/gbm/glx/gles1/gles2 = 'disabled'；opengl = false

# 3. 让解析器跳过 Windows/Haiku 专用前端（父文件条件改假，见下"坑 1"）
#    然后生成 python build + Android_res.bp
source meson_to_hermetic/venv/bin/activate
python3 -u meson_to_hermetic/generate_python_build.py
PYTHONPATH=meson_to_hermetic python3 -u generate_android_build.py \
    --config=meson_to_hermetic/gaokun.toml

# 4. 合并进 Android.bp（含 9 类后处理，幂等）
python3 <repo>/scripts/mesa-bp-merge.py

# 5. 构建
m glslangValidator      # 见 patches/0003
m vulkan.freedreno      # → /vendor/lib64/hw/vulkan.freedreno.so（12 MB）
```

产物验证：`llvm-readelf --dyn-syms` 应能看到 `HMI`（HAL_MODULE_INFO_SYM）与
`vk_icdGetInstanceProcAddr`。

## 踩过的坑（12 个）

### A. 工具（meson_to_hermetic）快照落后于同仓库 mesa 25.3
补丁全在 `scripts/mesa-tool-fixes.py`，逐条注释了成因：

1. `import('fs')` 不认 → 加最小存根（顶层 meson.build 用它算 OpenCL 的
   `-fmacro-prefix-map`，Android 侧无关）
2. `meson.global_source_root()/global_build_root()` 缺失 → 非子项目场景等价于
   `project_*` 版
3. `FeatureOption.enable_if()` 缺失（meson 0.59+ API）
4. `run_command()` 少解包参数（subprocess 收到嵌套 list）且没开输出捕获
5. `CommandReturn.stdout()` 返回 bytes，而生成代码按 meson 语义调
   `str.version_compare()` → 加 `MesonStr`（str 子类，split/strip 保持类型）
6. `find_program('flex','lex',…)` 多候选名把第二个名字塞进了 `required`
7. 程序白名单只有 `python`，mesa 25.3 找 `python3`
8. `get_option('b_sanitize')` 返回 bool，生成代码按字符串用
9. 白名单程序的 `found` 直接取自 `required`（默认 False），导致
   `prog_python.found()` 为假 → `custom_target` 断言失败。改成看 PATH
10. `custom_target` 匿名写法（meson 允许省略名字，从 output 推导）
11. **`libdrm` 被硬编码成 found=False** → mesa 跳过 `vk_drm_syncobj.c`，
    turnip 链接期缺 `vk_drm_syncobj_finish/get_type`

### B. 解析器啃不动 Windows/Haiku 专用 meson 文件（坑 1）
`src/gallium/frontends/{mediafoundation,wgl,d3d10umd,hgl}/meson.build` 里的
CRLF/Windows 路径语法让 lark 报 `No terminal matches 'r'`。
**清空文件不行**（空文件让 Earley 报"multiple start symbol items"），
正确做法是把父文件 `src/gallium/meson.build` 里对应的 `if with_gallium_*`
条件改成 `if false`，解析器就不会下去。

### C. Soong 侧（合并后处理，`scripts/mesa-bp-merge.py`）
1. 生成器按设计写 `Android_res.bp`，而 Soong 只读 `Android.bp`
2. **7 个模块与树内重名**（`mesa_util`、`mesa_util_c11`、gfxstream 那几个）。
   树里那些是 AOSP 手维护给 gfxstream/goldfish 用的，且被
   `device/generic/goldfish/**` 按名引用，不能动 →
   把**我们生成的**改名加 `_gaokun` 后缀。反过来剔除生成版行不通：
   树里的 `mesa_util` 只有 65 个源文件，turnip 要的生成版有 79 个，
   还带 `shader_stats.h` 这类生成头
3. 生成的 gfxstream guest 模块源码在这版 mesa 里已搬走（去了
   `hardware/google/gfxstream`）→ 凡源码路径不存在的模块整块剔除，
   并清理别处对它的引用
4. `out`/`tools`/`srcs` 有重复项 → Soong 报 "cannot be overwritten" /
   "multiple locations for label"
5. genrule 用了 `$(location m4)`/`$(location bison)` 但 `tools: []` 是空的
6. **`glslangValidator` 被裸调用**：Soong 沙箱禁止 PATH 工具
   （`"glslangValidator" is not allowed to be used`）。AOSP 树里 glslang
   只有静态库没有可执行模块 → 自己补一个 host 端可执行模块
   （`patches/0003`，含 `-DENABLE_SPIRV`，否则报 "does not have SPIR-V
   support"；还要一个 genrule 生成 CMake 侧的 `glsl_intrinsic_header.h`）。
   ⚠️ 不能反过来"让 glslang 不可用"：turnip 的 `subdir('bvh')` 是无条件的，
   glslang 缺失会让 `vk_bvh_include_dir` 未定义而生成失败
7. 生成头的 include 路径：spv 头落在 `$(genDir)/src/freedreno/vulkan/bvh/`，
   源码写 `#include "bvh/encode.spv.h"` → 给每个 out 路径补齐各级父目录导出
8. **`generated_headers` 在 Soong 里默认不传播给依赖者**（mesa 的 meson 语义是
   idep 传递）→ 统一补 `export_generated_headers`
9. python 生成脚本缺库：Soong 的 python 沙箱不含 PyYAML/Mako → 补
   `libs: ["pyyaml", "mako"]`（注意单行/多行两种 libs 写法都要处理）
10. `libdrm`、`android.hardware.graphics.common-V7-ndk`、`libui` 依赖漏了
11. AOSP 的全局 `-Werror` 比 mesa 严（如 `unreachable-code-loop-increment`）
12. 生成器只产出 `cc_library_static`，Android 的 Vulkan 加载器要
    `/vendor/lib64/hw/vulkan.<ro.hardware.vulkan>.so` →
    `device/huawei/gaokun3/mesa/turnip-shared.bp.in` 手写共享库包装。
    要点：`whole_static_libs`（否则没人引用的 `HAL_MODULE_INFO_SYM` 被丢掉）、
    `compile_multilib: "64"`（turnip 只有 arm64 变体，否则 32 位链接缺符号）、
    并把 turnip 自己的 21 个静态依赖镜像进来（whole_static 不会自动带）

### D2. 上机后的两个真机坑（不解决就开不进桌面）

**1. `/dev/dri/renderD128` 权限**
默认 `0660 system:graphics`，**应用进程**（GLES 经 ANGLE→Vulkan 也一样）打不开：

```
TU: tu_knl.cc:388: failed to open device /dev/dri/renderD128 (VK_ERROR_INCOMPATIBLE_DRIVER)
libEGL: ANGLE Error … Internal Vulkan error (-3)
```

修：`device/huawei/gaokun3/ueventd.gaokun3.rc` 里给 `renderD*`/`card*` 设 0666
（库存高通设备上 `/dev/kgsl-3d0` 也是 0666），装到 `/vendor/etc/ueventd.rc`。

**2. gralloc 元数据后端是 turnip 的硬需求（不是可选项）**
把 IMapper4/5 全关掉之后，turnip 在导入 `ANativeWindowBuffer` 时拿到空句柄：

```
#00 vulkan.freedreno.so  tu_BindImageMemory2
#01 libvulkan.so         vulkan::driver::AcquireNextImageKHR
#02 libGLESv2_angle.so   rx::WindowSurfaceVk::prepareSwap
#07 libhwui.so           EglManager::queryBufferAge → beginFrame
signal 11 (SIGSEGV) fault addr 0x70, tid RenderThread, >>> system_server <<<
```

RenderThread 一崩 system_server 就死，全系统跟着 `DeadSystemException`
崩溃循环 —— 表现为"能看到 SurfaceFlinger 用上了 turnip，但永远进不了桌面"。

正确取舍：**关 IMapper5、留 IMapper4**。
- IMapper5 要 `android::Singleton<GraphicBufferMapper>` 的静态成员，libui 的
  vendor 变体不导出（链接期报 `_ZN7android9SingletonINS_19GraphicBufferMapperEE…`）
- IMapper4 走 HIDL mapper 4.0，依赖 `libgralloctypes` /
  `android.hardware.graphics.mapper@4.0` / `libhidlbase` / `libutils`，
  全是 vendor 可用的
- ⚠️ 这些依赖要**显式写进共享库包装模块**：静态库里的 shared_libs 不会自动
  传到包装模块，少了会报 `BpHwRefBase` 相关的 undefined symbol

### D. gralloc 元数据后端要 libui 的模板静态成员
`u_gralloc_imapper5_api.cpp` 需要 `android::Singleton<GraphicBufferMapper>` 的
静态成员，libui 的 vendor 变体不导出 →
把 `ui` 和 `android.hardware.graphics.mapper` 依赖报告为未找到，mesa 自动跳过
IMapper4/5 后端。本机 gralloc 是 minigbm（= CrOS gralloc），
`u_gralloc_cros_api.c` 始终编译，够用；元数据后端只用于查压缩/modifier，
而我们本来就跑 `vendor.minigbm.debug=nocompression`。

## D3. GMU 死亡案（上机后最硬的骨头）

**症状**：Android 启动 ~7 秒（开机动画/SF 首用 GPU），第一条 GPU 错误就是
`HFI_H2F_MSG_GX_BW_PERF_VOTE timed out` → `GMU watchdog expired` → GMU 永久
wedge（后续所有 `a6xx_gmu_resume` 都超时，恢复路径 `cx gdsc didn't collapse`
也是坏的）→ 全系统 VK_ERROR_DEVICE_LOST 崩溃循环。

**devcoredump 关键证据**（`comm: BootAnimation`）：`rbbm-status: 0x00000000`
（GPU 核心空闲！）+ ring 积压 8 个提交没消费——**不是坏命令流挂 GPU，
是电源管理层（GMU）死了**。

**排除清单**（全部实测，方法论比结论值钱）：
| 假设 | 实验 | 结果 |
|---|---|---|
| 内核构建问题 | Ubuntu 用户态 + 我们的 Image/DTB（禁模块）跑 vulkaninfo/kmscube | ✅ turnip 完好，GMU 零报错 → 内核洗清 |
| 毒频点 OPP | devfreq userspace 扫全部 8 档（270–690MHz）满载 | 全过 |
| 挂起/唤醒竞态 | 3 路并发开关 GPU + 混合渲染负载 | 全过 |
| SF 帧节奏竞态 | 短爆发渲染 ×40 循环 | 全过 |
| 固件不一致 | vendor vs /lib/firmware 哈希比对（a660_gmu/a660_sqe）| 位相同 |
| 内核参数差异 | iommu.strict/passthrough 对齐 | 无效 |
| 内核抢占开关 | `msm.enable_preemption=0` | 无效（内核照样接受 ALLOW_PREEMPT flag）|

**现行主嫌**：turnip 25.3 的**抢占支持**。`tu_drm_has_preemption` 只要内核
接受 `MSM_SUBMITQUEUE_ALLOW_PREEMPT` 就全队列开抢占并按可抢占方式编排命令流；
Android 的不对称触发条件在于 **SurfaceFlinger 用高优先级上下文**、应用用默认
优先级（Ubuntu 的测试客户端全是单一优先级，永远不触发跨优先级调度）。
→ `patches/0005`：turnip 硬关 has_preemption。

**快速迭代机制**（告别 15 分钟/次的重建循环）：init.gaokun3.rc 在
post-fs-data 把 `/data/local/tmp/tu_debug` 内容装进 `debug.tu.debug` 属性
（mesa 的 os_get_option 在 Android 按 `debug.`/`vendor.`/裸名读属性，
`TU_DEBUG` → `tu.debug`）。此后 turnip 调试旗标实验 = 写文件 + 重启（2 分钟）。
可用旗标：nobin sysmem gmem noubwc nolrz flushall syncdraw noconform 等
（见 `tu_util.cc` 的 tu_debug_options 表）。

## 另一个必需件：GPU zap shader 固件

`adreno 3d00000.gpu: [drm:adreno_zap_shader_load] *ERROR* Unable to load
qcom/sc8280xp/HUAWEI/gaokun3/qcdxkmsuc8280.mbn`

zap shader 负责把 GPU 从安全模式解出来，缺了它 GPU 不可用。这个华为专有 blob
不在 linux-firmware 里，但**本机 Ubuntu 的 `/lib/firmware` 里有**（连同音频
拓扑 `audioreach-tplg.bin` 和 pd_mapper 的 `*.jsn`）。已加入设备树的固件
双路安装（vendor + ramdisk），见 `docs/stage4-findings.md` #31。

## 换 crDroid 时怎么迁

可移植的部分：内核、DTB、固件、`external/mesa3d` 的生成+合并脚本、
glslang 补丁、`turnip-shared.bp.in`。
需要重做的部分：LineageOS 系有自己的 mesa/ANGLE 打包惯例（可能直接有
`BOARD_MESA3D_*` 支持，见 `docs/parallel-mainline-generic.md`），
届时优先用它们的机制，本文档的坑清单仍然适用于排障。

## D4. 侦查战 2026-08-18：旧结论翻案 + 死亡现场首次完整取证

**背景**：决定不等上游自己修。本节记录一整天的排除战果，工具全在
`scripts/gmu-forensics/`。

### 旧结论翻案（先纠史）

- **"同一内核在 Ubuntu 下完好"此前从未被实证**——旧对照跑的是发行版
  7.1.0-rc3 内核 + apt turnip。本日用 **kb19 本尊**（sha256
  `35ff3019…3c5f`，/proc/version `#12 Mon Aug 17 12:50:56 UTC 2026`）
  + Ubuntu 用户态补齐了这块：**六种负载矩阵全部无法杀死 GMU**：
  满载 120s（52 次变频跨档）、300 轮真实 GMU 掉电冷启动（runtime
  suspend 计数器实证 59.3s）、抢占毒参数下的抢占模式渲染（strace 实证
  探测队列被接受）、双/三优先级 8.5 万次并发提交、churn+跨优先级组合、
  跨客户端唤醒相位。引导条目 `ubuntu-kb19*.conf` 留在 ESP 可复用。
- **`msm.enable_preemption=0` 是有害参数**：v7.2-rc2
  `msm_submitqueue.c:201-205` 判断语义反转（变量名与逻辑相反），传 0
  反而让内核接受 ALLOW_PREEMPT → turnip 进抢占模式。已从 cmdline 删除
  （原始死法与它无关：删后同签名复死）。**该反转判断值得投上游修复**。
- 旧排除项作废清单：governor 钉频（performance=m 不可加载，从未生效）、
  tu_debug"全部无罪"（无结果记录）、Ubuntu 旧压测（错内核错用户态）。

### 死亡现场取证（工具链 + 结论）

devcoredump 解码：ascii85 按 u32 值编码（大端解）；HFI 头 =
`id | size<<8 | seq<<20`；`scripts/gmu-forensics/{gmu-hfi-decode,
decode-fatal,decode-gmulog,decode-ring}.py`。宿主捕获器
`capture-death.sh`（klog 抓早期、devcd 按节点编号秒拉）。

**五次受控死亡（death-capture-2..7）的统一画像**：

1. 原始死法：GMU 单会话 ~2s、15 条 HFI 全部正常应答
   （PERF_TABLE/BW_TABLE/CORE_FW_START/START + 投票 档1→档4→档8→档1 全 ACK），
   **seq16 投票（档 8=690M，与 2 秒前刚 ACK 过的 seq14 同 payload）
   躺在 cmd 队列 rd=244 永不被消费**。GMU 固件日志（4 词记录
   {msg头,事件码,ts,arg}）显示 seq15（降 270M）的 ACK 是最后一条完整
   记录——**CM3 冻死在最低频善后开始处，seq16 连接收都没记**。
2. min_freq 钉 690（gpupin 服务）：HFI 全消费全 ACK，但 **CP 消费 16
   个提交后停在 CP_MEM_TO_REG（读特权 memptrs）**，ring 积压 8。
3. 禁 bootanim：死于**第 1-2 个提交**的 CP_EVENT_WRITE 0x19（缓存维护）。
4. **统一结论：谁碰内存子系统谁冻死（CM3 的 AHB 善后 / CP 的读与缓存
   维护），与投票内容、变频、抢占、提交数全部无关**；恢复循环
   `cx gdsc didn't collapse` 是下游放大器。
5. bw_index 恒 0（a690 无 .bcms，GMU 带宽表是 "single off entry, TODO"
   占位符）；真实总线投票走 dev_pm_opp_set_opp 的 ICC 并行路径。

### 已排除（本日新增，全部实测）

内核版本差（kb19 在 Ubuntu 下无敌）｜ 变频/投票内容 ｜ runtime PM churn
｜ 抢占（内核旗标与 turnip 模式双向）｜ sync_state 清理时序（gcc/gpucc
永远 pending：GMU 设备无驱动绑定、camss 永不探测，两 OS 相同）｜
deferred_probe_timeout 值 ｜ WiFi/PCIe 并发（initcall_blacklist 拔净
ath11k 仍死）｜ 多进程页表切换为唯一诱因（单上下文第 1 提交也死）｜
bootanim ｜ IFPC（a690 无 quirk）｜ ACD（DT 无 acd-level）｜
GEMNoC workaround 缺失作为**触发器**（作为放大器仍候选）

### 剩余嫌疑（按后验概率）

1. **我们的 AOSP turnip 构建**（vs apt 构建，同源码同版本）——工具链
   （AOSP clang vs gcc）或 Soong 转换配置差（生成的 defines）。
   正在验证：Ubuntu 上 gcc 编同源码+0004 补丁跑 vkmark
   （`scripts/gmu-forensics/mesa-lab-setup.sh`）。
2. **cmdstream 内容差**——crashdec 反汇编死亡提交 IB（devcd 里带全部
   BO 数据）与 apt turnip 参考流对比。
3. Android 环境的更深层差异（LLCC/缓存属性组合等待证）。

### 运维资产（本日新增，日后全用得上）

- **vendor 免构建机可写**：cmdline 加
  `androidboot.flash.locked=0 androidboot.verifiedbootstate=orange`
  后 `adb remount` 走 overlayfs（scratch 落 super 空闲区，重启后挂 ro，
  写前重跑 adb remount）。ro.hardware.vulkan 切换、init rc 投放、
  build.prop 实验从此零成本。
- 死亡复现开关：/vendor/build.prop `ro.hardware.vulkan=freedreno`（当前
  设备处于此状态 + nobootanimation + skiavk 实验残留，**收尾时需还原**）。
- gpupin 服务（`gpu-pin.sh`+`gpupin.rc`，seclabel u:r:shell:s0 过 init
  校验）：等 devfreq 节点出现即写 min_freq，目标值读
  /data/local/tmp/gpu_min_freq。

## D5. 真凶浮出：GPU SMMU translation fault（crashdec 铁证，推翻电源假说）

用自建 crashdec（`mesa-26.0.3/btools`，7.2 devcd 需把 `revision:` 行改成
`690 (6.9.0.0)` 骗过 parser）解全部 5 份死亡 devcoredump，**寄存器组给出
决定性证据**：

```
RBBM_STATUS:  { ... CP_BUSY | CP_AHB_BUSY_CX_MASTER }
RBBM_STATUS3: { SMMU_STALLED_ON_FAULT | 0xf060000f }   ← 5/5 全部命中
CP_IB1_REM_SIZE: 0    CP_IB2_REM_SIZE: 0                ← IB 都执行完了
CP_RB_RPTR: 0x2c9 < CP_RB_WPTR: 0x3e3                   ← ring 还有活没干
CP_HW_FAULT: 0
```

**判决**：GPU 的 SMMU（per-process pagetable）**卡在一次 translation
fault 上**（stall-on-fault 模式）→ AHB 总线 stall（`CP_AHB_BUSY_CX_MASTER`）
→ CP 取不到下一条指令 → GMU 想投票也碰不了总线 → `GX_BW_PERF_VOTE`
1 秒超时 → 看门狗。**`GX_BW_PERF_VOTE timed out` 是果，不是因；
GMU 电源假说（D3）被推翻**——旧判断"rbbm-status=0 + ring 积压 = 电源层死"
读的是内核早期快照，crashdec 从完整寄存器组读到的是 SMMU stall。

**这解释了全部矛盾**：
- 为什么 Ubuntu vkmark 无敌：kms winsys 渲染到 turnip **自分配**的 buffer，
  映射完全自控，无外来 IOVA；
- 为什么 Android 必死：SF/app 渲染到 gralloc(minigbm) 分配、经 dma-buf
  **导入 turnip** 的 ANativeWindowBuffer——**导入路径建立的 GPU 映射有误**
  （地址/大小/pagetable 归属），GPU 一访问就 fault；
- 为什么电源/变频/抢占/WiFi/时序全部实验无效：根本不在那条线上；
- 为什么单进程(X3)也死、且死更早：单 context 也走 ANB 导入，首帧就 fault。

→ **真凶重新锁定 WSI/ANB buffer 导入路径**（D 节开头的原始头号嫌疑，
一度被 D3 电源假说挤下，现由 SMMU_STALLED_ON_FAULT 铁证复位）。
patch 0004（ANB NULL-memory 重绑定）修的是**用户态崩溃**，与此正交——
真正要查的是 `vk_android_import_anb`（create 时 dma-buf 导入 + BindImageMemory2
建映射，见 src/vulkan/runtime/vk_android.c）在 a690 上产生的 GPU 映射
是否与 minigbm 的实际 buffer 布局/大小一致。

**旁证疑点**：内核 klog **没有** adreno SMMU fault handler 的地址打印
（正常应有 TTBR0/FAR/FSR 的 dev_err）→ a690 的 GPU SMMU context-fault
IRQ 路由可能也没接好（fault 静默 stall，驱动拿不到地址）——这本身是
第二个待查的 a690 特有缺陷。

### 下一步（已排好，全部低成本）
1. **抓 fault 地址**：开 arm-smmu/adreno dynamic debug + 确认 GPU SMMU
   context-fault IRQ；或 X4（DTB 单字节禁 `qcom,adreno-smmu` → 退全局
   地址空间，`scripts/gmu-forensics/dtb-smmu-patch.py`）看 fault 是否消失。
2. **审 ANB 导入映射**：对比 turnip 导入 buffer 的 iova/size 与 minigbm
   分配的实际布局；devcd 的 `bos:` 段有全部 BO 的 iova+size 可交叉核对。
3. 自建 turnip（Ubuntu gcc，btools 已通、bturnip 构建待修）本用于
   "我们的构建 vs apt 构建"对比，现降级——SMMU fault 指向导入逻辑而非
   工具链，除非确需再排构建差。

## D6. 根因确认：GPU SMMU 的 context-fault 中断从不到达 CPU（stall 死锁）

D5 定位到 SMMU translation fault 后，继续追问"为什么内核从不处理这次
fault"。**内核 5 份死亡日志里一条 fault 打印都没有**
（`*** gpu fault` / `*** fault: iova=` / `Unhandled context fault` 全 0 命中，
msm_iommu.c:647 与 adreno 侧打印均缺席）。

### 铁证一：中断使能着，但计数恒为 0

```
/proc/interrupts（Android，fault 已发生、recover 循环中）：
 41:  0 ... GICv3  710 Level  arm-smmu-context-fault   ← GPU SMMU CB0（SPI 678）
 42:  0 ... GICv3  711 Level  arm-smmu-context-fault
 39/40: 0 ...      704/705    arm-smmu global fault
```
15 秒观察窗内（期间 hangcheck 每 500ms 重试提交并反复 fault）**零增长**。
对照：`gpu-irq`（hwirq 332）计数 233，说明 GPU 自身中断链路是通的。

### 铁证二：devmem 直读 SMMU 硬件（CB0 @ 0x3db0000）

`CONFIG_DEVMEM=y` 且 `IO_STRICT_DEVMEM` 未开 → toybox `devmem` 可直读 MMIO。
CB 基址推导：`ID1=0x30000007` → NUMPAGENDXB=3 → numpage=16，4KB 页
→ `CB0 = 0x3da0000 + 16*0x1000 = 0x3db0000`（`ID0=0x4c017e09` 的 NUMSMRG=9
与 dmesg "9 register groups"、NUMCB=7 与 "7 context banks" 对齐）。

```
死亡现场（GPU 仍上电、cx gdsc 塌不下去时）：
  SCTLR = 0x1E7  → M=1 TRE=1 AFE=1 CFRE=1 CFIE=1 CFCFG=1 S1_ASIDPNE=1
                    ↑ 中断使能(CFIE) 与 stall-on-fault(CFCFG) 都正确开着
  FSR   = 0x40000400 → SS=1（bit30，SMMU 正卡在 stalled state）
                       但 TF/PF/EF/AFF/TLBMCF 全 0，FAR=0（fault 记录已被清）
```

### 铁证三：手工解锁 → GPU 当场复活

```
devmem CB0+0x00 4 0x167   # 清 SCTLR.CFCFG(bit7)：fault 改走 terminate
devmem CB0+0x08 4 1       # CB_RESUME=TERMINATE：放掉卡住的事务
→ SCTLR 0x1E7→0x167，FSR 0x40000400→0x80000602（SS 清除，MULTI|TF 浮现）
→ GMU 错误停止累积，dumpsys SurfaceFlinger --latency 返回 16666682（60Hz vsync）
→ 随后 CB0 全寄存器读 0 = **GPU 成功掉电了**（此前正是 stall 拖住掉电，
   才有那句 cx gdsc didn't collapse）
```
重启 + 开机自动解锁服务后：**GMU 错误 0，持续 95s+ 零错误**
（此前每次必进死循环）。

### 完整死亡链（终版）

1. GPU 渲染中访问了未正确映射的 IOVA → SMMU translation fault
2. SMMU 按 CFCFG=1 进入 **stall**，等 CPU 处理
3. **context-fault 中断从不到达 CPU** → 没人读 FSR、没人写 CB_RESUME
4. SMMU 永久 stall → AHB 总线 stall（`CP_AHB_BUSY_CX_MASTER`）→ CP 取不到指令
5. GMU 想投票也碰不了总线 → `GX_BW_PERF_VOTE` 1s 超时 → 看门狗
6. recover 想让 GPU 掉电，但 stall 拖住 → `cx gdsc didn't collapse` → 死循环

**为什么 Ubuntu 不死**：从不产生这个 fault（turnip 自分配 buffer，映射自控），
所以这条 stall 死锁链永远不被触发——不是 Ubuntu 更健壮。

### 方法学（会反复踩）

- **GPU SMMU 的 CB 寄存器只在 GPU 上电时有效，掉电后一律读 0**。
  `TTBR0=0/FAR=0` 若与 SCTLR=0 同时出现，是掉电，不是真值。
- toybox `devmem` 输出**十进制**（`00000487` = 0x1E7），别当 hex 读。
- ⚠️ **X4 实验（DTB 破坏 `qcom,adreno-smmu` compatible）已取消**：
  `msm_iommu.c:788` 无条件解引用 `adreno_smmu->cookie`，
  compatible 一改 drvdata 就是 NULL → 开机即 NULL deref panic。

### 疑点：DTS 的 SMMU 中断号跳号

`sc8280xp.dtsi` 的 `gpu_smmu`：global = SPI 672/673，context = SPI **678**–689
—— **674-677 被跳过**。若实际硬件 context fault 起于 674，则 CB0 的中断被整体
错配（DTS 逆向而来，无手册对照），完全符合"使能了但永不到达"。**待验证**。

### 修复层次

1. **可用性 workaround（已验证）**：`scripts/gmu-forensics/smmu-nostall.sh`
   + `smmustall.rc` —— 轮询清 `SCTLR.CFCFG`（内核 recover 会重写，故须持续），
   顺带趁上电抓 `FSR/FAR/FSYNR/TTBR0` 并 `log -t smmustall` 打出 fault 地址。
2. **内核补丁**：本平台不能用 stall-on-fault（msm_iommu.c 的
   `set_stall(true)` 是为抓 devcoredump 的调试特性，在中断不通的平台上
   直接致命）→ 条件禁用。**可提上游**。
3. **根治**：修 DTS 中断号（需先验证 674 假设）。
4. **fault 本身**：terminate 后系统能继续渲染，暗示 fault 影响局部
   （疑 CP 预取越界 / ANB 导入映射尺寸不符）——下一场从 workaround 打出的
   FAR 地址与 devcd `bos:` 表交叉核对开始。
