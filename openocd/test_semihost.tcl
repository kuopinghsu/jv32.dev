proc as_u32 {v} {
    if {[regexp {^0x[0-9a-fA-F]+$} $v]} { scan $v %x n; return $n }
    if {[regexp {^[0-9]+$} $v]} { return [expr {$v + 0}] }
    if {[regexp {0x([0-9a-fA-F]+)} $v -> hex]} { return [expr "0x$hex"] }
    error "Cannot parse: $v"
}

puts "\[TEST\] semihosting trap sequence"

halt
if {[catch {wait_halt 1000}]} {
    error "hart did not halt"
}

# Restart from reset vector and stop on ebreak in M-mode.
reg dpc 0x80000000
reg mtvec 0x80000074
reg mie 0

if {[catch {riscv set_ebreakm on} err]} {
    puts "\[SKIP\] riscv set_ebreakm unsupported: $err"
    return
}

resume
if {[catch {wait_halt 5000}]} {
    riscv set_ebreakm off
    error "did not halt on semihost ebreak"
}

set dpc [as_u32 [reg dpc]]
set w_pre [as_u32 [lindex [read_memory [expr {$dpc - 4}] 32 1] 0]]
set w_brk [as_u32 [lindex [read_memory $dpc 32 1] 0]]
set w_post [as_u32 [lindex [read_memory [expr {$dpc + 4}] 32 1] 0]]

set entry_marker 0x01F01013
set ebreak_insn  0x00100073
set exit_marker  0x40705013

if {$w_pre != $entry_marker || $w_brk != $ebreak_insn || $w_post != $exit_marker} {
    riscv set_ebreakm off
    error [format "unexpected semihost sequence at dpc=0x%08x: pre=0x%08x brk=0x%08x post=0x%08x" \
        $dpc $w_pre $w_brk $w_post]
}

puts [format "semihost sequence hit at dpc=0x%08x" $dpc]

# Continue by servicing semihost traps so text output becomes visible.
# We emulate host handling for SYS_WRITEC (0x03) and SYS_EXIT_EXTENDED (0x20):
#  - extract args from a0/a1
#  - for WRITEC: fetch byte at [a1], append to output
#  - set a0=0 return code
#  - advance dpc past ebreak (dpc += 4) and resume.
set captured ""
set saw_exit 0
set n_writec 0
set n_exit 0
set n_other 0
for {set i 0} {$i < 12000} {incr i} {
    set op [as_u32 [reg a0]]
    set param [as_u32 [reg a1]]

    if {$op == 0x03} {
        set chv [expr {$param & 0xFF}]
        append captured [format %c $chv]
        incr n_writec
    } elseif {$op == 0x20} {
        set reason [as_u32 [lindex [read_memory $param 32 1] 0]]
        set code   [as_u32 [lindex [read_memory [expr {$param + 4}] 32 1] 0]]
        if {$reason != 0x20026} {
            puts [format "\[WARN\] semihost exit reason=0x%08x code=%d" $reason $code]
        }
        incr n_exit
        set saw_exit 1
    } else {
        incr n_other
        if {$n_other <= 3} {
            puts [format "\[INFO\] semihost op=0x%08x param=0x%08x" $op $param]
        }
    }

    reg a0 0
    reg dpc [expr {$dpc + 4}]

    if {$saw_exit} {
        break
    }

    resume
    if {[catch {wait_halt 5000}]} {
        riscv set_ebreakm off
        error "timeout waiting for next semihost ebreak"
    }

    set dpc [as_u32 [reg dpc]]
    set w_pre [as_u32 [lindex [read_memory [expr {$dpc - 4}] 32 1] 0]]
    set w_brk [as_u32 [lindex [read_memory $dpc 32 1] 0]]
    set w_post [as_u32 [lindex [read_memory [expr {$dpc + 4}] 32 1] 0]]
    if {$w_pre != $entry_marker || $w_brk != $ebreak_insn || $w_post != $exit_marker} {
        riscv set_ebreakm off
        error [format "unexpected semihost sequence at dpc=0x%08x: pre=0x%08x brk=0x%08x post=0x%08x" \
            $dpc $w_pre $w_brk $w_post]
    }
}

if {!$saw_exit} {
    riscv set_ebreakm off
    error "did not observe semihost SYS_EXIT_EXTENDED"
}

puts "--- semihost output begin ---"
puts -nonewline $captured
puts ""
puts "--- semihost output end ---"
puts [format "semihost ops: writec=%d exit=%d other=%d" $n_writec $n_exit $n_other]

if {[string first "Hello via printf (semihost path)" $captured] < 0} {
    riscv set_ebreakm off
    error "missing expected semihost printf message"
}

riscv set_ebreakm off
puts "\[PASS\] semihosting trap sequence + output"
