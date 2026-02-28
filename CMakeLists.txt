cmake_minimum_required(VERSION 3.16)
project(t2sz VERSION 1.1.2 LANGUAGES C)

add_definitions(-DVERSION="${PROJECT_VERSION}")

set(CMAKE_C_STANDARD 17)

# --- Optional: sanitizers and coverage (mutually exclusive) ---
option(SANITIZE "Enable AddressSanitizer + UndefinedBehaviorSanitizer" OFF)
option(COVERAGE  "Enable LLVM coverage instrumentation"                 OFF)

if(SANITIZE AND COVERAGE)
    message(FATAL_ERROR "SANITIZE and COVERAGE are mutually exclusive. Use separate build directories.")
endif()

if(SANITIZE)
    message(STATUS "t2sz: building with ASAN + UBSAN")
    add_compile_options(-fsanitize=address,undefined -fno-omit-frame-pointer -g -O1)
    add_link_options(-fsanitize=address,undefined)
endif()

if(COVERAGE)
    message(STATUS "t2sz: building with LLVM coverage instrumentation")
    add_compile_options(-fprofile-instr-generate -fcoverage-mapping -g -O0)
    add_link_options(-fprofile-instr-generate)
endif()

add_executable(t2sz src/t2sz.c)

# --- Locate zstd (arch-aware: avoids stale x86_64 libs in /usr/local on Apple Silicon) ---
if(APPLE)
    # Homebrew on Apple Silicon installs to /opt/homebrew.
    # NO_DEFAULT_PATH prevents CMake from falling back to /usr/local,
    # which may contain x86_64 remnants from a previous Intel Homebrew.
    find_library(ZSTD_LIB  NAMES zstd   HINTS /opt/homebrew/lib     NO_DEFAULT_PATH)
    find_path   (ZSTD_INC  NAMES zstd.h HINTS /opt/homebrew/include NO_DEFAULT_PATH)
else()
    find_library(ZSTD_LIB  NAMES zstd)
    find_path   (ZSTD_INC  NAMES zstd.h)
endif()

if(NOT ZSTD_LIB)
    message(FATAL_ERROR
        "zstd library not found.\n"
        "  macOS:         brew install zstd\n"
        "  Debian/Ubuntu: apt install libzstd-dev\n"
        "  Arch:          pacman -S zstd\n")
endif()

target_include_directories(t2sz PRIVATE ${ZSTD_INC})
target_link_libraries(t2sz ${ZSTD_LIB} m)

if (CMAKE_BUILD_TYPE STREQUAL Release)
    add_custom_command(TARGET t2sz POST_BUILD COMMAND ${CMAKE_STRIP} t2sz)
endif ()

install(TARGETS t2sz)

#set(CPACK_SET_DESTDIR ON)
#set(CPACK_GENERATOR "DEB;TGZ;RPM")
set(CPACK_GENERATOR "DEB")

set(CPACK_DEBIAN_FILE_NAME DEB-DEFAULT)
set(CPACK_DEBIAN_PACKAGE_MAINTAINER "Marco Martinelli <marco+t2sz@13byte.com>")
set(CPACK_DEBIAN_PACKAGE_SHLIBDEPS ON)
set(CPACK_DEBIAN_PACKAGE_DESCRIPTION "tar 2 seekable zstd.\nIt will compress a tar archive with Zstandard keeping each file in a different frame, for fast seeking.\nThe compressed archive can be uncompressed with any Zstandard tool, including zstd.")
set(CPACK_DEBIAN_PACKAGE_HOMEPAGE "https://github.com/martinellimarco/t2sz")

#set(CPACK_RPM_PACKAGE_AUTOREQ ON)
#set(CPACK_RPM_PACKAGE_DESCRIPTION "tar 2 seekable zstd.\nIt will compress a tar archive with Zstandard keeping each file in a different frame, for fast seeking.\nThe compressed archive can be uncompressed with any Zstandard tool, including zstd.")
#set(CPACK_RPM_PACKAGE_URL "https://github.com/martinellimarco/t2sz")
#set(CPACK_RPM_PACKAGE_LICENSE "GPLv3")

set(CPACK_PACKAGE_NAME ${PROJECT_NAME})
set(CPACK_PACKAGE_CONTACT "Marco Martinelli <marco+t2sz@13byte.com>")
set(CPACK_PACKAGE_VERSION_MAJOR ${PROJECT_VERSION_MAJOR})
set(CPACK_PACKAGE_VERSION_MINOR ${PROJECT_VERSION_MINOR})
set(CPACK_PACKAGE_VERSION_PATCH ${PROJECT_VERSION_PATCH})

include(CPack)

# --- Optional: test suite ---
option(BUILD_TESTS "Build the test suite" OFF)
if(BUILD_TESTS)
    enable_testing()
    add_subdirectory(tests)
endif()
