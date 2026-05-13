# GDB helper for JV32 using OpenOCD-hosted semihosting handling.
# Usage:
#   riscv64-unknown-elf-gdb -q <semihost-elf> -x openocd/gdb_semihost_openocd.gdb

set confirm off
set pagination off
set print pretty on

target extended-remote :3333

# Optional memory map override for this SoC.
set mem inaccessible-by-default off
mem 0x80000000 0x80020000 rw
mem 0x90000000 0x90020000 rw

monitor reset halt
monitor wait_halt 2000

# RISC-V semihosting in OpenOCD is exposed via ARM-prefixed commands.
monitor arm semihosting enable
monitor arm semihosting_fileio enable

# Semihosting requests must enter debug mode on EBREAK.
monitor riscv set_ebreakm on

# Optional arguments and I/O redirection.
# monitor arm semihosting_cmdline arg1 arg2
# monitor arm semihosting_redirect tcp 4444 all

echo [INFO] OpenOCD semihosting enabled (arm semihosting + ebreakm=on).\n
