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
  uint8_t* data; /* zero-copy */
  int64_t width; 
  int64_t height; 
  int64_t stride; 
  int64_t timestampNs; 
} CameraFrame;

extern "C" {
#endif

NitroError* NitroGetError(void);
void NitroClearError(void);


// Methods
double my_camera_add(double a, double b);
const char* my_camera_get_greeting(const char* name);
void* my_camera_get_available_devices(void);

// Streams
// Stream<CameraFrame> frames
void my_camera_register_frames_stream(int64_t dart_port);
void my_camera_release_frames_stream(int64_t dart_port);
// Stream<CameraFrame> coloredFrames
void my_camera_register_colored_frames_stream(int64_t dart_port);
void my_camera_release_colored_frames_stream(int64_t dart_port);

#ifdef __cplusplus
}
#endif
