cmake_minimum_required(VERSION 3.24)
project(fulcrum-linux-host LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Release artifacts must not embed developer-machine library search paths;
# every linked library (GTK4, GIO, libsecret, curses, LZ4, zlib, X11/Xtst)
# is a system dependency resolved by the normal loader search on the target
# machine.
set(CMAKE_SKIP_RPATH TRUE)

# RIVET_ROOT points at the installed Rivet package. `raco rivet build` sets
# it; manual builds may export it themselves.
if(NOT DEFINED ENV{RIVET_ROOT})
  message(FATAL_ERROR "RIVET_ROOT is not set. Export RIVET_ROOT to a Rivet checkout.")
endif()
set(RIVET_ROOT "$ENV{RIVET_ROOT}")

# The Rivet platform is consumed as a package library target (project
# constraint, rivet#238): hosts never compile Rivet sources into their own
# executable lists — rivet adding a translation unit needs no downstream
# change.
add_subdirectory("${RIVET_ROOT}/platform/linux"
                 "${CMAKE_BINARY_DIR}/rivet-platform-build")

# Fulcrum's own automation reaches past GTK: X11 grabs and XTest inject
# input events directly.
find_package(X11 REQUIRED COMPONENTS Xtst)

add_executable(RivetHost
  src/main.cpp
)

target_include_directories(RivetHost PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
)

target_link_libraries(RivetHost PRIVATE
  rivet::platform
  X11
  X11::Xtst
)

target_compile_options(RivetHost PRIVATE -Wall -Wextra -Wpedantic)

add_executable(fulcrum-ui-test EXCLUDE_FROM_ALL ../tests/linux-ui-test.cpp)
target_include_directories(fulcrum-ui-test PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries(fulcrum-ui-test PRIVATE rivet::platform X11 X11::Xtst)
target_compile_options(fulcrum-ui-test PRIVATE -Wall -Wextra -Wpedantic)

# Headless transaction test: invokes the pinned Rivet AppImage helper
# directly against executable fixtures (no FUSE and no GTK display).
add_executable(fulcrum-appimage-handoff-test EXCLUDE_FROM_ALL
  ../tests/linux-appimage-handoff-test.cpp)
target_link_libraries(fulcrum-appimage-handoff-test PRIVATE rivet::platform)
target_compile_options(fulcrum-appimage-handoff-test PRIVATE
  -Wall -Wextra -Wpedantic)
