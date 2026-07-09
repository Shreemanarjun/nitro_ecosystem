cmake_minimum_required(VERSION 3.10)
project(benchmark_library VERSION 0.0.1 LANGUAGES C CXX)


set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(NITRO_NATIVE "${CMAKE_CURRENT_SOURCE_DIR}/native")
# NITRO_LINK_SPEC_CHECKSUM ae61dfd46297f9eb
set(GENERATED_CPP "${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp")

# ── Swift/Kotlin bridge (NativeImpl.swift / NativeImpl.kotlin) ────────────────
add_library(benchmark SHARED
  "${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp/benchmark.bridge.g.cpp"
  "benchmark.cpp"
  "benchmark.c"
  "dart_api_dl.c"
)

if(NOT ANDROID)
  target_sources(benchmark PRIVATE "HybridBenchmark.cpp")
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
  "HybridBenchmarkCpp.cpp"
  "benchmark.cpp"
  "benchmark.c"
  "dart_api_dl.c"
)

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
