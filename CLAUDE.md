# 项目：MateBook E Go (sc8280xp / gaokun) 移植 Android

## 目标

在华为 MateBook E Go（Snapdragon 8cx Gen 3 / sc8280xp，代号 gaokun）上跑原生 AOSP，
最终目标是能稳定运行 arm64 手游。

**当前阶段：Stage 6 M5 完成 — ★修复已固化进镜像；原神/明日方舟可玩；Windows 已抹除，/data 370G，救援系统全内置**（每次开工时更新这一行）

> **★★ Stage 6 M5（2026-08-20）：M4 的成果全部固化进镜像 + 传感器判死。**
>
> ★**用户实测：原神画质开到极高流畅可玩。** GPU 91% 时间待在最低档 270 MHz、
> 峰值 690 MHz、最高温 50 °C、零降频、`GMU 错误 0 / a6xx_recover 0 / SMMU fault 0`。
> 余量非常大。**唯一遗憾是清晰度**：渲染缓冲被钉在 1080×1728，这是原神按
> **设备白名单**给的档位，不是我们的技术限制（实测把逻辑分辨率改小，缓冲不变
> → 绝对上限而非比例）。要突破只能伪装机型，**有账号风险，留给用户决定，未做**。
>
> ★**新 super 已构建、刷入、验收通过**
> （sha256 `131c7f67…`，`ro.build.date = Aug 19 20:26:05 UTC`）。
> M4 那 4 个"只活在 overlay 里"的修复现在真在镜像里了：
> `display_settings.xml`（横屏）、`thermal-guard.sh` + `thermalguard.rc`（CPU 温控）、
> 删掉 MMAP 的音频策略。**验收判据是「overlay 里 0 个文件」** ——
> 刷 super 会连带抹掉 scratch，所以 overlay 空了还一切正常，就证明东西在镜像里。
> 只刷了 super：产物 ramdisk 与 ESP 上那份 sha256 完全相同，内核也没重编。
> - 流程：**先比两棵设备树的 md5 清单再传**。这次差异正好是预测的 3 缺 2 改，
>   且**"VM 上没有本地缺失的文件"**——确认了这条才敢整树覆盖，
>   否则不入库的华为固件会被 tar 抹掉，而且要到下次刷机声卡不注册才发现。
> - ⚠️ 两个会误报的核对坑：`grep -c mmap_no_irq_out` 得 1（那是**注释**，
>   判据要写 `grep -c 'name="mmap_no_irq_out"'`）；**`debugfs` 读得了
>   `vendor.img` 却读不了 `system.img`**（shared-blocks 去重），
>   `tinymix` 就是这样被我误报成缺失的 —— 它本来就该在 `/system/bin`。
> - **拆掉两颗地雷**：`deploy-from-ubuntu.sh` 的 `flash_boot` 一直往
>   `$ESP/Image` / `ramdisk.img` 写（**旧 AOSP 条目**的文件名），而
>   `crdroid.conf` 读的是 `Image-kb23` / `ramdisk-crdroid.img`
>   —— 跑 `all` 会"更新成功"却毫无作用，是 M3 那个坑的翻版；已改成从 BLS
>   条目里解析实际路径。另一颗是 `bootctl set-oneshot` 失败时静默，已改成炸出来。
>   > 附带查明：**`efi=noruntime` 不妨碍 `bootctl`**，oneshot 实测可写可回读，
>   > 远程救援闭环是可靠的。
>
> ★**传感器：不是缺 DTS 节点，是整套跑在 SLPI DSP 上 —— 主线此路不通。**
> 从本机 Windows 分区读出驱动库：没有任何 AP 侧传感器芯片驱动，只有
> `qcsensors.inf` + `qcsensorsconfigqrd8280`（里面是 `sns_*` 的 SEE 模块配置
> 和 **`libsdsprpc.dll` = Sensor DSP RPC**）。器件是 `sh3001`(IMU)、
> `tcs3701`(ams 光感+接近, I2C 0x39)、`sy3133cs`、`t1000`、`stm_lid_angle`(铰链角)，
> **全挂在 SLPI 自己的总线上，AP 够不着**。
> → **自动旋转、自动亮度在主线上做不了**（要有人写 SEE 的 QMI/FastRPC 客户端，
> 至今没有任何 sc8280xp 设备做到，X13s 也没有）。★**游戏不受影响。**
> 工具 `scripts/probe-windows-sensors.sh`，完整证据 `docs/stage4-findings.md` #37。
>
> ★★**Windows 已抹除，整机归 Android；U 盘不再是必需品**（2026-08-20，用户授权
> "数据都备份了，直接不要"）。
> - **引导链已搬进内置 ESP**（`scripts/esp-migrate-to-internal.sh`，纯增量）。
>   **拔盘实测通过**：`/dev/block/sd*` 不存在，Android 照常启动。
> - **删除 Windows 的 p2/p3/p4/p5/p6/p7**。现在盘上只有：
>   p1 ESP 300M / **p2 userdata 376G** / p8 super 12G /
>   p9 `userdata-old` 64G（迁移前备份，暂留）/ p10 metadata 32M /
>   **p3 Ubuntu 救援 24.6G**。未分配 1007 KiB。
> - ★**`/data` 62 GiB → 370 GiB（可用 294 GiB）**。此前它**已经 100% 满**
>   （原神 34G + 明日方舟 19G，非 root 只剩 235 MiB，装不下任何东西）。
>   做法是**新建 + `dd` 整盘克隆 + `resize2fs` + 换 PARTLABEL**，不是原地扩容：
>   `dd` 逐字节复制，SELinux 扩展属性/capabilities/硬链接零解释带过去；
>   `fstab.gaokun3` 用的是 `by-name/userdata`（**PARTLABEL**）所以改标签即可，
>   fstab 一字未动；**旧 p9 全程只读并保留**，出问题重启就是原来那台机器。
>   校验：文件数 49999=49999、字节数 63 237 600 073 相同、大文件 md5 抽查 3/3。
> - **Ubuntu 救援系统已搬进内置盘**（`rsync -aHAXx` 克隆活动根，134403 个文件），
>   hostname `gaokun3-rescue`、root=`nvme0n1p3`、ssh 仍是 192.168.31.230。
> - ⚠️★**固件的启动优先级会变，别当成一次测定的事实**：装引导链时
>   `LoaderDevicePartUUID` = `d5cb76b5…`（U 盘）；**删掉 Windows 分区之后变成
>   `825eaf3a…`（内置盘）**。于是"内置 ESP 只在 U 盘不在时才用到"当场失效，
>   而它的默认项当时是 Android → **自动回落安全网悄悄断了**，
>   症状只是"莫名其妙进了 Android"。动过分区表就要重读这个变量确认。
> - **现役闭环（两个方向都实测通过）**：默认 → 内置救援 Ubuntu；
>   `sudo bootctl set-oneshot <mid>-int-crdroid.conf` → Android；
>   Android 里 `adb reboot` → 自动回落救援系统。
>   ⚠️ 条目名带 **`int-`** 前缀，U 盘那套旧名（`<mid>-crdroid.conf`）已非现役。
>
> **★★ Stage 6 M4（2026-08-19 夜）：s2idle 定性 + 音频解锁。**
>
> ★**"不能待机"的判决：挂起成功、resume 失败、然后整机被复位 —— 而且在
> Ubuntu 里用同一棵内核复现得一模一样。** 所以与 Android、与 SystemSuspend、
> 与我们的设备树**全都无关**，是内核/EC 层面的缺陷，根治属上游活。
> 证据：Ubuntu 侧 `echo mem > /sys/power/state` 后日志停在那一行，
> 紧随的 "resume 成功" 标记从未写出，机器回来后 `uptime` 是全新启动。
> RTC 闹钟**确实按时触发**，约 13 秒后才重启 → **坏在 resume，不在 suspend**。
> - **三个元凶已排除**（各自卸掉再挂起，照样醒不来）：himax 触摸驱动、
>   三个 remoteproc（ADSP/CDSP/SLPI）、★**EC 驱动本身**
>   —— 最后这条**推翻了 CLAUDE.md 从 Stage 3 起的预言**（"EC 挂起/恢复会先炸"）。
> - 那两个"本该修好它"的补丁**其实一直都在**（buildbot 无条件 `git am`
>   `patches/upstream/*` 与 `patches/others/*`）：`upstream/0012`
>   （EC 的 PM 回调 NOIRQ→SYSTEM_SLEEP，自述就是修 "resume fail silently"）、
>   `others/0017`（EC 加 `device_init_wakeup`）。都在，照样挂 → **别再指望它们**。
> - **没法继续二分**：内核没开 `CONFIG_PM_DEBUG`，`/sys/power/pm_test` 不存在
>   （两侧都没有）；挂起瞬间的日志也拿不到（userspace 已冻结，journald 来不及落盘；
>   clean hang 不产生 panic，efi_pstore 抓不到）。→ 真要修，第一步是编个带
>   `CONFIG_PM_DEBUG` 的内核。
> - **落地取舍**：wakelock **保留**（这是正确的工程决定，不是偷懒），
>   加一条逃生口 `persist.gaokun3.allow_suspend=1` 供将来复测；
>   但把 `svc power stayon true` 与 `screen_off_timeout=INT_MAX` **删掉** ——
>   持 wakelock 时息屏是安全的。**于是本机的"待机" = 息屏但机器不真睡。**
> - ⚠️**会浪费两小时的陷阱**：持有 wakelock 时读 `/sys/power/wakeup_count`
>   会**永久阻塞**（实测 cat 挂死 120s）。Android 的 SystemSuspend 就卡在这一读上，
>   这也解释了 `suspend_stats/success` 恒为 0。别在探测脚本里 cat 它。
>
> ★**远程救援闭环本轮实战验证成功**：Android 挂死 → 自动复位 → 默认启动项
> Ubuntu → ssh 进去 → `bootctl set-oneshot ...crdroid.conf` → 回 Android。
> **全程不需要有人在机器边。**"默认启动项永远留 Ubuntu"这条纪律兑现了价值。
>
> **音频**：`tinymix` 首次真的编进来了（M3 只是排了队）。硬件路径**实测通**：
> 291 个混音器控件、路由回读正确（`>AIF1_PB`/`>RX0`/DAC on/BOOST off/PA=12）、
> `tinyplay` 让 `/proc/asound/card0/pcm1p/sub0/status` 变成 **`state: RUNNING`**
> 且 DMA 实时消耗。★**2026-08-20 用户实机确认：音频可用（听到声音）**。
> 框架路径于此确证 —— 此前 `Total writes: 0` 只是因为这个 ROM 里没有任何应用
> 能处理音频、我试过的每种无头触发都没能让 AudioTrack 起来，属"未测"而非"坏"。
> ⚠️ `tinymix` 动态链接 `libtinyalsa.so`，放 `/vendor/bin/` 时那个 .so
> 必须一起进 `/vendor/lib64/`（vendor 命名空间搜不到 system 的那份）。
>
> **蓝牙：撤销 #30**。实测 `state: ON`、地址读出、`crashed 0 times`。
> `android-post-flash.sh` 里的禁用两行已删（留着会在每次重刷 userdata 后
> 把好的蓝牙重新关掉）。
>
> **搁置并说明理由**：传感器（★M5 已查明**不是缺 DTS 节点，是整套跑在 SLPI
> DSP 上、AP 无总线可达** → 主线此路不通，见 #37；连带没有自动旋转与自动亮度，
> 但**游戏不受影响**）、
> Venus 硬解、UCSI、SELinux 转 enforcing。
> ⚠️**记一条将来的地雷**：热管理 HAL 是 AOSP mock，它报的 skin/battery
> **SHUTDOWN 阈值只有 36.0 °C**，而 `ThermalManagerService.shutdownIfNeeded()`
> 到 SHUTDOWN 会直接 `powerManager.shutdown()`。现在因 mock 值恒定打不到，
> **将来换成读 `/sys/class/thermal` 的真 HAL 时必须同时改阈值**，
> 否则开机几分钟就自动关机。
> 详见 `docs/stage6-crdroid.md` 的 M4 段。

> **★★ Stage 6 M3 已于 2026-08-19 完成：Android 跑在 Adreno 690 硬件 Vulkan 上。**
> `Turnip Adreno (TM) 690`、`boot_completed` t+48s、锁屏/桌面渲染正常
> （3.83 MB screencap 逐像素对）；22 分钟带负载浸泡：**GMU 错误 0 /
> a6xx_recover 0 / SMMU fault 0**，桌面四进程 PID 全程不变。
> 一键复验 `bash scripts/verify-turnip.sh`，案卷 `docs/stage6-crdroid.md`。
>
> 做法是**把 Stage 5 的补丁树整棵铺回来**，不是重跑生成管线；
> 另外首次把 `smmu-nostall.sh`（GPU SMMU stall 解锁器，常驻安全网）
> 写进了构建配置。
>
> **M3 顺带推翻了三条旧结论（都写进了案卷）**：
> 1. ★"crDroid 与我们的 mesa 是同一个 commit" —— **假阳性**。
>    `git log -1` 比的是 `.git` 的 HEAD，而 mesa 26 当年是**铺在工作树上
>    从未提交**的，所以两棵树必然显示同一个 commit。实际是
>    25.3.0-devel vs **26.0.3**，`git diff` 3791 个文件。
>    判"两棵源码树是否相同"，`git status --porcelain | wc -l` 才是那一句。
> 2. ★"s2idle 的 **wakelock 挡不住**" —— 挡是一直挡住了（⚠ 别把这条读成 "s2idle 是好的"；M4 已证明 **resume 确实坏**）。`/sys/power/wake_lock` 是
>    `radio:wakelock` 0660，shell 连读都读不了，我把 `cat` 的
>    "Permission denied" 当成了"内容为空"。实测 26 分钟 `suspend entry` = 0。
> 3. ★"`adb root` 不生效" —— **两步可解**：
>    `adb shell setprop service.adb.root 1` 然后 `adb root`
>    （permissive 下 shell 能写这个属性，而 adbd 自己那一步没生效）。
>    顺带查明 `ro.build.type` 是 **user** 而非 userdebug。
>    ★ 这把钥匙的真正价值是**远程救砖**：拿到 root 就能挂 U 盘 ESP
>    （`/dev/block/sda1`，**不是**内置盘 `nvme0n1p1`）直接改 `loader.conf`。
>
> **M3 最费时间的坑**：刷完 super 后 oneshot 到了 `android.conf`，
> 那是**旧 AOSP 的 Image(kb18)+ramdisk**，crDroid 要用 `crdroid.conf`
> （`Image-kb23`）。用错内核 → 没有 `patches/0007` → bpffs 标签崩溃循环，
> 症状一路指向刚换的 turnip 而其实毫无关系。
> **判据：`adb shell uname -a` 的编译时间必须与本次内核一致。**
> `scripts/deploy-from-ubuntu.sh` 已改成设 oneshot 到 `crdroid.conf`，
> 且不再篡改默认启动项（默认必须留 Ubuntu，那是唯一的自动回落安全网）。
>
> **M4 起点（已实测）**：触摸设备在（`Himax Capacitive TouchScreen`）、
> 声卡注册、解码器 66、蓝牙 HAL 装着但被 `android-post-flash.sh` 禁着；
> ⚠️ **音频当前是断的** —— `tinymix` 从没进过 `PRODUCT_PACKAGES`
> （`audio-route.sh` 找不到它就直接放弃），已补进 device.mk 待下次构建；
> ⚠️ **WiFi 硬件全通但网络被框架永久禁用**
> （`NETWORK_SELECTION_DISABLED_NO_INTERNET_PERMANENT`，stage4 #29 复发），
> 解禁需要一次带密码的用户发起连接。

> **★★ Stage 6 M2 已于 2026-08-19 完成：crDroid 16.0 完整启动进桌面。**
> `sys.boot_completed=1`（t+40s），surfaceflinger/system_server/systemui/launcher3
> 全部在跑；**解码器 66 个**（含 mp3/aac/flac/amrnb/amrwb/g711）；
> 铃声 130 + 通知音 92 + 闹铃 45 + UI 音效 25。执行案卷 `docs/stage6-crdroid.md`。
>
> **四个真凶（都不是配置写错，是真实的不兼容）**：
> 1. ★**`media.c2.hal.selection` 默认是 `hidl`** —— 这就是追了两个阶段的
>    "解码器一个都没有"（#36）。HIDL Codec2 在 Android 15+ 已不可用
>    （hwservicemanager 被移除）。**与 crDroid 无关，AOSP 16 上同样如此**，
>    只是真机设备树都会设它。必须走 `PRODUCT_SYSTEM_EXT_PROPERTIES`
>    （该属性上下文 `codec2_config_prop`，vendor 无权设）。
> 2. ★**bpffs 的 SELinux 标签**（`patches/0007` 内核补丁）——
>    主线 bpffs 在 inode 创建时急切赋标签，Android 依赖的 genfscon
>    惰性路径匹配失效 → ClatCoordinator 逐字比对标签失败 → system_server
>    崩溃循环。用户态无法修（`chcon` 报 ENOTSUP，因为策略对 bpf 用 genfscon
>    而非 `fs_use_xattr`）。**这个坑对任何"Android on 新主线内核"都成立。**
> 3. ★**crDroid 的 `SetSafetyNetProps()`**（`property_service.cpp:1168`）
>    在解析 cmdline 之前硬写一整张表，把 `ro.debuggable`/`ro.adb.secure`/
>    `verifiedbootstate`/`flash.locked` 全部盖成"已锁定已验证 user 版"。
>    这让 `WITH_ADB_INSECURE`、`PRODUCT_SYSTEM_EXT_PROPERTIES`、cmdline
>    三条路改了都没用，极具迷惑性。开关 `SPOOF_SAFETYNET` 只在 eng 变体关，
>    故用 `scripts/crdroid-tree-fixes.py` 改默认值（eng 会关 dexpreopt，不可取）。
> 4. **AOSP 基座必须由设备树自己 inherit**（`full_base.mk`）——
>    `vendor/lineage/` 下全是补充配置。少了它构建"成功"但产出空壳
>    （`system.img` 29.8 MB、无 apex/app/services.jar）——**比构建失败更危险**。
>
> **已补上（M3 复核）**：s2idle 休眠其实一直是好的 —— init 的
> `write /sys/power/wake_lock` 从第一次就成功了，我把 `cat` 的
> "Permission denied"（节点是 `radio:wakelock` 0660，shell 读不了）
> 当成了"内容为空"。实测 uptime 21 分钟时 `suspend entry` 计数 **0**
> （修之前 45–60 秒必挂且醒不来）。
>
> **还欠的**：见首屏 M3 段的「M4 起点」——音频（tinymix 漏装，已补待构建）、
> WiFi（网络被框架永久禁用，解禁要密码）、蓝牙（装着但禁用中）。

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
>   - ★**解码器缺口的最终结论（已解决）**：不是 `media_codecs.xml` 缺失，
>     也不是"servicemanager 的 declared 集"问题（这两个归因都被推翻了）。
>     真凶是 **`media.c2.hal.selection` 默认为 `hidl`**
>     （`frameworks/av/media/codec2/hal/common/HalSelection.cpp:57`），
>     而 HIDL Codec2 在 Android 15+ 已随 hwservicemanager 一起消失。
>     设成 `aidl` 后解码器从 0 → 66。详见首屏的 M2 段与 `docs/stage6-crdroid.md`。
>   - ★**mesa 管线一个都不能丢**：lineage-23.2 的 `external/mesa3d` 就是 AOSP 那份，
>     `BOARD_MESA3D_*` 是平行项目自带 mesa 仓库的机制，不是 Lineage 的
>     （作废 `docs/stage5-freedreno.md:212` 的猜测）。
>     ⚠️⚠️ **"两边是同一个 commit"这条结论是错的，2026-08-19 M3 当场推翻**：
>     `git log -1` 在两棵树上都给 `d4b6f1eba289…`，但那是 **`.git` 的 HEAD**，
>     而 Stage 5 的 mesa 是**直接铺在工作树上、从未提交**的上游 mesa
>     —— 于是这个对比必然给出假阳性。逐字节比才看得见真相：
>     crDroid 树内 = **mesa 25.3.0-devel**，Stage 5 补丁树 = **mesa 26.0.3**，
>     `git diff` 3791 个文件 / 36.5 万行，是真实的上游版本差
>     （`gl_shader_stage`→`mesa_shader_stage` 这类重命名、新增文件都在）。
>     ⚠️ 连带作废：早先那句"'mesa 26' 是被本地改过的 VERSION 文件误导"也是错的。
>     **正解 = 铺回归档树** `~/keep/mesa3d-patched.tar.zst`（M3 已这么做）：
>     它就是实测 SMMU fault=0 的那棵，patches/0004 v3 全在里面。
>     退路：`git checkout . && git clean -fd` 一句话回到 crDroid 原版 25.3。
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
| 已知不支持 | 指纹（FocalTech FTE7001）、TPM。**s2idle 已实测：挂得下去、醒不回来、约 20–40s 后整机复位；Ubuntu 同样复现 → 内核/EC 缺陷**（M4 定性）。深度休眠(S4)仍未测 |

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
