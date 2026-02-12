cmake_minimum_required(VERSION 3.16)
project(copilot-sdk-supercharged VERSION 1.0.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Fetch nlohmann/json as a header-only dependency
include(FetchContent)
FetchContent_Declare(
    json
    GIT_REPOSITORY https://github.com/nlohmann/json.git
    GIT_TAG        v3.11.3
    GIT_SHALLOW    TRUE
)
FetchContent_MakeAvailable(json)

# SDK library
add_library(copilot_sdk
    src/json_rpc_client.cpp
    src/client.cpp
    src/session.cpp
)

target_include_directories(copilot_sdk PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/include
)

target_link_libraries(copilot_sdk PUBLIC nlohmann_json::nlohmann_json)

# Platform-specific link libraries
if(WIN32)
    target_link_libraries(copilot_sdk PUBLIC ws2_32)
endif()

# Threads
find_package(Threads REQUIRED)
target_link_libraries(copilot_sdk PUBLIC Threads::Threads)

# Examples
option(COPILOT_SDK_BUILD_EXAMPLES "Build example programs" ON)
if(COPILOT_SDK_BUILD_EXAMPLES)
    add_executable(basic_example examples/basic_example.cpp)
    target_link_libraries(basic_example PRIVATE copilot_sdk)
endif()
