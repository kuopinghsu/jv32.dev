#include <stdint.h>
#include <csr.h>
#include <jv_platform.h>

static void print_u32(uint32_t v)
{
    char buf[11];
    int i = 0;
    if (v == 0) {
        jv_putc('0');
        return;
    }
    while (v && i < 10) {
        buf[i++] = (char)('0' + (v % 10));
        v /= 10;
    }
    while (i--) jv_putc(buf[i]);
}

static void print_u64(uint64_t v)
{
    char buf[21];
    int i = 0;
    if (v == 0) {
        jv_putc('0');
        return;
    }
    while (v && i < 20) {
        buf[i++] = (char)('0' + (v % 10));
        v /= 10;
    }
    while (i--) jv_putc(buf[i]);
}

static uint32_t run_mulh_interleaved(uint32_t iters)
{
    uint32_t a = 0x12345678u;
    uint32_t b = 0x9e3779b9u;
    uint32_t s1 = 0x11111111u;
    uint32_t s2 = 0x22222222u;
    uint32_t s3 = 0x33333333u;
    uint32_t acc = 0;

    for (uint32_t i = 0; i < iters; i++) {
        uint32_t t;
        asm volatile(
            "mulh  %0, %4, %5\n\t"
            "add   %1, %1, %6\n\t"
            "xor   %2, %2, %7\n\t"
            "add   %3, %3, %8\n\t"
            : "=&r"(t), "+r"(s1), "+r"(s2), "+r"(s3)
            : "r"(a), "r"(b), "r"(0x10203040u), "r"(0x55aa55aau), "r"(0x01010101u)
        );
        acc ^= t;
        a += 0x9e3779b9u;
        b += 0x7f4a7c15u;
    }

    return acc ^ s1 ^ s2 ^ s3 ^ a ^ b;
}

int main(void)
{
    const uint32_t iters = 200000;
    uint64_t c0 = read_csr_cycle64();
    uint64_t i0 = read_csr_instret64();
    uint32_t sig = run_mulh_interleaved(iters);
    uint64_t c1 = read_csr_cycle64();
    uint64_t i1 = read_csr_instret64();

    uint64_t cyc = c1 - c0;
    uint64_t ins = i1 - i0;

    jv_puts("mul_stress (MULH interleaved)\n");
    jv_puts("iters: ");
    print_u32(iters);
    jv_puts("\n");
    jv_puts("cycles: ");
    print_u64(cyc);
    jv_puts("\n");
    jv_puts("instret: ");
    print_u64(ins);
    jv_puts("\n");
    jv_puts("cpi_x1000: ");
    if (ins != 0) print_u64((cyc * 1000ull) / ins);
    else jv_puts("0");
    jv_puts("\n");
    jv_puts("signature: ");
    print_u32(sig);
    jv_puts("\n");

    jv_puts("PASS\n");
    jv_exit(0);
    return 0;
}
