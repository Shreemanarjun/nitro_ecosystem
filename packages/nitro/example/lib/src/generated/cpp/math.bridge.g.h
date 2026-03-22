#pragma once

#include <stdint.h>
#include <stdbool.h>

// --- Enums ---
typedef enum {
  ROUNDING_FLOOR = 1,
  ROUNDING_CEIL = 2,
  ROUNDING_ROUND = 3,
} Rounding;

// --- Structs ---
#pragma pack(push, 1)
typedef struct {
  double x; 
  double y; 
  uint8_t* payload; /* zero-copy */
} Point;
#pragma pack(pop)

#ifdef __cplusplus
extern "C" {
#endif

double math_add(double a, double b);
double math_multiply(double a, double b);
void math_process_buffer(uint8_t* data);

#ifdef __cplusplus
}
#endif
