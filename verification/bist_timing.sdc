# Shared timing constraints for single-clock hardware BIST tops (DE2-115)
# Sourced by board_pins.qsf / board_no_sdram_assignments.qsf.
#
# Use bist_sdram_timing.sdc (via board_assignments.qsf) for tops that instantiate
# sdram_clock_gen and run host logic at 100 MHz.
#
# Keep this file free of Tcl control flow (if/foreach).

# =============================================================================
# Board clock
# =============================================================================

create_clock -name clk_board_50mhz -period 20.000 [get_ports clk_50mhz]

derive_clock_uncertainty

# =============================================================================
# Clock domain crossing
# =============================================================================

set_clock_groups -asynchronous \
    -group [get_clocks {clk_board_50mhz}] \
    -group [get_clocks {altera_reserved_tck}]

# =============================================================================
# Asynchronous board inputs / non-critical outputs
# =============================================================================

set_false_path -from [get_ports {btn_start btn_reset}]
set_false_path -to   [get_ports led_status]
