set(NITRO_NATIVE "${CMAKE_CURRENT_SOURCE_DIR}/../src/native")

# The Flutter tooling requires that developers have a version of Visual Studio
# installed that includes CMake 3.14 or later.
cmake_minimum_required(VERSION 3.14)

# Project-level configuration.
set(PROJECT_NAME "benchmark")
project(${PROJECT_NAME} LANGUAGES C CXX)

# This value is used when generating builds using this plugin, so it must
# not be changed.
set(PLUGIN_NAME "benchmark_plugin")

# Build ALL Nitro module libraries (benchmark, benchmark_cpp, nitro_ar) from
# the shared source tree. Each becomes its own shared library, loaded by name
# via DynamicLibrary.open on the Dart side.
add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../src" nitro_modules)

# Define the plugin library target — MethodChannel baseline only; the Nitro
# bridges live in the module libraries above.
add_library(${PLUGIN_NAME} SHARED
  "benchmark_plugin.cpp"
  "benchmark_plugin.h"
  "benchmark_plugin_c_api.cpp"
  "include/benchmark/benchmark_plugin_c_api.h"
)

# Apply a standard set of build settings that are configured in the
# application-level CMakeLists.txt.
apply_standard_settings(${PLUGIN_NAME})

# Symbols are hidden by default to reduce the chance of accidental conflicts
# between plugins. This should not be removed; any symbols that should be
# exported should be explicitly exported with the FLUTTER_PLUGIN_EXPORT macro.
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

# Source include directories and library dependencies.
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_include_directories(${PLUGIN_NAME} PRIVATE
  "${NITRO_NATIVE}"
  "${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/../src"
)

target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin)

# Bundle the Nitro module libraries next to the executable so
# DynamicLibrary.open('benchmark_cpp.dll') etc. resolve at runtime.
set(benchmark_bundled_libraries
  $<TARGET_FILE:benchmark>
  $<TARGET_FILE:benchmark_cpp>
  $<TARGET_FILE:nitro_ar>
  PARENT_SCOPE
)
