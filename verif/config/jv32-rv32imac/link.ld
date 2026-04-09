OUTPUT_ARCH("riscv")
ENTRY(rvtest_entry_point)

/* JV32 memory map:
 *   IRAM: 0x80000000  64KB  (code only — .text sections)
 *   DRAM: 0xC0000000  64KB  (data — .bss + .data sections)
 *
 * Keeping code and data separate ensures that large .data sections
 * (expected signatures baked in by ACT4, plus test strings such as
 * RVCP-SUMMARY) do not overflow the 64KB IRAM.
 */
SECTIONS
{
  /* ── IRAM (0x80000000): code ─────────────────────────────────────── */
  . = 0x80000000;
  .text.init : { *(.text.init) }
  .text : { *(.text) *(.text.*) }

  /* ── DRAM (0xC0000000): BSS and initialised data ─────────────────── */
  . = 0xC0000000;
  .bss : { *(.bss) }
  . = ALIGN(0x1000);
  .data : { *(.data) }
  . = ALIGN(0x1000);
  _end = .;
}
