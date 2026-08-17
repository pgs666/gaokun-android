# Stage 2 调试记录：Android 启动链路的十二个真问题

日期：2026-08-14 ~ 2026-08-17
状态：✅ **验收通过（2026-08-17）—— `adb shell` 通，Android 16 稳定运行**

```
$ adb devices -l
gaokun3    device product:aosp_gaokun3 model:MateBook_E_Go device:gaokun3
$ adb shell uname -a
Linux localhost 7.2.0-rc2-gaokun3+ #2 SMP PREEMPT ... aarch64 Toybox
```

运行时验证（`docs/stage2-acceptance-live.txt`）：keystore2 健康、
cpuset/cpu/blkio v1 hierarchy 挂载在用、UDC 绑定 role=device、zygote 运行。
Stage 3 起点已由 surfaceflinger 的 abort message 指明：
`couldn't find an OpenGL ES implementation`（mesa/gralloc/hwc 未装，刻意的）。

> 这份文档记录的是"从零信息到定位"的完整过程。每一条都有实测依据。
> 下次重建镜像时**照这里的清单配置**，可以跳过全部弯路。

---

## 0. 当前进度

```
✅ 内核加载、DM 就绪、SELinux 激活
✅ init first stage 启动
✅ 从 super 创建 dm-0..dm-3 四个逻辑分区
✅ /system 挂载成功（ext4）
✅ switch_root 到 /system 成功
❌ second stage —— 切根后 <50ms 复位，无任何日志
```

---

## 1. 🔴 super.img 是 sparse 格式，不能直接 dd

**这是最靠前、也最隐蔽的一个错误，挡住了后面所有问题的暴露。**

AOSP 产出的 `super.img` 是 **Android sparse 镜像**，不是 raw。头部：

```
3aff26ed  0100 0000  1c00  0c00  0010 0000
魔数       v1.0      hdr=28 chunk=12 blk=4096
```

`0xED26FF3A` 是 **sparse magic**。我一度把它误读成"LP metadata 魔数、镜像完好"，
于是原样 `dd` 进分区——分区里躺的是 sparse 文件本身，init 读不到有效元数据，
挂载失败后主动复位。

**正确做法：**

```bash
apt install android-sdk-libsparse-utils
simg2img super.img /dev/disk/by-partlabel/super     # 直接展开写入，不落中间文件
```

`/tmp` 是 tmpfs（7.6 G），装不下展开后的 12 G，所以必须管道直写。

**验证方法**（`scripts/lpdump.py`）：

```
geometry magic   0x616c4467  @ offset 4096
metadata magic   0x414c5030  @ offset 12288
logical partitions: system / system_ext / product / vendor
```

三者都对上才算写对。sparse 头声明的展开大小（12884901888）必须与分区容量一致。

---

## 2. 🔴 device-mapper 必须编进内核，不能是模块

动态分区要靠 DM 从 `super` 变出逻辑分区，而 **first-stage init 在 ramdisk 阶段就要用它**。
我们的 ramdisk 里只有 `init` 和 `fstab`，**没有任何 `.ko`**，所以模块形态的 DM 加载不到。

buildbot 的 `gaokun3_defconfig` 里 DM 全是 `=m`：

```
dm-mod.ko  dm-verity.ko  dm-bufio.ko ...
/dev/mapper/control  不存在
```

**必需配置：**

```
CONFIG_BLK_DEV_DM=y
CONFIG_DM_VERITY=y
CONFIG_DM_BUFIO=y
CONFIG_DM_SNAPSHOT=y
```

**验证**：`/dev/mapper/control` 存在，且 `grep -c dm_mod /proc/modules` 为 0（built-in 不出现在模块列表里）。

---

## 3. 🔴 SELinux：`CONFIG_SECURITY_SELINUX=y` 不等于启用

**这一条最容易误判。** 检查配置会看到：

```
CONFIG_SECURITY_SELINUX=y          ← 看起来没问题
```

但实际上 SELinux 从未激活，因为：

```
CONFIG_LSM="landlock,lockdown,yama,loadpin,safesetid,apparmor,integrity,bpf"
                                              ↑ 没有 selinux
```

`CONFIG_LSM` 这个字符串才决定哪些 LSM 真正生效。selinux 不在里面 →
`selinuxfs` 从不注册 → `/sys/fs/selinux` 不存在 → Android init 在
`selinux_setup` 阶段死亡，且**来不及打任何日志**。

**必需配置：**

```
CONFIG_SECURITY_SELINUX=y
CONFIG_SECURITY_SELINUX_BOOTPARAM=y
CONFIG_SECURITY_SELINUX_DEVELOP=y
CONFIG_SECURITY_NETWORK=y
CONFIG_AUDIT=y
CONFIG_LSM="landlock,lockdown,yama,integrity,selinux,bpf"
```

⚠️ SELinux 与 AppArmor 都是 major LSM，当前内核**不能同时激活**。
把 apparmor 从列表里去掉，Ubuntu 侧只是失去应用约束，不影响功能。

**验证**（必须看运行时，不能只看 config）：

```bash
cat /sys/kernel/security/lsm        # 必须包含 selinux
ls -d /sys/fs/selinux               # 必须存在
```

`androidboot.selinux=permissive` **救不了这个问题**——permissive 只是不强制执行策略，
selinuxfs 本身必须存在。

---

## 4. 🔴 system 镜像里没有 `/metadata` 目录，切根失败

fstab 里挂了 `/metadata`，但 switch_root 时 init 要把所有已有挂载点搬到新根下：

```
init: Unable to move mount at '/metadata' to '/system/metadata': No such file or directory
```

实测 system 根目录里 `/data` `/vendor` `/product` `/system_ext` `/apex`
`/linkerconfig` 全都在，**唯独没有 `/metadata`**。

**根因**：AOSP 只有在 `BOARD_USES_METADATA_PARTITION := true` 时才会在
system 镜像根目录创建该挂载点。

**正确修法**（已写入 `device/huawei/gaokun3/BoardConfig.mk`）：

```makefile
BOARD_USES_METADATA_PARTITION := true
```

**临时绕过**（本次采用）：从 ramdisk 的 fstab 里删掉 metadata 那行。

⚠️ **不能靠"往镜像里补目录"解决** —— AOSP 的 system.img 按内容精确打包：

```
958M 用了 955M，可用 0，inode 用了 97%
mkdir: No space left on device
```

---

## 5. 调试方法论：如何在没有串口的机器上抓 Android 启动日志

这台机器没有串口，而 Android init 失败时的行为让常规手段全部失效。
以下是最终有效的组合，以及为什么别的方法不行。

### 5.1 为什么 pstore 抓不到

**Android init 失败时是主动调 `reboot()`，不是内核 panic。**
efi_pstore 只在 panic 路径上转储，所以 `/sys/fs/pstore` 永远是空的。

（init 还会给自己装崩溃信号处理器，SIGSEGV 等也转成 reboot 而非 panic。）

### 5.2 有效办法：包装 ramdisk + 写内置 ESP

把 ramdisk 里的 `/init` 换成 busybox 脚本，挂载**内置盘的 ESP**（`/dev/nvme0n1p1`）
写日志，然后交棒给真正的 init。

⚠️ **注意是内置盘的 ESP，不是 U 盘的。** 系统从 U 盘启动时
`/boot/efi` 是 `/dev/sda1`，我一度在错误的位置找日志。

### 5.3 包装脚本的四个必备细节

每一条都是踩过之后才知道的：

**① 必须交还干净的 `/proc` `/sys` `/dev`**

Android init 要自己挂这三个，发现已挂载就报 EBUSY 并致命退出：

```
init: mount("sysfs", "/sys", "sysfs", 0, NULL) failed Device or resource busy
init: init encountered errors starting first stage, aborting
```

用 `umount -l`（lazy），已打开的 fd 不受影响。

**② 日志挂载点也必须卸载**

switch_root 会搬移所有挂载点，任何残留（包括我们自己的 `/debuglog`）都会让它失败。
做法：先 `exec 3>>/debuglog/init.out` 持有 fd，再 `umount -l /debuglog`。
**已打开的 fd 在挂载点卸载后依然可写。**

**③ 只能用【长驻】进程抓 kmsg，不能循环里反复 exec**

Android init 在 switch_root 时会调 `FreeRamdisk()` 把 ramdisk 内容全删掉，
包括我们放的 `/bin/busybox`。所以：

| 写法 | 结果 |
|---|---|
| `while ...; do busybox dmesg -c >&3; done` | ❌ 切根后每轮 exec 都失败 |
| `while read -r L <&4; do ...` （纯内建，不 exec）| ❌ 见下 |
| `busybox cat /dev/kmsg >&3 &` （只 exec 一次）| ✅ |

**纯内建 `read` 读 `/dev/kmsg` 是行不通的**，这一条实测验证过：
`/dev/kmsg` 要求每次 `read()` 的缓冲区能装下整条记录，而 shell 的 `read`
内建为了不越过换行符是**逐字节**读的，直接 EINVAL。
在正常运行的 Ubuntu 上测同样的构造，捕获 **0 行**。

正确做法是长驻 `cat`：进程只在启动时 exec 一次，之后可执行文件被删也不影响。

**④ `-o sync` 要配合"交棒前先追平"**

`dmesg -c` **清不掉 `/dev/kmsg` 的读取位置**（两者是独立的迭代器），
所以 `cat` 总会从缓冲区头部重放，实测约 1535 行。
同步写下这些积压要几秒；若立刻交棒给 init，init 的日志排在积压后面，
还没轮到就复位了 —— 这正是之前"只拿到前 40%"的真因。

对策：起了 `cat` 之后 `sleep 8` 等它追平，再 `umount -l` 交棒。

### 5.4 检查镜像内容的方法

不需要 AOSP 工具，用 `losetup` 按 LP 元数据的偏移直接挂载逻辑分区：

```bash
python3 scripts/lpext.py            # 打印各逻辑分区在 super 中的 offset/size
losetup -f --show -r -o <offset> --sizelimit <size> /dev/nvme0n1p8
mount -o ro /dev/loopN /mnt/sys
```

---

## 6. 本次踩过的自制陷阱（都属于同一类）

调试过程中我自己引入的错误，全都是"把状态托付给会开新进程或有特殊退出码约定的构造"：

| 现象 | 真因 |
|---|---|
| `repo sync` 报成功但源码不全 | `repo sync \| tail` 取到的是 `tail` 的退出码 |
| `bootctl set-oneshot` 报"写入成功" | `cmd \| head && echo 成功` 中 `head` 永远成功 |
| dtc 编译"成功"但文件不存在 | `dtc ... \| head -3` 触发 SIGPIPE 杀掉 dtc |
| 校验显示"0 个 ramoops ✅" | 对不存在的文件 grep，假阴性 |
| 脚本校验全过却没执行替换 | `grep -c` 数到 0 时返回退出码 1，`set -e` 中断 |
| 检查镜像文件全部"缺失" | `lpext.py` 被 tmpfs 清掉，losetup 失败，挂载点是空的 |
| cgroups.json 被截成 0 字节 | 在 0 可用块的 ext4 上 `open(path,'w')` —— **先截断**再写，写入时 ENOSPC，原内容已没了。改前必须先备份 + 用 `r+` 就地写 |

**教训：先把结果落到变量再判断，不要在管道里取状态；检查"不存在"时必须先确认工具本身成功了。**

---

## 7. 下次重建镜像的配置清单

### 内核（在 buildbot `gaokun3_defconfig` 基础上）

```
# 动态分区必需
CONFIG_BLK_DEV_DM=y
CONFIG_DM_VERITY=y
CONFIG_DM_BUFIO=y
CONFIG_DM_SNAPSHOT=y

# Android 必需（注意 LSM 列表！）
CONFIG_SECURITY_SELINUX=y
CONFIG_SECURITY_SELINUX_BOOTPARAM=y
CONFIG_SECURITY_SELINUX_DEVELOP=y
CONFIG_SECURITY_NETWORK=y
CONFIG_AUDIT=y
CONFIG_LSM="landlock,lockdown,yama,integrity,selinux,bpf"

# cgroup v1（6.12+ 拆分后默认关，Android 的 cgroups.json 要求 cpuset 走 v1，见第 8 节）
CONFIG_CPUSETS_V1=y
CONFIG_MEMCG_V1=y
CONFIG_UCLAMP_TASK=y
CONFIG_UCLAMP_TASK_GROUP=y

# 调试通道
CONFIG_PSTORE=y  CONFIG_PSTORE_RAM=y  CONFIG_PSTORE_CONSOLE=y  CONFIG_PSTORE_PMSG=y
CONFIG_EFI_VARS_PSTORE=y
CONFIG_MAGIC_SYSRQ=y
CONFIG_DEBUG_FS=y

# adb / USB gadget
CONFIG_USB_CONFIGFS_F_FS=y      ← adbd 直接依赖
CONFIG_USB_CONFIGFS_ACM=y  CONFIG_USB_CONFIGFS_MASS_STORAGE=y
CONFIG_USB_CONFIGFS_ECM=y  CONFIG_USB_CONFIGFS_RNDIS=y  CONFIG_USB_CONFIGFS_EEM=y
```

**DTS**：`usb_0_dwc3` 设 `dr_mode = "otg"` + `usb-role-switch`；**不要加 ramoops 节点**
（本机固件每次复位重初始化 DRAM，ramoops 不存活，加了只会抢占 efi_pstore 的后端位）。

### AOSP BoardConfig

```makefile
BOARD_USES_METADATA_PARTITION := true
```

### 部署

```bash
simg2img super.img /dev/disk/by-partlabel/super     # 不是 dd！
```

---

## 8. ✅ 已解决：second stage 死因 = 内核缺 cgroup v1 cpuset

**2026-08-15 用修好的 kmsg 抓取拿到完整日志（948 行），死因一目了然：**

```
cgroup: Unknown subsys name 'cpuset'
libprocessgroup: Failed to mount controller cpuset: Invalid argument
init: Command 'SetupCgroups' ... failed: Failed to setup cgroups: Invalid argument
    ↓ cgroup v2 也因此没挂上，后续每个服务的 createProcessGroup 全失败
init: Service 'ueventd' failed to start due to a fatal error
init: Service apexd-bootstrap has 'reboot_on_failure' option and failed, shutting down system.
init: Reboot start, reason: reboot,bootloader,bootstrap-apexd-failed
```

**根因**：Linux 6.12+ 把 cgroup v1 控制器拆到独立的 `*_V1` 选项后面且默认关闭。
buildbot defconfig 只有 `CONFIG_CPUSETS=y`（v2 侧），**没有 `CONFIG_CPUSETS_V1`**
（7.2 树 `init/Kconfig:1310`），于是 `/proc/cgroups` 里没有 cpuset。
而 Android 16 的 `/system/etc/cgroups.json` 要求 **cpuset 走 v1**
（挂 `/dev/cpuset`，非 Optional）。

对照表（要求来自镜像里的 cgroups.json，实测）：

| Android 要求 | 修复前内核 |
|---|---|
| blkio (v1) 必需 | ✅ |
| cpu (v1) 必需 | ✅ |
| **cpuset (v1) 必需** | ❌ **缺 —— 就是它** |
| freezer (v2) 必需 | ✅ |
| memory (v2) 可选 | ✅ |

**修复**（一并补上 task_profiles.json 实际引用的邻近项）：

```
CONFIG_CPUSETS_V1=y        # 直接死因
CONFIG_MEMCG_V1=y          # task_profiles 引用 memory.limit_in_bytes 等 v1 文件
CONFIG_UCLAMP_TASK=y       # task_profiles 引用 cpu.uclamp.*
CONFIG_UCLAMP_TASK_GROUP=y
```

**注意两件与直觉相反的事：**

1. 这次 init 走的是**正常 shutdown 流程**（`reboot_on_failure`），不是 LOG(FATAL)，
   所以 `init_fatal_panic` 没触发、pstore 仍是空的 —— 与观察自洽。
   两条通路（pstore + kmsg 落盘）必须都布，谁也替代不了谁。
2. init 其实跑得很远：SELinux 策略加载、property、所有 rc 解析**全部成功**，
   死在 `SetupCgroups`。"<50ms 复位零日志"的印象全是抓取机制的锅。

此前逐项排除的（均实测）：

- ✅ `/system/bin/init` 存在（2.7 MB）
- ✅ `/system/etc/init/hw/init.rc` 存在（57 KB）
- ✅ `/system/etc/selinux/plat_sepolicy.cil` 存在（3.1 MB）
- ✅ vendor 侧策略齐全（含 `precompiled_sepolicy`）
- ✅ 我们的 `init.gaokun3.rc` / `.usb.rc` / `fstab` / `ueventd.rc` 都已打包
- ✅ 七个固件都在 `/vendor/firmware/`

### 8.1 ❌ 已排除：sepolicy 版本不匹配

原本最大的怀疑方向，**实测排除**：

```
precompiled_sepolicy 头部  magic=0xf97cff8c  "SE Linux"  policydb 版本 = 30
内核 /sys/fs/selinux/policyvers                            = 35
```

30 ≤ 35，兼容。vendor 侧文件也一个不缺：

```
plat_sepolicy_vers.txt = 202504
precompiled_sepolicy + 三个 .sha256 齐全
plat_pub_versioned.cil / vendor_sepolicy.cil 都在
/system/etc/selinux/mapping/ 存在
```

### 8.2 ✅ 正解：让 init 自己喊出死因，别再逐个假设

init 的**每一个 `LOG(FATAL)` 都走 `InitAborter` → `InitFatalReboot()`**
（`refs/aospm-system-core/init/util.cpp:699-708`、`:740-743`），
默认行为是 `RebootSystem()` —— **静默复位，这就是我们看到的现象**。

但 `InitFatalReboot()` 里有个开关（`init/reboot_utils.cpp:168-173`）：

```cpp
if (init_fatal_panic) {
    LOG(ERROR) << __FUNCTION__ << ": Trigger crash";
    android::base::WriteStringToFile("c", PROC_SYSRQ);   // 主动触发内核 panic
}
```

由 cmdline `androidboot.init_fatal_panic=true` 打开（`reboot_utils.cpp:49-61`）。

**为什么这条正好破局**：§5.1 说过 pstore 只在 panic 路径转储，而 init 是主动
`reboot()` 所以 pstore 永远是空的。这个开关**把静默复位变成真 panic**，
于是 efi_pstore 会把 kmsg 尾部（含 init 那条 FATAL 原文）落进 EFI 变量。
不管死因是十几种可能里的哪一种，都能一次拿到。

**三个前提都已实测确认：**

| 前提 | 实测 |
|---|---|
| AOSP 16 的 init 真有这个参数 | `strings system/bin/init` → `androidboot.init_fatal_panic` ✅ 命中 |
| sysrq 写 `c` 不受 mask 限制 | `write_sysrq_trigger` 调 `__handle_sysrq(c, **false**)` 且无 `sysrq_on()` 守卫（`drivers/tty/sysrq.c:1166-1188`）。运行时 `kernel.sysrq=176` 也照样能 panic |
| Android 内核带 efi_pstore | Android 的 `Image` 与 Linux 的 `vmlinuz` **sha256 完全相同** |

⚠️ **`efi=noruntime` 不影响 efivars**（我一度以为它会）。
本机 efivars 走高通 TrustZone 的 `uefisecapp` 驱动，不是 EFI runtime services，
所以关掉 runtime 后 `/sys/firmware/efi/efivars` 仍有 79 个变量，
`/sys/module/pstore/parameters/backend` 仍是 `efi_pstore`。

### 8.3（后续）第五个真问题：binderfs 双重挂载，servicemanager 与客户端隔离

cpuset 修掉之后 init 跑到 54 秒开外，服务批量启动，卡在新的一层：

```
servicemanager: Starting sm instance on /dev/binder        ← 起来了
binder: 309:309 cannot find target node                    ← 但客户端找不到 context manager
libbinder.ProcessState: Not able to get context object on /dev/binder
（vdc 每秒重试，永远等不到，启动挂死）
```

**根因是我们自己的 `init.gaokun3.rc`（从 aospm sdm845 模板抄的）：**

```
on init
    mount binder binder /dev/binderfs stats=global    ← 事故源
    symlink /dev/binderfs/binder /dev/binder          ← 报 File exists（AOSP 已建过）
```

三个事实拼起来：

1. **`CONFIG_ANDROID_BINDERFS=y` 时静态 binder 设备根本不注册**
   （`drivers/android/binder.c` `binder_init()` 里 `!IS_ENABLED(CONFIG_ANDROID_BINDERFS)`
   守卫，7.2 树 7068 行）。`/dev/binder` 只能是指向 binderfs 内节点的符号链接。
2. **AOSP 16 的 init.rc 原生处理 binderfs**：挂 `/dev/binderfs` + 建三个符号链接。
   我们的符号链接报 `File exists` 正是它已经建好的证据。
3. **每个 binderfs 挂载是独立的 binder context。** 我们的 rc 在同一路径又挂了
   实例 #2 盖在上面：servicemanager 恰好在间隙打开了实例 #1 并注册成
   context manager，之后所有客户端顺着符号链接解析到实例 #2 —— 那里没有
   context manager，全部 `BR_DEAD_REPLY`。

**修复**：删掉设备 rc 里整个 binderfs 块。Android 13 时代（aospm 模板）这段是
必要的，16 上是事故源。已在部署的 vendor 分区上做等长原位补丁
（首字符改 `#`，561 字节不变——vendor 镜像同样 0 空闲块，等长改写不触发分配）。

### 8.3bis 第六、第七个真问题：/data 没人挂载 + 关键驱动全是 =m

binderfs 修掉后 binder 全通（失败 0 行），vdc 秒过，init 跑到 81 秒。
同一份日志暴露两个并列的新问题：

**⑥ `/data` 永远不挂载 —— mount_all 是设备 rc 的职责，我们没写**

```
init: Command 'mkdir /data/bootchart ...' failed: mkdir() failed: Read-only file system
（post-fs-data 所有 mkdir 全报 EROFS —— 打在只读 system 根的 /data 空目录上）
init: Service 'keystore2' (pid 607) received SIGABRT   ← /data/misc/keystore 不存在
```

日志里 `mount_all` 出现 **0 次**。AOSP 16 的 `init.rc:511-520` 注释明说：
"Mount fstab in **init.{$device}.rc** by mount_all command" —— init.rc 自己不调。
fstab 在 `/vendor/etc/fstab.gaokun3` 躺着没人用。

**修复**（设备 rc 加两段）：

```
on fs
    mount_all /vendor/etc/fstab.gaokun3 --early
on late-fs
    mount_all /vendor/etc/fstab.gaokun3 --late
```

**⑦ buildbot defconfig 是 Ubuntu 取向，关键驱动全是 =m，Android 没有模块**

```
platform a400000.usb: deferred probe pending: dwc3: failed to initialize core
platform a600000.usb: deferred probe pending: dwc3: failed to initialize core   ← adb 的 UDC
platform a800000.usb: deferred probe pending: dwc3: failed to initialize core
qnoc-sc8280xp ...: sync_state() pending due to a9c000.i2c                        ← EC 的 I2C 总线没 probe
platform 18591000.cpufreq: deferred probe pending: Failed to find icc paths
```

**三个 dwc3 全灭 = 系统性问题。** 对照法定位：同一台机器上老内核的 Ubuntu
一切正常 —— 差别是 Ubuntu 从 `/lib/modules` 加载了模块。`lsmod` 是权威：

| Ubuntu 在用的模块 | config 名（从 Makefile 反查，≠模块名！）| 后果 |
|---|---|---|
| `i2c_qcom_geni` | `CONFIG_I2C_QCOM_GENI` | EC / 触摸的 I2C 总线不 probe |
| `phy_qcom_snps_femto_v2` | `CONFIG_PHY_QCOM_USB_SNPS_FEMTO_V2` | dwc3 拿不到 USB2 PHY，core init 失败 |
| `qcom_refgen_regulator` | `CONFIG_REGULATOR_QCOM_REFGEN` | QMP PHY 供电缺失 |
| `icc_osm_l3` | `CONFIG_INTERCONNECT_QCOM_OSM_L3` | cpufreq 找不到 icc path |
| `nvmem_qcom_spmi_sdam` | `CONFIG_NVMEM_SPMI_SDAM` | RTC 等 nvram supplier |
| `spi_geni_qcom` | `CONFIG_SPI_QCOM_GENI` | 触摸屏走 SPI（Stage 4 前置）|
| `pwrseq_qcom_wcn` | `CONFIG_POWER_SEQUENCING_QCOM_WCN` | WiFi/BT 上电（Stage 4 前置）|

全部翻成 `=y`（已进 `scripts/kernel-config-android.sh`）。

**方法论**：查"驱动是不是模块"，不要信 `/sys/.../driver/module` 符号链接
（内建驱动也可能有），**以 `lsmod` 为准**；config 名从对应 `Makefile` 的
`obj-$(CONFIG_XXX) += 模块名.o` 反查，二者经常不一致。

### 8.3ter 第八个真问题：keystore2 无 KeyMint 崩溃循环，经 vdc 绞死整个 boot

驱动修复（=y 那轮）生效后：`/data` 挂上、EC/i2c probe、无 deferred pending。
但 boot 停在 30 秒——keystore2（critical）崩 4 次触发 `InitFatalReboot`。
这次 `init_fatal_panic` 精确触发（`sysrq: Trigger a crash`），
⚠️ 但 **efi_pstore 在 panic 上下文没写成**（pstore 仍空——TrustZone efivars
路径疑似不能在 panic 里用，待查）。tombstone 也全是 0 字节（tombstoned 同死）。

**解除 critical（等长注释）后真相浮现**：Android 稳定运行 151 秒不复位，
keystore2 崩 52 次，但 adbd/zygote 依然无影无踪。Action 时间线锁定：

```
init: SVC_EXEC 'exec 4 (/system/bin/vdc keymaster earlyBootEnded)' started; waiting...
（永不返回 —— vdc 经 binder 调 keystore2，而 keystore2 在崩溃循环里）
```

init.rc 的这个 **exec（同步等待）** 排在 post-fs-data 里，它不返回，
后面的 zygote-start / on boot / adbd 全部排不上队。
**keystore2 起不来 = boot 绞死，critical 与否只决定复不复位。**

**根因**：我们的 device.mk"能不装一律不装"，一个 HAL 都没带，
keystore2 找不到任何 KeyMint 实例，启动即 Rust panic（消息进 logcat，拿不到）。

**修复**（cuttlefish 同款软件实现，包名从 Android.bp 核实）：

```makefile
PRODUCT_PACKAGES += \
    com.android.hardware.keymint.rust_nonsecure \      # keymint/aidl/default/Android.bp:183
    com.android.hardware.gatekeeper.nonsecure          # gatekeeper/aidl/software/Android.bp:64
```

（gatekeeper 是预防性的——Stage 3 锁屏/框架要用，省一轮重编。）

顺带：BPF_LSM 依赖链上 **buildbot config 连 FTRACE 都是关的**，
`--enable BPF_EVENTS` 静默不生效——先开 FTRACE/KPROBE_EVENTS/UPROBE_EVENTS
才能连锁成立。`scripts/config --enable` 对依赖不满足的项不报错，
**改完必须 olddefconfig 后 grep 验证**。

### 8.3quater 第九个问题：/vendor/etc/init/hw/ 不被自动扫描

keymint 修好后 boot 全通（zygote/adbd/usbd 都起来了），但 USB 无枚举。
日志里 `init.gaokun3.usb` **零命中** —— 这个 rc 从未被解析过：
init 自动扫的是 `/vendor/etc/init/`，**`hw/` 子目录必须被显式 import**。
`sys.usb.configfs` 恒为 0 → 触发走 legacy android_usb 分支（主线无此 sysfs）。

**修复**：`init.gaokun3.rc` 顶部加
`import /vendor/etc/init/hw/init.gaokun3.usb.rc`。

### 8.3quinquies 第十、十一个问题：usb rc 顺序 + gadget 栈整个在模块里

import 修好后 rc 跑了，暴露两层：

**⑩ functionfs mount 在实例创建之前**——`mount functionfs adb ...` 在
post-fs-data，而 `mkdir functions/ffs.adb`（注册实例）原在 on boot。
实例不存在 mount 必 ENODEV。骨架整体挪到 post-fs-data 的 mount 之前。

**⑪ tristate 父级陷阱（第 7 个坑的深水变体）**——顺序修好后仍 ENODEV：

```
CONFIG_USB_CONFIGFS=m        ← 父级（tristate）
CONFIG_USB_LIBCOMPOSITE=m
CONFIG_USB_F_FS=m            ← functionfs 文件系统类型的注册者
CONFIG_USB_CONFIGFS_F_FS=y   ← 我们验证时看的是它 —— bool 子开关，被骗
```

`--enable USB_CONFIGFS_F_FS` 后 grep 到 `=y` 就以为完事——但它是模块内
子开关，父级 `=m` 时整个 gadget 栈都不在内核里。`mount(2)` 对
**未知文件系统类型**返回的同样是 ENODEV，与"实例不存在"无法区分。

**教训：验证 config 必须看 tristate 父级（USB_CONFIGFS / USB_LIBCOMPOSITE /
USB_F_FS），bool 子项的 =y 不代表代码进了内核。**

**⑫ UCSI 会把 otg 口切成 host**——上上轮日志 `xhci-hcd ... io mem 0x0a600000`：
新内核 EC/UCSI 内建后接管了角色，port 被切成 host（对端 PC 也是 host →
电气零事件）。运行时接口 `/sys/class/usb_role/a600000.usb-role-switch/role`
可写且稳定（Ubuntu 实测），usb rc 在 post-fs-data + boot 各写一次 `device`。

### 8.5 Stage 3 冲刺段的问题清单（13–19 号，全部实测定位）

| # | 问题 | 实锤证据 | 修复 |
|---|---|---|---|
| 13 | AOSP 树内 mesa3d 无 freedreno，BOARD_MESA3D_* 无消费者 | 全树 grep 零命中 | Phase A 用 swangle（ANGLE+SwiftShader），Phase B 引 GloDroid 胶水 |
| 14 | ANGLE 库在 /system/lib64 根，开关是 persist.graphics.egl | Loader.cpp:67 | 设该属性 |
| 15 | SwiftShader 吃不下 UBWC buffer | GaneshBackendTexture tombstone | vendor.minigbm.debug=nocompression |
| 16 | msm KMS 是 card1（simpledrm 占过 card0），hwc 扫 card0 无头 | "No pipelines available" | vendor.hwc.drm.device=/dev/dri/card1 |
| 17 | 调试包装器 fd3 泄漏毒杀 zygote | "Not allowlisted (3): /init.out" | v18 包装器 spawn cat 后 exec 3>&- |
| 18 | 主线无 ashmem，A16 的 memfd 兼容探测又需要 ACK shim | ioctl 探测失败 | 从 ACK 移植 staging ashmem 驱动（2 处 API 漂移修正）|
| 19 | audioserver 全链（HAL apex→effects 配置→policy xml→AMS 时序）| 逐层 ANR/栈实锤 | com.android.hardware.audio APEX + use_default_audio_effects_config + cuttlefish policy xml 六件套 |
| 20 | netd 需 xt_policy/quota/quota2（quota2 是 ACK 专有）| "Extension policy revision 0" | xt 全族 =y + 移植 xt_quota2 |
| 21 | NetworkStats 的 synchronizeKernelRCU 用 AF_KEY socket | errno -97 EAFNOSUPPORT | CONFIG_NET_KEY=y（平行项目 defconfig 预告过）|
| 22 | 慢设备时序无余量，60s 看门狗击杀 cycle-1 | ANR：AudioService 等发布 | ro.hw_timeout_multiplier=5 |
| 23 | dalvik 堆默认 16MB，boot 后 system_server OOM | OutOfMemoryError growth limit 16777216 | 继承 tablet-10in dalvik-heap.mk |
| 24 | 无硬件 feature 声明，AppWidgetService 缺席，Launcher NPE | getInstalledProviders null | tablet_core_hardware.xml |
| 25 | 闲置 52s s2idle 休眠后不醒（CLAUDE.md 预言的 EC 坑）| "PM: suspend entry" 为日志绝笔 | 临时 svc power stayon；Stage 4 正修 |

**Stage 3 验收（2026-08-17）：Android 桌面完整渲染，SystemUI + Launcher3 稳定。**

### 8.4 顺带确认的两件事

- **`androidboot.usbcontroller` 现代 AOSP 已不读取** —— `strings` 在 AOSP 16 的
  init 里找不到这个串。stage2-plan.md §6 标的"[待确认]"到此有答案：不需要，已删。
- **Android 的 DTB 与 `dtb-otg.dtb` 字节相同** —— `dr_mode="otg"` +
  `usb-role-switch` 在位，且无 ramoops 节点。adb 的硬件前提没问题。
