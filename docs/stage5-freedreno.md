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
