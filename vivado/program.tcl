# Program the VCU118 FPGA.
#   vivado -mode batch -source program.tcl -tclargs <file.bit> <hw_server host:port>
# A local hw_server (localhost:3121) is started automatically if none runs.
lassign $argv bit url
if {$bit eq "" || ![file exists $bit]} { error "bitstream not found: '$bit'" }
if {$url eq ""} { set url localhost:3121 }

open_hw_manager
connect_hw_server -url $url
set targets [get_hw_targets *]
if {[llength $targets] == 0} {
  error "no JTAG target on $url. Is the USB cable on J106 and the board powered?"
}
open_hw_target [lindex $targets 0]

set dev [lindex [get_hw_devices -quiet xcvu9p*] 0]
if {$dev eq ""} { error "no xcvu9p on the JTAG chain: [get_hw_devices]" }
current_hw_device $dev
set_property PROGRAM.FILE $bit $dev
set_property PROBES.FILE {} $dev
program_hw_devices $dev
refresh_hw_device -quiet $dev
set done "?"
catch { set done [get_property REGISTER.CONFIG_STATUS.BIT14_DONE_PIN $dev] }
puts "PROGRAMMED: [get_property NAME $dev] DONE=$done"

close_hw_target
disconnect_hw_server
close_hw_manager
