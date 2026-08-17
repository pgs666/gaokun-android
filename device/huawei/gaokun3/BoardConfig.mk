#
# BoardConfig for Huawei MateBook E Go (sc8280xp / gaokun3)
#
# Bring-up target: Stage 2 == "adb shell works, black screen is fine".
# Deliberately minimal -- every HAL added here is another way for the first
# boot to fail, and this machine has no serial console to tell us which one.
#
# Everything marked [measured] came from the Stage 0 hardware inventory on the
# real device (docs/hw-inventory.md), not from a template.
#

# ---------------------------------------------------------------- 架构
# [measured] dmesg: "Booting Linux on physical CPU 0x0000000000 [0x410fd4b0]"
#   0x41 = ARM, part 0xd4b = Cortex-A78C  ->  ARMv8.2-A
TARGET_ARCH             := arm64
TARGET_ARCH_VARIANT     := armv8-2a
TARGET_CPU_VARIANT      := generic
TARGET_CPU_ABI          := arm64-v8a

TARGET_2ND_ARCH         := arm
TARGET_2ND_ARCH_VARIANT := armv8-2a
TARGET_2ND_CPU_VARIANT  := generic
TARGET_2ND_CPU_ABI      := armeabi-v7a
TARGET_2ND_CPU_ABI2     := armeabi

TARGET_BOARD_PLATFORM     := sc8280xp
TARGET_BOOTLOADER_BOARD_NAME := gaokun3

# ------------------------------------------------------- 没有 bootloader
# 本机是 UEFI + systemd-boot，不是 fastboot 设备。
# kernel / ramdisk / dtb 由 systemd-boot 从 ESP 直接加载，
# 所以不生成 boot.img，也没有 recovery 分区。
TARGET_NO_BOOTLOADER := true
TARGET_NO_RECOVERY   := true
TARGET_NO_KERNEL     := true      # 内核在树外自己编（v7.2-rc2 + gaokun3 补丁）
BOARD_USES_GENERIC_KERNEL_IMAGE := false

# ---------------------------------------------------------------- cmdline
# 只用于记录；实际生效的是 systemd-boot BLS entry 的 options 行
# （见 docs/stage2-plan.md 第 3 节）。两处必须保持一致。
#
# [measured] boot_devices 来自
#   /sys/devices/platform/soc@0/1c20000.pcie/pci0002:00/.../nvme/nvme0/nvme0n1
#
# ⚠️ 绝对不要加 earlycon：强烈怀疑 earlycon=efifb 会挂死本机启动，
#    见 docs/stage1-kernel-plan.md 第 1.0 节。
BOARD_KERNEL_CMDLINE := \
    androidboot.hardware=gaokun3 \
    androidboot.boot_devices=soc@0/1c20000.pcie \
    androidboot.selinux=permissive \
    firmware_class.path=/vendor/firmware/ \
    init=/init printk.devkmsg=on deferred_probe_timeout=30 \
    console=tty0 \
    clk_ignore_unused pd_ignore_unused arm64.nopauth efi=noruntime \
    fbcon=rotate:1 usbhid.quirks=0x12d1:0x10b8:0x20000000

# ------------------------------------------------------------ 分区布局
# 动态分区（super）而不是分立分区：AOSP 16 默认如此，构建直接产出
# super.img；关掉它反而要逆着构建系统走。
#
# ⚠️ PRODUCT_USE_DYNAMIC_PARTITIONS 是 **product** 变量
#    （build/make/core/product.mk:311），不是 board 变量。
#    product 配置先于 BoardConfig.mk 解析完并转为只读，在这里赋值会报
#    "cannot assign to readonly variable"。它设在 aosp_gaokun3.mk 里。
BOARD_SUPER_PARTITION_SIZE   := 12884901888        # 12 GiB
BOARD_SUPER_PARTITION_GROUPS := gaokun3_dynamic_partitions
BOARD_GAOKUN3_DYNAMIC_PARTITIONS_PARTITION_LIST := system system_ext product vendor
# 组大小留出 metadata 余量，官方建议比 super 小一些
BOARD_GAOKUN3_DYNAMIC_PARTITIONS_SIZE := 12683575296   # super - 200 MiB

# [实测必需] 只有设了这一项，AOSP 才会在 system 镜像根目录创建 /metadata 挂载点。
# 缺了它，init 在 switch_root 时会因为
#   "Unable to move mount at '/metadata' to '/system/metadata'"
# 而失败并复位。见 docs/stage2-findings.md 第 4 节。
# 注意：不能事后往镜像里 mkdir 补 —— system.img 按内容精确打包，可用空间为 0。
BOARD_USES_METADATA_PARTITION := true

BOARD_SYSTEMIMAGE_FILE_SYSTEM_TYPE := ext4
BOARD_VENDORIMAGE_FILE_SYSTEM_TYPE := ext4
BOARD_SYSTEM_EXTIMAGE_FILE_SYSTEM_TYPE := ext4
BOARD_PRODUCTIMAGE_FILE_SYSTEM_TYPE := ext4
BOARD_USERDATAIMAGE_FILE_SYSTEM_TYPE := ext4
TARGET_USERIMAGES_USE_EXT4 := true
TARGET_USERIMAGES_USE_F2FS := true

TARGET_COPY_OUT_VENDOR      := vendor
TARGET_COPY_OUT_SYSTEM_EXT  := system_ext
TARGET_COPY_OUT_PRODUCT     := product

BOARD_FLASH_BLOCK_SIZE := 262144

# 没有 A/B，没有 fastboot，不做 OTA
AB_OTA_UPDATER := false

# ----------------------------------------------------- Stage 3: 图形栈
# 模板：device/linaro/dragonboard/shared/graphics/（db845c = 树内同款高通主线）。
#
# ⚠️ 实测教训（2026-08-17）：AOSP 16 树内的 external/mesa3d 是 gfxstream 向
# fork，【不含 freedreno】；BOARD_MESA3D_* / BOARD_USE_CUSTOMIZED_MESA 在
# 本 manifest 里【无任何消费者】（grep 全树验证），设了会被静默忽略，
# 且缺失的 PRODUCT_PACKAGES 因 ALLOW_MISSING_DEPENDENCIES 不报错。
# → Phase A（现在）：swangle = ANGLE over SwiftShader Vulkan，纯树内，
#   CPU 渲染先出画面（dragonboard/shared/graphics/swangle/ 同款）。
# → Phase B（Stage 5 前）：引入 GloDroid 式 mesa 胶水构建 freedreno/turnip，
#   参考平行项目（docs/parallel-mainline-generic.md）。
PRODUCT_REQUIRES_INSECURE_EXECMEM_FOR_SWIFTSHADER := true

# --------------------------------------------------------------- sepolicy
# permissive 起步（cmdline 里也带了），但 policy 仍要能编过
BOARD_VENDOR_SEPOLICY_DIRS += device/huawei/gaokun3/sepolicy
# minigbm / swangle 的 sepolicy 直接复用 dragonboard 的（同一套 HAL）
BOARD_VENDOR_SEPOLICY_DIRS += device/linaro/dragonboard/shared/graphics/minigbm_msm/sepolicy
BOARD_VENDOR_SEPOLICY_DIRS += device/linaro/dragonboard/shared/graphics/swangle/sepolicy

# --------------------------------------------------------------- VINTF
DEVICE_MANIFEST_FILE := device/huawei/gaokun3/manifest.xml

#
# 刻意【不】设置的项 —— 都已对 AOSP 16 源码核实：
#
#   BOARD_VNDK_VERSION       build/make/core/config.mk:1268-1270 会强制清空，
#                            VNDK 在 Android 16 已移除
#   PRODUCT_FULL_TREBLE      config.mk:773-782 已强制为 true 且 .KATI_READONLY，
#                            再设一次会报错
#   TARGET_USES_HWC2         构建系统里已无任何引用
#   WITH_DEXPREOPT_PIC       同上
#   BOARD_USES_DRM_HWCOMPOSER 同上 —— Stage 3 改用 minigbm + drm_hwcomposer_hwc3，
#                            三者（含 mesa3d）都已在 AOSP 16 树内
#
# 以上都是 aospm sdm845 模板（Android 13 时代）里有、但在 16 上会出问题的写法。
#

# WiFi
WPA_SUPPLICANT_VERSION := VER_0_8_X
BOARD_WPA_SUPPLICANT_DRIVER := NL80211
