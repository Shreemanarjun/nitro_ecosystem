// The reference workload for cross-bridge comparison: FNV-1a 64-bit.
//
// Every bridge tier (MethodChannel, raw dart:ffi, Nitro) and every platform
// (Kotlin, Swift, C++, GTK) implements EXACTLY this algorithm over the same
// payload, and must produce the same 64-bit hash. The benchmark harness
// verifies the results agree before timing anything — so the comparison is
// provably measuring the same work, and only the bridge differs.
//
// FNV-1a was chosen because it is:
//   * a handful of lines, trivially identical in C/C++/Kotlin/Swift/Dart
//     (64-bit multiply wraps mod 2^64 in all of them),
//   * strictly sequential and CPU-bound (no allocation, no vectorizable
//     shortcuts a smart compiler could elide),
//   * self-verifying — a single wrong byte or iteration changes the result.
//
// Reference:
//   hash = 0xcbf29ce484222325
//   repeat `rounds` times:
//     for each byte b in data: hash = (hash ^ b) * 0x100000001b3
#ifndef NITRO_BENCH_WORKLOAD_H_
#define NITRO_BENCH_WORKLOAD_H_

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

static inline uint64_t nitro_bench_fnv1a(const uint8_t* data, int64_t len,
                                         int64_t rounds) {
  uint64_t hash = 0xcbf29ce484222325ULL;
  for (int64_t r = 0; r < rounds; r++) {
    for (int64_t i = 0; i < len; i++) {
      hash ^= data[i];
      hash *= 0x100000001b3ULL;
    }
  }
  return hash;
}

#ifdef __cplusplus
}
#endif

#endif  // NITRO_BENCH_WORKLOAD_H_
