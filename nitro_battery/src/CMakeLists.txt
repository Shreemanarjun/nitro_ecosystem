cmake_minimum_required(VERSION 3.10)
project(nitro_battery_library VERSION 0.0.1 LANGUAGES C CXX)

set(NITRO_NATIVE "${CMAKE_CURRENT_SOURCE_DIR}/../../packages/nitro/src/native")
set(GENERATED_CPP "${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp")

add_library(nitro_battery SHARED
  "nitro_battery.cpp"
  "${NITRO_NATIVE}/dart_api_dl.c"
)

target_include_directories(nitro_battery PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${GENERATED_CPP}"
  "${NITRO_NATIVE}"
)

target_compile_definitions(nitro_battery PUBLIC DART_SHARED_LIB)

if(ANDROID)
  target_link_libraries(nitro_battery PRIVATE android log)
  target_link_options(nitro_battery PRIVATE "-Wl,-z,max-page-size=16384")
endif()
