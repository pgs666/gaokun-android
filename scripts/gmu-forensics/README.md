# GPU/GMU 取证工具集（gaokun3 / a690 / 主线 msm）

2026-08-18 侦查战产物。完整案情见 `docs/stage5-freedreno.md` D4–D7。
这套工具与内核/DTB 绑定、与 AOSP 版本无关，**换 crDroid 后照样能用**。

## 设备侧（Android）

| 文件 | 用途 |
|---|---|
| `smmu-nostall.sh` + `smmustall.rc` | ★核心 workaround：轮询清 `SCTLR.CFCFG`，让 GPU SMMU fault 走 terminate 而非永久 stall；顺带抓 `FSR/FAR/FSYNR/TTBR0` 打到 logcat（`logcat -s smmustall`） |
| `smmu-irq-probe.sh` | 判定 SMMU context-fault 中断是否到达 CPU（挂 debugfs + 开 dyndbg + 采两次 `/proc/interrupts` 对比） |
| `tudebug.rc` | 注入 turnip 调试旗标（**正确属性名 `debug.mesa.tu.debug`**） |
| `gpu-pin.sh` + `gpupin.rc` | 钉 GPU `min_freq`（值读 `/data/local/tmp/gpu_min_freq`），排查变频相关问题 |
| `capture-death.sh` | 宿主机侧死亡现场捕获器：滚动抓 klog、devcoredump 按节点编号秒拉、devfreq 快照 |

## 分析侧（宿主机）

| 文件 | 用途 |
|---|---|
| `gmu-hfi-decode.py` | 解 devcd 的 `gmu-hfi` 段：队列表 + 消息流水 |
| `decode-fatal.py` | 按 `queue-history` 抠出最后 8 条 H2F 消息与 F2H ACK 的原始 payload |
| `decode-gmulog.py` | 解 GMU 固件 trace 环（4 词记录 `{msg头, 事件码, ts, arg}`） |
| `decode-ring.py` | 解 ring0 在 rptr 附近的 PM4 包（TYPE4/TYPE7） |
| `dtb-smmu-patch.py` | ⚠️ 保留但**别用**：破坏 `qcom,adreno-smmu` 会让 `msm_iommu.c:788` NULL deref panic |

## Ubuntu 对照侧（Ego）

| 文件 | 用途 |
|---|---|
| `gmu-lab.sh` | `evidence`（留证四件套）/ `churn`（GMU 真掉电翻炒）/ `stress`（满载）/ `watch` |
| `vk-prio.c` | 最小跨优先级提交器（`gcc -O2 -o vk-prio vk-prio.c -lvulkan`），复刻 SF+app 并发 |
| `mesa-lab-setup.sh` | Ego 上搭 mesa 分析环境（crashdec 已验证可编） |

## 关键踩坑（会反复中招）

1. **GPU SMMU 的 CB 寄存器只在 GPU 上电时有效**，掉电一律读 0。
   `TTBR0=0/FAR=0` 与 `SCTLR=0` 同时出现 = 掉电，不是真值。
2. **toybox `devmem` 输出十进制**（`00000487` 是 0x1E7，别当 hex）。
3. **crashdec 不认 7.2 的 devcd**：把 `revision: 0 (06090000)` 改成
   `revision: 690 (6.9.0.0)` 骗过 parser（`Enum chip doesn't exist` 可忽略）。
4. **mesa 的 Android 属性名**：`TU_DEBUG` → `debug.mesa.tu.debug`
   （加 `mesa.` 前缀、下划线转点、再试 `debug.`/`vendor.`/`""` 前缀）。
   曾误写 `debug.tu.debug` 导致所有旗标实验静默失效。
5. **`sudo cmd &` 拿到的是 sudo 的 PID**，SIGSTOP 不转发 → 信号实验要
   `pkill -STOP -x 进程名`，并用 `runtime_suspended_time` 计数器验真。
6. **`msm.enable_preemption=0` 是有害参数**（`msm_submitqueue.c:201` 判断
   语义反转，传 0 反而放行 ALLOW_PREEMPT）→ 已从 cmdline 删除。
7. **vendor 免构建机可写**：cmdline 加
   `androidboot.flash.locked=0 androidboot.verifiedbootstate=orange`
   后 `adb remount` 走 overlayfs；**每次重启都挂回 ro，写前重跑 remount**。
