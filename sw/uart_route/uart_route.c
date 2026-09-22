#include <stdint.h>
#include "jv_platform.h"
#define REG(a) (*(volatile uint32_t *)(uintptr_t)(a))
void __libc_init_array(void) {}
int main(void)
{
    int fail=0;
    REG(0x20010008)=0;
    fail |= (REG(0x02001000)&1)!=0;
    REG(0x20010008)=2; /* TX-empty interrupt */
    fail |= (REG(0x02001000)&1)!=1;
    fail |= (REG(0x02001004)&1)!=0;
    REG(0x20010008)=0;
    fail |= (REG(0x02001000)&1)!=0;
    const char *s=fail ? "FAIL UART source-0 routing\n":"PASS UART source-0 routing\n";
    while(*s) jv_putc(*s++);
    jv_exit(fail); return fail;
}
