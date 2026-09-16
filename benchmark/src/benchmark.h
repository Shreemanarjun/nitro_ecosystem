#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#if _WIN32
#include <windows.h>
#else
#include <pthread.h>
#include <unistd.h>
#endif

#if _WIN32
#define FFI_PLUGIN_EXPORT __declspec(dllexport)
#else
#define FFI_PLUGIN_EXPORT
#endif

#ifdef __cplusplus
extern "C" {
#endif

FFI_PLUGIN_EXPORT int sum(int a, int b);
FFI_PLUGIN_EXPORT int sum_long_running(int a, int b);
FFI_PLUGIN_EXPORT double add_double(double a, double b);

// Raw-FFI floor for a pointer argument (the handle-parameter cases): bumps
// and returns the first byte of the 64-byte object from make_ptr().
FFI_PLUGIN_EXPORT void* make_ptr(void);
FFI_PLUGIN_EXPORT int64_t touch_ptr(void* p);

#ifdef __cplusplus
}
#endif
