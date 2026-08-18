#!/vendor/bin/sh
# GMU 定位实验：等 GPU devfreq 节点出现（首次 open 才创建），立刻钉 min_freq。
# 目标频率由 /data/local/tmp/gpu_min_freq 提供，缺省 690000000（完全消灭降频）。
TARGET=$(cat /data/local/tmp/gpu_min_freq 2>/dev/null)
[ -z "$TARGET" ] && TARGET=690000000
N=/sys/class/devfreq/3d00000.gpu/min_freq
i=0
while [ $i -lt 300 ]; do
  if [ -e "$N" ]; then
    echo "$TARGET" > "$N" && log -t gpupin "min_freq=$TARGET 已钉 (i=$i)" && exit 0
  fi
  i=$((i+1))
  sleep 0.1
done
log -t gpupin "超时：devfreq 节点未出现"
exit 1
