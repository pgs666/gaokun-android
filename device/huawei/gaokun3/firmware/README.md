# 固件获取（blob 不进版本库）

`.gitignore` 把本目录**整个**忽略掉，只放行这份 README。
换机器 / 重建工作区时按下面任一条恢复。

## 最快的恢复办法：从一台还能开机的本机 Android 上 adb pull

`/vendor/firmware/` 里就是构建时装进去的全套（2026-08-19 实测 23 个文件）：

```bash
adb pull /vendor/firmware /tmp/fw
cp -r /tmp/fw/firmware/* device/huawei/gaokun3/firmware/
```

⚠️ 拉回来会多一个 `qcom/sc8280xp/SC8280XP-HUAWEI-GAOKUN3-tplg.bin` ——
它和 `HUAWEI/gaokun3/audioreach-tplg.bin` 内容完全相同（同 sha256，24296 字节），
`device.mk` 用同一个源文件装两个路径，所以**这份多出来的可以删掉**。

若设备已经刷成别的 ROM，就从跑主线 Linux 的本机 `/lib/firmware/` 里取（下表"来源"列）。

## 清单

| 文件 | 用途 | 缺了会怎样 | 来源 |
|---|---|---|---|
| `qcom/a660_sqe.fw`<br>`qcom/a660_gmu.bin` | GPU (Adreno 690) 微码 | GPU 不 probe | linux-firmware ≥ 20241210 |
| `qcom/sc8280xp/HUAWEI/gaokun3/qcdxkmsuc8280.mbn` | GPU **zap shader** | GPU 锁在安全模式，`adreno_zap_shader_load` 报错 | **华为专有** |
| `qca/wcnhpbtfw21.tlv`<br>`qca/wcnhpnv21g.bin` | 蓝牙 WCN6855 | 蓝牙不起 | linux-firmware ≥ 20241210 |
| `ath11k/WCN6855/hw2.0/{amss,board-2,m3,regdb}.bin` | WiFi | 无 WiFi | linux-firmware ≥ 20241210（上游把 hw2.1 软链到 hw2.0；`device.mk` 把同一份装到两个路径） |
| `qcom/sc8280xp/HUAWEI/gaokun3/qcadsp8280.mbn`<br>`qccdsp8280.mbn`<br>`qcslpi8280.mbn` | ADSP / CDSP / SLPI | 音频、传感器全无 | **华为专有** |
| `qcom/sc8280xp/HUAWEI/gaokun3/audioreach-tplg.bin` | 音频**拓扑** | **声卡不注册** | **华为专有** |
| `qcom/sc8280xp/HUAWEI/gaokun3/qcvss8280.mbn` | 语音服务 | （未用到，一并带上） | **华为专有** |
| `qcom/sc8280xp/HUAWEI/gaokun3/{adspr,adspua,battmgr,cdspr}.jsn` | pd_mapper 服务表 | remoteproc 域映射缺失 | **华为专有** |

华为专有那几个不在 linux-firmware 里，从跑主线 Linux 的本机
`/lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/` 直接拷，
或从 Windows 驱动包（`uup-drivers-sc8280xp`）提取。**不可公开再分发。**

## 放置规则

保持本目录下相同的子路径结构（cmdline 里 `firmware_class.path=/vendor/firmware/`）。
实测加载路径见 `docs/hw-inventory.md` 第 2 节。

★ **拓扑固件的名字有坑**：内核请求的是
`qcom/<card->driver_name>/<card->name>-tplg.bin`
（`sound/soc/qcom/qdsp6/topology.c:1320`），本机 =
`qcom/sc8280xp/SC8280XP-HUAWEI-GAOKUN3-tplg.bin`。
老规矩的 `HUAWEI/gaokun3/audioreach-tplg.bin` **内核从不去读**。
`device.mk` 两个路径都装。详见 `docs/stage4-findings.md` #33。
