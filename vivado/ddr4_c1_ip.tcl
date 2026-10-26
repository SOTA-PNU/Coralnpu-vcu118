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

    # --- AXI towards the SoC -----------------------------------------------
    vcu118_ddr4_c1_try $ip CONFIG.C0.DDR4_AxiSelection true
    vcu118_ddr4_c1_try $ip CONFIG.C0.DDR4_Ecc false
    vcu118_ddr4_c1_try $ip CONFIG.C0.DDR4_AxiDataWidth 256
    vcu118_ddr4_c1_try $ip CONFIG.C0.DDR4_AxiIDWidth 4
    vcu118_ddr4_c1_try $ip CONFIG.C0.DDR4_AxiNarrowBurst true

    # --- speed --------------------------------------------------------------
    # The board preset runs C1 at DDR4-2400 (ui_clk 300 MHz). The SoC's
    # DDR-side logic (AXI CDC) runs on ui_clk, so a slower memory clock buys
    # timing margin at no cost that matters here (models are compute-bound).
    # 1000 ps = DDR4-2000, ui_clk 250 MHz, 4x the 250 MHz input clock.
    set tp_before [get_property CONFIG.C0.DDR4_TimePeriod $ip]
    if {![vcu118_ddr4_c1_try $ip CONFIG.C0.DDR4_TimePeriod 1000]} {
        set_property CONFIG.C0.DDR4_TimePeriod $tp_before $ip
    }

    foreach p {C0_DDR4_BOARD_INTERFACE C0_CLOCK_BOARD_INTERFACE C0.DDR4_MemoryPart
               C0.DDR4_MemoryType C0.DDR4_DataWidth C0.DDR4_Ecc C0.DDR4_TimePeriod
               C0.DDR4_InputClockPeriod C0.DDR4_AxiSelection C0.DDR4_AxiDataWidth
               C0.DDR4_AxiIDWidth C0.DDR4_AxiAddressWidth C0.DDR4_AxiNarrowBurst} {
        vcu118_ddr4_c1_log "$p = [get_property -quiet CONFIG.$p $ip]"
    }
    return $ip
}
