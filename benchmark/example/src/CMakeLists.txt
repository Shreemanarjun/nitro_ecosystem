cmake_minimum_required(VERSION 3.10)
project(benchmark_example_library VERSION 0.0.1 LANGUAGES C CXX)

set(NITRO_NATIVE "/Users/shreemanarjunsahu/personal/flutter_package/nitro_ecosystem/benchmark/packages/nitro/src/native")

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
