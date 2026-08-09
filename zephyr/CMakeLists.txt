# SPDX-License-Identifier: MIT

if(CONFIG_BOARD_NEO65CU)
  zephyr_library()
  # ZMK keeps behavior/event APIs in app/include and does not expose that
  # directory automatically to external Zephyr module libraries.
  zephyr_library_include_directories(${APPLICATION_SOURCE_DIR}/include)
  zephyr_library_sources(
    ${CMAKE_CURRENT_LIST_DIR}/../src/behavior_neo65cu_rom_dfu.c
    ${CMAKE_CURRENT_LIST_DIR}/../src/caps_lock_led.c
  )
endif()
