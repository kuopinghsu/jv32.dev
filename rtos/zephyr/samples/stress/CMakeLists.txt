# ===================================================================
# CMakeLists.txt  --  Zephyr stress unit test project
#
# Build and run (Linux host / native_sim):
#   west build -b native_sim .
#   west build -t run
#
# Or via twister:
#   twister -p native_sim -T .
# ===================================================================

cmake_minimum_required(VERSION 3.20.0)

find_package(Zephyr REQUIRED HINTS $ENV{ZEPHYR_BASE})

project(zephyr_stress_test)

target_sources(app PRIVATE
    src/stress.c
)
