cmake_minimum_required(VERSION 3.10)
project(my_camera_library VERSION 0.0.1 LANGUAGES C CXX)

set(NITRO_NATIVE "${CMAKE_CURRENT_SOURCE_DIR}/../../packages/nitro/src/native")

# ── my_camera module ─────────────────────────────────────────────────────────
add_library(my_camera SHARED
  "my_camera.cpp"
  "dart_api_dl.c"
)

target_include_directories(my_camera PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp"
  "${NITRO_NATIVE}"
)

set_target_properties(my_camera PROPERTIES OUTPUT_NAME "my_camera")
target_compile_definitions(my_camera PUBLIC DART_SHARED_LIB)

if(ANDROID)
  target_link_libraries(my_camera PRIVATE android log)
  target_link_options(my_camera PRIVATE "-Wl,-z,max-page-size=16384")
endif()

# ── verification module ───────────────────────────────────────────────────────
add_library(verification SHARED
  "${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp/verification.bridge.g.cpp"
  "dart_api_dl.c"
)

target_include_directories(verification PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp"
  "${NITRO_NATIVE}"
)

set_target_properties(verification PROPERTIES OUTPUT_NAME "verification")
target_compile_definitions(verification PUBLIC DART_SHARED_LIB)

if(ANDROID)
  target_link_libraries(verification PRIVATE android log)
  target_link_options(verification PRIVATE "-Wl,-z,max-page-size=16384")
endif()

# ── complex module ────────────────────────────────────────────────────────────
add_library(complex SHARED
  "${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp/complex.bridge.g.cpp"
  "dart_api_dl.c"
)

target_include_directories(complex PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp"
  "${NITRO_NATIVE}"
)

set_target_properties(complex PROPERTIES OUTPUT_NAME "complex")
target_compile_definitions(complex PUBLIC DART_SHARED_LIB)

if(ANDROID)
  target_link_libraries(complex PRIVATE android log)
  target_link_options(complex PRIVATE "-Wl,-z,max-page-size=16384")
endif()
