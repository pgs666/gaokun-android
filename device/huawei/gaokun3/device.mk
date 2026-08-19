#
# device.mk -- Huawei MateBook E Go (gaokun3)
#
# Stage 2 原则：能不装的一律不装。缺 HAL 顶多日志报错，
# 多一个坏 HAL 就可能让 init 起不来，而本机没有串口可看。
#

LOCAL_PATH := device/huawei/gaokun3

# vendor 分区的基础件（vendor_compatibility_matrix.xml、shell_and_utilities_vendor
# 即 /vendor/bin/sh + toybox_vendor 等）随 full_base.mk → … → base_vendor.mk 一起来，
# 接线在 lineage_gaokun3.mk，那里有完整的踩坑记录。

# ----------------------------------------------------------------- fstab
# 同一份 fstab 要同时进 ramdisk（first stage mount 用）和 vendor
PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/fstab.gaokun3:$(TARGET_COPY_OUT_RAMDISK)/fstab.gaokun3 \
    $(LOCAL_PATH)/fstab.gaokun3:$(TARGET_COPY_OUT_VENDOR)/etc/fstab.gaokun3

# ------------------------------------------------------------- init 脚本
PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/init.gaokun3.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/hw/init.gaokun3.rc \
    $(LOCAL_PATH)/init.gaokun3.usb.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/hw/init.gaokun3.usb.rc \
    $(LOCAL_PATH)/ueventd.gaokun3.rc:$(TARGET_COPY_OUT_VENDOR)/etc/ueventd.rc

# ------------------------------------------------------------------ 属性
# adb 默认开，且不要求授权 —— Stage 2 的验收就是 adb 能连上。
# persist.adb.tcp.port=5555：首次开机就把 adb over TCP 打开，
#   免得换 ROM 后 USB 侧不通就彻底失联（本机 UCSI 拔插会丢 adb，见坑 #27）。
#   属性名实名核实：packages/modules/adb/daemon/main.cpp:272-274
#   先读 service.adb.tcp.port，回落 persist.adb.tcp.port。
PRODUCT_PROPERTY_OVERRIDES += \
    ro.adb.secure=0 \
    ro.debuggable=1 \
    persist.sys.usb.config=adb \
    persist.adb.tcp.port=5555

# 屏幕密度
# [measured] 1600x2560，物理 266x166 mm -> 对角 12.34"，约 245 dpi
# 取 240（hdpi 桶），1dp=1.5px -> 1067dp 宽，平板比例合理。
# CLAUDE.md 提示可对照 Galaxy Tab S7 FE（同款面板）的取值再调。
PRODUCT_PROPERTY_OVERRIDES += \
    ro.sf.lcd_density=240

# USB gadget 控制器
# [measured] Stage 1 实测 UDC 名就是 a600000.usb
PRODUCT_PROPERTY_OVERRIDES += \
    sys.usb.controller=a600000.usb

# ------------------------------------------------- 安全 HAL（软件实现）
# keystore2 是 critical 服务且被 init.rc 的
#   exec 4 (/system/bin/vdc keymaster earlyBootEnded)
# 同步等待 —— 它起不来整个 boot 队列就堵死（实测：keystore2 连崩 52 次，
# adbd/zygote 永远排不上队，见 docs/stage2-findings.md）。
# 本机没有可用 TEE，用 AOSP 自带的软件实现（cuttlefish 同款）：
#   keymint:    hardware/interfaces/security/keymint/aidl/default/Android.bp:183
#   gatekeeper: hardware/interfaces/gatekeeper/aidl/software/Android.bp:64
PRODUCT_PACKAGES += \
    com.android.hardware.keymint.rust_nonsecure \
    com.android.hardware.gatekeeper.nonsecure

# 软件 HAL 全家桶（hardware/interfaces 各 default 实现，模块名逐一核实）。
# system_server 的 HAL 阶梯（每级都是实测 FATAL 后确认的）：
#   BatteryService     ← IHealth（"instance default isn't available"）
#   HintManagerService ← IPower（SupportInfo.headroom NPE）
# thermal/memtrack/lights/vibrator 为预防性（cuttlefish 同款 example）。
PRODUCT_PACKAGES += \
    android.hardware.health-service.example \
    android.hardware.power-service.example \
    android.hardware.memtrack-service.example \
    android.hardware.lights-service.example \
    android.hardware.vibrator-service.example

# 音频 HAL（AIDL 示例实现，null 音频）—— audioserver 没有 HAL 会 NPE
# 崩溃循环，而 system_server 主线程在 AudioService 构造时【同步阻塞】
# 等 IAudioPolicyService，等不到就被看门狗处决 → zygote 全家轮回
# （ANR trace 实锤，见 docs/stage2-findings.md）。audioserver 必须活。
# Stage 4 换 tinyhal 真声卡时再替换。
# ⚠️ example service 是 installable:false（bp 明写"installed in apex
# com.android.hardware.audio"），直接列包名会被静默丢弃——用 APEX：
PRODUCT_PACKAGES += \
    com.android.hardware.audio

# thermal HAL 同样是 installable:false 的 APEX 打包件：
#   hardware/interfaces/thermal/aidl/default/Android.bp 的 cc_binary
#   android.hardware.thermal-service.example 带 installable: false，
#   binary 只出现在 apex "com.android.hardware.thermal" 里。
# 2026-08-19 实测：直接列 binary 名会让 kati 报
#   "includes non-existent modules in PRODUCT_PACKAGES" 并中止构建。
PRODUCT_PACKAGES += \
    com.android.hardware.thermal

# effects HAL 启动即退（"config file audio_effects_config.xml not found"，
# 实测）。默认配置的 prebuilt_etc 被 soong config 门控着
# （hardware/interfaces/audio/aidl/default/Android.bp:372-378）：
$(call soong_config_set_bool,hardware_interfaces_audio,use_default_audio_effects_config,true)
PRODUCT_PACKAGES += \
    audio_effects_config.xml

# 音频 policy 配置 —— example HAL 的 IModule 实例清单【完全来自】
# audio_policy_configuration.xml 解析结果（main.cpp:93-99 实名核实），
# 没有它 HAL 只注册 IConfig，audioserver 等 IModule/default 永阻塞。
# xml 抄 cuttlefish（同款 HAL），XInclude 相对路径要求全家同目录：
PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/audio/audio_policy_configuration.xml:$(TARGET_COPY_OUT_VENDOR)/etc/audio_policy_configuration.xml \
    $(LOCAL_PATH)/audio/primary_audio_policy_configuration.xml:$(TARGET_COPY_OUT_VENDOR)/etc/primary_audio_policy_configuration.xml \
    frameworks/av/services/audiopolicy/config/r_submix_audio_policy_configuration.xml:$(TARGET_COPY_OUT_VENDOR)/etc/r_submix_audio_policy_configuration.xml \
    frameworks/av/services/audiopolicy/config/bluetooth_with_le_audio_policy_configuration_7_0.xml:$(TARGET_COPY_OUT_VENDOR)/etc/bluetooth_with_le_audio_policy_configuration_7_0.xml \
    frameworks/av/services/audiopolicy/config/audio_policy_volumes.xml:$(TARGET_COPY_OUT_VENDOR)/etc/audio_policy_volumes.xml \
    frameworks/av/services/audiopolicy/config/default_volume_tables.xml:$(TARGET_COPY_OUT_VENDOR)/etc/default_volume_tables.xml

# ------------------------------------------------------------------ 固件
# [measured] 全部来自 Stage 0 的 dmesg 固件加载路径。
# 配合 cmdline 里的 firmware_class.path=/vendor/firmware/，
# 必须保持相同的子路径结构。
# 华为那三个 .mbn 不在 linux-firmware 里，需从当前 Linux 系统
# /lib/firmware/ 下取出后放进 firmware/ 目录再打包。
PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/firmware/qcom/a660_sqe.fw:$(TARGET_COPY_OUT_VENDOR)/firmware/qcom/a660_sqe.fw \
    $(LOCAL_PATH)/firmware/qcom/a660_gmu.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/qcom/a660_gmu.bin \
    $(LOCAL_PATH)/firmware/qca/wcnhpbtfw21.tlv:$(TARGET_COPY_OUT_VENDOR)/firmware/qca/wcnhpbtfw21.tlv \
    $(LOCAL_PATH)/firmware/qca/wcnhpnv21g.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/qca/wcnhpnv21g.bin \
    $(LOCAL_PATH)/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qcadsp8280.mbn:$(TARGET_COPY_OUT_VENDOR)/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qcadsp8280.mbn \
    $(LOCAL_PATH)/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qccdsp8280.mbn:$(TARGET_COPY_OUT_VENDOR)/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qccdsp8280.mbn \
    $(LOCAL_PATH)/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qcslpi8280.mbn:$(TARGET_COPY_OUT_VENDOR)/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qcslpi8280.mbn

# ------------------------------------------------- Stage 3: 图形栈
# 全套照抄 device/linaro/dragonboard/shared/graphics/（db845c 同款），
# 属性名/包名均为树内实名，非记忆。density 用我们实测的 240（不抄他家 160）。

# gralloc：minigbm，platform=msm 是高通 UBWC 后端
# （external/minigbm/Android.bp 的 soong_config_variable("minigbm","platform")）
$(call soong_config_set,minigbm,platform,msm)
PRODUCT_PACKAGES += \
    android.hardware.graphics.allocator-service.minigbm \
    mapper.minigbm
PRODUCT_PROPERTY_OVERRIDES += \
    ro.hardware.gralloc=minigbm

# hwcomposer：drm_hwcomposer 的 HWC3 APEX
PRODUCT_PACKAGES += \
    com.android.hardware.graphics.composer.drm_hwcomposer

# GLES/Vulkan：Phase A = swangle（ANGLE over SwiftShader，纯树内 CPU 渲染）。
# ⚠️ 树内 mesa3d 不含 freedreno（见 BoardConfig 注释），Phase B 再换。
# 模板：dragonboard/shared/graphics/swangle/device.mk（db845c 同款）。
PRODUCT_PACKAGES += \
    libEGL_angle \
    libGLESv1_CM_angle \
    libGLESv2_angle \
    vulkan.pastel
PRODUCT_PROPERTY_OVERRIDES += \
    ro.opengles.version=196608
# ⚠️ ANGLE 库在 /system/lib64/ 根（AOSP 16 默认自带，不在 egl/ 子目录），
# 加载开关是 persist.graphics.egl（Loader.cpp:67-70 实名核实），
# ro.hardware.egl 走的是 egl/libEGL_*.so 搜索路径，对 ANGLE 不生效。
PRODUCT_PROPERTY_OVERRIDES += \
    persist.graphics.egl=angle
PRODUCT_VENDOR_PROPERTIES += \
    debug.hwui.renderer=skiagl

# ⚠️ 软渲染（SwiftShader）导入不了 UBWC 压缩 buffer —— SF 崩于
# "Failed to create a valid texture"（GaneshBackendTexture 导入
# AHardwareBuffer 失败，tombstone_48 实测）。强制 minigbm 分配线性 buffer。
# 来源：dragonboard minigbm_msm/device.mk 的 TARGET_USES_SWR 分支。
# Phase B 换 freedreno 后删掉这行（GPU 认 UBWC，还能提性能）。
PRODUCT_VENDOR_PROPERTIES += \
    vendor.minigbm.debug=nocompression

# ⚠️ simpledrm 先占 card0 后被 msm 顶替，msm 的 KMS 节点是 card1；
# drm_hwcomposer 默认扫 card0 会进无头模式（"No pipelines available"）。
# 活体实测：设此属性 + 重启 hwc 后 SF 立即拿到 Primary display
# 1600x2560@120Hz。属性名从 hwc3 二进制 strings 核实。
PRODUCT_VENDOR_PROPERTIES += \
    vendor.hwc.drm.device=/dev/dri/card1

# 慢设备处方（SwiftShader CPU 渲染下时序没有余量）：
# 看门狗/ANR 超时统一 ×5。cycle-1 的 AudioService 等 audioserver 发布
# 差几十秒被 60s 看门狗击杀 → 级联轮回（ANR 实锤）。Phase B 换
# freedreno 后可降回 2 或删除。
PRODUCT_VENDOR_PROPERTIES += \
    ro.hw_timeout_multiplier=5

# 硬件 feature 声明 —— 没有它 AppWidgetService 等一票系统服务不启动，
# Launcher 直接 NPE（"AppWidgetManager...on a null object" 实测）。
PRODUCT_COPY_FILES += \
    frameworks/native/data/etc/tablet_core_hardware.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/tablet_core_hardware.xml

PRODUCT_COPY_FILES += \
    frameworks/native/data/etc/android.hardware.opengles.aep.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.opengles.aep.xml \
    frameworks/native/data/etc/android.hardware.vulkan.level-1.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.vulkan.level.xml \
    frameworks/native/data/etc/android.hardware.vulkan.version-1_1.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.vulkan.version.xml

#
# Stage 3 之后再加（每次只加一个）：
#   音频   tinyhal（refs/aospm-tinyhal），源是 LENOVO-X13s.conf / sc8280xp.conf
#   WiFi   wpa_supplicant + ath11k
#   传感器 / 相机 / 振动
#

# ─── Stage 4: WiFi（ath11k 主线 + AIDL HAL APEX + wpa_supplicant）───
PRODUCT_PACKAGES += \
    com.android.hardware.wifi \
    wpa_supplicant

PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/wifi/wpa_supplicant.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/wpa_supplicant.rc \
    frameworks/native/data/etc/android.hardware.wifi.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.wifi.xml

# WCN6855 固件（board-2.bin 已验含 NTM_TW220，DTS qcom,calibration-variant 所需）
PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/firmware/ath11k/WCN6855/hw2.0/amss.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/ath11k/WCN6855/hw2.0/amss.bin \
    $(LOCAL_PATH)/firmware/ath11k/WCN6855/hw2.0/board-2.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/ath11k/WCN6855/hw2.0/board-2.bin \
    $(LOCAL_PATH)/firmware/ath11k/WCN6855/hw2.0/m3.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/ath11k/WCN6855/hw2.0/m3.bin \
    $(LOCAL_PATH)/firmware/ath11k/WCN6855/hw2.0/regdb.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/ath11k/WCN6855/hw2.0/regdb.bin

PRODUCT_VENDOR_PROPERTIES += \
    wifi.interface=wlan0

# 实机芯片是 wcn6855 hw2.1（dmesg 实测）；上游 WHENCE 将 hw2.1 软链到 hw2.0，
# vendor 里直接把 hw2.0 文件再装一份到 hw2.1 路径
PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/firmware/ath11k/WCN6855/hw2.0/amss.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/ath11k/WCN6855/hw2.1/amss.bin \
    $(LOCAL_PATH)/firmware/ath11k/WCN6855/hw2.0/board-2.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/ath11k/WCN6855/hw2.1/board-2.bin \
    $(LOCAL_PATH)/firmware/ath11k/WCN6855/hw2.0/m3.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/ath11k/WCN6855/hw2.1/m3.bin \
    $(LOCAL_PATH)/firmware/ath11k/WCN6855/hw2.0/regdb.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/ath11k/WCN6855/hw2.1/regdb.bin

# goldfish 命名空间：libwifi-hal-emu（mainline nl80211 通用 wifi HAL 实现）在里面
PRODUCT_SOONG_NAMESPACES += device/generic/goldfish

PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/wifi/wpa_supplicant.conf:$(TARGET_COPY_OUT_VENDOR)/etc/wifi/wpa_supplicant.conf

# ─── Stage 4: 蓝牙（WCN6855 / hci_qca，AOSP 原装 HAL 直接可用）───
# ⚠️ 2026-08-19 发现：#34 记了"把这个 HAL 推进 vendor 即可"，但那句话
#    从没变成一行构建配置 —— Stage 4 是走 adb remount 的 overlay 推的。
#    这是本轮第三个同类漏网（前两个：拓扑固件名、audio-route.sh）。
#
# 为什么原装 HAL 就够（无需改一行代码）：
#   hardware/interfaces/bluetooth/aidl/default/BluetoothHci.cpp:172
#   先试 NetBluetoothMgmt::openHci()（BT 管理 socket + HCI_CHANNEL_USER），
#   失败才退回串口路径 —— 正好对上主线内核的 hci0。
# 模块自带 init_rc 与 vintf_fragments；android.hardware.bluetooth-V1-ndk
# 是它的 shared_libs，会自动随包安装（当初 overlay 手推才要单独补那个 .so，
#   少了它是 CANNOT LINK EXECUTABLE 的 5 秒重启循环）。
#
# ⚠️ 蓝牙能不能真的起来还取决于内核：CONFIG_RT_GROUP_SCHED 必须为 n，
#    否则 bt_main_thread 拿不到 SCHED_FIFO → bluetooth::log::fatal。
#    kb21 已经关掉，scripts/kernel-config-android.sh 里有断言守着。
PRODUCT_PACKAGES += \
    android.hardware.bluetooth-service.default

PRODUCT_COPY_FILES += \
    frameworks/native/data/etc/android.hardware.bluetooth.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.bluetooth.xml \
    frameworks/native/data/etc/android.hardware.bluetooth_le.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.bluetooth_le.xml

# ─── Stage 4/5: 固件双路安装 ───
# 新增固件（从本机 Ubuntu /lib/firmware 提取，华为专有，不入版本库）：
#   qcdxkmsuc8280.mbn   GPU zap shader（freedreno 必需，缺则 GPU 锁在安全模式）
#   audioreach-tplg.bin 音频拓扑（缺则声卡不注册）
#   *.jsn               pd_mapper 服务表
# ★★ 拓扑固件必须装成【内核实际请求的那个名字】：
#     sound/soc/qcom/qdsp6/topology.c:1320 拼的是
#         qcom/<card->driver_name>/<card->name>-tplg.bin
#     本机 = qcom/sc8280xp/SC8280XP-HUAWEI-GAOKUN3-tplg.bin
#     （dmesg 实测：qcom-apm: tplg firmware loading ... failed -2，
#       见 docs/stage4-findings.md #33 第 219 行）
#     老规矩的 HUAWEI/gaokun3/audioreach-tplg.bin 内核【从不去读】，
#     两份内容 sha256 完全相同（24296 字节），所以同一个源文件装两遍。
#
# ⚠️ 这一条 Stage 4 只在实机 overlay 里手动补过，从没写进构建配置
#     —— 2026-08-19 转 crDroid 时才发现（否则 crDroid 首boot 声卡不注册）。
PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qcdxkmsuc8280.mbn:$(TARGET_COPY_OUT_VENDOR)/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qcdxkmsuc8280.mbn \
    $(LOCAL_PATH)/firmware/qcom/sc8280xp/HUAWEI/gaokun3/audioreach-tplg.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/qcom/sc8280xp/HUAWEI/gaokun3/audioreach-tplg.bin \
    $(LOCAL_PATH)/firmware/qcom/sc8280xp/HUAWEI/gaokun3/audioreach-tplg.bin:$(TARGET_COPY_OUT_VENDOR)/firmware/qcom/sc8280xp/SC8280XP-HUAWEI-GAOKUN3-tplg.bin \
    $(LOCAL_PATH)/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qcvss8280.mbn:$(TARGET_COPY_OUT_VENDOR)/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qcvss8280.mbn \
    $(LOCAL_PATH)/firmware/qcom/sc8280xp/HUAWEI/gaokun3/adspr.jsn:$(TARGET_COPY_OUT_VENDOR)/firmware/qcom/sc8280xp/HUAWEI/gaokun3/adspr.jsn \
    $(LOCAL_PATH)/firmware/qcom/sc8280xp/HUAWEI/gaokun3/adspua.jsn:$(TARGET_COPY_OUT_VENDOR)/firmware/qcom/sc8280xp/HUAWEI/gaokun3/adspua.jsn \
    $(LOCAL_PATH)/firmware/qcom/sc8280xp/HUAWEI/gaokun3/battmgr.jsn:$(TARGET_COPY_OUT_VENDOR)/firmware/qcom/sc8280xp/HUAWEI/gaokun3/battmgr.jsn \
    $(LOCAL_PATH)/firmware/qcom/sc8280xp/HUAWEI/gaokun3/cdspr.jsn:$(TARGET_COPY_OUT_VENDOR)/firmware/qcom/sc8280xp/HUAWEI/gaokun3/cdspr.jsn

# ramdisk 副本：让 remoteproc/GPU/BT 在 /vendor 挂载前的首次 probe 就拿到固件
# （ramdisk 是第一阶段 rootfs，firmware_class.path 找不到会回落 /lib/firmware）
PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qcadsp8280.mbn:ramdisk/lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qcadsp8280.mbn \
    $(LOCAL_PATH)/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qccdsp8280.mbn:ramdisk/lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qccdsp8280.mbn \
    $(LOCAL_PATH)/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qcslpi8280.mbn:ramdisk/lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qcslpi8280.mbn \
    $(LOCAL_PATH)/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qcdxkmsuc8280.mbn:ramdisk/lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qcdxkmsuc8280.mbn \
    $(LOCAL_PATH)/firmware/qcom/sc8280xp/HUAWEI/gaokun3/audioreach-tplg.bin:ramdisk/lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/audioreach-tplg.bin \
    $(LOCAL_PATH)/firmware/qcom/sc8280xp/HUAWEI/gaokun3/audioreach-tplg.bin:ramdisk/lib/firmware/qcom/sc8280xp/SC8280XP-HUAWEI-GAOKUN3-tplg.bin \
    $(LOCAL_PATH)/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qcvss8280.mbn:ramdisk/lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qcvss8280.mbn \
    $(LOCAL_PATH)/firmware/qcom/sc8280xp/HUAWEI/gaokun3/adspr.jsn:ramdisk/lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/adspr.jsn \
    $(LOCAL_PATH)/firmware/qcom/sc8280xp/HUAWEI/gaokun3/adspua.jsn:ramdisk/lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/adspua.jsn \
    $(LOCAL_PATH)/firmware/qcom/sc8280xp/HUAWEI/gaokun3/battmgr.jsn:ramdisk/lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/battmgr.jsn \
    $(LOCAL_PATH)/firmware/qcom/sc8280xp/HUAWEI/gaokun3/cdspr.jsn:ramdisk/lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/cdspr.jsn

PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/firmware/qca/wcnhpbtfw21.tlv:ramdisk/lib/firmware/qca/wcnhpbtfw21.tlv \
    $(LOCAL_PATH)/firmware/qca/wcnhpnv21g.bin:ramdisk/lib/firmware/qca/wcnhpnv21g.bin

# ─── Stage 5 Phase B: 硬件 Vulkan（turnip / freedreno on 主线 msm DRM）───
# 构建流程见 docs/stage5-freedreno.md：
#   1. scripts/mesa-tool-fixes.py     补 meson_to_hermetic 与 mesa 25.3 的 API 落差
#   2. 生成器 + scripts/mesa-bp-merge.py 产出 external/mesa3d/Android.bp
#   3. mesa/turnip-shared.bp.in       把静态库包成 Android Vulkan HAL 共享库
# GLES 仍由 ANGLE 提供，但它的 Vulkan 后端从此跑在 Adreno 690 上而不是 SwiftShader。
# ⚠️ GPU 需要 zap shader 固件 qcdxkmsuc8280.mbn（见上面的固件双路安装），
#    缺了它 GPU 停在安全模式，adreno probe 会失败。
# Stage 6 M3（2026-08-19）：管线已在 crDroid 树上跑通并打开。
# crDroid 的 external/mesa3d 与 Stage 5 打补丁那棵是【同一个 commit】
# （d4b6f1eba289… @ android-16.0.0_r4，mesa 25.3.0-devel），
# 所以 Stage 5 的补丁树逐字可套，不需要重新对齐生成管线。
PRODUCT_PACKAGES += \
    vulkan.freedreno

# 排障开关：想回软渲染就把这行改回 pastel（vulkan.pastel 包仍然装着，
# 两个 HAL 共存于 /vendor/lib64/hw/，只由这条属性决定 libvulkan 加载谁）。
PRODUCT_VENDOR_PROPERTIES += \
    ro.hardware.vulkan=freedreno

# GPU SMMU stall 解锁器（常驻安全网）。装它的理由、时序约束与
# NCB=2 的血泪教训见 etc/smmustall.rc 与 bin/smmu-nostall.sh 的注释。
# ⚠️ 这两个文件在 Stage 5 只通过 adb push 进过设备，从没写进构建配置 ——
#    与 audio-route.sh / tplg.bin 是完全同一类漏网。照原样构建会得到
#    「跑着 turnip 但没有安全网」，第一次 GPU 页错误就永久挂死且无法自愈。
PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/bin/smmu-nostall.sh:$(TARGET_COPY_OUT_VENDOR)/bin/smmu-nostall.sh \
    $(LOCAL_PATH)/etc/smmustall.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/smmustall.rc

# turnip 调试旗标加载器（快速迭代机制，见 docs/stage5-freedreno.md）
PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/bin/tu_debug_loader.sh:$(TARGET_COPY_OUT_VENDOR)/bin/tu_debug_loader.sh

# ─── Stage 4 的音频路由（Android 没有 ALSA UCM，混音器要自己摆）───
# ⚠️ 2026-08-19 发现：这两个文件在 Stage 4 时【只通过 adb remount 的 overlay】
#    进过设备，从没写进构建配置 —— 和 SC8280XP-HUAWEI-GAOKUN3-tplg.bin
#    是完全同一类漏网。照原样构建 crDroid 会变成「声卡注册了但没人配路由」，
#    症状是能播放却没有声音，而且本机没有串口，只能靠 logcat 猜。
# 路由序列的来历、BOOST 关闭与 PA=12 的取值理由见 bin/audio-route.sh 的注释。
PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/bin/audio-route.sh:$(TARGET_COPY_OUT_VENDOR)/bin/audio-route.sh \
    $(LOCAL_PATH)/etc/audioroute.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/audioroute.rc

# ─── Stage 6: 修正 /sys/fs/bpf 的 SELinux 标签（主线内核 vs Android 的不兼容）───
# 不装它 → ClatCoordinator 标签比对失败 → system_server 崩溃循环，开不进桌面。
# 完整机制、对照实验与时序依据见 bin/bpf-relabel.sh 的注释。
PRODUCT_COPY_FILES += \
    $(LOCAL_PATH)/bin/bpf-relabel.sh:$(TARGET_COPY_OUT_VENDOR)/bin/bpf-relabel.sh \
    $(LOCAL_PATH)/etc/bpfrelabel.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/bpfrelabel.rc
