#pragma once

#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include "nitro.h"


// --- Structs ---
typedef struct {
  float* data; 
  int64_t length; 
} FloatBuffer;

#ifdef __cplusplus
extern "C" {
#endif

NitroError* verification_get_error(void);
void verification_clear_error(void);



// Methods
double verification_module_multiply(double a, double b);
const char* verification_module_ping(const char* message);
const char* verification_module_ping_async(const char* message);
void verification_module_throw_error(const char* message);
void* verification_module_process_floats(float* inputs);

#ifdef __cplusplus
}
#endif
