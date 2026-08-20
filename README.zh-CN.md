# 华为 MateBook E Go 跑 Android（SC8280XP / `gaokun3`）

**crDroid 16.0（Android 16），跑在主线 Linux 内核上，Adreno 690 硬件 Vulkan。**

高通从来没给 8cx 系列发过 Android BSP，只有 Windows 和 Linux 驱动。所以这里
没有可以扒 vendor blob 的原厂 ROM，没有 `fastboot`，没有 A/B 槽位，没有
recovery 分区，也没有串口。这不是一次常规移植 —— 它是 **AOSP on mainline**，
每一个 HAL 都建在上游驱动之上。

> ### ⚠️ Alpha 阶段，先读这段
> 游戏跑得不错。**但这台机器不能待机** —— 见[已知问题](#已知问题)。
> 安装会**清空内置硬盘**。你需要有能力救一台开不了机的机器。不提供任何担保。

[**English → README.md**](README.md)

**交流：**[Telegram](https://t.me/gaokunAndroid) · QQ 群 **920133252**

---

## 现状

下面每一条都是实机测出来的，不是推断。证据在 [`docs/`](docs/) 里。

| 项目 | 状态 | 说明 |
|---|:--:|---|
| 引导（UEFI + systemd-boot，内置盘） | ✅ | 不需要 U 盘 |
| 屏幕 1600×2560 @ 120 Hz | ✅ | 框架默认值把渲染钉在 60，已覆盖；实测 vsync 周期 8.33 ms |
| GPU —— Adreno 690 硬件 Vulkan | ✅ | Mesa 26.0.3 `turnip`；22 分钟浸泡零 SMMU fault |
| 触摸屏 | ✅ | Himax HX83121A；需要 `patches/` 里的 gpio174 补丁 |
| 磁吸键盘 + 触控板 | ✅ | USB HID `12d1:10b8` |
| Wi-Fi | ✅ | ath11k / WCN6855 |
| 蓝牙 | ✅ | `hci_qca`，adapter `ON`，零崩溃 |
| 扬声器 | ✅ | 用户实机确认；WSA883x 走 audioreach |
| 耳机口 / 麦克风 | ❓ | 插拔检测和 15 个 HPH 控件都在，**未实测** |
| 电池、充电、合盖检测 | ✅ | 华为 EC 驱动 |
| **游戏** | ✅ | 原神画质极高流畅。GPU 空闲 270 MHz、峰值 690 MHz、最高 50 °C |
| CPU 温控降频 | ✅ | 主线 DTS **根本没有** CPU 的 cooling map —— 已由 [`patches/0009`](patches/) 在设备树里根治 |
| **待机 / 挂起** | ❌ | s2idle **挂得下去、醒不回来**，随后整机复位。内核/EC 缺陷 —— Ubuntu 下同样复现 |
| 传感器（加速度计、光感） | ⚠️ | 加速度计在主线上**确实能读**—— 已在本机经 SLPI DSP 实测通过（静止时 Z≈9.87 m/s²）。但 Android 侧还没有 HAL，**所以 Android 里暂时仍无自动旋转**。光感是另一回事：一使能就会污染整个 DSP 会话 |
| 硬件视频解码 | ❌ | Venus 未启用；66 个编解码器全是软解 |
| 摄像头 | ❌ | 没开始 |
| USB-C 外接显示 / UCSI | ❌ | UCSI PPM 初始化超时，本机主线的已知缺陷 |
| 指纹、TPM | ❌ | 没有驱动 |
| SELinux | ⚠️ | `permissive` |

### 两件反直觉的事

**主线设备树里原先完全没有 CPU 温控。** `sc8280xp.dtsi` 里总共只有一处
`cooling-maps`，在 `gpu-thermal` 下面。每个 CPU 温区只有一条 110 °C 的
*critical* trip，别的什么都没有 —— CPU 会一路满频跑到内核紧急关机，
中间**没有任何渐进降频**。这台是被动散热的无风扇平板，长时间游戏真的撞得到。

[`patches/0009`](patches/) 在设备树里把它修好了：8 个 per-core 温区各加一条
85 °C 的 passive trip，绑到本簇的 cpufreq cooling device。同一台机器只换 DTB
的实测对比：每个温区绑定的 cooling device 从 0 变 1、trip 点从 1 变 2。
**这个缺口不是本机特有的** —— 任何跑主线的 sc8280xp 机器都值得看一眼。

**待机是在 Android 之下坏掉的。** 机器挂得下去，醒不回来，大约 13 秒后整机复位。
RTC 闹钟**确实按时触发**，所以坏在 *resume* 而不是 suspend。已用实验排除：
himax 触摸驱动、三个 remoteproc、以及 **EC 驱动本身**。两个自称修这个毛病的
上游 EC 补丁**其实一直都打着**。**在 Ubuntu 上用同一棵内核复现得一模一样**，
所以既不是 Android 的问题，也不是我们设备树的问题。因此默认持有一个 wakelock，
但息屏是正常的。将来复测的逃生口：`setprop persist.gaokun3.allow_suspend 1`。

---

## 硬件

| | |
|---|---|
| SoC | 高通骁龙 8cx Gen 3（SC8280XP） |
| 型号 | HUAWEI GK-W7X，2022 款，CSOT 面板 |
| **BIOS** | **2.16 —— 不要升到 2.17。** 两版的触摸 SPI 总线和 GPIO 编号完全不同，上游驱动是按 2.16 开发的 |
| GPU | Adreno 690 |
| 屏幕 | Himax HX83121A，MIPI-DSI，1600×2560 —— 与 Galaxy Tab S7 FE 同款面板 |
| Wi-Fi / 蓝牙 | WCN6855 |
| 存储 | NVMe |
| 固件 | UEFI，必须关闭 Secure Boot |

---

## 安装

从 [**Releases**](../../releases) 取最新版，按
[`docs/INSTALL.md`](docs/INSTALL.md) 操作。

安装会**清空内置硬盘**。它建出来的布局：

| 分区 | 大小 | 用途 |
|---|---|---|
| ESP | 300 MiB | systemd-boot、内核、ramdisk |
| `userdata` | 剩余全部 | `/data` |
| `super` | 12 GiB | system / system_ext / product / vendor |
| `metadata` | 32 MiB | |
| 救援系统 | 约 25 GiB | 一个完整的 Ubuntu，可 SSH |

最后那个分区是**故意留的**。这台机器没有 recovery 分区、没有串口，所以一个
普通的 Linux 安装**就是** recovery 环境。它是默认启动项 —— 于是 Android 挂死时，
拍一下电源键就回到一个能 SSH 进去远程修的系统，**人不用在机器旁边**。

---

## 构建

需要一台 Linux，约 16 GB 内存、400 GB 磁盘。

```sh
repo init -u https://github.com/crdroidandroid/android.git -b 16.0
# 把 manifests/local_manifest_gaokun3.xml 放进 .repo/local_manifests/
repo sync -c -j"$(nproc)"

python3 scripts/crdroid-tree-fixes.py <树路径>     # 为什么要改，脚本里写了
source build/envsetup.sh
lunch lineage_gaokun3-bp4a-userdebug
m
m superimage
```

华为专有固件**不在**本仓库里。获取方法见
[`device/huawei/gaokun3/firmware/README.md`](device/huawei/gaokun3/firmware/README.md)
—— 从你自己的机器上取。

内核单独构建，来自
[`linux-gaokun-buildbot`](https://github.com/KawaiiHachimi/linux-gaokun-buildbot)。
Android 相关的配置断言在
[`scripts/kernel-config-android.sh`](scripts/kernel-config-android.sh)，
额外补丁在 [`patches/`](patches/)。

---

## 仓库结构

| 路径 | 内容 |
|---|---|
| `device/huawei/gaokun3/` | 设备树 |
| `patches/` | 未进上游的内核与 Mesa 补丁 |
| `scripts/` | 构建、部署、取证、安装工具 |
| `docs/` | **工程案卷。** 每一条结论都带证据 |
| `manifests/` | `repo` local manifest |

`docs/` 不是附属品。这个平台的任何信息都不存在于任何 wiki、也不在任何模型的
训练数据里，所以那些 findings 文件本身就是主要产出：它们记录了测到了什么、
哪些判断后来被证明是错的、哪些早先的结论被推翻了。**被推翻的有好几条。**

---

## 已知问题

| 问题 | 位置 |
|---|---|
| s2idle 醒不回来，整机复位 | [`docs/stage6-crdroid.md`](docs/stage6-crdroid.md) §M4 |
| 传感器：Linux 侧加速度计已能正确读数，但 Android 侧尚无 HAL；使能光感会弄坏 DSP 会话（#37） | [`docs/stage4-findings.md`](docs/stage4-findings.md) |
| 拔插 USB 后 adb 不重枚举，用 adb over TCP 兜底（#27） | [`docs/stage4-findings.md`](docs/stage4-findings.md) |
| GPU SMMU 拉的是 SPI 675/680，而 DT 声明 678/679 | [`docs/stage5-freedreno.md`](docs/stage5-freedreno.md) D6 |
| 热管理 HAL 是 AOSP mock，它的 SHUTDOWN 阈值只有 36 °C | [`docs/stage6-crdroid.md`](docs/stage6-crdroid.md) §M4 |

---

## 招人 / Help wanted

都是边界清楚的活，大致由易到难：

1. **硬件视频解码。** `refs/linux-gaokun/patch sets/media/` 里有 8 个 Venus
   补丁，buildbot **没有**应用。现在 66 个编解码器全是软解。
2. **GPU SMMU 中断修复。** SMMU 拉的是 SPI 675/680，设备树声明的是 678/679，
   所以 context fault 永远到不了 CPU。改 DTB 应该就能彻底丢掉
   `smmu-nostall.sh` 那个轮询 workaround。
3. **写一个真的热管理 HAL**，读 `/sys/class/thermal`。⚠️ **必须同时把 SHUTDOWN
   阈值改掉** —— AOSP mock 报的是 36 °C，`ThermalManagerService` 看到就会
   直接关机。
4. **SELinux 转 enforcing。** 有两个服务需要写策略。
5. **s2idle 的 resume。** 要先编一个带 `CONFIG_PM_DEBUG` 的内核才能二分
   （现在的配置里没有 `/sys/power/pm_test`）。多半是上游内核/EC 的活。
6. **传感器 —— 难的那一半已经做完了。** 加速度计现在能在本机经 SLPI DSP
   正确读数（`hexagonrpcd` + `libssc`，
   [`scripts/slpi-sensors-setup.sh`](scripts/slpi-sensors-setup.sh) 能一键复现）。
   据我们所知，**其他 SC8280XP 设备都没有跑通过这一套**，ThinkPad X13s 也没有。
   缺的是 **Android 侧**。`hexagonrpcd` **已经能在 Android 上构建并运行**，
   SSC 服务也已在 QRTR 上就绪 —— 剩下的是一个 QMI/protobuf 客户端，
   再包成 AIDL `android.hardware.sensors` HAL。libssc 本身搬不过来
   （它拖着 glib/gobject/libqmi），所以协议要重写 —— 而**协议已经替你写清楚了**，
   连字节布局和消息 ID 都有：
   [`docs/sensors-ssc-protocol.md`](docs/sensors-ssc-protocol.md)。
   **就靠这一块活，自动旋转就能落地。**
7. **摄像头。** 完全没碰。

如果你手上有 MateBook E Go 想帮忙测，欢迎开 issue —— **报告哪里坏了和交补丁
一样有用**。请附上你的 BIOS 版本和 SKU。

---

## 社区

| | |
|---|---|
| **Telegram** | [t.me/gaokunAndroid](https://t.me/gaokunAndroid) |
| **QQ 群** | **920133252** |
| Issues | [GitHub issues](../../issues) —— 需要留痕的事走这里 |

群里适合问"这样是不是正常的"；**只要能复现，就开个 issue**，
否则聊天记录一刷就没了。

---

## 致谢

* **gaokun Linux 社区** ——
  [linux-gaokun](https://github.com/right-0903/linux-gaokun)、
  [linux-gaokun-buildbot](https://github.com/KawaiiHachimi/linux-gaokun-buildbot)、
  [EGoTouchRev](https://github.com/chiyuki0325/EGoTouchRev-Linux)
  —— 内核、EC 驱动、触摸逆向，这个移植是站在他们肩上的。
* **[aospm](https://github.com/aospm)**，让人看到"AOSP 跑在主线内核上"这条路
  本身是走得通的。
* **Johan Hovold** 以及所有把 SC8280XP 支持推上主线的人。
* **crDroid** 与 **LineageOS**。
* **Mesa** —— `freedreno` 和 `turnip`。

## 许可

Apache License 2.0，见 [`LICENSE`](LICENSE) 与 [`NOTICE`](NOTICE)。
`patches/` 下针对 Linux 内核的补丁按衍生作品适用 GPL-2.0-only；
Mesa 补丁沿用上游的 MIT。
