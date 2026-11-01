cmake_minimum_required(VERSION 3.10)
project(nitro_example_library VERSION 0.0.1 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(NITRO_NATIVE "${CMAKE_CURRENT_SOURCE_DIR}/native")
# NITRO_LINK_SPEC_CHECKSUM 15ecd05df2d00ad3

add_library(nitro_example SHARED
  "nitro_example.cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp/nitro_example.bridge.g.cpp"
  "dart_api_dl.c"
)
target_include_directories(nitro_example PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp"
  "${NITRO_NATIVE}"
)
target_compile_definitions(nitro_example PUBLIC DART_SHARED_LIB)
if(ANDROID)
  target_link_libraries(nitro_example PRIVATE android log)
  target_link_options(nitro_example PRIVATE "-Wl,-z,max-page-size=16384")
elseif(WIN32)
  target_link_libraries(nitro_example PRIVATE dbghelp)
elseif(UNIX AND NOT APPLE)
  target_link_libraries(nitro_example PRIVATE dl pthread)
endif()

add_library(math SHARED
  "${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp/math.bridge.g.cpp"
  "dart_api_dl.c"
)
target_include_directories(math PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp"
  "${NITRO_NATIVE}"
)
set_target_properties(math PROPERTIES OUTPUT_NAME "math")
target_compile_definitions(math PUBLIC DART_SHARED_LIB)
if(ANDROID)
  target_link_libraries(math PRIVATE android log)
  target_link_options(math PRIVATE "-Wl,-z,max-page-size=16384")
elseif(WIN32)
  target_link_libraries(math PRIVATE dbghelp)
elseif(UNIX AND NOT APPLE)
  target_link_libraries(math PRIVATE dl pthread)
endif()
