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

## D7. 瓶颈转移：turnip 在 ANGLE dynamic-rendering 路径上的空指针（+ 一个属性名陷阱）

D6 的 SMMU 解锁让 GPU 层彻底健康（**GMU 错误 0，持续 190s+，此前必进死循环**），
SurfaceFlinger 恢复 60Hz vsync、SystemUI 起来了。但 `boot_completed` 仍不出——
**瓶颈从内核死锁转移到 turnip 用户态崩溃**。

### 崩溃签名

```
signal 11 (SIGSEGV), SEGV_MAPERR, fault addr 0xd0 (read)   ← NULL + 208
#00 tu_cmd_render<(chip)6>(tu_cmd_buffer*, VkOffset2D const*)+324
#01 tu_CmdEndRendering2EXT(...)+552
#02 vk_common_CmdEndRendering+56
#03 libGLESv2_angle.so  rx::vk::RenderPassCommandBufferHelper::flushToPrimary(...)
#04..06 ANGLE  CommandPoolAccess::flushRenderPassCommands / ContextVk::flushCommandsAndEndRenderPass
```

**这条路径只有 Android 会走**：ANGLE 用 **dynamic rendering**
（`vkCmdBeginRendering`/`EndRendering`）；Ubuntu 侧的 vkmark/vulkaninfo 用传统
render pass，**永远不经过 `tu_CmdEndRendering2EXT`** —— Ubuntu 无敌的另一半原因
（前一半是从不产生 SMMU fault）。

`tu_CmdEndRendering2EXT` 本身对 `pRenderingEndInfo=NULL` 是安全的
（`vk_find_struct_const` 容 NULL → `fdm_offsets=NULL`），所以不是参数问题；
崩在 `tu_cmd_render` 内联体里读某个 NULL 指针的 +0xd0 字段
（`cmd->state.pass` / `attachments` / `tiling` 一类渲染状态缺失）。

### ⚠️ 陷阱：tu_debug 属性名一直是错的

mesa `src/util/os_misc.c` 的 `os_get_android_option()`：
`TU_DEBUG` 不以 `MESA_` 开头 → **加 `mesa.` 前缀** → 下划线转点、转小写
→ `mesa.tu.debug` → 再依次试前缀 `debug.` / `vendor.` / `""`。

→ **正确属性名是 `debug.mesa.tu.debug`**，而档案与 init.gaokun3.rc 里一直写的是
`debug.tu.debug`。**结论：2026-08-18 之前所有 tu_debug 旗标实验的旗标从未生效**，
"旗标全部无罪"的旧结论作废（`init.gaokun3.rc` 已修正，
overlay 侧另有 `scripts/gmu-forensics/tudebug.rc`）。

用正确属性名重做 `sysmem`（`use_sysmem_rendering()` 第一行就
`if (TU_DEBUG(SYSMEM)) return true`，能跳过 `cmd->state.tiling->possible`
那处解引用）：属性确认生效，但**崩溃点分毫未变**（同 +324/0xd0）→
崩溃不在 tiling 检查里，位置更靠前或在 sysmem 分支内部。

### 现状与下一步

- GPU/内核层：**已解决**（SMMU workaround 常驻，GMU 零错误）
- 用户态层：turnip 在 ANGLE dynamic-rendering 收尾路径上 NULL deref，
  阻止 systemui/system_server 存活 → 系统起不来
- 正在验证：`debug.hwui.renderer=skiavk` 让 HWUI 直连 Vulkan、**绕开 ANGLE**
  （SurfaceFlinger 用 `debug.renderengine.backend=skiavkthreaded` 已证明
  skia+turnip 这条路不崩）
- 若绕行有效 → 系统可用，ANGLE 只留给纯 GLES 应用，turnip bug 单独修
- 若无效 → 需源码级定位：VM 里给 turnip 编 debug 符号版，或对
  `tu_cmd_render+324` 反汇编确认 +0xd0 是哪个字段，然后修 mesa（可提上游）

## D8. 两条用户态路径的堵点都已精确定位（下一场只需一次 VM 会话）

GPU/内核层解决后（D6），Android 上剩下两条渲染路径，各有一个**明确的**障碍：

| 路径 | 配置 | 障碍 | 证据 |
|---|---|---|---|
| **GLES→ANGLE→Vulkan**（默认，`debug.hwui.renderer=skiagl`） | ANGLE 提供 GLES | turnip 在 **dynamic-rendering 收尾**处 NULL deref | `tu_cmd_render+324` 读 `NULL+0xd0`，栈经 `vk_common_CmdEndRendering` → `tu_CmdEndRendering2EXT` ← ANGLE `flushToPrimary` |
| **HWUI 直连 Vulkan**（`debug.hwui.renderer=skiavk`） | 绕开 ANGLE | **HWUI 要 2 个队列，turnip 只报 1 个** | `Abort message: Assertion failed: queueProps[i].queueFamilyProperties.queueCount < kRequestedQueueCount`（AOSP `VulkanManager.cpp`，`kRequestedQueueCount=2`，用于 protected/unprotected 双队列） |

**skiavk 实验的正面结果**：切到 skiavk 后 **`tu_cmd_render` 崩溃归零**
（60s+ 零次，此前每 5 秒涨数次），启动推进到 **launcher3 已出现**（此前只到
systemui）→ 反证了 ANGLE 的 dynamic-rendering 用法确实是那个 NULL deref 的
唯一触发源。SurfaceFlinger 用 `debug.renderengine.backend=skiavkthreaded`
全程存活（SF 的 RenderEngine 只要 1 个队列），说明 **skia+turnip 本身是通的**。

### 下一场的两个候选（按性价比）

1. ★**修 turnip 的 NULL deref**（推荐）：只需重编 `vulkan.freedreno.so`
   （~15 分钟），改 mesa 源码。定位手段：给 tu_cmd_render 路径加断言/日志，
   或对 `tu_cmd_render+324` 反汇编确认 `+0xd0` 是哪个字段
   （嫌疑：`cmd->state.pass` / `attachments` / `tiling` 在 ANGLE 的
   suspend-resume / secondary-CB 用法下未建立）。**修好即可提上游**，
   且 ANGLE 路径同时供 GLES 游戏使用 —— 与 Stage 5 目标一致。
2. 改 AOSP HWUI 的 `kRequestedQueueCount` 为 1：绕开队列断言，但要重编
   framework（慢），且 protected content 路径存疑。

### 设备当前状态（收尾）

已还原软渲染兜底可用态（`ro.hardware.vulkan=pastel`、`debug.hwui.renderer=skiagl`），
**SMMU workaround 服务保留常驻**（对将来 turnip 复用是必需的，且 pastel 下
GPU 不初始化时脚本读到 0 自动不动作，无副作用）。turnip 仍在 vendor 里。

## D9. ★里程碑：Android + turnip 硬件 GPU 完整启动进桌面

**2026-08-18 晚，`*** BOOT COMPLETED ***` at t=35s**：

```
renderer: freedreno      hwui: skiagl（原本必崩的 ANGLE 路径）
Turnip Adreno (TM) 690   turnip 崩溃 = 0
桌面进程：surfaceflinger + system_server + systemui + launcher3 全部存活
```

### 单一根因：patch 0004 v1 自己制造的 NULL

`llvm-addr2line` 配 `symbols/` 下的未 strip 库（BuildId `fdd5d912…` 与设备端
逐字节一致）把崩溃地址一次翻译到底：

```
0xa4e040 → tu_allocate_transient_attachments()  tu_cmd_buffer.cc:3955
         → 内联进 tu_cmd_render_sysmem()        :4087
         → 内联进 tu_cmd_render()               :4123
```

**3955 行就是 `!iview->image->mem->bo &&`** —— `image->mem` 是 NULL，
读它的 `bo`（`offsetof` 正好 **0xd0**，与 tombstone 的 fault addr 完全吻合）。

而 `image->mem` 为什么是 NULL？**patch 0004 v1 干的**：它在
`BindImageMemory2(memory=NULL)` 时直接 `return VK_SUCCESS`，
**从不给 `image->mem` 赋值**。于是同一个 NULL 制造了两个看似无关的灾难：

| 层 | 表现 | 追查记录 |
|---|---|---|
| 用户态 | `tu_allocate_transient_attachments` 解引用 NULL → SIGSEGV → RenderThread 崩溃风暴 | D7 |
| 内核态 | 该 image 的 `iova` 无效 → GPU 访问非法地址 → **SMMU translation fault** → 本平台 context-fault 中断不通 → 永久 stall → CP 断粮 → GMU 投票超时 → 看门狗 → 掉电失败 → 死循环 | D5/D6 |

→ **D5–D8 追了两天的全部现象，归一到这一个 bug。**
"GMU 必死"从来不是电源管理问题，而是一个空指针的下游放大。

### 修复（patch 0004 v2，权威实现 `scripts/gmu-forensics/apply-0004v2.py`）

1. `tu_image.cc`：NULL memory 时改用 `image->vk.anb_memory`
   （vkCreateImage 时 `vk_android_import_anb()` 导入的真实内存）装进
   `image->mem`；连它也没有才安全跳过（不再走 UB）。
2. `tu_cmd_buffer.cc`：`iview->image->mem &&` 防御——没有内存自然不需惰性分配。

编译 **1 分 31 秒**（`m vulkan.freedreno`），部署走 overlayfs `adb push`
（**不刷 super**，`scripts/gmu-forensics/deploy-turnip.sh` 一键完成），
顺带把 SELinux 标签从 `vendor_file` 改正为 `same_process_hal_file`
（与 vulkan.pastel.so 对齐；此前 app 加载它一直有 avc denied）。

### ⚠️ 浸泡暴露的边界：能启动，但撑不住持续运行

启动后 2 分钟浸泡（每 20s 采样）：`boot_completed=1` 一直在，GMU 错误在
7–9 之间小幅波动（缓冲轮转 + 零星新增，不是雪崩）。但**到第 7 分钟，
`surfaceflinger` / `system_server` / `launcher3` 全部消失，`input` 服务
也没了** —— 框架被残余 fault 慢慢拖垮。`screencap` 从一开始就卡死
（>3 分钟无返回），说明 GPU 的帧读回路径也踩在同一个坑上。

**所以 D9 的准确表述是**：主因已修、里程碑达成（首次用硬件 GPU 进桌面），
但**尚未稳定可用**，设备已回退 `ro.hardware.vulkan=pastel` 保持日常可用。
剩下的就是下面这个残余 fault —— 它是"稳定"与"能启动"之间的唯一距离。

### 残余问题（下一场）

- **仍有少量 SMMU fault**：`smmustall` 打出 `FAR=0x100`、
  `TTBR0=0x1_1C400000` —— 又是一个"iova 未设置 + 小偏移"的特征，说明还有
  image 走了 v2 的"安全跳过"分支（既无 memory 也无 anb_memory）。
  SMMU workaround 兜住了不死锁，但 GPU 会偶发 reset
  （`screencap` 会卡、GMU 错误缓慢累积）。
  → 下一场：在那个 else 分支加 `mesa_logw` 打印 image 属性
  （`create_flags`/`usage`/`format`/是否 ANB），一轮编译即可定性。
- 蓝牙仍在崩溃循环（已知 #30，无 HCI HAL，与 GPU 无关）。

### 上游价值

- `tu_image_bind` 的 ANB NULL-memory 处理（v2）是真 bug 修复，可提 mesa。
- 「本平台不能用 stall-on-fault」（D6）：msm_iommu.c 的 `set_stall(true)`
  在 context-fault 中断不通的平台上会把任何一次 fault 放大成整机死锁
  → 条件禁用，可提上游。
- `msm_submitqueue.c:201` 抢占判断语义反转（D4）→ 可提上游。

---

## D10. ★★残余 fault 归零：实现 turnip 从未实现的 ANB 延迟绑定

**2026-08-19。一轮"三探针"编译定性 + 一轮修复编译，把 D9 的残余 fault 打到 0。**

### 三探针（`scripts/gmu-forensics/apply-diag-b1.py`）

D9 收尾时只知道"还有 image 走了 v2 的安全跳过分支"，不知道是谁。
读权威快照先立了两个硬事实：

- `struct tu_image` 里 `iova` 的注释就是 **"Set when bound"** —— 未绑定就是 0；
  且 `mem` 与 `vma` 是 **union**（所以上游那句检查先看 SPARSE_BINDING 再碰 `mem`）。
- `tu_image_view_init()` 第 281 行 `args.iova = image->iova` ——
  **view 的描述符在建 view 那一刻就把地址烤死了**。未绑定 → 烤进 0。

于是三个探针（各限流，一轮编译全上）：

| 探针 | 位置 | 抓什么 |
|---|---|---|
| P1 | `tu_image_bind` 的 `!mem` 分支 | image 属性 + **pNext 链的 sType** + `dladdr` 调用栈 |
| P2 ★ | `tu_image_view_init` | 给 `iova==0` 的非 sparse image 建 view —— 真凶哨兵 |
| P3 | `tu_allocate_transient_attachments` | 无内存 attachment 被当渲染目标的频次 |

### 判决：Android loader 走的是**延迟绑定**

```
P1 NULL-bind #1 pNext=[1000010000,1000060009,] anb_mem=0x0
                     ↑NATIVE_BUFFER_ANDROID   ↑BIND_IMAGE_MEMORY_SWAPCHAIN_INFO_KHR
P1 image=… fmt=37 1600x2560 usage=0x97 iova=0x0 mem=0x0 anb=0 ahb=0 anb_mem=0x0
P1 caller[1] /system/lib64/libvulkan.so
P1 caller[2] /system/lib64/libGLESv2_angle.so
```

- **`vkCreateImage` 时根本没有 ANB**（`anb=0`）→ `vk_image_init` 没把
  `android_buffer_type` 设成 NATIVE → `vk_android_import_anb()` 从未运行
  → `vk.anb_memory` 为空。
- gralloc buffer 是在 **`vkBindImageMemory2` 这一刻**才通过
  `pNext` 的 `VkNativeBufferANDROID` 递进来的。
- **这正是 mesa 那句 `/* TODO handle VkNativeBufferANDROID */` 指的路径**，
  turnip 从来没实现过。于是：
  v1 走 `UNREACHABLE`（release 下 UB）；v2 去找 create 时的 `anb_memory`
  当然是空 → "安全跳过" → **image 永远没有内存**。
- 66 次 SMMU fault 里 **65 次是写**，FAR 值全是
  185344 / 186624 / 187904 / 83712 这类小地址 ——
  正是 1600 宽 RGBA 图从 **iova 0** 起算的行偏移。闭环。

### 修复（patch 0004 v3，`scripts/gmu-forensics/apply-0004v3.py`）

在 `!mem` 分支里实现那个 TODO，全用 runtime 现成 helper（可直接提上游）：

1. 用 bind info 的 ANB 造一份等价 `VkImageCreateInfo`；
2. `vk_android_get_anb_layout()` 取 gralloc buffer 的真实 modifier / plane layout
   → `tu_image_update_layout()` **重算布局**。
   ⚠️ 这步不能省：image 默认走 UBWC，而我们的 minigbm 是
   `nocompression=LINEAR`，不重算就是错位渲染 + 越界写。
3. `vk_android_import_anb()` 导入 dma-buf 并绑定（它自己会再调一次
   `BindImageMemory2`，那次 memory 非空，走正常路径落 `mem`/`iova`）。
   重复绑定先 `FreeMemory` 掉上一块，否则轮转时每次漏一个 dma-buf。
4. 真正无可绑定的情况保留跳过，但 `mesa_logw` 吼一声（实测该分支 0 命中）。

### 验收（同一台机器，同一天，前后对比）

| 指标 | v2（D9） | **v3** |
|---|---|---|
| SMMU fault 数 | 66 | **0** |
| P2 给未绑定 image 建 view | 96 行 | **0** |
| P3 无内存 attachment | 68 行 | **0** |
| `screencap` | 从头永久卡死 | **rc=0，3.27 MB PNG** |
| 启动 | 35s 进桌面 | 36s 进桌面 |
| GMU 错误 / `a6xx_recover` | 0 / 0 | 0 / 0 |

**截图逐像素正确**（锁屏壁纸渐变、时钟、状态栏、电量），
无错位无花屏 → 布局重算这步是对的。

### ★D6 悬案的物理机制：内核在听 678，硬件在喊 675/680

给 workaround 加了一行"fault 当场读 `GICD_ISPENDR22`（INTID 704-735）"，
一次就定性：

```
空闲基线      GICPEND22 = 0x78000000  bits 27-30 → INTID 731-734（别的设备的孤儿中断）
每次 fault    GICPEND22 = 0x78000108  **多出 bit3 和 bit8 → INTID 707 / 712 = SPI 675 / SPI 680**
而 /proc/interrupts 里内核注册并使能的是 INTID 710/711 = SPI 678/679，计数**恒 0**
```

- `/proc/interrupts` 实证 gpu_smmu 只注册 **2 条** `arm-smmu-context-fault`
  （CB0=GPU，CB1=GMU 自己的 iommu domain），`GICD_ISENABLER22=0xC1`
  → 704/710/711 确实**已在 GIC 使能**。
- 所以不是"SMMU 不拉中断"，也不是"内核没使能"，而是
  **GPU SMMU 实际拉的线不是 DT 里写的那两条**。
- ⚠️ **推翻本轮规划期的判断**：我曾用 sc8180x 的 adreno_smmu 也有编号间隙
  （全局 674 + 上下文 681 起）论证"跳号正常、DT 没问题"。
  实测反证：DT 的 678/679 与硬件不符。
- 下一步（可根治，DTB 级改动、无需重编内核）：把 gpu_smmu 的 context
  interrupts 改到实测那两条，看 `/proc/interrupts` 是否开始计数、
  内核自己的 `msm_fault_handler` 是否接管 → 成功即可**彻底丢掉轮询脚本**，
  并把「本平台 stall-on-fault 不可用」的上游补丁改成更准确的表述。

### 本轮自己踩的两个坑（都很贵）

1. ⚠️⚠️ **绝不要访问未实现的 SMMU context bank**。我把监视器从"只看 CB0"
   改成"扫满 reg 窗口的 16 个 CB"，结果 **Android 连续三次启动到
   post-fs-data（`derive_classpath` 之后）静默死亡**：无 tombstone、
   无 pstore（cmdline 的 `efi=noruntime` 让 efi_pstore 写不进去）、
   adb 永不上线。未实现 CB 的 MMIO 访问 = external abort = 内核当场没了。
   改成 `NCB=2` 后一次就正常启动。**实现了几个 CB 看 `/proc/interrupts`。**
2. **init 会解析 `/vendor/etc/init/` 下的所有文件，不只 `*.rc`**：
   把 rc 改名成 `.rc.off` 停不掉服务（实测照样起来）。要停用必须移出目录。

### 新增运维资产

- **离线救场通道 `scripts/gmu-forensics/overlay-rescue.sh`**：adb 彻底不通时
  从 Ubuntu 侧直接读写 Android 的 vendor overlay。关键细节：
  `adb remount` 的 scratch 是 super 里的 **f2fs** 逻辑分区、
  由 **4 段 extent** 拼成（真正那块 5.2 GB 在最后），必须 dm-linear
  按序拼回去；**7.2 内核没编 f2fs**，得先用 `ubuntu-kb19` 启动项
  （Android 内核 + Ubuntu 根，它带 `F2FS_FS=y`）。另含 userdata 尸检
  （`/data/system/environ/classpath` 等"每次启动都重写"的文件的 mtime
  能证明 Android 到底跑到了哪一步）。
- **默认启动项改成 Ubuntu**：Android 挂死时拍一下电源键就自动回落，
  不需要人到机器前选菜单。代价是 `adb reboot` 进 Ubuntu，
  要进 Android 得在 Ubuntu 里 `bootctl set-oneshot …android.conf`
  （`deploy-turnip.sh` 已内置中转；Android 侧因 `efi=noruntime` 没有
  efivarfs，自己设不了）。
- `deploy-turnip.sh` 走 `scp -C`：这条链路只有几十 KB/s，压缩省一半以上时间。
