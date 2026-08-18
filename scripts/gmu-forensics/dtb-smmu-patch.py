#!/usr/bin/env python3
"""X4 修复验证：DTB 单字节补丁，破坏 GPU SMMU 的 "qcom,adreno-smmu" compatible。
msm 因此拿不到 adreno_smmu_priv → 退回全局单地址空间 → CP 不再发
CP_SMMU_TABLE_UPDATE。同长度替换（adreno→adrenX），二进制安全。
用法: dtb-smmu-patch.py <in.dtb> <out.dtb> [--revert]
"""
import sys

src, dst = sys.argv[1], sys.argv[2]
revert = "--revert" in sys.argv
data = open(src, "rb").read()
old = b"qcom,adrenX-smmu" if revert else b"qcom,adreno-smmu"
new = b"qcom,adreno-smmu" if revert else b"qcom,adrenX-smmu"
n = data.count(old)
if n == 0:
    print(f"没找到 {old!r}（已是目标状态？）")
    sys.exit(1)
open(dst, "wb").write(data.replace(old, new))
print(f"已替换 {n} 处 {old!r} → {new!r}，写入 {dst}")
