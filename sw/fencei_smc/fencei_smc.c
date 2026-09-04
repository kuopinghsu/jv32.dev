// ============================================================================
// File: sw/fencei_smc/fencei_smc.c
// Project: JV32 RISC-V Processor
// Description: Zifencei self-modifying-code test for
//   TODO.bak/RISCV_COMPATIBILITY_TODO.md P2 "FENCE.I Must Be Verified with the
//   TCM Store Queue" -- every explicit store before FENCE.I must be visible to
//   the instruction fetch that follows.
//
// Uses the top of IRAM (past the linked program) as a scratch RWX region:
// write an instruction sequence, FENCE.I, then execute it.  Repeated with the
// TCM store queue deliberately loaded, and with byte / halfword writes that
// patch a 32-bit instruction in place.  Self-checking; exit 0/1.
// ============================================================================

#include <stdint.h>
#include <stdio.h>
#include "jv_platform.h"

#define FENCE_I() __asm__ volatile(".word 0x0000100F" ::: "memory")

static uint32_t tp = 0, tf = 0;
static void check(const char *n, int ok)
{
    printf("  %-50s : %s\n", n, ok ? "PASS" : "FAIL");
    if (ok) tp++; else tf++;
}

// Scratch RWX area: last 256 bytes of the 128 KB IRAM TCM.
#define SMC_AREA ((volatile uint32_t *)(uintptr_t)(JV_IRAM_BASE + JV_IRAM_SIZE - 256u))

typedef int (*fn_t)(int);

// Instruction encodings we patch in.
#define I_ADDI_A0_A0(imm12)  (0x00050513u | ((uint32_t)((imm12) & 0xFFF) << 20))  // addi a0,a0,imm
#define I_RET                (0x00008067u)                                        // jalr x0,0(ra)

static volatile uint32_t g_sink[64];

int main(void)
{
    printf("=== JV32 FENCE.I self-modifying-code test ===\n");

    volatile uint32_t *code = SMC_AREA;
    fn_t f = (fn_t)(uintptr_t)code;

    // --- 1. Plain: write "addi a0,a0,1 ; ret", FENCE.I, call ---------------
    code[0] = I_ADDI_A0_A0(1);
    code[1] = I_RET;
    FENCE_I();
    check("write insns + FENCE.I: f(41) == 42", f(41) == 42);

    // --- 2. Re-patch the immediate, FENCE.I, call again -------------------
    code[0] = I_ADDI_A0_A0(100);
    FENCE_I();
    check("re-patch imm + FENCE.I: f(41) == 141", f(41) == 141);

    // --- 3. Store queue loaded, then patch + FENCE.I ---------------------
    for (int i = 0; i < 64; i++) g_sink[i] = 0xC0000000u | (uint32_t)i;   // fill store queue
    code[0] = I_ADDI_A0_A0(7);
    FENCE_I();
    int q_ok = (f(41) == 48);
    for (int i = 0; i < 64; i++)
        if (g_sink[i] != (0xC0000000u | (uint32_t)i)) q_ok = 0;
    check("patch with store queue busy + FENCE.I: f(41) == 48", q_ok);

    // --- 4. Byte write patching one byte of the 32-bit addi imm ---------
    // addi a0,a0,1 -> change imm[11:0] low byte so imm becomes 0x0AB (171).
    code[0] = I_ADDI_A0_A0(1);
    FENCE_I();
    (void)f(0);
    ((volatile uint8_t *)code)[2] = (uint8_t)0xB5;  // patches bits [23:16] (imm[11:4] area)
    ((volatile uint8_t *)code)[3] = (uint8_t)0x0A;  // patches bits [31:24]
    // Now word == 0x0AB50513 -> addi a0,a0, sign-extend(0x0AB) = 171
    FENCE_I();
    check("byte-write patch + FENCE.I: f(0) == 171", f(0) == 171);

    // --- 5. Halfword write patching the low half of the instruction ----
    code[0] = I_ADDI_A0_A0(1);
    FENCE_I();
    (void)f(0);
    ((volatile uint16_t *)code)[0] = (uint16_t)0x0513;   // keep rd/funct3/opcode
    ((volatile uint16_t *)code)[1] = (uint16_t)0x0320;   // imm[11:0] = 0x032 = 50
    FENCE_I();
    check("halfword-write patch + FENCE.I: f(0) == 50", f(0) == 50);

    printf("\n--- Results ---  passed: %lu  failed: %lu\n",
           (unsigned long)tp, (unsigned long)tf);
    int pass = (tf == 0);
    printf(pass ? "\nPASS\n" : "\nFAIL\n");
    jv_exit(pass ? 0 : 1);
    return pass ? 0 : 1;
}
