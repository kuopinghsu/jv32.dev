/* ============================================================================
 * File: sw/link.ld
 * Project: JV32 RISC-V Processor
 * Description: Linker script for RV32IMAC bare-metal tests
 *
 * Memory map:
 *   IRAM: 0x80000000  64 KB  (executable, read-only at runtime)
 *   DRAM: 0xC0000000  64 KB  (read-write data, stack)
 * ============================================================================ */

MEMORY {
    IRAM (rx)  : ORIGIN = 0x80000000, LENGTH = 64K
    DRAM (rwx) : ORIGIN = 0xC0000000, LENGTH = 64K
}

ENTRY(_start)

SECTIONS {
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
        *(.gnu.linkonce.r.*)
    } > IRAM

    /* End of IRAM read-only content */
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
        _data_end = .;
    } > DRAM

    /* ------------------------------------------------------------------ */
    /* .bss : zero-initialised data                                        */
    /* ------------------------------------------------------------------ */
    .bss (NOLOAD) : {
        . = ALIGN(4);
        _bss_start = .;
        *(.bss .bss.*)
        *(.gnu.linkonce.b.*)
        *(COMMON)
        . = ALIGN(4);
        _bss_end = .;
    } > DRAM

    /* ------------------------------------------------------------------ */
    /* Stack: grows downward from top of DRAM                             */
    /* ------------------------------------------------------------------ */
    _stack_bottom = _bss_end;
    _stack_top    = ORIGIN(DRAM) + LENGTH(DRAM);

    /* ------------------------------------------------------------------ */
    /* Discard unwanted sections                                           */
    /* ------------------------------------------------------------------ */
    /DISCARD/ : {
        *(.note.*)
        *(.comment)
        *(.eh_frame)
        *(.riscv.attributes)
    }
}
