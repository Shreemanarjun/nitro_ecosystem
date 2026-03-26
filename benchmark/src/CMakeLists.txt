cmake_minimum_required(VERSION 3.10)
project(benchmark_library VERSION 0.0.1 LANGUAGES C CXX)

set(NITRO_NATIVE "/Users/shreemanarjunsahu/.puro/shared/pub_cache/hosted/pub.dev/nitro-0.2.2/src/native")
set(GENERATED_CPP "${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp")

add_library(benchmark SHARED
  "${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp/benchmark.bridge.g.cpp"
  "benchmark.cpp"
  "benchmark.c"
  "dart_api_dl.c"
)

target_include_directories(benchmark PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${GENERATED_CPP}"
  "${NITRO_NATIVE}"
)

target_compile_definitions(benchmark PUBLIC DART_SHARED_LIB)

if(ANDROID)
  target_link_libraries(benchmark PRIVATE android log)
  target_link_options(benchmark PRIVATE "-Wl,-z,max-page-size=16384")
endif()
