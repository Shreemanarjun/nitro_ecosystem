# Memory-safety harness for the header-only C++ bridge runtime.
# Builds the same source twice: once under ASan+UBSan, once under TSan (the two
# cannot be combined). Not part of the Flutter plugin build — standalone, run
# via run.sh locally or in Linux CI.
cmake_minimum_required(VERSION 3.13)
project(nitro_bridge_safety CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Threads REQUIRED)

set(SRC ${CMAKE_CURRENT_SOURCE_DIR}/bridge_safety_test.cpp)
set(RUNTIME_INC ${CMAKE_CURRENT_SOURCE_DIR}/../src/native)

function(add_sanitizer_target name flags)
  add_executable(${name} ${SRC})
  target_include_directories(${name} PRIVATE ${RUNTIME_INC})
  target_compile_options(${name} PRIVATE -g -O1 -fno-omit-frame-pointer ${flags})
  target_link_options(${name} PRIVATE ${flags})
  target_link_libraries(${name} PRIVATE Threads::Threads)
endfunction()

add_sanitizer_target(bridge_safety_asan "-fsanitize=address,undefined")
add_sanitizer_target(bridge_safety_tsan "-fsanitize=thread")
