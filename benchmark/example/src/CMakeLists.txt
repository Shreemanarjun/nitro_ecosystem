cmake_minimum_required(VERSION 3.10)
project(benchmark_example_library VERSION 0.0.1 LANGUAGES C CXX)


set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
# ── Optimization guard ───────────────────────────────────────────────────────
# The Android Gradle Plugin passes the VARIANT name (e.g. "profile") as
# CMAKE_BUILD_TYPE. CMake only defines per-config flags for
# Debug/Release/RelWithDebInfo/MinSizeRel — an unknown config has EMPTY flag
# sets, so every native source silently compiles at -O0. Flutter's release
# variant maps to RELEASE and is unaffected, but profile builds shipped
# unoptimized native code. Give any non-standard config Release-grade flags.
string(TOUPPER "${CMAKE_BUILD_TYPE}" _NITRO_CFG)
if(NOT "${_NITRO_CFG}" MATCHES "^(DEBUG|RELEASE|RELWITHDEBINFO|MINSIZEREL|)$")
  set(CMAKE_C_FLAGS_${_NITRO_CFG} "-O2 -DNDEBUG")
  set(CMAKE_CXX_FLAGS_${_NITRO_CFG} "-O2 -DNDEBUG")
endif()

set(NITRO_NATIVE "${CMAKE_CURRENT_SOURCE_DIR}/native")
# NITRO_LINK_SPEC_CHECKSUM efef548a6fc06bc7

add_library(benchmark_example SHARED
  "benchmark_example.cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp/benchmark_example.bridge.g.cpp"
  "dart_api_dl.c"
)
target_include_directories(benchmark_example PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp"
  "${NITRO_NATIVE}"
)
target_compile_definitions(benchmark_example PUBLIC DART_SHARED_LIB)
if(ANDROID)
  target_link_libraries(benchmark_example PRIVATE android log)
  target_link_options(benchmark_example PRIVATE "-Wl,-z,max-page-size=16384")
endif()
