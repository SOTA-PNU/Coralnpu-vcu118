# DDR4 calibration firmware for the VCU118 DDR4 controller.
#
# The controller's calibration MicroBlaze (mcs0) boots from two LMB block-RAM
# banks (lmb_bram_I, second_lmb_bram_I). The IP ships the firmware
# (calibration_ddr.elf, ~86 KB at 0x1630..), but this FuseSoC flow leaves the
# placeholder boot loop in the BRAMs, so the controller never calibrates.
# Vivado's write_mem_info does not describe the second bank, so, like Nexus's
# vivado_hook_write_bitstream_post.tcl, the MMI is built from the placed
# BRAMs' BMM info. Unlike that script nothing is hard-coded for Nexus: bank
# sizes come from the BMM info and the part from the open design.
#
#   vcu118_ddr4_fw_mmi <out.mmi>          needs the routed design open
#   vcu118_ddr4_fw_stitch <mmi> <elf> <in.bit> <out.bit>
#
# Standalone (fix an existing bitstream, ~15 min to open the checkpoint):
#   vivado -mode batch -source vcu118_ddr4_fw.tcl -tclargs <routed.dcp> <elf> <in.bit> <out.bit>

set vcu118_ddr4_fw_proc "i_ddr4/inst/u_ddr4_mem_intfc/u_ddr_cal_riu/mcs0/inst/microblaze_I"

proc vcu118_ddr4_fw_sort {a b} {
    # Same order as Nexus: by byte lane, then LSB descending.
    set ba [expr {[lindex $a 3] / 8}]
    set bb [expr {[lindex $b 3] / 8}]
    if {$ba != $bb} { return [expr {$ba < $bb ? -1 : 1}] }
    set la [lindex $a 3]; set lb [lindex $b 3]
    if {$la == $lb} { return 0 }
    return [expr {$la > $lb ? -1 : 1}]
}

proc vcu118_ddr4_fw_group {pattern} {
    set out {}
    foreach c [get_cells -quiet -hierarchical -filter "PRIMITIVE_TYPE =~ BLOCKRAM.BRAM.* && NAME =~ *u_ddr_cal_riu*/${pattern}/*"] {
        set loc [get_property LOC $c]
        set bmm [get_property bmm_info_memory_device $c]
        if {![regexp {RAMB\d+} $loc type] || ![regexp {X\d+Y\d+} $loc xy] ||
            ![regexp {\[(\d+):(\d+)\]\[(\d+):(\d+)\]} $bmm -> msb lsb a0 a1]} {
            error "DDR4FW: cannot parse BRAM $c (LOC '$loc', BMM '$bmm')"
        }
        lappend out [list $type $xy $msb $lsb $a0 $a1]
    }
    return [lsort -command vcu118_ddr4_fw_sort $out]
}

proc vcu118_ddr4_fw_mmi {mmi} {
    global vcu118_ddr4_fw_proc
    set g1 [vcu118_ddr4_fw_group lmb_bram_I]
    set g2 [vcu118_ddr4_fw_group second_lmb_bram_I]
    if {[llength $g1] == 0} { error "DDR4FW: no calibration MicroBlaze BRAMs in this design" }
    # Word depth of each bank from the BMM address ranges (32-bit words).
    set w1 0; foreach b $g1 { set w1 [expr {max($w1, [lindex $b 5] + 1)}] }
    set w2 0; foreach b $g2 { set w2 [expr {max($w2, [lindex $b 5] + 1)}] }
    set space [string map {/ _} $vcu118_ddr4_fw_proc]
    set space "${space}.${space}_dlmb_cntlr"
    set end [expr {($w1 + $w2) * 4 - 1}]
    set fh [open $mmi w]
    puts $fh {<?xml version="1.0" encoding="UTF-8"?>}
    puts $fh {<MemInfo Version="1" Minor="9">}
    puts $fh "  <Processor Endianness=\"Little\" InstPath=\"$vcu118_ddr4_fw_proc\">"
    puts $fh "    <AddressSpace Name=\"$space\" Begin=\"0\" End=\"$end\">"
    foreach {grp base_words words} [list $g1 0 $w1 $g2 $w1 $w2] {
        if {[llength $grp] == 0} continue
        set b0 [expr {$base_words * 4}]
        set b1 [expr {($base_words + $words) * 4 - 1}]
        puts $fh "      <AddressSpaceRange Name=\"$space\" Begin=\"$b0\" End=\"$b1\" CoreMemory_Width=\"32\" MemoryType=\"RAM_SP\" MemoryConfiguration=\"\">"
        puts $fh "        <BusBlock>"
        foreach b $grp {
            lassign $b type xy msb lsb a0 a1
            puts $fh "          <BitLane MemType=\"$type\" Placement=\"$xy\" Read_Width=\"0\" SLR_INDEX=\"-1\">"
            puts $fh "            <DataWidth MSB=\"$msb\" LSB=\"$lsb\"/>"
            puts $fh "            <AddressRange Begin=\"[expr {$a0 + $base_words}]\" End=\"[expr {$a1 + $base_words}]\"/>"
            puts $fh "            <BitLayout pattern=\"\"/>"
            puts $fh "            <Parity ON=\"false\" NumBits=\"0\"/>"
            puts $fh "          </BitLane>"
        }
        puts $fh "        </BusBlock>"
        puts $fh "      </AddressSpaceRange>"
    }
    puts $fh "    </AddressSpace>"
    puts $fh "  </Processor>"
    puts $fh "  <Config>"
    puts $fh "    <Option Name=\"Part\" Val=\"[get_property PART [current_design]]\"/>"
    puts $fh "  </Config>"
    puts $fh "  <DRC>"
    puts $fh "    <Rule Name=\"RDADDRCHANGE\" Val=\"false\"/>"
    puts $fh "  </DRC>"
    puts $fh "</MemInfo>"
    close $fh
    puts "DDR4FW: $mmi: bank1 [llength $g1] BRAMs x $w1 words, bank2 [llength $g2] BRAMs x $w2 words (0..$end)"
}

proc vcu118_ddr4_fw_stitch {mmi elf bit_in bit_out} {
    global vcu118_ddr4_fw_proc
    exec updatemem -force -meminfo $mmi -data $elf -proc $vcu118_ddr4_fw_proc \
        -bit $bit_in -out $bit_out
    puts "DDR4FW: stitched [file tail $elf] into $bit_out"
}

if {[info exists argv] && [llength $argv] == 4 && [string match *.dcp [lindex $argv 0]]} {
    lassign $argv dcp elf bit_in bit_out
    open_checkpoint $dcp
    set mmi [file rootname $bit_out].mmi
    vcu118_ddr4_fw_mmi $mmi
    vcu118_ddr4_fw_stitch $mmi $elf $bit_in $bit_out
}
