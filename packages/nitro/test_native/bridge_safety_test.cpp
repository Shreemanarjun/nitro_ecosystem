// Memory-safety harness for the header-only C++ bridge runtime.
//
// Compiles the real runtime headers (completion batch, worker pool, background
// job table) into one translation unit and drives their memory-management-heavy
// paths under AddressSanitizer + UndefinedBehaviorSanitizer (use-after-free,
// out-of-bounds, bad frees, UB) and ThreadSanitizer (races in the pool / batch).
//
// It is NOT a functional test — the Dart integration suite covers behaviour.
// The one Dart dependency, Dart_PostCObject_DL, is a global function pointer we
// point at a capture that reads every byte of each posted object, so any
// dangling pointer a deep-copy left behind is dereferenced here and caught.
//
// Run via run.sh (configures, builds, runs both sanitizer binaries). Proof the
// harness bites: build once with -DNITRO_SAFETY_SELFTEST and ASan must abort.
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <thread>
#include <vector>

#include "dart_api_dl.h"  // declares the Dart_*_DL globals as extern
#include "nitro_completion_batch.h"
#include "nitro_worker_pool.h"
#include "nitro_background.h"

// dart_api_dl.h only declares the DL function pointers (the real storage lives
// in dart_api_dl.c, which we don't link). Define the one the runtime uses; main
// points it at the capture below.
extern "C" {
Dart_PostCObject_Type Dart_PostCObject_DL = nullptr;
}

#define CHECK(cond)                                                            \
  do {                                                                         \
    if (!(cond)) {                                                             \
      std::fprintf(stderr, "CHECK FAILED: %s (%s:%d)\n", #cond, __FILE__,      \
                   __LINE__);                                                  \
      std::abort();                                                            \
    }                                                                          \
  } while (0)

// ── Captured posts ──────────────────────────────────────────────────────────
namespace {
struct Post {
  int64_t port;
  int type;
  intptr_t arrayLen;
};
std::vector<Post> g_posts;
std::vector<int64_t> g_freed;
char g_lastStrFirst = 0;
uint8_t g_lastTdFirst = 0;

// Read every byte of a posted object. On the batched/copied paths this walks
// the deep copy the batcher made, so a dangling or under-sized allocation is
// dereferenced right here where ASan can see it.
void touch(const Dart_CObject* o) {
  switch (o->type) {
    case Dart_CObject_kString: {
      const char* s = o->value.as_string;
      g_lastStrFirst = s ? s[0] : 0;
      break;
    }
    case Dart_CObject_kTypedData: {
      const intptr_t n = o->value.as_typed_data.length;
      const uint8_t* v = o->value.as_typed_data.values;
      if (n > 0) g_lastTdFirst = v[0];
      for (intptr_t i = 0; i < n; i++) {
        volatile uint8_t b = v[i];
        (void)b;
      }
      break;
    }
    case Dart_CObject_kArray: {
      const intptr_t n = o->value.as_array.length;
      for (intptr_t i = 0; i < n; i++) touch(o->value.as_array.values[i]);
      break;
    }
    default:
      break;
  }
}

bool capturePost(Dart_Port port, Dart_CObject* m) {
  Post p;
  p.port = port;
  p.type = m->type;
  p.arrayLen = (m->type == Dart_CObject_kArray) ? m->value.as_array.length : -1;
  touch(m);
  g_posts.push_back(p);
  return true;
}

void freeItemCb(int64_t v) { g_freed.push_back(v); }

// ── NitroCompletionBatch: deep-copy of a buffered completion ─────────────────
// A second post to an in-flight batch port is deep-copied into `pending`; the
// copy must own its string/typed-data/array storage independently of the
// caller's. We mutate the originals before ack and assert the flushed copy kept
// the pre-mutation bytes (so the copy did not alias freed/overwritten memory).
void test_completion_batch_deepcopy() {
  NitroCompletionBatch b;
  g_posts.clear();
  const int64_t P = 7777;
  const int64_t id1 = b.bind(P);
  const int64_t id2 = b.bind(P);

  Dart_CObject scalar{};
  scalar.type = Dart_CObject_kInt64;
  scalar.value.as_int64 = 42;
  CHECK(b.post(id1, &scalar));  // not in flight → posted directly, marks in-flight
  CHECK(g_posts.size() == 1);

  char msg[] = "hello";
  uint8_t bytes[4] = {1, 2, 3, 4};
  Dart_CObject s{};
  s.type = Dart_CObject_kString;
  s.value.as_string = msg;
  Dart_CObject td{};
  td.type = Dart_CObject_kTypedData;
  td.value.as_typed_data.type = Dart_TypedData_kUint8;
  td.value.as_typed_data.length = 4;
  td.value.as_typed_data.values = bytes;
  Dart_CObject* kids[2] = {&s, &td};
  Dart_CObject arr{};
  arr.type = Dart_CObject_kArray;
  arr.value.as_array.length = 2;
  arr.value.as_array.values = kids;

  CHECK(b.post(id2, &arr));    // in flight → deep-copied into pending
  CHECK(g_posts.size() == 1);  // still buffered, not posted

  msg[0] = 'X';   // clobber the originals: a copy that aliased them would show these
  bytes[0] = 99;

  b.ack(P);                    // flush: posts kArray [id2, copied-obj]
  CHECK(g_posts.size() == 2);
  CHECK(g_posts[1].type == Dart_CObject_kArray);
  CHECK(g_lastStrFirst == 'h');  // snapshot kept the pre-mutation value
  CHECK(g_lastTdFirst == 1);

  b.ack(P);  // idempotent: nothing pending → goes idle, no post
  CHECK(g_posts.size() == 2);
}

// ── NitroCompletionBatch: stream coalesce + drop-on-uncoalesce ───────────────
// A buffered stream item dropped by uncoalesce() must be released through the
// freeItem hook exactly once (the ownership-release path).
void test_completion_batch_coalesce_drop() {
  NitroCompletionBatch b;
  g_posts.clear();
  g_freed.clear();
  const int64_t P = 8888;
  b.coalesce(P, &freeItemCb);

  Dart_CObject a{};
  a.type = Dart_CObject_kInt64;
  a.value.as_int64 = 111;
  CHECK(b.post(P, &a));  // in flight → posted directly as a 1-item stream batch
  CHECK(g_posts.size() == 1);

  Dart_CObject c{};
  c.type = Dart_CObject_kInt64;
  c.value.as_int64 = 222;
  CHECK(b.post(P, &c));  // buffered (copied)
  CHECK(g_posts.size() == 1);

  b.uncoalesce(P);  // drop the buffered item → freeItem(222)
  CHECK(g_freed.size() == 1);
  CHECK(g_freed[0] == 222);
}

// ── NitroJob: inline + heap storage, move, destroy (non-trivial captures) ───
// The worker-pool job type. ASan/LSan here check that the type-erased object is
// constructed, moved and destroyed exactly once on both storage paths (a leak
// or double-free in the hand-rolled vtable shows up immediately).
void test_nitrojob() {
  // Inline path, non-trivial capture (std::string): move-ctor then move-assign,
  // then invoke the surviving instance.
  std::string captured;
  {
    std::string payload = "inline-capture-payload";
    NitroJob a([payload, &captured] { captured = payload; });
    NitroJob b(std::move(a));  // move-construct (inline: move + destroy source)
    NitroJob c;
    c = std::move(b);  // move-assign into an empty job
    c();               // run the one surviving instance
  }
  CHECK(captured == "inline-capture-payload");

  // Heap path: a capture larger than the 64B inline buffer falls back to the
  // heap (alloc on construct, pointer-steal on move, delete on destroy).
  int ran = 0;
  {
    struct Big {
      char bytes[256];
    };
    Big big{};
    big.bytes[0] = 7;
    NitroJob a([big, &ran] { ran = big.bytes[0]; });
    NitroJob b(std::move(a));  // move-construct (heap: steal pointer)
    b();
  }
  CHECK(ran == 7);
}

// ── NitroWorkerPool: both enqueue paths under TSan ──────────────────────────
// The pool spawns DETACHED workers that loop forever and is never stopped or
// joined — the generated bridge holds it as a process-lifetime global
// (`static NitroWorkerPool g_nitro_pool_math;`). Destructing it while workers
// are live is a use-after-free of its queue/mutex (TSan confirms this), so the
// test mirrors production: one leaked, globally-reachable pool, never destroyed
// (reachable from a global → not a leak for LSan).
NitroWorkerPool* g_pool = new NitroWorkerPool();

void test_worker_pool() {
  std::atomic<int> n{0};
  const int N = 500;
  for (int i = 0; i < N; i++)
    g_pool->enqueue([&] { n.fetch_add(1, std::memory_order_relaxed); });
  for (int i = 0; i < N; i++)
    g_pool->enqueueBounded([&] { n.fetch_add(1, std::memory_order_relaxed); },
                           /*maxQueued=*/0, /*dropOldest=*/0);
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
  while (n.load() < 2 * N && std::chrono::steady_clock::now() < deadline)
    std::this_thread::yield();
  CHECK(n.load() == 2 * N);
}

// ── NitroBgTable: submit → take → emit → complete, and the fail() array ──────
void test_bg_table() {
  NitroBgTable t;
  g_posts.clear();
  const char* entry = "doWork";
  uint8_t args[3] = {9, 8, 7};
  bool started = true;
  const int64_t id = t.submit(entry, args, sizeof(args), /*dartPort=*/1234, &started);
  CHECK(!started);  // no host registered
  CHECK(t.activeCount() == 1);

  int64_t outId = 0;
  std::string outArgs;
  CHECK(t.take(entry, /*id=*/0, &outId, &outArgs));
  CHECK(outId == id);
  CHECK(outArgs.size() == 3);
  CHECK((uint8_t)outArgs[0] == 9 && (uint8_t)outArgs[2] == 7);

  uint8_t item[2] = {1, 2};
  CHECK(t.emit(id, item, sizeof(item)));
  CHECK(g_posts.size() == 1);
  CHECK(g_posts[0].type == Dart_CObject_kTypedData);

  uint8_t result[1] = {5};
  CHECK(t.complete(id, result, 1));
  CHECK(g_posts.size() == 2);
  CHECK(t.activeCount() == 0);

  const int64_t id2 = t.submit(entry, args, 3, /*dartPort=*/4321, &started);
  int64_t o2 = 0;
  std::string a2;
  CHECK(t.take(entry, 0, &o2, &a2));
  CHECK(t.fail(id2, "boom", "stack"));  // posts [msg, stack, entry] as a kArray
  CHECK(g_posts.size() == 3);
  CHECK(g_posts[2].type == Dart_CObject_kArray);
  CHECK(g_posts[2].arrayLen == 3);
  CHECK(t.activeCount() == 0);
}
}  // namespace

int main() {
#ifdef NITRO_SAFETY_SELFTEST
  // Proof the sanitizer bites: a one-past-the-end heap read ASan must abort on.
  {
    uint8_t* p = new uint8_t[4];
    volatile uint8_t x = p[4];
    (void)x;
    delete[] p;
  }
#endif
  Dart_PostCObject_DL = &capturePost;

  test_completion_batch_deepcopy();
  std::printf("ok: completion_batch_deepcopy\n");
  test_completion_batch_coalesce_drop();
  std::printf("ok: completion_batch_coalesce_drop\n");
  test_nitrojob();
  std::printf("ok: nitrojob\n");
  test_worker_pool();
  std::printf("ok: worker_pool\n");
  test_bg_table();
  std::printf("ok: bg_table\n");

  std::printf("ALL BRIDGE SAFETY CHECKS PASSED\n");
  return 0;
}
