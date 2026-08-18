#!/bin/bash
# GMU 侦查实验室（Ubuntu 侧）。用法: gmu-lab.sh {evidence|churn|stress|watch}
# 全部证据落 /home/user/gmu-lab/<时间戳>/，方法论见项目 plan。
set -u
LAB=/home/user/gmu-lab/$(date +%Y%m%d-%H%M%S)-$1
mkdir -p "$LAB"
GPU_DEVFREQ=/sys/class/devfreq/3d00000.gpu
GPU_PM=/sys/devices/platform/soc@0/3d00000.gpu/power

evidence() {
  uname -a                                | tee    "$LAB/uname.txt"
  cat /proc/version                       | tee -a "$LAB/uname.txt"
  cat /proc/cmdline                       | tee    "$LAB/cmdline.txt"
  sudo dmesg | grep -iE "adreno|gmu|a690|msm.*gpu" | tee "$LAB/dmesg-gpu-boot.txt"
  sudo vulkaninfo --summary 2>/dev/null | grep -E "deviceName|driverInfo|apiVersion" | tee "$LAB/vulkaninfo.txt"
  for f in governor cur_freq min_freq max_freq polling_interval; do
    echo "$f = $(cat $GPU_DEVFREQ/$f 2>/dev/null)"; done | tee "$LAB/devfreq.txt"
  echo "autosuspend_delay_ms = $(cat $GPU_PM/autosuspend_delay_ms 2>/dev/null)" | tee -a "$LAB/devfreq.txt"
  echo "runtime_status = $(cat $GPU_PM/runtime_status 2>/dev/null)"             | tee -a "$LAB/devfreq.txt"
  echo "EVIDENCE-DONE $LAB"
}

# churn: 渲染客户端 STOP/CONT 翻炒，每轮空闲 >66ms 强制 GMU 真掉电再唤醒。
# $2=客户端命令（默认 kmscube），$3=轮数（默认 300），$4=进程名（默认 vkmark）
# ⚠️ 信号必须 pkill -x 按进程名发：sudo 包装进程不转发 SIGSTOP。
churn() {
  CLIENT="${2:-kmscube}"; ROUNDS="${3:-300}"; PNAME="${4:-vkmark}"
  sudo dmesg -C
  ( sudo dmesg -w > "$LAB/dmesg-live.txt" 2>&1 ) & DMESG_PID=$!
  $CLIENT >/dev/null 2>&1 & CPID=$!
  sleep 2
  if ! pgrep -x "$PNAME" >/dev/null; then echo "CLIENT-DIED-EARLY: $CLIENT"; sudo kill $DMESG_PID; exit 1; fi
  S0=$(cat $GPU_PM/runtime_suspended_time)
  echo "churn 开始: client=$CLIENT pname=$PNAME rounds=$ROUNDS"
  for i in $(seq 1 $ROUNDS); do
    sudo pkill -STOP -x "$PNAME" 2>/dev/null || break
    sleep 0.25          # >66ms autosuspend → GMU 掉电
    sudo pkill -CONT -x "$PNAME" 2>/dev/null || break
    sleep 0.15          # 渲染几帧 → GMU 冷启动 + 投票
    if [ $((i % 50)) -eq 0 ]; then
      SD=$(( $(cat $GPU_PM/runtime_suspended_time) - S0 ))
      echo "round $i: cur_freq=$(cat $GPU_DEVFREQ/cur_freq) rt=$(cat $GPU_PM/runtime_status) suspended_delta=${SD}ms"
      if ! pgrep -x "$PNAME" >/dev/null; then echo "!!! CLIENT-GONE at round $i !!!"; break; fi
      if grep -qiE "timed out|watchdog|gdsc|hangcheck" "$LAB/dmesg-live.txt"; then
        echo "!!! GMU-ERROR-DETECTED at round $i !!!"; break
      fi
    fi
  done
  sudo pkill -CONT -x "$PNAME" 2>/dev/null; sudo pkill -x "$PNAME" 2>/dev/null
  kill $CPID 2>/dev/null; sleep 1; sudo kill $DMESG_PID 2>/dev/null
  echo "真实性: 总 suspended_delta=$(( $(cat $GPU_PM/runtime_suspended_time) - S0 ))ms（期望≈轮数×180ms）"
  cat "$GPU_DEVFREQ/trans_stat" > "$LAB/trans_stat.txt" 2>/dev/null
  echo "=== GMU 错误扫描 ==="
  grep -iE "timed out|watchdog|gdsc|hangcheck|recover|fault" "$LAB/dmesg-live.txt" | head -30
  grep -qiE "timed out|watchdog|gdsc" "$LAB/dmesg-live.txt" && echo "CHURN-RESULT: GMU-DIED" || echo "CHURN-RESULT: CLEAN"
  echo "CHURN-DONE $LAB"
}

# stress: 满载推到 FMAX。$2=客户端（默认 vkmark），$3=秒数（默认 120）
stress() {
  CLIENT="${2:-kmscube}"; SECS="${3:-120}"
  sudo dmesg -C
  ( sudo dmesg -w > "$LAB/dmesg-live.txt" 2>&1 ) & DMESG_PID=$!
  $CLIENT >/dev/null 2>&1 & CPID=$!
  echo "stress 开始: $CLIENT $SECS 秒"
  for i in $(seq 1 $SECS); do
    sleep 1
    [ $((i % 10)) -eq 0 ] && echo "t=$i cur_freq=$(cat $GPU_DEVFREQ/cur_freq)"
    kill -0 $CPID 2>/dev/null || { echo "CLIENT-EXITED t=$i"; break; }
  done
  kill $CPID 2>/dev/null; sleep 1; sudo kill $DMESG_PID 2>/dev/null
  cat "$GPU_DEVFREQ/trans_stat" > "$LAB/trans_stat.txt" 2>/dev/null
  grep -iE "timed out|watchdog|gdsc|hangcheck|recover|fault" "$LAB/dmesg-live.txt" | head -30
  grep -qiE "timed out|watchdog|gdsc" "$LAB/dmesg-live.txt" && echo "STRESS-RESULT: GMU-DIED" || echo "STRESS-RESULT: CLEAN"
  cat "$LAB/trans_stat.txt"
  echo "STRESS-DONE $LAB"
}

watch_gpu() {
  while true; do
    echo "$(date +%T) freq=$(cat $GPU_DEVFREQ/cur_freq 2>/dev/null) rt=$(cat $GPU_PM/runtime_status 2>/dev/null)"
    sleep 1
  done
}

case "$1" in
  evidence) evidence ;;
  churn)    churn "$@" ;;
  stress)   stress "$@" ;;
  watch)    watch_gpu ;;
  *) echo "用法: $0 {evidence|churn|stress|watch} [client] [rounds/secs]"; exit 1 ;;
esac
