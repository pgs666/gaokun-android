# Stage 4 实测问题记录（输入 / 音频 / WiFi / 电源）

> 编号接续 `stage2-findings.md`（#1–#25 见彼处，含 Stage 3 冲刺）。
> 本文档记录 Stage 4 的实测问题、根因与修复。

---

## #26 触摸屏"随机"死亡 / 幽灵触摸 —— gpio174 模式选择脚无人驱动 ✅ 已修复

**现象（按时间线）**
1. kb17 首启：触摸可用但有幻影触点（单指出现多 slot 散点）
2. 60Hz 显示模式实验后：触摸彻底静默，evdev 零输出
3. 冷断电重启后：空闲幽灵触点风暴（不碰屏每秒冒随机按下事件，
   一次出现 6 个"手指"挤在 X≈877–1001 的窄带、Y 散布全屏），
   真手指画线反而完全不上报
4. 驱动重挂（unbind/bind）、`inplace_reset`、降 `peak_threshold` 至 400 都无效
5. **跨内核持久**：Ubuntu 7.1.0-rc3（buildbot 原装内核 + 树内
   himax_hx83121a_spi.ko）同样零输出——排除 Android 用户态、
   排除我们的 7.2 内核构建差异
6. Windows / BIOS 界面触摸始终正常

**根因**
`refs/linux-gaokun/README.MD` "Touchscreen / insights" 节：HX83121A
级联 IC 在**触摸固件重载瞬间采样 gpio174** 决定宿主传输模式——
低=SPI 原始数据模式（Linux 驱动要的），高=I2C HID 模式（UEFI/BIOS
用的）。固件重载会在 TS 复位（gpio99）后自动触发，而**显示复位
（gpio38）可能在驱动不知情时内部触发 TS 复位**。

buildbot 和 linux-gaokun 两棵树的 DTS 都只配置了 gpio175（IRQ）和
gpio99（复位），**gpio174 无人驱动**，电平全看 UEFI 退出时的遗留状态。
UEFI 自己用 I2C 模式，所以经常遗留高电平 → IC 锁进 I2C HID 模式 →
SPI 侧"探测成功但全聋"。KMS 模式切换（我们的 60Hz 实验）触发显示
复位 → 固件静默重载 → 模式翻转，营造出"随机死亡"的假象。

**修复**
DTS `ts0_default` pinctrl 加一组：

```dts
mode-pins {
    pins = "gpio174";
    function = "gpio";
    output-low;
};
```

见 `patches/0002-arm64-dts-gaokun3-drive-ts-mode-gpio174-low.patch`。
pinctrl default 状态在 himax-spi probe 时施加（先于驱动发起的复位→
固件重载），且此后恒为低——任何后续面板复位引发的重载都落在 SPI 模式。

**验证**
- Ubuntu 活体实验：`gpioset --chip gpiochip4 --hold-period 20s 174=0`
  期间重挂驱动 → 触摸完美（"非常跟手"）
- Android：直接改 ESP 上的 DTB（dtc 反编译→插节点→回编译，备份为
  `sc8280xp-huawei-gaokun3.dtb.bak-pre174`）→ "触摸非常丝滑"

**遗留事项**
- [x] ~~下次开构建机时把补丁应用进 VM 内核树~~ ✅ 2026-08-17 已进
  kb18（从源码编出的 DTB 与手术版 sha1 完全一致，零漂移）
- [ ] Ubuntu 7.1/7.2 启动项各自引用的 DTB 还没打补丁（在 Android 下
  无法挂 ESP 改，USB_STORAGE=m；下次进 Ubuntu 时用
  `/home/user/gk3-gpio174.dts.txt` 同法处理）
- [ ] 向 gaokun 社区（right-0903 / buildbot / mainline-generic live-ISO）
  报告：他们的 DTS 同样缺 gpio174，live-ISO 用户会随机踩坑

**诊断方法论沉淀**
- IC 空闲 IRQ 速率是状态指纹：**≈显示扫描率（120Hz 面板 ≈117/s）=
  SPI 原始模式正常流**；0/s = IC 停摆；与扫描率无关的风暴 + evdev
  静默 = 模式错乱
- 幽灵触点"整列电极同亮"（多 slot 同 X 窄带、Y 全屏散布）不一定是
  充电噪声——本例拔线后依旧，是模式错乱下的乱码帧
- **`timeout N getevent > file` 会因 stdio 块缓冲丢光输出**（SIGTERM
  不冲刷）；采集 evdev 用 `timeout N cat /dev/input/eventX > file` 录
  二进制流再离线解码（24 字节/事件：u64 sec, u64 usec, u16 type,
  u16 code, s32 value）

## #28 ath11k 内置驱动的固件竞速 + hw2.1 目录映射 ✅ 已修复

**现象**：kb18 后 PCI 域 0006 枚举成功（PWRSEQ 修复生效），但 ath11k
probe 报 `Direct firmware load for ath11k/WCN6855/hw2.1/amss.bin failed
with error -2` → `-110` 永久失败，无 wlan0。

**三层根因**
1. **芯片是 wcn6855 hw2.1 不是 hw2.0**（dmesg `wcn6855 hw2.1`；
   `ath11k/core.c` 的 hw_params 表把 hw2.1 硬映射到 `WCN6855/hw2.1` 目录）
2. **上游 linux-firmware 没有 hw2.1 实体文件**——WHENCE 里是
   `Link: ath11k/WCN6855/hw2.1/*.bin -> ../hw2.0/*.bin`，cgit 拉单文件 404。
   vendor 分区不做软链，把 hw2.0 文件在 hw2.1 路径再装一份即可
3. **内置(=y)驱动开机 ~5s 就 probe，/vendor 还没挂载**，request_firmware
   直接 -2，probe 失败后无人重试（msm GPU 能活是因为它懒加载固件，
   surfaceflinger 打开设备时 vendor 已在；ath11k 没这种运气）

**修复**
- device.mk：hw2.0 四件套同时装到 hw2.1 路径
- init.gaokun3.rc：`on post-fs-data`（vendor 已挂载）时
  `write /sys/bus/pci/drivers/ath11k_pci/bind "0006:01:00.0"` 手动补绑定

**教训**：内置驱动 + vendor 固件 = 天然竞速。任何要固件的 =y 驱动都要
检查它的固件加载时机（probe 时 vs 首次打开时），probe 时加载的一律需要
晚绑定兜底。蓝牙 hci_qca 同样在 4.6s 吃了 -2（待 BT 阶段一并处理）。

## #29 WiFi 用户态四连坑（HAL 空壳 / FW_PATH 毒药 / supplicant 配置 / 国内验证墙）✅ 已修复

kb18 内核就绪后（#26/#28），用户态又连过四关，全记录：

1. **libwifi-hal 空壳**：不设 `BOARD_WLAN_DEVICE` 时链接 fallback 实现，
   HAL `start()` 直接 Status 9。mainline nl80211 设备用
   `BOARD_WLAN_DEVICE := emulator`（goldfish 实现，CF 同款），并且
   **必须** `PRODUCT_SOONG_NAMESPACES += device/generic/goldfish`。
2. **`WIFI_DRIVER_FW_PATH_STA := ""` 是毒药**：空串被字面编译进
   libwifi-hal，configureChip 走 Broadcom 式固件模式切换 →
   `Failed to change firmware mode` → chip 配置失败。这些变量
   **完全不要定义**。
3. **supplicant 缺配置文件**：AIDL `addStaInterface` 硬要求
   `/data/vendor/wifi/wpa/wpa_supplicant.conf` 存在。goldfish 模板
   （disable_scan_offload=1 等三行）装到 vendor，rc 开机 copy 过去。
4. **国内连通性验证墙**：连接成功但框架访问 Google `generate_204`
   失败 → `NETWORK_SELECTION_DISABLED_NO_INTERNET_PERMANENT` →
   重启后永不自动回连（现象极具迷惑性：手动连每次都成）。
   换 `captive_portal_https_url` 为国内可达端点即验证通过
   （IS_VALIDATED），自动回连恢复。设置在 /data，重刷后要跑
   `scripts/android-post-flash.sh`。

**最终验收（2026-08-17）**：冷启动免手干预 → WiFi 自动连接 <SSID>
（11ax，2401Mbps，RSSI -27）→ DHCP + IPv6 GUA → 公网 ping 17ms →
adb over TCP（persist.adb.tcp.port=5555）双通道可用。

## #30 蓝牙崩溃循环——无 HCI HAL，先禁用（待做）

内核 BT 栈已 =y（kb18），但 vendor 没有 `com.android.hardware.bluetooth`
APEX → BT 应用起来就 LOG(FATAL) 崩溃循环（100 个墓碑，会喂 RescueParty）。
已 `settings put global bluetooth_on 0` 止血（进 post-flash 脚本）。
下一场双修：(a) 加 BT HCI HAL APEX；(b) hci_qca 固件竞速同 #28
（4.6s 就要 qca/wcnhpbtfw21.tlv，晚绑定或 rc 重触发）。

## #31 缺的固件其实一直躺在本机 Ubuntu 里 ✅ 已取用

排音频"无声卡"时顺手挖到的大礼包 —— Ego 的 Ubuntu 根（U 盘 sda2）的
`/lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/` 下有我们缺的全部华为专有件：

| 文件 | 作用 | 缺了会怎样 |
|---|---|---|
| `qcdxkmsuc8280.mbn` | **GPU zap shader** | GPU 停在安全模式，freedreno 不可用（dmesg 刷 `adreno_zap_shader_load *ERROR*`）|
| `audioreach-tplg.bin` | **音频拓扑** | 声卡不注册 |
| `adspr.jsn` / `adspua.jsn` / `cdspr.jsn` / `battmgr.jsn` | pd_mapper 服务表 | ADSP 服务注册不全 |
| `qcvss8280.mbn` | 语音 DSP | （暂未用到）|

**教训**：这台机器的"专有固件从哪来"问题，答案不一定是 Windows 驱动包 ——
gaokun 社区的 Linux 镜像早就把它们凑齐了，本机 Ubuntu 就是现成的固件来源。
以后缺任何 blob，先 `mount /dev/block/sda2` 翻一眼再说。
（Android 侧要 `CONFIG_USB_STORAGE=y` 才看得见 U 盘，kb19 已开。）

## #32 固件竞速的根治：ramdisk 副本 + AOSP 的 ELF 检查

remoteproc（ADSP/CDSP/SLPI）、GPU zap shader、hci_qca 都在 `/vendor` 挂载前
probe，而音频那条链的驱动全带 `suppress_bind_attrs`（`bind`/`unbind` 文件
根本不存在），#28 那套"晚绑定补一刀"用不了。根治办法是让**首次 probe 就能
拿到固件**：把固件也装进 ramdisk 的 `/lib/firmware/`（ramdisk 是第一阶段
rootfs；cmdline 的 `firmware_class.path=/vendor/firmware/` 只是首选路径，
找不到会回落到 `/lib/firmware`）。

踩坑：AOSP 会拒绝 `PRODUCT_COPY_FILES` 里**目标路径含 `bin`/`lib`/`lib64`
组件的 ELF 文件**（`found ELF prebuilt in PRODUCT_COPY_FILES`）。
`.mbn` 固件本身就是 ELF 格式，而 ramdisk 目标必须落在 `/lib/firmware` →
只能开官方逃生开关 `BUILD_BROKEN_ELF_PREBUILT_PRODUCT_COPY_FILES := true`。
（`/vendor/firmware/...` 不含 lib 组件，所以之前一直没触发。）

副作用：ramdisk.img 从 1.5 MB 涨到 12 MB，可接受。

## #27 拔插 USB 后 adb 不重枚举（UCSI 角色老毛病，缓解：adb over TCP）

拔掉 USB 线再插回后 gadget 不重新枚举，`adb devices` 空，需要整机
重启才恢复。与已知 UCSI PPM init 缺陷同源（dr_mode=otg 无 role 源
时靠初始 fallback 落到 device 侧，拔插后没有事件源驱动它再切回）。
Stage 4 电源/USB 项一并处理。

---

## 浸泡测试记录（2026-08-17 kb18 + build e）

冷启动后连续运行 ~2 小时（挂机 + 每 10 分钟 adb 采样 12 轮）：
崩溃 0（蓝牙禁用后 crash buffer 全程干净）、WiFi 全程在线、
最高温 44.8°C / 尾声 35.3°C、负载均值 ~1.1。
今日全部改动（gpio174 触摸、ath11k 晚绑定、wifi 栈、BT 禁用）无回归。

---

## #33 音频：声卡不注册的真正源头是三个 `=m` + 一个固件路径（2026-08-19 完成，实机出声）

`/proc/asound/cards` 一直是 `--- no soundcards ---`。链条自下而上：

```
CONFIG_PINCTRL_LPASS_LPI=m / PINCTRL_SC8280XP_LPASS_LPI=m
  → 33c0000.pinctrl 永不绑定（Android 不加载任何模块）
  → rx/tx/wsa macro 的 pinctrl supplier 缺席，永远 deferred
  → 三个 soundwire 控制器等 macro → sound 节点等 DAI → 无声卡
```

实测原话（logcat，kernel）：

```
platform 3200000.rxmacro: deferred probe pending:
  platform: wait for supplier /soc@0/pinctrl@33c0000/rx-swr-default-state
```

一起转正的还有：
- `SC_LPASSCC_8280XP=m` → `=y`（LPASS 时钟控制器，macro 的 mclk/npl 来源）
- `QRTR_SMD=m` → `=y`（QRTR 的 rpmsg 传输，pd-mapper 靠它与 ADSP 通信）
- **`SND_SOC_WSA883X` 压根没编** → 本机扬声器是 wsa8830
  （DT `compatible = "sdw10217020200"` = mfg 0x0217 / part 0x0202，
  由 `wsa883x.c` 认领，与 ThinkPad X13s 同款）

修完配置后 macro / soundwire / GPR 服务全部就位，卡在最后一步：

```
qcom-apm: tplg firmware loading qcom/sc8280xp/SC8280XP-HUAWEI-GAOKUN3-tplg.bin failed -2
snd-sc8280xp sound: ASoC: failed to instantiate card -2
```

**新内核的拓扑固件名是 `qcom/<card->driver_name>/<card->name>-tplg.bin`**
（`sound/soc/qcom/qdsp6/topology.c:1320` 用 `kasprintf` 拼，card 名来自 DT `model`），
而我们按老规矩装的是 `qcom/sc8280xp/HUAWEI/gaokun3/audioreach-tplg.bin`
—— 路径和文件名都不对。放到内核要的位置后声卡立刻注册：

```
0 [SC8280XPHUAWEIG]: sc8280xp - SC8280XP-HUAWEI-GAOKUN3
PCM：MultiMedia1/2 Playback + MultiMedia3/4 Capture
```

### 路由（Android 没有 ALSA UCM）

**华为 MateBook E 的 UCM 明确 include ThinkPad X13s 的配置**
（`conf.d/sc8280xp/sc8280xp.conf` 里 `If.HUAWEI → /Qualcomm/sc8280xp/LENOVO-X13s.conf`），
所以 X13s 那套控件序列与拓扑固件直接适用。PCM 映射：

| 用途 | PCM | 通路 |
|---|---|---|
| 扬声器 | **hw:0,1** | `WSA_CODEC_DMA_RX_0 ← MultiMedia2` |
| 耳机 | hw:0,0 | `RX_CODEC_DMA_RX_0 ← MultiMedia1` |
| 头戴麦 | hw:0,2 | `TX_CODEC_DMA_TX_3 → MultiMedia3` |
| 内置麦 | hw:0,3 | `VA_CODEC_DMA_TX_0 → MultiMedia4` |

开机自动摆路由：`device/huawei/gaokun3/bin/audio-route.sh` +
`etc/audioroute.rc`（等 `/dev/snd/controlC0` 出现后按 UCM 序列设 WSA 通路，PA=17）。

### 框架层接入

AOSP 的 AIDL 音频 HAL **自带 ALSA 后端**（`alsa/StreamAlsa.cpp` 等），
而它开哪张卡由 device port 的 **address 字符串**决定：
`primary/StreamPrimary.cpp getCardAndDeviceId()` 用
`sscanf("CARD_%d_DEV_%d")` 从 address 里解析，解析不到就退回内置默认值。
我们原本没写 address → 永远落不到扬声器。改成
`address="CARD_0_DEV_1"` 后 HAL 日志实证：

```
AHAL_StreamPrimary: getCardAndDeviceId: parsed with card id 0, device id 1
```

### 验收

`tinyplay /data/local/tmp/*.wav -D 0 -d 1` 实机出声（用户确认），
`/proc/asound/card0/pcm1p/sub0/status` 播放中为 `state: RUNNING`。
2026-08-19 用 ffmpeg 转码的整曲（48kHz 立体声 2'34"）完整放完。

### 起停爆音：BOOST 升压器（A/B 盲听定案）

用户反馈"开头结尾有破音"。三轮 A/B 实听把它逐步收窄：

1. 先怀疑我的测试音硬起停 → 加淡入淡出，**照样爆** → 不是文件问题。
2. 再怀疑我把 PA 推到 17 削波 → 降到 12/8，**照样爆** → 不只是增益。
3. 关掉 `SpkrLeft/Right BOOST Switch` → **爆音消失**（用户原话
   "第一遍没有爆音，很好"）。

→ 结论：爆音来自功放升压器使能瞬间。`bin/audio-route.sh` 默认改成
**BOOST 关 + PA=12（UCM 原厂值）**。代价是最大声压低一些，
对平板小喇叭是划算的取舍。
（另注：每次 `tinyplay` 都会重开 PCM，所以每段都上下电一次；
正常媒体播放时 audioserver 持有音频流，不会每首歌爆一次。）

### ⚠️ 设备上一个系统音效文件都没有

`/system/media/audio/` **整个目录不存在** —— 铃声、通知音、闹钟、UI 音效
（`Effect_Tick.ogg` 等）全都没装。所以：

- `cmd notification post`、音量键提示音、点击音效**天然无声**，
  不是通路问题（我一度用它们做验证，测不出东西）。
- 想要这些音效，需要在 device.mk 里 inherit AOSP 的音频资源包
  （`frameworks/base/data/sounds/` 下有若干 `.mk`：`AllAudio.mk` 是全量，
  另有若干按机型裁剪的 `AudioPackage*.mk`）。
  ⚠️ **具体该 inherit 哪个必须先在 AOSP 树里核实**（本项目规矩：不凭记忆写路径），
  下次开构建机时 `ls frameworks/base/data/sounds/*.mk` 确认后再加。
- 验证框架层媒体音只能靠真播放器：`com.android.music` 已装（AOSP 音乐播放器），
  但它只显示 MediaStore 里的内容，而 `adb push` 到 `/sdcard/Music/` 后
  MediaProvider 并未自动收录（`cmd media_provider` 在本版本不存在，
  `MEDIA_MOUNTED` 广播也没触发重扫）。

### 遗留

- 左功放（`sdw:1:0:0217:0202:00:1`）卡在 `Alert` 状态刷
  `Bus clash detected`（2607 次），右功放 `Attached` 正常；出声不受影响。
- `qcom-soundwire` 报 `din-ports/dout-ports mismatch with controller`（DT 端口数与
  控制器不符），暂未影响功能。
- 框架层只验证到"HAL 指向正确 PCM"，尚未用真播放器跑通媒体音
  （`cmd notification post` 默认无声音渠道，测不出来）。
- shell 用户不在 `audio` 组 → 非 root 下 `tinyplay` 会 "cannot open device"。

## #34 蓝牙：内核早就通了，缺 HAL + 一个调度器配置（2026-08-19 完成）

`hci0` 其实一直在（`BT_QCA`/`BT_HCIUART_QCA` 都是 `=y`，`hci_qca` 绑在
`988000.serial:0.0` 的 serdev 上）。#30 说的"无 HCI HAL"两步补齐：

1. **AOSP 自带的 HAL 就支持 Linux HCI**：
   `hardware/interfaces/bluetooth/aidl/default/BluetoothHci.cpp:172`
   先 `NetBluetoothMgmt::openHci()`（BT 管理 socket + `HCI_CHANNEL_USER`），
   失败才退回串口路径。**一行代码没改**，把
   `android.hardware.bluetooth-service.default` + 它的 `.rc` + VINTF 片段 +
   `android.hardware.bluetooth-V1-ndk.so` 走 overlay 推进 vendor 即可（不刷 super）。
   ⚠️ 少推那个 `-V1-ndk.so` 会得到 `CANNOT LINK EXECUTABLE ... not found`
   的 5 秒重启循环。
2. ★**真凶与 HAL 无关**：
   ```
   bluetooth: message_loop_thread.cc:291 EnableRealTimeScheduling:
     unable to set SCHED_FIFO priority 1 for bt_main_thread, error: Operation not permitted
   → bluetooth::log::fatal → com.android.bluetooth abort
   ```
   `CONFIG_RT_GROUP_SCHED=y` + `CGROUP_SCHED` 时，非 root cpu cgroup 的
   `rt_runtime_us` 默认是 0 → 该 cgroup 内任何 `sched_setscheduler(SCHED_FIFO)`
   一律 EPERM。**GKI 里这项是关的**，主线 defconfig 默认开。关掉即好。

验收：`svc bluetooth enable` → `dumpsys bluetooth_manager` 显示
`enabled: true / state: ON / address:（从芯片读出）/ name: MateBook E Go`，
`com.android.bluetooth` 崩溃 0 次，`EnableRealTimeScheduling` 报错 0 次。

## #35 方法论：`kernel-config-android.sh` 现在自带断言

"Android 不加载模块，`=m` 等于驱动缺席"这个坑本项目踩了 **12 次**
（WiFi 的 PWRSEQ、USB_STORAGE、这次的 LPASS pinctrl…）。脚本已改为：
自己跑 `olddefconfig`（把致命的 `ARCH=arm64` 固定住），跑完断言
**35 个必须 `=y`**、**1 个必须 `=n`**（`RT_GROUP_SCHED`），
另查 `CONFIG_LSM` 必须含 `selinux` 且不含 `apparmor`，不达标非零退出。

## #36 框架层媒体音的真正拦路虎：`MediaCodecList` 是空的（AOSP 产品配置缺失）

> ⚠️ **2026-08-19 更正**：本节把根因归给"`media_codecs.xml` 缺失 / 产品配置缺口"
> —— **这个结论是错的**。当天在同一台设备上把整条链路逐环量了一遍：
> XML（APEX 和 /vendor/etc 两份都在）、36 个软解码库、C2 服务已注册、
> VINTF 片段装着且 `vintf fm` 运行时确实列得出来、`ro.vendor.api_level=202504`
> 走 AIDL —— **每一环都是好的**。
> 真正断点是 `AServiceManager_forEachDeclaredInstance()` 返回空，
> 即 **servicemanager 的 "declared" 集里没有它**（registered ≠ declared）。
> 完整证据链与主嫌疑（servicemanager 的 VintfObject 快照早于 apexd 就绪，
> 而该声明带 `updatable-via-apex`）见 **`docs/stage6-crdroid.md`**。
> 本节下面的"排查过程"仍然有效，只是结论那一步要改读 stage6。

音频**输出**通路已经完备，有硬证据：

- HAL 指向正确的 ALSA 设备：`AHAL_StreamPrimary: getCardAndDeviceId: parsed with card id 0, device id 1`
- AudioFlinger 有两个 48kHz 输出线程（`AudioOut_D` / `AudioOut_1D`）
- `tinyplay` 直连 ALSA 出声正常（用户实听确认，整曲 2'34" 放完）

但任何 App/媒体播放都失败，栈底原因是**解码器一个都没有**：

```
E NuPlayerDecoder: Failed to create audio/mpeg decoder
E NuPlayer: received error(0x80000000) from audio decoder
D MediaPlayerService: OMX service is not available
dumpsys media.player → "Decoder infos by media types:" （空）
```

排查过程（都是实测，不是推断）：

| 检查 | 结果 |
|---|---|
| `media.swcodec` / `mediaserver` / `media.extractor` 进程 | 都在跑 |
| C2 软件服务注册 | 在：`android.hardware.media.c2.IComponentStore/software` |
| VINTF 声明 | 在：`/system/etc/vintf/manifest/manifest_media_c2_software.xml`（AIDL + HIDL 双声明）|
| `hwservicemanager` | **不在**（Android 15+ 已移除 HIDL），所以 HIDL 那条声明是死的，只能走 AIDL |
| `/vendor/etc/media_codecs.xml` | **原本不存在** → 从 `/apex/com.android.media.swcodec/etc/media_codecs.xml` 拷了一份进 vendor + 重启媒体栈 |
| 拷贝后 | `MediaCodecList` **仍然是空的**（decoders 和 encoders 都空）|
| `ro.media.xml_variant.*` 属性 | **全部未设置** |
| swcodec 进程日志 | 一行都没有（连启动信息都没打）|

→ 结论：这是 **AOSP 产品配置层的缺口**，不是硬件或内核问题。
一个正常 ROM 的设备配置会带齐 `media_codecs.xml` /
`media_codecs_performance.xml` / `media_profiles.xml` /
`ro.media.xml_variant.*` 一整套；我们这棵手搓的最小 AOSP 从来没配过。
同理 `/system/media/audio/`（铃声/UI 音效）也整个缺失（见上一节）。

**这条正是"换 crDroid（LineageOS 系）比继续修手搓 AOSP 更划算"的最好论据**：
这些产品级配置是 Lineage 设备树的标准组成部分，换轨后大概率自动消失，
而我们所有的硬件使能成果（内核配置、DTB、固件路径、turnip 补丁、
混音器路由脚本、SMMU workaround）**全部可平移**。

---

## #37 传感器：整套跑在 SLPI DSP 上 —— ★结论已修正，主线**能**做到（2026-08-20）

> ### ⚠️ 本条原先的结论是错的，2026-08-20 当天被推翻
>
> 我原先写的是"主线此路不通，任何 sc8280xp 设备都没人做到过"。
> **错。** 一位贡献者拿 **`hexagonrpcd`（linux-msm）+ `libssc`
> （Dylan Van Assche，codeberg.org/dylanvanassche/libssc）** 在本机型上把
> 三个传感器读出来了（light / accelerometer / gyroscope）。
>
> 下面的**结构性分析仍然成立**（传感器由 SLPI 托管、芯片挂在 SSC 侧总线、
> AP 侧没有任何传感器芯片驱动），错的只是"因此不可达"这一步推论 ——
> 可达路径是 **AP 通过 FastRPC 给 DSP 当文件服务器**，再用 QMI/protobuf
> 取读数，而不是 AP 直接驱动芯片。
>
> ★**一个强互证**：贡献者的部署指南里 socinfo 要填
> `QRD` / `Unknown` / `0` / `65536` / **`449`** / `3.1`，
> 与我从 Windows 驱动里独立读出的完全一致（`tcs3701.json` 里就是
> `"soc_id": ["449"]`、`hw_platform` 文件内容就是 `QRD`）。两边互相印证。
>
> ★**已经打通的第一步（实测）**：`CONFIG_QCOM_FASTRPC` 在本内核里是 **`=m`**，
> 而这棵树**不发模块**（设备上 `/proc/modules` 是 0 行、连模块目录都没有），
> 所以 `/dev/fastrpc-*` 从来不出现。DTS 里节点是齐的
> （`remoteproc_slpi` 下 `fastrpc` + `compute-cb@1/2/3`），
> rpmsg 通道也在（`2400000.remoteproc:glink-edge.*`）—— 只是没人 probe。
> 单独编出 `fastrpc.ko` 推上去 `insmod`（vermagic 完全匹配、模块签名关闭）：
> ```
> /dev/fastrpc-sdsp   /dev/fastrpc-adsp   /dev/fastrpc-cdsp   /dev/fastrpc-cdsp-secure
> ```
> **这和 #33 音频那三个 `=m` 断点是同一类问题。** 正解是 `=y` 并加进
> `scripts/kernel-config-android.sh` 的断言。
>
> ⚠️ 附带告警：`qcom,fastrpc 3000000.remoteproc:...: no reserved DMA memory
> for FASTRPC`（出现在 ADSP 节点，SLPI 侧未报），待观察。
>
> **还差什么，见本条末尾的「落地路线」。**

### 结构性分析（这部分是对的）

**加速度计、磁力计、光感、接近、铰链角度，全部由 SLPI 传感器 DSP 托管，
AP 侧根本没有到这些芯片的总线。** 因此：

- 「往 DTS 里加个 `accel@xx` 节点」这条路**不存在**——不是没人写，是没有节点可写。
- **自动旋转、自动亮度在主线内核上无法实现**，除非有人为 sc8280xp 写出
  SLPI SEE 的客户端（QMI/FastRPC 那一整套）。**据我所知没有任何
  sc8280xp 设备做到过（包括 ThinkPad X13s）。**
- 影响面：没有自动旋转、没有自动亮度、没有铰链角度。
  ★**游戏不受影响**（应用自己请求方向，`ignoreOrientationRequest=false`
  之后照常横屏，见 `docs/stage6-crdroid.md` §9）。

### 证据（从本机 Windows 分区只读挂载后直接读出，`scripts/probe-windows-sensors.sh`）

`/dev/nvme0n1p3` 的 `Windows/System32/DriverStore/FileRepository/` 里，
**没有任何一个具体传感器芯片的独立驱动包**，取而代之的是高通那一套：

```
qcsensors.inf_arm64_...                 (qcSensors.dll —— 传感器框架)
qcsensorsconfigqrd8280.inf_arm64_...    (配置 JSON + libsdsprpc.dll)
qcalwaysoncvsensor(_ext8280).inf        (常开视觉)
qchumanpresencesensor.inf               (人体存在)
```

★`libsdsprpc.dll` = **Sensor DSP RPC**。这个名字本身就说明数据通路是
**AP ⇄ DSP 的 FastRPC**，不是 AP ⇄ I2C 芯片。

配置包里的 JSON 一览（`sns_` 前缀是高通 SEE / Sensors Execution Environment
的模块命名，这些模块**跑在 SLPI 上，不是跑在 CPU 上**）：

| 类别 | 文件 |
|---|---|
| 物理器件 | `sh3001_0.json`（6 轴 IMU）、`sy3133cs_0.json`、`t1000_0.json`、`tcs3701.json`（ams 光感+接近）、`stm_lid_angle.json`（铰链角，节名 `hingeangle_0_platform`） |
| SEE 算法模块 | `sns_device_orient`（设备方向）、`sns_rotv`（旋转矢量）、`sns_geomag_rv`、`sns_gyro_cal`、`sns_mag_cal`、`sns_amd`、`sns_rmd`、`sns_tilt`、`sns_fmv`、`sns_cm`、`sns_dae`、`sns_aont` |

TCS3701 那份 JSON 解出来的接线（**注意这是 SSC 侧的编号，不是 AP 侧**）：

```
owner            sns_tcs3701      ← SLPI 上的驱动名
bus_type         0                ← I2C
bus_instance     5
slave_config     57               ← 0x39，ams TCS370x 的经典地址
dri_irq_num      127
irq_is_chip_pin  1
vddio_rail       /pmic/client/sensor_vddio
```

### ⚠️ 一个尚未排除的疑点（别把本条当成 100% 定论）

这个配置包叫 `qcsensorsconfig**qrd**8280` —— **QRD = 高通参考设计**，
包内 `hw_platform` 文件的内容也确实是 `QRD`。零售的华为机器**通常**会另有
一个 OEM 自己的 `qcsensorsconfig<oem>8280` 包，而 DriverStore 里没有。

两种可能：(a) 华为直接沿用了 QRD 配置；(b) 真正的配置在别处（比如
`C:\Windows\INF\oem*.inf` 或 EC/ACPI 里）。**芯片型号可能不准，
但"传感器挂在 SLPI 后面、AP 无总线可达"这个结构性结论不受影响** ——
因为整个 DriverStore 里根本不存在任何 AP 侧的传感器芯片驱动。

### 复现方法

```
# 在 Ego 的 Ubuntu 里（Android 侧读不了 NTFS）
bash scripts/probe-windows-sensors.sh
```

⚠️ 本机 Ubuntu **没有 `ntfs3` 内核模块**，`mount -t ntfs3` 会报
"未知的文件系统类型"；靠 `mount -o ro` 自动探测走 `fuseblk`（ntfs-3g）才挂得上。
⚠️ 包里那几个 `8280_qrd_*.json` 是 NTFS 重解析点（symlink），
ntfs-3g 显示为 `-> unsupported reparse tag 0x80000017`、`stat` 只有 34 字节，
**读它们会 FileNotFoundError**；要读的是同目录下的**去掉 `8280_qrd_` 前缀**
的那份实体文件（`sh3001_0.json` / `tcs3701.json` …）。

### 落地路线（2026-08-20 状态）

| 步骤 | 状态 |
|---|---|
| SLPI remoteproc running | ✅ 一直是 |
| QRTR（`/dev/qrtr-tun`） | ✅ 一直是 |
| **`/dev/fastrpc-sdsp`** | ✅ **已打通**，靠 `insmod fastrpc.ko`；正解是 `CONFIG_QCOM_FASTRPC=y` |
| Windows DriverStore 的传感器文件 | ✅ **已解决**（2026-08-20）—— 从 `uup-drivers-sc8280xp` 的 release 提取，不需要 Windows 分区，见下 |
| `hexagonrpcd`（给 DSP 当文件服务器） | ⬜ 需编译，且要打一个补丁 |
| `libssc` + `ssccli`（读数） | ⬜ 需编译 |
| **Android 侧 sensors HAL** | ⬜ 尚不存在，是独立的一大块 |

#### ✅ 原先的硬阻塞已解除：文件从公开源拿到了

**本机的 Windows 已在 2026-08-20 抹除**，我当时读过那些 JSON 但没拷出来。
但不需要它了 —— 全部文件都在 **`matebook-e-go/uup-drivers-sc8280xp`
的 release** 里（该项目用 forked UUPMediaCreator 从 Windows Update 抓驱动）：

| 需要的 | 出自 |
|---|---|
| 传感器全套 JSON、`sns_reg_config`（**407 B 文本格式**，与指南要求一致）、socinfo 原件 | `qcSensorsConfigQrd8280.cab` |
| **`RSCS.bin`**（1340 B）与 `qcslpi8280.mbn` | `qcsubsys_ext_scss8280.cab`（SCSS = Sensor Core SubSystem） |

★ **交叉校验通过**：cab 里的 `qcslpi8280.mbn` 与本仓在用的那份 sha256
**逐字节相同**（`9c1ce6f5…`），证明来源同出一脉。
★ **socinfo 原件的内容与指南要求逐字一致**：`QRD` / `Unknown` / `0` /
`65536` / `3.1`（`soc_id` 文件 cab 里没有，指南给 `449`，而这与
`tcs3701.json` 里的 `"soc_id": ["449"]` 一致）。
★ `sns_reg_config` 开头确实是 `version=1` + `file=hw_platform=/sys/devices/soc0/hw_platform`
—— 这也解释了**为什么必须有 hexagonrpcd 提供 VFS**：DSP 要按这些路径去读。

提取步骤与两个会绕人的坑（cab 静默解包失败、NTFS 上 JSON 是重解析点）
记在 `device/huawei/gaokun3/firmware/README.md`。

#### （历史）原先的阻塞描述

贡献者的 Phase 4 / Phase 10 需要从 Windows DriverStore 取三类文件：

* `qcsensorsconfigqrd8280*/*.json` —— 传感器驱动配置（我读过，**但没拷**）
* `sns_reg_config` —— DSP 注册表索引。★**必须是 DriverStore 的文本格式
  （约 407 B，`version=1` 开头），不能用 DriverData 的 JSON 格式（2423 B）**，
  后者会让 DSP 注册表初始化崩溃
* `RSCS.bin` —— SLPI 伴生固件

**本机的 Windows 已在 2026-08-20 抹除**（见 `docs/hw-inventory.md` 8quinquies），
所以只能从别处取：向贡献者索取、从 `uup-drivers-sc8280xp` 驱动包提取
（`device/huawei/gaokun3/firmware/README.md` 记的那个来源）、
或另一台仍装着 Windows 的 MateBook E Go。

#### 两个已知的坑（贡献者踩出来的，转录以免重犯）

1. **DSP 固件请求的路径带尾随 `\r`**（它是在 Windows 上编译的）。两处要分别处理：
   * socinfo 走真实文件系统 → 建 `名字
` 的 symlink 即可；
   * registry 走 hexagonfs 的**内部 VFS**、不经过内核 symlink 解析
     → **必须改 `hexagonrpcd/hexagonfs.c`**，在每段路径末尾截掉 `\r`。
     apt 里的现成版本不带这个补丁，所以必须自己编。
2. **`hexagonrpcd` 的 shell wrapper 不认识 sc8280xp**，会 fallback 到错误的
   DSP；必须直接调二进制并显式给 `-f /dev/fastrpc-sdsp -d sdsp -s -R <VFS 根>`。

#### 为什么先在救援 Linux 上验，再谈 Android

`hexagonrpcd` 与 `libssc` 都是 Linux 侧的守护进程/库，贡献者的指南也是针对
Linux 写的。先在内置的救援系统上跑通 `ssccli`，能一次性验证整条 DSP 通路
（fastrpc → hexagonfs → DSP 注册表 → SSC → QMI 读数）。
之后 Android 侧还需要：把 `hexagonrpcd` 移植进 Android（纯 C 守护进程，
用 fastrpc ioctl + 一个 VFS，可移植性不差，但要写 Android.bp 和 sepolicy），
再写一个 AIDL `android.hardware.sensors` HAL 把 libssc 的逻辑包起来喂
SensorService。**那一块目前不存在，是独立的工程量。**

---

### ★★ 实测结果（2026-08-20，救援 Linux 上全程实机）

**结论：加速度计真的通了；光感通不了。** 于是「自动旋转」在本机是**可达的**，
而「自动亮度」不可达。这是本条从"不可达"到"部分可达"的最终定性。

#### ✅ 加速度计：整条 DSP 通路验证通过

```
Accelerometer sensor measurement: X=-0.052672 Y=0.114922 Z=9.873688 m/s²
```

机器平放，Z ≈ **9.87 m/s²**（重力），X/Y 近零；15 秒稳定输出 **131 行**读数。
这一个数字同时证明了整条链路：
`fastrpc → hexagonfs（含 \r 截断补丁）→ DSP 注册表 → SSC → QMI → libssc`。

配置要点（与贡献者指南一致，逐条实测）：
* `hw_platform=QRD` / `soc_id=449` —— ★**独立佐证**：内核
  `/sys/devices/soc0/soc_id` **就是 449**、`machine` 是 `SC8280XP`；
  而 26 个 JSON 里 `QRD` 出现 25 次、`449` 出现 23 次。三方一致。
* `sensors/registry/registry` **必须是空文件**（DSP 找不到覆盖值就用默认值）。
* 恢复手段 = `systemctl restart hexagonrpcd`。⚠️ **需要沉降时间**：
  重启后 6 秒就读，实测拿到 0 行；隔久一点再读才有 131 行。
  所以"重启后读不到"**不等于**坏了，别据此下结论。

#### ⚠️ 光感（tcs3701）：使能后从不返回读数

硬件是在的（`tcs3701.json`，ams 光感+接近，I2C bus 5 / 地址 0x39）。
libssc 的日志显示 registry 服务可用、传感器被发现、
`Sensor enable request sent successfully` —— **然后就再也没有读数**。
同一次会话里 QRTR 节点 9 曾整体消失又重建（服务 400 一并消失）。
更麻烦的是：**尝试过 light 之后，连加速度计也读不到了**，必须重启
`hexagonrpcd` 才恢复 → 光感的使能会**污染整个 SSC 会话**。

⚠️ **两条我自己下错又更正的判断，记下来免得后人重犯**：
1. ❌ "`registry` 传感器起不来，所以光感失败" —— **错**。那份
   `G_MESSAGES_DEBUG` 日志是在**装了生成注册表的坏状态**下抓的。
   加速度计能出数本身就证明 registry 服务是可用的。
   **判据：诊断日志必须在已知good状态下重抓，否则读的是自己制造的故障。**
2. ❌ "`qcom_q6v5_pas 2400000.remoteproc: Handover signaled, but it already
   happened` 是 SLPI 崩溃循环" —— **错，那是良性噪声**。对照实验：空闲 12 秒
   0 条，跑 light 12 秒 13 条，**但跑加速度计（工作正常）12 秒也是 13 条**。
   任何传感器会话都会伴生它。（`2400000.remoteproc` 的 `name` 确实是 `slpi`。）

#### ❌ 负面结果：`sscregistrygen` 预生成注册表会**弄坏**加速度计

思路本来很顺：hexagonrpcd 自带 `tools/sscregistrygen`，用法就写在源码头上
（`-p <平台> -s <soc_id> <配置目录> <输出目录>`，按 JSON 里 `config`
子对象下的 `hw_platform`/`soc_id` 过滤）。跑 `-p QRD -s 449` 生成了
**142 个**文件，其中确实有 `default_sensors.ambient_light`。

**结果：光感照旧没有读数，而加速度计也一起坏了**（`Unable to initialize …`）。
把 141 个文件挪走、只留回空 `registry` 文件并重启 → **加速度计当场恢复**。
干净的 A/B，因果明确。→ **本机不要预生成注册表，空 registry 才是对的。**

#### ★ 为什么"实现写入"不是一个小补丁

DSP 每秒几十次请求写 `/persist/sensors/registry/registry/../temp.json`，
`hexagonrpcd/apps_std.c` 对 `w`/`a` 模式直接返回 `AEE_EUNSUPPORTED`。
本来以为补上写入就能解决，但查了 `hexagonfs.h:34-45` 的 ops 表：

```c
struct hexagonfs_file_ops {
        close / from_dirent / openat / readdir / read / stat / seek
};
```

**没有 write 钩子，整个 VFS 是设计上只读的。** 而且那个 `..` 解析出来的
`/persist/sensors/registry/` 是 `rpcd_builder.c:163-166` 用 `hfs_mkdir`
建的**虚拟目录**，不落盘 —— 就算加了写钩子也没有后端可写，还得先把它改成
映射到真实可写目录。这是给上游加功能，不是打补丁。**别低估这一块。**

#### ⚠️ 出厂校准已随 Windows 永久消失（安装矩阵全零）

每次读数都伴随一条告警：

```
Mount matrix provided by firmware is all 0, falling back to identity matrix!
```

安装矩阵（把芯片坐标系旋到屏幕坐标系）全零，libssc 退回单位矩阵。
指南 Phase 10 的校准来源是
`$WIN/DriverData/Qualcomm/fastRPC/persist/sensors/registry/registry` ——
那是**机器出厂时写在本机 Windows 里的**，不在任何驱动包里，
而本机 Windows 已于 2026-08-20 抹除 → **这份校准数据永久丢失，Phase 10 做不了。**
后果：没有出厂 bias 补偿。
★**但轴向无害**：2026-08-20 用户实机确认**自动旋转方向正确** ——
libssc 退回的单位矩阵恰好与面板方向一致，**不需要在上层纠正**。
（所以"安装矩阵全零"这条只影响精度，不影响可用性。）
⚠️ **给后人**：还留着 Windows 的机器，
**先把那个 registry 目录拷出来再装系统。**

#### 落地路线更新

| 步骤 | 状态 |
|---|---|
| `hexagonrpcd`（打 `\r` 截断补丁后自编） | ✅ **已通**（apt 版不带补丁；注意要连 `libhexagonrpc.so` 一起装 + `ldconfig`） |
| `libssc` + `ssccli` | ✅ **已通**（⚠️ 上游已删掉 `-Dmocking` 选项，照指南写会报 "Unknown option"） |
| **加速度计读数** | ✅ **已通**，Z≈9.87 |
| 光感读数 | ❌ 使能即污染会话，未解 |
| 出厂校准 / 安装矩阵 | ❌ 随 Windows 永久丢失 |
| **Android 侧管道** | ✅ **已打通**（2026-08-20）：hexagonrpcd 在 Android 上运行，**QRTR 服务 400 上线**（node 9 port 13）。工具 `tools/qrtr-lookup/` |
| **Android 侧读数** | ✅ **已通**（2026-08-20）：自研客户端 `device/huawei/gaokun3/ssc/` 在 Android 上读出 `accel` Z≈9.88 m/s² accuracy=3、`gyro` 静止≈0 rad/s。规格见 [`sensors-ssc-protocol.md`](sensors-ssc-protocol.md) |
| 本机传感器清单（SSC 亲口回答）| `accel` ✅ / `gyro` ✅ / `mag` ❌ **本机无磁力计** / `rotv` ❌ 未注册 / `ambient_light` ❌ 污染会话 |
| **AIDL sensors HAL** | ✅ **已实现并实机验证**（2026-08-20）：`device/huawei/gaokun3/sensors-hal/`，SensorService 里能看到 `SH3001 Accelerometer` / `SH3001 Gyroscope`，事件值 `-0.04, 0.05, 9.88` 正在流入，消费者是自动旋转的 `WindowOrientationListener`。★框架还自动融合出 Game Rotation Vector / Gravity / Linear Acceleration |
| 轴向 | ✅ **用户实机确认自动旋转方向正确**，单位矩阵即可，无需纠正 |
| 仍欠 | sepolicy（现 permissive）、`CONFIG_QCOM_FASTRPC=y`（重启后要跑 `scripts/sensors-up-android.sh` 手动补）、把这套编进 ROM |

⚠️ 另有两个环境坑（都会浪费大量时间）：
* `droid-juicer` 会**无限 `openat("/usr/share/droid-juicer/configs")` 死循环**
  （0.4.2 的 bug，`strace` 当场看到），把 apt 卡住 43 分钟。→ `systemctl mask`。
* `initramfs-tools` 的 postinst 在本机**必然失败**
  （`/etc/initramfs/post-update.d/systemd-boot` 返回 1，因为我们的 ESP 布局是自定义的）
  → initramfs 的改动不会自动传播，别以为装完就生效了。

---

## #38 音频与蓝牙在长期运行后可能死锁（用户报告，尚未复现定位）

**状态：用户实机报告，我未复现、未定位。** 记在这里是为了不让它丢掉，
以及给之后动手的人一个明确的起点 —— 不要把它当成已经查清的结论。

### 现象

长时间运行之后，**音频与蓝牙可能死锁**。

⚠️ 我手上没有更细的复现条件（多久、什么负载、是同时死还是各自死、
是整个进程卡住还是只是不出声/连不上）。下面的排查建议是基于本机已知结构
推导的，不是观测结论。

### 为什么值得认真对待

这两个子系统在本机**共享一条通路**，所以"一起死"是合理的：

* 蓝牙是 **WCN6855**，走 `hci_qca`；WiFi 是同一颗芯片（ath11k）。
* 音频跑在 **ADSP** 上（audioreach + 华为拓扑固件），
  而 ADSP 与 SLPI/CDSP 一样是 remoteproc + **QRTR/FastRPC**。
* 传感器（#37）也在这条 QRTR/FastRPC 通路上 —— 而我们已经**实测到过**
  这条通路的会话可以被弄坏：使能光感会污染整个 SSC 会话，之后连加速度计
  都读不到，必须重启 `hexagonrpcd`；HAL 早期版本频繁重建客户端也会把
  传感器枚举彻底弄坏。
  **同一类"会话/客户端泄漏导致整条通路卡住"的失效模式，完全可能出现在
  音频或蓝牙上。**

### 建议的排查顺序（下次动手时照这个来）

1. **先分清是哪一层死的**，不要一上来就怀疑 HAL：
   * `dumpsys media.audio_flinger` / `dumpsys bluetooth_manager` 还响应吗？
     不响应 = 进程级卡住；响应但不出声 = 数据面。
   * `cat /proc/asound/card0/pcm*/sub0/status` —— `state: RUNNING` 且 DMA
     计数在动，说明内核侧还活着，问题在上层。
   * `bootctl`/`ps -A` 看相关进程是否处于 `D` 状态（不可中断睡眠）。
2. **看 remoteproc 有没有崩过**：
   `dmesg | grep -iE "remoteproc|adsp|q6|fatal|watchdog"`。
   ⚠️ 注意 `Handover signaled, but it already happened` 是**良性噪声**
   （#37 已用对照实验证明：工作正常的加速度计同样每 12 秒 13 条），
   不要把它当成崩溃证据。
3. **QRTR 服务表**：本仓已有 `gaokun3-qrtr-lookup`（随镜像发布）。
   死锁时列一遍，和正常时对比 —— 少了哪个服务就指向哪个 DSP。
   这是本机唯一现成的 QRTR 诊断工具。
4. **抓 ANR/tombstone**：`/data/anr/`、`/data/tombstones/`。
   ⚠️ 本机没有串口，init 期的失败也不会进 pstore（init 是主动 `reboot()`
   而不是 panic），所以**别指望 pstore**，证据只能从这两处和 logcat 取。
5. 若确认是 DSP 侧会话卡住，参照 #37 的手法做**干净的 A/B**：
   重启相关守护进程/服务，看是否当场恢复。恢复即说明是会话泄漏而非硬件。

### 影响

* 音频死锁 → 播放/通话不可用，重启可恢复（未验证是否必须重启整机）。
* 蓝牙死锁 → 外设断连、开关蓝牙无响应。
* ⚠️ 对**游戏**的影响未知：如果只是音频输出停掉，游戏本身可能仍能玩。

---

## #39 recovery：镜像能造、能交付，但启动会复位循环（未解，且诊断手段在本机失效）

**状态：卡住。** 记录下来是为了让接手的人不必重走这条路，尤其是不要再用
`init_fatal_panic` 这条在本机注定无效的手段。

### 已经做成的部分（这些是对的，可复用）

* **构建**：`TARGET_NO_RECOVERY := false` + `BOARD_RECOVERYIMAGE_PARTITION_SIZE`
  → 独立的 `recovery.img`（29,161,472 字节）。
  ⚠️ 绝不能用 `BOARD_USES_RECOVERY_AS_BOOT`：`board_config.mk:463` 一看到它就把
  `BUILDING_BOOT_IMAGE` 关掉，会推翻本机的 boot.img。改后已验证
  `BUILDING_BOOT_IMAGE` 仍为 true。
* ★**它的内核与 boot.img 里的 sha256 完全相同**（`8e55f776…`），dtb 也一样
  → ESP 上不必再放一份内核，recovery 条目直接复用该槽的 `Image` 与 `gaokun3.dtb`，
  只需多搬 14 MB 的 ramdisk。
* ★**recovery 的内嵌 cmdline 与 boot 的逐字相同** —— 是 ramdisk 决定它是 recovery，
  不需要特殊 cmdline。
* **交付形态**：ramdisk 作为文件随 `vendor` 走 OTA，由 postinstall 钩子铺到 ESP。
  于是**已装的机器一次普通 OTA 就能拿到**，不必像 `boot_a/boot_b` 那样重装
  （安装器把剩余空间全给了 `userdata`，已装机器没有余地再切分区）。
* **ramdisk 结构完好**（本地解包逐项核对）：`system/bin/recovery` 2,849,968、
  `system/bin/init` 2,468,840、`/init` 是指向 `/system/bin/init` 的符号链接、
  `system/etc/recovery.fstab` 2,257、`system/bin/adbd`、
  `system/bin/update_engine_sideload` 都在，640 个条目，gzip cpio。
  ★ `res/images/fastbootd.png` 在里面 —— 说明 fastbootd 本来是白送的。
* **BLS 条目派生也是对的**：`bootctl list` 能正常列出
  `Recovery (gaokun3) — slot _b`，`initrd` 指向的文件存在且大小正确。

### 失败现象

用 oneshot 启动 recovery 条目后**进入复位循环**，用户手动按电源键才回到 Android。

关键观测：
* **Android 一次都没进** —— `persist.sys.boot.reason.history` 在整个循环期间
  没有新增条目（它只在 Android 启动时追加）。
* **没有任何 panic 记录** —— `/sys/fs/pstore/` 空、EFI 变量里没有 `dmesg-*`。
* `/data/misc/recovery/last_log` 与 `/cache/recovery/` 都是空的
  → recovery 没有正常退出过。
* `misc` 的 BCB 仍是 `boot-recovery`（recovery 完成动作才会清它）。

### ⚠️ 为什么"加 init_fatal_panic 抓 panic"这条路在本机无效

我试过给 recovery 条目加 `androidboot.init_fatal_panic=true panic=10`，
指望把失败转成 panic 让 `efi_pstore` 抓到 —— **一无所获**。原因本仓早有记录
（见"已知坑"）：**Android init 的服务级失败（`reboot_on_failure`）走的是正常
shutdown，不是 `LOG(FATAL)`**，所以 `init_fatal_panic` 覆盖不到，pstore 里
自然什么都没有。`panic=10` 也就无从触发。
→ **别再重复这个实验。**

### 本机的根本困难：没有任何早期启动的可观测通道

* **没有串口**（硬件上就没引出）。
* **recovery 里没有网络栈**（无 WiFi 驱动/supplicant），所以它不会出现在局域网上
  —— 无法像 Android 那样用 adb over TCP 观察。
* **USB adb 在本机是坏的**（#27），而 recovery 的 adbd 只走 USB。
* pstore 这条路如上所述对这类失败无效。

所以现在是"黑盒里循环"，而每次尝试都需要人到机器旁按电源键。

### 建议的下一步（按性价比，都不要再盲试重启）

1. ★**先把 USB adb 在 recovery 里弄通** —— 这是唯一能真正看见内部的通道。
   #27 说的是"拔插后掉"，而全新启动时插着线可能是好的。判据很简单：
   插好线启动 recovery，在主机上看 `adb devices` 有没有 `recovery` 状态的设备。
   通了之后 `adb shell`、`/tmp/recovery.log` 全都能看，这个问题大概率当场就清楚。
2. 若 USB 也不通，就**给 recovery 的 ramdisk 塞一个早期写盘的探针**
   （我们控制这个 ramdisk）：在 `init.recovery.gaokun3.rc` 里挂 ESP 并
   `echo` 阶段标记到文件。这样"走到哪一步"就能在事后从 ESP 上读出来。
3. 也可以先用**最小 recovery**（`TARGET_RECOVERY_UI_LIB` 之类全不带）排除
   图形/UI 初始化的可能 —— 我们连"是不是 minui 拿不到显示"都还不知道。

### 现在的保护措施

**默认不创建 recovery 启动项。** 条目一旦存在，谁在 15 秒菜单里误选一次就得
跑到机器旁按电源键。ramdisk 照样铺（无害，14 MB，将来验证要用）。
要调试：安装器 `ENABLE_RECOVERY_ENTRY=1`，OTA 钩子
`setprop persist.gaokun3.recovery_entry 1`。

---

## #40 ★耳机口不出声 —— 已解决：RX 插值器链从未接上 + 框架找的是不存在的 h2w（2026-08-20）

用户报告耳机接口不能用。实测下来是**三个独立的阻塞点**，全部已定位并修复；
内核侧一点没缺。⚠️ 下面「阻塞点 2」保留了我当时下的错结论与它是怎么错的，因为那个误判很典型。

### 内核侧是完全好的 —— 这点先说清，别再去查它

* **插孔检测在工作**：`/proc/bus/input/devices` 里有
  `"SC8280XP-HUAWEI-GAOKUN3 Headset Jack"`（input12），
  `capabilities/sw = 0xd4` → `SW_HEADPHONE_INSERT(2)` /
  `SW_MICROPHONE_INSERT(4)` / `SW_LINEOUT_INSERT(6)` /
  `SW_JACK_PHYSICAL_INSERT(7)` 四位都声明了。
* **插入被真的识别了**：`dumpsys input` 显示
  `SwState (pressed): SW_HEADPHONE_INSERT, SW_MICROPHONE_INSERT, SW_JACK_PHYSICAL_INSERT`。
* ★**编解码器不但活着，还量出了耳机阻抗**：`HPHL Impedance 62` / `HPHR Impedance 61`、
  `HPH Type 2`。阻抗检测要求 WCD938x 已上电并在通信，所以它没问题。
* **SoundWire 枚举正常**：`sdw:2:0:0217:010d:00:4` 与 `sdw:3:0:0217:010d:00:3`
  = mfg 0x0217 / part 0x010d = **WCD938x**，在 RX 与 TX 两条链路上都在。
  （另外两个 `0217:0202` 是 WSA8830 扬声器。）
* `3200000.rxmacro` 已 probe（driver=rx_macro），
  `/sys/kernel/debug/devices_deferred` 是**空的**。

### 阻塞点 1：Android 音频策略里根本没有耳机设备

`primary_audio_policy_configuration.xml` 里声明的输出设备只有
`AUDIO_DEVICE_OUT_SPEAKER` 与 `AUDIO_DEVICE_OUT_TELEPHONY_TX`；输入只有
`BUILTIN_MIC` / `FM_TUNER` / `TELEPHONY_RX`。
**没有 `WIRED_HEADPHONE` / `WIRED_HEADSET`，也没有耳机麦克风的输入设备。**

实机对应现象：`dumpsys audio` 里只有 `speaker(2)`，
logcat 里 `WiredHeadsetManager: ACTION_HEADSET_PLUG event, plugged in: false`。
→ 即使底层能出声，框架也永远不会往那边路由。**这一条我们自己能修。**

### ★ 阻塞点 2（已解决 2026-08-20）：RX **插值器链**从来没接上

**先记原始症状**，因为它极具误导性：整条混音器通路都能配起来、全部能回读，
但 `tinyplay … -d 0`（MultiMedia1）返回 `Error playing sample`，
`/proc/asound/card0/pcm0p/sub0/status` 保持 `closed`，
而**内核一条错误都没有**。

当时那个 A/B 是对的、但不完整：把已知能用的前端 **MultiMedia2** 从 WSA 后端
改接到 RX 后端，**同样失败**；恢复 WSA 后同一个文件立刻又能播。
这正确地把责任定位到了「RX 这条链」，但我由此下的结论
（"后端 `RX_CODEC_DMA_RX_0` 本身开不起来，原因无定论，候选是拓扑缺 APM 图 /
soundwire 没上电 / q6apm 静默失败"）**是错的** —— 三个候选一个都不是。

**真凶：我配的通路中间断了一节。** 我只设了 `RX_MACRO RX0/RX1 MUX = AIF1_PB`
就以为数据能走到 HPH，实际 rx-macro 内部还有一级**插值器（interpolator）**，
它的输入选择器和解调器输出都停在默认值：

```
RX INT0_1 MIX1 INP0 = ZERO             ← 插值器混音器没有选任何输入
RX INT1_1 MIX1 INP0 = ZERO
RX INT0 DEM MUX     = NORMAL_DSM_OUT   ← 解调器没切到 class-H 输出
RX INT1 DEM MUX     = NORMAL_DSM_OUT
CLSH Switch         = Off              ← class-H 本身没开
LO Switch           = Off
RX_HPH PWR Mode     = ULP
RX_COMP1/2 Switch   = Off
```

DAPM 路径不完整 → 后端 DAI 拿不到有效通路 → PCM open 失败。
**内核不为此打任何日志**，这就是为什么它看起来像"后端坏了"。

补齐后当场通了（同一台机、同一个内核、同一份拓扑，只多设了 9 个控件）：

| 判据 | 修之前 | 修之后 |
|---|---|---|
| `tinyplay -D 0 -d 0` | `Error playing sample` | **rc=0**，正常排空 |
| `pcm0p/sub0/status` | `closed` | **`state: RUNNING`** |
| `hw_ptr` 2 秒增量 | — | 141119 → 239039 = **48960 帧/秒**（正好实时 48 kHz）|
| dmesg | 无 | 无（零报错）|

hw_ptr 按实时速率前进是关键判据 —— 它证明 DMA 在**真实消耗**数据，
不是"打开了但空转"。

### ★ 配方的来源：上游 ALSA UCM2，而且上游本来就把本机当 X13s

不用猜控件顺序。救援 Ubuntu 上 `/usr/share/alsa/ucm2/Qualcomm/sc8280xp/`
就有官配，而 `sc8280xp.conf` 里明写

```
Regex "HUAWEI.*MateBook E.*"  →  include LENOVO-X13s.conf
```

**上游把华为 MateBook E 和 ThinkPad X13s 视为同一套配置**（拓扑固件同理）。
耳机那份配方分散在四个 include 里，缺一节就是上面那个症状：

* `codecs/wcd938x/HeadphoneEnableSeq.conf` —— RDAC / HPH / **CLSH / LO** / `RX HPH Mode CLS_H_ULP`
* `codecs/qcom-lpass/rx-macro/HeadphoneEnableSeq.conf` —— **插值器那 6 条** + PWR Mode + COMP
* `codecs/qcom-lpass/rx-macro/init.conf` —— `RX_RXn Digital Volume 84`
* `Qualcomm/sc8280xp/LENOVO-X13s.conf` BootSequence —— `HPHL/HPHR Volume 2`

存档在 `docs/` 之外没必要，但**方法论值得记**：本机凡是 LPASS 音频的事，
先去救援 Ubuntu 的 UCM2 目录抄，别自己推 DAPM 图。
映射也在那里：耳机 `hw:0,0`、扬声器 `hw:0,1`、耳机麦 `hw:0,2`、内置麦 `hw:0,3`。

### ★ 阻塞点 3（原先没看见）：框架走的是 `/sys/class/switch/h2w`，本机没有

策略里加了 `WIRED_HEADPHONE` / `WIRED_HEADSET` / `IN_WIRED_HEADSET` 之后还不够。
`WiredAccessoryManager` 有两条获知插拔的路：默认那条是 legacy switch class
—— 打开 `/sys/class/switch/h2w` 收 uevent。**本机 `ls /sys/class/switch/` 是
ENOENT**（主线没有 h2w 驱动，也不会有），所以框架从来就不知道插孔存在。

开关在框架资源 `config_useDevInputEventForAudioJack`（设备上
`cmd overlay lookup android android:bool/config_useDevInputEventForAudioJack`
实名核实 = `false`）。设成 true 后它改从普通 evdev switch 设备取
`SW_HEADPHONE_INSERT` / `SW_MICROPHONE_INSERT` —— 而这个源**本来就在、
而且已经在被读**：`dumpsys input` 里那个设备的 `Classes` 是
`KEYBOARD | SWITCH`，还挂着活的 `Switch Input Mapper`。
**内核侧一点没缺，缺的只是这一个 bool。**

### 落地的三处改动

| 改动 | 文件 |
|---|---|
| `config_useDevInputEventForAudioJack = true` | `overlay/frameworks/base/core/res/res/values/config.xml` |
| 三个可插拔设备端口 + 路由（`CARD_0_DEV_0` / `_2`）| `audio/primary_audio_policy_configuration.xml` |
| 耳机 + 耳机麦的完整使能序列 | `bin/audio-route.sh` |

设备端口刻意**不进 `attachedDevices`**（可插拔设备由框架在插入时连接），
且**显式写 profile** 而不是留空 —— 扬声器留空能行是因为它开机就 attached，
可插拔设备留空会让策略在连接时去问 HAL，那是条没验证过的路；
48 kHz / stereo / S16_LE 是实测跑通的配置。

**构建前已在设备上用 overlayfs 验过的部分**（这一步值得做，策略 XML 解析失败会让
整个音频挂掉，不该等两小时构建完才发现）：
* `audio-route.sh` 三段共 45 个控件全部应用，**零个"设置失败"**；
* 重启 audioserver 后策略被接受，`dumpsys media.audio_policy` 里三个新端口
  连地址一起认下（`{AUDIO_DEVICE_OUT_WIRED_HEADPHONE, @:CARD_0_DEV_0}`）；
* 扬声器回归正常（PCM1 仍 `state: RUNNING`）。
* ⚠️ `E APM_AudioPolicyManager: invalid volume index range in the curve` **不是
  我引入的**：干净 A/B，旧策略 12 条、新策略 12 条，完全相同。是既有噪声，另记待办。

**仍未验证的一环**：`config_useDevInputEventForAudioJack` 是框架资源，
只能构建期 overlay，且 `WiredAccessoryManager` 在 SystemServer 启动时读一次，
所以端到端（插入 → 框架切路由 → 耳机出声）必须等新 ROM + 真的插一次耳机。
框架层也没有可用的插拔模拟命令（`cmd audio help` 里没有任何 device/connect/jack）。

### ⚠️ HPH 音量的方向不能猜 —— 从内核算

上游把 `HPHL/HPHR Volume` 设成 **2**，而默认是 **24**（range 0→24）。
到底哪边响？查驱动：

```
sound/soc/codecs/wcd938x.c:2620
  SOC_SINGLE_TLV("HPHL Volume", WCD938X_HPH_L_EN, 0, 0x18, 1, line_gain)
sound/soc/codecs/wcd938x.c:192
  DECLARE_TLV_DB_SCALE(line_gain, -3000, 150, 0)
```

→ 控件值 v 对应 **−30 + 1.5·v dB**。所以**默认的 24 = +6 dB**（满增益直接进耳朵），
上游的 **2 = −27 dB**。耳机灵敏度远高于喇叭，衰减是对的，框架自己还有一层音量。
交叉验证同一份配方里的 `ADC2 Volume 10`：`analog_gain = MINMAX(0, 3000)` over
0→20 → 10 = **+15 dB** 麦克风增益，也合理 —— 说明这个读法是对的。
**嫌小就往上调，每 +1 = +1.5 dB；别接近 24。**

### 顺带记两个会误导人的点

* `tinymix contents` **不是这个版本的子命令**（报 `Invalid mixer control: contents`）。
  列控件用不带参数的 `tinymix`。我第一次因此得出"没有 HPH 控件"的错误结论。
* `tinymix` **可以直接用带空格的控件名**（`tinymix 'CLSH Switch' 1`），
  不必像早期脚本那样用控件编号。用名字更好 —— **编号会随内核/拓扑变化而漂移**。


### ★ 顺带查出：内置麦克风一直是**完全断的**，而且谁都没发现（2026-08-21）

修完耳机之后顺手把两条采集通路也测了 —— 结果内置麦压根打不开：

```
tinycap -D 0 -d 3   →  cannot open device 3 for card 0
tinypcminfo -d 3    →  连能力都查不到（"Device does not exist"）
```

而音频策略里 `Built-In Mic` 声明的正是 `CARD_0_DEV_3`。**也就是说这台机器
自始至终不能录音，只是没人试过。**

根因和耳机是同一类：**前端混音器没接**
（`MultiMedia4 Mixer VA_CODEC_DMA_TX_0` = Off），再加上 va-macro 的 DMIC
使能序列一条都没设。我之前只补了耳机麦那条（MultiMedia3），漏了这条。
补齐上游 `SectionDevice."Mic"` 的 `va-macro/DMIC0EnableSeq.conf` +
`DMIC1EnableSeq.conf` 之后当场好：`tinycap -c 2` 录到 384000 帧、
`pcm3c` `state: RUNNING`、安静房间 **RMS 981 = −30.5 dBFS**
（近满幅样本只有 4 个瞬态）—— 是真实音频，不是静音也不是直流。

⚠️★ **两个采集 PCM 都只支持双声道**（`tinypcminfo`: `channels min=2 max=2`）。
传 `-c 1` 得到的是 `cannot set hw params: Invalid argument` ——
我一度因此认为**耳机麦也是坏的**，其实它一直是好的，换成 `-c 2` 立刻录到
384000 帧。⚠️ 判断"某条通路坏了"之前先看它宣告的能力。

耳机麦的数据符合"没插耳机"：RMS 25 = −62.3 dBFS、峰值 640、**51.3% 精确零**
（开路输入的样子）。要判它到底好不好，得插一副带麦的耳机。

### 与上游 UCM 刻意不同的两处（记下来免得以后当成漏配）

* `SpkrLeft/Right BOOST Switch`：**我们 0，上游 1**。功放升压器一使能，
  每次流起停都有明显爆音（2026-08-19 A/B 盲听定案）。
* `SpkrLeft/Right VISENSE Switch`：**我们 1，上游 0**。现状出声正常、
  dmesg 无抱怨，故未动；但这是个**未验证的偏离**，将来查扬声器功耗或
  保护逻辑时先看这里。

另两处查过是**已经一致**的，不用设：`WSA MODE` 默认就是上游的 0；
`WSA_RXn Digital Volume` 本机范围是 `0->81` 且已在 81（最大），
而上游写的 `84` 在本机是**超范围值**。


## #41 ★Venus 硬件视频编解码：内核这一半已打通并实机验证（2026-08-21）

`/dev/video0` = `qcom-venus-decoder`、`/dev/video1` = `qcom-venus-encoder`，
`aa00000.video-codec` 绑在 `qcom-venus` 驱动上，`abf0000.clock-controller`
绑在 `sm8350-videocc` 上，**延迟 probe 队列空**，**固件加载失败 0 行**。
据我们所知这是 sc8280xp 上第一次在主线内核 + Android 里把 Venus 跑起来。

### 三个前提，动手前逐个核实过（都不缺）

1. **时钟控制器主线已有**：`drivers/clk/qcom/videocc-sm8350.c` 自己就认
   `"qcom,sc8280xp-videocc"`（该文件 :537 与 :572 两处），不用写新驱动。
2. dt-bindings 头文件在：`include/dt-bindings/clock/qcom,sm8350-videocc.h`。
3. ★**固件我们一直在装，只是名字骗了我**。DTS 补丁把 `firmware-name` 指向
   `qcom/sc8280xp/HUAWEI/gaokun3/qcvss8280.mbn` —— 而 `firmware/README.md` 里
   那一行当初被我标成"语音服务（未用到，一并带上）"。
   **VSS = Video SubSystem，不是 Voice。** 设备上实测在，2035748 字节。
   驱动确实读 DT 覆盖：`drivers/media/platform/qcom/venus/firmware.c:224`
   `of_property_read_string_index(dev->of_node, "firmware-name", 0, ...)`。

### 补丁：8 个里打 7 个

`refs/linux-gaokun/patch sets/media/` 的 0013–0020。主线 v7.2 里
`sm8350_res` / `sc8280xp_res` / `llcc_path` / 两个 compatible **一个都没有**
（grep 全 0），所以整套都要打。

* **0014 跳过** —— 纯格式清理（去 of_match 表的尾逗号），而主线已分叉
  （多了 msm8939，sc7280/sm8250 被挪进 `#if !IS_ENABLED(CONFIG_VIDEO_QCOM_IRIS)`），
  打不上也不影响功能。
* 0017/0018/0019 需要 `patch -p1 -F3` 的 fuzz，其余 `git apply` 直接过。
* ⚠️ 我们的内核补丁是**铺在工作树上没提交**的，所以只能 `git apply`，不能 `git am`；
  打完要复核自己的补丁还在（`cooling-maps` 9 处、`gpio174` 1 处，都在）。

### ★ compatible 选 `sc8280xp` 而不是 `sm8350`

0019 的 DTS 原文写的是 `qcom,sm8350-venus`，但 0018 专门为本 SoC 加了
`sc8280xp_res`。两个资源结构**只差一个 freq_tbl**：`sm8350_res` 借用
`sm8250_freq_table`（444/366/338/240 MHz），`sc8280xp_res` 有自己的
（240/338/366/444/533/560 MHz）。既然 0018 就是为本 SoC 加的，用它才对
（否则 0018 是死代码）。bindings 里两个都文档化了
（`Documentation/devicetree/bindings/media/qcom,sm8350-venus.yaml:22-23`）。

⚠️ **顺带发现一个上游小 bug，但【故意不改】**：`sc8280xp_freq_table` 是**升序**，
而其他 SoC 的表（msm8916/msm8996/sdm845/sc7180/sc7280）**全是降序**。
查了消费者才敢下结论：V6 走的 `load_scale_v4` 用的是 **OPP 框架**
（`dev_pm_opp_find_freq_floor/ceil`），`freq_tbl` 只在两处用到 ——
`core_get_v4` 在 **DT 没有 OPP 表时**拿它填 OPP（我们的 DTS 有），
以及 `core_clks_enable` 在 OPP 查找失败时取 `freq_tbl[size-1]` 兜底。
所以在我们这个配置下升序**无害**；改了反而是未经验证的偏离。
（若哪天去掉 DT 的 OPP 表，兜底就会取到 560 MHz 最高档而不是 240 MHz 最低档。）

### ⚠️★ 最难猜的一步：必须关掉 `CONFIG_VIDEO_QCOM_IRIS`

不关的话 Venus 编不过，而**报错完全看不出跟它有关**：

```
core.c:1192: error: 'sm8350_reg_preset' undeclared here
core.c:1194: error: 'sm8250_bw_table_enc' undeclared here
core.c:1210: error: 'VPU_VERSION_IRIS2' undeclared here
core.c:1282: error: 'sm8350_res' undeclared here
```

看起来像补丁打错了。真相是主线 v7.2 引入了新的 iris 驱动接管 IRIS2 世代，于是
`core.c:1017` 的 `#if (!IS_ENABLED(CONFIG_VIDEO_QCOM_IRIS))` 把
`sm8250_freq_table` / `sm8250_bw_table_{enc,dec}` / `sm8350_reg_preset` 全编掉，
`core.h:58` 连 `VPU_VERSION_IRIS2` 都没了 —— 而 `sc8280xp_res` 正好引用其中四个。

★ **关它是对的，不是权宜**：iris 的 of_match 里只有 `qcs8300` / `sm8550` /
`sm8650` / `sm8750` / `x1p42100`，**没有 sc8280xp 也没有 sm8350** ——
它永远服务不了本机，却把本机需要的代码删掉了。而且它是 `=m`，Android 不加载模块。

### ⚠️★ 又是 "=m 坑"，这次整条链上有五个

刷机前的实测值：`MEDIA_SUPPORT=m`、`VIDEO_DEV=m`、`VIDEOBUF2_DMA_CONTIG=m`、
`V4L2_MEM2MEM_DEV=m`、`SM_VIDEOCC_8350=m`。Android **不加载任何模块**，
所以只 `--enable VIDEO_QCOM_VENUS` 会得到"配置里明明开了、设备却不存在"。
八个符号全部拉 `=y` 并写进 `scripts/kernel-config-android.sh` 的 MUST_Y 断言
（44 → 52 条），`VIDEO_QCOM_IRIS` 进 MUST_N。

### ⚠️ 一个会骗过自己的构建脚本写法

第一次构建报 `KBUILD_RC=0` 而实际 `drivers/media` 编译失败 ——
因为 `make ... | tail -30` 之后取的 `$?` 是 **tail 的退出码**。
判据要看产物时间戳：`Image` 还停在旧的 10:09，只有 DTB 是新的。
（本仓在 az CLI 上记过同一个坑，这次是在 make 上重演。）

### 还没做的另一半：Android 侧的 Codec2 组件

内核给出的是 V4L2 M2M 设备，Android 要用它还需要一个 Codec2 组件。
★ 好消息：**`external/v4l2_codec2` 本来就在 crDroid 的 manifest 里**
（`LineageOS/android_external_v4l2_codec2`，groups="pdk"），不用新增仓库。
现有 66 个解码器仍然全是软解。


## #42 ★Android 上**能**写 EFI 变量 —— 推翻 M4/M6 的判断（2026-08-21）

M4/M6 记的是"`efi=noruntime` 所以 Android 写不了 `LoaderEntryOneShot`，
要进别的系统只能先重启到救援 Ubuntu 用 `bootctl set-oneshot`"。**这是错的。**

实测（cmdline 里确实有 `efi=noruntime`）：

```
mount -t efivarfs none /data/local/tmp/efivars   → rc=0，列出 78 个变量
读 LoaderEntrySelected / LoaderDevicePartUUID    → 正常（UTF-16LE）
写 LoaderEntryOneShot-4a67b082-...               → rc=0，回读正确
```

写法：4 字节属性（`NV|BS|RT` = `0x07`，小端）+ 条目名的 UTF-16LE + 双字节 NUL。
覆盖已存在的变量前要 `chattr -i`。

★**而且机制我们 Stage 0 就写下来了，只是没把它和 Android 联系起来** ——
`docs/hw-inventory.md` 第 8 节原文：本机的 EFI 变量走**高通 TrustZone 的
`uefisecapp` 后端**，不依赖 EFI 运行时服务（dmesg 里同时有
`EFI runtime services will be disabled.` 和 `efivars: Registered efivars
operations`），所以 `efi=noruntime` **不影响**变量读写。
M4/M6 那个"Android 写不了"的判断，其实与本仓自己的记录是矛盾的 ——
教训是**跨阶段的结论要回头对一遍旧案卷**，不然会重新发明一个错误。

**为什么这条重要**：它让 Android **自己**就能安排"下一次启动进救援系统"，
而且是 oneshot —— 失败会自动回落到 `default`。这正是"远程优先"缺的最后一块。
本轮就靠它安全地试了 Venus 内核：`default` 全程保持已知可用的 slot_b 不动，
oneshot 指向临时条目；万一新内核起不来，一次断电就回到能用的系统。

### ⚠️ 顺带查明：boot_control HAL 会把"默认项=救援系统"这条纪律覆盖掉

`loader.conf` 里读到的是 `default *-android-b.conf` —— 不是安装器写的
`*-int-ubuntu.conf`。因为 boot_control HAL **每次 Android 启动都把当前槽位
镜像进 loader.conf**（M6 的设计）。于是 `docs/INSTALL.md` 里承诺的
"Android 挂死 → 拍电源键 → 自动回落到可远程接入的系统"这条安全网，
**在首次进 Android 之后就静默失效了**。
本轮的 `adb reboot` 本想去 Ubuntu，结果又回到 Android，就是这么发现的。
有了上面的 oneshot 能力，正解是：让 HAL 只镜像槽位、把 `default` 留给救援系统，
或者干脆改用 oneshot。已记入 TODO。

### ⚠️ toybox 的 `mount` 报 `bad /etc/fstab` 其实是"你不是 root"

`mount -t vfat /dev/block/by-name/esp DIR` 直接报
`mount: bad /etc/fstab: No such file or directory` 并 rc=1，**即使参数完整**，
非常容易让人去追 fstab。

⚠️ **我确实为此下过一次错结论**（"toybox mount 要求 /etc/fstab 存在"）——
因为我当时同时改了两个变量：造了空 fstab **并且**重新拿了 root。
干净的 A/B（root 身份、把 fstab 移走）证明：**efivarfs 与 vfat 都照样 rc=0**。
真正的原因是**非 root 挂载**时 toybox 会去查 fstab，查不到就报这句。
`adb root` 之后重启会掉，每次重启都要重做
（`setprop service.adb.root 1` 然后 `adb root`，见 M3）。

顺带两条真的坑：`/mnt` 在 adb shell 里不可写，挂载点要放 `/data/local/tmp/` 下；
**挂载与后续操作要在同一次 `adb shell` 调用里**（不同调用的挂载命名空间可能不同，
不过实测挂载会保留下来，所以看到 `Device or resource busy` 是"已经挂上了"）。


## #43 光感 tcs3701 为什么不通：与能用的加速度计做逐字段对照（2026-08-21）

#37 记了"光感使能后从不返回读数，而且会污染整个 SSC 会话"。这次把两份
出厂配置逐字段对照，**排除了一条假设，并把嫌疑收敛到一处**。

配置在 `/vendor/etc/hexagonrpcd-root/sensors/config/`（华为专有，不入库）：

| 字段 | sh3001 加速度计（**能用**）| tcs3701 光感（**不通**）|
|---|---|---|
| `bus_type` / `bus_instance` | I2C / **1** | I2C / **5** |
| `slave_config` | 54 (0x36) | 57 (0x39) |
| `dri_irq_num` / `irq_is_chip_pin` | 32 / 1 | 127 / 1 |
| `irq_trigger_type` | 3 | 1 |
| `num_rail` / `rail_on_state` | 1 / **1** | 1 / **2** |
| `vddio_rail` | `/pmic/client/sensor_vddio` | **同一条** |

* ❌ **"DSP 够不到 PMIC 电源轨"被排除** —— 能用的加速度计走的是**同一条轨**。
* ❌ **"SLPI 用不了主 SoC 的 TLMM 脚做中断"也站不住** —— 加速度计同样是
  `irq_is_chip_pin=1`（GPIO 32）。（保留一点余地：加速度计约 8.7 Hz 的流也可能
  是轮询出来的，这条没有被同等强度地证否。）
* ★ **嫌疑收敛到 `bus_instance` 1 vs 5**，其次是 `rail_on_state` 1 vs 2。
  而且它正好能解释"污染整个会话"：往一个没起来的 I2C 控制器发事务会在 SEE
  里挂住，之后连加速度计也读不到，必须重启 hexagonrpcd。

**下一步**：找 SLPI 侧 I2C 实例号到实际 QUP 控制器的映射，确认 instance 5
是否需要 AP 让出某个控制器（或需要 AP 侧不去 claim 它）。
本机 AP 的 DTS 里有哪些 i2c 节点是开着的，是可以直接比对的。


## #44 装 OTA 时的"WiFi 很慢"：⚠️我先归错了因，实际 WiFi 没问题（2026-08-21）

**这条的价值主要在于它记录了一次我自己的误判是怎么被查出来的。**

### 现象

装 OTA 时 1.1 GB 的 payload 下到 2% 几乎停住，约 **10 KB/s**；
同时 `ping 1.1.1.1` **45% 丢包**，dmesg 在刷
`ath11k_pci: msdu_done bit in attention is not set`。
而链路指标完美：RSSI −35 dBm、802.11ax、5200 MHz、协商 Tx 2401 / Rx 1921 Mbps。

### ⚠️ 我当场下的结论（**错的**）

"`msdu_done` 丢帧导致 45% 丢包和吞吐崩塌，是 ath11k 的负载触发缺陷。"
理由看起来很硬：那 25 条报错**全部**落在下载那几分钟（t=1423–1671 s，
uptime 1690 s），开机到下载开始一条都没有，而且是唯一一种 ath11k 报错。

**三个证据推翻了它**：

| 实验 | 结果 |
|---|---|
| 空闲 30 秒后 `ping 1.1.1.1` ×30 | **40% 丢包，新增 msdu_done = 0** |
| 27.5 MB 小下载 | 881 KB/s，**新增 msdu_done = 0** |
| ★ `ping 192.168.31.1`（网关）×30，含 1400 字节大包 | **0% 丢包** |
| ★★ 从本机 HTTP 拉 200 MB（纯 LAN / WiFi） | **61.7 MB/s（≈494 Mbps），新增 msdu_done = 0** |

* **丢包只发生在到 1.1.1.1 的 WAN 路径上**，到网关是 0% —— 连 1400 字节大包
  都不丢。所以**不是无线链路、不是驱动**。（到公网 DNS 的高 ICMP 丢包
  很常见，多半是 ICMP 限速。）
* **msdu_done 与丢包、与日常慢速都不相关**：小下载 881 KB/s 时它是 0，
  而 61.7 MB/s 的大流量 LAN 传输**同样是 0**。它只在那条已经很糟的 WAN
  下载里出现 —— 是**伴随现象**，不是原因。
* ★ **WiFi 能跑到 61.7 MB/s**，这一条就足以把"ath11k 有问题"整个否掉。

### 真正还不知道的部分（不要假装知道）

设备从 R2 拉东西只有 **1–2 MB/s**，而**同一个网络里的 PC 拉同一个 URL 是
36.9 MB/s**。20 倍的差距是真的，**原因未定**。候选（都没验证）：
Android 与 Windows 在高时延（40–50 ms）有损路径上的 TCP 行为差异；
不同的 Cloudflare PoP；运营商对不同主机的策略。
**不要再把它记到 ath11k 头上。**

### ★ 顺带得到一条很实用的运维手段

既然设备的 WAN 慢而 LAN/USB 快，装 OTA 就别让设备自己去下。实测五条链路：

| 链路 | 速度 |
|---|---|
| 本机 ↔ Azure 构建机（scp） | **145 KB/s**（1.1 GB 要两小时，不可用）|
| 构建机 → R2（云到云） | 35 MB/s（1.05 GiB / 30 s）|
| **本机 ↔ R2（Cloudflare）** | **36.9 MB/s**（1.1 GB / 30 s）|
| **本机 → 设备（USB adb）** | **35–36 MB/s** |
| **本机 → 设备（WiFi LAN, HTTP）** | **61.7 MB/s** |
| 设备 ↔ R2（WiFi WAN） | 1–2 MB/s |

最快的路是 **R2 → 本机 → USB → 设备**，然后
`update_engine_client --payload=file:///data/local/tmp/payload.bin`。
实测 **76 秒**装完一个 1.1 GB 的包（让设备自己走 WiFi 那次要二十多分钟）。
★ **`update_engine` 支持 `file://`** —— 在这台没有 recovery、没有 sideload
的机器上，这是最快也最可控的装机手段，值得记住。

### 方法论

⚠️ **"同时出现"不等于"因果"。** 那 25 条 msdu_done 与下载完美重合，
时间相关性非常诱人 —— 但只要多做一步"到网关 ping"和"LAN 大流量"，
结论就整个反过来了。本仓 #37 与 #40 都有同类教训：
**先把嫌疑分量隔离，再下结论。**
