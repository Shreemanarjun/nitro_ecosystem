/**
 * Nitrogern FFI Module Entry Point
 * 
 * This file acts as the primary compilation unit for the native side of the
 * my_camera plugin. It includes the generated C++ bridge logic.
 */

#include <stdint.h>
#include <stdbool.h>

// If you add manual C++ files, include their headers here.
// #include "my_other_local_native_header.h"

// The Generated Nitrogen bridge header
#include "../lib/src/generated/cpp/my_camera.bridge.g.h"

// The Generated Nitrogen bridge source
// (This pattern ensures CocoaPods and CMake both have easy access to the full bridge)
#include "../lib/src/generated/cpp/my_camera.bridge.g.cpp"

extern "C" {
    /**
     * You can add manual non-Nitrogen FFI functions here.
     * Use the `my_camera_` prefix to follow convention.
     */
}
