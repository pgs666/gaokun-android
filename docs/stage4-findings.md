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
