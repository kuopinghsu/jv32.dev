/* ============================================================================
 * File: sw/link.ld
 * Project: JV32 RISC-V Processor
 * Description: Linker script for RV32IMAC bare-metal tests
 *
 * Memory map:
 *   IRAM: 0x80000000  128 KB  (executable, read-only at runtime)
 *   DRAM: 0x90000000  128 KB  (read-write data, stack)
 *   EXTRAM: 0xA0000000  2 MB   (external AXI RAM, simulation only)
 * ============================================================================ */

MEMORY {
    IRAM   (rx)  : ORIGIN = 0x80000000, LENGTH = 128K
    DRAM   (rwx) : ORIGIN = 0x90000000, LENGTH = 128K
    EXTRAM (rwx) : ORIGIN = 0xA0000000, LENGTH = 2M
}

ENTRY(_start)

SECTIONS {
    /* ------------------------------------------------------------------ */
    /* External RAM sections (0xA0000000, simulation only)                */
    /* Listed FIRST so wildcards in IRAM/DRAM sections don't capture them.*/
    /* ELF loader writes these directly; no startup copy needed.          */
    /* ------------------------------------------------------------------ */
    .text.ext ORIGIN(EXTRAM) : {
        KEEP(*(.text.ext .text.ext.*))
    } > EXTRAM

    .rodata.ext : {
        KEEP(*(.rodata.ext .rodata.ext.*))
    } > EXTRAM

    .data.ext : {
        _extdata_start = .;
        KEEP(*(.data.ext .data.ext.*))
        . = ALIGN(4);
        _extdata_end = .;
    } > EXTRAM

    /* ------------------------------------------------------------------ */
    /* .text : code and read-only data                                     */
    /* ------------------------------------------------------------------ */
    .text ORIGIN(IRAM) : {
        /* Reset vector must be at the very start */
        KEEP(*(.text.reset))
        *(.text.trap)
        *(.text .text.*)
        *(.gnu.linkonce.t.*)
    } > IRAM

    .rodata : {
        *(.rodata .rodata.*)
        *(.srodata .srodata.*)
        *(.gnu.linkonce.r.*)
    } > IRAM

    .init_array : {
        __init_array_start = .;
        KEEP(*(.init_array*))
        __init_array_end = .;
    } > IRAM

    .fini_array : {
        __fini_array_start = .;
        KEEP(*(.fini_array*))
        __fini_array_end = .;
    } > IRAM

    /* End of IRAM read-only content — must be 4-byte aligned so the
     * startup data-copy loop can use word-granule lw/sw without triggering
     * a misaligned-access exception (sp is not yet initialised at that
     * point, so an exception would immediately recurse into the trap
     * handler with sp=0 and crash the firmware). */
    . = ALIGN(4);
    _iram_end = .;

    /* ------------------------------------------------------------------ */
    /* .data : initialised data – stored in IRAM, copied to DRAM at boot  */
    /* ------------------------------------------------------------------ */
    _data_lma = LOADADDR(.data);    /* LMA = copy source in IRAM */

    .data : AT(_iram_end) {
        _data_start = .;
        *(.data .data.*)
        *(.gnu.linkonce.d.*)
        . = ALIGN(4);
        /* Global pointer for gp-relative data access (sdata/sbss) */
        PROVIDE(__global_pointer$ = . + 0x800);
        *(.sdata .sdata.*)
        . = ALIGN(4);
        _data_end = .;
    } > DRAM

    /* ------------------------------------------------------------------ */
    /* .bss : zero-initialised data                                        */
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
    } > DRAM

    /* ------------------------------------------------------------------ */
    /* Stack: grows downward from top of DRAM                             */
    /* ------------------------------------------------------------------ */
    _stack_bottom = _bss_end;
    __heap_start  = _bss_end;
    __heap_end    = ORIGIN(DRAM) + LENGTH(DRAM) - 0x1000; /* reserve 4 KB for stack */
    _stack_top    = ORIGIN(DRAM) + LENGTH(DRAM);

    /* ------------------------------------------------------------------ */
    /* Discard unwanted sections                                           */
    /* ------------------------------------------------------------------ */
    /DISCARD/ : {
        *(.note.*)
        *(.comment)
        *(.eh_frame .eh_frame_hdr)
        *(.gcc_except_table .gcc_except_table.*)
        *(.riscv.attributes)
    }
}
