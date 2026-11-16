# PCIe (XDMA) for the VCU118 edge connector, sharing DDR4 C1 with the SoC.
#
#   host PC --PCIe Gen3 x8--> pcie_xdma (axi_aclk 250 MHz, AXI-MM 256 bit)
#            --> pcie_axi_cdc (async, 250 MHz -> 50 MHz main clock)
#            --> ddr_axi_xbar S01 \
#   SoC io_ddr_mem_axi --------> S00 -> M00 --> ddr4_c1_axi_up --> ddr4_c1
#
# Card address 0 of the DMA = DDR offset 0 = SoC address 0x8000_0000.
# Only the low 31 bits of the XDMA address reach the crossbar (2 GB window).
# The SoC keeps working exactly as before when no host talks to the card:
# the crossbar only arbitrates, and the 50 MHz side is the one that already
# meets timing. Only Xilinx IP (XDMA, converters) runs at 250/300 MHz.
#
# Pins follow the same rule as DDR4 C1 (vcu118_ddr4_c1_ip.tcl): nothing is
# hand-typed. The XDMA lanes and PERST# come from the board interfaces set on
# the IP; the reference clock enters through an IBUFDS_GTE4 in chip_vcu118.sv,
# so vcu118_pcie_pins_xdc writes its PACKAGE_PIN from the board files.
#
# Usage (inside an open project, after vcu118_ddr4_c1_all):
#   source vcu118_pcie_ip.tcl; vcu118_pcie_all <ipdir> <xdc out>
# Prints one "PCIE:" line per decision.

proc vcu118_pcie_log {msg} { puts "PCIE: $msg" }

proc vcu118_pcie_try {ip prop val} {
    if {[catch {set_property $prop $val $ip} err]} {
        vcu118_pcie_log "could not set $prop=$val ($err)"
        return 0
    }
    set now [get_property $prop $ip]
    if {$now ne $val} {
        vcu118_pcie_log "set $prop=$val but it reads back $now"
        return 0
    }
    return 1
}

proc vcu118_pcie_need {ip prop val} {
    if {![vcu118_pcie_try $ip $prop $val]} {
        error "PCIE: [get_property NAME $ip] needs $prop=$val (chip_vcu118.sv is written for it)"
    }
}

# First board interface whose name matches any of the patterns.
proc vcu118_pcie_board_if {patterns} {
    foreach i [lsort [get_board_part_interfaces -quiet *]] {
        foreach p $patterns {
            if {[string match -nocase $p $i]} { return $i }
        }
    }
    return ""
}

proc vcu118_pcie_xdma {ipdir} {
    set lanes_if [vcu118_pcie_board_if {pci_express_x8 *pcie*x8*}]
    set rst_if   [vcu118_pcie_board_if {pcie_perstn *pcie*perst*}]
    if {$lanes_if eq ""} {
        error "PCIE: no x8 PCIe board interface; have: [get_board_part_interfaces -quiet *]"
    }
    vcu118_pcie_log "lanes interface $lanes_if, reset interface [expr {$rst_if eq {} ? {(none)} : $rst_if}]"

    if {[llength [get_ips -quiet pcie_xdma]] == 0} {
        file mkdir $ipdir
        create_ip -name xdma -vendor xilinx.com -library ip -module_name pcie_xdma -dir $ipdir
    }
    set ip [get_ips pcie_xdma]
    # Board interfaces first: they pick the PCIe block, the GT quads and the
    # PERST# pin, and may reset other settings.
    vcu118_pcie_need $ip CONFIG.PCIE_BOARD_INTERFACE $lanes_if
    if {$rst_if ne ""} { vcu118_pcie_try $ip CONFIG.SYS_RST_N_BOARD_INTERFACE $rst_if }

    # Gen3 x8, AXI memory-mapped DMA, 256-bit user side at 250 MHz,
    # one H2C (host -> card: model load) and one C2H (card -> host) channel.
    vcu118_pcie_need $ip CONFIG.functional_mode DMA
    vcu118_pcie_need $ip CONFIG.mode_selection Advanced
    vcu118_pcie_need $ip CONFIG.pl_link_cap_max_link_width X8
    vcu118_pcie_need $ip CONFIG.pl_link_cap_max_link_speed 8.0_GT/s
    vcu118_pcie_need $ip CONFIG.axi_data_width 256_bit
    vcu118_pcie_need $ip CONFIG.axisten_freq 250
    vcu118_pcie_try  $ip CONFIG.ref_clk_freq 100_MHz
    vcu118_pcie_try  $ip CONFIG.xdma_rnum_chnl 1
    vcu118_pcie_try  $ip CONFIG.xdma_wnum_chnl 1
    vcu118_pcie_try  $ip CONFIG.xdma_axi_intf_mm AXI_Memory_Mapped
    vcu118_pcie_try  $ip CONFIG.axilite_master_en false
    vcu118_pcie_try  $ip CONFIG.xdma_pcie_64bit_en false
    vcu118_pcie_try  $ip CONFIG.pf0_device_id 9038

    foreach p {PCIE_BOARD_INTERFACE SYS_RST_N_BOARD_INTERFACE functional_mode
               pl_link_cap_max_link_width pl_link_cap_max_link_speed axi_data_width
               axisten_freq ref_clk_freq xdma_rnum_chnl xdma_wnum_chnl axi_id_width
               axi_addr_width pcie_blk_locn select_quad pf0_device_id} {
        vcu118_pcie_log "xdma $p = [get_property -quiet CONFIG.$p $ip]"
    }
    return $ip
}

# XDMA master (250 MHz) -> main clock (50 MHz). Same data and ID width.
proc vcu118_pcie_axi_cdc {ipdir} {
    if {[llength [get_ips -quiet pcie_axi_cdc]] == 0} {
        create_ip -name axi_clock_converter -vendor xilinx.com -library ip \
            -module_name pcie_axi_cdc -dir $ipdir
    }
    set ip [get_ips pcie_axi_cdc]
    foreach {p v} {PROTOCOL AXI4 DATA_WIDTH 256 ADDR_WIDTH 31 ID_WIDTH 4 ACLK_ASYNC 1} {
        vcu118_pcie_need $ip CONFIG.$p $v
    }
    foreach p {PROTOCOL DATA_WIDTH ADDR_WIDTH ID_WIDTH ACLK_ASYNC SYNCHRONIZATION_STAGES} {
        vcu118_pcie_log "cdc $p = [get_property -quiet CONFIG.$p $ip]"
    }
    return $ip
}

# Two masters (S00 SoC, S01 PCIe) onto the one DDR path, main clock.
# ID_WIDTH 5: one bit tells the two masters apart, four are left for each.
proc vcu118_pcie_xbar {ipdir} {
    if {[llength [get_ips -quiet ddr_axi_xbar]] == 0} {
        create_ip -name axi_crossbar -vendor xilinx.com -library ip \
            -module_name ddr_axi_xbar -dir $ipdir
    }
    set ip [get_ips ddr_axi_xbar]
    foreach {p v} {PROTOCOL AXI4 NUM_SI 2 NUM_MI 1 DATA_WIDTH 256 ADDR_WIDTH 31 ID_WIDTH 5
                   S00_THREAD_ID_WIDTH 1 S01_THREAD_ID_WIDTH 4
                   M00_A00_BASE_ADDR 0x0000000000000000 M00_A00_ADDR_WIDTH 31} {
        vcu118_pcie_need $ip CONFIG.$p $v
    }
    foreach p {PROTOCOL NUM_SI NUM_MI DATA_WIDTH ADDR_WIDTH ID_WIDTH S00_THREAD_ID_WIDTH
               S01_THREAD_ID_WIDTH M00_A00_BASE_ADDR M00_A00_ADDR_WIDTH CONNECTIVITY_MODE
               STRATEGY} {
        vcu118_pcie_log "xbar $p = [get_property -quiet CONFIG.$p $ip]"
    }
    return $ip
}

# PACKAGE_PIN for the reference clock (and PERST# if the IP does not place it)
# from the board files. Writes an XDC and returns its path.
proc vcu118_pcie_pins_xdc {xdc} {
    set clk_if [vcu118_pcie_board_if {pcie_refclk *pcie*refclk* *pcie*clk*}]
    set rst_if [vcu118_pcie_board_if {pcie_perstn *pcie*perst*}]
    if {$clk_if eq ""} {
        error "PCIE: no PCIe reference clock board interface; have: [get_board_part_interfaces -quiet *]"
    }
    set fh [open $xdc w]
    puts $fh "# Generated by vcu118_pcie_ip.tcl from the VCU118 board files. Do not edit."
    set placed {}
    foreach {ifc ports} [list $clk_if {pcie_refclk_p pcie_refclk_n} $rst_if {pcie_perst_n}] {
        if {$ifc eq ""} { continue }
        foreach pin [get_board_part_pins -quiet -of_objects [get_board_part_interfaces $ifc]] {
            set loc [get_property -quiet LOC $pin]
            set ios [get_property -quiet IOSTANDARD $pin]
            vcu118_pcie_log "board pin $ifc/$pin LOC=$loc IOSTANDARD=$ios"
            if {$loc eq ""} { continue }
            if {[llength $ports] == 1} {
                set port [lindex $ports 0]
            } elseif {[regexp -nocase {(_n|n)$} $pin]} {
                set port [lindex $ports 1]
            } else {
                set port [lindex $ports 0]
            }
            puts $fh "set_property PACKAGE_PIN $loc \[get_ports $port\]"
            if {$ios ne "" && $port eq "pcie_perst_n"} {
                puts $fh "set_property IOSTANDARD $ios \[get_ports $port\]"
            }
            lappend placed $port
        }
    }
    # 100 MHz reference from the host slot (the XDMA example design does the
    # same in its top-level XDC). PERST# is asynchronous to everything.
    puts $fh "create_clock -name pcie_refclk -period 10.000 \[get_ports pcie_refclk_p\]"
    puts $fh "set_false_path -from \[get_ports pcie_perst_n\]"
    close $fh
    foreach need {pcie_refclk_p pcie_refclk_n pcie_perst_n} {
        if {[lsearch $placed $need] < 0} {
            error "PCIE: board files gave no pin for $need (placed: $placed)"
        }
    }
    vcu118_pcie_log "wrote $xdc ($placed)"
    return $xdc
}

# Everything chip_vcu118.sv instantiates for PCIe. Also widens the DDR
# upsizer's ID to the crossbar's 5 bits.
proc vcu118_pcie_all {ipdir xdc} {
    set x [vcu118_pcie_xdma $ipdir]
    set c [vcu118_pcie_axi_cdc $ipdir]
    set b [vcu118_pcie_xbar $ipdir]
    set up [get_ips -quiet ddr4_c1_axi_up]
    if {$up eq ""} { error "PCIE: run vcu118_ddr4_c1_all first (ddr4_c1_axi_up missing)" }
    vcu118_pcie_need $up CONFIG.SI_ID_WIDTH 5
    vcu118_pcie_log "axi_up SI_ID_WIDTH = [get_property CONFIG.SI_ID_WIDTH $up]"
    vcu118_pcie_pins_xdc $xdc
    return [list $x $c $b]
}
