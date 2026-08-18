#!/bin/bash
# 在 Ego 的 **Ubuntu 侧**离线访问 Android 的 vendor overlay —— adb 不通时的救场通道。
#
# 背景：`adb remount` 会在 super 里动态建一个名叫 scratch 的逻辑分区，
# overlayfs 的 upper 层（我们改过的 build.prop / init rc / vulkan HAL）全在里面。
# 一旦某次改动让 Android 起不来，adb 就没了 —— 但 super 只是 nvme 上一个普通分区，
# LP 元数据能纯 Python 解出来（scripts/lpext.py 同一套解析），
# 于是可以 losetup 挂上 scratch，把改动改回去。
#
# 用法（在 Ego 的 Ubuntu 上，sudo 免密）：
#   overlay-rescue.sh inspect              # 只读体检：占用、我们的三个改动、是否损坏
#   overlay-rescue.sh mount                # 读写挂到 /mnt/vscratch，之后随意操作
#   overlay-rescue.sh set-vulkan pastel    # 一键把 vendor 的 Vulkan HAL 切回软渲染
#   overlay-rescue.sh umount
set -u
SUPER=${SUPER:-/dev/nvme0n1p8}
MNT=/mnt/vscratch
ACT=${1:-inspect}

find_scratch() {
    sudo python3 - "$SUPER" <<'EOF'
import struct, sys
f = open(sys.argv[1], "rb")
f.seek(4096); g = f.read(4096)
magic, ssz, chk, mmax, slots, lbs = struct.unpack_from("<II32sIII", g, 0)
off = 4096 * 3
f.seek(off); h = f.read(512)
hmagic, maj, mnr, hsz = struct.unpack_from("<IHHI", h, 0)
p_off, p_num, p_sz = struct.unpack_from("<III", h, 80)
e_off, e_num, e_sz = struct.unpack_from("<III", h, 92)
f.seek(off + hsz + e_off)
ext = [struct.unpack_from("<QIQI", f.read(e_sz), 0) for _ in range(e_num)]
f.seek(off + hsz + p_off)
for _ in range(p_num):
    e = f.read(p_sz)
    name = e[:36].split(b"\x00")[0].decode()
    attr, first, num, grp = struct.unpack_from("<IIII", e, 36)
    for j in range(first, first + num):
        ns, tt, td, tsrc = ext[j]
        if name == "scratch":
            print("%d %d" % (td * 512, ns * 512))
EOF
}

do_mount() {
    mountpoint -q $MNT && { echo "已挂在 $MNT"; return 0; }
    read -r OFF SZ <<<"$(find_scratch)"
    [ -n "${OFF:-}" ] || { echo "!! super 里没有 scratch 分区（overlay 从没建过？）" >&2; exit 1; }
    echo "scratch: offset=$OFF size=$SZ ($((SZ / 1024 / 1024)) MB)"
    LOOP=$(sudo losetup -f --show -o "$OFF" --sizelimit "$SZ" "$SUPER") || exit 1
    echo "loop: $LOOP"
    sudo mkdir -p $MNT
    sudo mount "$1" "$LOOP" $MNT || { sudo losetup -d "$LOOP"; exit 1; }
    echo "已挂载 $MNT（$1）"
}

do_umount() {
    LOOP=$(losetup -j "$SUPER" | cut -d: -f1 | head -1)
    sudo umount $MNT 2>/dev/null
    [ -n "$LOOP" ] && sudo losetup -d "$LOOP"
    echo "已卸载"
}

case "$ACT" in
inspect)
    do_mount -oro
    V=$MNT/overlay/vendor/upper
    echo "=== 空间占用（scratch 满了会让 adb push / sed -i 写坏文件）==="
    df -h $MNT | tail -1
    echo "=== overlay 目录 ==="
    sudo ls -la $MNT/overlay/ 2>&1
    echo "=== vendor upper 里我们改过的东西 ==="
    sudo find $V -maxdepth 3 \( -type f -o -type c \) -printf "%y %10s %p\n" 2>/dev/null | head -30
    echo "=== build.prop 关键行（截断/损坏一眼可见）==="
    echo -n "行数: "; sudo wc -l < $V/build.prop 2>/dev/null || echo "(没有)"
    sudo grep -nE "hardware.vulkan|hwui.renderer" $V/build.prop 2>/dev/null
    echo "=== smmustall.rc ==="
    sudo cat $V/etc/init/smmustall.rc 2>/dev/null || echo "(不在 upper 层)"
    echo "=== vulkan HAL ==="
    sudo ls -la $V/lib64/hw/ 2>/dev/null
    do_umount
    ;;
mount)   do_mount -orw ;;
umount)  do_umount ;;
postmortem)
    # Android 起不来时的尸检：userdata 是普通物理分区，Ubuntu 直接挂得上。
    # tombstone / ANR / dropbox 的时间戳能回答两个关键问题：
    #   ① Android 到底跑起来没有（有没有新文件）
    #   ② 崩的是谁（tombstone 里的进程名与 backtrace 库名）
    DEV=$(blkid -t PARTLABEL=userdata -o device | head -1)
    [ -n "$DEV" ] || { echo "!! 找不到 PARTLABEL=userdata" >&2; exit 1; }
    echo "userdata = $DEV"
    sudo mkdir -p /mnt/adata
    mountpoint -q /mnt/adata || sudo mount -o ro "$DEV" /mnt/adata || exit 1
    echo "=== 最近改动的文件（Android 究竟跑到哪一步）==="
    sudo find /mnt/adata -maxdepth 3 -newermt "-6 hours" -printf "%TY-%Tm-%Td %TH:%TM %p\n" 2>/dev/null | sort | tail -25
    echo "=== tombstones ==="
    sudo ls -la /mnt/adata/tombstones/ 2>&1 | tail -8
    echo "=== 最新 tombstone 头 40 行 ==="
    T=$(sudo ls -t /mnt/adata/tombstones/tombstone_* 2>/dev/null | head -1)
    [ -n "$T" ] && sudo head -40 "$T"
    echo "=== ANR ==="
    sudo ls -la /mnt/adata/anr/ 2>&1 | tail -5
    sudo umount /mnt/adata
    ;;
set-vulkan)
    NEW=${2:?用法: set-vulkan pastel|freedreno}
    do_mount -orw
    P=$MNT/overlay/vendor/upper/build.prop
    sudo sed -i "s/^ro.hardware.vulkan=.*/ro.hardware.vulkan=$NEW/" "$P" || exit 1
    sudo grep -n "hardware.vulkan" "$P"
    sync; do_umount
    ;;
*) echo "用法: $0 inspect|mount|umount|set-vulkan <pastel|freedreno>" >&2; exit 1 ;;
esac
