cmake_minimum_required(VERSION 3.10)
project(benchmark_library VERSION 0.0.1 LANGUAGES C CXX)


set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# ── Optimization guard (issue: -O0 native code in Flutter profile mode) ──────
# The Android Gradle Plugin passes the VARIANT name (e.g. "profile") as
# CMAKE_BUILD_TYPE. CMake only defines per-config flags for
# Debug/Release/RelWithDebInfo/MinSizeRel — an unknown config has EMPTY flag
# sets, so every native source silently compiles at -O0. Flutter's release
# variant maps to RELEASE and is unaffected; profile (the benchmarking mode
# of record) was shipping unoptimized native code. Give any non-standard
# config Release-grade optimization.
string(TOUPPER "${CMAKE_BUILD_TYPE}" _NITRO_CFG)
if(NOT "${_NITRO_CFG}" MATCHES "^(DEBUG|RELEASE|RELWITHDEBINFO|MINSIZEREL|)$")
  set(CMAKE_C_FLAGS_${_NITRO_CFG} "-O2 -DNDEBUG")
  set(CMAKE_CXX_FLAGS_${_NITRO_CFG} "-O2 -DNDEBUG")
endif()
set(NITRO_NATIVE "${CMAKE_CURRENT_SOURCE_DIR}/native")
# NITRO_LINK_SPEC_CHECKSUM ca6155f3cd2a36bc
set(GENERATED_CPP "${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp")

# ── Swift/Kotlin bridge (NativeImpl.swift / NativeImpl.kotlin) ────────────────
add_library(benchmark SHARED
  "${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp/benchmark.bridge.g.cpp"
  "benchmark.cpp"
  "benchmark.c"
  "dart_api_dl.c"
)

if(NOT ANDROID)
  if(DEFINED NITRO_IMPL_SRC_benchmark)
    target_sources(benchmark PRIVATE "${NITRO_IMPL_SRC_benchmark}")
  else()
    target_sources(benchmark PRIVATE "HybridBenchmark.cpp")
  endif()
endif()
target_include_directories(benchmark PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${GENERATED_CPP}"
  "${NITRO_NATIVE}"
)

target_compile_definitions(benchmark PUBLIC DART_SHARED_LIB)

if(ANDROID)
  target_link_libraries(benchmark PRIVATE android log)
  target_link_options(benchmark PRIVATE "-Wl,-z,max-page-size=16384")
elseif(WIN32)
  target_link_libraries(benchmark PRIVATE dbghelp)
elseif(UNIX AND NOT APPLE)
  target_link_libraries(benchmark PRIVATE dl pthread)
endif()

# ── Direct C++ dispatch (NativeImpl.cpp) ─────────────────────────────────────
add_library(benchmark_cpp SHARED
  "${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp/benchmark_cpp.bridge.g.cpp"
  "benchmark.cpp"
  "benchmark.c"
  "dart_api_dl.c"
)
if(DEFINED NITRO_IMPL_SRC_benchmark_cpp)
  target_sources(benchmark_cpp PRIVATE "${NITRO_IMPL_SRC_benchmark_cpp}")
else()
  target_sources(benchmark_cpp PRIVATE "HybridBenchmarkCpp.cpp")
endif()

target_include_directories(benchmark_cpp PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${GENERATED_CPP}"
  "${NITRO_NATIVE}"
)

target_compile_definitions(benchmark_cpp PUBLIC DART_SHARED_LIB)

if(ANDROID)
  target_link_libraries(benchmark_cpp PRIVATE android log)
  target_link_options(benchmark_cpp PRIVATE "-Wl,-z,max-page-size=16384")
elseif(WIN32)
  target_link_libraries(benchmark_cpp PRIVATE dbghelp)
elseif(UNIX AND NOT APPLE)
  target_link_libraries(benchmark_cpp PRIVATE dl pthread)
endif()

add_library(nitro_ar SHARED
  "${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp/nitro_ar.bridge.g.cpp"
  "dart_api_dl.c"
)
target_include_directories(nitro_ar PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp"
  "${NITRO_NATIVE}"
)
set_target_properties(nitro_ar PROPERTIES OUTPUT_NAME "nitro_ar")
target_compile_definitions(nitro_ar PUBLIC DART_SHARED_LIB)
if(ANDROID)
  target_link_libraries(nitro_ar PRIVATE android log)
  target_link_options(nitro_ar PRIVATE "-Wl,-z,max-page-size=16384")
elseif(WIN32)
  target_link_libraries(nitro_ar PRIVATE dbghelp)
elseif(UNIX AND NOT APPLE)
  target_link_libraries(nitro_ar PRIVATE dl pthread)
endif()
