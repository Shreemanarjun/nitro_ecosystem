cmake_minimum_required(VERSION 3.10)
project(nitrogen_cli_library VERSION 0.0.1 LANGUAGES C CXX)

set(NITRO_NATIVE "${CMAKE_CURRENT_SOURCE_DIR}/../../packages/nitro/src/native")

add_library(nitrogen_cli SHARED
  "nitrogen_cli.cpp"
  "${NITRO_NATIVE}/dart_api_dl.c"
)
target_include_directories(nitrogen_cli PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp"
  "${NITRO_NATIVE}"
)
target_compile_definitions(nitrogen_cli PUBLIC DART_SHARED_LIB)
if(ANDROID)
  target_link_libraries(nitrogen_cli PRIVATE android log)
  target_link_options(nitrogen_cli PRIVATE "-Wl,-z,max-page-size=16384")
endif()
