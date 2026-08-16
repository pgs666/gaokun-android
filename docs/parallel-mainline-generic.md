# 平行进度：mainline-generic 的 gaokun3 支持（他人分享）

日期：2026-08-17
来源：其他开发者分享的 5 个 patch（原件在 `refs/shared-patches/`，不进版本库）

## 这是什么

**LineageOS 系的 "mainline-generic" 项目**（`device/mainline/generic`）——
面向任意 UEFI PC 的通用 Android 发行：GRUB live-ISO 引导、
`rdinit=/system/bin/generic_init` 预初始化、运行时硬件探测（DMI + 设备树）、
从 live 介质 loop 挂载 system。patch 5 把它从 x86_64 扩展到 arm64，
**首个 arm64 目标就是 gaokun3**，内核用的正是我们同款
`linux-gaokun-buildbot`（作者路径 `/home/cool/gaokun/linux-gaokun-buildbot`）。

作者：Yumi Yukimura <me.cafebabe@gmail.com>（patch 1–4，通用侧）、
cool（patch 5，gaokun3 侧，WIP）。

> CLAUDE.md 说本项目是 gaokun 社区与 Android 的"第一个连接点"——
> 现在有第二个了，且路线互补：他们做免安装 live-ISO，我们做安装式
> AOSP 16 + 动态分区。

## 交叉验证：他们独立撞出了和我们相同的结论

他们的 `gaokun3-android.config` 与我们 stage2-findings 的重合项：

| 结论 | 我们（实测踩坑得出）| 他们（fragment 直接带上）|
|---|---|---|
| cgroup v1 拆分坑 | §8：CPUSETS_V1/MEMCG_V1 | ✅ 同款两项 |
| uclamp | task_profiles 引用 | ✅ UCLAMP_TASK(_GROUP) |
| LSM 列表必须含 selinux、去 apparmor | §3 | ✅ `CONFIG_LSM="...selinux,bpf"` + 显式关 APPARMOR |
| binder 三设备 + binderfs | —— | ✅ 同款 |

**两边独立得出相同配置 = 这些结论可信度极高。**

## 他们有、我们还没有的（= 我们的未来坑清单）

对照实测（`scripts/` 下按本机 config 逐项 diff），我们缺的按用途分组：

### netd / bpfloader 会炸的（预计是我们过了 zygote 后的下一批阻塞）

```
CONFIG_NETFILTER_XTABLES=y        ← 我们 =m，Android 没模块！
CONFIG_IP_NF_IPTABLES/FILTER/TARGET_REJECT=y     （IP6 同）
CONFIG_NETFILTER_XT_MATCH_BPF/OWNER/MARK=y
CONFIG_NETFILTER_XT_TARGET_IDLETIMER/MARK=y
CONFIG_KPROBES=y  CONFIG_BPF_EVENTS=y  CONFIG_BPF_LSM=y
CONFIG_BPF_JIT_ALWAYS_ON=y
```

### 框架/内存管理

```
CONFIG_ZRAM=y (+BACKEND_LZ4/ZSTD/LZO, WRITEBACK, MULTI_COMP)   ← lmkd/swap
CONFIG_INPUT_UINPUT=y
CONFIG_CFS_BANDWIDTH=y  CONFIG_TASK_DELAY_ACCT=y
CONFIG_DM_UEVENT=y  CONFIG_DM_VERITY_FEC=y  CONFIG_DM_CRYPT=y
CONFIG_FS_ENCRYPTION=y  CONFIG_FS_VERITY=y
CONFIG_EROFS_FS=y (+XATTR/POSIX_ACL)  CONFIG_F2FS_FS=y (+XATTR/ACL/SECURITY)
```

全部已加进 `scripts/kernel-config-android.sh`（下次 spin 自动带上）。

### 不抄的项（核实过不适用）

- `CONFIG_DM_DEFAULT_KEY` —— **android-common 专有，主线没有**
  （grep 主线 `drivers/md/Kconfig` 无此符号）。纯主线做不了 metadata 加密。
- `ISO9660/JOLIET/ZISOFS/UDF`、`EFI_GENERIC_STUB_INITRD_CMDLINE_LOADER`
  —— live-ISO/GRUB 流程专用；后者在新内核里已不存在。

## 他们的 ramdisk 模块清单 = 我们 Stage 3/4 的驱动依赖图

他们走"模块进 ramdisk + modprobe"路线（`modules.load.ramdisk`），
清单直接暴露了后续阶段的依赖链（我们转 =y 时照此办理）：

| 用途 | 模块（他们）| 对应我们的 Stage |
|---|---|---|
| GPU/显示 | `msm.ko`、`panel-himax-hx83121a.ko` | Stage 3 |
| 触摸 | `himax_hx83121a_spi.ko`、`hid-multitouch`、`i2c-hid-of` | Stage 4 |
| WiFi | `ath11k_pci.ko` | Stage 4 |
| DSP/remoteproc | `qcom_q6v5_pas`、`mdt_loader`、`qcom_pd_mapper`、qrtr/glink 全家 | Stage 4 音频 |
| 音频 | `sound/`、soundwire | Stage 4 |

## Stage 3 直接可抄的

- `BOARD_MESA3D_GALLIUM_DRIVERS := freedreno`、`BOARD_MESA3D_VULKAN_DRIVERS := freedreno`
- minigbm：`$(call soong_config_set,minigbm_upstream,platform,all_arm)`
- 他们的 cmdline 与我们几乎逐字相同（都源自 Ubuntu 实测），
  多一个 `psi=1`（我们 PSI 默认开，不需要）。

## 值得回赠社区的（我们有、他们清单里看不出来的）

1. **binderfs 双重挂载事故**（findings §8.3）——他们 generic 树自己管 binderfs
   所以没踩，但任何抄 aospm sdm845 模板的人都会踩。
2. **`BOARD_USES_METADATA_PARTITION` / mount_all 是设备 rc 的职责**（§4、§8.3bis）。
3. **efi_pstore 调试通道 + init_fatal_panic**（§5、§8.2）——他们没串口时同样适用
   （他们 grub.cfg 里还留着 ttyMSM0 串口选项，本机并没有暴露的串口）。
4. **ramoops 在本机固件下不存活**（hw-inventory §7bis）。

## patch 1–4 摘要（通用侧，与我们暂无交集）

- 0001/0002：live-USB 拔插盘技巧（boot 后拔 U 盘、冷启动完成后再插回）。
- 0003：libinit 属性来源 dmi_id → both（DMI + 设备树）——arm64 设备树机型需要。
- 0004：asahi/apple 的 Vulkan 归一化。
