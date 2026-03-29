// Direct C++ implementation of BenchmarkCpp.
// Auto-registered at shared library load via __attribute__((constructor)).
// This is the "NativeImpl.cpp" benchmark path — no JNI, no Swift, pure C++ dispatch.
#include "../lib/src/generated/cpp/benchmark_cpp.native.g.h"

#include <string>
#include <chrono>
#include <cstring>
#include <cstdlib>
#include <cstdint>

class HybridBenchmarkCppImpl final : public HybridBenchmarkCpp {
public:
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
    // BenchmarkPoint is a packed C struct passed as const ref at C++ boundary.
    BenchmarkPoint scalePoint(const BenchmarkPoint& point, double factor) override {
        return BenchmarkPoint{point.x * factor, point.y * factor};
    }

    // ── Async returning @HybridRecord — measures Future + binary-record round-trip ──
    // Returns a NitroCppBuffer (pointer + size) that the bridge encodes back to Dart
    // as a BenchmarkStats value via the binary record protocol.
    NitroCppBuffer computeStats(int64_t iterations) override {
        if (iterations <= 0) iterations = 1;

        // Run `iterations` add() calls and collect timing statistics.
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

        // Encode BenchmarkStats as binary record: [4-byte length][int64 count][double mean][double min][double max]
        // Layout matches the @HybridRecord field declaration order (little-endian).
        static const int kFieldCount = 4;
        static const int kPayloadSize =
            sizeof(int64_t)  // count
            + sizeof(double) // meanUs
            + sizeof(double) // minUs
            + sizeof(double) // maxUs
            ;
        const int kTotalSize = 4 + kPayloadSize; // 4-byte length prefix

        uint8_t* buf = static_cast<uint8_t*>(malloc(kTotalSize));
        if (buf == nullptr) {
            return NitroCppBuffer{nullptr, 0}; // OOM — bridge returns nullptr to Dart
        }
        int32_t payloadLen = static_cast<int32_t>(kPayloadSize);
        // Write length prefix (little-endian int32)
        memcpy(buf, &payloadLen, 4);
        int offset = 4;
        // Write fields in declaration order
        int64_t count = iterations;
        memcpy(buf + offset, &count,   sizeof(count));   offset += sizeof(count);
        memcpy(buf + offset, &meanUs,  sizeof(meanUs));  offset += sizeof(meanUs);
        memcpy(buf + offset, &minUs,   sizeof(minUs));   offset += sizeof(minUs);
        memcpy(buf + offset, &maxUs,   sizeof(maxUs));   offset += sizeof(maxUs);

        return NitroCppBuffer{buf, static_cast<size_t>(kTotalSize)};
    }

    // ── dataStream — emit BenchmarkPoint items from C++ to Dart ──────────────
    // Call emit_dataStream(item) from any thread to push to Dart.
    // The emit helper is generated in benchmark_cpp.bridge.g.cpp.
};

static HybridBenchmarkCppImpl g_benchmark_cpp_impl;

// Auto-register on shared library load — no manual init call needed.
__attribute__((constructor))
static void benchmark_cpp_auto_register() {
    benchmark_cpp_register_impl(&g_benchmark_cpp_impl);
}
