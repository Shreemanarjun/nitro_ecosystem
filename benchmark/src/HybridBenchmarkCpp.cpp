#include "../lib/src/generated/cpp/benchmark_cpp.native.g.h"

#include <string>
#include <chrono>
#include <cstring>
#include <cstdlib>
#include <cstdint>
#include <thread>
#include <atomic>
#include <cmath>

class HybridBenchmarkCppImpl final : public HybridBenchmarkCpp {
public:
    HybridBenchmarkCppImpl() : _running(true) {
        _streamThread = std::thread([this]() {
            double angle = 0;
            auto nextTick = std::chrono::steady_clock::now();
            while (_running) {
                // Precise 60fps timing
                nextTick += std::chrono::microseconds(16666);
                std::this_thread::sleep_until(nextTick);

                if (!_running) break;

                // 1. Stress Test Data (BenchmarkPoint)
                emit_dataStream(BenchmarkPoint{std::sin(angle), std::cos(angle)});

                // 2. Visual Stress Test (BenchmarkBox)
                // Cycle through colors and oscillate size
                uint32_t r = static_cast<uint32_t>((std::sin(angle) + 1.0) * 127);
                uint32_t g = static_cast<uint32_t>((std::sin(angle + 2.0) + 1.0) * 127);
                uint32_t b = static_cast<uint32_t>((std::sin(angle + 4.0) + 1.0) * 127);
                int64_t color = 0xFF000000 | (r << 16) | (g << 8) | b;

                double width = 100.0 + std::sin(angle * 0.5) * 50.0;
                double height = 100.0 + std::cos(angle * 0.5) * 50.0;

                emit_boxStream(BenchmarkBox{color, width, height});

                angle += 0.05;
            }
        });
    }

    ~HybridBenchmarkCppImpl() {
        _running = false;
        if (_streamThread.joinable()) {
            _streamThread.join();
        }
    }

    // ── Sync primitive — baseline C++ dispatch overhead ───────────────────────
    double add(double a, double b) override {
        return a + b;
    }

    double addFast(double a, double b) override {
        return a + b;
    }

    // ── Sync string — measures heap allocation for std::string ────────────────
    std::string getGreeting(const std::string& name) override {
        return "Hello, " + name + "!";
    }

    // ── Sync zero-copy struct — measures struct pass-by-value cost ────────────
    BenchmarkPoint scalePoint(const BenchmarkPoint& point, double factor) override {
        return BenchmarkPoint{point.x * factor, point.y * factor};
    }

    // ── Async @HybridRecord — measures Future + binary-record round-trip ──────
    NitroCppBuffer computeStats(int64_t iterations) override {
        if (iterations <= 0) iterations = 1;

        using Clock = std::chrono::high_resolution_clock;
        double sum = 0.0;
        double minUs = 1e18;
        double maxUs = 0.0;

        for (int64_t i = 0; i < iterations; ++i) {
            auto t0 = Clock::now();
            volatile double r = add(static_cast<double>(i), static_cast<double>(i + 1));
            (void)r;
            auto t1 = Clock::now();
            double us = std::chrono::duration<double, std::micro>(t1 - t0).count();
            sum += us;
            if (us < minUs) minUs = us;
            if (us > maxUs) maxUs = us;
        }

        double meanUs = sum / static_cast<double>(iterations);

        static const int kPayloadSize =
            sizeof(int64_t)  // count
            + sizeof(double) // meanUs
            + sizeof(double) // minUs
            + sizeof(double) // maxUs
            ;
        const int kTotalSize = 4 + kPayloadSize;

        uint8_t* buf = static_cast<uint8_t*>(malloc(kTotalSize));
        if (buf == nullptr) return {nullptr, 0};

        int32_t payloadLen = static_cast<int32_t>(kPayloadSize);
        memcpy(buf, &payloadLen, 4);
        int offset = 4;
        int64_t count = iterations;
        memcpy(buf + offset, &count,   sizeof(count));   offset += sizeof(count);
        memcpy(buf + offset, &meanUs,  sizeof(meanUs));  offset += sizeof(meanUs);
        memcpy(buf + offset, &minUs,   sizeof(minUs));   offset += sizeof(minUs);
        memcpy(buf + offset, &maxUs,   sizeof(maxUs));   offset += sizeof(maxUs);

        return {buf, static_cast<size_t>(kTotalSize)};
    }

    int64_t sendLargeBufferFast(const uint8_t* buffer, size_t buffer_length) override {
        if (!buffer || buffer_length == 0) return 0;

        uint64_t sum = 0;
        // Sample every 4KB page using 8-byte reads.
        // Use memcpy to avoid undefined behaviour on architectures requiring aligned access.
        for (size_t i = 0; i < buffer_length; i += 4096) {
            uint64_t word = 0;
            memcpy(&word, buffer + i, sizeof(word));
            sum += word;
        }

        // Return a representation of work done to prevent DCE
        return static_cast<int64_t>(sum == 0 ? buffer_length : buffer_length + 1);
    }

    int64_t sendLargeBufferNoop(const uint8_t* buffer, size_t buffer_length) override {
        // Return immediately to measure pure dispatch overhead (NO checksum loop).
        return static_cast<int64_t>(buffer_length);
    }

    int64_t sendLargeBufferNoopFast(const uint8_t* buffer, size_t buffer_length) override {
        // Absolute floor: No-op leaf call.
        return static_cast<int64_t>(buffer_length);
    }

    int64_t sendLargeBufferUnsafe(void* buffer, int64_t buffer_length) override {
        // Bypasses pinning cost — matches Raw FFI theoretical performance.
        return static_cast<int64_t>(buffer_length);
    }

private:
    std::thread _streamThread;
    std::atomic<bool> _running;
};

static HybridBenchmarkCppImpl g_benchmark_cpp_impl;

__attribute__((constructor))
static void benchmark_cpp_auto_register() {
    benchmark_cpp_register_impl(&g_benchmark_cpp_impl);
}
