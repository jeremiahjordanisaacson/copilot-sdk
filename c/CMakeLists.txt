##---------------------------------------------------------------------------------------------
##  Copyright (c) Microsoft Corporation. All rights reserved.
##--------------------------------------------------------------------------------------------

cmake_minimum_required(VERSION 3.14)
project(copilot-sdk-supercharged-c
    VERSION 0.1.0
    DESCRIPTION "GitHub Copilot SDK for C"
    LANGUAGES C
)

# Require C11
set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)

# Build type defaults to Release
if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release)
endif()

# ============================================================================
# Dependencies
# ============================================================================

include(FetchContent)

# cJSON - lightweight JSON parser for C
FetchContent_Declare(
    cjson
    GIT_REPOSITORY https://github.com/DaveGamble/cJSON.git
    GIT_TAG        v1.7.18
)
# Disable cJSON tests and install to keep the build minimal
set(ENABLE_CJSON_TEST OFF CACHE BOOL "" FORCE)
set(ENABLE_CJSON_INSTALL OFF CACHE BOOL "" FORCE)
set(CJSON_BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
FetchContent_MakeAvailable(cjson)

# ============================================================================
# Platform-specific settings
# ============================================================================

# Find pthreads
set(THREADS_PREFER_PTHREAD_FLAG ON)
find_package(Threads REQUIRED)

# ============================================================================
# Library target
# ============================================================================

add_library(copilot_sdk
    src/json_rpc_client.c
    src/client.c
    src/session.c
)

target_include_directories(copilot_sdk
    PUBLIC
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
        $<INSTALL_INTERFACE:include>
    PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/src
)

target_link_libraries(copilot_sdk
    PRIVATE
        cjson
        Threads::Threads
)

# Platform-specific link libraries
if(WIN32)
    target_link_libraries(copilot_sdk PRIVATE ws2_32)
endif()

# Compiler warnings
if(MSVC)
    target_compile_options(copilot_sdk PRIVATE /W4)
else()
    target_compile_options(copilot_sdk PRIVATE -Wall -Wextra -Wpedantic)
endif()

# ============================================================================
# Examples
# ============================================================================

option(COPILOT_SDK_BUILD_EXAMPLES "Build example programs" ON)

if(COPILOT_SDK_BUILD_EXAMPLES)
    add_executable(copilot_basic_example examples/basic_example.c)

    target_link_libraries(copilot_basic_example
        PRIVATE
            copilot_sdk
            cjson
            Threads::Threads
    )

    target_include_directories(copilot_basic_example
        PRIVATE
            ${CMAKE_CURRENT_SOURCE_DIR}/include
    )
endif()

# ============================================================================
# Install
# ============================================================================

include(GNUInstallDirs)

install(TARGETS copilot_sdk
    EXPORT copilot_sdk-targets
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
    ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
)

install(DIRECTORY include/copilot
    DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}
)

install(EXPORT copilot_sdk-targets
    FILE copilot_sdk-targets.cmake
    NAMESPACE copilot::
    DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/copilot_sdk
)
