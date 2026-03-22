#pragma once

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Methods
double verification_module_multiply(double a, double b);
const char* verification_module_ping(const char* message);
const char* verification_module_ping_async(const char* message);

#ifdef __cplusplus
}
#endif
