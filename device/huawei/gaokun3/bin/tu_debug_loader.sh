#!/system/bin/sh
# turnip 调试旗标加载（gaokun 快速迭代机制）
setprop debug.tu.debug "$(cat /data/local/tmp/tu_debug 2>/dev/null)"
