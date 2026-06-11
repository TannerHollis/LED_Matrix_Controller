# Optional SDRAM pad I/O delays — NOT enabled by default.
#
# 1. Run Analysis & Synthesis once with bist_sdram_timing.sdc (or
#    led_panel_controller_bist_timing.sdc) loaded.
# 2. Confirm clk_sdram_100mhz on sdram_clk in output_files/*.sdc.rpt.
# 3. Add to board_assignments.qsf or led_panel_controller board_pins.qsf:
#      set_global_assignment -name SDC_FILE ../bist_sdram_io.sdc
#
# W9825G6KH-6 @ 100 MHz — starting values; tune using *.sta.rpt if I/O fails.

set sdram_clock [get_clocks {clk_sdram_100mhz}]

set sdram_ctrl_out [get_ports {sdram_addr* sdram_ba* sdram_cas_n sdram_cke sdram_cs_n sdram_dqm* sdram_ras_n sdram_we_n}]
set_output_delay -clock $sdram_clock -max 3.0 $sdram_ctrl_out
set_output_delay -clock $sdram_clock -min -0.5 $sdram_ctrl_out

set sdram_dq_ports [get_ports sdram_dq*]
set_input_delay  -clock $sdram_clock -max 3.0 $sdram_dq_ports
set_input_delay  -clock $sdram_clock -min 0.5  $sdram_dq_ports
set_output_delay -clock $sdram_clock -max 3.0 $sdram_dq_ports
set_output_delay -clock $sdram_clock -min -0.5 $sdram_dq_ports
