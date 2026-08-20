<!--
  ★ 这份文档是外部贡献，原样保留（只加了这段抬头）。

  它推翻了本仓 docs/stage4-findings.md #37 原先的结论
  （我曾判定"传感器在主线上不可达"）。修正说明见 #37 开头。

  它针对的是【Linux 侧】。本机的 Android 侧还缺一个 sensors HAL，
  见 #37 末尾的「落地路线」。

  ══ 2026-08-20 本仓在真机上逐条复现的结果（详见 #37 的「实测结果」段）══

  ✅ 加速度计跑通了：静止时 Z≈9.87 m/s²，15 秒 131 行读数。
     整条通路 fastrpc → hexagonfs → DSP 注册表 → SSC → QMI → libssc 全部验证。
     一键复现脚本：scripts/slpi-sensors-setup.sh

  ✅ Phase 0 的前提：/dev/fastrpc-sdsp 原先不存在，因为 CONFIG_QCOM_FASTRPC=m
     而那棵树不发模块；insmod fastrpc.ko 后四个节点全出现。
  ✅ Phase 4 原先的硬阻塞（要 Windows DriverStore）已解除 —— 全部文件可从
     公开的 uup-drivers-sc8280xp release 提取，不需要 Windows 分区。
     ★ cab 里的 qcslpi8280.mbn 与本仓在用的那份 sha256 逐字节相同。
  ✅ Phase 3 的 socinfo 取值（QRD / 449 …）与内核 /sys/devices/soc0/soc_id
     和 JSON 里的 soc_id 三方一致。

  ⚠️ Phase 7 有出入：上游已删掉 -Dmocking 选项，照抄会报 "Unknown option"。
     直接 meson setup build 即可。
  ⚠️ Phase 8 之后需要【沉降时间】：重启后 6 秒就读实测是 0 行，等约 20 秒才有。
     "读不到"不等于"坏了"。

  ❌ Phase 9 的 light 在本机不成立：使能后从不返回读数，而且会污染整个 SSC
     会话（之后连加速度计也读不到，必须重启 hexagonrpcd）。gyroscope 也测不了 ——
     当前 ssccli 只支持 proximity/light/accelerometer/magnetometer/compass。
  ❌ Phase 10 在本机【永久做不了】：出厂校准存在本机 Windows 的 DriverData 里，
     不在任何驱动包中，而本机 Windows 已于 2026-08-20 抹除。
     后果是安装矩阵全零（libssc 退回单位矩阵），轴向可能需上层纠正。
     ★ 给还留着 Windows 的人：先把那个 registry 目录拷出来再装系统。
  ❌ 顺带一条负面结果：不要用 hexagonrpcd 自带的 sscregistrygen 预生成注册表
     —— 实测生成 142 个文件后加速度计一起坏掉，挪走即恢复。空 registry 才对。
-->

# Gaokun3 SLPI 传感器手动部署指南

**前提**: SLPI DSP running, `/dev/fastrpc-sdsp` 存在, Windows 分区已挂载, QRTR Service 400 在线.

---

## Phase 1 — 系统依赖

编译 hexagonrpcd/libssc 的工具链和调试工具.

```bash
sudo apt install -y meson ninja-build git libglib2.0-dev libqmi-glib-dev \
  libprotobuf-c-dev libqrtr-glib-dev libjson-c-dev protobuf-c-compiler \
  protobuf-compiler qrtr-tools dos2unix python3-dev hexagonrpcd strace
```

---

## Phase 2 — systemd override

绕过有 bug 的 shell wrapper (不认 sc8280xp, fallback 到错误 DSP).
`-f sdsp` = SLPI 设备, `-s` = 传感器模式, `-R` = VFS 根目录.
`ExecStart=` 空值清掉原无参版本.

```bash
sudo mkdir -p /etc/systemd/system/hexagonrpcd.service.d
cat | sudo tee /etc/systemd/system/hexagonrpcd.service.d/override.conf << 'EOF'
[Service]
ExecStart=
ExecStart=/usr/bin/hexagonrpcd -f /dev/fastrpc-sdsp -d sdsp -s -R /usr/share/qcom/sc8280xp/HUAWEI/GAOKUN3
ProtectSystem=full
ReadWritePaths=/var/lib/hexagonrpc
EOF
sudo systemctl daemon-reload
sudo systemctl disable --now droid-juicer 2>/dev/null; sudo systemctl mask droid-juicer 2>/dev/null
```

---

## Phase 3 — 目录 + socinfo + `\r` symlink

DSP 固件 (Windows 编译) 请求的路径带 `\r` 后缀.
socinfo 走物理文件系统 → symlink 让内核把 `hw_platform\r` 映射到 `hw_platform`.

```bash
P=/usr/share/qcom/sc8280xp/HUAWEI/GAOKUN3
sudo mkdir -p $P/{sensors/config,sensors/registry,acdb,dsp/sdsp,socinfo}

echo "QRD"     | sudo tee $P/socinfo/hw_platform
echo "Unknown" | sudo tee $P/socinfo/platform_subtype
echo "0"       | sudo tee $P/socinfo/platform_subtype_id
echo "65536"   | sudo tee $P/socinfo/platform_version
echo "449"     | sudo tee $P/socinfo/soc_id
echo "3.1"     | sudo tee $P/socinfo/revision

for f in hw_platform platform_subtype platform_subtype_id \
         platform_version soc_id revision; do
    sudo ln -sf "$f" "$P/socinfo/${f}"$'\r'
done
```

---

## Phase 4 — 传感器文件

从 Windows DriverStore 拷贝出厂配置. **sns_reg.conf 必须用 DriverStore 文本格式 (407B),
不能用 DriverData JSON 格式 (2423B)** — 后者导致 DSP 注册表初始化崩溃.

```bash
WIN=/run/media/user/Windows/Windows/System32/drivers
DS=$(find $WIN/DriverStore/FileRepository -maxdepth 1 -type d \
     -iname "qcsensorsconfigqrd8280*" | head -1)

# JSON 传感器驱动配置
sudo cp "$DS"/*.json $P/sensors/config/

# DSP 注册表索引 (文本格式: version=1, file=config=...)
sudo cp "$DS/sns_reg_config" $P/sensors/sns_reg.conf

# SLPI 伴生固件
sudo cp "$DS/RSCS.bin" $P/dsp/sdsp/

# 空 registry — DSP 找不到覆盖值时用默认值: 全部传感器启用
sudo touch $P/sensors/registry/registry
```

---

## Phase 5 — 编译 hexagonrpcd (`\r` strip patch)

socinfo 的 `\r` symlink 对 registry 路径无效 (走 hexagonfs 内部 VFS, 不经过内核 symlink 解析).
必须改 hexagonfs.c 的路径解析函数, 在每段末尾截掉 `\r`.
**仅此一个补丁. apt stock 版本不带此补丁, 必须编译.**

```bash
git clone https://github.com/linux-msm/hexagonrpc.git ~/project/hexagonrpc
cd ~/project/hexagonrpc

sed -i '/segment\[segment_len\] = 0;/a\
    if (segment_len > 0 \&\& segment[segment_len - 1] == '"'"'\\r'"'"') segment[--segment_len] = 0;' \
    hexagonrpcd/hexagonfs.c

meson setup build --wipe -Dhexagonrpcd_verbose=false
ninja -C build
sudo cp build/hexagonrpcd/hexagonrpcd /usr/libexec/hexagonrpc/hexagonrpcd
```

---

## Phase 6 — dos2unix + 权限

JSON 配置文件从 Windows 拷贝, 内容是 CRLF (`\r\n`). dos2unix 转为 LF.
hexagonrpcd 以 fastrpc 用户运行, 需要读权限.

```bash
sudo find $P -type f -exec dos2unix {} \; 2>/dev/null
sudo chown -R fastrpc:fastrpc $P
sudo mkdir -p /var/lib/hexagonrpc/persist/sensors/registry
sudo chown -R fastrpc:fastrpc /var/lib/hexagonrpc
```

---

## Phase 7 — 编译 libssc

slpi → QRTR → hexagonrpcd → libssc → ssccli.
libssc 解码 QMI protobuf, 输出传感器读数.

```bash
git clone https://codeberg.org/dylanvanassche/libssc.git ~/project/libssc
cd ~/project/libssc
meson setup build -Dmocking=disabled && ninja -C build && sudo ninja -C build install
sudo ldconfig
```

---

## Phase 8 — 启动

```bash
sudo systemctl start hexagonrpcd && sleep 5
systemctl status hexagonrpcd --no-pager
```

---

## Phase 9 — 测试

三个传感器应该在空 registry 下全部可用 (DSP 默认值 = 全部启用).

```bash
ssccli --sensor light          # 应返回 lux 值
ssccli --sensor accelerometer  # Z ≈ 9.78 m/s²
ssccli --sensor gyroscope      # ~0.01 rad/s
```

---

## Phase 10 — 校准数据（可选）

选择性导入 Windows 出厂校准, 跳过含 `"data":"0"` 的文件 (禁用标记).
导入后读数更精准 (accel bias, gyro bias 等).

```bash
SRC=$WIN/DriverData/Qualcomm/fastRPC/persist/sensors/registry/registry
for f in "$SRC"/*; do
    grep -q '"data":"0"' "$f" 2>/dev/null && continue
    sudo cp "$f" $P/sensors/registry/
done
sudo systemctl restart hexagonrpcd
```

---

## 故障排查

```bash
systemctl status hexagonrpcd --no-pager -l     # 服务状态
sudo strace -f -e openat -p $(pgrep -f hexagonrpc) 2>&1 | head -30  # 看 DSP 在请求什么文件
qrtr-lookup | grep 400                                   # QRTR 服务在不在
G_MESSAGES_DEBUG=all ssccli --sensor light 2>&1 | head -20  # libssc 详细日志
cat $P/sensors/sns_reg.conf | head -3                    # 确认文本格式 (version=1)
stat -c%s $P/sensors/sns_reg.conf                        # 应 <500B
```
