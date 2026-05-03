#pragma once

#include <stdint.h>
#include <stdbool.h>

#if _WIN32
#define NITRO_EXPORT __declspec(dllexport)
#else
#define NITRO_EXPORT __attribute__((visibility("default"))) __attribute__((used))
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
  int8_t hasError;
  const char* name;
  const char* message;
  const char* code;
  const char* stackTrace;
} NitroError;

#ifdef __cplusplus
}
#endif
