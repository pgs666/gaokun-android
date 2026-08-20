#!/usr/bin/env bash
# Prepare a Linux v7.2-rc2 tree for the gaokun3 Android kernel build.
#
# The released Android kernel is not just the linux-gaokun-buildbot tree:
# it also contains ACK compatibility drivers and gaokun-android patches.  Keep
# those source changes in one place so a successful compile cannot silently
# produce a kernel that stalls during Android userspace startup.
set -euo pipefail

KERNEL_DIR="${1:?usage: $0 <linux-source-dir>}"
REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
ACK_REV=36f28f93dabdfb0fc8f0e256ed849ff732390871
ACK_BASE="https://android.googlesource.com/kernel/common/+/$ACK_REV"

test -d "$KERNEL_DIR/.git"

echo "== Applying gaokun-android kernel patches =="
for patch in \
    0001-efi-pstore-register-backend-when-efivars-ops-arrive-.patch \
    0002-arm64-dts-gaokun3-drive-ts-mode-gpio174-low.patch \
    0007-bpf-inode-label-bpffs-lazily-for-android-genfscon.patch \
    0009-arm64-dts-sc8280xp-add-cpu-cooling-maps.patch
do
    git -C "$KERNEL_DIR" apply --check "$REPO_DIR/patches/$patch"
    git -C "$KERNEL_DIR" apply "$REPO_DIR/patches/$patch"
done

fetch_ack_file() {
    local path=$1
    local dest="$KERNEL_DIR/$path"

    mkdir -p "$(dirname "$dest")"
    curl --fail --location --silent --show-error \
        "$ACK_BASE/$path?format=TEXT" | base64 --decode > "$dest"
    test -s "$dest"
}

echo "== Restoring Android ashmem compatibility driver from ACK $ACK_REV =="
fetch_ack_file drivers/staging/android/ashmem.c
fetch_ack_file drivers/staging/android/ashmem.h
fetch_ack_file drivers/staging/android/uapi/ashmem.h
fetch_ack_file drivers/staging/android/Kconfig
fetch_ack_file drivers/staging/android/Makefile

# Linux 7.2 made vm_area_struct flags type-safe.  The ACK source still uses
# the legacy vm_flags view at this call site; pass the native flags value.
sed -i 's/shmem_file_setup(name, asma->size, vma->vm_flags)/shmem_file_setup(name, asma->size, vma->flags)/' \
    "$KERNEL_DIR/drivers/staging/android/ashmem.c"
# inode numbers are u64 on this kernel, including arm64 where unsigned long
# and u64 are distinct GCC format types.
sed -i 's/seq_printf(m, "inode:\\t%ld\\n", file_inode(asma->file)->i_ino);/seq_printf(m, "inode:\\t%llu\\n", (unsigned long long)file_inode(asma->file)->i_ino);/' \
    "$KERNEL_DIR/drivers/staging/android/ashmem.c"

if ! grep -qF 'source "drivers/staging/android/Kconfig"' "$KERNEL_DIR/drivers/staging/Kconfig"; then
    sed -i '/^endif # STAGING/i source "drivers/staging/android/Kconfig"\n' \
        "$KERNEL_DIR/drivers/staging/Kconfig"
fi
if ! grep -qF 'obj-$(CONFIG_ANDROID_STAGING)' "$KERNEL_DIR/drivers/staging/Makefile"; then
    printf '%s\n' 'obj-$(CONFIG_ANDROID_STAGING) += android/' >> \
        "$KERNEL_DIR/drivers/staging/Makefile"
fi

echo "== Restoring Android quota2 netfilter match from ACK $ACK_REV =="
fetch_ack_file net/netfilter/xt_quota2.c
# ACK keeps this kernel/userspace ABI header outside include/uapi.
fetch_ack_file include/linux/netfilter/xt_quota2.h

if ! grep -q '^config NETFILTER_XT_MATCH_QUOTA2$' "$KERNEL_DIR/net/netfilter/Kconfig"; then
    sed -i '/^config NETFILTER_XT_MATCH_RATEEST/i\
config NETFILTER_XT_MATCH_QUOTA2\
\ttristate '"'"'"quota2" match support'"'"'\
\tdepends on NETFILTER_ADVANCED\
\thelp\
\t  This option adds Android-compatible named quota counters.\
\
' "$KERNEL_DIR/net/netfilter/Kconfig"
fi
if ! grep -qF 'obj-$(CONFIG_NETFILTER_XT_MATCH_QUOTA2)' "$KERNEL_DIR/net/netfilter/Makefile"; then
    sed -i '/CONFIG_NETFILTER_XT_MATCH_QUOTA).*xt_quota.o/a obj-$(CONFIG_NETFILTER_XT_MATCH_QUOTA2) += xt_quota2.o' \
        "$KERNEL_DIR/net/netfilter/Makefile"
fi

echo "== Android compatibility source preparation complete =="
git -C "$KERNEL_DIR" status --short
