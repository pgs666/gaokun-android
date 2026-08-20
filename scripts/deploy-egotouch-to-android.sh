#!/usr/bin/env bash
# 在救援 Ubuntu 上把 GitHub Actions 构建的 EGoTouchRev 内核部署到 Android _a 槽。
# 用法： bash deploy-egotouch-to-android.sh <artifact.zip>
#
# 前置：
#   - 已备份 boot_a / boot_b / ESP（脚本会再次检查）
#   - artifact.zip 里包含 vmlinuz.efi、gaokun3.dtb
#   - 当前在救援 Ubuntu，adb 在重启后可用
set -euo pipefail

ARTIFACT="${1:-}"
if [[ -z "$ARTIFACT" || ! -f "$ARTIFACT" ]]; then
    echo "用法: $0 <artifact.zip>" >&2
    exit 1
fi

# ── 常量 ────────────────────────────────────────────────────────────────────
MID=15712761d310481ab255ee2b8eef12e9
ESP=/boot/efi
SLOT_A_DIR="$ESP/$MID/android/slot_a"
BOOT_A=/dev/disk/by-partlabel/boot_a
BOOT_B=/dev/disk/by-partlabel/boot_b
ESP_DEV=/dev/disk/by-partlabel/esp

# ── 安全检查 ────────────────────────────────────────────────────────────────
if [[ "$BOOT_A" != /dev/* ]] || [[ "$BOOT_B" != /dev/* ]]; then
    echo "错误: boot 分区路径异常" >&2
    exit 1
fi

if [[ ! -b "$BOOT_A" || ! -b "$BOOT_B" || ! -b "$ESP_DEV" ]]; then
    echo "错误: 找不到 boot_a / boot_b / esp 分区" >&2
    ls -l /dev/disk/by-partlabel/ >&2
    exit 1
fi

echo "════════════════════════════════════════════════════════════"
echo "部署 EGoTouchRev 内核到 Android _a 槽"
echo "════════════════════════════════════════════════════════════"
echo "Artifact: $ARTIFACT"
echo "boot_a:   $BOOT_A"
echo "boot_b:   $BOOT_B"
echo "ESP:      $ESP_DEV"
echo "slot_a:   $SLOT_A_DIR"
echo
read -r -p "是否已备份 boot_a/boot_b/ESP？（输入 yes 继续）: " confirm
if [[ "$confirm" != "yes" ]]; then
    echo "已取消。请先运行备份步骤。" >&2
    exit 1
fi

# ── 解压 artifact ───────────────────────────────────────────────────────────
WORK=$(mktemp -d /tmp/egotouch-deploy.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

echo "== 解压 artifact 到 $WORK =="
unzip -q "$ARTIFACT" -d "$WORK"

VMLINUZ=$(find "$WORK" -name 'vmlinuz.efi' -type f | head -1)
DTB=$(find "$WORK" -name 'gaokun3.dtb' -type f | head -1)

if [[ -z "$VMLINUZ" || ! -s "$VMLINUZ" ]]; then
    echo "错误: artifact 中找不到 vmlinuz.efi" >&2
    exit 1
fi
if [[ -z "$DTB" || ! -s "$DTB" ]]; then
    echo "错误: artifact 中找不到 gaokun3.dtb" >&2
    exit 1
fi

echo "vmlinuz.efi: $VMLINUZ ($(stat -c%s "$VMLINUZ") bytes)"
echo "gaokun3.dtb: $DTB ($(stat -c%s "$DTB") bytes)"

# ── 从当前 boot_a 解出 ramdisk 和 cmdline ───────────────────────────────────
RAMDISK_DIR="$WORK/ramdisk"
mkdir -p "$RAMDISK_DIR"

echo "== 从 $BOOT_A 解出 ramdisk / cmdline =="
python3 - "$BOOT_A" "$RAMDISK_DIR" <<'PYEOF'
import struct, sys, os
img, out = sys.argv[1], sys.argv[2]
with open(img, "rb") as f:
    hdr = f.read(1664)
    if hdr[:8] != b"ANDROID!":
        sys.exit("not an Android boot image (bad magic)")
    u32 = lambda off: struct.unpack_from("<I", hdr, off)[0]
    kernel_size, ramdisk_size, second_size = u32(8), u32(16), u32(24)
    page, ver = u32(36), u32(40)
    if ver != 2:
        sys.exit(f"expected boot header v2, got {ver}")
    recovery_dtbo_size, dtb_size = u32(1632), u32(1648)
    cmdline = hdr[64:64+512].split(b'\x00', 1)[0].decode('utf-8', errors='ignore')
    extra_cmdline = hdr[1056:1056+1024].split(b'\x00', 1)[0].decode('utf-8', errors='ignore')
    full_cmdline = (cmdline + extra_cmdline).strip()
    with open(os.path.join(out, "cmdline.txt"), "w") as o:
        o.write(full_cmdline + "\n")
    align = lambda x: (x + page - 1) // page * page
    off = page
    parts = []
    for size, name in ((kernel_size, "Image"), (ramdisk_size, "ramdisk.img")):
        parts.append((off, size, name))
        off += align(size)
    off += align(second_size) + align(recovery_dtbo_size)
    parts.append((off, dtb_size, "gaokun3.dtb"))
    for start, size, name in parts:
        if size == 0:
            sys.exit(f"{name} is empty in the boot image")
        f.seek(start)
        data = f.read(size)
        if len(data) != size:
            sys.exit(f"short read for {name}")
        with open(os.path.join(out, name), "wb") as o:
            o.write(data)
        print(f"  {name:12s} {size:10d} bytes")
PYEOF

RAMDISK="$RAMDISK_DIR/ramdisk.img"
CMDLINE="$RAMDISK_DIR/cmdline.txt"
if [[ ! -s "$RAMDISK" ]]; then
    echo "错误: 未能解出 ramdisk.img" >&2
    exit 1
fi
echo "cmdline: $(cat "$CMDLINE")"

# ── 打包新 boot.img（不依赖 mkbootimg，直接复写原 header）─────────────────────
BOOT_NEW="$WORK/boot-new-a.img"
echo "== 打包新 boot.img =="

python3 - "$BOOT_A" "$VMLINUZ" "$RAMDISK" "$DTB" "$BOOT_NEW" <<'PYEOF'
import struct, sys, os

def align(x, page):
    return (x + page - 1) // page * page

src_img, kernel_path, ramdisk_path, dtb_path, out_path = sys.argv[1:6]

with open(src_img, "rb") as f:
    hdr = bytearray(f.read(1664))
if hdr[:8] != b"ANDROID!":
    sys.exit("源 boot.img magic 错误")

u32 = lambda off: struct.unpack_from("<I", hdr, off)[0]
page = u32(36)
ver = u32(40)
if ver != 2:
    sys.exit(f"仅支持 header v2，当前 {ver}")

with open(kernel_path, "rb") as f:
    kernel = f.read()
with open(ramdisk_path, "rb") as f:
    ramdisk = f.read()
with open(dtb_path, "rb") as f:
    dtb = f.read()

# 更新 header 中的大小字段
struct.pack_into("<I", hdr, 8, len(kernel))
struct.pack_into("<I", hdr, 16, len(ramdisk))
struct.pack_into("<I", hdr, 24, 0)          # second_size
struct.pack_into("<I", hdr, 1632, 0)       # recovery_dtbo_size
struct.pack_into("<I", hdr, 1648, len(dtb))
struct.pack_into("<I", hdr, 1644, 1660)   # header_size for v2

# 清零 id 字段（hash 不再匹配原镜像，对 UEFI 启动无影响）
hdr[576:608] = b'\x00' * 32

with open(out_path, "wb") as out:
    out.write(hdr)
    # kernel
    out.write(kernel)
    out.write(b'\x00' * (align(len(kernel), page) - len(kernel)))
    # ramdisk
    out.write(ramdisk)
    out.write(b'\x00' * (align(len(ramdisk), page) - len(ramdisk)))
    # second (0)
    # recovery_dtbo (0)
    # dtb
    out.write(dtb)
    out.write(b'\x00' * (align(len(dtb), page) - len(dtb)))

print(f"新 boot.img 已写入: {out_path}")
print(f"  kernel: {len(kernel)} bytes")
print(f"  ramdisk: {len(ramdisk)} bytes")
print(f"  dtb: {len(dtb)} bytes")
PYEOF

echo "新 boot.img: $BOOT_NEW ($(stat -c%s "$BOOT_NEW") bytes)"

# ── 刷入 boot_a ─────────────────────────────────────────────────────────────
echo "== 刷入 boot_a =="
sudo dd if="$BOOT_NEW" of="$BOOT_A" bs=4M conv=fsync status=progress
sync

# ── 解包到 ESP slot_a ───────────────────────────────────────────────────────
echo "== 更新 ESP slot_a =="
MNT=$(mktemp -d /mnt/egotouch-esp.XXXXXX)
trap 'sudo umount "$MNT" 2>/dev/null || true; rm -rf "$MNT"; rm -rf "$WORK"' EXIT

sudo mount -t vfat "$ESP_DEV" "$MNT"
sudo mkdir -p "$MNT/$MID/android/slot_a"

python3 - "$BOOT_A" "$MNT/$MID/android/slot_a" <<'PYEOF'
import struct, sys, os
img, out = sys.argv[1], sys.argv[2]
with open(img, "rb") as f:
    hdr = f.read(1664)
    if hdr[:8] != b"ANDROID!":
        sys.exit("not an Android boot image (bad magic)")
    u32 = lambda off: struct.unpack_from("<I", hdr, off)[0]
    kernel_size, ramdisk_size, second_size = u32(8), u32(16), u32(24)
    page, ver = u32(36), u32(40)
    if ver != 2:
        sys.exit(f"expected boot header v2, got {ver}")
    recovery_dtbo_size, dtb_size = u32(1632), u32(1648)
    cmdline = hdr[64:64+512].split(b'\x00', 1)[0].decode('utf-8', errors='ignore')
    extra_cmdline = hdr[1056:1056+1024].split(b'\x00', 1)[0].decode('utf-8', errors='ignore')
    full_cmdline = (cmdline + extra_cmdline).strip()
    with open(os.path.join(out, "cmdline.txt"), "w") as o:
        o.write(full_cmdline + "\n")
    align = lambda x: (x + page - 1) // page * page
    off = page
    parts = []
    for size, name in ((kernel_size, "Image"), (ramdisk_size, "ramdisk.img")):
        parts.append((off, size, name))
        off += align(size)
    off += align(second_size) + align(recovery_dtbo_size)
    parts.append((off, dtb_size, "gaokun3.dtb"))
    for start, size, name in parts:
        if size == 0:
            sys.exit(f"{name} is empty in the boot image")
        f.seek(start)
        data = f.read(size)
        if len(data) != size:
            sys.exit(f"short read for {name}")
        with open(os.path.join(out, name), "wb") as o:
            o.write(data)
        print(f"  {name:12s} {size:10d} bytes")
PYEOF

sudo umount "$MNT"

# ── 设置一次性启动到 _a，保留 Ubuntu 默认安全网 ─────────────────────────────
echo "== 设置一次性启动到 android-a =="
sudo bootctl set-oneshot "$MID-android-a.conf"

echo
echo "════════════════════════════════════════════════════════════"
echo "部署完成。请检查："
echo "  1. ESP slot_a 文件已更新: $SLOT_A_DIR"
echo "  2. boot_a 分区已刷新"
echo "  3. 下次启动将一次性进入 android-a"
echo
echo "建议执行: sudo systemctl reboot"
echo "起来后验证: adb shell uname -a"
echo "           adb shell dmesg | grep -iE 'himax|hx83121a|touch'"
echo "════════════════════════════════════════════════════════════"
