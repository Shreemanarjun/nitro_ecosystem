// C-bridge instance lookup: replicates _nitro_get_instance with a compile-time
// WAYS parameter, over a rotating-id workload (a Dart loop across live instances).
//   WAYS=1  single-entry cache — any rotation misses to the mutex + hashmap.
//   WAYS=8  N-way cache; several distinct ids stay lock-free.
// Build & run both:
//   clang++ -std=c++17 -O2 -DWAYS=1 bench_instance_cache.cpp -o /tmp/ic1 && /tmp/ic1
//   clang++ -std=c++17 -O2 -DWAYS=8 bench_instance_cache.cpp -o /tmp/ic8 && /tmp/ic8
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <memory>
#include <mutex>
#include <thread>
#include <unordered_map>
#include <vector>

#ifndef WAYS
#define WAYS 8
#endif

struct Hybrid { int64_t v; };

static std::unordered_map<int64_t, std::shared_ptr<Hybrid>>& _g_instances() {
  static std::unordered_map<int64_t, std::shared_ptr<Hybrid>> m;
  return m;
}
static std::mutex& _g_instances_mtx() { static std::mutex m; return m; }

static constexpr int _kWays = WAYS;
struct alignas(64) Slot {
  std::atomic<int64_t> id{-1};
  std::atomic<Hybrid*> ptr{nullptr};
};
static Slot _cache[_kWays];

static Hybrid* get_instance(int64_t id) {
  Slot& s = _cache[(uint64_t)id & (_kWays - 1)];
  if (s.id.load(std::memory_order_acquire) == id) {
    return s.ptr.load(std::memory_order_relaxed);
  }
  std::lock_guard<std::mutex> lk(_g_instances_mtx());
  auto it = _g_instances().find(id);
  Hybrid* p = (it != _g_instances().end()) ? it->second.get() : nullptr;
  if (p) {
    s.ptr.store(p, std::memory_order_relaxed);
    s.id.store(id, std::memory_order_release);
  }
  return p;
}

int main(int argc, char** argv) {
  const int nInst = (argc > 1) ? atoi(argv[1]) : 4;   // instances in rotation
  const long iters = (argc > 2) ? atol(argv[2]) : 20'000'000L;
  const int threads = (argc > 3) ? atoi(argv[3]) : 1; // contended readers

  std::vector<int64_t> ids;
  for (int i = 0; i < nInst; ++i) {
    int64_t id = 2 + i; // factory ids start at 2 (matches _g_next_instance_id)
    _g_instances()[id] = std::make_shared<Hybrid>(Hybrid{id});
    ids.push_back(id);
  }

  auto work = [&](long n) {
    int64_t acc = 0;
    for (long i = 0; i < n; ++i) {
      Hybrid* h = get_instance(ids[i % nInst]); // rotate → exercises the cache
      acc += h ? h->v : 0;
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
  double perCall = ns / (double)(threads <= 1 ? iters : (iters / threads) * threads);
  std::printf("WAYS=%d  nInst=%d  threads=%d  iters=%ld  ->  %.3f ns/lookup  (sink=%lld)\n",
              _kWays, nInst, threads, iters, perCall, (long long)sink);
  return 0;
}
