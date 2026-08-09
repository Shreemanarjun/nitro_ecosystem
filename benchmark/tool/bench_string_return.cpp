// Micro-benchmark for improvement F — String return marshalling.
//   MODE=0 (before) strdup the std::string, "Dart" decodes then frees it.
//   MODE=1 (after)  assign into a per-thread std::string (reuses its capacity
//                   once warm, so no allocation at all) and return c_str().
// Build BOTH with -fno-builtin-malloc -fno-builtin-free so LLVM cannot elide the
// non-escaping allocation (see bench_opt_return.cpp for why that matters):
//   clang++ -std=c++17 -O2 -fno-builtin-malloc -fno-builtin-free -DMODE=0 \
//       bench_string_return.cpp -o /tmp/st0 && /tmp/st0
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

#ifndef MODE
#define MODE 1
#endif

static thread_local std::string _g_str_ret;

static inline char* bridge_echo_string(const std::string& res) {
#if MODE == 0
  return strdup(res.c_str());
#else
  _g_str_ret = res;
  return const_cast<char*>(_g_str_ret.c_str());
#endif
}

// Stands in for the Dart side: walk to NUL (both modes do this), then free only
// when Dart owns the buffer.
static inline size_t consume(char* p, bool owns) {
  size_t n = 0;
  while (p[n] != '\0') ++n;
  if (owns) ::free(p);
  return n;
}

int main(int argc, char** argv) {
  const long iters = (argc > 1) ? atol(argv[1]) : 5'000'000L;
  const int threads = (argc > 2) ? atoi(argv[2]) : 1;
  const int len = (argc > 3) ? atoi(argv[3]) : 32;
  const std::string payload(len, 'x');

  auto work = [&](long n) {
    size_t acc = 0;
    for (long i = 0; i < n; ++i) acc += consume(bridge_echo_string(payload), MODE == 0);
    return acc;
  };

  auto t0 = std::chrono::steady_clock::now();
  size_t sink = 0;
  if (threads <= 1) {
    sink = work(iters);
  } else {
    std::vector<std::thread> ts;
    std::atomic<size_t> agg{0};
    for (int t = 0; t < threads; ++t)
      ts.emplace_back([&]() { agg.fetch_add(work(iters / threads), std::memory_order_relaxed); });
    for (auto& t : ts) t.join();
    sink = agg.load();
  }
  auto t1 = std::chrono::steady_clock::now();

  double ns = std::chrono::duration<double, std::nano>(t1 - t0).count();
  long total = (threads <= 1) ? iters : (iters / threads) * threads;
  std::printf("MODE=%d (%s)  len=%d  threads=%d  ->  %.3f ns/call  (sink=%zu)\n",
              MODE, MODE == 0 ? "strdup+free" : "tls std::string", len, threads,
              ns / (double)total, sink);
  return 0;
}
