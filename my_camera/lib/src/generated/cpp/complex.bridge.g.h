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

// --- Enums ---
typedef enum {
  DEVICESTATUS_IDLE = 0,
  DEVICESTATUS_BUSY = 1,
  DEVICESTATUS_ERROR = 2,
  DEVICESTATUS_FATAL = 3,
} DeviceStatus;

// --- Structs ---
#pragma pack(push, 1)
typedef struct {
  double temperature; 
  double humidity; 
  int64_t lastUpdate; 
} SensorData;
#pragma pack(pop)

typedef struct {
  int64_t sequence; 
  uint8_t* buffer; /* zero-copy */
  int64_t size; 
} Packet;

extern "C" {
#endif

NitroError* NitroGetError(void);
void NitroClearError(void);


// Methods
int64_t complex_module_calculate(int64_t seed, double factor, int8_t enabled);
const char* complex_module_fetch_metadata(const char* url);
int64_t complex_module_get_status(void);
void complex_module_update_sensors(void* data);
void* complex_module_generate_packet(int64_t type);

// Properties
double complex_module_get_battery_level(void);
void complex_module_set_config(const char* value);

// Streams
// Stream<SensorData> sensorStream
void complex_module_register_sensor_stream_stream(int64_t dart_port);
void complex_module_release_sensor_stream_stream(int64_t dart_port);
// Stream<Packet> dataStream
void complex_module_register_data_stream_stream(int64_t dart_port);
void complex_module_release_data_stream_stream(int64_t dart_port);

#ifdef __cplusplus
}
#endif
