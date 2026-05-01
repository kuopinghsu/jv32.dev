/* ============================================================================
 * File: rtos/threadx/ports/jv32/threadx_link.ld
 * Project: JV32 RISC-V Processor
 * Description: Linker script for ThreadX on the JV32 SoC
 *
 * Memory layout:
 *   IRAM   128 KB @ 0x80000000  (rx)   code, rodata, .data LMA, init arrays
 *   DRAM   128 KB @ 0x90000000  (rw)   .data VMA, .bss, heap, stack
 *   EXTRAM   2 MB @ 0xA0000000  (rwx)  external AXI RAM (simulation only)
 *
 * Startup sequence (sw/common/startup.S):
 *   1. zero .bss  (_bss_start .. _bss_end in DRAM)
 *   2. copy .data  _data_lma (IRAM) -> _data_start .. _data_end (DRAM)
 *   3. set sp = _stack_top  (top of DRAM)
 *
 * tx_port.c uses __heap_start (first free byte after .bss in DRAM).
 * ============================================================================ */

OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY {
    iram   (rx)  : ORIGIN = 0x80000000, LENGTH = 128K
    dram   (rw)  : ORIGIN = 0x90000000, LENGTH = 128K
    extram (rwx) : ORIGIN = 0xA0000000, LENGTH = 2M
}

SECTIONS {
    /* ------------------------------------------------------------------ */
    /* External RAM sections (0xA0000000, simulation only)                */
    /* Listed FIRST so wildcards below don't capture them.                */
    /* ------------------------------------------------------------------ */
    .text.ext ORIGIN(extram) : {
        KEEP(*(.text.ext .text.ext.*))
    } > extram

    .rodata.ext : {
        KEEP(*(.rodata.ext .rodata.ext.*))
    } > extram

    .data.ext : {
        _extdata_start = .;
        KEEP(*(.data.ext .data.ext.*))
        . = ALIGN(4);
        _extdata_end = .;
    } > extram

    /* ------------------------------------------------------------------ */
    /* Code and read-only data — IRAM                                     */
    /* ------------------------------------------------------------------ */
    .text ORIGIN(iram) : {
        KEEP(*(.text.reset))
        *(.text.trap)
        *(.text .text.*)
        *(.gnu.linkonce.t.*)
    } > iram

    .rodata : {
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
        *(.gnu.linkonce.r.*)
    } > iram

    .init_array : {
        __init_array_start = .;
        KEEP(*(.init_array*))
        __init_array_end = .;
    } > iram

    .fini_array : {
        __fini_array_start = .;
        KEEP(*(.fini_array*))
        __fini_array_end = .;
    } > iram

    . = ALIGN(4);
    _iram_end = .;

    /* ------------------------------------------------------------------ */
    /* Initialised data — LMA in IRAM, VMA in DRAM (copied at boot)       */
    /* ------------------------------------------------------------------ */
    _data_lma = _iram_end;

    .data : AT(_iram_end) {
        _data_start = .;
        *(.data .data.*)
        *(.gnu.linkonce.d.*)
        . = ALIGN(4);
        PROVIDE(__global_pointer$ = . + 0x800);
        *(.sdata .sdata.*)
        . = ALIGN(4);
        _data_end = .;
    } > dram

    /* ------------------------------------------------------------------ */
    /* Zero-initialised data — DRAM                                       */
    /* ------------------------------------------------------------------ */
    .bss (NOLOAD) : {
        . = ALIGN(4);
        _bss_start = .;
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(.gnu.linkonce.b.*)
        *(COMMON)
        . = ALIGN(4);
        _bss_end = .;
    } > dram

    /* ------------------------------------------------------------------ */
    /* Heap and stack — DRAM                                              */
    /* ------------------------------------------------------------------ */
    __heap_start  = _bss_end;
    __heap_end    = ORIGIN(dram) + LENGTH(dram) - 0x1000; /* reserve 4 KB */
    _stack_top    = ORIGIN(dram) + LENGTH(dram);

    /* ------------------------------------------------------------------ */
    /* Discard debug / metadata sections                                  */
    /* ------------------------------------------------------------------ */
    /DISCARD/ : {
        *(.note.*)
        *(.comment)
        *(.eh_frame .eh_frame_hdr)
        *(.gcc_except_table .gcc_except_table.*)
        *(.riscv.attributes)
    }
}
