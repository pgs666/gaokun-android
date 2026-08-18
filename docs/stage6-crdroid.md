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

**但有个好消息，而且已经实测确认（不是推断）**：crDroid 同步下来的
`external/mesa3d` 与我们打过补丁的那棵是**同一个 commit**：

```
                    crDroid 16.0                 我们归档的（Stage 5）
git describe        android-16.0.0_r4            android-16.0.0_r4
HEAD                d4b6f1eba289310b16ee77…      d4b6f1eba28…（同）
VERSION             25.3.0-devel                 26.0.3   ← 差异见下
tu_image.cc:918     /* TODO handle VkNativeBufferANDROID */   ← 那句还在
```

⚠️ **`VERSION` 的差异不是版本不同**：同一 git HEAD，说明我们那棵的 VERSION
文件是本地未提交的改动（管线自己改的）。**上游快照的真实版本是 mesa
`25.3.0-devel`**；CLAUDE.md / stage5 文档里出现过的"mesa 26"是被这个改过的
文件误导的说法，以本节为准。

结论：Stage 5 的生成/合并管线可以逐字套用，最差情况直接把
`~/keep/mesa3d-patched.tar.zst` 整棵铺回去。M3 的风险比预期低得多。

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

### 换轨前的硬件基线（2026-08-19 实机采集，M4 回归时逐项对照）

```
ro.build.fingerprint  Huawei/aosp_gaokun3/gaokun3:16/BP4A.251205.006/eng.vahiru:userdebug
                      ↑ 平台自己的 build ID 也是 BP4A，与 crDroid 的 release config 对上
uname -r              7.2.0-rc2-gaokun3+            （kb21，crDroid 继续用它）
ro.hardware.vulkan    freedreno                     /vendor/lib64/hw/vulkan.freedreno.so 14,617,032
/proc/asound/cards    0 [SC8280XPHUAWEIG]: sc8280xp - SC8280XP-HUAWEI-GAOKUN3
                        HUAWEI-GK_W7X-M1010-GK_W7X_PCB
bluetooth_manager     state: ON，地址从芯片读出
wlan0                 192.168.31.227/24             （自动连网）
桌面进程              surfaceflinger 711 / system_server 874 / systemui 1153 / launcher3 1424
dumpsys media.player  "Decoder infos by media types:" 之后【空无一物】  ← 换轨要修的就是这个
```

## ★ #36 的机制查清了：不是 XML 缺失，是 servicemanager 的 declared 集里没有 c2

2026-08-19 在**换轨前的这台设备上**（AOSP 16 那套）把整条链路逐环量了一遍。
结论推翻了 #36 里"`media_codecs.xml` 缺失"的说法 —— 那份文件在，缺的是别的东西。

### 链路上每一环的实测状态

| 环节 | 实测 | 结论 |
|---|---|---|
| swcodec APEX | `isActive="true"`，`apexd.status=ready`，41 个模块在 `apex-info-list.xml` 里 | ✅ |
| 软解码库 | `/apex/com.android.media.swcodec/lib64/libcodec2_soft_*.so` **36 个** | ✅ |
| 编解码器 XML | `/apex/…/etc/media_codecs.xml` 24377 字节；`/vendor/etc/media_codecs.xml` 同样大小 | ✅ |
| 变体属性 | `ro.media.xml_variant.codecs{,_performance}` 均为空 → 用默认文件名 | ✅ |
| C2 服务注册 | `service check android.hardware.media.c2.IComponentStore/software` → **found** | ✅ |
| VINTF 片段 | `/system/etc/vintf/manifest/manifest_media_c2_software.xml` 装着 | ✅ |
| libvintf 运行时视图 | `vintf fm` **确实列出** `android.hardware.media.c2` / `IComponentStore/software`（带 `updatable-via-apex`） | ✅ |
| AIDL/HIDL 选择 | `ro.vendor.api_level=202504` ≥ 202404 → 走 AIDL（`hal/common/HalSelection.cpp:31`） | ✅ |
| **客户端枚举** | `Codec2Client: No Codec2 services declared in the manifest.` | ❌ |
| MediaCodecList | `dumpsys media.player` 的 `countCodecs()` = 0 | ❌ |

### 精确定位

`frameworks/av/media/codec2/hal/client/client.cpp:2636` 起：

```cpp
if (c2_aidl::utils::IsSelected()) {                    // ← 实测为 true
    AServiceManager_forEachDeclaredInstance(AidlBase::descriptor, &names, …);
}
…
if (names.empty()) LOG(INFO) << "No Codec2 services declared in the manifest.";
```

★ **关键区别：registered ≠ declared。**
`service list` 看到的是服务自己 `addService` 注册的；
`forEachDeclaredInstance` 查的是 servicemanager 从 **VINTF** 建的"声明"集
（`frameworks/native/cmds/servicemanager/ServiceManager.cpp:759 getDeclaredInstances`
→ `getVintfInstances()`）。两者可以一个有一个没有 —— 本机正是如此。

排除的分支（都读过源码）：
- `ServiceManager.cpp:765` 那个静默清空分支不成立 ——
  `isRomService()` 只匹配 `lineage*` / `vendor.lineage.*` / `profile`（crDroid 自加），
  且 `isUntrustedCaller()` 要求 uid ≥ AID_APP_START 且 sid 含 `untrusted_app`，
  而 mediaserver 是 `u:r:mediaserver:s0`。
- SELinux 拒绝也不成立：真被拒会返回 `EX_SECURITY`，而且本机是 Permissive。

### 剩下的主嫌疑（下一步怎么证）

**servicemanager 的 `VintfObject` 快照是开机早期建的，而那条声明带
`updatable-via-apex="com.android.media.swcodec"`。** `vintf fm` 是刚起的新进程、
APEX 已 active，所以看得见；servicemanager 活了一整个开机周期，很可能缓存了
apexd 就绪【之前】的视图。这能同时解释"libvintf 看得见、servicemanager 看不见"。

下一次开机时一条命令就能证/证伪：
```
logcat -b all | grep -i "VINTF manifest"
```
（`isVintfDeclared()` 会打 `Found … in framework VINTF manifest` 或
 `Could not find … in the VINTF manifest`。）

### 对换轨的意义

⚠️ **不能承诺"crDroid 自动修好"** —— 链条上每个文件都在、都正确，
这不是那种"少装一个 xml"的产品配置缺口。但 crDroid 是被几十万台设备验证过的
完整 ROM，启动顺序/apexd/servicemanager 的时序都是标准的，
**crDroid 起来后第一件事就是量 `dumpsys media.player`**，一条命令即可判定。

（铃声那半边仍然大概率自动好：`vendor/lineage/audio/audio.mk` 明确装 44 个音频。）

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

## M1 执行记录：首次构建踩到的坑

### 坑 1 — `android.hardware.thermal-service.example` 不存在

```
build/make/core/main.mk:1074: warning: device/huawei/gaokun3/lineage_gaokun3.mk
    includes non-existent modules in PRODUCT_PACKAGES
Offending entries:
    android.hardware.thermal-service.example
    vulkan.freedreno
```

模块**定义是在的**（`hardware/interfaces/thermal/aidl/default/Android.bp`），
但那个 `cc_binary` 带 `installable: false`，binary 只出现在
`apex "com.android.hardware.thermal"` 里 —— 和音频 HAL 完全同一套路。
改为直接列 APEX 名即可。

> 教训：AOSP 16 里越来越多 default HAL 被搬进 APEX，`-service.example`
> 这种 binary 名会变成"存在但不可安装"。列包名前先看 bp 里有没有
> `installable: false`。

`vulkan.freedreno` 缺失是意料之中（mesa 管线要到 M3 才跑），M1 按计划
先用 swangle：`ro.hardware.vulkan=pastel`，两处一起在 M3 打开。

⚠️ kati 是**一次性列全**所有缺失模块的，所以第一轮报了哪几个，其余包名就都是好的。

### 坑 2（审出来的，尚未被触发）— `deploy-android.sh` 直接 dd sparse 镜像

`super.img` 默认是 Android sparse 格式（实测魔数 `3a ff 26 ed` = 0xED26FF3A），
而 `scripts/deploy-android.sh` 一直是直接 `dd`。这会让 init 读不到 LP 元数据、
挂载失败后主动复位，**且不留任何日志**（`docs/stage2-findings.md` 第 1 节的老坑）。

一直没炸是因为实际在用的是 `scripts/deploy-from-ubuntu.sh`（它用 `simg2img`）。
现已改为按魔数判断，两种格式都能正确写入。

### 坑 3（同上，审出来的）— 远端路径里的 `~` 被本地展开

`deploy-from-ubuntu.sh` 跑在 **Ego**（`/home/user`），但 `OUT` / `KEEP` 指的是
**构建机**上的路径（`/home/vahiru`）。写成 `OUT=~/aosp/...` 会在 Ego 本地展开成
`/home/user/aosp/...`，再去 `scp vahiru@vm:/home/user/aosp/...` —— 必然找不到。
波浪号必须保持字面量，交给远端 shell 展开。

### M2 的回退演练已经脚本化

```bash
# 在 Ego 的 Ubuntu 里
bash deploy-from-ubuntu.sh rollback    # 刷回换轨前那套 AOSP 16
```
从构建机 `~/keep/aosp16-images/` 拉 super + ramdisk（sha256 校验过），
内核/DTB 不用换 —— crDroid 和 AOSP 用的是同一个 kb21 内核。
