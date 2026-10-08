#/**************************************************/
#/* Compile Script for Synopsys DC                 */
#/* ADDV Lab 2 Part 1 — pipelined MIPS              */
#/* OSU FreePDK 45nm, flip-flop mapped memories     */
#/*                                                */
#/* dc_shell -f compile_dc.tcl                     */
#/**************************************************/

#/* All SystemVerilog files, separated by spaces   */
set my_sv_files [list ../rtl/top.sv ../rtl/controller.sv ../rtl/datapath.sv]

#/* Top-level Module                               */
set my_toplevel top

#/* Target frequency in MHz for optimization       */
set my_clk_freq_MHz 1000

#/* Delay of input signals (Clock-to-Q, Package etc.)  */
set my_input_delay_ns 0.1

#/* Reserved time for output signals (Holdtime etc.)   */
set my_output_delay_ns 0.1

#/**************************************************/
#/* No modifications needed below                  */
#/**************************************************/
set OSU_FREEPDK [format "%s%s" [getenv "PDK_DIR"] "/osu_soc/lib/files"]
set search_path [concat $search_path $OSU_FREEPDK]
set alib_library_analysis_path $OSU_FREEPDK

set link_library [set target_library [concat [list gscl45nm.db] [list dw_foundation.sldb]]]
set target_library "gscl45nm.db"
define_design_lib WORK -path ./WORK
set verilogout_show_unconnected_pins "true"

analyze -format sverilog $my_sv_files

elaborate $my_toplevel

current_design $my_toplevel

# keep the memories from being optimized away
set_dont_touch [get_cells "imem"]
set_dont_touch [get_cells "dmem"]

link
uniquify

set my_period [expr 1000 / $my_clk_freq_MHz]

set find_clock [ find port [list clk] ]
if {  $find_clock != [list] } {
   set clk_name clk
   create_clock -period $my_period $clk_name
} else {
   set clk_name vclk
   create_clock -period $my_period -name $clk_name
}

set_driving_cell  -lib_cell INVX1  [all_inputs]
set_input_delay $my_input_delay_ns -clock $clk_name [remove_from_collection [all_inputs] $clk_name]
set_output_delay $my_output_delay_ns -clock $clk_name [all_outputs]

compile -map_effort medium
compile -incremental_mapping -map_effort medium

check_design
report_constraint -all_violators

redirect timing_ff.rep { report_timing }
redirect cell_ff.rep { report_cell }
redirect power_ff.rep { report_power }
redirect area_ff.rep { report_area }

quit
