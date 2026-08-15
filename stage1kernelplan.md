# Stage 0 收尾 + Stage 1 合并：内核构建方案

> 依据：2026-08 实机 Stage 0 验收结果。
> 决策：同意合并。pstore 和 dwc3 都要重编内核，binderfs 已就绪，分两次没意义。

---

## 一、先把调试通道建起来（本方案的真正目的）

现状：**没有串口，没有 UDC**。这是项目当前唯一的存亡级问题。
不要指望单一通道，建三条，覆盖不同的失败时段。

| 通道 | 覆盖时段 | 成本 | 状态 |
|---|---|---|---|
| **EFI earlycon** | 内核解压后 → console 接管前 | 改 cmdline，**不用重编** | 今晚就能有 |
| **ramoops/pstore** | 任何时刻的 panic，重启后读回 | 本次内核构建 | 本方案主体 |
| **netconsole / adb over TCP** | 网络起来之后 | 后期配置 | 后备 |

### 1.1 EFI earlycon —— 优先级最高，先做

```
earlycon=efifb keep_bootcon
```

需要 `CONFIG_EFI_EARLYCON=y`（多数 arm64 UEFI 配置默认开）。
先确认：

```bash
zcat /proc/config.gz 2>/dev/null | grep EFI_EARLYCON
# 或
grep EFI_EARLYCON /boot/config-$(uname -r)
```

**⚠️ 需实测验证**：`earlycon=efifb` 在 arm64 + 这块 DSI panel 上是否真的出字。
理论上 EFI GOP 提供的 framebuffer 在 DRM 接管前可用，但这机器的 panel 由 DSI 驱动，
UEFI 阶段的 GOP framebuffer 是否延续到内核早期是要实测的。**先单独测这一条，
成功与否决定后面调试的舒适度。**

如果 efifb 不出字，`earlycon` 也可以尝试挂到别的地方，但在无串口设备上选择很少，
那样 ramoops 的重要性就上升到唯一。

### 1.2 后备通道（等 Stage 2 再配，但现在心里有数）

- **netconsole**：WiFi 已实测稳定（SSH 全程无断连），网络起来后的内核日志可以推到 G15
- **adb over TCP**：`service.adb.tcp.port=5555`。如果 dwc3 peripheral 最终搞不定，
  这是 Stage 2「adb shell 通了」的替代验收路径 —— 代价是要等 Android 起到能配网，
  比 USB adb 晚得多，但**不是死路**

---

## 二、内核 config 增量

基线：`refs/gaokun-buildbot/defconfig/gaokun3_defconfig`

```
# pstore 全家桶
CONFIG_PSTORE=y
CONFIG_PSTORE_RAM=y
CONFIG_PSTORE_CONSOLE=y        # 把 console 输出也存进去，最有用的一项
CONFIG_PSTORE_PMSG=y           # 提供 /dev/pmsg0，Android logcat 落盘也走它
CONFIG_PSTORE_COMPRESS=y       # 可选；出问题先关掉，压缩过的日志排错时更麻烦

# 确认已有（Stage 0 已验证 binderfs 可挂，但确认 config 而非仅确认行为）
CONFIG_ANDROID_BINDER_IPC=y
CONFIG_ANDROID_BINDERFS=y

# 确认 EFI earlycon
CONFIG_EFI_EARLYCON=y
```

**⚠️ 逐项对着 `fs/pstore/Kconfig` 核对名字再写进 defconfig**，
不同版本有增删（例如压缩后端相关的选项改过几轮）。别照抄这份清单。

Stage 1 的另外两项验收里，binderfs 已过；`CONFIG_USB_CONFIGFS` 相关项等
dwc3 peripheral 确认能出 UDC 之后再一并开，现在开了也没有 UDC 可绑。

---

## 三、ramoops：地址选择与迭代方法

### 3.1 关键认知：不用重编内核就能换地址

`make dtbs` 只要十几秒，GRUB 的 `devicetree` 行单独加载 dtb。
**内核编一次，地址靠重编 DTB 迭代。** 别把这两件事绑在一起。

### 3.2 DTS 节点

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

**⚠️ `no-map` 属性加不加需要实测**：不同 qcom 板子两种写法都出现过，
行为差异在于 ramoops 用 `ioremap_wc` 还是直接用已映射内存。
**如果 pstore 探测失败（dmesg 无 "Registered ramoops"），这是第一个该动的旋钮。**

### 3.3 地址选择的三条约束

你的候选 `0xae900000`（System RAM 尾部，紧邻已 reserved 的 `0xaeb00000`）
从这三条看是合理的，但第 3 条只能实测：

1. **不能和任何 firmware reserved region 重叠。** 高通平台上远端处理器
   （adsp/cdsp/mpss）的保留区被踩会直接硬挂或静默损坏。对着 DT 里所有
   `reserved-memory` 子节点核一遍，确认无交集。
2. **必须从内核内存分配器里排除**，否则你在往正常内存上写。
   用 `reserved-memory` 节点声明就满足。
3. **热重启后内容必须存活** —— 这条是这台机器上的真正未知数。
   重启走 EC + PSCI + UEFI，**UEFI 固件在初始化时是否会清零或复用这段内存，
   没有先例可查。** 只能测。

### 3.4 如果这个地址不存活怎么办

固件通常使用低地址。往**更高的地址**挪，优先考虑高位内存 bank 的尾部。
每次改动只要 `make dtbs` + 换 dtb + 重启，一轮两分钟。

---

## 四、验证协议（严格按顺序，别跳）

**分步验证的意义**：每步只引入一个变量。一次改两处再重启，
起不来的时候你不知道是谁的锅 —— 而这台机器没有调试通道来告诉你。

### 第 0 步：earlycon 单独测（不重编内核）

只改 GRUB cmdline 加 `earlycon=efifb keep_bootcon`，重启。
屏幕上出现内核早期日志 = 通过。

### 第 1 步：新内核 + ramoops，先测 pmsg（最便宜的探针）

```bash
# 1. 确认 pstore 后端注册成功
dmesg | grep -i -E 'pstore|ramoops'
# 期望看到类似 "pstore: Registered ramoops as persistent store backend"

# 2. 确认挂载
mount | grep pstore || mount -t pstore pstore /sys/fs/pstore
ls /sys/fs/pstore/          # 此时应为空

# 3. 写标记
echo "gaokun-pstore-test-$(date +%s)" > /dev/pmsg0

# 4. 正常热重启
reboot

# 5. 读回
cat /sys/fs/pstore/pmsg-ramoops-0
```

**读到标记 = 这段内存活过了热重启。这是整个 Stage 0 剩下的唯一验收点。**

### 第 2 步：真 panic 测试

```bash
echo 1 > /proc/sys/kernel/sysrq
echo c > /proc/sysrq-trigger      # 强制 panic
# 机器重启后
cat /sys/fs/pstore/dmesg-ramoops-0
```

### 第 3 步：EC 强制复位测试（Android 会遇到）

长按电源键强制断电重启，再读 pstore。
**预期读不到**（ramoops 只承诺热重启存活），但要确认，
因为 Stage 2 调试时你会大量使用强制复位。
如果冷复位也存活，那是意外之喜，记下来。

---

## 五、dwc3 peripheral：单独一次启动测试

**不要和 pstore 改动放在同一次重启里验证。**

### 5.1 风险

这是本次唯一有"把自己锁在外面"风险的改动：

- 把接键盘/坞的那个控制器改成 peripheral，键盘就没了
- 这是个可拆键盘的平板，触摸屏在早期启动阶段也未必可用
- 回滚手段：GRUB 里保留一份指向**旧 dtb** 的启动项。改 DTS 前先做这个。

### 5.2 选哪个控制器

sc8280xp 上通常 `usb_0` / `usb_1` 走 Type-C（QMP PHY，兼 DP），
需要确认哪个物理对应哪个口。建议：

1. 在 DT 里找 typec connector / retimer / orientation-switch 相关节点，
   看它们 phandle 指向哪个 dwc3
2. **⚠️ 需验证**：静态 `dr_mode = "peripheral"` 是否足够。
   这些笔记本的 Type-C 数据通路上常有 mux / retimer，方向切换可能由 EC 或
   独立驱动控制。**有可能出现"UDC 出来了但插上去主机端枚举不到"** ——
   因为 mux 没切到 device 方向。这是本方案里我最不确定的一点。

### 5.3 验证（不依赖 adb）

先别测 adb，adb 引入太多变量。用最小 gadget 探针：

```bash
# 1. UDC 是否出现
ls /sys/class/udc/            # 期望出现类似 a600000.usb

# 2. 最小 gadget：g_serial 或 g_ether，插到 G15 上看主机端 dmesg
modprobe g_serial
# G15 上：dmesg | tail  → 看到 USB device 枚举 = 通路全线打通
```

主机端能枚举出设备，才说明 dr_mode + PHY + mux 整条链是通的。
到这一步 Stage 2 的「adb shell 通了」才有意义 —— 否则你会在
「adb 连不上」上排查半天，而真正的问题在三层之下。

---

## 六、建议执行顺序

| 顺序 | 动作 | 重编？ | 风险 |
|---|---|---|---|
| 1 | GRUB 加 `earlycon=efifb keep_bootcon`，重启看屏幕 | 否 | 无 |
| 2 | 搭构建环境（G15，15 核 / 32G），拉源码、暖 ccache | — | 无 |
| 3 | 加 PSTORE 系列 config，编内核 | 内核 | 无 |
| 4 | 加 ramoops DTS 节点，`make dtbs` | 仅 dtb | 无 |
| 5 | 验证协议第 1、2、3 步 | 仅 dtb 迭代 | 无 |
| 6 | **备份可用的 GRUB 启动项 + 旧 dtb** | — | — |
| 7 | 改 dwc3 dr_mode，`make dtbs`，单独一次启动 | 仅 dtb | **中** |
| 8 | g_serial 探针验证枚举 | — | 低 |

第 1、2 步可以并行 —— 环境搭建基本是下载等待，不占你的脑子。

**到第 5 步完成，Stage 0 就真正过了；第 8 步完成，Stage 1 也过了。**

---

## 七、顺带记下来的 Stage 3 输入（已实测，别再猜）

- **plane 25 个 / CRTC 6 个** —— 硬件合成资源充裕，
  drm_hwcomposer 回退 GPU 合成的担心不成立
- **modifier 只有两种**：`LINEAR` 和 `QCOM_COMPRESSED (0x500000000000001)`（UBWC）
- **支持 UBWC 的格式**：AR24 AB24 AR30 XR30 XR24 XB24 BG16 P010 NV12 NV21 NV16
  YUYV YVYU YU12 YV12
- 这三条直接就是 minigbm msm 后端的配置依据，Stage 3 不用再摸
