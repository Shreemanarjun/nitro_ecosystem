#pragma once

#include <stdint.h>

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

NitroError* NitroGetError(void);
void NitroClearError(void);

#ifdef __cplusplus
}
#endif
