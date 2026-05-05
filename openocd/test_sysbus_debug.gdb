# Test sysbus writes with known patterns to diagnose corruption

target remote :3333
monitor halt
monitor wait_halt 2000

# Force sysbus mode
monitor riscv set_mem_access sysbus

# Test pattern 1: Simple incrementing values
set {int}0x90000000 = 0x11111111
set {int}0x90000004 = 0x22222222
set {int}0x90000008 = 0x33333333
set {int}0x9000000c = 0x44444444

# Read back
x/4xw 0x90000000

# Test pattern 2: All bits set/clear
set {int}0x90000010 = 0xFFFFFFFF
set {int}0x90000014 = 0x00000000
set {int}0x90000018 = 0xAAAAAAAA
set {int}0x9000001c = 0x55555555

# Read back
x/4xw 0x90000010

# Test pattern 3: The specific corrupted value
set {int}0x90000020 = 0x10001197
set {int}0x90000024 = 0x80820141

# Read back
x/2xw 0x90000020

quit
