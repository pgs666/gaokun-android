#!/vendor/bin/sh
# GPU SMMU stall-on-fault 解锁器 + fault 地址捕获器（v2：全 CB 扫描 + 无限运行）。
#
# 背景（docs/stage5-freedreno.md D5/D6）：a690 的 GPU SMMU 配成 stall-on-fault
# （SCTLR.CFCFG=1）且中断使能（CFIE=1），但 context-fault 中断从不到达 CPU
# （/proc/interrupts 计数恒 0）→ 没人 resume → SMMU 永久 stall → CP 取不到指令
# → GMU 投票超时 → 看门狗 → cx gdsc 塌不下去（stall 拖住掉电）→ 死循环。
#
# 本脚本清 SCTLR.CFCFG，让 fault 改走 terminate（GPU 收到 abort 后能正常
# 报错+恢复+掉电），并趁 GPU 上电时轮询 FSR/FAR 抓 fault 地址（真 bug 定位）。
# 内核 recover 会重写 SCTLR 把 CFCFG 加回来，所以必须持续轮询。
#
# v2 相比 v1 的三处改进（2026-08-18 第二轮）：
#   1. **不再 6000 轮就退出** —— v1 约 10 分钟后自己退了，撑不住浸泡验证。
#   2. **扫全部 16 个 context bank**，不只 CB0。GPU 用 CB0（per-process TTBR0
#      由 CP 切换），但 **GMU 自己另有一个 iommu domain**
#      （a6xx_gmu_memory_probe 建的）→ 落在另一个 CB 上。只看 CB0 会把
#      GMU 侧的 fault 完全漏掉。全扫每 2s 一次，CB0 每轮都看（省 fork）。
#   3. fault 日志补 CB 号与 WNR（读/写方向）；每 60s 一行心跳。
#
# GPU 掉电时 SMMU CB 寄存器读全 0；只在读到非 0（已上电）时才动手，避免
# 对断电的 MMIO 写入。⚠️ toybox devmem 输出十进制。

DM=/system/bin/devmem
CB_BASE=$((0x3db0000))     # GPU SMMU (3da0000) context bank 0：base + numpage(16)*4K
CB_STRIDE=$((0x1000))
NCB=16                     # reg 窗口 0x20000 → CB 0..15

CFCFG=128                  # SCTLR bit7  stall-on-fault
SS=1073741824              # FSR   bit30 stalled state
FAULTBITS=511              # FSR   bits0-8 各类 fault（TF/AFF/PF/EF/TLBMCF/TLBLKF/ASF/UUT）
WNR=16                     # FSYNR0 bit4  write-not-read

cleared=0; caught=0; round=0

# 处理一个 context bank：$1 = CB 序号
check_cb() {
    cb=$1
    B=$((CB_BASE + cb * CB_STRIDE))
    S=$($DM $B 2>/dev/null)
    [ -n "$S" ] && [ "$S" != "0" ] || return 0     # 掉电/未使用

    # 1) 关 stall-on-fault（内核 recover 会重写，故每轮都查）
    if [ $((S & CFCFG)) -ne 0 ]; then
        $DM $B 4 $((S & ~CFCFG)) 2>/dev/null
        cleared=$((cleared + 1))
        log -t smmustall "CB$cb 清 CFCFG 第 ${cleared} 次：SCTLR $S -> $((S & ~CFCFG))"
    fi

    # 2) 抓 fault 现场（趁上电，FAR/FSYNR 有效）
    F=$($DM $((B + 0x58)) 2>/dev/null)
    [ -n "$F" ] && [ "$F" != "0" ] && [ $((F & (FAULTBITS | SS))) -ne 0 ] || return 0

    LO=$($DM $((B + 0x60)) 2>/dev/null); HI=$($DM $((B + 0x64)) 2>/dev/null)
    S0=$($DM $((B + 0x68)) 2>/dev/null); S1=$($DM $((B + 0x6c)) 2>/dev/null)
    T0L=$($DM $((B + 0x20)) 2>/dev/null); T0H=$($DM $((B + 0x24)) 2>/dev/null)
    # GICD_ISPENDR word22 = INTID 704..735 = SPI 672..703：gpu_smmu 的 global
    # (SPI 672/673 = bit0/1) 与 context fault (SPI 678/679 = bit6/7) 都在这一个
    # word 里。fault 当场读它就能回答 D6 悬案：SMMU 到底有没有拉中断线、
    # 拉的是不是 DT 声明的那一条。（空闲基线实测 0x78000000 = bit27-30 常挂起）
    GP=$($DM $((0x17a00258)) 2>/dev/null)
    caught=$((caught + 1))
    if [ $((S0 & WNR)) -ne 0 ]; then D=WRITE; else D=READ; fi
    log -t smmustall "FAULT#${caught} CB$cb $D FSR=$F FAR=${HI}_${LO} FSYNR0=$S0 FSYNR1=$S1 TTBR0=${T0H}_${T0L} GICPEND22=$GP"

    # 3) 清 FSR（否则同一份 fault 会被反复上报），卡在 stall 就 terminate
    if [ $((F & SS)) -ne 0 ]; then
        $DM $((B + 0x8)) 4 1 2>/dev/null            # CB_RESUME = terminate
        log -t smmustall "  → CB$cb RESUME terminate 已发"
    fi
    $DM $((B + 0x58)) 4 $F 2>/dev/null              # FSR 写 1 清位
}

log -t smmustall "启动 v2：CB0..CB$((NCB - 1)) @ $CB_BASE，无限运行"
while true; do
    check_cb 0                                      # GPU 主 CB：每轮
    if [ $((round % 20)) -eq 0 ]; then               # 全扫：约每 2s
        cb=1
        while [ $cb -lt $NCB ]; do check_cb $cb; cb=$((cb + 1)); done
    fi
    if [ $((round % 600)) -eq 0 ]; then               # 心跳：约每 60s
        log -t smmustall "心跳 round=$round 清 CFCFG=${cleared} 抓 fault=${caught}"
    fi
    round=$((round + 1))
    sleep 0.1
done
