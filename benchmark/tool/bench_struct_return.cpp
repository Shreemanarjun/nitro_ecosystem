// Micro-benchmark for improvement C — @HybridStruct return marshalling.
// Replicates what the generated C bridge does per call for a struct return:
//   MODE=0 (before) malloc a shell, copy the struct into it, "Dart" frees it.
//   MODE=1 (after)  copy into a reusable per-thread slot; nothing to free.
// Inner heap fields are unaffected either way (Dart still freeFields() them),
// so this measures exactly the shell allocation that improvement C removes.
// Build BOTH with -fno-builtin-malloc -fno-builtin-free, otherwise LLVM elides
// the non-escaping malloc/free pair and the comparison is meaningless:
//   clang++ -std=c++17 -O2 -fno-builtin-malloc -fno-builtin-free -DMODE=0 \
//       bench_struct_return.cpp -o /tmp/sr0 && /tmp/sr0
//   clang++ -std=c++17 -O2 -fno-builtin-malloc -fno-builtin-free -DMODE=1 \
//       bench_struct_return.cpp -o /tmp/sr1 && /tmp/sr1
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <thread>
#include <vector>

#ifndef MODE
#define MODE 1
#endif

// Mirrors a typical @HybridStruct (TcPoint-like, 3 doubles).
struct TcPoint {
  double x, y, z;
};

static inline TcPoint* bridge_echo_point(const TcPoint& res) {
#if MODE == 0
  auto* p = static_cast<TcPoint*>(::malloc(sizeof(TcPoint)));
  if (!p) return nullptr;
#else
  static thread_local TcPoint _g_ret_st;
  auto* p = &_g_ret_st;
#endif
  *p = res;
  return p;
}

// Stands in for the Dart side: read the fields, then (malloc mode only) free the
// shell — exactly `structPtr.ref.toDart(); … _nitroFree(structPtr);`.
static inline double consume(TcPoint* p, bool owns) {
  double v = p->x + p->y + p->z;
  if (owns) ::free(p);
  return v;
}

int main(int argc, char** argv) {
  const long iters = (argc > 1) ? atol(argv[1]) : 20'000'000L;
  const int threads = (argc > 2) ? atoi(argv[2]) : 1;

  auto work = [&](long n) {
    double acc = 0;
    for (long i = 0; i < n; ++i) {
      TcPoint src{(double)i, (double)i * 0.5, 1.0};
      acc += consume(bridge_echo_point(src), MODE == 0);
    }
    return acc;
  };

  auto t0 = std::chrono::steady_clock::now();
  double sink = 0;
  if (threads <= 1) {
    sink = work(iters);
  } else {
    std::vector<std::thread> ts;
    std::atomic<int64_t> agg{0};
    for (int t = 0; t < threads; ++t)
      ts.emplace_back([&]() { agg.fetch_add((int64_t)work(iters / threads), std::memory_order_relaxed); });
    for (auto& t : ts) t.join();
    sink = (double)agg.load();
  }
  auto t1 = std::chrono::steady_clock::now();

  double ns = std::chrono::duration<double, std::nano>(t1 - t0).count();
  long total = (threads <= 1) ? iters : (iters / threads) * threads;
  std::printf("MODE=%d (%s)  threads=%d  ->  %.3f ns/call  (sink=%.0f)\n",
              MODE, MODE == 0 ? "malloc+free shell" : "tls slot", threads,
              ns / (double)total, sink);
  return 0;
}
