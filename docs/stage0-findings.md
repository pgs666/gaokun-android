# Stage 0 — 从参考树核实的事实

采集日期：2026-08-13
方法：`refs/` 下本地 checkout 直接 grep。每条都带来源。**没有一条来自记忆。**

未经实机验证的条目标注为 `[待实机确认]`——这些是上游文档的说法，
按 CLAUDE.md 规则 #3，与 dmesg / 实际观察冲突时以实机为准。

---

## 1. 最重要的一条：内核基线应该是主线 7.1+，不是 jhovold 6.16

`refs/linux-gaokun/README.MD:17-23` 的上游进度表：

| 功能 | 进入主线的版本 | 状态 |
|---|---|---|
| 初始 device tree | 6.14 | landed |
| EC | 6.15 | landed |
| UCSI | 6.16 | landed |
| **DSI 面板** | **7.1** | **landed** |

在本地树上验证过（不是照抄 README）：

- `refs/jhovold-linux` @ `wip/sc8280xp-6.16`（Makefile: VERSION=6 PATCHLEVEL=16）
  - **有** `drivers/platform/arm64/huawei-gaokun-ec.c`
  - **有** `arch/arm64/boot/dts/qcom/sc8280xp-huawei-gaokun3.dts`
  - **没有** hx83121a 面板驱动。`drivers/gpu/drm/panel/` 下的 himax 只有
    `hx8279` / `hx83102` / `hx83112a` / `hx8394`。

- 主线当前 tag：**v7.2-rc7**（`git ls-remote https://github.com/torvalds/linux`，2026-08-13）
  → v7.1 已发布，面板已在主线内。

**结论：** CLAUDE.md 把 `refs/jhovold-linux` 列为"sc8280xp 事实标准内核树"在
2025 年成立，现在过时了。jhovold 树最后推送 2025-09-19，停在 6.16。
Stage 0/1 的内核基线应该用 **mainline 7.1 或 7.2**，四大件（DT/EC/UCSI/面板）
全部开箱即用。jhovold 树留着做历史对照有价值，做基线没有。

**待做：** CLAUDE.md 第 42 行「EC 主线驱动 6.15 进；UCSI 6.16」应补上
「DSI 面板 7.1 进」；第 80 行对 jhovold 的定位需要改。

---

## 2. 主线之外仍需的补丁

`refs/linux-gaokun/patch sets/recommended/` —— 24 个补丁，维护到 **2026-06-14**
（仓库 HEAD：`f6b55e5` "patch: force to use GPI DMA for spi touchscreen"）。
补丁日期分布 2024-07 ~ 2026-06，多数是 2026 年的，说明是活跃维护的集合。

按 `refs/linux-gaokun/README.MD:31`：**「Use mainline with recommended patches」**
—— 作者自己就是这个用法，佐证了上面第 1 条。

分类（文件名即依据，`refs/linux-gaokun/patch sets/`）：

| 目录 | 数量 | 用途 | Stage |
|---|---|---|---|
| `recommended/` | 24 | 主线之上的必需补丁 | 0/1 |
| `el2/` | 24 | EL2/KVM 启动流程（smp2p / remoteproc / SCM）| 见第 6 条 |
| `media/` | 8 | Venus 硬解（sc8280xp resource struct + DT）| 5 |
| `freq_scaling/` | 2 | CPU interconnect + DDR/LLCC OPP | 5 |
| `negligible/` | 2 | 可忽略 | — |
| `experimental/` | 1 | EC wakeup source | — |
| `for-myself/` | 4 | 作者调试用（regulator dump）| — |

`recommended/` 里和我们各阶段直接相关的：

- 显示：`0004`(dsi nodes) `0005`(MDSS interconnect) `0007`(**HX83121A 面板驱动**)
  `0008`/`0009`(dispcc) `0010`/`0011`(DPU DSC/widebus 截断修复)
  `00013`(bonded dsi pclk) `0014`(link clock toggles) `0019`(dsi1_phy 顺序)
- EC/电源：`0012`(**suspend/resume 修复**) `0015`(battery _STA) `0016`(EC enable)
  `0024`(UCSI mode switching)
- 触摸：`0018`(**HACK**: gpio175 不映射到 pdc) `0025`(SPI 强制 GSI 模式)
- 其他：`0001`(ADSP FastRPC) `0002`(audio 内存区) `0017`(pdc map)

注意 `0007` 面板驱动仍在 `recommended/` 里，但日期是 2026-03-03，早于 7.1 发布。
**[待实机确认]** 用 7.1+ 主线时这个补丁是否还需要打——很可能已被上游版本取代，
要比对主线里的 `drivers/gpu/drm/panel/` 实际内容。

---

## 3. 内核命令行

`refs/linux-gaokun/README.MD:33`：

```
clk_ignore_unused pd_ignore_unused arm64.nopauth efi=noruntime
```

Stage 2 配引导链时这四个参数要带上。`arm64.nopauth` 和 `efi=noruntime` 尤其
不能漏——**[待实机确认]** 但这是上游明确给出的。

---

## 4. 触摸屏：SPI vs I2C 的答案已经有了

CLAUDE.md 第 111 行把「触摸屏走 SPI 还是 I2C」列为 Stage 0 待采集项。
`refs/linux-gaokun/README.MD:191-212` 已经给出完整拓扑：

- 级联 IC 位于 **i2c4 的 @0x48 和 @0x49**，对应 HID 接口 **@0x4f 和 @0x50**
- @0x48 + @0x4f = 触摸屏；@0x49 + @0x50 疑似手写笔
- **gpio174 决定传输模式**：拉低 → SPI 侧激活；拉高 → I2C HID(@0x4f) 激活。
  只有拉高时 i2c4 上才会出现这些 HID 接口。
- **gpio99** = 触摸复位，**gpio38** = 显示复位（会内部触发触摸复位），
  **gpio175** = 触摸中断
- 关键时序：**gpio174 必须在固件重载之前设置**（复位会自动触发重载）。
  之后再改 gpio174 是安全的。

状态（`README.MD:69-70`）：I2C HID = partial（滑动时间歇失灵，
与 CLAUDE.md 第 116 行「已知坑」一致）；**SPI = works**。

→ **走 SPI。** 这条不需要再花 Stage 0 的时间去测，只需实机确认 gpio 编号一致。

`refs/linux-gaokun/README.MD:222-238` 还列了触摸固件版本表（按面板厂
BOE / CSOT 分三套）。面板厂不同固件不同，**[待实机确认]** 本机是哪一套：

```
i2ctransfer -y 4 w5@0x48 0x00 0x00 0x15 0x02 0x00
i2ctransfer -y 4 w2@0x48 0x0c 0x00
i2ctransfer -y 4 w1@0x48 0x08 r2@0x48
```

或在 Windows 侧读 `C:\ProgramData\Huawei\HuaweiTHP\hx_hal_log_*`。
**本机 A 还在 Windows 上，这条现在就能查。**

---

## 5. 音频：Stage 4 的捷径比预想的更短

`refs/linux-gaokun/README.MD:119-121`：本机直接复用 **X13s 的 UCM 配置**。

```
ln -sf ../../Qualcomm/sc8280xp/LENOVO-X13s.conf \
       /usr/share/alsa/ucm2/conf.d/sc8280xp/HUAWEI-GK_W7X-M1010-GK_W7X_PCB.conf
```

两个收获：

1. **ALSA machine 名 = `HUAWEI-GK_W7X-M1010-GK_W7X_PCB`**
   （CLAUDE.md 第 38 行留空的型号，这里有个强候选：**GK-W7X-M1010**。
   **[待实机确认]** 以机身背面 / DMI 为准。）
2. Stage 4 要翻译成 `mixer_paths.xml` 的源文件是 **`LENOVO-X13s.conf`**，
   不是某个华为专有配置。X13s 是 sc8280xp 上文档最全的机器，这是好消息。

采集脚本的 UCM2 过滤已经把 `*Lenovo*` 和 `*sc8280*` 都包含在内。

---

## 6. EL2 / KVM 不是免费的 —— 影响 CLAUDE.md 的止损方案

CLAUDE.md 第 45 行写「虚拟化 KVM/EL2 可用」，第 126 行把 Cuttlefish 当作
Stage 3 卡死时的止损方案。但 `refs/linux-gaokun/README.MD:319-331` 说明
EL2 需要一整套非默认的引导流程：

- 用 [`slbounce`](https://github.com/TravMurav/slbounce) 在 `ExitBootServices()` 切进 EL2
- 用 [`qebspil`](https://github.com/stephan-gh/qebspil) 在 Linux 启动前预启 DSP
- 打 `patch sets/el2/` 那 24 个补丁（否则 DSP/remoteproc 相关功能，比如音频，在 EL2 下不工作）
- EFI 路径下放好固件和**一个足够旧的可用 `tcblaunch.exe`**
- 用 EL2 专用设备树 `sc8280xp-huawei-gaokun3-el2.dtb` 启动

**结论：** Cuttlefish 止损方案的前置成本 ≈ 一个完整的子项目。
它不是"Stage 3 卡住就退回去"的轻量选项。真要留作后路，EL2 引导流程
得在 Stage 0/1 期间就顺带验证，不能等到 Stage 3 卡住才开始弄。

---

## 7. WiFi 校准数据

`refs/linux-gaokun/README.MD:332-369`：

- ath11k board file 里本机的 variant 是 **`HW_GK3`**
- 主线 linux-firmware 的 `ath11k/WCN6855/hw2.0/board-2.bin` 里**没有**本机条目，
  需要用 [`ath11k-bdencoder`](https://github.com/qca/qca-swiss-army-knife) 解包，
  把 `HW_GK3` 指向 X13s 的校准数据（`...qmi-board-id=140,variant=LE_X13S.bin`），再打包回去
- 华为对**每台机器单独校准**，原始 board file 在 BIOS 第 12 分区
  （偏移 0x1000，大小 0xea04）。但作者实测 **X13s 的校准数据信号更好**，
  且单机校准只在下游 2.0 固件下生效。→ **直接用 X13s 的，别折腾单机校准。**

`refs/matebook-e-go-linux/docs/WIFI_CALIBRATION_DTBO.md` 和
`device-tree/sc8280xp-huawei-gaokun3-calibration*.dtso` 提供了 DTBO 方式的替代做法。

---

## 8. 其他已核实的硬件细节

来源 `refs/linux-gaokun/README.MD`：

| 项 | 事实 | 行号 |
|---|---|---|
| 背光 | 走 **DCS**（不是 PWM，不是 I2C）| 123-125 |
| EC 位置 | **i2c-15，地址 0x38**（由 fn_lock sysfs 路径推出）| 267 |
| EC 热传感器 | 20 路，`gaokun_ec_hwmon-i2c-15-38` | 272-281 |
| 电池控制 | `/sys/class/power_supply/gaokun-ec-battery/*` | 48, 132-154 |
| GPU | Freedreno **690**，`vulkan-freedreno` | 57 |
| 指纹 | FTE7001，**gpio185**，不支持 | 56 |
| 休眠 | **untested**，不是"不支持" | 58 |
| 前摄 | hi846@0x20 (2022) / s5k4h7@0x2d (2023) | 158 |
| 后摄 | s5k3l6@0x10 (2022) | 160 |
| Venus 硬解 | 走 `v4l2m2m`，编码不可用 | 302-317 |
| USB-PD | 45W+ 快充，需 UCSI EC 驱动 | 73 |
| 悬空风险 | **UCSI 有 bug，开机前插 Type-C 可能导致自动重启** | 86-87 |

最后一条对日常操作有影响：**调试时先开机再插 Type-C。**

CLAUDE.md 第 46 行「已知不支持：指纹、TPM、休眠」——休眠应改为「未测试」。

---

## 9. `refs/matebook-e-go-linux` 里的高价值素材

这个树 4 天前才更新（2026-08-09），是最活跃的源。内含：

- `device-tree/sc8280xp-huawei-gaokun3.dts` + **预编译好的 `.dtb`**
- `device-tree/sc8280xp-huawei-gaokun3-calibration*.dtso` —— WiFi 校准 DTBO
- `docs/acpi/DSDT_216.dsl` / `DSDT_217.dsl` —— **反编译的 DSDT**。
  README 提到「DSDT 里 gpio174 决定传输模式」，原始依据就在这。
- `docs/uefi_extracted/{216,217}/` —— UEFI DXE 模块二进制：
  `DisplayDxe` `TouchPanelInit` `GpioConfigDxe` `I2cTouchPanel` `SPI` `I2C`
  → 面板上电时序和触摸初始化序列的最终依据
- `boot/grub.cfg` + `boot/mkinitcpio.conf` —— Stage 2 引导链的直接参考
- 大量触摸调研文档（`TOUCHSCREEN.md`、`TOUCH_COORDINATE_MAPPING.md`、
  `UEFI_FIRMWARE_TOUCH_ANALYSIS_2026-02-11.md` 等）

**注意：** 193 MB 里绝大部分是 git-lfs 管的 `*.exe`（`.gitattributes`），
是固件更新工具，不是内核素材。

---

## 10. 仍然只能靠实机采集的

上面解决了 CLAUDE.md Stage 0 清单里的「触摸屏走 SPI 还是 I2C」和
大半个「ALSA UCM2」。剩下必须上机器的：

- [ ] `.config` 实际值（QCOM / ath11k / hid 相关项）
- [ ] `dmesg | grep -i firmware` 的完整固件加载路径 ← **Stage 2 打包 vendor 分区的依据**
- [ ] `modetest` 完整输出：connector 名、plane 数量、**format 和 modifier**
      ← Stage 3 配 minigbm 的关键，没有替代来源
- [ ] evdev 名 + evtest 输出（触摸/键盘/触控板）
- [ ] `vulkaninfo` 认出 a690
- [ ] **pstore/ramoops 是否真的配好了**
- [ ] 分区表的 PARTLABEL（fstab 要用）
- [ ] 本机触摸固件版本（BOE / CSOT，见第 4 条）
- [ ] 本机确切型号（第 5 条的 GK-W7X-M1010 待证）

→ 这些正是 `scripts/collect-hw-inventory.sh` 采集的内容。

---

## 11. 第三方触摸驱动：存在两套，别搞混

追查 `refs/matebook-e-go-linux/README.md:253-270` 的线索后新克隆了三个仓库。
结论是**同时存在两个 SPI 触摸驱动**，能力差一个数量级：

| | A：基础驱动 | B：算法驱动 |
|---|---|---|
| 位置 | `refs/linux-gaokun/touchscreen-hx83121a-dkms/himax-spi.c` | `refs/egotouchrev-linux/touchscreen-hx83121a-dkms/` |
| 规模 | 1199 行，单文件 | 2802 行，三文件拆分 |
| 组成 | SPI 通信 / 固件初始化 / 电源管理 / panel follower | `himax-spi-core.c`(1478) + `hx-algo.c`(1133) + `hx-algo.h`(191) |
| 作者 | Pengyu Luo（`MODULE_AUTHOR`）| core 同左；**算法部分见下方警告** |
| 上游来源 | `TheUnknownThing/linux-gaokun` | `chiyuki0325/EGoTouchRev-Linux` |

B 在 A 之上加了一整条触摸处理流水线（`refs/egotouchrev-linux/README.md:30-53`），
算法移植自 Windows 用户态驱动 `awarson2233/EGoTouchRev`：

```
Phase 1 预处理   基线减除 → CMF 共模滤波（抗充电器噪声）→ GridIIR 时域滤波
Phase 2 触点求解 8-连通 BFS 宏区域 → 掌压抑制 → 非对称峰值检测 → Q8.8 加权质心
Phase 3 跟踪     贪心距离匹配 + 速度预测 → input_mt 上报
```

**buildbot 用的是 B。** `refs/gaokun-buildbot/drivers/touchscreen-hx83121a/` 下三个文件与
`refs/egotouchrev-linux/` 的**逐字节相同**（已 diff 验证），以
`patches/others/0003-Input-touchscreen-add-Himax-HX83121A-SPI-driver.patch` 形式打进内核。
EGoTouchRev-Linux 最后推送 2026-04-08，buildbot 2026-07-11，三个月无变化 → 驱动已稳定。

> ⚠️ **必须知道的前提**：`refs/egotouchrev-linux/README.md:9-10` 原文：
> 「本驱动代码完全由 Claude Opus 4.6 大模型进行编写，不提供任何可用性保证。」
> `README.md:188` 再次说明 `hx-algo.c/h` 由模型编写，人类作者只做了算法参考对照。
>
> 这是一个跑在 IRQ 上下文的内核模块，且未经上游 review。它已经被 buildbot 用于
> 发布镜像、也被上游 README 推荐，说明实际能用；但**它不是主线代码**，
> Stage 4 出现触摸异常时，这里是第一嫌疑人，不要默认它是对的。

### 对 Stage 5（手游）的直接价值

CLAUDE.md 第 101 行 Stage 5 的验收是「目标游戏能启动并稳定运行」，
触摸是手游唯一的输入通路。驱动自带**游戏模式**
（`refs/egotouchrev-linux/README.md:152-156`）：关闭轨迹平滑、禁用起始防抖、
启用跳点检测——正是手游需要的低延迟取向，日用模式反而要平滑。

调参走 sysfs（`README.md:94-142`，约 20 个可调项，含 `peak_threshold`、
`palm_area_threshold`、`track_dist2_max`、`debounce_base` 等）。

**Android 移植注意：** 上游配的是 Tkinter 图形调参工具（`tuner/tune.py`），
Android 上没有。这些 sysfs 节点要改成开机由 `init.rc` 的 `write` 指令设置，
或做成 vendor property。Stage 4 配输入时一并处理。

---

## 12. buildbot 有现成镜像 —— 直接改变 Stage 0 的起步方式

`KawaiiHachimi/linux-gaokun-buildbot`（→ `refs/gaokun-buildbot/`）
是 gaokun3 的 CI 构建流水线，**发布可直接刷的整盘镜像**。
Ego 目前只有 Windows，这意味着不需要先自己编内核。

GitHub Releases（API 查询，2026-08-13）：

| 发布 | 内容 | 大小 |
|---|---|---|
| `ubuntu26.04-7.1.0-rc3-gaokun3+-el2-20260514` | `ubuntu-26.04-gaokun3.img.zst` | 1365 MB |
| `fedora44-7.1.0-rc3-gaokun3+-el2-20260514` | `fedora-44-gaokun3.img.zst` | 1566 MB |
| `gaokun3-debs-v7.1-rc3-std-el2-20260514` | 内核 deb（标准版 + **el2 版**）| — |
| `gaokun3-rpms-v7.1-rc3-std-el2-20260514` | 内核 rpm（标准版 + **el2 版**）| — |

两点很重要：

1. **内核版本 `7.1.0-rc3-gaokun3+`** —— 独立佐证了本文第 1 条：基线是 7.1，不是 jhovold 6.16。
2. **EL2 版内核已经预编译好了。** 本文第 6 条说 EL2 成本高，这条把成本砍掉一大截：
   `patches/el2/` 那 22 个补丁 buildbot 已经打好并出包。仍需自己搞定的是
   slbounce / qebspil / tcblaunch.exe 那套引导流程，但内核侧不用管了。
   → Cuttlefish 止损方案重新变得可行，值得在 Stage 0/1 期间顺手验证。

### ⚠️ 这批镜像有已知的 WiFi 缺陷

`refs/matebook-e-go-linux/README.md:205-207` 明确点名：

> images built from `linux-gaokun-buildbot` between **2026-03-20 and 2026-07-11** shipped a
> device tree asking for `NTM_TW220` alongside a `board-2.bin` that did not contain it,
> so they are affected regardless of anything done locally.

上表镜像发布于 **2026-05-14，正落在这个区间内**。症状是 WiFi 每约 40 秒重新协商一次，
内核日志出现 `deauthenticated ... Reason: 34=DISASSOC_LOW_ACK`。

自检与修复：

```bash
strings /lib/firmware/ath11k/WCN6855/hw2.0/board-2.bin | grep -c NTM_TW220
# 返回 0 = 固件太旧，从 linux-firmware 更新 board-2.bin
```

注意这与本文第 7 条有冲突：linux-gaokun README 说用 `HW_GK3`，
matebook README（2026-08-09 更新）说上游现在请求 `NTM_TW220`，且
**「which of the two variants is correct for this device has not been re-verified」**。
→ **[待实机确认]** 两个 variant 哪个对，上游自己也没定论。实机上试。

### buildbot 里另外两样直接有用的

- **`defconfig/gaokun3_defconfig`**（12 KB）—— Stage 1「内核转 Android 配置」的起点。
  在一个已知能点屏能联网的 config 上加 Android 项，比从 `defconfig` 白手起家安全得多。
- **`patches/`** 分类比 linux-gaokun 更清晰：`upstream/`(13) `others/`(6) `el2/`(22) `media/`(6)
  ——其中 `others/0002-drm-panel-himax-hx83121a-enable-DSC-by-default.patch` 和
  `others/0006-...add-backlight-regulator.patch` 是 linux-gaokun 的 `recommended/` 里没有的。

其他分支：`el2` `systemd-boot` `ubuntu` `bls` `feature/venus-sc8280xp`。
`systemd-boot` 分支对 Stage 2 引导链可能比 GRUB 路线更合适，待评估。

---

## 13. 参考树清单（更新）

`scripts/clone-refs.sh` 现在克隆 11 个树。新增的三个：

```
refs/egotouchrev-linux/     chiyuki0325/EGoTouchRev-Linux        算法触摸驱动（见第 11 条）
refs/gaokun-buildbot/       KawaiiHachimi/linux-gaokun-buildbot  CI 镜像 + defconfig + 补丁（第 12 条）
refs/egotouchrev-rebuild/   awarson2233/EGoTouchRev-rebuild      Windows 用户态驱动，算法原始出处
```

`egotouchrev-rebuild` 是 Windows 侧的 C++ 工程（`Common/DVRCore`、`IPCCore`、imgui），
是 `hx-algo.c` 算法的**原始参考实现**。Stage 4/5 调触摸算法遇到疑问时，
这里是比 AI 重写版更权威的依据。
