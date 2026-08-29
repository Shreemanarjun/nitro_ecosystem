#include "../lib/src/generated/cpp/benchmark_cpp.native.g.h"
#include "nitro_workload.h"
#ifdef __EMSCRIPTEN__
#include "nitro_wasm_compat.h"
#else
#include "dart_api_dl.h"
#endif

#include <string>
#include <chrono>
#include <cstring>
#include <cstdlib>
#include <cstdint>
#include <thread>
#include <atomic>
#include <cmath>
#include <mutex>
#include <condition_variable>
#include <queue>
#include <functional>
#include <vector>
#include <utility>

#ifdef __EMSCRIPTEN__
// Single-threaded web build: no worker/stream threads. Async tasks run
// inline (Dart-side delivery is still microtask-deferred), and the 60fps
// stream tick runs on an emscripten main-loop interval instead of a thread.
#include <emscripten/emscripten.h>
#include <emscripten/html5.h>

// Hot-restart ownership. A hot restart re-instantiates the module in the SAME
// JS context, but this instance's interval survives on the page, posting into
// a torn-down Dart context. The bridge's EM_JS helper claims ownership for
// the newest instance; a tick that finds itself no longer current clears its
// own interval (same-module API — no cross-module handles needed).
extern "C" int nitro_web_instance_changed();
EM_JS(int, benchmark_cpp_is_current_instance, (), {
  var reg = globalThis.__nitroInstances;
  return (reg && reg["benchmark_cpp"] === wasmExports) ? 1 : 0;
});
#endif

class HybridBenchmarkCppImpl final : public HybridBenchmarkCpp {
public:
    HybridBenchmarkCppImpl() : _running(true), _asyncWorkerRunning(true) {
#ifdef __EMSCRIPTEN__
        nitro_web_instance_changed();  // claim ownership; stale tickers stand down
        _tickInterval = emscripten_set_interval(
            [](void* self) { static_cast<HybridBenchmarkCppImpl*>(self)->_streamTick(); },
            16.666, this);
#else
        _streamThread = std::thread([this]() {
            auto nextTick = std::chrono::steady_clock::now();
            while (_running) {
                // Precise 60fps timing
                nextTick += std::chrono::microseconds(16666);
                std::this_thread::sleep_until(nextTick);

                if (!_running) break;
                _streamTick();
            }
        });
#endif
#if !defined(__EMSCRIPTEN__) || defined(__EMSCRIPTEN_PTHREADS__)
        // Persistent worker thread for computeStatsNative — reused across
        // calls (not spawned per call) so the @nitroAsync vs @nitroNativeAsync
        // benchmark comparison measures dispatch overhead, not OS thread
        // creation cost. Also spawned on a NITRO_WEB_THREADS=1 web build,
        // where native-async work leaves the main thread.
        // Worker pool on every platform: a burst of CPU-bound native-async
        // calls runs in parallel (web-threaded 4×2M burst: 2.7 s → 1.4 s).
        // The coalescer is locked accordingly — see _flushCoalesce.
        const unsigned _poolN = std::max(2u, std::min(4u, std::thread::hardware_concurrency()));
        for (unsigned _w = 0; _w < _poolN; ++_w)
        _asyncWorkerPool.emplace_back([this]() {
            while (true) {
                std::function<void()> task;
                {
                    std::unique_lock<std::mutex> lk(_asyncQueueMtx);
                    _asyncQueueCv.wait(lk, [this]() { return !_asyncQueue.empty() || !_asyncWorkerRunning; });
                    if (!_asyncWorkerRunning && _asyncQueue.empty()) return;
                    task = std::move(_asyncQueue.front());
                    _asyncQueue.pop();
                }
                task();
                // Coalesce flush (issue #39): once the burst has drained, post all
                // accumulated (callId, value) results in ONE kArray, so N
                // completions share a single Dart_PostCObject / isolate wake.
                {
                    std::unique_lock<std::mutex> lk(_asyncQueueMtx);
                    const bool drained = _asyncQueue.empty();
                    lk.unlock();
                    if (drained) _flushCoalesce();
                }
            }
        });  // pool worker

#endif
    }

    ~HybridBenchmarkCppImpl() {
        _running = false;
#ifdef __EMSCRIPTEN__
        emscripten_clear_interval(_tickInterval);
#else
        if (_streamThread.joinable()) {
            _streamThread.join();
        }
#endif
#if !defined(__EMSCRIPTEN__) || defined(__EMSCRIPTEN_PTHREADS__)
        {
            std::lock_guard<std::mutex> lk(_asyncQueueMtx);
            _asyncWorkerRunning = false;
        }
        _asyncQueueCv.notify_all();
        for (auto& _w : _asyncWorkerPool) {
            if (_w.joinable()) _w.join();
        }
#endif
    }

    // One 60fps stream frame — shared by the native stream thread and the
    // emscripten interval.
    void _streamTick() {
#ifdef __EMSCRIPTEN__
        if (!benchmark_cpp_is_current_instance()) {
            emscripten_clear_interval(_tickInterval);
            return;
        }
#endif
        // 1. Stress Test Data (BenchmarkPoint)
        emit_dataStream(BenchmarkPoint{std::sin(_angle), std::cos(_angle)});

        // 2. Visual Stress Test (BenchmarkBox)
        // Cycle through colors and oscillate size
        uint32_t r = static_cast<uint32_t>((std::sin(_angle) + 1.0) * 127);
        uint32_t g = static_cast<uint32_t>((std::sin(_angle + 2.0) + 1.0) * 127);
        uint32_t b = static_cast<uint32_t>((std::sin(_angle + 4.0) + 1.0) * 127);
        int64_t color = 0xFF000000 | (r << 16) | (g << 8) | b;

        double width = 100.0 + std::sin(_angle * 0.5) * 50.0;
        double height = 100.0 + std::cos(_angle * 0.5) * 50.0;

        emit_boxStream(BenchmarkBox{color, width, height});

        _angle += 0.05;
    }

    // Dispatches an async task: worker-thread queue on native, inline on the
    // single-threaded web build (Dart delivery stays async — the post callback
    // defers to a microtask).
    void _enqueue(std::function<void()> task) {
#if defined(__EMSCRIPTEN__) && !defined(__EMSCRIPTEN_PTHREADS__)
        task();
        _flushCoalesce();
#else
        {
            std::lock_guard<std::mutex> lk(_asyncQueueMtx);
            _asyncQueue.push(std::move(task));
        }
        _asyncQueueCv.notify_one();
#endif
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
        return computeStatsBuffer(iterations);
    }

    // ── Native-async twin of computeStats — same computation, dispatched via
    // a persistent worker thread + Dart_PostCObject_DL instead of the isolate
    // pool. See computeStatsBuffer() for the shared, byte-identical logic.
    // _nitro_err is unused here — this benchmark case has no error path — but
    // must stay in the signature to match the (generated) pure-virtual
    // declaration in benchmark_cpp.native.g.h.
    void computeStatsNative(int64_t iterations, NitroError* /*_nitro_err*/, int64_t dartPort) override {
        _enqueue([this, iterations, dartPort]() {
            NitroCppBuffer buf = computeStatsBuffer(iterations);
            Dart_CObject obj;
            if (buf.data == nullptr) {
                obj.type = Dart_CObject_kNull;
            } else {
                obj.type = Dart_CObject_kInt64;
                obj.value.as_int64 = reinterpret_cast<intptr_t>(buf.data);
            }
            Dart_PostCObject_DL(dartPort, &obj);
        });
    }

    // ── Perf-audit benchmark methods (map codec + async dispatch) ──────────
    // Echo a Map<String,int>: the Dart proxy encodes the map to [4B len]
    // [payload], we re-emit an identical length-prefixed block, Dart decodes
    // it back. Native work is minimal so the harness measures the Dart-side
    // map binary codec (encode + decode), optimization target "B".
    NitroCppBuffer echoIntMap(NitroCppBuffer map) override {
        int32_t len = static_cast<int32_t>(map.size);
        uint8_t* out = static_cast<uint8_t*>(::malloc(sizeof(int32_t) + map.size));
        ::memcpy(out, &len, sizeof(int32_t));
        if (map.size) ::memcpy(out + sizeof(int32_t), map.data, map.size);
        return { out, sizeof(int32_t) + map.size };
    }

    // List<@HybridRecord> echo — re-emit the incoming length-prefixed record-
    // list blob. The list codec is entirely Dart-side; native just returns the
    // same [4B len][payload] block.
    NitroCppBuffer echoStatsList(NitroCppBuffer stats) override {
        int32_t len = static_cast<int32_t>(stats.size);
        uint8_t* out = static_cast<uint8_t*>(::malloc(sizeof(int32_t) + stats.size));
        ::memcpy(out, &len, sizeof(int32_t));
        if (stats.size) ::memcpy(out + sizeof(int32_t), stats.data, stats.size);
        return { out, sizeof(int32_t) + stats.size };
    }

    // Minimal @nitroAsync scalar round-trip: returns its argument. The isolate
    // dispatch happens on the Dart side; here it is a plain return.
    int64_t asyncEcho(int64_t value) override { return value; }

    // Minimal @nitroNativeAsync scalar round-trip: post the value straight back
    // via Dart_PostCObject_DL (no thread hop) so the harness measures the
    // Dart-side per-call native-async dispatch cost (ReceivePort + error slot +
    // Future), optimization target "D".
    void nativeAsyncEcho(int64_t value, NitroError* /*_nitro_err*/, int64_t dartPort) override {
        Dart_CObject obj;
        obj.type = Dart_CObject_kInt64;
        obj.value.as_int64 = value;
        Dart_PostCObject_DL(dartPort, &obj);
    }

    // Cross-thread variant of nativeAsyncEcho: the worker thread does the post,
    // so it pays the OS isolate wake the inline version skips (issue #39).
    void nativeAsyncEchoFromThread(int64_t value, NitroError* /*_nitro_err*/, int64_t dartPort) override {
        _enqueue([value, dartPort]() {
            Dart_CObject obj;
            obj.type = Dart_CObject_kInt64;
            obj.value.as_int64 = value;
            Dart_PostCObject_DL(dartPort, &obj);
        });
    }

    // Coalesced completion (issue #39): buffer (callId, value); the worker posts
    // the whole drained batch as one kArray, so a burst shares one wake.
    void submitCoalesced(int64_t callId, int64_t value, int64_t dartPort) override {
        _coalescePort.store(dartPort, std::memory_order_relaxed);
        _enqueue([this, callId, value]() {
            std::lock_guard<std::mutex> lk(_asyncQueueMtx);
            _coalesceBuf.emplace_back(callId, value);
        });
    }

    // Coalesce instrumentation (issue #39): flush/item counters so the harness
    // can report the average batch size (items ÷ flushes) achieved per burst.
    void resetCoalesceStats() override {
        _coalesceFlushes.store(0, std::memory_order_relaxed);
        _coalesceItems.store(0, std::memory_order_relaxed);
    }
    int64_t coalesceFlushes() override { return _coalesceFlushes.load(std::memory_order_relaxed); }
    int64_t coalesceItems() override { return _coalesceItems.load(std::memory_order_relaxed); }

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

    int64_t sendLargeBufferUnsafe(uint8_t* buffer, int64_t buffer_length) override {
        // Bypasses pinning cost — matches Raw FFI theoretical performance.
        return static_cast<int64_t>(buffer_length);
    }

    int64_t sievePrimes(int64_t limit) override {
        // Second reference workload: sieve of Eratosthenes — the same C
        // routine every other tier runs (src/nitro_workload.h); every tier
        // must return the identical prime count.
        return nitro_bench_sieve_primes(limit);
    }

    int64_t hashBuffer(const uint8_t* data, size_t data_length,
                       int64_t rounds) override {
        // Reference workload: FNV-1a 64-bit — the same C routine every other
        // tier runs (src/nitro_workload.h); results must be bit-identical.
        return static_cast<int64_t>(
            nitro_bench_fnv1a(data, static_cast<int64_t>(data_length), rounds));
    }

private:
    // Shared by computeStats (sync) and computeStatsNative (native-async) so
    // both paths run byte-identical computation and encoding — only the
    // dispatch mechanism differs between the two benchmark cases.
    NitroCppBuffer computeStatsBuffer(int64_t iterations) {
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

#ifdef __EMSCRIPTEN__
    long _tickInterval = 0;
#endif
    double _angle = 0;
    std::thread _streamThread;
    std::atomic<bool> _running;

    // Persistent worker + task queue backing computeStatsNative().
    std::vector<std::thread> _asyncWorkerPool;
    std::mutex _asyncQueueMtx;
    std::condition_variable _asyncQueueCv;
    std::queue<std::function<void()>> _asyncQueue;
    bool _asyncWorkerRunning;
    // Coalescing (issue #39): worker-thread-only buffer of (callId, value)
    // completions, flushed as one kArray post to the shared port when the queue
    // drains. Guarded by _asyncQueueMtx: several pool workers push and any of
    // them may flush.
    std::vector<std::pair<int64_t, int64_t>> _coalesceBuf;
    std::atomic<int64_t> _coalescePort{0};
    // Instrumentation: how many flushes (posts) and how many total items, so the
    // harness can report the AVERAGE batch size a burst achieved (items/flushes).
    std::atomic<int64_t> _coalesceFlushes{0};
    std::atomic<int64_t> _coalesceItems{0};

    void _flushCoalesce() {
        // Take the batch out under the lock; build and post from locals so a
        // concurrent push from another pool worker can never tear the array.
        std::vector<std::pair<int64_t, int64_t>> batch;
        {
            std::lock_guard<std::mutex> lk(_asyncQueueMtx);
            if (_coalesceBuf.empty()) return;
            batch.swap(_coalesceBuf);
        }
        const int64_t port = _coalescePort.load(std::memory_order_relaxed);
        if (port == 0) return;
        _coalesceFlushes.fetch_add(1, std::memory_order_relaxed);
        _coalesceItems.fetch_add(static_cast<int64_t>(batch.size()), std::memory_order_relaxed);
        const size_t n = batch.size() * 2;
        std::vector<Dart_CObject> elems(n);
        std::vector<Dart_CObject*> ptrs(n);
        for (size_t i = 0; i < batch.size(); ++i) {
            elems[2 * i].type = Dart_CObject_kInt64;
            elems[2 * i].value.as_int64 = batch[i].first;   // callId
            elems[2 * i + 1].type = Dart_CObject_kInt64;
            elems[2 * i + 1].value.as_int64 = batch[i].second; // value
        }
        for (size_t i = 0; i < n; ++i) ptrs[i] = &elems[i];
        Dart_CObject arr;
        arr.type = Dart_CObject_kArray;
        arr.value.as_array.length = static_cast<intptr_t>(n);
        arr.value.as_array.values = ptrs.data();
        Dart_PostCObject_DL(port, &arr);
    }
};

static HybridBenchmarkCppImpl g_benchmark_cpp_impl;

// Auto-register on shared library load — no manual init call needed.
#if defined(_WIN32)
// MSVC lacks __attribute__((constructor)); use a static object instead.
namespace {
  struct _AutoRegisterBenchmarkCpp {
    _AutoRegisterBenchmarkCpp() { benchmark_cpp_register_impl(&g_benchmark_cpp_impl); }
  };
  _AutoRegisterBenchmarkCpp _auto_register_benchmark_cpp;
}
#else
__attribute__((constructor))
static void benchmark_cpp_auto_register() {
    benchmark_cpp_register_impl(&g_benchmark_cpp_impl);
}
#endif
