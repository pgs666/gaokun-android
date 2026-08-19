# Stage 6：转 crDroid 16.0（gaokun3）

日期起点：2026-08-19

## 为什么换轨

硬件已全线打通（GPU/turnip、音频、蓝牙、WiFi、触摸），卡住的只剩 App/媒体没声音，
而根因不在硬件也不在内核 —— 是手搓最小 AOSP **缺产品级配置**：

- `MediaCodecList` 是空的（`dumpsys media.player` 的 codec 列表一条不出，
  App 播放栈底是 `NuPlayerDecoder: Failed to create audio/mpeg decoder`）
- `/system/media/audio/` 整个缺失 —— 铃声、通知音、UI 音效一个没有

> ⚠️ 换轨决定做出时，第一条的归因是"`media_codecs.xml` 缺失、产品配置缺口"
> （`docs/stage4-findings.md` #36）。**当天晚些时候查清后这个归因被推翻了** ——
> 见下面"#36 的机制查清了"一节。铃声那条仍然成立，且 crDroid 自带解决。
> 换轨这个决定本身不受影响（真 ROM 的产品配置仍然是我们要的），
> 但**不能再指望解码器缺口自动消失**。

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

### ★ mesa 管线一个都不能丢；而"同一个 commit"是我自己制造的假阳性

`lineage-23.2` 的 `external/mesa3d` 就是 AOSP 的 `platform/external/mesa3d`，
manifest 里**没有** `device/mainline/generic` / `kernel/mainline` / `prebuilts/bootmgr`
—— 平行项目的 `BOARD_MESA3D_*` 是**它自带的 mesa 仓库**带来的机制，不是 Lineage 的。

> ⚠️ 这条推翻我自己写在 `docs/stage5-freedreno.md:212` 的猜测
> （"LineageOS 系可能直接有 `BOARD_MESA3D_*` 支持"）。
> `scripts/mesa-*.py` + `patches/0003..0006` + `mesa/turnip-shared.bp.in` 全部仍然必需。

#### 翻案（2026-08-19 M3 当场）

本节原先写着"两棵树是同一个 commit，管线逐字可套"，并据此把 `VERSION` 的
差异解释成"本地未提交的改动"。**这是错的，而且错法很典型，值得留档。**

| | crDroid 16.0 树内 | Stage 5 归档补丁树 |
|---|---|---|
| `git log -1`（`.git` 的 HEAD）| `d4b6f1eba289…` | `d4b6f1eba289…` |
| `VERSION`（工作树实际内容）| **25.3.0-devel** | **26.0.3** |
| 相对 HEAD 的 `git diff` | 干净 | **3791 文件 / +365105 −276293** |

错在**比错了对象**：Stage 5 时我们是把上游 mesa 26 **解包铺在
`external/mesa3d` 的工作树上、从未 `git commit`**，所以 `.git` 里的 HEAD
自始至终是 AOSP 那个 commit。拿 `git log -1` 去比两棵树，**必然得到相同结果，
无论工作树里放的是什么**。真相要逐字节比才看得见 —— diff 里是
`gl_shader_stage` → `mesa_shader_stage` 这类真实的上游重命名和新增文件，
不是空白差异（`git diff --ignore-all-space` 只少了 17 个文件）。

⚠️ 连带作废：本节原先那句"'mesa 26' 是被改过的 VERSION 文件误导，
上游快照是 25.3.0-devel"——上游快照确实是 25.3.0-devel，
但**我们用的从来就是 26.0.3**，两句话说的不是同一棵树。

**方法论教训**：判断"两棵源码树是不是同一份"时，`git log`/`git describe`
只能证明 `.git` 的历史相同，**证明不了工作树相同**。差一句
`git status --porcelain | wc -l` 就能当场戳破。

#### 结论与做法

M3 采取的是**整棵铺回归档树**（不是重跑生成管线）：

```bash
tar --zstd -xf ~/keep/mesa3d-patched.tar.zst -C ~/stage-mesa
cd ~/crdroid/external/mesa3d
find . -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +   # 保 .git
tar cf - -C ~/stage-mesa/mesa3d . | tar xf - -C .
```

理由：归档树就是实测 **SMMU fault 66 → 0** 的那一棵，`patches/0004` v3
（ANB 延迟绑定）已在里面，所有 12 个管线坑都已经踩平；在 25.3 上重跑管线
等于把 Stage 5 整场再打一遍，且要重新移植 ANB 修复。

保留 `.git` 的好处：**一句 `git checkout . && git clean -fd` 就回到
crDroid 原版 25.3**，随时可对照。代价是 `repo sync --force-sync` 会把它冲掉
—— 冲掉了就再铺一次，归档在 `~/keep/`。

## M0 执行记录

### 归档（在删除之前，顺序不可逆）

构建机 `~/keep/`（1.7G，`sha256sum -c` 五项全 OK）：

| 文件 | 大小 | 用途 |
|---|---|---|
| `aosp16-images/super.img` | 1.686 GB (sparse) | 设备回退：dd 回去就是今天这套能用的系统 |
| `aosp16-images/ramdisk.img` | 12.0 MB | 同上 |
| `aosp16-images/super_empty.img` | 4.6 KB | LP metadata |
| `aosp16-images/vulkan.freedreno.so` | 14.6 MB | 已修好 ANB 延迟绑定的硬件 turnip |
| `mesa3d-patched.tar.zst` | 82 MB | 打过补丁 + 生成好 `Android.bp` 的 mesa 全树（含 .git），commit `d4b6f1eba28` |

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

## M1 完成（2026-08-19）：六轮构建，产出 super.img 2.69 GB

| 轮次 | 结果 | 学到什么 |
|---|---|---|
| 1 | kati 2:57 中止 | 两个 non-existent module：thermal 的 binary 是 `installable:false` 的 APEX 打包件；`vulkan.freedreno` 尚不存在（M3 才有） |
| 2 | 97% 处 check_vintf 失败 | 缺 vendor 兼容性矩阵 |
| 3 | 同上 | 加了 `DEVICE_MATRIX_FILE` 没用 —— 它只决定**内容**，装它的模块 `vendor_compatibility_matrix.xml` 来自 `base_vendor.mk` |
| 4 | **BUILD-RC=0，但产物是空壳** | `system.img` 29.8 MB，无 `apex/`、无 `app/`、无 `services.jar` |
| 5 | 成功（1:56:39） | 加回 `full_base.mk` → 目标数 59,227 → **145,445**，`system.img` 1.02 GB |
| 6 | 成功（07:07） | 补三处 overlay-only 漏网后重打 super |

### ★ 最大的一课：AOSP 基座必须由设备树自己提供

我一度以为 crDroid 自带整套应用、叠 `full_base.mk` 会撞包，于是拿掉了它。
结果第 4 轮**构建成功但产出空壳**——这比构建失败危险得多，因为它不报错。

`vendor/lineage/` 下的配置全是**补充**性质的：

```
common.mk         只 inherit vendor/extra、crdroid.mk、vendor/addons、audio.mk
common_mobile.mk  只补 frameworks/base/data/sounds/AudioPackage14.mk
tablet.mk         只补 $(SRC_TARGET_DIR)/product/large_screen_common.mk
```

整个 `vendor/lineage/config/*.mk` 里对 `SRC_TARGET_DIR` 的引用**只有 tablet.mk 一处**。
LineageOS/crDroid 的设备树本来就该自己 inherit 一个 AOSP base 产品。

前两轮的症状（缺 vendor 矩阵、缺 `/vendor/bin/sh`）其实都是这一件事的局部表现：

```
full_base → generic_no_telephony → handheld_{system,system_ext,vendor,product}
         → media_vendor → base_vendor   （vendor_compatibility_matrix.xml、
                                          shell_and_utilities_vendor = sh + toybox_vendor）
full_base 还带 frameworks/base/data/sounds/AllAudio.mk（铃声）
```

### ★ 第二大的一课：三处"只活在设备 overlay 里"的东西

Stage 4/5 有些修复是用 `adb remount` 的 overlay 推进设备的，
结论写进了 docs，**却从没变成一行构建配置**。照原样构建 crDroid 会得到：

| 漏网 | 上机后的症状 |
|---|---|
| `qcom/sc8280xp/SC8280XP-HUAWEI-GAOKUN3-tplg.bin` | 声卡不注册 |
| `bin/audio-route.sh` + `etc/audioroute.rc` | 声卡注册了但没人配路由 → **能播放、没声音** |
| 蓝牙 HAL（`android.hardware.bluetooth-service.default`） | 蓝牙起不来 |

这些如果不是装机前逐项对着产物验收，都会变成上机后的疑难杂症
（本机没有串口，只能靠 logcat 猜）。

> **方法论**：换轨时不要只看 docs 的结论，要 `grep` 构建配置里**有没有那一行**。
> 判据是"产物里有没有这个文件"，不是"文档里写没写这件事"。

### 其他要点

- `DEVICE_MATRIX_FILE` 用我们自己那份**空**矩阵，不用 AOSP 兜底的
  `system/libhidl/vintfdata/device_compatibility_matrix.default.xml` ——
  后者要求 HIDL `android.hidl.manager@1.0::IServiceManager`，
  而 hwservicemanager 在 Android 15+ 已被移除。
  assemble_vintf 会自动给我们的空矩阵补上 `<system-sdk><version>36</version>`。
- `super.img` **不在 `droid` 目标里**，要单独 `m superimage`。
- 加了 `persist.adb.tcp.port=5555`（`adb/daemon/main.cpp:272-274` 实名核实：
  先读 `service.adb.tcp.port`，回落 `persist.adb.tcp.port`），
  换 ROM 后 USB 侧万一不通不至于失联。

### M1 产物验收

```
super.img    2,687,636,036  sparse（魔数 3a ff 26 ed）
ramdisk.img     12,064,835
system.img   1,022,251,008   （旧 AOSP 1,004,400,640，量级对上）
vendor/bin/sh                                       755  334856
vendor/bin/audio-route.sh                           755    2342
vendor/etc/init/audioroute.rc                       644     376
vendor/bin/hw/android.hardware.bluetooth-service.default  755  294744
vendor/lib64/android.hardware.bluetooth-V1-ndk.so   755   85272   ← 随包自动装
vendor/etc/vintf/compatibility_matrix.xml           644     215
vendor/firmware/qcom/sc8280xp/SC8280XP-HUAWEI-GAOKUN3-tplg.bin
product/media/audio/  = 92 通知音 + 130 铃声 + 45 闹铃 + 25 UI 音效
```

★ 最后一行意味着**换轨动机的一半（铃声/UI 音效）已经确凿解决**。
另一半（解码器）等上机后 `dumpsys media.player` 判定。

## M2：首次上机 —— crDroid 起来了，但 system_server 崩溃循环

### 装机流程（已验证可复现）

Ego 根在 U 盘（`/dev/sda2`），内置盘 super = `nvme0n1p8`，`/tmp` 是 7.5G tmpfs
（内存 15G）—— 2.69G 的 super.img 直接下到内存盘，不占根分区那 4.1G。

```bash
# Ego 从构建机直传（Ego 有 VM 的 ssh 钥匙）
scp vahiru@VM:~/crdroid/out/target/product/gaokun3/super.img /tmp/
sha256sum /tmp/super-crdroid.img        # 与构建机逐字比对
sudo simg2img /tmp/super-crdroid.img /dev/nvme0n1p8      # ⚠️ 必须 simg2img，不能 dd
sudo mkfs.ext4 -F -L userdata /dev/disk/by-partlabel/userdata   # 换 ROM 必清
sudo mkfs.ext4 -F -L metadata /dev/disk/by-partlabel/metadata
sudo bootctl set-oneshot <machine-id>-crdroid.conf && sudo systemctl reboot
```

- crDroid 的 ramdisk 单独放成 `ramdisk-crdroid.img`，**不覆盖** AOSP 那份 ——
  回退时老启动项原样可用。内核仍是 `Image-kb21`（两套 ROM 共用）。
- **默认启动项保持 Ubuntu**，只用 oneshot 进 Android → 起不来拍电源键自动回落。
- 写完读回 `/dev/nvme0n1p8` 偏移 4096 处应为 `67 44 6c 61`
  （`LP_METADATA_GEOMETRY_MAGIC = 0x616c4467` 小端，
  `system/core/fs_mgr/liblp/include/liblp/metadata_format.h:32`）。

### ★ 属性系统的两条反直觉机制（花了很久才查清）

**① `gen_build_prop.py` 里没有 userdebug 这一档**

```python
# build/soong/scripts/gen_build_prop.py:28
def get_build_variant(product_config):
  if product_config["Eng"]: return "eng"
  else:                     return "user"
```

只要不是 `eng`，`/system/build.prop` 就按 **user** 分支硬写
`ro.adb.secure=1` + `ro.debuggable=0` + `ro.allow.mock.location=0`，
与 `TARGET_BUILD_VARIANT=userdebug` 无关。
（判据：产物里这三条同时出现 = 走了 user 分支。）

**② init 的属性加载是「后来者覆盖」，但 vendor 无权设 system 属主的属性**

`property_service.cpp` 的 map 插入（807-815）是后覆盖前，加载顺序
`/system` → `system_ext` → `vendor` → `odm` → `product`
（注释原话：越贴近产品的分区优先级越高）。
**但**每条都要过 `CheckPermissions(key, value, context, …)`，
而 `/vendor` `/odm` `/vendor_dlkm` `/odm_dlkm` 用的是 **vendor context**
（`LoadProperties` 里按路径前缀判定）——
`ro.adb.secure` / `ro.debuggable` 是 system 属主的属性，**vendor 无权设置，静默拒绝**。

> 这解释了一个从 Stage 2 起就存在、一直没被发现的问题：
> `device.mk` 里 `PRODUCT_PROPERTY_OVERRIDES += ro.adb.secure=0 ro.debuggable=1`
> 落进 `vendor/build.prop`，**从来没有生效过**。
> AOSP 时代没暴露，是因为那棵树的 `/system/build.prop` 里本来就没有这两条。

**正确渠道：`PRODUCT_SYSTEM_EXT_PROPERTIES`**（init context，且在 system 之后加载）

```makefile
WITH_ADB_INSECURE := true                       # crDroid 官方开关 → system_ext 的 ro.adb.secure=0
PRODUCT_SYSTEM_EXT_PROPERTIES += ro.debuggable=1  # 我们自己补，M3 要 adb root/remount
```
⚠️ `WITH_ADB_INSECURE` 必须在 `inherit vendor/lineage/config/common_full_tablet_wifionly.mk`
**之前**赋值（`common.mk:33` 是 `ifdef`，解析时求值）。

### ★ 真正的阻塞：ClatCoordinator 让 system_server 崩溃循环

首次开机停在开机动画，`/data/tombstones/` 里 **100 个** tombstone，全是 system_server：

```
#01 register_com_android_server_connectivity_ClatCoordinator()+716
      /apex/com.android.tethering/lib64/libservice-connectivity.so
#02 JNI_OnLoad
#08 com.android.server.NetworkStatsServiceInitializer.<init>
#17 com.android.server.SystemServer.startOtherServices     → SIGABRT
```

`register_...` 第一件事是 `verifyClatPerms()`
（`packages/modules/Connectivity/service/jni/com_android_server_connectivity_ClatCoordinator.cpp:564`），
它逐项核对：

| 检查项 | 期望 |
|---|---|
| `/apex/com.android.tethering/bin/for-system` | dir 0750, clat:system, `u:object_r:system_file:s0` |
| `…/for-system/clatd` | 06755, clat:clat, `u:object_r:clatd_exec:s0` |
| `/sys/fs/bpf` | dir 01777, root:root, `u:object_r:fs_bpf:s0` |
| `/sys/fs/bpf/net_shared` | dir 01777, root:root, `u:object_r:fs_bpf_net_shared:s0` |
| `prog_clatd_schedcls_{egress4_clat_rawip,ingress6_clat_rawip,ingress6_clat_ether}` | 0440, PROG |
| `map_clatd_clat_{egress4,ingress6}_map` | 0660, MAP_RW |

任一不符 → `ALOGF`（只写 logcat，**不留 abort message**）→ `abort()`。
`/data/misc/logd` 里没有持久化日志，dropbox 也没有 → **事后查不出是哪一项，必须拿运行时 logcat**。

我们那棵最小 AOSP 从没走到这里（没带 tethering APEX），所以是换轨后的新问题。

> ⚠️ **一个差点犯的错**：看到程序名 `prog_clatd_schedcls_*` 我第一反应是内核缺
> `CONFIG_NET_CLS_BPF`（实测确实 not set）。但翻内核源码发现
> `BPF_PROG_TYPE_SCHED_CLS` 在 `include/linux/bpf_types.h` 里只受 `#ifdef CONFIG_NET`
> 保护 —— **加载**这类程序不需要 `NET_CLS_BPF`，那个选项管的是往 tc filter 上**挂载**。
> 照那个假设去重编内核就是几十分钟白费。

## ★★ M2 的三个真凶（都不是配置写错，是真实的不兼容）

### 真凶一：bpffs 的 SELinux 标签 —— 主线内核 vs Android

**症状**：system_server 崩溃循环，开不进桌面，`/data/tombstones/` 一次开机 100 个。

```
#01 register_com_android_server_connectivity_ClatCoordinator()+716
#08 com.android.server.NetworkStatsServiceInitializer.<init>
#17 com.android.server.SystemServer.startOtherServices     → SIGABRT

E jniClatCoordinator: context of '/sys/fs/bpf/net_shared' is
    'u:object_r:fs_bpf:s0' != 'u:object_r:fs_bpf_net_shared:s0'
```

**注意这是逐字比对标签字符串，不是权限检查 —— SELinux permissive 完全救不了。**

链路上其余环节全部正常（逐条实测）：五个 clat BPF 程序/映射**加载成功并 pin 好了**
（`NetBpfLoad` 日志为证），`plat_sepolicy.cil` 里 11 条 `genfscon bpf` 齐全。

**机制**：Android 靠 genfscon 给 bpffs 子目录打标签，而 genfscon 是【惰性】标注
（inode 首次访问时按路径匹配）。但主线内核的 bpffs（`kernel/bpf/inode.c`）在
`bpf_mkdir` / `bpf_mkobj` / `bpf_mklink` 三处都调用
`security_inode_init_security()` —— **创建时就急切赋标签、从父目录继承**，
genfscon 那 11 条形同虚设。

对照实验证明不是 genfscon 整体失效：

| 路径 | 实测标签 | 结论 |
|---|---|---|
| `/proc/sysrq-trigger` | `proc_sysrq` | ✅ 子路径匹配正常 |
| `/sys/kernel/tracing` | `debugfs_tracing_debug` | ✅ |
| `/sys/fs/bpf/*` | `fs_bpf`（全部） | ❌ 只有 bpffs |

**用户态修不了**：`chcon` 报 `ENOTSUP`。原因是 `selinux_inode_setxattr()` 只在
超级块带 `SBLABEL_MNT`（即策略对该 fs 用 `fs_use_xattr`）时才允许写
`security.selinux`，而 Android 对 bpf 用的是 genfscon。
—— 我一度写了 `bin/bpf-relabel.sh` 挂在 init 的 `bpf-progs-loaded` 触发器上，
服务确实跑了（avc 日志里有 `comm="bpf-relabel.sh"`），但 chcon 全部失败。
**这个方案从原理上就不成立。**

**修法**：`patches/0007-*` —— 把三处调用用编译期常量
`BPF_FS_EAGER_SECURITY_INIT=0` 短路（保留调用表达式在 `?:` 的未取分支，
免得 `bpf_fs_initxattrs` 变成未使用函数触发 `-Werror`）。
幂等脚本 `scripts/kernel-bpffs-genfscon-fix.py`。

**结果**：标签变成 `u:object_r:fs_bpf_net_shared:s0`，
**crDroid 首次完整启动**（`sys.boot_completed=1`，t+40s，
surfaceflinger / system_server / systemui / launcher3 全部在跑）。

> 这个坑对任何"Android on 新主线内核"的项目都成立，值得回赠社区。

### 真凶二：crDroid 的 SafetyNet 属性伪装

`system/core/init/property_service.cpp:1168` 的 `SetSafetyNetProps()` 里有一张
硬编码表（含 `oplusboot.verifiedbootstate` 这类非 AOSP 键），
在**解析 kernel cmdline 之前**强制写入。源码注释直言不讳：

> Report a valid verified boot chain to make Google SafetyNet integrity checks
> pass. This needs to be done before parsing the kernel cmdline as these
> properties are read-only and will be set to invalid values with androidboot
> cmdline arguments.

实机 getprop 逐条确认被它盖掉的值：

| 属性 | 我们设的 | 它强制的 |
|---|---|---|
| `ro.boot.verifiedbootstate` | orange（cmdline） | **green** |
| `ro.boot.flash.locked` | 0（cmdline） | **1** |
| `ro.boot.veritymode` | disabled（cmdline） | **enforcing** |
| `ro.debuggable` | 1（system_ext） | **0** |
| `ro.adb.secure` | 0（WITH_ADB_INSECURE） | **1** |

这一条解释了为什么 `WITH_ADB_INSECURE`、`PRODUCT_SYSTEM_EXT_PROPERTIES`、
kernel cmdline **三条路改了都没用** —— 产物里的 build.prop 明明是对的，
极具迷惑性，查了很久。

对本项目致命：`ro.debuggable=0` + 非 orange ⇒ `adb root` / `adb remount` 全废，
而 M3 部署 turnip 完全依赖 overlayfs remount。

开关是 `SPOOF_SAFETYNET`（`system/core/init/Android.bp:133`），
上游**只在 eng 变体关它**（`product_variables.eng`）。但 eng 会关掉 dexpreopt、
首次开机全靠 JIT，本机跑 swangle 软渲染受不了。
故用 `scripts/crdroid-tree-fixes.py` 把两处默认值改成 0（幂等）。

**结果**：`verifiedbootstate=orange`、`flash.locked=0`、`ro.debuggable=1`、
`ro.adb.secure=0` 全部为真，adb 免授权可用。

### 真凶三：s2idle 休眠 —— 排查效率的最大杀手

设备闲置 45–60 秒就

```
I PM      : suspend entry (s2idle)
```

然后醒不来（EC 挂起坑，CLAUDE.md 从 Stage 3 就预言了）。
**一度被误判成"system_server 崩溃导致重启"**——实际 logcat 最后一行就是它。
每次上机只有 45 秒窗口，这轮的低效大半来自这里。

★ 根因是内核**没开 `CONFIG_PM_WAKELOCKS`**，`/sys/power/wake_lock` 不存在。

> ⚠️ 我一度从 `shell: can't create /sys/power/wake_lock: Permission denied`
> 推断"文件存在只是没权限"——**这是错的**：往 sysfs 里创建不存在的文件
> 同样报 Permission denied。判据应该是直接 `ls`。

修法两处：
- `scripts/kernel-config-android.sh` 加 `--enable PM_WAKELOCKS` 并进 `MUST_Y` 断言
- `init.gaokun3.rc` 的 `on early-init` 写 `/sys/power/wake_lock gaokun3_nosuspend`
  （无条件、与是否插电无关；`svc power stayon` 只在插电时有效）

无需重建的止血（当场生效）：
```
settings put system screen_off_timeout 2147483647
svc power stayon true
```

## 仍未解决：MediaCodecList 依然为空

crDroid 完整启动后 `dumpsys media.player` 的解码器数**仍是 0**，
与 AOSP 时代同一症状 —— 说明**不是 crDroid 特有**，是本设备/内核层面的问题。

断点仍在 `Codec2Client::CacheServiceNames()`（`client.cpp:2636`）的
`AServiceManager_forEachDeclaredInstance()` 返回空。已排除：

- 服务确实注册（`service list` 有 `…IComponentStore/software`）
- framework VINTF 确实有该声明（`vintf fm` 列得出来，带 `updatable-via-apex`）
- servicemanager 的 `isVintfDeclared` 本身工作正常
  （logcat 里 vold/keymint/gatekeeper 都有 "Found … in … VINTF manifest"）
- `getVintfInstances()` 的 package/iface 拆分与
  `HalManifest::getAidlInstances()` 的过滤条件（`ExclusiveTo::EMPTY`、版本 0）
  逻辑上都应匹配

**主嫌疑（待验证）**：`CacheServiceNames()` 的结果是**进程内静态缓存、只查一次**；
framework 那条声明带 `updatable-via-apex="com.android.media.swcodec"`，
若查询早于 apexd/VINTF 更新，就永远为空。

**当前尝试**：在设备 manifest（`device/huawei/gaokun3/manifest.xml`）里再声明一次
—— 它随 `/vendor` 在 first-stage 挂载，没有 apex 依赖，时序上更早。
若仍为 0，下一步给 `Codec2Client` 加日志或直接跳过 declared 检查。

## ★★★ M2 收官：crDroid 完整启动，解码器 66 个

### 最终验收（2026-08-19 实机）

```
sys.boot_completed = 1               （t+40s）
进程：surfaceflinger / system_server / systemui / launcher3 全在
/sys/fs/bpf/net_shared  →  u:object_r:fs_bpf_net_shared:s0      ← 内核补丁生效
ro.boot.verifiedbootstate = orange   ro.boot.flash.locked = 0    ← SafetyNet 伪装已关
ro.debuggable = 1                    ro.adb.secure = 0           ← adb 免授权
media.c2.hal.selection = aidl
Codec2Client: Available Codec2 services: "software" "software" "__ApexCodecs__"
dumpsys media.player 的 c2.android.* 条目：66
  含 c2.android.mp3.decoder / aac / flac / amrnb / amrwb / g711
product/media/audio/：130 铃声 + 92 通知音 + 45 闹铃 + 25 UI 音效
```

`screenrecord` 不再报 `unable to create video/avc codec instance`。

### ★ #36 的最终定论

追了两个阶段的"解码器一个都没有"，根因是**一行没设的属性**：

```cpp
// frameworks/av/media/codec2/hal/common/HalSelection.cpp:57
std::string selection = GetProperty("media.c2.hal.selection", "hidl");
if (selection == "aidl") return true;
else if (selection == "hidl") return false;
```

**默认 `hidl`**，而 HIDL 的 Codec2 在 Android 15+ 已彻底不可用
（hwservicemanager 被移除）。实机一句话点破：

```
I HidlServiceManagement: Cannot list manifest for
    android.hardware.media.c2@1.0::IComponentStore without hwservicemanager
```

→ `Codec2Client::CacheServiceNames()` 空 → `MediaCodecList` 空 →
App "Failed to create audio/mpeg decoder"。

**与 crDroid 无关** —— AOSP 16 上同样如此，只是真机设备树都会设它。
所以 #36 最初"产品配置缺口"的直觉是对的，缺的不是 `media_codecs.xml`，
而是这个 HAL 选择属性。

⚠️ 必须走 `PRODUCT_SYSTEM_EXT_PROPERTIES`：该属性上下文是
`codec2_config_prop`，vendor context 无权设置。

### 排查路上被推翻的三个自己的假设（都值得记住）

1. **"clat 的 schedcls 程序需要 CONFIG_NET_CLS_BPF"** —— 错。
   `BPF_PROG_TYPE_SCHED_CLS` 在 `include/linux/bpf_types.h` 里只受
   `#ifdef CONFIG_NET` 保护；`NET_CLS_BPF` 管的是往 tc filter 上**挂载**。
   照这个假设去重编内核就是几十分钟白费。
2. **"chcon 能把 bpffs 标签改回来"** —— 错。`selinux_inode_setxattr()` 只在
   超级块带 `SBLABEL_MNT`（策略用 `fs_use_xattr`）时才允许写 `security.selinux`，
   Android 对 bpf 用 genfscon，所以用户态**从原理上**改不了。
   写好的 `bin/bpf-relabel.sh` 服务确实跑了（avc 日志可证），但 chcon 全部 ENOTSUP。
3. **"c2 声明的时序问题，放进设备 manifest 就好"** —— 错。
   开机很久之后新起的 mediaserver 依然报 "No Codec2 services declared"，
   证明不是时序；而且设备 manifest 那条加了也没用（反而让服务列了两次）。

### 仍未解决 / 下一步

- ~~**s2idle 休眠**：init 的 `write /sys/power/wake_lock` 静默失败~~
  ✅ **已解决，而且原本就是好的 —— 之前是我读错了（2026-08-19 M3 复核）**。

  当初判"没写进去"的依据是 `cat /sys/power/wake_lock` 输出为空。实测：

  ```
  -rw-rw---- 1 radio wakelock 4096 /sys/power/wake_lock
  $ cat /sys/power/wake_lock
  cat: /sys/power/wake_lock: Permission denied
  ```

  节点属主是 `radio:wakelock`、模式 0660，**`shell` 用户既不是属主也不在组里**，
  连读都读不了。之前那条 `echo "内容: [$(cat …)]"` 把 stderr 丢掉了，
  于是"权限不足"长得和"内容为空"一模一样。init 是 root，写入从一开始就成功。

  实测佐证：`uptime` 1305 秒（21 分钟）时 `dmesg | grep -ci "suspend entry"` = **0**，
  而修之前是 45–60 秒必挂起且醒不来。

  ⚠️ **方法论**：sysfs 上"读到空"有三种完全不同的成因 —— 文件不存在、
  没有读权限、内容真的为空，而它们在丢掉 stderr 的命令替换里长得一样。
  判断 sysfs 节点状态必须先 `ls -l` 看存在与权限，再看内容。
  （同一个坑先前已经中过一次：因为写它报的是 "Permission denied" 而不是
   "No such file"，我据此推断"内核有这项能力"——那次推断碰巧对了，
   但推理是不成立的，sysfs 对不存在的路径也可能报 Permission denied。）

  遗留：`settings put system screen_off_timeout` / `svc power stayon true`
  这两条 /data 里的兜底现在是冗余的，可以不再重设。
- ~~**`adb root` 不生效**~~ ✅ **已解决（2026-08-19 M3），两步走**：

  ```bash
  adb shell setprop service.adb.root 1     # 关键的一步
  adb root                                 # 这时才真的重启成 root
  adb shell id                             # uid=0(root) context=u:r:su:s0
  ```

  机制：adbd 的 `should_drop_privileges()` 看两个属性 ——
  `ro.debuggable`（=1，允许提权）和 `service.adb.root`（=1 才真的不降权）。
  `adb root` 本该自己把 `service.adb.root` 写成 1 再重启自己，但在本机
  这一步没生效（`adb root` 返回 0、无输出、adbd 也不重启）。
  由 shell 自己 `setprop` 就能写进去 —— **SELinux 是 permissive，
  属性上下文的限制只记 avc 不拦**。写进去之后再 `adb root`，
  adbd 重启并读到 1，就以 root 起来了。

  ⚠️ 顺带查明：`getprop ro.build.type` 是 **`user`** 而不是 `userdebug`
  （我们构建的是 userdebug 变体），`ro.secure=1`。这解释了为什么各种
  "userdebug 应该自带 root"的预期都落空。`ro.debuggable` 倒是 1
  （`SPOOF_SAFETYNET=0` 那一改起了作用）。

  ★ 这把钥匙的真正价值不在 overlayfs remount，而在**远程救砖**：
  拿到 root 后可以直接挂引导 ESP 改 `loader.conf`，见下面 M3 的坑 4。
- ~~设备 manifest 里那条 c2 声明是多余的，可以删~~ ✅ **已删（M3）**，
  而且不删还会直接卡住整树构建 —— `check_vintf` 报
  "in the device manifest but not specified in framework compatibility matrix"。
  详见下面 M3 的坑 3。
- 首次开机应用未就绪（`Could not find provider: media`、没有注册 audio/mpeg 的
  Activity），完整播放验证要等 SetupWizard 走完。

---

## M3：swangle → turnip（硬件 Vulkan）

M1/M2 一路都跑 `ro.hardware.vulkan=pastel`（ANGLE over SwiftShader，纯 CPU），
这一步把它换成 Adreno 690 的硬件驱动。Stage 5 已经把最难的部分打完了
（`docs/stage5-freedreno.md` D1–D10），M3 的工作是**把成果搬到 crDroid 树上**，
而不是重打一遍。

### 做法：铺回归档树，不重跑生成管线

见上面「★ mesa 管线一个都不能丢」一节的翻案。归档树 `~/keep/mesa3d-patched.tar.zst`
就是实测 SMMU fault 66 → 0 的那一棵（mesa 26.0.3 + `patches/0004` v3），
整棵铺进 `~/crdroid/external/mesa3d/`，保留 `.git` 以便随时对照/回退。

铺完用 git 反查改动量当作体检：4233 个变更文件、`Android.bp` 15109 行、
`vulkan.freedreno` 包装模块在位、`tu_knl_drm_msm` 出现 1 次而 `tu_knl_kgsl` 0 次
（**这一项必须确认**：AOSP 自带的 `aosp.toml` 默认是 kgsl，那是高通闭源内核接口，
在主线 msm DRM 上根本打不开设备）。

### ⚠️ 顺带发现：`patches/0005`（关抢占）在最终状态里是**没有应用**的

归档时间（UTC 2026-08-18 19:47）晚于 D10 定案 v3 的时间（UTC 16:35），
而归档树里 `tu_drm_has_preemption()` 和 `device->has_preemption = tu_drm_has_preemption(device)`
都是原样。也就是说：**实测 fault=0 / 进桌面 / screencap 正常，是在抢占开着的情况下拿到的**。
`patches/0005` 是 D3 时代"抢占是主嫌"那条错误主线的产物，D10 之后已被回退。
文件保留在 `patches/` 里作为侦查史，但**不要再应用它**。

### 坑 1 — `patches/0003` 记漏了，干净树上根本编不过

原版 0003 让 `glslangValidator` 复用树内的 `deqp_glslang_*` 静态库。在 crDroid 上：

```
error: external/deqp-deps/glslang/Android.bp:257:1: dependency
       "deqp_glslang_SPIRV" of "glslangValidator" missing variant:
  os:linux_glibc,link:static
available variants:
  os:android,arch:arm64_armv8-2a,link:static …
```

那些静态库继承 `deqp_and_deps_defaults`（`external/deqp/Android.bp:59`），
带 `sdk_version: "27"` 和 `-DDE_OS=DE_OS_ANDROID` —— 是**彻底的 device-only 模块**，
没有 `linux_glibc` 变体。给它们加 `host_supported` 会连锁污染整个 deqp。

而 `external/deqp` 在 crDroid 的 manifest 里就是原版 AOSP 项目
（`platform/external/deqp`, `remote="aosp"`），两边并无差异 ——
**所以当年在 AOSP 树上能编过，只能是还改过别处而 patches/0003 没记全。**
这是"补丁文件只记了一半"的典型代价：换棵树就现原形。

改法：写成**自足**模块，自带源码清单，只依赖 glslang 目录本身，
不碰 deqp 的任何 defaults。落成幂等脚本 `scripts/glslang-host-tool.py`
（不再靠手贴），`patches/0003` 同步更新为 v2。

两个具体点：
- `-DENABLE_SPIRV` 不给 → 运行时报 "does not have SPIR-V support"
  （StandAlone 的 SPIR-V 出口是编译期开关，不是命令行选项）
- `StandAlone.cpp` 硬 `#include "glslang/glsl_intrinsic_header.h"`，
  这是 CMake 侧 `gen_extension_headers.py` 生成的，Soong 侧原本无人生成
  → `fatal error: file not found`。补一个 genrule
  `gaokun_glslang_glsl_intrinsic_header`。

验收：`out/host/linux-x86/bin/glslangValidator --version` → `Glslang Version: 11:15.1.0`。

### 坑 2 — 生成的 `Android.bp` 里烤死了旧树的绝对路径

铺回归档树后 17 个 genrule 齐刷刷失败：

```
FileNotFoundError: [Errno 2] No such file or directory:
  '/home/vahiru/aosp/external/mesa3d/src/freedreno/registers/freedreno_copyright.xml'
```

`meson_to_hermetic` 的生成器把两类路径写成了**绝对路径**：

```
cmd: "… --rnn /home/vahiru/aosp/external/mesa3d/src/freedreno/registers …"
cmd: "… glslangValidator -V -I/home/vahiru/aosp/…/src/vulkan/runtime/bvh
                            -I/home/vahiru/aosp/…/src/compiler/spirv …"
```

树从 `~/aosp` 搬到 `~/crdroid`，这些路径全部落空。

★ **不能改成相对路径 / `$(location)`** —— 这些绝对路径的作用恰恰是
**逃出 Soong 的 sbox 沙箱**：沙箱里只有被声明成 `srcs` 的文件，而 glslang
那两个 `-I` 指向的目录（尤其 `src/compiler/spirv` 下被 `#include` 的头）
根本没被声明。改相对 = 沙箱里找不到，失败得更晚更难查。

正解是"重定位"而不是"相对化"：`scripts/mesa-relocate-abs-paths.py`
把任意 `<abs>/external/mesa3d` 前缀统一改写成当前树的实际路径
（Android.bp 62 处 + Android_res.bp 71 处）。幂等，换构建机也不用改脚本。
副作用是构建不 hermetic（out/ 里留有本机路径），但这是生成器的既有行为。

### 顺带补上：`smmu-nostall.sh` 也是"只活在设备 overlay 里"的漏网

`bin/smmu-nostall.sh` + `etc/smmustall.rc` 之前从没进过构建配置
（和 `audio-route.sh`、`SC8280XP-HUAWEI-GAOKUN3-tplg.bin` 是同一类）。
它是 GPU SMMU stall-on-fault 的常驻解锁器 —— 本平台 context-fault 中断
打不到 CPU，任何一次 GPU 页错误都会让 SMMU 永久 stall 并拖死整条链，
**错一次就死且不自愈**。0004 v3 之后 fault 实测为 0，但安全网必须在。

时序：挂在 `on post-fs-data`（脚本在 /vendor/bin，要等 mount_all；
而 SurfaceFlinger 首次用 GPU 在 `on boot` 之后，来得及）。
`seclabel u:r:shell:s0` 照 audioroute 的写法。
⚠️ 脚本里的 `NCB=2` 绝不能调大 —— 扫未实现的 context bank 会打出 external abort，
把内核静默带走。

### 坑 3 — 设备 manifest 里那条 c2 声明会直接卡住整树构建

M2 遗留的"多余声明"不只是多余，整树构建到 `check_vintf` 就死：

```
ERROR: files are incompatible: The following instances are in the device
manifest but not specified in framework compatibility matrix:
    android.hardware.media.c2.IComponentStore/software (@1)
```

`android.hardware.media.c2` 是**平台 HAL**，只能由 framework compatibility
matrix 认领；设备 manifest 单方面声明它，就成了"多出来的实例"。
（M1/M2 时之所以没炸，是因为那几轮构建没走到 `check_vintf_all` 这一步 ——
`m vulkan.freedreno` 之后第一次跑整树才撞上。）

删掉即可 —— 真凶从来就是 `media.c2.hal.selection=hidl`，
这条声明是错误归因时代的遗物。`device/huawei/gaokun3/manifest.xml`
现在只剩 `target-level="202504"`，删除理由写在文件注释里。

### M3 验收（2026-08-19，实机）

一键复跑：`bash scripts/verify-turnip.sh [浸泡秒数]`。

```
ro.hardware.vulkan = freedreno
/vendor/lib64/hw/vulkan.freedreno.so   14 927 336 B   （vulkan.pastel.so 仍在，一行属性可切回）
logcat                                 Turnip Adreno (TM) 690
sys.boot_completed=1                   t+48s
桌面进程                                surfaceflinger / system_server / systemui / launcher3 全在
GMU 错误（timed out|watchdog|gdsc didn） 0
a6xx_recover                            0
SMMU FAULT#                             0
screencap                               rc=0，3.83 MB PNG，锁屏逐像素正常
崩溃残留（logcat -b crash）              无
```

**浸泡 22 分钟**（每 2 分钟采样，期间反复启动设置/浏览器 + `screencap`
给 GPU 加负载；原计划 30 分钟，22 分钟时判定证据已足够而提前收）：

```
[2..22 分钟] gmu=0  recover=0  fault=0  boot=1
桌面四进程 PID  696 882 1326 1650   ← 22 分钟内一次都没变（没有崩溃重启）
smmustall 心跳  round=11400  清 CFCFG=132  抓 fault=0
suspend entry   0
```

`清 CFCFG=132` 这个数字本身是有信息量的：内核确实在反复把
`SCTLR.CFCFG` 写回 1（每次 GPU 上下电/恢复都会），解锁器每次都及时清掉 ——
**说明这个常驻 workaround 不是摆设，去掉它只是等一次页错误的运气。**

截图肉眼确认：1600×2560 壁纸、通知卡的毛玻璃/圆角、状态栏图标全部正常
—— 是真的在做硬件合成，不是黑屏也不是软渲染兜底。

### M3 之后的实机状态（M4 的起点，已逐项实测）

| 项 | 状态 | 说明 |
|---|---|---|
| 触摸 | 设备在 | `Himax Capacitive TouchScreen` (event7)，未做手感复验 |
| 键盘/触控板 | 在 | `HID 12d1:10b8` 一族 |
| 声卡 | 注册 | `SC8280XP-HUAWEI-GAOKUN3` |
| **音频路由** | ❌ **断** | 见下 |
| 解码器 | 66 | `dumpsys media.player` 数 `c2.android.*` |
| WiFi | 硬件通、**没连上** | 见下 |
| 蓝牙 | OFF | 未开，`android-post-flash.sh` 里还禁着（HAL 已装，可以放开重测）|
| 休眠 | 不挂起 | `suspend entry` 计数 0 |

#### ★ tinyalsa 工具集从没进过构建配置（音频当前是断的）

`/vendor/bin/audio-route.sh` 第一件事是找 `tinymix`：

```sh
M=/system/bin/tinymix
[ -x $M ] || M=/vendor/bin/tinymix
[ -x $M ] || { log -t audioroute "找不到 tinymix，放弃"; exit 1; }
```

实测 `command -v tinymix` → 缺。Stage 4 时它是**手动 push 进设备的**，
从来没有出现在 `PRODUCT_PACKAGES` 里 —— 与 `audio-route.sh` 本身、
`SC8280XP-HUAWEI-GAOKUN3-tplg.bin`、`smmu-nostall.sh` 是同一类漏网，
而且已经是这一类的**第四个**。

表现最阴：声卡注册了、服务也确实跑了、播放不报错 —— 就是一个混音器控件都没设，
所以没声音。已加进 `device.mk`（`tinymix tinyplay tinycap tinypcminfo`），
下次构建生效。

> 教训固化：凡是"我 adb push 一下就好了"的东西，**当场就要写进 device.mk**。
> 这一类问题在换 ROM 时会一次性全部引爆，而且每一个都伪装成硬件故障。

#### WiFi：硬件全通，但网络被框架**永久**禁用（stage4 #29 复发）

```
ath11k_pci 已绑定 0006:01:00.0        wpa_supplicant running
cmd wifi start-scan → 扫到 25 个 AP（含目标 AP，RSSI −38）
WifiHalAidlImpl: Initialization is complete   （AIDL v3）
但：NetworkSelectionStatus NETWORK_SELECTION_PERMANENTLY_DISABLED
    mNetworkSelectionDisableReason NETWORK_SELECTION_DISABLED_NO_INTERNET_PERMANENT
```

即 `docs/stage4-findings.md` #29 那个坑：连通性探测端点被墙 → 框架判"永久无网"
→ 把这个网络的自动加入**永久**关掉。`android-post-flash.sh` 里换国内端点那两条
已经重新执行（`captive_portal_https_url` 现为 miui 的 generate_204），
但**已经背上的永久禁用标记不会因此自动清除**：

- `cmd wifi clear-user-disabled-networks` 清的是"用户禁用"，不是这一个；
- `NO_INTERNET_PERMANENT` 的重新启用条件是**一次用户发起的连接**
  （`cmd wifi connect-network <ssid> wpa2 <密码>` 或设置里点一下）。

所以这一步需要密码，留给 M4 / 用户操作。硬件侧没有任何问题。
