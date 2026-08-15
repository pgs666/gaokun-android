# Stage 1 完成记录

日期：2026-08-13
内核：**`7.2.0-rc2-gaokun3+`**（mainline v7.2-rc2 + buildbot 20 个补丁 + 本项目 1 个补丁）

## 验收结果（CLAUDE.md 第 97 行）

| 验收项 | 结果 | 依据 |
|---|---|---|
| `/dev/binderfs` 存在 | ✅ | buildbot defconfig 本来就带 binder，实测可挂载 |
| **dwc3 进 peripheral 模式** | ✅ | UDC 出现 + 主机端完整枚举到 `configured` |

---

## 1. binderfs

`refs/gaokun-buildbot/defconfig/gaokun3_defconfig` 本来就有（大概率为 Waydroid）：

```
CONFIG_ANDROID_BINDER_IPC=y
CONFIG_ANDROID_BINDERFS=y
CONFIG_ANDROID_BINDER_DEVICES="binder,hwbinder,vndbinder"
```

实测：

```
# mkdir -p /dev/binderfs && mount -t binder binder /dev/binderfs
# ls /dev/binderfs/
binder  binder-control  features  hwbinder  vndbinder
```

Ubuntu 不自动挂载它，Android 的 init 会自己挂。**内核层面无需改动。**

---

## 2. dwc3 peripheral

### 2.1 三个控制器的分工（实测确认）

| DT label | 地址 | compatible | 用途 |
|---|---|---|---|
| `usb_2_dwc3` | `a400000` | `qcom,sc8280xp-dwc3-mp` | **键盘盖**（USB `12d1:10b8`）|
| `usb_0_dwc3` | `a600000` | `qcom,sc8280xp-dwc3` | **Type-C port0，空闲 → 改为 OTG** |
| `usb_1_dwc3` | `a800000` | `qcom,sc8280xp-dwc3` | **Type-C port1，U 盘根文件系统 ⛔** |

⚠️ **DT label 编号与物理地址不对应**：`usb_0` 是 `a6f8800`，`usb_1` 才是 `a8f8800`。
按 label 编号想当然会改错控制器。

U 盘的物理路径（改动前务必核对）：

```
/dev/sda → soc@0/a8f8800.usb/a800000.usb/xhci-hcd.3.auto/usb6/6-1 → sda2 → /
```

### 2.2 DTS 改动

上游 `sc8280xp-huawei-gaokun3.dts` 里是 `dr_mode = "host"`，**没有任何 gadget 控制器**。
改成：

```dts
&usb_0_dwc3 {
	dr_mode = "otg";
	usb-role-switch;
};
```

连接器管线上游已经铺好了，不用动：`usb_0_dwc3_hs` ↔ `ucsi0_hs_in`、
`usb_0_qmpphy_out` ↔ `ucsi0_ss_in`，`connector@0` 是 `usb-c-connector`
且 `data-role = "dual"`，`ucsi0_hs_in` 的注释直接写着 `// role_switch`。

### 2.3 实测结果

```
/sys/class/udc/a600000.usb -> .../soc@0/a6f8800.usb/a600000.usb/udc/a600000.usb
/sys/class/usb_role/a600000.usb-role-switch: device
/sys/kernel/debug/usb/a600000.usb/mode: device
```

主机端（x86 Windows）枚举，用 mass_storage 功能验证完整配置：

```
[OK] USB 大容量存储设备   USB\VID_1D6B&PID_0104\GAOKUN3-MSC
磁盘 1: Linux File-Stor Gadget  16 MB  Online
卷 D:   GAOKUN  FAT  16 MB          ← Windows 读出了 Ego 上创建的文件系统
```

Ego 侧状态随插拔正确变化：

| | 未插线 | 插线后（gser）| mass_storage |
|---|---|---|---|
| `state` | not attached | addressed | **configured** |
| `link_state` | Suspend | Suspend | **On** |
| `current_speed` | UNKNOWN | high-speed | high-speed |

**`configured` + Windows 能读文件系统 = 双向数据通路成立。**

### 2.4 🔑 UCSI 挂了也不影响 adb 通路

本次启动 UCSI 初始化失败：

```
ucsi_huawei_gaokun.ucsi ...: set orientation out of range: con0
ucsi_huawei_gaokun.ucsi ...: con2: failed to register alt modes
ucsi_huawei_gaokun.ucsi ...: error -ETIMEDOUT: PPM init failed
ucsi_huawei_gaokun.ucsi ...: ucsi connector is not initialized yet
```

`/sys/class/typec/` 为 **0 项**——没有任何 typec 端口注册。

**但 USB 枚举照样完全成功。** 原因：`dr_mode = "otg"` 在没有 role 源时落到 device 侧，
PHY 的数据方向不依赖 UCSI 的 PPM 初始化。

> 这推翻了 `docs/stage1-kernel-plan.md` 第 5.3 节的担心
> （「可能出现 UDC 出来了但主机端枚举不到，因为 EC 没把数据方向切过去」）。
>
> **对 Stage 2 的意义：adb 通路不依赖那个有已知缺陷的 UCSI 子系统**
> （`refs/linux-gaokun/README.MD:86-87` 记录了这个缺陷）。

代价：SuperSpeed 用不上，当前跑 **high-speed（480 Mbps）**，因为 SS 通道的
orientation 要靠 UCSI 切。adb 完全够用；将来推大镜像若嫌慢再回头解决 UCSI。

---

## 3. Stage 2 需要的 gadget 功能已就位

原 defconfig 只有 `USB_CONFIGFS_SERIAL`，**缺 adbd 依赖的 FunctionFS**。已补全：

```
CONFIG_USB_CONFIGFS_F_FS=y          ← adbd 用这个
CONFIG_USB_CONFIGFS_ACM=y
CONFIG_USB_CONFIGFS_MASS_STORAGE=y
CONFIG_USB_CONFIGFS_ECM=y
CONFIG_USB_CONFIGFS_RNDIS=y         ← USB 网络，Stage 2 的后备调试通道
CONFIG_USB_CONFIGFS_EEM=y
```

FunctionFS 实测可用：

```
# mkdir -p /sys/kernel/config/usb_gadget/adbtest/functions/ffs.adb
# mount -t functionfs adb /dev/usb-ffs/adb
# ls /dev/usb-ffs/adb/
ep0
```

`ep0` 存在即 adbd 可以在此写描述符并接管。

**RNDIS/ECM 的价值**：万一 Android 起来了但 WiFi 没配好，可以走 USB 网络
做 adb over TCP，不必依赖无线。

---

## 4. 操作注意事项

- **改 dwc3 前先确认 U 盘在哪个控制器**：`readlink -f /sys/block/sda`
- **`a800000` 绝对不能动**，改了根文件系统当场消失
- 键盘盖在 `a400000`（multiport 型号），改 Type-C 口不影响它
- Ego 的 GNOME 默认会空闲挂起，挂起后 WiFi 断、SSH 全挂。调试期已
  `systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target`
  并关掉 GNOME 空闲挂起和 WiFi 省电。
  ⚠️ 这是**临时措施**，suspend/resume 本身 Stage 4 还要测
  （CLAUDE.md 第 117 行预期它会先炸）

---

## 5. 当前内核的完整改动清单

相对 `refs/gaokun-buildbot` 的 `gaokun3_defconfig` + 20 个补丁：

**config 增量**

```
CONFIG_PSTORE=y  PSTORE_RAM=y  PSTORE_CONSOLE=y  PSTORE_PMSG=y
CONFIG_MAGIC_SYSRQ=y            （触发 panic 做验证，也是 Stage 2 的调试手段）
CONFIG_DEBUG_FS=y
CONFIG_USB_CONFIGFS_{F_FS,ACM,MASS_STORAGE,ECM,RNDIS,EEM}=y
```

**源码补丁**

- `patches/0001-efi-pstore-register-backend-when-efivars-ops-arrive-.patch`

**DTS 改动**

- `usb_0_dwc3`：`dr_mode = "otg"` + `usb-role-switch`

**跳过的上游补丁**

- `patches/media/`（6 个 Venus 硬解补丁）在 v7.2-rc2 上打不上，
  且 gaokun3 板级 DTS 不引用 venus、defconfig 也没开 —— Stage 5 再处理
