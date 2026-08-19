# Android on the Huawei MateBook E Go (SC8280XP / `gaokun3`)

**crDroid 16.0 (Android 16) on a mainline Linux kernel, with hardware Vulkan on
the Adreno 690.**

Qualcomm never shipped an Android BSP for the 8cx family — only Windows and
Linux drivers. There is no stock ROM to lift vendor blobs from, no `fastboot`,
no A/B slots, no recovery partition and no serial console. So this is not a
normal device port: it is *AOSP on mainline*, with every HAL built on top of
upstream drivers.

> ### ⚠️ Alpha. Read this first.
> Games run well. **The machine cannot suspend** — see
> [Known issues](#known-issues). Installing erases the internal disk. You need
> to be comfortable recovering a machine that will not boot. No warranty of any
> kind.

[**中文说明 → README.zh-CN.md**](README.zh-CN.md)

---

## Status

Everything below was measured on hardware, not inferred. The evidence is in
[`docs/`](docs/).

| Area | State | Notes |
|---|:--:|---|
| Boot (UEFI + systemd-boot, internal disk) | ✅ | No USB media required |
| Display 1600×2560 | ✅ | Panel also has a 120 Hz mode; render is pinned to 60 |
| GPU — Adreno 690, hardware Vulkan | ✅ | Mesa 26.0.3 `turnip`; zero SMMU faults over a 22-minute soak |
| Touchscreen | ✅ | Himax HX83121A; needs the gpio174 patch in `patches/` |
| Detachable keyboard + touchpad | ✅ | USB HID `12d1:10b8` |
| Wi-Fi | ✅ | ath11k / WCN6855 |
| Bluetooth | ✅ | `hci_qca`; adapter `ON`, zero crashes |
| Speakers | ✅ | User-confirmed; WSA883x via audioreach |
| Headphone jack / microphone | ❓ | Jack detection and 15 HPH mixer controls exist; untested |
| Battery, charging, lid switch | ✅ | Huawei EC driver |
| **Gaming** | ✅ | Genshin Impact at max graphics, smooth. GPU idles at 270 MHz, peaks 690 MHz, 50 °C |
| CPU thermal throttling | ⚠️ | Mainline DTS has **no** CPU cooling maps — replaced by a userspace guard, see below |
| **Suspend / standby** | ❌ | s2idle **resumes into a reset**. Kernel/EC bug — reproduces identically under Ubuntu |
| Sensors (accelerometer, ALS) | ❌ | Live on the SLPI DSP, unreachable from mainline. No auto-rotate, no auto-brightness |
| Hardware video decode | ❌ | Venus not enabled; 66 software codecs only |
| Camera | ❌ | Not started |
| USB-C DisplayPort / UCSI | ❌ | UCSI PPM init times out — a known mainline defect on this machine |
| Fingerprint, TPM | ❌ | No driver exists |
| SELinux | ⚠️ | `permissive` |

### Two things that will surprise you

**The mainline device tree has no CPU thermal throttling.** `sc8280xp.dtsi`
contains exactly one `cooling-maps` block, and it is under `gpu-thermal`. Every
CPU zone has a single 110 °C *critical* trip and nothing else — so the CPUs run
flat out until the kernel performs an emergency shutdown, with no gradual
throttling in between. On a fanless tablet that is reachable. This port ships
[`thermal-guard.sh`](device/huawei/gaokun3/bin/thermal-guard.sh), a userspace
step-wise governor driving the `cpufreq-cpu0` / `cpufreq-cpu4` cooling devices.
Fixing it properly means adding passive trips and cooling maps to the DTS.

**Standby is broken below Android.** The machine suspends, fails to resume, and
resets itself about 13 seconds later. The RTC alarm fires correctly, so the
fault is in *resume*, not suspend. Ruled out by experiment: the Himax touch
driver, all three remoteprocs, and the EC driver itself. Both upstream EC
patches that claim to fix this are already applied. **It reproduces identically
in Ubuntu on the same kernel**, so it is neither an Android nor a device-tree
problem. A wakelock is therefore held by default; the screen still turns off
normally. Escape hatch for future re-testing:
`setprop persist.gaokun3.allow_suspend 1`.

---

## Hardware

| | |
|---|---|
| SoC | Qualcomm Snapdragon 8cx Gen 3 (SC8280XP) |
| Model | HUAWEI GK-W7X, 2022, CSOT panel |
| **BIOS** | **2.16 — do not upgrade to 2.17.** The touch SPI bus and GPIO numbering differ between the two, and the upstream driver targets 2.16 |
| GPU | Adreno 690 |
| Panel | Himax HX83121A, MIPI-DSI, 1600×2560 — the same panel as the Galaxy Tab S7 FE |
| Wi-Fi / BT | WCN6855 |
| Storage | NVMe |
| Firmware | UEFI. Secure Boot must be disabled |

---

## Installing

Take the latest [**Release**](../../releases) and follow
[`docs/INSTALL.md`](docs/INSTALL.md).

Installation **erases the internal disk**. The layout it creates:

| Partition | Size | Purpose |
|---|---|---|
| ESP | 300 MiB | systemd-boot, kernels, ramdisks |
| `userdata` | rest of the disk | `/data` |
| `super` | 12 GiB | system / system_ext / product / vendor |
| `metadata` | 32 MiB | |
| rescue | ~25 GiB | A full Ubuntu, reachable over SSH |

That last partition is deliberate. This machine has no recovery partition and
no serial console, so an ordinary Linux install *is* the recovery environment.
It is the default boot entry, which means a hung Android is one power-button
press away from a system you can SSH into and repair remotely — without being
anywhere near the machine.

---

## Building

A Linux host with roughly 16 GB of RAM and 400 GB of disk.

```sh
repo init -u https://github.com/crdroidandroid/android.git -b 16.0
# add manifests/local_manifest_gaokun3.xml to .repo/local_manifests/
repo sync -c -j"$(nproc)"

python3 scripts/crdroid-tree-fixes.py <tree>     # read the script for why
source build/envsetup.sh
lunch lineage_gaokun3-bp4a-userdebug
m
m superimage
```

Proprietary Huawei firmware is **not** in this repository. See
[`device/huawei/gaokun3/firmware/README.md`](device/huawei/gaokun3/firmware/README.md)
for how to obtain it from your own machine.

The kernel is built separately, from
[`linux-gaokun-buildbot`](https://github.com/KawaiiHachimi/linux-gaokun-buildbot).
The Android-specific configuration assertions are in
[`scripts/kernel-config-android.sh`](scripts/kernel-config-android.sh) and the
extra patches in [`patches/`](patches/).

---

## Repository layout

| Path | Contents |
|---|---|
| `device/huawei/gaokun3/` | The device tree |
| `patches/` | Kernel and Mesa patches that are not upstream |
| `scripts/` | Build, deploy, forensics and installer tooling |
| `docs/` | **The engineering record.** Every finding, with evidence |
| `manifests/` | `repo` local manifest |

`docs/` is not an afterthought. Nothing about this platform exists in any wiki
or in any model's training data, so the findings files are a primary artifact:
they record what was measured, what turned out to be wrong, and which earlier
conclusions were later overturned. Several of them were.

---

## Known issues

| Issue | Where |
|---|---|
| s2idle resume fails; the machine resets | [`docs/stage6-crdroid.md`](docs/stage6-crdroid.md) §M4 |
| Sensors are behind the SLPI DSP (#37) | [`docs/stage4-findings.md`](docs/stage4-findings.md) |
| USB re-enumeration drops adb after unplug — use adb over TCP (#27) | [`docs/stage4-findings.md`](docs/stage4-findings.md) |
| No CPU cooling maps in the mainline DTS | [`docs/stage6-crdroid.md`](docs/stage6-crdroid.md) §10 |
| GPU SMMU raises SPI 675/680 while the DT declares 678/679 | [`docs/stage5-freedreno.md`](docs/stage5-freedreno.md) D6 |
| The thermal HAL is the AOSP mock, and its SHUTDOWN threshold is 36 °C | [`docs/stage6-crdroid.md`](docs/stage6-crdroid.md) §M4 |

---

## Help wanted

Concrete, well-scoped work, roughly easiest first:

1. **Hardware video decode.** Eight Venus patches exist in
   `refs/linux-gaokun/patch sets/media/` and are *not* applied by the buildbot.
   All 66 current codecs are software.
2. **GPU SMMU interrupt fix.** The SMMU asserts SPI 675/680; the device tree
   declares 678/679, so context faults never reach the CPU. A DTB change should
   remove the need for the `smmu-nostall.sh` polling workaround entirely.
3. **A real thermal HAL** reading `/sys/class/thermal`. ⚠️ Raise the SHUTDOWN
   thresholds at the same time — the AOSP mock reports 36 °C, and
   `ThermalManagerService` will power the machine off when it sees that.
4. **CPU cooling maps in the DTS**, retiring `thermal-guard.sh`.
5. **SELinux enforcing.** Two services need policy written.
6. **s2idle resume.** Needs a kernel with `CONFIG_PM_DEBUG` to bisect —
   `/sys/power/pm_test` does not exist in the shipped config. Probably upstream
   kernel/EC work.
7. **Sensors.** Would require a mainline client for Qualcomm's SEE running on
   the SLPI, over QMI/FastRPC. Nobody has done this for any SC8280XP device,
   the ThinkPad X13s included.
8. **Camera.** Untouched.

If you have a MateBook E Go and want to test, open an issue — reports of what
breaks are as useful as patches. Please include your BIOS version and SKU.

---

## Credits

* The **gaokun Linux community** —
  [linux-gaokun](https://github.com/right-0903/linux-gaokun),
  [linux-gaokun-buildbot](https://github.com/KawaiiHachimi/linux-gaokun-buildbot),
  [EGoTouchRev](https://github.com/chiyuki0325/EGoTouchRev-Linux) — for the
  kernel, the EC driver and the touch reverse-engineering this port stands on.
* **[aospm](https://github.com/aospm)**, for showing that AOSP on a mainline
  kernel is a workable shape at all.
* **Johan Hovold** and everyone who brought SC8280XP support upstream.
* **crDroid** and **LineageOS**.
* **Mesa** — `freedreno` and `turnip`.

## License

Apache License 2.0 — see [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).
Kernel patches under `patches/` are GPL-2.0-only as derivative works of Linux;
Mesa patches are MIT, matching upstream.
