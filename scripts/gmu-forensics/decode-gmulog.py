#!/usr/bin/env python3
"""解码 devcd 的 gmu-log 段（GMU 固件 trace 环形缓冲）。
记录格式未公开，按 u32 流转储非零区，猜测 {u32 头, u32 时间戳/参数...} 记录结构。
用法: decode-gmulog.py <devcd.txt> [起始dword] [数量]
"""
import base64, struct, re, sys

def extract(txt, name):
    m = re.search(rf"^{name}:\n(.*?)(?=^\S|\Z)", txt, re.M | re.S)
    body = m.group(1)
    iova = int(re.search(r"iova: (0x[0-9a-f]+)", body).group(1), 16)
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
    return iova, base64.a85decode("".join(a85))

txt = open(sys.argv[1], encoding="utf-8", errors="replace").read()
iova, data = extract(txt, "gmu-log")
n = len(data) // 4
ws = struct.unpack(f">{n}I", data[:n*4])
print(f"gmu-log: iova={iova:#x} 解码 {len(data)} 字节 = {n} dwords")

# 找最后一个非零 dword（环形缓冲的写入前沿）
last = max((i for i, w in enumerate(ws) if w), default=0)
print(f"最后非零 dword @ {last}")

start = int(sys.argv[2]) if len(sys.argv) > 2 else max(0, last - 120)
cnt = int(sys.argv[3]) if len(sys.argv) > 3 else 128
print(f"=== dwords [{start}..{min(start+cnt, n)}] ===")
for i in range(start, min(start + cnt, n), 4):
    row = ws[i:i+4]
    print(f"  [{i:5d}] " + " ".join(f"{w:#010x}" for w in row))
