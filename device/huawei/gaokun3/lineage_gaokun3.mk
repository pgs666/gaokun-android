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
#    落在 vendor/build.prop，被 init 的 CheckPermissions 静默拒绝
#    （vendor context 无权设置 system 属主的 ro.adb.secure）。
#    详见下面那段对 property_service 加载语义的实测说明。
WITH_ADB_INSECURE := true

# ★ ro.debuggable=1 必须从 system_ext 发（不能从 vendor）。
#
# 2026-08-19 实测出来的两条机制，都和直觉相反：
#
# 1) build/soong/scripts/gen_build_prop.py:28 的 get_build_variant()
#    【没有 userdebug 这一档】—— 非 eng 一律按 user 处理：
#        if product_config["Eng"]: return "eng"
#        else:                     return "user"
#    所以 /system/build.prop 被硬写成 ro.adb.secure=1 + ro.debuggable=0
#    + ro.allow.mock.location=0，与 TARGET_BUILD_VARIANT=userdebug 无关。
#
# 2) init 的属性加载是【后来者覆盖】（property_service.cpp:807-815
#    的 map 插入：已存在且不同就 it->second = value），
#    加载顺序 /system → system_ext → vendor → odm → product。
#    但每条都要过 CheckPermissions(key, value, context, …)，
#    而 /vendor/* 用的是 vendor context —— ro.adb.secure / ro.debuggable
#    都是 system 属主的属性，vendor 无权设置，会被【静默拒绝】。
#    这就是为什么 device.mk 里 PRODUCT_PROPERTY_OVERRIDES 那两句
#    （落进 vendor/build.prop）一直没生效。
#
# system_ext 用 init context 且在 system 之后加载 → 能正确覆盖。
# WITH_ADB_INSECURE 走的就是这条路（PRODUCT_SYSTEM_EXT_PROPERTIES）。
PRODUCT_SYSTEM_EXT_PROPERTIES += \
    ro.debuggable=1

# ★★ Codec2 HAL 选 AIDL —— 没有这行就一个解码器都没有。
#
# frameworks/av/media/codec2/hal/common/HalSelection.cpp:57
#     std::string selection = GetProperty("media.c2.hal.selection", "hidl");
#     if (selection == "aidl") return true;
#     else if (selection == "hidl") return false;
# 【默认是 hidl】。而 HIDL 的 Codec2 在 Android 15+ 已经彻底不可用 ——
# hwservicemanager 被移除，实机日志：
#     I HidlServiceManagement: Cannot list manifest for
#         android.hardware.media.c2@1.0::IComponentStore without hwservicemanager
# 于是 Codec2Client::CacheServiceNames() 拿到空列表：
#     I Codec2Client: No Codec2 services declared in the manifest.
# → MediaCodecList 为空 → App 一律 "Failed to create audio/mpeg decoder"，
#   screenrecord 报 "unable to create video/avc codec instance"。
#
# 这就是 docs/stage4-findings.md #36 追了两个阶段的那个"解码器一个都没有"。
# 它与 crDroid 无关 —— AOSP 16 上同样如此，只是真机设备树都会设这个属性，
# 我们这棵手搓的从来没设过。
#
# 运行时 setprop 之后 Codec2Client 立刻变成
#     I Codec2Client: Available Codec2 services: "software"
# 但必须在【开机时】就位：media.swcodec 自己也读它决定注册 AIDL 还是 HIDL。
#
# ⚠️ 走 PRODUCT_SYSTEM_EXT_PROPERTIES 而不是 PRODUCT_PROPERTY_OVERRIDES：
#    后者落进 vendor/build.prop，而该属性的 SELinux 上下文是
#    codec2_config_prop，vendor context 无权设置，会被静默拒绝
#    （同 ro.adb.secure / ro.debuggable 的坑，见本文件上面的说明）。
PRODUCT_SYSTEM_EXT_PROPERTIES += \
    media.c2.hal.selection=aidl

# ★ 把开发机的 adb 公钥烤进镜像 —— 不依赖 ro.adb.secure 的那条路。
#
# 2026-08-19 实测：即使 system_ext 里 ro.adb.secure=0 已经写进产物，
# 实机 adbd 仍然要求授权（adbd 的判定见 packages/modules/adb/daemon/main.cpp:223-226：
#   device_unlocked（我们 cmdline 带 verifiedbootstate=orange）为真 →
#   auth_required = GetBoolProperty("ro.adb.secure", false)），
# 说明运行时它读到的仍是 1 —— system_ext 的覆盖没有落地，原因待查。
#
# 而公钥这条路完全绕开属性：
#   packages/modules/adb/docs/dev/keystore.md
#     /adb_keys                 系统公钥，只读，随镜像出厂
#                               （system/core/rootdir/create_root_structure.mk:36
#                                把它做成指向 /product/etc/security/adb_keys 的符号链接）
#     /data/misc/adb/adb_keys   用户公钥，可写分区
#   adbd 收到 AUTH 挑战时会遍历这两处的所有 RSA 公钥。
#
# PRODUCT_ADB_KEYS → soong 的 AdbKeys（build/make/core/soong_config.mk:377），
# 且只在 eng/userdebug 保留（product_config.mk:493-494），正合我们。
#
# ⚠️ adb_keys 文件本身【不入版本库】（.gitignore 挡着）——
#    它是开发机个人密钥，仓库是公开的。换机器时执行：
#        cp ~/.android/adbkey.pub device/huawei/gaokun3/adb_keys
PRODUCT_ADB_KEYS := device/huawei/gaokun3/adb_keys

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
