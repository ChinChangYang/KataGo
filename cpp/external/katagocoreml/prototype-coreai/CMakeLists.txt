# PROTOTYPE (wayfinder #36), throwaway: a CLI that writes the .mlpackage MILBuilder builds.
cmake_minimum_required(VERSION 3.20)
project(katagocoreml_prototype_cli CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
add_subdirectory(.. katagocoreml)
add_executable(mlpackage_cli mlpackage_cli.cpp)
target_link_libraries(mlpackage_cli katagocoreml ${KATAGOCOREML_DEP_LDFLAGS})
