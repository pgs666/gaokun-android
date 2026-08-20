/*
 * Copyright (C) 2022 The Android Open Source Project
 * Copyright 2026 The gaokun-android contributors
 * SPDX-License-Identifier: Apache-2.0
 *
 * Based on hardware/interfaces/boot/aidl/default/main.cpp. The AIDL *instance*
 * name must stay "default" even though the service binary is named .gaokun3 —
 * that is the name the framework looks up.
 */

#include "BootControl.h"

#include <unistd.h>

#include <android-base/logging.h>
#include <android/binder_manager.h>
#include <android/binder_process.h>

using aidl::android::hardware::boot::BootControl;
using aidl::android::hardware::boot::IBootControl;

namespace {

// ★ Make libboot_control count exactly two slots.
//
// InitDefaultBootloaderControl() works out the slot count by stat()ing
// <dirname(misc)>/boot_a, boot_b, boot_c, boot_d — "a partition required by
// Android Bootloader Requirements". This machine has no boot partition at
// all: the kernel, DTB and ramdisk are plain files on the ESP, loaded by
// systemd-boot. So the probe finds nothing, and the code deliberately falls
// back to kMaxNumSlots, which is 4.
//
// That is not cosmetic. update_engine picks its target as
// (current + 1) % num_slots, so the first OTA would correctly go _a -> _b,
// and the second would go _b -> _c — a slot that does not exist anywhere in
// super. The failure would land one update later than the change that caused
// it, which is the worst kind.
//
// Pointing the two probe paths at /dev/null is the honest representation:
// there is no boot partition for either slot. stat() follows symlinks and
// succeeds, so the probe counts 2 and stops. Nothing ever reads or writes
// these — `boot` is deliberately absent from AB_OTA_PARTITIONS — and if
// something ever did, writing to /dev/null is harmless, which is why they
// point there rather than at a real partition.
//
// Done here, before BootControl is constructed, so it cannot race the
// init.rc trigger ordering that decides when class early_hal starts.
void EnsureSlotProbeHints() {
    for (const char* path : {"/dev/block/by-name/boot_a", "/dev/block/by-name/boot_b"}) {
        if (symlink("/dev/null", path) != 0 && errno != EEXIST) {
            PLOG(WARNING) << "could not create slot-count probe hint " << path
                          << " — libboot_control may report 4 slots instead of 2";
        }
    }
}

}  // namespace

int main(int, char* argv[]) {
    android::base::InitLogging(argv, android::base::KernelLogger);

    EnsureSlotProbeHints();

    ABinderProcess_setThreadPoolMaxThreadCount(0);
    std::shared_ptr<IBootControl> service = ndk::SharedRefBase::make<BootControl>();

    int32_t slots = 0;
    if (service->getNumberSlots(&slots).isOk() && slots != 2) {
        LOG(ERROR) << "boot control reports " << slots << " slots, expected 2. "
                   << "The bootloader_control block in misc was written before the probe hints "
                   << "existed; zero the first 4 KiB of /dev/block/by-name/misc and reboot to "
                   << "let it re-initialise.";
    }

    const std::string instance = std::string(BootControl::descriptor) + "/default";
    auto status = AServiceManager_addService(service->asBinder().get(), instance.c_str());
    CHECK_EQ(status, STATUS_OK) << "Failed to add service " << instance << " " << status;
    LOG(INFO) << "IBootControl AIDL service running with " << slots << " slots";

    ABinderProcess_joinThreadPool();
    return EXIT_FAILURE;  // should not reach
}
