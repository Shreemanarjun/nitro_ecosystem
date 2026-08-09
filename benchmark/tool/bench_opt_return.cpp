// Nullable-primitive return marshalling: malloc+free vs a per-thread slot.
//   MODE=0  malloc a NitroOptInt64, fill it, hand it to "Dart", free it.
//   MODE=1  fill a reusable per-thread slot; nothing to free.
// Build BOTH with -fno-builtin-malloc -fno-builtin-free, or LLVM elides the
// non-escaping allocation and both modes measure the same.
//   clang++ -std=c++17 -O2 -fno-builtin-malloc -fno-builtin-free -DMODE=0 \
//       bench_opt_return.cpp -o /tmp/or0 && /tmp/or0
//   clang++ -std=c++17 -O2 -fno-builtin-malloc -fno-builtin-free -DMODE=1 \
//       bench_opt_return.cpp -o /tmp/or1 && /tmp/or1
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <optional>
#include <thread>
#include <vector>

#ifndef MODE
#define MODE 1
#endif

struct NitroOptInt64 {
  int8_t hasValue;
  int64_t value;
};

alignas(8) static thread_local uint8_t _g_opt_ret[16];

// Stands in for Dart: decode both fields, then free only in malloc mode.
static inline int64_t consume(uint8_t* p, bool owns) {
  auto* o = reinterpret_cast<NitroOptInt64*>(p);
  int64_t v = o->hasValue ? o->value : 0;
  if (owns) ::free(p);
  return v;
}

static inline uint8_t* bridge_echo_nullable_int(std::optional<int64_t> opt) {
#if MODE == 0
  auto* out = static_cast<NitroOptInt64*>(::malloc(sizeof(NitroOptInt64)));
  if (!out) return nullptr;
#else
  auto* out = reinterpret_cast<NitroOptInt64*>(static_cast<void*>(_g_opt_ret));
#endif
  out->hasValue = opt.has_value() ? 1 : 0;
  out->value = opt.value_or(0);
  return reinterpret_cast<uint8_t*>(out);
}

int main(int argc, char** argv) {
  const long iters = (argc > 1) ? atol(argv[1]) : 20'000'000L;
  const int threads = (argc > 2) ? atoi(argv[2]) : 1;

  auto work = [&](long n) {
    int64_t acc = 0;
    for (long i = 0; i < n; ++i) {
      std::optional<int64_t> opt = (i & 7) ? std::optional<int64_t>(i) : std::nullopt;
      uint8_t* p = bridge_echo_nullable_int(opt);
      acc += consume(p, MODE == 0);
    }
    return acc;
  };

  auto t0 = std::chrono::steady_clock::now();
  int64_t sink = 0;
  if (threads <= 1) {
    sink = work(iters);
  } else {
    std::vector<std::thread> ts;
    std::atomic<int64_t> agg{0};
    for (int t = 0; t < threads; ++t)
      ts.emplace_back([&]() { agg.fetch_add(work(iters / threads), std::memory_order_relaxed); });
    for (auto& t : ts) t.join();
    sink = agg.load();
  }
  auto t1 = std::chrono::steady_clock::now();

  double ns = std::chrono::duration<double, std::nano>(t1 - t0).count();
  long total = (threads <= 1) ? iters : (iters / threads) * threads;
  std::printf("MODE=%d (%s)  threads=%d  iters=%ld  ->  %.3f ns/call  (sink=%lld)\n",
              MODE, MODE == 0 ? "malloc+free" : "tls scratch", threads, iters,
              ns / (double)total, (long long)sink);
  return 0;
}
