/*
 * Linker script for FreeRTOS on JV32 RISC-V SoC
 * Memory layout:
 *   IRAM (rx)  : 0x80000000, 128 KB  — text + rodata
 *   DRAM (rwx) : 0x90000000, 128 KB  — data + bss + heap + stack
 */

OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
    IRAM (rx)  : ORIGIN = 0x80000000, LENGTH = 128K
    DRAM (rwx) : ORIGIN = 0x90000000, LENGTH = 128K
}

PHDRS
{
    text PT_LOAD FLAGS(5);  /* Read + Execute */
    data PT_LOAD FLAGS(6);  /* Read + Write */
}

SECTIONS
{
    .text : {
        KEEP(*(.text.init))
        *(.text.unlikely .text.unlikely.*)
        *(.text.startup .text.startup.*)
        *(.text .text.*)
        *(.gnu.linkonce.t.*)
    } > IRAM :text

    .rodata : {
        *(.rdata)
        *(.rodata .rodata.*)
        *(.gnu.linkonce.r.*)
    } > IRAM :text

    .data : {
        __data_start = .;
        *(.data .data.*)
        *(.gnu.linkonce.d.*)
        __data_end = .;
    } > DRAM :data

    .sdata : {
        __global_pointer$ = . + 0x800;
        *(.srodata.cst16)
        *(.srodata.cst8)
        *(.srodata.cst4)
        *(.srodata.cst2)
        *(.srodata .srodata.*)
        *(.sdata .sdata.*)
        *(.gnu.linkonce.s.*)
    } > DRAM :data

    .bss : {
        __bss_start = .;
        *(.sbss*)
        *(.gnu.linkonce.sb.*)
        *(.bss .bss.*)
        *(.gnu.linkonce.b.*)
        *(COMMON)
        __bss_end = .;
    } > DRAM

    /* Stack grows downward */
    .stack (NOLOAD) : {
        . = ALIGN(16);
        __stack_bottom = .;
        . = . + 0x2000;  /* 8KB stack */
        . = ALIGN(16);
        __stack_top = .;
    } > DRAM

    /* FreeRTOS IRQ stack */
    .irq_stack (NOLOAD) : {
        . = ALIGN(16);
        __freertos_irq_stack_bottom = .;
        . = . + 0x800;  /* 2KB IRQ stack */
        . = ALIGN(16);
        __freertos_irq_stack_top = .;
    } > DRAM

    /* Heap for FreeRTOS (fills remaining DRAM) */
    .heap (NOLOAD) : {
        . = ALIGN(16);
        __heap_start = .;
        . = ORIGIN(DRAM) + LENGTH(DRAM) - 0x100;
        . = ALIGN(16);
        __heap_end = .;
    } > DRAM

    _end = .;
}
