/*
 * boot_control HAL for gaokun3.
 *
 * Structurally identical to hardware/interfaces/boot/aidl/default/BootControl.h
 * — every call still goes to libboot_control. The only difference is that the
 * two calls which change what the machine will boot next also mirror the slot
 * into systemd-boot's loader.conf. See Android.bp for the reasoning.
 *
 * Copyright (C) 2022 The Android Open Source Project
 * Copyright 2026 The gaokun-android contributors
 * SPDX-License-Identifier: Apache-2.0
 */

#pragma once

#include <aidl/android/hardware/boot/BnBootControl.h>
#include <libboot_control/libboot_control.h>

namespace aidl::android::hardware::boot {

class BootControl final : public BnBootControl {
  public:
    BootControl();
    ::ndk::ScopedAStatus getActiveBootSlot(int32_t* _aidl_return) override;
    ::ndk::ScopedAStatus getCurrentSlot(int32_t* _aidl_return) override;
    ::ndk::ScopedAStatus getNumberSlots(int32_t* _aidl_return) override;
    ::ndk::ScopedAStatus getSnapshotMergeStatus(MergeStatus* _aidl_return) override;
    ::ndk::ScopedAStatus getSuffix(int32_t in_slot, std::string* _aidl_return) override;
    ::ndk::ScopedAStatus isSlotBootable(int32_t in_slot, bool* _aidl_return) override;
    ::ndk::ScopedAStatus isSlotMarkedSuccessful(int32_t in_slot, bool* _aidl_return) override;
    ::ndk::ScopedAStatus markBootSuccessful() override;
    ::ndk::ScopedAStatus setActiveBootSlot(int32_t in_slot) override;
    ::ndk::ScopedAStatus setSlotAsUnbootable(int32_t in_slot) override;
    ::ndk::ScopedAStatus setSnapshotMergeStatus(MergeStatus in_status) override;

  private:
    ::android::bootable::BootControl impl_;
};

}  // namespace aidl::android::hardware::boot
