/*
 * gaokun3-bootimg-extract —— 从 Android boot 镜像里取出 kernel / ramdisk / dtb
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * 为什么需要它：本机【没有能读 Android boot 镜像的 bootloader】。
 * 引导链是 UEFI + systemd-boot，后者只会从 ESP 上按 BLS 条目加载文件。
 *
 * 所以在自研 EFI 加载器就位之前，走一条过渡路线：
 *   update_engine 按规范把 boot_a/boot_b 刷好（boot 已进 AB_OTA_PARTITIONS）
 *   → OTA 的 postinstall 钩子用本程序把内核从【刚刷好的那个槽】解出来
 *   → 放到 ESP 上该槽专属的目录，systemd-boot 照旧启动
 * boot 分区因此是唯一真相源，ESP 上的文件只是派生物。
 *
 * ★ 头结构直接 include 树内的 <bootimg.h>（header_libs: bootimg_headers），
 *   不手抄偏移 —— 偏移抄错的后果是解出一个能通过 magic 校验但内容错位的内核。
 *
 * 用法： gaokun3-bootimg-extract <boot 分区或镜像文件> <输出目录>
 * 产出： <输出目录>/{Image,ramdisk.img,gaokun3.dtb,cmdline.txt}
 *        （固定名，好让 BLS 条目里的路径保持稳定）
 */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <bootimg.h>

namespace {

bool ReadExact(int fd, off_t off, void* buf, size_t len) {
    uint8_t* p = static_cast<uint8_t*>(buf);
    size_t done = 0;
    while (done < len) {
        ssize_t n = pread(fd, p + done, len - done, off + done);
        if (n == 0) {
            fprintf(stderr, "读到文件末尾（偏移 %lld，还差 %zu 字节）\n",
                    static_cast<long long>(off + done), len - done);
            return false;
        }
        if (n < 0) {
            if (errno == EINTR) continue;
            fprintf(stderr, "pread: %s\n", strerror(errno));
            return false;
        }
        done += static_cast<size_t>(n);
    }
    return true;
}

// 从 fd 的 off 处拷 len 字节到 path。先写 .new 再改名。
bool ExtractTo(int fd, off_t off, uint32_t len, const char* dir, const char* name) {
    if (len == 0) {
        fprintf(stderr, "警告: %s 长度为 0，跳过\n", name);
        return true;
    }
    char tmp[1024], dst[1024];
    snprintf(tmp, sizeof(tmp), "%s/.%s.new", dir, name);
    snprintf(dst, sizeof(dst), "%s/%s", dir, name);

    int out = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (out < 0) {
        fprintf(stderr, "打不开 %s: %s\n", tmp, strerror(errno));
        return false;
    }
    const size_t kChunk = 1 << 20;
    uint8_t* buf = static_cast<uint8_t*>(malloc(kChunk));
    if (buf == nullptr) { close(out); return false; }

    bool ok = true;
    uint32_t left = len;
    off_t cur = off;
    while (left > 0) {
        size_t want = left < kChunk ? left : kChunk;
        if (!ReadExact(fd, cur, buf, want)) { ok = false; break; }
        size_t w = 0;
        while (w < want) {
            ssize_t n = write(out, buf + w, want - w);
            if (n < 0) {
                if (errno == EINTR) continue;
                fprintf(stderr, "write %s: %s\n", tmp, strerror(errno));
                ok = false; break;
            }
            w += static_cast<size_t>(n);
        }
        if (!ok) break;
        cur += want;
        left -= want;
    }
    free(buf);
    if (ok && fsync(out) != 0) {
        fprintf(stderr, "fsync %s: %s\n", tmp, strerror(errno));
        ok = false;
    }
    close(out);
    if (!ok) { unlink(tmp); return false; }
    if (rename(tmp, dst) != 0) {
        fprintf(stderr, "rename -> %s: %s\n", dst, strerror(errno));
        unlink(tmp);
        return false;
    }
    printf("  %-12s %10u 字节\n", name, len);
    return true;
}

// 按 page_size 向上取整
uint64_t PageAlign(uint64_t x, uint32_t page) {
    return (x + page - 1) / page * page;
}

}  // namespace

int main(int argc, char** argv) {
    if (argc != 3) {
        fprintf(stderr, "用法: %s <boot 分区或镜像文件> <输出目录>\n", argv[0]);
        return 1;
    }
    const char* src = argv[1];
    const char* dir = argv[2];

    int fd = open(src, O_RDONLY);
    if (fd < 0) {
        fprintf(stderr, "打不开 %s: %s\n", src, strerror(errno));
        return 1;
    }

    boot_img_hdr_v2 hdr;
    if (!ReadExact(fd, 0, &hdr, sizeof(hdr))) { close(fd); return 1; }

    if (memcmp(hdr.magic, BOOT_MAGIC, BOOT_MAGIC_SIZE) != 0) {
        fprintf(stderr, "%s 不是 Android boot 镜像（magic 不符）\n", src);
        close(fd);
        return 2;
    }
    if (hdr.page_size == 0 || hdr.page_size > (1u << 20)) {
        fprintf(stderr, "page_size 不合理: %u\n", hdr.page_size);
        close(fd);
        return 2;
    }
    printf("boot 镜像: header_version=%u page_size=%u\n", hdr.header_version,
           hdr.page_size);
    // ★ 只认 v2：v0/v1 没有 dtb 字段，v3+ 的 dtb 在 vendor_boot 里而不在这。
    //   本机刻意用 v2 —— 一个分区装齐 kernel+ramdisk+dtb，不需要 vendor_boot。
    if (hdr.header_version != 2) {
        fprintf(stderr, "只支持 header_version=2，实际是 %u\n", hdr.header_version);
        close(fd);
        return 2;
    }

    const uint32_t page = hdr.page_size;
    // 磁盘布局：每段都按 page_size 对齐依次排列
    //   header | kernel | ramdisk | second | recovery_dtbo | dtb
    uint64_t off = page;
    const uint64_t kernel_off = off;
    off += PageAlign(hdr.kernel_size, page);
    const uint64_t ramdisk_off = off;
    off += PageAlign(hdr.ramdisk_size, page);
    off += PageAlign(hdr.second_size, page);
    off += PageAlign(hdr.recovery_dtbo_size, page);
    const uint64_t dtb_off = off;

    bool ok = true;
    ok = ExtractTo(fd, kernel_off, hdr.kernel_size, dir, "Image") && ok;
    ok = ExtractTo(fd, ramdisk_off, hdr.ramdisk_size, dir, "ramdisk.img") && ok;
    ok = ExtractTo(fd, dtb_off, hdr.dtb_size, dir, "gaokun3.dtb") && ok;

    // cmdline 一并写出来：将来自研的 EFI 加载器要用它，
    // 而现在也方便核对 BLS 条目里的 options 有没有跟镜像里的走偏。
    char cmd[BOOT_ARGS_SIZE + BOOT_EXTRA_ARGS_SIZE + 2];
    snprintf(cmd, sizeof(cmd), "%.*s%.*s", BOOT_ARGS_SIZE,
             reinterpret_cast<const char*>(hdr.cmdline), BOOT_EXTRA_ARGS_SIZE,
             reinterpret_cast<const char*>(hdr.extra_cmdline));
    char cpath[1024];
    snprintf(cpath, sizeof(cpath), "%s/cmdline.txt", dir);
    FILE* cf = fopen(cpath, "w");
    if (cf != nullptr) {
        fprintf(cf, "%s\n", cmd);
        fclose(cf);
    } else {
        fprintf(stderr, "警告: 写不了 %s: %s\n", cpath, strerror(errno));
    }

    close(fd);
    if (!ok) {
        fprintf(stderr, "解包失败\n");
        return 1;
    }
    printf("解包完成 -> %s\n", dir);
    return 0;
}
