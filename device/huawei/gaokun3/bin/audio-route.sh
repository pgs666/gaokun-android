#!/vendor/bin/sh
# 开机把 LPASS 混音器路由到内置扬声器（Android 没有 ALSA UCM，得自己摆）。
#
# 序列来自实机验证过的 UCM2：华为 MateBook E 的 UCM 明确 include
# ThinkPad X13s 的配置（`conf.d/sc8280xp/sc8280xp.conf` 里
# `If.HUAWEI → /Qualcomm/sc8280xp/LENOVO-X13s.conf`），所以 X13s 那套
# 控件序列直接适用；audioreach 拓扑固件同理（都是 X13s 那份）。
#
# 关键映射（`Qualcomm/sc8280xp/HiFi.conf`）：
#   扬声器 = PCM **1**（WSA_CODEC_DMA_RX_0 ← MultiMedia2）
#   耳机   = PCM **0**（RX_CODEC_DMA_RX_0  ← MultiMedia1）
# 自测：`tinyplay /data/local/tmp/tone.wav -D 0 -d 1`（2026-08-19 实机出声）
#
# ⚠️ 左功放（sdw:1:...:1）会卡在 Alert 状态刷 "Bus clash detected"，
#    右功放正常；出声不受影响，但这是个待查项（docs/stage5-audio.md）。

M=/system/bin/tinymix
[ -x $M ] || M=/vendor/bin/tinymix
[ -x $M ] || { log -t audioroute "找不到 tinymix，放弃"; exit 1; }

n=0
while [ ! -e /dev/snd/controlC0 ] && [ $n -lt 60 ]; do sleep 1; n=$((n+1)); done
[ -e /dev/snd/controlC0 ] || { log -t audioroute "等不到声卡（60s）"; exit 1; }

set -- \
    "WSA_CODEC_DMA_RX_0 Audio Mixer MultiMedia2" 1 \
    "WSA RX0 MUX" AIF1_PB \
    "WSA RX1 MUX" AIF1_PB \
    "WSA_RX0 INP0" RX0 \
    "WSA_RX1 INP0" RX1 \
    "WSA_COMP1 Switch" 1 \
    "WSA_COMP2 Switch" 1 \
    "SpkrLeft COMP Switch" 1 \
    "SpkrLeft BOOST Switch" 1 \
    "SpkrLeft VISENSE Switch" 1 \
    "SpkrLeft DAC Switch" 1 \
    "SpkrRight COMP Switch" 1 \
    "SpkrRight BOOST Switch" 1 \
    "SpkrRight VISENSE Switch" 1 \
    "SpkrRight DAC Switch" 1 \
    "SpkrLeft PA Volume" 17 \
    "SpkrRight PA Volume" 17

while [ $# -ge 2 ]; do
    $M "$1" "$2" >/dev/null 2>&1 || log -t audioroute "设置失败: $1 -> $2"
    shift 2
done

log -t audioroute "扬声器路由已应用（PCM1 / WSA / PA=17）"
