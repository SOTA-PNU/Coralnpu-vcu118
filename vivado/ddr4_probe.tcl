# Check, before a multi-hour build, that this Vivado can build the VCU118
# DDR4 C1 controller the way patch 0009 wants:
#   1. the IP settings that stick (AXI width, speed),
#   2. the exact port list (instantiation template),
#   3. with "synth": a tiny top with only the controller is synthesized and
#      every DDR4/clock pin must come out placed (PACKAGE_PIN + IOSTANDARD)
#      by the board flow. ~20 min.
# Run via "coral ddr4-probe [synth]". Output lines start with PROBE: or DDR4C1:.

set here [file dirname [file normalize [info script]]]
set work [lindex $argv 0]
set do_synth [expr {[lindex $argv 1] eq "synth"}]
file delete -force $work
create_project ddr4_probe $work -part xcvu9p-flga2104-2L-e
source [file join $here ddr4_c1_ip.tcl]

puts "PROBE: vivado [version -short]"
puts "PROBE: board parts (default paths): [get_board_parts -quiet *vcu118*]"

set ip [vcu118_ddr4_c1 [file join $work ip]]
set axiw [get_property CONFIG.C0.DDR4_AxiDataWidth $ip]
set ips [list $ip]
if {$axiw != 256} {
    puts "PROBE: controller AXI is $axiw bits; adding a 256->$axiw upsizer"
    lappend ips [vcu118_ddr4_c1_axi_up [file join $work ip] $axiw]
}
generate_target {instantiation_template synthesis} $ips

proc ports_of {work name} {
    set veo [lindex [glob -nocomplain [file join $work ip $name *.veo]] 0]
    if {$veo eq ""} { error "PROBE: no instantiation template for $name" }
    set fh [open $veo r]
    set ports {}
    foreach line [split [read $fh] "\n"] {
        if {[regexp {^\s*\.([A-Za-z0-9_]+)\s*\(.*//\s*(input|output|inout)\s+wire\s*(\[[^\]]*\])?} $line -> n d w]} {
            regsub -all {\s} $w {} w
            lappend ports [list $d $w $n]
            puts [format "PROBE: %s port %-6s %-10s %s" $name $d $w $n]
        }
    }
    close $fh
    return $ports
}
set ports [ports_of $work ddr4_c1]
if {[llength $ips] > 1} { ports_of $work ddr4_c1_axi_up }

set nbp 0
foreach x [glob -nocomplain -directory [file join $work ip ddr4_c1] -types f */*.xdc *.xdc] {
    set fh [open $x r]; set t [read $fh]; close $fh
    set n [regexp -all -line {BOARD_PART_PIN|BOARD_PIN|PACKAGE_PIN} $t]
    puts "PROBE: xdc [file tail $x] board/pin lines $n"
    incr nbp $n
}

if {$do_synth} {
    # Top = the controller with its memory/clock pins as top ports, AXI idle.
    set top [file join $work probe_top.v]
    set fh [open $top w]
    set decl {}
    set conn {}
    foreach p $ports {
        lassign $p d w n
        if {$n eq "c0_init_calib_complete"} {
            lappend conn "    .${n}(c)"
        } elseif {[string match c0_ddr4_s_axi_* $n] || $n in {c0_ddr4_ui_clk c0_ddr4_ui_clk_sync_rst
                c0_ddr4_aresetn dbg_clk dbg_bus addn_ui_clkout1 sys_rst}} {
            if {$d eq "input"} {
                lappend conn "    .${n}([expr {$n eq "c0_ddr4_aresetn" ? "1'b1" : "0"}])"
            } else {
                lappend conn "    .${n}()"
            }
        } else {
            lappend decl "  $d wire $w $n"
            lappend conn "    .${n}($n)"
        }
    }
    lappend decl "  output wire calib"
    puts $fh "module probe_top (\n[join $decl ",\n"]\n);"
    puts $fh "  wire c;\n  assign calib = c;"
    puts $fh "  ddr4_c1 u (\n[join $conn ",\n"]\n  );\nendmodule"
    close $fh
    add_files $top
    set_property top probe_top [current_fileset]
    set_property generate_synth_checkpoint false [get_files ddr4_c1.xci]
    puts "PROBE: synthesizing probe_top (controller only)"
    synth_design -top probe_top -part xcvu9p-flga2104-2L-e
    set bad 0
    foreach port [get_ports] {
        if {$port eq "calib"} continue
        set pin [get_property PACKAGE_PIN $port]
        set ios [get_property IOSTANDARD $port]
        if {$pin eq "" || $ios eq "" || $ios eq "DEFAULT"} {
            incr bad
            if {$bad <= 10} { puts "PROBE: UNPLACED $port pin='$pin' iostd='$ios'" }
        }
    }
    puts "PROBE: top ports [llength [get_ports]], unplaced $bad"
    foreach port {c0_sys_clk_p c0_ddr4_dq[0] c0_ddr4_adr[0] c0_ddr4_ck_t[0]} {
        set o [get_ports -quiet $port]
        if {$o ne ""} {
            puts "PROBE: $port -> [get_property PACKAGE_PIN $o] [get_property IOSTANDARD $o]"
        }
    }
    puts "PROBE: LUT [llength [get_cells -hier -filter {PRIMITIVE_GROUP == CLB && PRIMITIVE_SUBGROUP == LUT}]]"
}
puts "PROBE: done"
