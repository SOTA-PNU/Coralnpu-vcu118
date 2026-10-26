# Quick check (no synthesis, a few minutes): can this Vivado build the VCU118
# DDR4 C1 controller the way patch 0009 wants, and what does its port list
# look like? Run via "coral ddr4-probe". Output lines start with PROBE: or
# DDR4C1: so they can be grepped out of Vivado's chatter.

set here [file dirname [file normalize [info script]]]
set work [lindex $argv 0]
file delete -force $work
create_project ddr4_probe $work -part xcvu9p-flga2104-2L-e
source [file join $here ddr4_c1_ip.tcl]

puts "PROBE: vivado [version -short]"
puts "PROBE: board parts (default paths): [get_board_parts -quiet *vcu118*]"
puts "PROBE: board.repoPaths: [get_param board.repoPaths]"

set ip [vcu118_ddr4_c1 [file join $work ip]]
foreach i [get_board_part_interfaces -quiet *] {
    if {[string match -nocase *ddr4* $i] || [string match -nocase *clk* $i]} {
        puts "PROBE: board interface $i"
    }
}

generate_target {instantiation_template synthesis} $ip

# Port list from the instantiation template.
set veo [lindex [glob -nocomplain [file join $work ip ddr4_c1 *.veo]] 0]
if {$veo eq ""} { error "PROBE: no instantiation template generated" }
set fh [open $veo r]
foreach line [split [read $fh] "\n"] {
    if {[regexp {^\s*\.([A-Za-z0-9_]+)\s*\(.*//\s*(input|output|inout)\s+wire\s*(\[[^\]]*\])?} $line -> name dir width]} {
        puts [format "PROBE: port %-6s %-12s %s" $dir $width $name]
    }
}
close $fh

# Do the generated constraints place the memory pins?
set npin 0
foreach x [glob -nocomplain -directory [file join $work ip ddr4_c1] -types f */*.xdc *.xdc] {
    set fh [open $x r]
    set n [regexp -all -line {PACKAGE_PIN|\sLOC\s} [read $fh]]
    close $fh
    puts "PROBE: xdc [file tail $x] pin-lines $n"
    incr npin $n
}
puts "PROBE: total pin-lines $npin"
puts "PROBE: done"
