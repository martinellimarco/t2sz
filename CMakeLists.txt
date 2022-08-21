cmake_minimum_required(VERSION 3.16)
project(t2sz VERSION 1.1.2 LANGUAGES C)

add_definitions(-DVERSION="${PROJECT_VERSION}")

set(CMAKE_C_STANDARD 99)

add_executable(t2sz src/t2sz.c)
target_link_libraries(t2sz zstd m)

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
