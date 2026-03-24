#pragma once

#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>

typedef struct {
  int8_t hasError;
  const char* name;
  const char* message;
  const char* code;
  const char* stackTrace;
} NitroError;

// --- Structs ---
typedef struct {
  float* data; /* zero-copy */
  int64_t length; 
} FloatBuffer;

extern "C" {
#endif

NitroError* NitroGetError(void);
void NitroClearError(void);


// Methods
double verification_module_multiply(double a, double b);
const char* verification_module_ping(const char* message);
const char* verification_module_ping_async(const char* message);
void verification_module_throw_error(const char* message);
void* verification_module_process_floats(float* inputs);

#ifdef __cplusplus
}
#endif
