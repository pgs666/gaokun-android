#!/usr/bin/env python3
"""解 devcd 里 ring0 在 rptr 附近的 PM4 包（a6xx type4/type7 编码）。
用法: decode-ring.py <devcd.txt> [前后dword数]
"""
import base64, struct, re, sys

OP7 = {0x10:"CP_NOP",0x12:"CP_WAIT_MEM_WRITES",0x14:"CP_WAIT_FOR_ME",0x1d:"CP_WAIT_FOR_IDLE",
 0x21:"CP_EXEC_CS_INDIRECT",0x22:"CP_DRAW_INDX",0x25:"CP_UNK",0x26:"CP_WAIT_REG_MEM",
 0x2d:"CP_REG_WRITE",0x33:"CP_DRAW_INDX_OFFSET",0x34:"CP_DRAW_INDIRECT",0x36:"CP_DRAW_AUTO",
 0x37:"CP_DRAW_INDIRECT_MULTI",0x38:"CP_DRAW_PRED_ENABLE_GLOBAL",0x3d:"CP_MEM_WRITE",
 0x3f:"CP_INDIRECT_BUFFER",0x40:"CP_MEM_TO_MEM",0x42:"CP_SET_DRAW_STATE",0x43:"CP_COND_EXEC",
 0x44:"CP_COND_WRITE5",0x45:"CP_EVENT_WRITE7?",0x46:"CP_EVENT_WRITE",0x48:"CP_INDIRECT_BUFFER_CHAIN?",
 0x4d:"CP_REG_TO_MEM",0x53:"CP_SMMU_TABLE_UPDATE",0x65:"CP_SET_MARKER",0x66:"CP_SET_PSEUDO_REG",
 0x6d:"CP_CONTEXT_REG_BUNCH",0x70:"CP_SKIP_IB2_ENABLE_GLOBAL",0x73:"CP_MEM_WRITE_CNTR?",
 0x8b:"CP_SET_SUBDRAW_SIZE?",0xd8:"CP_WHERE_AM_I"}

def extract_ring0(txt):
    m = re.search(r"^ringbuffer:\n(.*?)(?=^\S)", txt, re.M | re.S)
    body = m.group(1)
    # 第一个 id: 0 段里的 data
    seg = re.search(r"- id: 0\n(.*?)(?=  - id: |\Z)", body, re.S)
    s = seg.group(1)
    rptr = int(re.search(r"rptr: (\d+)", s).group(1))
    wptr = int(re.search(r"wptr: (\d+)", s).group(1))
    a85, in_d = [], False
    for ln in s.split("\n"):
        if "data: !!ascii85 |" in ln:
            in_d = True; continue
        if in_d:
            t = ln.strip()
            if t and all(("!" <= c <= "u") or c == "z" for c in t):
                a85.append(t)
            else:
                break
    return rptr, wptr, base64.a85decode("".join(a85))

txt = open(sys.argv[1], encoding="utf-8", errors="replace").read()
span = int(sys.argv[2]) if len(sys.argv) > 2 else 48
rptr, wptr, data = extract_ring0(txt)
n = len(data) // 4
ws = struct.unpack(f">{n}I", data[:n*4])
print(f"ring0: {n} dwords, rptr={rptr} wptr={wptr}")

def annotate(i):
    w = ws[i]
    t = (w >> 28) & 0xf
    if t == 0x7:
        op = (w >> 16) & 0x7f
        cnt = w & 0x3fff
        return f"TYPE7 {OP7.get(op, f'op{op:#x}')} cnt={cnt}"
    if t == 0x4:
        reg = (w >> 8) & 0x7ffff
        cnt = w & 0x7f
        return f"TYPE4 reg={reg:#x} cnt={cnt}"
    return ""

start = max(0, rptr - span)
end = min(n, rptr + span)
print(f"=== dwords [{start}..{end}]（rptr 处标 >>>）===")
i = start
while i < end:
    mark = ">>>" if i == rptr else "   "
    note = annotate(i)
    print(f"{mark}[{i:5d}] {ws[i]:#010x}  {note}")
    i += 1
