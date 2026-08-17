#!/usr/bin/env bash
# 在 Ego 的 Ubuntu 上跑：从构建机拉产物 → 刷 super → 换内核/DTB/ramdisk → 回 Android
#
# 用法（在 Ego 的 Ubuntu 里）：
#   bash deploy-from-ubuntu.sh [all|super|boot]
#     all   （默认）super + 内核 + DTB + ramdisk 全刷
#     super 只刷 super.img
#     boot  只换内核/DTB/ramdisk（不动 super）
#
# 前提：Ego 已有直连构建机的 ssh 钥匙（vahiru@<BUILD_VM>），
#       ESP 挂在 /boot/efi，Android 目录是 <machine-id>/android/。
set -euo pipefail

VM=vahiru@<BUILD_VM>
OUT=~/aosp/out/target/product/gaokun3
MID=8a29534fa802480d9fbb71aa18c01d7b
ESP=/boot/efi/$MID/android
SUPER_PART=/dev/nvme0n1p8
MODE=${1:-all}

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
  pull "$OUT/../../../../gaokun/kernel-out/arch/arm64/boot/Image" /tmp/Image 2>/dev/null || \
    pull "~/gaokun/kernel-out/arch/arm64/boot/Image" /tmp/Image
  pull "~/gaokun/kernel-out/arch/arm64/boot/dts/qcom/sc8280xp-huawei-gaokun3.dtb" /tmp/gk3.dtb
  pull "$OUT/ramdisk.img" /tmp/ramdisk.img
  sudo -n cp "$ESP/Image" "$ESP/Image.bak-prev" 2>/dev/null || true
  sudo -n cp "$ESP/ramdisk.img" "$ESP/ramdisk.img.bak-prev" 2>/dev/null || true
  sudo -n cp /tmp/Image "$ESP/Image"
  sudo -n cp /tmp/gk3.dtb "$ESP/sc8280xp-huawei-gaokun3.dtb"
  sudo -n cp /tmp/ramdisk.img "$ESP/ramdisk.img"
  # LOG 启动项用的是 ramdisk-debug.img，同步一份，免得两个入口行为不一致
  [ -f "$ESP/ramdisk-debug.img" ] && sudo -n cp /tmp/ramdisk.img "$ESP/ramdisk-debug.img"
  sync
  echo "内核 / DTB / ramdisk 已更新（ramdisk $(stat -c%s /tmp/ramdisk.img) 字节）"
}

case "$MODE" in
  all)   flash_boot; flash_super ;;
  super) flash_super ;;
  boot)  flash_boot ;;
  *) echo "未知模式: $MODE"; exit 2 ;;
esac

# 回到 Android（默认启动项设为 Android，这样以后不用来回折腾）
sudo -n sed -i "s|^default .*|default $MID-android.conf|" "$(sudo -n bootctl -p)/loader/loader.conf"
echo "默认启动项 → Android"
echo
echo "现在重启：sudo systemctl reboot"
echo "起来后建议验证："
echo "  adb shell 'dmesg | grep -iE \"zap|adreno\" | tail -5'          # zap shader 应无报错"
echo "  adb shell 'getprop ro.hardware.vulkan; ls /vendor/lib64/hw/'  # 应为 freedreno"
echo "  adb shell 'cat /proc/asound/cards'                            # 应能看到声卡"
echo "  bash scripts/android-post-flash.sh                            # /data 侧置备"
