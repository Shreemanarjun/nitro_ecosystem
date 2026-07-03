// HybridBenchmark — desktop C++ implementation of the Benchmark spec.
//
// On iOS/macOS this module is Swift, on Android it is Kotlin; this C++ impl
// serves Windows and Linux only. The whole file is guarded so it is a no-op
// on every other platform (note: Android defines __linux__ too — the
// !__ANDROID__ check keeps the C++ registry from shadowing the Kotlin impl).
#if defined(_WIN32) || (defined(__linux__) && !defined(__ANDROID__))

#include "../lib/src/generated/cpp/benchmark.native.g.h"
#include "nitro_workload.h"

#include <cstdint>
#include <string>

class HybridBenchmarkImpl final : public HybridBenchmark {
public:
    double add(double a, double b) override { return a + b; }

    double addFast(double a, double b) override { return a + b; }

    std::string getGreeting(const std::string& name) override {
        return "Hello, " + name + "!";
    }

    int64_t hashBuffer(const uint8_t* data, size_t data_length,
                       int64_t rounds) override {
        // Reference workload — same C routine as the desktop channel handler.
        return static_cast<int64_t>(
            nitro_bench_fnv1a(data, static_cast<int64_t>(data_length), rounds));
    }

    int64_t sendLargeBuffer(const uint8_t* buffer, size_t buffer_length) override {
        // 4 KiB stride walk — touch memory so the transfer can't be elided,
        // mirroring the Swift/Kotlin implementations.
        volatile uint8_t sum = 0;
        for (size_t i = 0; i < buffer_length; i += 4096) {
            sum = static_cast<uint8_t>(sum + buffer[i]);
        }
        (void)sum;
        return static_cast<int64_t>(buffer_length);
    }
};

static HybridBenchmarkImpl g_impl;

// Auto-register on shared library load — no manual init call needed.
#if defined(_WIN32)
// MSVC lacks __attribute__((constructor)); use a static object instead.
namespace {
  struct _AutoRegister {
    _AutoRegister() { benchmark_register_impl(&g_impl); }
  };
  _AutoRegister _auto_register_instance;
}
#else
__attribute__((constructor))
static void benchmark_auto_register() {
    benchmark_register_impl(&g_impl);
}
#endif

#endif  // _WIN32 || (__linux__ && !__ANDROID__)
