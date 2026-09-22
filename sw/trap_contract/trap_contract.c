#include <stdint.h>
#include "jv_platform.h"
#include "jv_irq.h"
void __libc_init_array(void) {}
static volatile uint32_t count, cause, epc, tval;
extern void fetch_fault(void), fetch_resume(void);
__asm__(".pushsection .text\n.global fetch_fault\n.global fetch_resume\n"
        "fetch_fault: li a1, 0xc0000000\njalr zero, 0(a1)\n"
        "fetch_resume: ret\n.popsection\n");
static void handler(jv_trap_frame_t *f)
{
    count++; cause=f->mcause; epc=f->mepc; tval=f->mtval;
    if(cause==1) f->mepc=(uintptr_t)fetch_resume;
    else f->mepc += (*(volatile uint16_t*)f->mepc & 3)==3 ? 4:2;
}
static void print(const char *s) {while(*s) jv_putc(*s++);}
static unsigned failures;
static void check(int ok,const char *label)
{
    print(ok ? "PASS " : "FAIL "); print(label); print("\n"); failures+=!ok;
}
#define RUN_AT(enc,want_cause,want_value,address) do { \
    uint32_t pc; count=0; \
    __asm__ volatile("li a1," #address "\nli a2,1\nla %0,1f\n1: .word " #enc "\n" \
       : "=&r"(pc) :: "a1","a2","a3","memory"); \
    check(count==1 && cause==(want_cause) && epc==pc && tval==(want_value),#enc); \
} while(0)
#define RUN(enc,cause,value) RUN_AT(enc,cause,value,0xc0000000)
int main(void)
{
    for(unsigned i=0;i<12;i++) jv_exc_register(i,handler);
    RUN(0x00000073,11,0); /* ECALL */
    RUN(0x00100073,3,pc); /* EBREAK */
    RUN(0xfff026f3,2,0xfff026f3); /* unknown CSR read */
    RUN(0x100026f3,2,0x100026f3); /* supervisor CSR, absent in M-only core */
    RUN(0xf14016f3,2,0xf14016f3); /* CSRRW mhartid even rs1=x0 */
    RUN(0xf14666f3,2,0xf14666f3); /* CSRRSI mhartid, nonzero zimm */
    RUN(0x0005a683,5,0xc0000000); /* LW response error */
    RUN(0x00c5a023,7,0xc0000000); /* SW response error */
    RUN_AT(0x0005a683,4,0x90000001,0x90000001); /* LW misaligned */
    RUN_AT(0x00c5a023,6,0x90000001,0x90000001); /* SW misaligned */
    count=0; fetch_fault();
    check(count==1 && cause==1 && epc==0xc0000000 && tval==0xc0000000,"instruction access fault");
#if EXPECT_A
    RUN_AT(0x1005a6af,4,0x90000001,0x90000001); /* LR.W misaligned */
    RUN_AT(0x18c5a6af,6,0x90000001,0x90000001); /* SC.W misaligned */
    RUN_AT(0x00c5a6af,6,0x90000001,0x90000001); /* AMOADD.W misaligned */
#endif
#if !EXPECT_M
    RUN(0x02c586b3,2,0x02c586b3); /* MUL */
    RUN(0x02c5c6b3,2,0x02c5c6b3); /* DIV */
#endif
#if !EXPECT_B
    RUN(0x20c5a6b3,2,0x20c5a6b3); /* SH1ADD */
    RUN(0x40c5f6b3,2,0x40c5f6b3); /* ANDN */
    RUN(0x28c596b3,2,0x28c596b3); /* BSET */
#endif
#if !EXPECT_ZCMP
    uint32_t pc; count=0;
    __asm__ volatile("la %0,1f\n1: .2byte 0xac22\n" : "=&r"(pc) :: "memory");
    check(count==1 && cause==2 && epc==pc && tval==0xac22,"disabled Zcmp");
#endif
    uint32_t hart;
    __asm__ volatile("csrr %0,mhartid" : "=r"(hart));
    check(hart==0,"read-only CSR read is legal");
    jv_exit(failures ? 1:0); return failures ? 1:0;
}
