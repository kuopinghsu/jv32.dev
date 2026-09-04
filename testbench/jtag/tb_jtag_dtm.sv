// ============================================================================
// File        : testbench/jtag/tb_jtag_dtm.sv
// Project     : JV32 RISC-V Processor
// Description : Focused TAP / DTM / DMI testbench harness.
//
// Drives the real JTAG pins of `jtag_top` (USE_CJTAG=0) with hand-built
// JTAG scans so individual DTM/DMI behaviours can be checked the way a
// debugger would exercise them -- without OpenOCD in the loop.
//
// Build/run (Verilator):
//   make jtag-tb                 # build + run all groups
//   make jtag-tb JTAG_TB_ARGS=+TEST=dtmcs_reset
//
// Test groups (select with +TEST=<name>, default = all):
//   dtmcs_reset   - JTAG_DEBUG_TODO P0 s1: DTMCS reset must use dtmcs_shift,
//                   not the stale DMI shift register.
//   ntrig         - JTAG_DEBUG_TODO P1 s4: trigger register bank must be a
//                   function of N_TRIGGERS (elaboration is the primary check;
//                   this group additionally reads tselect WARL behaviour).
//
// Exit code 0 = all selected checks pass, 1 = at least one failed.
// ============================================================================

`timescale 1ns / 1ps

module tb_jtag_dtm #(
    parameter int DBG_BUS_TIMEOUT_W = 16   // overridden via -GDBG_BUS_TIMEOUT_W
);

  // ---------------------------------------------------------------------------
  // Clocks / reset
  // ---------------------------------------------------------------------------
  logic clk = 1'b0;
  always #5 clk = ~clk;              // 100 MHz system clock

  logic rst_n  = 1'b0;
  logic ntrst  = 1'b0;

  // JTAG pins
  logic tck = 1'b0;
  logic tms = 1'b1;
  logic tdi = 1'b0;
  wire  tdo;
  wire  tdo_oe;

  // ---------------------------------------------------------------------------
  // DUT  (standard 4-wire JTAG, 2 triggers -- matches the SoC default)
  // ---------------------------------------------------------------------------
  localparam int N_TRIG = 2;

  // debug<->core stubs
  logic        halted_i     = 1'b0;
  logic        resumeack_i  = 1'b0;
  logic [31:0] dbg_reg_rdata_i = 32'h0;
  logic [31:0] dbg_csr_rdata_i = 32'h0;
  logic [31:0] dbg_pc_i        = 32'h0;
  logic        dbg_mem_ready_i = 1'b1;
  logic        dbg_mem_error_i = 1'b0;
  logic [31:0] dbg_mem_rdata_i = 32'h0;

  // ---------------------------------------------------------------------------
  // Debug-bus memory model with programmable response latency.
  //   mem_latency = 0  -> combinational ready (default; unchanged behaviour)
  //   mem_latency = N  -> deassert ready for N clk cycles after each req,
  //                       then 1-cycle ready pulse.
  //   mem_force_err    -> respond with dbg_mem_error_i on the ready pulse.
  // ---------------------------------------------------------------------------
  int          mem_latency   = 0;
  bit          mem_force_err = 1'b0;
  logic [31:0] mem_arr [0:15];
  int          mem_cnt   = 0;
  logic        mem_req_q = 1'b0;

  // Sticky captures of momentary core-facing debug strobes.
  bit          reg_we_seen = 1'b0;
  logic [4:0]  reg_we_addr = 5'b0;
  logic [31:0] reg_we_data = 32'b0;
  always @(posedge clk) if (dbg_reg_we_o) begin
    reg_we_seen <= 1'b1;
    reg_we_addr <= dbg_reg_addr_o;
    reg_we_data <= dbg_reg_wdata_o;
  end

  always @(posedge clk) begin
    if (!rst_n) begin
      dbg_mem_ready_i <= 1'b1;
      dbg_mem_error_i <= 1'b0;
      mem_cnt         <= 0;
      mem_req_q       <= 1'b0;
    end
    else if (mem_latency == 0) begin
      dbg_mem_ready_i <= 1'b1;
      dbg_mem_error_i <= mem_force_err;
      if (dbg_mem_req_o && |dbg_mem_we_o) mem_arr[dbg_mem_addr_o[5:2]] <= dbg_mem_wdata_o;
      dbg_mem_rdata_i <= mem_arr[dbg_mem_addr_o[5:2]];
    end
    else begin
      mem_req_q <= dbg_mem_req_o;
      if (dbg_mem_req_o && !mem_req_q) begin           // new request edge
        dbg_mem_ready_i <= 1'b0;
        dbg_mem_error_i <= 1'b0;
        mem_cnt         <= 1;
      end
      else if (!dbg_mem_ready_i && dbg_mem_req_o) begin
        if (mem_cnt >= mem_latency) begin
          dbg_mem_ready_i <= 1'b1;
          dbg_mem_error_i <= mem_force_err;
          if (|dbg_mem_we_o) mem_arr[dbg_mem_addr_o[5:2]] <= dbg_mem_wdata_o;
          dbg_mem_rdata_i <= mem_arr[dbg_mem_addr_o[5:2]];
        end
        else mem_cnt <= mem_cnt + 1;
      end
      else begin
        dbg_mem_ready_i <= 1'b0;
      end
    end
  end
  logic                   trigger_halt_i = 1'b0;
  logic                   ebreak_halt_i  = 1'b0;
  logic [N_TRIG-1:0]      trigger_hit_i  = '0;

  wire        halt_req_o, resume_req_o;
  wire [4:0]  dbg_reg_addr_o;
  wire [31:0] dbg_reg_wdata_o;
  wire        dbg_reg_we_o;
  wire [11:0] dbg_csr_addr_o;
  wire [31:0] dbg_csr_wdata_o;
  wire        dbg_csr_we_o;
  wire [31:0] dbg_pc_wdata_o;
  wire        dbg_pc_we_o;
  wire        dbg_mem_req_o;
  wire [31:0] dbg_mem_addr_o;
  wire [3:0]  dbg_mem_we_o;
  wire [31:0] dbg_mem_wdata_o;
  wire        dbg_ndmreset_o, dbg_hartreset_o;
  wire        dbg_singlestep_o, dbg_ebreakm_o, dcsr_stopcount_o;
  wire [31:0] progbuf0_o, progbuf1_o;
  wire [N_TRIG-1:0][31:0] tdata1_o, tdata2_o;

  jtag_top #(
      .USE_CJTAG         (1'b0),
      .IDCODE            (32'h1DEAD3FF),
      .IR_LEN            (5),
      .N_TRIGGERS        (N_TRIG),
      .DBG_BUS_TIMEOUT_W (DBG_BUS_TIMEOUT_W)
  ) dut (
      .clk_i   (clk),
      .rst_n_i (rst_n),
      .ntrst_i (ntrst),

      .pin0_tck_i (tck),
      .pin1_tms_i (tms),
      .pin1_tms_o (),
      .pin1_tms_oe(),
      .pin2_tdi_i (tdi),
      .pin3_tdo_o (tdo),
      .pin3_tdo_oe(tdo_oe),

      .halt_req_o  (halt_req_o),
      .halted_i    (halted_i),
      .resume_req_o(resume_req_o),
      .resumeack_i (resumeack_i),

      .dbg_reg_addr_o (dbg_reg_addr_o),
      .dbg_reg_wdata_o(dbg_reg_wdata_o),
      .dbg_reg_we_o   (dbg_reg_we_o),
      .dbg_reg_rdata_i(dbg_reg_rdata_i),
      .dbg_csr_addr_o (dbg_csr_addr_o),
      .dbg_csr_wdata_o(dbg_csr_wdata_o),
      .dbg_csr_we_o   (dbg_csr_we_o),
      .dbg_csr_rdata_i(dbg_csr_rdata_i),

      .dbg_pc_wdata_o(dbg_pc_wdata_o),
      .dbg_pc_we_o   (dbg_pc_we_o),
      .dbg_pc_i      (dbg_pc_i),

      .dbg_mem_req_o  (dbg_mem_req_o),
      .dbg_mem_addr_o (dbg_mem_addr_o),
      .dbg_mem_we_o   (dbg_mem_we_o),
      .dbg_mem_wdata_o(dbg_mem_wdata_o),
      .dbg_mem_ready_i(dbg_mem_ready_i),
      .dbg_mem_error_i(dbg_mem_error_i),
      .dbg_mem_rdata_i(dbg_mem_rdata_i),

      .dbg_ndmreset_o  (dbg_ndmreset_o),
      .dbg_hartreset_o (dbg_hartreset_o),
      .dbg_singlestep_o(dbg_singlestep_o),
      .dbg_ebreakm_o   (dbg_ebreakm_o),
      .dcsr_stopcount_o(dcsr_stopcount_o),
      .progbuf0_o      (progbuf0_o),
      .progbuf1_o      (progbuf1_o),

      .trigger_halt_i(trigger_halt_i),
      .ebreak_halt_i (ebreak_halt_i),
      .trigger_hit_i (trigger_hit_i),
      .tdata1_o      (tdata1_o),
      .tdata2_o      (tdata2_o)
  );

  // ---------------------------------------------------------------------------
  // IR / DMI encodings (mirror jtag_tap.sv)
  // ---------------------------------------------------------------------------
  localparam logic [4:0] IR_IDCODE = 5'h01;
  localparam logic [4:0] IR_DTMCS  = 5'h10;
  localparam logic [4:0] IR_DMI    = 5'h11;

  localparam logic [6:0] DMI_DATA0        = 7'h04;
  localparam logic [6:0] DMI_DMCONTROL    = 7'h10;
  localparam logic [6:0] DMI_DMSTATUS     = 7'h11;
  localparam logic [6:0] DMI_ABSTRACTCS   = 7'h16;
  localparam logic [6:0] DMI_ABSTRACTAUTO = 7'h18;
  localparam logic [6:0] DMI_COMMAND      = 7'h17;
  localparam logic [6:0] DMI_PROGBUF0     = 7'h20;
  localparam logic [6:0] DMI_SBCS         = 7'h38;
  localparam logic [6:0] DMI_SBADDRESS0   = 7'h39;
  localparam logic [6:0] DMI_SBDATA0      = 7'h3c;

  localparam logic [31:0] SBCS_RESET = 32'h2014_0407;   // sbversion=1, readonaddr=1, access=32b, asize=32

  // Access-Register abstract command: cmdtype=0, aarsize=2 (32-bit),
  // transfer=1, write=0/1, regno in [15:0].
  localparam logic [31:0] ACMD_CSR_RD = 32'h0022_0000;   // | regno
  localparam logic [31:0] ACMD_CSR_WR = 32'h0023_0000;   // | regno

  localparam logic [1:0] DMI_OP_READ  = 2'b01;
  localparam logic [1:0] DMI_OP_WRITE = 2'b10;

  // ---------------------------------------------------------------------------
  // Low-level JTAG driver
  // ---------------------------------------------------------------------------
  // One TCK period ~ 20 system-clock cycles so CDC synchronisers settle.
  // TDO is registered on the falling edge of TCK; the extra settle delay after
  // deasserting TCK lets that NBA update land before the caller samples `tdo`.
  task automatic tck_pulse(input logic tms_v, input logic tdi_v);
    tms = tms_v;
    tdi = tdi_v;
    #35; tck = 1'b1;
    #40; tck = 1'b0;
    #5;
  endtask

  // Move through TMS states (bit 0 first).
  task automatic tms_moves(input logic [15:0] pattern, input int n);
    for (int i = 0; i < n; i++) tck_pulse(pattern[i], 1'b0);
  endtask

  task automatic tap_reset();
    tck = 1'b0; tms = 1'b1; tdi = 1'b0;
    for (int i = 0; i < 8; i++) tck_pulse(1'b1, 1'b0);  // -> Test-Logic-Reset
    tck_pulse(1'b0, 1'b0);                              // -> Run-Test/Idle
  endtask

  // Full DUT reset -- run between test groups so state never leaks across them.
  task automatic dut_reset();
    halted_i = 1'b0;
    ntrst = 1'b0; rst_n = 1'b0;
    repeat (8) @(posedge clk);
    ntrst = 1'b1; rst_n = 1'b1;
    repeat (8) @(posedge clk);
    tap_reset();
  endtask

  // From Run-Test/Idle: load IR, return to Run-Test/Idle.
  task automatic ir_scan(input logic [4:0] ir);
    tck_pulse(1'b1, 1'b0);   // RTI -> Select-DR
    tck_pulse(1'b1, 1'b0);   // -> Select-IR
    tck_pulse(1'b0, 1'b0);   // -> Capture-IR
    tck_pulse(1'b0, 1'b0);   // -> Shift-IR
    for (int i = 0; i < 5; i++)
      tck_pulse((i == 4) ? 1'b1 : 1'b0, ir[i]);  // last bit exits (TMS=1 -> Exit1-IR)
    tck_pulse(1'b1, 1'b0);   // -> Update-IR
    tck_pulse(1'b0, 1'b0);   // -> Run-Test/Idle
  endtask

  // From Run-Test/Idle: shift `n` bits of `din` (LSB first), capture TDO into
  // `dout`, return to Run-Test/Idle.
  task automatic dr_scan(input  logic [63:0] din,
                         input  int          n,
                         output logic [63:0] dout);
    dout = '0;
    tck_pulse(1'b1, 1'b0);   // RTI -> Select-DR
    tck_pulse(1'b0, 1'b0);   // -> Capture-DR
    tck_pulse(1'b0, 1'b0);   // -> Shift-DR
    for (int i = 0; i < n; i++) begin
      dout[i] = tdo;                                  // TDO is valid in Shift-DR
      tck_pulse((i == n-1) ? 1'b1 : 1'b0, din[i]);    // last bit -> Exit1-DR
    end
    tck_pulse(1'b1, 1'b0);   // -> Update-DR
    tck_pulse(1'b0, 1'b0);   // -> Run-Test/Idle
  endtask

  // ---------------------------------------------------------------------------
  // DMI / DTMCS helpers
  // ---------------------------------------------------------------------------
  logic [63:0] scan_ret;

  task automatic dmi_write(input logic [6:0] addr, input logic [31:0] data);
    ir_scan(IR_DMI);
    dr_scan({23'b0, addr, data, DMI_OP_WRITE}, 41, scan_ret);
    // A DMI access needs a run-test/idle settle window for the CLK domain.
    repeat (4) tck_pulse(1'b0, 1'b0);
  endtask

  // Two-scan read: scan #1 latches the address, scan #2's capture returns data.
  task automatic dmi_read(input logic [6:0] addr, output logic [31:0] data);
    ir_scan(IR_DMI);
    dr_scan({23'b0, addr, 32'h0, DMI_OP_READ}, 41, scan_ret);
    repeat (4) tck_pulse(1'b0, 1'b0);
    dr_scan({23'b0, addr, 32'h0, DMI_OP_READ}, 41, scan_ret);
    repeat (4) tck_pulse(1'b0, 1'b0);
    data = scan_ret[33:2];
  endtask

  task automatic dtmcs_scan(input logic [31:0] din, output logic [31:0] dout);
    ir_scan(IR_DTMCS);
    dr_scan({32'b0, din}, 32, scan_ret);
    dout = scan_ret[31:0];
    repeat (4) tck_pulse(1'b0, 1'b0);
  endtask

  localparam logic [31:0] DTMCS_DMIRESET     = 32'h1 << 16;
  localparam logic [31:0] DTMCS_DMIHARDRESET = 32'h1 << 17;

  // Abstract CSR access (hart must look halted for the DM to accept it).
  task automatic acmd_settle();
    repeat (24) tck_pulse(1'b0, 1'b0);   // let cmd_busy holdoff drain
  endtask

  task automatic csr_write(input logic [11:0] csr, input logic [31:0] val);
    dmi_write(DMI_DATA0, val);
    dmi_write(DMI_COMMAND, ACMD_CSR_WR | {20'b0, csr});
    acmd_settle();
  endtask

  task automatic csr_read(input logic [11:0] csr, output logic [31:0] val);
    dmi_write(DMI_COMMAND, ACMD_CSR_RD | {20'b0, csr});
    acmd_settle();
    dmi_read(DMI_DATA0, val);
  endtask

  // ---------------------------------------------------------------------------
  // Scoreboard
  // ---------------------------------------------------------------------------
  int pass_cnt = 0;
  int fail_cnt = 0;

  task automatic check(input string name, input logic cond);
    if (cond) begin
      pass_cnt++;
      $display("  [PASS] %s", name);
    end
    else begin
      fail_cnt++;
      $display("  [FAIL] %s", name);
    end
  endtask

  task automatic check_eq(input string name, input logic [31:0] got, input logic [31:0] exp);
    if (got === exp) begin
      pass_cnt++;
      $display("  [PASS] %s (0x%08x)", name, got);
    end
    else begin
      fail_cnt++;
      $display("  [FAIL] %s : got 0x%08x expected 0x%08x", name, got, exp);
    end
  endtask

  // SBCS field accessors -------------------------------------------------------
  function automatic logic sbcs_busy(input logic [31:0] v);       return v[21]; endfunction
  function automatic logic sbcs_busyerror(input logic [31:0] v);  return v[22]; endfunction
  function automatic logic [2:0] sbcs_error(input logic [31:0] v); return v[14:12]; endfunction

  task automatic sbcs_write(input logic ro_addr, input logic [2:0] acc,
                            input logic autoinc, input logic ro_data,
                            input logic clr_busyerr, input logic [2:0] clr_err);
    // data layout: readonaddr@20, access@[19:17], autoincr@16, readondata@15,
    //              sberror W1C @[14:12], sbbusyerror W1C @22
    dmi_write(DMI_SBCS, ({9'b0, clr_busyerr, 1'b0,
                          ro_addr, acc, autoinc, ro_data, clr_err, 12'b0}));
  endtask

  // Spin the JTAG clock until the DM's SBA engine is (or is not) busy.
  task automatic wait_sba(input logic want_busy);
    logic [31:0] s;
    for (int i = 0; i < 200; i++) begin
      dmi_read(DMI_SBCS, s);
      if (sbcs_busy(s) == want_busy) return;
    end
  endtask

  // ---------------------------------------------------------------------------
  // Test group: SBA sbbusy / sbbusyerror semantics (JTAG_DEBUG_TODO P0 s3)
  // ---------------------------------------------------------------------------
  task automatic test_sba_busy();
    logic [31:0] s, d;
    $display("\n=== sba_busy : writes while sbbusy must not stick + set sbbusyerror ===");

    dut_reset();
    dmi_write(DMI_DMCONTROL, 32'h0000_0001);
    mem_arr[0] = 32'h0;
    mem_latency = 25000;                        // long: SBA stays busy across DMI scans (< 2^16)

    // readonaddr=0 so an SBADDRESS0 write does not auto-start a read.
    sbcs_write(1'b0, 3'd2, 1'b0, 1'b0, 1'b0, 3'b0);
    dmi_write(DMI_SBADDRESS0, 32'h0000_0000);
    dmi_write(DMI_SBDATA0,    32'hCAFE_F00D);   // starts an SBA write, now busy

    wait_sba(1'b1);
    dmi_read(DMI_SBCS, s);
    check("SBA is busy",              sbcs_busy(s) === 1'b1);
    check("sbbusyerror clear at start", sbcs_busyerror(s) === 1'b0);

    // Interfering accesses while busy -----------------------------------------
    dmi_write(DMI_SBADDRESS0, 32'hDEAD_BEEF);   // forbidden: write sbaddress while busy
    dmi_read(DMI_SBCS, s);
    check("sbbusyerror set by SBADDRESS0 write while busy", sbcs_busyerror(s) === 1'b1);

    dmi_write(DMI_SBDATA0, 32'h1111_2222);      // forbidden: write sbdata while busy
    dmi_read(DMI_SBDATA0, d);                   // forbidden: read sbdata while busy
    dmi_read(DMI_SBCS, s);
    check("sbbusyerror still set after SBDATA0 write/read while busy", sbcs_busyerror(s) === 1'b1);

    // Let the in-flight write finish.
    mem_latency = 0;
    wait_sba(1'b0);

    dmi_read(DMI_SBADDRESS0, d);
    check_eq("SBADDRESS0 unchanged by forbidden write", d, 32'h0000_0000);
    dmi_read(DMI_SBDATA0, d);
    check_eq("SBDATA0 unchanged by forbidden write", d, 32'hCAFE_F00D);
    check_eq("memory got the original write data", mem_arr[0], 32'hCAFE_F00D);

    // With sbbusyerror still set, a new SBA op must not be performed ----------
    dmi_write(DMI_SBADDRESS0, 32'h0000_0004);
    sbcs_write(1'b1, 3'd2, 1'b0, 1'b0, 1'b0, 3'b0);   // set readonaddr=1
    dmi_write(DMI_SBADDRESS0, 32'h0000_0004);         // would auto-read, but busyerror is set
    dmi_read(DMI_SBCS, s);
    check("no SBA started while sbbusyerror set", sbcs_busy(s) === 1'b0);

    // Clear sbbusyerror (W1C), then a real read must work -------------------
    sbcs_write(1'b1, 3'd2, 1'b0, 1'b0, 1'b1 /*clr busyerr*/, 3'b111 /*clr sberror*/);
    dmi_read(DMI_SBCS, s);
    check("sbbusyerror cleared (W1C)", sbcs_busyerror(s) === 1'b0);
    check_eq("sberror cleared (W1C)", {29'b0, sbcs_error(s)}, 32'h0);

    mem_arr[0] = 32'hA5A5_1234;
    dmi_write(DMI_SBADDRESS0, 32'h0000_0000);   // readonaddr=1 -> auto read
    wait_sba(1'b0);
    dmi_read(DMI_SBDATA0, d);
    check_eq("SBA read works again after recovery", d, 32'hA5A5_1234);

    mem_latency = 0;
  endtask

  // ---------------------------------------------------------------------------
  // Test group: SBA response timeout is a parameter, not a fixed 15 cycles
  //   (JTAG_DEBUG_TODO P2 s3).  Build with a small DBG_BUS_TIMEOUT_W.
  // ---------------------------------------------------------------------------
  task automatic test_sba_timeout();
    logic [31:0] s, d;
    int tmo;
    if (!$value$plusargs("TMO_W=%d", tmo)) tmo = DBG_BUS_TIMEOUT_W;
    $display("\n=== sba_timeout : timeout counter width = %0d (%0d cycles) ===",
             tmo, (1 << tmo) - 1);

    dut_reset();
    dmi_write(DMI_DMCONTROL, 32'h0000_0001);
    sbcs_write(1'b1, 3'd2, 1'b0, 1'b0, 1'b0, 3'b0);   // readonaddr=1
    mem_arr[0] = 32'h600D_DA7A;

    // Latency well under the timeout -> completes, no sberror.
    mem_latency = (1 << tmo) / 4;
    dmi_write(DMI_SBADDRESS0, 32'h0000_0000);
    wait_sba(1'b0);
    dmi_read(DMI_SBCS, s);
    check_eq("under-timeout latency: sberror stays 0", {29'b0, sbcs_error(s)}, 32'h0);
    dmi_read(DMI_SBDATA0, d);
    check_eq("under-timeout latency: data returned", d, 32'h600D_DA7A);

    // Latency past the timeout -> sberror = timeout(1).
    sbcs_write(1'b1, 3'd2, 1'b0, 1'b0, 1'b1, 3'b111);  // clear any error
    mem_latency = (1 << tmo) + 50;
    dmi_write(DMI_SBADDRESS0, 32'h0000_0000);
    wait_sba(1'b0);
    dmi_read(DMI_SBCS, s);
    check_eq("over-timeout latency: sberror = 1 (timeout)", {29'b0, sbcs_error(s)}, 32'h1);

    mem_latency = 0;
    sbcs_write(1'b1, 3'd2, 1'b0, 1'b0, 1'b1, 3'b111);
  endtask

  // ---------------------------------------------------------------------------
  // Test group: abstract-memory access uses the same parameterized timeout
  //   (JTAG_DEBUG_TODO P2 s4).  Build with a small DBG_BUS_TIMEOUT_W.
  // ---------------------------------------------------------------------------
  localparam logic [6:0] DMI_DATA1 = 7'h05;

  task automatic abs_wait_done();
    logic [31:0] a;
    for (int i = 0; i < 200; i++) begin
      dmi_read(DMI_ABSTRACTCS, a);
      if (!a[12]) return;                        // busy == 0
    end
  endtask

  task automatic test_absmem_timeout();
    logic [31:0] a, d;
    int tmo;
    if (!$value$plusargs("TMO_W=%d", tmo)) tmo = DBG_BUS_TIMEOUT_W;
    $display("\n=== absmem_timeout : abstract access-memory shares the parameterized timeout ===");

    dut_reset();
    dmi_write(DMI_DMCONTROL, 32'h0000_0001);
    halted_i = 1'b1;
    repeat (10) @(posedge clk);
    mem_arr[1] = 32'h1BADB002;

    // Access-Memory read, 32-bit, from address = 0x4 (mem_arr word 1).
    dmi_write(DMI_DATA1, 32'h0000_0004);
    mem_latency = (1 << tmo) / 4;               // under timeout -> succeeds
    dmi_write(DMI_COMMAND, 32'h0220_0000);
    abs_wait_done();
    dmi_read(DMI_ABSTRACTCS, a);
    check_eq("under-timeout: cmderr stays 0", {29'b0, a[10:8]}, 32'h0);
    dmi_read(DMI_DATA0, d);
    check_eq("under-timeout: DATA0 has memory word", d, 32'h1BADB002);

    // Clear cmderr, then repeat with latency past the timeout -> cmderr=BUS(5).
    dmi_write(DMI_ABSTRACTCS, 32'h0000_0700);   // W1C cmderr
    dmi_write(DMI_DATA1, 32'h0000_0004);
    mem_latency = (1 << tmo) + 50;
    dmi_write(DMI_COMMAND, 32'h0220_0000);
    abs_wait_done();
    dmi_read(DMI_ABSTRACTCS, a);
    check_eq("over-timeout: cmderr = 5 (bus error)", {29'b0, a[10:8]}, 32'h5);

    mem_latency = 0;
    halted_i = 1'b0;
  endtask

  // ---------------------------------------------------------------------------
  // Test group: havereset reflects reset by anything (JTAG_DEBUG_TODO P1 s2)
  // ---------------------------------------------------------------------------
  task automatic test_havereset();
    logic [31:0] s;
    $display("\n=== havereset : set after reset, cleared only by ackhavereset ===");

    dut_reset();                                  // power-on / external reset path
    dmi_write(DMI_DMCONTROL, 32'h0000_0001);      // dmactive = 1 (no ack)
    dmi_read(DMI_DMSTATUS, s);
    check("allhavereset set after reset",  s[19] === 1'b1);
    check("anyhavereset set after reset",  s[18] === 1'b1);

    dmi_write(DMI_DMCONTROL, 32'h1000_0001);      // ackhavereset(bit28) + dmactive
    dmi_read(DMI_DMSTATUS, s);
    check("havereset cleared by ackhavereset", (s[19] === 1'b0) && (s[18] === 1'b0));

    // dmactive 1 -> 0 -> 1 must NOT resurrect havereset (already acked)...
    dmi_write(DMI_DMCONTROL, 32'h0000_0000);
    dmi_write(DMI_DMCONTROL, 32'h0000_0001);
    dmi_read(DMI_DMSTATUS, s);
    check("havereset stays clear across dmactive cycle", (s[19] === 1'b0) && (s[18] === 1'b0));

    // ...but a DM-driven reset (ndmreset / hartreset) re-arms it.
    dmi_write(DMI_DMCONTROL, 32'h0000_0003);      // ndmreset(bit1) + dmactive
    dmi_read(DMI_DMSTATUS, s);
    check("ndmreset re-arms havereset", (s[19] === 1'b1) && (s[18] === 1'b1));
    dmi_write(DMI_DMCONTROL, 32'h1000_0001);      // ack + clear ndmreset
    dmi_read(DMI_DMSTATUS, s);
    check("havereset cleared again", (s[19] === 1'b0) && (s[18] === 1'b0));
  endtask

  // ---------------------------------------------------------------------------
  // Test group: hart selection is stable while an abstract command runs
  //   (JTAG_DEBUG_TODO P1 s2)
  // ---------------------------------------------------------------------------
  task automatic test_hartsel_busy();
    logic [31:0] c, a;
    $display("\n=== hartsel_busy : hartsel writes ignored while a command is busy ===");

    dut_reset();
    dmi_write(DMI_DMCONTROL, 32'h0000_0001);
    halted_i = 1'b1;
    repeat (10) @(posedge clk);

    mem_arr[1] = 32'hFEED_C0DE;
    dmi_write(DMI_DATA1, 32'h0000_0004);
    mem_latency = 25000;                          // command stays busy across DMI scans
    dmi_write(DMI_COMMAND, 32'h0220_0000);        // access-memory read, 32-bit

    // Wait for busy, then try to move hartsel.
    for (int i = 0; i < 50; i++) begin
      dmi_read(DMI_ABSTRACTCS, a);
      if (a[12]) break;                           // busy
    end
    check("abstract command is busy", a[12] === 1'b1);

    dmi_write(DMI_DMCONTROL, 32'h0001_0001);      // hartsel=1 + dmactive, while busy
    dmi_read(DMI_DMCONTROL, c);
    check_eq("hartsel unchanged while busy", {22'b0, c[25:16]}, 32'h0);

    mem_latency = 0;
    abs_wait_done();
    dmi_read(DMI_ABSTRACTCS, a);
    check_eq("command completed with cmderr=0", {29'b0, a[10:8]}, 32'h0);
    dmi_read(DMI_DATA0, c);
    check_eq("command returned the memory word", c, 32'hFEED_C0DE);

    // When idle, hartsel is writable (WARL: nonzero -> anynonexistent).
    dmi_write(DMI_DMCONTROL, 32'h0001_0001);
    dmi_read(DMI_DMCONTROL, c);
    check_eq("hartsel writable when idle", {22'b0, c[25:16]}, 32'h1);
    dmi_read(DMI_DMSTATUS, a);
    check("anynonexistent set for hartsel=1 (single-hart)", a[14] === 1'b1);
    dmi_write(DMI_DMCONTROL, 32'h0000_0001);      // back to hart 0
    halted_i = 1'b0;
  endtask

  // ---------------------------------------------------------------------------
  // Test group: dmactive=0 resets Debug Module state (JTAG_DEBUG_TODO P0 s2)
  // ---------------------------------------------------------------------------
  task automatic test_dmactive_reset();
    logic [31:0] rd;
    $display("\n=== dmactive_reset : dmactive=0 must take DM state to reset values ===");

    dut_reset();
    dmi_write(DMI_DMCONTROL, 32'h0000_0001);      // dmactive = 1

    // Seed a spread of DM soft state.
    dmi_write(DMI_DATA0, 32'hAAAA_5555);
    dmi_write(DMI_PROGBUF0, 32'h1234_5678);
    dmi_write(DMI_ABSTRACTAUTO, 32'h0003_0003);
    dmi_write(DMI_SBCS, (32'd1 << 20) | (32'd2 << 17) | (32'd1 << 15));  // readonaddr=1,access=2,readondata=1

    dmi_read(DMI_DATA0, rd);
    check_eq("seed: DATA0", rd, 32'hAAAA_5555);
    dmi_read(DMI_ABSTRACTAUTO, rd);
    check_eq("seed: ABSTRACTAUTO", rd, 32'h0003_0003);   // {pbuf@[17:16], data@[1:0]}
    dmi_read(DMI_SBCS, rd);
    check("seed: SBCS.sbreadondata set", rd[15] === 1'b1);

    // Toggle dmactive 1 -> 0 -> 1.
    dmi_write(DMI_DMCONTROL, 32'h0000_0000);      // dmactive = 0
    dmi_write(DMI_DMCONTROL, 32'h0000_0001);      // dmactive = 1

    dmi_read(DMI_DATA0, rd);
    check_eq("after dmactive pulse: DATA0 reset", rd, 32'h0000_0000);
    dmi_read(DMI_PROGBUF0, rd);
    check_eq("after dmactive pulse: PROGBUF0 reset (EBREAK)", rd, 32'h0010_0073);
    dmi_read(DMI_ABSTRACTAUTO, rd);
    check_eq("after dmactive pulse: ABSTRACTAUTO reset", rd, 32'h0000_0000);
    dmi_read(DMI_SBCS, rd);
    check_eq("after dmactive pulse: SBCS reset value", rd, SBCS_RESET);

    // A field write in the same scan that clears dmactive must not take effect.
    dmi_write(DMI_DATA0, 32'hDEAD_0001);
    dmi_write(DMI_DMCONTROL, 32'h0000_0000);
    dmi_write(DMI_DATA0, 32'hDEAD_0002);          // ignored: dmactive is 0
    dmi_write(DMI_DMCONTROL, 32'h0000_0001);
    dmi_read(DMI_DATA0, rd);
    check_eq("writes while dmactive=0 are dropped", rd, 32'h0000_0000);
  endtask

  // ---------------------------------------------------------------------------
  // Test group: DTMCS reset (JTAG_DEBUG_TODO P0 s1)
  // ---------------------------------------------------------------------------
  task automatic test_dtmcs_reset();
    logic [31:0] rd;
    logic [31:0] dtmcs_rd;

    dut_reset();
    $display("\n=== dtmcs_reset : DTMCS reset must use dtmcs_shift, not dmi_shift ===");

    tap_reset();
    dmi_write(DMI_DMCONTROL, 32'h0000_0001);      // dmactive = 1

    // --- Direction A: dmihardreset in DTMCS *must* wipe soft DM state,
    //     even though the preceding DMI scan carried bit 17 = 0. -----------
    dmi_write(DMI_DATA0, 32'hDEAD_BEEF);
    dmi_write(DMI_ABSTRACTAUTO, 32'h0003_0003);   // autoexec_data=3, autoexec_pbuf=3
    // Final DMI traffic before the DTMCS scan is a READ (data field = 0), so
    // the stale dmi_shift[17] is 0.  A correct DTM ignores dmi_shift here.
    dmi_read(DMI_DATA0, rd);
    check_eq("A: DATA0 seeded", rd, 32'hDEAD_BEEF);

    dtmcs_scan(DTMCS_DMIHARDRESET, dtmcs_rd);

    dmi_read(DMI_DATA0, rd);
    check_eq("A: DATA0 cleared by dmihardreset", rd, 32'h0000_0000);
    dmi_read(DMI_ABSTRACTAUTO, rd);
    check_eq("A: ABSTRACTAUTO cleared by dmihardreset", rd, 32'h0000_0000);

    // --- Direction B: a DTMCS scan with dmihardreset = 0 must NOT wipe DM
    //     state, even though the preceding DMI scan carried bit 17 = 1. ----
    dmi_write(DMI_DMCONTROL, 32'h0000_0001);
    dmi_write(DMI_DATA0, 32'h0000_8000);          // data[15] = 1  -> dmi_shift[17] = 1
    check(  "B: (setup) last DMI write had bit17=1", 1'b1);

    dtmcs_scan(32'h0000_0000, dtmcs_rd);          // no reset bits

    dmi_read(DMI_DATA0, rd);
    check_eq("B: DATA0 survives DTMCS scan w/o dmihardreset", rd, 32'h0000_8000);

    // --- Direction C: dmireset (bit 16) alone must not disturb DM state ----
    dmi_write(DMI_DATA0, 32'h1234_5678);
    dtmcs_scan(DTMCS_DMIRESET, dtmcs_rd);
    dmi_read(DMI_DATA0, rd);
    check_eq("C: DATA0 survives dmireset (no sticky DMI status here)", rd, 32'h1234_5678);

    // DTMCS readback sanity: dmistat/version/abits still sane.
    dtmcs_scan(32'h0000_0000, dtmcs_rd);
    check_eq("DTMCS version field", {28'b0, dtmcs_rd[3:0]}, 32'h1);
    check_eq("DTMCS abits field",  {26'b0, dtmcs_rd[9:4]}, 32'd7);
    check_eq("DTMCS dmistat field",{30'b0, dtmcs_rd[11:10]}, 32'h0);
  endtask

  // ---------------------------------------------------------------------------
  // Test group: halt / resume request + status plumbing through real DMI
  //   transactions (JTAG_DEBUG_TODO P2 s7 -- the DM half; single-step across
  //   instruction types needs a real core and stays with the OpenOCD suite).
  // ---------------------------------------------------------------------------
  task automatic test_halt_resume();
    logic [31:0] s, c;
    $display("\n=== halt_resume : haltreq/resumereq + dmstatus halted/resumeack ===");

    dut_reset();
    dmi_write(DMI_DMCONTROL, 32'h0000_0001);      // dmactive = 1
    halted_i = 1'b0; resumeack_i = 1'b0;
    repeat (6) @(posedge clk);

    // haltreq -> DM asserts halt_req_o
    dmi_write(DMI_DMCONTROL, 32'h8000_0001);      // haltreq(bit31) + dmactive
    repeat (8) @(posedge clk);
    check("halt_req_o asserted after haltreq", halt_req_o === 1'b1);

    // Model the core halting.
    halted_i = 1'b1;
    repeat (8) @(posedge clk);
    dmi_read(DMI_DMSTATUS, s);
    check("dmstatus.allhalted set", s[9] === 1'b1);
    check("dmstatus.anyhalted set", s[8] === 1'b1);

    // Write GPR x1 via abstract command; check it reaches the core port.
    reg_we_seen = 1'b0;
    dmi_write(DMI_DATA0, 32'hC0DE_0001);
    dmi_write(DMI_COMMAND, 32'h0023_1001);        // access-reg write, regno 0x1001 (x1)
    repeat (16) @(posedge clk);
    check("dbg_reg_we_o pulsed for GPR write", reg_we_seen === 1'b1);
    check_eq("GPR write address = x1", {27'b0, reg_we_addr}, 32'h1);
    check_eq("GPR write data forwarded", reg_we_data, 32'hC0DE_0001);

    // Clear haltreq, set resumereq -> resume_req_o.
    dmi_write(DMI_DMCONTROL, 32'h4000_0001);      // resumereq(bit30) + dmactive
    repeat (8) @(posedge clk);
    check("resume_req_o asserted after resumereq", resume_req_o === 1'b1);

    // Model the core resuming.
    halted_i = 1'b0; resumeack_i = 1'b1;
    repeat (8) @(posedge clk);
    dmi_read(DMI_DMSTATUS, s);
    check("dmstatus.allresumeack set", s[17] === 1'b1);
    check("dmstatus.allrunning set",   s[11] === 1'b1);

    resumeack_i = 1'b0;
  endtask

  // ---------------------------------------------------------------------------
  // Test group: mcontrol trigger WARL coercion (JTAG_DEBUG_TODO P1 s5 /
  //   RISCV_COMPATIBILITY_TODO P1).  Unsupported tdata1 fields must read back
  //   as a value JV32 actually implements, not the raw debugger value.
  // ---------------------------------------------------------------------------
  task automatic test_trigger_warl();
    logic [31:0] d;
    $display("\n=== trigger_warl : tdata1 fields coerce to supported values ===");

    dut_reset();
    dmi_write(DMI_DMCONTROL, 32'h0000_0001);
    halted_i = 1'b1; repeat (8) @(posedge clk);
    csr_write(12'h7A0, 32'd0);

    // Write with many unsupported fields asserted:
    //  dmode=1, select=1, timing=1, sizelo=3, action=3, chain=1, match=5,
    //  m=1, execute=1.
    csr_write(12'h7A1, 32'h080F_3AC4);
    csr_read (12'h7A1, d);
    check_eq("type coerced to 2",        {28'b0, d[31:28]}, 32'h2);
    check_eq("action coerced to 1",      {28'b0, d[15:12]}, 32'h1);
    check_eq("match(5) coerced to 0",    {28'b0, d[10:7]},  32'h0);
    check("select cleared",              d[19] === 1'b0);
    check("timing cleared",              d[18] === 1'b0);
    check_eq("sizelo cleared",           {30'b0, d[17:16]}, 32'h0);
    check("chain cleared",               d[11] === 1'b0);
    check("sizehi cleared",              (d[4] === 1'b0) && (d[3] === 1'b0));
    check("dmode kept",                  d[27] === 1'b1);
    check("m kept",                      d[6]  === 1'b1);
    check("execute kept",                d[2]  === 1'b1);

    // match = 1 (NAPOT) is supported and must stick.
    csr_write(12'h7A1, 32'h0800_10C1);   // dmode, action=1, match=1, m=1, load=1
    csr_read (12'h7A1, d);
    check_eq("match=1 (NAPOT) preserved", {28'b0, d[10:7]}, 32'h1);
    check("load kept",                    d[0] === 1'b1);

    halted_i = 1'b0;
  endtask

  // ---------------------------------------------------------------------------
  // Test group: RISC-V Debug Spec 1.0 register conformance
  // ---------------------------------------------------------------------------
  task automatic test_dbg_spec_1_0();
    logic [31:0] d, s;
    $display("\n=== dbg_spec_1_0 : DMSTATUS/DTMCS advertise and match Debug Spec 1.0 ===");

    dut_reset();
    dmi_write(DMI_DMCONTROL, 32'h0000_0001);      // dmactive = 1

    // DTMCS version (IR_DTMCS scan) = 1 (covers Debug Spec 0.13 AND 1.0).
    dtmcs_scan(32'h0, d);
    check_eq("DTMCS.version = 1", {28'b0, d[3:0]}, 32'h1);
    check_eq("DTMCS.abits = 7",  {26'b0, d[9:4]}, 32'd7);
    check_eq("DTMCS.errinfo = 0 (not implemented)", {29'b0, d[20:18]}, 32'h0);

    // DMSTATUS.version = 3 -> Debug Spec 1.0.
    dmi_read(DMI_DMSTATUS, s);
    check_eq("DMSTATUS.version = 3 (Debug Spec 1.0)", {28'b0, s[3:0]}, 32'h3);
    check("DMSTATUS.authenticated = 1",       s[7]  === 1'b1);
    check("DMSTATUS.impebreak = 1",           s[22] === 1'b1);
    check("DMSTATUS.stickyunavail = 0",       s[23] === 1'b0);
    check("DMSTATUS.hasresethaltreq = 0 (opt, not impl)", s[5] === 1'b0);
    check("DMSTATUS.confstrptrvalid = 0",     s[4] === 1'b0);
    check("DMSTATUS.ndmresetpending = 0 (ndmreset clear)", s[24] === 1'b0);

    // ndmresetpending must track dmcontrol.ndmreset.
    dmi_write(DMI_DMCONTROL, 32'h0000_0003);      // ndmreset(bit1) + dmactive
    dmi_read(DMI_DMSTATUS, s);
    check("DMSTATUS.ndmresetpending = 1 while ndmreset set", s[24] === 1'b1);
    dmi_read(DMI_DMCONTROL, d);
    check("DMCONTROL.ndmreset reads back 1", d[1] === 1'b1);
    dmi_write(DMI_DMCONTROL, 32'h0000_0001);      // clear ndmreset
    dmi_read(DMI_DMSTATUS, s);
    check("DMSTATUS.ndmresetpending = 0 after clear", s[24] === 1'b0);

    // hartreset (optional, implemented) must read back in DMCONTROL.
    dmi_write(DMI_DMCONTROL, 32'h2000_0001);      // hartreset(bit29) + dmactive
    dmi_read(DMI_DMCONTROL, d);
    check("DMCONTROL.hartreset reads back 1", d[29] === 1'b1);
    dmi_write(DMI_DMCONTROL, 32'h0000_0001);
    dmi_read(DMI_DMCONTROL, d);
    check("DMCONTROL.hartreset reads back 0 after clear", d[29] === 1'b0);
    check("DMCONTROL.haltreq reads 0 (write-only)", d[31] === 1'b0);
  endtask

  // ---------------------------------------------------------------------------
  // Test group: DMI reset vs hard reset vs dmactive reset are distinct
  //   (JTAG_DEBUG_TODO P1 s1).  This DTM keeps dmistat=0 and never reports a
  //   sticky per-operation DMI error, so dmireset has nothing to clear; the
  //   check is that the three reset controls stay separated.
  // ---------------------------------------------------------------------------
  task automatic test_dmi_reset_sema();
    logic [31:0] s, d;
    $display("\n=== dmi_reset_sema : dmireset / dmihardreset / dmactive are separate ===");

    dut_reset();
    dmi_write(DMI_DMCONTROL, 32'h0000_0001);      // dmactive = 1

    // -- dmireset alone: no sticky DMI status here, so it disturbs nothing ----
    dmi_write(DMI_DATA0, 32'h1234_ABCD);
    dtmcs_scan(DTMCS_DMIRESET, d);
    check_eq("DTMCS.dmistat stays 0",      {30'b0, d[11:10]}, 32'h0);
    dmi_read(DMI_DATA0, d);
    check_eq("dmireset left DATA0 intact", d, 32'h1234_ABCD);
    dmi_read(DMI_DMCONTROL, d);
    check("dmireset leaves dmactive=1", d[0] === 1'b1);

    // -- Seed a trigger CSR (hart state) ------------------------------------
    halted_i = 1'b1; repeat (8) @(posedge clk);
    csr_write(12'h7A0, 32'd1);
    csr_write(12'h7A2, 32'h7EED_0001);           // tdata2[1]
    halted_i = 1'b0;

    // -- dmihardreset: wipes DTM soft state, but not dmactive, not hart CSRs -
    dmi_write(DMI_DATA0, 32'h0BAD_F00D);
    dtmcs_scan(DTMCS_DMIHARDRESET, d);
    dmi_read(DMI_DMCONTROL, d);
    check("dmihardreset leaves dmactive=1", d[0] === 1'b1);
    dmi_read(DMI_DATA0, d);
    check_eq("dmihardreset wiped DATA0", d, 32'h0000_0000);
    halted_i = 1'b1; repeat (8) @(posedge clk);
    csr_write(12'h7A0, 32'd1);
    csr_read(12'h7A2, d);
    check_eq("dmihardreset kept tdata2[1] (hart state)", d, 32'h7EED_0001);
    halted_i = 1'b0;
  endtask

  // ---------------------------------------------------------------------------
  // Test group: N_TRIGGERS sanity via tselect WARL (JTAG_DEBUG_TODO P1 s4)
  //   (Full parameter sweep is an elaboration check driven from the Makefile.)
  // ---------------------------------------------------------------------------
  task automatic test_ntrig();
    dut_reset();
    $display("\n=== ntrig : trigger bank reset + tdata1_o width tracks N_TRIGGERS ===");
    // With N_TRIGGERS=2 both trigger slots must come out of reset defined
    // (tdata1 = type=2 disabled, i.e. 0x2........).  X here means the reset
    // path referenced a slot it did not initialise.
    check("tdata1_o[0] defined after reset", ^tdata1_o[0] !== 1'bx);
    check("tdata1_o[1] defined after reset", ^tdata1_o[1] !== 1'bx);
    check("tdata2_o[0] defined after reset", ^tdata2_o[0] !== 1'bx);
    check("tdata2_o[1] defined after reset", ^tdata2_o[1] !== 1'bx);
    check_eq("tdata1_o[0] type field = 2", {28'b0, tdata1_o[0][31:28]}, 32'h2);
    check_eq("tdata1_o[1] type field = 2", {28'b0, tdata1_o[1][31:28]}, 32'h2);
  endtask

  // Per-index trigger register access + tselect WARL, via abstract CSR access.
  task automatic test_ntrig_warl();
    logic [31:0] rd;
    $display("\n=== ntrig_warl : tselect WARL + per-trigger tdata storage ===");

    dut_reset();
    dmi_write(DMI_DMCONTROL, 32'h0000_0001);
    halted_i = 1'b1;                            // DM only runs abstract cmds when halted
    repeat (10) @(posedge clk);

    csr_write(12'h7A0, 32'd0);                  // tselect = 0
    csr_read (12'h7A0, rd);
    check_eq("tselect accepts 0", rd, 32'd0);

    csr_write(12'h7A0, 32'd1);                  // tselect = 1 (valid, N_TRIGGERS=2)
    csr_read (12'h7A0, rd);
    check_eq("tselect accepts 1", rd, 32'd1);

    csr_write(12'h7A0, 32'd5);                  // out of range -> WARL: unchanged
    csr_read (12'h7A0, rd);
    check_eq("tselect WARL rejects 5 (stays 1)", rd, 32'd1);

    // Write tdata1/tdata2 for trigger 1, then trigger 0, and confirm they are
    // independent per-index storage (the bug: hard-coded [0]/[1] handling).
    csr_write(12'h7A0, 32'd1);
    csr_write(12'h7A2, 32'hCAFE_0001);         // tdata2[1]
    csr_write(12'h7A1, 32'h2000_0055);         // tdata1[1] (type forced to 2)
    csr_write(12'h7A0, 32'd0);
    csr_write(12'h7A2, 32'hBEEF_0000);         // tdata2[0]
    csr_write(12'h7A1, 32'h2000_00AA);         // tdata1[0]

    csr_write(12'h7A0, 32'd0);
    csr_read (12'h7A2, rd);
    check_eq("tdata2[0] readback", rd, 32'hBEEF_0000);
    csr_read (12'h7A1, rd);
    check_eq("tdata1[0] type=2 preserved", {28'b0, rd[31:28]}, 32'h2);

    csr_write(12'h7A0, 32'd1);
    csr_read (12'h7A2, rd);
    check_eq("tdata2[1] readback independent of [0]", rd, 32'hCAFE_0001);

    check_eq("tdata2_o[0] reflects DM store", tdata2_o[0], 32'hBEEF_0000);
    check_eq("tdata2_o[1] reflects DM store", tdata2_o[1], 32'hCAFE_0001);

    halted_i = 1'b0;
  endtask

  // ---------------------------------------------------------------------------
  // Main
  // ---------------------------------------------------------------------------
  string test_sel;

  initial begin
    if (!$value$plusargs("TEST=%s", test_sel)) test_sel = "all";

    ntrst = 1'b0; rst_n = 1'b0;
    repeat (10) @(posedge clk);
    ntrst = 1'b1; rst_n = 1'b1;
    repeat (10) @(posedge clk);

    // Scan-framing calibration: IDCODE is a known constant.
    begin
      logic [63:0] r;
      tap_reset();
      ir_scan(IR_IDCODE);
      dr_scan(64'h0, 32, r);
      $display("  [CAL] IDCODE = 0x%08x (expect 0x1DEAD3FF)", r[31:0]);
    end

    if (test_sel == "all" || test_sel == "ntrig")           test_ntrig();
    if (test_sel == "all" || test_sel == "ntrig")           test_ntrig_warl();
    if (test_sel == "all" || test_sel == "dmactive_reset")  test_dmactive_reset();
    if (test_sel == "all" || test_sel == "dtmcs_reset")     test_dtmcs_reset();
    if (test_sel == "all" || test_sel == "sba_busy")        test_sba_busy();
    if (test_sel == "all" || test_sel == "havereset")       test_havereset();
    if (test_sel == "all" || test_sel == "hartsel_busy")    test_hartsel_busy();
    if (test_sel == "all" || test_sel == "dmi_reset_sema")  test_dmi_reset_sema();
    if (test_sel == "all" || test_sel == "dbg_spec_1_0")    test_dbg_spec_1_0();
    if (test_sel == "all" || test_sel == "trigger_warl")    test_trigger_warl();
    if (test_sel == "all" || test_sel == "halt_resume")     test_halt_resume();
    if (test_sel == "sba_timeout")                          test_sba_timeout();
    if (test_sel == "sba_timeout")                          test_absmem_timeout();

    $display("\n---------------------------------------------");
    $display("  jtag-dtm tb: %0d passed, %0d failed", pass_cnt, fail_cnt);
    $display("---------------------------------------------");
    if (fail_cnt != 0) begin
      $display("RESULT: FAIL");
      $finish(1);
    end
    $display("RESULT: PASS");
    $finish;
  end

  // Watchdog
  initial begin
    #300_000_000;
    $display("RESULT: FAIL (timeout)");
    $finish(1);
  end

endmodule
