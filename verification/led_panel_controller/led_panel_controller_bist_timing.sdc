# Timing constraints for led_panel_controller_bist_top (DE2-115)
#
# Board: 50 MHz oscillator on clk_50mhz.
# Host/SDRAM logic: 100 MHz from sdram_clock_gen inside led_panel_controller.
# clk_host_i and clk_sdram_i are the same PLL output in the current design.
#
# BIST synthetic SPI runs on clk_board_50mhz; spi_slave inside the DUT uses
# clk_host_100mhz — treat as an asynchronous scripted interface.
#
# Keep this file free of Tcl control flow (if/foreach).

# =============================================================================
# Board clock
# =============================================================================

create_clock -name clk_board_50mhz -period 20.000 [get_ports clk_50mhz]

# =============================================================================
# PLL-generated host clock (50 MHz board -> 100 MHz)
# =============================================================================
# Confirm pll_inst hierarchy in output_files/*.sdc.rpt after the first compile.

create_generated_clock -name clk_host_100mhz \
    -source [get_ports clk_50mhz] \
    -multiply_by 2 -divide_by 1 \
    [get_pins {*|sdram_clock_gen_inst|pll_inst|altpll_component|auto_generated|pll1|clk[0]}]

# SDRAM chip clock pin (same 100 MHz as PLL output).
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

# =============================================================================
# BIST harness (50 MHz) — not sign-off critical; DUT closes on clk_host_100mhz
# =============================================================================

set_false_path -from [get_clocks clk_board_50mhz]
set_false_path -to   [get_registers {*spi_slave*}]

# =============================================================================
# SignalTap (debug-only)
# =============================================================================

set_false_path -to [get_registers {*acq_trigger_in_reg*}]
set_false_path -to [get_registers {*acq_data_in_reg*}]
set_false_path -from [get_registers {*acq_trigger_in_reg*}]
set_false_path -from [get_registers {*acq_data_in_reg*}]

# =============================================================================
# Asynchronous board inputs / non-critical outputs
# =============================================================================

set_false_path -from [get_ports {btn_start btn_reset}]
set_false_path -to   [get_ports led_status]

# HUB75 panel outputs are source-synchronous to clk_host_100mhz; add output delays
# after board trace models are enabled if needed.
#
# SDRAM pad I/O delays: optional ../bist_sdram_io.sdc (clock name clk_sdram_100mhz).
