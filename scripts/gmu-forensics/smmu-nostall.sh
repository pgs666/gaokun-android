#!/vendor/bin/sh
# GPU SMMU stall-on-fault 解锁器 + fault 地址捕获器。
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
# GPU 掉电时 SMMU CB 寄存器读全 0；只在读到非 0（已上电）时才动手，避免
# 对断电的 MMIO 写入。

DM=/system/bin/devmem
CB=$((0x3db0000))          # GPU SMMU (3da0000) context bank 0：base + numpage(16)*4K
SCTLR=$CB
FSR=$((CB + 0x58))
FAR_LO=$((CB + 0x60))
FAR_HI=$((CB + 0x64))
FSYNR0=$((CB + 0x68))
FSYNR1=$((CB + 0x6c))
RESUME=$((CB + 0x8))
TTBR0_LO=$((CB + 0x20))
TTBR0_HI=$((CB + 0x24))

CFCFG=128                  # SCTLR bit7  stall-on-fault
SS=1073741824              # FSR   bit30 stalled state
FAULTBITS=511              # FSR   bits0-8 各类 fault（TF/AFF/PF/EF/TLBMCF/TLBLKF/ASF/UUT）

log -t smmustall "启动：等 GPU SMMU 上电（CB0=$CB）"
n=0; cleared=0; caught=0
while [ $n -lt 6000 ]; do          # 约 10 分钟
    S=$($DM $SCTLR 2>/dev/null)
    if [ -n "$S" ] && [ "$S" != "0" ]; then
        # 1) 关 stall-on-fault（内核 recover 会重写，故每轮都查）
        if [ $((S & CFCFG)) -ne 0 ]; then
            $DM $SCTLR 4 $((S & ~CFCFG)) 2>/dev/null
            cleared=$((cleared + 1))
            log -t smmustall "清 CFCFG 第 ${cleared} 次：SCTLR $S -> $((S & ~CFCFG))"
        fi

        # 2) 抓 fault 现场（趁上电，FAR/FSYNR 有效）
        F=$($DM $FSR 2>/dev/null)
        if [ -n "$F" ] && [ "$F" != "0" ] && [ $((F & (FAULTBITS | SS))) -ne 0 ]; then
            LO=$($DM $FAR_LO 2>/dev/null); HI=$($DM $FAR_HI 2>/dev/null)
            S0=$($DM $FSYNR0 2>/dev/null); S1=$($DM $FSYNR1 2>/dev/null)
            T0L=$($DM $TTBR0_LO 2>/dev/null); T0H=$($DM $TTBR0_HI 2>/dev/null)
            caught=$((caught + 1))
            log -t smmustall "FAULT#${caught} FSR=$F FAR=${HI}_${LO} FSYNR0=$S0 FSYNR1=$S1 TTBR0=${T0H}_${T0L}"
            # 3) 若卡在 stall，terminate 掉让 GPU 继续
            if [ $((F & SS)) -ne 0 ]; then
                $DM $RESUME 4 1 2>/dev/null
                log -t smmustall "  → RESUME terminate 已发"
            fi
        fi
    fi
    n=$((n + 1))
    sleep 0.1
done
log -t smmustall "退出：清 CFCFG ${cleared} 次，抓到 fault ${caught} 次"
