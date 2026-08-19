/*
 * Slot mirroring from Android's misc partition into systemd-boot's loader.conf.
 *
 * Copyright 2026 The gaokun-android contributors
 * SPDX-License-Identifier: Apache-2.0
 */

#include "EspSlot.h"

#include <sys/mount.h>
#include <sys/stat.h>
#include <unistd.h>

#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#include <android-base/file.h>
#include <android-base/logging.h>
#include <android-base/strings.h>

namespace gaokun3 {
namespace {

// The installer gives the ESP the PARTLABEL `esp` precisely so that this
// by-name link exists. The conventional label "EFI system partition" contains
// spaces and is therefore useless for by-name lookup — UEFI identifies the ESP
// by its partition *type* GUID, not by name, so renaming it is harmless.
constexpr char kEspDevice[] = "/dev/block/by-name/esp";
constexpr char kMountPoint[] = "/mnt/gaokun3_esp";
constexpr char kLoaderConf[] = "/mnt/gaokun3_esp/loader/loader.conf";

// The BLS entry filenames are prefixed with the systemd machine-id, which this
// HAL has no business knowing. systemd-boot accepts a glob in `default`, so we
// write a pattern and stay independent of it.
std::string DefaultLineForSlot(int slot) {
    return std::string("default *-android-") + (slot == 0 ? "a" : "b") + ".conf";
}

class MountedEsp {
  public:
    MountedEsp() {
        if (mkdir(kMountPoint, 0700) != 0 && errno != EEXIST) {
            PLOG(ERROR) << "mkdir " << kMountPoint;
            return;
        }
        if (mount(kEspDevice, kMountPoint, "vfat", MS_NOATIME, nullptr) != 0) {
            PLOG(ERROR) << "mount " << kEspDevice << " -> " << kMountPoint;
            return;
        }
        mounted_ = true;
    }
    ~MountedEsp() {
        if (mounted_) {
            sync();
            if (umount(kMountPoint) != 0) PLOG(WARNING) << "umount " << kMountPoint;
        }
    }
    bool ok() const { return mounted_; }

    MountedEsp(const MountedEsp&) = delete;
    MountedEsp& operator=(const MountedEsp&) = delete;

  private:
    bool mounted_ = false;
};

}  // namespace

bool SetEspDefaultSlot(int slot) {
    if (slot != 0 && slot != 1) {
        LOG(ERROR) << "SetEspDefaultSlot: invalid slot " << slot;
        return false;
    }

    MountedEsp esp;
    if (!esp.ok()) return false;

    std::string contents;
    if (!android::base::ReadFileToString(kLoaderConf, &contents)) {
        PLOG(ERROR) << "read " << kLoaderConf;
        return false;
    }

    // Replace the existing `default` directive in place so that timeout,
    // console-mode, editor and any comments the operator left survive.
    const std::string wanted = DefaultLineForSlot(slot);
    std::vector<std::string> out;
    bool replaced = false;
    for (const auto& line : android::base::Split(contents, "\n")) {
        if (android::base::StartsWith(android::base::Trim(line), "default")) {
            if (!replaced) {
                out.push_back(wanted);
                replaced = true;
            }
            continue;  // drop any further default lines; systemd-boot honours the first
        }
        out.push_back(line);
    }
    if (!replaced) out.push_back(wanted);

    const std::string result = android::base::Join(out, "\n");

    // Write through a temporary file in the same directory, then rename.
    // vfat has no atomic-rename-over-existing guarantee the way ext4 does, but
    // this still shrinks the window in which loader.conf is truncated, and a
    // torn loader.conf only costs a trip through the boot menu — systemd-boot
    // falls back to showing the entry list.
    const std::string tmp = std::string(kLoaderConf) + ".new";
    if (!android::base::WriteStringToFile(result, tmp)) {
        PLOG(ERROR) << "write " << tmp;
        return false;
    }
    if (rename(tmp.c_str(), kLoaderConf) != 0) {
        PLOG(ERROR) << "rename " << tmp << " -> " << kLoaderConf;
        unlink(tmp.c_str());
        return false;
    }

    LOG(INFO) << "systemd-boot default now: " << wanted;
    return true;
}

}  // namespace gaokun3
