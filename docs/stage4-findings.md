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
- [ ] 下次开构建机时把补丁应用进 VM 内核树
  （`~/gaokun/mainline-linux/arch/arm64/boot/dts/qcom/`），
  之后构建的 DTB 才自带修复；目前只有 ESP 上的 DTB 是打过补丁的
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
