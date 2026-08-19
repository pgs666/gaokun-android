#
# Product definition for Huawei MateBook E Go (sc8280xp / gaokun3)
# —— crDroid 16.0（= LineageOS 23.2 布局，AOSP 基线 android-16.0.0_r4）
#
# 取代 Stage 2–5 时期的 aosp_gaokun3.mk（在 git 历史里）。
# 换轨理由见 docs/stage4-findings.md #36：手搓最小 AOSP 缺产品级配置
# （MediaCodecList 空、无铃声/UI 音效），而这些是真 ROM 设备树的标配。
#
# ⚠️ 产品名必须是 lineage_<codename>：vendor/lineage/build/envsetup.sh 的
#    breakfast/brunch 拼的就是
#        lunch lineage_$target-$aosp_target_release-$variant
#    而 vendor/lineage/vars/aosp_target_release = bp4a。
#    （vendor/lineage 这个路径由 crdroidandroid/android_vendor_crdroid 提供，
#      不是 LineageOS 那个仓库 —— repo manifest 实名核实。）
#

# dalvik 堆：不配则 system_server 只有 16MB growth limit，boot 后必 OOM
# （java.lang.OutOfMemoryError 实测，Stage 2）。用 10 寸平板标准档。
$(call inherit-product, frameworks/native/build/tablet-10in-xhdpi-2048-dalvik-heap.mk)

# 64 位为主 + 32 位兼容（手游 arm64-v8a 直跑，但 armeabi-v7a 也要能装）
$(call inherit-product, $(SRC_TARGET_DIR)/product/core_64_bit.mk)

# ★ AOSP 基座 —— 必须由设备树自己提供。
#
# 2026-08-19 实测教训：我一度以为 crDroid 自带整套应用，叠 full_base 会撞包，
# 于是把它拿掉了。结果构建"成功"但产物是空壳：
#     system.img 只有 29.8 MB（旧 AOSP 那份是 1.0 GB），
#     /system 里没有 apex/、没有 app/、连 framework/services.jar 都不存在。
#
# 原因：vendor/lineage/ 下的所有配置都是【补充】性质的 ——
#   common.mk        只 inherit vendor/extra、crdroid.mk、vendor/addons、audio.mk
#   common_mobile.mk 只补 frameworks/base/data/sounds/AudioPackage14.mk
#   tablet.mk        只补 $(SRC_TARGET_DIR)/product/large_screen_common.mk
# 整个 vendor/lineage/config/*.mk 里对 SRC_TARGET_DIR 的引用只有 tablet.mk 那一处。
# 也就是说 LineageOS/crDroid 的设备树【本来就该】自己 inherit 一个 AOSP base 产品，
# 这也是上游设备树模板的标准写法。
#
# full_base.mk 的链条（本地实读）：
#   full_base → generic_no_telephony → handheld_{system,system_ext,vendor,product}
#            → media_vendor → base_vendor（vendor_compatibility_matrix.xml、
#              shell_and_utilities_vendor = /vendor/bin/sh + toybox_vendor …）
#   full_base 还带 frameworks/base/data/sounds/AllAudio.mk（铃声）
# 正是我们旧的 aosp_gaokun3.mk 用过、并产出可用镜像的那条链。
$(call inherit-product, $(SRC_TARGET_DIR)/product/full_base.mk)

# ★ 关掉 adb 授权 —— 必须在 inherit crDroid 配置【之前】设。
#
# 2026-08-19 首次上机踩到：crDroid 起来了，但 adb 一直是 unauthorized，
# 而设备端没有 ssh、也就没法远程重启，等于失联（只能靠人去点屏幕）。
#
# vendor/lineage/config/common.mk:33-45 的逻辑：
#     ifeq ($(TARGET_BUILD_VARIANT),eng)      ro.adb.secure=0
#     else ifdef WITH_ADB_INSECURE            ro.adb.secure=0
#     else                                    ro.adb.secure=1
#                                             PRODUCT_NOT_DEBUGGABLE_IN_USERDEBUG := true
# 后一个分支还会把 userdebug 的 ro.debuggable 压成 0 ——
# 那样 adb root / adb remount 都不能用，而 M3 部署 turnip 全靠 overlay。
#
# ⚠️ 我们 device.mk 里那句 PRODUCT_PROPERTY_OVERRIDES += ro.adb.secure=0
#    落在 vendor/build.prop，而 system/build.prop 里的 ro.adb.secure=1 先被 init
#    读到 —— ro.* 是只读属性，先设者胜，所以 vendor 那份完全无效。
#    必须从源头（这个开关）解决。
WITH_ADB_INSECURE := true

# crDroid 的「平板 + 无 modem」组合（叠在 AOSP 基座之上）：
#   common_full_tablet_wifionly.mk = common_mobile_full + tablet + wifionly
# Lineage 侧用 LOCAL_OVERRIDES_PACKAGES 顶掉 AOSP 的同类应用，不会真的撞包。
$(call inherit-product, vendor/lineage/config/common_full_tablet_wifionly.mk)

# 设备配置（固件、init rc、HAL、图形、WiFi、音频 —— Stage 2–5 的全部成果）
$(call inherit-product, device/huawei/gaokun3/device.mk)

# 动态分区（super）。这是 product 变量，必须设在这里而不是 BoardConfig.mk
# —— 后者解析时它已经只读了（build/make/core/product.mk:311）。
PRODUCT_USE_DYNAMIC_PARTITIONS := true

PRODUCT_NAME   := lineage_gaokun3
PRODUCT_DEVICE := gaokun3
PRODUCT_BRAND  := Huawei
PRODUCT_MODEL  := MateBook E Go
PRODUCT_MANUFACTURER := Huawei

# API 等级：不声明 vendor 冻结，按当前平台走（Android 16 = 36）
PRODUCT_SHIPPING_API_LEVEL := 36
