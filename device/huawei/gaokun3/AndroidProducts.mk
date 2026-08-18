PRODUCT_MAKEFILES := \
    $(LOCAL_DIR)/lineage_gaokun3.mk

# release config = bp4a，来自 vendor/lineage/vars/aosp_target_release
# （crdroidandroid/android_vendor_crdroid@16.0，2026-08-19 核实）。
# brunch gaokun3 == lunch lineage_gaokun3-bp4a-userdebug
COMMON_LUNCH_CHOICES := \
    lineage_gaokun3-bp4a-userdebug \
    lineage_gaokun3-bp4a-eng
