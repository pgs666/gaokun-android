#!/system/bin/sh
# 重启后一键恢复传感器（临时手段）。
# 之所以需要它：内核里 CONFIG_QCOM_FASTRPC 还是 =m，而这棵树不发模块，
# 所以每次重启 /dev/fastrpc-* 都不存在。下一次出 ROM 会带 =y 的内核，
# 届时 init 会自己拉起 hexagonrpcd，本脚本即可废弃。
set -x
insmod /data/local/tmp/fastrpc.ko
pkill -f hexagonrpcd
LD_LIBRARY_PATH=/data/local/tmp /data/local/tmp/hexagonrpcd \
  -f /dev/fastrpc-sdsp -d sdsp -s -R /data/local/tmp/hxroot \
  > /data/local/tmp/hx.log 2>&1 &
# ★ 必须等 SSC 把物理传感器注册完（约 20 秒）再拉 HAL：
#   HAL 一上来查不到就会重试，而重试会新建/丢弃 SSC 客户端，那种 churn
#   实测会把传感器枚举彻底弄坏（见 docs/stage4-findings.md #37）。
sleep 25
stop vendor.sensors-gaokun3
start vendor.sensors-gaokun3
sleep 3
echo "--- 完成。核对："
/data/local/tmp/gaokun3-qrtr-lookup 400 | tail -2
dumpsys sensorservice 2>/dev/null | grep -m2 SH3001
