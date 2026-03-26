/**
 * Nitrogen FFI Module Entry Point — my_camera
 *
 * This file is the single compilation unit for the native side of the
 * my_camera plugin. It includes every generated bridge in order so that
 * the lib-level symbols (JNI_OnLoad, error state) are defined exactly once
 * thanks to the NITRO_MY_CAMERA_LIB_INIT_DEFINED include guard.
 *
 * ─── Adding a new NativeImpl.cpp module ───────────────────────────────────
 * 1. Create lib/src/{module}.native.dart with @NitroModule(androidImpl:
 * NativeImpl.cpp, ...)
 * 2. Run: flutter pub run build_runner build
 * 3. Create src/{module}_impl.hpp implementing Hybrid{Module}
 * 4. #include "{module}_impl.hpp" below and register in the init function.
 * ──────────────────────────────────────────────────────────────────────────
 */

#include <memory>
#include <stdbool.h>
#include <stdint.h>

// ── Generated bridge sources ──────────────────────────────────────────────
// The first #include defines the lib-level guard (JNI_OnLoad, error state).
// Subsequent includes skip those thanks to #ifndef guards in each file.
#include "../lib/src/generated/cpp/math.bridge.g.cpp"
#include "../lib/src/generated/cpp/my_camera.bridge.g.cpp"

// ── C++ implementation headers ────────────────────────────────────────────
#include "math_impl.hpp"

// ── Module registration ───────────────────────────────────────────────────
// Called once at app startup (e.g. from Activity.onCreate or AppDelegate).
extern "C" {
/**
 * Initialize all C++ NitroModule implementations.
 * Call this once before making any Dart FFI calls.
 */
void my_camera_initialize_cpp_modules() {
  nitro::MathModuleRegistry::registerImpl(std::make_shared<nitro::MathImpl>());
}
}
