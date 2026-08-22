cmake_minimum_required(VERSION 3.10)
project(nitro_web_e2e_library VERSION 0.0.1 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(NITRO_NATIVE "${CMAKE_CURRENT_SOURCE_DIR}/native")
# NITRO_LINK_SPEC_CHECKSUM 2fb82c521e7cb0b9

add_library(nitro_web_e2e SHARED
  "nitro_web_e2e.cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp/nitro_web_e2e.bridge.g.cpp"
  "dart_api_dl.c"
)
target_include_directories(nitro_web_e2e PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp"
  "${NITRO_NATIVE}"
)
target_compile_definitions(nitro_web_e2e PUBLIC DART_SHARED_LIB)
if(ANDROID)
  target_link_libraries(nitro_web_e2e PRIVATE android log)
  target_link_options(nitro_web_e2e PRIVATE "-Wl,-z,max-page-size=16384")
elseif(WIN32)
  target_link_libraries(nitro_web_e2e PRIVATE dbghelp)
elseif(UNIX AND NOT APPLE)
  target_link_libraries(nitro_web_e2e PRIVATE dl pthread)
endif()

add_library(web_echo SHARED
  "${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp/web_echo.bridge.g.cpp"
  "dart_api_dl.c"
)
target_include_directories(web_echo PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp"
  "${NITRO_NATIVE}"
)
set_target_properties(web_echo PROPERTIES OUTPUT_NAME "web_echo")
target_compile_definitions(web_echo PUBLIC DART_SHARED_LIB)
if(ANDROID)
  target_link_libraries(web_echo PRIVATE android log)
  target_link_options(web_echo PRIVATE "-Wl,-z,max-page-size=16384")
elseif(WIN32)
  target_link_libraries(web_echo PRIVATE dbghelp)
elseif(UNIX AND NOT APPLE)
  target_link_libraries(web_echo PRIVATE dl pthread)
endif()
