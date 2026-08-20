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
后果：加速度计能用，但轴向可能需要在上层手动纠正（自动旋转方向可能颠倒），
且没有出厂 bias 补偿。⚠️ **给后人**：还留着 Windows 的机器，
**先把那个 registry 目录拷出来再装系统。**

#### 落地路线更新

| 步骤 | 状态 |
|---|---|
| `hexagonrpcd`（打 `\r` 截断补丁后自编） | ✅ **已通**（apt 版不带补丁；注意要连 `libhexagonrpc.so` 一起装 + `ldconfig`） |
| `libssc` + `ssccli` | ✅ **已通**（⚠️ 上游已删掉 `-Dmocking` 选项，照指南写会报 "Unknown option"） |
| **加速度计读数** | ✅ **已通**，Z≈9.87 |
| 光感读数 | ❌ 使能即污染会话，未解 |
| 出厂校准 / 安装矩阵 | ❌ 随 Windows 永久丢失 |
| **Android 侧 sensors HAL** | ⬜ 仍不存在 —— 这是把"自动旋转"真正交付给用户前唯一剩下的工程量 |

⚠️ 另有两个环境坑（都会浪费大量时间）：
* `droid-juicer` 会**无限 `openat("/usr/share/droid-juicer/configs")` 死循环**
  （0.4.2 的 bug，`strace` 当场看到），把 apt 卡住 43 分钟。→ `systemctl mask`。
* `initramfs-tools` 的 postinst 在本机**必然失败**
  （`/etc/initramfs/post-update.d/systemd-boot` 返回 1，因为我们的 ESP 布局是自定义的）
  → initramfs 的改动不会自动传播，别以为装完就生效了。
