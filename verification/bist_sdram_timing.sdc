# Shared timing constraints for SDRAM hardware BIST tops (DE2-115)
# Sourced by board_assignments.qsf — projects with sdram_clock_gen in the top.
#
# Board: 50 MHz on clk_50mhz. Host + SDRAM controller logic: 100 MHz PLL output
# (clk_host_i and clk_sdram_i are the same net in the current design).
#
# Keep this file free of Tcl control flow (if/foreach).

# =============================================================================
# Board clock
# =============================================================================

create_clock -name clk_board_50mhz -period 20.000 [get_ports clk_50mhz]

# =============================================================================
# PLL-generated host clock (50 MHz board -> 100 MHz)
# =============================================================================
# Confirm hierarchy in output_files/*.sdc.rpt after the first compile.

create_generated_clock -name clk_host_100mhz \
    -source [get_ports clk_50mhz] \
    -multiply_by 2 -divide_by 1 \
    [get_pins {*|sdram_clock_gen_inst|pll_inst|altpll_component|auto_generated|pll1|clk[0]}]

# SDRAM chip clock output pin (same frequency as host PLL output).
create_generated_clock -name clk_sdram_100mhz \
    -source [get_pins {*|sdram_clock_gen_inst|pll_inst|altpll_component|auto_generated|pll1|clk[0]}] \
    -multiply_by 1 -divide_by 1 \
    [get_ports sdram_clk]

derive_clock_uncertainty

# =============================================================================
# Clock domain crossing
# =============================================================================

set_clock_groups -asynchronous \
    -group [get_clocks {clk_host_100mhz clk_sdram_100mhz}] \
    -group [get_clocks {altera_reserved_tck}]

# BIST harnesses that run on clk_board_50mhz and feed DUT logic on clk_host_100mhz
# (command_processor_bist_top, etc.) — scripted / slow, not single-cycle paths.
set_false_path -from [get_clocks clk_board_50mhz] -to [get_registers {*command_processor*}]

# =============================================================================
# Asynchronous board inputs / non-critical outputs
# =============================================================================

set_false_path -from [get_ports {btn_start btn_reset}]
set_false_path -to   [get_ports led_status]

# SDRAM pad I/O delays: optional bist_sdram_io.sdc after first compile.
