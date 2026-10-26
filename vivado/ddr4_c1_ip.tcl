# DDR4 C1 memory controller for the VCU118 (module name: ddr4_c1).
#
# Nexus gets its DDR4 core from Google's internal tree (//internal/fpga/ip/ddr4);
# the public tree only has ddr4_stub. Here we generate the equivalent core from
# the Vivado IP catalog using the VCU118 board files, so pin locations, memory
# part and the 250 MHz C1 system clock come from AMD's board definition rather
# than from a hand-typed XDC.
#
# The SoC side (coralnpu_soc io_ddr_mem_axi_*) is AXI4, 256-bit data, 1-bit ID,
# clocked by the controller's ui_clk, exactly as on Nexus. ECC is off, so the
# controller has no AXI-lite ctrl port; chip_vcu118 answers the SoC's ddr_ctrl
# port itself.
#
# Usage (inside an open project):  source ddr4_c1_ip.tcl; vcu118_ddr4_c1 <ipdir>
# Prints one "DDR4C1:" line per decision so a build log shows what was chosen.

proc vcu118_ddr4_c1_log {msg} { puts "DDR4C1: $msg" }

proc vcu118_ddr4_c1_try {ip prop val} {
    if {[catch {set_property $prop $val $ip} err]} {
        vcu118_ddr4_c1_log "could not set $prop=$val ($err)"
        return 0
    }
    set now [get_property $prop $ip]
    if {$now ne $val} {
        vcu118_ddr4_c1_log "set $prop=$val but it reads back $now"
        return 0
    }
    return 1
}

proc vcu118_ddr4_c1 {ipdir} {
    # --- board part -------------------------------------------------------
    # Board files ship with Vivado (data/xhub/boards) or are downloaded by
    # XHub into the user's ~/.Xilinx. The FuseSoC build runs Vivado with a
    # fake HOME, so look in the real home (~user) too.
    set bps [lsort -dictionary [get_board_parts -quiet *vcu118*]]
    if {[llength $bps] == 0} {
        set cands [glob -nocomplain -types d \
            [file join $::env(XILINX_VIVADO) data xhub boards XilinxBoardStore boards Xilinx] \
            [file join $::env(XILINX_VIVADO) data boards board_files] \
            [file normalize "~[exec id -un]/.Xilinx/Vivado/[version -short]/xhub/board_store/xilinx_board_store"]]
        if {[llength $cands]} {
            set_param board.repoPaths $cands
            vcu118_ddr4_c1_log "board.repoPaths $cands"
            set bps [lsort -dictionary [get_board_parts -quiet *vcu118*]]
        }
    }
    if {[llength $bps] == 0} {
        error "DDR4C1: no VCU118 board files in this Vivado (get_board_parts *vcu118* is empty)"
    }
    set bp [lindex $bps end]
    set_property board_part $bp [current_project]
    vcu118_ddr4_c1_log "board_part $bp"

    # --- board interfaces ---------------------------------------------------
    set all_ifs [get_board_part_interfaces -quiet *]
    set ddr_if ""
    foreach i $all_ifs {
        if {[string match -nocase *ddr4*c1* $i]} { set ddr_if $i; break }
    }
    if {$ddr_if eq ""} {
        error "DDR4C1: no ddr4 C1 board interface; have: $all_ifs"
    }
    vcu118_ddr4_c1_log "memory interface $ddr_if"

    # --- create -------------------------------------------------------------
    if {[llength [get_ips -quiet ddr4_c1]] == 0} {
        file mkdir $ipdir
        create_ip -name ddr4 -vendor xilinx.com -library ip -module_name ddr4_c1 -dir $ipdir
    }
    set ip [get_ips ddr4_c1]
    set_property CONFIG.C0_DDR4_BOARD_INTERFACE $ddr_if $ip

    # The board preset normally picks the matching sys clock; set it
    # explicitly when the board has an obvious C1 clock interface.
    set clk_if ""
    foreach i $all_ifs {
        if {[string match -nocase *c1*clk* $i] || [string match -nocase *clk*c1* $i] ||
            [string match -nocase *250mhz_clk1* $i]} { set clk_if $i; break }
    }
    if {$clk_if ne ""} {
        vcu118_ddr4_c1_try $ip CONFIG.C0_CLOCK_BOARD_INTERFACE $clk_if
    }

    # --- width and speed ----------------------------------------------------
    # The controller's AXI width is fixed at 8 x DQ width (64-bit DQ -> 512).
    # The SoC port is 256 bits (as on Nexus), so use 32 of C1's 64 DQ bits:
    # 1 GB instead of 2 GB, half the bandwidth, which the 50 MHz core cannot
    # use anyway, and no width converter. If the board preset refuses, the
    # caller adds an AXI upsizer instead (vcu118_ddr4_c1_axi_up).
    vcu118_ddr4_c1_try $ip CONFIG.C0.DDR4_AxiSelection true
    vcu118_ddr4_c1_try $ip CONFIG.C0.DDR4_Ecc false
    vcu118_ddr4_c1_try $ip CONFIG.C0.DDR4_DataWidth 32
    vcu118_ddr4_c1_try $ip CONFIG.C0.DDR4_AxiDataWidth 256
    vcu118_ddr4_c1_try $ip CONFIG.C0.DDR4_AxiIDWidth 4
    vcu118_ddr4_c1_try $ip CONFIG.C0.DDR4_AxiNarrowBurst true
    # The preset runs C1 at DDR4-2400 (ui_clk 300 MHz). 1000 ps (ui_clk
    # 250 MHz) would give the SoC's DDR-side CDC more margin.
    vcu118_ddr4_c1_try $ip CONFIG.C0.DDR4_TimePeriod 1000

    foreach p {C0_DDR4_BOARD_INTERFACE C0_CLOCK_BOARD_INTERFACE C0.DDR4_MemoryPart
               C0.DDR4_MemoryType C0.DDR4_DataWidth C0.DDR4_Ecc C0.DDR4_TimePeriod
               C0.DDR4_InputClockPeriod C0.DDR4_AxiSelection C0.DDR4_AxiDataWidth
               C0.DDR4_AxiIDWidth C0.DDR4_AxiAddressWidth C0.DDR4_AxiNarrowBurst} {
        vcu118_ddr4_c1_log "$p = [get_property -quiet CONFIG.$p $ip]"
    }
    return $ip
}

# 256-bit SoC master -> wider controller slave, same clock (ui_clk).
proc vcu118_ddr4_c1_axi_up {ipdir mi_width} {
    if {[llength [get_ips -quiet ddr4_c1_axi_up]] == 0} {
        create_ip -name axi_dwidth_converter -vendor xilinx.com -library ip \
            -module_name ddr4_c1_axi_up -dir $ipdir
    }
    set ip [get_ips ddr4_c1_axi_up]
    foreach {p v} [list PROTOCOL AXI4 SI_DATA_WIDTH 256 MI_DATA_WIDTH $mi_width \
                        ADDR_WIDTH 31 SI_ID_WIDTH 4 ACLK_ASYNC 0] {
        vcu118_ddr4_c1_try $ip CONFIG.$p $v
    }
    foreach p {PROTOCOL SI_DATA_WIDTH MI_DATA_WIDTH ADDR_WIDTH SI_ID_WIDTH ACLK_ASYNC FIFO_MODE} {
        vcu118_ddr4_c1_log "axi_up $p = [get_property -quiet CONFIG.$p $ip]"
    }
    return $ip
}
