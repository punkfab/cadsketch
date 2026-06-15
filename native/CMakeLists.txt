cmake_minimum_required(VERSION 3.13)
project(sketch_kernel LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_VISIBILITY_PRESET hidden)

# Built as a shared lib so Dart can dlopen it (and so the iOS port can later
# swap the same sources into an xcframework behind the identical header).
add_library(sketch_kernel SHARED sketch_kernel.cpp)
target_include_directories(sketch_kernel PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})

# Standalone builds (build_native.sh) land the .so next to the project root so
# Dart's DynamicLibrary.open can find it during `flutter run`. When built as a
# subdirectory of the Flutter runner, the parent CMake installs it into the
# app bundle instead (see linux/CMakeLists.txt), so skip this there.
if(CMAKE_PROJECT_NAME STREQUAL "sketch_kernel")
  set_target_properties(sketch_kernel PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/../build/native")
endif()
