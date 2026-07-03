#include <stdint.h>
#include <stdbool.h>
#include "nitro.h"
#include "nitro_workload.h"

extern "C" {
  /// Simple double addition for raw FFI benchmarking.
  NITRO_EXPORT double add_double(double a, double b) {
    return a + b;
  }

  /// Reference workload (FNV-1a, see nitro_workload.h) for the raw-FFI tier.
  NITRO_EXPORT uint64_t fnv1a_hash(const uint8_t* data, int64_t length,
                                   int64_t rounds) {
    return nitro_bench_fnv1a(data, length, rounds);
  }

  NITRO_EXPORT int64_t send_large_buffer(const uint8_t* buffer, int64_t length) {
    if (!buffer || length <= 0) return 0;
    // Force memory access to prevent optimization
    uint64_t sum = 0;
    for (int64_t i = 0; i < length; i += 4096) {
        sum += buffer[i];
    }
    return static_cast<int64_t>(sum == 0 ? length : length + 1);
  }

  NITRO_EXPORT int64_t send_large_buffer_noop(const uint8_t* buffer, int64_t length) {
    (void)buffer; // intentionally unused — baseline dispatch overhead only
    return length;
  }
}
