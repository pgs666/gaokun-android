/*
 * Slot mirroring from Android's misc partition into systemd-boot's loader.conf.
 *
 * Copyright 2026 The gaokun-android contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

namespace gaokun3 {

// Point systemd-boot at the given slot (0 = _a, 1 = _b) by rewriting the
// `default` line of loader.conf on the ESP. Returns false if the ESP could
// not be mounted or written; the caller should surface that as a HAL error
// so update_engine does not believe the switch happened.
bool SetEspDefaultSlot(int slot);

}  // namespace gaokun3
