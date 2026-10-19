// Completion-spin & batch contention: the per-call hot paths behind
// @nitroNativeAsync under concurrent load (issue #58).
//
// Part A — arm() claim: bare CAS vs test-then-CAS (TTAS). 0.7.12's thread-safety
//   fix made arm() CAS the one process-global slot; under many concurrent arming
//   isolates that bare CAS ping-pongs a single cache line and serializes
//   throughput (single-call latency is unaffected). 0.7.13 adds a relaxed load
//   first. This measures the claim cost on the contended bail path (slot held).
// Part B — completion-batch bind→post→ack cycle under N threads: the mu_ mutex
//   that guards the id/port maps, exercised the way concurrent native workers
//   hit it. Shows how the single lock scales (ns/cycle vs thread count) — the
//   next lever if per-call dispatch is the bottleneck.
//
// Build & run (from benchmark/tool/):
//   clang++ -std=c++17 -O2 -I ../../packages/nitro/src/native -I ../src/native \
//     bench_spin_contention.cpp -o /tmp/bsc && /tmp/bsc
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <thread>
#include <vector>

#include "dart_native_api.h"
#include "dart_api_dl.h"
#include "nitro_completion_batch.h"

// The one DL symbol the batch calls (stub: count posts).
static std::atomic<long> g_posts{0};
static bool myPost(Dart_Port_DL, Dart_CObject*) {
  g_posts.fetch_add(1, std::memory_order_relaxed);
  return true;
}
extern "C" {
Dart_PostCObject_Type Dart_PostCObject_DL = &myPost;
}

static double seconds(std::chrono::steady_clock::time_point a, std::chrono::steady_clock::time_point b) {
  return std::chrono::duration<double, std::nano>(b - a).count();
}

// ── Part A: arm() claim, CAS vs TTAS, slot held so every arm bails ───────────
static std::atomic<int64_t> g_slot{1};
static bool cas_arm(int64_t id) {
  int64_t e = 0;
  return g_slot.compare_exchange_strong(e, id, std::memory_order_acq_rel, std::memory_order_relaxed);
}
static bool ttas_arm(int64_t id) {
  if (g_slot.load(std::memory_order_relaxed) != 0) return false;  // 0.7.13: skip the contended RMW
  int64_t e = 0;
  return g_slot.compare_exchange_strong(e, id, std::memory_order_acq_rel, std::memory_order_relaxed);
}
static double armRun(bool ttas, int threads, long iters) {
  std::atomic<bool> go{false};
  std::vector<std::thread> ts;
  for (int t = 0; t < threads; ++t) {
    ts.emplace_back([&, t] {
      while (!go.load(std::memory_order_acquire)) {}
      for (long i = 0; i < iters; ++i) {
        const int64_t id = (long)t * iters + i + 2;
        volatile bool claimed = ttas ? ttas_arm(id) : cas_arm(id);
        (void)claimed;
      }
    });
  }
  const auto t0 = std::chrono::steady_clock::now();
  go.store(true, std::memory_order_release);
  for (auto& th : ts) th.join();
  return seconds(t0, std::chrono::steady_clock::now()) / ((double)threads * iters);
}

// ── Part B: completion-batch bind→post→ack cycle under contention (mu_) ──────
static double batchRun(int threads, long iters) {
  NitroCompletionBatch batch;
  std::atomic<bool> go{false};
  std::vector<std::thread> ts;
  for (int t = 0; t < threads; ++t) {
    ts.emplace_back([&, t] {
      const int64_t port = 1000 + t;  // each "worker" posts to its own port
      while (!go.load(std::memory_order_acquire)) {}
      for (long i = 0; i < iters; ++i) {
        const int64_t id = batch.bind(port);  // mu_
        Dart_CObject o;
        std::memset(&o, 0, sizeof(o));
        o.type = Dart_CObject_kInt64;
        o.value.as_int64 = id;
        batch.post(id, &o);  // mu_
        batch.ack(port);     // mu_ (drains, resets inFlight)
      }
    });
  }
  const auto t0 = std::chrono::steady_clock::now();
  go.store(true, std::memory_order_release);
  for (auto& th : ts) th.join();
  return seconds(t0, std::chrono::steady_clock::now()) / ((double)threads * iters);
}

int main() {
  std::printf("── arm() claim, slot held (bail path): bare CAS (0.7.12) vs TTAS (0.7.13) ──\n");
  std::printf("%-8s %12s %12s %9s\n", "threads", "CAS ns", "TTAS ns", "speedup");
  for (int th : {1, 2, 4, 8, 16, 64}) {
    g_slot.store(1, std::memory_order_relaxed);
    const double c = armRun(false, th, 2'000'000);
    g_slot.store(1, std::memory_order_relaxed);
    const double t = armRun(true, th, 2'000'000);
    std::printf("%-8d %12.2f %12.2f %8.1fx\n", th, c, t, c / t);
  }
  std::printf("\n── completion-batch bind->post->ack cycle: mu_ contention (ns/cycle) ──\n");
  std::printf("%-8s %12s\n", "threads", "ns/cycle");
  for (int th : {1, 2, 4, 8, 16, 64}) {
    std::printf("%-8d %12.2f\n", th, batchRun(th, 200'000));
  }
  return 0;
}
