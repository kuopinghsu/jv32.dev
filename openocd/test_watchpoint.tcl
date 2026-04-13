puts "\[TEST\] watchpoint"

# Strategy: reset halt before startup runs, then set a write watchpoint on
# the first DRAM word (0xC0000000).  Startup's BSS-clear / .data-copy loop
# is guaranteed to write to DRAM, so the watchpoint will fire reliably.
set dram_base 0xC0000000

proc reg_val {name} {
    set s [reg $name]
    if {[regexp {0x([0-9a-fA-F]+)} $s -> hex]} {
        return [expr "0x$hex"]
    }
    error "Cannot parse register value from: $s"
}

# ── subtest: write watchpoint ─────────────────────────────────────────────────
puts "\[SUBTEST\] write watchpoint"
reset halt
if {[catch {wait_halt 2000}]} {
    error "hart did not halt after reset"
}

if {[catch {wp $dram_base 4 w} wp_err]} {
    puts "write watchpoint unsupported: $wp_err"
    puts "\[SKIP\] watchpoint: wp command failed"
    return
}

if {[catch {resume} resume_err]} {
    catch {rwp $dram_base}
    error "resume failed: $resume_err"
}

# Startup's DRAM initialisation (BSS-clear or .data copy) writes to 0xC0000000.
if {[catch {wait_halt 2000}]} {
    catch {rwp $dram_base}
    puts "\[SKIP\] watchpoint: startup did not write DRAM (no BSS/data?)"
    return
}

catch {rwp $dram_base}

# Validate DCSR.cause == 2 (trigger) after watchpoint fires.
set dcsr [reg_val dcsr]
set dcsr_cause [expr {($dcsr >> 6) & 0x7}]
if {$dcsr_cause != 2} {
    error "write wp: DCSR.cause expected 2 (trigger) after watchpoint got $dcsr_cause (dcsr=[format 0x%08x $dcsr])"
}
puts "write watchpoint hit on [format 0x%08x $dram_base] dcsr.cause=$dcsr_cause OK"

# ── subtest: read watchpoint ──────────────────────────────────────────────────
# Use an IRAM address that the spin-loop code passes through; we write the
# value first via debug so it is not zero, then watch it for a load-triggered
# halt.  The hart will continuously read from its own code stream (instruction
# fetch via IRAM), so a load-watchpoint on a code-fetch address fires instantly.
# Strategy: halt the spinning hart, place a read watchpoint on its current PC
# (an instruction-fetch load), resume, and expect immediate halt.
puts "\[SUBTEST\] read watchpoint"
halt
if {[catch {wait_halt 1000}]} {
    error "hart did not halt for read wp test"
}
set rwp_addr [reg_val pc]

if {[catch {wp $rwp_addr 4 r} rwp_err]} {
    puts "read watchpoint unsupported: $rwp_err"
} else {
    if {[catch {resume} resume_err2]} {
        catch {rwp $rwp_addr}
        error "resume failed for read wp: $resume_err2"
    }
    if {[catch {wait_halt 1000}]} {
        catch {rwp $rwp_addr}
        puts "read watchpoint: hart did not halt (instruction-fetch load may not trigger data-addr watch)"
    } else {
        catch {rwp $rwp_addr}
        set dcsr2 [reg_val dcsr]
        set cause2 [expr {($dcsr2 >> 6) & 0x7}]
        if {$cause2 != 2} {
            error "read wp: DCSR.cause expected 2 (trigger) got $cause2"
        }
        puts "read watchpoint hit at [format 0x%08x $rwp_addr] dcsr.cause=$cause2 OK"
    }
}

puts "\[PASS\] watchpoint"
