#!/usr/bin/env bash
#
# 把 buildbot 的 gaokun3_defconfig 调整成能跑 Android 的配置。
# 在内核源码树里执行：bash kernel-config-android.sh <kernel-out-dir>
#
# 每一项都是实测必需，依据见 docs/stage2-findings.md。
set -u
OUT="${1:?用法: $0 <kernel-out-dir>}"

./scripts/config --file "$OUT/.config" \
    `# —— 动态分区：first-stage init 在 ramdisk 里就要用 DM，而 ramdisk 里没有模块 ——` \
    --enable BLK_DEV_DM --enable DM_VERITY --enable DM_BUFIO --enable DM_SNAPSHOT \
    \
    `# —— SELinux：Android 硬性依赖 ——` \
    --enable SECURITY --enable SECURITY_NETWORK --enable AUDIT \
    --enable SECURITY_SELINUX --enable SECURITY_SELINUX_BOOTPARAM \
    --enable SECURITY_SELINUX_DEVELOP --enable SECURITY_SELINUX_AVC_STATS \
    \
    `# —— 调试通道：本机无串口，崩溃日志只能走 EFI 变量 ——` \
    --enable PSTORE --enable PSTORE_RAM --enable PSTORE_CONSOLE --enable PSTORE_PMSG \
    --disable PSTORE_COMPRESS --enable EFI_VARS_PSTORE \
    --enable MAGIC_SYSRQ --enable DEBUG_FS \
    \
    `# —— adb / USB gadget ——` \
    `# ⚠️ USB_CONFIGFS_F_FS 等只是 tristate 父级下的 bool 子开关，` \
    `#    父级 =m 时它们照样显示 =y 但整个栈都在模块里 —— Android 无模块，` \
    `#    functionfs mount 报 ENODEV（未知文件系统类型同样是 ENODEV！）。` \
    `#    三个父级必须显式 =y。实测见 findings 第 8.3quinquies 节。` \
    --enable CONFIGFS_FS --enable USB_LIBCOMPOSITE --enable USB_CONFIGFS --enable USB_F_FS \
    --enable USB_CONFIGFS_F_FS --enable USB_CONFIGFS_ACM \
    --enable USB_CONFIGFS_MASS_STORAGE --enable USB_CONFIGFS_ECM \
    --enable USB_CONFIGFS_RNDIS --enable USB_CONFIGFS_EEM \
    --enable OVERLAY_FS \
    \
    `# —— cgroup v1：6.12+ 拆分后默认关。Android cgroups.json 要求 cpuset 走 v1，` \
    `#    缺了会 SetupCgroups 失败 -> bootstrap-apexd-failed 复位（findings 第 8 节）——` \
    --enable CPUSETS_V1 --enable MEMCG_V1 \
    --enable UCLAMP_TASK --enable UCLAMP_TASK_GROUP \
    \
    `# —— buildbot defconfig 是 Ubuntu 取向：以下关键驱动全是 =m，` \
    `#    而 Android 侧没有任何模块加载机制，必须 =y。` \
    `#    实测后果（findings 第 8.3bis 节）：三个 dwc3 全部` \
    `#    "failed to initialize core"（缺 femto USB2 PHY + refgen 供电），` \
    `#    a9c000.i2c 不 probe -> EC 全灭，cpufreq 找不到 icc path。` \
    `#    名字全部从 Makefile 反查核实过，模块名 != config 名：` \
    `#      i2c_qcom_geni          -> I2C_QCOM_GENI` \
    `#      phy_qcom_snps_femto_v2 -> PHY_QCOM_USB_SNPS_FEMTO_V2` \
    `#      nvmem_qcom-spmi-sdam   -> NVMEM_SPMI_SDAM` \
    `#      spi_geni_qcom          -> SPI_QCOM_GENI` \
    --enable I2C_QCOM_GENI --enable PHY_QCOM_USB_SNPS_FEMTO_V2 \
    --enable REGULATOR_QCOM_REFGEN --enable INTERCONNECT_QCOM_OSM_L3 \
    --enable NVMEM_SPMI_SDAM --enable SPI_QCOM_GENI \
    --enable POWER_SEQUENCING_QCOM_WCN \
    \
    `# —— 前瞻项（来自平行项目 mainline-generic 的 gaokun3 fragment，` \
    `#    docs/parallel-mainline-generic.md）。netd/bpfloader/lmkd 到位后必炸的：` \
    --enable NETFILTER_XTABLES --enable IP_NF_IPTABLES --enable IP_NF_FILTER \
    --enable IP_NF_TARGET_REJECT --enable IP6_NF_IPTABLES --enable IP6_NF_FILTER \
    --enable IP6_NF_TARGET_REJECT --enable NETFILTER_XT_MATCH_BPF \
    --enable NETFILTER_XT_MATCH_OWNER --enable NETFILTER_XT_MATCH_MARK \
    --enable NETFILTER_XT_TARGET_IDLETIMER --enable NETFILTER_XT_TARGET_MARK \
    --enable KPROBES --enable BPF_EVENTS --enable BPF_LSM --enable BPF_JIT_ALWAYS_ON \
    \
    `# —— 框架/内存管理（同上来源）——` \
    --enable ZRAM --enable ZRAM_BACKEND_LZ4 --enable ZRAM_BACKEND_ZSTD \
    --enable ZRAM_WRITEBACK --enable ZRAM_MULTI_COMP \
    --enable INPUT_UINPUT --enable CFS_BANDWIDTH --enable TASK_DELAY_ACCT \
    --enable DM_UEVENT --enable DM_VERITY_FEC --enable DM_CRYPT \
    --enable FS_ENCRYPTION --enable FS_VERITY \
    --enable EROFS_FS --enable EROFS_FS_XATTR --enable EROFS_FS_POSIX_ACL \
    --enable F2FS_FS --enable F2FS_FS_XATTR --enable F2FS_FS_POSIX_ACL \
    --enable F2FS_FS_SECURITY
    `# ⚠️ 不要抄 DM_DEFAULT_KEY（android-common 专有，主线没有）`

# ─── Stage 4: WiFi + BT 全栈 =y（Android 无模块加载，第 11 次踩 =m 坑）───
#   PCI_PWRCTRL_PWRSEQ 是无提示隐藏项，由 ATH11K_PCI select（含 HAVE_PWRCTRL 链），
#   =m 时 WCN6855 无人上电 → PCI 域 0006 整个不枚举。
#   ⚠️ olddefconfig 必须带 ARCH=arm64，否则按 x86 Kconfig 重算会删光 arm64 符号！
./scripts/config --file "$OUT/.config" \
    --enable CFG80211 --enable MAC80211 --enable RFKILL \
    --enable ATH_COMMON --enable ATH11K --enable ATH11K_PCI \
    --enable QRTR --enable QRTR_MHI --enable QRTR_SMD --enable QRTR_TUN \
    --enable MHI_BUS --enable MHI_BUS_PCI_GENERIC \
    --enable QCOM_QMI_HELPERS --enable PCI_PWRCTRL_PWRSEQ \
    --enable BT --enable BT_BREDR --enable BT_LE \
    --enable BT_QCA --enable BT_HCIUART
    `# BT_HCIUART_QCA 已默认 y（在 BT_HCIUART 之下）`

# ★ 最关键也最容易漏的一步：
#   CONFIG_SECURITY_SELINUX=y 只是「编进内核」，不等于「被激活」。
#   真正决定哪些 LSM 生效的是 CONFIG_LSM 这个字符串。
#   buildbot 的默认值里只有 apparmor，没有 selinux，
#   结果 selinuxfs 从不注册，Android init 在 selinux_setup 阶段静默死亡。
#   SELinux 和 AppArmor 都是 major LSM，当前内核不能同时激活，必须去掉 apparmor。
./scripts/config --file "$OUT/.config" \
    --set-str LSM "landlock,lockdown,yama,integrity,selinux,bpf"

echo "已写入 $OUT/.config，请执行 olddefconfig 后检查："
echo "  grep -E '^CONFIG_(BLK_DEV_DM|SECURITY_SELINUX|LSM|USB_CONFIGFS_F_FS)=' $OUT/.config"
echo
echo "启动后必须在运行时复验（只看 config 会误判）："
echo "  cat /sys/kernel/security/lsm       # 必须包含 selinux"
echo "  ls -d /sys/fs/selinux              # 必须存在"
echo "  ls -l /dev/mapper/control          # 必须存在"
