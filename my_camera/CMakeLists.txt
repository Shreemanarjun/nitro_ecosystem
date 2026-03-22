cmake_minimum_required(VERSION 3.10)
project(my_camera_library VERSION 0.0.1 LANGUAGES C CXX)

# Include the Nitrogen generated module bindings
include(lib/src/generated/cmake/my_camera.CMakeLists.g.txt OPTIONAL)
