#include <stdint.h>
#include "jv_platform.h"
#include "jv_irq.h"

/* Raw encodings keep this test buildable when -march excludes A. */
static volatile uint32_t traps, cause, epc, tval;
static volatile uint32_t cell __attribute__((aligned(4)));

/* The shared startup calls this hook; this test has no constructors. */
void __libc_init_array(void) {}

static void print(const char *s)
{
    while (*s) jv_putc(*s++);
}

static void exception(jv_trap_frame_t *frame)
{
    ++traps;
    cause = frame->mcause;
    epc = frame->mepc;
    tval = frame->mtval;
    frame->mepc += 4;
}

#define PROBE(encoding) do { \
    __asm__ volatile("la %0, 1f\n" \
                     "li a2, 9\n" \
                     "li a3, 85\n" \
                     "1: .word " #encoding "\n" \
                     "mv %1, a3\n" \
                     : "=&r"(pc), "=&r"(result) : "r"(address) \
                     : "a2", "a3", "memory"); \
} while (0)

int main(void)
{
    uint32_t misa;
    __asm__ volatile("csrr %0, misa" : "=r"(misa));
    const int enabled = misa & 1;
    if (enabled != EXPECT_AMO_EN) {
        print("FAIL: misa.A disagrees with requested AMO_EN\n");
        jv_exit(1);
    }
    const uint32_t instructions[] = {0x1005a6af, 0x18c5a6af,
                                     0x08c5a6af, 0x00c5a6af, 0x20c5a6af,
                                     0x60c5a6af, 0x40c5a6af, 0x80c5a6af,
                                     0xa0c5a6af, 0xc0c5a6af, 0xe0c5a6af};
    const char *names[] = {"LR.W", "SC.W", "AMOSWAP.W", "AMOADD.W",
                           "AMOXOR.W", "AMOAND.W", "AMOOR.W", "AMOMIN.W",
                           "AMOMAX.W", "AMOMINU.W", "AMOMAXU.W"};
    unsigned failures = 0;
    jv_exc_register(JV_EXC_ILLEGAL_INSN, exception);
    for (unsigned pattern = 0; pattern < 2; ++pattern) {
      const uint32_t initial = pattern ? 0xfffffff9u : 7u;
      const uint32_t expected[] = {initial, 0, 9, initial+9, initial^9,
          initial&9, initial|9, (int32_t)initial<9 ? initial:9,
          (int32_t)initial>9 ? initial:9, initial<9 ? initial:9,
          initial>9 ? initial:9};
      for (unsigned i = 0; i < 11; ++i) {
        cell = initial;
        traps = 0;
        uint32_t pc, result;
        register volatile uint32_t *address asm("a1") = &cell;
        switch (i) {
        case 0: PROBE(0x1005a6af); break;
        case 1: PROBE(0x18c5a6af); break;
        case 2: PROBE(0x08c5a6af); break;
        case 3: PROBE(0x00c5a6af); break;
        case 4: PROBE(0x20c5a6af); break;
        case 5: PROBE(0x60c5a6af); break;
        case 6: PROBE(0x40c5a6af); break;
        case 7: PROBE(0x80c5a6af); break;
        case 8: PROBE(0xa0c5a6af); break;
        case 9: PROBE(0xc0c5a6af); break;
        default: PROBE(0xe0c5a6af); break;
        }
        int ok = enabled ? (traps == 0) :
            (traps == 1 && cause == 2 && epc == pc &&
             tval == instructions[i] && cell == initial && result == 85);
        if (enabled && i == 0) ok &= result == initial && cell == initial;
        if (enabled && i == 1) ok &= result <= 1 && cell == (result ? initial : 9u);
        if (enabled && i >= 2) ok &= result == initial && cell == expected[i];
        print(enabled ? "AMO_EN=1 " : "AMO_EN=0 ");
        print(names[i]);
        print(ok ? ": PASS\n" : ": FAIL\n");
        failures += !ok;
    }
    }
    jv_exit(failures ? 1 : 0);
    return failures ? 1 : 0;
}
