# SSC 客户端 —— 从 Android 侧读 SLPI 上的传感器

这台机器**没有任何 AP 侧传感器芯片驱动**：加速度计、陀螺仪、光感、铰链角
全部跑在 SLPI DSP 上，AP 够不着那些总线。可行的通路是反过来 ——
AP 用 FastRPC 给 DSP 当只读文件服务器（`hexagonrpcd`），DSP 起 SSC，
再由 QRTR 上的 QMI 服务 400 把读数送回来。

背景与全部踩坑见 `docs/stage4-findings.md` #37；
**协议规格（含每条事实的来源文件与行号）见 `docs/sensors-ssc-protocol.md`。**

## 为什么不用 libssc

`libssc` 依赖 glib / gio / gobject / **qmi-glib(libqmi)** / libprotobuf-c，
整套 GLib 栈搬不进 Android。但它的协议逻辑很薄，`.proto` 只有几百行，
而 AOSP 自带 `protoc` 与 `libprotobuf-cpp-lite` —— 照规格重写比移植依赖便宜。

## 内容

| 文件 | 作用 |
|---|---|
| `ssc_client.{h,cpp}` | 可复用客户端：QRTR lookup → QMI 组包/解包 → protobuf。**将来的 AIDL HAL 直接链 `libgaokun3ssc`** |
| `ssc_test.cpp` | 命令行验证工具 `gaokun3-ssc-test`，对标 Linux 上的 `ssccli` |
| `ssc-*.proto` | 取自 libssc 原文（GPL-3.0，保留其版权头）|

## 实测结果（2026-08-20，Android，slot _a）

```
$ gaokun3-ssc-test accel 10 8
SSC 服务 400 在 node 9 port 13
传感器 accel 的 UID = 61ab5376b4a5c9aa58442ede47acd316
  X=-0.086191 Y= 0.052672 Z= 9.883265  accuracy=3
```

| data_type | 结果 |
|---|---|
| `accel` | ✅ Z≈9.88 m/s²（重力），accuracy=3 |
| `gyro` | ✅ 静止时各轴 ≈0 rad/s，accuracy=3。★Linux 侧从未验证过（那边的 `ssccli` 不支持）|
| `mag` | ❌ SSC 明确回答"没有传感器提供" —— **本机没有磁力计**，所以没有指南针 |
| `rotv` | ❌ 未注册（配置里有 `sns_rotv.json`，但融合旋转矢量多半需要磁力计）|
| `ambient_light` | ❌ **别碰**：使能后从不返回读数，且会污染整个 SSC 会话 —— 之后连加速度计也读不到，必须重启 hexagonrpcd |

⚠️ `mag`/`rotv` 那两次"找不到"**不会**污染会话（回读 accel 正常），
与 `ambient_light` 的行为不同。

## 用法

```sh
# 前提：hexagonrpcd 在跑
gaokun3-qrtr-lookup 400        # 先确认服务在
gaokun3-ssc-test               # 默认 accel 10 Hz 10 秒
gaokun3-ssc-test gyro 20 5
```

⚠️ **需要沉降时间**：hexagonrpcd 刚起来时 SSC 约需 20 秒才出数，
所以本工具的等待窗口给到 40 秒。**"读不到"不等于"坏了"。**

## 构建上的两个坑（都踩过）

1. `proto: { canonical_path_from_root: false }` **必须加**，否则生成的头文件是
   `device/huawei/gaokun3/ssc/xxx.pb.h`，而 `.proto` 之间的
   `import "ssc-common.proto"` 也解析不了。
2. protobuf **静态链接**，不用 `shared_libs`：`libprotobuf-cpp-lite.so`
   只在 `/system/lib64`（而且文件名带版本号
   `libprotobuf-cpp-lite-4.25.8.so`），vendor 二进制走 vendor 链接命名空间
   看不见它 —— 和 CLAUDE.md 里 `tinymix`/`libtinyalsa` 是同一个坑。
   ★ 静态 protobuf 引用 `__android_log_write`，所以还要补 `shared_libs: ["liblog"]`，
   否则链接期 `undefined symbol`。

## 还差什么

⬜ **AIDL `android.hardware.sensors` HAL** —— 把 `libgaokun3ssc` 包起来喂
SensorService，自动旋转才会真的生效。要处理的额外问题：
* **安装矩阵全零**（出厂校准随 Windows 永久丢失）→ 轴向可能要在 HAL 里硬编纠正，
  得实机对着屏幕方向标定一次。
* 采样率/batching/flush 的语义映射。
* sepolicy（当前 SELinux permissive，转 enforcing 前必须补）。
