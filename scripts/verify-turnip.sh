#!/usr/bin/env bash
# M3 验收：确认 Android 真的跑在硬件 turnip 上，且 GPU 没有暗伤。
# 在【宿主机】跑（走 adb），设备需已进 Android。
#
# 每一项都对应 Stage 5 踩过的一个坑，别删：
#   ro.hardware.vulkan   —— 加载哪个 Vulkan HAL（pastel=软渲染兜底）
#   Turnip Adreno 690    —— 只有真正初始化成功才会打这行；属性对了不等于在用
#   GMU 错误计数         —— GX_BW_PERF_VOTE 超时 / watchdog / gdsc didn't collapse
#                           三者任一非 0 = D3 那条死亡链又起来了
#   smmustall 服务       —— 常驻解锁器；它不跑 = 第一次页错误就永久挂死
#   FAULT# 行            —— 解锁器抓到的真实 GPU 页错误（0004 v3 之后应为 0）
#   screencap            —— 帧读回；Stage 5 时它会永久卡死，是最灵敏的探针
set -u
export MSYS_NO_PATHCONV=1
SECS=${1:-0}          # 可选：浸泡秒数，之后再复查一次 fault 计数

adb wait-for-device
echo "═══ 1. 属性与 HAL ═══"
adb shell 'echo -n "ro.hardware.vulkan = "; getprop ro.hardware.vulkan
echo -n "debug.hwui.renderer = "; getprop debug.hwui.renderer
echo -n "persist.graphics.egl = "; getprop persist.graphics.egl
ls -la /vendor/lib64/hw/vulkan.*.so'

echo; echo "═══ 2. turnip 真的被初始化了吗 ═══"
adb shell 'logcat -d 2>/dev/null | grep -oE "Turnip Adreno \(TM\) [0-9]+|vulkan\.freedreno" | sort -u'

echo; echo "═══ 3. GPU / GMU 内核侧 ═══"
adb shell 'echo -n "GMU 错误行数: "; dmesg | grep -cE "timed out|watchdog expired|gdsc didn"
echo -n "a6xx_recover: "; dmesg | grep -c "a6xx_recover"
echo "--- adreno probe ---"; dmesg | grep -iE "adreno|zap" | tail -4'

echo; echo "═══ 4. SMMU 解锁器 ═══"
adb shell 'echo -n "init.svc.smmustall = "; getprop init.svc.smmustall
echo "--- 最近日志 ---"; logcat -d -s smmustall 2>/dev/null | tail -3
echo -n "抓到的 FAULT 数: "; logcat -d -s smmustall 2>/dev/null | grep -c "FAULT#"'

echo; echo "═══ 5. 桌面进程 ═══"
adb shell 'getprop sys.boot_completed; pgrep -l -f "surfaceflinger|system_server|systemui|launcher3" | head -5'

echo; echo "═══ 6. 帧读回（Stage 5 时这一步永久卡死）═══"
adb shell 'rm -f /data/local/tmp/vt.png; screencap -p /data/local/tmp/vt.png; echo "rc=$?"; ls -la /data/local/tmp/vt.png'

echo; echo "═══ 7. 崩溃残留 ═══"
adb shell 'logcat -d -b crash 2>/dev/null | grep -E ">>> " | tail -3'

if [ "$SECS" -gt 0 ]; then
  echo; echo "═══ 浸泡 ${SECS}s 后复查 ═══"
  sleep "$SECS"
  adb shell 'echo -n "GMU 错误: "; dmesg | grep -cE "timed out|watchdog expired|gdsc didn"
  echo -n "SMMU FAULT: "; logcat -d -s smmustall 2>/dev/null | grep -c "FAULT#"
  echo -n "boot_completed: "; getprop sys.boot_completed
  echo "--- 桌面四进程 PID（应与浸泡前一致）---"
  pgrep -f "surfaceflinger|system_server|systemui|launcher3" | head -5'
fi
