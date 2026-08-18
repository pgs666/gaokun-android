# 项目：MateBook E Go (sc8280xp / gaokun) 移植 Android

## 目标

在华为 MateBook E Go（Snapdragon 8cx Gen 3 / sc8280xp，代号 gaokun）上跑原生 AOSP，
最终目标是能稳定运行 arm64 手游。

**当前阶段：Stage 6 — crDroid 16.0 移植中（M0：构建机已腾空，`repo sync` 进行中）**（每次开工时更新这一行）

> **★决策（2026-08-19）：硬件使能告一段落，下一步转 crDroid 移植。**
> 理由：剩下卡住的东西（App/媒体没声音）**不是硬件或内核问题**，
> 而是这棵手搓最小 AOSP 缺产品级配置 —— `MediaCodecList` 是空的
> （`/vendor/etc/media_codecs.xml` 原本不存在，拷进去仍空，
> `ro.media.xml_variant.*` 全未设）、`/system/media/audio/` 整个缺失
> （铃声/UI 音效一个没有）。这些是 Lineage/crDroid 设备树的标准组成部分，
> 换轨后大概率自动消失。详见 `docs/stage4-findings.md` #36。
> - **已定：直接上 crDroid**（不先过 Lineage）。执行案卷 `docs/stage6-crdroid.md`。
>   - crDroid `16.0` = LineageOS 23.2 布局，AOSP 基线 tag **`android-16.0.0_r4`**；
>     `lunch lineage_gaokun3-bp4a-userdebug`（release config `bp4a`，实名核实）。
>   - manifest 1180 个项目，本机只缺 `device/linaro/dragonboard`
>     → `manifests/local_manifest_gaokun3.xml`。
>   - ★**铃声缺口 crDroid 自带解决**（`vendor/lineage/audio/audio.mk` 装 44 个音频到
>     `product/media/audio/`）。
>   - ★**解码器缺口的根因换了**：不是"`media_codecs.xml` 缺失"（#36 那句已更正）。
>     逐环实测：XML 两份都在、36 个软解码库在、C2 服务已注册、VINTF 片段
>     `vintf fm` 运行时列得出、AIDL 分支被选中 —— 断点是
>     `AServiceManager_forEachDeclaredInstance()` 返回空，即
>     **servicemanager 的 declared 集里没有它**（registered ≠ declared）。
>     主嫌疑：servicemanager 的 VintfObject 快照早于 apexd 就绪，而该声明带
>     `updatable-via-apex`。证据链见 `docs/stage6-crdroid.md`。
>     **不能承诺 crDroid 自动修好**；crDroid 一起来先量 `dumpsys media.player`。
>   - ★**mesa 管线一个都不能丢**：lineage-23.2 的 `external/mesa3d` 就是 AOSP 那份，
>     `BOARD_MESA3D_*` 是平行项目自带 mesa 仓库的机制，不是 Lineage 的
>     （作废 `docs/stage5-freedreno.md:212` 的猜测）。**但好消息（已实测）**：
>     crDroid 的 `external/mesa3d` 与我们打过补丁的那棵是**同一个 commit**
>     （`d4b6f1eba289…` @ `android-16.0.0_r4`，mesa **25.3.0-devel**，
>     `tu_image.cc:918` 那句 TODO 还在）→ 管线逐字可套，最差直接铺回归档树
>     `~/keep/mesa3d-patched.tar.zst`。
>     ⚠️ 顺带修正：文档里出现过的"mesa 26"是被我们本地改过的 `VERSION`
>     文件误导，上游快照是 25.3.0-devel。
>   - 构建机磁盘：**整棵删了 `~/aosp`**（157G → 451G 可用）。
>     "只删 out 腾到 264G"的算术不够 —— crDroid 源码+.repo≈190G + out 100–130G。
>     删之前已归档 `~/keep/`（super/ramdisk/turnip.so/mesa 全树，`sha256sum -c` 通过）。
> - **可平移的成果（换 ROM 不用重做）**：kb21 内核配置 +
>   `scripts/kernel-config-android.sh` 的断言、DTB（含 gpio174 触摸补丁）、
>   固件集与 audioreach 拓扑固件的**正确路径名**、mesa turnip
>   `apply-0004v3.py`（ANB 延迟绑定，纯 mesa 修复）、
>   `smmu-nostall.sh`（SMMU stall workaround）、
>   `audio-route.sh`（混音器路由）、蓝牙用 AOSP 原装 HAL 即可、
>   以及 docs/ 里全部踩坑记录。
> - **要重做的**：Lineage 布局的设备树、UEFI 引导集成（无 fastboot）、
>   整棵 ROM 的构建。参考 `docs/parallel-mainline-generic.md`（同款内核的
>   Lineage 系平行项目，可借它的 gaokun3 配置）。

> **Stage 4 音频/蓝牙已于 2026-08-19 完成（硬件层）**：
> 声卡 `SC8280XP-HUAWEI-GAOKUN3` 注册、内置扬声器实机出声（用户确认，
> 整曲播放通过）；蓝牙 adapter `state: ON`、地址从芯片读出、零崩溃。
> 三个 `=m` 断点（LPASS pinctrl ×2 + LPASS 时钟）+ 未编的 `SND_SOC_WSA883X`
> + 拓扑固件路径名 + `RT_GROUP_SCHED=y`（挡住蓝牙的 SCHED_FIFO）——
> 全部记在 `docs/stage4-findings.md` #33–#36。
> ⚠️ 起停爆音源是功放 BOOST 升压器（A/B 实听定案），默认已关。

> **Stage 5 GPU 战况（2026-08-19 凌晨）：★GPU 攻坚完成 —— Android 用硬件
> turnip 启动进桌面，SMMU fault 归零，帧读回正常。** 案卷
> `docs/stage5-freedreno.md` D4–D10，工具集 `scripts/gmu-forensics/`
> （**11 条会反复中招的坑，动手前先读 README**）。
> - **"GMU 必死"从头到尾不是电源管理问题**，是一条空指针放大链：
>   turnip 没实现 ANB 延迟绑定 → image 没内存、`iova` 恒 0 →
>   **GPU 往地址 0 写** → GPU SMMU translation fault →
>   本平台 fault 中断打不到 CPU → `SCTLR.CFCFG=1` 永久 stall →
>   AHB 总线 stall → CP 断粮 → `GX_BW_PERF_VOTE` 超时 → 看门狗 →
>   stall 拖住掉电（`cx gdsc didn't collapse`）→ 死循环。
>   `GX_BW_PERF_VOTE 超时`是**果**，不是因。
> - ★**真凶（D10 三探针实测定性）**：Android 的 libvulkan 走**延迟绑定**——
>   `vkCreateImage` 时不带 ANB，gralloc buffer 是在 `vkBindImageMemory2`
>   那一刻才用 `pNext` 的 `VkNativeBufferANDROID` 递进来的
>   （实测 pNext=`{NATIVE_BUFFER_ANDROID, BIND_IMAGE_MEMORY_SWAPCHAIN_INFO_KHR}`，
>   调用链 ANGLE → libvulkan → turnip）。mesa 那句
>   `/* TODO handle VkNativeBufferANDROID */` 说的就是这条路，**从没人实现**。
>   **权威修复 = `scripts/gmu-forensics/apply-0004v3.py`**
>   （patches/0004 的 v1/v2 都是错的，v2 的"安全跳过"正是残余 fault 的来源）。
>   编译只需 `m vulkan.freedreno`（约 1.5 分钟），部署
>   `scripts/gmu-forensics/deploy-turnip.sh`（overlayfs，**不刷 super**）。
> - **实测对比**：SMMU fault **66 → 0**；未绑定 image 建 view **96 → 0**；
>   `screencap` 从**永久卡死 → rc=0 出 3.27MB 正常图**（截图逐像素正确，
>   证明按 gralloc 真实 modifier 重算布局那步是对的）；
>   t=36s 进桌面，GMU 错误 0，`a6xx_recover` 0，桌面四进程 PID 稳定不变。
> - ★**D6 悬案的物理机制找到了**：fault 当场读 `GICD_ISPENDR22` 发现
>   SMMU 拉的是 **SPI 675 / 680**，而 DT 声明、内核注册并使能的是
>   **SPI 678/679**（`/proc/interrupts` 计数恒 0）。**内核在听 678，
>   硬件在喊 675** —— 不是"SMMU 不拉中断"也不是"内核没使能"。
>   ⚠️ 顺带作废我自己一度下的"DT 跳号正常"判断。
>   下一步可根治：改 DTB 的 gpu_smmu context interrupts（不用重编内核），
>   成功就能彻底丢掉轮询脚本。
> - **常驻 workaround**：`scripts/gmu-forensics/smmu-nostall.sh`（轮询清
>   `SCTLR.CFCFG` 让 fault 走 terminate + 抓 FSR/FAR/GICPEND）。
>   ⚠️⚠️ **只能扫 CB0/CB1（`NCB=2`）**：实现了几个 CB 看
>   `/proc/interrupts` 的 `arm-smmu-context-fault` 条数；扫到未实现的 CB
>   → external abort → **内核静默死亡**（Android 连续三次启动到
>   post-fs-data 后消失、无 tombstone 无 pstore 无 adb）。
> - **运维**：cmdline 已带 `androidboot.flash.locked=0
>   androidboot.verifiedbootstate=orange` → `adb remount` 走 overlayfs，
>   改 vendor 不用开构建机（每次重启挂回 ro，写前重跑 remount）。
>   **默认启动项已改成 Ubuntu**（Android 挂死拍电源键自动回落）→ 要进
>   Android 得在 Ubuntu 里 `bootctl set-oneshot …android.conf`
>   （deploy 脚本已内置中转）。adb 彻底不通时走
>   `scripts/gmu-forensics/overlay-rescue.sh` 离线读写 overlay
>   （scratch 是 super 里 4 段 extent 拼的 f2fs，要 dm-linear 拼回去，
>   且得用 `ubuntu-kb19` 启动项才有 f2fs）。
> - ⚠️ **旧结论作废**：属性名是 `debug.mesa.tu.debug`（不是 `debug.tu.debug`），
>   故 2026-08-18 前所有 tu_debug 实验旗标从未生效；
>   `msm.enable_preemption=0` 是有害参数（内核判断语义反转）已从 cmdline 删。
> - mesa 26 的 AOSP 构建管线已全套入库：`scripts/mesa-tool-fixes.py`
>   + `scripts/mesa-bp-merge.py` + `scripts/join_meson_continuations.py`
>   + `patches/0003..0006` + `device/huawei/gaokun3/mesa/`。
>   软渲染兜底仍在（`ro.hardware.vulkan=pastel` 一行可切回）。
> - **下一场**：音频 —— 内核链全 =y、ADSP 三兄弟 running、固件（含
>   audioreach-tplg.bin）进 ramdisk+vendor，但声卡未注册（macro/soundwire
>   的 deferred probe 不收敛，`suppress_bind_attrs` 封死手动补绑定）。
>   另有蓝牙（#30）、s2idle、以及可选的 DTB 中断根治。

> **Stage 4 触摸已于 2026-08-17 完成：触摸丝滑可用。**
> 根因是 gpio174（模式选择脚）无人驱动，见 `docs/stage4-findings.md` #26
> 和 `patches/0002-*.patch`。✅ 补丁已应用进 VM 内核树（kb18 起自带）。
>
> **Stage 4 WiFi 已于 2026-08-17 完成：冷启动免干预自动连网。**
> 内核 kb18（ath11k 全家 =y + PWRSEQ）+ 晚绑定 + goldfish wifi HAL +
> supplicant 配置 + 国内验证端点，全程见 `docs/stage4-findings.md`
> #28/#29。adb over TCP 已开（5555 端口，缓解 #27）。
> ⚠️ 重刷 userdata 后必须跑 `scripts/android-post-flash.sh`。
> 剩余：音频、蓝牙（#30，无 HCI HAL 暂禁用）、挂起/恢复（s2idle）、
> UCSI 拔插（#27）、Ubuntu 侧 DTB 触摸补丁（等 USB_STORAGE=y 或进 Ubuntu 手做）。

> **Stage 3 已于 2026-08-17 完成验收：Android 桌面完整渲染**
> （Launcher3 + SystemUI 稳定，1600×2560，截图为证）。
> 图形 = swangle 软渲染（Phase A）；Phase B 换 freedreno 见
> `docs/parallel-mainline-generic.md` 路线图。
> ⚠️ 已确认坑：闲置 52 秒自动 s2idle 休眠后醒不来（CLAUDE.md 预言的
> EC 挂起坑），临时用 `svc power stayon true` 顶着，Stage 4 正修。

> Stage 0 / Stage 1 已于 2026-08-13 完成验收。
> **Stage 2 已于 2026-08-17 完成验收：`adb shell` 通，Android 16 稳定运行**
> （`gaokun3 device product:aosp_gaokun3`，内核 7.2.0-rc2-gaokun3+）。
> 全部 12 个实测问题及修复见 `docs/stage2-findings.md`。
> Stage 3 起点：surfaceflinger 崩于 "couldn't find an OpenGL ES
> implementation"（mesa/gralloc/hwc 未装，abort message 见
> `docs/stage2-acceptance-live.txt`）。

---

## ⚠️ 给 AI 助手的强制规则

**这个平台没有任何 Android 移植的前人成果。** 训练数据里不存在这台机器上的
Android 相关知识。因此：

1. **任何具体的 kernel config 名、AOSP property 名、HAL 接口名、文件路径，
   必须从本地 checkout 的源码树里 grep 出来，并给出文件路径和行号。**
   不允许凭记忆给出。记忆里的名字在这个平台上大概率是错的或过时的。

2. **不确定就明说"我不确定，需要验证"**，不要给出听起来笃定的猜测。
   在这个项目里，一个自信的错误答案比"我不知道"贵得多——用户要花几小时
   才能发现你编的那个 config 项根本不存在。

3. **实机行为以 dmesg / logcat / 用户的实际观察为准，与你的判断冲突时以实机为准。**

4. 涉及 sc8280xp 硬件细节时，优先查 `refs/linux-gaokun` 和 `refs/jhovold-linux`；
   涉及 AOSP-on-mainline 的组织方式时，优先查 `refs/aospm-*`。

---

## 硬件事实

| 项目 | 值 |
|---|---|
| SoC | Qualcomm Snapdragon 8cx Gen 3 / **SC8280XP** |
| 设备代号 | gaokun3（8cx Gen 3 机型）；gaokun2 是另一套 EC 协议 |
| 型号 | **HUAWEI GK-W7X，SKU C233，2022 款，CSOT 面板，触摸固件 `41 07`** |
| BIOS | **2.16**（2023-01-31）⚠️ **不要升级到 2.17** —— 触摸的 SPI 总线和 GPIO 编号两版完全不同，上游驱动是按 2.16 开发的（reset=99 / IRQ=175 / 12 MHz）|
| GPU | **Adreno 690** —— mesa freedreno + turnip，主线支持成熟 |
| 屏幕 | **Himax HX83121A / ppc357db11 WQXGA**，MIPI-DSI。**与三星 Galaxy Tab S7 FE 同款面板** |
| WiFi/BT | WCN6855 —— ath11k + hci_qca，主线驱动 |
| EC | 华为自研，主线驱动 6.15 进；UCSI 6.16；**DSI 面板 7.1 进** |
| 存储 | NVMe（**不是 UFS**，不是手机那套分区布局） |
| 引导 | **UEFI，不是 fastboot**。可关 Secure Boot。GRUB/systemd-boot 加载 |
| 虚拟化 | KVM/EL2 可用 |
| 已知不支持 | 指纹（FocalTech FTE7001）、TPM。休眠是**未测试**，不是不支持 |

## 关键约束（每次都要记住）

- **没有高通 Android BSP。** 8cx 系列从来只发 Windows/Linux 驱动。
  不存在可扒的 vendor blob，所有 HAL 必须基于主线内核自建。
  → 路线只能是 **AOSP on mainline**，参考 aospm 项目。

- **不是 fastboot 设备。** 所有假设 `fastboot flash` / `by-name` 软链接 /
  A/B 槽位的 AOSP 常规流程都要改写。
  ⚠️ **fstab 用 PARTUUID，不能用 PARTLABEL** —— 实测内置盘上 Windows 建的分区
  PARTLABEL 全都是 `Basic data partition`，不唯一。见 `docs/hw-inventory.md` 第 8 节。

- **没有暴露的串口。** 早期启动失败 = 纯黑屏零信息，adb 要等 init 起来才有。
  → ✅ **已解决，走 `efi_pstore`（EFI 变量），不是 ramoops。**
  **ramoops 在这台机器上不可能工作** —— 固件每次复位都重新初始化 DRAM，
  低位 `0xae900000` 和高位 `0x865d38000` 都实测过，内容一律不存活。
  崩溃日志现在会自动落到 `/var/lib/systemd/pstore/`。
  详见 `docs/hw-inventory.md` 第 7bis 节，工具 `scripts/pstore-ctl.sh`。

- **无 modem。** aospm 的 libqril/qrild/qrtr 那一套全部跳过。

- **arm64 原生。** 手游 arm64-v8a 包直接跑，不需要任何转译层。

## 环境

- **编译机：Dell G15（x86_64 Linux）** —— AOSP 编译需要 ~16GB+ RAM、250–400GB 磁盘。
  不要在 Ego 上编译 AOSP。
- **目标机 A：** 保持可用状态（Windows 或稳定 Linux），作为参照和日常用
- **目标机 B：** 随便刷的实验机
- 两台机器的意义：A 永远能开机，用来对比"正常应该是什么样"

---

## 本地参考树（clone 到 `refs/` 下，供 AI 直接读源码）

```
refs/linux-gaokun/           github.com/right-0903/linux-gaokun          本机内核核心
refs/matebook-e-go-linux/    github.com/whitelewi1-ctrl/matebook-e-go-linux   GK-W7X patch + GRUB 配置
refs/boot-works/             github.com/matalama80td3l/matebook-e-go-boot-works  面板驱动
refs/jhovold-linux/          github.com/jhovold/linux (wip/sc8280xp-6.16)  ⚠️ 已停更，仅作历史对照
refs/gaokun-buildbot/        github.com/KawaiiHachimi/linux-gaokun-buildbot  ⭐ 现役内核基线
refs/egotouchrev-linux/      github.com/chiyuki0325/EGoTouchRev-Linux    触摸 SPI 驱动
refs/aospm-device-sdm845/    github.com/aospm/android_device_generic_sdm845    ⭐ 设备树模板
refs/aospm-manifests/        github.com/aospm/android_local_manifests
refs/aospm-system-core/      github.com/aospm/platform_system_core       看 diff 知道要改什么
refs/aospm-tinyhal/          github.com/aospm/tinyhal                    音频 HAL
```

> ⚠️ **jhovold 树已不是基线。** 它停在 6.16（2025-09 最后推送），
> 缺 HX83121A 面板驱动（7.1 才进主线）。现役基线是
> **mainline v7.2-rc2 + `refs/gaokun-buildbot/patches/` 20 个补丁**。

固件来源：`matebook-e-go/uup-drivers-sc8280xp`（Windows 驱动扒 blob）+
linux-firmware ≥ **20241210**

**Stage 2 打 vendor 分区要抓的固件（实测 dmesg 加载路径）：**

```
qcom/a660_sqe.fw          qcom/a660_gmu.bin              GPU (Adreno 690)
qca/wcnhpbtfw21.tlv       qca/wcnhpnv21g.bin             蓝牙 WCN6855
qcom/sc8280xp/HUAWEI/gaokun3/qcadsp8280.mbn              ADSP
qcom/sc8280xp/HUAWEI/gaokun3/qccdsp8280.mbn              CDSP
qcom/sc8280xp/HUAWEI/gaokun3/qcslpi8280.mbn              SLPI
```

华为专有路径下那三个 `.mbn` 不在 linux-firmware 里，必须自己带。

---

## 阶段计划与验收

| 阶段 | 内容 | 验收标准 |
|---|---|---|
| **0** ✅ | 主线 Linux 跑通 + 配好崩溃日志 + 采集素材 | 全部通过（pstore 走 efi_pstore） |
| **1** ✅ | 内核转 Android 配置 | 全部通过（UDC 出现，主机端 `configured` 枚举）|
| **2** ✅ | 引导链 + AOSP 启动 | **全部通过**（2026-08-17）：adb shell 通，keystore2/zygote/adbd 稳定运行。12 个问题的完整记录见 `docs/stage2-findings.md` |
| **3** ✅ | 图形栈（minigbm + drm_hwcomposer + swangle） | **全部通过**（2026-08-17）：桌面完整渲染。freedreno 留待 Phase B |
| **4** | 输入 / 音频 / WiFi / 电源 | 触摸可用、有声音、能联网 |
| **5** | 游戏适配 | 目标游戏能启动并稳定运行 |

**Stage 0 必须采集并记录在 `docs/hw-inventory.md` 的东西：**
- `.config` 中所有 QCOM / ath11k / hid 相关项
- `dmesg | grep -i firmware` 的完整固件加载路径
- **ALSA UCM2 配置文件**（Stage 4 要翻译成 mixer_paths.xml）
- `modetest` 完整输出：connector 名、plane 数量、**支持的 format 和 modifier**
  （Stage 3 配 minigbm 的关键依据）
- 触摸屏 / 键盘 / 触控板的 evdev 名和 evtest 输出
- 触摸屏走 SPI 还是 I2C

---

## 已知坑

- 触摸屏 I2C 模式有间歇性失灵，SPI 模式更稳
- **触摸 IC 的工作模式由 gpio174 在固件重载瞬间的电平决定**（低=SPI 高=I2C HID），
  上游两棵 DTS 都没配这个脚，全靠 UEFI 遗留电平碰运气；显示复位还会静默触发
  固件重载。症状是"触摸随机死亡/幽灵触点风暴/驱动探测成功但全聋"。
  修复=pinctrl 恒拉低，见 `patches/0002-*.patch` + `docs/stage4-findings.md` #26。
  空闲 IRQ 速率是状态指纹：≈显示扫描率=正常；0=IC 停摆；乱=模式错乱。
- **`timeout N getevent > 文件` 会因块缓冲丢光全部输出**——采集 evdev 要用
  `cat /dev/input/eventX` 录二进制再离线解码。见 `docs/stage4-findings.md` #26 方法论。
- EC 挂起/恢复：Android 的 suspend 模型比 Linux 激进，预期这里会先炸
- ~~DSI panel 的 KMS plane 数量少时 drm_hwcomposer 会 fallback 到 GPU 合成~~
  ✅ **担心不成立。** 实测 **25 个 plane / 6 个 CRTC**，硬件合成资源充裕。
  modifier 只有 `LINEAR` 和 `QCOM_COMPRESSED`(UBWC, `0x500000000000001`)，
  支持 UBWC 的 format 见 `docs/hw-inventory.md` 第 3 节 —— 那就是 minigbm 的配置依据。

- **UCSI 有缺陷**（`refs/linux-gaokun/README.MD:86-87`），常见
  `error -ETIMEDOUT: PPM init failed`，此时 `/sys/class/typec/` 为空。
  ✅ 但**不影响 adb**：`dr_mode = "otg"` 无 role 源时落到 device 侧，
  USB 数据通路不经 UCSI。代价是只有 high-speed，SuperSpeed 需要 UCSI 切 orientation。

- **DT label 编号与物理地址不对应**：`usb_0` 是 `a6f8800`，`usb_1` 才是 `a8f8800`。
  改 dwc3 前务必 `readlink -f /sys/block/sda` 确认启动介质在哪个控制器上。

- **`super.img` 是 Android sparse 格式，不能 `dd`** —— 必须 `simg2img` 展开。
  头部魔数 `0xED26FF3A` 是 sparse 标志，**不是** LP metadata。误 dd 会让 init
  读不到元数据、挂载失败后主动复位，且不留任何日志。见 `docs/stage2-findings.md` 第 1 节。

- **`CONFIG_SECURITY_SELINUX=y` 不等于 SELinux 已启用** —— 还必须出现在
  `CONFIG_LSM` 字符串里。buildbot 默认值只有 apparmor，导致 selinuxfs 从不注册、
  Android init 静默死亡。**只看 config 会误判，必须查 `/sys/kernel/security/lsm`。**

- **Android init 失败时是主动 `reboot()`，不是 panic** —— 所以 pstore 抓不到。
  抓日志要靠改造 ramdisk 写内置盘 ESP，方法见 `docs/stage2-findings.md` 第 5 节。
  `androidboot.init_fatal_panic=true` 可以把 LOG(FATAL) 类失败转成真 panic 走 pstore，
  但服务级失败（`reboot_on_failure`）仍是正常 shutdown，两条通路都要布。
- **cgroup v1 在 6.12+ 拆到 `*_V1` 选项后面且默认关** —— `CONFIG_CPUSETS=y` 只给 v2。
  Android 的 cgroups.json 要求 cpuset 走 v1，缺 `CONFIG_CPUSETS_V1` 时
  `SetupCgroups` 失败 → 所有服务起不来 → `bootstrap-apexd-failed` 复位。
  一并要 `MEMCG_V1` / `UCLAMP_TASK(_GROUP)`（task_profiles.json 引用）。
  见 `docs/stage2-findings.md` 第 8 节。
- 游戏多走 GLES，freedreno GL 路径和 zink-over-turnip 都试，先通再选

## 捷径备忘

- **面板与 Galaxy Tab S7 FE（gts7fe / SM-T733）同款** → DPI、时序、背光曲线
  可直接参考 Tab S7 FE 的 AOSP 设备树
- Stage 3 卡死时的止损方案：Cuttlefish（`cvd start --gpu_mode=gfxstream`），
  KVM 可用，是真 Android VM 不是容器

## 协作

- gaokun 社区（Linux 侧）：面板、EC、休眠、触摸的问题问他们
- aospm 社区（Android-on-mainline 侧）：HAL、设备树组织方式问他们
- ~~这两个圈子此前没有交集，本项目是第一个连接点~~
  **已有平行项目**：LineageOS 系 mainline-generic 正在做 gaokun3 live-ISO
  （同款 buildbot 内核），双方结论交叉验证一致。他们的 config fragment
  和模块清单是我们 Stage 3/4 的路线图，见 `docs/parallel-mainline-generic.md`。
