/*
 * gaokun3-ssc-test —— 从 Android 侧直接读 SLPI 传感器
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * 对标 Linux 上的 ssccli。存在的意义：它验证的正是将来 sensors HAL 逻辑的
 * 90%（SUID 查找 → 使能 → 解读数），但不牵扯 AIDL、不牵扯 SensorService，
 * 失败时容易定位。
 *
 * 前提：hexagonrpcd 在跑（否则 QRTR 上没有服务 400）。
 *   /vendor/bin/hexagonrpcd -f /dev/fastrpc-sdsp -d sdsp -s -R /vendor/etc/hexagonrpcd-root
 *
 * 用法：
 *   gaokun3-ssc-test                     读加速度计 10 Hz 10 秒
 *   gaokun3-ssc-test accel 20 5          指定 data_type / 采样率 / 秒数
 *   gaokun3-ssc-test gyro
 * data_type 可用值见 docs/sensors-ssc-protocol.md（accel / gyro / mag /
 * ambient_light / proximity / rotv）。
 *
 * ⚠️ 别用 ambient_light：实测使能它之后从不返回读数，而且会污染整个 SSC
 *    会话——之后连加速度计也读不到，必须重启 hexagonrpcd（stage4-findings #37）。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <string>
#include <vector>

#include "ssc_client.h"
#include "ssc-sensor-accelerometer.pb.h"

using gaokun3::SscClient;
using gaokun3::SscReport;

static int64_t NowMs() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return static_cast<int64_t>(ts.tv_sec) * 1000 + ts.tv_nsec / 1000000;
}

int main(int argc, char** argv) {
    const std::string data_type = (argc > 1) ? argv[1] : "accel";
    const float rate_hz = (argc > 2) ? strtof(argv[2], nullptr) : 10.0f;
    const int seconds = (argc > 3) ? atoi(argv[3]) : 10;

    SscClient client;
    std::string err;

    if (!client.Open(&err)) {
        fprintf(stderr, "打开失败: %s\n", err.c_str());
        return 1;
    }
    printf("SSC 服务 400 在 node %u port %u\n", client.service_node(),
           client.service_port());

    // hexagonrpcd 刚起来时 SSC 要沉降约 20 秒，给足 40 秒
    printf("等 SSC 就绪（最多 40 秒，刚重启过 hexagonrpcd 时确实要等）…\n");
    if (!client.WaitForService(40000, &err)) {
        fprintf(stderr, "SSC 没就绪: %s\n", err.c_str());
        return 1;
    }
    printf("SSC 已就绪\n");

    SscUid uid;
    if (!client.FindSensor(data_type, &uid, &err)) {
        fprintf(stderr, "找不到传感器 %s: %s\n", data_type.c_str(), err.c_str());
        return 1;
    }
    printf("传感器 %s 的 UID = %016llx%016llx\n", data_type.c_str(),
           static_cast<unsigned long long>(uid.high()),
           static_cast<unsigned long long>(uid.low()));

    if (!client.EnableContinuous(uid, rate_hz, &err)) {
        fprintf(stderr, "使能失败: %s\n", err.c_str());
        return 1;
    }
    printf("已请求 %.1f Hz 连续上报，收 %d 秒\n", rate_hz, seconds);

    const int64_t deadline = NowMs() + seconds * 1000;
    int n_meas = 0, n_other = 0;
    while (NowMs() < deadline) {
        std::vector<SscReport> reports;
        std::string ignore;
        if (!client.ReadReports(&reports, 1000, &ignore)) continue;
        for (size_t i = 0; i < reports.size(); i++) {
            const SscReport& r = reports[i];
            if (r.msg_id != gaokun3::kMsgReportMeasurement) {
                n_other++;
                continue;
            }
            n_meas++;
            if (data_type == "accel" || data_type == "gyro" ||
                data_type == "mag") {
                // 这三个的载荷布局相同：repeated float + accuracy
                SscAccelerometerResponse m;
                if (!m.ParseFromString(r.payload)) {
                    printf("  [解析失败，%zu 字节]\n", r.payload.size());
                    continue;
                }
                if (m.acceleration_size() >= 3) {
                    printf("  X=%9.6f Y=%9.6f Z=%9.6f  accuracy=%d\n",
                           m.acceleration(0), m.acceleration(1),
                           m.acceleration(2), m.accuracy());
                } else {
                    printf("  [只有 %d 个分量]\n", m.acceleration_size());
                }
            } else {
                printf("  msg_id=%u  %zu 字节\n", r.msg_id, r.payload.size());
            }
        }
    }

    client.Disable(uid, &err);
    printf("\n共 %d 条测量、%d 条其它消息\n", n_meas, n_other);
    if (n_meas == 0) {
        fprintf(stderr,
                "一条读数都没有。排查顺序：\n"
                "  1) gaokun3-qrtr-lookup 400 —— 服务还在吗\n"
                "  2) hexagonrpcd 的日志里 DSP 还在请求文件吗\n"
                "  3) 之前是不是试过 ambient_light？它会污染整个会话，"
                "重启 hexagonrpcd 再等 20 秒\n");
        return 2;
    }
    // 静止平放时加速度计 Z 应该 ≈ 9.8 m/s²，这是整条通路的硬判据
    return 0;
}
