# Optional SDRAM pad I/O delays — NOT enabled by default.
#
# 1. Run Analysis & Synthesis once with bist_timing.sdc only.
# 2. Open output_files/*.sdc.rpt and find the 100 MHz PLL clock name.
# 3. Replace <PLL_CLOCK_NAME> below with that exact name.
# 4. Add to board_assignments.qsf:
#      set_global_assignment -name SDC_FILE ../bist_sdram_io.sdc
#
# W9825G6KH-6 @ 100 MHz — starting values; tune using *.sta.rpt if I/O fails.

# set sdram_clock [get_clocks {<PLL_CLOCK_NAME>}]

# set sdram_ctrl_out [get_ports {sdram_addr* sdram_ba* sdram_cas_n sdram_cke sdram_cs_n sdram_dqm* sdram_ras_n sdram_we_n}]
# set_output_delay -clock $sdram_clock -max 3.0 $sdram_ctrl_out
# set_output_delay -clock $sdram_clock -min -0.5 $sdram_ctrl_out

# set sdram_dq_ports [get_ports sdram_dq*]
# set_input_delay  -clock $sdram_clock -max 3.0 $sdram_dq_ports
# set_input_delay  -clock $sdram_clock -min 0.5  $sdram_dq_ports
# set_output_delay -clock $sdram_clock -max 3.0 $sdram_dq_ports
# set_output_delay -clock $sdram_clock -min -0.5 $sdram_dq_ports
