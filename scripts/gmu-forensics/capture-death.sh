#!/bin/bash
# GMU 死亡现场捕获器 v2。用法: capture-death.sh <输出目录> [最长等待秒,默认 300]
# v2 修正：pull 用 cd+"."（MSYS 路径坑）；devcd 按节点名编号保存不覆盖；
#          用 logcat -b kernel 抓早期启动日志（dmesg 环轮转太快）。
set -u
OUT="$1"; DEADLINE="${2:-300}"
mkdir -p "$OUT"; cd "$OUT" || exit 1
echo "捕获开始 $(date +%T) → $OUT"

T0=$(date +%s); SEEN=""; FIRST_ERR=0
while :; do
  NOW=$(date +%s); ELAPSED=$((NOW - T0))
  [ $ELAPSED -gt $DEADLINE ] && { echo "DEADLINE ${ELAPSED}s"; break; }
  if ! adb devices 2>/dev/null | grep -q "gaokun3.*device"; then sleep 2; continue; fi
  adb root >/dev/null 2>&1

  adb shell 'logcat -b kernel -d 2>/dev/null' > klog-latest.txt
  D=$(grep -cE "timed out|watchdog expired|gdsc" klog-latest.txt 2>/dev/null)
  if [ "$D" -gt 0 ] && [ $FIRST_ERR -eq 0 ]; then
    FIRST_ERR=1; cp klog-latest.txt klog-at-first-error.txt
    adb shell dmesg > dmesg-at-first-error.txt 2>/dev/null
    echo "FIRST-GMU-ERROR @ ${ELAPSED}s (行数 $D)"
  fi

  for N in $(adb shell 'ls /sys/class/devcoredump/ 2>/dev/null' | tr -d "\r" | grep devcd); do
    case " $SEEN " in *" $N "*) continue;; esac
    echo "NEW-DEVCD: $N @ ${ELAPSED}s"
    adb shell "cat /sys/class/devcoredump/$N/data > /data/local/tmp/$N.bin 2>/dev/null"
    SZ=$(adb shell "wc -c < /data/local/tmp/$N.bin" | tr -d "\r ")
    adb pull "/data/local/tmp/$N.bin" . >/dev/null 2>&1 && mv "$N.bin" "$N.txt" && echo "PULLED $N.txt ($SZ bytes)" && SEEN="$SEEN $N"
    adb shell 'echo "cur_freq=$(cat /sys/class/devfreq/3d00000.gpu/cur_freq 2>/dev/null) rt=$(cat /sys/devices/platform/soc@0/3d00000.gpu/power/runtime_status 2>/dev/null)"' >> devfreq-timeline.txt
  done

  # 拿到第一个 devcd + 已见错误 → 收尾
  if [ -n "$SEEN" ] && [ $FIRST_ERR -eq 1 ]; then
    sleep 20
    adb shell 'logcat -b kernel -d 2>/dev/null' > klog-final.txt
    adb shell 'logcat -d -b main,system,crash 2>/dev/null | tail -300' > logcat-tail.txt
    echo "CAPTURE-COMPLETE @ ${ELAPSED}s"
    break
  fi
  sleep 3
done
echo "=== 死亡序列（首错快照）==="
grep -E "timed out|watchdog|gdsc|recover|hangcheck|adreno|gmu" klog-at-first-error.txt 2>/dev/null | head -25
ls -la "$OUT"
