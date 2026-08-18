#!/bin/bash
# 把 VM 新编的 vulkan.freedreno.so 部署到设备并验证（走 overlayfs，不刷 super）。
# 用法: deploy-turnip.sh [VM_IP]
set -u
export MSYS_NO_PATHCONV=1
VM="${1:-<BUILD_VM>}"
SO=vulkan.freedreno.so
cd "$(dirname "$0")" || exit 1

echo "=== 1. 从 VM 取新 so ==="
# -C 压缩：这条链路实测只有几十 KB/s，14.6MB 的 ELF 压完约 4MB，省一半以上时间
scp -C -i ~/.ssh/ed25519 -o StrictHostKeyChecking=no \
  "vahiru@$VM:~/aosp/out/target/product/gaokun3/vendor/lib64/hw/$SO" . || exit 1
ls -la "$SO"

echo "=== 2. 部署（overlayfs，标签按 pastel 的 same_process_hal_file 对齐）==="
adb wait-for-device root >/dev/null 2>&1; sleep 2; adb wait-for-device
adb remount 2>&1 | tail -1
adb push "$SO" /vendor/lib64/hw/$SO || exit 1
adb shell "chcon u:object_r:same_process_hal_file:s0 /vendor/lib64/hw/$SO; ls -laZ /vendor/lib64/hw/$SO"

echo "=== 3. 切回 turnip + ANGLE 路径 ==="
adb shell 'sed -i "s/^ro.hardware.vulkan=pastel/ro.hardware.vulkan=freedreno/" /vendor/build.prop
grep -nE "hardware.vulkan|hwui.renderer" /vendor/build.prop'

echo "=== 4. 重启验证（经 Ubuntu 中转）==="
# ⚠️ 默认启动项已改成 Ubuntu（这样 Android 挂死时拍一下电源键就自动回落，
#    不用人到机器前选菜单）。代价是 `adb reboot` 会进 Ubuntu，
#    必须在 Ubuntu 里 `bootctl set-oneshot android` 再重启。
#    Android 侧无法自己设：cmdline 带 efi=noruntime，没有 efivarfs。
EGO=${EGO:-192.168.31.230}
SSH="ssh -i $HOME/.ssh/ed25519 -o StrictHostKeyChecking=no -o ConnectTimeout=8 -o BatchMode=yes user@$EGO"
adb reboot
echo "等 Ubuntu 上线…"
for i in $(seq 1 40); do $SSH true 2>/dev/null && break; sleep 6; done
$SSH 'sudo bootctl set-oneshot 8a29534fa802480d9fbb71aa18c01d7b-android.conf && echo ONESHOT-ANDROID; sudo systemctl reboot' 2>&1 | head -2
for i in $(seq 1 36); do
  sleep 5
  adb devices 2>/dev/null | grep -q "gaokun3.*device" || continue
  adb root >/dev/null 2>&1; sleep 1
  B=$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d "\r")
  E=$(adb shell 'dmesg | grep -cE "timed out|watchdog expired|gdsc didn"' 2>/dev/null | tr -d "\r")
  C=$(adb shell 'logcat -d -b crash 2>/dev/null | grep -c "tu_allocate_transient\|tu_cmd_render"' 2>/dev/null | tr -d "\r")
  echo "t=$((i*5))s boot=[$B] gmu_err=$E turnip崩溃=$C"
  [ "$B" = "1" ] && { echo "*** BOOT COMPLETED ***"; break; }
done

echo "=== 5. 验收 ==="
adb shell 'echo -n "renderer: "; getprop ro.hardware.vulkan
echo -n "hwui: "; getprop debug.hwui.renderer
echo "--- 桌面进程 ---"; pgrep -l -f "system_server|surfaceflinger|systemui|launcher3" | head -4
echo "--- turnip 真在用？---"; logcat -d 2>/dev/null | grep -oE "Turnip Adreno \(TM\) 690|vulkan.freedreno" | head -2
echo "--- GMU 错误 ---"; dmesg | grep -cE "timed out|watchdog expired|gdsc didn"
echo "--- SMMU 解锁服务 ---"; logcat -d -s smmustall 2>/dev/null | tail -2
echo "--- 崩溃残留 ---"; logcat -d -b crash 2>/dev/null | grep -E ">>> " | tail -3'
