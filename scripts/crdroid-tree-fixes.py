#!/usr/bin/env python3
"""对 crDroid 源码树的本地修补（幂等，可反复跑）。

在构建机上执行：
    python3 <repo>/scripts/crdroid-tree-fixes.py ~/crdroid

—— 修补 1：关掉 SPOOF_SAFETYNET ——

crDroid 在 system/core/init/property_service.cpp 里加了 SetSafetyNetProps()，
在【解析 kernel cmdline 之前】硬写一整张属性表来伪装"已锁定、已验证、user 版"，
好让 Play Integrity 通过。源码注释原话：

    // Report a valid verified boot chain to make Google SafetyNet integrity
    // checks pass. This needs to be done before parsing the kernel cmdline as
    // these properties are read-only and will be set to invalid values with
    // androidboot cmdline arguments.

被它强制的值（2026-08-19 实机 getprop 逐条确认）：
    ro.boot.verifiedbootstate = green      （cmdline 写的是 orange）
    ro.boot.flash.locked      = 1          （cmdline 写的是 0）
    ro.boot.veritymode        = enforcing  （cmdline 写的是 disabled）
    ro.debuggable = 0    ro.adb.secure = 1    ro.secure = 1
    ro.build.type = user   ro.build.tags = release-keys
    ro.crypto.state = encrypted            ro.secureboot.lockstate = locked

对本项目这是致命的：
  * ro.debuggable=0            → adb root / adb remount 全部不可用，
                                 而 M3 部署 turnip 完全依赖 overlayfs remount
  * verifiedbootstate != orange → adb remount 的前提不成立（Stage 5 的运维基础）
  * ro.adb.secure=1            → adb 要授权（可用 PRODUCT_ADB_KEYS 绕开，但治标）
  * 这些值把 WITH_ADB_INSECURE、PRODUCT_SYSTEM_EXT_PROPERTIES、cmdline
    统统盖掉 —— 排查时极具迷惑性，因为产物里的 build.prop 明明是对的。

上游只在 eng 变体里关它（Android.bp 的 product_variables.eng），
但 eng 会关掉 dexpreopt，首次开机全靠 JIT —— 本机跑 swangle 软渲染，
慢到不可接受。所以直接把默认值改成 0。

我们本来就不追求 Play Integrity（这是台开发机），关掉没有副作用。
"""
import io, re, sys, pathlib

def patch_spoof_safetynet(tree: pathlib.Path) -> str:
    p = tree / "system/core/init/Android.bp"
    if not p.exists():
        return f"跳过（找不到 {p}）"
    s = io.open(p, encoding="utf-8").read()
    n = s.count('"-DSPOOF_SAFETYNET=1"')
    if n == 0:
        return "已是 0（幂等，无需改动）" if '"-DSPOOF_SAFETYNET=0"' in s else "⚠️ 找不到 SPOOF_SAFETYNET，上游可能改了写法"
    s = s.replace('"-DSPOOF_SAFETYNET=1"', '"-DSPOOF_SAFETYNET=0"')
    io.open(p, "w", encoding="utf-8", newline="").write(s)
    return f"已把 {n} 处 -DSPOOF_SAFETYNET=1 改为 =0"

def main():
    tree = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else pathlib.Path.home() / "crdroid").expanduser()
    if not (tree / "build/envsetup.sh").exists():
        print(f"✗ {tree} 看起来不是 Android 源码树"); sys.exit(1)
    print(f"树: {tree}")
    print("  [1] SPOOF_SAFETYNET: " + patch_spoof_safetynet(tree))

if __name__ == "__main__":
    main()
