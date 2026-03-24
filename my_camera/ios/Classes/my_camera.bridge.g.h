#pragma once

#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include "nitro.h"


// --- Structs ---
typedef struct {
  uint8_t* data; /* zero-copy */
  int64_t width; 
  int64_t height; 
  int64_t stride; 
  int64_t timestampNs; 
} CameraFrame;

#ifdef __cplusplus
extern "C" {
#endif

NitroError* my_camera_get_error(void);
void my_camera_clear_error(void);



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
