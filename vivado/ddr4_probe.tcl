# Check, before a multi-hour build, that this Vivado can build the VCU118
# DDR4 C1 controller the way patch 0009 wants:
#   1. the IP settings that stick (AXI width, speed),
#   2. the exact port list (instantiation template),
#   3. with "synth": a tiny top with only the controller is synthesized and
#      every DDR4/clock pin must come out placed (PACKAGE_PIN + IOSTANDARD)
#      by the board flow. ~20 min.
# Run via "coral ddr4-probe [synth]". Output lines start with PROBE: or DDR4C1:
# (coral greps for exactly those two prefixes, so every new line needs one).
# "PROBE: CLK" lines answer one question: does the IP believe its reference
# clock is the board's 250 MHz (4000 ps), or something else?

set here [file dirname [file normalize [info script]]]
set work [lindex $argv 0]
set do_synth [expr {[lindex $argv 1] eq "synth"}]
file delete -force $work
create_project ddr4_probe $work -part xcvu9p-flga2104-2L-e
source [file join $here ddr4_c1_ip.tcl]

puts "PROBE: vivado [version -short]"
puts "PROBE: board parts (default paths): [get_board_parts -quiet *vcu118*]"

set ips [vcu118_ddr4_c1_all [file join $work ip]]
set ip [lindex $ips 0]
# --- which setting makes InputClockPeriod come out 4000? ---------------------
# Measured: the shipped settings give InputClockPeriod 14161 = 17 x 833, and the
# MMCM is built for 70.6 MHz while the board pin carries 250 MHz. 4000/833 = 4.8
# is not an integer, so 4000 may simply be illegal once TimePeriod snaps to 833 --
# while 4000 = 4 x 1000 is legal at the 1000 ps the script asks for and is refused.
# Build throwaway IPs with single changes and print what each one settles on.
# They are removed again so they never reach synthesis.
proc clk_variant {tag ipdir ddr_if clk_if steps} {
    set name ddr4_probe_$tag
    if {[catch {
        create_ip -name ddr4 -vendor xilinx.com -library ip -module_name $name -dir $ipdir
        set v [get_ips $name]
        set_property CONFIG.C0_DDR4_BOARD_INTERFACE $ddr_if $v
        if {$clk_if ne ""} { catch {set_property CONFIG.C0_CLOCK_BOARD_INTERFACE $clk_if $v} }
        foreach {prop val} $steps {
            if {[catch {set_property CONFIG.$prop $val $v} e]} {
                puts "PROBE: CLK variant $tag could not set $prop=$val"
            }
        }
        puts [format "PROBE: CLK variant %-10s TimePeriod=%-6s InputClockPeriod=%-7s DataWidth=%-3s AxiDataWidth=%s" \
            $tag [get_property -quiet CONFIG.C0.DDR4_TimePeriod $v] \
                 [get_property -quiet CONFIG.C0.DDR4_InputClockPeriod $v] \
                 [get_property -quiet CONFIG.C0.DDR4_DataWidth $v] \
                 [get_property -quiet CONFIG.C0.DDR4_AxiDataWidth $v]]
    } err]} {
        puts "PROBE: CLK variant $tag FAILED: $err"
    }
    catch {remove_files [get_files -quiet ${name}.xci]}
    catch {file delete -force [file join $ipdir $name]}
}

set _ddr_if ""; set _clk_if ""
foreach i [get_board_part_interfaces -quiet *] {
    if {$_ddr_if eq "" && [string match -nocase *ddr4*c1* $i]} { set _ddr_if $i }
    if {$_clk_if eq "" && [string match -nocase *250mhz_clk1* $i]} { set _clk_if $i }
}
# Everything vcu118_ddr4_c1 sets, in order, except the last line.
set _common {C0.DDR4_AxiSelection true C0.DDR4_Ecc false C0.DDR4_DataWidth 32
             C0.DDR4_AxiDataWidth 256 C0.DDR4_AxiIDWidth 4 C0.DDR4_AxiNarrowBurst true}
if {$_ddr_if ne ""} {
    set vdir [file join $work ipvar]
    file mkdir $vdir
    #   a = exactly what the build does now (expect 14161)
    clk_variant a $vdir $_ddr_if $_clk_if [concat $_common {C0.DDR4_TimePeriod 1000}]
    #   b = same, minus the TimePeriod request that is refused anyway
    clk_variant b $vdir $_ddr_if $_clk_if $_common
    #   c = as now, then ask for 4000 explicitly, last
    clk_variant c $vdir $_ddr_if $_clk_if [concat $_common {C0.DDR4_TimePeriod 1000 C0.DDR4_InputClockPeriod 4000}]
    #   d = no TimePeriod request, then ask for 4000 explicitly
    clk_variant d $vdir $_ddr_if $_clk_if [concat $_common {C0.DDR4_InputClockPeriod 4000}]
} else {
    puts "PROBE: CLK variant skipped (no DDR4 C1 board interface)"
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
set up_ports [ports_of $work ddr4_c1_axi_up]
foreach need {m_axi_aclk m_axi_aresetn s_axi_aclk s_axi_aresetn} {
    if {[lsearch -index 2 $up_ports $need] < 0} { error "PROBE: ddr4_c1_axi_up has no $need" }
}
puts "PROBE: ports match chip_vcu118.sv expectations"

set nbp 0
foreach x [glob -nocomplain -directory [file join $work ip ddr4_c1] -types f */*.xdc *.xdc] {
    set fh [open $x r]; set t [read $fh]; close $fh
    set n [regexp -all -line {BOARD_PART_PIN|BOARD_PIN|PACKAGE_PIN} $t]
    puts "PROBE: xdc [file tail $x] board/pin lines $n"
    incr nbp $n
}

# --- reference clock: what the IP thinks it is given -------------------------
# The board drives c0_sys_clk at 250 MHz = 4000 ps. probe already showed
# DDR4_TimePeriod snapping 1000 -> 833 and DDR4_InputClockPeriod = 14161
# (= 17 x 833, about 70.6 MHz). If that number is what programs the IP's
# internal MMCM, the MMCM is told to expect ~70 MHz on a 250 MHz pin, never
# locks, and ui_clk / ui_clk_sync_rst stay dead -- which is exactly what the
# board reports (GPIO bit 1 = 0 with sys_rst provably released). If instead
# C0_CLOCK_BOARD_INTERFACE wins and the real constraint is 4.000 ns, this
# hypothesis is dead and the reference clock itself must be measured.
foreach prop {C0.DDR4_TimePeriod C0.DDR4_InputClockPeriod C0_CLOCK_BOARD_INTERFACE} {
    puts "PROBE: CLK CONFIG.$prop = [get_property -quiet CONFIG.$prop $ip]"
    if {[catch {list_property_value CONFIG.$prop $ip} vals]} {
        puts "PROBE: CLK CONFIG.$prop allowed = <none> ($vals)"
    } else {
        puts "PROBE: CLK CONFIG.$prop allowed = $vals"
    }
}

# The timing constraint the IP generates for its own reference clock.
foreach x [glob -nocomplain -directory [file join $work ip ddr4_c1] -types f */*.xdc *.xdc] {
    set fh [open $x r]; set t [read $fh]; close $fh
    foreach line [split $t "\n"] {
        set line [string trim $line]
        if {[string match create_clock* $line] || [string match *CLKIN1_PERIOD* $line]} {
            puts "PROBE: CLK xdc [file tail $x] $line"
        }
    }
}

# MMCM/PLL parameters as written into the generated RTL (capped: the IP has
# hundreds of files and only the clocking module matters).
set shown 0
foreach ext {v sv vhd} {
    foreach f [glob -nocomplain -directory [file join $work ip ddr4_c1] -types f \
                   *.$ext */*.$ext */*/*.$ext */*/*/*.$ext] {
        if {$shown >= 60} { break }
        set fh [open $f r]; set t [read $fh]; close $fh
        foreach line [split $t "\n"] {
            set line [string trim $line]
            if {[regexp {CLKIN1_PERIOD|CLKFBOUT_MULT|DIVCLK_DIVIDE|CLKOUT0_DIVIDE} $line]} {
                puts "PROBE: CLK rtl [file tail $f] $line"
                if {[incr shown] >= 60} { puts "PROBE: CLK rtl (capped at 60 lines)"; break }
            }
        }
    }
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

    # The clocking primitive the controller actually got, after elaboration.
    # CLKIN1_PERIOD here is the decisive number: 4.000 kills the hypothesis
    # above, 14.161 confirms it.
    foreach cell [get_cells -quiet -hier -filter {REF_NAME =~ MMCM* || REF_NAME =~ PLLE*}] {
        puts "PROBE: CLK cell [get_property REF_NAME $cell] $cell"
        foreach prop {CLKIN1_PERIOD CLKFBOUT_MULT_F CLKFBOUT_MULT DIVCLK_DIVIDE \
                      CLKOUT0_DIVIDE_F CLKOUT0_DIVIDE} {
            set v [get_property -quiet $prop $cell]
            if {$v ne ""} { puts "PROBE: CLK   $prop = $v" }
        }
    }
    foreach c [get_clocks -quiet] {
        puts "PROBE: CLK clock $c period [get_property -quiet PERIOD $c] src [get_property -quiet SOURCE_PINS $c]"
    }
}
# How the generated IP declares sys_rst. The DDR4 IP has no polarity
# CONFIG property, so the polarity lives in the .xci interface metadata.
foreach x [glob -nocomplain -directory [file join $work ip ddr4_c1] *.xci] {
    set fh [open $x r]; set lines [split [read $fh] "\n"]; close $fh
    set n [llength $lines]
    for {set i 0} {$i < $n} {incr i} {
        set line [string trim [lindex $lines $i]]
        if {[string match -nocase *POLARITY* $line]} {
            puts "PROBE: xci POLARITY-line $line"
            for {set j [expr {$i - 6}]} {$j <= $i + 2} {incr j} {
                if {$j >= 0 && $j < $n} {
                    puts "PROBE: xci   ctx\[$j\] [string trim [lindex $lines $j]]"
                }
            }
        }
    }
    # the RST interface block
    for {set i 0} {$i < $n} {incr i} {
        if {[string match {*"RST"*} [lindex $lines $i]]} {
            for {set j $i} {$j <= $i + 14} {incr j} {
                if {$j < $n} { puts "PROBE: xci RST\[$j\] [string trim [lindex $lines $j]]" }
            }
        }
    }
}
puts "PROBE: done"
