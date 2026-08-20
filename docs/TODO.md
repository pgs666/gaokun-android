# 待办清单

最后更新：2026-08-20（v0.2.0-alpha 发布之后）

这份清单的排序原则是**用户能不能感觉到**，而不是有趣程度。每条都尽量写出
**具体的第一步** —— 没有第一步的条目只是愿望，不是待办。

状态表与公开招募项在 [`../README.md`](../README.md)；每条的证据在
[`stage4-findings.md`](stage4-findings.md) 等案卷里。

---

## A. 用户能感觉到的缺口

### A1. 音频与蓝牙长期运行后死锁 ⚠️ 最高优先
用户实机报告，我未复现、未定位（[#38](stage4-findings.md)）。
两者共用同一条到 DSP 的 QRTR/FastRPC 通路，而这条通路上**已经实测到过**
会话级卡死（使能光感会污染整个 SSC 会话）。

**第一步**：拿到复现条件（多久、什么负载、是同时死还是各自死）。
死锁当场跑 `gaokun3-qrtr-lookup`（已随镜像发布）与正常时对比服务表 ——
少了哪个服务就指向哪个 DSP。⚠️ 别把 `Handover signaled` 当崩溃证据，
那是良性噪声（#37 已用对照实验证明）。

### A2. 硬件视频解码（Venus）
现在 66 个解码器全是软解，4K 会吃力。
`refs/linux-gaokun/patch sets/media/` 里有 8 个补丁，**buildbot 没有应用**
（它 am 的 `patches/media/` 是 hi846 相机，不是 Venus）。

**第一步**：把那 8 个 `git am` 进内核树编一次，看 `/dev/video*` 出不出来。
纯内核侧，不动 ROM。

### A3. 自动亮度（环境光）
`tcs3701` 硬件在（I2C bus 5 / 0x39），但使能后从不返回读数，**而且会污染整个
SSC 会话** —— 之后连加速度计也读不到，必须重启 `hexagonrpcd`（[#37](stage4-findings.md)）。

**第一步**：从 `tcs3701.json` 读出它的 `vddio_rail` 与 `dri_irq_num`，
确认 SSC 侧那条电源/中断在主线下是否真的可用。这是"DSP 侧驱动起不来"
还是"我们缺了什么"的分水岭。

### A4. 耳机口不出声 ✅ 已修，待用户插一次耳机验收
详见 [#40](stage4-findings.md)。**三个阻塞点，全部定位并修复**，内核侧一点没缺。

1. **RX 插值器链从来没接上** —— 这是"后端打不开"的真凶。我原先只设了
   `RX_MACRO RXn MUX`，而 rx-macro 内部还有一级插值器停在默认值
   （`RX INTn_1 MIX1 INP0 = ZERO`、`RX INTn DEM MUX = NORMAL_DSM_OUT`、
   `CLSH/LO Switch = Off`）。DAPM 路径不完整 → PCM open 失败，**内核不打任何日志**。
   补齐 9 个控件后当场通：`tinyplay -D 0 -d 0` rc=0、`pcm0p` `state: RUNNING`、
   hw_ptr 2 秒前进 48960 帧/秒（实时 48 kHz）。
   ⚠️ 我为此下过的错结论（"拓扑缺 APM 图 / soundwire 没上电 / q6apm 静默失败"）
   三个候选一个都不是 —— 案卷里保留了它是怎么错的。
2. **策略里没声明耳机设备** → 已加 `WIRED_HEADPHONE` / `WIRED_HEADSET` /
   `IN_WIRED_HEADSET`（`CARD_0_DEV_0` / `_2`）。
3. **框架找的是 `/sys/class/switch/h2w`，本机 ENOENT** →
   `config_useDevInputEventForAudioJack = true`，改从 evdev 取
   `SW_HEADPHONE_INSERT`。那个 input 设备本来就在、而且已经在被读。

配方来源：救援 Ubuntu 上的上游 ALSA UCM2 —— **上游用
`Regex "HUAWEI.*MateBook E.*"` 把本机直接 include 成 ThinkPad X13s**。
★ 方法论：本机凡是 LPASS 音频的事，先去抄那个目录，别自己推 DAPM 图。

**构建前已用 overlayfs 在设备上验过**：45 个控件零失败、策略被 audioserver 接受
（三个新端口带地址出现在 `dumpsys media.audio_policy`）、扬声器无回归。
**仍需用户做的**：新 ROM 起来后插一次耳机 —— 框架资源只能构建期 overlay，
且 `WiredAccessoryManager` 在 SystemServer 启动时只读一次，框架层也没有
插拔模拟命令可用。

### A5. 恢复出厂设置不起作用
设置里那条路走 misc 的 BCB + recovery，而本机没有可用 recovery
（[#39](stage4-findings.md)）。实机证据：misc 里躺着一条没人消费的 `boot-recovery`。

**现在的替代**：从救援 Linux `mkfs.ext4 -F /dev/disk/by-partlabel/userdata`。
**真正的修法**：见 B3（EFI 加载器）或让 recovery 能启动（已搁置）。

### A6. USB-C 外接显示（UCSI）
`PPM init failed -ETIMEDOUT`，本机主线已知缺陷，`/sys/class/typec/` 是空的。
代价还包括 USB 只有 high-speed（SuperSpeed 需要 UCSI 切 orientation）。

### A7. 摄像头
完全没碰。

---

## B. 工程债与正确性

### B1. SELinux 转 enforcing
现在是 `permissive`。影响 Play Integrity 与部分带反作弊的游戏。
需要写 policy 的至少有：`hexagonrpcd`、sensors HAL、`audioroute`、`smmustall`。
logcat 里现成一串 `avc: denied` 就是清单。

**第一步**：把现有 denial 收集成 `.te`，先让 `hexagonrpcd` 与 sensors HAL 干净。

### B2. 真温控 HAL
现在是 AOSP mock（温度恒定 30.1/30.2），框架完全没有真实温控感知。
⚠️★ **换成读 `/sys/class/thermal` 的真 HAL 时必须同时改阈值** ——
mock 报的 skin/battery SHUTDOWN 阈值只有 **36 °C**，而
`ThermalManagerService.shutdownIfNeeded()` 到 SHUTDOWN 会直接
`powerManager.shutdown()`。现在因为 mock 值恒定打不到，**换真 HAL 会开机
几分钟就自动关机**。

### B3. 自研 EFI 加载器（规范化的最后一段）
读 `misc` 的 `bootloader_control` 选槽 + 解析 Android boot 镜像 +
装 initrd/DTB 协议。做完之后：
* postinstall 钩子与 ESP 上的派生文件**全部可以退役**
* BCB 能被消费 → `adb reboot recovery` 与恢复出厂设置才有可能工作
* 是 AVB/verified boot 的前提

**安全阀**：用 systemd-boot 的 `efi` 指令 chainload 它 —— 起不来就在菜单里
选别的，救援 Linux 那条路一个字节都不动。
⚠️ 这是唯一一个"写坏就要人到机器旁"的部件，别在没有安全阀的情况下动它。

### B4. LiveCD 打包
`scripts/install-gaokun3.sh` **从未端到端跑过**。它就是 LiveCD 的内核，
但没有人用它从零装过一台机器。

**第一步**：在一台可牺牲的机器（或本机，数据已备份）上真跑一次。
在那之前，"别人能装"这件事是未经验证的。

### B5. 发版流程固化成脚本
本轮踩到：`m bacon` 与 `m superimage` **分两次调用**会让 build.prop 时间戳不同，
于是 OTA 包与安装用的 super 变成两个构建、互相不认（甚至构成降级）。
正解是一次 `m bacon superimage`。

**第一步**：把发版的三步（一次构建 → 校验戳一致 → 产物先传清单最后传）
写成 `scripts/release.sh`，把这次的三项核对变成断言。

### B6. GPU SMMU 中断根治
实际 DT 是全局 672/673、context bank 从 678 起；而硬件拉的是 675/680，
其中 680 被分给 CB2、675 整张表里根本没有。很像 CB 起始偏移就错了。
⚠️ 但只凭"675/680 挂起"推不出正确映射，而且**改错了没有任何征兆**
（只是继续收不到 fault）。做成之后可以丢掉常驻的 `smmu-nostall.sh` 轮询。

### B7. 救援 Ubuntu 瘦身
现在 24.6 GiB，一个最小 rootfs 1–2 GiB 就够。刚腾出的 63.9 GiB 未分配空间
让这件事不再紧迫，但它仍是本机最胖的一块。
⚠️ 别把它换掉 —— recovery 给不了 `sgdisk`/`resize2fs`/sshd，而这轮重新分区
正是靠它远程完成的。

### B8. `invalid volume index range in the curve` ×12（既有，非回归）
每次 audioserver 启动都吐 12 条 `E APM_AudioPolicyManager: invalid volume index
range in the curve:`（后面是空的，连哪条曲线都没说）。
**确认与耳机改动无关**：干净 A/B，旧策略 12 条、新策略 12 条。
来源应在 `audio_policy_volumes.xml` / `default_volume_tables.xml`（两份都是从
`frameworks/av/services/audiopolicy/config/` 原样拷的）与本机 `devicePorts`
的交集上。目前没有可观测的功能损害，故只记不修。

**第一步**：给那条日志找出打印点（`EngineBase`/`VolumeCurve`），看它校验的是
哪个字段，再对照我们装进去的两份 XML。

---

## C. 上游或硬件层面（本地做不了）

* **待机（s2idle resume）** —— 挂得下去、醒不回来，随后整机复位。
  **Ubuntu 上同款内核完全复现** → 内核/EC 缺陷，不是 Android 的问题。
  第一步是编一个带 `CONFIG_PM_DEBUG` 的内核（现在 `/sys/power/pm_test` 不存在），
  否则无法二分。三个元凶（himax / 三个 remoteproc / EC 驱动本身）已逐个排除。
* **磁力计** —— 本机**没有这个硬件**（SSC 亲口回答），所以没有指南针、
  没有 9 轴融合。不是缺驱动。
* **指纹（FocalTech FTE7001）、TPM** —— 没有任何驱动存在。
* **出厂传感器校准** —— 存在本机 Windows 的 DriverData 里、不在任何驱动包中，
  而 Windows 已抹除 → **永久丢失**。实测无害（单位矩阵恰好与面板方向一致），
  只影响 bias 精度。⚠️ 给还留着 Windows 的人：先把那个 registry 目录拷出来。

---

## D. 运维与安全（需要你动手）

1. ⚠️★ **轮换 R2 的 S3 密钥** —— 它们在聊天记录里出现过多次。
2. ⚠️ **把 Azure NSG 的 22 端口锁到你的出口 IP** —— 构建机是静态公网 IP，
   而它曾进过 git 历史（已 filter-branch 抹掉并强推，但 GitHub 仍保留旧对象）。
3. 构建机用完立刻 `az vm deallocate` 并**取真实退出码**（`| tail` 会吞掉失败）。
   ★ 大文件传输**走 R2 中转**，不要让按分钟计费的构建机干等：
   本轮直连 1 MB/s（2.7 GB 要 45 分钟）vs 上传 R2 43 MB/s（27 秒）。

---

## E. 明确搁置（记录理由，不是忘了）

* **recovery** —— 启动即复位循环（[#39](stage4-findings.md)）。
  现阶段意义不大：sideload 被系统内 OTA 覆盖，而调试它需要人反复到机器旁
  （本机没有串口、recovery 没有网络栈、pstore 对这类失败无效）。
  真要做，**第一步是把 USB adb 在 recovery 里弄通**，那是唯一能看见内部的通道。
* **fastboot** —— bootloader 级**不可能**（固件是 UEFI，不是 fastboot 设备）。
  用户态的 `fastbootd` 住在 recovery 的 ramdisk 里，所以随 recovery 一起搁置。
* **GMS / Play 商店** —— 用户未提出需求。
* **突破原神 1080×1728 的渲染上限** —— 那是游戏按**设备白名单**给的档位，
  不是本机的技术限制。要突破只能伪装机型，**有账号风险**，留给用户决定。
