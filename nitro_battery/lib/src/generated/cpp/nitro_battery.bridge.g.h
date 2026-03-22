#pragma once

#include <stdint.h>
#include <stdbool.h>

// --- Enums ---
typedef enum {
  CHARGINGSTATE_UNKNOWN = 0,
  CHARGINGSTATE_CHARGING = 1,
  CHARGINGSTATE_DISCHARGING = 2,
  CHARGINGSTATE_FULL = 3,
} ChargingState;

// --- Structs ---
typedef struct {
  int64_t level; 
  int64_t chargingState; 
  double voltage; 
  double temperature; 
} BatteryInfo;

#ifdef __cplusplus
extern "C" {
#endif

// Methods
int64_t nitro_battery_get_battery_level(void);
int8_t nitro_battery_is_charging(void);
int64_t nitro_battery_get_charging_state(void);
void* nitro_battery_get_battery_info(void);

// Properties
int64_t nitro_battery_get_low_power_threshold(void);
void nitro_battery_set_low_power_threshold(int64_t value);

// Streams
// Stream<int> batteryLevelChanges
void nitro_battery_register_battery_level_changes_stream(int64_t dart_port);
void nitro_battery_release_battery_level_changes_stream(int64_t dart_port);

#ifdef __cplusplus
}
#endif
