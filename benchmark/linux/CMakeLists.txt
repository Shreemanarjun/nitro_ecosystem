set(NITRO_NATIVE "${CMAKE_CURRENT_SOURCE_DIR}/../src/native")

# The Flutter tooling requires that developers have CMake 3.10 or later
# installed. You should not increase this version, as doing so will cause
# the plugin to fail to compile for some customers of the plugin.
cmake_minimum_required(VERSION 3.10)

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
  "benchmark_plugin.cc"
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

# Exposes include/benchmark/benchmark_plugin.h to the example app's
# generated_plugin_registrant.cc, which #includes it to call
# BenchmarkPluginRegisterWithRegistrar(). Without this, the registrant fails
# to compile with "benchmark/benchmark_plugin.h: file not found".
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")

target_link_libraries(${PLUGIN_NAME} PRIVATE flutter)
target_link_libraries(${PLUGIN_NAME} PRIVATE PkgConfig::GTK)

# Bundle the Nitro module libraries next to the executable so
# DynamicLibrary.open('libbenchmark_cpp.so') etc. resolve at runtime.
set(benchmark_bundled_libraries
  $<TARGET_FILE:benchmark>
  $<TARGET_FILE:benchmark_cpp>
  $<TARGET_FILE:nitro_ar>
  PARENT_SCOPE
)
