// TSan audit harness for the two coalescer threading patterns (issue #39).
// Mocks Dart_PostCObject_DL and hammers each coalescer with concurrent
// producers while its worker flushes, so ThreadSanitizer sees the real
// cross-thread accesses. Build:
//   clang++ -std=c++17 -fsanitize=thread -g -O1 tsan_coalescer.cpp -o tsan_coal
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <functional>
#include <mutex>
#include <queue>
#include <thread>
#include <utility>
#include <vector>
#include <cstdio>

// ── Mock dart_api_dl ─────────────────────────────────────────────────────────
enum { Dart_CObject_kInt64, Dart_CObject_kArray };
struct Dart_CObject {
  int type;
  union {
    int64_t as_int64;
    struct { intptr_t length; Dart_CObject** values; } as_array;
  } value;
};
static std::atomic<int64_t> g_posted{0}; // count elements delivered (sink)
static void Dart_PostCObject_DL(int64_t /*port*/, Dart_CObject* obj) {
  // Read the array the way Dart would, on the worker thread.
  if (obj->type == Dart_CObject_kArray) {
    int64_t sum = 0;
    for (intptr_t i = 0; i < obj->value.as_array.length; ++i)
      sum += obj->value.as_array.values[i]->value.as_int64;
    g_posted.fetch_add(sum == 0 ? 0 : obj->value.as_array.length, std::memory_order_relaxed);
  }
}

// ── Pattern A: type_coverage coalescer (mutex + cv + time-window flush) ──────
class TcCoalescer {
public:
  TcCoalescer() { _thread = std::thread([this]() { loop(); }); }
  ~TcCoalescer() {
    { std::lock_guard<std::mutex> lk(_mtx); _running = false; }
    _cv.notify_one();
    if (_thread.joinable()) _thread.join();
  }
  void submit(int64_t callId, int64_t value, int64_t port) {
    _port.store(port, std::memory_order_relaxed);
    { std::lock_guard<std::mutex> lk(_mtx); _buf.emplace_back(callId, value); }
    _cv.notify_one();
  }
private:
  void loop() {
    while (true) {
      std::vector<std::pair<int64_t,int64_t>> batch;
      {
        std::unique_lock<std::mutex> lk(_mtx);
        _cv.wait(lk, [this]() { return !_buf.empty() || !_running; });
        if (!_running && _buf.empty()) return;
        // Improved: RAII wait_for accumulates the window, releasing the lock,
        // breaking early on shutdown (CP.20 — no manual unlock/lock).
        _cv.wait_for(lk, std::chrono::microseconds(50), [this]() { return !_running; });
        batch.swap(_buf);
      }
      const int64_t port = _port.load(std::memory_order_relaxed);
      if (port == 0 || batch.empty()) continue;
      const size_t n = batch.size() * 2;
      std::vector<Dart_CObject> elems(n);
      std::vector<Dart_CObject*> ptrs(n);
      for (size_t i = 0; i < batch.size(); ++i) {
        elems[2*i].type = Dart_CObject_kInt64; elems[2*i].value.as_int64 = batch[i].first;
        elems[2*i+1].type = Dart_CObject_kInt64; elems[2*i+1].value.as_int64 = batch[i].second;
      }
      for (size_t i = 0; i < n; ++i) ptrs[i] = &elems[i];
      Dart_CObject arr; arr.type = Dart_CObject_kArray;
      arr.value.as_array.length = (intptr_t)n; arr.value.as_array.values = ptrs.data();
      Dart_PostCObject_DL(port, &arr);
    }
  }
  std::mutex _mtx; std::condition_variable _cv;
  std::vector<std::pair<int64_t,int64_t>> _buf;
  std::atomic<int64_t> _port{0};
  bool _running = true;
  std::thread _thread;
};

// ── Pattern B: benchmark coalescer (worker queue; buffer is worker-only) ─────
class BenchCoalescer {
public:
  BenchCoalescer() {
    _thread = std::thread([this]() {
      while (true) {
        std::function<void()> task;
        {
          std::unique_lock<std::mutex> lk(_qmtx);
          _qcv.wait(lk, [this]() { return !_q.empty() || !_running; });
          if (!_running && _q.empty()) return;
          task = std::move(_q.front()); _q.pop();
        }
        task();
        { std::unique_lock<std::mutex> lk(_qmtx); bool drained = _q.empty(); lk.unlock(); if (drained) flush(); }
      }
    });
  }
  ~BenchCoalescer() {
    { std::lock_guard<std::mutex> lk(_qmtx); _running = false; }
    _qcv.notify_one();
    if (_thread.joinable()) _thread.join();
  }
  void submit(int64_t callId, int64_t value, int64_t port) {
    _port.store(port, std::memory_order_relaxed);
    { std::lock_guard<std::mutex> lk(_qmtx); _q.push([this, callId, value]() { _buf.emplace_back(callId, value); }); }
    _qcv.notify_one();
  }
private:
  void flush() { // worker-thread-only
    if (_buf.empty()) return;
    const int64_t port = _port.load(std::memory_order_relaxed);
    if (port == 0) { _buf.clear(); return; }
    const size_t n = _buf.size() * 2;
    std::vector<Dart_CObject> elems(n); std::vector<Dart_CObject*> ptrs(n);
    for (size_t i = 0; i < _buf.size(); ++i) {
      elems[2*i].type = Dart_CObject_kInt64; elems[2*i].value.as_int64 = _buf[i].first;
      elems[2*i+1].type = Dart_CObject_kInt64; elems[2*i+1].value.as_int64 = _buf[i].second;
    }
    for (size_t i = 0; i < n; ++i) ptrs[i] = &elems[i];
    Dart_CObject arr; arr.type = Dart_CObject_kArray;
    arr.value.as_array.length = (intptr_t)n; arr.value.as_array.values = ptrs.data();
    Dart_PostCObject_DL(port, &arr);
    _buf.clear();
  }
  std::mutex _qmtx; std::condition_variable _qcv;
  std::queue<std::function<void()>> _q;
  std::vector<std::pair<int64_t,int64_t>> _buf; // worker-only
  std::atomic<int64_t> _port{0};
  bool _running = true;
  std::thread _thread;
};

template <class C> void hammer(const char* name) {
  C c;
  const int producers = 8, perProducer = 2000;
  std::vector<std::thread> ts;
  for (int p = 0; p < producers; ++p)
    ts.emplace_back([&c, p]() {
      for (int i = 0; i < perProducer; ++i) c.submit(p * 100000 + i, i + 1, 42);
    });
  for (auto& t : ts) t.join();
  std::this_thread::sleep_for(std::chrono::milliseconds(50)); // let final batch flush
  std::printf("  %s: submitted %d calls across %d producers\n", name, producers * perProducer, producers);
}

int main() {
  std::printf("TSan coalescer audit:\n");
  hammer<TcCoalescer>("TcCoalescer (mutex+cv window)");
  hammer<BenchCoalescer>("BenchCoalescer (worker queue)");
  std::printf("done (posted sink=%lld)\n", (long long)g_posted.load());
  return 0;
}
