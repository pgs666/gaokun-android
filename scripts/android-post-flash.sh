#!/usr/bin/env bash
# Android 刷机后置备脚本（settings/persist 住在 /data，重刷 userdata 后要重跑）
# 用法：adb 连上后  bash scripts/android-post-flash.sh
set -e
ADB="${ADB:-adb}"

# ─── 电源：不再需要 `svc power stayon true` ────────────────────────────────
# 防挂起已由【内核 wakelock】承担（init.gaokun3.rc 的 on init 写 /sys/power/wake_lock），
# 它与供电状态无关，而且**不妨碍息屏**。而 stayon 走 stay_on_while_plugged_in，
# 会把屏幕也钉亮着 —— 白耗电、屏幕长期常亮，还让"按电源键息屏"看起来像坏了。
# ★M4 实测：持 wakelock 时息屏是安全的（不会触发挂起，因为 SystemSuspend 卡在
#   读 /sys/power/wakeup_count 上，见 init.gaokun3.rc 的注释），所以给它一个
#   正常的息屏超时即可 —— 这就是本机目前能提供的"待机"：息屏，但机器不真睡。
$ADB shell settings put global stay_on_while_plugged_in 0
$ADB shell settings put system screen_off_timeout 120000

# 连通性验证端点换国内可达（默认 Google generate_204 被墙 →
# 框架判"永久无网" → WiFi 自动加入被永久禁用，见 stage4-findings #29）
$ADB shell settings put global captive_portal_https_url https://connect.rom.miui.com/generate_204
$ADB shell settings put global captive_portal_http_url http://connect.rom.miui.com/generate_204

# ★蓝牙不再禁用（M4 实测推翻 stage4-findings #30）：
#   crDroid 上 adapter state=ON、地址从芯片读出、"Bluetooth crashed 0 times"、
#   vendor.bluetooth-default 常驻 running。
#   旧脚本这里曾有两行 `settings put global bluetooth_on 0` + `svc bluetooth disable`，
#   留着会在**每次重刷 userdata 后把好的蓝牙重新关掉**，故删除。

# adb over TCP（UCSI 拔插丢 USB adb 的兜底，见 #27；也是远程排查的主通路）
# persist. 那条下次开机才生效；service. 那条让本次立刻生效。
$ADB shell setprop persist.adb.tcp.port 5555
$ADB shell setprop service.adb.tcp.port 5555

# 触点可视化按需开：
# $ADB shell settings put system pointer_location 1
echo "置备完成"
