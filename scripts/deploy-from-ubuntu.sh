#!/usr/bin/env bash
# 在 Ego 的 Ubuntu 上跑：从构建机拉产物 → 刷 super → 换内核/DTB/ramdisk → 回 Android
#
# 用法（在 Ego 的 Ubuntu 里）：
#   bash deploy-from-ubuntu.sh [all|super|boot|rollback]
#     all      （默认）super + 内核 + DTB + ramdisk 全刷
#     super    只刷 super.img
#     boot     只换内核/DTB/ramdisk（不动 super）
#     rollback 刷回 Stage 5 那套能用的 AOSP 16（构建机 ~/keep/aosp16-images/）
#              —— turnip + 声音 + 蓝牙都在里面，十来分钟回到换轨前状态
#
# 源码树用环境变量切：SRC_TREE=~/aosp 可回到旧的 AOSP 树。
#   SRC_TREE=~/aosp bash deploy-from-ubuntu.sh super
#
# 前提：Ego 已有直连构建机的 ssh 钥匙（vahiru@<BUILD_VM>），
#       ESP 挂在 /boot/efi，Android 目录是 <machine-id>/android/。
set -euo pipefail

VM=vahiru@<BUILD_VM>
# Stage 6 起默认从 crDroid 树取产物（旧 AOSP 树已删，归档在构建机 ~/keep/）
#
# ⚠️ 这两个路径里的 ~ 必须保持【字面量】，不能让本地 shell 展开：
#    它们是【构建机】上的路径（/home/vahiru），而脚本跑在 Ego（/home/user）。
#    展开了就会去 scp vahiru@vm:/home/user/... —— 必然找不到。
#    pull() 把路径整个交给 scp，由远端 shell 展开 ~。
SRC_TREE=${SRC_TREE:-'~/crdroid'}
OUT=$SRC_TREE/out/target/product/gaokun3
KEEP='~/keep/aosp16-images'
MID=8a29534fa802480d9fbb71aa18c01d7b
ESP=/boot/efi/$MID/android
SUPER_PART=/dev/nvme0n1p8
MODE=${1:-all}
# ENTRY 提前定义：flash_boot 要靠它找到条目实际引用的文件名
ENTRY=${ENTRY:-$MID-crdroid.conf}

pull() {  # pull <远端文件> <本地目标>
  echo "拉取 $(basename "$1") …"
  scp -o BatchMode=yes -q "$VM:$1" "$2"
}

flash_super() {
  pull "$OUT/super.img" /tmp/super.img
  echo "super sha1: $(sha1sum /tmp/super.img | cut -c1-12)"
  # ⚠️ super.img 是 Android sparse 格式，必须 simg2img 展开，不能 dd
  sudo -n simg2img /tmp/super.img "$SUPER_PART"
  sync
  echo "super 已写入 $SUPER_PART"
}

flash_boot() {
  # ⚠️⚠️ 目标文件名【必须从 BLS 条目里读】，不能写死（2026-08-20 M5 发现）。
  #
  # 这个函数原先硬编码写 $ESP/Image 与 $ESP/ramdisk.img —— 那是【旧 AOSP】
  # 条目 android.conf 用的文件名。crDroid 的 crdroid.conf 用的是
  # Image-kb23 与 ramdisk-crdroid.img。于是 `deploy-from-ubuntu.sh all`
  # 会把新内核/新 ramdisk 写到【没人读的文件】上，然后打印"已更新"。
  # 结果就是 M3 那个坑的镜像版：一切显示成功，实机跑的却是旧内核。
  # 改成从条目文件里解析 linux/initrd/devicetree 三行，永远不会漂。
  local conf="/boot/efi/loader/entries/$ENTRY"
  [ -f "$conf" ] || { echo "找不到启动项 $conf"; exit 1; }
  local k_rel i_rel d_rel
  k_rel=$(awk '$1=="linux"      {print $2}' "$conf")
  i_rel=$(awk '$1=="initrd"     {print $2}' "$conf")
  d_rel=$(awk '$1=="devicetree" {print $2}' "$conf")
  local K="/boot/efi$k_rel" I="/boot/efi$i_rel" D="/boot/efi$d_rel"
  echo "条目 $ENTRY 实际读取的文件："
  echo "  内核   $K"
  echo "  ramdisk $I"
  echo "  DTB    $D"

  pull "~/gaokun/kernel-out/arch/arm64/boot/Image" /tmp/Image
  pull "~/gaokun/kernel-out/arch/arm64/boot/dts/qcom/sc8280xp-huawei-gaokun3.dtb" /tmp/gk3.dtb
  pull "$OUT/ramdisk.img" /tmp/ramdisk.img

  for f in "$K" "$I" "$D"; do
    [ -f "$f" ] && sudo -n cp "$f" "$f.bak-prev"
  done
  sudo -n cp /tmp/Image       "$K"
  sudo -n cp /tmp/ramdisk.img "$I"
  sudo -n cp /tmp/gk3.dtb     "$D"
  sync
  echo "内核 / DTB / ramdisk 已写入【条目实际引用的路径】"
  echo "  ⚠️ 起来后必须核对：adb shell uname -a 的编译时间要与本次内核一致"
}

flash_rollback() {
  # 回到换轨前那套 AOSP 16（归档于构建机，sha256 校验过）。
  # 内核/DTB 不用换：crDroid 与 AOSP 用的是同一个 kb21 内核。
  echo "════ 回退到 Stage 5 的 AOSP 16 ════"
  pull "$KEEP/super.img"   /tmp/super-rollback.img
  pull "$KEEP/ramdisk.img" /tmp/ramdisk-rollback.img
  sudo -n simg2img /tmp/super-rollback.img "$SUPER_PART"
  sudo -n cp /tmp/ramdisk-rollback.img "$ESP/ramdisk.img"
  [ -f "$ESP/ramdisk-debug.img" ] && sudo -n cp /tmp/ramdisk-rollback.img "$ESP/ramdisk-debug.img"
  sync
  echo "已回退。注意 /data 里是 crDroid 写的数据，AOSP 起不来就清 userdata："
  echo "  sudo mkfs.ext4 -F /dev/disk/by-partlabel/userdata"
  echo "  然后重启进 Android 后跑 scripts/android-post-flash.sh"
}

case "$MODE" in
  all)   flash_boot; flash_super ;;
  rollback) flash_rollback ;;
  super) flash_super ;;
  boot)  flash_boot ;;
  *) echo "未知模式: $MODE（all|super|boot|rollback）"; exit 2 ;;
esac

# ⚠️⚠️ 这里【不再】改默认启动项，而是设 oneshot（2026-08-19 M3 血泪）。
#
# 旧写法把默认改成 $MID-android.conf，两个后果：
#   1. ★ 条目就错了 —— android.conf 指向的是【旧 AOSP 的】Image(kb18) +
#      ramdisk.img。crDroid 有自己的条目 $MID-crdroid.conf
#      （Image-kb23 + ramdisk-crdroid.img）。用错条目的表现极具迷惑性：
#      能起来、adb 能连、getprop 都对，但内核是不带 patches/0007 的旧核 →
#      bpffs 标签问题回归 → system_server 崩溃循环、永远到不了 boot_completed。
#      查的时候会一路怀疑刚换的 turnip，其实跟 GPU 毫无关系。
#      判据：`adb shell uname -a` 的编译时间必须与本次内核一致。
#   2. 破坏"默认留 Ubuntu"这条运维约定 —— 默认是 Ubuntu 时，Android 挂死
#      拍一下电源键就自动回落到能远程接入的系统；默认改成 Android 就没有
#      这个安全网了，而本机没有串口。
#
# 补救手段（万一又踩到）：Android 起来但卡住时，adb 里两步拿 root——
#   adb shell setprop service.adb.root 1 && adb root
# 然后 `mount -t vfat -o rw /dev/block/sda1 /mnt/usb` 直接改 ESP 上的
# loader.conf（引导 ESP 是 U 盘 = sda1，不是内置盘的 nvme0n1p1）。
sudo -n bootctl set-oneshot "$ENTRY" && echo "下次启动 → $ENTRY（一次性，默认仍是 Ubuntu）"
echo
echo "现在重启：sudo systemctl reboot"
echo "起来后建议验证："
echo "  adb shell 'dmesg | grep -iE \"zap|adreno\" | tail -5'          # zap shader 应无报错"
echo "  adb shell 'getprop ro.hardware.vulkan; ls /vendor/lib64/hw/'  # 应为 freedreno"
echo "  adb shell 'cat /proc/asound/cards'                            # 应能看到声卡"
echo "  bash scripts/android-post-flash.sh                            # /data 侧置备"
