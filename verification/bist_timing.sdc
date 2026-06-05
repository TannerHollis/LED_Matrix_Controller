# Shared timing constraints for hardware BIST tops (DE2-115)
# Sourced by each verification project via board_assignments.qsf
#
# Keep this file free of Tcl control flow (if/foreach) — quartus_map embeds STA
# during timing-driven synthesis and complex SDC can trigger 24.1 exit crashes.
#
# After compile, review:
#   output_files/*.sta.rpt  — setup/hold slack
#   output_files/*.sdc.rpt  — PLL clock names (for optional SDRAM I/O delays)

# =============================================================================
# Board and PLL clocks
# =============================================================================

# DE2-115 oscillator: 50 MHz
create_clock -name clk_50mhz -period 20.000 [get_ports clk_50mhz]

# pll_100mhz inside sdram_controller (50 MHz in -> 100 MHz c0 / sdram_clk)
derive_pll_clocks
derive_clock_uncertainty

# =============================================================================
# Clock domain crossing
# =============================================================================

# Host logic (50 MHz) and SDRAM core (100 MHz) connect through async FIFOs
# in sdram_controller.v — do not time cross-domain paths as single-cycle.
set_clock_groups -asynchronous \
    -group [get_clocks clk_50mhz] \
    -group [remove_from_collection [get_clocks] [get_clocks clk_50mhz]]

# =============================================================================
# Asynchronous board inputs / non-critical outputs
# =============================================================================

# Buttons are synchronized in RTL before use (btn_sync / edge detect).
set_false_path -from [get_ports {btn_start btn_reset}]
set_false_path -to   [get_ports led_status]

# SDRAM pad I/O delays: add in Timing Analyzer after first compile, or enable
# bist_sdram_io.sdc once the generated PLL clock name is confirmed in *.sdc.rpt.
