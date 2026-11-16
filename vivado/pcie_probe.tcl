# Check, before a multi-hour build, that this Vivado builds the PCIe part of
# patch 0014 the way chip_vcu118.sv is wired for it:
#   1. the VCU118 board interfaces for PCIe (names the Tcl looks for),
#   2. the XDMA / clock converter / crossbar settings that stick,
#   3. every port of the three IPs and of the widened ddr4_c1_axi_up
#      (instantiation templates), checked against the ports and widths
#      chip_vcu118.sv connects,
#   4. the reference clock / PERST# pins written from the board files,
#   5. that the XDMA IP constrains its GT channels (LOC lines in its XDC).
# Run via "coral pcie-probe" (also at the end of "coral ddr4-probe").
# Output lines start with PROBE:, PCIE: or DDR4C1:.

set here [file dirname [file normalize [info script]]]
set work [lindex $argv 0]
file delete -force $work
create_project pcie_probe $work -part xcvu9p-flga2104-2L-e
source [file join $here ddr4_c1_ip.tcl]
source [file join $here pcie_ip.tcl]

puts "PROBE: vivado [version -short]"
vcu118_ddr4_c1_all [file join $work ip]
foreach i [lsort [get_board_part_interfaces -quiet *]] {
    if {[string match -nocase *pci* $i]} {
        puts "PROBE: board interface $i ([get_property -quiet MODE $i]) pins: [get_board_part_pins -quiet -of_objects $i]"
    }
}
set xdc [file join $work vcu118_pcie_pins.xdc]
set ips [vcu118_pcie_all [file join $work ip] $xdc]
lappend ips [get_ips ddr4_c1_axi_up]
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

# What chip_vcu118.sv (patch 0014) connects: name -> width (1 = scalar).
set expect(pcie_xdma) {
    sys_clk 1 sys_clk_gt 1 sys_rst_n 1 user_lnk_up 1 pci_exp_txp 8 pci_exp_txn 8
    pci_exp_rxp 8 pci_exp_rxn 8 axi_aclk 1 axi_aresetn 1 usr_irq_req 1
    m_axi_awready 1 m_axi_wready 1 m_axi_bid 4 m_axi_bresp 2 m_axi_bvalid 1
    m_axi_arready 1 m_axi_rid 4 m_axi_rdata 256 m_axi_rresp 2 m_axi_rlast 1
    m_axi_rvalid 1 m_axi_awid 4 m_axi_awaddr 64 m_axi_awlen 8 m_axi_awsize 3
    m_axi_awburst 2 m_axi_awprot 3 m_axi_awvalid 1 m_axi_awlock 1 m_axi_awcache 4
    m_axi_wdata 256 m_axi_wstrb 32 m_axi_wlast 1 m_axi_wvalid 1 m_axi_bready 1
    m_axi_arid 4 m_axi_araddr 64 m_axi_arlen 8 m_axi_arsize 3 m_axi_arburst 2
    m_axi_arprot 3 m_axi_arvalid 1 m_axi_arlock 1 m_axi_arcache 4 m_axi_rready 1
}
proc axi_side {pfx iw aw dw region} {
    set l [list ${pfx}_awid $iw ${pfx}_awaddr $aw ${pfx}_awlen 8 ${pfx}_awsize 3 ${pfx}_awburst 2 \
        ${pfx}_awlock 1 ${pfx}_awcache 4 ${pfx}_awprot 3 ${pfx}_awqos 4 ${pfx}_awvalid 1 ${pfx}_awready 1 \
        ${pfx}_wdata $dw ${pfx}_wstrb [expr {$dw / 8}] ${pfx}_wlast 1 ${pfx}_wvalid 1 ${pfx}_wready 1 \
        ${pfx}_bid $iw ${pfx}_bresp 2 ${pfx}_bvalid 1 ${pfx}_bready 1 \
        ${pfx}_arid $iw ${pfx}_araddr $aw ${pfx}_arlen 8 ${pfx}_arsize 3 ${pfx}_arburst 2 \
        ${pfx}_arlock 1 ${pfx}_arcache 4 ${pfx}_arprot 3 ${pfx}_arqos 4 ${pfx}_arvalid 1 ${pfx}_arready 1 \
        ${pfx}_rid $iw ${pfx}_rdata $dw ${pfx}_rresp 2 ${pfx}_rlast 1 ${pfx}_rvalid 1 ${pfx}_rready 1]
    if {$region} { lappend l ${pfx}_awregion 4 ${pfx}_arregion 4 }
    return $l
}
set expect(pcie_axi_cdc) [concat {s_axi_aclk 1 s_axi_aresetn 1 m_axi_aclk 1 m_axi_aresetn 1} \
    [axi_side s_axi 4 31 256 1] [axi_side m_axi 4 31 256 1]]
# crossbar: slave side vectors are 2 x the per-port width, no s_axi_*region
set xs {}
foreach {n w} [axi_side s_axi 5 31 256 0] { lappend xs $n [expr {2 * $w}] }
set expect(ddr_axi_xbar) [concat {aclk 1 aresetn 1} $xs [axi_side m_axi 5 31 256 1]]
# axi_up: slave side now 5-bit ID; master side unchanged (no ID)
set ms {}
foreach {n w} [axi_side m_axi 5 31 512 1] { if {![string match *id $n]} { lappend ms $n $w } }
set expect(ddr4_c1_axi_up) [concat {s_axi_aclk 1 s_axi_aresetn 1 m_axi_aclk 1 m_axi_aresetn 1} \
    [axi_side s_axi 5 31 256 1] $ms]

set bad 0
foreach name {pcie_xdma pcie_axi_cdc ddr_axi_xbar ddr4_c1_axi_up} {
    set ports [ports_of $work $name]
    foreach {n w} $expect($name) {
        set k [lsearch -index 2 $ports $n]
        if {$k < 0} { puts "PROBE: MISMATCH $name has no port $n"; incr bad; continue }
        set got [lindex $ports $k 1]
        set gw 1
        if {[regexp {\[(\d+):(\d+)\]} $got -> hi lo]} { set gw [expr {$hi - $lo + 1}] }
        if {$gw != $w} { puts "PROBE: MISMATCH $name.$n is $gw bits, chip_vcu118.sv expects $w"; incr bad }
    }
    # inputs the RTL leaves unconnected would float
    foreach p $ports {
        lassign $p d w n
        if {$d eq "input" && [lsearch -exact $expect($name) $n] < 0 && ![string match *region $n] && ![string match *qos $n]} {
            puts "PROBE: NOTE $name input $n is not connected by chip_vcu118.sv"
        }
    }
}
puts "PROBE: port check [expr {$bad ? "FAILED ($bad mismatches)" : "ok"}]"

set fh [open $xdc r]
foreach line [split [read $fh] "\n"] { if {$line ne ""} { puts "PROBE: xdc $line" } }
close $fh

# GT placement comes from the XDMA's own constraints
set nloc 0
foreach f [get_files -quiet -of_objects [get_files pcie_xdma.xci] -filter {FILE_TYPE == XDC}] {
    set fh [open $f r]
    foreach line [split [read $fh] "\n"] {
        if {[regexp -nocase {LOC|PACKAGE_PIN} $line] && ![string match "#*" [string trim $line]]} {
            if {$nloc < 24} { puts "PROBE: xdma xdc [file tail $f]: [string trim $line]" }
            incr nloc
        }
    }
    close $fh
}
puts "PROBE: xdma LOC/PACKAGE_PIN lines: $nloc"
puts "PROBE: done"
