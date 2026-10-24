cmake_minimum_required(VERSION 3.20.0)
find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})
project(keepsake_p0)

target_sources(app PRIVATE src/main.c)

# Backport Zephyr 8260e1ff5cc4 (DMA slab ownership). Generate into the build
# directory: never modify the west checkout or depend on an untracked edit.
set(pdm_original ${ZEPHYR_BASE}/drivers/audio/dmic_nrfx_pdm.c)
set(pdm_patch ${CMAKE_CURRENT_SOURCE_DIR}/../patches/zephyr-pdm-ownership.patch)
file(SHA256 ${pdm_original} pdm_sha)
if(NOT pdm_sha STREQUAL "60f8dd2504aa72fa922262f3206bf8f4934a6689186cfa0d31728e76f8ca50df")
  message(FATAL_ERROR "PDM source changed: review/remove the v4.1.0 ownership backport")
endif()
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS ${pdm_patch} ${pdm_original})
find_program(PATCH_EXECUTABLE patch REQUIRED)
set(pdm_fixed ${CMAKE_CURRENT_BINARY_DIR}/dmic_nrfx_pdm_fixed.c)
file(REMOVE ${pdm_fixed})
execute_process(COMMAND ${PATCH_EXECUTABLE} -s -o ${pdm_fixed} ${pdm_original} ${pdm_patch}
                RESULT_VARIABLE patch_result)
if(NOT patch_result EQUAL 0)
  message(FATAL_ERROR "Cannot apply PDM ownership backport")
endif()
get_target_property(audio_sources drivers__audio SOURCES)
list(FILTER audio_sources EXCLUDE REGEX "(^|/)dmic_nrfx_pdm\\.c$")
set_property(TARGET drivers__audio PROPERTY SOURCES ${audio_sources})
target_sources(drivers__audio PRIVATE ${pdm_fixed})
