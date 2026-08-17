#!/usr/bin/env bash
# Android 刷机后置备脚本（settings/persist живут в /data，重刷 userdata 后要重跑）
# 用法：adb 连上后  bash scripts/android-post-flash.sh
set -e
ADB="${ADB:-adb}"

# 防睡眠（s2idle 醒不来，Stage 4 电源项未修前必须开）
$ADB shell svc power stayon true

# 连通性验证端点换国内可达（默认 Google generate_204 被墙 →
# 框架判"永久无网"→ WiFi 自动加入被永久禁用，见 stage4-findings #29）
$ADB shell settings put global captive_portal_https_url https://connect.rom.miui.com/generate_204
$ADB shell settings put global captive_portal_http_url http://connect.rom.miui.com/generate_204

# 蓝牙禁用（无 HCI HAL，会崩溃循环喂 RescueParty，见 #30；装好 APEX 后删这行）
$ADB shell settings put global bluetooth_on 0
$ADB shell svc bluetooth disable 2>/dev/null || true

# adb over TCP（UCSI 拔插丢 USB adb 的兜底，见 #27）
$ADB shell setprop persist.adb.tcp.port 5555

# 触点可视化按需开：
# $ADB shell settings put system pointer_location 1
echo "置备完成"
