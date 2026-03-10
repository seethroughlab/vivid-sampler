cmake_minimum_required(VERSION 3.16)
project(vivid_sampler)

# --- Dependencies (compiled once, linked into each operator module) ---

# miniaudio: decoder only (no device I/O, no threading, no encoding)
add_library(sampler_miniaudio STATIC src/common/miniaudio_impl.c)
target_include_directories(sampler_miniaudio PRIVATE ${VIVID_SRC_DIR}/deps/miniaudio)

# yyjson: JSON parser
add_library(sampler_yyjson STATIC src/common/yyjson_impl.c)
target_include_directories(sampler_yyjson PRIVATE ${VIVID_SRC_DIR}/deps/yyjson)

# --- Operators ---

set(VIVID_SAMPLER_OPS sp404 sampler slicer)

foreach(name IN LISTS VIVID_SAMPLER_OPS)
  add_library(${name} MODULE src/${name}.cpp)
  target_include_directories(${name} PRIVATE
    ${VIVID_SRC_DIR}/src
    ${VIVID_SRC_DIR}/deps/miniaudio
    ${VIVID_SRC_DIR}/deps/yyjson
    ${CMAKE_CURRENT_SOURCE_DIR}/src/common
  )
  target_link_libraries(${name} PRIVATE sampler_miniaudio sampler_yyjson)
  target_compile_features(${name} PRIVATE cxx_std_17)
  set_target_properties(${name} PROPERTIES
    PREFIX ""
    SUFFIX "${VIVID_PLUGIN_SUFFIX}"
    LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}
  )
endforeach()

add_custom_target(operators DEPENDS ${VIVID_SAMPLER_OPS})
