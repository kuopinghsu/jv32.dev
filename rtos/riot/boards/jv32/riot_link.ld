/*
 * Linker script for RIOT OS on JV32 RISC-V SoC
 *
 * Memory layout:
 *   IRAM  128 KB @ 0x80000000  (rwx) — code, rodata, data, BSS, exception stack
 *   DRAM  128 KB @ 0x90000000  (rw)  — thread stacks, heap
 *
 * SPDX-License-Identifier: LGPL-2.1-only
 */

OUTPUT_ARCH("riscv")
ENTRY(_start)

/* Exception / ISR stack size (separate from thread stacks) */
__stack_size = DEFINED(__stack_size) ? __stack_size : 2048;

MEMORY
{
    iram (rwx) : ORIGIN = 0x80000000, LENGTH = 128K
    dram (rw)  : ORIGIN = 0x90000000, LENGTH = 128K
}

SECTIONS
{
    /* ── Text ─────────────────────────────────────────────────── */
    .init :
    {
        KEEP(*(.text.init .init))
    } > iram

    .text :
    {
        *(.text.unlikely .text.unlikely.*)
        *(.text.startup .text.startup.*)
        *(.text .text.*)
        *(.gnu.linkonce.t.*)
    } > iram

    .fini :
    {
        KEEP(*(.fini))
    } > iram

    PROVIDE(__etext = .);
    PROVIDE(_etext  = .);
    PROVIDE(etext   = .);

    /* ── Read-only data ────────────────────────────────────────── */
    .rodata :
    {
        *(.rdata)
        *(.rodata .rodata.*)
        *(.gnu.linkonce.r.*)
    } > iram

    . = ALIGN(4);

    /* C++ / libc init/fini arrays */
    .preinit_array :
    {
        PROVIDE_HIDDEN(__preinit_array_start = .);
        KEEP(*(.preinit_array))
        PROVIDE_HIDDEN(__preinit_array_end = .);
    } > iram

    .init_array :
    {
        PROVIDE_HIDDEN(__init_array_start = .);
        KEEP(*(SORT_BY_INIT_PRIORITY(.init_array.*) SORT_BY_INIT_PRIORITY(.ctors.*)))
        KEEP(*(.init_array EXCLUDE_FILE(*crtbegin.o *crtbegin?.o *crtend.o *crtend?.o) .ctors))
        PROVIDE_HIDDEN(__init_array_end = .);
    } > iram

    .fini_array :
    {
        PROVIDE_HIDDEN(__fini_array_start = .);
        KEEP(*(SORT_BY_INIT_PRIORITY(.fini_array.*) SORT_BY_INIT_PRIORITY(.dtors.*)))
        KEEP(*(.fini_array EXCLUDE_FILE(*crtbegin.o *crtbegin?.o *crtend.o *crtend?.o) .dtors))
        PROVIDE_HIDDEN(__fini_array_end = .);
    } > iram

    /* ── Writeable data ─────────────────────────────────────────── */
    . = ALIGN(4);
    PROVIDE(_data_lma = .);
    PROVIDE(_data     = .);

    .data :
    {
        *(.data .data.*)
        *(.gnu.linkonce.d.*)
        . = ALIGN(8);
        PROVIDE(__global_pointer$ = . + 0x800);
        *(.sdata .sdata.*)
        *(.gnu.linkonce.s.*)
        . = ALIGN(8);
        *(.srodata.cst16 .srodata.cst8 .srodata.cst4 .srodata.cst2)
        *(.srodata .srodata.*)
    } > iram

    . = ALIGN(4);
    PROVIDE(_edata = .);
    PROVIDE(edata  = .);

    /* ── BSS ────────────────────────────────────────────────────── */
    PROVIDE(__bss_start = .);
    .bss :
    {
        *(.sbss* .gnu.linkonce.sb.*)
        *(.bss   .bss.* .gnu.linkonce.b.*)
        *(COMMON)
        . = ALIGN(4);
    } > iram
    PROVIDE(__bss_end = .);

    /* ── No-init (PUF SRAM etc.) ────────────────────────────────── */
    .noinit (NOLOAD) :
    {
        __noinit_begin__ = .;
        *(.noinit .noinit.*)
        . = ALIGN(4);
        __noinit_end__ = .;
    } > iram

    /* ── Exception/ISR stack — top of IRAM ──────────────────────
     * _sp  is used by irq_arch.c: "la sp, _sp" to switch to the
     * exception stack on interrupt entry.
     */
    .stack ORIGIN(iram) + LENGTH(iram) - __stack_size :
    {
        PROVIDE(_eheap = .);
        . = __stack_size;
        PROVIDE(_sp = .);
    } > iram

    /* Stack pointer alias used by the startup code and context switch */
    PROVIDE(__stack_top = _sp);

    /* ── DRAM: thread stacks + heap ─────────────────────────────── */
    .dram_heap (NOLOAD) :
    {
        PROVIDE(_dram_start = .);
        PROVIDE(_sheap = .);
        . = LENGTH(dram);
        PROVIDE(_eheap_dram = .);
        PROVIDE(_dram_end = .);
    } > dram
}

