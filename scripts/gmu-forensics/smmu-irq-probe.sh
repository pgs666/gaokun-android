#!/bin/bash
# Android 侧：SMMU fault IRQ 到达判定 + fault handler 链路取证。
# 逻辑：GPU fault 持续发生（recover 每 500ms 重试），IRQ 计数是累积的，
# 所以 adb 上线后连采两次即可判定 IRQ 是否到达（无需 fault 前快照）。
set -u
OUT="$1"; mkdir -p "$OUT"; cd "$OUT" || exit 1

echo "等 adb..."
for i in $(seq 1 60); do
  adb devices 2>/dev/null | grep -q "gaokun3.*device" && break
  sleep 5
done
adb root >/dev/null 2>&1; sleep 3; adb wait-for-device

echo "=== 挂 debugfs + 开 dyndbg ==="
adb shell 'mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null
echo -n "debugfs: "; ls /sys/kernel/debug 2>/dev/null | head -3 | tr "\n" " "; echo
D=/sys/kernel/debug/dynamic_debug/control
if [ -e $D ]; then
  echo "file arm-smmu.c +p" > $D 2>/dev/null
  echo "file arm-smmu-qcom.c +p" > $D 2>/dev/null
  echo "file msm_iommu.c +p" > $D 2>/dev/null
  echo "file adreno_gpu.c +p" > $D 2>/dev/null
  echo "file a6xx_gpu.c +p" > $D 2>/dev/null
  echo "dyndbg 已开: $(grep -c "=p" $D) 条"
else
  echo "dyndbg 节点缺失"
fi'

echo "=== 采样 1 ==="
adb shell 'grep -iE "smmu" /proc/interrupts' > irq-1.txt
adb shell 'dmesg | grep -cE "timed out|watchdog expired|gdsc didn|hangcheck"' > errcount-1.txt
cat irq-1.txt

echo "=== 等 15 秒（期间 recover 循环会多次重试提交 → 若 IRQ 通则计数增长）==="
sleep 15
adb shell 'grep -iE "smmu" /proc/interrupts' > irq-2.txt
adb shell 'dmesg | grep -cE "timed out|watchdog expired|gdsc didn|hangcheck"' > errcount-2.txt

echo "=== IRQ 计数变化（非零列 = 有中断到达）==="
paste <(awk '{print $1, $NF, $2+$3+$4+$5+$6+$7+$8+$9}' irq-1.txt) \
      <(awk '{print $2+$3+$4+$5+$6+$7+$8+$9}' irq-2.txt) \
  | awk '{printf "%-6s %-26s 采样1=%-8s 采样2=%-8s 增长=%s\n", $1, $2, $3, $4, $4-$3}'

echo "=== GPU fault 打印（handler 是否被调用）==="
adb shell 'dmesg | grep -iE "\*\*\* (gpu )?fault|ttbr0=|fsynr|TRANSLATION|PERMISSION|resume_translation|Unhandled context" | head -10' | tee fault-prints.txt
[ -s fault-prints.txt ] && echo ">>> handler 被调用了" || echo ">>> handler 完全静默（IRQ 未到达 或 早退）"

echo "=== 错误累积 $(cat errcount-1.txt) → $(cat errcount-2.txt) ==="
adb shell 'dmesg | grep -iE "arm-smmu|smmu" | grep -viE "avc|audit|probing|SMMUv2|context banks|page sizes|Stage-1|stream matching|coherent|boot mappings|translation$" | head -8'
adb shell 'cat /sys/kernel/debug/dri/0/gpu 2>/dev/null | head -20' > dri-gpu-state.txt 2>/dev/null
echo "DONE $OUT"
