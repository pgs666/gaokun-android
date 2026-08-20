/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
#include "SscHub.h"

#include <android-base/logging.h>

#include <vector>

#include "ssc-sensor-accelerometer.pb.h"

namespace gaokun3 {
namespace {
// 50 Hz 足够自动旋转与体感；SSC 会给出它实际采用的速率。
constexpr float kRateHz = 50.0f;
// hexagonrpcd 刚起来时 SSC 约需 20 秒沉降，给足余量（实测 6 秒读不到）。
constexpr int kServiceWaitMs = 60000;
}  // namespace

SscHub& SscHub::Get() {
    static SscHub instance;
    return instance;
}

void SscHub::EnsureStarted() {
    std::call_once(started_, [this]() {
        thread_ = std::thread([this]() { ReaderLoop(); });
    });
}

Sample SscHub::Accel() {
    EnsureStarted();
    std::lock_guard<std::mutex> lk(m_);
    return accel_;
}

Sample SscHub::Gyro() {
    EnsureStarted();
    std::lock_guard<std::mutex> lk(m_);
    return gyro_;
}

void SscHub::ReaderLoop() {
    while (!stop_) {
        SscClient client;
        std::string err;

        if (!client.Open(&err)) {
            LOG(ERROR) << "SscHub: 打开 SSC 失败: " << err;
            std::this_thread::sleep_for(std::chrono::seconds(5));
            continue;
        }
        if (!client.WaitForService(kServiceWaitMs, &err)) {
            LOG(ERROR) << "SscHub: SSC 未就绪: " << err;
            std::this_thread::sleep_for(std::chrono::seconds(5));
            continue;
        }
        LOG(INFO) << "SscHub: SSC 就绪，服务在 node " << client.service_node()
                  << " port " << client.service_port();

        // ★★ 物理传感器比 registry 服务【晚】注册，所以刚就绪时查 accel 会
        //    得到"没有传感器提供"。必须在【同一个 client 上】重试等它出现。
        //    ⚠️ 千万不要为此重建会话：每次重建都在 SSC 上留下一个被丢弃的
        //    客户端，实测那种 churn 会把传感器枚举彻底弄坏 —— 之后连独立
        //    命令行客户端都找不到 accel，必须重启 hexagonrpcd 才恢复。
        //    这是 2026-08-20 实测定位到的真实故障，不是防御性编程。
        //
        //    本机只有这两个可用：mag 没有硬件、rotv 未注册，
        //    ambient_light 一使能就污染会话（#37），所以坚决不碰。
        SscUid accel_uid, gyro_uid;
        bool has_accel = false, has_gyro = false;
        for (int round = 0; round < 30 && !stop_; round++) {
            if (!has_accel) has_accel = client.FindSensor("accel", &accel_uid, &err);
            if (!has_gyro) has_gyro = client.FindSensor("gyro", &gyro_uid, &err);
            if (has_accel && has_gyro) break;
            std::this_thread::sleep_for(std::chrono::seconds(2));
        }
        if (!has_accel && !has_gyro) {
            LOG(ERROR) << "SscHub: 等了 60 秒仍没有任何传感器注册，重建会话";
            std::this_thread::sleep_for(std::chrono::seconds(30));
            continue;
        }
        LOG(INFO) << "SscHub: accel=" << has_accel << " gyro=" << has_gyro;

        if (has_accel) client.EnableContinuous(accel_uid, kRateHz, &err);
        if (has_gyro) client.EnableContinuous(gyro_uid, kRateHz, &err);

        // 收数。连续空转说明会话坏了（例如别的进程去碰了光感）。
        // 先在同一个 client 上重新使能一次，还是不行才整条重建 —— 同样是为了
        // 少制造客户端 churn。
        int idle = 0;
        bool re_enabled = false;
        while (!stop_) {
            std::vector<SscReport> reports;
            std::string ignore;
            if (!client.ReadReports(&reports, 1000, &ignore)) {
                if (++idle == 15 && !re_enabled) {
                    LOG(WARNING) << "SscHub: 15 秒无读数，在同一会话上重新使能";
                    if (has_accel) client.EnableContinuous(accel_uid, kRateHz, &err);
                    if (has_gyro) client.EnableContinuous(gyro_uid, kRateHz, &err);
                    re_enabled = true;
                    continue;
                }
                if (idle >= 60) break;   // 真的坏了，重建
                continue;
            }
            idle = 0;
            re_enabled = false;
            for (size_t i = 0; i < reports.size(); i++) {
                const SscReport& r = reports[i];
                if (r.msg_id != kMsgReportMeasurement) continue;
                SscAccelerometerResponse m;
                if (!m.ParseFromString(r.payload)) continue;
                if (m.acceleration_size() < 3) continue;

                Sample s;
                s.v[0] = m.acceleration(0);
                s.v[1] = m.acceleration(1);
                s.v[2] = m.acceleration(2);
                s.accuracy = m.accuracy();
                s.valid = true;

                std::lock_guard<std::mutex> lk(m_);
                if (has_accel && r.uid_low == accel_uid.low() &&
                    r.uid_high == accel_uid.high()) {
                    accel_ = s;
                } else if (has_gyro && r.uid_low == gyro_uid.low() &&
                           r.uid_high == gyro_uid.high()) {
                    gyro_ = s;
                }
            }
        }
        if (has_accel) client.Disable(accel_uid, &err);
        if (has_gyro) client.Disable(gyro_uid, &err);
        LOG(WARNING) << "SscHub: 60 秒没有读数，重建 SSC 会话";
    }
}

}  // namespace gaokun3
