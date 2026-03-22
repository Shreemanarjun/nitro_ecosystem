# The Flutter tooling requires that developers have CMake 3.10 or later
# installed. You should not increase this version, as doing so will cause
# the plugin to fail to compile for some customers of the plugin.
cmake_minimum_required(VERSION 3.10)

project(my_camera_library VERSION 0.0.1 LANGUAGES C)

add_library(my_camera SHARED
  "my_camera.c"
)

set_target_properties(my_camera PROPERTIES
  PUBLIC_HEADER my_camera.h
  OUTPUT_NAME "my_camera"
)

target_compile_definitions(my_camera PUBLIC DART_SHARED_LIB)

if (ANDROID)
  # Support Android 15 16k page size
  target_link_options(my_camera PRIVATE "-Wl,-z,max-page-size=16384")
endif()
