#include <stdint.h>
#include "jv_platform.h"
#include "jv_irq.h"
void __libc_init_array(void) {}
static volatile uint32_t count,cause,epc,tval;
static void handler(jv_trap_frame_t *f)
{count++;cause=f->mcause;epc=f->mepc;tval=f->mtval;f->mepc+=4;}
struct probe {uint32_t addr; unsigned fault; const char *name;};
static const struct probe cases[]={
 {0x7fffffff,1,"IRAM below"},{0x80000000,0,"IRAM first"},{0x8001ffff,0,"IRAM last"},{0x80020000,1,"IRAM above"},
 {0x8fffffff,1,"DRAM below"},{0x90000000,0,"DRAM first"},{0x9001ffff,0,"DRAM last"},{0x90020000,1,"DRAM above"},
 {0x5fffffff,1,"IRAM alias below"},{0x60000000,0,"IRAM alias first"},{0x6001ffff,0,"IRAM alias last"},{0x60020000,1,"IRAM alias above"},
 {0x6fffffff,1,"DRAM alias below"},{0x70000000,0,"DRAM alias first"},{0x7001ffff,0,"DRAM alias last"},{0x70020000,1,"DRAM alias above"},
 {0x2000ffff,1,"UART below"},{0x20010000,0,"UART first"},{0x200100ff,1,"UART last unsupported"},{0x20010100,1,"UART above"},
 {0x01ffffff,1,"CLIC below"},{0x02000000,0,"CLIC first"},{0x021fffff,0,"CLIC last RAZ"},{0x02200000,1,"CLIC above"},
 {0x3fffffff,1,"Magic below"},{0x40000000,0,"Magic first"},{0x4fffffff,1,"Magic last unsupported"},{0x50000000,1,"Magic above"},
 {0x9fffffff,1,"external RAM below"},{0xa0000000,0,"external RAM first"},{0xa01fffff,0,"external RAM last"},{0xa0200000,1,"external RAM above"},
 {0,1,"external catch-all zero"},{0xffffffff,1,"external catch-all last"}
};
int main(void)
{
 unsigned failures=0; jv_exc_register(5,handler);
 for(unsigned i=0;i<sizeof(cases)/sizeof(cases[0]);i++){
  uint32_t pc; count=0;
  register uint32_t address __asm__("a1")=cases[i].addr;
  __asm__ volatile("la %0,1f\n.option push\n.option norvc\n1: lbu a3,0(a1)\n.option pop\n"
    : "=&r"(pc) : "r"(address) : "a3","memory");
  int ok=cases[i].fault ? count==1 && cause==5 && epc==pc && tval==address : count==0;
  const char *s=ok?"PASS ":"FAIL "; while(*s)jv_putc(*s++);
  s=cases[i].name;while(*s)jv_putc(*s++);jv_putc('\n');failures+=!ok;
 }
 jv_exit(failures?1:0);return failures?1:0;
}
