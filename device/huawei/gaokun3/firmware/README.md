# 固件获取（blob 不进版本库）

| 文件 | 来源 |
|---|---|
| `qcom/a660_sqe.fw`, `qcom/a660_gmu.bin` | linux-firmware >= 20241210 |
| `qca/wcnhpbtfw21.tlv`, `qca/wcnhpnv21g.bin` | linux-firmware >= 20241210 |
| `qcom/sc8280xp/HUAWEI/gaokun3/qc{a,c}dsp8280.mbn`, `qcslpi8280.mbn` | **华为专有**，不在 linux-firmware。从跑主线 Linux 的本机 `/lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/` 直接拷，或从 Windows 驱动包（uup-drivers-sc8280xp）提取 |

放置时保持本目录下相同的子路径结构（`firmware_class.path=/vendor/firmware/`）。
实测加载路径见 `docs/hw-inventory.md` 第 2 节。
