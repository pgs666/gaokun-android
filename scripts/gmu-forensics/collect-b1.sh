#!/bin/bash
# turnip 运行现场采集器：探针输出 + SMMU fault 普查 + 帧读回/存活体检。
# 用法: collect-b1.sh [输出目录]   （设备须已在跑 turnip）
set -u
export MSYS_NO_PATHCONV=1
OUT="${1:-b1-$(date +%H%M)}"
mkdir -p "$OUT" || exit 1

adb root >/dev/null 2>&1; sleep 1; adb wait-for-device

echo "=== 1. mesa 探针（P1 NULL-bind / P2 unbound-view / P3 unbound-attachment）==="
adb shell 'logcat -d 2>/dev/null | grep -a gaokun' > "$OUT/probes.txt" 2>&1
for p in P1 P2 P3; do
  printf "%s 命中 %s 行\n" "$p" "$(grep -ac "gaokun $p" "$OUT/probes.txt")"
done
grep -aE "gaokun P[123] " "$OUT/probes.txt" | head -30

echo
echo "=== 2. SMMU fault 普查 ==="
adb shell 'logcat -d -s smmustall 2>/dev/null' > "$OUT/smmustall.txt" 2>&1
echo "FAULT 行数: $(grep -ac FAULT# "$OUT/smmustall.txt")"
echo "清 CFCFG 行数: $(grep -ac "清 CFCFG" "$OUT/smmustall.txt")"
echo "--- 首个 fault ---"; grep -a FAULT# "$OUT/smmustall.txt" | head -2
echo "--- FAR 值谱（去重计数）---"
grep -aoE "CB[0-9]+ (READ|WRITE) FSR=[0-9]+ FAR=[0-9]+_[0-9]+" "$OUT/smmustall.txt" \
  | sort | uniq -c | sort -rn | head -12
echo "--- 心跳（服务是否还活着）---"; grep -a 心跳 "$OUT/smmustall.txt" | tail -2

echo
echo "=== 3. 帧读回（screencap 15s 超时）==="
adb shell 'rm -f /data/local/tmp/s.png; timeout 15 screencap -p /data/local/tmp/s.png; echo "screencap-rc=$?"; ls -la /data/local/tmp/s.png 2>&1'

echo
echo "=== 4. 存活体检 ==="
adb shell 'echo -n "boot_completed="; getprop sys.boot_completed
echo -n "renderer="; getprop ro.hardware.vulkan
echo -n "uptime="; cut -d. -f1 /proc/uptime
echo "--- 桌面四进程 ---"; pgrep -l -f "surfaceflinger|system_server|systemui|launcher3" | head -4
echo -n "GMU 错误数="; dmesg | grep -cE "timed out|watchdog expired|gdsc didn"
echo -n "a6xx_recover 数="; dmesg | grep -c a6xx_recover
echo "--- turnip 崩溃 ---"; logcat -d -b crash 2>/dev/null | grep -c ">>> "'

adb shell 'dmesg' > "$OUT/dmesg.txt" 2>&1
echo
echo "证据已存 $OUT/（probes.txt / smmustall.txt / dmesg.txt）"
