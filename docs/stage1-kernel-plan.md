# Stage 0 收尾 + Stage 1 合并：内核构建方案

> 基于 2026-08-13 实机 Stage 0 采集结果（`docs/hw-inventory.md`）。
> 决策：合并。pstore 和 dwc3 都要重编内核，binderfs 已就绪，分两次没意义。
>
> 本文中标 ✅ 的是**已从实机或源码核实**的事实；标 ⚠️ 的是仍需实测的未知数。

---

## 〇、当前形态：全系统跑在 U 盘上

这是本次所有操作的安全边界，也是风险评估的前提：

```
/dev/sda (SanDisk 114.6G, USB)
├─ sda1  1G  vfat  → /boot/efi     (ESP，systemd-boot + BLS + dtb)
└─ sda2  11G ext4  → /             (rootfs，剩余约 5.8G)

内置 nvme0n1 476.9G —— 一个字节都没动，Windows 完好
```

**含义：**

1. **不存在变砖风险。** 内核 panic、dtb 改废、启动项写坏——最坏结果是重做 U 盘，
   内置盘和 Windows 不受影响。方案里所有"中风险"步骤实际都是低风险。
2. **但 rootfs 只剩 5.8G** —— 够装新内核（约 300–500 MB），
   **不够在机器上编内核**。构建必须在别的机器上做。
3. **U 盘本身插在一个 Type-C 口上** —— 见第五节，这是唯一真正要小心的地方。

---

## 一、先把调试通道建起来

现状：**没有串口，没有 UDC**。这是当前唯一的存亡级问题。
不要指望单一通道，建三条覆盖不同失败时段。

| 通道 | 覆盖时段 | 成本 | 状态 |
|---|---|---|---|
| **EFI earlycon** | 内核解压后 → console 接管前 | 改 cmdline，不重编 | ✅ 前提已具备 |
| **ramoops/pstore** | 任何时刻的 panic，重启后读回 | 本次内核构建 | 本方案主体 |
| **netconsole / adb over TCP** | 网络起来之后 | 后期配置 | 后备 |

### 1.0 🔴 2026-08-13 实战教训 —— 重来一遍前必读

第一次执行本方案把机器搞到无法启动，最终重刷镜像。三条教训：

**教训一：`earlycon=efifb` 高度可疑，很可能会挂死本机启动。**

事后回看全部观察，相关性是 100%：

| entry | 是否带 earlycon | 结果 |
|---|---|---|
| `7.1.0-rc3-gaokun3+`（标准，被改过） | ✅ | 起不来 |
| `[EARLYCON DEBUG]` | ✅ | 起不来 |
| `7.2.0-rc2`（新内核） | ✅ | 起不来 |
| `7.1.0-rc3-gaokun3-el2+`（**从未改动**） | ❌ | **唯一成功启动过的** |

**[待确认]** 样本小，且未做对照实验，但足以支持一条操作规则：
**先在一个可牺牲的 entry 上单独验证 earlycon，永远不要把它加到已知可用的 entry 上。**

推论：7.2.0-rc2 内核和 ramoops 节点**可能根本没问题**，是被 earlycon 连累的。
重来时应先单独排除 earlycon 变量。

**教训二：永远不要动已知可用的 entry。**

当时为了消除"选错菜单项"的可能，把 earlycon 加进了标准项、又把三个 7.1 条目
全部停用，只留新内核。结果新内核起不来 = 没有任何退路，只能拔 U 盘去 Windows 救。
**多一轮选错的代价，远小于失去全部退路的代价。**

**教训三：「用户选错了菜单」这个判断大概率是错的。**

当时观察到"配置的默认项没生效、实际启动的是别的 entry"，判断为人为误选。
更可能的解释是：默认项**根本起不来**，机器只能落到唯一能起的 el2 项。
——排查时不要把"系统没按预期工作"轻易归因于操作失误。

### 1.0.1 重来时的正确顺序

1. 刷回原始镜像，确认能进系统
2. **先解决启动可靠性，再碰内核**：去掉 cmdline 里的 `efi=noruntime`
   （`refs/matebook-e-go-linux/docs/BOOT_SETUP.md` 把它列为 Optional），
   重启确认系统仍稳定且 `/sys/firmware/efi/efivars` 可写
3. 之后所有内核测试一律走 **`bootctl set-oneshot`**：
   - 默认项永远是已知可用的内核，**从不修改**
   - 待测内核只启动一次，无论成败下次自动回默认项
   - **全程不需要在菜单里做任何选择** —— 这才是机制上的保证
4. 再单独验 earlycon（用一次性启动，炸了断电重启即可）
5. 最后验新内核 + ramoops

### 1.1 EFI earlycon —— 需单独验证，不可与其他变更混做

✅ **前提已确认**（`hw-inventory-*/01-kconfig-full.txt`）：

```
CONFIG_EFI=y
CONFIG_EFI_EARLYCON=y
CONFIG_FB_EFI=y
CONFIG_SERIAL_EARLYCON=y
```

不需要重编内核，只加 cmdline 参数：

```
earlycon=efifb keep_bootcon
```

⚠️ **仍需实测**：`earlycon=efifb` 在这块 DSI panel 上是否真的出字。
UEFI 阶段 GOP framebuffer 是否延续到内核早期，只能试。
**先单独测这一条，成功与否决定后面调试的舒适度。**

注：当前 cmdline 里有 `modprobe.blacklist=simpledrm`。earlycon 工作在 driver
之前，不冲突，但知道一下。

### 1.2 改 cmdline 的正确方式 —— 是 systemd-boot，不是 GRUB

✅ **实测确认**：`/boot/efi/loader/entries/` 下有两个 BLS entry，**没有 `/boot/grub`**。

```
8a29534fa802480d9fbb71aa18c01d7b-7.1.0-rc3-gaokun3+.conf
8a29534fa802480d9fbb71aa18c01d7b-7.1.0-rc3-gaokun3-el2+.conf
```

单个 entry 结构：

```
title      Ubuntu 26.04 LTS
version    7.1.0-rc3-gaokun3+
options    root=UUID=a2447957-... clk_ignore_unused pd_ignore_unused arm64.nopauth
           iommu.passthrough=0 iommu.strict=0 pcie_aspm.policy=powersupersave
           modprobe.blacklist=simpledrm efi=noruntime fbcon=rotate:1
           usbhid.quirks=0x12d1:0x10b8:0x20000000 consoleblank=0 loglevel=4 psi=1
linux      /<machine-id>/7.1.0-rc3-gaokun3+/linux
devicetree /<machine-id>/7.1.0-rc3-gaokun3+/sc8280xp-huawei-gaokun3.dtb
initrd     /<machine-id>/7.1.0-rc3-gaokun3+/initrd.img-7.1.0-rc3-gaokun3+
```

两种改法：

- **持久**：编辑 `/etc/kernel/cmdline`（已存在），再 `kernel-install add <ver> <vmlinuz>`
- **临时试一次**：直接改 `.conf` 的 `options` 行

顺带把 `loglevel=4` 提到 `loglevel=7`，调试期需要。

### 1.3 回滚机制 —— 比 GRUB 简单

**复制一份 `.conf`，改 `title` / `devicetree` / `linux` 行即可。**
镜像里已经有现成范例：标准版和 el2 版两个 entry 并存，systemd-boot 启动时列成菜单。

**每次改 dtb 或内核前，先复制一份指向已知可用组合的 entry。** 这是本方案唯一的
回滚手段，也完全够用。

### 1.4 后备通道（Stage 2 再配，现在心里有数）

- **netconsole**：✅ WiFi 实测稳定（本次全程 SSH over WiFi 采集，无断连）
- **adb over TCP**：`service.adb.tcp.port=5555`。若 dwc3 最终搞不定，
  这是 Stage 2「adb shell 通了」的替代路径——代价是要等 Android 起到能配网，
  比 USB adb 晚得多，但**不是死路**

---

## 二、内核 config 增量

基线：`refs/gaokun-buildbot/defconfig/gaokun3_defconfig`

✅ **选项名已对 `fs/pstore/Kconfig` 核实**（jhovold 6.16）：

```
CONFIG_PSTORE=y
CONFIG_PSTORE_RAM=y
CONFIG_PSTORE_CONSOLE=y        # console 输出也存进去，最有用的一项
CONFIG_PSTORE_PMSG=y           # 提供 /dev/pmsg0，Android logcat 落盘走它
CONFIG_PSTORE_COMPRESS=y       # 现在就是个 bool(deflate/zlib)，default y
```

补充说明：`PSTORE_COMPRESS` 在当前内核里已经简化成单个 bool，不再是多压缩后端
选择。排错阶段可以先关掉，未压缩的日志更好读。

⚠️ 上述基于 6.16 的树。**实际构建的是 7.1，写进 defconfig 前对着那棵树再核一遍。**

### 已满足，不用动

✅ `CONFIG_ANDROID_BINDER_IPC=y` / `CONFIG_ANDROID_BINDERFS=y` /
`CONFIG_ANDROID_BINDER_DEVICES="binder,hwbinder,vndbinder"` ——
buildbot defconfig 本来就有（应为 Waydroid），实机已验证可挂载：

```
# mount -t binder binder /dev/binderfs && ls /dev/binderfs/
binder  binder-control  features  hwbinder  vndbinder
```

**Stage 1 第一条验收（`/dev/binderfs` 存在）内核层面已过。**

### 暂不开

`CONFIG_USB_CONFIGFS` 等 gadget 相关项，等第五节确认能出 UDC 之后再一并开。
现在开了也没有 UDC 可绑。

---

## 三、ramoops

### 3.1 内核编一次，地址靠 DTB 迭代

`make dtbs` 只要十几秒，BLS entry 的 `devicetree` 行单独指定 dtb。
**别把换地址和重编内核绑在一起。**

### 3.2 DTS 节点

✅ **`reg` 写法已核实正确**：实机 `reserved-memory` 是
`#address-cells = <0x02>`、`#size-cells = <0x02>`。

```dts
reserved-memory {
    ramoops@ae900000 {
        compatible = "ramoops";
        reg = <0x0 0xae900000 0x0 0x200000>;   /* 2 MB */
        console-size = <0x100000>;              /* 1 MB，最有用 */
        record-size  = <0x20000>;               /* 128 KB × N 条 panic 记录 */
        pmsg-size    = <0x40000>;               /* 256 KB */
        ftrace-size  = <0x0>;                   /* 先关 */
    };
};
```

⚠️ **`no-map` 加不加需要实测。** 差异在于 ramoops 用 `ioremap_wc` 还是直接用
已映射内存。**如果 dmesg 里看不到 "Registered ramoops"，这是第一个该动的旋钮。**
参考 `refs/jhovold-linux/Documentation/admin-guide/ramoops.rst`。

### 3.3 地址选择

✅ **实测物理内存布局**（`/proc/iomem`，root）：

```
System RAM: 80c00000-826fffff  8e400000-9efbffff  9f000000-9f5cffff
            9f600000-aeafffff  c8600000-ffa75fff  fff22000-3ffffffff
            800000000-87fffffff
reserved  : 80600000-806fffff  80880000-808affff  808c0000-808effff
            9efc0000-9effffff  9f5f7000-9f5fffff  aeb00000-bfffffff
            c6200000-c85fffff  ffa76000-fff21fff
```

候选 `0xae900000` + 2 MB → 占用 `0xae900000-0xaeafffff`，
正好是 System RAM 段 `9f600000-aeafffff` 的尾部，**紧邻已 reserved 的 `0xaeb00000`**。
边界干净。

三条约束：

1. ✅ **不与任何 firmware reserved region 重叠** —— 已对 DT 全部
   `reserved-memory` 子节点核过（adsp/cdsp0/cdsp1/slpi/gpu-mem/pil_video/smem/cmd-db
   等），`0xae900000-0xaeafffff` 与它们均无交集
2. ✅ **从内核分配器排除** —— 用 `reserved-memory` 声明即满足
3. ⚠️ **热重启后内容存活** —— **这是唯一的真未知数**。
   重启走 EC + PSCI + UEFI，UEFI 初始化时是否清零或复用这段内存无先例可查

⚠️ **无先例可抄：** 已 grep 全部参考树，`ramoops` 节点只出现在老的高通手机平台
（msm8953 / msm8996 / msm8998 / sdm630 等）和非高通板子上，
**没有任何 sc8280xp / x1e 笔记本定义过 ramoops**。

### 3.4 不存活怎么办

固件通常用低地址。往**更高**挪，优先高位内存 bank 的尾部
（例如 `fff22000-3ffffffff` 或 `800000000-87fffffff` 段内）。
每轮改动 `make dtbs` + 换 dtb + 重启，两分钟。

---

## 四、验证协议（严格按顺序）

**每步只引入一个变量。** 一次改两处再重启，起不来时你不知道是谁的锅——
而这台机器现在还没有调试通道来告诉你。

### 第 0 步：earlycon 单独测（不重编内核）

改 BLS `.conf` 的 `options` 加 `earlycon=efifb keep_bootcon loglevel=7`，重启。
屏幕出现内核早期日志 = 通过。

### 第 1 步：新内核 + ramoops，先测 pmsg（最便宜的探针）

```bash
# 1. 后端是否注册
dmesg | grep -iE 'pstore|ramoops'
#    期望：pstore: Registered ramoops as persistent store backend

# 2. 挂载
mount | grep pstore || mount -t pstore pstore /sys/fs/pstore
ls /sys/fs/pstore/          # 此时应为空

# 3. 写标记
echo "gaokun-pstore-test-$(date +%s)" > /dev/pmsg0

# 4. 正常热重启
reboot

# 5. 读回
cat /sys/fs/pstore/pmsg-ramoops-0
```

**读到标记 = 这段内存活过了热重启 = Stage 0 剩下的唯一验收点通过。**

### 第 2 步：真 panic

```bash
echo 1 > /proc/sys/kernel/sysrq
echo c > /proc/sysrq-trigger
# 重启后
cat /sys/fs/pstore/dmesg-ramoops-0
```

### 第 3 步：强制断电复位

长按电源键强制重启，再读 pstore。
**预期读不到**（ramoops 只承诺热重启存活），但要确认——
Stage 2 调试时会大量使用强制复位。若冷复位也存活，是意外之喜，记下来。

---

## 五、dwc3：单独一次启动测试

**不要和 pstore 改动放在同一次重启里验证。**

### 5.1 ✅ 三个控制器的分工已查清

| DT 节点 | compatible | 实际用途 |
|---|---|---|
| `a4f8800` → `a400000` | `qcom,sc8280xp-dwc3-**mp**`（6 phy） | **键盘盖**在这里 |
| `a6f8800` → `a600000` | `qcom,sc8280xp-dwc3`（2 phy + port@0） | **Type-C，port0，空闲** |
| `a8f8800` → `a800000` | `qcom,sc8280xp-dwc3`（2 phy + port@0） | **Type-C，port1，U 盘在这** |

三者当前全是 `dr_mode = "host"`。

键盘实测路径：
`/sys/devices/platform/soc@0/a4f8800.usb/a400000.usb/xhci-hcd.1.auto/usb1/1-3`

→ **改 Type-C 控制器不会影响键盘。** 原方案担心的"键盘没了"不成立。

### 5.2 🔴 必须改 `a600000`，绝不能动 `a800000`

✅ **根文件系统的物理路径**：

```
/dev/sda → soc@0/a8f8800.usb/a800000.usb/xhci-hcd.3.auto/usb6/6-1 → sda2 → /
```

✅ **typec 端口状态**：

```
port0: data_role=[host] device   partner: 空
port1: data_role=[host] device   partner: 有设备（即 U 盘，supports_usb_power_delivery=no）
```

**U 盘 = port1 = `a800000.usb`。改它 = 根文件系统当场消失。**

port0 空闲，对应 `a600000.usb`（由排除法确定：唯一插着的设备在 port1 且走 a800000）。
⚠️ 这个对应关系是推断而非 DT 直接声明，动手前可插拔一次确认。

### 5.3 建议用 `otg` 而不是 `peripheral`

两个 Type-C 口在 typec 层**已声明支持 device 角色**（`[host] device`，
方括号是当前角色）。但 dwc3 的 `dr_mode = "host"` 让它根本没编 gadget，所以切不动。

```dts
&usb_1_dwc3 {          /* 对应 a600000，按实际 label 调整 */
    dr_mode = "otg";
    usb-role-switch;
};
```

`otg` 保留 host 能力并让 UCSI 切换角色，比硬设 `peripheral` 更贴这机器的拓扑。

⚠️ **本方案最不确定的一点。** 两个 Type-C 口都由 **EC 的 UCSI** 管：

```
/sys/devices/platform/soc@0/ac0000.geniqup/a9c000.i2c/i2c-15/15-0038/
    huawei_gaokun_ec.ucsi.0/typec/port{0,1}
```

DT 里 `connector@0` / `connector@1` 挂在 `embedded-controller@38` 下，
且有 `orientation-switch`。**完全可能出现"UDC 出来了但主机端枚举不到"**——
因为 EC 没把数据方向切到 device。而 `refs/linux-gaokun/README.MD:86-87` 明确说
UCSI 在这台机器上有 bug。

### 5.4 验证（不依赖 adb）

adb 引入太多变量，先用最小 gadget 探针：

```bash
# 1. UDC 是否出现
ls /sys/class/udc/            # 期望出现 a600000.usb

# 2. 最小 gadget，插到编译机上看主机端 dmesg
modprobe g_serial
# 主机端：dmesg | tail → 看到 USB device 枚举 = 整条链打通
```

**主机端能枚举，才说明 dr_mode + PHY + EC 方向切换整条链是通的。**
到这一步 Stage 2 的「adb shell 通了」才有意义，否则你会在「adb 连不上」上
排查半天，而真正的问题在三层之下。

---

## 六、执行顺序

| # | 动作 | 重编？ | 风险 |
|---|---|---|---|
| 1 | BLS `.conf` 加 `earlycon=efifb keep_bootcon loglevel=7`，重启看屏幕 | 否 | 无 |
| 2 | 搭构建环境，拉 7.1 源码 + buildbot patches，暖 ccache | — | 无 |
| 3 | 加 PSTORE 系列 config，编内核 | 内核 | 无 |
| 4 | 加 ramoops DTS 节点，`make dtbs` | 仅 dtb | 无 |
| 5 | 验证协议第 1、2、3 步 | 仅 dtb 迭代 | 无 |
| 6 | **复制一份已知可用的 BLS entry 作回滚** | — | — |
| 7 | 改 **`a600000`** 的 `dr_mode = "otg"`，`make dtbs`，单独一次启动 | 仅 dtb | 低 |
| 8 | `g_serial` 探针验证枚举 | — | 低 |

第 1、2 步可并行——环境搭建基本是下载等待。

**第 5 步完成 → Stage 0 真正过了；第 8 步完成 → Stage 1 也过了。**

### 构建机

- **不要在 Ego 上编**：rootfs 11G，剩 5.8G，不够
- Dell G15 5510：i7-10870H **8 核 16 线程 / 15.8 GB / 72 GB 空闲** —— 够，约 30–60 分钟
- 用户另一台 15 核 / 32 GB —— 更快

内核构建约需 20–30 GB 磁盘，两台都满足。（AOSP 的 250–400 GB 是 Stage 2 才面对的问题。）

---

## 七、Stage 3 的输入（已实测，不用再猜）

| 项 | 实测值 |
|---|---|
| Plane / CRTC | **25 个 plane / 6 个 CRTC** —— 硬件合成资源充裕 |
| Modifier | 只有 `LINEAR(0x0)` 和 `QCOM_COMPRESSED(0x500000000000001)`（UBWC） |
| 支持 UBWC 的 format | `AR24 AB24 AR30 XR30 XR24 XB24 BG16 P010 NV12 NV21 NV16 YUYV YVYU YU12 YV12` |
| Connector | `DSI-1`，1600x2560 @ 120/60 Hz |

✅ CLAUDE.md 第 118 行「plane 数量少时 drm_hwcomposer 会 fallback 到 GPU 合成，
先接受性能损失」的担心**不成立**，不需要预留这个妥协。

这几条直接就是 minigbm msm 后端的配置依据。
