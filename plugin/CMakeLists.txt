cmake_minimum_required(VERSION 3.16)
project(appliance-lockdown)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

find_package(Qt6 REQUIRED COMPONENTS Core Widgets)
find_package(libobs REQUIRED)
find_package(obs-frontend-api REQUIRED)

add_library(appliance-lockdown MODULE src/lockdown-plugin.cpp)

target_link_libraries(appliance-lockdown
    PRIVATE
        OBS::libobs
        OBS::obs-frontend-api
        Qt6::Core
        Qt6::Widgets
)

set_target_properties(appliance-lockdown PROPERTIES PREFIX "")
