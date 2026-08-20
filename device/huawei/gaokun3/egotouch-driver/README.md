# EGoTouchRev-Linux Himax HX83121A 触控驱动

本目录存放从本地 `/home/user/Project/EGoTouchRev-Linux` 复制而来的 Himax HX83121A SPI 触控驱动源码，用于在 GitHub Actions 中重编 Android 内核时使用。

来源：
- 本地路径：`/home/user/Project/EGoTouchRev-Linux/touchscreen-hx83121a-dkms/`
- 上游仓库：`https://github.com/pgs666/EGoTouchRev-Linux`
- 分支：`windows-v1.1.2-port`
- 当前提交：`03ffefe fix: stabilize touch tracking and DKMS deployment`

许可证：GPL-2.0（与上游 EGoTouchRev-Linux 一致）。

为什么要复制进 gaokun-android：
- 确保 GitHub Actions 构建使用的是本机这个确切版本，而不是某个可能与本地有差异的远程分支。
- 避免依赖私有或可能不可达的远程仓库。
- 让这次内核替换可 reproducible：gaokun-android 的一个 commit 就包含了全部所需源码。

文件：
- `himax-spi-core.c`：SPI 通信、固件初始化、电源管理、输入上报
- `hx-algo.c` / `hx-algo.h`：触控算法流水线
- `hx-frame-status.h`：帧状态解析
