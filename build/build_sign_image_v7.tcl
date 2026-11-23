# WEPWAWET SIGN+VERIFY image v7 (= v6 + PL ||h||_1<=omega reject, omega_v1): Zynq UltraScale+ PS + one AXI4-Lite slave (wepwawet_sign_axil).
# Project-mode build in 04_WORK (never touches the Stage 8 / V7 baselines).
# Usage (vivado -mode batch -source):  set ::CLK_MHZ before sourcing to override 300.
if {![info exists ::CLK_MHZ]} { set ::CLK_MHZ 300 }
set root  <WORKDIR>/04_WORK
set src   $root/omega_v1/src
set proj  $root/sign_impl/proj_v7_${::CLK_MHZ}
set part  xczu3eg-sfvc784-2-e
file delete -force $proj
create_project wepwawet_sign $proj -part $part
set_property target_language Verilog [current_project]

# ---- RTL sources (frozen V7 copy + production bridge + retry + wrapper)
set files {}
foreach d {rtl hls_ntt hls_intt hls_shake hls_shake128 hls_poly} {
    foreach f [lsort [concat [glob -nocomplain $src/$d/*.v] [glob -nocomplain $src/$d/*.sv]]] { lappend files $f }
}
lappend files $src/reference/wcore_scratchpad.v
lappend files $src/v7_registered_retry_manager.sv
lappend files $src/wepwawet_sign_axil.v
# Stage 8 TRNG (copied; only change = 2-FF synchroniser in sampler.v)
foreach f {trng_axi ro_bank sampler pack32 health_mon entropy_src} { lappend files $root/sign_v5/src/$f.v }
add_files -norecurse $files
foreach d {hls_ntt hls_intt hls_poly hls_shake hls_shake128} {
    foreach f [glob -nocomplain $src/$d/*.dat] { add_files -norecurse $f }
}
add_files -fileset constrs_1 -norecurse $root/sign_v5/src/trng_v5.xdc
update_compile_order -fileset sources_1

# ---- Block design: PS + SmartConnect + RTL module reference
create_bd_design wepwawet_sign
set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e:3.4 zynq_ultra_ps_e_0]
set_property -dict [list \
    CONFIG.PSU__USE__M_AXI_GP0 {1} CONFIG.PSU__USE__M_AXI_GP1 {0} CONFIG.PSU__USE__M_AXI_GP2 {0} \
    CONFIG.PSU__MAXIGP0__DATA_WIDTH {32} \
    CONFIG.PSU__CRL_APB__PL0_REF_CTRL__SRCSEL {IOPLL} \
    CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ $::CLK_MHZ \
    CONFIG.PSU__USE__IRQ0 {1} ] $ps
set rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_pl0]
set sc  [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 axi_sc]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {2}] $sc
set core [create_bd_cell -type module -reference wepwawet_sign_axil wepwawet_sign_0]
set_property CONFIG.MAX_ATTEMPTS 814 $core
set trng [create_bd_cell -type module -reference trng_axi trng_0]

connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] \
    [get_bd_pins zynq_ultra_ps_e_0/maxihpm0_fpd_aclk] [get_bd_pins rst_pl0/slowest_sync_clk] \
    [get_bd_pins axi_sc/aclk] [get_bd_pins wepwawet_sign_0/aclk] [get_bd_pins trng_0/s_axi_aclk]
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_resetn0] [get_bd_pins rst_pl0/ext_reset_in]
connect_bd_net [get_bd_pins rst_pl0/peripheral_aresetn] \
    [get_bd_pins axi_sc/aresetn] [get_bd_pins wepwawet_sign_0/aresetn] [get_bd_pins trng_0/s_axi_aresetn]
connect_bd_intf_net [get_bd_intf_pins zynq_ultra_ps_e_0/M_AXI_HPM0_FPD] [get_bd_intf_pins axi_sc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_sc/M00_AXI] [get_bd_intf_pins wepwawet_sign_0/s_axi]
connect_bd_intf_net [get_bd_intf_pins axi_sc/M01_AXI] [get_bd_intf_pins trng_0/s_axi]
connect_bd_net [get_bd_pins wepwawet_sign_0/irq] [get_bd_pins zynq_ultra_ps_e_0/pl_ps_irq0]
assign_bd_address
set segs [get_bd_addr_segs -of_objects [get_bd_addr_spaces zynq_ultra_ps_e_0/Data]]
puts "SIGN_IMG_ADDR_SEGS=$segs"
# 3 passes so no intermediate overlap: park TRNG, place SIGN, place TRNG.
foreach seg $segs { if {[string match *trng_0* $seg]} { set_property range 4K $seg; set_property offset 0xA0100000 $seg } }
foreach seg $segs { if {![string match *trng_0* $seg]} { set_property range 128K $seg; set_property offset 0xA0000000 $seg } }
foreach seg $segs { if {[string match *trng_0* $seg]} { set_property offset 0xA0020000 $seg } }
foreach seg $segs { puts "SIGN_IMG_ADDR_SEG=$seg off=[get_property offset $seg] range=[get_property range $seg]" }
validate_bd_design
save_bd_design
make_wrapper -files [get_files $proj/wepwawet_sign.srcs/sources_1/bd/wepwawet_sign/wepwawet_sign.bd] -top
add_files -norecurse $proj/wepwawet_sign.gen/sources_1/bd/wepwawet_sign/hdl/wepwawet_sign_wrapper.v
set_property top wepwawet_sign_wrapper [current_fileset]
update_compile_order -fileset sources_1

# ---- Synthesis / implementation
set_property STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY rebuilt [get_runs synth_1]
set_property STRATEGY Performance_ExplorePostRoutePhysOpt [get_runs impl_1]
set_property STEPS.WRITE_BITSTREAM.TCL.PRE $root/sign_v5/src/pre_bitstream.tcl [get_runs impl_1]
launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} { puts "SIGN_IMG_SYNTH_FAILED"; exit 1 }
open_run synth_1
report_utilization -file $proj/synth_util.rpt
report_utilization -hierarchical -hierarchical_depth 3 -file $proj/synth_util_hier.rpt
close_design
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
open_run impl_1
report_timing_summary -max_paths 20 -file $proj/route_timing.rpt
report_utilization -file $proj/route_util.rpt
report_route_status -file $proj/route_status.rpt
report_drc -file $proj/route_drc.rpt
puts "TRNG_RO_NETS_ROUTED=[llength [get_nets -quiet -hier -filter {NAME =~ *u_ro_bank/GEN_RO*ro_n*}]]"
report_utilization -hierarchical -hierarchical_depth 3 -file $proj/route_util_hier.rpt
set wns [get_property SLACK [get_timing_paths -delay_type max]]
set whs [get_property SLACK [get_timing_paths -delay_type min]]
puts "SIGN_IMG_CLK_MHZ=$::CLK_MHZ WNS=$wns WHS=$whs"
set fd [open $proj/SIGN_IMG_SUMMARY.txt w]
puts $fd "CLK_MHZ=$::CLK_MHZ\nWNS=$wns\nWHS=$whs\nBIT=[glob -nocomplain $proj/wepwawet_sign.runs/impl_1/*.bit]"
close $fd
# Export .bit + .hwh for PYNQ
set bit [lindex [glob -nocomplain $proj/wepwawet_sign.runs/impl_1/*.bit] 0]
set hwh [lindex [glob -nocomplain $proj/wepwawet_sign.gen/sources_1/bd/wepwawet_sign/hw_handoff/*.hwh] 0]
file mkdir $root/../05_RESULTS/sign_v7_${::CLK_MHZ}
if {$bit ne ""} { file copy -force $bit $root/../05_RESULTS/sign_v7_${::CLK_MHZ}/wepwawet_sign.bit }
if {$hwh ne ""} { file copy -force $hwh $root/../05_RESULTS/sign_v7_${::CLK_MHZ}/wepwawet_sign.hwh }
puts "SIGN_IMG_DONE"
