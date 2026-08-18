#!/usr/bin/env python3
"""抠出 devcd 里 queue[0]（H2F cmd 队列）按 history 索引的最后 8 条消息原始 payload。
用法: decode-fatal.py <devcd.txt>
"""
import base64, struct, re, sys

NAMES = {0:'INIT',1:'FW_VERSION',3:'BW_TABLE',4:'PERF_TABLE',5:'TEST',7:'ACD',
         10:'START',11:'FEATURE_CTRL',14:'CORE_FW_START',15:'TABLE',
         30:'GX_BW_PERF_VOTE',33:'PREPARE_SLUMBER',100:'F2H_ERROR',126:'F2H_ACK'}

def extract(txt, name):
    m = re.search(rf"^{name}:\n(.*?)(?=^\S|\Z)", txt, re.M | re.S)
    body = m.group(1)
    iova = int(re.search(r"iova: (0x[0-9a-f]+)", body).group(1), 16)
    hist = [ [int(x) for x in h.split()] for h in re.findall(r"queue-history\[\d\]: ([-\d ]+)", body) ]
    a85, in_d = [], False
    for ln in body.split("\n"):
        if "data: !!ascii85 |" in ln:
            in_d = True; continue
        if in_d:
            s = ln.strip()
            if s and all(("!" <= c <= "u") or c == "z" for c in s):
                a85.append(s)
            else:
                break
    return iova, base64.a85decode("".join(a85)), hist

txt = open(sys.argv[1], encoding="utf-8", errors="replace").read()
iova, data, hist = extract(txt, "gmu-hfi")

# 队列表头(大端 u32)：qhdr0=6, qhdr_size=12, 3 队列
def dws(off, n): return struct.unpack_from(f">{n}I", data, off)
q0 = dws(6*4 + 0*12*4, 12)
q1 = dws(6*4 + 1*12*4, 12)
off0 = q0[1] - iova
off1 = q1[1] - iova
print(f"queue0(H2F cmd): rd={q0[10]} wr={q0[11]}  queue1(F2H msg): rd={q1[10]} wr={q1[11]}")

def dw(base, i): return struct.unpack_from(">I", data, base + i*4)[0]

print("\n=== H2F 最后 8 条（queue-history[0]）===")
for idx in hist[0]:
    if idx < 0: continue
    h = dw(off0, idx)
    mid, msz, seq = h & 0xff, (h >> 8) & 0xff, (h >> 20) & 0xfff
    pl = [dw(off0, idx+1+k) for k in range(min(max(msz-1,0), 6))]
    tag = "  <-- 未消费(致命)" if q0[10] <= idx < q0[11] else ""
    print(f"  [{idx:4d}] seq={seq:3d} {NAMES.get(mid, f'id{mid}'):16s} size={msz} " +
          " ".join(f"{p:#010x}" for p in pl) + tag)

print("\n=== F2H 最后 8 条 ACK（queue-history[1]，payload[0]=被应答消息的原头）===")
for idx in hist[1]:
    if idx < 0: continue
    h = dw(off1, idx)
    mid, msz, seq = h & 0xff, (h >> 8) & 0xff, (h >> 20) & 0xfff
    pl = [dw(off1, idx+1+k) for k in range(min(max(msz-1,0), 3))]
    rh = pl[0] if pl else 0
    rname = NAMES.get(rh & 0xff, f"id{rh & 0xff}")
    print(f"  [{idx:4d}] {NAMES.get(mid, f'id{mid}'):8s} → 应答 seq={ (rh>>20)&0xfff :3d} {rname:16s} err={pl[1]:#x}" if len(pl)>1 else f"  [{idx:4d}] {NAMES.get(mid, f'id{mid}')}")
