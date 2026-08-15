#
# Product definition for Huawei MateBook E Go (sc8280xp / gaokun3)
#
# 继承链沿用 aospm 在 sdm845 上验证过的组合（core_64_bit + full_base）。
# Stage 2 只要 adb，但 full_base 让 Stage 3 不必重做 product 定义。
#

$(call inherit-product, $(SRC_TARGET_DIR)/product/core_64_bit.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/full_base.mk)
$(call inherit-product, device/huawei/gaokun3/device.mk)

# 动态分区（super）。这是 product 变量，必须设在这里而不是 BoardConfig.mk
# —— 后者解析时它已经只读了。
PRODUCT_USE_DYNAMIC_PARTITIONS := true

PRODUCT_NAME   := aosp_gaokun3
PRODUCT_DEVICE := gaokun3
PRODUCT_BRAND  := Huawei
PRODUCT_MODEL  := MateBook E Go
PRODUCT_MANUFACTURER := Huawei

# API 等级：不声明 vendor 冻结，按当前平台走
PRODUCT_SHIPPING_API_LEVEL := 36
