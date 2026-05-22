/* ============================================================================
 * test_ftdi_cjtag_activate.c
 *
 * Standalone replayer for the cjtag_reset_online_activate() escape sequence
 * from OpenOCD's ftdi.c driver.  Sends the exact TCKC/TMSC bit sequence
 * directly to the JV32 Verilator VPI testbench over TCP (CMD_OSCAN1_RAW),
 * then scans the IDCODE register through OScan1 SF0 to confirm that the RTL
 * cjtag_bridge entered selected OScan1 mode correctly.
 *
 * Mapping from ftdi.c {tck, tms, tdi} to CMD_OSCAN1_RAW
 * -------------------------------------------------------
 * On a physical FTDI cJTAG adapter the signal wiring is:
 *   TCK pin  → TCKC   (TCKC = tck)
 *   TDI pin  → TMSC   (TMSC = tdi; TMS is held high as an FTDI-side enable)
 * TMS is always '1' throughout the activation sequence and is not forwarded
 * to the 2-wire bus.
 *
 * CMD_OSCAN1_RAW packet format (must match tb_jv32_vpi.cpp):
 *   buffer_out[0] bit0 = TCKC
 *   buffer_out[0] bit1 = TMSC_in
 *   buffer_in[0]  bit0 = TMSC_out (cJTAG bridge output = TDO)
 *
 * Exit codes: 0 = PASS, 1 = FAIL
 * Usage: ./test_ftdi_cjtag_activate [port]   (default port: 5555)
 *
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2026 Kuoping Hsu
 * ============================================================================
 */

#include <arpa/inet.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

/* ── VPI protocol constants (must match tb_jv32_vpi.cpp / jtag_vpi.c) ─────── */
#define CMD_RESET       0u
#define CMD_OSCAN1_RAW  5u
#define XFERT_MAX_SIZE  512

typedef struct {
    uint32_t cmd;
    uint8_t  buffer_out[XFERT_MAX_SIZE];
    uint8_t  buffer_in[XFERT_MAX_SIZE];
    uint32_t length;
    uint32_t nb_bits;
} vpi_cmd_t;

/* Compile-time size guard matching tb_jv32_vpi.cpp's static_assert */
typedef char vpi_cmd_size_check[(sizeof(vpi_cmd_t) == 1036) ? 1 : -1];

static int g_sock = -1;

/* ── Low-level I/O ─────────────────────────────────────────────────────────── */

static int xfer_all(int fd, void *buf, size_t len, int do_write)
{
    uint8_t *p = (uint8_t *)buf;
    size_t done = 0;
    while (done < len) {
        ssize_t n = do_write ? write(fd, p + done, len - done)
                             : read(fd,  p + done, len - done);
        if (n <= 0) {
            fprintf(stderr, "[ACT] %s error: %s\n",
                    do_write ? "write" : "read", strerror(errno));
            return -1;
        }
        done += (size_t)n;
    }
    return 0;
}

static int vpi_send_recv(vpi_cmd_t *c)
{
    if (xfer_all(g_sock, c, sizeof(*c), 1) != 0) return -1;
    if (xfer_all(g_sock, c, sizeof(*c), 0) != 0) return -1;
    return 0;
}

/* ── VPI helpers ───────────────────────────────────────────────────────────── */

/*
 * Drive nTRST: 1 = assert (active), 0 = deassert.
 * CMD_RESET has no response — the VPI testbench returns true without calling
 * send_exact(), so we only write, never read.
 */
static int vpi_reset(int trst)
{
    vpi_cmd_t c;
    memset(&c, 0, sizeof(c));
    c.cmd = CMD_RESET;
    c.buffer_out[0] = trst ? 1u : 0u;
    return xfer_all(g_sock, &c, sizeof(c), 1);
}

/*
 * Single CMD_OSCAN1_RAW transfer.
 * buffer_out[0] = (tmsc << 1) | tckc
 * Returns tmsc_out (TDO from bridge) in *tmsc_out when non-NULL.
 */
static int vpi_oscan1_raw(uint8_t tckc, uint8_t tmsc, uint8_t *tmsc_out)
{
    vpi_cmd_t c;
    memset(&c, 0, sizeof(c));
    c.cmd = CMD_OSCAN1_RAW;
    c.buffer_out[0] = (uint8_t)(((tmsc & 1u) << 1) | (tckc & 1u));
    if (vpi_send_recv(&c) != 0) return -1;
    if (tmsc_out) *tmsc_out = c.buffer_in[0] & 1u;
    return 0;
}

/*
 * OScan1 SF0: encode one JTAG bit (tms, tdi) as a 3-packet OScan1 transfer.
 *
 * IEEE 1149.7 SF0 packet layout (6 TCKC edges per JTAG bit):
 *   Packet bit 0 (nTDI): TCKC 0→1, TMSC = !tdi
 *   Packet bit 1 (TMS):  TCKC 0→1, TMSC =  tms
 *   Packet bit 2 (TDO):  TCKC 0→1, bridge drives TMSC with TDO
 *
 * The TDO value is read from buffer_in[0] on the TCKC=0 packet of bit 2
 * (before the bridge deasserts its output on the following TCKC=1).
 * Returns TDO in *tdo when non-NULL.
 */
static int oscan1_bit(uint8_t tms, uint8_t tdi, uint8_t *tdo)
{
    uint8_t ntdi = tdi ? 0u : 1u;
    uint8_t dummy;

    /* Packet bit 0: nTDI */
    if (vpi_oscan1_raw(0, ntdi, &dummy) != 0) return -1;
    if (vpi_oscan1_raw(1, ntdi, &dummy) != 0) return -1;
    /* Packet bit 1: TMS */
    if (vpi_oscan1_raw(0, tms,  &dummy) != 0) return -1;
    if (vpi_oscan1_raw(1, tms,  &dummy) != 0) return -1;
    /* Packet bit 2: TDO capture (read on falling edge before bridge tristates) */
    if (vpi_oscan1_raw(0, 0, tdo)    != 0) return -1;
    if (vpi_oscan1_raw(1, 0, &dummy) != 0) return -1;

    return 0;
}

/* ── Activation sequence ───────────────────────────────────────────────────── */

/*
 * Exact TCKC/TMSC sequence derived from ftdi.c cjtag_reset_online_activate().
 *
 * Each entry maps one {tck, tdi} pair from ftdi.c:
 *   TCKC = tck   (TCK pin → TCKC)
 *   TMSC = tdi   (TDI pin → TMSC; TMS is held high throughout and is not
 *                 forwarded to the 2-wire cJTAG interface)
 *
 * Sections:
 *   [0]      Baseline     : TCKC=0, TMSC=0
 *   [1..10]  TAP reset    : TCKC=1 held; 8 TMSC edges; TCKC=0
 *   [11..16] Padding      : 3 TCKC pulses (no TMSC edges)
 *   [17..24] SELECT       : TCKC=1 held; 6 TMSC edges; TCKC=0
 *   [25..32] OAC = 0b1100 : 4 clocked bits (OScan1 / 2-wire mode)
 *   [33..40] EC  = 0b1000 : 4 clocked bits (Extended Commands)
 *   [41..48] CP  = 0b0000 : 4 clocked bits (Command Parameter)
 */
static const struct { uint8_t tckc; uint8_t tmsc; } activation_seq[] = {
    /* [0] Baseline: TCKC=0, TMSC=0 */
    { 0, 0 },

    /* [1..10] TAP reset escape: 8 TMSC edges while TCKC=1 */
    { 1, 0 },                                   /* TCKC rising, TMSC=0       */
    { 1, 1 }, { 1, 0 },                          /* TMSC edges 1-2            */
    { 1, 1 }, { 1, 0 },                          /* TMSC edges 3-4            */
    { 1, 1 }, { 1, 0 },                          /* TMSC edges 5-6            */
    { 1, 1 }, { 1, 0 },                          /* TMSC edges 7-8            */
    { 0, 0 },                                   /* TCKC falling              */

    /* [11..16] 3 TCKC pulses padding */
    { 1, 0 }, { 0, 0 },
    { 1, 0 }, { 0, 0 },
    { 1, 0 }, { 0, 0 },

    /* [17..24] SELECT escape: 6 TMSC edges while TCKC=1 */
    { 1, 0 },                                   /* TCKC rising (TAP reset)   */
    { 1, 1 }, { 1, 0 },                          /* TMSC edges 1-2            */
    { 1, 1 }, { 1, 0 },                          /* TMSC edges 3-4            */
    { 1, 1 }, { 1, 0 },                          /* TMSC edges 5-6            */
    { 0, 0 },                                   /* TCKC falling              */

    /* [25..32] OAC = 0b1100 (bits sampled on TCKC rising; driven on falling) */
    /* OAC[0]=0: TMSC=0 at rising; OAC[1]=0: TMSC=0→1 after falling */
    { 1, 0 }, { 0, 0 },                          /* OAC bit0 = 0              */
    { 1, 0 }, { 0, 1 },                          /* OAC bit1 = 0; TMSC rises  */
    { 1, 1 }, { 0, 1 },                          /* OAC bit2 = 1; TMSC stays  */
    { 1, 1 }, { 0, 0 },                          /* OAC bit3 = 1; TMSC falls  */

    /* [33..40] EC = 0b1000 */
    { 1, 0 }, { 0, 0 },                          /* EC bit0 = 0               */
    { 1, 0 }, { 0, 0 },                          /* EC bit1 = 0               */
    { 1, 0 }, { 0, 1 },                          /* EC bit2 = 0; TMSC rises   */
    { 1, 1 }, { 0, 0 },                          /* EC bit3 = 1; TMSC falls   */

    /* [41..48] CP = 0b0000 */
    { 1, 0 }, { 0, 0 },                          /* CP bit0 = 0               */
    { 1, 0 }, { 0, 0 },                          /* CP bit1 = 0               */
    { 1, 0 }, { 0, 0 },                          /* CP bit2 = 0               */
    { 1, 0 }, { 0, 0 },                          /* CP bit3 = 0               */
};

#define ACTIVATION_SEQ_LEN  (sizeof(activation_seq) / sizeof(activation_seq[0]))

static int run_activation(void)
{
    printf("[ACT] Replaying ftdi.c cjtag_reset_online_activate() "
           "(%zu TCKC/TMSC steps)...\n", ACTIVATION_SEQ_LEN);

    for (size_t i = 0; i < ACTIVATION_SEQ_LEN; i++) {
        uint8_t dummy;
        if (vpi_oscan1_raw(activation_seq[i].tckc,
                           activation_seq[i].tmsc, &dummy) != 0) {
            fprintf(stderr, "[ACT] I/O error at activation step %zu\n", i);
            return -1;
        }
    }

    printf("[ACT] Activation sequence complete\n");
    return 0;
}

/* ── JTAG TAP navigation + IDCODE scan ────────────────────────────────────── */

/* Send 5 × TMS=1 to force Test-Logic-Reset regardless of current TAP state */
static int tap_reset(void)
{
    for (int i = 0; i < 5; i++)
        if (oscan1_bit(1, 0, NULL) != 0) return -1;
    return 0;
}

/*
 * From Test-Logic-Reset, select IR=0x01 (IDCODE) and shift 32 DR bits.
 * TAP path:
 *   TLR → RTI (TMS=0)
 *   RTI → SDR (TMS=1)
 *   SDR → SIR (TMS=1)
 *   SIR → CIR (TMS=0)
 *   CIR → ShIR (TMS=0)
 *   Shift 5-bit IR=0x01 LSB-first: bits[0..3] TMS=0, bit[4] TMS=1
 *   Exit1-IR → UIR (TMS=1)
 *   UIR → SDR (TMS=1)
 *   SDR → CDR (TMS=0)
 *   CDR → ShDR (TMS=0)
 *   Shift 32 DR bits: bits[0..30] TMS=0, bit[31] TMS=1
 *   Exit1-DR → UDR (TMS=1)
 */
static int scan_idcode(uint32_t *idcode)
{
    uint8_t tdo;
    uint32_t result = 0;

    /* TLR → RTI */
    if (oscan1_bit(0, 0, NULL) != 0) return -1;
    /* RTI → Select-DR */
    if (oscan1_bit(1, 0, NULL) != 0) return -1;
    /* Select-DR → Select-IR */
    if (oscan1_bit(1, 0, NULL) != 0) return -1;
    /* Select-IR → Capture-IR */
    if (oscan1_bit(0, 0, NULL) != 0) return -1;
    /* Capture-IR → Shift-IR */
    if (oscan1_bit(0, 0, NULL) != 0) return -1;

    /* Shift in IR=0x01 (5 bits, LSB first: 1,0,0,0,0) */
    if (oscan1_bit(0, 1, NULL) != 0) return -1;  /* IR[0]=1  */
    if (oscan1_bit(0, 0, NULL) != 0) return -1;  /* IR[1]=0  */
    if (oscan1_bit(0, 0, NULL) != 0) return -1;  /* IR[2]=0  */
    if (oscan1_bit(0, 0, NULL) != 0) return -1;  /* IR[3]=0  */
    if (oscan1_bit(1, 0, NULL) != 0) return -1;  /* IR[4]=0, TMS=1 → Exit1-IR */

    /* Exit1-IR → Update-IR */
    if (oscan1_bit(1, 0, NULL) != 0) return -1;
    /* Update-IR → Select-DR */
    if (oscan1_bit(1, 0, NULL) != 0) return -1;
    /* Select-DR → Capture-DR */
    if (oscan1_bit(0, 0, NULL) != 0) return -1;
    /* Capture-DR → Shift-DR */
    if (oscan1_bit(0, 0, NULL) != 0) return -1;

    /* Shift 32 DR bits; collect TDO (LSB first) */
    for (int i = 0; i < 32; i++) {
        uint8_t tms = (i == 31) ? 1u : 0u;  /* last bit exits to Exit1-DR */
        if (oscan1_bit(tms, 0, &tdo) != 0) return -1;
        if (tdo) result |= (1u << i);
    }

    /* Exit1-DR → Update-DR */
    if (oscan1_bit(1, 0, NULL) != 0) return -1;

    *idcode = result;
    return 0;
}

/* ── main ──────────────────────────────────────────────────────────────────── */

int main(int argc, char *argv[])
{
    int port = 5555;
    if (argc >= 2) port = atoi(argv[1]);

    /* Connect to VPI testbench */
    g_sock = socket(AF_INET, SOCK_STREAM, 0);
    if (g_sock < 0) { perror("socket"); return 1; }

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port   = htons((uint16_t)port);
    inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr);

    if (connect(g_sock, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        perror("connect");
        fprintf(stderr, "[ACT] Could not connect to VPI testbench on port %d\n",
                port);
        return 1;
    }
    printf("[ACT] Connected to VPI testbench on port %d\n", port);

    /* Step 1: assert then deassert nTRST for a clean initial state */
    printf("[ACT] Step 1: nTRST pulse\n");
    if (vpi_reset(1) != 0) goto fail;
    if (vpi_reset(0) != 0) goto fail;

    /* Step 2: replay the ftdi.c cjtag_reset_online_activate() sequence */
    printf("[ACT] Step 2: cJTAG activation sequence\n");
    if (run_activation() != 0) goto fail;

    /* Step 3: navigate to Test-Logic-Reset via OScan1 SF0 TMS sequences */
    printf("[ACT] Step 3: TAP reset via OScan1 SF0 (5 × TMS=1)\n");
    if (tap_reset() != 0) goto fail;

    /* Step 4: scan IDCODE and verify */
    printf("[ACT] Step 4: IDCODE scan\n");
    uint32_t idcode = 0;
    if (scan_idcode(&idcode) != 0) goto fail;

    printf("[ACT] IDCODE = 0x%08X\n", idcode);

    if (idcode != 0x1DEAD3FFu) {
        fprintf(stderr,
                "[FAIL] ftdi cJTAG activation: IDCODE mismatch "
                "got=0x%08X expected=0x1DEAD3FF\n", idcode);
        goto fail;
    }

    printf("[PASS] ftdi cJTAG activation: IDCODE=0x%08X verified against RTL\n",
           idcode);
    close(g_sock);
    return 0;

fail:
    close(g_sock);
    return 1;
}
