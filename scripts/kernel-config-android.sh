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
    --enable BT_QCA --enable BT_HCIUART \
    --enable USB_STORAGE --enable USB_UAS
    `# BT_HCIUART_QCA 已默认 y（在 BT_HCIUART 之下）`
    `# USB_STORAGE/UAS：Android 下能看见 USB 棒上的 Ubuntu ESP，`
    `# 维护引导项/DTB 不用重启（kb18 仍是 =m，kb19 转正）`

# ★ 最关键也最容易漏的一步：
#   CONFIG_SECURITY_SELINUX=y 只是「编进内核」，不等于「被激活」。
#   真正决定哪些 LSM 生效的是 CONFIG_LSM 这个字符串。
#   buildbot 的默认值里只有 apparmor，没有 selinux，
#   结果 selinuxfs 从不注册，Android init 在 selinux_setup 阶段静默死亡。
#   SELinux 和 AppArmor 都是 major LSM，当前内核不能同时激活，必须去掉 apparmor。
./scripts/config --file "$OUT/.config" \
    --set-str LSM "landlock,lockdown,yama,integrity,selinux,bpf"

# ─── Stage 5: 音频链 + 蓝牙 profile + 温控（第 12 次踩 =m 坑）───
#   ★声卡不注册的真正源头：LPASS 的 pinctrl 是 =m。
#     rx/tx/wsa macro 的 pinctrl-0 指向 /soc@0/pinctrl@33c0000 下的
#     *-swr-default-state，fw_devlink 因此把 33c0000.pinctrl 当成 supplier；
#     驱动是模块 → 永不加载 → macro 永远 deferred → soundwire 等 macro →
#     sound 节点等 DAI → /proc/asound/cards 里 "no soundcards"。
#     实测 dmesg 原话：
#       platform 3200000.rxmacro: deferred probe pending:
#         platform: wait for supplier /soc@0/pinctrl@33c0000/rx-swr-default-state
#   SC_LPASSCC_8280XP：LPASS 时钟控制器，macro 的 mclk/npl 从这来。
#   SND_SOC_WSA883X：本机扬声器 wsa8830（DT compatible sdw10217020200
#     = mfg 0x0217 part 0x0202，与 ThinkPad X13s 同款），**原本压根没编**。
#   QRTR_SMD：QRTR 的 rpmsg 传输，pd-mapper 靠它跟 ADSP 说话
#     （之前虽写了 --enable 却仍是 =m —— 所以下面加了断言）。
#   BT：内核侧 hci0 已经能出来（BT_QCA + HCIUART_QCA 都是 y），
#     但 RFCOMM/HIDP/UHID 是 =m → 蓝牙键鼠/串口 profile 全废。
#   温控/带宽：QCOM_SPMI_ADC5 等是 =m → PMIC 温度传感器缺席；
#     ICC_BWMON 关系到内存带宽随负载升频（打游戏要）。
./scripts/config --file "$OUT/.config" \
    `# ★声卡链` \
    --enable PINCTRL_LPASS_LPI --enable PINCTRL_SC8280XP_LPASS_LPI \
    --enable SC_LPASSCC_8280XP --enable SND_SOC_WSA883X \
    --enable QRTR_SMD \
    `# 蓝牙 profile（hci0 已通，缺的是这些）` \
    --enable BT_RFCOMM --enable BT_RFCOMM_TTY --enable BT_HIDP --enable UHID \
    --enable HID_MULTITOUCH \
    `# 温度传感器 + 内存带宽调频 + 电源统计` \
    --enable IIO --enable QCOM_SPMI_ADC5 --enable QCOM_VADC_COMMON \
    --enable QCOM_SPMI_TEMP_ALARM --enable QCOM_ICC_BWMON \
    --enable QCOM_LMH --enable QCOM_SPM --enable QCOM_STATS --enable QCOM_SOCINFO \
    `# Android 基础设施：FUSE（外部存储）、熵源、AF_ALG` \
    --enable FUSE_FS --enable HW_RANDOM --enable HW_RANDOM_ARM_SMCCC_TRNG \
    --enable CRYPTO_USER_API --enable CRYPTO_USER_API_HASH \
    --enable CRYPTO_USER_API_SKCIPHER --enable CRYPTO_HMAC \
    --enable CRYPTO_SHA512 --enable CRYPTO_CMAC --enable CRYPTO_CRC32C \
    --enable CRYPTO_AES_ARM64_NEON_BLK --enable CRYPTO_AES_ARM64_BS \
    `# 杂项：外置盘、键盘灯、GENI DMA、i2c 调试` \
    --enable EXFAT_FS --enable LEDS_CLASS --enable INPUT_LEDS \
    --enable QCOM_GPI_DMA --enable I2C_CHARDEV --enable RESET_QCOM_PDC

# ★ 蓝牙栈起不来的真凶（与 HAL 无关）：RT cgroup 带宽管制。
#   实测报错：
#     bluetooth: message_loop_thread.cc:291 EnableRealTimeScheduling:
#       unable to set SCHED_FIFO priority 1 for bt_main_thread, error: Operation not permitted
#     → bluetooth::log::fatal → com.android.bluetooth abort → 开关蓝牙即崩溃循环
#   CONFIG_RT_GROUP_SCHED=y + CGROUP_SCHED 时，非 root cpu cgroup 的
#   rt_runtime_us 默认是 0 → 该 cgroup 里任何 sched_setscheduler(SCHED_FIFO)
#   一律 EPERM。Android 从不用 RT cgroup，GKI 里这项是关的。
#   （6.12+ 也可用 RT_GROUP_SCHED_DEFAULT_DISABLED，但直接关更干净。）
./scripts/config --file "$OUT/.config" --disable RT_GROUP_SCHED

# ─── olddefconfig + 断言（止损"=m 坑"）───
# 这个坑已经踩了 12 次：`scripts/config --enable X` 写进去了，olddefconfig
# 却可能因为依赖把它降回 =m（或压根没有该符号），而 Android **不加载任何模块**
# （/vendor/lib/modules 不存在、lsmod 为空），于是驱动静默缺席。
# 所以：olddefconfig 由脚本自己跑（顺手把 ARCH=arm64 这个致命参数固定住），
# 跑完立刻断言关键符号必须是 y，不是就非零退出。
echo "== 跑 olddefconfig（ARCH=arm64 必带，否则 arm64 符号会被删光）=="
make ARCH=arm64 O="$OUT" olddefconfig >/dev/null || exit 1

MUST_Y="
BLK_DEV_DM SECURITY_SELINUX EROFS_FS F2FS_FS DM_VERITY
CFG80211 MAC80211 ATH11K ATH11K_PCI PCI_PWRCTRL_PWRSEQ QRTR QRTR_SMD
BT BT_QCA BT_HCIUART BT_HCIUART_QCA BT_RFCOMM BT_HIDP UHID
PINCTRL_LPASS_LPI PINCTRL_SC8280XP_LPASS_LPI SC_LPASSCC_8280XP
SND_SOC_SC8280XP SND_SOC_WSA883X SND_SOC_WCD938X SOUNDWIRE_QCOM
SND_SOC_LPASS_RX_MACRO SND_SOC_LPASS_TX_MACRO SND_SOC_LPASS_VA_MACRO
SND_SOC_LPASS_WSA_MACRO SND_SOC_QDSP6 QCOM_PD_MAPPER
FUSE_FS IIO QCOM_SPMI_ADC5
"
bad=0
for s in $MUST_Y; do
    v=$(grep -E "^CONFIG_$s=" "$OUT/.config" | cut -d= -f2)
    case "$v" in
        y) ;;
        m) echo "  ✗ CONFIG_$s=m  ← Android 不加载模块，必须 =y"; bad=1 ;;
        *) echo "  ✗ CONFIG_$s 缺失/未启用（值='$v'）"; bad=1 ;;
    esac
done
# 反向断言：这些**必须关**，开着会主动破坏 Android
MUST_N="RT_GROUP_SCHED"
for s in $MUST_N; do
    if grep -qE "^CONFIG_$s=(y|m)" "$OUT/.config"; then
        echo "  ✗ CONFIG_$s 开着 —— 必须 =n（见脚本内注释）"; bad=1
    fi
done
# apparmor **编进内核无害**，致命的是它出现在 CONFIG_LSM 里（会挤掉 selinux）
if grep -qE "^CONFIG_LSM=.*apparmor" "$OUT/.config"; then
    echo "  ✗ CONFIG_LSM 里有 apparmor —— 会顶掉 selinux，Android init 静默死亡"; bad=1
fi
if ! grep -qE "^CONFIG_LSM=.*selinux" "$OUT/.config"; then
    echo "  ✗ CONFIG_LSM 里没有 selinux —— selinuxfs 不会注册"; bad=1
fi

if [ $bad -ne 0 ]; then
    echo "断言失败：上面的符号会导致对应硬件静默缺席或功能被内核拒绝。" >&2
    exit 1
fi
echo "== 断言通过：$(echo $MUST_Y | wc -w) 个必须 =y、$(echo $MUST_N | wc -w) 个必须 =n =="

echo "已写入 $OUT/.config，olddefconfig 已跑，可继续检查："
echo "  grep -E '^CONFIG_(BLK_DEV_DM|SECURITY_SELINUX|LSM|USB_CONFIGFS_F_FS)=' $OUT/.config"
echo
echo "启动后必须在运行时复验（只看 config 会误判）："
echo "  cat /sys/kernel/security/lsm       # 必须包含 selinux"
echo "  ls -d /sys/fs/selinux              # 必须存在"
echo "  ls -l /dev/mapper/control          # 必须存在"
