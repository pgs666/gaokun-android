#
# device.mk -- Huawei MateBook E Go (gaokun3)
#
# Stage 2 原则：能不装的一律不装。缺 HAL 顶多日志报错，
# 多一个坏 HAL 就可能让 init 起不来，而本机没有串口可看。
#

LOCAL_PATH := device/huawei/gaokun3

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
# adb 默认开，且不要求授权 —— Stage 2 的验收就是 adb 能连上
PRODUCT_PROPERTY_OVERRIDES += \
    ro.adb.secure=0 \
    ro.debuggable=1 \
    persist.sys.usb.config=adb

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

#
# Stage 2 刻意不装的东西（Stage 3/4 再逐个加，每次只加一个）：
#   图形   minigbm(cros_gralloc) + drm_hwcomposer_hwc3 + mesa3d  <- 三者已在树内
#   音频   tinyhal（refs/aospm-tinyhal），源是 LENOVO-X13s.conf / sc8280xp.conf
#   WiFi   wpa_supplicant + ath11k
#   传感器 / 相机 / 振动
#
