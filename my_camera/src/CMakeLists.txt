cmake_minimum_required(VERSION 3.10)
project(my_camera_library VERSION 0.0.1 LANGUAGES C CXX)

set(BRIDGE_CPP "${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp/my_camera.bridge.g.cpp")
set(BRIDGE_H   "${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp/my_camera.bridge.g.h")

add_library(my_camera SHARED
  "my_camera.cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/../../packages/nitro/src/native/dart_api_dl.c"
)

target_include_directories(my_camera PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/../../packages/nitro/src/native"
)

set_target_properties(my_camera PROPERTIES
  PUBLIC_HEADER "${BRIDGE_H}"
  OUTPUT_NAME   "my_camera"
)

target_compile_definitions(my_camera PUBLIC DART_SHARED_LIB)

if(ANDROID)
  target_link_libraries(my_camera PRIVATE android log)
  target_link_options(my_camera PRIVATE "-Wl,-z,max-page-size=16384")
endif()
