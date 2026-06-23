cmake_minimum_required(VERSION 3.10)
project(nitro_generator_library VERSION 0.0.1 LANGUAGES C CXX)


set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(NITRO_NATIVE "${CMAKE_CURRENT_SOURCE_DIR}/native")
# NITRO_LINK_SPEC_CHECKSUM efef548a6fc06bc7

add_library(nitro_generator SHARED
  "nitro_generator.cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp/nitro_generator.bridge.g.cpp"
  "${NITRO_NATIVE}/dart_api_dl.c"
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
