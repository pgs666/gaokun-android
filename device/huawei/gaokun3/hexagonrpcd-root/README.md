# 传感器 VFS 根（hexagonrpcd 喂给 SLPI DSP 的文件）

`.gitignore` 把本目录**整个**忽略，只放行这份 README。

这些文件不是给 CPU 用的 —— 它们由 `hexagonrpcd` 通过 FastRPC **服务给 SLPI
上的 DSP 读**。AP 侧没有任何到传感器芯片的总线，整套传感器跑在 SLPI 上，
所以 AP 的角色是**只读文件服务器**。原理与全部踩坑见
`docs/stage4-findings.md` #37。

装到设备上的路径是 `/vendor/etc/hexagonrpcd-root/`
（由上游自带的 `hexagonrpcd-sdsp.rc` 用 `-R` 指定）。

## 需要的布局

```
sensors/config/*.json     26 个，SEE 传感器驱动配置
sensors/sns_reg.conf      DSP 注册表索引。★必须是【文本格式】约 400 B，
                          开头是 version=1。用 DriverData 的 JSON 格式
                          （2423 B）会让 DSP 注册表初始化崩溃
dsp/sdsp/RSCS.bin         1340 B，SLPI 伴生固件
socinfo/{hw_platform,platform_subtype,platform_subtype_id,
         platform_version,soc_id,revision}
```

`sensors/registry/registry` **不在本目录** —— 它是个 0 字节文件，
放在 `../etc/hexagonrpcd-empty-registry` 受版本控制。
★ **它必须是空的**：DSP 找不到覆盖值就用默认值（= 全部传感器启用）。
⚠️ **别用 `sscregistrygen` 预生成注册表** —— 实测生成 142 个文件后加速度计
一起坏掉，挪走只留空 registry 当场恢复（干净 A/B，见 #37）。

## 怎么取（不需要机器上还留着 Windows）

全部来自公开源，与 `../firmware/README.md` 同一个 release：

```bash
curl -LO https://github.com/matebook-e-go/uup-drivers-sc8280xp/releases/download/200.0.10.0/200.0.10.0.zip
unzip -o 200.0.10.0.zip 'qc*.cab'
# .cab 用 cabextract（Linux）或 Windows 自带 expand.exe -F:* x.cab 目标目录
```

| 需要的 | 出自哪个 cab |
|---|---|
| 传感器全套 JSON、`sns_reg_config`、socinfo 原件 | `qcSensorsConfigQrd8280.cab` |
| `RSCS.bin` | `qcsubsys_ext_scss8280.cab`（SCSS = Sensor Core SubSystem）|

取回后要做两件事：

1. **`dos2unix`** —— JSON 是从 Windows 来的 CRLF。
2. `sns_reg_config` 改名成 `sensors/sns_reg.conf`。

## ⚠️ 不需要做的事

贡献者的 Linux 部署指南在 `socinfo/` 下建了 6 个**带尾随 `\r`** 的 symlink
（DSP 固件在 Windows 上编译，请求的路径每段都带 CR）。
**本仓实测证明那是多余的**：`\r` 截断补丁打在 `copy_segment_and_advance()`
里，那是通用分段解析函数，清理后的 segment 才分派给各后端
（`hexagonfs.c:179`），物理目录后端同样受益。移走 6 个 symlink 后加速度计
照样 Z≈9.86 正常读数。

★ 这条正是 Android 侧能用普通 `PRODUCT_COPY_FILES` 的前提 ——
构建系统造不出带控制字符的文件名。
