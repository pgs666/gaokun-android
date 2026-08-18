#!/usr/bin/env python3
"""解码 msm devcoredump 里的 gmu-hfi 段：ascii85 → 队列表 → 消息流水。
用法: gmu-hfi-decode.py <devcd.txt>
结构对照 v7.2-rc2 drivers/gpu/drm/msm/adreno/a6xx_hfi.h
"""
import base64, struct, sys, re

MSG_NAMES = {
    0: "H2F_INIT", 1: "H2F_FW_VERSION", 3: "H2F_BW_TABLE", 4: "H2F_PERF_TABLE",
    5: "H2F_TEST", 7: "H2F_ACD", 8: "H2F_CLX_TBL", 10: "H2F_START",
    11: "H2F_FEATURE_CTRL", 14: "H2F_CORE_FW_START", 15: "H2F_TABLE",
    30: "H2F_GX_BW_PERF_VOTE", 33: "H2F_PREPARE_SLUMBER",
    100: "F2H_ERROR", 126: "F2H_ACK",
}

def extract_section(txt, name):
    """取 'name:' 段里的 iova 与 ascii85 数据"""
    m = re.search(rf"^{name}:\n(.*?)(?=^\S|\Z)", txt, re.M | re.S)
    if not m:
        return None, None, None
    body = m.group(1)
    iova = int(re.search(r"iova: (0x[0-9a-f]+)", body).group(1), 16)
    hist = re.findall(r"queue-history\[\d\]: ([-\d ]+)", body)
    lines = body.split("\n")
    a85_parts, in_data = [], False
    for ln in lines:
        if "data: !!ascii85 |" in ln:
            in_data = True
            continue
        if in_data:
            s = ln.strip()
            # ascii85 行：全部字符在 '!'..'u' 或 'z'
            if s and all(("!" <= c <= "u") or c == "z" for c in s):
                a85_parts.append(s)
            else:
                break
    data = base64.a85decode("".join(a85_parts)) if a85_parts else b""
    return iova, data, hist

def u32s(b, off, n):
    # 内核 drm ascii85 按 u32 值编码（组内大端），故按大端解 u32
    return struct.unpack_from(f">{n}I", b, off)

def main(path):
    txt = open(path, encoding="utf-8", errors="replace").read()
    iova, data, hist = extract_section(txt, "gmu-hfi")
    print(f"gmu-hfi: iova={iova:#x} size={len(data)}")
    for i, h in enumerate(hist or []):
        print(f"  queue-history[{i}]: {h.strip()}")

    ver, size, qhdr0, qhdr_size, nq, act = u32s(data, 0, 6)
    print(f"table: ver={ver:#x} size={size} qhdr0={qhdr0} qhdr_size={qhdr_size} queues={nq} active={act}")

    qhdrs = []
    for q in range(nq):
        off = qhdr0 * 4 + q * qhdr_size * 4 if qhdr_size < 64 else qhdr0 + q * qhdr_size
        f = u32s(data, off, 12)
        qhdrs.append(f)
        print(f"queue[{q}]: status={f[0]} iova={f[1]:#x} type={f[2]:#x} size={f[3]} "
              f"msg_size={f[4]} dropped={f[5]} rx_wm={f[6]} tx_wm={f[7]} "
              f"rx_req={f[8]} tx_req={f[9]} read_idx={f[10]} write_idx={f[11]}")

    for q, f in enumerate(qhdrs):
        qiova, qsize_dw, rd, wr = f[1], f[3], f[10], f[11]
        if qiova == 0:
            continue
        off = qiova - iova
        print(f"\n=== queue[{q}] 消息流水 (数据偏移 {off:#x}, {qsize_dw} dwords, rd={rd} wr={wr}) ===")
        idx = 0
        count = 0
        while idx < qsize_dw and count < 80:
            hdr = u32s(data, off + idx * 4, 1)[0]
            if hdr == 0:
                idx += 1
                continue
            mid = hdr & 0xff
            msz = (hdr >> 8) & 0xff
            seq = (hdr >> 20) & 0xfff
            name = MSG_NAMES.get(mid, f"id{mid}")
            payload = u32s(data, off + idx * 4 + 4, min(max(msz - 1, 0), 8)) if msz > 1 else ()
            mark = ""
            if rd <= idx < wr or (wr < rd and (idx >= rd or idx < wr)):
                mark = "  <-- 未消费"
            print(f"  [{idx:5d}] seq={seq:4d} {name:22s} size={msz:3d} "
                  + " ".join(f"{p:#010x}" for p in payload) + mark)
            idx += msz if msz > 0 else 1
            count += 1

if __name__ == "__main__":
    main(sys.argv[1])
