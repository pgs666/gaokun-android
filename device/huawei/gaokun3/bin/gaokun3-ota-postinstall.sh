#!/system/bin/sh
#
# A/B OTA 的 postinstall 钩子：把刚刷好的那个槽的内核搬到 ESP 上。
#
# 背景：本机按 Android 分区规范有 boot_a / boot_b，update_engine 会像刷别的
# 分区一样把标准 Android boot 镜像刷进去。但引导链是 UEFI + systemd-boot，
# 它【读不了】Android boot 镜像 —— 只会从 ESP 按 BLS 条目加载文件。
# 所以过渡期在这里补一步：从 boot_<目标槽> 解出 kernel/ramdisk/dtb，
# 放到 ESP 上该槽专属的目录。
#   boot 分区 = 唯一真相源；ESP 上的文件 = 派生物。
# 两个槽的 BLS 条目【永久】指向各自的 slot_a/ slot_b，所以这里只放文件、
# 不改条目，也就绝不会碰到正在运行的那个槽 —— 回滚天然安全。
#
# 自研的 EFI 加载器（读 misc 选槽 + 解析 boot 镜像 + 装 initrd/DTB 协议）
# 就位之后，本脚本连同 ESP 上那些派生文件一起退役。
#
# ★ 参数是 update_engine 给的，不是猜的：
#   system/update_engine/payload_consumer/postinstall_runner_action.cc:355-357
#     argv[1] = target_slot（整数，0=_a 1=_b）  argv[2] = 状态 fd
#
# 退出码非 0 会让整个 OTA 失败。这是【故意的】：宁可更新失败，也不能让某个槽
# 位上出现"新 system + 旧内核"的组合。
set -u

TARGET_SLOT="${1:-}"
case "$TARGET_SLOT" in
    0) SUFFIX=a ;;
    1) SUFFIX=b ;;
    *) echo "postinstall: 目标槽位参数无效: '$TARGET_SLOT'"; exit 1 ;;
esac

# 本脚本随【新的】vendor 分区被挂到 /postinstall，所以同目录下的解包器
# 也是新的那一份 —— 与新 boot 镜像的格式必然匹配。
HERE="$(dirname "$0")"
EXTRACT="$HERE/gaokun3-bootimg-extract"
BOOT_DEV="/dev/block/by-name/boot_$SUFFIX"
ESP_DEV=/dev/block/by-name/esp
MNT=/mnt/gaokun3_ota_esp

log()  { echo "postinstall: $*"; }
fail() { log "失败: $*"; [ -n "${MOUNTED:-}" ] && { sync; umount "$MNT" 2>/dev/null; }; exit 1; }

log "目标槽位 = _$SUFFIX"

[ -x "$EXTRACT" ] || fail "$EXTRACT 不存在或不可执行"
[ -e "$BOOT_DEV" ] || fail "$BOOT_DEV 不存在（boot_a/boot_b 分区建了吗？）"
[ -e "$ESP_DEV" ]  || fail "$ESP_DEV 不存在（ESP 的 PARTLABEL 必须正好是 esp）"

mkdir -p "$MNT" || fail "mkdir $MNT"
mount -t vfat "$ESP_DEV" "$MNT" || fail "挂载 ESP"
MOUNTED=1

# systemd-boot 的布局是 <ESP>/<machine-id>/…，machine-id 不固定，按模式找
MID=$(ls "$MNT" | grep -E '^[0-9a-f]{32}$' | head -1)
[ -n "$MID" ] || fail "ESP 上找不到 machine-id 目录"
DEST="$MNT/$MID/android/slot_$SUFFIX"
mkdir -p "$DEST" || fail "mkdir $DEST"
log "目标目录 = $DEST"

# ★ 先看空间：ESP 只有 300 MiB，还要和固件自己那个 73 MiB 的
#   Persisted_Capsules.bin 共处。空间不够必须【当场失败】，
#   而不是写出一个被截断的内核 —— 那会变成一台不开机的机器。
#   目标目录里的旧文件会被覆盖，所以它们占的空间算作可用。
avail_kb=$(df -k "$MNT" | tail -1 | awk '{print $4}')
for f in Image ramdisk.img gaokun3.dtb; do
    [ -f "$DEST/$f" ] && avail_kb=$((avail_kb + $(stat -c%s "$DEST/$f") / 1024))
done
log "可用（含将被覆盖的旧文件）约 ${avail_kb} KB"
# zboot 内核 13 MB + ramdisk 13 MB + dtb 0.2 MB ≈ 27 MB，要 40 MB 余量
[ "$avail_kb" -gt 40960 ] || \
    fail "ESP 空间不足（需约 40 MB）。清掉 <ESP>/$MID/android/ 下的 *.bak-* 再试"

# 解包器自己会写临时文件再改名，并逐段核对长度
"$EXTRACT" "$BOOT_DEV" "$DEST" || fail "从 $BOOT_DEV 解包失败"

sync
umount "$MNT" || log "警告: umount 失败（数据已 sync）"
log "完成：_$SUFFIX 槽的内核已就位"
exit 0
