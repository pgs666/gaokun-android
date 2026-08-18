# Stage 6：转 crDroid 16.0（gaokun3）

日期起点：2026-08-19

## 为什么换轨

硬件已全线打通（GPU/turnip、音频、蓝牙、WiFi、触摸），卡住的只剩 App/媒体没声音，
而根因不在硬件也不在内核 —— 是手搓最小 AOSP **缺产品级配置**：

- `MediaCodecList` 是空的（`dumpsys media.player` 的 codec 列表一条不出，
  App 播放栈底是 `NuPlayerDecoder: Failed to create audio/mpeg decoder`），
  `/vendor/etc/media_codecs.xml` 原本不存在、拷进去仍空、`ro.media.xml_variant.*` 全未设
- `/system/media/audio/` 整个缺失 —— 铃声、通知音、UI 音效一个没有

详见 `docs/stage4-findings.md` #36。这些是真 ROM 设备树的标准组成部分。

## 已核实的上游事实（2026-08-19 逐条从 raw 文件/实际 checkout 读出）

| 事实 | 来源 |
|---|---|
| crDroid `16.0` 分支：default revision `refs/heads/lineage-23.2` | `crdroidandroid/android@16.0/default.xml` |
| AOSP remote revision = **`refs/tags/android-16.0.0_r4`** | 同上（`repo manifest -o -` 实测） |
| `vendor/lineage` 路径由 **`crdroidandroid/android_vendor_crdroid`** 提供 | `snippets/crdroid.xml` |
| lunch 格式 `lineage_<device>-<release>-<variant>`，release 取自 `vars/aosp_target_release` | `vendor/crdroid/build/envsetup.sh` |
| **release config = `bp4a`** → `lunch lineage_gaokun3-bp4a-userdebug`（`brunch gaokun3` 等价） | `vendor/crdroid/vars/aosp_target_release` |
| `config/common_full_tablet_wifionly.mk` 存在 = `common_mobile_full` + `tablet` + `wifionly`，正合本机（平板 + 无 modem） | `vendor/crdroid/config/` |
| `BOARD_USES_FULL_RECOVERY_IMAGE ?= true`（`?=`，可提前覆盖） | `vendor/crdroid/config/BoardConfigLineage.mk` |
| manifest 共 **1180** 个项目；本机只缺 `device/linaro/dragonboard` 一个 | `repo manifest -o -` 实测 |
| `device/generic/goldfish` 用的是 **LineageOS 的 fork**（`LineageOS/android_device_generic_goldfish`） | 同上 |

### ★ 铃声缺口 crDroid 自带解决，解码器缺口不解决

- `vendor/lineage/audio/audio.mk` 把 **4 个通知音 + 20 闹铃 + 20 铃声**（Plasma Mobile
  音源）装到 `product/media/audio/{notifications,alarms,ringtones}` → 铃声/通知音预期自动就有。
- 但 `vendor/lineage/config/common.mk` 里**没有任何** `media_codecs` /
  `ro.media.xml_variant` 引用 → **`media_codecs.xml` 仍然要我们自己装**。
  这一项从"换轨后自动消失"降级为"换轨后的一个明确任务"（M5）。

### ★ mesa 管线一个都不能丢，但比预期便宜得多

`lineage-23.2` 的 `external/mesa3d` 就是 AOSP 的 `platform/external/mesa3d`，
manifest 里**没有** `device/mainline/generic` / `kernel/mainline` / `prebuilts/bootmgr`
—— 平行项目的 `BOARD_MESA3D_*` 是**它自带的 mesa 仓库**带来的机制，不是 Lineage 的。

> ⚠️ 这条推翻我自己写在 `docs/stage5-freedreno.md:212` 的猜测
> （"LineageOS 系可能直接有 `BOARD_MESA3D_*` 支持"）。
> `scripts/mesa-*.py` + `patches/0003..0006` + `mesa/turnip-shared.bp.in` 全部仍然必需。

**但有个好消息**（归档时顺手读出来的）：我们 AOSP 树里那份打过补丁的 `external/mesa3d`

```
VERSION       = 26.0.3
git describe  = android-16.0.0_r4
```

与 crDroid 的 AOSP remote revision **是同一个 tag**。所以 mesa 快照逐字相同，
Stage 5 的生成/合并管线可以原样套用，最差情况直接把归档的整棵树铺回去。

## M0 执行记录

### 归档（在删除之前，顺序不可逆）

构建机 `~/keep/`（1.7G，`sha256sum -c` 五项全 OK）：

| 文件 | 大小 | 用途 |
|---|---|---|
| `aosp16-images/super.img` | 1.686 GB (sparse) | 设备回退：dd 回去就是今天这套能用的系统 |
| `aosp16-images/ramdisk.img` | 12.0 MB | 同上 |
| `aosp16-images/super_empty.img` | 4.6 KB | LP metadata |
| `aosp16-images/vulkan.freedreno.so` | 14.6 MB | 已修好 ANB 延迟绑定的硬件 turnip |
| `mesa3d-patched.tar.zst` | 82 MB | 打过补丁 + 生成好 `Android.bp` 的 mesa 26.0.3 全树（含 .git） |

### 腾地

```
rm -rf ~/aosp        # 7m30s，296G
/dev/sda1  504G  33G used  451G avail       （之前只有 157G，装不下 crDroid 的 ~320G）
```

⚠️ **原先"只删 out 腾到 264G"的算术是不够的**：crDroid 源码+.repo 约 190G，
out 还要 100–130G。264G 会在编译中途爆盘。

### 工具与同步

```bash
sudo apt-get install -y git-lfs          # 3.3.0；repo launcher 原先在 ~/aosp 里，一起没了
curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo -o ~/bin/repo   # 2.65

cd ~/crdroid
repo init -u https://github.com/crdroidandroid/android.git -b 16.0 \
     --git-lfs --no-clone-bundle
cp <repo>/manifests/local_manifest_gaokun3.xml .repo/local_manifests/
repo sync -c --no-clone-bundle --force-sync -j16
```

- `-c` 其实是冗余的（manifest 的 `<default sync-c="true">` 已经开了），留着无害。
- **刻意不加 `--no-tags`**：AOSP 项目的 revision 本身就是个 tag
  （`refs/tags/android-16.0.0_r4`），省这点空间不值得赌一个隐晦的失败模式。
  451G 可用，不需要抠。

## 待核实（进了同步好的树再 grep，不许凭记忆下结论）

- `PRODUCT_VERSION_MAJOR/MINOR`、`LINEAGE_BUILD` 由谁赋值（`config/version.mk` 还是 envsetup）
- 无 recovery / 无 boot.img 下 `m` 与 `m superimage` 是否成立
  （Lineage 只有 `mka bacon` 强依赖 recovery）
- `vendor/lineage/config/common.mk` 是否已带 `core_64_bit` 等价物
  → 若带了，`lineage_gaokun3.mk` 里那句 `core_64_bit.mk` 可以删
- `device/generic/goldfish` 的 Lineage fork 里 `libwifi-hal-emu` 是否还在
  （Stage 4 的 WiFi HAL 靠它）
- crDroid 用自己的 `external/wpa_supplicant_8` fork，与我们的
  `BOARD_WLAN_DEVICE := emulator` + `NL80211` 组合要重验
- 树内可抄的 `media_codecs.xml` 基线在哪（cuttlefish/goldfish 那份 +
  `frameworks/av/media/libstagefright/data/media_codecs_google_*.xml`）

## 设备树改动（M1）

**在 `device/huawei/gaokun3/` 原地改**，不新建目录 —— `.gitignore` 里
`device/huawei/gaokun3/firmware/**/*.mbn` 这类规则只对这个路径生效，
改名会让华为专有 blob 失去保护。AOSP 版留在 git 历史里，镜像已归档。

| 文件 | 动作 |
|---|---|
| `AndroidProducts.mk` | 指向 `lineage_gaokun3.mk`；`COMMON_LUNCH_CHOICES := lineage_gaokun3-bp4a-{userdebug,eng}` |
| `lineage_gaokun3.mk` | 新建，继承 `common_full_tablet_wifionly.mk` + `core_64_bit.mk` + 平板 dalvik 堆 + 我们的 `device.mk`；**刻意不叠 AOSP `full_base.mk`**（会与 crDroid 自带应用撞包） |
| `aosp_gaokun3.mk` | 删除（git 历史里有） |
| `BoardConfig.mk` | 追加 crDroid 段：`BOARD_USES_FULL_RECOVERY_IMAGE := false`（必须在 include 之前）、`BOARD_USES_QCOM_HARDWARE := false`（8cx 没有 CAF BSP）、`TARGET_KERNEL_SOURCE :=`（内核树外自编）、`include vendor/lineage/config/BoardConfigLineage.mk` |
| `lineage.dependencies` | 新建 `[]`（让 `breakfast gaokun3` 不去 roomservice 抓东西；dragonboard 走 local manifest） |
| `manifests/local_manifest_gaokun3.xml` | 新建，只补 `device/linaro/dragonboard`（`remote="aosp"`，tag 已用 `git ls-remote` 验证 = 685cd7ce06fd） |

`device.mk` 基本不动 —— 固件双路安装、fstab、init rc、ueventd、audio policy、
WiFi、mesa/turnip 全部照用。
