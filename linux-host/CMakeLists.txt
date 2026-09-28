cmake_minimum_required(VERSION 3.24)
project(fulcrum-host LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# RIVET_ROOT points at a Rivet package checkout (its runtime/ codec is
# shared across platforms). raco rivet build sets it; manual builds must too.
if(NOT DEFINED ENV{RIVET_ROOT})
  message(FATAL_ERROR "RIVET_ROOT is not set. Build this host through raco rivet build/dev, or export RIVET_ROOT to a Rivet checkout.")
endif()
set(RIVET_ROOT "$ENV{RIVET_ROOT}")

find_package(PkgConfig REQUIRED)
pkg_check_modules(GTK4 REQUIRED IMPORTED_TARGET gtk4)
pkg_check_modules(PANGO REQUIRED IMPORTED_TARGET pango)

add_executable(fulcrum
  src/main.cpp
  src/posix_backend.cpp
  "${RIVET_ROOT}/runtime/src/protocol.cpp"
)

target_include_directories(fulcrum PRIVATE
  src
  "${RIVET_ROOT}/runtime/include"
)

target_link_libraries(fulcrum PRIVATE
  PkgConfig::GTK4
  PkgConfig::PANGO
  X11
  pthread
  dl
  # The embedded Racket CS runtime: the staged lib directory is selected by
  # raco rivet build (RIVET_RACKET_LIB_DIR) and contains libracketcs.
  "$ENV{RIVET_RACKET_LIB_DIR}/libracketcs.a"
)

# libcrypto is not needed by the host; libracketcs is self-contained.
target_compile_options(fulcrum PRIVATE -Wall -Wextra -Wno-unused-parameter)
