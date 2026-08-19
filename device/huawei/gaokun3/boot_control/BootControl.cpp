/*
 * boot_control HAL for gaokun3.
 *
 * Copied from hardware/interfaces/boot/aidl/default/BootControl.cpp. Two
 * methods differ; everything else is byte-for-byte the upstream behaviour so
 * that bootctl(1), update_engine and update_verifier see exactly what they
 * expect. The differences are marked ★ below.
 *
 * Copyright (C) 2022 The Android Open Source Project
 * Copyright 2026 The gaokun-android contributors
 * SPDX-License-Identifier: Apache-2.0
 */

#include "BootControl.h"

#include <cstdint>

#include <android-base/logging.h>

#include "EspSlot.h"

using HIDLMergeStatus = ::android::bootable::BootControl::MergeStatus;
using ndk::ScopedAStatus;

namespace aidl::android::hardware::boot {

BootControl::BootControl() {
    CHECK(impl_.Init());
}

ScopedAStatus BootControl::getActiveBootSlot(int32_t* _aidl_return) {
    *_aidl_return = impl_.GetActiveBootSlot();
    return ScopedAStatus::ok();
}

ScopedAStatus BootControl::getCurrentSlot(int32_t* _aidl_return) {
    *_aidl_return = impl_.GetCurrentSlot();
    return ScopedAStatus::ok();
}

ScopedAStatus BootControl::getNumberSlots(int32_t* _aidl_return) {
    *_aidl_return = impl_.GetNumberSlots();
    return ScopedAStatus::ok();
}

namespace {

static constexpr MergeStatus ToAIDLMergeStatus(HIDLMergeStatus status) {
    switch (status) {
        case HIDLMergeStatus::NONE:
            return MergeStatus::NONE;
        case HIDLMergeStatus::UNKNOWN:
            return MergeStatus::UNKNOWN;
        case HIDLMergeStatus::SNAPSHOTTED:
            return MergeStatus::SNAPSHOTTED;
        case HIDLMergeStatus::MERGING:
            return MergeStatus::MERGING;
        case HIDLMergeStatus::CANCELLED:
            return MergeStatus::CANCELLED;
    }
}

static constexpr HIDLMergeStatus ToHIDLMergeStatus(MergeStatus status) {
    switch (status) {
        case MergeStatus::NONE:
            return HIDLMergeStatus::NONE;
        case MergeStatus::UNKNOWN:
            return HIDLMergeStatus::UNKNOWN;
        case MergeStatus::SNAPSHOTTED:
            return HIDLMergeStatus::SNAPSHOTTED;
        case MergeStatus::MERGING:
            return HIDLMergeStatus::MERGING;
        case MergeStatus::CANCELLED:
            return HIDLMergeStatus::CANCELLED;
    }
}

}  // namespace

ScopedAStatus BootControl::getSnapshotMergeStatus(MergeStatus* _aidl_return) {
    *_aidl_return = ToAIDLMergeStatus(impl_.GetSnapshotMergeStatus());
    return ScopedAStatus::ok();
}

ScopedAStatus BootControl::getSuffix(int32_t in_slot, std::string* _aidl_return) {
    if (!impl_.IsValidSlot(in_slot)) {
        // Old HIDL hal returns empty string for invalid slots. We should maintain this behavior in
        // AIDL for compatibility.
        _aidl_return->clear();
    } else {
        *_aidl_return = impl_.GetSuffix(in_slot);
    }
    return ScopedAStatus::ok();
}

ScopedAStatus BootControl::isSlotBootable(int32_t in_slot, bool* _aidl_return) {
    if (!impl_.IsValidSlot(in_slot)) {
        return ScopedAStatus::fromServiceSpecificErrorWithMessage(
                INVALID_SLOT, (std::string("Invalid slot ") + std::to_string(in_slot)).c_str());
    }
    *_aidl_return = impl_.IsSlotBootable(in_slot);
    return ScopedAStatus::ok();
}

ScopedAStatus BootControl::isSlotMarkedSuccessful(int32_t in_slot, bool* _aidl_return) {
    if (!impl_.IsValidSlot(in_slot)) {
        return ScopedAStatus::fromServiceSpecificErrorWithMessage(
                INVALID_SLOT, (std::string("Invalid slot ") + std::to_string(in_slot)).c_str());
    }
    *_aidl_return = impl_.IsSlotMarkedSuccessful(in_slot);
    return ScopedAStatus::ok();
}

ScopedAStatus BootControl::markBootSuccessful() {
    if (!impl_.MarkBootSuccessful()) {
        return ScopedAStatus::fromServiceSpecificErrorWithMessage(COMMAND_FAILED,
                                                                  "Operation failed");
    }
    // ★ gaokun3: re-assert the ESP default for the slot we just proved good.
    //   Normally redundant — setActiveBootSlot already wrote it — but it makes
    //   the ESP self-healing if loader.conf was ever edited by hand or if a
    //   write was lost to a torn vfat update.
    int current = impl_.GetCurrentSlot();
    if (!gaokun3::SetEspDefaultSlot(current)) {
        LOG(WARNING) << "markBootSuccessful: could not refresh ESP default for slot " << current
                     << " (misc is still correct; the machine will boot the old entry)";
    }
    return ScopedAStatus::ok();
}

ScopedAStatus BootControl::setActiveBootSlot(int32_t in_slot) {
    if (!impl_.IsValidSlot(in_slot)) {
        return ScopedAStatus::fromServiceSpecificErrorWithMessage(
                INVALID_SLOT, (std::string("Invalid slot ") + std::to_string(in_slot)).c_str());
    }
    if (!impl_.SetActiveBootSlot(in_slot)) {
        return ScopedAStatus::fromServiceSpecificErrorWithMessage(COMMAND_FAILED,
                                                                  "Operation failed");
    }
    // ★ gaokun3: systemd-boot cannot read misc, so mirror the switch into
    //   loader.conf. This MUST be reported as a failure if it does not stick —
    //   otherwise update_engine would believe slot B is active while the
    //   firmware keeps booting slot A, and the update would silently vanish.
    if (!gaokun3::SetEspDefaultSlot(in_slot)) {
        return ScopedAStatus::fromServiceSpecificErrorWithMessage(
                COMMAND_FAILED, "misc updated but ESP loader.conf could not be written");
    }
    return ScopedAStatus::ok();
}

ScopedAStatus BootControl::setSlotAsUnbootable(int32_t in_slot) {
    if (!impl_.IsValidSlot(in_slot)) {
        return ScopedAStatus::fromServiceSpecificErrorWithMessage(
                INVALID_SLOT, (std::string("Invalid slot ") + std::to_string(in_slot)).c_str());
    }
    if (!impl_.SetSlotAsUnbootable(in_slot)) {
        return ScopedAStatus::fromServiceSpecificErrorWithMessage(COMMAND_FAILED,
                                                                  "Operation failed");
    }
    return ScopedAStatus::ok();
}

ScopedAStatus BootControl::setSnapshotMergeStatus(MergeStatus in_status) {
    if (!impl_.SetSnapshotMergeStatus(ToHIDLMergeStatus(in_status))) {
        return ScopedAStatus::fromServiceSpecificErrorWithMessage(COMMAND_FAILED,
                                                                  "Operation failed");
    }
    return ScopedAStatus::ok();
}

}  // namespace aidl::android::hardware::boot
