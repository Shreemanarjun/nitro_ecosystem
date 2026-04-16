cmake_minimum_required(VERSION 3.10)
project(nitro_generator_library VERSION 0.0.1 LANGUAGES C CXX)

set(NITRO_NATIVE "/Users/shreemanarjunsahu/personal/flutter_package/nitro_ecosystem/packages/packages/nitro/src/native")

add_library(nitro_generator SHARED
  "nitro_generator.cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp/nitro_generator.bridge.g.cpp"
  "dart_api_dl.c"
)
target_include_directories(nitro_generator PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp"
  "${NITRO_NATIVE}"
)
target_compile_definitions(nitro_generator PUBLIC DART_SHARED_LIB)
if(ANDROID)
  target_link_libraries(nitro_generator PRIVATE android log)
  target_link_options(nitro_generator PRIVATE "-Wl,-z,max-page-size=16384")
endif()
