// Fire-and-forget void dispatch vs single-in-flight completion (issue #58).
// Exercises the REAL production NitroWorkerPool — the fire-and-forget path calls
// `enqueueBounded(...)` exactly as the generated `<sym>_fnf` does (copy args →
// enqueue → return), so this measures real code, not a model.
//
// Q: does fire-and-forget scale past the serial ~230k calls/s completion ceiling
//    that bottlenecks streaming/SSE?
//
// Build & run (from benchmark/tool/):
//   clang++ -std=c++17 -O2 -I ../../packages/nitro/src/native \
//     bench_fnf_dispatch.cpp -o /tmp/bfnf && /tmp/bfnf
#include <atomic>
#include <chrono>
#include <cstdio>
#include <mutex>
#include <thread>
#include <vector>

#include "nitro_worker_pool.h"

// Leaked so the detached workers never outlive a static destructor at exit
// (benign process-teardown race otherwise); isolates the dispatch path.
static NitroWorkerPool& pool = *new NitroWorkerPool();
static std::atomic<long> g_ran{0};

static double secs(std::chrono::steady_clock::time_point a, std::chrono::steady_clock::time_point b) {
  return std::chrono::duration<double>(b - a).count();
}

// Fire-and-forget: the generated <sym>_fnf copies args then enqueueBounded(block,
// 1024) and returns. Here the job is a no-op stand-in for the sync impl.
static double fnfThroughput(int producers, long perProducer) {
  std::atomic<bool> go{false};
  std::vector<std::thread> ts;
  for (int t = 0; t < producers; ++t)
    ts.emplace_back([&] {
      while (!go.load(std::memory_order_acquire)) {}
      for (long i = 0; i < perProducer; ++i)
        pool.enqueueBounded([] { g_ran.fetch_add(1, std::memory_order_relaxed); }, 1024, 0);
    });
  const auto t0 = std::chrono::steady_clock::now();
  go.store(true, std::memory_order_release);
  for (auto& th : ts) th.join();
  return (double)producers * perProducer / secs(t0, std::chrono::steady_clock::now());
}

// Today's awaited path: one completion in flight across all producers (the
// process-global single-in-flight slot), each waits before issuing the next.
static std::mutex g_slot;
static double roundTripThroughput(int producers, long perProducer) {
  std::atomic<bool> go{false};
  std::vector<std::thread> ts;
  for (int t = 0; t < producers; ++t)
    ts.emplace_back([&] {
      while (!go.load(std::memory_order_acquire)) {}
      for (long i = 0; i < perProducer; ++i) {
        std::lock_guard<std::mutex> lk(g_slot);
        std::atomic<bool> done{false};
        pool.enqueue([&] { done.store(true, std::memory_order_release); });
        while (!done.load(std::memory_order_acquire)) {}
      }
    });
  const auto t0 = std::chrono::steady_clock::now();
  go.store(true, std::memory_order_release);
  for (auto& th : ts) th.join();
  return (double)producers * perProducer / secs(t0, std::chrono::steady_clock::now());
}

int main() {
  pool.enqueue([] {});  // warm the pool threads
  std::this_thread::sleep_for(std::chrono::milliseconds(50));
  std::printf("── fire-and-forget: enqueueBounded + return (the <sym>_fnf path) ──\n");
  std::printf("%-10s %16s\n", "producers", "calls/s");
  for (int p : {1, 2, 4, 8}) std::printf("%-10d %16.0f\n", p, fnfThroughput(p, 500'000));
  std::printf("\n── single-in-flight completion round-trip (today) ──\n");
  std::printf("%-10s %16s\n", "producers", "calls/s");
  for (int p : {1, 2, 4, 8}) std::printf("%-10d %16.0f\n", p, roundTripThroughput(p, 50'000));
  return 0;
}
