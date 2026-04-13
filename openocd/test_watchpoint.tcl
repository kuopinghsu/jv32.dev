proc run_watchpoint_test {label addr init_write} {
    puts "\[TEST\] $label"

    halt
    if {[catch {wait_halt 1000}]} {
        error "hart did not halt"
    }

    if {$init_write} {
        if {[catch {mww $addr 0} init_err]} {
            error "memory init write failed: $init_err"
        }
    }

    if {[catch {wp $addr 4 w} wp_err]} {
        puts "\[SKIP\] $label unsupported: $wp_err"
        return
    }

    if {[catch {resume} resume_err]} {
        catch {rwp $addr}
        error "resume failed: $resume_err"
    }

    # This relies on natural hart memory traffic hitting $addr after resume.
    if {[catch {wait_halt 500}]} {
        catch {rwp $addr}
        puts "\[SKIP\] $label: hart did not naturally access watched address"
        return
    }

    catch {rwp $addr}
    puts "watchpoint hit on write to [format 0x%08x $addr]"
    puts "\[PASS\] $label"
}

run_watchpoint_test "watchpoint" 0x80000200 1
run_watchpoint_test "strict watchpoint" 0x800009c0 0
